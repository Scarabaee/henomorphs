// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {ColonyHelper} from "../libraries/ColonyHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {LibAchievementTrigger} from "../libraries/LibAchievementTrigger.sol";

/**
 * @dev Interface for inter-facet calls to ColonyWarsFacet
 */
interface IColonyWarsFacet {
    function initiateAttack(
        bytes32 attackerColony,
        bytes32 defenderColony,
        uint256[] memory attackCollectionIds,
        uint256[] memory attackTokenIds,
        uint256 stakeAmount
    ) external returns (bytes32 battleId);
}

/**
 * @title AllianceEvolutionFacet
 * @notice Alliance evolution features: contested zones, missions, diplomacy
 * @dev Extends AllianceWarsFacet + TerritoryWarsFacet functionality
 * @custom:version 1.1.0 - Fixed storage references and consistency issues
 */
contract AllianceEvolutionFacet is AccessControlBase {

    // Events
    event ContestedZoneClaimed(bytes32 indexed zoneId, bytes32 indexed allianceId, uint32 season);
    event AllianceMissionCreated(bytes32 indexed missionId, bytes32 indexed allianceId, uint8 missionType);
    event MissionContribution(bytes32 indexed missionId, bytes32 indexed colony, uint256 amount);
    event MissionCompleted(bytes32 indexed missionId, bytes32 indexed allianceId, uint256 totalReward);
    event DiplomaticTreatyProposed(bytes32 indexed treatyId, bytes32 indexed proposerAlliance, bytes32 indexed targetAlliance);
    event TreatyAccepted(bytes32 indexed treatyId, uint8 treatyType);
    event TreatyBroken(bytes32 indexed treatyId, bytes32 indexed violatorAlliance);
    event CoordinatedAttackInitiated(
        bytes32 indexed allianceId,
        bytes32 indexed targetColony,
        bytes32[] battleIds,
        uint8 participatingColonies
    );

    // Custom errors
    error ZoneNotContested();
    error AllianceNotEligible();
    error MissionNotActive();
    error InsufficientContribution();
    error TreatyNotFound();
    error TreatyAlreadyExists();
    error NotAllianceLeader();
    error InvalidMissionType();
    error InvalidMissionDuration();
    error TerritoryNotControlled();
    error DailyCoordinatedAttackLimitReached(uint8 attacksToday, uint8 maxPerDay);
    error NoParticipatingColonies();
    error InsufficientStakeForCoordinatedAttack();
    error CoordinatedAttacksNotEnabled();

    /**
     * @notice Claim contested territory zone for alliance
     * @param zoneId Territory zone ID (13-15 per existing system)
     */
    function claimContestedZone(uint256 zoneId) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        address user = LibMeta.msgSender();
        bytes32 allianceId = LibColonyWarsStorage.getUserAllianceId(user);
        if (allianceId == bytes32(0)) revert AllianceNotEligible();
        
        // Validate zone is contested (13-15)
        if (zoneId < 13 || zoneId > 15) revert ZoneNotContested();
        
        LibColonyWarsStorage.Alliance storage alliance = cws.alliances[allianceId];
        bytes32 leaderColony = alliance.leaderColony;
        
        // Leader colony must control the zone
        bytes32 currentController = cws.currentTerritoryController[zoneId];
        if (currentController != leaderColony) revert TerritoryNotControlled();
        
        // Mark zone as alliance-controlled
        cws.allianceContestedZones[cws.currentSeason][allianceId].push(uint8(zoneId));

        // Grant bonus: +5% production for all alliance members
        cws.zoneControlBonuses[allianceId] += 5; // 5% bonus

        emit ContestedZoneClaimed(bytes32(zoneId), allianceId, cws.currentSeason);

        // Trigger territory conquest achievement
        LibAchievementTrigger.triggerTerritoryConquest(user);
    }

    /**
     * @notice Create alliance mission (leader only)
     * @param missionType 0=Resource, 1=Battle, 2=Territory
     * @param target Target amount/count
     * @param duration Mission duration in days
     */
    function createAllianceMission(
        uint8 missionType,
        uint256 target,
        uint32 duration
    ) external whenNotPaused nonReentrant returns (bytes32 missionId) {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        address user = LibMeta.msgSender();
        bytes32 allianceId = LibColonyWarsStorage.getUserAllianceId(user);
        if (allianceId == bytes32(0)) revert AllianceNotEligible();
        
        LibColonyWarsStorage.Alliance storage alliance = cws.alliances[allianceId];
        bytes32 userColony = LibColonyWarsStorage.getUserPrimaryColony(user);
        if (userColony != alliance.leaderColony) revert NotAllianceLeader();
        
        // Validate mission type and duration
        if (missionType > 2) revert InvalidMissionType();
        if (duration < 3 || duration > 30) revert InvalidMissionDuration();
        
        missionId = keccak256(abi.encodePacked(allianceId, block.timestamp, missionType));
        
        // ✅ FIXED: Use correct storage reference
        LibColonyWarsStorage.AllianceMission storage mission = cws.allianceMissions[missionId];
        
        mission.allianceId = allianceId;
        mission.missionType = missionType;
        mission.targetAmount = target;
        mission.currentProgress = 0;
        mission.deadline = uint32(block.timestamp + (duration * 1 days));
        mission.active = true;
        mission.completed = false;

        // Track mission in alliance's mission list
        cws.allianceMissionIds[allianceId].push(missionId);

        emit AllianceMissionCreated(missionId, allianceId, missionType);
        return missionId;
    }

    /**
     * @notice Contribute to alliance mission
     * @param missionId Mission to contribute to
     * @param amount Contribution amount
     */
    function contributeToMission(bytes32 missionId, uint256 amount) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        // ✅ FIXED: Use correct storage reference
        LibColonyWarsStorage.AllianceMission storage mission = cws.allianceMissions[missionId];
        if (!mission.active) revert MissionNotActive();
        if (block.timestamp > mission.deadline) revert MissionNotActive();
        
        address user = LibMeta.msgSender();
        bytes32 allianceId = LibColonyWarsStorage.getUserAllianceId(user);
        if (allianceId != mission.allianceId) revert AllianceNotEligible();
        
        bytes32 colony = LibColonyWarsStorage.getUserPrimaryColony(user);
        if (amount == 0) revert InsufficientContribution();
        
        // Record contribution
        mission.currentProgress += amount;
        mission.contributors.push(colony);
        
        emit MissionContribution(missionId, colony, amount);
        
        // Check if mission completed
        if (mission.currentProgress >= mission.targetAmount) {
            _completeMission(missionId, mission, cws);
        }
    }

    /**
     * @notice Propose diplomatic treaty between alliances
     * @param targetAlliance Alliance to propose treaty to
     * @param treatyType 0=NAP, 1=Trade, 2=Military
     * @param duration Treaty duration in days
     */
    function proposeTreaty(
        bytes32 targetAlliance,
        uint8 treatyType,
        uint32 duration
    ) external whenNotPaused nonReentrant returns (bytes32 treatyId) {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        address user = LibMeta.msgSender();
        bytes32 proposerAlliance = LibColonyWarsStorage.getUserAllianceId(user);
        if (proposerAlliance == bytes32(0)) revert AllianceNotEligible();
        
        LibColonyWarsStorage.Alliance storage alliance = cws.alliances[proposerAlliance];
        bytes32 userColony = LibColonyWarsStorage.getUserPrimaryColony(user);
        if (userColony != alliance.leaderColony) revert NotAllianceLeader();
        
        // Validate target exists
        if (!cws.alliances[targetAlliance].active) revert TreatyNotFound();
        
        // Check no existing treaty
        bytes32 existingKey = keccak256(abi.encodePacked(proposerAlliance, targetAlliance));
        if (cws.activeTreaties[existingKey].active) revert TreatyAlreadyExists();
        
        treatyId = keccak256(abi.encodePacked(proposerAlliance, targetAlliance, block.timestamp));
        
        // ✅ FIXED: Use correct storage reference
        LibColonyWarsStorage.DiplomaticTreaty storage treaty = cws.treaties[treatyId];
        treaty.alliance1 = proposerAlliance;
        treaty.alliance2 = targetAlliance;
        treaty.treatyType = treatyType;
        treaty.proposedAt = uint32(block.timestamp);
        treaty.duration = duration;
        treaty.active = false; // Pending acceptance
        treaty.broken = false;

        // Track treaty in both alliances' treaty lists
        cws.allianceTreatyIds[proposerAlliance].push(treatyId);
        cws.allianceTreatyIds[targetAlliance].push(treatyId);

        // Add to pending proposals for target alliance
        cws.pendingTreatyProposals[targetAlliance].push(treatyId);

        emit DiplomaticTreatyProposed(treatyId, proposerAlliance, targetAlliance);
        return treatyId;
    }

    /**
     * @notice Accept treaty proposal
     * @param treatyId Treaty to accept
     */
    function acceptTreaty(bytes32 treatyId) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        LibColonyWarsStorage.DiplomaticTreaty storage treaty = cws.treaties[treatyId];
        if (treaty.alliance1 == bytes32(0)) revert TreatyNotFound();
        if (treaty.active) revert TreatyAlreadyExists();
        
        address user = LibMeta.msgSender();
        bytes32 userAlliance = LibColonyWarsStorage.getUserAllianceId(user);
        if (userAlliance != treaty.alliance2) revert AllianceNotEligible();
        
        LibColonyWarsStorage.Alliance storage alliance = cws.alliances[userAlliance];
        bytes32 userColony = LibColonyWarsStorage.getUserPrimaryColony(user);
        if (userColony != alliance.leaderColony) revert NotAllianceLeader();
        
        // Activate treaty
        treaty.active = true;
        treaty.acceptedAt = uint32(block.timestamp);
        treaty.expiresAt = uint32(block.timestamp + (treaty.duration * 1 days));

        // Store active treaty link
        bytes32 key = keccak256(abi.encodePacked(treaty.alliance1, treaty.alliance2));
        cws.activeTreaties[key] = treaty;

        // Remove from pending proposals
        _removePendingProposal(cws, userAlliance, treatyId);

        // Apply treaty effects
        _applyTreatyEffects(treaty, cws);

        emit TreatyAccepted(treatyId, treaty.treatyType);

        // Trigger diplomacy achievement for both alliance leaders
        LibAchievementTrigger.triggerDiplomacy(user);
    }

    /**
     * @notice Break treaty (triggers penalties)
     * @param treatyId Treaty to break
     */
    function breakTreaty(bytes32 treatyId) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        LibColonyWarsStorage.DiplomaticTreaty storage treaty = cws.treaties[treatyId];
        if (!treaty.active) revert TreatyNotFound();
        
        address user = LibMeta.msgSender();
        bytes32 userAlliance = LibColonyWarsStorage.getUserAllianceId(user);
        if (userAlliance != treaty.alliance1 && userAlliance != treaty.alliance2) revert AllianceNotEligible();
        
        LibColonyWarsStorage.Alliance storage alliance = cws.alliances[userAlliance];
        bytes32 userColony = LibColonyWarsStorage.getUserPrimaryColony(user);
        if (userColony != alliance.leaderColony) revert NotAllianceLeader();
        
        // Mark as broken
        treaty.active = false;
        treaty.broken = true;
        
        // Remove active treaty link
        bytes32 key = keccak256(abi.encodePacked(treaty.alliance1, treaty.alliance2));
        delete cws.activeTreaties[key];
        
        // Apply penalties to breaker
        LibColonyWarsStorage.Alliance storage violator = cws.alliances[userAlliance];
        if (violator.stabilityIndex > 20) {
            violator.stabilityIndex -= 20;
        } else {
            violator.stabilityIndex = 0;
        }
        
        emit TreatyBroken(treatyId, userAlliance);
    }

    // ==================== VIEW FUNCTIONS ====================

    /**
     * @notice Get alliance contested zones
     */
    function getAllianceZones(bytes32 allianceId, uint32 season) 
        external 
        view 
        returns (uint8[] memory zones, uint256 bonus) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        zones = cws.allianceContestedZones[season][allianceId];
        bonus = cws.zoneControlBonuses[allianceId];
        return (zones, bonus);
    }

    /**
     * @notice Get alliance mission details
     */
    function getMissionDetails(bytes32 missionId) 
        external 
        view 
        returns (
            bytes32 allianceId,
            uint8 missionType,
            uint256 target,
            uint256 progress,
            uint32 deadline,
            bool active
        ) 
    {
        // ✅ FIXED: Use correct storage reference
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.AllianceMission storage mission = cws.allianceMissions[missionId];

        return (
            mission.allianceId,
            mission.missionType,
            mission.targetAmount,
            mission.currentProgress,
            mission.deadline,
            mission.active
        );
    }

    /**
     * @notice Get mission contributors
     */
    function getMissionContributors(bytes32 missionId) 
        external 
        view 
        returns (bytes32[] memory contributors) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        return cws.allianceMissions[missionId].contributors;
    }

    /**
     * @notice Get active treaty between alliances
     */
    function getActiveTreaty(bytes32 alliance1, bytes32 alliance2) 
        external 
        view 
        returns (
            bool exists,
            uint8 treatyType,
            uint32 expiresAt
        ) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        bytes32 key = keccak256(abi.encodePacked(alliance1, alliance2));
        LibColonyWarsStorage.DiplomaticTreaty storage treaty = cws.activeTreaties[key];

        return (treaty.active, treaty.treatyType, treaty.expiresAt);
    }

    /**
     * @notice Get treaty details by ID
     */
    function getTreatyDetails(bytes32 treatyId)
        external
        view
        returns (
            bytes32 alliance1,
            bytes32 alliance2,
            uint8 treatyType,
            uint32 proposedAt,
            uint32 acceptedAt,
            uint32 expiresAt,
            bool active,
            bool broken
        )
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.DiplomaticTreaty storage treaty = cws.treaties[treatyId];

        return (
            treaty.alliance1,
            treaty.alliance2,
            treaty.treatyType,
            treaty.proposedAt,
            treaty.acceptedAt,
            treaty.expiresAt,
            treaty.active,
            treaty.broken
        );
    }

    /**
     * @notice Check if alliances have NAP
     */
    function hasNonAggressionPact(bytes32 alliance1, bytes32 alliance2) 
        external 
        view 
        returns (bool) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        bytes32 key = keccak256(abi.encodePacked(alliance1, alliance2));
        LibColonyWarsStorage.DiplomaticTreaty storage treaty = cws.activeTreaties[key];

        return treaty.active && treaty.treatyType == 0 && block.timestamp < treaty.expiresAt;
    }

    /**
     * @notice Check if alliances have trade agreement
     */
    function hasTradeAgreement(bytes32 alliance1, bytes32 alliance2) 
        external 
        view 
        returns (bool) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        bytes32 key = keccak256(abi.encodePacked(alliance1, alliance2));
        LibColonyWarsStorage.DiplomaticTreaty storage treaty = cws.activeTreaties[key];

        return treaty.active && treaty.treatyType == 1 && block.timestamp < treaty.expiresAt;
    }

    /**
     * @notice Check if alliances have military pact
     */
    function hasMilitaryPact(bytes32 alliance1, bytes32 alliance2) 
        external 
        view 
        returns (bool) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        bytes32 key = keccak256(abi.encodePacked(alliance1, alliance2));
        LibColonyWarsStorage.DiplomaticTreaty storage treaty = cws.activeTreaties[key];

        return treaty.active && treaty.treatyType == 2 && block.timestamp < treaty.expiresAt;
    }

    // ==================== INTERNAL HELPERS ====================

    /**
     * @notice Complete mission and distribute rewards
     */
    function _completeMission(
        bytes32 missionId,
        LibColonyWarsStorage.AllianceMission storage mission,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        mission.active = false;
        mission.completed = true;
        mission.completedAt = uint32(block.timestamp);
        
        // Calculate rewards based on mission type
        uint256 baseReward = mission.targetAmount / 10; // 10% of target
        uint256 bonusReward = mission.contributors.length * 1000 ether; // Participation bonus
        uint256 totalReward = baseReward + bonusReward;
        
        // Distribute to alliance treasury
        LibColonyWarsStorage.Alliance storage alliance = cws.alliances[mission.allianceId];
        alliance.sharedTreasury += totalReward;
        
        // Boost stability
        if (alliance.stabilityIndex <= 80) {
            alliance.stabilityIndex += 20;
        } else {
            alliance.stabilityIndex = 100;
        }

        emit MissionCompleted(missionId, mission.allianceId, totalReward);

        // Trigger mission completed achievement for all contributors
        for (uint256 i = 0; i < mission.contributors.length; i++) {
            LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
            address contributorOwner = hs.colonyCreators[mission.contributors[i]];
            if (contributorOwner != address(0)) {
                LibAchievementTrigger.triggerMissionComplete(contributorOwner);
            }
        }
    }

    /**
     * @notice Apply treaty effects to both alliances
     */
    function _applyTreatyEffects(
        LibColonyWarsStorage.DiplomaticTreaty storage treaty,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        if (treaty.treatyType == 1) {
            // Trade: +10% resource production for both
            cws.zoneControlBonuses[treaty.alliance1] += 10;
            cws.zoneControlBonuses[treaty.alliance2] += 10;
        } else if (treaty.treatyType == 2) {
            // Military: +15% defense for both
            LibColonyWarsStorage.Alliance storage a1 = cws.alliances[treaty.alliance1];
            LibColonyWarsStorage.Alliance storage a2 = cws.alliances[treaty.alliance2];
            
            if (a1.stabilityIndex <= 85) a1.stabilityIndex += 15;
            if (a2.stabilityIndex <= 85) a2.stabilityIndex += 15;
        }
        // NAP (type 0) has no immediate bonus, just attack restrictions
    }

    // ==================== COORDINATED ATTACKS ====================

    /**
     * @notice Initiate coordinated attack from alliance members against target colony
     * @param targetColony Colony being attacked
     * @param participatingColonies Array of colony IDs participating in attack
     * @param collectionIds Array of collection IDs per participating colony (flattened)
     * @param tokenIds Array of token IDs per participating colony (flattened)
     * @param tokensPerColony Number of tokens each colony is using
     * @param totalStake Total PEAN staked for this coordinated attack
     * @return battleIds Array of battle IDs created
     */
    function initiateCoordinatedAttack(
        bytes32 targetColony,
        bytes32[] calldata participatingColonies,
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds,
        uint8 tokensPerColony,
        uint256 totalStake
    ) external whenNotPaused nonReentrant returns (bytes32[] memory battleIds) {
        bytes32 allianceId = _validateCoordinatedAttack(uint8(participatingColonies.length), totalStake);

        // Transfer stake
        _transferStake(totalStake);

        // Execute attacks
        battleIds = _executeCoordinatedAttacks(
            targetColony,
            participatingColonies,
            collectionIds,
            tokenIds,
            tokensPerColony,
            totalStake / participatingColonies.length
        );

        // Increment daily counter
        LibColonyWarsStorage.incrementAllianceCoordinatedAttackCount(allianceId);

        emit CoordinatedAttackInitiated(allianceId, targetColony, battleIds, uint8(participatingColonies.length));

        // Trigger coordinated attack achievement
        LibAchievementTrigger.triggerCoordinatedAttack(LibMeta.msgSender());
    }

    /**
     * @notice Initiate coordinated attack using task force
     * @param targetColony Colony being attacked
     * @param taskForceId Task force to use for attack
     * @param totalStake Total PEAN staked for this attack
     * @return battleIds Array of battle IDs created
     */
    function initiateCoordinatedAttackWithTaskForce(
        bytes32 targetColony,
        bytes32 taskForceId,
        uint256 totalStake
    ) external whenNotPaused nonReentrant returns (bytes32[] memory battleIds) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ColonyTaskForce storage taskForce = cws.allianceTaskForces[taskForceId];

        uint8 numColonies = uint8(taskForce.memberColonyIds.length) + 1;
        bytes32 allianceId = _validateTaskForceAttack(taskForce, numColonies, totalStake);

        // Transfer stake
        _transferStake(totalStake);

        // Execute attacks
        battleIds = _executeTaskForceAttacks(targetColony, taskForce, totalStake / numColonies, numColonies);

        // Increment daily counter
        LibColonyWarsStorage.incrementAllianceCoordinatedAttackCount(allianceId);

        emit CoordinatedAttackInitiated(allianceId, targetColony, battleIds, numColonies);

        // Trigger coordinated attack achievement
        LibAchievementTrigger.triggerCoordinatedAttack(LibMeta.msgSender());
    }

    // ==================== COORDINATED ATTACK HELPERS ====================

    function _validateCoordinatedAttack(uint8 numColonies, uint256 totalStake) private view returns (bytes32 allianceId) {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        if (!cws.coordinatedAttackConfig.enabled) revert CoordinatedAttacksNotEnabled();

        allianceId = LibColonyWarsStorage.getUserAllianceId(LibMeta.msgSender());
        if (allianceId == bytes32(0)) revert AllianceNotEligible();

        (bool canAttack, uint8 attacksToday) = LibColonyWarsStorage.canAllianceInitiateCoordinatedAttack(allianceId);
        if (!canAttack) {
            revert DailyCoordinatedAttackLimitReached(attacksToday, cws.coordinatedAttackConfig.maxCoordinatedAttacksPerDay);
        }

        if (numColonies == 0 || numColonies < cws.coordinatedAttackConfig.minParticipants) {
            revert NoParticipatingColonies();
        }

        uint256 minStake = cws.coordinatedAttackConfig.minStakePerParticipant * numColonies;
        if (totalStake < minStake) revert InsufficientStakeForCoordinatedAttack();
    }

    function _validateTaskForceAttack(
        LibColonyWarsStorage.ColonyTaskForce storage taskForce,
        uint8 numColonies,
        uint256 totalStake
    ) private view returns (bytes32 allianceId) {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        if (!cws.coordinatedAttackConfig.enabled) revert CoordinatedAttacksNotEnabled();
        if (!taskForce.isActive) revert MissionNotActive();

        allianceId = LibColonyWarsStorage.getUserAllianceId(LibMeta.msgSender());
        if (allianceId == bytes32(0)) revert AllianceNotEligible();

        bytes32 leaderAllianceId = LibColonyWarsStorage.getUserAllianceId(
            LibHenomorphsStorage.henomorphsStorage().colonyCreators[taskForce.leaderColonyId]
        );
        if (leaderAllianceId != allianceId) revert AllianceNotEligible();

        (bool canAttack, uint8 attacksToday) = LibColonyWarsStorage.canAllianceInitiateCoordinatedAttack(allianceId);
        if (!canAttack) {
            revert DailyCoordinatedAttackLimitReached(attacksToday, cws.coordinatedAttackConfig.maxCoordinatedAttacksPerDay);
        }

        uint256 minStake = cws.coordinatedAttackConfig.minStakePerParticipant * numColonies;
        if (totalStake < minStake) revert InsufficientStakeForCoordinatedAttack();
    }

    function _transferStake(uint256 amount) private {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        IERC20(hs.chargeTreasury.treasuryCurrency).transferFrom(LibMeta.msgSender(), address(this), amount);
    }

    function _executeCoordinatedAttacks(
        bytes32 targetColony,
        bytes32[] calldata participatingColonies,
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds,
        uint8 tokensPerColony,
        uint256 stakePerColony
    ) private returns (bytes32[] memory battleIds) {
        uint256 numColonies = participatingColonies.length;
        battleIds = new bytes32[](numColonies);

        for (uint256 i = 0; i < numColonies;) {
            uint256 startIdx = i * tokensPerColony;
            battleIds[i] = _doAttack(
                participatingColonies[i],
                targetColony,
                collectionIds,
                tokenIds,
                startIdx,
                tokensPerColony,
                stakePerColony
            );
            unchecked { ++i; }
        }
    }

    function _doAttack(
        bytes32 attackerColony,
        bytes32 targetColony,
        uint256[] calldata allCollections,
        uint256[] calldata allTokens,
        uint256 startIdx,
        uint8 count,
        uint256 stakeAmount
    ) private returns (bytes32) {
        uint256[] memory cols = new uint256[](count);
        uint256[] memory toks = new uint256[](count);

        for (uint256 j = 0; j < count;) {
            cols[j] = allCollections[startIdx + j];
            toks[j] = allTokens[startIdx + j];
            unchecked { ++j; }
        }

        return IColonyWarsFacet(address(this)).initiateAttack(attackerColony, targetColony, cols, toks, stakeAmount);
    }

    function _executeTaskForceAttacks(
        bytes32 targetColony,
        LibColonyWarsStorage.ColonyTaskForce storage taskForce,
        uint256 stakePerColony,
        uint8 numColonies
    ) private returns (bytes32[] memory battleIds) {
        battleIds = new bytes32[](numColonies);

        // Leader attack
        battleIds[0] = IColonyWarsFacet(address(this)).initiateAttack(
            taskForce.leaderColonyId,
            targetColony,
            taskForce.collectionIds,
            taskForce.tokenIds,
            stakePerColony
        );

        // Member attacks
        for (uint8 i = 0; i < taskForce.memberColonyIds.length; i++) {
            battleIds[i + 1] = _executeMemberAttack(taskForce.memberColonyIds[i], targetColony, stakePerColony);
        }
    }

    function _executeMemberAttack(
        bytes32 memberColony,
        bytes32 targetColony,
        uint256 stakeAmount
    ) private returns (bytes32) {
        LibColonyWarsStorage.SquadStakePosition storage squad =
            LibColonyWarsStorage.colonyWarsStorage().colonySquadStakes[memberColony];

        (uint256[] memory cols, uint256[] memory toks) = _getSquadTokens(squad);
        return IColonyWarsFacet(address(this)).initiateAttack(memberColony, targetColony, cols, toks, stakeAmount);
    }

    function _getSquadTokens(LibColonyWarsStorage.SquadStakePosition storage squad)
        private view returns (uint256[] memory cols, uint256[] memory toks)
    {
        uint256 count = squad.territoryCards.length + squad.infraCards.length + squad.resourceCards.length;
        cols = new uint256[](count);
        toks = new uint256[](count);

        uint256 idx = 0;
        for (uint256 j = 0; j < squad.territoryCards.length; j++) {
            cols[idx] = squad.territoryCards[j].collectionId;
            toks[idx++] = squad.territoryCards[j].tokenId;
        }
        for (uint256 j = 0; j < squad.infraCards.length; j++) {
            cols[idx] = squad.infraCards[j].collectionId;
            toks[idx++] = squad.infraCards[j].tokenId;
        }
        for (uint256 j = 0; j < squad.resourceCards.length; j++) {
            cols[idx] = squad.resourceCards[j].collectionId;
            toks[idx++] = squad.resourceCards[j].tokenId;
        }
    }

    /**
     * @notice Remove treaty from pending proposals array
     */
    function _removePendingProposal(
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        bytes32 allianceId,
        bytes32 treatyId
    ) internal {
        bytes32[] storage proposals = cws.pendingTreatyProposals[allianceId];
        for (uint256 i = 0; i < proposals.length; i++) {
            if (proposals[i] == treatyId) {
                proposals[i] = proposals[proposals.length - 1];
                proposals.pop();
                break;
            }
        }
    }

    // ==================== ALLIANCE EVOLUTION VIEW FUNCTIONS ====================

    /**
     * @notice Get all mission IDs for an alliance
     * @param allianceId Alliance to query
     * @return missionIds Array of all mission IDs (active and completed)
     */
    function getAllianceMissions(bytes32 allianceId)
        external
        view
        returns (bytes32[] memory missionIds)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        return cws.allianceMissionIds[allianceId];
    }

    /**
     * @notice Get current active mission for an alliance
     * @param allianceId Alliance to query
     * @return missionId Active mission ID (bytes32(0) if none)
     * @return exists True if active mission exists
     */
    function getAllianceActiveMission(bytes32 allianceId)
        external
        view
        returns (bytes32 missionId, bool exists)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        bytes32[] storage missionIds = cws.allianceMissionIds[allianceId];

        for (uint256 i = 0; i < missionIds.length; i++) {
            LibColonyWarsStorage.AllianceMission storage mission = cws.allianceMissions[missionIds[i]];
            if (mission.active && !mission.completed && block.timestamp <= mission.deadline) {
                return (missionIds[i], true);
            }
        }

        return (bytes32(0), false);
    }

    /**
     * @notice Get all treaty IDs for an alliance
     * @param allianceId Alliance to query
     * @return treatyIds Array of all treaty IDs (proposed, active, broken)
     */
    function getAllianceTreaties(bytes32 allianceId)
        external
        view
        returns (bytes32[] memory treatyIds)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        return cws.allianceTreatyIds[allianceId];
    }

    /**
     * @notice Get pending treaty proposals for an alliance
     * @param allianceId Alliance to query (as target)
     * @return proposalIds Array of pending treaty IDs awaiting acceptance
     */
    function getPendingTreatyProposals(bytes32 allianceId)
        external
        view
        returns (bytes32[] memory proposalIds)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        return cws.pendingTreatyProposals[allianceId];
    }

    /**
     * @notice Get all contested zones for a season
     * @param season Season number to query
     * @return zoneIds Array of contested zone IDs
     */
    function getContestedZones(uint32 season)
        external
        view
        returns (uint256[] memory zoneIds)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        return cws.seasonContestedZones[season];
    }

    /**
     * @notice Get detailed info about a contested zone
     * @param zoneId Zone ID to query
     * @return info ContestedZoneInfo struct with zone details
     */
    function getZoneDetails(uint256 zoneId)
        external
        view
        returns (LibColonyWarsStorage.ContestedZoneInfo memory info)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        return cws.contestedZoneInfo[zoneId];
    }

    /**
     * @notice Get list of alliances contesting a zone
     * @param zoneId Zone ID to query
     * @return challengers Array of alliance IDs contesting the zone
     */
    function getZoneChallengers(uint256 zoneId)
        external
        view
        returns (bytes32[] memory challengers)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        return cws.zoneChallengers[zoneId];
    }
}
