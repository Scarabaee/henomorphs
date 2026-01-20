// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibGamingStorage} from "../libraries/LibGamingStorage.sol";
import {ActionHelper} from "../libraries/ActionHelper.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {PodsUtils} from "../../../libraries/PodsUtils.sol";
import {ChargeCalculator} from "../libraries/ChargeCalculator.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ControlFee, Calibration, SpecimenCollection, PowerMatrix, ChargeActionType, ChargeAccessory} from "../../../libraries/HenomorphsModel.sol";
import {UserEngagement, DailyChallengeSet, DailyChallenge, FlashEvent, FlashParticipation} from "../../../libraries/GamingModel.sol";
import {ISpecimenBiopod} from "../../../interfaces/ISpecimenBiopod.sol";
import {AccessHelper} from "../../staking/libraries/AccessHelper.sol";
import {ColonyHelper} from "../../staking/libraries/ColonyHelper.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {LibFeeCollection} from "../../staking/libraries/LibFeeCollection.sol";
import {IExternalCollection, IRankingFacet, ISpecializationEvolution, IStakingSystem} from "../../staking/interfaces/IStakingInterfaces.sol";

/**
 * @title ChargeFacet
 * @notice Handles user charge interactions and power core operations
 * @dev Conservative gas optimizations maintaining full functionality
 * @author rutilicus.eth (ArchXS)
 */
