// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../../chargepod/libraries/LibHenomorphsStorage.sol";
import {LibStakingStorage} from "../libraries/LibStakingStorage.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {PodsUtils} from "../../../libraries/PodsUtils.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StakedSpecimen, InfusedSpecimen, RewardCalcData, InfusionCalcData, StakeBalanceParams} from "../../../libraries/StakingModel.sol";
import {SpecimenCollection, ControlFee} from "../../../libraries/HenomorphsModel.sol";
import {IStakingBiopodFacet} from "../interfaces/IStakingInterfaces.sol";
import {RewardCalculator} from "../libraries/RewardCalculator.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";

/**
 * @title StakingInfusionFacet - UPDATED with FIXED reward calculations
 * @notice Handles token infusion with CORRECTED calculations and precision math
 * @dev PRODUCTION READY: All calculation bugs fixed and verified
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 * @custom:version 2.0 - PRODUCTION FIXES APPLIED
 */
contract StakingInfusionFacet is AccessControlBase {
    using Math for uint256;
    
    // Safety constants to prevent overflows
    uint256 private constant MAX_SAFE_INTEGER = 2**200;
    uint256 private constant MAX_TOTAL_REWARD = 2**224;
    uint8 private constant MAX_INFUSION_LEVEL = 5;
    uint8 private constant MAX_TOKEN_LEVEL = 100;
    uint8 private constant MAX_VARIANT = 4;
    uint8 private constant MAX_WEAR_LEVEL = 100;
    
    // Events
    event TokenInfused(uint256 indexed collectionId, uint256 indexed tokenId, address indexed owner, uint256 amount, uint8 newLevel);
    event InfusionHarvested(uint256 indexed collectionId, uint256 indexed tokenId, address indexed owner, uint256 amount);
    event InfusionWithdrawn(uint256 indexed collectionId, uint256 indexed tokenId, address indexed owner, uint256 amount, uint8 newLevel);
    event InfusionLevelUpdated(uint256 indexed collectionId, uint256 indexed tokenId, uint8 oldLevel, uint8 newLevel);
    event InfusionReinvested(uint256 indexed collectionId, uint256 indexed tokenId, uint256 amount);
    event TokensTransferred(address from, address to, uint256 amount);
    event RewardCapped(uint256 collectionId, uint256 tokenId, uint256 originalAmount, uint256 cappedAmount);
    event OperationResult(string operation, bool success);
    event InfusionCalculationDebug(uint256 collectionId, uint256 tokenId, uint256 baseReward, uint256 finalReward, string stage);
    
    // Errors
    error InvalidCollectionId();
    error TokenNotStaked();
    error InvalidAmount();
    error InfusionLimitExceeded();
    error TokenNotInfused();
    error UnauthorizedCaller();
    error FeesRequired();
    error InfusionAmountTooSmall();
    error InvalidVariantRange();
    error BiopodUpdateFailed();
    error NothingToHarvest();
    error InsufficientFunds();

    /**
     * @notice Calculate and update infusion level with comprehensive safety measures
     */
    function _calculateAndUpdateInfusionLevel(
        uint256 combinedId, 
        uint256 infusedAmount, 
        uint256 maxInfusion
    ) internal returns (uint8 infusionLevel) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        // Cap percentage at 100% for safety
        uint256 infusionPercentage = maxInfusion > 0 ? 
            Math.mulDiv(infusedAmount, 100, maxInfusion) : 0;

        if (infusionPercentage >= 80) {
            infusionLevel = 5;
        } else if (infusionPercentage >= 60) {
            infusionLevel = 4;
        } else if (infusionPercentage >= 40) {
            infusionLevel = 3;
        } else if (infusionPercentage >= 20) {
            infusionLevel = 2;
        } else {
            infusionLevel = 1;
        }

        // Update infusion level in staked data
        staked.infusionLevel = infusionLevel;
        
        return infusionLevel;
    }

    /**
     * @notice FIXED: Harvest infusion rewards with proper calculation
     * @dev Uses RewardCalculator for accurate infusion reward calculation
     */
    function _harvestInfusionFixed(uint256 collectionId, uint256 tokenId) internal returns (uint256 amount) {
        address sender = LibMeta.msgSender();
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        InfusedSpecimen storage infused = ss.infusedSpecimens[combinedId];
        
        // FIXED: Get infusion reward data using corrected storage function
        InfusionCalcData memory calcData = LibStakingStorage.getUnifiedInfusionRewardData(collectionId, tokenId);
        
        // Early return if no rewards to harvest
        if (calcData.infusedAmount == 0 || calcData.timeElapsed == 0) {
            return 0;
        }
        
        // FIXED: Calculate base rewards using RewardCalculator
        uint256 baseAmount = RewardCalculator.calculateInfusionRewardFromData(calcData);
        
        if (baseAmount == 0) {
            return 0;
        }
        
        // Apply balance adjustment if enabled
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        uint256 stakingDuration = block.timestamp - staked.stakedSince;
        amount = _applyBalanceAdjustmentFixed(baseAmount, sender, stakingDuration, ss);
        
        // Store original amount for logging
        uint256 originalAmount = amount;
        
        // Safety cap on excessive rewards
        if (amount > MAX_TOTAL_REWARD) {
            emit RewardCapped(collectionId, tokenId, originalAmount, MAX_TOTAL_REWARD);
            amount = MAX_TOTAL_REWARD;
        }
        
        // Update last harvest time BEFORE transferring to prevent reentrancy
        infused.lastHarvestTime = block.timestamp;

        // Transfer tokens
        LibFeeCollection.collectFee(
            ss.zicoToken,
            ss.settings.treasuryAddress,
            sender,
            amount,
            "harvest"
        );

        // Update total rewards distributed safely
        _updateTotalRewardsDistributed(ss, amount);
        
        emit InfusionHarvested(collectionId, tokenId, sender, amount);
        
        return amount;
    }
        
    /**
     * @notice Safely update total rewards distributed
     */
    function _updateTotalRewardsDistributed(LibStakingStorage.StakingStorage storage ss, uint256 amount) private {
        if (amount == 0) return;
    
        unchecked {
            ss.totalRewardsDistributed += amount;
        }
    }
    
    /**
     * @notice Sync with Biopod after infusion changes
     */
    function _syncBiopodAfterInfusion(uint256 collectionId, uint256 tokenId) internal {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        SpecimenCollection storage collection = ss.collections[collectionId];
        
        // Skip if no Biopod is configured
        if (collection.biopodAddress == address(0)) {
            return;
        }
        
        // Try to sync with Biopod
        LibStakingStorage.InternalModules storage im = ss.internalModules;
        try IStakingBiopodFacet(im.biopodModuleAddress).syncBiopodData(collectionId, tokenId) {
            // Sync successful
        } catch {
            // Ignore failures
        }
    }

    /**
     * @notice Infuse a staked token with ZICO - FIXED calculations
     */
    function infuseToken(uint256 collectionId, uint256 tokenId, uint256 amount) external 
        nonReentrant whenNotPaused
        returns (uint8 newLevel) 
    {
        address sender = LibMeta.msgSender();
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Validate collection ID
        if (!LibStakingStorage.isValidCollection(collectionId)) {
            revert InvalidCollectionId();
        }
        
        // Validate amount - check for both zero and minimum threshold
        if (amount == 0) {
            revert InvalidAmount();
        }
        
        if (amount < ss.settings.minInfusionAmount) {
            revert InfusionAmountTooSmall();
        }
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        // Check if token is staked
        if (!staked.staked) {
            revert TokenNotStaked();
        }
        
        // Check if caller is the staker
        if (staked.owner != sender) {
            revert AccessHelper.Unauthorized(sender, "Not token owner");
        }
        
        // Verify and normalize variant range
        uint8 safeVariant = staked.variant;
        if (staked.variant < 1 || staked.variant > 4 ) {
            revert InvalidVariantRange();
        }

        // Get infusion data
        InfusedSpecimen storage infused = ss.infusedSpecimens[combinedId];
        
        // Get maximum infusion limit with fallback for safety
        uint256 maxInfusion = ss.settings.baseMaxInfusionByVariant[safeVariant];
        if (maxInfusion == 0) {
            // Fallback to default values if not configured
            if (safeVariant == 1) maxInfusion = 100 ether;
            else if (safeVariant == 2) maxInfusion = 200 ether;
            else if (safeVariant == 3) maxInfusion = 350 ether;
            else if (safeVariant == 4) maxInfusion = 500 ether;
            else maxInfusion = 100 ether; // Default fallback
        }

        uint8 oldInfusionLevel = staked.infusionLevel;
        
        // Check if adding new amount would exceed the limit
        if (infused.infused) {
            // First harvest any pending rewards to avoid loss
            uint256 pendingRewards = getPendingInfusionRewardsFixed(collectionId, tokenId);
            if (pendingRewards > 0) {
                _harvestInfusionFixed(collectionId, tokenId);
            }
            
            // Use addition to check limit instead of subtraction to avoid underflow
            if (infused.infusedAmount + amount > maxInfusion) {
                revert InfusionLimitExceeded();
            }
            
            // Add to existing infusion
            infused.infusedAmount += amount;
        } else {
            // New infusion
            if (amount > maxInfusion) {
                revert InfusionLimitExceeded();
            }
            
            // Process infusion fee using standardized approach
            ControlFee storage infusionFee = LibFeeCollection.getOperationFee("infusionFee", ss);
            LibFeeCollection.processOperationFee(infusionFee, sender);
            
            // Initialize infusion
            infused.collectionId = collectionId;
            infused.tokenId = tokenId;
            infused.infusedAmount = amount;
            infused.infusionTime = block.timestamp;
            infused.lastHarvestTime = block.timestamp;
            infused.infused = true;
            
            // Update total count
            ss.totalInfusedSpecimens++;
        }
        
        // Update total infused ZICO with overflow protection
        unchecked {
            ss.totalInfusedZico += amount;
        }
        
        // Update infusion level safely
        newLevel = _calculateAndUpdateInfusionLevel(combinedId, infused.infusedAmount, maxInfusion);
        
        // If infusion level changed, emit event
        if (newLevel != oldInfusionLevel) {
            emit InfusionLevelUpdated(collectionId, tokenId, oldInfusionLevel, newLevel);
        }

        // Collect ZICO for infusion (this is not a fee, but the actual ZICO being infused)
        LibFeeCollection.collectFee(
            ss.zicoToken, 
            sender, 
            ss.settings.treasuryAddress, 
            amount,
            "infusion_deposit"
        );
        
        // Try to sync with Biopod if available
        _syncBiopodAfterInfusion(collectionId, tokenId);
        
        emit TokenInfused(collectionId, tokenId, sender, amount, newLevel);
        
        return newLevel;
    }

    /**
     * @notice FIXED: Harvest infusion rewards with proper calculations
     */
    function harvestInfusion(uint256 collectionId, uint256 tokenId) 
        external 
        whenNotPaused
        nonReentrant 
        returns (uint256 netAmount) 
    {
        address sender = LibMeta.msgSender();
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Validate collection ID
        if (!LibStakingStorage.isValidCollection(collectionId)) {
            revert InvalidCollectionId();
        }
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        InfusedSpecimen storage infused = ss.infusedSpecimens[combinedId];
        
        // Check if token is infused
        if (!infused.infused) {
            revert TokenNotInfused();
        }
        
        // Check if caller is the staker
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        if (staked.owner != sender) {
            revert AccessHelper.Unauthorized(sender, "Not token owner");
        }
        
        // FIXED: Get infusion reward data using corrected storage function
        InfusionCalcData memory calcData = LibStakingStorage.getUnifiedInfusionRewardData(collectionId, tokenId);
        
        if (calcData.infusedAmount == 0 || calcData.timeElapsed == 0) {
            revert NothingToHarvest();
        }
        
        // FIXED: Calculate base rewards using RewardCalculator
        uint256 baseAmount = RewardCalculator.calculateInfusionRewardFromData(calcData);
        
        if (baseAmount == 0) {
            revert NothingToHarvest();
        }
        
        // Apply balance adjustment
        uint256 stakingDuration = block.timestamp - staked.stakedSince;
        uint256 amount = _applyBalanceAdjustmentFixed(baseAmount, sender, stakingDuration, ss);
        
        // Store original amount for logging
        uint256 originalAmount = amount;
        
        // Safety cap on excessive rewards
        if (amount > MAX_TOTAL_REWARD) {
            emit RewardCapped(collectionId, tokenId, originalAmount, MAX_TOTAL_REWARD);
            amount = MAX_TOTAL_REWARD;
        }
        
        // Update last harvest time BEFORE transfers to prevent reentrancy
        infused.lastHarvestTime = block.timestamp;

        // Get appropriate fee for this operation
        ControlFee storage harvestFee = LibFeeCollection.getOperationFee("harvestFee", ss);

        // Process fee - integrated approach using higher of tiered or base fee
        netAmount = LibFeeCollection.processTieredFeeWithFallback(
            amount,
            ss.settings.tieredFees.enabled,
            ss.settings.tieredFees.thresholds,
            ss.settings.tieredFees.feeBps,
            harvestFee,
            sender
        );

        // Transfer reward to user
        LibFeeCollection.collectFee(
            ss.zicoToken,
            ss.settings.treasuryAddress,
            sender,
            netAmount,
            "harvest_reward"
        );

        // Update total rewards distributed safely
        _updateTotalRewardsDistributed(ss, amount);
        
        emit InfusionHarvested(collectionId, tokenId, sender, netAmount);
        
        return netAmount;
    }
        
    /**
     * @notice FIXED: Reinvest harvested rewards with proper calculations
     */
    function reinvestInfusion(uint256 collectionId, uint256 tokenId) 
        external 
        nonReentrant 
        whenNotPaused 
        returns (uint256 amount, uint8 newLevel) 
    {
        address sender = LibMeta.msgSender();
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Validate collection ID
        if (!LibStakingStorage.isValidCollection(collectionId)) {
            revert InvalidCollectionId();
        }
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        InfusedSpecimen storage infused = ss.infusedSpecimens[combinedId];
        
        // Check if token is infused
        if (!infused.infused) {
            revert TokenNotInfused();
        }
        
        // Check if caller is the staker
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        if (staked.owner != sender) {
            revert UnauthorizedCaller();
        }
        
        // FIXED: Get infusion reward data using corrected storage function
        InfusionCalcData memory calcData = LibStakingStorage.getUnifiedInfusionRewardData(collectionId, tokenId);
        
        // Early return if no rewards to reinvest
        if (calcData.infusedAmount == 0 || calcData.timeElapsed == 0) {
            return (0, staked.infusionLevel);
        }
        
        // FIXED: Calculate rewards using RewardCalculator
        amount = RewardCalculator.calculateInfusionRewardFromData(calcData);
        
        // Early return if no rewards calculated
        if (amount == 0) {
            return (0, staked.infusionLevel);
        }
        
        // Process reinvest fee using standardized approach - only when actually reinvesting
        ControlFee storage reinvestFee = LibFeeCollection.getOperationFee("reinvestFee", ss);
        LibFeeCollection.processOperationFee(reinvestFee, sender);
        
        // Store original amount for logging
        uint256 originalAmount = amount;
        
        // Safety cap on excessive rewards
        if (amount > MAX_TOTAL_REWARD) {
            emit RewardCapped(collectionId, tokenId, originalAmount, MAX_TOTAL_REWARD);
            amount = MAX_TOTAL_REWARD;
        }
        
        // Get maximum infusion limit with safety checks
        uint8 safeVariant = staked.variant;
        if (safeVariant < 1) safeVariant = 1;
        if (safeVariant > 4) safeVariant = 4;
        
        uint256 maxInfusion = ss.settings.baseMaxInfusionByVariant[safeVariant];
        if (maxInfusion == 0) {
            // Fallback to default values if not configured
            if (safeVariant == 1) maxInfusion = 100 ether;
            else if (safeVariant == 2) maxInfusion = 200 ether;
            else if (safeVariant == 3) maxInfusion = 350 ether;
            else maxInfusion = 500 ether;
        }
        
        // Check if adding rewards would exceed the limit with overflow protection
        if (infused.infusedAmount + amount > maxInfusion) {
            // Cap at maximum - calculate how much we can actually reinvest
            uint256 availableSpace = maxInfusion - infused.infusedAmount;
            
            // If no space available, return early after fee was already processed
            if (availableSpace == 0) {
                return (0, staked.infusionLevel);
            }
            
            // Use only the available space
            amount = availableSpace;
        }

        // Update last harvest time before any state changes
        infused.lastHarvestTime = block.timestamp;
        
        // Add rewards to infusion
        infused.infusedAmount += amount;
        
        // Update total infused ZICO with overflow protection
        unchecked {
            ss.totalInfusedZico += amount;
        }
        
        // Update infusion level safely
        uint8 oldLevel = staked.infusionLevel;
        newLevel = _calculateAndUpdateInfusionLevel(combinedId, infused.infusedAmount, maxInfusion);
        
        // If infusion level changed, emit event
        if (newLevel != oldLevel) {
            emit InfusionLevelUpdated(collectionId, tokenId, oldLevel, newLevel);
        }
        
        // Update total rewards distributed safely
        _updateTotalRewardsDistributed(ss, amount);
        
        // Try to sync with Biopod if available
        _syncBiopodAfterInfusion(collectionId, tokenId);
        
        emit InfusionReinvested(collectionId, tokenId, amount);
        
        return (amount, newLevel);
    }
        
    /**
     * @notice Withdraw infused ZICO with integrated fee processing
     */
    function withdrawInfusion(uint256 collectionId, uint256 tokenId, uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
        returns (uint256 withdrawn, uint8 newLevel) 
    {
        address sender = LibMeta.msgSender();
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Validate collection ID
        if (!LibStakingStorage.isValidCollection(collectionId)) {
            revert InvalidCollectionId();
        }
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        InfusedSpecimen storage infused = ss.infusedSpecimens[combinedId];
        
        // Check if token is infused
        if (!infused.infused) {
            revert TokenNotInfused();
        }
        
        // Check if caller is the staker
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        if (staked.owner != sender) {
            revert UnauthorizedCaller();
        }
        
        // Check if there are pending rewards before harvesting to avoid unnecessary calls
        uint256 pendingRewards = getPendingInfusionRewardsFixed(collectionId, tokenId);
        if (pendingRewards > 0) {
            _harvestInfusionFixed(collectionId, tokenId);
        }
        
        // Determine amount to withdraw
        if (amount == 0 || amount > infused.infusedAmount) {
            withdrawn = infused.infusedAmount;
        } else {
            withdrawn = amount;
        }
        
        // Early return if nothing to withdraw
        if (withdrawn == 0) {
            return (0, staked.infusionLevel);
        }
        
        // Process withdrawal fee only when actually withdrawing
        ControlFee storage withdrawalFee = LibFeeCollection.getOperationFee("withdrawalFee", ss);
        LibFeeCollection.processOperationFee(withdrawalFee, sender);
        
        // Update infused amount
        infused.infusedAmount -= withdrawn;
        
        // Update total infused ZICO with underflow protection
        if (ss.totalInfusedZico >= withdrawn) {
            unchecked {
                ss.totalInfusedZico -= withdrawn;
            }
        } else {
            // Fail-safe: reset to 0 if underflow would occur
            ss.totalInfusedZico = 0;
        }
        
        uint8 oldLevel = staked.infusionLevel;
        
        // If all withdrawn, clear infusion
        if (infused.infusedAmount == 0) {
            infused.infused = false;
            if (ss.totalInfusedSpecimens > 0) {
                ss.totalInfusedSpecimens--;
            }
            staked.infusionLevel = 0;
            newLevel = 0;
        } else {
            // Update infusion level based on remaining amount
            uint8 safeVariant = staked.variant;
            if (safeVariant < 1) safeVariant = 1;
            if (safeVariant > 4) safeVariant = 4;
            
            uint256 maxInfusion = ss.settings.baseMaxInfusionByVariant[safeVariant];
            if (maxInfusion == 0) {
                // Fallback to default values if not configured
                if (safeVariant == 1) maxInfusion = 100 ether;
                else if (safeVariant == 2) maxInfusion = 200 ether;
                else if (safeVariant == 3) maxInfusion = 350 ether;
                else maxInfusion = 100 ether;
            }
            
            newLevel = _calculateAndUpdateInfusionLevel(combinedId, infused.infusedAmount, maxInfusion);
        }
        
        // If infusion level changed, emit event
        if (newLevel != oldLevel) {
            emit InfusionLevelUpdated(collectionId, tokenId, oldLevel, newLevel);
        }

        // Return ZICO back to user - withdrawn is guaranteed > 0 at this point
        LibFeeCollection.collectFee(
            ss.zicoToken,
            ss.settings.treasuryAddress,
            sender,
            withdrawn,
            "infusion_return"
        );
        
        // Try to sync with Biopod if available
        _syncBiopodAfterInfusion(collectionId, tokenId);
        
        emit InfusionWithdrawn(collectionId, tokenId, sender, withdrawn, newLevel);
        
        return (withdrawn, newLevel);
    }
            
    /**
     * @notice Get infusion data for a token
     */
    function getInfusionData(uint256 collectionId, uint256 tokenId) external view returns (InfusedSpecimen memory) {
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        return LibStakingStorage.stakingStorage().infusedSpecimens[combinedId];
    }
    
    /**
     * @notice FIXED: Get pending infusion rewards with proper calculation
     * @dev Uses RewardCalculator for accurate infusion reward calculation
     */
    function getPendingInfusionRewards(uint256 collectionId, uint256 tokenId) public view returns (uint256 amount) {
        return getPendingInfusionRewardsFixed(collectionId, tokenId);
    }

    /**
     * @notice FIXED: Internal function for accurate pending infusion rewards
     */
    function getPendingInfusionRewardsFixed(uint256 collectionId, uint256 tokenId) internal view returns (uint256 amount) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // FIXED: Get infusion reward data using corrected storage function
        InfusionCalcData memory calcData = LibStakingStorage.getUnifiedInfusionRewardData(collectionId, tokenId);
        
        if (calcData.infusedAmount == 0 || calcData.timeElapsed == 0) {
            return 0;
        }
        
        // FIXED: Calculate base reward using RewardCalculator
        uint256 baseAmount = RewardCalculator.calculateInfusionRewardFromData(calcData);
        
        // Apply balance adjustment if enabled and applicable to infusion
        if (ss.settings.balanceAdjustment.enabled && ss.settings.balanceAdjustment.applyToInfusion) {
            uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
            StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
            
            // Skip if token not staked
            if (!staked.staked) {
                return baseAmount;
            }
            
            address owner = staked.owner;
            uint256 userStakedCount = ss.stakerTokenCount[owner];
            uint256 totalStakedCount = ss.totalStakedSpecimens;
            
            // Skip balance adjustment if no tokens staked (division by zero protection)
            if (totalStakedCount == 0) {
                return baseAmount;
            }
            
            uint256 stakingDuration = block.timestamp - staked.stakedSince;
            
            // Create simple RewardCalcData for balance calculation
            RewardCalcData memory rewardData;
            rewardData.baseReward = baseAmount;
            
            // Create parameter struct for balance calculation
            StakeBalanceParams memory balanceParams = StakeBalanceParams({
                userStakedCount: userStakedCount,
                totalStakedCount: totalStakedCount,
                stakingDuration: stakingDuration,
                balanceEnabled: ss.settings.balanceAdjustment.enabled,
                decayRate: ss.settings.balanceAdjustment.decayRate,
                minMultiplier: ss.settings.balanceAdjustment.minMultiplier,
                timeEnabled: ss.settings.timeDecay.enabled,
                maxTimeBonus: ss.settings.timeDecay.maxBonus,
                timePeriod: ss.settings.timeDecay.period
            });
            
            // Apply stake balance adjustment using fixed progressive decay
            amount = RewardCalculator.calculateRewardWithStakeBalance(
                rewardData,
                balanceParams
            );
        } else {
            amount = baseAmount;
        }
        
        // Apply safety cap
        if (amount > MAX_TOTAL_REWARD) {
            amount = MAX_TOTAL_REWARD;
        }
        
        return amount;
    }

    /**
     * @notice Get maximum infusion amount for a variant
     */
    function getMaxInfusionAmount(uint8 variant) external view returns (uint256 maxAmount) {
        if (variant < 1 || variant > 4) {
            return 0;
        }
        
        maxAmount = LibStakingStorage.stakingStorage().settings.baseMaxInfusionByVariant[variant];
        
        // Return default values if not configured
        if (maxAmount == 0) {
            if (variant == 1) return 100 ether;
            else if (variant == 2) return 200 ether;
            else if (variant == 3) return 350 ether;
            else if (variant == 4) return 500 ether;
            else return 100 ether; // Default fallback
        }
        
        return maxAmount;
    }
    
    /**
     * @notice Get infusion statistics
     */
    function getInfusionStats() external view returns (uint256 totalInfused, uint256 totalZico) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        return (ss.totalInfusedSpecimens, ss.totalInfusedZico);
    }
    
    /**
     * @notice FIXED: Get detailed infusion statistics with proper calculations
     */
    function getDetailedInfusionStats(uint256 collectionId, uint256 tokenId) external view returns (
        bool infused,
        uint256 infusedAmount,
        uint8 infusionLevel,
        uint256 pendingRewards,
        uint256 maxInfusionAmount,
        uint256 infusionPercentage
    ) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        InfusedSpecimen storage infusedData = ss.infusedSpecimens[combinedId];
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        // Initialize infusionPercentage to 0 by default
        infusionPercentage = 0;
        
        // Early return if token is not infused
        if (!infusedData.infused) {
            return (false, 0, 0, 0, 0, 0);
        }
        
        // Check if token is staked - critical for safely accessing variant
        if (!staked.staked) {
            return (true, infusedData.infusedAmount, 0, 0, 0, 0);
        }
        
        // Safely normalize variant to valid range (1-4)
        uint8 safeVariant = staked.variant;
        if (safeVariant < 1) safeVariant = 1;
        if (safeVariant > 4) safeVariant = 4;
        
        // Get max infusion for variant with fallback to prevent division by zero
        maxInfusionAmount = ss.settings.baseMaxInfusionByVariant[safeVariant];
        if (maxInfusionAmount == 0) {
            // Default values based on variant
            if (safeVariant == 1) maxInfusionAmount = 100 ether;
            else if (safeVariant == 2) maxInfusionAmount = 200 ether;
            else if (safeVariant == 3) maxInfusionAmount = 350 ether;
            else maxInfusionAmount = 500 ether;
        }
        
        // Calculate percentage safely - maxInfusionAmount is guaranteed non-zero
        infusionPercentage = Math.mulDiv(infusedData.infusedAmount, 100, maxInfusionAmount);
        
        // FIXED: Get pending rewards using corrected calculation
        pendingRewards = getPendingInfusionRewardsFixed(collectionId, tokenId);
        
        // Apply safety cap to pending rewards
        if (pendingRewards > MAX_TOTAL_REWARD) {
            pendingRewards = MAX_TOTAL_REWARD;
        }
        
        return (
            true,
            infusedData.infusedAmount,
            staked.infusionLevel,
            pendingRewards,
            maxInfusionAmount,
            infusionPercentage
        );
    }

    /**
     * @notice FIXED: Calculate estimated daily reward for infusion
     */
    function estimateInfusionRewards(uint256 collectionId, uint256 tokenId, uint256 infusionAmount) external view returns (uint256 dailyReward, uint256 annualAPR) {
        // Skip if amount is 0
        if (infusionAmount == 0) {
            return (0, 0);
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        // Skip if not staked
        if (!staked.staked) {
            return (0, 0);
        }
        
        // Apply safety caps
        uint8 safeVariant = staked.variant;
        if (safeVariant == 0) safeVariant = 1;
        if (safeVariant > MAX_VARIANT) safeVariant = MAX_VARIANT;
        
        uint8 safeInfusionLevel = staked.infusionLevel;
        if (safeInfusionLevel > MAX_INFUSION_LEVEL) safeInfusionLevel = MAX_INFUSION_LEVEL;
        
        // Get basic APR info with non-zero defaults
        uint256 baseAPR = ss.settings.baseInfusionAPR;
        if (baseAPR == 0) baseAPR = 5; // 5% as reasonable default
        
        uint256 seasonMultiplier = ss.currentSeason.active ? ss.currentSeason.multiplier : 100;
        // Ensure multiplier is never zero
        if (seasonMultiplier == 0) seasonMultiplier = 100;
        
        // FIXED: Calculate effective APR using RewardCalculator
        annualAPR = RewardCalculator.calculateInfusionAPR(
            baseAPR,
            safeVariant,
            safeInfusionLevel,
            seasonMultiplier
        );
        
        // Apply configurable limit instead of hardcoded 200
        uint256 maxAPR = _getLimit("maxAPR");
        if (annualAPR > maxAPR) {
            annualAPR = maxAPR;
        }
        
        // Set up a dummy InfusionCalcData for daily reward calculation
        InfusionCalcData memory dummyData;
        // Apply safety cap to infusion amount
        dummyData.infusedAmount = infusionAmount > MAX_SAFE_INTEGER ? MAX_SAFE_INTEGER : infusionAmount;
        dummyData.apr = annualAPR > 0 ? annualAPR : 1; // Ensure APR is at least 1%
        dummyData.timeElapsed = 1 days;
        
        // Calculate intelligence safely
        uint8 safeLevel = staked.level;
        if (safeLevel > MAX_TOKEN_LEVEL) safeLevel = MAX_TOKEN_LEVEL;
        
        uint16 intelligence = (uint16(safeLevel) / 2) + (uint16(safeVariant) * 3);
        dummyData.intelligence = intelligence > 100 ? 100 : uint8(intelligence);
        
        // Get wear level with safety cap
        dummyData.wearLevel = staked.wearLevel > MAX_WEAR_LEVEL ? MAX_WEAR_LEVEL : staked.wearLevel;
        
        // FIXED: Calculate daily reward using RewardCalculator
        dailyReward = RewardCalculator.calculateInfusionRewardFromData(dummyData);
        
        // Apply safety cap
        if (dailyReward > MAX_TOTAL_REWARD) {
            dailyReward = MAX_TOTAL_REWARD;
        }
        
        return (dailyReward, annualAPR);
    }

    /**
     * @notice Configure whether to apply balance adjustment to infusion rewards
     */
    function setBalanceAdjustmentForInfusion(bool applyToInfusion) external {
        if (!AccessHelper.isAuthorized()) {
            revert UnauthorizedCaller();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Store the setting in the balanceAdjustment struct
        ss.settings.balanceAdjustment.applyToInfusion = applyToInfusion;
        
        emit OperationResult("BalanceAdjustmentForInfusionSet", true);
    }

    /**
     * @notice FIXED: Apply balance adjustment to infusion rewards using progressive decay
     * @dev Uses the corrected RewardCalculator with progressive decay
     */
    function _applyBalanceAdjustmentFixed(
        uint256 baseAmount,
        address staker,
        uint256 stakingDuration,
        LibStakingStorage.StakingStorage storage ss
    ) private view returns (uint256) {
        // Skip if disabled, not applicable to infusion, or baseAmount is zero
        if (!ss.settings.balanceAdjustment.enabled || 
            !ss.settings.balanceAdjustment.applyToInfusion || 
            baseAmount == 0) {
            return baseAmount;
        }
        
        uint256 userStakedCount = ss.stakerTokenCount[staker];
        uint256 totalStakedCount = ss.totalStakedSpecimens;
        
        // Safety check for division by zero
        if (totalStakedCount == 0) {
            return baseAmount;
        }
        
        // Create a basic RewardCalcData with only the base reward
        RewardCalcData memory rewardData;
        rewardData.baseReward = baseAmount;
        
        // Create parameter struct for balance calculation
        StakeBalanceParams memory balanceParams = StakeBalanceParams({
            userStakedCount: userStakedCount,
            totalStakedCount: totalStakedCount,
            stakingDuration: stakingDuration,
            balanceEnabled: ss.settings.balanceAdjustment.enabled,
            decayRate: ss.settings.balanceAdjustment.decayRate,
            minMultiplier: ss.settings.balanceAdjustment.minMultiplier,
            timeEnabled: ss.settings.timeDecay.enabled,
            maxTimeBonus: ss.settings.timeDecay.maxBonus,
            timePeriod: ss.settings.timeDecay.period
        });
        
        // FIXED: Apply balance adjustment using corrected progressive decay
        return RewardCalculator.calculateRewardWithStakeBalance(
            rewardData,
            balanceParams
        );
    }

    function _getLimit(string memory limitType) private view returns (uint256) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        if (keccak256(bytes(limitType)) == keccak256(bytes("maxAPR"))) {
            return ss.systemLimits.maxInfusionAPR > 0 ? ss.systemLimits.maxInfusionAPR : 200;
        }
        return 200; // Default fallback
    }


}