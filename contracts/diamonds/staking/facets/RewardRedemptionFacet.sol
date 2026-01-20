// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibRedemptionStorage} from "../../chargepod/libraries/LibRedemptionStorage.sol";
import {LibStakingStorage} from "../libraries/LibStakingStorage.sol";
import {PodsUtils} from "../../../libraries/PodsUtils.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {StakedSpecimen} from "../../../libraries/StakingModel.sol";
import {SpecimenCollection} from "../../../libraries/HenomorphsModel.sol";
import {IStakingBiopodFacet, Calibration} from "../interfaces/IStakingInterfaces.sol";

/**
 * @title IRewardRedeemable
 * @notice Interface for external contracts to mint reward tokens
 */
interface IRewardRedeemable {
    function mintReward(
        uint256 collectionId,
        uint256 tierId,
        address to,
        uint256 amount
    ) external returns (uint256 tokenId);

    function batchMintReward(
        uint256 collectionId,
        uint256[] calldata tierIds,
        address to,
        uint256[] calldata amounts
    ) external returns (uint256[] memory tokenIds);

    function canMintReward(
        uint256 collectionId,
        uint256 tierId,
        uint256 amount
    ) external view returns (bool);

    function getRemainingSupply(
        uint256 collectionId,
        uint256 tierId
    ) external view returns (uint256 remaining);
}

/**
 * @title TierEligibility
 * @notice Structure containing tier eligibility information for a user
 */
struct TierEligibility {
    uint256 configId;              // Tier config ID
    bool eligible;                 // Whether user is eligible
    uint256 rewardAmount;          // Amount of tokens user can redeem (0 if not eligible or already redeemed)
    uint256 userStakedCount;       // Number of eligible staked tokens user has
    uint256 minRequired;           // Minimum staked tokens required
    bool whitelisted;              // Whether user is on whitelist (if whitelist exists)
    bool alreadyRedeemed;          // Whether user already redeemed this tier
    bool globalLimitReached;       // Whether global redemption limit reached
    bool onCooldown;               // Whether user is on cooldown
    string reason;                 // Human-readable reason if not eligible
}

/**
 * @title RewardRedemptionFacet
 * @notice Diamond facet for collection-based and staking-based token redemption
 * @dev Compatible with HenomorphsStaking diamond pattern
 *
 * This facet enables two redemption methods:
 * 1. Collection Ownership: Users holding specific ERC721 tokens can redeem rewards
 * 2. Staking Conditions: Users meeting staking requirements can redeem rewards
 */
