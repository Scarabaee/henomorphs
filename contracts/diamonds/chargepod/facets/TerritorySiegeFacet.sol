// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {ColonyHelper} from "../libraries/ColonyHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {PowerMatrix} from "../../libraries/HenomorphsModel.sol";
import {WarfareHelper, TokenStats, IAccessoryFacet} from "../libraries/WarfareHelper.sol";
import {LibAchievementTrigger} from "../libraries/LibAchievementTrigger.sol";

/**
 * @title TerritorySiegeFacet
 * @notice Territory siege operations - initiate, defend, cancel, and resolve sieges
 * @dev Extracted from TerritoryWarsFacet to reduce contract size
 */
contract TerritorySiegeFacet is AccessControlBase {

    // Struct to reduce stack depth in siegeTerritory
    struct SiegeSetupParams {
        uint256 territoryId;
        bytes32 attackerColony;
        bytes32 defenderColony;
        uint256[] attackTokens;
        uint256[] attackerPowers;
        uint256 validatedStake;
        uint32 siegeEndTime;
    }

    // Events
    event TerritorySiegeCreated(
        bytes32 indexed siegeId,
        uint256 indexed territoryId,
        bytes32 indexed attackerColony,
        bytes32 defenderColony,
        uint256 stake
    );
    event SiegeDefended(
        bytes32 indexed siegeId,
        bytes32 indexed defenderColony,
        uint256 defenseTokensCount
    );
    event SiegeResolved(
        bytes32 indexed siegeId,
        uint256 indexed territoryId,
        bytes32 indexed winner,
        uint256 prize,
        uint16 damageDealt
    );
    event SiegeCancelled(
        bytes32 indexed siegeId,
        uint256 indexed territoryId,
        string reason,
        uint256 refundAmount
    );
    event SiegeForfeit(
        bytes32 indexed siegeId,
        uint256 indexed territoryId,
        bytes32 indexed forfeitingColony,
        bytes32 winner,
        string reason,
        uint256 penaltyAmount
    );
    event SiegeOutcome(
        bytes32 indexed siegeId,
        bytes32 indexed attackerColony,
        bytes32 indexed defenderColony,
        uint256 attackerPower,
        uint256 defenderPower,
        bytes32 winner,
        string weatherDescription
    );

    // Custom errors
    error InvalidRaidTarget();
    error InsufficientRaidStake();
    error TerritoryFullyDamaged();
    error WarfareNotStarted();
    error WarfareEnded();
    error SiegeNotFound();
    error InvalidSiegeState();
    error SiegeAlreadyResolved();
    error TerritoryNotFound();
    error RateLimitExceeded();
    error RaidCooldownActive();
    error TaskForceInvalid();

    /**
     * @notice Siege territory with tokens and stake
     * @param territoryId Territory to siege
     * @param attackerColony Attacking colony ID
     * @param attackCollectionIds Array of collection IDs for attacking tokens
     * @param attackTokenIds Array of token IDs for attacking tokens
     * @param stakeAmount ZICO amount to stake on the siege
     * @return siegeId Unique identifier for the created siege
     */
    function siegeTerritory(
        uint256 territoryId,
        bytes32 attackerColony,
        uint256[] memory attackCollectionIds,
        uint256[] memory attackTokenIds,
        uint256 stakeAmount
    )
        public
        whenNotPaused
        nonReentrant
        returns (bytes32 siegeId)
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("territories");

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        // Validate and prepare siege (reduces stack depth)
        SiegeSetupParams memory params = _validateAndPrepareSiege(
            territoryId,
            attackerColony,
            attackCollectionIds,
            attackTokenIds,
            stakeAmount,
            cws,
            hs
        );

        // Generate unique siege identifier
        cws.siegeCounter++;
        siegeId = keccak256(abi.encodePacked(
            "territory_siege",
            params.territoryId,
            params.attackerColony,
            params.defenderColony,
            block.timestamp,
            cws.siegeCounter
        ));

        // Initialize siege and finalize setup
        _finalizeSiegeSetup(siegeId, params, stakeAmount, cws, hs);

        return siegeId;
    }

    /**
     * @notice Validate siege parameters and prepare setup data
     */
    function _validateAndPrepareSiege(
        uint256 territoryId,
        bytes32 attackerColony,
        uint256[] memory attackCollectionIds,
        uint256[] memory attackTokenIds,
        uint256 stakeAmount,
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) internal returns (SiegeSetupParams memory params) {
        // Rate limiting
        if (!LibColonyWarsStorage.checkRateLimit(LibMeta.msgSender(), this.siegeTerritory.selector, cws.config.attackCooldown)) {
            revert RateLimitExceeded();
        }

        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
        if (block.timestamp < season.registrationEnd) revert WarfareNotStarted();
        if (block.timestamp > season.warfareEnd) revert WarfareEnded();

        // Basic validation
        if (!ColonyHelper.isColonyCreator(attackerColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Only colony creator can siege");
        }
        if (attackCollectionIds.length != attackTokenIds.length) revert WarfareHelper.InvalidTokenCount();
        if (attackCollectionIds.length > cws.config.maxBattleTokens || attackCollectionIds.length < 2) {
            revert WarfareHelper.InvalidTokenCount();
        }

        // Validate territory
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        if (!territory.active) revert TerritoryNotFound();
        if (territory.controllingColony == bytes32(0)) revert InvalidRaidTarget();
        if (territory.controllingColony == attackerColony) revert InvalidRaidTarget();
        if (hs.colonyCreators[attackerColony] == hs.colonyCreators[territory.controllingColony]) revert InvalidRaidTarget();
        if (territory.damageLevel >= 100) revert TerritoryFullyDamaged();

        // Conflict checks
        if (ColonyHelper.isColonyCreator(territory.controllingColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Cannot siege own territory");
        }
        if (WarfareHelper.checkTokensForWarfareConflict(attackCollectionIds, attackTokenIds, territory.controllingColony)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Token ownership conflict");
        }

        // Cooldown and registration checks
        if (block.timestamp < territory.lastRaidTime + 86400) revert RaidCooldownActive();
        if (!cws.colonyWarProfiles[attackerColony].registered) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Colony not registered");
        }
        if (!cws.colonyWarProfiles[territory.controllingColony].registered) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Target colony not registered");
        }

        // Stake validation
        LibColonyWarsStorage.ColonyWarProfile storage defenderProfile = cws.colonyWarProfiles[territory.controllingColony];
        if (stakeAmount < defenderProfile.defensiveStake / 2) revert InsufficientRaidStake();

        // Verify tokens and get powers
        params.attackTokens = WarfareHelper.verifyAndConvertTokens(attackCollectionIds, attackTokenIds, attackerColony, hs);
        for (uint256 i = 0; i < params.attackTokens.length; i++) {
            if (!LibColonyWarsStorage.isTokenAvailableForBattle(params.attackTokens[i])) {
                revert WarfareHelper.TokenInActiveBattle();
            }
        }

        TokenStats[] memory attackerStats = IAccessoryFacet(address(this)).getTokenPerformanceStats(attackCollectionIds, attackTokenIds);
        if (attackerStats.length != attackCollectionIds.length || attackerStats.length > cws.config.maxBattleTokens) {
            revert WarfareHelper.InvalidTokenCount();
        }

        params.attackerPowers = new uint256[](attackerStats.length);
        for (uint256 i = 0; i < attackerStats.length; i++) {
            params.attackerPowers[i] = WarfareHelper.calculateTokenPower(attackerStats[i]);
        }

        params.territoryId = territoryId;
        params.attackerColony = attackerColony;
        params.defenderColony = territory.controllingColony;
        params.validatedStake = WarfareHelper.validateTerritoryStake(stakeAmount, defenderProfile.defensiveStake, false);
        params.siegeEndTime = uint32(block.timestamp + cws.config.battlePreparationTime + cws.config.battleDuration);

        return params;
    }

    /**
     * @notice Finalize siege setup and emit events
     */
    function _finalizeSiegeSetup(
        bytes32 siegeId,
        SiegeSetupParams memory params,
        uint256 originalStake,
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) internal {
        LibColonyWarsStorage.TerritorySiege storage siege = cws.territorySieges[siegeId];
        siege.territoryId = params.territoryId;
        siege.attackerColony = params.attackerColony;
        siege.defenderColony = params.defenderColony;
        siege.attackerTokens = params.attackTokens;
        siege.siegeStartTime = uint32(block.timestamp);
        siege.siegeEndTime = params.siegeEndTime;
        siege.siegeState = 0;
        siege.stakeAmount = params.validatedStake;
        siege.prizePool = params.validatedStake;

        // Check for alliance betrayal
        (bool isBetrayal, bytes32 betrayedAllianceId) = LibColonyWarsStorage.validateAndProcessBetrayal(
            LibMeta.msgSender(),
            params.attackerColony,
            params.defenderColony,
            "siege"
        );

        if (isBetrayal) {
            siege.isBetrayalAttack = true;
            emit WarfareHelper.BetrayalRecorded(params.attackerColony, betrayedAllianceId);
            emit WarfareHelper.ColonyLeftAlliance(betrayedAllianceId, params.attackerColony, "Attacked alliance member territory");
        }

        LibColonyWarsStorage.reserveTokensForBattle(params.attackTokens, params.siegeEndTime);

        cws.siegeSnapshots[siegeId].attackerPowers = params.attackerPowers;
        cws.siegeSnapshots[siegeId].timestamp = block.timestamp;

        cws.territories[params.territoryId].lastRaidTime = uint32(block.timestamp);

        // Transfer stake
        LibFeeCollection.collectFee(
            IERC20(hs.chargeTreasury.treasuryCurrency),
            LibMeta.msgSender(),
            hs.chargeTreasury.treasuryAddress,
            params.validatedStake,
            "territory_siege"
        );

        cws.activeSieges.push(siegeId);
        cws.territoryActiveSieges[params.territoryId].push(siegeId);
        cws.seasonSieges[cws.currentSeason].push(siegeId);
        cws.colonySiegeHistory[params.attackerColony].push(siegeId);
        cws.colonySiegeHistory[params.defenderColony].push(siegeId);

        emit TerritorySiegeCreated(siegeId, params.territoryId, params.attackerColony, params.defenderColony, originalStake);
    }

    /**
     * @notice Defend against a siege by committing defense tokens
     * @param siegeId Siege ID to defend
     * @param defenseCollectionIds Array of collection IDs for defending tokens
     * @param defenseTokenIds Array of token IDs for defending tokens
     */
    function defendSiege(
        bytes32 siegeId,
        uint256[] memory defenseCollectionIds,
        uint256[] memory defenseTokenIds
    )
        public
        whenNotPaused
        nonReentrant
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("territories");

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        LibColonyWarsStorage.TerritorySiege storage siege = cws.territorySieges[siegeId];
        if (siege.siegeStartTime == 0) {
            revert SiegeNotFound();
        }
        if (siege.siegeState != 0) {
            revert InvalidSiegeState();
        }
        if (block.timestamp > siege.siegeStartTime + cws.config.battlePreparationTime) {
            revert InvalidSiegeState();
        }
        if (defenseCollectionIds.length != defenseTokenIds.length) {
            revert WarfareHelper.InvalidTokenCount();
        }
        if (defenseCollectionIds.length > cws.config.maxBattleTokens || defenseCollectionIds.length == 0) {
            revert WarfareHelper.InvalidTokenCount();
        }

        // Verify caller controls the defending colony
        if (!ColonyHelper.isColonyCreator(siege.defenderColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Only colony creator can defend siege");
        }

        if (WarfareHelper.checkTokensForWarfareConflict(
            defenseCollectionIds,
            defenseTokenIds,
            siege.attackerColony
        )) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Token ownership conflict with attacker");
        }

        // Verify tokens belong to defender colony and convert to combined IDs
        uint256[] memory defenseTokens = WarfareHelper.verifyAndConvertTokens(defenseCollectionIds, defenseTokenIds, siege.defenderColony, hs);
        for (uint256 i = 0; i < defenseTokens.length; i++) {
            if (!LibColonyWarsStorage.isTokenAvailableForBattle(defenseTokens[i])) {
                revert WarfareHelper.TokenInActiveBattle();
            }
        }

        // Create battle snapshot for defender tokens
        TokenStats[] memory defenderStats = IAccessoryFacet(address(this)).getTokenPerformanceStats(defenseCollectionIds, defenseTokenIds);

        // Safety check: prevent memory allocation errors from corrupted external call data
        if (defenderStats.length != defenseCollectionIds.length || defenderStats.length > cws.config.maxBattleTokens) {
            revert WarfareHelper.InvalidTokenCount();
        }

        uint256[] memory defenderPowers = new uint256[](defenderStats.length);
        for (uint256 i = 0; i < defenderStats.length; i++) {
            defenderPowers[i] = WarfareHelper.calculateTokenPower(defenderStats[i]);
        }

        // Only store tokens and advance siege state - DO NOT add defensive stake to prize pool
        siege.defenderTokens = defenseTokens;
        siege.siegeState = 1; // Active phase

        LibColonyWarsStorage.reserveTokensForBattle(defenseTokens, siege.siegeEndTime);
        cws.siegeSnapshots[siegeId].defenderPowers = defenderPowers;

        cws.colonyWarProfiles[siege.defenderColony].lastAttackTime = uint32(block.timestamp);

        WarfareHelper.awardTerritoryDefensiveBonus(
            siege.defenderColony,
            defenseTokens.length,
            siege.attackerTokens.length,
            cws.currentSeason
        );

        emit SiegeDefended(siegeId, siege.defenderColony, defenseTokens.length);
    }

    /**
     * @notice Cancel siege during preparation phase
     * @param siegeId Siege to cancel
     * @param reason Reason for cancellation
     */
    function cancelSiege(bytes32 siegeId, string calldata reason)
        external
        whenNotPaused
        nonReentrant
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("territories");

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        LibColonyWarsStorage.TerritorySiege storage siege = cws.territorySieges[siegeId];
        if (siege.siegeStartTime == 0) {
            revert SiegeNotFound();
        }

        if (!ColonyHelper.isColonyCreator(siege.attackerColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Only attacker colony creator can cancel siege");
        }

        if (siege.siegeState != 0) {
            revert InvalidSiegeState();
        }

        // Calculate penalty based on game state and time
        uint32 timeElapsed = uint32(block.timestamp) - siege.siegeStartTime;
        uint32 preparationTime = cws.config.battlePreparationTime;
        bool defenderCommitted = siege.defenderTokens.length > 0;

        uint256 penalty;
        if (!defenderCommitted && timeElapsed < preparationTime / 3) {
            penalty = 5; // Minimal penalty
        } else if (!defenderCommitted) {
            penalty = 15; // Moderate penalty
        } else if (timeElapsed < preparationTime / 2) {
            penalty = 25; // Defender prepared, early cancellation
        } else {
            penalty = 40; // High penalty for late cancellation
        }

        uint256 penaltyAmount = (siege.stakeAmount * penalty) / 100;
        uint256 refundAmount = siege.stakeAmount - penaltyAmount;

        // Distribute penalty appropriately
        if (penaltyAmount > 0) {
            if (defenderCommitted) {
                // Compensate defender for wasted preparation
                address defenderCreator = hs.colonyCreators[siege.defenderColony];
                if (defenderCreator != address(0)) {
                    LibFeeCollection.transferFromTreasury(defenderCreator, penaltyAmount * 60 / 100, "siege_preparation_compensation");
                }
                // Rest goes to season pool
                LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
                season.prizePool += penaltyAmount * 40 / 100;
            } else {
                // No defender commitment - penalty goes to season pool
                LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
                season.prizePool += penaltyAmount;
            }
        }

        // Refund attacker
        if (refundAmount > 0) {
            LibFeeCollection.transferFromTreasury(LibMeta.msgSender(), refundAmount, "siege_cancellation_refund");
        }

        // Update siege state
        siege.siegeState = 3; // CANCELLED
        siege.winner = bytes32(0);
        cws.siegeResolved[siegeId] = true;

        WarfareHelper.removeFromActiveSieges(siegeId, siege.territoryId, cws);

        for (uint256 i = 0; i < siege.attackerTokens.length; i++) {
            LibColonyWarsStorage.releaseToken(siege.attackerTokens[i]);
        }
        if (siege.defenderTokens.length > 0) {
            for (uint256 i = 0; i < siege.defenderTokens.length; i++) {
                LibColonyWarsStorage.releaseToken(siege.defenderTokens[i]);
            }
        }

        emit SiegeCancelled(siegeId, siege.territoryId, reason, refundAmount);
    }

    /**
     * @notice Resolve completed siege
     * @param siegeId Siege identifier to resolve
     */
    function resolveSiege(bytes32 siegeId)
        external
        whenNotPaused
        nonReentrant
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("territories");

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        LibColonyWarsStorage.TerritorySiege storage siege = cws.territorySieges[siegeId];
        if (siege.siegeStartTime == 0) {
            revert SiegeNotFound();
        }
        if (siege.siegeState != 0 && siege.siegeState != 1) {
            revert InvalidSiegeState();
        }

        uint32 siegeEndTime;
        if (siege.siegeState == 0) {
            siegeEndTime = siege.siegeStartTime + cws.config.battlePreparationTime;
        } else {
            siegeEndTime = siege.siegeEndTime;
        }

        if (block.timestamp < siegeEndTime) {
            revert InvalidSiegeState();
        }

        if (cws.siegeResolved[siegeId]) {
            revert SiegeAlreadyResolved();
        }

        if (siege.siegeState == 0) {
            siege.siegeState = 1;
        }

        // FORFEIT VALIDATION SYSTEM - Check both sides for token movement
        bool attackerValid = WarfareHelper.validateTokensStillInColony(
            siege.attackerTokens,
            siege.attackerColony,
            hs
        );

        bool defenderValid = true;
        if (siege.defenderTokens.length > 0) {
            defenderValid = WarfareHelper.validateTokensStillInColony(
                siege.defenderTokens,
                siege.defenderColony,
                hs
            );
        }

        // Handle forfeit scenarios
        if (!attackerValid && !defenderValid) {
            // Both sides moved tokens - mutual forfeit, defender wins (territory advantage)
            siege.winner = siege.defenderColony;
            WarfareHelper.applyForfeitPenalty(
                WarfareHelper.ForfeitParams({
                    attackerColony: siege.attackerColony,
                    defenderColony: siege.defenderColony,
                    stakeAmount: siege.stakeAmount,
                    defenderStake: cws.colonyWarProfiles[siege.defenderColony].defensiveStake,
                    forfeitType: 3,
                    seasonId: cws.currentSeason,
                    isTerritory: true
                }),
                cws, hs
            );
            emit SiegeForfeit(siegeId, siege.territoryId, siege.attackerColony, siege.defenderColony, "Mutual token movement", siege.stakeAmount);

        } else if (!attackerValid) {
            // Attacker moved tokens - attacker forfeits, defender wins
            siege.winner = siege.defenderColony;
            WarfareHelper.applyForfeitPenalty(
                WarfareHelper.ForfeitParams({
                    attackerColony: siege.attackerColony,
                    defenderColony: siege.defenderColony,
                    stakeAmount: siege.stakeAmount,
                    defenderStake: cws.colonyWarProfiles[siege.defenderColony].defensiveStake,
                    forfeitType: 1,
                    seasonId: cws.currentSeason,
                    isTerritory: true
                }),
                cws, hs
            );
            emit SiegeForfeit(siegeId, siege.territoryId, siege.attackerColony, siege.defenderColony, "Attacker moved tokens", siege.stakeAmount);

        } else if (!defenderValid) {
            // Defender moved tokens - defender forfeits, attacker wins
            siege.winner = siege.attackerColony;
            WarfareHelper.applyForfeitPenalty(
                WarfareHelper.ForfeitParams({
                    attackerColony: siege.attackerColony,
                    defenderColony: siege.defenderColony,
                    stakeAmount: siege.stakeAmount,
                    defenderStake: cws.colonyWarProfiles[siege.defenderColony].defensiveStake,
                    forfeitType: 2,
                    seasonId: cws.currentSeason,
                    isTerritory: true
                }),
                cws, hs
            );
            emit SiegeForfeit(siegeId, siege.territoryId, siege.defenderColony, siege.attackerColony, "Defender moved tokens", 0);

        } else {
            // Both sides valid - proceed with normal siege resolution
            bytes32 winner = _calculateSiegeOutcome(siegeId, siege, cws);
            siege.winner = winner;

            // Calculate and apply territory damage if attacker wins
            if (winner == siege.attackerColony) {
                LibColonyWarsStorage.SiegeSnapshot storage dmgSnapshot = cws.siegeSnapshots[siegeId];
                uint16 damageDealt = WarfareHelper.calculateTerritoryDamage(
                    dmgSnapshot.attackerPowers,
                    dmgSnapshot.defenderPowers,
                    siege.stakeAmount
                );
                LibColonyWarsStorage.Territory storage territory = cws.territories[siege.territoryId];
                uint16 previousDamage = territory.damageLevel;
                territory.damageLevel += damageDealt;
                if (territory.damageLevel > 100) territory.damageLevel = 100;

                // If this siege destroyed the territory (brought damage to 100), record siege for capture priority
                if (previousDamage < 100 && territory.damageLevel >= 100) {
                    cws.lastDestroyingSiegeId[siege.territoryId] = siegeId;
                }
            }

            // Apply normal post-siege effects
            _applySiegeEffects(siege, winner, hs);

            // Distribute normal rewards
            _distributeSiegeRewards(siege, cws, hs);

            // Update season points normally
            _updateSiegeSeasonPoints(siege, winner, cws);

            // Trigger siege achievements
            address winnerOwner = hs.colonyCreators[winner];
            if (winnerOwner != address(0)) {
                LibAchievementTrigger.triggerSiegeWin(winnerOwner, cws.colonyWinStreaks[winner]);
                if (winner == siege.defenderColony) {
                    LibAchievementTrigger.triggerDefense(winnerOwner, cws.colonyWinStreaks[winner]);
                }
            }
        }

        // Common cleanup for all resolution types
        siege.siegeState = 2; // Completed
        cws.siegeResolved[siegeId] = true;

        // Clean up siege snapshot
        delete cws.siegeSnapshots[siegeId];

        WarfareHelper.removeFromActiveSieges(siegeId, siege.territoryId, cws);

        // Release all tokens
        for (uint256 i = 0; i < siege.attackerTokens.length; i++) {
            LibColonyWarsStorage.releaseToken(siege.attackerTokens[i]);
        }
        if (siege.defenderTokens.length > 0) {
            for (uint256 i = 0; i < siege.defenderTokens.length; i++) {
                LibColonyWarsStorage.releaseToken(siege.defenderTokens[i]);
            }
        }

        emit SiegeResolved(siegeId, siege.territoryId, siege.winner, siege.prizePool, 0);
    }

    // ============ TASK FORCE INTEGRATION ============

    /**
     * @notice Siege territory using a Task Force
     * @param territoryId Territory to siege
     * @param attackerColony Attacking colony ID
     * @param taskForceId Task Force to use for siege
     * @param stakeAmount ZICO amount to stake
     * @return siegeId Siege identifier
     */
    function initiateSiege(
        uint256 territoryId,
        bytes32 attackerColony,
        bytes32 taskForceId,
        uint256 stakeAmount
    )
        external
        returns (bytes32 siegeId)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        // Validate task force
        LibColonyWarsStorage.TaskForce storage tf = cws.taskForces[taskForceId];
        if (tf.createdAt == 0 || !tf.active) revert TaskForceInvalid();
        if (tf.colonyId != attackerColony) revert TaskForceInvalid();
        if (tf.seasonId != cws.currentSeason) revert TaskForceInvalid();

        // Delegate to siegeTerritory
        return siegeTerritory(
            territoryId,
            attackerColony,
            tf.collectionIds,
            tf.tokenIds,
            stakeAmount
        );
    }

    /**
     * @notice Defend siege using a Task Force
     * @param siegeId Siege to defend
     * @param taskForceId Task Force to use for defense
     */
    function reinforceSiege(
        bytes32 siegeId,
        bytes32 taskForceId
    )
        external
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.TerritorySiege storage siege = cws.territorySieges[siegeId];

        if (siege.siegeStartTime == 0) revert SiegeNotFound();

        // Validate task force
        LibColonyWarsStorage.TaskForce storage tf = cws.taskForces[taskForceId];
        if (tf.createdAt == 0 || !tf.active) revert TaskForceInvalid();
        if (tf.colonyId != siege.defenderColony) revert TaskForceInvalid();
        if (tf.seasonId != cws.currentSeason) revert TaskForceInvalid();

        // Delegate to defendSiege
        defendSiege(siegeId, tf.collectionIds, tf.tokenIds);
    }

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @notice Calculate siege outcome with hybrid defense system
     */
    function _calculateSiegeOutcome(
        bytes32 siegeId,
        LibColonyWarsStorage.TerritorySiege storage siege,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal returns (bytes32 winner) {
        LibColonyWarsStorage.SiegeSnapshot storage snapshot = cws.siegeSnapshots[siegeId];

        // Calculate base powers using WarfareHelper
        WarfareHelper.SiegeBaseResult memory baseResult = WarfareHelper.calculateSiegeBasePowers(
            WarfareHelper.SiegeBaseParams({
                attackerColony: siege.attackerColony,
                defenderColony: siege.defenderColony,
                territoryId: siege.territoryId
            }),
            snapshot.attackerPowers,
            snapshot.defenderPowers,
            cws
        );

        uint256 attackerPower;
        uint256 defenderPower;

        // Apply attacker bonuses
        {
            uint256 defenderStake = cws.colonyWarProfiles[siege.defenderColony].defensiveStake;
            attackerPower = WarfareHelper.calculateSiegeAttackerPower(
                WarfareHelper.SiegeAttackerParams({
                    attackerColony: siege.attackerColony,
                    defenderColony: siege.defenderColony,
                    territoryId: siege.territoryId,
                    basePower: baseResult.attackerPower,
                    stakeAmount: siege.stakeAmount,
                    defenderStake: defenderStake
                }),
                cws
            );
        }

        // Apply defender bonuses
        defenderPower = WarfareHelper.calculateSiegeDefenderPower(
            WarfareHelper.SiegeDefenderParams({
                defenderColony: siege.defenderColony,
                territoryId: siege.territoryId,
                basePower: baseResult.defenderPower,
                defenderPowers: snapshot.defenderPowers,
                siegeId: siegeId
            }),
            cws
        );

        // Apply randomness effects
        (attackerPower, defenderPower) = WarfareHelper.applySiegeRandomnessEffects(
            attackerPower,
            defenderPower,
            baseResult.randomness
        );

        // Determine winner
        bytes32 loser = attackerPower > defenderPower ? siege.defenderColony : siege.attackerColony;
        winner = attackerPower > defenderPower ? siege.attackerColony : siege.defenderColony;

        // Update win streaks
        WarfareHelper.updateWinStreaks(winner, loser, cws);
        WarfareHelper.updateSeasonConsecutiveLosses(winner, loser, cws.currentSeason, cws);

        emit SiegeOutcome(
            siegeId,
            siege.attackerColony,
            siege.defenderColony,
            attackerPower,
            defenderPower,
            winner,
            baseResult.weatherDesc
        );

        return winner;
    }

    /**
     * @notice Apply post-siege effects only to tokens that participated
     */
    function _applySiegeEffects(
        LibColonyWarsStorage.TerritorySiege storage siege,
        bytes32 winner,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) internal {
        // Apply effects to attacker tokens (always present)
        // consumptionMultiplier=10, fatigueMultiplier=5 for siege battles
        WarfareHelper.applyTokenBattleEffects(siege.attackerTokens, winner == siege.attackerColony, 10, 5, hs);

        // Apply effects to defender tokens only if they participated actively
        if (siege.defenderTokens.length > 0) {
            WarfareHelper.applyTokenBattleEffects(siege.defenderTokens, winner == siege.defenderColony, 10, 5, hs);
        }
    }

    /**
     * @notice Updated reward distribution with adaptive stake loss for territory sieges
     */
    function _distributeSiegeRewards(
        LibColonyWarsStorage.TerritorySiege storage siege,
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) internal {
        if (siege.prizePool == 0) return;

        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];

        // 5% to season pool
        uint256 seasonFee = siege.prizePool / 20;
        season.prizePool += seasonFee;

        // Work with remaining pool
        uint256 remaining = siege.prizePool - seasonFee;
        siege.prizePool = 0; // Zero immediately after reading

        if (siege.winner == siege.attackerColony) {
            _handleTerritoryConquest(siege, cws, hs, remaining, season);
        } else {
            _handleTerritoryDefense(siege, cws, hs, remaining, season);
        }
    }

    /**
     * @notice Territory conquest handling with proper defensive stake loss
     */
    function _handleTerritoryConquest(
        LibColonyWarsStorage.TerritorySiege storage siege,
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        LibHenomorphsStorage.HenomorphsStorage storage hs,
        uint256 available,
        LibColonyWarsStorage.Season storage season
    ) internal {
        LibColonyWarsStorage.ColonyWarProfile storage defenderProfile = cws.colonyWarProfiles[siege.defenderColony];

        // Calculate defensive stake loss and ADD it to available rewards
        uint256 stakeLoss = WarfareHelper.calculateSiegeStakeLoss(
            siege.defenderTokens.length > 0, // hasDefended
            0, 0, // power parameters not needed
            defenderProfile.defensiveStake
        );

        // Actually consume defensive stake and add to prize pool
        if (stakeLoss > 0 && defenderProfile.defensiveStake >= stakeLoss) {
            defenderProfile.defensiveStake -= stakeLoss;
            cws.colonyLosses[siege.defenderColony] += stakeLoss;
            available += stakeLoss;
        }

        // 85% to winner (higher than colony battles)
        uint256 winnerAmount = (available * 85) / 100;

        address winnerCreator = hs.colonyCreators[siege.winner];
        if (winnerCreator != address(0)) {
            LibFeeCollection.transferFromTreasury(winnerCreator, winnerAmount, "territory_conquest");
        } else {
            season.prizePool += winnerAmount;
        }

        // Remaining 15% to season
        season.prizePool += available - winnerAmount;
    }

    /**
     * @notice Territory defense handling - no defensive stake loss
     */
    function _handleTerritoryDefense(
        LibColonyWarsStorage.TerritorySiege storage siege,
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        LibHenomorphsStorage.HenomorphsStorage storage hs,
        uint256 available,
        LibColonyWarsStorage.Season storage season
    ) internal {
        // When defender wins, NO defensive stake is lost

        // 65% defender, 25% attacker refund, 10% system
        uint256 defenderAmount = (available * 65) / 100;
        uint256 refundAmount = (available * 25) / 100;
        uint256 systemAmount = available - defenderAmount - refundAmount;

        // Pay defender
        address defenderCreator = hs.colonyCreators[siege.winner];
        if (defenderCreator != address(0)) {
            LibFeeCollection.transferFromTreasury(defenderCreator, defenderAmount, "territory_defense");
        } else {
            systemAmount += defenderAmount;
        }

        // Refund attacker
        address attackerCreator = hs.colonyCreators[siege.attackerColony];
        if (attackerCreator != address(0)) {
            LibFeeCollection.transferFromTreasury(attackerCreator, refundAmount, "siege_refund");
            cws.colonyLosses[siege.attackerColony] += siege.stakeAmount - refundAmount;
        } else {
            systemAmount += refundAmount;
            cws.colonyLosses[siege.attackerColony] += siege.stakeAmount;
        }

        // System amount to season pool
        season.prizePool += systemAmount;
    }

    /**
     * @notice Update siege season points with activity-based scoring
     */
    function _updateSiegeSeasonPoints(
        LibColonyWarsStorage.TerritorySiege storage siege,
        bytes32 winner,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        WarfareHelper.updateSiegeSeasonPoints(
            siege.attackerColony,
            siege.defenderColony,
            winner,
            siege.stakeAmount,
            cws.colonyWarProfiles[siege.defenderColony].defensiveStake,
            siege.defenderTokens.length > 0,
            cws
        );
    }
}
