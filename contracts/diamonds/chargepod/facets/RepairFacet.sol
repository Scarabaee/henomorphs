// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibBiopodIntegration} from "../../staking/libraries/LibBiopodIntegration.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {PodsUtils} from "../../../libraries/PodsUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ControlFee, SpecimenCollection, PowerMatrix, Calibration} from "../../../libraries/HenomorphsModel.sol";
import {ISpecimenBiopod} from "../../../interfaces/ISpecimenBiopod.sol";
import {AccessHelper} from "../../staking/libraries/AccessHelper.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {LibFeeCollection} from "../../staking/libraries/LibFeeCollection.sol";
import {ChargeCalculator} from "../libraries/ChargeCalculator.sol";
import {IStakingSystem, IExternalCollection} from "../../staking/interfaces/IStakingInterfaces.sol";

/**
 * @title RepairFacet 
 * @notice Unified, gas-optimized repair system for henomorphs
 * @dev Integrates seamlessly with BiopodFacet and provides advanced repair features
 */
contract RepairFacet is AccessControlBase {
    using Math for uint256;
    
    // Packed struct for repair operations to save gas
    struct RepairOperation {
        uint128 chargePoints;
        uint128 wearReduction;
        bool emergencyMode;
        bool skipValidation;
    }
    
    struct RepairResult {
        uint256 actualChargeRestored;
        uint256 actualWearReduced;
        uint256 totalCost;
        bool chargeSuccess;
        bool wearSuccess;
    }
    
    // Events
    event ChargeRepaired(uint256 indexed collectionId, uint256 indexed tokenId, uint256 pointsRepaired, uint256 cost);
    event WearRepaired(uint256 indexed collectionId, uint256 indexed tokenId, uint256 wearReduced, uint256 cost);
    event CombinedRepairCompleted(uint256 indexed collectionId, uint256 indexed tokenId, uint256 chargeRestored, uint256 wearReduced, uint256 totalCost);
    event ChargeBoostActivated(uint256 indexed collectionId, uint256 indexed tokenId, uint256 duration, uint256 boostAmount);
    event RepairModeChanged(uint256 indexed collectionId, uint256 indexed tokenId, bool repairMode);
    event EmergencyRepairExecuted(uint256 indexed collectionId, uint256 indexed tokenId, address admin, string reason);
    event BatchRepairCompleted(uint256 successCount, uint256 failedCount);

    error InsufficientRepairPoints();
    error HenomorphInRepairMode();
    error HenomorphFullyRepaired();
    error InvalidRepairAmount();
    error RepairOperationFailed(string reason);
    error BatchSizeTooLarge();

    // Constants for gas optimization
    uint256 private constant MAX_REPAIR_AMOUNT = 100;
    uint256 private constant MAX_BATCH_SIZE = 20;
    uint256 private constant COMBINED_REPAIR_DISCOUNT = 10; // 10%
    uint256 private constant WEAR_REPAIR_MULTIPLIER = 2; // 2x cost of charge repair

    /**
     * @notice Single entry point for all repair operations
     * @param collectionId Collection ID
     * @param tokenId Henomorph token ID  
     * @param operation Packed repair operation data
     */
    function executeRepair(
        uint256 collectionId,
        uint256 tokenId,
        RepairOperation memory operation
    ) public nonReentrant returns (RepairResult memory result) {
        // Unified permission check
        if (!operation.skipValidation) {
            _checkRepairPermissions(collectionId, tokenId);
        }
        
        // Validate inputs
        if ((operation.chargePoints == 0 && operation.wearReduction == 0) ||
            operation.chargePoints > MAX_REPAIR_AMOUNT || 
            operation.wearReduction > MAX_REPAIR_AMOUNT) {
            revert InvalidRepairAmount();
        }

        // Execute repairs
        if (operation.chargePoints > 0) {
            (result.chargeSuccess, result.actualChargeRestored) = _executeChargeRepair(
                collectionId, 
                tokenId, 
                operation.chargePoints,
                operation.emergencyMode
            );
        }
        
        if (operation.wearReduction > 0) {
            (result.wearSuccess, result.actualWearReduced) = _executeWearRepair(
                collectionId, 
                tokenId, 
                operation.wearReduction,
                operation.emergencyMode
            );
        }
        
        // Calculate and collect fees
        if (!operation.emergencyMode) {
            result.totalCost = _calculateAndCollectFee(
                result.actualChargeRestored,
                result.actualWearReduced,
                operation.chargePoints > 0 && operation.wearReduction > 0 // isCombined
            );
        }
        
        // Emit appropriate events
        _emitRepairEvents(collectionId, tokenId, result, operation);
        
        return result;
    }

    /**
     * @notice Simplified charge-only repair
     */
    function repairCharge(
        uint256 collectionId, 
        uint256 tokenId, 
        uint256 chargePoints
    ) external returns (uint256 actualRepaired) {
        RepairOperation memory op = RepairOperation({
            chargePoints: uint128(chargePoints),
            wearReduction: 0,
            emergencyMode: false,
            skipValidation: false
        });
        
        RepairResult memory result = executeRepair(collectionId, tokenId, op);
        return result.actualChargeRestored;
    }

    /**
     * @notice Simplified wear-only repair
     */
    function repairWear(
        uint256 collectionId, 
        uint256 tokenId, 
        uint256 wearReduction
    ) external returns (uint256 actualReduced) {
        RepairOperation memory op = RepairOperation({
            chargePoints: 0,
            wearReduction: uint128(wearReduction),
            emergencyMode: false,
            skipValidation: false
        });
        
        RepairResult memory result = executeRepair(collectionId, tokenId, op);
        return result.actualWearReduced;
    }

    /**
     * @notice Combined repair with automatic discount
     */
    function combinedRepair(
        uint256 collectionId,
        uint256 tokenId,
        uint256 chargePoints,
        uint256 wearReduction
    ) external returns (RepairResult memory) {
        RepairOperation memory op = RepairOperation({
            chargePoints: uint128(chargePoints),
            wearReduction: uint128(wearReduction),
            emergencyMode: false,
            skipValidation: false
        });
        
        return executeRepair(collectionId, tokenId, op);
    }

    /**
     * @notice Batch repair multiple henomorphs
     * @param collectionIds Array of collection IDs
     * @param tokenIds Array of token IDs
     * @param operations Array of repair operations
     */
    function batchRepair(
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds,
        RepairOperation[] calldata operations
    ) external onlyAuthorized returns (uint256 successCount) {
        uint256 length = collectionIds.length;

        if (length != tokenIds.length || length != operations.length || length > MAX_BATCH_SIZE) {
            revert BatchSizeTooLarge();
        }

        uint256 failedCount = 0;

        for (uint256 i = 0; i < length;) {
            try this.executeRepair(collectionIds[i], tokenIds[i], operations[i]) {
                unchecked { ++successCount; }
            } catch {
                unchecked { ++failedCount; }
            }
            unchecked { ++i; }
        }

        emit BatchRepairCompleted(successCount, failedCount);
        return successCount;
    }

    /**
     * @notice Batch combined repair with automatic discount
     * @param collectionIds Array of collection IDs
     * @param tokenIds Array of token IDs
     * @param chargePoints Array of charge points to repair
     * @param wearReduction Array of wear reduction amounts
     * @return successCount Number of successful repairs
     * @return totalCost Total cost across all repairs
     */
    function batchCombinedRepair(
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds,
        uint256[] calldata chargePoints,
        uint256[] calldata wearReduction
    ) external nonReentrant returns (uint256 successCount, uint256 totalCost) {
        uint256 length = collectionIds.length;

        if (length != tokenIds.length || length != chargePoints.length ||
            length != wearReduction.length || length > MAX_BATCH_SIZE) {
            revert BatchSizeTooLarge();
        }

        if (length == 0) {
            revert LibHenomorphsStorage.InvalidCallData();
        }

        uint256 failedCount = 0;

        for (uint256 i = 0; i < length;) {
            RepairOperation memory op = RepairOperation({
                chargePoints: uint128(chargePoints[i]),
                wearReduction: uint128(wearReduction[i]),
                emergencyMode: false,
                skipValidation: false
            });

            try this.executeRepair(collectionIds[i], tokenIds[i], op) returns (RepairResult memory result) {
                if (result.chargeSuccess || result.wearSuccess) {
                    unchecked {
                        ++successCount;
                        totalCost += result.totalCost;
                    }
                } else {
                    unchecked { ++failedCount; }
                }
            } catch {
                unchecked { ++failedCount; }
            }

            unchecked { ++i; }
        }

        emit BatchRepairCompleted(successCount, failedCount);
        return (successCount, totalCost);
    }

    /**
     * @notice Repair multiple tokens with uniform wear reduction
     * @param collectionIds Array of collection IDs
     * @param tokenIds Array of token IDs
     * @param wearAmount Uniform wear reduction for all tokens (1-100)
     * @return successCount Number of successful repairs
     * @return totalCost Total cost of all repairs
     */
    function repairMultipleWear(
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds,
        uint256 wearAmount
    ) 
        external 
        nonReentrant 
        returns (uint256 successCount, uint256 totalCost) 
    {
        // Input validation
        if (collectionIds.length == 0 || collectionIds.length > MAX_BATCH_SIZE) {
            revert BatchSizeTooLarge();
        }
        
        if (collectionIds.length != tokenIds.length) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        if (wearAmount == 0 || wearAmount > MAX_REPAIR_AMOUNT) {
            revert InvalidRepairAmount();
        }
        
        uint256 failedCount = 0;
        
        for (uint256 i = 0; i < collectionIds.length;) {
            RepairOperation memory op = RepairOperation({
                chargePoints: 0,
                wearReduction: uint128(wearAmount),
                emergencyMode: false,
                skipValidation: false
            });
            
            try this.executeRepair(collectionIds[i], tokenIds[i], op) returns (RepairResult memory result) {
                if (result.wearSuccess) {
                    unchecked { 
                        ++successCount;
                        totalCost += result.totalCost;
                    }
                } else {
                    unchecked { ++failedCount; }
                }
            } catch {
                unchecked { ++failedCount; }
            }
            
            unchecked { ++i; }
        }
        
        emit BatchRepairCompleted(successCount, failedCount);
        return (successCount, totalCost);
    }

    /**
     * @notice Emergency repair - admin only, no fees
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param chargePoints Charge to restore
     * @param wearReduction Wear to reduce
     * @param reason Reason for emergency repair
     */
    function emergencyRepair(
        uint256 collectionId,
        uint256 tokenId,
        uint256 chargePoints,
        uint256 wearReduction,
        string calldata reason
    ) external onlyAuthorized {
        RepairOperation memory op = RepairOperation({
            chargePoints: uint128(chargePoints),
            wearReduction: uint128(wearReduction),
            emergencyMode: true,
            skipValidation: true
        });
        
        executeRepair(collectionId, tokenId, op);
        
        emit EmergencyRepairExecuted(collectionId, tokenId, LibMeta.msgSender(), reason);
    }

    /**
     * @notice Optimized charge boost with dynamic pricing
     */
    function activateChargeBoost(
        uint256 collectionId, 
        uint256 tokenId, 
        uint256 period
    ) external nonReentrant {
        if (period == 0 || period > 72) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        _checkRepairPermissions(collectionId, tokenId);
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage charge = hs.performedCharges[combinedId];
        
        if (charge.lastChargeTime == 0) { 
            revert LibHenomorphsStorage.PowerCoreNotActivated(collectionId, tokenId);
        }
        
        // Dynamic pricing based on current boost status
        uint256 periodHours = period;
        if (charge.boostEndTime > block.timestamp) {
            periodHours = (periodHours * 120) / 100; // 20% more if extending
        }
        
        // Use dual token boost fee (YELLOW with burn)
        LibColonyWarsStorage.OperationFee storage chargeBoostFee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_CHARGE_BOOST);
        LibFeeCollection.processOperationFee(
            chargeBoostFee.currency,
            chargeBoostFee.beneficiary,
            chargeBoostFee.baseAmount,
            chargeBoostFee.multiplier,
            chargeBoostFee.burnOnCollect,
            chargeBoostFee.enabled,
            LibMeta.msgSender(),
            periodHours,  // multiplier per hour
            "charge_boost"
        );
        
        // Apply boost
        uint256 boostDuration = period * 3600;
        charge.boostEndTime = charge.boostEndTime > block.timestamp 
            ? uint32(charge.boostEndTime + boostDuration)
            : uint32(block.timestamp + boostDuration);
        
        emit ChargeBoostActivated(collectionId, tokenId, boostDuration, LibHenomorphsStorage.CHARGE_BOOST_PERCENTAGE);
    }

    /**
     * @notice Predict repair costs and effects before execution
     */
    function predictRepair(
        uint256 collectionId,
        uint256 tokenId,
        uint256 chargePoints,
        uint256 wearReduction
    ) external view returns (
        uint256 actualChargeRepair,
        uint256 actualWearRepair,
        uint256 totalCost,
        bool chargeNeeded,
        bool wearNeeded
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage charge = hs.performedCharges[combinedId];
        
        // Predict charge repair
        if (chargePoints > 0 && charge.lastChargeTime > 0) {
            uint256 missingCharge = charge.maxCharge - charge.currentCharge;
            actualChargeRepair = chargePoints > missingCharge ? missingCharge : chargePoints;
            chargeNeeded = missingCharge > 0;
        }
        
        // UPDATED: Predict wear repair using unified wear level
        if (wearReduction > 0) {
            (uint256 currentWear, ) = LibBiopodIntegration.getUnifiedWearLevel(collectionId, tokenId);
            actualWearRepair = wearReduction > currentWear ? currentWear : wearReduction;
            wearNeeded = currentWear > 0;
        }
        
        // Calculate costs using existing cost calculation
        totalCost = _calculateRepairCost(actualChargeRepair, actualWearRepair, chargePoints > 0 && wearReduction > 0);
        
        return (actualChargeRepair, actualWearRepair, totalCost, chargeNeeded, wearNeeded);
    }

    // =================== ADMIN FUNCTIONS ===================

    function setRepairMode(uint256 collectionId, uint256 tokenId, bool repairMode) external onlyAuthorized {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage charge = hs.performedCharges[combinedId];
        
        if (charge.lastChargeTime == 0) { 
            revert LibHenomorphsStorage.PowerCoreNotActivated(collectionId, tokenId);
        }
        
        charge.flags = repairMode ? charge.flags | 1 : charge.flags & ~uint8(1);
        emit RepairModeChanged(collectionId, tokenId, repairMode);
    }

    function adminBoost(uint256 collectionId, uint256 tokenId, uint256 period) external onlyAuthorized {
        if (period == 0 || period > 168) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage charge = hs.performedCharges[combinedId];
        
        if (charge.lastChargeTime == 0) { 
            revert LibHenomorphsStorage.PowerCoreNotActivated(collectionId, tokenId);
        }
        
        uint256 boostDuration = period * 3600;
        charge.boostEndTime = charge.boostEndTime > block.timestamp 
            ? uint32(charge.boostEndTime + boostDuration)
            : uint32(block.timestamp + boostDuration);
        
        emit ChargeBoostActivated(collectionId, tokenId, boostDuration, LibHenomorphsStorage.CHARGE_BOOST_PERCENTAGE);
    }

    // =================== VIEW FUNCTIONS ===================

    function isInRepairMode(uint256 collectionId, uint256 tokenId) external view returns (bool) {
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage charge = LibHenomorphsStorage.henomorphsStorage().performedCharges[combinedId];
        
        if (charge.lastChargeTime == 0) { 
            revert LibHenomorphsStorage.PowerCoreNotActivated(collectionId, tokenId);
        }
        
        return (charge.flags & 1) != 0;
    }
    
    function getBoostEndTime(uint256 collectionId, uint256 tokenId) external view returns (uint256) {
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage charge = LibHenomorphsStorage.henomorphsStorage().performedCharges[combinedId];
        
        if (charge.lastChargeTime == 0) { 
            revert LibHenomorphsStorage.PowerCoreNotActivated(collectionId, tokenId);
        }
        
        return charge.boostEndTime > block.timestamp ? charge.boostEndTime : 0;
    }

    function getRepairStatus(uint256 collectionId, uint256 tokenId) external view returns (
        uint256 currentCharge,
        uint256 maxCharge,
        uint256 currentWear,
        bool inRepairMode,
        uint256 boostEndTime
    ) {
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage charge = LibHenomorphsStorage.henomorphsStorage().performedCharges[combinedId];
        
        if (charge.lastChargeTime == 0) { 
            return (0, 0, 0, false, 0);
        }
        
        currentCharge = charge.currentCharge;
        maxCharge = charge.maxCharge;
        (currentWear,) = LibBiopodIntegration.getStakingWearLevel(collectionId, tokenId);
        inRepairMode = (charge.flags & 1) != 0;
        boostEndTime = charge.boostEndTime > block.timestamp ? charge.boostEndTime : 0;
        
        return (currentCharge, maxCharge, currentWear, inRepairMode, boostEndTime);
    }

    // =================== INTERNAL FUNCTIONS ===================

    function _executeChargeRepair(
        uint256 collectionId,
        uint256 tokenId,
        uint256 chargePoints,
        bool emergencyMode
    ) internal returns (bool success, uint256 actualRepaired) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage charge = hs.performedCharges[combinedId];

        // Auto-initialize power core if not activated
        if (charge.lastChargeTime == 0) {
            _autoInitializePowerCore(collectionId, tokenId, hs, charge);

            // After initialization, check if it succeeded
            if (charge.lastChargeTime == 0) {
                return (false, 0);
            }
        }

        if (!emergencyMode && (charge.flags & 1) != 0) {
            return (false, 0);
        }

        // Recalibrate charge
        _recalibrateChargeInternal(charge, hs);

        uint256 missingCharge = charge.maxCharge - charge.currentCharge;
        if (missingCharge == 0) {
            return (false, 0);
        }

        actualRepaired = chargePoints > missingCharge ? missingCharge : chargePoints;

        // Apply repair
        charge.currentCharge += uint128(actualRepaired);

        // Reduce fatigue proportionally
        if (charge.fatigueLevel > 0) {
            uint256 fatigueReduction = Math.mulDiv(actualRepaired, charge.fatigueLevel, charge.maxCharge);
            charge.fatigueLevel = charge.fatigueLevel > uint8(fatigueReduction)
                ? charge.fatigueLevel - uint8(fatigueReduction)
                : 0;
        }

        // Reset consecutive actions for significant repairs
        if (actualRepaired >= charge.maxCharge / 4) {
            charge.consecutiveActions = 0;
        }

        // Sync with biopod
        _syncRepairWithBiopod(collectionId, tokenId, charge);

        return (true, actualRepaired);
    }

    function _executeWearRepair(
        uint256 collectionId,
        uint256 tokenId,
        uint256 wearReduction,
        bool emergencyMode
    ) internal returns (bool success, uint256 actualReduced) {
        // UPDATED: Check current wear level using unified function
        (uint256 currentWear, ) = LibBiopodIntegration.getUnifiedWearLevel(collectionId, tokenId);

        if (currentWear == 0) {
            return (false, 0);
        }

        actualReduced = wearReduction > currentWear ? currentWear : wearReduction;

        // Apply wear repair for staked tokens
        bool repairSuccess = LibBiopodIntegration.applyWearRepair(collectionId, tokenId, actualReduced);

        // Emergency mode always succeeds
        if (emergencyMode && !repairSuccess) {
            repairSuccess = true;
        }

        // Notify Staking system of wear change (if applicable)
        if (repairSuccess) {
            LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
            if (hs.stakingSystemAddress != address(0)) {
                uint256 newWear = currentWear > actualReduced ? currentWear - actualReduced : 0;
                try IStakingSystem(hs.stakingSystemAddress).notifyWearChange(collectionId, tokenId, newWear) {} catch {}
            }
        }

        return (repairSuccess, repairSuccess ? actualReduced : 0);
    }

    function _calculateAndCollectFee(
        uint256 chargeRepaired,
        uint256 wearReduced,
        bool /* isCombined */
    ) internal returns (uint256 totalCost) {
        LibColonyWarsStorage.OperationFee storage chargeRepairFee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_CHARGE_REPAIR);
        LibColonyWarsStorage.OperationFee storage wearRepairFee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_WEAR_REPAIR);
        address user = LibMeta.msgSender();

        // Process charge repair fee (YELLOW with burn)
        if (chargeRepaired > 0) {
            LibFeeCollection.processOperationFee(
                chargeRepairFee.currency,
                chargeRepairFee.beneficiary,
                chargeRepairFee.baseAmount,
                chargeRepairFee.multiplier,
                chargeRepairFee.burnOnCollect,
                chargeRepairFee.enabled,
                user,
                chargeRepaired,  // multiplier per point
                "charge_repair"
            );
        }

        // Process wear repair fee (YELLOW with burn, 2x multiplier)
        if (wearReduced > 0) {
            LibFeeCollection.processOperationFee(
                wearRepairFee.currency,
                wearRepairFee.beneficiary,
                wearRepairFee.baseAmount,
                wearRepairFee.multiplier,  // Already 2x (200)
                wearRepairFee.burnOnCollect,
                wearRepairFee.enabled,
                user,
                wearReduced,  // multiplier per point
                "wear_repair"
            );
        }

        // Calculate total for return (for events/tracking)
        uint256 chargeCost = (chargeRepairFee.baseAmount * chargeRepairFee.multiplier * chargeRepaired) / 100;
        uint256 wearCost = (wearRepairFee.baseAmount * wearRepairFee.multiplier * wearReduced) / 100;
        totalCost = chargeCost + wearCost;

        return totalCost;
    }

    function _calculateRepairCost(
        uint256 chargeRepaired,
        uint256 wearReduced,
        bool isCombined
    ) internal view returns (uint256 totalCost) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        uint256 chargeCost = chargeRepaired * hs.chargeFees.repairFee.amount;
        uint256 wearCost = wearReduced * hs.chargeFees.repairFee.amount * WEAR_REPAIR_MULTIPLIER;
        
        totalCost = chargeCost + wearCost;
        
        if (isCombined && chargeRepaired > 0 && wearReduced > 0) {
            totalCost = Math.mulDiv(totalCost, 100 - COMBINED_REPAIR_DISCOUNT, 100);
        }
        
        return totalCost;
    }

    function _emitRepairEvents(
        uint256 collectionId,
        uint256 tokenId,
        RepairResult memory result,
        RepairOperation memory operation
    ) internal {
        if (result.chargeSuccess && result.actualChargeRestored > 0) {
            emit ChargeRepaired(collectionId, tokenId, result.actualChargeRestored, 
                result.actualChargeRestored * LibHenomorphsStorage.henomorphsStorage().chargeFees.repairFee.amount);
        }
        
        if (result.wearSuccess && result.actualWearReduced > 0) {
            emit WearRepaired(collectionId, tokenId, result.actualWearReduced,
                result.actualWearReduced * LibHenomorphsStorage.henomorphsStorage().chargeFees.repairFee.amount * WEAR_REPAIR_MULTIPLIER);
        }
        
        if (operation.chargePoints > 0 && operation.wearReduction > 0) {
            emit CombinedRepairCompleted(collectionId, tokenId, result.actualChargeRestored, result.actualWearReduced, result.totalCost);
        }
    }

    function _checkRepairPermissions(uint256 collectionId, uint256 tokenId) internal view {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        if (!collection.enabled) {
            revert LibHenomorphsStorage.CollectionNotEnabled(collectionId);
        }
        
        if (AccessHelper.isAuthorized()) {
            return;
        }
        
        if (!AccessHelper.checkTokenOwnership(collectionId, tokenId, LibMeta.msgSender(), hs.stakingSystemAddress)) {
            revert LibHenomorphsStorage.HenomorphControlForbidden(collectionId, tokenId);
        }
    }

    function _recalibrateChargeInternal(
        PowerMatrix storage charge,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) internal {
        uint256 elapsedTime = block.timestamp - charge.lastChargeTime;
        
        if (elapsedTime > 0 && charge.currentCharge < charge.maxCharge && (charge.flags & 1) == 0) {
            charge.currentCharge = uint128(ChargeCalculator.calculateChargeRegen(
                charge,
                elapsedTime,
                hs.chargeEventEnd,
                hs.chargeEventBonus
            ));
        }
        
        // Fatigue recovery
        if (charge.fatigueLevel > 0 && elapsedTime > 0) {
            uint256 fatigueReduction = (elapsedTime * hs.chargeSettings.fatigueRecoveryRate) / 3600;
            charge.fatigueLevel = charge.fatigueLevel > uint8(fatigueReduction) 
                ? charge.fatigueLevel - uint8(fatigueReduction) 
                : 0;
        }
        
        charge.lastChargeTime = uint32(block.timestamp);
    }

    function _syncRepairWithBiopod(
        uint256 collectionId,
        uint256 tokenId,
        PowerMatrix storage charge
    ) internal {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];

        if (collection.biopodAddress != address(0)) {
            try ISpecimenBiopod(collection.biopodAddress).updateChargeData(
                collectionId,
                tokenId,
                charge.currentCharge,
                charge.lastChargeTime
            ) {} catch {
                // Graceful fallback - attempt alternative sync
                try ISpecimenBiopod(collection.biopodAddress).probeCalibration(collectionId, tokenId) returns (Calibration memory cal) {
                    try ISpecimenBiopod(collection.biopodAddress).updateCalibrationStatus(
                        collectionId,
                        tokenId, cal.level, cal.wear
                    ) {} catch {}
                } catch {}
            }
        }
    }

    /**
     * @notice Auto-initialize power core for tokens that haven't been activated
     * @dev This allows repair to work without requiring separate activation step
     */
    function _autoInitializePowerCore(
        uint256 collectionId,
        uint256 tokenId,
        LibHenomorphsStorage.HenomorphsStorage storage hs,
        PowerMatrix storage charge
    ) internal {
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];

        uint8 variant = 0;
        uint256 initialCharge = 100;

        // Try to get token variant
        try IExternalCollection(collection.collectionAddress).itemVariant(tokenId) returns (uint8 v) {
            variant = v;
        } catch {
            // Fallback: assume variant 2 (most common)
            variant = 2;
        }

        // Validate variant
        if (variant == 0 || variant > 4) {
            return; // Token not minted/revealed or invalid
        }

        // Try to get calibration from Biopod
        if (collection.biopodAddress != address(0)) {
            try ISpecimenBiopod(collection.biopodAddress).probeCalibration(collectionId, tokenId) returns (Calibration memory cal) {
                initialCharge = cal.charge > 0 ? cal.charge : 100;
            } catch {}
        }

        // Calculate initial stats
        uint256 baseMaxCharge = 80 + (variant * 5) + collection.maxChargeBonus;
        uint256 adjustedRegenRate = hs.chargeSettings.baseRegenRate + variant;
        adjustedRegenRate = Math.mulDiv(adjustedRegenRate, collection.regenMultiplier, 100);

        // Initialize PowerMatrix
        charge.currentCharge = uint128(initialCharge);
        charge.maxCharge = uint128(baseMaxCharge);
        charge.lastChargeTime = uint32(block.timestamp);
        charge.regenRate = uint16(adjustedRegenRate);
        charge.fatigueLevel = 0;
        charge.boostEndTime = 0;
        charge.chargeEfficiency = 100;
        charge.consecutiveActions = 0;
        charge.flags = 0;
        charge.specialization = 0;
        charge.seasonPoints = 0;
        charge.evolutionLevel = 1;
        charge.evolutionXP = 0;
        charge.masteryPoints = 0;
        charge.kinship = 50;
        charge.prowess = 1;
        charge.agility = 10;
        charge.intelligence = 10;
        charge.calibrationCount = 0;
        charge.lastInteraction = 0;
    }
}