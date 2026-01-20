// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibResourceStorage} from "../libraries/LibResourceStorage.sol";
import {LibPremiumStorage} from "../libraries/LibPremiumStorage.sol";
import {LibGamingStorage} from "../libraries/LibGamingStorage.sol";
import {Achievement, AchievementProgress} from "../../../libraries/GamingModel.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";

/**
 * @title ColonyIntegrationFacet
 * @notice Central integration point for all Colony phases (1-5)
 * @dev Coordinates interactions between: staking, resources, events, premium, alliances
 */
contract ColonyIntegrationFacet is AccessControlBase {

    // Events
    event PhaseIntegrationTriggered(uint8 indexed phase, bytes32 indexed entityId, string action);
    event CrossPhaseBonus(bytes32 indexed beneficiary, uint256 amount, string source);
    event SystemSynced(uint32 season, uint256 timestamp);

    // Custom errors
    error InvalidPhase();
    error IntegrationDisabled();

    /**
     * @notice Get comprehensive colony status across all phases
     * @param colonyId Colony to query
     * @dev Emits PhaseIntegrationTriggered for tracking
     */
    function getColonyIntegratedStatus(bytes32 colonyId) 
        external view
        returns (
            // PHASE 1: Staking
            uint256 stakedTokens,
            uint256 stakingLevel,
            // PHASE 2: Resources
            uint256 zicoBalance,
            uint256 ylwBalance,
            uint256[] memory resourceProduction,
            // PHASE 3: Events
            uint256 seasonScore,
            uint256 activeAchievements,
            // PHASE 4: Premium
            bool hasPremiumActions,
            uint256 predictionReputation,
            // PHASE 5: Alliance
            bool inAlliance,
            bytes32 allianceId,
            uint256 contestedZones
        ) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();

        // PHASE 1: Staking (existing system)
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
        stakedTokens = profile.defensiveStake;
        stakingLevel = _getStakingLevel(profile.defensiveStake);

        // PHASE 2: Resources
        zicoBalance = rs.colonyResources[colonyId][0]; // ZICO
        ylwBalance = rs.colonyResources[colonyId][1];  // YLW
        resourceProduction = new uint256[](3);
        resourceProduction[0] = rs.colonyProductionRates[colonyId][0];
        resourceProduction[1] = rs.colonyProductionRates[colonyId][1];
        resourceProduction[2] = rs.colonyProductionRates[colonyId][2];

        // PHASE 3: Events & Seasons
        seasonScore = cws.seasonScores[cws.currentSeason][colonyId];
        activeAchievements = _countActiveAchievements(colonyId);

        // PHASE 4: Premium
        // Get colony owner first to check their premium actions
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        address owner = hs.colonyCreators[colonyId];
        hasPremiumActions = ps.userActiveActionTypes[owner].length > 0;
        predictionReputation = ps.userProfiles[owner].winRate;

        // PHASE 5: Alliance
        allianceId = LibColonyWarsStorage.getUserAllianceId(owner);
        inAlliance = allianceId != bytes32(0);
        
        if (inAlliance) {
            contestedZones = cws.zoneControlBonuses[allianceId];
        }

        return (
            stakedTokens, stakingLevel,
            zicoBalance, ylwBalance, resourceProduction,
            seasonScore, activeAchievements,
            hasPremiumActions, predictionReputation,
            inAlliance, allianceId, contestedZones
        );
    }

    /**
     * @notice Calculate total production multiplier from all phases
     * @param colonyId Colony to calculate for
     */
    function getTotalProductionMultiplier(bytes32 colonyId) 
        external 
        view 
        returns (uint256 multiplier, string memory breakdown) 
    {
        multiplier = 100; // Base 100%
        string memory parts = "";

        // PHASE 2: Territory bonuses
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        uint256[] memory territories = cws.colonyTerritories[colonyId];
        uint256 territoryBonus = 0;
        for (uint256 i = 0; i < territories.length; i++) {
            LibColonyWarsStorage.Territory storage terr = cws.territories[territories[i]];
            territoryBonus += terr.bonusValue;
        }
        multiplier += territoryBonus;
        parts = string.concat("Territory:", _uint2str(territoryBonus), "%");

        // PHASE 3: Seasonal events
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        bytes32 activeEventId = rs.activeResourceEvent;
        if (activeEventId != bytes32(0)) {
            LibResourceStorage.ResourceEvent storage evt = rs.resourceEvents[activeEventId];
            if (evt.active && block.timestamp < evt.endTime) {
                multiplier += evt.productionMultiplier;
                parts = string.concat(parts, " Event:", _uint2str(evt.productionMultiplier), "%");
            }
        }

        // PHASE 4: Premium actions
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        address colonyOwner = hs.colonyCreators[colonyId];
        LibPremiumStorage.ActionType[] memory activeActions = ps.userActiveActionTypes[colonyOwner];
        for (uint256 i = 0; i < activeActions.length; i++) {
            LibPremiumStorage.PremiumAction storage action = ps.userActions[colonyOwner][activeActions[i]];
            if (action.actionType == LibPremiumStorage.ActionType.BOOST_PRODUCTION && action.expiresAt > block.timestamp) {
                multiplier += 50; // +50% from premium (1.5x = 150% total)
                parts = string.concat(parts, " Premium:50%");
                break;
            }
        }

        // PHASE 5: Alliance bonuses
        address owner = hs.colonyCreators[colonyId];
        bytes32 allianceId = LibColonyWarsStorage.getUserAllianceId(owner);
        if (allianceId != bytes32(0)) {
            uint256 allianceBonus = cws.zoneControlBonuses[allianceId];
            multiplier += allianceBonus;
            parts = string.concat(parts, " Alliance:", _uint2str(allianceBonus), "%");
        }
        
        breakdown = parts;
        return (multiplier, breakdown);
    }

    /**
     * @notice Calculate total defensive power from all phases
     * @param colonyId Colony to calculate for
     */
    function getTotalDefensivePower(bytes32 colonyId) 
        external 
        view 
        returns (uint256 totalPower, string memory breakdown) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
        
        totalPower = profile.defensiveStake; // Base
        string memory parts = string.concat("Base:", _uint2str(profile.defensiveStake / 1 ether), " ZICO");

        // PHASE 2: Territory fortress bonuses
        uint256[] memory territories = cws.colonyTerritories[colonyId];
        uint256 fortressBonus = 0;
        for (uint256 i = 0; i < territories.length; i++) {
            LibColonyWarsStorage.Territory storage terr = cws.territories[territories[i]];
            if (terr.territoryType == 3) { // Fortress
                fortressBonus += (totalPower * terr.bonusValue) / 100;
            }
        }
        if (fortressBonus > 0) {
            totalPower += fortressBonus;
            parts = string.concat(parts, " Fortress:+", _uint2str(fortressBonus / 1 ether));
        }

        // PHASE 4: Premium shield
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        address colonyOwner = hs.colonyCreators[colonyId];
        LibPremiumStorage.ActionType[] memory activeActions = ps.userActiveActionTypes[colonyOwner];
        for (uint256 i = 0; i < activeActions.length; i++) {
            LibPremiumStorage.PremiumAction storage action = ps.userActions[colonyOwner][activeActions[i]];
            if (action.actionType == LibPremiumStorage.ActionType.TERRITORY_SHIELD && action.expiresAt > block.timestamp) {
                totalPower += (totalPower * 20) / 100; // +20%
                parts = string.concat(parts, " Shield:+20%");
                break;
            }
        }

        // PHASE 5: Alliance defensive bonuses
        address owner = hs.colonyCreators[colonyId];
        bytes32 allianceId = LibColonyWarsStorage.getUserAllianceId(owner);
        if (allianceId != bytes32(0)) {
            LibColonyWarsStorage.Alliance storage alliance = cws.alliances[allianceId];
            uint256 allianceBonus = (totalPower * alliance.stabilityIndex) / 1000; // 0-10%
            totalPower += allianceBonus;
            parts = string.concat(parts, " Alliance:+", _uint2str(alliance.stabilityIndex / 10), "%");
        }
        
        breakdown = parts;
        return (totalPower, breakdown);
    }

    /**
     * @notice Check if action is restricted by any phase
     * @param user User attempting action
     * @param actionType Action identifier
     */
    function validateCrossPhaseAction(address user, string calldata actionType) 
        external 
        view 
        returns (bool allowed, string memory reason) 
    {
        bytes32 colonyId = LibColonyWarsStorage.getUserPrimaryColony(user);
        if (colonyId == bytes32(0)) {
            return (false, "No primary colony");
        }

        // Check PHASE 3: Seasonal restrictions
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
        if (!season.active) {
            if (keccak256(bytes(actionType)) == keccak256("battle")) {
                return (false, "Season not active");
            }
        }

        // Check PHASE 4: Premium cooldowns
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        if (keccak256(bytes(actionType)) == keccak256("battle")) {
            LibPremiumStorage.ActionType[] memory activeActions = ps.userActiveActionTypes[user];
            for (uint256 i = 0; i < activeActions.length; i++) {
                LibPremiumStorage.PremiumAction storage action = ps.userActions[user][activeActions[i]];
                if (action.actionType == LibPremiumStorage.ActionType.SKIP_BATTLE_COOLDOWN && action.usesRemaining > 0) {
                    return (true, "Premium skip active");
                }
            }
        }

        // Check PHASE 5: Treaty restrictions (NAP - Non-Aggression Pact)
        if (keccak256(bytes(actionType)) == keccak256("attack")) {
            bytes32 attackerAllianceId = LibColonyWarsStorage.getUserAllianceId(user);
            if (attackerAllianceId != bytes32(0)) {
                // Check if target is in a protected alliance
                // This would require target parameter - for now check if user's alliance has active treaties
                // Full implementation would check: activeTreaties[keccak256(alliance1+alliance2)]
                LibColonyWarsStorage.Alliance storage alliance = cws.alliances[attackerAllianceId];
                if (alliance.active && alliance.stabilityIndex > 80) {
                    // High stability alliances have treaty considerations
                    return (true, "Check treaty status with target");
                }
            }
        }

        return (true, "Action allowed");
    }

    /**
     * @notice Get recommended next actions for colony
     * @param colonyId Colony to analyze
     */
    function getRecommendedActions(bytes32 colonyId) 
        external 
        view 
        returns (string[] memory recommendations, uint8[] memory priorities) 
    {
        recommendations = new string[](5);
        priorities = new uint8[](5);
        uint8 count = 0;

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        // Check resource balance
        if (rs.colonyResources[colonyId][0] < 1000 ether) {
            recommendations[count] = "Low ZICO - claim from pods or participate in events";
            priorities[count] = 1; // High priority
            count++;
        }

        // Check territories
        uint256[] memory territories = cws.colonyTerritories[colonyId];
        if (territories.length == 0) {
            recommendations[count] = "No territories - capture one for production bonuses";
            priorities[count] = 2; // Medium
            count++;
        }

        // Check alliance
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        address owner = hs.colonyCreators[colonyId];
        bytes32 allianceId = LibColonyWarsStorage.getUserAllianceId(owner);
        if (allianceId == bytes32(0)) {
            recommendations[count] = "Join alliance for defensive bonuses and missions";
            priorities[count] = 2;
            count++;
        }

        // Check premium potential
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        if (ps.userActiveActionTypes[owner].length == 0 && rs.colonyResources[colonyId][0] > 5000 ether) {
            recommendations[count] = "Consider premium actions for competitive edge";
            priorities[count] = 3; // Low
            count++;
        }

        // Trim arrays
        assembly {
            mstore(recommendations, count)
            mstore(priorities, count)
        }

        return (recommendations, priorities);
    }

    /**
     * @notice Check if attack would violate a treaty between alliances
     * @param attackerColony Attacking colony ID
     * @param targetColony Target colony ID
     * @return violates Whether attack would violate a treaty
     * @return treatyType Type of violated treaty (0=none, 1=NAP, 2=Trade, 3=Military)
     */
    function checkTreatyViolation(bytes32 attackerColony, bytes32 targetColony)
        external
        view
        returns (bool violates, uint8 treatyType)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Get alliances for both colonies
        address attackerOwner = hs.colonyCreators[attackerColony];
        address targetOwner = hs.colonyCreators[targetColony];
        
        if (attackerOwner == address(0) || targetOwner == address(0)) {
            return (false, 0);
        }
        
        bytes32 attackerAllianceId = LibColonyWarsStorage.getUserAllianceId(attackerOwner);
        bytes32 targetAllianceId = LibColonyWarsStorage.getUserAllianceId(targetOwner);
        
        // No treaty if either not in alliance
        if (attackerAllianceId == bytes32(0) || targetAllianceId == bytes32(0)) {
            return (false, 0);
        }
        
        // Check for active treaty
        bytes32 treatyKey = keccak256(abi.encodePacked(attackerAllianceId, targetAllianceId));
        LibColonyWarsStorage.DiplomaticTreaty storage treaty = cws.activeTreaties[treatyKey];
        
        if (treaty.active && treaty.expiresAt > uint40(block.timestamp) && !treaty.broken) {
            // NAP (Type 0) and Military Alliance (Type 2) prevent attacks
            if (treaty.treatyType == 0 || treaty.treatyType == 2) {
                return (true, treaty.treatyType);
            }
        }
        
        return (false, 0);
    }

    /**
     * @notice Get aggregated colony performance metrics
     * @param colonyId Colony to analyze
     * @return performanceScore Overall performance score (0-1000)
     * @return growthTrend Growth trend indicator (-100 to +100)
     * @return efficiencyRating Resource efficiency rating (0-100)
     */
    function getColonyPerformanceMetrics(bytes32 colonyId)
        external
        view
        returns (
            uint256 performanceScore,
            int16 growthTrend,
            uint8 efficiencyRating
        )
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        
        // Base score from staking level (0-250)
        uint256 stakingScore = _getStakingLevel(cws.colonyWarProfiles[colonyId].defensiveStake) * 62;
        
        // Territory control score (0-250)
        uint256 territoryScore = cws.colonyTerritories[colonyId].length * 50;
        if (territoryScore > 250) territoryScore = 250;
        
        // Resource management score (0-250)
        uint256 resourceScore = 0;
        uint256 totalResources = rs.colonyResources[colonyId][0] + 
                                rs.colonyResources[colonyId][1] + 
                                rs.colonyResources[colonyId][2] + 
                                rs.colonyResources[colonyId][3];
        if (totalResources > 10000 ether) resourceScore = 250;
        else resourceScore = (totalResources * 250) / 10000 ether;
        
        // Season performance score (0-250)
        uint256 seasonScore = cws.seasonScores[cws.currentSeason][colonyId];
        uint256 seasonPerformance = seasonScore > 1000 ? 250 : (seasonScore * 250) / 1000;
        
        performanceScore = stakingScore + territoryScore + resourceScore + seasonPerformance;
        if (performanceScore > 1000) performanceScore = 1000;
        
        // Growth trend (simplified - would need historical data for full implementation)
        if (seasonScore > 500) {
            growthTrend = 50; // Positive trend
        } else if (seasonScore > 100) {
            growthTrend = 0; // Neutral
        } else {
            growthTrend = -50; // Negative trend
        }
        
        // Efficiency rating based on production vs consumption
        uint256 totalProduction = rs.colonyProductionRates[colonyId][0] + 
                                 rs.colonyProductionRates[colonyId][1] + 
                                 rs.colonyProductionRates[colonyId][2];
        efficiencyRating = totalProduction > 100 ? 100 : uint8(totalProduction);
        
        return (performanceScore, growthTrend, efficiencyRating);
    }

    // Internal helpers

    function _getStakingLevel(uint256 stake) internal pure returns (uint256) {
        if (stake < 1000 ether) return 1;
        if (stake < 5000 ether) return 2;
        if (stake < 10000 ether) return 3;
        return 4;
    }

    /**
     * @notice Count active (earned but not fully completed) achievements for colony owner
     * @param colonyId Colony to check
     * @return count Number of active achievements
     */
    function _countActiveAchievements(bytes32 colonyId) internal view returns (uint256 count) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        address owner = hs.colonyCreators[colonyId];
        if (owner == address(0)) return 0;
        
        // Get user's achievement history
        uint256[] memory earnedAchievements = gs.userAchievementHistory[owner];
        
        // Count achievements that are earned but have repeatable potential or active progress
        for (uint256 i = 0; i < earnedAchievements.length; i++) {
            uint256 achievementId = earnedAchievements[i];
            Achievement storage achievement = gs.achievements[achievementId];
            AchievementProgress storage progress = gs.userAchievements[owner][achievementId];
            
            // Count if: earned, active, and either repeatable or has ongoing progress
            if (achievement.active && progress.hasEarned) {
                if (achievement.repeatable) {
                    // Check if cooldown has passed for repeatable achievements
                    if (block.timestamp >= progress.earnedAt + achievement.cooldownPeriod) {
                        count++;
                    }
                } else if (progress.currentProgress > 0 && progress.currentProgress < achievement.targetValue) {
                    // Partially completed non-repeatable achievements
                    count++;
                }
            }
        }
        
        return count;
    }

    function _uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) return "0";
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }
}