contract RewardRedemptionFacet is AccessControlBase {
    using LibRedemptionStorage for LibRedemptionStorage.RedemptionStorage;

    // ============ Modifiers ============
    modifier onlyRedemptionAdmin() {
        if (!AccessHelper.isAuthorized()) {
            revert LibRedemptionStorage.UnauthorizedAccess();
        }
        _;
    }

    // ============ Redemption Functions ============

    /**
     * @notice Redeem tokens based on ERC721 collection ownership
     * @dev User must own tokens from the configured collection
     * @param configId The collection config ID to use for redemption
     * @param tokenIds Array of token IDs user owns (for verification)
     * @return rewardTokenId The redeemed reward token ID
     */
    function redeemByCollection(
        uint256 configId,
        uint256[] calldata tokenIds
    ) external whenNotPaused nonReentrant returns (uint256 rewardTokenId) {
        address sender = LibMeta.msgSender();
        LibRedemptionStorage.RedemptionStorage storage rs = LibRedemptionStorage.redemptionStorage();
        LibRedemptionStorage.CollectionRedemptionConfig storage config = rs.collectionConfigs[configId];

        // Validations
        if (!config.enabled) revert LibRedemptionStorage.RedemptionNotEnabled();
        if (config.collectionAddress == address(0)) revert LibRedemptionStorage.InvalidConfiguration();

        address rewardCollection = rs.rewardContracts[config.rewardContractId];
        if (rewardCollection == address(0)) revert LibRedemptionStorage.RewardRedeemableNotSet();

        // Check cooldown
        bytes32 cooldownKey = LibRedemptionStorage.getCollectionCooldownKey(configId, sender);
        uint256 lastRedemption = rs.collectionCooldowns[cooldownKey];
        if (block.timestamp < lastRedemption + config.cooldownPeriod) {
            revert LibRedemptionStorage.CooldownNotElapsed();
        }

        // Verify collection ownership
        uint256 tokensToCount = tokenIds.length;
        if (tokensToCount > config.maxTokensPerRedemption) {
            tokensToCount = config.maxTokensPerRedemption;
        }
        if (tokensToCount == 0) revert LibRedemptionStorage.InsufficientCollectionBalance();

        IERC721 collection = IERC721(config.collectionAddress);
        for (uint256 i = 0; i < tokensToCount; i++) {
            if (collection.ownerOf(tokenIds[i]) != sender) {
                revert LibRedemptionStorage.InsufficientCollectionBalance();
            }
        }

        // Calculate redemption amount
        uint256 redemptionAmount = tokensToCount * config.amountPerToken;

        // Check redemption limits AFTER calculating redemption amount
        bytes32 countKey = LibRedemptionStorage.getCollectionRedemptionCountKey(configId, sender);

        // maxRedemptionsPerUser is the maximum TOTAL AMOUNT of reward tokens a user can redeem PER CONFIG
         bytes32 amountKey = LibRedemptionStorage.getUserConfigAmountKey(configId, sender);
        if (config.maxRedemptionsPerUser > 0) {
            uint256 userConfigRedeemed = rs.userAmountRedeemed[amountKey];
            if (userConfigRedeemed + redemptionAmount > config.maxRedemptionsPerUser) {
                revert LibRedemptionStorage.RedemptionLimitReached();
            }
        }

        // maxTotalRedemptions is the maximum NUMBER of redemptions globally for collection redemption
        // (each redemption can vary in amount, so we track count not total amount)
        if (config.maxTotalRedemptions > 0) {
            if (config.totalRedemptions >= config.maxTotalRedemptions) {
                revert LibRedemptionStorage.GlobalRedemptionLimitReached();
            }
        }

        // Mint reward
        IRewardRedeemable rewardable = IRewardRedeemable(rewardCollection);
        rewardTokenId = rewardable.mintReward(
            config.rewardCollectionId,
            config.rewardTierId,
            sender,
            redemptionAmount
        );

        // Update state
        rs.collectionCooldowns[cooldownKey] = block.timestamp;
        rs.userCollectionRedemptionCount[countKey]++;
        config.totalRedemptions++;

        // Update per-config amount tracking
        rs.userAmountRedeemed[amountKey] += redemptionAmount;

        // Update global user stats (for overall statistics)
        rs.userStats[sender].totalEligibleRedemptions++;
        rs.userStats[sender].totalAmountRedeemed += redemptionAmount;
        rs.userStats[sender].lastRedemption = block.timestamp;

        emit LibRedemptionStorage.TokensRedeemed(
            sender,
            LibRedemptionStorage.RedemptionMethod.COLLECTION_OWNERSHIP,
            configId,
            redemptionAmount,
            rewardTokenId
        );

        return rewardTokenId;
    }

    /**
     * @notice Redeem tokens based on staking conditions
     * @dev Automatically detects user's staked tokens and redeems specified tiers
     * @dev Checks whitelist (if defined) + staking conditions for each tier
     * @param tierConfigIds Array of tier config IDs to redeem (empty array = redeem ALL eligible tiers)
     * @return rewardTokenIds Array of redeemed reward token IDs
     */
    function redeemByStaking(uint256[] calldata tierConfigIds)
        external
        whenNotPaused
        nonReentrant
        returns (uint256[] memory rewardTokenIds)
    {
        address sender = LibMeta.msgSender();
        LibRedemptionStorage.RedemptionStorage storage rs = LibRedemptionStorage.redemptionStorage();
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        // Determine which tiers to check
        uint256[] memory configIdsToCheck;

        if (tierConfigIds.length == 0) {
            // Empty array = check all tiers
            configIdsToCheck = rs.stakingConfigIds;
        } else {
            // User specified specific tiers = only check those
            configIdsToCheck = tierConfigIds;
        }

        if (configIdsToCheck.length == 0) revert LibRedemptionStorage.RedemptionNotEnabled();

        // Collect all eligible tiers
        uint256[] memory eligibleConfigs = new uint256[](configIdsToCheck.length);
        uint256 eligibleCount = 0;

        // Check tiers for eligibility
        for (uint256 i = 0; i < configIdsToCheck.length; i++) {
            uint256 configId = configIdsToCheck[i];
            LibRedemptionStorage.StakingRedemptionConfig storage config = rs.stakingConfigs[configId];

            // Skip disabled configs
            if (!config.enabled) continue;

            // Check whitelist if defined for this tier
            if (!LibRedemptionStorage.isUserWhitelisted(configId, sender)) continue;

            // Check if user already redeemed this tier
            bytes32 amountKey = LibRedemptionStorage.getUserConfigAmountKey(configId, sender);
            uint256 userConfigRedeemed = rs.userAmountRedeemed[amountKey];

            if (config.maxRedemptionsPerUser > 0) {
                if (userConfigRedeemed >= config.maxRedemptionsPerUser) continue;
            }

            // Check if global limit reached
            if (config.maxTotalRedemptions > 0) {
                uint256 configTotal = rs.configAmountRedeemed[configId];
                if (configTotal >= config.maxTotalRedemptions) continue;
            }

            // Check cooldown
            bytes32 cooldownKey = LibRedemptionStorage.getStakingCooldownKey(configId, sender);
            uint256 lastRedemption = rs.stakingCooldowns[cooldownKey];
            if (block.timestamp < lastRedemption + config.cooldownPeriod) continue;

            // Auto-detect user's staked tokens and validate
            uint256 validStakedCount = _countAllValidStakedTokens(sender, config, ss);

            if (validStakedCount >= config.minStakedTokens) {
                // Mark this tier as eligible
                eligibleConfigs[eligibleCount] = configId;
                eligibleCount++;
            }
        }

        // Must have at least one eligible tier
        if (eligibleCount == 0) revert LibRedemptionStorage.StakingConditionsNotMet();

        // Calculate total tokens to mint across all eligible tiers
        uint256 totalTokensToMint = 0;
        for (uint256 i = 0; i < eligibleCount; i++) {
            uint256 configId = eligibleConfigs[i];
            LibRedemptionStorage.StakingRedemptionConfig storage config = rs.stakingConfigs[configId];
            
            bytes32 amountKey = LibRedemptionStorage.getUserConfigAmountKey(configId, sender);
            uint256 userConfigRedeemed = rs.userAmountRedeemed[amountKey];
            
            uint256 remaining = config.maxRedemptionsPerUser > userConfigRedeemed
                ? config.maxRedemptionsPerUser - userConfigRedeemed
                : config.amountPerRedemption;
            
            if (config.amountPerRedemption > remaining) {
                totalTokensToMint += remaining;
            } else {
                totalTokensToMint += config.amountPerRedemption;
            }
        }

        // Redeem all tokens across all eligible tiers
        rewardTokenIds = new uint256[](totalTokensToMint);
        uint256 tokenIndex = 0;
        
        for (uint256 i = 0; i < eligibleCount; i++) {
            uint256 configId = eligibleConfigs[i];
            LibRedemptionStorage.StakingRedemptionConfig storage config = rs.stakingConfigs[configId];
            
            bytes32 amountKey = LibRedemptionStorage.getUserConfigAmountKey(configId, sender);
            uint256 userConfigRedeemed = rs.userAmountRedeemed[amountKey];
            
            uint256 remaining = config.maxRedemptionsPerUser > userConfigRedeemed
                ? config.maxRedemptionsPerUser - userConfigRedeemed
                : config.amountPerRedemption;
            
            uint256 tokensToMintForTier = config.amountPerRedemption > remaining 
                ? remaining 
                : config.amountPerRedemption;
            
            // Mint each token individually for this tier
            for (uint256 j = 0; j < tokensToMintForTier; j++) {
                rewardTokenIds[tokenIndex] = _redeemStaking(configId, sender, rs, ss);
                tokenIndex++;
            }
        }

        return rewardTokenIds;
    }

    // ============ View Functions ============

    /**
     * @notice Get user's eligible staked tokens for active staking config
     * @param user User address to check
     * @param collectionId The collection ID to filter by
     * @return eligibleTokenIds Array of combined token IDs that meet requirements
     */
    function getEligibleStakedTokens(address user, uint256 collectionId)
        external
        view
        returns (uint256[] memory eligibleTokenIds)
    {
        LibRedemptionStorage.RedemptionStorage storage rs = LibRedemptionStorage.redemptionStorage();
        uint256 configId = rs.activeStakingConfig;
        return _getEligibleTokensForConfig(user, configId, collectionId);
    }

    /**
     * @notice Get user's eligible staked tokens for specific config
     * @param user User address to check
     * @param configId Staking config ID to check against
     * @param collectionId The collection ID to filter by
     * @return eligibleTokenIds Array of combined token IDs that meet requirements
     */
    function getTierEligibleStakedTokens(address user, uint256 configId, uint256 collectionId)
        external
        view
        returns (uint256[] memory eligibleTokenIds)
    {
        return _getEligibleTokensForConfig(user, configId, collectionId);
    }

    /**
     * @notice Internal helper to get eligible tokens for a config
     */
    function _getEligibleTokensForConfig(address user, uint256 configId, uint256 collectionId)
        internal
        view
        returns (uint256[] memory eligibleTokenIds)
    {
        LibRedemptionStorage.RedemptionStorage storage rs = LibRedemptionStorage.redemptionStorage();
        LibRedemptionStorage.StakingRedemptionConfig storage config = rs.stakingConfigs[configId];
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        uint256[] memory userTokens = ss.stakerTokens[user];
        uint256[] memory tempEligible = new uint256[](userTokens.length);
        uint256 eligibleCount = 0;

        for (uint256 i = 0; i < userTokens.length; i++) {
            uint256 combinedId = userTokens[i];

            // Filter by collection
            (uint256 tokenCollectionId, ) = PodsUtils.extractIds(combinedId);
            if (tokenCollectionId != collectionId) continue;

            if (!_isTokenEligible(user, combinedId, config, ss)) continue;

            tempEligible[eligibleCount] = combinedId;
            eligibleCount++;
        }

        // Copy to properly sized array
        eligibleTokenIds = new uint256[](eligibleCount);
        for (uint256 i = 0; i < eligibleCount; i++) {
            eligibleTokenIds[i] = tempEligible[i];
        }

        return eligibleTokenIds;
    }

    /**
     * @notice Check collection redemption eligibility
     * @param configId The collection config ID
     * @param user The user address to check
     * @param ownedTokenCount Number of tokens user owns
     * @return eligibility Detailed eligibility information
     */
    function checkCollectionEligibility(
        uint256 configId,
        address user,
        uint256 ownedTokenCount
    ) external view returns (LibRedemptionStorage.RedemptionEligibility memory eligibility) {
        LibRedemptionStorage.RedemptionStorage storage rs = LibRedemptionStorage.redemptionStorage();
        LibRedemptionStorage.CollectionRedemptionConfig storage config = rs.collectionConfigs[configId];

        eligibility.method = LibRedemptionStorage.RedemptionMethod.COLLECTION_OWNERSHIP;

        // Check enabled
        if (!config.enabled) {
            eligibility.eligible = false;
            eligibility.reason = "Redemption not enabled";
            return eligibility;
        }

        // Check cooldown
        bytes32 cooldownKey = LibRedemptionStorage.getCollectionCooldownKey(configId, user);
        uint256 lastRedemption = rs.collectionCooldowns[cooldownKey];
        if (block.timestamp < lastRedemption + config.cooldownPeriod) {
            eligibility.eligible = false;
            eligibility.remainingCooldown = (lastRedemption + config.cooldownPeriod) - block.timestamp;
            eligibility.reason = "Cooldown not elapsed";
            return eligibility;
        }

        // Check token balance
        if (ownedTokenCount == 0) {
            eligibility.eligible = false;
            eligibility.reason = "No tokens owned";
            return eligibility;
        }

        // Calculate max amount
        uint256 tokensToCount = ownedTokenCount > config.maxTokensPerRedemption
            ? config.maxTokensPerRedemption
            : ownedTokenCount;

        eligibility.eligible = true;
        eligibility.maxAmount = tokensToCount * config.amountPerToken;
        eligibility.reason = "Eligible for redemption";

        return eligibility;
    }

    /**
     * @notice Check staking redemption eligibility
     * @param configId The staking config ID
     * @param user The user address to check
     * @param stakedTokenIds Array of user's staked token combined IDs
     * @return eligibility Detailed eligibility information
     */
    function checkStakingEligibility(
        uint256 configId,
        address user,
        uint256[] calldata stakedTokenIds
    ) external view returns (LibRedemptionStorage.RedemptionEligibility memory eligibility) {
        LibRedemptionStorage.RedemptionStorage storage rs = LibRedemptionStorage.redemptionStorage();
        LibRedemptionStorage.StakingRedemptionConfig storage config = rs.stakingConfigs[configId];
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        eligibility.method = LibRedemptionStorage.RedemptionMethod.STAKING_CONDITIONS;

        // Check enabled
        if (!config.enabled) {
            eligibility.eligible = false;
            eligibility.reason = "Redemption not enabled";
            return eligibility;
        }

        // Check cooldown
        bytes32 cooldownKey = LibRedemptionStorage.getStakingCooldownKey(configId, user);
        uint256 lastRedemption = rs.stakingCooldowns[cooldownKey];
        if (block.timestamp < lastRedemption + config.cooldownPeriod) {
            eligibility.eligible = false;
            eligibility.remainingCooldown = (lastRedemption + config.cooldownPeriod) - block.timestamp;
            eligibility.reason = "Cooldown not elapsed";
            return eligibility;
        }

        // Verify staking conditions
        uint256 validStakedCount = 0;
        for (uint256 i = 0; i < stakedTokenIds.length; i++) {
            uint256 combinedId = stakedTokenIds[i];

            if (!ss.stakedSpecimens[combinedId].staked || ss.stakedSpecimens[combinedId].owner != user) continue;

            uint256 stakingDuration = block.timestamp - ss.stakedSpecimens[combinedId].stakedSince;
            if (stakingDuration < config.minStakingDuration) continue;
            if (ss.stakedSpecimens[combinedId].level < config.minLevel) continue;
            if (ss.stakedSpecimens[combinedId].infusionLevel < config.minInfusionLevel) continue;
            if (config.requireColony && ss.stakedSpecimens[combinedId].colonyId == bytes32(0)) continue;

            validStakedCount++;
        }

        if (validStakedCount < config.minStakedTokens) {
            eligibility.eligible = false;
            eligibility.reason = "Staking conditions not met";
            return eligibility;
        }

        eligibility.eligible = true;
        eligibility.maxAmount = config.amountPerRedemption;
        eligibility.reason = "Eligible for redemption";

        return eligibility;
    }

    // ============ View Functions ============

    /**
     * @notice Get user redemption statistics
     */
    function redemptionStatsOf(address user)
        external
        view
        returns (LibRedemptionStorage.UserRedemptionStats memory)
    {
        return LibRedemptionStorage.redemptionStorage().userStats[user];
    }

    /**
     * @notice Get collection redemption configuration
     */
    function getCollectionRedemptionConfig(uint256 configId)
        external
        view
        returns (
            address collectionAddress,
            bool enabled,
            uint256 rewardCollectionId,
            uint256 rewardTierId,
            uint256 amountPerToken,
            uint256 maxTokensPerRedemption,
            uint256 cooldownPeriod
        )
    {
        LibRedemptionStorage.CollectionRedemptionConfig storage config =
            LibRedemptionStorage.redemptionStorage().collectionConfigs[configId];

        return (
            config.collectionAddress,
            config.enabled,
            config.rewardCollectionId,
            config.rewardTierId,
            config.amountPerToken,
            config.maxTokensPerRedemption,
            config.cooldownPeriod
        );
    }

    /**
     * @notice Get staking redemption configuration
     */
    function getStakingRedemptionConfig(uint256 configId)
        external
        view
        returns (
            bool enabled,
            uint256 rewardCollectionId,
            uint256 rewardTierId,
            uint256 minStakedTokens,
            uint256 minStakingDuration,
            uint8 minLevel,
            uint8 minInfusionLevel,
            bool requireColony,
            uint256 amountPerRedemption,
            uint256 cooldownPeriod
        )
    {
        LibRedemptionStorage.StakingRedemptionConfig storage config =
            LibRedemptionStorage.redemptionStorage().stakingConfigs[configId];

        return (
            config.enabled,
            config.rewardCollectionId,
            config.rewardTierId,
            config.minStakedTokens,
            config.minStakingDuration,
            config.minLevel,
            config.minInfusionLevel,
            config.requireColony,
            config.amountPerRedemption,
            config.cooldownPeriod
        );
    }

    /**
     * @notice Get user's last redemption timestamp for collection config
     */
    function getCollectionRedemptionCooldown(uint256 configId, address user)
        external
        view
        returns (uint256)
    {
        bytes32 key = LibRedemptionStorage.getCollectionCooldownKey(configId, user);
        return LibRedemptionStorage.redemptionStorage().collectionCooldowns[key];
    }

    /**
     * @notice Get user's last redemption timestamp for staking config
     */
    function getStakingRedemptionCooldown(uint256 configId, address user)
        external
        view
        returns (uint256)
    {
        bytes32 key = LibRedemptionStorage.getStakingCooldownKey(configId, user);
        return LibRedemptionStorage.redemptionStorage().stakingCooldowns[key];
    }

    /**
     * @notice Get reward contract by ID
     */
    function getRewardCollection(uint256 contractId) external view returns (address) {
        return LibRedemptionStorage.redemptionStorage().rewardContracts[contractId];
    }

    /**
     * @notice Get all reward contract IDs
     */
    function allRewardContractIds() external view returns (uint256[] memory) {
        return LibRedemptionStorage.redemptionStorage().rewardContractIds;
    }

    /**
     * @notice Get active collection config ID
     */
    function getActiveCollectionRedemption() external view returns (uint256) {
        return LibRedemptionStorage.redemptionStorage().activeCollectionConfig;
    }

    /**
     * @notice Get active staking config ID
     */
    function getActiveStakingRedemption() external view returns (uint256) {
        return LibRedemptionStorage.redemptionStorage().activeStakingConfig;
    }

    /**
     * @notice Get all collection config IDs
     */
    function allCollectionConfigIds() external view returns (uint256[] memory) {
        return LibRedemptionStorage.redemptionStorage().collectionConfigIds;
    }

    /**
     * @notice Get all staking config IDs
     */
    function allStakingConfigIds() external view returns (uint256[] memory) {
        return LibRedemptionStorage.redemptionStorage().stakingConfigIds;
    }

    /**
     * @notice Get whitelist for a redemption config
     */
    function getRedemptionWhitelist(uint256 configId) external view returns (address[] memory) {
        return LibRedemptionStorage.redemptionStorage().configWhitelists[configId].eligibleAddresses;
    }

    /**
     * @notice Check if user is whitelisted for a staking config
     */
    function checkRedemptionEligibility(uint256 configId, address user) external view returns (bool) {
        return LibRedemptionStorage.isUserWhitelisted(configId, user);
    }

    /**
     * @notice Get all tier eligibility information for a user
     * @dev Returns detailed information about each tier: eligibility, amounts, and reasons
     * @param user User address to check
     * @return eligibilities Array of TierEligibility structs with all tier information
     */
    function getUserTierEligibility(address user) external view returns (TierEligibility[] memory eligibilities) {
        LibRedemptionStorage.RedemptionStorage storage rs = LibRedemptionStorage.redemptionStorage();
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        uint256[] memory configIds = rs.stakingConfigIds;
        eligibilities = new TierEligibility[](configIds.length);

        for (uint256 i = 0; i < configIds.length; i++) {
            uint256 configId = configIds[i];
            LibRedemptionStorage.StakingRedemptionConfig storage config = rs.stakingConfigs[configId];

            TierEligibility memory tier;
            tier.configId = configId;
            tier.minRequired = config.minStakedTokens;

            // Check if config is enabled
            if (!config.enabled) {
                tier.eligible = false;
                tier.rewardAmount = 0;
                tier.reason = "Tier disabled";
                eligibilities[i] = tier;
                continue;
            }

            // Check whitelist
            tier.whitelisted = LibRedemptionStorage.isUserWhitelisted(configId, user);
            if (!tier.whitelisted) {
                tier.eligible = false;
                tier.rewardAmount = 0;
                tier.reason = "Not whitelisted";
                eligibilities[i] = tier;
                continue;
            }

            // Check if already redeemed
            bytes32 amountKey = LibRedemptionStorage.getUserConfigAmountKey(configId, user);
            uint256 userRedeemed = rs.userAmountRedeemed[amountKey];
            tier.alreadyRedeemed = (config.maxRedemptionsPerUser > 0 && userRedeemed >= config.maxRedemptionsPerUser);

            if (tier.alreadyRedeemed) {
                tier.eligible = false;
                tier.rewardAmount = 0;
                tier.reason = "Already redeemed";
                eligibilities[i] = tier;
                continue;
            }

            // Check global limit
            uint256 configTotal = rs.configAmountRedeemed[configId];
            tier.globalLimitReached = (config.maxTotalRedemptions > 0 && configTotal >= config.maxTotalRedemptions);

            if (tier.globalLimitReached) {
                tier.eligible = false;
                tier.rewardAmount = 0;
                tier.reason = "Global limit reached";
                eligibilities[i] = tier;
                continue;
            }

            // Check cooldown
            bytes32 cooldownKey = LibRedemptionStorage.getStakingCooldownKey(configId, user);
            uint256 lastRedemption = rs.stakingCooldowns[cooldownKey];
            tier.onCooldown = (block.timestamp < lastRedemption + config.cooldownPeriod);

            if (tier.onCooldown) {
                tier.eligible = false;
                tier.rewardAmount = 0;
                tier.reason = "On cooldown";
                eligibilities[i] = tier;
                continue;
            }

            // Count valid staked tokens
            tier.userStakedCount = _countAllValidStakedTokens(user, config, ss);

            // Check if user meets staking requirements
            if (tier.userStakedCount >= config.minStakedTokens) {
                tier.eligible = true;
                unchecked {
                    uint256 remaining = config.maxRedemptionsPerUser > userRedeemed
                        ? config.maxRedemptionsPerUser - userRedeemed
                        : config.amountPerRedemption;
                    tier.rewardAmount = remaining;
                }
                tier.reason = "Eligible";
            } else {
                tier.eligible = false;
                tier.rewardAmount = 0;
                tier.reason = "Insufficient eligible tokens";
            }

            eligibilities[i] = tier;
        }

        return eligibilities;
    }

    // ============ Internal Helper Functions ============

    /**
     * @notice Internal redemption logic for auto-detected staking
     */
    function _redeemStaking(
        uint256 configId,
        address sender,
        LibRedemptionStorage.RedemptionStorage storage rs,
        LibStakingStorage.StakingStorage storage
    ) internal returns (uint256 rewardTokenId) {
        LibRedemptionStorage.StakingRedemptionConfig storage config = rs.stakingConfigs[configId];

        address rewardCollection = rs.rewardContracts[config.rewardContractId];
        if (rewardCollection == address(0)) revert LibRedemptionStorage.RewardRedeemableNotSet();

        // Mint single reward token
        IRewardRedeemable rewardable = IRewardRedeemable(rewardCollection);
        rewardTokenId = rewardable.mintReward(
            config.rewardCollectionId,
            config.rewardTierId,
            sender,
            1  // Mint 1 token at a time
        );

        // Update state
        bytes32 cooldownKey = LibRedemptionStorage.getStakingCooldownKey(configId, sender);
        rs.stakingCooldowns[cooldownKey] = block.timestamp;

        bytes32 countKey = LibRedemptionStorage.getStakingRedemptionCountKey(configId, sender);
        rs.userStakingRedemptionCount[countKey]++;
        config.totalRedemptions++;

        // Update per-config amount tracking (increment by 1)
        bytes32 amountKey = LibRedemptionStorage.getUserConfigAmountKey(configId, sender);
        rs.userAmountRedeemed[amountKey] += 1;
        rs.configAmountRedeemed[configId] += 1;

        // Update global user stats
        rs.userStats[sender].totalStakingRedemptions++;
        rs.userStats[sender].totalAmountRedeemed += 1;
        rs.userStats[sender].lastRedemption = block.timestamp;

        emit LibRedemptionStorage.TokensRedeemed(
            sender,
            LibRedemptionStorage.RedemptionMethod.STAKING_CONDITIONS,
            configId,
            1,  // Amount = 1
            rewardTokenId
        );

        return rewardTokenId;
    }

    /**
     * @notice Count ALL valid staked tokens across all collections
     * @dev Does not filter by collectionId - checks all user's staked tokens
     * @dev Used by redeemByStaking() for parameter-free redemption
     */
    function _countAllValidStakedTokens(
        address sender,
        LibRedemptionStorage.StakingRedemptionConfig storage config,
        LibStakingStorage.StakingStorage storage ss
    ) internal view returns (uint256) {
        uint256[] memory userTokens = ss.stakerTokens[sender];
        uint256 validCount = 0;

        for (uint256 i = 0; i < userTokens.length; i++) {
            uint256 combinedId = userTokens[i];

            if (!_isTokenEligible(sender, combinedId, config, ss)) continue;

            validCount++;
        }

        return validCount;
    }

    /**
     * @notice Check if a single staked token is eligible for redemption
     * @dev Separated to reduce code duplication and stack depth
     */
    function _isTokenEligible(
        address sender,
        uint256 combinedId,
        LibRedemptionStorage.StakingRedemptionConfig storage config,
        LibStakingStorage.StakingStorage storage ss
    ) internal view returns (bool) {
        StakedSpecimen storage specimen = ss.stakedSpecimens[combinedId];

        // Basic checks
        if (!specimen.staked) return false;
        if (specimen.owner != sender) return false;

        // Duration check
        if (block.timestamp - specimen.stakedSince < config.minStakingDuration) return false;

        // Get best values from StakedSpecimen and Biopod calibration data
        (uint256 bestLevel, uint256 bestCharge, uint256 bestWear) = _getBestTokenValues(specimen, ss);

        // Level checks - use best level from both sources
        if (bestLevel < config.minLevel) return false;
        if (specimen.infusionLevel < config.minInfusionLevel) return false;

        // Colony check
        if (config.requireColony && specimen.colonyId == bytes32(0)) return false;

        // Quality and maintenance checks - use best values from both sources
        if (config.minChargeLevel > 0 && bestCharge < config.minChargeLevel) return false;
        if (config.maxWearLevel < 100 && bestWear > config.maxWearLevel) return false;
        if (config.minVariant > 0 && specimen.variant < config.minVariant) return false;
        if (config.minLifetimeEarnings > 0 && specimen.totalRewardsClaimed < config.minLifetimeEarnings) return false;
        if (config.minSpecialization > 0 && specimen.specialization < config.minSpecialization) return false;

        return true;
    }

    /**
     * @notice Get best token values from StakedSpecimen and Biopod calibration data
     * @param specimen The staked specimen
     * @return bestLevel The highest level from both sources
     * @return bestCharge The highest charge level from both sources
     * @return bestWear The lowest wear level from both sources
     */
    function _getBestTokenValues(
        StakedSpecimen storage specimen,
        LibStakingStorage.StakingStorage storage
    ) internal view returns (uint256 bestLevel, uint256 bestCharge, uint256 bestWear) {
        // Start with StakedSpecimen values
        bestLevel = specimen.level;
        bestCharge = specimen.chargeLevel;
        bestWear = specimen.wearLevel;

        // Try to get Biopod calibration data using getBiopodCalibrationData from StakingBiopodFacet
        // This is called on the same diamond (address(this)) since we're part of the same diamond
        try IStakingBiopodFacet(address(this)).getBiopodCalibrationData(specimen.collectionId, specimen.tokenId) returns (bool exists, Calibration memory cal) {
            if (exists) {
                // Use the highest level
                uint8 level = uint8(cal.bioLevel > 0 ? cal.bioLevel : cal.level);
                if (level > bestLevel) {
                    bestLevel = level;
                }
                // Use the highest charge
                if (cal.charge > bestCharge) {
                    bestCharge = cal.charge;
                }
                // Use the lowest wear (better condition)
                if (cal.wear < bestWear) {
                    bestWear = cal.wear;
                }
            }
        } catch {
            // If Biopod call fails, use specimen values (already set)
        }

        return (bestLevel, bestCharge, bestWear);
    }

    // ============ Admin Functions ============

    /**
     * @notice Register a reward redeemable contract
     */
    function registerRewardCollection(uint256 contractId, address contractAddress)
        external
        onlyRedemptionAdmin
    {
        LibRedemptionStorage.RedemptionStorage storage rs = LibRedemptionStorage.redemptionStorage();
        rs.rewardContracts[contractId] = contractAddress;

        // Add to IDs if new
        bool exists = false;
        for (uint256 i = 0; i < rs.rewardContractIds.length; i++) {
            if (rs.rewardContractIds[i] == contractId) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            rs.rewardContractIds.push(contractId);
        }

        emit LibRedemptionStorage.RewardContractRegistered(contractId, contractAddress);
    }

    /**
     * @notice Set active collection redemption config
     */
    function setActiveCollectionRedemption(uint256 configId) external onlyRedemptionAdmin {
        LibRedemptionStorage.RedemptionStorage storage rs = LibRedemptionStorage.redemptionStorage();
        uint256 oldConfigId = rs.activeCollectionConfig;
        rs.activeCollectionConfig = configId;
        emit LibRedemptionStorage.ActiveCollectionConfigChanged(oldConfigId, configId);
    }

    /**
     * @notice Set active staking redemption config
     */
    function setActiveStakingRedemption(uint256 configId) external onlyRedemptionAdmin {
        LibRedemptionStorage.RedemptionStorage storage rs = LibRedemptionStorage.redemptionStorage();
        uint256 oldConfigId = rs.activeStakingConfig;
        rs.activeStakingConfig = configId;
        emit LibRedemptionStorage.ActiveStakingConfigChanged(oldConfigId, configId);
    }

    /**
     * @notice Configure collection-based redemption
     */
    function configureCollectionRedemption(
        uint256 configId,
        address collectionAddress,
        bool enabled,
        uint256 rewardContractId,
        uint256 rewardCollectionId,
        uint256 rewardTierId,
        uint256 amountPerToken,
        uint256 maxTokensPerRedemption,
        uint256 cooldownPeriod,
        uint256 maxRedemptionsPerUser,
        uint256 maxTotalRedemptions
    ) external onlyRedemptionAdmin {
        LibRedemptionStorage.RedemptionStorage storage rs = LibRedemptionStorage.redemptionStorage();
        LibRedemptionStorage.CollectionRedemptionConfig storage config = rs.collectionConfigs[configId];

        config.collectionAddress = collectionAddress;
        config.enabled = enabled;
        config.rewardContractId = rewardContractId;
        config.rewardCollectionId = rewardCollectionId;
        config.rewardTierId = rewardTierId;
        config.amountPerToken = amountPerToken;
        config.maxTokensPerRedemption = maxTokensPerRedemption;
        config.cooldownPeriod = cooldownPeriod;
        config.maxRedemptionsPerUser = maxRedemptionsPerUser;
        config.maxTotalRedemptions = maxTotalRedemptions;
        // Note: totalRedemptions is not reset when reconfiguring

        // Add to config IDs if new
        bool exists = false;
        for (uint256 i = 0; i < rs.collectionConfigIds.length; i++) {
            if (rs.collectionConfigIds[i] == configId) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            rs.collectionConfigIds.push(configId);
        }

        emit LibRedemptionStorage.CollectionRedemptionConfigured(
            configId,
            collectionAddress,
            rewardCollectionId,
            rewardTierId,
            amountPerToken
        );
    }

    /**
     * @notice Configure staking-based redemption
     * @dev Accepts config struct to avoid stack too deep errors
     */
    function configureStakingRedemption(
        uint256 configId,
        LibRedemptionStorage.StakingRedemptionConfig calldata newConfig
    ) external onlyRedemptionAdmin {
        // Copy config in chunks to avoid stack too deep
        _setStakingConfigBasic(configId, newConfig);
        _setStakingConfigQuality(configId, newConfig);

        // Add to config IDs if new
        _addStakingConfigId(configId);

        emit LibRedemptionStorage.StakingRedemptionConfigured(
            configId,
            newConfig.rewardCollectionId,
            newConfig.rewardTierId,
            newConfig.minStakedTokens,
            newConfig.minStakingDuration
        );
    }

    function _setStakingConfigBasic(
        uint256 configId,
        LibRedemptionStorage.StakingRedemptionConfig calldata newConfig
    ) internal {
        LibRedemptionStorage.RedemptionStorage storage rs = LibRedemptionStorage.redemptionStorage();
        LibRedemptionStorage.StakingRedemptionConfig storage config = rs.stakingConfigs[configId];

        config.enabled = newConfig.enabled;
        config.rewardContractId = newConfig.rewardContractId;
        config.rewardCollectionId = newConfig.rewardCollectionId;
        config.rewardTierId = newConfig.rewardTierId;
        config.minStakedTokens = newConfig.minStakedTokens;
        config.minStakingDuration = newConfig.minStakingDuration;
        config.minLevel = newConfig.minLevel;
        config.minInfusionLevel = newConfig.minInfusionLevel;
        config.requireColony = newConfig.requireColony;
        config.amountPerRedemption = newConfig.amountPerRedemption;
        config.cooldownPeriod = newConfig.cooldownPeriod;
    }

    function _setStakingConfigQuality(
        uint256 configId,
        LibRedemptionStorage.StakingRedemptionConfig calldata newConfig
    ) internal {
        LibRedemptionStorage.RedemptionStorage storage rs = LibRedemptionStorage.redemptionStorage();
        LibRedemptionStorage.StakingRedemptionConfig storage config = rs.stakingConfigs[configId];

        config.minChargeLevel = newConfig.minChargeLevel;
        config.maxWearLevel = newConfig.maxWearLevel;
        config.minVariant = newConfig.minVariant;
        config.minLifetimeEarnings = newConfig.minLifetimeEarnings;
        config.minSpecialization = newConfig.minSpecialization;
        config.maxRedemptionsPerUser = newConfig.maxRedemptionsPerUser;
        config.maxTotalRedemptions = newConfig.maxTotalRedemptions;
        // Note: totalRedemptions is not reset when reconfiguring
    }

    function _addStakingConfigId(uint256 configId) internal {
        LibRedemptionStorage.RedemptionStorage storage rs = LibRedemptionStorage.redemptionStorage();

        bool exists = false;
        for (uint256 i = 0; i < rs.stakingConfigIds.length; i++) {
            if (rs.stakingConfigIds[i] == configId) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            rs.stakingConfigIds.push(configId);
        }
    }

    /**
     * @notice Set whitelist for a staking config
     * @dev Replaces entire whitelist. Pass empty array to remove whitelist restriction.
     * @param configId The staking config ID
     * @param addresses Array of addresses to whitelist (empty = no restriction)
     */
    function setRedemptionWhitelist(uint256 configId, address[] calldata addresses)
        external
        onlyRedemptionAdmin
    {
        LibRedemptionStorage.RedemptionStorage storage rs = LibRedemptionStorage.redemptionStorage();
        LibRedemptionStorage.ConfigWhitelist storage whitelist = rs.configWhitelists[configId];

        // Clear old cache entries (only if whitelist exists)
        if (whitelist.eligibleAddresses.length > 0) {
            _clearWhitelistCache(configId, whitelist.eligibleAddresses);
        }

        // Replace whitelist
        delete whitelist.eligibleAddresses;
        for (uint256 i = 0; i < addresses.length; i++) {
            whitelist.eligibleAddresses.push(addresses[i]);
        }

        // Build cache for new whitelist
        if (addresses.length > 0) {
            _buildWhitelistCache(configId, addresses);
        }
    }

    /**
     * @notice Add addresses to staking config whitelist
     * @dev Appends to existing whitelist
     * @param configId The staking config ID
     * @param addresses Array of addresses to add
     */
    function addToRedemptionWhitelist(uint256 configId, address[] calldata addresses)
        external
        onlyRedemptionAdmin
    {
        LibRedemptionStorage.RedemptionStorage storage rs = LibRedemptionStorage.redemptionStorage();
        LibRedemptionStorage.ConfigWhitelist storage whitelist = rs.configWhitelists[configId];

        for (uint256 i = 0; i < addresses.length; i++) {
            whitelist.eligibleAddresses.push(addresses[i]);

            // Update cache
            bytes32 cacheKey = LibRedemptionStorage.getWhitelistCacheKey(configId, addresses[i]);
            rs.whitelistCache[cacheKey] = true;
        }
    }

    /**
     * @notice Remove addresses from staking config whitelist
     * @dev This is gas-intensive for large whitelists
     * @param configId The staking config ID
     * @param addresses Array of addresses to remove
     */
    function removeFromRedemptionWhitelist(uint256 configId, address[] calldata addresses)
        external
        onlyRedemptionAdmin
    {
        LibRedemptionStorage.RedemptionStorage storage rs = LibRedemptionStorage.redemptionStorage();
        LibRedemptionStorage.ConfigWhitelist storage whitelist = rs.configWhitelists[configId];

        for (uint256 i = 0; i < addresses.length; i++) {
            address toRemove = addresses[i];

            // Find and remove from array
            for (uint256 j = 0; j < whitelist.eligibleAddresses.length; j++) {
                if (whitelist.eligibleAddresses[j] == toRemove) {
                    // Move last element to this position and pop
                    whitelist.eligibleAddresses[j] = whitelist.eligibleAddresses[whitelist.eligibleAddresses.length - 1];
                    whitelist.eligibleAddresses.pop();
                    break;
                }
            }

            // Clear cache
            bytes32 cacheKey = LibRedemptionStorage.getWhitelistCacheKey(configId, toRemove);
            delete rs.whitelistCache[cacheKey];
        }
    }

    /**
     * @notice Internal helper to clear whitelist cache
     */
    function _clearWhitelistCache(uint256 configId, address[] storage addresses) internal {
        LibRedemptionStorage.RedemptionStorage storage rs = LibRedemptionStorage.redemptionStorage();

        for (uint256 i = 0; i < addresses.length; i++) {
            bytes32 cacheKey = LibRedemptionStorage.getWhitelistCacheKey(configId, addresses[i]);
            delete rs.whitelistCache[cacheKey];
        }
    }

    /**
     * @notice Internal helper to build whitelist cache
     */
    function _buildWhitelistCache(uint256 configId, address[] calldata addresses) internal {
        LibRedemptionStorage.RedemptionStorage storage rs = LibRedemptionStorage.redemptionStorage();

        for (uint256 i = 0; i < addresses.length; i++) {
            bytes32 cacheKey = LibRedemptionStorage.getWhitelistCacheKey(configId, addresses[i]);
            rs.whitelistCache[cacheKey] = true;
        }
    }

}
