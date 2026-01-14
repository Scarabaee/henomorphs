// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibStakingStorage} from "../libraries/LibStakingStorage.sol";
import {LibBiopodIntegration} from "../libraries/LibBiopodIntegration.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {PodsUtils} from "../../libraries/PodsUtils.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StakedSpecimen, RewardCalcData, StakeBalanceParams} from "../../libraries/StakingModel.sol";
import {SpecimenCollection, ChargeAccessory} from "../../libraries/HenomorphsModel.sol";
import {IStakingBiopodFacet, IStakingIntegrationFacet, IStakingWearFacet} from "../interfaces/IStakingInterfaces.sol";
import {RewardCalculator} from "../libraries/RewardCalculator.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IAccessoryFacet {
    function getTokenAccessories(uint256 collectionId, uint256 tokenId) external view returns (ChargeAccessory[] memory);
    function getAugmentationStatus(uint256 collectionId, uint256 tokenId) external view returns (
        bool hasTraitPack,
        uint8 traitPackId,
        uint8 variant,
        uint256 accessoryCount,
        uint64[] memory accessoryIds,
        bool bonusesWouldApply,
        uint256 expectedEfficiencyBonus,
        uint256 expectedRegenBonus,
        uint256 expectedChargeBonus
    );
    function checkTokenHasTraitPack(uint256 collectionId, uint256 tokenId) external view returns (bool hasTraitPack, uint256 traitPackId);
}

/**
 * @title StakingClaimFacet
 * @notice DEPRECATED - Production reward claiming system with clean API
 * @dev This facet is deprecated. Use StakingEarningsFacet instead.
 *      All claiming functions have been disabled to prevent further reward distribution.
 * @author rutilicus.eth (ArchXS)
 */
