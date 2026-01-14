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
import {RewardCalculator} from "../libraries/RewardCalculator.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibStakingAchievementTrigger} from "../libraries/LibStakingAchievementTrigger.sol";

/**
 * @title IRewardToken
 * @notice Generic interface for reward token with treasury → mint fallback
 */
interface IRewardToken is IERC20 {
    function mint(address to, uint256 amount, string calldata reason) external;
    function dailyMintLimit() external view returns (uint256);
    function dailyMinted(address account) external view returns (uint256);
    function lastMintDay(address account) external view returns (uint256);
}

interface IStakingIntegrationFacet {
    function applyExperienceFromRewards(uint256 collectionId, uint256 tokenId, uint256 amount) external;
}

interface IStakingBiopodFacet {
    function getWearLevel(uint256 collectionId, uint256 tokenId) external view returns (uint256);
}

/**
 * @title StakingEarningsFacet
 * @notice Optimized batch claiming with reward token distribution
 * @dev Treasury-first approach with mint fallback for sustainability
 */
contract StakingEarningsFacet is AccessControlBase {
    using Math for uint256;
    
    uint256 private constant MAX_BATCH = 30;
    uint256 private constant MIN_GAS_RESERVE = 50000;

    uint256 private constant DAILY_AUX_TOKEN_LIMIT = 20000 ether; // 20,000 YLW per day (swap + claim)

    // NOTE: Base reward rates are now configurable via ss.settings.baseRewardRates[]
    // Retrieved using LibStakingStorage.getBaseDailyRewardRate(variant) or RewardCalculator.calculateBaseTimeReward()

    struct ClaimBatch {
        uint256 rewardTotal;
        uint256 processed;
        uint256 gasUsed;
    }

    /**
     * @notice Preloaded context for batch reward calculations
     */
    struct RewardContext {
        // Season (preloaded once)
        uint256 seasonMultiplier;
        bool seasonActive;

        // Balance params (preloaded once)
        bool balanceEnabled;
        uint256 decayRate;
        uint256 minMultiplier;
        bool timeEnabled;
        uint256 maxTimeBonus;
        uint256 timePeriod;
        uint256 totalStakedCount;

        // Config limits (preloaded once)
        uint256 maxAccessoryBonus;
        uint256 maxColonyBonus;
        uint256 maxCombinedContextBonus;
        bool useAdditiveContextBonuses;

        // Cached bonus arrays
        uint8[6] infusionBonuses;
        uint8[6] specializationBonuses;
    }

    event RewardClaimed(
        uint256 indexed collectionId, 
        uint256 indexed tokenId, 
        address indexed staker, 
        uint256 amount,
        bool fromTreasury
    );
    
    event BatchProcessed(
        address indexed staker, 
        uint256 rewardTotal, 
        uint256 tokensProcessed, 
        uint256 gasUsed,
        uint256 fromTreasury,
        uint256 fromMint
    );
    
    event BatchLimitReached(
        address indexed staker,
        uint256 claimedAmount,
        uint256 remainingTokens
    );

    error InvalidBatchSize();
    error NothingToClaim();
    error RewardTokenNotConfigured();
    error DailyMintLimitExceeded(uint256 requested, uint256 available);
    error TreasuryInsufficientAllowance();
    error DailyLimitExceeded(uint256 requested, uint256 available);
    error NoTokensStaked();

    /**
     * @notice Reset user's claim index to 0 (admin emergency function)
     * @dev Use this if rotation gets stuck or needs manual reset
     * @param user Address to reset
     */
    function resetUserClaimIndex(address user) 
        external 
        onlyAuthorized 
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        ss.userLastClaimIndex[user] = 0;
    }

    function updateRewardToken(address newRewardToken) 
        external 
        onlyAuthorized
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        ss.rewardToken = newRewardToken;
    }

    function getRewardToken()
        external
        view
        returns (address)
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        return ss.rewardToken;
    }

    /**
     * @notice Process pending rewards during unstaking (internal diamond call only)
     * @dev Called by StakingCoreFacet during unstake to distribute pending rewards
     * @param collectionId Collection identifier
     * @param tokenId Token identifier
     * @return amount Amount of reward tokens distributed
     */
    function processUnstakeRewards(uint256 collectionId, uint256 tokenId)
        external
        whenNotPaused
        returns (uint256 amount)
    {
        // Only allow internal diamond calls
        if (!AccessHelper.isInternalCall()) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Internal call only");
        }

        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        // If reward token not configured, silently return 0 (don't block unstake)
        if (ss.rewardToken == address(0)) {
            return 0;
        }

        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];

        if (!staked.staked) {
            return 0;
        }

        address tokenOwner = staked.owner;
        amount = _calculateReward(collectionId, tokenId, staked, ss);

        if (amount == 0) {
            return 0;
        }

        // Check daily limit but don't revert - cap to available limit
        uint256 availableLimit = LibStakingStorage.getAvailableYlwLimit(ss, tokenOwner);
        if (amount > availableLimit) {
            amount = availableLimit;
        }

        if (amount == 0) {
            return 0;
        }

        // Update claim timestamp
        staked.lastClaimTimestamp = uint32(block.timestamp);
        staked.totalRewardsClaimed += amount;

        // Distribute reward to token owner
        bool fromTreasury = _distributeReward(ss, tokenOwner, amount);
        _tryExpGain(collectionId, tokenId, amount);

        // Consume from shared daily limit
        LibStakingStorage.checkAndConsumeYlwLimit(ss, tokenOwner, amount);

        emit RewardClaimed(collectionId, tokenId, tokenOwner, amount, fromTreasury);

        return amount;
    }

    /**
     * @notice Claim rewards for single token
     * @param collectionId Collection identifier
     * @param tokenId Token identifier
     * @return amount Amount of reward tokens claimed
     * @return fromTreasury Whether reward came from treasury (true) or mint (false)
     */
    function claimStakingRewards(uint256 collectionId, uint256 tokenId) 
        external 
        whenNotPaused 
        nonReentrant 
        returns (uint256 amount, bool fromTreasury) 
    {
        address sender = LibMeta.msgSender();
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        if (ss.rewardToken == address(0)) revert RewardTokenNotConfigured();
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];

        if (!staked.staked || staked.owner != sender) revert NothingToClaim();

        // Block direct claim if receipt was transferred to another owner
        // Original staker can still claim normally if they hold the receipt
        if (LibStakingStorage.isReceiptTransferred(combinedId, sender)) {
            revert LibStakingStorage.TokenHasReceipt(combinedId, LibStakingStorage.getReceiptId(combinedId));
        }

        amount = _calculateReward(collectionId, tokenId, staked, ss);
        if (amount == 0) revert NothingToClaim();
        
        // Check shared daily limit
        uint256 availableLimit = LibStakingStorage.getAvailableYlwLimit(ss, sender);
        if (amount > availableLimit) {
            revert DailyLimitExceeded(amount, availableLimit);
        }
        
        staked.lastClaimTimestamp = uint32(block.timestamp);
        staked.totalRewardsClaimed += amount;
        
        fromTreasury = _distributeReward(ss, sender, amount);
        _tryExpGain(collectionId, tokenId, amount);
        
        // Consume from shared daily limit
        (bool limitOk, ) = LibStakingStorage.checkAndConsumeYlwLimit(ss, sender, amount);
        if (!limitOk) revert DailyLimitExceeded(amount, availableLimit);
        
        emit RewardClaimed(collectionId, tokenId, sender, amount, fromTreasury);

        // Trigger reward claim achievement
        LibStakingAchievementTrigger.triggerRewardClaim(sender);

        return (amount, fromTreasury);
    }

    /**
     * @notice Claim rewards for multiple tokens in batch - FIXED with shared limit enforcement
     * @dev Implements round-robin processing and checks shared daily YLW limit (swap + claim)
     * @dev CRITICAL FIX: Now properly checks daily limit BEFORE processing claims
     * @dev FIX v2: No longer reverts when no rewards available - returns zeros instead
     * @param maxTokens Maximum number of tokens to process (1-30)
     * @return rewardTotal Total rewards claimed (0 if no rewards available yet)
     * @return processed Number of tokens actually processed
     * @return treasuryAmount Amount distributed from treasury
     * @return mintAmount Amount minted
     */
    function claimBatchStakingRewards(uint256 maxTokens)
        external
        whenNotPaused
        nonReentrant
        returns (
            uint256 rewardTotal,
            uint256 processed,
            uint256 treasuryAmount,
            uint256 mintAmount
        )
    {
        if (maxTokens == 0 || maxTokens > MAX_BATCH) revert InvalidBatchSize();

        uint256 gasStart = gasleft();
        address sender = LibMeta.msgSender();
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        if (ss.rewardToken == address(0)) revert RewardTokenNotConfigured();

        uint256[] storage tokens = ss.stakerTokens[sender];
        // FIX: Use specific error for no staked tokens vs no rewards ready
        if (tokens.length == 0) revert NoTokensStaked();

        // FIX: Check shared daily limit FIRST before calculating other limits
        // This is the primary constraint that affects both swap and claim
        uint256 availableDailyLimit = LibStakingStorage.getAvailableYlwLimit(ss, sender);

        // If daily limit exhausted, return zeros instead of reverting
        if (availableDailyLimit == 0) {
            return (0, 0, 0, 0);
        }

        // Daily limit from LibStakingStorage is the only constraint
        // YellowToken mint limit is bypassed for this contract (limitExemptMinters)
        uint256 totalAvailable = availableDailyLimit;

        ClaimBatch memory batch;
        bool limitReached = false;

        // Preload context once for entire batch
        RewardContext memory ctx = _loadRewardContext(ss);

        // Start from last processed index for this user (round-robin)
        uint256 startIndex = ss.userLastClaimIndex[sender];
        uint256 checkedCount = 0;
        uint256 maxToCheck = tokens.length;
        uint256 tokensWithRewardsFound = 0; // Track if we found any tokens with potential rewards

        // Loop with rotation - continues from where we left off last time
        while (checkedCount < maxToCheck && batch.processed < maxTokens && gasleft() > MIN_GAS_RESERVE) {
            // Calculate current index with wrap-around
            uint256 currentIndex = (startIndex + checkedCount) % tokens.length;
            uint256 combinedId = tokens[currentIndex];
            checkedCount++;

            StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];

            if (!staked.staked || staked.owner != sender) continue;

            // Skip tokens where receipt was transferred to another owner
            // Original staker can still claim normally if they hold the receipt
            if (LibStakingStorage.isReceiptTransferred(combinedId, sender)) continue;

            (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);

            uint256 reward = _calculateRewardWithContext(collectionId, tokenId, staked, ss, ctx);
            if (reward == 0) continue;

            tokensWithRewardsFound++;

            // Check if adding this reward would exceed available limit
            if (batch.rewardTotal + reward > totalAvailable) {
                limitReached = true;
                emit BatchLimitReached(sender, batch.rewardTotal, maxToCheck - checkedCount);
                break;
            }

            unchecked {
                batch.rewardTotal += reward;
                batch.processed++;
            }

            staked.lastClaimTimestamp = uint32(block.timestamp);
            staked.totalRewardsClaimed += reward;
            _tryExpGain(collectionId, tokenId, reward);

            emit RewardClaimed(collectionId, tokenId, sender, reward, false);
        }

        // FIX: If no rewards found, return zeros instead of reverting
        // This happens when all tokens were recently claimed (elapsed == 0)
        if (batch.rewardTotal == 0) {
            // Still update the index so next call starts from a different position
            // This prevents getting stuck checking the same tokens repeatedly
            if (checkedCount > 0) {
                ss.userLastClaimIndex[sender] = (startIndex + checkedCount) % tokens.length;
            }
            return (0, 0, 0, 0);
        }

        // CRITICAL FIX: Consume from shared daily limit BEFORE distribution
        // This ensures swap and claim share the same limit tracking
        (bool limitOk, ) = LibStakingStorage.checkAndConsumeYlwLimit(ss, sender, batch.rewardTotal);
        if (!limitOk) revert DailyLimitExceeded(batch.rewardTotal, availableDailyLimit);

        // Save position for next claim (round-robin state)
        ss.userLastClaimIndex[sender] = (startIndex + checkedCount) % tokens.length;

        batch.gasUsed = gasStart - gasleft();

        // Distribute rewards (treasury first, then mint if needed)
        (treasuryAmount, mintAmount) = _distributeBatchReward(ss, sender, batch.rewardTotal);

        emit BatchProcessed(
            sender,
            batch.rewardTotal,
            batch.processed,
            batch.gasUsed,
            treasuryAmount,
            mintAmount
        );

        // Trigger reward claim achievement for batch
        LibStakingAchievementTrigger.triggerRewardClaim(sender);

        return (batch.rewardTotal, batch.processed, treasuryAmount, mintAmount);
    }

    /**
     * @notice Claim rewards for specific token IDs (FIXED - shared limit enforcement)
     * @dev Now correctly enforces shared daily limit across all claim operations
     * @param tokenIds Array of token IDs to claim
     * @return rewardTotal Total rewards claimed
     * @return processed Number of tokens processed
     */
    function claimTokenRewards(uint256[] calldata tokenIds) 
        external 
        whenNotPaused 
        nonReentrant 
        returns (uint256 rewardTotal, uint256 processed) 
    {
        if (tokenIds.length == 0 || tokenIds.length > MAX_BATCH) revert InvalidBatchSize();
        
        address sender = LibMeta.msgSender();
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        if (ss.rewardToken == address(0)) revert RewardTokenNotConfigured();
        
        // FIX: Check shared daily limit FIRST before calculating other limits
        uint256 availableDailyLimit = LibStakingStorage.getAvailableYlwLimit(ss, sender);
        
        // Daily limit from LibStakingStorage is the only constraint
        // YellowToken mint limit is bypassed for this contract (limitExemptMinters)
        uint256 totalAvailable = availableDailyLimit;

        uint256 treasuryAmount = 0;
        uint256 mintAmount = 0;
        uint256 skipped = 0;

        // Preload context once for entire batch
        RewardContext memory ctx = _loadRewardContext(ss);

        for (uint256 i = 0; i < tokenIds.length; i++) {
            // Try to find token in any collection
            bool found = false;

            for (uint256 colId = 0; colId < 10 && !found; colId++) {
                uint256 combinedId = PodsUtils.combineIds(colId, tokenIds[i]);
                StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];

                if (!staked.staked || staked.owner != sender) continue;

                // Skip tokens where receipt was transferred to another owner
                // Original staker can still claim normally if they hold the receipt
                if (LibStakingStorage.isReceiptTransferred(combinedId, sender)) continue;

                found = true;
                uint256 reward = _calculateRewardWithContext(colId, tokenIds[i], staked, ss, ctx);
                
                if (reward > 0) {
                    // Check if adding this reward would exceed available limit
                    if (rewardTotal + reward > totalAvailable) {
                        skipped = tokenIds.length - i;
                        emit BatchLimitReached(sender, rewardTotal, skipped);
                        break;
                    }
                    
                    unchecked {
                        rewardTotal += reward;
                        processed++;
                    }
                    
                    staked.lastClaimTimestamp = uint32(block.timestamp);
                    staked.totalRewardsClaimed += reward;
                    
                    _tryExpGain(colId, tokenIds[i], reward);
                    
                    emit RewardClaimed(colId, tokenIds[i], sender, reward, false);
                }
            }
            
            // If we hit the limit, break outer loop too
            if (skipped > 0) break;
        }
        
        if (rewardTotal == 0) revert NothingToClaim();
        
        // CRITICAL FIX: Consume from shared daily limit BEFORE distribution
        (bool limitOk, ) = LibStakingStorage.checkAndConsumeYlwLimit(ss, sender, rewardTotal);
        if (!limitOk) revert DailyLimitExceeded(rewardTotal, availableDailyLimit);
        
        // Distribute all at once
        (treasuryAmount, mintAmount) = _distributeBatchReward(ss, sender, rewardTotal);

        emit BatchProcessed(sender, rewardTotal, processed, 0, treasuryAmount, mintAmount);

        // Trigger reward claim achievement
        LibStakingAchievementTrigger.triggerRewardClaim(sender);

        return (rewardTotal, processed);
    }

    /**
     * @notice Get detailed claim status for debugging
     * @param user Address to check
     * @param checkCount Number of tokens to check ahead
     * @return nextTokensWithRewards Array of next token indices that have pending rewards
     * @return rewardsAvailable Array of reward amounts for those tokens
     */
    function previewNextClaims(address user, uint256 checkCount)
        external
        view
        returns (
            uint256[] memory nextTokensWithRewards,
            uint256[] memory rewardsAvailable
        )
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256[] storage tokens = ss.stakerTokens[user];

        if (tokens.length == 0 || checkCount == 0) {
            return (new uint256[](0), new uint256[](0));
        }

        // Preload context once
        RewardContext memory ctx = _loadRewardContext(ss);

        // Temporary arrays (may be oversized)
        uint256[] memory tempIndices = new uint256[](checkCount);
        uint256[] memory tempRewards = new uint256[](checkCount);
        uint256 foundCount = 0;

        uint256 startIndex = ss.userLastClaimIndex[user];
        uint256 checked = 0;

        while (checked < tokens.length && foundCount < checkCount) {
            uint256 currentIndex = (startIndex + checked) % tokens.length;
            uint256 combinedId = tokens[currentIndex];
            checked++;

            StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];

            if (!staked.staked || staked.owner != user) continue;

            (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);
            uint256 reward = _calculateRewardWithContext(collectionId, tokenId, staked, ss, ctx);

            if (reward > 0) {
                tempIndices[foundCount] = currentIndex;
                tempRewards[foundCount] = reward;
                foundCount++;
            }
        }

        // Create properly sized return arrays
        nextTokensWithRewards = new uint256[](foundCount);
        rewardsAvailable = new uint256[](foundCount);

        for (uint256 i = 0; i < foundCount; i++) {
            nextTokensWithRewards[i] = tempIndices[i];
            rewardsAvailable[i] = tempRewards[i];
        }

        return (nextTokensWithRewards, rewardsAvailable);
    }

    /**
     * @notice Get pending reward for a specific token
     * @param collectionId Collection identifier
     * @param tokenId Token identifier
     * @return amount Pending reward amount
     */
    function getPendingReward(uint256 collectionId, uint256 tokenId)
        external
        view
        returns (uint256 amount)
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];

        if (!staked.staked) {
            return 0;
        }

        return _calculateReward(collectionId, tokenId, staked, ss);
    }

    /**
     * @notice Get pending rewards for staker
     * @param staker Address to check
     * @param maxCheck Maximum tokens to check
     * @return rewardTotal Total rewards pending
     * @return count Number of tokens with pending rewards
     */
    function getPendingEarnings(address staker, uint256 maxCheck)
        external
        view
        returns (uint256 rewardTotal, uint256 count)
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256[] storage tokens = ss.stakerTokens[staker];

        uint256 limit = tokens.length > maxCheck ? maxCheck : tokens.length;

        // Preload context once
        RewardContext memory ctx = _loadRewardContext(ss);

        for (uint256 i = 0; i < limit; i++) {
            uint256 combinedId = tokens[i];
            StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];

            if (!staked.staked || staked.owner != staker) continue;

            (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);

            uint256 reward = _calculateRewardWithContext(collectionId, tokenId, staked, ss, ctx);
            if (reward > 0) {
                unchecked {
                    rewardTotal += reward;
                    count++;
                }
            }
        }

        return (rewardTotal, count);
    }

    /**
     * @notice Get total historical earnings for a user (lifetime rewards claimed)
     * @param user Address to check
     * @return totalEarnings Total rewards claimed by user across all tokens
     */
    function getTotalEarnings(address user) 
        external 
        view 
        returns (uint256 totalEarnings) 
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256[] storage tokens = ss.stakerTokens[user];
        
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 combinedId = tokens[i];
            StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
            
            if (staked.owner != user) continue;
            
            unchecked {
                totalEarnings += staked.totalRewardsClaimed;
            }
        }
        
        return totalEarnings;
    }

    /**
     * @notice Get complete staking overview for user (dashboard in one call)
     * @param user Address to check
     * @return stakedCount Number of tokens currently staked
     * @return pendingRewards Total pending rewards ready to claim
     * @return lifetimeEarnings Total rewards claimed historically
     * @return estimatedDailyRate Estimated daily earnings at current rates
     */
    function getUserStakingOverview(address user)
        external
        view
        returns (
            uint256 stakedCount,
            uint256 pendingRewards,
            uint256 lifetimeEarnings,
            uint256 estimatedDailyRate
        )
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256[] storage tokens = ss.stakerTokens[user];

        // Preload context once
        RewardContext memory ctx = _loadRewardContext(ss);

        for (uint256 i = 0; i < tokens.length; i++) {
            (
                uint256 pending,
                uint256 daily,
                uint256 lifetime,
                bool isStaked
            ) = _getTokenOverviewData(tokens[i], user, ss, ctx);

            unchecked {
                lifetimeEarnings += lifetime;
                if (isStaked) {
                    stakedCount++;
                    pendingRewards += pending;
                    estimatedDailyRate += daily;
                }
            }
        }

        return (stakedCount, pendingRewards, lifetimeEarnings, estimatedDailyRate);
    }

    /**
     * @notice Helper to get token overview data (avoids stack too deep)
     */
    function _getTokenOverviewData(
        uint256 combinedId,
        address user,
        LibStakingStorage.StakingStorage storage ss,
        RewardContext memory ctx
    ) private view returns (uint256 pending, uint256 daily, uint256 lifetime, bool isStaked) {
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];

        if (staked.owner != user) return (0, 0, 0, false);

        lifetime = staked.totalRewardsClaimed;
        isStaked = staked.staked;

        if (isStaked) {
            (uint256 colId, uint256 tokId) = PodsUtils.extractIds(combinedId);
            pending = _calculateRewardWithContext(colId, tokId, staked, ss, ctx);
            daily = _calculateDailyRateWithContext(colId, tokId, staked, ss, ctx);
        }

        return (pending, daily, lifetime, isStaked);
    }

    /**
     * @notice Get current earning rate for a specific token (per day)
     * @param tokenId Token identifier
     * @return dailyRate Daily earning rate in wei
     */
    function getTokenEarningRate(uint256 tokenId) 
        external 
        view 
        returns (uint256 dailyRate) 
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Find the token in staked specimens
        // Since we don't have collectionId, we need to search through user's tokens
        // This is a view function, so gas cost is not a concern
        
        // Try to find in any collection
        // uint256[] memory collectionIds = new uint256[](10); // Assume max 10 collections
        uint256 collectionsCount = 0;
        
        // Get all collection IDs (in real implementation, you'd have a registry)
        // For now, we'll check collections 0-9
        for (uint256 colId = 0; colId < 10 && collectionsCount < 10; colId++) {
            uint256 combinedId = PodsUtils.combineIds(colId, tokenId);
            StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
            
            if (staked.staked) {
                // Found the staked token
                return _calculateDailyRate(colId, tokenId, staked, ss);
            }
        }
        
        return 0; // Token not staked
    }

    /**
     * @notice Get daily claim limit information (FIXED - returns shared limit)
     * @dev This function now returns the UNIFIED daily limit that includes both swap and claim operations
     * @dev Previously returned only mint limit, causing confusion with actual available limit
     * @return dailyLimit Total daily limit for YLW (swap + claim combined)
     * @return alreadyUsed Amount already used today (swap + claim)
     * @return available Amount still available to use today
     * @return resetsIn Seconds until the limit resets (midnight UTC)
     */
    function getDailyClaimLimitInfo(address staker) 
        external 
        view 
        returns (
            uint256 dailyLimit,
            uint256 alreadyUsed,
            uint256 available,
            uint256 resetsIn
        ) 
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        address sender = staker;
        
        // FIX: Return shared limit (swap + claim) instead of mint limit
        // This ensures consistency with actual available limit
        dailyLimit = DAILY_AUX_TOKEN_LIMIT; // 20,000 ether constant
        
        // Get current day (UTC midnight-based)
        uint256 currentDay = block.timestamp / 1 days;
        
        // Get amount already used today (from both swap and claim operations)
        alreadyUsed = ss.userDailyRewardTokenUsed[sender][currentDay];
        
        // Calculate available amount
        available = alreadyUsed >= dailyLimit ? 0 : dailyLimit - alreadyUsed;
        
        // Calculate seconds until next day (midnight UTC)
        uint256 secondsIntoDay = block.timestamp % 1 days;
        resetsIn = 1 days - secondsIntoDay;
        
        return (dailyLimit, alreadyUsed, available, resetsIn);
    }

    /**
     * @notice Get claimable amount respecting daily limit (FIXED)
     * @dev Now correctly uses shared daily limit instead of only mint limit
     * @param user Address to check
     * @param maxTokens Maximum tokens to check
     * @return claimableNow Amount that can be claimed right now (respecting daily limit)
     * @return totalPending Total pending rewards (may exceed daily limit)
     * @return tokensToClaim Number of tokens needed to reach claimableNow
     * @return tokensWithRewards Total tokens with pending rewards
     */
    function getClaimableWithLimit(address user, uint256 maxTokens) 
        external 
        view 
        returns (
            uint256 claimableNow,
            uint256 totalPending,
            uint256 tokensToClaim,
            uint256 tokensWithRewards
        ) 
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        if (ss.rewardToken == address(0)) {
            return (0, 0, 0, 0);
        }
        
        // FIX: Use shared daily limit instead of only mint limit
        // This ensures frontend shows correct claimable amount considering swap usage
        uint256 availableDailyLimit = LibStakingStorage.getAvailableYlwLimit(ss, user);
        uint256[] storage tokens = ss.stakerTokens[user];
        
        uint256 limit = tokens.length > maxTokens ? maxTokens : tokens.length;
        
        for (uint256 i = 0; i < limit; i++) {
            uint256 combinedId = tokens[i];
            StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];

            if (!staked.staked || staked.owner != user) continue;

            // Skip tokens where receipt was transferred to another owner
            // Original staker can still claim normally if they hold the receipt
            if (LibStakingStorage.isReceiptTransferred(combinedId, user)) continue;

            (uint256 colId, uint256 tokId) = PodsUtils.extractIds(combinedId);

            uint256 reward = _calculateReward(colId, tokId, staked, ss);
            if (reward > 0) {
                unchecked {
                    totalPending += reward;
                    tokensWithRewards++;
                }
                
                // Track how much we can claim within daily limit
                if (claimableNow + reward <= availableDailyLimit) {
                    unchecked {
                        claimableNow += reward;
                        tokensToClaim++;
                    }
                }
            }
        }
        
        return (claimableNow, totalPending, tokensToClaim, tokensWithRewards);
    }

    /**
     * @notice Get user's last claim index (for debugging and UI display)
     * @param user Address to check
     * @return index Last processed token index for this user
     */
    function getUserLastClaimIndex(address user)
        external
        view
        returns (uint256 index)
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        return ss.userLastClaimIndex[user];
    }

    /**
     * @notice Check if user can claim rewards right now
     * @dev Useful for frontend to decide whether to show claim button or estimated wait time
     * @param user Address to check
     * @param maxTokensToCheck Maximum tokens to scan (use 30 for batch size preview)
     * @return canClaim True if at least one token has claimable rewards
     * @return estimatedReward Estimated reward amount from next batch
     * @return tokensReady Number of tokens with rewards ready
     * @return dailyLimitRemaining Remaining daily limit
     */
    function canClaimNow(address user, uint256 maxTokensToCheck)
        external
        view
        returns (
            bool canClaim,
            uint256 estimatedReward,
            uint256 tokensReady,
            uint256 dailyLimitRemaining
        )
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        if (ss.rewardToken == address(0)) {
            return (false, 0, 0, 0);
        }

        uint256[] storage tokens = ss.stakerTokens[user];
        if (tokens.length == 0) {
            return (false, 0, 0, 0);
        }

        dailyLimitRemaining = LibStakingStorage.getAvailableYlwLimit(ss, user);
        if (dailyLimitRemaining == 0) {
            return (false, 0, 0, 0);
        }

        // Preload context once
        RewardContext memory ctx = _loadRewardContext(ss);

        uint256 startIndex = ss.userLastClaimIndex[user];
        uint256 checked = 0;
        uint256 limit = maxTokensToCheck > tokens.length ? tokens.length : maxTokensToCheck;

        while (checked < tokens.length && tokensReady < limit) {
            uint256 currentIndex = (startIndex + checked) % tokens.length;
            uint256 combinedId = tokens[currentIndex];
            checked++;

            StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];

            if (!staked.staked || staked.owner != user) continue;

            // Skip tokens where receipt was transferred to another owner
            if (LibStakingStorage.isReceiptTransferred(combinedId, user)) continue;

            (uint256 colId, uint256 tokId) = PodsUtils.extractIds(combinedId);
            uint256 reward = _calculateRewardWithContext(colId, tokId, staked, ss, ctx);

            if (reward > 0) {
                estimatedReward += reward;
                tokensReady++;

                // Stop if we'd exceed daily limit
                if (estimatedReward >= dailyLimitRemaining) {
                    estimatedReward = dailyLimitRemaining;
                    break;
                }
            }
        }

        canClaim = tokensReady > 0 && estimatedReward > 0;
        return (canClaim, estimatedReward, tokensReady, dailyLimitRemaining);
    }

    /**
     * @notice Get progress of claim rotation for user
     * @param user Address to check
     * @return currentIndex Current position in token array
     * @return totalTokens Total number of staked tokens
     * @return percentComplete Percentage of tokens processed in current rotation (0-100)
     */
    function getClaimProgress(address user) 
        external 
        view 
        returns (
            uint256 currentIndex,
            uint256 totalTokens,
            uint256 percentComplete
        ) 
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        currentIndex = ss.userLastClaimIndex[user];
        totalTokens = ss.stakerTokens[user].length;
        
        if (totalTokens == 0) {
            percentComplete = 0;
        } else {
            percentComplete = (currentIndex * 100) / totalTokens;
        }
        
        return (currentIndex, totalTokens, percentComplete);
    }

    /**
     * @notice Load reward context for batch calculations
     */
    function _loadRewardContext(LibStakingStorage.StakingStorage storage ss)
        private view returns (RewardContext memory ctx)
    {
        // Season
        ctx.seasonActive = ss.currentSeason.active;
        ctx.seasonMultiplier = ctx.seasonActive ? ss.currentSeason.multiplier : 100;
        if (ctx.seasonMultiplier > 200) ctx.seasonMultiplier = 200;

        // Balance params
        ctx.balanceEnabled = ss.settings.balanceAdjustment.enabled;
        ctx.decayRate = ss.settings.balanceAdjustment.decayRate;
        ctx.minMultiplier = ss.settings.balanceAdjustment.minMultiplier;
        ctx.timeEnabled = ss.settings.timeDecay.enabled;
        ctx.maxTimeBonus = ss.settings.timeDecay.maxBonus;
        ctx.timePeriod = ss.settings.timeDecay.period;
        ctx.totalStakedCount = ss.totalStakedSpecimens;

        // Config limits
        LibStakingStorage.RewardCalculationConfig storage config = ss.rewardCalculationConfig;
        ctx.maxAccessoryBonus = config.maxAccessoryBonus > 0 ? config.maxAccessoryBonus : 40;
        ctx.maxColonyBonus = config.maxColonyBonus > 0 ? config.maxColonyBonus : 30;
        ctx.maxCombinedContextBonus = config.maxCombinedContextBonus > 0 ? config.maxCombinedContextBonus : 75;
        ctx.useAdditiveContextBonuses = config.useAdditiveContextBonuses || ss.configVersion >= 2;

        // Cached bonus arrays
        ctx.infusionBonuses = config.infusionBonuses;
        ctx.specializationBonuses = config.specializationBonuses;

        return ctx;
    }

    /**
     * @notice Calculate reward for a staked token (uses configurable rates from storage)
     */
    function _calculateReward(
        uint256 collectionId,
        uint256 tokenId,
        StakedSpecimen storage staked,
        LibStakingStorage.StakingStorage storage ss
    ) private view returns (uint256) {
        RewardContext memory ctx = _loadRewardContext(ss);
        return _calculateRewardWithContext(collectionId, tokenId, staked, ss, ctx);
    }

    /**
     * @notice Calculate reward with preloaded context (for batch operations)
     */
    function _calculateRewardWithContext(
        uint256 collectionId,
        uint256 tokenId,
        StakedSpecimen storage staked,
        LibStakingStorage.StakingStorage storage ss,
        RewardContext memory ctx
    ) private view returns (uint256) {
        uint256 elapsed = block.timestamp - staked.lastClaimTimestamp;
        if (elapsed == 0) return 0;

        if (elapsed > LibStakingStorage.MAX_REWARD_PERIOD) {
            elapsed = LibStakingStorage.MAX_REWARD_PERIOD;
        }

        // Base reward from configurable rates
        uint256 baseReward = RewardCalculator.calculateBaseTimeReward(staked.variant, elapsed);
        if (baseReward == 0) return 0;

        // === TOKEN MULTIPLIER ===
        uint256 tokenMultiplier = 100;

        // Level bonus (0.4% per level, max 40%)
        tokenMultiplier += (uint256(staked.level) * 40) / 100;

        // Variant bonus (4% per variant above 1, max 12%)
        if (staked.variant > 1) {
            tokenMultiplier += (staked.variant - 1) * 4;
        }

        // Charge bonus
        if (staked.chargeLevel >= 80) tokenMultiplier += 10;
        else if (staked.chargeLevel >= 60) tokenMultiplier += 6;
        else if (staked.chargeLevel >= 40) tokenMultiplier += 3;

        // Infusion bonus (8-28%)
        if (staked.infusionLevel > 0 && staked.infusionLevel <= 5) {
            uint8 infusionBonus = ctx.infusionBonuses[staked.infusionLevel];
            if (infusionBonus == 0) {
                if (staked.infusionLevel == 1) infusionBonus = 8;
                else if (staked.infusionLevel == 2) infusionBonus = 12;
                else if (staked.infusionLevel == 3) infusionBonus = 16;
                else if (staked.infusionLevel == 4) infusionBonus = 20;
                else if (staked.infusionLevel == 5) infusionBonus = 28;
            }
            tokenMultiplier += infusionBonus;
        }

        // Specialization bonus (4-6%)
        if (staked.specialization > 0 && staked.specialization <= 5) {
            uint8 specBonus = ctx.specializationBonuses[staked.specialization];
            if (specBonus == 0) {
                if (staked.specialization == 1) specBonus = 4;
                else if (staked.specialization == 2) specBonus = 6;
            }
            tokenMultiplier += specBonus;
        }

        // === CONTEXT BONUSES ===
        uint256 contextBonus = 0;

        // Colony bonus
        if (staked.colonyId != bytes32(0)) {
            uint256 colonyBonus = ss.colonyStakingBonuses[staked.colonyId];
            if (colonyBonus == 0) colonyBonus = ss.colonies[staked.colonyId].stakingBonus;
            if (colonyBonus == 0) colonyBonus = 5;
            if (colonyBonus > ctx.maxColonyBonus) colonyBonus = ctx.maxColonyBonus;
            contextBonus += colonyBonus;
        }

        // Loyalty bonus
        uint256 stakingDuration = block.timestamp - staked.stakedSince;
        contextBonus += LibStakingStorage.calculateLoyaltyBonus(stakingDuration);

        // Accessory bonus (cached)
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        (uint256 accessoryBonus, bool cacheValid) = LibStakingStorage.getCachedAccessoryBonus(combinedId);
        if (!cacheValid) {
            ChargeAccessory[] memory accessories = LibStakingStorage.getTokenAccessories(ss, collectionId, tokenId);
            accessoryBonus = RewardCalculator.calculateAccessoryBonus(accessories, staked.specialization);
        }
        if (accessoryBonus > ctx.maxAccessoryBonus) accessoryBonus = ctx.maxAccessoryBonus;
        contextBonus += accessoryBonus;

        // Cap context bonus
        if (contextBonus > ctx.maxCombinedContextBonus) {
            contextBonus = ctx.maxCombinedContextBonus;
        }

        // === CALCULATE REWARD ===
        uint256 reward;
        if (ctx.useAdditiveContextBonuses) {
            uint256 safeSeasonMult = ctx.seasonMultiplier > 150 ? 150 : ctx.seasonMultiplier;
            reward = Math.mulDiv(
                Math.mulDiv(baseReward, tokenMultiplier, 100),
                (100 + contextBonus) * safeSeasonMult,
                10000
            );
        } else {
            reward = Math.mulDiv(baseReward, tokenMultiplier, 100);
            reward = Math.mulDiv(reward, ctx.seasonMultiplier, 100);
            reward = Math.mulDiv(reward, 100 + contextBonus, 100);
        }

        // Stake balance adjustment
        if (ctx.balanceEnabled && reward > 0) {
            uint256 balanceMultiplier = RewardCalculator.calculateStakeBalanceMultiplier(
                ss.stakerTokenCount[staked.owner],
                ctx.totalStakedCount,
                stakingDuration,
                ctx.balanceEnabled,
                ctx.decayRate,
                ctx.minMultiplier,
                ctx.timeEnabled,
                ctx.maxTimeBonus,
                ctx.timePeriod
            );
            reward = Math.mulDiv(reward, balanceMultiplier, 100);
        }

        // Wear penalty
        uint8 wear = _quickWear(collectionId, tokenId, staked, ss);
        if (wear > 0) {
            uint256 penalty = LibStakingStorage.calculateWearPenalty(wear);
            if (penalty > 0 && penalty < 100) {
                reward = (reward * (100 - penalty)) / 100;
            }
        }

        return reward;
    }

    /**
     * @notice Calculate daily earning rate for a token (without time factor)
     * @dev Used by getTokenEarningRate to show potential daily earnings
     */
    function _calculateDailyRate(
        uint256 collectionId,
        uint256 tokenId,
        StakedSpecimen storage staked,
        LibStakingStorage.StakingStorage storage ss
    ) private view returns (uint256) {
        RewardContext memory ctx = _loadRewardContext(ss);
        return _calculateDailyRateWithContext(collectionId, tokenId, staked, ss, ctx);
    }

    /**
     * @notice Calculate daily rate with preloaded context
     */
    function _calculateDailyRateWithContext(
        uint256 collectionId,
        uint256 tokenId,
        StakedSpecimen storage staked,
        LibStakingStorage.StakingStorage storage ss,
        RewardContext memory ctx
    ) private view returns (uint256) {
        // Base daily rate from configurable storage
        uint256 dailyRate = LibStakingStorage.getBaseDailyRewardRate(staked.variant);

        // === TOKEN MULTIPLIER ===
        uint256 tokenMultiplier = 100;

        // Level bonus (0.4% per level)
        tokenMultiplier += (uint256(staked.level) * 40) / 100;

        // Variant bonus (4% per variant above 1)
        if (staked.variant > 1) {
            tokenMultiplier += (staked.variant - 1) * 4;
        }

        // Charge bonus
        if (staked.chargeLevel >= 80) tokenMultiplier += 10;
        else if (staked.chargeLevel >= 60) tokenMultiplier += 6;
        else if (staked.chargeLevel >= 40) tokenMultiplier += 3;

        // Infusion bonus
        if (staked.infusionLevel > 0 && staked.infusionLevel <= 5) {
            uint8 infusionBonus = ctx.infusionBonuses[staked.infusionLevel];
            if (infusionBonus == 0) {
                if (staked.infusionLevel == 1) infusionBonus = 8;
                else if (staked.infusionLevel == 2) infusionBonus = 12;
                else if (staked.infusionLevel == 3) infusionBonus = 16;
                else if (staked.infusionLevel == 4) infusionBonus = 20;
                else if (staked.infusionLevel == 5) infusionBonus = 28;
            }
            tokenMultiplier += infusionBonus;
        }

        // Specialization bonus
        if (staked.specialization > 0 && staked.specialization <= 5) {
            uint8 specBonus = ctx.specializationBonuses[staked.specialization];
            if (specBonus == 0) {
                if (staked.specialization == 1) specBonus = 4;
                else if (staked.specialization == 2) specBonus = 6;
            }
            tokenMultiplier += specBonus;
        }

        // === CONTEXT BONUSES ===
        uint256 contextBonus = 0;

        // Colony bonus
        if (staked.colonyId != bytes32(0)) {
            uint256 colonyBonus = ss.colonyStakingBonuses[staked.colonyId];
            if (colonyBonus == 0) colonyBonus = ss.colonies[staked.colonyId].stakingBonus;
            if (colonyBonus == 0) colonyBonus = 5;
            if (colonyBonus > ctx.maxColonyBonus) colonyBonus = ctx.maxColonyBonus;
            contextBonus += colonyBonus;
        }

        // Loyalty bonus
        uint256 stakingDuration = block.timestamp - staked.stakedSince;
        contextBonus += LibStakingStorage.calculateLoyaltyBonus(stakingDuration);

        // Accessory bonus
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        (uint256 accessoryBonus, bool cacheValid) = LibStakingStorage.getCachedAccessoryBonus(combinedId);
        if (!cacheValid) {
            ChargeAccessory[] memory accessories = LibStakingStorage.getTokenAccessories(ss, collectionId, tokenId);
            accessoryBonus = RewardCalculator.calculateAccessoryBonus(accessories, staked.specialization);
        }
        if (accessoryBonus > ctx.maxAccessoryBonus) accessoryBonus = ctx.maxAccessoryBonus;
        contextBonus += accessoryBonus;

        // Cap context bonus
        if (contextBonus > ctx.maxCombinedContextBonus) {
            contextBonus = ctx.maxCombinedContextBonus;
        }

        // === CALCULATE DAILY RATE ===
        uint256 result;
        if (ctx.useAdditiveContextBonuses) {
            uint256 safeSeasonMult = ctx.seasonMultiplier > 150 ? 150 : ctx.seasonMultiplier;
            result = Math.mulDiv(
                Math.mulDiv(dailyRate, tokenMultiplier, 100),
                (100 + contextBonus) * safeSeasonMult,
                10000
            );
        } else {
            result = Math.mulDiv(dailyRate, tokenMultiplier, 100);
            result = Math.mulDiv(result, ctx.seasonMultiplier, 100);
            result = Math.mulDiv(result, 100 + contextBonus, 100);
        }

        // Stake balance adjustment
        if (ctx.balanceEnabled && result > 0) {
            uint256 balanceMultiplier = RewardCalculator.calculateStakeBalanceMultiplier(
                ss.stakerTokenCount[staked.owner],
                ctx.totalStakedCount,
                stakingDuration,
                ctx.balanceEnabled,
                ctx.decayRate,
                ctx.minMultiplier,
                ctx.timeEnabled,
                ctx.maxTimeBonus,
                ctx.timePeriod
            );
            result = Math.mulDiv(result, balanceMultiplier, 100);
        }

        // Wear penalty
        uint8 wear = _quickWear(collectionId, tokenId, staked, ss);
        if (wear > 0) {
            uint256 penalty = LibStakingStorage.calculateWearPenalty(wear);
            if (penalty > 0 && penalty < 100) {
                result = (result * (100 - penalty)) / 100;
            }
        }

        return result;
    }

    function _quickWear(
        uint256 collectionId,
        uint256 tokenId,
        StakedSpecimen storage staked,
        LibStakingStorage.StakingStorage storage ss
    ) private view returns (uint8) {
        SpecimenCollection storage collection = ss.collections[collectionId];
        if (collection.biopodAddress != address(0)) {
            try IStakingBiopodFacet(collection.biopodAddress).getWearLevel(collectionId, tokenId) returns (uint256 wear) {
                return uint8(wear > 100 ? 100 : wear);
            } catch {}
        }
        
        uint256 elapsed = block.timestamp - staked.lastWearUpdateTime;
        if (elapsed < 3600 || ss.wearIncreasePerDay == 0) {
            return staked.wearLevel;
        }
        
        uint256 increase = (elapsed * ss.wearIncreasePerDay) / LibStakingStorage.SECONDS_PER_DAY;
        uint256 total = staked.wearLevel + increase;
        
        return uint8(total > 100 ? 100 : total);
    }

    /**
     * @notice Distribute reward tokens: Treasury first, then mint if needed
     * @return fromTreasury True if paid from treasury, false if minted
     */
    function _distributeReward(
        LibStakingStorage.StakingStorage storage ss,
        address to,
        uint256 amount
    ) private returns (bool fromTreasury) {
        address rewardToken = ss.rewardToken;
        address treasury = ss.settings.treasuryAddress;
        
        // Try treasury first
        uint256 treasuryBalance = IRewardToken(rewardToken).balanceOf(treasury);
        uint256 allowance = IRewardToken(rewardToken).allowance(treasury, address(this));
        
        if (treasuryBalance >= amount && allowance >= amount) {
            // Pay from treasury
            bool success = IRewardToken(rewardToken).transferFrom(treasury, to, amount);
            if (success) {
                unchecked {
                    ss.totalRewardsDistributed += amount;
                }
                return true;
            }
        }
        
        // Fallback: Mint new tokens
        _mintReward(rewardToken, to, amount);
        
        unchecked {
            ss.totalRewardsDistributed += amount;
        }
        
        return false;
    }

    /**
     * @notice Distribute batch rewards with treasury/mint split tracking
     */
    function _distributeBatchReward(
        LibStakingStorage.StakingStorage storage ss,
        address to,
        uint256 totalAmount
    ) private returns (uint256 fromTreasury, uint256 fromMint) {
        address rewardToken = ss.rewardToken;
        address treasury = ss.settings.treasuryAddress;
        
        // Check treasury availability
        uint256 treasuryBalance = IRewardToken(rewardToken).balanceOf(treasury);
        uint256 allowance = IRewardToken(rewardToken).allowance(treasury, address(this));
        
        uint256 availableFromTreasury = treasuryBalance < allowance ? treasuryBalance : allowance;
        
        if (availableFromTreasury >= totalAmount) {
            // Full amount from treasury
            bool success = IRewardToken(rewardToken).transferFrom(treasury, to, totalAmount);
            if (success) {
                fromTreasury = totalAmount;
                fromMint = 0;
            } else {
                // Transfer failed, mint everything
                _mintReward(rewardToken, to, totalAmount);
                fromTreasury = 0;
                fromMint = totalAmount;
            }
        } else if (availableFromTreasury > 0) {
            // Partial from treasury, rest from mint
            bool success = IRewardToken(rewardToken).transferFrom(treasury, to, availableFromTreasury);
            if (success) {
                fromTreasury = availableFromTreasury;
                fromMint = totalAmount - availableFromTreasury;
                _mintReward(rewardToken, to, fromMint);
            } else {
                // Transfer failed, mint everything
                _mintReward(rewardToken, to, totalAmount);
                fromTreasury = 0;
                fromMint = totalAmount;
            }
        } else {
            // Everything from mint
            _mintReward(rewardToken, to, totalAmount);
            fromTreasury = 0;
            fromMint = totalAmount;
        }
        
        unchecked {
            ss.totalRewardsDistributed += totalAmount;
        }
        
        return (fromTreasury, fromMint);
    }

    /**
     * @notice Mint reward tokens
     * @dev Daily limit is enforced by LibStakingStorage, not YellowToken
     *      This contract must be set as limitExemptMinter in YellowToken
     */
    function _mintReward(address rewardToken, address to, uint256 amount) private {
        IRewardToken(rewardToken).mint(to, amount, "staking_reward");
    }

    function _tryExpGain(uint256 collectionId, uint256 tokenId, uint256 amount) private {
        if (amount == 0) return;

        try IStakingIntegrationFacet(address(this)).applyExperienceFromRewards(
            collectionId,
            tokenId,
            amount / 1 ether // Convert to whole tokens for EXP
        ) {} catch {}
    }

    // ============ RECEIPT TOKEN INTEGRATION ============

    /**
     * @notice Internal function to claim rewards for receipt token holders
     * @dev Called by StakingReceiptFacet - bypasses receipt check since caller already validated
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param recipient Address to receive rewards
     * @return amount Amount of rewards claimed
     */
    function claimRewardsFor(
        uint256 collectionId,
        uint256 tokenId,
        address recipient
    ) external onlyInternal returns (uint256 amount) {
        // Only callable internally (from this diamond's facets)
        if (msg.sender != address(this)) revert AccessHelper.Unauthorized(msg.sender, "Internal only");

        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        if (ss.rewardToken == address(0)) revert RewardTokenNotConfigured();

        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];

        if (!staked.staked) revert NothingToClaim();

        amount = _calculateReward(collectionId, tokenId, staked, ss);
        if (amount == 0) revert NothingToClaim();

        // Check shared daily limit
        uint256 availableLimit = LibStakingStorage.getAvailableYlwLimit(ss, recipient);
        if (amount > availableLimit) {
            revert DailyLimitExceeded(amount, availableLimit);
        }

        staked.lastClaimTimestamp = uint32(block.timestamp);
        staked.totalRewardsClaimed += amount;

        bool fromTreasury = _distributeReward(ss, recipient, amount);
        _tryExpGain(collectionId, tokenId, amount);

        // Consume from shared daily limit
        (bool limitOk, ) = LibStakingStorage.checkAndConsumeYlwLimit(ss, recipient, amount);
        if (!limitOk) revert DailyLimitExceeded(amount, availableLimit);

        emit RewardClaimed(collectionId, tokenId, recipient, amount, fromTreasury);

        return amount;
    }
}
