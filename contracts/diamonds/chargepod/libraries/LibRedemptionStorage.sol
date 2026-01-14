// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title LibRedemptionStorage
 * @notice Storage library for collection-based and staking-based token redemption
 * @dev Uses diamond storage pattern compatible with HenomorphsStaking diamond
 * @dev NO nested mappings - all mappings at top level for diamond compatibility
 */
library LibRedemptionStorage {
    bytes32 constant REDEMPTION_STORAGE_POSITION = keccak256("henomorphs.redemption.storage");

    /**
     * @notice Events
     */
    event CollectionRedemptionConfigured(
        uint256 indexed configId,
        address indexed collectionAddress,
        uint256 rewardCollectionId,
        uint256 rewardTierId,
        uint256 amountPerToken
    );

    event StakingRedemptionConfigured(
        uint256 indexed configId,
        uint256 rewardCollectionId,
        uint256 rewardTierId,
        uint256 minStakedTokens,
        uint256 minStakingDuration
    );

    event TokensRedeemed(
        address indexed user,
        RedemptionMethod indexed method,
        uint256 configId,
        uint256 amount,
        uint256 tokenId
    );

    event RewardContractRegistered(uint256 indexed contractId, address indexed contractAddress);
    event ActiveCollectionConfigChanged(uint256 indexed oldConfigId, uint256 indexed newConfigId);
    event ActiveStakingConfigChanged(uint256 indexed oldConfigId, uint256 indexed newConfigId);

    /**
     * @notice Errors
     */
    error RedemptionNotEnabled();
    error InsufficientCollectionBalance();
    error StakingConditionsNotMet();
    error CooldownNotElapsed();
    error InvalidConfiguration();
    error RewardRedeemableNotSet();
    error UnauthorizedAccess();
    error InvalidConfigId();
    error RedemptionLimitReached();
    error GlobalRedemptionLimitReached();

    /**
     * @notice Redemption method types
     */
    enum RedemptionMethod {
        NONE,                   // Not eligible
        COLLECTION_OWNERSHIP,   // Eligible via ERC721 collection ownership
        STAKING_CONDITIONS      // Eligible via staking conditions
    }

    /**
     * @notice Configuration for collection-based redemption
     * @dev Defines which ERC721 collections allow redemption and how much
     */
    struct CollectionRedemptionConfig {
        address collectionAddress;      // ERC721 collection address
        bool enabled;                   // Is this collection enabled for redemption
        uint256 rewardContractId;       // ID of reward contract to use
        uint256 rewardCollectionId;     // Target IRewardRedeemable collection ID
        uint256 rewardTierId;           // Target IRewardRedeemable tier ID
        uint256 amountPerToken;         // Amount to redeem per token owned
        uint256 maxTokensPerRedemption; // Max tokens to count per transaction
        uint256 cooldownPeriod;         // Cooldown between redemptions (seconds)
        uint256 maxRedemptionsPerUser;  // Max TOTAL AMOUNT of reward tokens per user PER CONFIG (0 = unlimited)
        uint256 maxTotalRedemptions;    // Max NUMBER of redemptions globally PER CONFIG (0 = unlimited) - for collection redemption only
        uint256 totalRedemptions;       // Counter: number of redemption attempts PER CONFIG
    }

    /**
     * @notice Configuration for staking-based redemption
     * @dev Defines staking conditions required for redemption
     */
    struct StakingRedemptionConfig {
        bool enabled;                   // Is staking redemption enabled
        uint256 rewardContractId;       // ID of reward contract to use
        uint256 rewardCollectionId;     // Target IRewardRedeemable collection ID
        uint256 rewardTierId;           // Target IRewardRedeemable tier ID
        uint256 minStakedTokens;        // Minimum tokens staked required
        uint256 minStakingDuration;     // Minimum staking duration (seconds)
        uint8 minLevel;                 // Minimum token level required
        uint8 minInfusionLevel;         // Minimum infusion level required
        bool requireColony;             // Must be in a colony
        uint256 amountPerRedemption;    // Amount to redeem per redemption
        uint256 cooldownPeriod;         // Cooldown between redemptions (seconds)
        // Quality and maintenance requirements
        uint8 minChargeLevel;           // Minimum charge level (0-100)
        uint8 maxWearLevel;             // Maximum wear level (0-100)
        uint8 minVariant;               // Minimum variant (1-4: Common, Rare, Epic, Legendary)
        uint256 minLifetimeEarnings;    // Minimum totalRewardsClaimed
        uint8 minSpecialization;        // Minimum specialization (0=none, 1=Efficiency, 2=Regen)
        uint256 maxRedemptionsPerUser;  // Max TOTAL AMOUNT of reward tokens per user PER CONFIG (0 = unlimited)
        uint256 maxTotalRedemptions;    // Max TOTAL AMOUNT of reward tokens globally PER CONFIG (0 = unlimited)
        uint256 totalRedemptions;       // Counter: number of redemption attempts PER CONFIG (NOT total amount)
    }

    /**
     * @notice Whitelist entry for staking config
     * @dev Stored separately to avoid modifying StakingRedemptionConfig struct (Diamond pattern)
     */
    struct ConfigWhitelist {
        address[] eligibleAddresses;    // Whitelist of eligible addresses (empty = no restriction)
    }

    /**
     * @notice Combined redemption eligibility check
     */
    struct RedemptionEligibility {
        bool eligible;
        RedemptionMethod method;
        uint256 maxAmount;              // Maximum redeemable amount
        uint256 remainingCooldown;      // Remaining cooldown time
        string reason;                  // Eligibility/ineligibility reason
    }

    /**
     * @notice Redemption statistics per user
     */
    struct UserRedemptionStats {
        uint256 totalEligibleRedemptions;
        uint256 totalStakingRedemptions;
        uint256 totalAmountRedeemed;
        uint256 lastRedemption;
    }

    /**
     * @notice Main storage struct
     * @dev All mappings at top level - NO nested mappings for diamond compatibility
     */
    struct RedemptionStorage {
        // Reward contracts: contractId => address
        mapping(uint256 => address) rewardContracts;
        uint256[] rewardContractIds;

        // Collection configs
        mapping(uint256 => CollectionRedemptionConfig) collectionConfigs;
        uint256[] collectionConfigIds;
        uint256 activeCollectionConfig;

        // Staking configs
        mapping(uint256 => StakingRedemptionConfig) stakingConfigs;
        uint256[] stakingConfigIds;
        uint256 activeStakingConfig;

        // User stats
        mapping(address => UserRedemptionStats) userStats;

        // Cooldowns: keccak256(configId, user) => timestamp
        mapping(bytes32 => uint256) collectionCooldowns;
        mapping(bytes32 => uint256) stakingCooldowns;

        // Per-config per-user redemption counts: keccak256("collection"|"staking", configId, user) => count
        mapping(bytes32 => uint256) userCollectionRedemptionCount;
        mapping(bytes32 => uint256) userStakingRedemptionCount;

        // Per-config per-user total amount redeemed: keccak256("amount", configId, user) => total amount
        mapping(bytes32 => uint256) userAmountRedeemed;

        // Per-config total amount redeemed: configId => total amount (for staking configs)
        mapping(uint256 => uint256) configAmountRedeemed;

        // Whitelist support for staking configs (Diamond pattern - added separately)
        mapping(uint256 => ConfigWhitelist) configWhitelists;
        mapping(bytes32 => bool) whitelistCache; // keccak256(configId, user) => bool
    }

    /**
     * @notice Get storage reference
     * @return rs RedemptionStorage reference
     */
    function redemptionStorage() internal pure returns (RedemptionStorage storage rs) {
        bytes32 position = REDEMPTION_STORAGE_POSITION;
        assembly {
            rs.slot := position
        }
    }

    /**
     * @notice Helper to get collection cooldown key
     */
    function getCollectionCooldownKey(uint256 configId, address user) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("collection", configId, user));
    }

    /**
     * @notice Helper to get staking cooldown key
     */
    function getStakingCooldownKey(uint256 configId, address user) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("staking", configId, user));
    }

    /**
     * @notice Helper to get collection redemption count key
     */
    function getCollectionRedemptionCountKey(uint256 configId, address user) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("collectionCount", configId, user));
    }

    /**
     * @notice Helper to get staking redemption count key
     */
    function getStakingRedemptionCountKey(uint256 configId, address user) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("stakingCount", configId, user));
    }

    /**
     * @notice Helper to get user config amount redeemed key
     */
    function getUserConfigAmountKey(uint256 configId, address user) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("configAmount", configId, user));
    }

    /**
     * @notice Helper to get whitelist cache key
     */
    function getWhitelistCacheKey(uint256 configId, address user) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("whitelistCache", configId, user));
    }

    /**
     * @notice Check if user is whitelisted for a staking config
     * @dev Returns true if whitelist is empty (no restriction) or user is on the list
     * @dev Uses cache to optimize repeated lookups
     */
    function isUserWhitelisted(uint256 configId, address user) internal view returns (bool) {
        RedemptionStorage storage rs = redemptionStorage();
        ConfigWhitelist storage whitelist = rs.configWhitelists[configId];

        // Empty whitelist = no restriction
        if (whitelist.eligibleAddresses.length == 0) {
            return true;
        }

        // Check cache first
        bytes32 cacheKey = getWhitelistCacheKey(configId, user);
        if (rs.whitelistCache[cacheKey]) {
            return true;
        }

        // Linear search through whitelist (cache miss)
        for (uint256 i = 0; i < whitelist.eligibleAddresses.length; i++) {
            if (whitelist.eligibleAddresses[i] == user) {
                return true;
            }
        }

        return false;
    }

}