contract StakingClaimFacet is AccessControlBase {
    using Math for uint256;
    
    uint256 private constant MAX_TOTAL_REWARD = 2**224;
    uint256 private constant MAX_TOKENS_PER_BATCH = 30;

    struct BatchVars {
        uint256 totalAmount;
        uint256 tokenCount;
        uint256 repairsPerformed;
    }

    // Events
    event RewardClaimed(uint256 indexed collectionId, uint256 indexed tokenId, address indexed staker, uint256 amount);
    event BatchRewardsClaimed(address indexed staker, uint256 totalAmount, uint256 tokenCount);
    event RewardCapped(uint256 collectionId, uint256 tokenId, uint256 originalAmount, uint256 cappedAmount);
    event AutoRepairsPerformed(address indexed staker, uint256 repairsPerformed, uint256 totalRewardsClaimed, uint256 tokenCount);

    // Errors
    error InvalidCollectionId();
    error TokenNotStaked();
    error NothingToClaim();
    error TooManyTokens(uint256 tokenCount, uint256 maxAllowed);
    error InsufficientTreasuryBalance(uint256 required, uint256 available);
    error FacetDeprecated(string message);

    /**
     * @notice Claim rewards for a specific token
     * @dev DEPRECATED: This function is no longer available. Use StakingEarningsFacet.claimStakingRewards() instead.
     */
    function claimRewards(uint256, uint256)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 amount)
    {
        return 0;
    }

    /**
     * @notice Claim all available rewards
     * @dev DEPRECATED: This function is no longer available. Use StakingEarningsFacet.claimBatchStakingRewards() instead.
     */
    function claimAllRewards() external whenNotPaused nonReentrant returns (uint256 totalAmount, uint256 tokenCount) {
        return (0, 0);
    }

    /**
     * @notice Claim all rewards without auto-repair
     * @dev DEPRECATED: This function is no longer available. Use StakingEarningsFacet.claimBatchStakingRewards() instead.
     */
    function claimAllNoRepair() external whenNotPaused nonReentrant returns (uint256 totalAmount, uint256 tokenCount, uint256 repairsPerformed) {
        return (0, 0, 0);
    }

    /**
     * @notice Batch claim with progress tracking
     * @dev DEPRECATED: This function is no longer available. Use StakingEarningsFacet.claimBatchStakingRewards() instead.
     */
    function claimBatchDeprecated(uint256, uint256)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 totalAmount, uint256 tokenCount, bool hasMore, uint256 nextStart)
    {
        return (0, 0, false, 0);
    }

    /**
     * @notice Get pending rewards for a specific token
     */
    function getPendingRewards(uint256 collectionId, uint256 tokenId) external view returns (uint256 amount) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        if (collectionId == 0 || collectionId > ss.collectionCounter) {
            return 0;
        }
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        if (!staked.staked) {
            return 0;
        }
        
        return _calculateTokenReward(collectionId, tokenId, staked);
    }

    /**
     * @notice Get total pending rewards for address
     */
    function getPendingTotal(address staker) external view returns (uint256 totalAmount, uint256 tokenCount) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        uint256[] storage tokens = ss.stakerTokens[staker];
        
        if (tokens.length == 0) {
            return (0, 0);
        }
        
        uint256 maxProcess = tokens.length > 50 ? 50 : tokens.length;
        
        for (uint256 i = 0; i < maxProcess; i++) {
            uint256 combinedId = tokens[i];
            StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
            
            if (!staked.staked || staked.owner != staker) {
                continue;
            }
            
            (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);
            
            uint256 reward = _calculateTokenReward(collectionId, tokenId, staked);
            
            if (reward > 0) {
                if (totalAmount <= MAX_TOTAL_REWARD - reward) {
                    totalAmount += reward;
                    tokenCount++;
                } else {
                    totalAmount = MAX_TOTAL_REWARD;
                    break;
                }
            }
        }
        
        return (totalAmount, tokenCount);
    }

    /**
     * @notice Process pending rewards during unstaking (authorized access only)
     * @dev This function should only be called by authorized facets/operators within the diamond
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return pendingRewards Amount of rewards processed
     */
    function processPendingRewards(uint256 collectionId, uint256 tokenId) 
        external 
        whenNotPaused 
        returns (uint256 pendingRewards) 
    {

        if (!AccessHelper.isInternalCall() ) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not authorized");
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        if (collectionId == 0 || collectionId > ss.collectionCounter) {
            return 0;
        }
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        if (!staked.staked) {
            return 0;
        }
        
        // Use token owner from storage (not msg.sender since this is authorized call)
        address tokenOwner = staked.owner;
        
        pendingRewards = _calculateTokenReward(collectionId, tokenId, staked);
        
        if (pendingRewards > 0) {
            if (pendingRewards > MAX_TOTAL_REWARD) {
                emit RewardCapped(collectionId, tokenId, pendingRewards, MAX_TOTAL_REWARD);
                pendingRewards = MAX_TOTAL_REWARD;
            }

            _checkTreasuryBalance(ss, pendingRewards);
            
            // Update claim timestamp
            staked.lastClaimTimestamp = uint32(block.timestamp);
            
            // Process fees for the actual token owner
            _processFees(ss, tokenOwner, pendingRewards, "unstake_rewards");
            
            unchecked {
                ss.totalRewardsDistributed += pendingRewards;
            }

            _applyExperienceGain(collectionId, tokenId, pendingRewards);
            
            emit RewardClaimed(collectionId, tokenId, tokenOwner, pendingRewards);
        }
        
        return pendingRewards;
    }

    // =================== CORE CALCULATION ===================

    /**
     * @notice Main reward calculation
     */
    function _calculateTokenReward(
        uint256 collectionId,
        uint256 tokenId,
        StakedSpecimen storage staked
    ) private view returns (uint256) {
        uint256 timeElapsed = block.timestamp - staked.lastClaimTimestamp;
        if (timeElapsed == 0) return 0;
        
        if (timeElapsed > LibStakingStorage.MAX_REWARD_PERIOD) {
            timeElapsed = LibStakingStorage.MAX_REWARD_PERIOD;
        }
        
        RewardCalcData memory rewardData = _getTokenRewardData(collectionId, tokenId, staked, timeElapsed);
        
        if (rewardData.baseReward == 0) return 0;
        
        StakeBalanceParams memory balanceParams = _getBalanceParams(staked);
        
        return RewardCalculator.calculateRewardWithStakeBalance(rewardData, balanceParams);
    }

    /**
     * @notice Get token reward data
     */
    function _getTokenRewardData(
        uint256 collectionId,
        uint256 tokenId,
        StakedSpecimen storage staked,
        uint256 timeElapsed
    ) private view returns (RewardCalcData memory data) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        data.baseReward = RewardCalculator.calculateBaseTimeReward(staked.variant, timeElapsed);
        
        data.level = staked.level;
        data.variant = staked.variant;
        data.chargeLevel = staked.chargeLevel;
        data.infusionLevel = staked.infusionLevel;
        data.specialization = staked.specialization;
        data.baseMultiplier = 100;
        
        data.wearLevel = _getCurrentWearLevel(collectionId, tokenId, staked);
        data.wearPenalty = uint8(LibStakingStorage.calculateWearPenalty(data.wearLevel));
        
        if (staked.colonyId != bytes32(0)) {
            uint256 rawBonus = _getColonyBonus(ss, staked.colonyId);
            data.colonyBonus = RewardCalculator.processColonyBonus(rawBonus, _getMaxCreatorBonus(ss));
        }
        
        data.seasonMultiplier = ss.currentSeason.active ? ss.currentSeason.multiplier : 100;
        if (data.seasonMultiplier > 300) data.seasonMultiplier = 300;
        
        uint256 stakingDuration = block.timestamp - staked.stakedSince;
        data.loyaltyBonus = LibStakingStorage.calculateLoyaltyBonus(stakingDuration);
        
        data.accessoryBonus = _calculateAccessoryBonus(collectionId, tokenId, staked.specialization);
        
        return data;
    }

    /**
     * @notice Calculate accessory bonus with fallbacks
     */
    function _calculateAccessoryBonus(
        uint256 collectionId,
        uint256 tokenId,
        uint8 specialization
    ) private view returns (uint256 totalBonus) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        (uint256 cachedBonus, bool cacheValid) = LibStakingStorage.getCachedAccessoryBonus(combinedId);
        if (cacheValid) {
            return cachedBonus;
        }
        
        address accessoryFacet = ss.externalModules.accessoryModuleAddress;
        
        if (accessoryFacet != address(0)) {
            try IAccessoryFacet(accessoryFacet).getAugmentationStatus(collectionId, tokenId) returns (
                bool hasTraitPack,
                uint8 traitPackId,
                uint8 variant,
                uint256 accessoryCount,
                uint64[] memory accessoryIds,
                bool bonusesWouldApply,
                uint256,
                uint256,
                uint256
            ) {
                if (bonusesWouldApply) {
                    if (hasTraitPack) {
                        totalBonus += _calculateTraitPackBonus(traitPackId, variant, accessoryCount);
                    }
                    totalBonus += _calculateAccessoryBonus(accessoryIds, specialization);
                }
            } catch {
                totalBonus = _calculateBasicAccessoryBonus(ss, collectionId, tokenId, specialization);
            }
        } else {
            totalBonus = _calculateBasicAccessoryBonus(ss, collectionId, tokenId, specialization);
        }
        
        uint256 maxBonus = _getMaxAccessoryBonus(ss);
        if (totalBonus > maxBonus) totalBonus = maxBonus;
        
        return totalBonus;
    }

    // =================== HELPER METHODS ===================

    function _getCurrentWearLevel(
        uint256 collectionId,
        uint256 tokenId,
        StakedSpecimen storage staked
    ) private view returns (uint8) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        SpecimenCollection storage collection = ss.collections[collectionId];
        if (collection.biopodAddress != address(0)) {
            (uint256 _currentWear, ) = LibBiopodIntegration.getStakingWearLevel(collectionId, tokenId);
            return uint8(_currentWear > 100 ? 100 : _currentWear);
        }
        
        uint256 currentWear = staked.wearLevel;
        
        if (ss.wearIncreasePerDay > 0) {
            uint256 timeElapsed = block.timestamp - staked.lastWearUpdateTime;
            if (timeElapsed > 3600) {
                uint256 wearIncrease = (timeElapsed * ss.wearIncreasePerDay) / LibStakingStorage.SECONDS_PER_DAY;
                currentWear += wearIncrease;
                if (currentWear > 100) currentWear = 100;
            }
        }
        
        return uint8(currentWear);
    }

    function _getColonyBonus(
        LibStakingStorage.StakingStorage storage ss,
        bytes32 colonyId
    ) private view returns (uint256) {
        uint256 bonus = ss.colonyStakingBonuses[colonyId];
        if (bonus > 0) return bonus;
        
        bonus = ss.colonies[colonyId].stakingBonus;
        if (bonus > 0) return bonus;
        
        return 10;
    }

    function _calculateTraitPackBonus(
        uint8 traitPackId,
        uint8 variant,
        uint256 accessoryCount
    ) private pure returns (uint256 bonus) {
        if (traitPackId == 0) return 0;
        
        bonus = 10;
        
        if (variant == 1) {
            bonus += 3;
        } else if (variant == 2) {
            bonus += 5;
        } else if (variant == 3) {
            bonus += 4;
        } else if (variant == 4) {
            bonus += 8;
        }
        
        if (accessoryCount >= 3) {
            bonus += 5;
        } else if (accessoryCount >= 2) {
            bonus += 2;
        }
        
        return bonus;
    }

    function _calculateAccessoryBonus(
        uint64[] memory accessoryIds,
        uint8 specialization
    ) private pure returns (uint256 bonus) {
        if (accessoryIds.length == 0) return 0;
        
        uint256 processCount = accessoryIds.length > 5 ? 5 : accessoryIds.length;
        
        for (uint256 i = 0; i < processCount; i++) {
            uint8 accessoryId = uint8(accessoryIds[i]);
            
            bonus += 2;
            
            if (specialization == 1 && accessoryId == 1) {
                bonus += 3;
            } else if (specialization == 2 && accessoryId == 2) {
                bonus += 3;
            }
        }
        
        return bonus;
    }

    function _calculateBasicAccessoryBonus(
        LibStakingStorage.StakingStorage storage ss,
        uint256 collectionId,
        uint256 tokenId,
        uint8 specialization
    ) private view returns (uint256) {
        ChargeAccessory[] memory accessories = LibStakingStorage.getTokenAccessories(ss, collectionId, tokenId);
        return RewardCalculator.calculateAccessoryBonus(accessories, specialization);
    }

    function _getBalanceParams(StakedSpecimen storage staked) 
        private 
        view 
        returns (StakeBalanceParams memory) 
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        return StakeBalanceParams({
            userStakedCount: ss.stakerTokenCount[staked.owner],
            totalStakedCount: ss.totalStakedSpecimens,
            stakingDuration: block.timestamp - staked.stakedSince,
            balanceEnabled: ss.settings.balanceAdjustment.enabled,
            decayRate: ss.settings.balanceAdjustment.decayRate,
            minMultiplier: ss.settings.balanceAdjustment.minMultiplier,
            timeEnabled: ss.settings.timeDecay.enabled,
            maxTimeBonus: ss.settings.timeDecay.maxBonus,
            timePeriod: ss.settings.timeDecay.period
        });
    }

    function _getMaxCreatorBonus(LibStakingStorage.StakingStorage storage ss) private view returns (uint256) {
        if (ss.configVersion >= 2) {
            LibStakingStorage.RewardCalculationConfig storage config = ss.rewardCalculationConfig;
            if (config.maxAdminColonyBonus > 0) {
                return config.maxAdminColonyBonus;
            }
        }
        return LibStakingStorage.getMaxCreatorBonusPercentage();
    }

    function _getMaxAccessoryBonus(LibStakingStorage.StakingStorage storage ss) private view returns (uint256) {
        uint256 maxBonus = ss.rewardCalculationConfig.maxAccessoryBonus;
        return maxBonus > 0 ? maxBonus : 50;
    }

    // =================== BATCH PROCESSING ===================

    function _claimAll(uint256[] storage tokens) 
        private 
        returns (uint256, uint256) 
    {
        address sender = LibMeta.msgSender();
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        BatchVars memory vars;
        
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 combinedId = tokens[i];
            StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
            
            if (!staked.staked || staked.owner != sender) {
                continue;
            }
            
            (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);
            
            if (_performAutoRepair(collectionId, tokenId)) {
                vars.repairsPerformed++;
            }

            uint256 reward = _calculateTokenReward(collectionId, tokenId, staked);
            
            if (reward > 0) {
                if (vars.totalAmount > MAX_TOTAL_REWARD - reward) {
                    reward = MAX_TOTAL_REWARD > vars.totalAmount ? MAX_TOTAL_REWARD - vars.totalAmount : 0;
                }
                
                if (reward > 0) {
                    staked.lastClaimTimestamp = uint32(block.timestamp);
                    _applyExperienceGain(collectionId, tokenId, reward);
                    emit RewardClaimed(collectionId, tokenId, sender, reward);
                    
                    vars.totalAmount += reward;
                    vars.tokenCount++;
                    
                    if (vars.totalAmount >= MAX_TOTAL_REWARD) {
                        vars.totalAmount = MAX_TOTAL_REWARD;
                        break;
                    }
                }
            }
        }
        
        if (vars.totalAmount == 0) {
            revert NothingToClaim();
        }

        _checkTreasuryBalance(ss, vars.totalAmount);
        _processFees(ss, sender, vars.totalAmount, "claimAllRewards");
        
        unchecked {
            ss.totalRewardsDistributed += vars.totalAmount;
        }
        
        emit BatchRewardsClaimed(sender, vars.totalAmount, vars.tokenCount);
        
        if (vars.repairsPerformed > 0) {
            emit AutoRepairsPerformed(sender, vars.repairsPerformed, vars.totalAmount, vars.tokenCount);
        }
        
        return (vars.totalAmount, vars.tokenCount);
    }

    function _claimAllNoRepair(uint256[] storage tokens) 
        private 
        returns (uint256, uint256) 
    {
        address sender = LibMeta.msgSender();
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        BatchVars memory vars;
        
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 combinedId = tokens[i];
            StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
            
            if (!staked.staked || staked.owner != sender) {
                continue;
            }
            
            (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);

            uint256 reward = _calculateTokenReward(collectionId, tokenId, staked);
            
            if (reward > 0) {
                if (vars.totalAmount > MAX_TOTAL_REWARD - reward) {
                    reward = MAX_TOTAL_REWARD > vars.totalAmount ? MAX_TOTAL_REWARD - vars.totalAmount : 0;
                }
                
                if (reward > 0) {
                    staked.lastClaimTimestamp = uint32(block.timestamp);
                    _applyExperienceGain(collectionId, tokenId, reward);
                    emit RewardClaimed(collectionId, tokenId, sender, reward);
                    
                    vars.totalAmount += reward;
                    vars.tokenCount++;
                    
                    if (vars.totalAmount >= MAX_TOTAL_REWARD) {
                        vars.totalAmount = MAX_TOTAL_REWARD;
                        break;
                    }
                }
            }
        }
        
        if (vars.totalAmount == 0) {
            revert NothingToClaim();
        }

        _checkTreasuryBalance(ss, vars.totalAmount);
        _processFees(ss, sender, vars.totalAmount, "claimAllRewards");
        
        unchecked {
            ss.totalRewardsDistributed += vars.totalAmount;
        }
        
        emit BatchRewardsClaimed(sender, vars.totalAmount, vars.tokenCount);
        
        return (vars.totalAmount, vars.tokenCount);
    }

    function _processBatch(
        uint256[] storage tokens,
        uint256 startIndex,
        uint256 batchSize,
        address sender,
        LibStakingStorage.StakingStorage storage ss
    ) private returns (uint256, uint256, bool, uint256) {
        uint256 endIndex = startIndex + batchSize;
        if (endIndex > tokens.length) {
            endIndex = tokens.length;
        }
        
        BatchVars memory vars;
        
        for (uint256 i = startIndex; i < endIndex; i++) {
            uint256 combinedId = tokens[i];
            StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
            
            if (!staked.staked || staked.owner != sender) {
                continue;
            }
            
            (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);
            
            if (_performAutoRepair(collectionId, tokenId)) {
                vars.repairsPerformed++;
            }

            uint256 reward = _calculateTokenReward(collectionId, tokenId, staked);
            
            if (reward > 0) {
                if (vars.totalAmount > MAX_TOTAL_REWARD - reward) {
                    reward = MAX_TOTAL_REWARD > vars.totalAmount ? MAX_TOTAL_REWARD - vars.totalAmount : 0;
                }
                
                if (reward > 0) {
                    staked.lastClaimTimestamp = uint32(block.timestamp);
                    _applyExperienceGain(collectionId, tokenId, reward);
                    emit RewardClaimed(collectionId, tokenId, sender, reward);
                    
                    vars.totalAmount += reward;
                    vars.tokenCount++;
                    
                    if (vars.totalAmount >= MAX_TOTAL_REWARD) {
                        vars.totalAmount = MAX_TOTAL_REWARD;
                        break;
                    }
                }
            }
        }
        
        if (vars.totalAmount == 0) {
            revert NothingToClaim();
        }

        _checkTreasuryBalance(ss, vars.totalAmount);
        _processFees(ss, sender, vars.totalAmount, "claimBatch");
        
        unchecked {
            ss.totalRewardsDistributed += vars.totalAmount;
        }
        
        emit BatchRewardsClaimed(sender, vars.totalAmount, vars.tokenCount);
        
        if (vars.repairsPerformed > 0) {
            emit AutoRepairsPerformed(sender, vars.repairsPerformed, vars.totalAmount, vars.tokenCount);
        }
        
        bool hasMore = endIndex < tokens.length;
        uint256 nextStartIndex = endIndex;
        
        return (vars.totalAmount, vars.tokenCount, hasMore, nextStartIndex);
    }

    function _claimAllInBatches() 
        private 
        returns (uint256 totalAmount, uint256 tokenCount) 
    {
        totalAmount = 0;
        tokenCount = 0;
        uint256 startIndex = 0;
        bool hasMore = true;
        uint256 batchCount = 0;
        uint256 maxBatches = 10;
        
        while (hasMore && batchCount < maxBatches) {
            (
                uint256 batchAmount,
                uint256 batchTokens,
                bool more,
                uint256 nextStartIndex
            ) = _claimBatchInternal(startIndex, MAX_TOKENS_PER_BATCH);
                totalAmount += batchAmount;
                tokenCount += batchTokens;
                hasMore = more;
                startIndex = nextStartIndex;
                batchCount++;
                
            if (batchAmount == 0 || !more) {
                break;
            }
        }
        
        if (totalAmount > 0) {
            emit BatchRewardsClaimed(LibMeta.msgSender(), totalAmount, tokenCount);
        }
        
        return (totalAmount, tokenCount);
    }

    function _claimBatchInternal(
        uint256 startIndex, 
        uint256 batchSize
    ) internal whenNotPaused nonReentrant returns (
        uint256 totalAmount, 
        uint256 tokenCount, 
        bool hasMore,
        uint256 nextStartIndex
    ) {
        address sender = LibMeta.msgSender();
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        uint256[] storage tokens = ss.stakerTokens[sender];
        
        if (tokens.length == 0) {
            return (0, 0, false, startIndex);
        }
        
        return _processBatch(tokens, startIndex, batchSize, sender, ss);
    }

    // =================== UTILITY FUNCTIONS ===================

    function _checkTreasuryBalance(
        LibStakingStorage.StakingStorage storage ss,
        uint256 amount
    ) private view {
        if (amount == 0) return;
        
        uint256 balance = IERC20(ss.zicoToken).balanceOf(ss.settings.treasuryAddress);
        if (balance < amount) {
            revert InsufficientTreasuryBalance(amount, balance);
        }
    }

    function _processFees(
        LibStakingStorage.StakingStorage storage ss,
        address sender,
        uint256 amount,
        string memory operation
    ) private {
        LibFeeCollection.processOperationFee(ss.fees.claimFee, sender);
        LibFeeCollection.collectFee(
            ss.zicoToken,
            ss.settings.treasuryAddress,
            sender,
            amount,
            operation
        );
    }
    
    function _performAutoRepair(uint256 collectionId, uint256 tokenId) private returns (bool repaired) {
        try IStakingWearFacet(address(this)).checkAndPerformAutoRepair(collectionId, tokenId) returns (bool result) {
            return result;
        } catch {
            return false;
        }
    }

    function _applyExperienceGain(uint256 collectionId, uint256 tokenId, uint256 amount) private {
        try IStakingIntegrationFacet(address(this)).applyExperienceFromRewards(collectionId, tokenId, amount) {
            // Successfully applied
        } catch {
            // Continue if experience update fails
        }
    }

    // =================== VIEW FUNCTIONS ===================

    function getRewardBreakdown(uint256 collectionId, uint256 tokenId) 
        external 
        view 
        returns (
            uint256 baseReward,
            uint256 levelBonus,
            uint256 variantBonus,
            uint256 chargeBonus,
            uint256 colonyBonus,
            uint256 loyaltyBonus,
            uint256 seasonMultiplier,
            uint256 balanceMultiplier,
            uint256 wearPenalty,
            uint256 finalReward
        ) 
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        if (!staked.staked) {
            return (0,0,0,0,0,0,0,0,0,0);
        }
        
        uint256 timeElapsed = block.timestamp - staked.lastClaimTimestamp;
        RewardCalcData memory data = _getTokenRewardData(collectionId, tokenId, staked, timeElapsed);
        
        baseReward = data.baseReward;
        variantBonus = data.variant > 0 ? (data.variant - 1) * 4 : 0;
        levelBonus = data.level * 40 / 100;
        chargeBonus = data.chargeLevel >= 80 ? 10 : (data.chargeLevel >= 60 ? 6 : (data.chargeLevel >= 40 ? 3 : 0));
        colonyBonus = data.colonyBonus;
        loyaltyBonus = data.loyaltyBonus;
        seasonMultiplier = data.seasonMultiplier;
        wearPenalty = data.wearPenalty;
        
        balanceMultiplier = 100;
        if (staked.owner != address(0) && 
            ss.totalStakedSpecimens > 0 && 
            block.timestamp >= staked.stakedSince) {
            
            uint256 stakingDuration = block.timestamp - staked.stakedSince;
            
            balanceMultiplier = RewardCalculator.calculateStakeBalanceMultiplier(
                ss.stakerTokenCount[staked.owner],
                ss.totalStakedSpecimens,
                stakingDuration,
                ss.settings.balanceAdjustment.enabled,
                ss.settings.balanceAdjustment.decayRate,
                ss.settings.balanceAdjustment.minMultiplier,
                ss.settings.timeDecay.enabled,
                ss.settings.timeDecay.maxBonus,
                ss.settings.timeDecay.period
            );
        }
        
        finalReward = _calculateTokenReward(collectionId, tokenId, staked);
        
        return (
            baseReward,
            levelBonus,
            variantBonus,
            chargeBonus,
            colonyBonus,
            loyaltyBonus,
            seasonMultiplier,
            balanceMultiplier,
            wearPenalty,
            finalReward
        );
    }

    function getUserMultiplier(
        address staker,
        uint256 stakingDuration
    ) external view returns (
        uint256 balanceMultiplier,
        uint256 timeBonus,
        uint256 totalMultiplier
    ) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        uint256 userStakedCount = ss.stakerTokenCount[staker];
        
        balanceMultiplier = RewardCalculator.calculateStakeBalanceMultiplier(
            userStakedCount,
            ss.totalStakedSpecimens,
            stakingDuration,
            ss.settings.balanceAdjustment.enabled,
            ss.settings.balanceAdjustment.decayRate,
            ss.settings.balanceAdjustment.minMultiplier,
            ss.settings.timeDecay.enabled,
            ss.settings.timeDecay.maxBonus,
            ss.settings.timeDecay.period
        );
        
        if (ss.settings.timeDecay.enabled && stakingDuration > 0) {
            uint256 safePeriod = ss.settings.timeDecay.period == 0 ? 90 days : ss.settings.timeDecay.period;
            uint256 safeMaxBonus = ss.settings.timeDecay.maxBonus > 50 ? 16 : ss.settings.timeDecay.maxBonus;
            
            if (stakingDuration >= safePeriod) {
                timeBonus = safeMaxBonus;
            } else {
                timeBonus = Math.mulDiv(stakingDuration, safeMaxBonus, safePeriod);
            }
        }
        
        totalMultiplier = balanceMultiplier;
        
        return (balanceMultiplier - timeBonus, timeBonus, totalMultiplier);
    }

    function getAugmentationInfo(uint256 collectionId, uint256 tokenId) 
        external 
        view 
        returns (
            bool hasTraitPack,
            uint8 traitPackId,
            uint8 variant,
            uint256 accessoryCount,
            uint64[] memory accessoryIds,
            uint256 traitPackStakingBonus,
            uint256 accessoryStakingBonus,
            uint256 totalStakingBonus,
            bool bonusesActive
        ) 
    {
        address accessoryFacet = address(this);
        
        try IAccessoryFacet(accessoryFacet).getAugmentationStatus(collectionId, tokenId) returns (
            bool _hasTraitPack,
            uint8 _traitPackId,
            uint8 _variant,
            uint256 _accessoryCount,
            uint64[] memory _accessoryIds,
            bool _bonusesWouldApply,
            uint256,
            uint256,
            uint256
        ) {
            hasTraitPack = _hasTraitPack;
            traitPackId = _traitPackId;
            variant = _variant;
            accessoryCount = _accessoryCount;
            accessoryIds = _accessoryIds;
            bonusesActive = _bonusesWouldApply;
            
            if (bonusesActive) {
                traitPackStakingBonus = _calculateTraitPackBonus(traitPackId, variant, accessoryCount);
                accessoryStakingBonus = _calculateAccessoryBonus(accessoryIds, 0);
                totalStakingBonus = traitPackStakingBonus + accessoryStakingBonus;
                
                LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
                uint256 maxBonus = _getMaxAccessoryBonus(ss);
                if (totalStakingBonus > maxBonus) {
                    totalStakingBonus = maxBonus;
                }
            }
        } catch {
            hasTraitPack = false;
            traitPackId = 0;
            variant = 0;
            accessoryCount = 0;
            accessoryIds = new uint64[](0);
            traitPackStakingBonus = 0;
            accessoryStakingBonus = 0;
            totalStakingBonus = 0;
            bonusesActive = false;
        }
        
        return (
            hasTraitPack,
            traitPackId,
            variant,
            accessoryCount,
            accessoryIds,
            traitPackStakingBonus,
            accessoryStakingBonus,
            totalStakingBonus,
            bonusesActive
        );
    }

    // =================== COMPATIBILITY ALIASES ===================

    /**
     * @dev DEPRECATED: View functions remain available for backward compatibility
     */
    function calculateAccuratePendingRewards(address staker, bool) 
        external 
        view
        returns (uint256 totalAmount, uint256 tokenCount) 
    {
        return this.getPendingTotal(staker);
    }

    /**
     * @dev DEPRECATED: View functions remain available for backward compatibility
     */
    function getTotalPendingRewardsForAddress(address staker) external view returns (uint256 totalAmount, uint256 tokenCount) {
        return this.getPendingTotal(staker);
    }

    /**
     * @dev DEPRECATED: This function is no longer available. Use StakingEarningsFacet.claimBatchStakingRewards() instead.
     */
    function claimAllRewardsWithoutRepair() external whenNotPaused nonReentrant returns (uint256 totalAmount, uint256 tokenCount, uint256 repairsPerformed) {
        return (0, 0, 0);
    }

    /**
     * @dev DEPRECATED: This function is no longer available. Use StakingEarningsFacet.claimBatchStakingRewards() instead.
     */
    function claimRewardsBatchWithProgress(uint256, uint256)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 totalAmount, uint256 tokenCount, bool hasMore, uint256 nextStart)
    {
        return (0, 0, false, 0);
    }

    /**
     * @dev DEPRECATED: View functions remain available for backward compatibility
     */
    function getTokenAugmentationInfo(uint256 collectionId, uint256 tokenId) 
        external 
        view 
        returns (
            bool hasTraitPack,
            uint8 traitPackId,
            uint8 variant,
            uint256 accessoryCount,
            uint64[] memory accessoryIds,
            uint256 traitPackStakingBonus,
            uint256 accessoryStakingBonus,
            uint256 totalStakingBonus,
            bool bonusesActive
        ) 
    {
        return this.getAugmentationInfo(collectionId, tokenId);
    }

    /**
     * @dev DEPRECATED: View functions remain available for backward compatibility
     */
    function calculateUserMultiplier(address staker, uint256 stakingDuration) 
        external 
        view 
        returns (uint256 balanceMultiplier, uint256 timeBonus, uint256 totalMultiplier) 
    {
        return this.getUserMultiplier(staker, stakingDuration);
    }
}