// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {ColonyHelper} from "../libraries/ColonyHelper.sol";
import {PodsUtils} from "../../libraries/PodsUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {SpecimenCollection, PowerMatrix} from "../../libraries/HenomorphsModel.sol";
import {WarfareHelper, TokenStats, IAccessoryFacet, IAllianceWarsFacet} from "../libraries/WarfareHelper.sol";
import {LibAchievementTrigger} from "../libraries/LibAchievementTrigger.sol";

interface IStrategicOverviewFacet {
    function getBattlefieldWeather() external view returns (uint8, string memory, uint8, uint8);
}

interface IAllianceEvolutionFacet {
    function getTreaty(bytes32 allianceId1, bytes32 allianceId2) external view returns (bool active, uint8 treatyType, uint32 activatedAt, uint32 expiresAt);
}

/**
 * @title ColonyWarsFacet
 * @notice Enhanced Colony Wars with improved economic incentives for attackers
 * @dev Implements asymmetric reward distribution and reduced entry barriers
 */
contract ColonyWarsFacet is AccessControlBase {

    // Events
    event BattleCreated(bytes32 indexed battleId, bytes32 indexed attacker, bytes32 indexed defender, uint256 stake);
    event BattleResolved(bytes32 indexed battleId, bytes32 indexed winner, uint256 prize);
    event ColonyRegisteredForSeason(bytes32 indexed colonyId, uint32 indexed seasonId);
    event BattleStatsSnapshot(bytes32 indexed battleId, uint256 attackerTotalPower, uint256 defenderTotalPower);
    event RaidBonusPaid(bytes32 indexed battleId, bytes32 indexed winner, uint256 bonusAmount);
    event BattleCancelled(
        bytes32 indexed battleId, 
        bytes32 indexed attackerColony, 
        string reason, 
        uint256 refundAmount, 
        uint256 penaltyAmount
    );
    event StakeChanged(bytes32 indexed colonyId, uint256 newTotal, bool increased, uint256 amount);
    event ColonyUnregisteredFromSeason(
        bytes32 indexed colonyId, 
        uint32 indexed seasonId, 
        uint256 refundAmount, 
        uint256 penaltyAmount
    );

    event BattleForfeit(
        bytes32 indexed battleId,
        bytes32 indexed forfeitingColony,
        bytes32 indexed winner,
        string reason,
        uint256 penaltyAmount
    );
    event BattleOutcome(
        bytes32 indexed battleId,
        bytes32 indexed attackerColony,
        bytes32 indexed defenderColony,
        uint256 attackerPower,
        uint256 defenderPower,
        bytes32 winner,
        string weatherDescription
    );

    // Shared events moved to WarfareHelper library

    // Custom errors
    error BattleNotFound();
    error InvalidStake();
    error AttackOnCooldown();
    error InvalidBattleState();
    error InvalidTokenCount();
    error SeasonNotActive();
    error RegistrationClosed();
    error BattleAlreadyResolved();
    error TokenNotInColony();
    error RateLimitExceeded();
    error CannotAttackOwnColony();
    error CannotUnregisterDuringBattle();
    error UnregistrationNotAllowed();
    error ColonyNotRegistered();
    error WarfareNotStarted();
    error WarfareEnded();
    
    error TaskForceInvalid();
    // TokensNoLongerInColony, TokenInActiveBattle, InvalidTokenCount moved to WarfareHelper

    // ============ MODIFIERS ============

    /**
     * @dev Verifies caller is the creator of the specified colony
     */
    modifier onlyColonyCreator(bytes32 colonyId) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        if (!ColonyHelper.isColonyCreator(colonyId, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony creator");
        }
        _;
    }

    /**
     * @dev Verifies current season is in registration period
     */
    modifier duringRegistrationPeriod() {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
        if (!season.active || block.timestamp < season.startTime || block.timestamp > season.registrationEnd) {
            revert RegistrationClosed();
        }
        _;
    }

    /**
     * @dev Verifies current season is in warfare period
     */
    modifier duringWarfarePeriod() {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
        if (block.timestamp < season.registrationEnd) {
            revert WarfareNotStarted();
        }
        if (block.timestamp > season.warfareEnd) {
            revert WarfareEnded();
        }
        _;
    }
    
    /**
     * @notice Register colony for current warfare season
     * @param colonyId Colony identifier to register
     * @param stake ZICO amount to stake for defensive purposes
     */
    function registerForSeason(bytes32 colonyId, uint256 stake)
        external
        whenNotPaused
        nonReentrant
        onlyColonyCreator(colonyId)
        duringRegistrationPeriod
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("registration");

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        // Rate limiting to prevent spam registrations
        if (!LibColonyWarsStorage.checkRateLimit(LibMeta.msgSender(), this.registerForSeason.selector, 3600)) {
            revert RateLimitExceeded();
        }

        uint32 currentSeason = cws.currentSeason;
        LibColonyWarsStorage.Season storage season = cws.seasons[currentSeason];
        
        // Validate stake amount within configured bounds
        if (stake < cws.config.minStakeAmount || stake > cws.config.maxStakeAmount) {
            revert InvalidStake();
        }
        
        // Prevent duplicate registrations
        if (cws.colonyWarProfiles[colonyId].registered) {
            revert InvalidBattleState();
        }
        
        // Transfer defensive stake to treasury
        address currency = hs.chargeTreasury.treasuryCurrency;
        LibFeeCollection.collectFee(
            IERC20(currency),
            LibMeta.msgSender(),
            hs.chargeTreasury.treasuryAddress,
            stake,
            "season_registration"
        );

        season.prizePool += stake / 20; 
        
        // Initialize war profile with defensive capabilities
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
        profile.defensiveStake = stake;
        profile.acceptingChallenges = true;
        profile.reputation = 0; // Start with honorable reputation
        profile.registered = true;
        
        // Add to season tracking
        season.registeredColonies.push(colonyId);
        LibColonyWarsStorage.setColonyScore(currentSeason, colonyId, 0);

        // Track user's colony - set as primary if user doesn't have one yet
        if (LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender()) == bytes32(0)) {
            LibColonyWarsStorage.setUserPrimaryColony(LibMeta.msgSender(), colonyId);
        }
        cws.userToColony[LibMeta.msgSender()] = colonyId;
        LibColonyWarsStorage.addUserSeasonColony(currentSeason, LibMeta.msgSender(), colonyId);

        emit ColonyRegisteredForSeason(colonyId, currentSeason);
    }

    /**
     * @notice Unregister colony from current season with refund
     * @param colonyId Colony to unregister
     */
    function unregisterFromSeason(bytes32 colonyId)
        external
        whenNotPaused
        nonReentrant
        onlyColonyCreator(colonyId)
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("registration");

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        // Rate limiting - once per hour to prevent spam
        if (!LibColonyWarsStorage.checkRateLimit(LibMeta.msgSender(), this.unregisterFromSeason.selector, 3600)) {
            revert RateLimitExceeded();
        }

        uint32 currentSeason = cws.currentSeason;
        LibColonyWarsStorage.Season storage season = cws.seasons[currentSeason];
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
        
        // Verify colony is registered
        if (!profile.registered) {
            revert ColonyNotRegistered();
        }
        
        // Check if unregistration is allowed (only during registration period or early warfare)
        uint32 unregistrationDeadline = season.registrationEnd + 3 days; // 3 days grace period
        if (block.timestamp > unregistrationDeadline) {
            revert UnregistrationNotAllowed();
        }
        
        // Check if colony has active battles
        if (_hasActiveBattles(colonyId, cws, currentSeason)) {
            revert CannotUnregisterDuringBattle();
        }
        
        // Check if colony is in alliance - require leaving first
        if (LibColonyWarsStorage.isUserInAlliance(LibMeta.msgSender())) {
            bytes32 _userPrimary = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());
            if (_userPrimary == colonyId) {
                revert InvalidBattleState(); // Cannot unregister primary colony while in alliance
            }
        }
        
        // Calculate refund with penalty
        uint256 originalStake = profile.defensiveStake;
        uint256 penalty = _calculateUnregistrationPenalty(originalStake, season, block.timestamp);
        uint256 refundAmount = originalStake - penalty;
        
        // Remove from season tracking
        _removeColonyFromSeason(colonyId, currentSeason, cws);
        
        // Reset colony profile
        profile.defensiveStake = 0;
        profile.acceptingChallenges = false;
        profile.registered = false;
        
        // Remove from user's primary colony if it was primary
        bytes32 userPrimary = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());
        if (userPrimary == colonyId) {
            // Set new primary from remaining colonies
            bytes32[] memory userColonies = LibColonyWarsStorage.getUserSeasonColonies(currentSeason, LibMeta.msgSender());
            bytes32 newPrimary = bytes32(0);
            
            for (uint256 i = 0; i < userColonies.length; i++) {
                if (userColonies[i] != colonyId && cws.colonyWarProfiles[userColonies[i]].registered) {
                    newPrimary = userColonies[i];
                    break;
                }
            }
            
            LibColonyWarsStorage.setUserPrimaryColony(LibMeta.msgSender(), newPrimary);
            cws.userToColony[LibMeta.msgSender()] = newPrimary;
        }
        
        // Remove from user's season colonies array
        _removeFromUserSeasonColonies(colonyId, currentSeason, LibMeta.msgSender(), cws);
        
        // Process refund
        if (refundAmount > 0) {
            LibFeeCollection.transferFromTreasury(
                LibMeta.msgSender(), 
                refundAmount, 
                "colony_unregistration_refund"
            );
        }
        
        // Penalty goes to season prize pool
        if (penalty > 0) {
            season.prizePool += penalty;
        }
        
        emit ColonyUnregisteredFromSeason(colonyId, currentSeason, refundAmount, penalty);
    }

    /**
     * @notice Initiate attack on another colony with reduced entry barriers
     * @param attackerColony Attacking colony ID
     * @param defenderColony Defending colony ID
     * @param attackCollectionIds Array of collection IDs for attacking tokens
     * @param attackTokenIds Array of token IDs for attacking tokens
     * @param stakeAmount ZICO amount to stake on the battle
     * @return battleId Unique identifier for the created battle
     */
    function initiateAttack(
        bytes32 attackerColony,
        bytes32 defenderColony,
        uint256[] memory attackCollectionIds,
        uint256[] memory attackTokenIds,
        uint256 stakeAmount
    )
        public
        whenNotPaused
        nonReentrant
        duringWarfarePeriod
        returns (bytes32 battleId)
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("battles");

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        // Rate limiting to prevent attack spam
        if (!LibColonyWarsStorage.checkRateLimit(LibMeta.msgSender(), this.initiateAttack.selector, cws.config.attackCooldown)) {
            revert RateLimitExceeded();
        }
                
        // PHASE 5 INTEGRATION: Check NAP treaty before attack
        bytes32 attackerAllianceId = LibColonyWarsStorage.getUserAllianceId(LibMeta.msgSender());
        bytes32 defenderAllianceId = LibColonyWarsStorage.getUserAllianceId(hs.colonyCreators[defenderColony]);

        if (attackerAllianceId != bytes32(0) && defenderAllianceId != bytes32(0) && attackerAllianceId != defenderAllianceId) {
            // Check if there's an active NAP treaty between alliances
            (bool hasActiveTreaty, , , ) = IAllianceEvolutionFacet(address(this)).getTreaty(attackerAllianceId, defenderAllianceId);
            if (hasActiveTreaty) {
                revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Cannot attack - NAP treaty active between alliances");
            }
        }
        
        // Basic validation checks
        if (!WarfareHelper.isAuthorizedForColony(
            attackerColony, 
            defenderColony, 
            hs.stakingSystemAddress
        )) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Colony warfare conflict or unauthorized");
        }
        
        // CONFLICT CHECK: Verify attack tokens don't belong to defender owner
        if (WarfareHelper.checkTokensForWarfareConflict(
            attackCollectionIds, 
            attackTokenIds, 
            defenderColony
        )) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Token ownership conflict with defender");
        }

        if (hs.colonyCreators[attackerColony] == hs.colonyCreators[defenderColony]) {
            revert CannotAttackOwnColony();
        }
        if (attackerColony == defenderColony) {
            revert InvalidBattleState();
        }
        if (attackCollectionIds.length != attackTokenIds.length) {
            revert InvalidTokenCount();
        }
        if (attackCollectionIds.length > cws.config.maxBattleTokens || attackCollectionIds.length < 2) {
            revert InvalidTokenCount();
        }
        
        // Verify both colonies are registered for current season
        LibColonyWarsStorage.ColonyWarProfile storage attackerProfile = cws.colonyWarProfiles[attackerColony];
        LibColonyWarsStorage.ColonyWarProfile storage defenderProfile = cws.colonyWarProfiles[defenderColony];
        
        if (!attackerProfile.registered || !defenderProfile.registered) {
            revert SeasonNotActive();
        }
        
        // Check attacker cooldown period
        if (block.timestamp < attackerProfile.lastAttackTime + cws.config.attackCooldown) {
            revert AttackOnCooldown();
        }
        
        // Validate defender is accepting challenges and stake requirements
        if (!defenderProfile.acceptingChallenges) {
            revert InvalidBattleState();
        }
        
        // IMPROVEMENT: Reduced minimum stake from 50% to 25% of defensive stake
        // This lowers the barrier to entry and allows smaller colonies to challenge larger ones
        if (stakeAmount < defenderProfile.defensiveStake / 2) {
            revert InvalidStake();
        }
        
        // Verify tokens belong to attacker colony and convert to combined IDs
        uint256[] memory attackTokens = WarfareHelper.verifyAndConvertTokens(attackCollectionIds, attackTokenIds, attackerColony, hs);
        for (uint256 i = 0; i < attackTokens.length; i++) {
            if (!LibColonyWarsStorage.isTokenAvailableForBattle(attackTokens[i])) {
                revert WarfareHelper.TokenInActiveBattle();
            }
        }    

        // Create battle snapshot for attacker tokens to prevent manipulation
        TokenStats[] memory attackerStats = IAccessoryFacet(address(this)).getTokenPerformanceStats(attackCollectionIds, attackTokenIds);
        uint256[] memory attackerPowers = new uint256[](attackerStats.length);
        for (uint256 i = 0; i < attackerStats.length; i++) {
            attackerPowers[i] = WarfareHelper.calculateTokenPower(attackerStats[i]);
        }
        
        // Generate unique battle identifier
        cws.battleCounter++;
        battleId = keccak256(abi.encodePacked(
            "battle",
            attackerColony, 
            defenderColony, 
            block.timestamp, 
            cws.battleCounter
        ));
        
        // Initialize battle instance
        LibColonyWarsStorage.BattleInstance storage battle = cws.battles[battleId];
        battle.attackerColony = attackerColony;
        battle.defenderColony = defenderColony;
        battle.attackerTokens = attackTokens;
        battle.battleStartTime = uint32(block.timestamp);
        battle.battleEndTime = uint32(block.timestamp + cws.config.battlePreparationTime + cws.config.battleDuration);
        battle.battleState = 0; // Preparation phase

        uint256 validatedStake = _validateStakeAmount(stakeAmount, defenderProfile.defensiveStake);
    
        // Use validated stake for the rest of the function
        battle.stakeAmount = validatedStake;
        battle.prizePool = validatedStake;
        
        // Check for alliance betrayal using centralized validation
        (bool isBetrayal, bytes32 betrayedAllianceId) = LibColonyWarsStorage.validateAndProcessBetrayal(
            LibMeta.msgSender(),
            attackerColony,
            defenderColony,
            "attack"
        );

        if (isBetrayal) {
            battle.isBetrayalAttack = true;
            emit WarfareHelper.BetrayalRecorded(attackerColony, betrayedAllianceId);
            emit WarfareHelper.ColonyLeftAlliance(betrayedAllianceId, attackerColony, "Attacked alliance member");
        }

        LibColonyWarsStorage.reserveTokensForBattle(attackTokens, battle.battleEndTime);
        
        // Store attacker power snapshot to prevent stat manipulation
        cws.battleSnapshots[battleId].attackerPowers = attackerPowers;
        cws.battleSnapshots[battleId].timestamp = block.timestamp;
        
        // Update attacker profile with cooldown
        attackerProfile.lastAttackTime = uint32(block.timestamp);
        
        // Transfer attack stake to treasury

        // Transfer validated amount (might be less than requested)
        address currency = hs.chargeTreasury.treasuryCurrency;
        LibFeeCollection.collectFee(
            IERC20(currency),
            LibMeta.msgSender(),
            hs.chargeTreasury.treasuryAddress,
            validatedStake, // Use validated amount
            "battle_stake"
        );

        cws.seasonBattles[cws.currentSeason].push(battleId);
        cws.colonyBattleHistory[attackerColony].push(battleId);
        cws.colonyBattleHistory[defenderColony].push(battleId);
        
        emit BattleCreated(battleId, attackerColony, defenderColony, stakeAmount);
        
        return battleId;
    }

    /**
     * @notice Cancel attack during preparation phase with balanced penalties
     * @param battleId Battle to cancel
     * @param reason Reason for cancellation
     */
    function cancelAttack(bytes32 battleId, string calldata reason) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("battles");
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        LibColonyWarsStorage.BattleInstance storage battle = cws.battles[battleId];
        if (battle.battleStartTime == 0) {
            revert BattleNotFound();
        }
        if (!ColonyHelper.isAuthorizedForColony(battle.attackerColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not attacker");
        }
        if (battle.battleState != 0) {
            revert InvalidBattleState();
        }
        
        // Calculate penalty based on game state and time
        uint32 timeElapsed = uint32(block.timestamp) - battle.battleStartTime;
        uint32 preparationTime = cws.config.battlePreparationTime;
        bool defenderCommitted = battle.defenderTokens.length > 0;
        
        uint256 penalty;
        if (!defenderCommitted && timeElapsed < preparationTime / 3) {
            penalty = 5; // Minimal penalty for early cancellation without defender response
        } else if (!defenderCommitted) {
            penalty = 15; // Moderate penalty for late cancellation without defender response
        } else if (timeElapsed < preparationTime / 2) {
            penalty = 25; // Defender prepared, but cancellation still early
        } else {
            penalty = 40; // High penalty for late cancellation after defender committed
        }
        
        uint256 penaltyAmount = (battle.stakeAmount * penalty) / 100;
        uint256 refundAmount = battle.stakeAmount - penaltyAmount;
        
        // Distribute penalty appropriately
        if (penaltyAmount > 0) {
            if (defenderCommitted) {
                // Compensate defender for wasted preparation
                address defenderCreator = hs.colonyCreators[battle.defenderColony];
                if (defenderCreator != address(0)) {
                    LibFeeCollection.transferFromTreasury(defenderCreator, penaltyAmount * 60 / 100, "preparation_compensation");
                }
                // Rest goes to system/season pool
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
            LibFeeCollection.transferFromTreasury(LibMeta.msgSender(), refundAmount, "attack_cancellation_refund");
        }
        
        // Update battle state
        battle.battleState = 3; // CANCELLED
        battle.winner = bytes32(0);
        cws.battleResolved[battleId] = true;
        
        // Apply minor reputation impact for frequent cancellations
        LibColonyWarsStorage.ColonyWarProfile storage attackerProfile = cws.colonyWarProfiles[battle.attackerColony];
        if (attackerProfile.reputation < 3) {
            attackerProfile.reputation = 3; // Mark as unreliable
        }
        
        emit BattleCancelled(battleId, battle.attackerColony, reason, refundAmount, penaltyAmount);
    }
        
    /**
     * @notice Defend against an attack by committing defense tokens
     * @param battleId Battle ID to defend
     * @param defenseCollectionIds Array of collection IDs for defending tokens
     * @param defenseTokenIds Array of token IDs for defending tokens
     */
    function defendBattle(
        bytes32 battleId, 
        uint256[] memory defenseCollectionIds,
        uint256[] memory defenseTokenIds
    ) 
        public 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("battles");
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        LibColonyWarsStorage.BattleInstance storage battle = cws.battles[battleId];
        if (battle.battleStartTime == 0) {
            revert BattleNotFound();
        }
        if (battle.battleState != 0) {
            revert InvalidBattleState();
        }
        if (block.timestamp > battle.battleStartTime + cws.config.battlePreparationTime) {
            revert InvalidBattleState();
        }
        if (defenseCollectionIds.length != defenseTokenIds.length) {
            revert InvalidTokenCount();
        }
        if (defenseCollectionIds.length > cws.config.maxBattleTokens || defenseCollectionIds.length < 2) {
            revert InvalidTokenCount();
        }
        
        // Verify caller controls the defending colony
        if (!WarfareHelper.isAuthorizedForColony(
            battle.defenderColony,
            battle.attackerColony, 
            hs.stakingSystemAddress
        )) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Colony warfare conflict or unauthorized");
        }
        
        // CONFLICT CHECK: Verify defense tokens don't belong to attacker owner
        if (WarfareHelper.checkTokensForWarfareConflict(
            defenseCollectionIds,
            defenseTokenIds,
            battle.attackerColony
        )) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Token ownership conflict with attacker");
        }
        
        // Verify tokens belong to defender colony and convert to combined IDs
        uint256[] memory defenseTokens = WarfareHelper.verifyAndConvertTokens(defenseCollectionIds, defenseTokenIds, battle.defenderColony, hs);
        for (uint256 i = 0; i < defenseTokens.length; i++) {
            if (!LibColonyWarsStorage.isTokenAvailableForBattle(defenseTokens[i])) {
                revert WarfareHelper.TokenInActiveBattle();
            }
        }
            
        // Create battle snapshot for defender tokens
        TokenStats[] memory defenderStats = IAccessoryFacet(address(this)).getTokenPerformanceStats(defenseCollectionIds, defenseTokenIds);
        uint256[] memory defenderPowers = new uint256[](defenderStats.length);
        for (uint256 i = 0; i < defenderStats.length; i++) {
            defenderPowers[i] = WarfareHelper.calculateTokenPower(defenderStats[i]);
        }
        
        // FIXED: Only activate battle and set tokens - DO NOT add defensive stake to prize pool
        // Defensive stake will be added only if defender loses during battle resolution
        battle.defenderTokens = defenseTokens;
        battle.battleState = 1; // Active phase
        
        // REMOVED: battle.prizePool += cws.colonyWarProfiles[battle.defenderColony].defensiveStake;
        // This was causing double accounting - defensive stake should only be at risk if defender loses
        
        LibColonyWarsStorage.reserveTokensForBattle(defenseTokens, battle.battleEndTime);
        
        // Finalize defender snapshot
        cws.battleSnapshots[battleId].defenderPowers = defenderPowers;
        
        // Calculate and emit total battle powers for transparency
        uint256 attackerTotal = WarfareHelper.sumArray(cws.battleSnapshots[battleId].attackerPowers);
        uint256 defenderTotal = WarfareHelper.sumArray(defenderPowers);
        
        emit BattleStatsSnapshot(battleId, attackerTotal, defenderTotal);
        
        // Update defender profile with defense timestamp
        cws.colonyWarProfiles[battle.defenderColony].lastAttackTime = uint32(block.timestamp);
    }

    
    // ============ TASK FORCE INTEGRATION ============

    /**
     * @notice Initiate attack using a Task Force
     * @param attackerColony Attacking colony ID
     * @param defenderColony Defending colony ID
     * @param taskForceId Task Force to use for attack
     * @param stakeAmount ZICO amount to stake
     * @return battleId Battle identifier
     */
    function initiateCombat(
        bytes32 attackerColony,
        bytes32 defenderColony,
        bytes32 taskForceId,
        uint256 stakeAmount
    )
        external
        duringWarfarePeriod
        returns (bytes32 battleId)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        // Validate task force
        LibColonyWarsStorage.TaskForce storage tf = cws.taskForces[taskForceId];
        if (tf.createdAt == 0 || !tf.active) revert TaskForceInvalid();
        if (tf.colonyId != attackerColony) revert TaskForceInvalid();
        if (tf.seasonId != cws.currentSeason) revert TaskForceInvalid();

        // Delegate to initiateAttack
        return initiateAttack(
            attackerColony,
            defenderColony,
            tf.collectionIds,
            tf.tokenIds,
            stakeAmount
        );
    }

    /**
     * @notice Defend battle using a Task Force
     * @param battleId Battle to defend
     * @param taskForceId Task Force to use for defense
     */
    function defendCombat(
        bytes32 battleId,
        bytes32 taskForceId
    )
        external
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.BattleInstance storage battle = cws.battles[battleId];

        if (battle.battleStartTime == 0) revert BattleNotFound();

        // Validate task force
        LibColonyWarsStorage.TaskForce storage tf = cws.taskForces[taskForceId];
        if (tf.createdAt == 0 || !tf.active) revert TaskForceInvalid();
        if (tf.colonyId != battle.defenderColony) revert TaskForceInvalid();
        if (tf.seasonId != cws.currentSeason) revert TaskForceInvalid();

        // Delegate to defendBattle
        defendBattle(battleId, tf.collectionIds, tf.tokenIds);
    }
        
    /**
     * @notice Resolve completed battle with enhanced rewards and token effects
     * @param battleId Battle identifier to resolve
     */
    function resolveBattle(bytes32 battleId) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("battles");
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        LibColonyWarsStorage.BattleInstance storage battle = cws.battles[battleId];
        if (battle.battleStartTime == 0) {
            revert BattleNotFound();
        }

        if (battle.battleState != 0 && battle.battleState != 1) {
            revert InvalidBattleState();
        }

        uint32 battleEndTime;
        if (battle.battleState == 0) {
            battleEndTime = battle.battleStartTime + cws.config.battlePreparationTime;
        } else {
            battleEndTime = battle.battleEndTime; 
        }

        if (block.timestamp < battleEndTime) {
            revert InvalidBattleState();
        }

        if (cws.battleResolved[battleId]) {
            revert BattleAlreadyResolved();
        }

        if (battle.battleState == 0) {
            battle.battleState = 1;
        }
        
        // FORFEIT VALIDATION SYSTEM - Check both sides for token movement
        bool attackerValid = WarfareHelper.validateTokensStillInColony(
            battle.attackerTokens, 
            battle.attackerColony, 
            hs
        );
        
        bool defenderValid = true;
        if (battle.defenderTokens.length > 0) {
            defenderValid = WarfareHelper.validateTokensStillInColony(
                battle.defenderTokens, 
                battle.defenderColony, 
                hs
            );
        }
        
        // Handle forfeit scenarios
        if (!attackerValid && !defenderValid) {
            battle.winner = battle.defenderColony;
            _applyForfeitPenalty(battle, cws, hs, 3); // Mutual forfeit
            emit BattleForfeit(battleId, battle.attackerColony, battle.defenderColony, "Mutual token movement", battle.stakeAmount);
            
        } else if (!attackerValid) {
            battle.winner = battle.defenderColony;
            _applyForfeitPenalty(battle, cws, hs, 1); // Attacker forfeit
            emit BattleForfeit(battleId, battle.attackerColony, battle.defenderColony, "Attacker moved tokens", battle.stakeAmount);
            
        } else if (!defenderValid) {
            battle.winner = battle.attackerColony;
            _applyForfeitPenalty(battle, cws, hs, 2); // Defender forfeit
            emit BattleForfeit(battleId, battle.defenderColony, battle.attackerColony, "Defender moved tokens", 0);
        } else {
            // Both sides valid - proceed with normal battle resolution
            bytes32 winner = _calculateBattleOutcome(battleId, battle, cws);
            battle.winner = winner;
            
            // Apply normal post-battle effects
            _applyBattleEffects(battle, winner, hs);
            
            // Distribute normal rewards
            _distributeBattleRewards(battle, cws, hs, battleId);
            
            // Update season points normally
            _updateSeasonPoints(battle, winner, cws, hs);
        }
        
        // Common cleanup for all resolution types
        battle.battleState = 2; // Completed
        cws.battleResolved[battleId] = true;
        
        // Release all tokens
        for (uint256 i = 0; i < battle.attackerTokens.length; i++) {
            LibColonyWarsStorage.releaseToken(battle.attackerTokens[i]);
        }
        if (battle.defenderTokens.length > 0) {
            for (uint256 i = 0; i < battle.defenderTokens.length; i++) {
                LibColonyWarsStorage.releaseToken(battle.defenderTokens[i]);
            }
        }
        
        // Clean up battle snapshot
        delete cws.battleSnapshots[battleId];
        
        emit BattleResolved(battleId, battle.winner, battle.prizePool);
    }

    /**
     * @notice Increase defensive stake for current season
     * @param colonyId Colony to increase stake for
     * @param additionalAmount ZICO amount to add to stake
     */
    function increaseDefensiveStake(bytes32 colonyId, uint256 additionalAmount)
        external
        whenNotPaused
        nonReentrant
        onlyColonyCreator(colonyId)
        duringRegistrationPeriod
    {
        LibColonyWarsStorage.requireInitialized();

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
        if (!profile.registered) {
            revert SeasonNotActive();
        }
        
        // Validate new total doesn't exceed maximum
        uint256 newTotal = profile.defensiveStake + additionalAmount;
        if (newTotal > cws.config.maxStakeAmount) {
            revert InvalidStake();
        }
        
        if (additionalAmount == 0) {
            revert InvalidStake();
        }
        
        // Transfer additional stake
        address currency = hs.chargeTreasury.treasuryCurrency;
        LibFeeCollection.collectFee(
            IERC20(currency),
            LibMeta.msgSender(),
            hs.chargeTreasury.treasuryAddress,
            additionalAmount,
            "stake_increase"
        );
        
        // Update profile
        profile.defensiveStake = newTotal;
        
        // Add to season prize pool (5% of increase)
        season.prizePool += additionalAmount / 20;
        emit StakeChanged(colonyId, newTotal, true, additionalAmount);
    }

    /**
     * @notice Decrease defensive stake (with limitations)
     * @param colonyId Colony to decrease stake for
     * @param reductionAmount ZICO amount to remove from stake
     */
    function decreaseDefensiveStake(bytes32 colonyId, uint256 reductionAmount)
        external
        whenNotPaused
        nonReentrant
        onlyColonyCreator(colonyId)
        duringRegistrationPeriod
    {
        LibColonyWarsStorage.requireInitialized();

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];

        // Rate limiting - once per day to prevent manipulation
        if (!LibColonyWarsStorage.checkRateLimit(LibMeta.msgSender(), this.decreaseDefensiveStake.selector, 86400)) {
            revert RateLimitExceeded();
        }

        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
        if (!profile.registered) {
            revert SeasonNotActive();
        }
        
        if (reductionAmount == 0 || reductionAmount > profile.defensiveStake) {
            revert InvalidStake();
        }
        
        // Validate new total meets minimum requirements
        uint256 newTotal = profile.defensiveStake - reductionAmount;
        if (newTotal < cws.config.minStakeAmount) {
            revert InvalidStake();
        }
        
        // Check if colony has active battles - cannot reduce during active battles
        bytes32[] storage seasonBattles = cws.seasonBattles[season.seasonId];
        
        for (uint256 i = 0; i < seasonBattles.length; i++) {
            LibColonyWarsStorage.BattleInstance storage battle = cws.battles[seasonBattles[i]];
            if ((battle.attackerColony == colonyId || battle.defenderColony == colonyId) && 
                battle.battleState < 2 && !cws.battleResolved[seasonBattles[i]]) {
                revert InvalidBattleState();
            }
        }
        
        // Apply penalty for stake reduction (10% penalty)
        uint256 penalty = reductionAmount / 10;
        uint256 refundAmount = reductionAmount - penalty;
        
        // Update profile
        profile.defensiveStake = newTotal;
        
        // Transfer refund to colony owner
        LibFeeCollection.transferFromTreasury(LibMeta.msgSender(), refundAmount, "stake_reduction");
        
        // Penalty goes to season prize pool
        season.prizePool += penalty;
        
        emit StakeChanged(colonyId, newTotal, false, reductionAmount);
    }

    /**
     * @notice Check if tokens are available for battles (public view function)
     * @param collectionIds Array of collection IDs
     * @param tokenIds Array of token IDs
     * @return available Array of bools - true if token is available for battle
     */
    function canStartBattle(
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds
    )
        external
        view
        returns (bool[] memory available)
    {
        if (collectionIds.length != tokenIds.length) {
            revert InvalidTokenCount();
        }
        
        available = new bool[](collectionIds.length);
        
        for (uint256 i = 0; i < collectionIds.length; i++) {
            uint256 combinedId = PodsUtils.combineIds(collectionIds[i], tokenIds[i]);
            available[i] = LibColonyWarsStorage.isTokenAvailableForBattle(combinedId);
        }
        
        return available;
    }
        
    // View functions

    function getColonyWarProfile(bytes32 colonyId) external view returns (LibColonyWarsStorage.ColonyWarProfile memory) {
        return LibColonyWarsStorage.colonyWarsStorage().colonyWarProfiles[colonyId];
    }
    
    function getBattleDetails(bytes32 battleId) external view returns (LibColonyWarsStorage.BattleInstance memory) {
        return LibColonyWarsStorage.colonyWarsStorage().battles[battleId];
    }
    
    function getBattleSnapshot(bytes32 battleId) external view returns (uint256[] memory attackerPowers, uint256[] memory defenderPowers) {
        LibColonyWarsStorage.BattleSnapshot storage snapshot = LibColonyWarsStorage.colonyWarsStorage().battleSnapshots[battleId];
        return (snapshot.attackerPowers, snapshot.defenderPowers);
    }

    /**
     * @notice Get current stake information for colony
     * @param colonyId Colony to check
     * @return currentStake Current defensive stake amount
     * @return canIncrease Whether stake can be increased
     * @return canDecrease Whether stake can be decreased
     * @return maxIncrease Maximum amount that can be added
     * @return maxDecrease Maximum amount that can be removed
     */
    function getDefensiveStakeInfo(bytes32 colonyId) 
        external 
        view 
        returns (
            uint256 currentStake,
            bool canIncrease,
            bool canDecrease,
            uint256 maxIncrease,
            uint256 maxDecrease
        ) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
        
        currentStake = profile.defensiveStake;
        
        if (!profile.registered) {
            return (currentStake, false, false, 0, 0);
        }
        
        // Check increase capability
        maxIncrease = cws.config.maxStakeAmount > currentStake ? 
            cws.config.maxStakeAmount - currentStake : 0;
        canIncrease = maxIncrease > 0;
        
        // Check decrease capability
        maxDecrease = currentStake > cws.config.minStakeAmount ? 
            currentStake - cws.config.minStakeAmount : 0;
        canDecrease = maxDecrease > 0 && !_hasActiveBattles(colonyId, cws, cws.currentSeason);
        
        return (currentStake, canIncrease, canDecrease, maxIncrease, maxDecrease);
    }
  
    // Internal functions

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

    function _getTopColony(uint32 seasonId) internal view returns (bytes32 top) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Season storage s = cws.seasons[seasonId];
        uint256 maxScore = 0;
        
        for (uint256 i = 0; i < s.registeredColonies.length; i++) {
            bytes32 colony = s.registeredColonies[i];
            uint256 score = LibColonyWarsStorage.getColonyScore(seasonId, colony);
            if (score > maxScore) {
                maxScore = score;
                top = colony;
            }
        }
    }
    
    /**
     * @notice Calculate battle outcome with weather effects and enhanced randomness
     * @param battleId Battle identifier
     * @param battle Battle instance
     * @return winner Winning colony ID
     */
    function _calculateBattleOutcome(
        bytes32 battleId,
        LibColonyWarsStorage.BattleInstance storage battle,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal returns (bytes32 winner) {
        LibColonyWarsStorage.BattleSnapshot storage snapshot = cws.battleSnapshots[battleId];

        // 1. Calculate attacker power with bonuses
        uint256 attackerPower = WarfareHelper.sumArray(snapshot.attackerPowers);

        // Apply Squad Staking synergy bonus for attacker
        attackerPower = WarfareHelper.applyTeamSynergyBonus(battle.attackerColony, attackerPower, cws);
        uint256 defenderStake = cws.colonyWarProfiles[battle.defenderColony].defensiveStake;
        uint256 stakeBonus = _calculateStakeBonus(battle.stakeAmount, defenderStake);
        if (stakeBonus > 0 && attackerPower <= type(uint256).max / stakeBonus) {
            attackerPower += (attackerPower * stakeBonus) / 100;
        } else if (stakeBonus > 0) {
            attackerPower += (attackerPower / 100) * stakeBonus;
        }

        uint256 attackerBonus = WarfareHelper.calculateAdditionalBattlePower(battle.attackerColony, attackerPower, true, cws);
        attackerPower += attackerBonus;

        uint256 attackerPenalty = WarfareHelper.calculateDebtPenalty(battle.attackerColony, attackerPower, cws);
        attackerPower = attackerPower > attackerPenalty ? attackerPower - attackerPenalty : attackerPower / 2;

        attackerPower += (attackerPower * 20) / 100; // Base 20% attack bonus

        uint8 consecutiveLosses = _getValidConsecutiveLosses(
            battle.attackerColony, 
            cws.currentSeason, 
            cws
        );
        if (consecutiveLosses > 0) {
            uint256 furyBonus = consecutiveLosses * 15;
            if (furyBonus > 75) furyBonus = 75;
            attackerPower += (attackerPower * furyBonus) / 100;
        }

        // 2. Calculate defender power (unchanged)
        uint256 defenderPower = _calculateDefenderPower(
            battle.defenderColony,
            snapshot.defenderPowers,
            cws,
            false,
            battleId
        );
        
        bool hasActiveDefense = battle.defenderTokens.length > 0;
        uint256 activeDefenseBonus = WarfareHelper.calculateActiveDefenseBonus(
            battle.stakeAmount,
            defenderStake,
            hasActiveDefense
        );
        defenderPower += (defenderPower * activeDefenseBonus) / 100;

        uint256 defenderPenalty = WarfareHelper.calculateDebtPenalty(battle.defenderColony, defenderPower, cws);
        defenderPower = defenderPenalty > defenderPower ? defenderPower / 2 : defenderPower - defenderPenalty;

        uint8 scoutBonus = _getScoutingBonus(battle.attackerColony, battle.defenderColony, 0);
        if (scoutBonus > 0) {
            attackerPower += (attackerPower * scoutBonus) / 100;
        }
        
        // 3. Generate battle randomness
        uint256 randomness = uint256(keccak256(abi.encodePacked(
            battle.attackerColony,
            battle.defenderColony,
            block.timestamp,
            block.prevrandao
        ))) % 100;
        
        // 4. APPLY WEATHER EFFECTS FIRST
        string memory weatherDesc;
        (attackerPower, defenderPower, weatherDesc) = _applyWeatherEffects(
            attackerPower, 
            defenderPower, 
            randomness
        );
        
        // 5. APPLY MODERATE RANDOMNESS (on top of weather)
        // Reduced swing factor since weather already adds variation
        uint256 swingFactor = 3 + (randomness % 8); // 3-10% (less than pure randomness version)
        
        if (randomness < 45) {
            if (attackerPower <= type(uint256).max / swingFactor) {
                attackerPower += (attackerPower * swingFactor) / 100;
            }
        } else if (randomness > 55) {
            if (defenderPower <= type(uint256).max / swingFactor) {
                defenderPower += (defenderPower * swingFactor) / 100;
            }
        }

        bytes32 loser = attackerPower > defenderPower ? battle.defenderColony : battle.attackerColony;
        winner = attackerPower > defenderPower ? battle.attackerColony : battle.defenderColony;

        // 7. Update win streaks
        WarfareHelper.updateWinStreaks(winner, loser, cws);
        _updateSeasonConsecutiveLosses(winner, loser, cws.currentSeason, cws);

        // 8. Trigger battle achievements for winner
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        _triggerBattleAchievements(winner, cws, hs);

        emit BattleOutcome(battleId, battle.attackerColony, battle.defenderColony, attackerPower, defenderPower, winner, weatherDesc);
        return winner;
    }

    /**
     * @notice Apply post-battle effects to participating tokens
     * @param battle Battle instance
     * @param winner Winning colony ID
     * @param hs Henomorphs storage reference
     */
    function _applyBattleEffects(
        LibColonyWarsStorage.BattleInstance storage battle,
        bytes32 winner,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) internal {
        // Apply effects to attacker tokens
        _applyTokenBattleEffects(battle.attackerTokens, winner == battle.attackerColony, hs);
        
        // Apply effects to defender tokens  
        _applyTokenBattleEffects(battle.defenderTokens, winner == battle.defenderColony, hs);
    }

    /**
     * @notice Apply battle effects to specific token array
     * @param tokens Array of combined token IDs
     * @param isWinner Whether these tokens are on the winning side
     * @param hs Henomorphs storage reference
     */
    function _applyTokenBattleEffects(
        uint256[] storage tokens,
        bool isWinner,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) internal {
        uint8 consumptionMultiplier = isWinner ? 10 : 5;  // Colony: 10% vs 20% charge consumption
        uint8 fatigueMultiplier = isWinner ? 5 : 15;      // Colony: 5 vs 15 fatigue increase
        WarfareHelper.applyTokenBattleEffects(tokens, isWinner, consumptionMultiplier, fatigueMultiplier, hs);
    }

    /**
     * @notice Updated reward distribution with adaptive stake loss
     * @dev Replace the existing _distributeBattleRewards function with this
     */
    function _distributeBattleRewards(
        LibColonyWarsStorage.BattleInstance storage battle,
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        LibHenomorphsStorage.HenomorphsStorage storage hs,
        bytes32 /* battleId */
    ) internal {
        if (battle.prizePool == 0) return;
        
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
        
        // 5% to season pool (always succeeds)
        uint256 seasonFee = battle.prizePool / 20;
        season.prizePool += seasonFee;
        
        // Work with remaining pool from attack stake only
        uint256 remaining = battle.prizePool - seasonFee;
        battle.prizePool = 0; // Zero immediately after reading
        
        if (battle.winner == battle.attackerColony) {
            _handleAttackerVictory(battle, cws, hs, remaining, season);
        } else {
            _handleDefenderVictory(battle, cws, hs, remaining, season);
        }
    }

    /**
     * @notice FIX 3: Corrected attacker victory handling with proper defensive stake loss
     * @dev Only now do we consume defensive stake when defender actually loses
     */
    function _handleAttackerVictory(
        LibColonyWarsStorage.BattleInstance storage battle,
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        LibHenomorphsStorage.HenomorphsStorage storage hs,
        uint256 available,
        LibColonyWarsStorage.Season storage season
    ) internal {
        LibColonyWarsStorage.ColonyWarProfile storage defenderProfile = cws.colonyWarProfiles[battle.defenderColony];
        
        // FIXED: Calculate defensive stake loss and ADD it to available rewards
        uint256 stakeLoss = _calculateStakeLoss(
            battle.defenderTokens.length > 0, // hasDefended - whether defender actively participated
            0, 0, // power parameters not needed for this calculation
            defenderProfile.defensiveStake
        );
        
        // Actually consume defensive stake and add to prize pool
        if (stakeLoss > 0 && defenderProfile.defensiveStake >= stakeLoss) {
            defenderProfile.defensiveStake -= stakeLoss;
            cws.colonyLosses[battle.defenderColony] += stakeLoss;
            available += stakeLoss; // ADD defensive stake loss to available rewards
        }
        
        // Now distribute the total available amount (attack stake + defensive stake loss)
        // 90% to winner, 10% to system
        uint256 winnerAmount = (available * 90) / 100;
        
        address winnerCreator = hs.colonyCreators[battle.winner];
        bool transferSuccess = _safeTransfer(winnerCreator, winnerAmount, "attack_victory");
        
        if (!transferSuccess) {
            // Failed transfer - add to season pool
            season.prizePool += winnerAmount;
        }
        
        // Remaining 10% always goes to season
        season.prizePool += available - winnerAmount;
    }

    /**
     * @notice Corrected defender victory handling - no defensive stake loss
     * @dev When defender wins, their defensive stake remains intact
     */
    function _handleDefenderVictory(
        LibColonyWarsStorage.BattleInstance storage battle,
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        LibHenomorphsStorage.HenomorphsStorage storage hs,
        uint256 available,
        LibColonyWarsStorage.Season storage season
    ) internal {
        // FIXED: When defender wins, NO defensive stake is lost or consumed
        // Only the attacker's stake is distributed
        
        // 70% defender, 20% attacker refund, 10% system
        uint256 defenderAmount = (available * 70) / 100;
        uint256 refundAmount = (available * 20) / 100;
        uint256 systemAmount = available - defenderAmount - refundAmount;
        
        // Pay defender
        address defenderCreator = hs.colonyCreators[battle.winner];
        if (!_safeTransfer(defenderCreator, defenderAmount, "defense_victory")) {
            systemAmount += defenderAmount;
        }
        
        // Refund attacker  
        address attackerCreator = hs.colonyCreators[battle.attackerColony];
        if (!_safeTransfer(attackerCreator, refundAmount, "partial_refund")) {
            systemAmount += refundAmount;
            // Track full loss if refund failed
            cws.colonyLosses[battle.attackerColony] += battle.stakeAmount;
        } else {
            // Track partial loss
            cws.colonyLosses[battle.attackerColony] += battle.stakeAmount - refundAmount;
        }
        
        // System amount to season pool
        season.prizePool += systemAmount;
        
        // IMPORTANT: Defensive stake remains unchanged when defender wins
        // No modification to defenderProfile.defensiveStake
    }

    // 4. ADD safe transfer helper
    function _safeTransfer(address recipient, uint256 amount, string memory reason) 
        internal 
        returns (bool success) 
    {
        if (recipient == address(0) || amount == 0) {
            return false;
        }
        
        // Check treasury balance before transfer
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        address currency = hs.chargeTreasury.treasuryCurrency;
        uint256 treasuryBalance = IERC20(currency).balanceOf(hs.chargeTreasury.treasuryAddress);
        
        if (treasuryBalance < amount) {
            return false; // Insufficient treasury funds
        }
        
        // Call LibFeeCollection.transferFromTreasury (internal call - no try-catch needed)
        LibFeeCollection.transferFromTreasury(recipient, amount, reason);
        return true;
    }

    /**
     * @notice Calculate defensive stake loss based on battle participation and power ratio
     * @param hasDefended Whether defender actively participated with tokens
     * @param attackerPower Total attacker power
     * @param defenderPower Total defender power
     * @param defensiveStake Current defensive stake amount
     * @return stakeLoss Amount of defensive stake to lose
     * @notice FIX 5: Updated stake loss calculation for clarity
     * @dev This function now clearly defines when and how much defensive stake is lost
     */
    function _calculateStakeLoss(
        bool hasDefended,
        uint256 attackerPower,
        uint256 defenderPower,
        uint256 defensiveStake
    ) internal pure returns (uint256 stakeLoss) {
        if (defensiveStake == 0) return 0;
        
        // CLARIFIED: This function is only called when DEFENDER LOSES
        // It determines how much of their defensive stake they forfeit
        
        // Case 1: Didn't defend actively (no tokens committed) - lose 20%
        if (!hasDefended) {
            return (defensiveStake * 20) / 100;
        }
        
        // Case 2: Defended actively but still lost - variable loss based on how badly outmatched
        if (defenderPower == 0) return (defensiveStake * 15) / 100; // Edge case
        
        // Calculate how much stronger attacker was (100 = equal, 200 = 2x stronger)
        uint256 powerRatio = defenderPower == 0 ? 500 : (attackerPower * 100) / defenderPower;
                
        uint256 lossPercentage;
        if (powerRatio >= 200) {
            lossPercentage = 20; // Attacker 2x+ stronger - maximum loss
        } else if (powerRatio >= 150) {
            lossPercentage = 15; // Attacker 1.5x stronger  
        } else if (powerRatio >= 120) {
            lossPercentage = 10; // Attacker 1.2x stronger
        } else if (powerRatio >= 105) {
            lossPercentage = 5;  // Attacker slightly stronger - minimal loss
        } else {
            lossPercentage = 0;  // Should not happen (defender was stronger but somehow lost)
        }
        
        return (defensiveStake * lossPercentage) / 100;
    }
    
    /**
     * @notice Update season points and apply raid bonus for successful attacks
     * @dev Provides immediate micro-incentive for successful attackers
     * @param battle Battle instance
     * @param winner Winning colony ID
     * @param cws Colony wars storage reference
     */
    function _updateSeasonPoints(
        LibColonyWarsStorage.BattleInstance storage battle,
        bytes32 winner,
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        LibHenomorphsStorage.HenomorphsStorage storage /* hs */
    ) internal {
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
        
        // Determine if defense was active
        bool hasActiveDefense = battle.defenderTokens.length > 0;
        
        // UPDATED: Use enhanced risk-based points calculation with activity consideration
        bytes32 loser = winner == battle.attackerColony ? battle.defenderColony : battle.attackerColony;

        (uint256 winnerPoints, uint256 loserPoints) = _calculateRiskBasedPoints(
            battle.stakeAmount,
            cws.colonyWarProfiles[battle.defenderColony].defensiveStake,
            winner == battle.attackerColony,
            hasActiveDefense,
            battle.attackerColony,  // Pass attacker colony ID
            battle.defenderColony   // Pass defender colony ID
        );

        LibColonyWarsStorage.addColonyScore(season.seasonId, winner, winnerPoints);
        LibColonyWarsStorage.addColonyScore(season.seasonId, loser, loserPoints);
    }

    /**
     * @notice Calculate unregistration penalty based on timing
     */
    function _calculateUnregistrationPenalty(
        uint256 originalStake, 
        LibColonyWarsStorage.Season storage season, 
        uint256 currentTime
    ) internal view returns (uint256 penalty) {
        // No penalty during registration period
        if (currentTime <= season.registrationEnd) {
            return 0;
        }
        
        // Progressive penalty after registration ends
        uint256 timeAfterRegistration = currentTime - season.registrationEnd;
        
        if (timeAfterRegistration <= 1 days) {
            penalty = originalStake * 5 / 100;  // 5% penalty first day
        } else if (timeAfterRegistration <= 2 days) {
            penalty = originalStake * 10 / 100; // 10% penalty second day
        } else {
            penalty = originalStake * 15 / 100; // 15% penalty third day
        }
        
        return penalty;
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

    /**
     * @notice Remove colony from user's season colonies array
     */
    function _removeFromUserSeasonColonies(
        bytes32 colonyId,
        uint32 seasonId,
        address user,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        bytes32[] storage userColonies = cws.userSeasonColonies[seasonId][user];
        
        // Find and remove colony from user's season colonies
        for (uint256 i = 0; i < userColonies.length; i++) {
            if (userColonies[i] == colonyId) {
                userColonies[i] = userColonies[userColonies.length - 1];
                userColonies.pop();
                break;
            }
        }
    }

    /**
     * @notice Unified defender power calculation with primary colony auto-defense
     * @dev Auto-defense only works with defending user's registered primary colony
     * @param defenderColony Colony being defended
     * @param defenderTokenPowers Array of manually selected token powers (empty if no active defense)
     * @param cws Colony wars storage reference
     * @param isTerritory Whether this is territory siege
     * @param battleId Battle ID for event emission (pass bytes32(0) if not available)
     * @return totalDefenderPower Combined defensive power
     */
    function _calculateDefenderPower(
        bytes32 defenderColony,
        uint256[] memory defenderTokenPowers,
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        bool isTerritory,
        bytes32 battleId
    ) internal returns (uint256 totalDefenderPower) {
        
        uint256 tokenPower = 0;
        uint256 stakePower = 0;
        
        // 1. Calculate TOKEN POWER first (core defense)
        if (defenderTokenPowers.length > 0) {
            // ACTIVE DEFENSE: Full token power + moderate bonus
            tokenPower = WarfareHelper.sumArray(defenderTokenPowers);
            
            // Home advantage only on token power (not stake)
            uint256 homeBonus = isTerritory ? 4 : 6; // 4% territories, 6% colonies
            tokenPower += (tokenPower * homeBonus) / 100;
            
        } else if (cws.config.enableAutoDefense) {
            // AUTO DEFENSE: Heavily penalized
            LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
            address defenderOwner = hs.colonyCreators[defenderColony];

            if (defenderOwner != address(0) && _isUserRecentlyActive(defenderOwner, cws)) {
                uint256[] memory autoTokens = WarfareHelper.getRandomDefenseTokens(
                    defenderColony,
                    defenderOwner,
                    cws.config.autoDefenseTokenCount,
                    cws,
                    hs
                );

                if (autoTokens.length > 0) {
                    // MAJOR PENALTY: 85% reduction for auto-defense
                    tokenPower = WarfareHelper.calculateAutoDefensePower(autoTokens, 85);

                    emit WarfareHelper.AutoDefenseTriggered(
                        battleId, defenderColony, defenderOwner, autoTokens, tokenPower, 85
                    );
                }
            }
            // NO home advantage for auto-defense
        }
        
        // 2. Calculate LIMITED STAKE POWER (economic defense only)
        LibColonyWarsStorage.ColonyWarProfile storage defenderProfile = cws.colonyWarProfiles[defenderColony];
        if (defenderProfile.defensiveStake > 0) {
            // Stake power is CAPPED at 50% of token power (or minimum if no tokens)
            uint256 maxStakePower = tokenPower > 0 ? tokenPower / 2 : 50;
            stakePower = defenderProfile.defensiveStake / 25; // 1 ZICO = 0.04 power (reduced from 0.1)
            
            if (stakePower > maxStakePower) {
                stakePower = maxStakePower;
            }
        }
        
        // 3. Base total (no exponential growth)
        totalDefenderPower = tokenPower + stakePower;
        
        // 3.5. Apply Squad Staking synergy bonus for defender
        totalDefenderPower = WarfareHelper.applyTeamSynergyBonus(defenderColony, totalDefenderPower, cws);
        
        // 4. Alliance bonuses CAPPED at 30% of base power
        uint256 allianceBonus = _applyAllianceBonuses(totalDefenderPower, defenderColony, isTerritory);
        totalDefenderPower += allianceBonus;
        
        return totalDefenderPower;
    }

    /**
     * @notice Apply alliance bonuses to defender power
     * @param basePower Base defensive power before alliance bonuses
     * @param defenderColony Defending colony
     * @param isTerritory Whether this is territory siege (affects bonus scaling)
     * @return bonusAmount Power after alliance bonuses
     */
    function _applyAllianceBonuses(
        uint256 basePower,
        bytes32 defenderColony,
        bool isTerritory
    ) internal view returns (uint256 bonusAmount) {
        
        try IAllianceWarsFacet(address(this)).getAllianceDefensiveBonuses(defenderColony) 
            returns (bool hasAlliance, uint256 defensiveBonus, uint256 reinforcementTokens, uint256 sharedStakeBonus) 
        {
            if (!hasAlliance) {
                return 0; // No alliance = no bonus
            }
            
            uint256 totalAllianceBonus = 0;
            
            // 1. Percentage bonus CAPPED at 15%
            uint256 percentBonus = (basePower * defensiveBonus) / 100;
            if (percentBonus > (basePower * 15) / 100) {
                percentBonus = (basePower * 15) / 100;
            }
            totalAllianceBonus += percentBonus;
            
            // 2. Reinforcement tokens CAPPED
            uint256 reinforcementPower = isTerritory ? 
                reinforcementTokens * 50 : reinforcementTokens * 75;
            if (reinforcementPower > (basePower * 20) / 100) {
                reinforcementPower = (basePower * 20) / 100;
            }
            totalAllianceBonus += reinforcementPower;
            
            // 3. Shared stake bonus CAPPED
            uint256 stakeBonusPower = isTerritory ?
                (sharedStakeBonus * 8) / 100 : (sharedStakeBonus * 12) / 100;
            if (stakeBonusPower > (basePower * 10) / 100) {
                stakeBonusPower = (basePower * 10) / 100;
            }
            totalAllianceBonus += stakeBonusPower;
            
            // 4. HARD CAP: Total alliance bonus max 30%
            if (totalAllianceBonus > (basePower * 30) / 100) {
                totalAllianceBonus = (basePower * 30) / 100;
            }
            
            return totalAllianceBonus; // FIXED: Return only bonus amount
            
        } catch {
            // Fallback bonus only for confirmed alliance members
            LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
            address defenderOwner = hs.colonyCreators[defenderColony];
            
            if (defenderOwner != address(0) && LibColonyWarsStorage.isUserInAlliance(defenderOwner)) {
                if (isTerritory) {
                    return (basePower * 6) / 100; // FIXED: Return only bonus, reduced from 8%
                } else {
                    return (basePower * 8) / 100; // FIXED: Return only bonus, reduced from 12%
                }
            }
            
            return 0; // No alliance = no bonus
        }
    }

    /**
     * @notice Enhanced stake validation with maximum cap to prevent economic dominance
     * @dev Replaces existing stake validation in initiateAttack function
     */
    function _validateStakeAmount(
        uint256 stakeAmount, 
        uint256 defenderStake
    ) internal pure returns (uint256 validatedStake) {
        // Minimum stake: 50% of defender's stake (existing logic)
        uint256 minStake = defenderStake / 2;
        if (stakeAmount < minStake) {
            revert InvalidStake();
        }
        
        // NEW: Maximum stake cap to prevent economic overwhelming
        // Cap at 4x defender's stake for balanced gameplay
        uint256 maxStake = defenderStake * 4;
        if (stakeAmount > maxStake) {
            // Auto-adjust to maximum allowed instead of reverting
            // This prevents users from accidentally failing transactions
            validatedStake = maxStake;
        } else {
            validatedStake = stakeAmount;
        }
        
        return validatedStake;
    }

    /**
    * @notice Calculate progressive stake bonus with diminishing returns
    * @dev Replaces fixed 30% bonus with scaled bonus based on stake ratio
    * @param stakeAmount Attacker's actual stake amount
    * @param defenderStake Defender's defensive stake
    * @return bonusPercentage Percentage bonus to apply to attacker power (15-45%)
    */
    function _calculateStakeBonus(uint256 stakeAmount, uint256 defenderStake) 
        internal pure returns (uint256 bonusPercentage) {

        if (defenderStake == 0) return 15; // Safe fallback
        
        uint256 stakeRatio = (stakeAmount * 100) / defenderStake;
        
        if (stakeRatio < 50) {
            bonusPercentage = 20; // Minimum bonus
        } else if (stakeRatio <= 100) {
            bonusPercentage = 20 + ((stakeRatio - 50) * 20) / 50;
        } else if (stakeRatio <= 200) {
            bonusPercentage = 40 + ((stakeRatio - 100) * 25) / 100;
        } else if (stakeRatio <= 300) {
            bonusPercentage = 65 + ((stakeRatio - 200) * 20) / 100;
        } else {
            bonusPercentage = 85 + ((stakeRatio - 300) * 10) / 100;
            if (bonusPercentage > 95) bonusPercentage = 95;
        }
        
        return bonusPercentage;
    }

    /**
     * @notice Get scouting bonus for colony attacks
     */
    function _getScoutingBonus(bytes32 attackerColony, bytes32 targetColony, uint256 territoryId) 
        internal 
        view 
        returns (uint8 bonus) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        // Territory-specific scouting (preferred)
        if (territoryId > 0 && block.timestamp <= cws.scoutedTerritories[attackerColony][territoryId]) {
            return 8; // 8% bonus for territory raids/sieges
        }
        
        // Colony-wide scouting (fallback)  
        if (block.timestamp <= cws.scoutedTargets[attackerColony][targetColony]) {
            return 5; // 5% bonus for colony battles
        }
        
        return 0;
    }
    
    /**
    * @notice Check if user was recently active (for auto-defense eligibility)
    * @param user User address to check
    * @param cws Colony wars storage reference
    * @return isActive True if user performed any action in last 48 hours
    */
    function _isUserRecentlyActive(
        address user,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal view returns (bool isActive) {
        if (user == address(0)) return false;
        
        uint256 activityWindow = 48 * 3600; // 48 hours
        
        // Check recent Colony Wars actions
        bytes4[7] memory selectors = [
            this.registerForSeason.selector,
            this.initiateAttack.selector,
            this.defendBattle.selector,
            this.increaseDefensiveStake.selector,
            this.decreaseDefensiveStake.selector,
            this.resolveBattle.selector,
            this.cancelAttack.selector
        ];
        
        for (uint256 i = 0; i < selectors.length; i++) {
            if (block.timestamp < cws.lastActionTime[user][selectors[i]] + activityWindow) {
                return true;
            }
        }
        
        // Check colony activity using available HenomorphsStorage data
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Get user's colonies and check their activity
        bytes32[] memory userColonies = hs.userColonies[user];
        for (uint256 i = 0; i < userColonies.length; i++) {
            bytes32 colonyId = userColonies[i];
            uint256 lastActiveTime = hs.colonyLastActiveTime[colonyId];
            
            if (block.timestamp < lastActiveTime + activityWindow) {
                return true;
            }
        }
        
        return false;
    }
    
    function _getValidConsecutiveLosses(
        bytes32 colonyId, 
        uint32 seasonId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal view returns (uint8) {
        uint8 losses = cws.seasonColonyLosses[seasonId][colonyId];
        uint32 lastLoss = cws.seasonLastLossTime[seasonId][colonyId];
        
        // Reset po 48h bez bitew w tym sezonie
        if (block.timestamp > lastLoss + 48 hours) {
            return 0;
        }
        
        return losses > 5 ? 5 : losses; // Cap na 5 porażek
    }

    function _updateSeasonConsecutiveLosses(
        bytes32 winner, 
        bytes32 loser, 
        uint32 seasonId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        // Winner - reset losses w tym sezonie
        cws.seasonColonyLosses[seasonId][winner] = 0;
        
        // Loser - increment losses w tym sezonie
        cws.seasonColonyLosses[seasonId][loser] += 1;
        cws.seasonLastLossTime[seasonId][loser] = uint32(block.timestamp);
    }

    /**
     * @notice Apply penalty for forfeit scenarios
     * @param battle Battle instance
     * @param forfeitType 1=attacker forfeit, 2=defender forfeit, 3=mutual forfeit
     */
    function _applyForfeitPenalty(
        LibColonyWarsStorage.BattleInstance storage battle,
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        LibHenomorphsStorage.HenomorphsStorage storage hs,
        uint8 forfeitType
    ) internal {
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
        uint256 prizePool = battle.prizePool;
        
        // Check activity levels for both parties
        address attackerOwner = hs.colonyCreators[battle.attackerColony];
        address defenderOwner = hs.colonyCreators[battle.defenderColony];
        
        bool isAttackerActive = _isUserRecentlyActive(attackerOwner, cws);
        bool isDefenderActive = _isUserRecentlyActive(defenderOwner, cws);
        
        if (forfeitType == 1) {
            // ATTACKER FORFEIT
            uint256 defenderCompensation = prizePool / 2;
            uint256 systemPenalty = prizePool - defenderCompensation;
            
            address defenderCreator = hs.colonyCreators[battle.defenderColony];
            if (!_safeTransfer(defenderCreator, defenderCompensation, "forfeit_compensation")) {
                systemPenalty += defenderCompensation;
            }
            
            cws.colonyLosses[battle.attackerColony] += battle.stakeAmount;
            season.prizePool += systemPenalty;
            
            // Activity-based reputation penalty
            LibColonyWarsStorage.ColonyWarProfile storage attackerProfile = cws.colonyWarProfiles[battle.attackerColony];
            if (isAttackerActive) {
                if (attackerProfile.reputation < 5) attackerProfile.reputation = 5; // Active player forfeit
            } else {
                if (attackerProfile.reputation < 6) attackerProfile.reputation = 6; // Inactive player forfeit (worse)
            }
            
            // Activity-based scoring for forfeit
            uint256 defenderPoints = isDefenderActive ? 60 : 40; // Active defender gets more points
            LibColonyWarsStorage.addColonyScore(season.seasonId, battle.defenderColony, defenderPoints);
            LibColonyWarsStorage.addColonyScore(season.seasonId, battle.attackerColony, 0);
            
        } else if (forfeitType == 2) {
            // DEFENDER FORFEIT
            address attackerCreator = hs.colonyCreators[battle.attackerColony];
            if (!_safeTransfer(attackerCreator, prizePool, "forfeit_victory")) {
                season.prizePool += prizePool;
            }
            
            // Apply defensive stake loss
            LibColonyWarsStorage.ColonyWarProfile storage defenderProfile = cws.colonyWarProfiles[battle.defenderColony];
            uint256 stakePenalty = defenderProfile.defensiveStake / 4;
            if (defenderProfile.defensiveStake >= stakePenalty) {
                defenderProfile.defensiveStake -= stakePenalty;
                cws.colonyLosses[battle.defenderColony] += stakePenalty;
            }
            
            // Activity-based reputation penalty
            if (isDefenderActive) {
                if (defenderProfile.reputation < 4) defenderProfile.reputation = 4; // Active player forfeit
            } else {
                if (defenderProfile.reputation < 5) defenderProfile.reputation = 5; // Inactive player forfeit (worse)
            }
            
            // Activity-based scoring for forfeit
            uint256 attackerPoints = isAttackerActive ? 80 : 60; // Active attacker gets more points
            LibColonyWarsStorage.addColonyScore(season.seasonId, battle.attackerColony, attackerPoints);
            LibColonyWarsStorage.addColonyScore(season.seasonId, battle.defenderColony, 0);
            
        } else if (forfeitType == 3) {
            // MUTUAL FORFEIT
            season.prizePool += prizePool;
            
            cws.colonyLosses[battle.attackerColony] += battle.stakeAmount;
            
            LibColonyWarsStorage.ColonyWarProfile storage defenderProfile = cws.colonyWarProfiles[battle.defenderColony];
            uint256 defenderPenalty = defenderProfile.defensiveStake / 4;
            if (defenderProfile.defensiveStake >= defenderPenalty) {
                defenderProfile.defensiveStake -= defenderPenalty;
                cws.colonyLosses[battle.defenderColony] += defenderPenalty;
            }
            
            // Both get reputation penalties
            LibColonyWarsStorage.ColonyWarProfile storage attackerProfile = cws.colonyWarProfiles[battle.attackerColony];
            if (attackerProfile.reputation < 5) attackerProfile.reputation = 5;
            if (defenderProfile.reputation < 4) defenderProfile.reputation = 4;
            
            // Minimal points for mutual forfeit, slightly more for active players
            uint256 defenderPoints = isDefenderActive ? 20 : 15;
            uint256 attackerPoints = isAttackerActive ? 10 : 5;
            
            LibColonyWarsStorage.addColonyScore(season.seasonId, battle.defenderColony, defenderPoints);
            LibColonyWarsStorage.addColonyScore(season.seasonId, battle.attackerColony, attackerPoints);
        }
        
        battle.prizePool = 0;
    }

    /**
     * @notice Calculate season points based on risk/reward ratio
     * @param attackerStake Amount staked by attacker
     * @param defenderStake Defender's defensive stake
     * @param isAttackerWin Whether attacker won the battle
     * @return winnerPoints Points for winner
     * @return loserPoints Points for loser
     */
    function _calculateRiskBasedPoints(
        uint256 attackerStake,
        uint256 defenderStake, 
        bool isAttackerWin,
        bool hasActiveDefense,
        bytes32 attackerColony,
        bytes32 defenderColony
    ) internal view returns (uint256 winnerPoints, uint256 loserPoints) {
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Check activity levels for both colonies
        address attackerOwner = hs.colonyCreators[attackerColony];
        address defenderOwner = hs.colonyCreators[defenderColony];
        
        bool isAttackerActive = _isUserRecentlyActive(attackerOwner, cws);
        bool isDefenderActive = _isUserRecentlyActive(defenderOwner, cws);
        
        if (isAttackerWin) {
            // Attacker wins - scale by economic risk
            uint256 stakeRatio = defenderStake > 0 ? (attackerStake * 100) / defenderStake : 100;
            
            if (stakeRatio >= 300) {
                winnerPoints = 400; // Massive economic risk
            } else if (stakeRatio >= 200) {
                winnerPoints = 300; // Very high risk
            } else if (stakeRatio >= 150) {
                winnerPoints = 200; // High risk
            } else if (stakeRatio >= 100) {
                winnerPoints = 150; // Medium risk
            } else if (stakeRatio >= 75) {
                winnerPoints = 100; // Low risk
            } else {
                winnerPoints = 50;  // Punching down
            }
            
            // ACTIVITY MODIFIERS FOR ATTACKER VICTORY:
            
            // 1. Penalty for beating inactive defender (easier target)
            if (!isDefenderActive) {
                winnerPoints = (winnerPoints * 85) / 100; // 15% penalty for beating inactive colony
            }
            
            // 2. Additional penalty if defender didn't actively defend
            if (!hasActiveDefense) {
                winnerPoints = (winnerPoints * 80) / 100; // 20% penalty for beating passive defense
            }
            
            // 3. Bonus for active attacker taking real risks
            if (isAttackerActive && stakeRatio >= 150) {
                winnerPoints = (winnerPoints * 110) / 100; // 10% bonus for active player taking big risks
            }
            
            // DEFENDER CONSOLATION POINTS:
            if (hasActiveDefense && isDefenderActive) {
                // Active defender who fought gets better consolation
                if (stakeRatio >= 200) {
                    loserPoints = 45; // Heroic active defense against overwhelming odds
                } else if (stakeRatio >= 150) {
                    loserPoints = 40; // Strong active resistance
                } else {
                    loserPoints = 30; // Standard active defense consolation
                }
            } else if (hasActiveDefense && !isDefenderActive) {
                // Had auto-defense but player was inactive
                loserPoints = 20; // Reduced consolation for inactive player
            } else if (!hasActiveDefense && isDefenderActive) {
                // Active player but didn't defend (was away/busy)
                if (stakeRatio >= 200) {
                    loserPoints = 25; // Some credit for facing overwhelming odds
                } else {
                    loserPoints = 20; // Minimal credit
                }
            } else {
                // Inactive player with no active defense
                loserPoints = 10; // Minimal points for inactive target
            }
            
        } else {
            // Defender wins - reward based on pressure faced
            uint256 stakeRatio = defenderStake > 0 ? (attackerStake * 100) / defenderStake : 100;
            
            if (stakeRatio >= 200) {
                winnerPoints = 200; // Heroic defense against overwhelming odds
            } else if (stakeRatio >= 150) {
                winnerPoints = 150; // Strong defense
            } else {
                winnerPoints = 100; // Standard defense
            }
            
            // ACTIVITY MODIFIERS FOR DEFENDER VICTORY:
            
            // 1. Bonus for active defense victory
            if (hasActiveDefense && isDefenderActive) {
                winnerPoints = (winnerPoints * 120) / 100; // 20% bonus for active player defending actively
            } else if (hasActiveDefense && !isDefenderActive) {
                winnerPoints = (winnerPoints * 100) / 100; // No bonus for inactive player (auto-defense victory)
            } else if (!hasActiveDefense && isDefenderActive) {
                winnerPoints = (winnerPoints * 90) / 100;  // 10% penalty for active player not defending
            } else {
                winnerPoints = (winnerPoints * 70) / 100;  // 30% penalty for inactive player with passive defense
            }
            
            // ATTACKER CONSOLATION POINTS:
            if (isAttackerActive) {
                // Active attacker gets credit for bold attempt
                if (stakeRatio >= 150) {
                    loserPoints = 35; // Bonus for active player taking big risks
                } else {
                    loserPoints = 25; // Standard consolation for active player
                }
            } else {
                // Inactive attacker gets reduced consolation
                loserPoints = 15; // Minimal points for inactive player attempt
            }
        }
        
        return (winnerPoints, loserPoints);
    }

    /**
     * @notice ADD: Defensive preparation bonus for active defense
     * @dev Call this in defendBattle when defender commits tokens
     */
    function _awardDefensivePreparationBonus(
        bytes32 defenderColony,
        uint256 defenseTokenCount,
        uint256 attackTokenCount,
        uint32 seasonId
    ) internal {
        uint256 bonusPoints = 5; // Base bonus for showing up to fight
        
        // Extra bonus for matching or exceeding attacker commitment
        if (defenseTokenCount >= attackTokenCount) {
            bonusPoints += 5; // Total 10 points for full commitment
        }
        
        // Award the bonus immediately
        LibColonyWarsStorage.addColonyScore(seasonId, defenderColony, bonusPoints);
    }

    /**
     * @notice Apply weather effects to battle powers
     * @param attackerPower Base attacker power
     * @param defenderPower Base defender power
     * @param battleRandomness Battle-specific randomness (0-99)
     * @return modifiedAttacker Attacker power after weather
     * @return modifiedDefender Defender power after weather
     * @return weatherDescription Description of weather effect applied
     */
    function _applyWeatherEffects(
        uint256 attackerPower,
        uint256 defenderPower,
        uint256 battleRandomness
    ) internal view returns (
        uint256 modifiedAttacker,
        uint256 modifiedDefender,
        string memory weatherDescription
    ) {
        (uint8 weatherType, string memory weatherName, uint8 attackerMod, uint8 defenderMod) = IStrategicOverviewFacet(address(this)).getBattlefieldWeather();
        
        if (weatherType == 3) { // STRONG WIND - special variable effect
            if (battleRandomness < 40) {
                // Wind favors attackers (easier movement)
                modifiedAttacker = (attackerPower * 115) / 100;
                modifiedDefender = (defenderPower * 95) / 100;
                weatherDescription = string(abi.encodePacked(weatherName, " (Favoring Attackers)"));
            } else if (battleRandomness > 60) {
                // Wind favors defenders (disrupts attack formations)
                modifiedAttacker = (attackerPower * 90) / 100;
                modifiedDefender = (defenderPower * 110) / 100;
                weatherDescription = string(abi.encodePacked(weatherName, " (Favoring Defenders)"));
            } else {
                // Neutral wind
                modifiedAttacker = (attackerPower * 95) / 100;
                modifiedDefender = (defenderPower * 95) / 100;
                weatherDescription = string(abi.encodePacked(weatherName, " (Chaotic)"));
            }
        } else {
            // Standard weather effects
            modifiedAttacker = (attackerPower * attackerMod) / 100;
            modifiedDefender = (defenderPower * defenderMod) / 100;
            weatherDescription = weatherName;
        }
        
        return (modifiedAttacker, modifiedDefender, weatherDescription);
    }

    /**
     * @notice Trigger battle achievements for winner
     */
    function _triggerBattleAchievements(
        bytes32 winner,
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) internal {
        address winnerOwner = hs.colonyCreators[winner];
        if (winnerOwner == address(0)) return;

        uint256 winStreak = cws.colonyWinStreaks[winner];
        // Use win streak as proxy for total wins (simplified)
        LibAchievementTrigger.triggerBattleWin(winnerOwner, winStreak, winStreak);
    }
}