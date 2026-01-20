// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibFeeCollection} from "../../staking/libraries/LibFeeCollection.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {ColonyHelper} from "../../staking/libraries/ColonyHelper.sol";
import {AccessHelper} from "../../staking/libraries/AccessHelper.sol";

/**
 * @title StrategicOverviewFacet
 * @notice Production-ready strategic overview system for Colony Wars
 * @dev Provides essential strategic intelligence without over-engineering
 */
contract StrategicOverviewFacet is AccessControlBase {

    // Compact enums for gas efficiency
    enum ThreatLevel { SAFE, LOW, MEDIUM, HIGH, CRITICAL }
    enum ActionType { ATTACK, SIEGE, RAID, DEFEND }
    
    // Core strategic data structures
    struct BattleReadiness {
        bool canAttack;
        bool canDefend;
        bool canSiege;
        bool canRaid;
        uint8 score; // 0-100
        uint32[4] cooldowns; // [attack, raid, siege, betrayal]
    }

    struct ThreatStatus {
        ThreatLevel level;
        bool underAttack;
        bool territoriesUnderSiege;
        uint8 vulnerableCount;
        uint32 nextThreatTime;
    }

    struct ColonyOverview {
        bytes32 colonyId;
        BattleReadiness readiness;
        ThreatStatus threats;
        uint8 overallScore; // 0-100
        bool registered;
        uint256 defensiveStake;
        uint8 territoriesCount;
        bool inAlliance;
        bytes32 allianceId; 
    }

    struct ValidationResult {
        bool canPerform;
        uint8 reasonCode; // 0=OK, 1=NOT_REGISTERED, 2=COOLDOWN, 3=NO_STAKE, etc.
        uint32 timeToReady;
        uint256 requiredStake;
    }

    // Events
    event OverviewRequested(bytes32 indexed colonyId, uint8 score, uint8 threatLevel);
    event ValidationPerformed(bytes32 indexed colonyId, uint8 actionType, bool result);
    event BetrayalRecorded(bytes32 indexed colonyId, bytes32 indexed allianceId);
    event ColonyLeftAlliance(bytes32 indexed allianceId, bytes32 indexed colonyId, string reason);
    event TerritoryLost(uint256 indexed territoryId, bytes32 indexed colonyId, string reason);
    event ColonyUnregisteredFromSeason(bytes32 indexed colonyId, uint32 seasonId, uint256 refund, uint256 penalty);
    event StakeChanged(bytes32 indexed colonyId, uint256 newStake, bool increased, uint256 changeAmount);

    // Custom errors
    error ColonyNotFound();
    error InvalidAction();
    error WarfareNotStarted();
    error RateLimitExceeded();
    error ColonyNotRegistered();
    error CannotUnregisterDuringBattle();
    error WarfareNotActive();
    error StakeIncreaseLimitExceeded();
    error InvalidStake();

    /**
     * @notice Reinforce defensive position during active warfare
     * @param colonyId Colony to reinforce
     * @param additionalAmount ZICO amount to add to defensive stake
     */
    function reinforceDefensivePosition(bytes32 colonyId, uint256 additionalAmount) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Only allow during warfare period
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
        if (!season.active || block.timestamp < season.registrationEnd || block.timestamp > season.warfareEnd) {
            revert WarfareNotActive();
        }
        
        // Rate limiting using configurable cooldown
        if (!LibColonyWarsStorage.checkRateLimit(LibMeta.msgSender(), this.reinforceDefensivePosition.selector, cws.config.stakeIncreaseCooldown)) {
            revert RateLimitExceeded();
        }
        
        // Verify caller controls the colony
        if (!ColonyHelper.isColonyCreator(colonyId, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony controller");
        }
        
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
        if (!profile.registered) {
            revert ColonyNotRegistered();
        }
        
        // Limit to 2 reinforcements per season
        if (profile.stakeIncreases >= 2) {
            revert StakeIncreaseLimitExceeded();
        }
        
        // Limit increase to 50% of current stake per operation
        uint256 maxIncrease = profile.defensiveStake / 2;
        if (additionalAmount == 0 || additionalAmount > maxIncrease) {
            revert InvalidStake();
        }
        
        // Validate new total doesn't exceed maximum
        uint256 newTotal = profile.defensiveStake + additionalAmount;
        if (newTotal > cws.config.maxStakeAmount) {
            revert InvalidStake();
        }
        
        // Apply 20% penalty for warfare reinforcements
        uint256 penalty = additionalAmount / 5;
        uint256 totalCost = additionalAmount + penalty;
        
        // Transfer payment including penalty
        address currency = hs.chargeTreasury.treasuryCurrency;
        LibFeeCollection.collectFee(
            IERC20(currency),
            LibMeta.msgSender(),
            hs.chargeTreasury.treasuryAddress,
            totalCost,
            "defensive_reinforcement"
        );
        
        // Update profile
        profile.defensiveStake = newTotal;
        profile.stakeIncreases++;
        
        // Penalty goes to season prize pool
        season.prizePool += penalty;
        
        emit StakeChanged(colonyId, newTotal, true, additionalAmount);
    }

    /**
     * @notice Emergency withdrawal from warfare with alliance/territory consequences
     * @param colonyId Colony to withdraw from season
     */
    function withdrawFromWarfare(bytes32 colonyId) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Basic validations (same as before)
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
        if (!season.active || block.timestamp < season.registrationEnd || block.timestamp > season.warfareEnd) {
            revert WarfareNotStarted();
        }
        
        if (!LibColonyWarsStorage.checkRateLimit(LibMeta.msgSender(), this.withdrawFromWarfare.selector, season.resolutionEnd - season.startTime)) {
            revert RateLimitExceeded();
        }
        
        if (!ColonyHelper.isAuthorizedForColony(colonyId, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony controller");
        }
        
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
        if (!profile.registered) {
            revert ColonyNotRegistered();
        }
        
        if (_hasActiveBattles(colonyId, cws, cws.currentSeason)) {
            revert CannotUnregisterDuringBattle();
        }

        // Handle alliance betrayal if primary colony
        bytes32 userPrimary = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());
        if (userPrimary == colonyId && LibColonyWarsStorage.isUserInAlliance(LibMeta.msgSender())) {
            bytes32 allianceId = LibColonyWarsStorage.getUserAllianceId(LibMeta.msgSender());
            
            // Mark betrayal and remove from alliance
            LibColonyWarsStorage.markAllianceBetrayal(allianceId, colonyId);
            LibColonyWarsStorage.removeAllianceMember(allianceId, LibMeta.msgSender());
            
            emit BetrayalRecorded(colonyId, allianceId);
            emit ColonyLeftAlliance(allianceId, colonyId, "Emergency withdrawal");
        }

        // Forfeit all territories
        uint256[] storage territories = cws.colonyTerritories[colonyId];
        for (uint256 i = 0; i < territories.length; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[territories[i]];
            if (territory.active && territory.controllingColony == colonyId) {
                territory.controllingColony = bytes32(0);
                territory.lastMaintenancePayment = 0;
                emit TerritoryLost(territories[i], colonyId, "Emergency withdrawal");
            }
        }
        delete cws.colonyTerritories[colonyId];
        
        // Calculate penalty - 50% base + 5% per territory (max 75%)
        uint256 originalStake = profile.defensiveStake;
        uint256 territoryCount = territories.length;
        uint256 penalty = originalStake / 2; // 50% base
        
        if (territoryCount > 0) {
            uint256 territoryPenalty = (originalStake * territoryCount * 5) / 100;
            if (territoryPenalty > originalStake / 4) territoryPenalty = originalStake / 4; // Max 25%
            penalty += territoryPenalty;
        }
        
        if (penalty > originalStake) penalty = originalStake;
        uint256 refund = originalStake - penalty;
        
        // Clean up colony registration
        _removeColonyFromSeason(colonyId, cws.currentSeason, cws);
        
        profile.defensiveStake = 0;
        profile.registered = false;
        profile.reputation = 5; // Deserter
        
        // Clean up user mapping
        if (userPrimary == colonyId) {
            LibColonyWarsStorage.setUserPrimaryColony(LibMeta.msgSender(), bytes32(0));
            cws.userToColony[LibMeta.msgSender()] = bytes32(0);
        }
        
        // Process payments
        if (refund > 0) {
            LibFeeCollection.transferFromTreasury(LibMeta.msgSender(), refund, "emergency_withdrawal");
        }
        season.prizePool += penalty;
        
        emit ColonyUnregisteredFromSeason(colonyId, cws.currentSeason, refund, penalty);
    }

    /**
     * @notice Get comprehensive colony overview
     * @param colonyId Colony to analyze
     * @return overview Complete strategic overview
     */
    function getColonyStrategicOverview(bytes32 colonyId) 
        public
        view 
        returns (ColonyOverview memory overview) 
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (hs.colonyCreators[colonyId] == address(0)) revert ColonyNotFound();
        
        overview.colonyId = colonyId;
        overview.readiness = _assessReadiness(colonyId, cws, hs);
        overview.threats = _assessThreats(colonyId, cws, hs);
        overview.overallScore = _calculateOverallScore(overview.readiness, overview.threats);
        
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
        overview.registered = profile.registered;
        overview.defensiveStake = profile.defensiveStake;
        overview.territoriesCount = uint8(cws.colonyTerritories[colonyId].length);
        
        address owner = hs.colonyCreators[colonyId];
        overview.inAlliance = LibColonyWarsStorage.isUserInAlliance(owner);
        overview.allianceId = LibColonyWarsStorage.getUserAllianceId(owner);
        
        return overview;
    }

    /**
     * @notice Validate if colony can perform specific action
     * @param colonyId Colony to check
     * @param action Action type to validate
     * @return result Validation result with details
     */
    function validateCombatAction(bytes32 colonyId, ActionType action)
        external
        view
        returns (ValidationResult memory result)
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (hs.colonyCreators[colonyId] == address(0)) revert ColonyNotFound();
        
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
        
        // Check registration first
        if (!profile.registered) {
            return ValidationResult(false, 1, 0, 0); // NOT_REGISTERED
        }
        
        // Check defensive stake for offensive actions
        if (action != ActionType.DEFEND && profile.defensiveStake < cws.config.minStakeAmount) {
            return ValidationResult(
                false, 
                3, // NO_STAKE
                0, 
                cws.config.minStakeAmount - profile.defensiveStake
            );
        }
        
        // Check cooldowns for attack/siege
        if (action == ActionType.ATTACK || action == ActionType.SIEGE) {
            uint32 cooldownEnd = profile.lastAttackTime + cws.config.attackCooldown;
            if (block.timestamp < cooldownEnd) {
                return ValidationResult(false, 2, cooldownEnd - uint32(block.timestamp), 0); // COOLDOWN
            }
        }
        
        return ValidationResult(true, 0, 0, 0);
    }

    /**
     * @notice Get current cooldowns for all activities
     * @param colonyId Colony to check
     * @return cooldowns [attack, raid, siege, betrayal] in seconds remaining
     */
    function getCombatCooldowns(bytes32 colonyId)
        public
        view
        returns (uint32[4] memory cooldowns)
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (hs.colonyCreators[colonyId] == address(0)) revert ColonyNotFound();
        
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
        uint32 _now = uint32(block.timestamp);
        
        // Attack cooldown
        uint32 attackEnd = profile.lastAttackTime + cws.config.attackCooldown;
        cooldowns[0] = attackEnd > _now ? attackEnd - _now : 0;

        // Raid cooldown (same as attack for simplicity)
        cooldowns[1] = cooldowns[0];
        
        // Siege cooldown (same as attack)
        cooldowns[2] = cooldowns[0];
        
        // Betrayal cooldown
        uint32 betrayalEnd = cws.lastBetrayalTime[colonyId] + cws.config.betrayalCooldown;
        cooldowns[3] = betrayalEnd > _now ? betrayalEnd - _now : 0;

        return cooldowns;
    }

    /**
     * @notice Check if colony/territories are under active attack
     * @param colonyId Colony to check
     * @return underAttack Colony is being attacked
     * @return siegeCount Number of territories under siege
     * @return threatLevel Overall threat assessment
     */
    function checkActiveThreats(bytes32 colonyId)
        public
        view
        returns (bool underAttack, uint8 siegeCount, ThreatLevel threatLevel)
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (hs.colonyCreators[colonyId] == address(0)) revert ColonyNotFound();
        
        // Check active battles
        bytes32[] storage battles = cws.colonyBattleHistory[colonyId];
        for (uint256 i = 0; i < battles.length; i++) {
            LibColonyWarsStorage.BattleInstance storage battle = cws.battles[battles[i]];
            if (battle.defenderColony == colonyId && !cws.battleResolved[battles[i]]) {
                underAttack = true;
                break;
            }
        }
        
        // Check territory sieges
        uint256[] storage territories = cws.colonyTerritories[colonyId];
        for (uint256 i = 0; i < territories.length && i < 20; i++) { // Gas limit
            bytes32[] storage territorySieges = cws.territoryActiveSieges[territories[i]];
            siegeCount += uint8(territorySieges.length);
        }
        
        // Determine threat level
        if (underAttack) {
            threatLevel = ThreatLevel.CRITICAL;
        } else if (siegeCount > 2) {
            threatLevel = ThreatLevel.HIGH;
        } else if (siegeCount > 0) {
            threatLevel = ThreatLevel.MEDIUM;
        } else {
            threatLevel = ThreatLevel.SAFE;
        }
        
        return (underAttack, siegeCount, threatLevel);
    }

    /**
     * @notice Get territory maintenance status
     * @param colonyId Colony to check
     * @return overdue Number of territories with overdue payments
     * @return atRisk Number of territories at risk (1-2 days overdue)
     * @return totalCost Total maintenance cost to bring all current
     */
    function getTerritoryMaintenanceStatus(bytes32 colonyId)
        public
        view
        returns (uint8 overdue, uint8 atRisk, uint256 totalCost)
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (hs.colonyCreators[colonyId] == address(0)) revert ColonyNotFound();
        
        uint256[] storage territories = cws.colonyTerritories[colonyId];
        uint32 _now = uint32(block.timestamp);
        
        for (uint256 i = 0; i < territories.length && i < 50; i++) { // Gas limit
            LibColonyWarsStorage.Territory storage territory = cws.territories[territories[i]];
            
            if (!territory.active || territory.controllingColony != colonyId) continue;
            
            uint32 daysSince = (_now - territory.lastMaintenancePayment) / 86400;
            
            if (daysSince >= 3) {
                overdue++;
                totalCost += cws.config.dailyMaintenanceCost * daysSince;
            } else if (daysSince >= 1) {
                atRisk++;
                totalCost += cws.config.dailyMaintenanceCost * daysSince;
            }
        }
        
        return (overdue, atRisk, totalCost);
    }

    /**
     * @notice Get available territories for capture
     * @param limit Maximum results to return
     * @return territoryIds Available territory IDs
     * @return values Territory bonus values
     */
    function getTerritoriesForCapture(uint8 limit)
        public
        view
        returns (uint256[] memory territoryIds, uint16[] memory values)
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        uint256[] memory tempIds = new uint256[](limit);
        uint16[] memory tempValues = new uint16[](limit);
        uint8 count = 0;
        
        for (uint256 i = 1; i <= cws.territoryCounter && count < limit; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[i];
            
            if (!territory.active) continue;
            
            bool available = territory.controllingColony == bytes32(0) ||
                (uint32(block.timestamp) - territory.lastMaintenancePayment) / 86400 > 2;
            
            if (available) {
                tempIds[count] = i;
                tempValues[count] = territory.bonusValue;
                count++;
            }
        }
        
        // Resize arrays
        territoryIds = new uint256[](count);
        values = new uint16[](count);
        for (uint256 i = 0; i < count; i++) {
            territoryIds[i] = tempIds[i];
            values[i] = tempValues[i];
        }
        
        return (territoryIds, values);
    }

    /**
     * @notice Get weak targets for potential attacks
     * @param colonyId Requesting colony
     * @param limit Maximum results
     * @return targets Array of weak colony IDs
     * @return stakes Their defensive stakes
     */
    function getSupposedWeakTargets(bytes32 colonyId, uint8 limit)
        public
        view
        returns (bytes32[] memory targets, uint256[] memory stakes)
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (hs.colonyCreators[colonyId] == address(0)) revert ColonyNotFound();
        
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
        
        bytes32[] memory tempTargets = new bytes32[](limit);
        uint256[] memory tempStakes = new uint256[](limit);
        uint8 count = 0;
        
        address colonyOwner = hs.colonyCreators[colonyId];
        bytes32 myAlliance = LibColonyWarsStorage.getUserAllianceId(colonyOwner);
        
        for (uint256 i = 0; i < season.registeredColonies.length && count < limit; i++) {
            bytes32 target = season.registeredColonies[i];
            if (target == colonyId) continue;
            
            LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[target];
            
            // Target criteria: low stake, has territories
            if (profile.defensiveStake < cws.config.minStakeAmount * 2 &&
                cws.colonyTerritories[target].length > 0) {
                
                // Check not in same alliance
                address targetOwner = hs.colonyCreators[target];
                bytes32 targetAlliance = LibColonyWarsStorage.getUserAllianceId(targetOwner);
                
                if (targetAlliance != myAlliance) {
                    tempTargets[count] = target;
                    tempStakes[count] = profile.defensiveStake;
                    count++;
                }
            }
        }
        
        // Resize arrays
        targets = new bytes32[](count);
        stakes = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            targets[i] = tempTargets[i];
            stakes[i] = tempStakes[i];
        }
        
        return (targets, stakes);
    }

    /**
     * @notice Get alliance status and recommendations
     * @param colonyId Colony to check
     * @return inAlliance Whether colony is in alliance
     * @return allianceId Current alliance ID
     * @return stability Alliance stability (0-100)
     * @return shouldJoin Recommendation to join alliance
     */
    function getColonyStatusInAlliance(bytes32 colonyId)
        external
        view
        returns (bool inAlliance, bytes32 allianceId, uint32 stability, bool shouldJoin)
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (hs.colonyCreators[colonyId] == address(0)) revert ColonyNotFound();
        
        address owner = hs.colonyCreators[colonyId];
        allianceId = LibColonyWarsStorage.getUserAllianceId(owner);
        inAlliance = allianceId != bytes32(0);
        
        if (inAlliance) {
            LibColonyWarsStorage.Alliance storage alliance = cws.alliances[allianceId];
            stability = alliance.stabilityIndex;
        }
        
        // Recommend joining if not in alliance and financially stable
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
        shouldJoin = !inAlliance && 
                    profile.defensiveStake >= cws.config.minStakeAmount * 2 &&
                    cws.colonyTerritories[colonyId].length > 0;
        
        return (inAlliance, allianceId, stability, shouldJoin);
    }

    /**
     * @notice Get season ranking and prize estimate
     * @param colonyId Colony to check
     * @return rank Current rank (1 = first, 0 = unranked)
     * @return score Season score
     * @return estimatedPrize Prize if season ended now
     */
    function getColonySeasonStatus(bytes32 colonyId)
        external
        view
        returns (uint256 rank, uint256 score, uint256 estimatedPrize)
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (hs.colonyCreators[colonyId] == address(0)) revert ColonyNotFound();
        
        uint32 seasonId = cws.currentSeason;
        score = LibColonyWarsStorage.getColonyScore(seasonId, colonyId);
        
        if (score == 0) return (0, 0, 0);
        
        // Calculate rank
        LibColonyWarsStorage.Season storage season = cws.seasons[seasonId];
        uint256 betterCount = 0;
        
        for (uint256 i = 0; i < season.registeredColonies.length && i < 100; i++) { // Gas limit
            bytes32 other = season.registeredColonies[i];
            if (other != colonyId) {
                uint256 otherScore = LibColonyWarsStorage.getColonyScore(seasonId, other);
                if (otherScore > score) betterCount++;
            }
        }
        
        rank = betterCount + 1;
        
        // Prize estimate (winner takes all simplified)
        if (rank == 1) {
            estimatedPrize = season.prizePool;
        }
        
        return (rank, score, estimatedPrize);
    }

    /**
     * @notice Get system-wide overview
     * @return activeBattles Number of active colony battles
     * @return activeSieges Number of active territory sieges
     * @return availableTerritories Number of territories available for capture
     * @return seasonTimeLeft Seconds until season ends
     */
    function getWarsSeasonOverview()
        external
        view
        returns (uint16 activeBattles, uint16 activeSieges, uint16 availableTerritories, uint32 seasonTimeLeft)
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        // Count active battles
        bytes32[] storage battles = cws.seasonBattles[cws.currentSeason];
        for (uint256 i = 0; i < battles.length && i < 200; i++) { // Gas limit
            if (!cws.battleResolved[battles[i]]) {
                activeBattles++;
            }
        }
        
        // Count active sieges
        activeSieges = uint16(cws.activeSieges.length);
        
        // Count available territories
        for (uint256 i = 1; i <= cws.territoryCounter && i <= 200; i++) { // Gas limit
            LibColonyWarsStorage.Territory storage territory = cws.territories[i];
            if (territory.active && (territory.controllingColony == bytes32(0) ||
                (uint32(block.timestamp) - territory.lastMaintenancePayment) / 86400 > 2)) {
                availableTerritories++;
            }
        }
        
        // Season time left
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
        if (block.timestamp < season.resolutionEnd) {
            seasonTimeLeft = season.resolutionEnd - uint32(block.timestamp);
        }
        
        return (activeBattles, activeSieges, availableTerritories, seasonTimeLeft);
    }

    /**
     * @notice Get strategic alerts and warnings for colony
     * @param colonyId Colony to check
     * @return alerts Array of strategic alerts
     * @dev Proactive warning system - short, actionable messages
     */
    function getColonyStrategicAlerts(bytes32 colonyId)
        external
        view
        returns (string[] memory alerts)
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (hs.colonyCreators[colonyId] == address(0)) revert ColonyNotFound();
        
        string[] memory tempAlerts = new string[](8);
        uint256 alertCount = 0;
        
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
        
        // Critical issues only
        if (profile.registered && profile.defensiveStake < cws.config.minStakeAmount) {
            tempAlerts[alertCount] = "Stake too low";
            alertCount++;
        }

        (bool underAttack, uint8 siegeCount,) = checkActiveThreats(colonyId);
        if (underAttack) {
            tempAlerts[alertCount] = "Under attack";
            alertCount++;
        }
        if (siegeCount > 0) {
            tempAlerts[alertCount] = "Territories besieged";
            alertCount++;
        }
        
        // Time warnings
        if (season.active && block.timestamp > season.warfareEnd - 86400) {
            tempAlerts[alertCount] = "Season ending soon";
            alertCount++;
        }
        
        // Territory issues
        (uint8 overdue, ,) = getTerritoryMaintenanceStatus(colonyId);
        if (overdue > 0) {
            tempAlerts[alertCount] = "Territories overdue";
            alertCount++;
        }
        
        // Alliance risk
        address owner = hs.colonyCreators[colonyId];
        if (LibColonyWarsStorage.isUserInAlliance(owner)) {
            bytes32 allianceId = LibColonyWarsStorage.getUserAllianceId(owner);
            LibColonyWarsStorage.Alliance storage alliance = cws.alliances[allianceId];
            if (alliance.stabilityIndex < 40) {
                tempAlerts[alertCount] = "Alliance unstable";
                alertCount++;
            }
        }
        
        // Debt warning
        if (cws.colonyDebts[colonyId].principalDebt > profile.defensiveStake) {
            tempAlerts[alertCount] = "Debt exceeds stake";
            alertCount++;
        }
        
        // Resize array
        alerts = new string[](alertCount);
        for (uint256 i = 0; i < alertCount; i++) {
            alerts[i] = tempAlerts[i];
        }
        
        return alerts;
    }

    /**
     * @notice Get top 3 recommended actions
     * @param colonyId Colony to analyze
     * @return actions Array of 3 most important actions
     * @dev Simple, prioritized action list
     */
    function getAdvisedCombatActions(bytes32 colonyId)
        external
        view
        returns (string[] memory actions)
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (hs.colonyCreators[colonyId] == address(0)) revert ColonyNotFound();
        
        string[] memory topActions = new string[](3);
        uint256 actionCount = 0;
        
        ColonyOverview memory overview = getColonyStrategicOverview(colonyId);
        
        // Priority 1: Defend if under threat
        if (overview.threats.level >= ThreatLevel.HIGH) {
            topActions[actionCount] = "Defend now";
            actionCount++;
        }
        
        // Priority 2: Pay maintenance
        if (overview.threats.vulnerableCount > 0) {
            topActions[actionCount] = "Pay maintenance";
            actionCount++;
        }
        
        // Priority 3: Best opportunity
        if (actionCount < 3) {
            if (overview.readiness.canAttack && overview.threats.level <= ThreatLevel.LOW) {
                (bytes32[] memory targets,) = getSupposedWeakTargets(colonyId, 1);
                if (targets.length > 0) {
                    topActions[actionCount] = "Attack weak enemy";
                    actionCount++;
                }
            }
        }
        
        if (actionCount < 3) {
            (uint256[] memory available,) = getTerritoriesForCapture(1);
            if (available.length > 0 && overview.territoriesCount < 6) {
                topActions[actionCount] = "Capture territory";
                actionCount++;
            }
        }
        
        if (actionCount < 3 && !overview.inAlliance && overview.defensiveStake >= cws.config.minStakeAmount * 2) {
            topActions[actionCount] = "Join alliance";
            actionCount++;
        }
        
        // Return only filled actions
        actions = new string[](actionCount);
        for (uint256 i = 0; i < actionCount; i++) {
            actions[i] = topActions[i];
        }
        
        return actions;
    }

    /**
     * @notice Compare battle power with target
     * @param colonyId Your colony
     * @param targetColonyId Target colony
     * @return yourPower Your attack power
     * @return theirPower Their defense power  
     * @return winProbability Win chance (0-100%)
     * @return recommendation Short recommendation
     * @dev Simple power comparison and recommendation
     */
    function compareBattlePower(bytes32 colonyId, bytes32 targetColonyId)
        external
        view
        returns (uint256 yourPower, uint256 theirPower, uint8 winProbability, string memory recommendation)
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (hs.colonyCreators[colonyId] == address(0) || hs.colonyCreators[targetColonyId] == address(0)) {
            revert ColonyNotFound();
        }
        
        if (colonyId == targetColonyId) {
            return (0, 0, 0, "Cannot attack self");
        }
        
        LibColonyWarsStorage.ColonyWarProfile storage yourProfile = cws.colonyWarProfiles[colonyId];
        LibColonyWarsStorage.ColonyWarProfile storage targetProfile = cws.colonyWarProfiles[targetColonyId];
        
        if (!yourProfile.registered || !targetProfile.registered) {
            return (0, 0, 0, "Not registered");
        }
        
        // NAPRAWIONA kalkulacja - uwzględnia tokeny jako główny czynnik
        uint256[] storage yourTokens = hs.colonies[colonyId];
        uint256[] storage theirTokens = hs.colonies[targetColonyId];
        
        // Estymuj token power (główny czynnik)
        yourPower = yourTokens.length * 150; // Avg 150 power per token
        theirPower = theirTokens.length * 150;
        
        // Zastosuj bonusy atakującego
        yourPower += (yourPower * 20) / 100; // Base attack bonus
        
        // Estymuj stake bonus (używaj rzeczywistego defensive stake)
        uint256 estimatedStake = yourProfile.defensiveStake; 
        if (estimatedStake >= targetProfile.defensiveStake / 2) {
            uint256 stakeBonus = _estimateStakeBonus(estimatedStake, targetProfile.defensiveStake);
            yourPower += (yourPower * stakeBonus) / 100;
        }
        
        // Zastosuj bonusy obrońcy
        theirPower += (theirPower * 6) / 100; // Home advantage
        
        // Dodaj limited stake power dla obrońcy
        uint256 defenderStakePower = targetProfile.defensiveStake / 25;
        uint256 maxDefenderStakePower = theirPower > 0 ? theirPower / 2 : 50;
        if (defenderStakePower > maxDefenderStakePower) {
            defenderStakePower = maxDefenderStakePower;
        }
        theirPower += defenderStakePower;
        
        // Alliance bonus (jeśli potwierdzone)
        address targetOwner = hs.colonyCreators[targetColonyId];
        if (LibColonyWarsStorage.isUserInAlliance(targetOwner)) {
            theirPower += (theirPower * 8) / 100; // Realistic alliance bonus
        }
        
        // Kalkuluj win probability
        if (yourPower == 0) {
            winProbability = 0;
            recommendation = "No attack power";
        } else if (theirPower == 0) {
            winProbability = 85;
            recommendation = "Undefended";
        } else {
            uint256 ratio = (yourPower * 100) / theirPower;
            
            if (ratio >= 130) {
                winProbability = 75;
                recommendation = "Strong attack";
            } else if (ratio >= 110) {
                winProbability = 60;
                recommendation = "Good odds";
            } else if (ratio >= 95) {
                winProbability = 50;
                recommendation = "Even fight";
            } else if (ratio >= 80) {
                winProbability = 35;
                recommendation = "Risky";
            } else {
                winProbability = 20;
                recommendation = "Poor odds";
            }
        }
        
        return (yourPower, theirPower, winProbability, recommendation);
    }

    /**
     * @notice Get resource optimization advice
     * @param colonyId Colony to analyze
     * @return stakeAdvice Stake recommendation
     * @return territoryAdvice Territory recommendation
     * @return allianceAdvice Alliance recommendation
     * @dev Simple optimization recommendations
     */
    function getQuickResourceAdvice(bytes32 colonyId)
        external
        view
        returns (
            string memory stakeAdvice,
            string memory territoryAdvice, 
            string memory allianceAdvice
        )
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (hs.colonyCreators[colonyId] == address(0)) revert ColonyNotFound();

        ColonyOverview memory overview = getColonyStrategicOverview(colonyId);

        // Stake advice
        if (overview.defensiveStake < cws.config.minStakeAmount * 2) {
            stakeAdvice = "Increase stake";
        } else if (overview.defensiveStake > cws.config.minStakeAmount * 8) {
            stakeAdvice = "Reduce stake";
        } else {
            stakeAdvice = "Optimal";
        }
        
        // Territory advice
        if (overview.territoriesCount == 0) {
            territoryAdvice = "Get territories";
        } else if (overview.territoriesCount < 3) {
            territoryAdvice = "Expand more";
        } else if (overview.territoriesCount >= 6) {
            territoryAdvice = "At limit";
        } else {
            territoryAdvice = "Good amount";
        }
        
        // Alliance advice
        if (!overview.inAlliance) {
            if (overview.defensiveStake >= cws.config.minStakeAmount * 2) {
                allianceAdvice = "Join alliance";
            } else {
                allianceAdvice = "Build first";
            }
        } else {
            // Get alliance ID for current colony
            address owner = hs.colonyCreators[colonyId];
            bytes32 allianceId = LibColonyWarsStorage.getUserAllianceId(owner);
            LibColonyWarsStorage.Alliance storage alliance = cws.alliances[allianceId];
            
            if (alliance.stabilityIndex < 50) {
                allianceAdvice = "Alliance risky";
            } else {
                allianceAdvice = "Alliance good";
            }
        }
        
        return (stakeAdvice, territoryAdvice, allianceAdvice);
    }

    /**
     * @notice Get current weather conditions with predictable short-term forecast
     * @dev Weather seed changes daily, but forecast is possible within that day
     * @return weatherType 0=Clear, 1=Storm, 2=Fog, 3=Wind, 4=Rain
     * @return weatherName Human-readable weather name
     * @return attackerMod Attacker power modifier
     * @return defenderMod Defender power modifier
     */
    function getBattlefieldWeather() 
        public 
        view 
        returns (
            uint8 weatherType,
            string memory weatherName,
            uint8 attackerMod,
            uint8 defenderMod
        ) 
    {
        // Daily seed - zmienia się raz dziennie o północy UTC
        uint256 dailySeed = uint256(keccak256(abi.encodePacked(
            block.timestamp / 86400,  // Dzień (zmienia się co 24h)
            block.prevrandao          // Losowość z tego dnia
        )));
        
        // Current 2-hour period within the day (0-11)
        uint256 periodOfDay = (block.timestamp % 86400) / 7200;
        
        // Combine daily seed with period for weather determination
        uint256 weatherSeed = uint256(keccak256(abi.encodePacked(dailySeed, periodOfDay)));
        uint256 weatherCycle = weatherSeed % 5;
        
        if (weatherCycle == 0) {
            return (0, "Clear Skies", 105, 100);
        } else if (weatherCycle == 1) {
            return (1, "Thunderstorm", 85, 90);
        } else if (weatherCycle == 2) {
            return (2, "Dense Fog", 90, 115);
        } else if (weatherCycle == 3) {
            // Strong Wind - direction depends on weather seed
            uint256 windDirection = uint256(keccak256(abi.encodePacked(weatherSeed, "wind"))) % 2;
            if (windDirection == 0) {
                return (3, "Strong Wind (Tailwind)", 110, 95);
            } else {
                return (3, "Strong Wind (Headwind)", 95, 110);
            }
        } else {
            return (4, "Light Rain", 95, 105);
        }
    }

    /**
     * @notice Get weather forecast - predictable within current day
     * @return current Current weather conditions
     * @return next Weather in next 2-hour period
     * @return timeUntilChange Seconds until weather changes
     * @return forecastReliable True if forecast is for same day, false if crosses midnight
     */
    function getWeatherForecast() 
        external 
        view 
        returns (
            string memory current,
            string memory next,
            uint256 timeUntilChange,
            bool forecastReliable
        ) 
    {
        uint256 currentPeriod = block.timestamp / 7200;
        uint256 nextPeriodTimestamp = (currentPeriod + 1) * 7200;
        
        // Get current weather
        (, current,,) = getBattlefieldWeather();
        
        // Check if next period crosses midnight (new day = new seed)
        uint256 currentDay = block.timestamp / 86400;
        uint256 nextDay = nextPeriodTimestamp / 86400;
        
        if (currentDay == nextDay) {
            // Same day - we can predict accurately
            forecastReliable = true;
            
            // Calculate next weather using same daily seed
            uint256 dailySeed = uint256(keccak256(abi.encodePacked(
                currentDay,
                block.prevrandao
            )));
            
            uint256 nextPeriodOfDay = (nextPeriodTimestamp % 86400) / 7200;
            uint256 nextWeatherSeed = uint256(keccak256(abi.encodePacked(dailySeed, nextPeriodOfDay)));
            uint256 nextWeatherCycle = nextWeatherSeed % 5;
            
            if (nextWeatherCycle == 0) {
                next = "Clear Skies";
            } else if (nextWeatherCycle == 1) {
                next = "Thunderstorm";
            } else if (nextWeatherCycle == 2) {
                next = "Dense Fog";
            } else if (nextWeatherCycle == 3) {
                uint256 windDirection = uint256(keccak256(abi.encodePacked(nextWeatherSeed, "wind"))) % 2;
                next = windDirection == 0 ? "Strong Wind (Tailwind)" : "Strong Wind (Headwind)";
            } else {
                next = "Light Rain";
            }
        } else {
            // Crosses midnight - cannot predict (new prevrandao unknown)
            forecastReliable = false;
            next = "Unknown (crosses midnight)";
        }
        
        timeUntilChange = nextPeriodTimestamp - block.timestamp;
        
        return (current, next, timeUntilChange, forecastReliable);
    }

    /**
     * @notice Get full day weather forecast (all 12 periods)
     * @return periods Array of 12 weather descriptions for each 2h period today
     * @return currentPeriod Which period we're currently in (0-11)
     */
    function getDailyWeatherForecast()
        external
        view
        returns (string[12] memory periods, uint8 currentPeriod)
    {
        uint256 dailySeed = uint256(keccak256(abi.encodePacked(
            block.timestamp / 86400,
            block.prevrandao
        )));
        
        currentPeriod = uint8((block.timestamp % 86400) / 7200);
        
        for (uint256 i = 0; i < 12; i++) {
            uint256 weatherSeed = uint256(keccak256(abi.encodePacked(dailySeed, i)));
            uint256 weatherCycle = weatherSeed % 5;
            
            if (weatherCycle == 0) {
                periods[i] = "Clear";
            } else if (weatherCycle == 1) {
                periods[i] = "Storm";
            } else if (weatherCycle == 2) {
                periods[i] = "Fog";
            } else if (weatherCycle == 3) {
                uint256 windDir = uint256(keccak256(abi.encodePacked(weatherSeed, "wind"))) % 2;
                periods[i] = windDir == 0 ? "Wind(T)" : "Wind(H)"; // T=Tailwind, H=Headwind
            } else {
                periods[i] = "Rain";
            }
        }
        
        return (periods, currentPeriod);
    }

    /**
     * @notice Check if current weather favors attackers or defenders
     * @return favorType 0=attackers, 1=defenders, 2=neutral
     * @return advantage Percentage advantage (5 = 5% advantage)
     */
    function checkWeatherAdvantage() 
        external 
        view 
        returns (uint8 favorType, uint8 advantage) 
    {
        (, , uint8 attackerMod, uint8 defenderMod) = getBattlefieldWeather();
        
        if (attackerMod > defenderMod) {
            favorType = 0; // Attackers
            // Oblicz przewagę jako różnicę, nie tylko bonus
            advantage = attackerMod > defenderMod ? uint8(attackerMod - defenderMod) : 0;
        } else if (defenderMod > attackerMod) {
            favorType = 1; // Defenders
            advantage = defenderMod > attackerMod ? uint8(defenderMod - attackerMod) : 0;
        } else {
            favorType = 2; // Neutral
            advantage = 0;
        }
        
        return (favorType, advantage);
    }

    // Internal helper functions

    function _assessReadiness(
        bytes32 colonyId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        LibHenomorphsStorage.HenomorphsStorage storage
    ) internal view returns (BattleReadiness memory readiness) {
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];

        // canDefend requires stake for defensive bonus, but registered colonies can always defend
        readiness.canDefend = profile.registered && profile.defensiveStake > 0;
        // canAttack only requires registration - stake requirement is per-battle (must be >= 50% of defender's stake)
        readiness.canAttack = profile.registered;
        readiness.canSiege = readiness.canAttack;
        readiness.canRaid = readiness.canAttack;
        
        // Get cooldowns
        readiness.cooldowns = getCombatCooldowns(colonyId);
        
        // Adjust capabilities based on cooldowns
        if (readiness.cooldowns[0] > 0) {
            readiness.canAttack = false;
            readiness.canSiege = false;
        }
        
        // Calculate score
        uint8 score = 0;
        if (readiness.canAttack) score += 30;
        if (readiness.canDefend) score += 30;
        if (readiness.canSiege) score += 20;
        if (readiness.canRaid) score += 20;
        readiness.score = score;
        
        return readiness;
    }

    function _assessThreats(
        bytes32 colonyId,
        LibColonyWarsStorage.ColonyWarsStorage storage,
        LibHenomorphsStorage.HenomorphsStorage storage
    ) internal view returns (ThreatStatus memory threats) {
        (bool underAttack, uint8 siegeCount, ThreatLevel level) = checkActiveThreats(colonyId);

        threats.underAttack = underAttack;
        threats.level = level;
        threats.territoriesUnderSiege = siegeCount > 0;
        
        // Count vulnerable territories
        (uint8 overdue, uint8 atRisk,) = getTerritoryMaintenanceStatus(colonyId);
        threats.vulnerableCount = overdue + atRisk;
        
        // Estimate next threat time
        if (level == ThreatLevel.CRITICAL) {
            threats.nextThreatTime = 0; // Immediate
        } else if (level == ThreatLevel.HIGH) {
            threats.nextThreatTime = 3600; // 1 hour
        } else {
            threats.nextThreatTime = 86400; // 24 hours
        }
        
        return threats;
    }

    function _calculateOverallScore(
        BattleReadiness memory readiness,
        ThreatStatus memory threats
    ) internal pure returns (uint8) {
        uint256 score = uint256(readiness.score);
        
        // Reduce score based on threat level
        if (threats.level == ThreatLevel.CRITICAL) {
            score = score / 2;
        } else if (threats.level == ThreatLevel.HIGH) {
            score = (score * 70) / 100;
        } else if (threats.level == ThreatLevel.MEDIUM) {
            score = (score * 85) / 100;
        }
        
        // Additional penalties
        if (threats.vulnerableCount > 3) {
            score = (score * 80) / 100;
        }
        
        return uint8(score > 100 ? 100 : score);
    }

    /**
     * @notice Remove colony from season registered colonies array
     */
    function _removeColonyFromSeason(
        bytes32 colonyId, 
        uint32 seasonId, 
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        LibColonyWarsStorage.Season storage season = cws.seasons[seasonId];
        
        // Find and remove colony from season.registeredColonies
        for (uint256 i = 0; i < season.registeredColonies.length; i++) {
            if (season.registeredColonies[i] == colonyId) {
                season.registeredColonies[i] = season.registeredColonies[season.registeredColonies.length - 1];
                season.registeredColonies.pop();
                break;
            }
        }
        
        // Reset colony score
        LibColonyWarsStorage.setColonyScore(seasonId, colonyId, 0);
    }

    function _hasActiveBattles(bytes32 colonyId, LibColonyWarsStorage.ColonyWarsStorage storage cws, uint32 seasonId) 
        internal 
        view 
        returns (bool) 
    {
        bytes32[] storage seasonBattles = cws.seasonBattles[seasonId];
        
        for (uint256 i = 0; i < seasonBattles.length; i++) {
            LibColonyWarsStorage.BattleInstance storage battle = cws.battles[seasonBattles[i]];
            
            // Check if colony is involved and battle is not resolved
            if ((battle.attackerColony == colonyId || battle.defenderColony == colonyId) && 
                battle.battleState < 2 && !cws.battleResolved[seasonBattles[i]]) {
                return true;
            }
        }
        
        return false;
    }

    function _estimateStakeBonus(uint256 stakeAmount, uint256 defenderStake) 
        internal pure returns (uint256) {
        uint256 ratio = (stakeAmount * 100) / defenderStake;
        
        if (ratio <= 100) return 20 + ((ratio - 50) * 20) / 50;
        if (ratio <= 200) return 40 + ((ratio - 100) * 25) / 100;
        if (ratio <= 300) return 65 + ((ratio - 200) * 20) / 100;
        
        uint256 bonus = 85 + ((ratio - 300) * 10) / 100;
        return bonus > 95 ? 95 : bonus;
    }

}