contract ChargeFacet is AccessControlBase {
    using Math for uint256;

    uint8 private constant COLONY_ACTION = 5;
    uint8 private constant EXPLORATION_ACTION = 3;
    uint256 private constant MAX_ITEMS_IN_BATCH = 50;
    uint256 private constant BASE_ZICO_REWARD = 1e18;
    uint8 private constant MAX_SUPPORTED_ACTION = 5;
    
    event ChargeUpdated(uint256 indexed collectionId, uint256 indexed tokenId, uint256 newCharge, uint256 maxCharge);
    event PowerCoreActivated(uint256 indexed collectionId, uint256 indexed tokenId, uint256 initialCharge, uint256 maxCharge);
    event ActionPerformed(uint256 indexed collectionId, uint256 indexed tokenId, uint8 actionType, uint256 chargeCost, uint256 reward);
    event StreakUpdated(address indexed user, uint32 currentStreak, uint128 streakMultiplier);
    event FlashEventParticipation(address indexed user, uint16 actionsPerformed, uint256 bonusEarned);
    event DailyChallengeCompleted(address indexed user, uint256 challengeIndex, uint256 reward);
    event AchievementEarned(address indexed user, uint256 indexed achievementId, uint256 reward);
    event AllDailyChallengesCompleted(address indexed user, uint256 bonusReward);
    event PowerCoreDeactivated(uint256 indexed collectionId, uint256 indexed tokenId, uint256 oldCurrentCharge, uint256 oldMaxCharge);
    event PowerCoreRestored(uint256 indexed collectionId, uint256 indexed tokenId, uint256 currentCharge, uint256 caxCharge);
    event ColonyEventBonus(address indexed user, uint256 indexed collectionId, uint256 indexed tokenId, uint32 bonusPoints, uint16 bonusPercentage);
    event UserStateReset(address indexed admin, address indexed user, string resetType, string reason);

    error InsufficientCharge();
    error HenomorphInRepairMode();

    modifier whenChargeEnabled(uint256 collectionId, uint256 tokenId) {
        _checkChargeEnabled(collectionId, tokenId);
        _;
    }

    modifier whenActionEnabled(uint256 collectionId, uint256 tokenId, uint8 actionId) {
        address user = LibMeta.msgSender();
        _checkChargeEnabled(collectionId, tokenId);
        ActionHelper.validateUnifiedCooldown(user, collectionId, tokenId, actionId);
        _;
    }

    function activatePowerCore(uint256 collectionId, uint256 tokenId) external whenChargeEnabled(collectionId, tokenId) nonReentrant {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 _combinedId = PodsUtils.combineIds(collectionId, tokenId);
        SpecimenCollection storage _collection = hs.specimenCollections[collectionId];
        PowerMatrix storage _charge = hs.performedCharges[_combinedId];

        // Check if token already has full calibration data (imported via BiopodFacet.inspect)
        // If so, don't overwrite - just ensure power core is marked as active
        if (_hasFullCalibrationData(_charge)) {
            // Token already has calibration data from BiopodFacet - don't overwrite
            // Just emit events to confirm activation state
            emit PowerCoreActivated(collectionId, tokenId, _charge.currentCharge, _charge.maxCharge);
            emit ChargeUpdated(collectionId, tokenId, _charge.currentCharge, _charge.maxCharge);
            return;
        }

        // Legacy migration: if lastChargeTime is set but missing calibration data
        // Auto-migrate by filling in missing fields instead of reverting
        bool isLegacyMigration = _charge.lastChargeTime != 0;

        uint8 _variant = 0;
        uint256 _initialCharge = isLegacyMigration ? _charge.currentCharge : 100;

        try IExternalCollection(_collection.collectionAddress).itemVariant(tokenId) returns (uint8 variant) {
            _variant = variant;
        } catch {}

        // Validate variant > 0 (token must be minted/revealed)
        if (_variant == 0 || _variant > 4) {
            return;
        }

        if (_collection.biopodAddress != address(0)) {
            try ISpecimenBiopod(_collection.biopodAddress).probeCalibration(collectionId, tokenId) returns (Calibration memory calibration) {
                if (!isLegacyMigration) {
                    _initialCharge = calibration.charge > 0 ? calibration.charge : 100;
                }
            } catch {}
        }

        uint256 _baseMaxCharge = 80 + (_variant * 5) + _collection.maxChargeBonus;
        uint256 _adjustedRegenRate = hs.chargeSettings.baseRegenRate + _variant;
        _adjustedRegenRate = Math.mulDiv(_adjustedRegenRate, _collection.regenMultiplier, 100);

        if (isLegacyMigration) {
            // Auto-migrate: preserve existing data, fill missing calibration fields
            _charge.maxCharge = uint128(_baseMaxCharge);
            _charge.regenRate = uint16(_adjustedRegenRate);
            _charge.chargeEfficiency = _charge.chargeEfficiency > 0 ? _charge.chargeEfficiency : 100;
            _charge.evolutionLevel = _charge.evolutionLevel > 0 ? _charge.evolutionLevel : 1;
            _charge.kinship = _charge.kinship > 0 ? _charge.kinship : 50;
            _charge.prowess = _charge.prowess > 0 ? _charge.prowess : 1;
            _charge.agility = _charge.agility > 0 ? _charge.agility : 10;
            _charge.intelligence = _charge.intelligence > 0 ? _charge.intelligence : 10;
            _charge.lastInteraction = uint32(block.timestamp);
        } else {
            // Fresh activation
            hs.performedCharges[_combinedId] = PowerMatrix({
                currentCharge: uint128(_initialCharge),
                maxCharge: uint128(_baseMaxCharge),
                lastChargeTime: uint32(block.timestamp),
                regenRate: uint16(_adjustedRegenRate),
                fatigueLevel: 0,
                boostEndTime: 0,
                chargeEfficiency: 100,
                consecutiveActions: 0,
                flags: 0,
                specialization: 0,
                seasonPoints: 0,
                evolutionLevel: 1,
                evolutionXP: 0,
                masteryPoints: 0,
                kinship: 50,
                prowess: 1,
                agility: 10,
                intelligence: 10,
                calibrationCount: 0,
                lastInteraction: 0
            });
        }

        emit PowerCoreActivated(collectionId, tokenId, _initialCharge, _baseMaxCharge);
        emit ChargeUpdated(collectionId, tokenId, _initialCharge, _baseMaxCharge);
    }

    /**
     * @dev Check if PowerMatrix has full calibration data (imported from BiopodFacet)
     * @return true if token has been fully initialized with calibration data
     */
    function _hasFullCalibrationData(PowerMatrix storage _charge) private view returns (bool) {
        // Token has full data if maxCharge is set AND (both timestamps are set OR calibrationCount > 0)
        // This ensures we don't skip activation for tokens with incomplete data
        return _charge.maxCharge > 0 && (
            (_charge.lastChargeTime != 0 && _charge.lastInteraction != 0) ||
            _charge.calibrationCount > 0
        );
    }

    /**
     * @notice Batch activate with proper error reporting
     */
    function batchActivatePowerCore(
        uint256 collectionId,
        uint256[] calldata tokenIds
    ) external nonReentrant returns (uint256[] memory results, uint256 successCount) {
        if (tokenIds.length == 0 || tokenIds.length > MAX_ITEMS_IN_BATCH) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        address user = LibMeta.msgSender();
        ActionHelper.ensureDailyReset(user);
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        SpecimenCollection storage _collection = hs.specimenCollections[collectionId];
        if (!_collection.enabled) {
            revert LibHenomorphsStorage.CollectionNotEnabled(collectionId);
        }
        
        results = new uint256[](tokenIds.length);
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 initialCharge = _activateSinglePowerCore(collectionId, tokenIds[i], _collection, hs);
            results[i] = initialCharge;
            if (initialCharge > 0) {
                successCount++;
            }
        }
        
        return (results, successCount);
    }

    function recalibrateCore(uint256 collectionId, uint256 tokenId) public returns (uint256) {
        if (!AccessHelper.isInternalCall() && !AccessHelper.isAuthorized()) {
            _checkChargeEnabled(collectionId, tokenId);
        }

        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 _combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage _charge = hs.performedCharges[_combinedId];
        
        if (_charge.lastChargeTime == 0) { 
            revert LibHenomorphsStorage.PowerCoreNotActivated(collectionId, tokenId);
        }
        
        uint256 _elapsedTime = block.timestamp - _charge.lastChargeTime;
        
        if (_elapsedTime > 0 && _charge.currentCharge < _charge.maxCharge && (_charge.flags & 1) == 0) {
            _charge.currentCharge = uint128(ChargeCalculator.calculateChargeRegen(
                _charge,
                _elapsedTime,
                hs.chargeEventEnd,
                hs.chargeEventBonus
            ));
        }
        
        if (_charge.fatigueLevel > 0 && _elapsedTime > 0) {
            uint256 fatigueReduction = (_elapsedTime * hs.chargeSettings.fatigueRecoveryRate) / 3600;
            _charge.fatigueLevel = _charge.fatigueLevel > uint8(fatigueReduction) ? _charge.fatigueLevel - uint8(fatigueReduction) : 0;
        }
        
        _charge.lastChargeTime = uint32(block.timestamp);
        
        emit ChargeUpdated(collectionId, tokenId, _charge.currentCharge, _charge.maxCharge);
        
        return _charge.currentCharge;
    }
    
    function performAction(uint256 collectionId, uint256 tokenId, uint8 actionId) 
        external 
        whenActionEnabled(collectionId, tokenId, actionId)
        nonReentrant 
        returns (uint256) 
    {
        if (actionId == 0 || actionId > MAX_SUPPORTED_ACTION) {
            revert LibHenomorphsStorage.UnsupportedAction();
        }

        address user = LibMeta.msgSender();
        ActionHelper.ensureDailyReset(user);
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);

        _validateAndPrepareAction(collectionId, tokenId, actionId);
        uint256 chargeCost = _processActionCost(collectionId, tokenId, actionId, combinedId);
        uint256 baseReward = _processActionReward(collectionId, tokenId, actionId, combinedId);
        uint256 enhancedReward = _applyAllRewardBonuses(baseReward, collectionId, tokenId, actionId, user);

        _updateGameState(user, collectionId, tokenId, actionId, enhancedReward);
        ActionHelper.updateAfterAction(user, collectionId, tokenId, actionId);

        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        bytes32 tokenColony = hs.specimenColonies[combinedId];
        if (tokenColony != bytes32(0)) {
            ColonyHelper.updateColonyHealth(tokenColony);
        }

        emit ActionPerformed(collectionId, tokenId, actionId, chargeCost, enhancedReward);
        return enhancedReward;
    }

    /**
     * @notice Batch perform with upfront validation and proper error handling
     */
    function batchPerformAction(
        uint256 collectionId,
        uint256[] calldata tokenIds,
        uint8 actionId
    ) external nonReentrant returns (uint256[] memory results, uint256 successCount) {
        
        address user = LibMeta.msgSender();
        ActionHelper.ensureDailyReset(user);
        
        results = new uint256[](tokenIds.length);
        
        // SAFE OPTIMIZATION 1: Pre-validate collection once
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            return (results, 0);
        }
        
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        if (!collection.enabled) {
            return (results, 0);
        }
        
        // SAFE OPTIMIZATION 2: Count valid tokens and collect fees upfront
        uint256 validCount = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            (bool valid, ) = ActionHelper.checkUnifiedCooldown(user, collectionId, tokenIds[i], actionId);
            if (valid) validCount++;
        }
        
        if (validCount > 0) {
            // Use dual token action fee (YELLOW with burn) from ColonyWars config
            LibColonyWarsStorage.OperationFee storage actionFee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_ACTION);
            LibFeeCollection.processOperationFee(
                actionFee.currency,
                actionFee.beneficiary,
                actionFee.baseAmount,
                actionFee.multiplier,
                actionFee.burnOnCollect,
                actionFee.enabled,
                user,
                validCount,
                "batch_action"
            );
        }
        
        // Execute actions with proper error handling
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 reward = _performSingleTokenAction(
                collectionId, 
                tokenIds[i], 
                actionId, 
                user, 
                true // skipFeeCollection since we paid upfront
            );
            results[i] = reward;
            if (reward > 0) {
                successCount++;
            }
        }
        
        return (results, successCount);
    }

    function configureRepairMode(uint256 collectionId, uint256 tokenId, bool repairMode) external onlyAuthorized {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        uint256 _combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage _charge = hs.performedCharges[_combinedId];
        
        if (repairMode) {
            _charge.flags |= 1;
        } else {
            _charge.flags &= ~uint8(1);
        }
    }

    function disposePowerCore(uint256 collectionId, uint256 tokenId) external onlyAuthorized {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        if (hs.performedCharges[combinedId].lastChargeTime == 0) {
            revert LibHenomorphsStorage.PowerCoreNotActivated(collectionId, tokenId);
        }
        
        uint256 oldCharge = hs.performedCharges[combinedId].currentCharge;
        uint256 oldMaxCharge = hs.performedCharges[combinedId].maxCharge;
        
        delete hs.performedCharges[combinedId];
        
        for (uint8 actionId = 1; actionId <= 5; actionId++) {
            delete hs.actionLogs[combinedId][actionId];
        }
        
        emit PowerCoreDeactivated(collectionId, tokenId, oldCharge, oldMaxCharge);
    }

    function restorePowerCore(
        uint256 collectionId,
        uint256 tokenId, 
        uint128 currentCharge,
        uint128 maxCharge,
        uint16 regenRate,
        uint8 evolutionLevel,
        uint32 evolutionXP,
        uint16 masteryPoints
    ) external onlyAuthorized {
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        PowerMatrix storage charge = hs.performedCharges[combinedId];
        
        charge.currentCharge = currentCharge;
        charge.maxCharge = maxCharge;
        charge.lastChargeTime = uint32(block.timestamp);
        charge.regenRate = regenRate;
        charge.fatigueLevel = 0;
        charge.boostEndTime = 0;
        charge.chargeEfficiency = 100;
        charge.consecutiveActions = 0;
        charge.flags = 0;
        charge.specialization = 0;
        charge.seasonPoints = 0;
        charge.evolutionLevel = evolutionLevel;
        charge.evolutionXP = evolutionXP;
        charge.masteryPoints = masteryPoints;
        
        emit PowerCoreRestored(collectionId, tokenId, currentCharge, maxCharge);
    }

    // =================== INTERNAL FUNCTIONS ===================

    function _isTokenStaked(uint256 collectionId, uint256 tokenId) internal view returns (bool isStaked) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (hs.stakingSystemAddress == address(0)) {
            return false;
        }
        
        try IStakingSystem(hs.stakingSystemAddress).isSpecimenStaked(collectionId, tokenId) returns (bool staked) {
            return staked;
        } catch {
            return false;
        }
    }

    function _isTokenInColony(uint256 collectionId, uint256 tokenId) internal view returns (bool inColony) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        return hs.specimenColonies[combinedId] != bytes32(0);
    }

    /**
     * @notice Single token action for batch operations
     */
    function _performSingleTokenAction(
        uint256 collectionId,
        uint256 tokenId,
        uint8 actionId,
        address user,
        bool skipFeeCollection
    ) internal returns (uint256) {
        if (!_canUserControlToken(collectionId, tokenId, user)) {
            return 0;
        }

        (bool canPerform, ) = ActionHelper.checkUnifiedCooldown(user, collectionId, tokenId, actionId);
        if (!canPerform) {
            return 0;
        }

        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage charge = hs.performedCharges[combinedId];

        if (charge.lastChargeTime == 0) {
            return 0;
        }

        if ((charge.flags & 1) != 0) {
            return 0;
        }

        _validateAndPrepareAction(collectionId, tokenId, actionId);

        uint256 chargeCost;
        if (skipFeeCollection) {
            chargeCost = _processActionCostNoFee(collectionId, tokenId, actionId, combinedId);
        } else {
            chargeCost = _processActionCost(collectionId, tokenId, actionId, combinedId);
        }

        uint256 baseReward = _processActionReward(collectionId, tokenId, actionId, combinedId);
        uint256 enhancedReward = _applyAllRewardBonuses(baseReward, collectionId, tokenId, actionId, user);

        ActionHelper.updateAfterAction(user, collectionId, tokenId, actionId);

        bytes32 tokenColony = hs.specimenColonies[combinedId];
        if (tokenColony != bytes32(0)) {
            ColonyHelper.updateColonyHealth(tokenColony);
        }

        emit ActionPerformed(collectionId, tokenId, actionId, chargeCost, enhancedReward);
        return enhancedReward;
    }

    function _canUserControlToken(uint256 collectionId, uint256 tokenId, address user) internal view returns (bool) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (AccessHelper.isAuthorized()) {
            return true;
        }
        
        if (hs.stakingSystemAddress != address(0)) {
            if (AccessHelper.checkTokenOwnership(collectionId, tokenId, user, hs.stakingSystemAddress)) {
                return true;
            }
        }
        
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        try IERC721(collection.collectionAddress).ownerOf(tokenId) returns (address owner) {
            return owner == user;
        } catch {
            return false;
        }
    }

    function _activateSinglePowerCore(
        uint256 collectionId,
        uint256 tokenId,
        SpecimenCollection storage _collection,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) internal returns (uint256) {
        address user = LibMeta.msgSender();
        uint256 _combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        if (!_canUserControlToken(collectionId, tokenId, user)) {
            return 0;
        }
        
        if (hs.performedCharges[_combinedId].lastChargeTime != 0) {
            return 0;
        }

        uint8 _variant = 0;
        try IExternalCollection(_collection.collectionAddress).itemVariant(tokenId) returns (uint8 variant) {
            _variant = variant;
        } catch {
            return 0;
        }

        if (_variant == 0 || _variant > 4) {
            return 0;
        }
        
        uint256 _initialCharge = 100;
        if (_collection.biopodAddress != address(0)) {
            try ISpecimenBiopod(_collection.biopodAddress).probeCalibration(collectionId, tokenId) returns (Calibration memory calibration) {
                _initialCharge = calibration.charge;
            } catch {}
        }
        
        uint256 _baseMaxCharge = 80 + (_variant * 5) + _collection.maxChargeBonus;
        uint256 _adjustedRegenRate = hs.chargeSettings.baseRegenRate + _variant;
        _adjustedRegenRate = Math.mulDiv(_adjustedRegenRate, _collection.regenMultiplier, 100);
        
        hs.performedCharges[_combinedId] = PowerMatrix({
            currentCharge: uint128(_initialCharge),
            maxCharge: uint128(_baseMaxCharge),
            lastChargeTime: uint32(block.timestamp),
            regenRate: uint16(_adjustedRegenRate),
            fatigueLevel: 0,
            boostEndTime: 0,
            chargeEfficiency: 100,
            consecutiveActions: 0,
            flags: 0,
            specialization: 0,
            seasonPoints: 0,
            evolutionLevel: 1,
            evolutionXP: 0,
            masteryPoints: 0,
            // Calibration-compatible fields
            kinship: 50,
            prowess: 1,
            agility: 10,
            intelligence: 10,
            calibrationCount: 0,
            lastInteraction: 0
        });

        emit PowerCoreActivated(collectionId, tokenId, _initialCharge, _baseMaxCharge);
        emit ChargeUpdated(collectionId, tokenId, _initialCharge, _baseMaxCharge);

        return _initialCharge;
    }

    function _checkChargeEnabled(uint256 collectionId, uint256 tokenId) internal view {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        SpecimenCollection storage _collection = hs.specimenCollections[collectionId];
        if (!_collection.enabled) {
            revert LibHenomorphsStorage.CollectionNotEnabled(collectionId);
        }
        
        if (AccessHelper.isAuthorized()) {
            return;
        }
        
        address sender = LibMeta.msgSender();
        
        if (hs.stakingSystemAddress != address(0)) {
            if (AccessHelper.checkTokenOwnership(collectionId, tokenId, sender, hs.stakingSystemAddress)) {
                return;
            }
        }
        
        address owner;
        
        try IERC721(_collection.collectionAddress).ownerOf(tokenId) returns (address _owner) {
            owner = _owner;
        } catch {
            revert LibHenomorphsStorage.TokenNotFound(tokenId);
        }
        
        if (owner == address(0) || owner != sender) {
            revert LibHenomorphsStorage.HenomorphControlForbidden(collectionId, tokenId);
        }
    }

    function _validateAndPrepareAction(uint256 collectionId, uint256 tokenId, uint8 actionId) internal {
        recalibrateCore(collectionId, tokenId);
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage _charge = hs.performedCharges[combinedId];
        
        if ((_charge.flags & 1) != 0) {
            revert HenomorphInRepairMode();
        }
        
        ChargeActionType storage actionType = hs.actionTypes[actionId];
        if (actionType.minChargePercent > 0) {
            uint256 requiredCharge = (_charge.maxCharge * actionType.minChargePercent) / 100;
            if (_charge.currentCharge < requiredCharge) {
                revert InsufficientCharge();
            }
        }
    }


    function _applyAllRewardBonuses(
        uint256 baseReward,
        uint256 collectionId,
        uint256 tokenId,
        uint8 actionId,
        address user
    ) internal returns (uint256 enhancedReward) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        enhancedReward = baseReward;
        
        if (hs.featureFlags["streaks"]) {
            enhancedReward = _applyStreakBonus(user, actionId, enhancedReward);
        }
        
        if (hs.featureFlags["flashEvents"]) {
            enhancedReward = _applyFlashEventBonus(user, actionId, enhancedReward);
        }
        
        if (hs.featureFlags["globalMultipliers"]) {
            enhancedReward = _applyGlobalMultiplier(enhancedReward);
        }
        
        if (hs.featureFlags["colonyEvents"] && hs.colonyEventConfig.active) {
            enhancedReward = _applyColonyEventBonus(collectionId, tokenId, user, enhancedReward);
        }
        
        return enhancedReward;
    }

    function _updateGameState(address user, uint256 collectionId, uint256 tokenId, uint8 actionId, uint256 enhancedReward) internal {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        _updateUserEngagement(user, actionId);
        
        if (hs.featureFlags["dailyChallenges"]) {
            _updateDailyChallenges(user, actionId);
        }
        
        if (hs.featureFlags["achievements"]) {
            _checkAchievementProgress(user, actionId, enhancedReward);
        }
        
        if (hs.featureFlags["rankings"]) {
            IRankingFacet rankingFacet = IRankingFacet(address(this));
            
            (uint256 globalRankingId, uint256 seasonRankingId) = rankingFacet.getActiveRankingIds();
            
            if (globalRankingId > 0) {
                rankingFacet.updateUserScore(globalRankingId, user, enhancedReward);
            }
            
            if (seasonRankingId > 0) {
                rankingFacet.updateUserScore(seasonRankingId, user, enhancedReward);
            }
        }

        if (hs.featureFlags["specializationEvolution"]) {
            try ISpecializationEvolution(address(this)).awardSpecializationXP(
                collectionId, tokenId, actionId, enhancedReward
            ) {} catch {}
        }     

        uint8 activityPoints = _getActionActivityPoints(actionId);
        gs.globalGameState.totalDailyActions += activityPoints;
    }

    function _applyColonyEventBonus(
        uint256 collectionId,
        uint256 tokenId,
        address user,
        uint256 baseReward
    ) internal returns (uint256) {
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        if (hs.specimenColonies[combinedId] == bytes32(0)) {
            return baseReward;
        }

        uint16 bonusPercent = _calculateOptimalColonyBonus(collectionId, tokenId, user);
        
        if (bonusPercent == 0) {
            return baseReward;
        }
        
        uint256 bonusAmount = Math.mulDiv(baseReward, bonusPercent, 100);
        uint256 totalReward = baseReward + bonusAmount;
        
        emit ColonyEventBonus(user, collectionId, tokenId, uint32(bonusAmount), bonusPercent);
        
        return totalReward;
    }

    function _calculateOptimalColonyBonus(uint256 collectionId, uint256 tokenId, address user) internal view returns (uint16 bonusPercentage) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        bytes32 colonyId = hs.specimenColonies[combinedId];
        uint32 currentDay = LibGamingStorage.getCurrentDay();
        
        uint32 eventStartDay = hs.colonyEventConfig.startDay;
        uint8 minDailyActions = hs.colonyEventConfig.minDailyActions;
        uint16 maxBonusPercent = hs.colonyEventConfig.maxBonusPercent;
        
        uint16 totalBonus = 0;
        
        uint256 stakingBonus = hs.colonyStakingBonuses[colonyId];
        totalBonus += uint16(stakingBonus > 25 ? 25 : stakingBonus);
        
        uint32 streak = gs.userEngagement[user].currentStreak;
        totalBonus += uint16(streak > 7 ? 35 : streak * 5);
        
        uint8 tier = _calculateUserColonyTier(user, currentDay, eventStartDay, minDailyActions);
        if (tier >= 5) totalBonus += 30;
        else if (tier >= 4) totalBonus += 25;
        else if (tier >= 3) totalBonus += 15;
        else if (tier >= 2) totalBonus += 10;
        
        if (_isColonyActiveToday(colonyId, currentDay, minDailyActions)) {
            totalBonus += 10;
        }
        
        if (currentDay >= hs.colonyEventConfig.endDay - 1) {
            totalBonus += 15;
        }
        
        return totalBonus > maxBonusPercent ? maxBonusPercent : totalBonus;
    }

    function _calculateUserColonyTier(address user, uint32 currentDay, uint32 eventStartDay, uint8 minDailyActions) internal view returns (uint8) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        uint8 qualifiedDays = 0;
        
        if (eventStartDay == 0 || currentDay < eventStartDay) {
            return 1;
        }
        
        uint32 maxDaysToCheck = 90;
        uint32 startDay = eventStartDay;
        if (currentDay - eventStartDay > maxDaysToCheck) {
            startDay = currentDay - maxDaysToCheck;
        }
        
        uint32 iterations = 0;
        for (uint32 day = startDay; day <= currentDay; day++) {
            iterations++;
            if (iterations > maxDaysToCheck) break;
            
            if (gs.userDailyActivity[user][day] >= minDailyActions) {
                qualifiedDays++;
                if (qualifiedDays >= 13) break;
            }
        }
        
        if (qualifiedDays >= 13) return 5;
        if (qualifiedDays >= 10) return 4;
        if (qualifiedDays >= 7) return 3;
        if (qualifiedDays >= 4) return 2;
        return 1;
    }

    function _isColonyActiveToday(bytes32 colonyId, uint32 currentDay, uint8 minDailyActions) internal view returns (bool isActive) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        uint256[] storage members = hs.colonies[colonyId];
        if (members.length == 0) return false;
        
        uint256 maxMembersToCheck = 50;
        uint256 membersToCheck = members.length > maxMembersToCheck ? maxMembersToCheck : members.length;
        uint256 activeMembers = 0;
        uint256 requiredActive = (membersToCheck / 2) + 1;
        
        for (uint256 i = 0; i < membersToCheck && activeMembers < requiredActive; i++) {
            if (i >= members.length) break;
            
            (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(members[i]);
            address owner = ColonyHelper.getTokenOwner(collectionId, tokenId);
            
            if (gs.userDailyActivity[owner][currentDay] >= minDailyActions) {
                activeMembers++;
            }
        }
        
        return activeMembers >= requiredActive;
    }

    function _processActionCost(uint256, uint256, uint8 actionId, uint256 _combinedId) private returns (uint256) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        PowerMatrix storage _charge = hs.performedCharges[_combinedId];
        ChargeActionType memory _action = hs.actionTypes[actionId];

        // Each action has its own fee configuration
        ControlFee memory actionFee = hs.actionFees[actionId];

        if (actionFee.beneficiary == address(0)) {
            actionFee = hs.actionTypes[actionId].baseCost;
        }

        LibFeeCollection.collectAndBurnFee(
            actionFee.currency,
            LibMeta.msgSender(),
            actionFee.beneficiary,
            actionFee.amount,
            "action"
        );

        uint256 _chargeCost = ChargeCalculator.calculateChargeCost(10, _charge, _action);

        if (_charge.currentCharge < _chargeCost) {
            revert InsufficientCharge();
        }

        _charge.currentCharge = uint128(uint256(_charge.currentCharge) - _chargeCost);

        _updateFatigue(_combinedId, _charge);

        return _chargeCost;
    }

    function _processActionCostNoFee(uint256, uint256, uint8 actionId, uint256 _combinedId) private returns (uint256) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        PowerMatrix storage _charge = hs.performedCharges[_combinedId];
        ChargeActionType memory _action = hs.actionTypes[actionId];

        uint256 _chargeCost = ChargeCalculator.calculateChargeCost(10, _charge, _action);
        
        if (_charge.currentCharge < _chargeCost) {
            revert InsufficientCharge();
        }
        
        _charge.currentCharge = uint128(uint256(_charge.currentCharge) - _chargeCost);
        
        _updateFatigue(_combinedId, _charge);
        
        return _chargeCost;
    }

    function _updateFatigue(uint256 _combinedId, PowerMatrix storage _charge) private {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        _charge.consecutiveActions++;
        if (_charge.consecutiveActions > hs.chargeSettings.maxConsecutiveActions) {
            _charge.fatigueLevel += hs.chargeSettings.fatigueIncreaseRate * 2;
        } else {
            _charge.fatigueLevel += hs.chargeSettings.fatigueIncreaseRate;
        }

        if (_charge.fatigueLevel > LibHenomorphsStorage.MAX_FATIGUE_LEVEL) {
            _charge.fatigueLevel = LibHenomorphsStorage.MAX_FATIGUE_LEVEL;
        }

        if (_charge.currentCharge < _charge.maxCharge / 5) {
            _charge.consecutiveActions = 0;
        }

        // Notify Staking system of wear change
        if (hs.stakingSystemAddress != address(0)) {
            (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(_combinedId);
            try IStakingSystem(hs.stakingSystemAddress).notifyWearChange(collectionId, tokenId, _charge.fatigueLevel) {} catch {}
        }
    }

    function _processActionReward(uint256 collectionId, uint256 tokenId, uint8 actionId, uint256 _combinedId) private returns (uint256) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        PowerMatrix storage _charge = hs.performedCharges[_combinedId];
        ChargeActionType memory _action = hs.actionTypes[actionId];
        
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        
        uint256 _reward = _calculateReward(collectionId, _combinedId, _charge, _action, collection);
        
        _charge.seasonPoints += uint32(_reward / 10);
        hs.operatorSeasonPoints[LibMeta.msgSender()][hs.seasonCounter] += uint32(_reward / 10);
        
        _updateBiopod(collection, tokenId, _charge, _reward);
        
        return _reward;
    }

    function _calculateReward(
        uint256,
        uint256 _combinedId,
        PowerMatrix storage _charge,
        ChargeActionType memory _action,
        SpecimenCollection storage collection
    ) private view returns (uint256) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
    
        ChargeAccessory[] storage accessories = hs.equippedAccessories[_combinedId];
        uint256 accessoryCount = accessories.length;
        
        // Bound accessory count
        if (accessoryCount > 10) {
            accessoryCount = 0;
        }
        
        ChargeAccessory[] memory accessoryArray = new ChargeAccessory[](accessoryCount);
        
        for(uint i = 0; i < accessoryCount; i++) {
            accessoryArray[i] = accessories[i];
        }
        
        return ChargeCalculator.calculateActionReward(
            _charge,
            _action,
            collection,
            _combinedId,
            accessoryArray,
            hs.currentSeason
        );
    }

    function _updateBiopod(
        SpecimenCollection storage collection,
        uint256 tokenId,
        PowerMatrix storage _charge,
        uint256 _reward
    ) private {
        if (collection.biopodAddress != address(0)) {
            LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
            
            uint256 fatigueAmount = hs.chargeSettings.fatigueIncreaseRate;
            bool fatigueApplied = false;
            uint256 collectionId = hs.collectionIndexes[collection.collectionAddress];
            
            try ISpecimenBiopod(collection.biopodAddress).applyFatigue(collectionId, tokenId, fatigueAmount) returns (bool result) {
                fatigueApplied = result;
            } catch {}
            
            try ISpecimenBiopod(collection.biopodAddress).applyExperienceGain(
                collectionId,
                tokenId,
                _reward / 5
            ) {} catch {}
            
            try ISpecimenBiopod(collection.biopodAddress).updateChargeData(
                collectionId,
                tokenId, 
                _charge.currentCharge, 
                _charge.lastChargeTime
            ) {} catch {}
            
            if (!fatigueApplied) {
                try ISpecimenBiopod(collection.biopodAddress).probeCalibration(collectionId, tokenId) returns (Calibration memory cal) {
                    uint256 newWear = cal.wear + fatigueAmount;
                    if (newWear > 100) newWear = 100;
                    
                    try ISpecimenBiopod(collection.biopodAddress).updateWearData(collectionId, tokenId, newWear) {} catch {}
                } catch {}
            }
        }
    }
    
    function _applyStreakBonus(address user, uint8 actionId, uint256 baseReward) internal view returns (uint256) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        ChargeActionType storage actionType = hs.actionTypes[actionId];

        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        UserEngagement storage engagement = gs.userEngagement[user];
        
        if (actionType.streakBonusMultiplier == 0) {
            return baseReward;
        }
        
        if (engagement.streakMultiplier > 100) {
            uint256 streakBonus = Math.mulDiv(baseReward, engagement.streakMultiplier, 100);
            uint256 actionBonus = Math.mulDiv(streakBonus, actionType.streakBonusMultiplier, 100);
            return baseReward + (actionBonus - baseReward);
        }
        
        return baseReward;
    }

    function _applyFlashEventBonus(address user, uint8 actionId, uint256 baseReward) internal returns (uint256) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        FlashEvent storage flashEvent = gs.currentFlashEvent;
        
        if (!flashEvent.active || 
            block.timestamp > flashEvent.endTime ||
            flashEvent.currentParticipants >= flashEvent.maxParticipants ||
            (flashEvent.targetActionId != 0 && flashEvent.targetActionId != actionId)) {
            return baseReward;
        }
        
        ChargeActionType storage actionType = hs.actionTypes[actionId];
        if (!actionType.eligibleForSpecialEvents) {
            return baseReward;
        }
        
        uint256 flashBonus = Math.mulDiv(baseReward, flashEvent.bonusMultiplier, 100);
        
        FlashParticipation storage participation = gs.flashParticipations[user];
        if (participation.actionsPerformed == 0) {
            LibFeeCollection.processOperationFee(hs.chargeFees.eventFee, user);
            
            flashEvent.currentParticipants++;
            participation.participationTime = uint32(block.timestamp);
        }

        participation.actionsPerformed++;
        participation.rewardsEarned += flashBonus;
        participation.qualified = true;
        
        emit FlashEventParticipation(user, participation.actionsPerformed, flashBonus);
        
        return flashBonus;
    }

    function _applyGlobalMultiplier(uint256 baseReward) internal view returns (uint256) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        if (gs.globalGameState.globalMultiplier > 100) {
            return Math.mulDiv(baseReward, gs.globalGameState.globalMultiplier, 100);
        }
        
        return baseReward;
    }

    function _updateUserEngagement(address user, uint8 actionId) internal {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        uint32 today = uint32(block.timestamp / 86400);
        
        UserEngagement storage engagement = gs.userEngagement[user];
        
        if (engagement.lastActivityDay != today) {
            if (engagement.lastActivityDay == today - 1) {
                engagement.currentStreak++;
            } else if (engagement.lastActivityDay < today - 1) {
                engagement.currentStreak = 1;
            } else {
                engagement.currentStreak = 1;
            }
            
            engagement.streakMultiplier = uint128(100 + Math.min(engagement.currentStreak * 5, 100));
            
            if (engagement.currentStreak > engagement.longestStreak) {
                engagement.longestStreak = engagement.currentStreak;
            }
            
            engagement.lastActivityDay = today;
            
            emit StreakUpdated(user, engagement.currentStreak, engagement.streakMultiplier);
        }
        
        uint8 activityPoints = _getActionActivityPoints(actionId);
        engagement.totalLifetimeActions += activityPoints;
        
        gs.userTotalPlayTime[user] += 300;
    }

    function _getActionActivityPoints(uint8 actionId) internal view returns (uint8 activityPoints) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        activityPoints = hs.actionTypes[actionId].difficultyTier;
        
        if (activityPoints == 0) {
            if (actionId == 1) activityPoints = 1;
            else if (actionId == 2) activityPoints = 2;
            else if (actionId == 3) activityPoints = 3;
            else if (actionId == 4) activityPoints = 4;
            else if (actionId == 5) activityPoints = 5;
            else activityPoints = 1;
        }
        
        return activityPoints;
    }

    function _updateDailyChallenges(address user, uint8 actionId) internal {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        uint32 today = uint32(block.timestamp / 86400);
        DailyChallengeSet storage challengeSet = gs.dailyChallenges[user];
        
        if (challengeSet.dayIssued != today) {
            _generateDailyChallenges(user, today);
        }
        
        for (uint i = 0; i < 3; i++) {
            if (challengeSet.challenges[i].completed) continue;
            
            bool shouldUpdate = false;
            
            if (challengeSet.challenges[i].challengeType == 1) {
                if (challengeSet.challenges[i].targetActionId == 0 || challengeSet.challenges[i].targetActionId == actionId) {
                    shouldUpdate = true;
                }
            } else if (challengeSet.challenges[i].challengeType == 2) {
                shouldUpdate = true;
            } else if (challengeSet.challenges[i].challengeType == 3 && actionId == 5) {
                shouldUpdate = true;
            }
            
            if (shouldUpdate) {
                challengeSet.challenges[i].currentProgress++;
                
                if (challengeSet.challenges[i].currentProgress >= challengeSet.challenges[i].targetValue) {
                    challengeSet.challenges[i].completed = true;
                    challengeSet.challenges[i].completedAt = uint32(block.timestamp);
                    challengeSet.completedCount++;

                    LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
                    LibFeeCollection.processOperationFee(hs.chargeFees.eventFee, user);
                    
                    emit DailyChallengeCompleted(user, i, challengeSet.challenges[i].rewardAmount);
                    
                    if (challengeSet.completedCount == 3 && challengeSet.bonusReward > 0) {
                        emit AllDailyChallengesCompleted(user, challengeSet.bonusReward);
                    }
                }
            }
        }
    }

    function _checkAchievementProgress(address user, uint8, uint256 rewardEarned) internal {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        UserEngagement storage engagement = gs.userEngagement[user];
        
        _checkStreakAchievements(user, engagement.currentStreak);
        _checkLifetimeActionAchievements(user, engagement.totalLifetimeActions);
        
        engagement.lifetimeRewards += rewardEarned;
    }

    function _generateDailyChallenges(address user, uint32 today) internal {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        DailyChallengeSet storage challengeSet = gs.dailyChallenges[user];
        
        challengeSet.dayIssued = today;
        challengeSet.completedCount = 0;
        challengeSet.bonusClaimed = false;
        challengeSet.difficultyLevel = _calculateUserDifficulty(user);
        challengeSet.streakBonus = _calculateStreakBonus(user);
        
        uint256[3] memory rewardAmounts = [
            BASE_ZICO_REWARD * 15 / 10,
            BASE_ZICO_REWARD * 25 / 10,  
            BASE_ZICO_REWARD * 30 / 10
        ];
        
        challengeSet.bonusReward = BASE_ZICO_REWARD * 2;
        
        for (uint i = 0; i < 3; i++) {
            challengeSet.challenges[i] = DailyChallenge({
                challengeType: uint8(1 + (i % 3)),
                targetActionId: uint8((i + today) % 5 + 1),
                targetValue: uint32(3 + i + challengeSet.difficultyLevel),
                currentProgress: 0,
                rewardAmount: rewardAmounts[i],
                bonusMultiplier: uint16(110 + (i * 5)),
                timeLimit: 0,
                completed: false,
                claimed: false,
                completedAt: 0,
                difficulty: challengeSet.difficultyLevel,
                personalizedModifier: _getPersonalizedModifier(user, uint8(i))
            });
        }
    }

    function _calculateUserDifficulty(address user) internal view returns (uint8 difficulty) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        UserEngagement storage engagement = gs.userEngagement[user];
        
        if (engagement.totalLifetimeActions >= 1000 && engagement.currentStreak >= 14) {
            difficulty = 5;
        } else if (engagement.totalLifetimeActions >= 500 && engagement.currentStreak >= 7) {
            difficulty = 4;
        } else if (engagement.totalLifetimeActions >= 200 && engagement.currentStreak >= 3) {
            difficulty = 3;
        } else if (engagement.totalLifetimeActions >= 50) {
            difficulty = 2;
        } else {
            difficulty = 1;
        }
        
        return difficulty;
    }

    function _calculateStreakBonus(address user) internal view returns (uint256 bonus) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        UserEngagement storage engagement = gs.userEngagement[user];
        
        if (engagement.currentStreak >= 30) {
            bonus = 200;
        } else if (engagement.currentStreak >= 14) {
            bonus = 100;
        } else if (engagement.currentStreak >= 7) {
            bonus = 50;
        } else {
            bonus = 0;
        }
        
        return bonus;
    }

    function _getPersonalizedModifier(address user, uint8) internal view returns (uint16 mod) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        UserEngagement storage engagement = gs.userEngagement[user];
        
        if (engagement.favoriteAction > 0) {
            mod = 105;
        } else {
            mod = 100;
        }
        
        return mod;
    }

    function _checkStreakAchievements(address user, uint32 currentStreak) internal {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        uint256[] memory streakMilestones = new uint256[](3);
        streakMilestones[0] = 7;
        streakMilestones[1] = 14;
        streakMilestones[2] = 30;
        
        for (uint i = 0; i < streakMilestones.length; i++) {
            if (currentStreak >= streakMilestones[i]) {
                uint256 achievementId = 1000 + i;
                
                if (!gs.userAchievements[user][achievementId].hasEarned) {
                    gs.userAchievements[user][achievementId].hasEarned = true;
                    gs.userAchievements[user][achievementId].earnedAt = uint32(block.timestamp);
                    
                    emit AchievementEarned(user, achievementId, 200 + (i * 100));
                }
            }
        }
    }

    function _checkLifetimeActionAchievements(address user, uint256 totalActions) internal {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        uint256[] memory actionMilestones = new uint256[](3);
        actionMilestones[0] = 100;
        actionMilestones[1] = 500;
        actionMilestones[2] = 1000;
        
        for (uint i = 0; i < actionMilestones.length; i++) {
            if (totalActions >= actionMilestones[i]) {
                uint256 achievementId = 2000 + i;
                
                if (!gs.userAchievements[user][achievementId].hasEarned) {
                    gs.userAchievements[user][achievementId].hasEarned = true;
                    gs.userAchievements[user][achievementId].earnedAt = uint32(block.timestamp);

                    try IRankingFacet(address(this)).trackAchievementEarned(user, achievementId) {
                        // Achievement tracked successfully
                    } catch {
                        // Fail gracefully - don't break core functionality
                    }
                    
                    emit AchievementEarned(user, achievementId, 300 + (i * 150));
                }
            }
        }
    }
}