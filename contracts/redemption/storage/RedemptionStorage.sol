// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title RedemptionStorage
 * @notice Storage structure for Henomorphs Redemption System
 * @dev Uses ERC-7201 namespaced storage pattern for UUPS upgradeable proxy
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */

library RedemptionStorage {
    /// @custom:storage-location erc7201:henomorphs.redemption.storage
    bytes32 public constant REDEMPTION_STORAGE_POSITION = 
        keccak256(abi.encode(uint256(keccak256("henomorphs.redemption.storage")) - 1)) & ~bytes32(uint256(0xff));

    /**
     * @notice Tier configuration structure
     * @dev Defines requirements for each redemption tier
     */
    struct TierConfig {
        uint256 tierId;                      // Unique tier identifier (1=Bronze, 2=Silver, 3=Gold, 4=Diamond)
        string name;                         // Tier name (e.g., "Gold Badge")
        string uri;                          // Metadata URI (IPFS or on-chain)
        bool active;                         // Whether tier is currently active
        
        // Quantitative Requirements
        uint16 minStakedTokens;              // Minimum number of staked tokens
        uint32 minStakingDays;               // Minimum average staking duration in days
        uint8 minAverageLevel;               // Minimum average level of staked tokens
        
        // Qualitative Requirements
        uint8 requiredVariantCount;          // Number of different variants required (0-4)
        uint8 minInfusionLevel;              // Minimum infusion level required
        uint16 minInfusedTokenCount;         // Minimum count of tokens with infusion
        
        // Advanced Requirements
        bool requireColonyMembership;        // Must be in a colony
        bool requireColonyCreator;           // Must be colony creator (OR condition with membership)
        bool requireLoyaltyBonus;            // Must have active loyalty bonus
        uint8 minLoyaltyTier;                // Minimum loyalty tier (0=NONE, 1=BASIC, 2=SILVER, 3=GOLD, 4=PLATINUM, 5=DIAMOND)
        
        // Supply and Timing
        uint256 maxSupply;                   // Maximum number that can be redeemed (0 = unlimited)
        uint256 currentSupply;               // Current number redeemed
        uint256 startTime;                   // When tier becomes available (0 = immediately)
        uint256 endTime;                     // When tier closes (0 = never)
        
        // Additional Configuration
        uint256 cooldownPeriod;              // Cooldown between redemptions (seconds)
        bool allowMultipleRedemptions;       // Can user redeem multiple times
        bool burnOnUpgrade;                  // Burn lower tier when claiming higher tier
    }

    /**
     * @notice User redemption record
     * @dev Tracks individual user's redemption history
     */
    struct UserRedemption {
        uint256 tierId;                      // Which tier was redeemed
        uint256 timestamp;                   // When redemption occurred
        uint256 stakedTokenCount;            // How many tokens were staked at redemption
        uint256 averageStakingDays;          // Average staking duration at redemption
        uint256 snapshotBlockNumber;         // Block number of verification snapshot
        bool active;                         // Whether redemption is still valid
    }

    /**
     * @notice Snapshot data for verification
     * @dev Stores verification data at time of redemption attempt
     */
    struct VerificationSnapshot {
        address user;                        // User being verified
        uint256 tierId;                      // Tier being verified for
        uint256 timestamp;                   // Verification timestamp
        uint256 blockNumber;                 // Block number of snapshot
        
        // Computed metrics
        uint256 totalStakedTokens;           // Total staked at snapshot time
        uint256 averageStakingDays;          // Average days staked
        uint256 averageLevel;                // Average token level
        uint8[] variantDistribution;         // Count of each variant (index 0-4)
        uint256 infusedTokenCount;           // Tokens with infusion
        uint8 maxInfusionLevel;              // Highest infusion level
        
        // Status flags
        bool hasColonyMembership;            // Is in a colony
        bool isColonyCreator;                // Is colony creator
        bool hasLoyaltyBonus;                // Has active loyalty bonus
        uint8 loyaltyTier;                   // Current loyalty tier
        
        // Result
        bool eligible;                       // Final eligibility result
        string[] failureReasons;             // Reasons for ineligibility (if any)
    }

    /**
     * @notice Main storage structure
     */
    struct Layout {
        // Core configuration
        address stakingDiamondAddress;       // Address of Henomorphs Staking Diamond
        address treasuryAddress;             // Treasury for any fees
        bool systemPaused;                   // Emergency pause
        uint256 globalCooldownPeriod;        // Global cooldown between any redemptions
        
        // Tier management
        mapping(uint256 => TierConfig) tiers; // tierId => TierConfig
        uint256[] activeTierIds;             // List of active tier IDs
        uint256 tierCount;                   // Total number of tiers
        
        // User tracking
        mapping(address => UserRedemption[]) userRedemptions; // user => redemption history
        mapping(address => mapping(uint256 => bool)) hasRedeemed; // user => tierId => redeemed
        mapping(address => uint256) lastRedemptionTime; // user => timestamp
        mapping(address => uint256) userRedemptionCount; // user => total redemptions
        
        // Snapshot tracking
        mapping(bytes32 => VerificationSnapshot) snapshots; // snapshotHash => snapshot data
        mapping(address => bytes32[]) userSnapshots; // user => snapshot hashes
        
        // Statistics
        uint256 totalRedemptions;            // Total redemptions across all tiers
        mapping(uint256 => uint256) tierRedemptionCount; // tierId => count
        mapping(uint256 => address[]) tierRedeemers; // tierId => redeemer addresses
        
        // Metadata
        string baseURI;                      // Base URI for metadata
        mapping(uint256 => string) tierURIs; // Override URIs per tier
        bool useIPFS;                        // Whether to use IPFS for metadata
        
        // Access control extensions (beyond OpenZeppelin)
        mapping(address => bool) trustedVerifiers; // Addresses that can perform verification
        mapping(address => bool) blacklistedUsers; // Users blocked from redemption
        
        // Feature flags
        bool snapshotRequired;               // Whether snapshot verification is required
        bool gracePeriodsEnabled;            // Whether grace periods are active
        mapping(address => uint256) gracePeriodEnds; // user => grace period end timestamp
        
        // Version tracking
        uint256 storageVersion;              // Storage layout version
        uint256 lastUpgradeTimestamp;        // When last upgraded
        
        // Reserved for future upgrades
        uint256[50] __gap;                   // Reserve storage slots
    }

    /**
     * @notice Get storage layout
     * @return l Storage layout reference
     */
    function layout() internal pure returns (Layout storage l) {
        bytes32 position = REDEMPTION_STORAGE_POSITION;
        assembly {
            l.slot := position
        }
    }

    /**
     * @notice Generate snapshot hash
     * @param user User address
     * @param tierId Tier ID
     * @param timestamp Timestamp
     * @return Hash of snapshot
     */
    function generateSnapshotHash(
        address user,
        uint256 tierId,
        uint256 timestamp
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(user, tierId, timestamp));
    }

    /**
     * @notice Initialize storage
     * @dev Should be called only once during contract initialization
     */
    function initializeStorage(
        address _stakingDiamond,
        address _treasury
    ) internal {
        Layout storage l = layout();
        require(l.storageVersion == 0, "Already initialized");
        
        l.stakingDiamondAddress = _stakingDiamond;
        l.treasuryAddress = _treasury;
        l.systemPaused = false;
        l.globalCooldownPeriod = 24 hours;
        l.snapshotRequired = true;
        l.gracePeriodsEnabled = true;
        l.storageVersion = 1;
        l.lastUpgradeTimestamp = block.timestamp;
        l.useIPFS = true;
        l.baseURI = "ipfs://";
    }
}
