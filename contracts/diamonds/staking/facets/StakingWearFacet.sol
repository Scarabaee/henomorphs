// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibStakingStorage} from "../libraries/LibStakingStorage.sol";
import {LibBiopodIntegration} from "../libraries/LibBiopodIntegration.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {PodsUtils} from "../../libraries/PodsUtils.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {StakedSpecimen, ControlFee} from "../../libraries/StakingModel.sol";
import {Calibration, SpecimenCollection, ChargeAccessory} from "../../libraries/HenomorphsModel.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {IExternalBiopod, IExternalAccessory, IExternalCollection} from "../interfaces/IStakingInterfaces.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title StakingWearFacet
 * @notice Facet for handling wear management in staking system
 * @dev Integrates with Biopod wear system with standardized fee handling
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract StakingWearFacet is AccessControlBase {
    /**
     * @notice Parameters for batch repair operations
     */
    struct BatchRepairParams {
        uint256[] collectionIds;    // Array of collection IDs
        uint256[] tokenIds;         // Array of token IDs
        uint256 repairAmount;       // Single repair amount (if uniform)
        uint256[] repairAmounts;    // Individual repair amounts (if not uniform)
        bool uniformRepair;         // Whether to use single amount for all
    }

    // Events
    event WearUpdated(uint256 indexed collectionId, uint256 indexed tokenId, uint256 oldWear, uint256 newWear);
    event WearRepaired(uint256 indexed collectionId, uint256 indexed tokenId, uint256 repairAmount, uint256 newWear);
    event AutoRepairApplied(uint256 indexed collectionId, uint256 indexed tokenId, uint256 repairAmount, uint256 cost);
    event RepairFeeCollected(address from, address beneficiary, uint256 amount);
    event OperationResult(string operation, bool success);
    event WearSystemConfigured(
        uint256 wearIncreasePerDay, 
        uint256 repairCostPerPoint, 
        bool autoRepairEnabled
    );
    event WearPenaltySettingsUpdated(uint8[] thresholds, uint8[] penalties);
    event BatchWearRepairCompleted(address sender, uint256 successCount, uint256 totalCost);
    
    // Errors
    error InvalidCollectionId();
    error TokenNotStaked();
    error UnauthorizedCaller();
    error InsufficientFunds();
    error RepairFailed();
    error InvalidWearAmount();
    error TransferFailed();
    error InvalidCallData();
    
    /**
     * @notice Receive wear change notification from Chargepod
     * @dev Called by Chargepod Diamond when wear changes
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param newWear New wear level (0-100)
     */
    function notifyWearChange(uint256 collectionId, uint256 tokenId, uint256 newWear) external {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        // Only accept from configured Chargepod system
        if (msg.sender != ss.chargeSystemAddress) {
            return;
        }

        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];

        // Only update if token is staked
        if (!staked.staked) {
            return;
        }

        uint8 oldWear = staked.wearLevel;
        uint8 cappedWear = uint8(newWear > 100 ? 100 : newWear);

        staked.wearLevel = cappedWear;
        staked.wearPenalty = uint8(LibStakingStorage.calculateWearPenalty(cappedWear));
        staked.lastWearUpdateTime = uint32(block.timestamp);

        emit WearUpdated(collectionId, tokenId, oldWear, cappedWear);
    }

    /**
     * @notice Update wear data from Biopod with improved error handling
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return success Whether update was successful
     */
    function updateWearFromBiopod(uint256 collectionId, uint256 tokenId) external returns (bool success) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Validate collection ID
        if (collectionId == 0 || collectionId > ss.collectionCounter) {
            revert InvalidCollectionId();
        }
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        // Check if token is staked
        if (!staked.staked) {
            revert TokenNotStaked();
        }
        
        // UPDATED: Get unified wear level
        (uint256 newWear,) = LibBiopodIntegration.getUnifiedWearLevel(collectionId, tokenId);
        
        // Update only if wear changed or it's first update
        uint256 oldWear = staked.wearLevel;
        if (newWear != oldWear || staked.lastWearUpdateTime == 0) {
            // Cap wear at 100
            staked.wearLevel = uint8(newWear > 100 ? 100 : newWear);
            
            // Update wear penalty using unified calculation
            staked.wearPenalty = uint8(LibBiopodIntegration.calculateWearPenalty(staked.wearLevel));
            
            // Update last wear update time
            staked.lastWearUpdateTime = uint32(block.timestamp);
            
            emit WearUpdated(collectionId, tokenId, oldWear, staked.wearLevel);
            
            // Check if auto-repair is needed
            if (ss.wearAutoRepairEnabled && staked.wearLevel >= ss.wearAutoRepairThreshold) {
                applyAutoWearRepair(collectionId, tokenId);
            }
            
            return true;
        }
        
        return false;
    }
                        
    /**
     * @notice Manually repair wear on a staked token with standardized fee handling
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param repairAmount Amount of wear to repair
     */
    function repairTokenWear(uint256 collectionId, uint256 tokenId, uint256 repairAmount) 
        external
        whenNotPaused 
    {
        // Input validation
        if (repairAmount == 0 || repairAmount > 100) {
            revert InvalidWearAmount();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Validate collection ID
        if (collectionId == 0 || collectionId > ss.collectionCounter) {
            revert InvalidCollectionId();
        }
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        // Check if token is staked
        if (!staked.staked) {
            revert TokenNotStaked();
        }
        
        // Check if caller is the staker or has admin/operator role
        address sender = LibMeta.msgSender();
        if (staked.owner != sender) {
            if (!AccessHelper.isAuthorized()) {
                revert AccessHelper.Unauthorized(sender, "Not token owner or admin");
            }
        }

        // Use LibFeeCollection with staking storage parameters
        LibFeeCollection.processOperationFee(
            ss.rewardToken,                    // currency: YELLOW token
            ss.settings.treasuryAddress,       // beneficiary: treasury
            ss.wearRepairCostPerPoint,         // baseAmount: cost per point
            5000,                               // multiplier: 100 = 1x (no multiplier)
            true,                             // burnOnCollect: false (staking doesn't burn)
            true,                              // enabled: always enabled
            sender,                            // payer
            repairAmount,                      // quantityMultiplier: repair points
            "wearRepair"                       // operation identifier
        );

        // Apply repair
        uint256 oldWear = staked.wearLevel;
        bool success = LibBiopodIntegration.applyWearRepair(collectionId, tokenId, repairAmount);
        
        if (!success) {
            revert RepairFailed();
        }
        
        emit WearUpdated(collectionId, tokenId, oldWear, staked.wearLevel);
        emit WearRepaired(collectionId, tokenId, repairAmount, staked.wearLevel);
    }

    /**
     * @notice Batch repair wear on multiple staked tokens with flexible repair amounts
     * @param params Batch repair parameters
     * @return successCount Number of successful repairs
     * @return totalCost Total cost of all successful repairs
     */
    function batchRepairTokenWear(BatchRepairParams calldata params) 
        external 
        whenNotPaused 
        nonReentrant 
        returns (uint256 successCount, uint256 totalCost) 
    {
        // Input validation
        if (params.collectionIds.length == 0 || params.collectionIds.length > 50) {
            revert InvalidCallData();
        }
        
        if (params.collectionIds.length != params.tokenIds.length) {
            revert InvalidCallData();
        }
        
        // Validate repair parameters based on mode
        if (params.uniformRepair) {
            if (params.repairAmount == 0 || params.repairAmount > 100) {
                revert InvalidWearAmount();
            }
        } else {
            if (params.repairAmounts.length != params.collectionIds.length) {
                revert InvalidCallData();
            }
        }
        
        return _executeBatchRepair(params);
    }

    /**
     * @notice Batch repair wear on multiple staked tokens
     * @param collectionIds Array of collection IDs
     * @param tokenIds Array of token IDs
     * @param repairAmount Repair amount for all tokens (1-100)
     * @return successCount Number of successful repairs
     * @return totalCost Total cost of all successful repairs
     */
    function repairMultipleTokens(
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds,
        uint256 repairAmount
    ) 
        external 
        whenNotPaused 
        nonReentrant 
        returns (uint256 successCount, uint256 totalCost) 
    {
        // Input validation
        if (collectionIds.length == 0 || collectionIds.length > 50) {
            revert InvalidCallData();
        }
        
        if (collectionIds.length != tokenIds.length) {
            revert InvalidCallData();
        }
        
        if (repairAmount == 0 || repairAmount > 100) {
            revert InvalidWearAmount();
        }
        
        // Create params for existing function
        BatchRepairParams memory params = BatchRepairParams({
            collectionIds: collectionIds,
            tokenIds: tokenIds,
            uniformRepair: true,
            repairAmount: repairAmount,
            repairAmounts: new uint256[](0)
        });
        
        return _executeBatchRepair(params);
    }

    /**
     * @notice Internal function to execute batch repair
     * @param params Batch repair parameters
     * @return successCount Number of successful repairs
     * @return totalCost Total cost of successful repairs
     */
    function _executeBatchRepair(BatchRepairParams memory params) 
        private 
        returns (uint256 successCount, uint256 totalCost) 
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        address sender = LibMeta.msgSender();
        
        // Calculate total repair points
        uint256 totalRepairPoints = 0;
        for (uint256 i = 0; i < params.collectionIds.length; i++) {
            uint256 currentRepairAmount = params.uniformRepair ? 
                params.repairAmount : params.repairAmounts[i];
            
            if (_isValidRepairOperation(params.collectionIds[i], params.tokenIds[i], currentRepairAmount, ss, sender)) {
                totalRepairPoints += currentRepairAmount;
            }
        }
        
        if (totalRepairPoints == 0) {
            revert InvalidCallData();
        }
        
        // Use LibFeeCollection with staking storage parameters
        LibFeeCollection.processOperationFee(
            ss.rewardToken,                    // currency: YELLOW token
            ss.settings.treasuryAddress,       // beneficiary: treasury
            ss.wearRepairCostPerPoint,         // baseAmount: cost per point
            5000,                               // multiplier: 100 = 1x (no multiplier)
            true,                             // burnOnCollect: true (staking burns)
            true,                              // enabled: always enabled
            sender,                            // payer
            totalRepairPoints,                 // quantityMultiplier: total repair points
            "batchWearRepair"                  // operation identifier
        );
        
        // Execute repairs
        (successCount, totalCost) = _performRepairs(params, ss, sender);
        
        emit BatchWearRepairCompleted(sender, successCount, totalCost);
    }



    /**
     * @notice Perform the actual repairs
     * @param params Batch repair parameters
     * @param ss Storage reference
     * @param sender Caller address
     * @return successCount Number of successful repairs
     * @return totalCost Total cost of successful repairs (calculated from operation fee)
     */
    function _performRepairs(
        BatchRepairParams memory params,
        LibStakingStorage.StakingStorage storage ss,
        address sender
    ) private returns (uint256 successCount, uint256 totalCost) {
        for (uint256 i = 0; i < params.collectionIds.length; i++) {
            uint256 currentRepairAmount = params.uniformRepair ? 
                params.repairAmount : params.repairAmounts[i];
            
            if (_isValidRepairOperation(params.collectionIds[i], params.tokenIds[i], currentRepairAmount, ss, sender)) {
                if (_executeRepair(params.collectionIds[i], params.tokenIds[i], currentRepairAmount, ss)) {
                    successCount++;
                    // Calculate cost using wear repair cost per point
                    totalCost += ss.wearRepairCostPerPoint * currentRepairAmount;
                }
            }
        }
    }

    /**
     * @notice Check if repair operation is valid
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param repairAmount Repair amount
     * @param ss Storage reference
     * @param sender Caller address
     * @return valid Whether operation is valid
     */
    function _isValidRepairOperation(
        uint256 collectionId,
        uint256 tokenId,
        uint256 repairAmount,
        LibStakingStorage.StakingStorage storage ss,
        address sender
    ) private view returns (bool valid) {
        if (repairAmount == 0 || repairAmount > 100) {
            return false;
        }
        
        if (collectionId == 0 || collectionId > ss.collectionCounter) {
            return false;
        }
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        if (!staked.staked) {
            return false;
        }
        
        if (staked.owner != sender && !AccessHelper.isAuthorized()) {
            return false;
        }
        
        return true;
    }

    /**
     * @notice Execute single repair operation
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param repairAmount Repair amount
     * @param ss Storage reference
     * @return success Whether repair was successful
     */
    function _executeRepair(
        uint256 collectionId,
        uint256 tokenId,
        uint256 repairAmount,
        LibStakingStorage.StakingStorage storage ss
    ) private returns (bool success) {
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        uint256 oldWear = staked.wearLevel;
        
        // Use LibBiopodIntegration which properly handles timer separation
        success = LibBiopodIntegration.applyWearRepair(collectionId, tokenId, repairAmount);
        
        if (success) {
            emit WearUpdated(collectionId, tokenId, oldWear, staked.wearLevel);
            emit WearRepaired(collectionId, tokenId, repairAmount, staked.wearLevel);
            
            // NO ADDITIONAL TIMER UPDATES HERE - LibBiopodIntegration handles it correctly
        }
        
        return success;
    }


        
    /**
     * @notice Get current wear level for a token
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return wearLevel Current wear level
     * @return wearPenalty Current wear penalty percentage
     */
    function getTokenWearData(uint256 collectionId, uint256 tokenId) external view returns (
        uint256 wearLevel, 
        uint256 wearPenalty,
        string memory dataSource
    ) {
        // UPDATED: Use unified implementation from library
        (wearLevel, dataSource) = LibBiopodIntegration.getUnifiedWearLevel(collectionId, tokenId);
        
        // Calculate penalty based on unified wear level
        wearPenalty = LibBiopodIntegration.calculateWearPenalty(wearLevel);
        
        return (wearLevel, wearPenalty, dataSource);
    }
        
    /**
     * @notice Get wear repair cost
     * @param wearAmount Amount of wear to repair
     * @return cost Cost in YELLOW tokens
     * @return beneficiary Address that receives the fee (treasury)
     * @return currency YELLOW token address
     */
    function getWearRepairCost(uint256 wearAmount) external view returns (
        uint256 cost, 
        address beneficiary,
        address currency
    ) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Calculate cost using wear repair cost per point
        cost = ss.wearRepairCostPerPoint * wearAmount;
        
        beneficiary = ss.settings.treasuryAddress;
        currency = ss.rewardToken;
        
        return (cost, beneficiary, currency);
    }
    
    /**
     * @notice Updates wear level locally based on time elapsed
     * @param collectionId Collection ID
     * @param tokenId Token ID
     */
    function updateLocalWearLevel(uint256 collectionId, uint256 tokenId) internal {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        // Skip if wear increase rate is 0
        if (ss.wearIncreasePerDay == 0) {
            return;
        }
        
        // Calculate time elapsed since last wear update
        uint256 timeElapsed = block.timestamp - staked.lastWearUpdateTime;
        
        // Skip if no time elapsed or less than minimum interval
        if (timeElapsed < 3600) { // Minimum 1 hour between updates
            return;
        }
        
        // Calculate wear increase based on daily rate
        uint256 wearIncrease = (timeElapsed * ss.wearIncreasePerDay) / 1 days;
        
        if (wearIncrease > 0) {
            uint256 oldWear = staked.wearLevel;
            uint256 newWear = oldWear + wearIncrease;
            
            // Cap at 100
            if (newWear > LibStakingStorage.MAX_WEAR_LEVEL) {
                newWear = LibStakingStorage.MAX_WEAR_LEVEL;
            }
            
            // Update wear level
            staked.wearLevel = uint8(newWear);
            
            // Update wear penalty
            updateWearPenaltyLevel(staked);
            
            // Update ONLY the wear update time, not repair time
            staked.lastWearUpdateTime = uint32(block.timestamp);
            
            emit WearUpdated(collectionId, tokenId, oldWear, newWear);
            
            // Check if auto-repair is needed
            if (ss.wearAutoRepairEnabled && staked.wearLevel >= ss.wearAutoRepairThreshold) {
                applyAutoWearRepair(collectionId, tokenId);
            }
        }
    }
    
    /**
     * @notice Update wear penalty based on current wear level
     * @param staked Staked specimen data
     */
    function updateWearPenaltyLevel(StakedSpecimen storage staked) internal {
        // Use the unified penalty calculation
        staked.wearPenalty = uint8(LibStakingStorage.calculateWearPenalty(staked.wearLevel));
    }
    
    /**
     * @notice Apply auto-repair if enabled and threshold reached
     * @param collectionId Collection ID
     * @param tokenId Token ID
     */
    function applyAutoWearRepair(uint256 collectionId, uint256 tokenId) internal {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        // Skip if auto-repair is disabled or repair amount is 0
        if (!ss.wearAutoRepairEnabled || ss.wearAutoRepairAmount == 0) {
            return;
        }

        // Calculate repair cost
        uint256 repairCost = ss.wearRepairCostPerPoint * ss.wearAutoRepairAmount;

        // Check if payer has sufficient balance and allowance before attempting repair
        if (repairCost > 0 && ss.rewardToken != address(0)) {
            IERC20 rewardToken = IERC20(ss.rewardToken);
            uint256 balance = rewardToken.balanceOf(staked.owner);
            uint256 allowance = rewardToken.allowance(staked.owner, address(this));

            // Skip auto-repair if user cannot pay the fee
            if (balance < repairCost || allowance < repairCost) {
                return;
            }
        }

        // Apply repair (only if user can pay)
        uint256 oldWear = staked.wearLevel;
        bool success = LibBiopodIntegration.applyWearRepair(collectionId, tokenId, ss.wearAutoRepairAmount);

        if (success) {
            // Process fee - user has sufficient funds (validated above)
            if (repairCost > 0 && ss.rewardToken != address(0)) {
                LibFeeCollection.processOperationFee(
                    address(ss.rewardToken),           // currency: YELLOW token
                    ss.settings.treasuryAddress,       // beneficiary: treasury
                    ss.wearRepairCostPerPoint,         // baseAmount: cost per point
                    5000,                               // multiplier: 100 = 1x (no multiplier)
                    true,                             // burnOnCollect: true (staking burns)
                    true,                              // enabled: always enabled
                    staked.owner,                      // payer: token owner
                    ss.wearAutoRepairAmount,           // quantityMultiplier: auto repair amount
                    "autoWearRepair"                   // operation identifier
                );
            }

            emit AutoRepairApplied(collectionId, tokenId, ss.wearAutoRepairAmount, repairCost);
            emit WearUpdated(collectionId, tokenId, oldWear, staked.wearLevel);
            emit WearRepaired(collectionId, tokenId, ss.wearAutoRepairAmount, staked.wearLevel);
        }
    }

    /**
     * @notice Configure auto-repair for wear system
     * @dev Sets parameters for automatic wear repair to improve user experience
     * @param enabled Whether auto-repair is enabled
     * @param repairInterval Time between auto-repairs (seconds)
     * @param repairAmount Amount to repair when triggered
     * @param triggerThreshold Threshold to trigger repair (0-100)
     * @param freeAutoRepair Whether auto-repair is free
     */
    function configureWearAutoRepair(
        bool enabled,
        uint256 repairInterval,
        uint8 repairAmount,
        uint8 triggerThreshold,
        bool freeAutoRepair
    ) external onlyAuthorized whenNotPaused {
        // Validation with sensible defaults
        if (repairInterval == 0) {
            repairInterval = 1 days;
        }
        
        if (repairAmount == 0) {
            repairAmount = 5;
        }
        
        if (triggerThreshold == 0 || triggerThreshold > 100) {
            triggerThreshold = 30;
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Update configuration
        ss.wearAutoRepairConfig.enabled = enabled;
        ss.wearAutoRepairConfig.repairInterval = repairInterval;
        ss.wearAutoRepairConfig.repairAmount = repairAmount;
        ss.wearAutoRepairConfig.triggerThreshold = triggerThreshold;
        ss.wearAutoRepairConfig.freeAutoRepair = freeAutoRepair;
        
        emit OperationResult("WearAutoRepairConfigured", true);
    }

    /**
     * @notice Public function to check and perform auto-repair if needed
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return repaired Whether repair was performed
     */
    function checkAndPerformAutoRepair(
        uint256 collectionId, 
        uint256 tokenId
    ) external returns (bool repaired) {
        return _checkAndPerformAutoRepair(collectionId, tokenId);
    }

    /**
     * @notice Configure wear system settings
     * @param wearIncreasePerDay Daily wear increase (0 = disable automatic wear)
     * @param repairCostPerPoint Cost in ZICO per repair point
     * @param autoRepairEnabled Whether auto-repair is enabled
     * @param autoRepairThreshold Wear level that triggers auto-repair
     * @param autoRepairAmount Amount repaired during auto-repair
     */
    function setWearSystemSettings(
        uint256 wearIncreasePerDay,
        uint256 repairCostPerPoint,
        bool autoRepairEnabled,
        uint256 autoRepairThreshold,
        uint256 autoRepairAmount
    ) external onlyAuthorized whenNotPaused {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        ss.wearIncreasePerDay = wearIncreasePerDay;
        ss.wearRepairCostPerPoint = repairCostPerPoint;
        ss.wearAutoRepairEnabled = autoRepairEnabled;
        ss.wearAutoRepairThreshold = autoRepairThreshold;
        ss.wearAutoRepairAmount = autoRepairAmount;
        
        emit WearSystemConfigured(wearIncreasePerDay, repairCostPerPoint, autoRepairEnabled);
    }

    /**
     * @notice Configure wear penalty thresholds
     * @param thresholds Array of wear levels where penalties start
     * @param penalties Array of penalty percentages for each threshold
     */
    function setWearPenaltySettings(
        uint8[] calldata thresholds,
        uint8[] calldata penalties
    ) external onlyAuthorized whenNotPaused {
        if (thresholds.length != penalties.length) {
            revert InvalidCallData();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        ss.wearPenaltyThresholds = thresholds;
        ss.wearPenaltyValues = penalties;
        
        emit WearPenaltySettingsUpdated(thresholds, penalties);
    }

    /**
     * @notice Internal implementation of auto-repair logic
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return repaired Whether repair was performed
     */
    function _checkAndPerformAutoRepair(
        uint256 collectionId, 
        uint256 tokenId
    ) internal returns (bool repaired) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        if (!ss.wearAutoRepairConfig.enabled) {
            return false;
        }
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        if (!staked.staked) {
            return false;
        }
        
        // ENHANCED AUTO-FIX: More conservative approach
        if (staked.lastWearRepairTime == 0) {
            // For auto-repair, be more conservative - set to current time
            // This means auto-repair won't trigger immediately for old tokens
            staked.lastWearRepairTime = uint32(block.timestamp);
            return false; // Skip repair this time, will work next time
        }
        
        // Standard auto-repair logic
        uint256 repairInterval = ss.wearAutoRepairConfig.repairInterval;
        if (repairInterval == 0) repairInterval = 21600; // 6 hours
        
        if (block.timestamp - staked.lastWearRepairTime < repairInterval) {
            return false;
        }
        
        uint8 triggerThreshold = ss.wearAutoRepairConfig.triggerThreshold;
        if (triggerThreshold == 0) triggerThreshold = 30;
        
        if (staked.wearLevel < triggerThreshold) {
            return false;
        }
        
        // Rest of auto-repair logic...
        uint8 repairAmount = ss.wearAutoRepairConfig.repairAmount;
        if (repairAmount == 0) repairAmount = 5;
        
        if (staked.wearLevel <= repairAmount) {
            repairAmount = staked.wearLevel;
        }
        
        uint8 oldWear = staked.wearLevel;
        staked.wearLevel -= repairAmount;
        updateWearPenaltyLevel(staked);
        staked.lastWearRepairTime = uint32(block.timestamp);
        
        // Handle payment and events...
        if (!ss.wearAutoRepairConfig.freeAutoRepair) {
            uint256 repairCost = repairAmount * ss.wearRepairCostPerPoint;
            if (ss.settings.treasuryAddress != address(0) && staked.owner != address(0)) {
                try ss.zicoToken.transferFrom(staked.owner, ss.settings.treasuryAddress, repairCost) {
                    emit AutoRepairApplied(collectionId, tokenId, repairAmount, repairCost);
                } catch {
                    emit AutoRepairApplied(collectionId, tokenId, repairAmount, 0);
                }
            }
        }
        
        emit WearUpdated(collectionId, tokenId, oldWear, staked.wearLevel);
        emit WearRepaired(collectionId, tokenId, repairAmount, staked.wearLevel);

        return true;
    }

    /**
     * @notice Admin function to fix corrupted wear data for legacy tokens
     * @dev Only callable by operators to fix tokens with incorrect wear values
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param newWearLevel New wear level to set (0-100)
     */
    function adminFixWearLevel(
        uint256 collectionId,
        uint256 tokenId,
        uint8 newWearLevel
    ) external onlyAuthorized {
        require(newWearLevel <= 100, "Wear level must be <= 100");

        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];

        require(staked.staked, "Token not staked");

        uint8 oldWear = staked.wearLevel;
        staked.wearLevel = newWearLevel;
        staked.lastWearUpdateTime = uint32(block.timestamp);
        updateWearPenaltyLevel(staked);

        emit WearUpdated(collectionId, tokenId, oldWear, newWearLevel);
    }

    /**
     * @notice Admin function to batch fix corrupted wear data for multiple tokens
     * @param collectionId Collection ID
     * @param tokenIds Array of token IDs
     * @param newWearLevel New wear level to set for all tokens
     */
    function adminBatchFixWearLevel(
        uint256 collectionId,
        uint256[] calldata tokenIds,
        uint8 newWearLevel
    ) external onlyAuthorized {
        require(newWearLevel <= 100, "Wear level must be <= 100");

        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 combinedId = PodsUtils.combineIds(collectionId, tokenIds[i]);
            StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];

            if (staked.staked) {
                uint8 oldWear = staked.wearLevel;
                staked.wearLevel = newWearLevel;
                staked.lastWearUpdateTime = uint32(block.timestamp);
                updateWearPenaltyLevel(staked);

                emit WearUpdated(collectionId, tokenIds[i], oldWear, newWearLevel);
            }
        }
    }

}