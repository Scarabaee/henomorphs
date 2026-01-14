// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title LibPremiumStorage
 * @notice Storage library for premium actions and prediction markets
 * @dev Diamond storage pattern for premium features and prediction markets
 * @dev REFACTORED: Removed nested mappings from structs for proper Diamond Pattern compliance
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 * @custom:version 2.0.0 - Flattened storage structure
 */
library LibPremiumStorage {
    bytes32 constant PREMIUM_STORAGE_POSITION = keccak256("henomorphs.premium.storage");

    // ==================== PREMIUM ACTIONS ====================

    enum ActionType {
        INSTANT_PROCESS,      // Skip cooldowns instantly
        DOUBLE_REWARDS,       // 2x rewards for duration
        FREE_REPAIRS,         // Free repairs for duration  
        BOOST_PRODUCTION,     // 1.5x resource production
        GUARANTEED_CRIT,      // Guaranteed critical hits
        SKIP_BATTLE_COOLDOWN, // Skip battle cooldowns
        ENHANCED_DROPS,       // Better rare drop chances
        TERRITORY_SHIELD      // Temporary territory protection
    }

    struct PremiumAction {
        ActionType actionType;
        uint40 purchasedAt;      // When purchased
        uint40 activatedAt;      // When activated (0 if not yet)
        uint40 expiresAt;        // When expires
        uint16 usesRemaining;    // Uses left (0 = unlimited)
        uint16 totalUses;        // Total uses purchased
        bool active;             // Currently active
        uint256 amountPaid;      // ZICO or YLW paid
    }

    struct ActionConfig {
        uint256 priceZICO;       // Price in ZICO
        uint256 priceYLW;        // Price in YLW
        uint32 duration;         // Duration in seconds
        uint16 uses;             // Number of uses (0 = unlimited)
        uint16 effectStrength;   // Effect multiplier (200 = 2x)
        bool enabled;            // Can be purchased
        bool stackable;          // Can stack with other actions
    }

    struct DiscountTier {
        uint8 minLevel;          // Minimum staking level
        uint16 discountBps;      // Discount in basis points (1000 = 10%)
        uint32 minStakingDays;   // Minimum days staked
    }

    // ==================== PREDICTION MARKETS ====================

    enum MarketType {
        BINARY,           // Yes/No (2 outcomes)
        CATEGORICAL,      // Multiple outcomes (3-10)
        SCALAR            // Numerical range
    }

    enum MarketStatus {
        PENDING,          // Not yet open
        OPEN,             // Accepting bets
        LOCKED,           // Closed for betting
        RESOLVED,         // Winner determined
        DISPUTED,         // Under dispute
        CANCELLED         // Cancelled/invalid
    }

    struct PredictionMarket {
        MarketType marketType;
        MarketStatus status;
        bytes32 questionHash;    // IPFS hash of full question
        uint8 outcomeCount;      // Number of outcomes
        uint40 openTime;         // When market opens
        uint40 lockTime;         // When betting closes
        uint40 resolutionTime;   // Expected resolution time
        uint40 resolvedAt;       // Actual resolution time
        uint8 winningOutcome;    // Winning outcome index
        address creator;         // Market creator
        address resolver;        // Designated resolver
        uint256 creatorFee;      // Creator fee in bps
        uint256 protocolFee;     // Protocol fee in bps
        uint256 totalPool;       // Total YLW in pool
        uint256 creatorBond;     // Creator's bond (refunded if valid)
        uint256 minBet;          // Minimum bet amount
        uint256 maxBet;          // Maximum single bet
        bytes32 linkedEntity;    // Colony/battle/event ID
        bool allowDisputes;      // Can be disputed
        uint32 disputeWindow;    // Dispute window in seconds
    }

    struct MarketOutcome {
        string description;      // Outcome description
        uint256 pool;            // YLW staked on this outcome
        uint256 shares;          // Total shares issued
        uint256 impliedProb;     // Implied probability (cached)
    }

    // REMOVED: UserPosition struct with nested mappings
    // Now using flattened mappings in PremiumStorage

    struct MarketDispute {
        address disputer;
        uint8 proposedOutcome;
        uint256 bondAmount;
        uint40 timestamp;
        uint256 votesFor;
        uint256 votesAgainst;
        bool resolved;
    }

    // ==================== AMM MECHANICS (like Polymarket) ====================

    struct AMMPool {
        uint256[10] reserves;      // Reserves per outcome (max 10 outcomes)
        uint256 k;                 // Constant product k
        uint256 liquidity;         // Total liquidity
        uint256 creatorShares;     // Creator's LP shares
        uint16 swapFeeBps;         // Swap fee in basis points
    }

    // ==================== REPUTATION & REWARDS ====================

    struct ResolverProfile {
        uint32 marketsResolved;
        uint32 correctResolutions;
        uint32 disputesLost;
        uint256 totalVolume;
        uint16 reputationScore;    // 0-10000
        bool trusted;              // Trusted resolver
        uint40 lastActiveTime;
    }

    struct UserMarketProfile {
        uint256 totalWagered;
        uint256 totalWon;
        uint256 totalLost;
        uint32 marketsParticipated;
        uint32 marketsWon;
        uint16 winRate;            // Win rate in bps
        uint8 streakCurrent;       // Current win streak
        uint8 streakBest;          // Best win streak
    }

    // ==================== PROBABILISTIC REWARDS ====================

    struct ProbabilisticConfig {
        bool criticalHitsEnabled;
        bool rareDropsEnabled;
        bool streakBonusEnabled;
        uint16 baseCritChance;        // Base critical hit chance (basis points, 500 = 5%)
        uint16 maxCritChance;         // Max critical hit chance (4000 = 40%)
        uint16 critMultiplier;        // Critical hit multiplier (200 = 2x)
        uint16 pityThreshold;         // Actions before guaranteed epic (100)
        uint16 legendaryPityBoost;    // Pity boost per action (10 = 0.1%)
    }

    struct DropRarity {
        uint16 chance;                // Drop chance (basis points)
        uint256 minReward;            // Min reward amount
        uint256 maxReward;            // Max reward amount
        uint8 resourceCount;          // Number of resources awarded
    }

    struct UserProbabilisticData {
        uint32 lastActionDay;         // Last action day for streak tracking
        uint32 currentStreak;         // Current daily streak
        uint32 longestStreak;         // Longest streak achieved
        uint16 actionsSinceLegendary; // Pity counter
        uint256 totalCriticalHits;    // Lifetime crits
        uint256 totalRareDrops;       // Lifetime rare drops
    }

    // ==================== ACHIEVEMENT REWARDS ====================

    struct AchievementRewardConfig {
        uint256 tokenReward;          // Token reward amount
        uint256 resourceReward;       // Resource reward amount
        uint8 resourceType;           // Resource type (0-3)
        bool nftMintEnabled;          // Whether to mint NFT
        uint8 minTier;                // Minimum tier for rewards (1-5)
        bool configured;              // Whether achievement is configured
        // NEW FIELDS - APPEND ONLY BELOW
        uint8 maxTier;                // Maximum tier achievable (1-5)
    }

    struct UserAchievementReward {
        bool nftMinted;
        bool rewardClaimed;
        uint32 completionTime;
        uint8 tierAchieved;
    }

    // ==================== ORACLE INTEGRATION ====================

    struct OracleConfig {
        address oracleAddress;
        string description;
        uint32 stalePeriod;      // Seconds before data considered stale
        bool active;
        uint8 decimals;
    }

    struct OracleMarket {
        bytes32 oracleId;
        int256 targetPrice;      // Target price (scaled by oracle decimals)
        bool isAbove;            // True = price above target wins
        uint40 resolutionDeadline;
        bool autoResolved;
    }

    // ==================== STORAGE STRUCTURE ====================

    struct PremiumStorage {
        // === PREMIUM ACTIONS ===
        
        // User premium actions
        mapping(address => mapping(ActionType => PremiumAction)) userActions;
        mapping(address => uint256) userPremiumSpent;
        
        // Action configurations
        mapping(ActionType => ActionConfig) actionConfigs;
        
        // Discount tiers
        mapping(uint8 => DiscountTier) discountTiers;
        uint8 maxDiscountTier;
        
        // Statistics
        mapping(ActionType => uint256) actionsPurchased;
        mapping(ActionType => uint256) actionsRedeemed;
        uint256 totalPremiumRevenue;
        
        // Active actions tracking (for integration/queries)
        mapping(address => ActionType[]) userActiveActionTypes;  // User => list of active action types
        
        // === PREDICTION MARKETS ===
        
        // Markets
        mapping(uint256 => PredictionMarket) markets;
        mapping(uint256 => mapping(uint8 => MarketOutcome)) marketOutcomes;
        mapping(uint256 => MarketDispute[]) disputes;
        mapping(uint256 => AMMPool) ammPools;
        uint256 marketCounter;
        
        // === USER POSITIONS (FLATTENED - was UserPosition struct) ===
        // marketId => user => outcome => shares owned
        mapping(uint256 => mapping(address => mapping(uint8 => uint256))) positionOutcomeShares;
        
        // marketId => user => outcome => YLW staked
        mapping(uint256 => mapping(address => mapping(uint8 => uint256))) positionOutcomeStakes;
        
        // marketId => user => total YLW staked across all outcomes
        mapping(uint256 => mapping(address => uint256)) positionTotalStaked;
        
        // marketId => user => staking bonus amount
        mapping(uint256 => mapping(address => uint256)) positionStakingBonus;
        
        // marketId => user => has claimed winnings
        mapping(uint256 => mapping(address => bool)) positionClaimed;
        
        // marketId => user => last bet timestamp
        mapping(uint256 => mapping(address => uint40)) positionLastBetTime;
        
        // Market indexing
        mapping(MarketStatus => uint256[]) marketsByStatus;
        mapping(bytes32 => uint256[]) marketsByEntity;  // Colony/battle => market IDs
        mapping(address => uint256[]) userMarkets;      // User => participated markets
        
        // === DISPUTE VOTING ===
        // marketId => disputeIndex => voter => hasVoted
        mapping(uint256 => mapping(uint256 => mapping(address => bool))) disputeVotes;
        // marketId => disputeIndex => voter => votedFor (true = for, false = against)
        mapping(uint256 => mapping(uint256 => mapping(address => bool))) disputeVoteDirection;
        
        // === AMM LIQUIDITY PROVIDER TRACKING ===
        // marketId => user => LP shares
        mapping(uint256 => mapping(address => uint256)) lpShares;
        // marketId => total LP shares issued
        mapping(uint256 => uint256) totalLpShares;
        // marketId => list of LP providers
        mapping(uint256 => address[]) lpProviders;
        // marketId => user => is LP provider
        mapping(uint256 => mapping(address => bool)) isLpProvider;
        
        // === REFUND TRACKING ===
        // marketId => user => has claimed refund (for cancelled markets)
        mapping(uint256 => mapping(address => bool)) refundClaimed;
        
        // Resolvers
        mapping(address => ResolverProfile) resolvers;
        mapping(address => bool) trustedResolvers;
        mapping(address => uint256) resolverBonds;
        
        // User profiles
        mapping(address => UserMarketProfile) userProfiles;
        
        // Configuration
        uint256 minCreatorBond;
        uint256 minResolverBond;
        uint16 defaultProtocolFee;    // Basis points
        uint16 maxCreatorFee;         // Max creator can charge
        uint16 stakingBonusBps;       // Bonus per staking level
        uint32 defaultDisputeWindow;
        bool marketsEnabled;
        bool premiumEnabled;
        
        // Protocol revenue
        uint256 protocolFeesCollected;
        uint256 creatorFeesCollected;
        
        // Governance
        mapping(address => bool) authorizedCreators;  // Can create markets
        mapping(address => bool) marketOperators;     // Can manage markets
        
        // === ORACLE INTEGRATION ===
        mapping(bytes32 => OracleConfig) oracles;
        mapping(uint256 => OracleMarket) oracleMarkets;  // marketId => oracle config
        bytes32[] oracleIds;
        
        // === PROBABILISTIC REWARDS ===
        ProbabilisticConfig probabilisticConfig;
        mapping(uint8 => DropRarity) dropRarities;      // 0=common, 1=uncommon, 2=rare, 3=epic, 4=legendary
        mapping(address => UserProbabilisticData) probabilisticUserData;
        uint256 totalCriticalHits;
        uint256 totalRareDrops;
        uint256 legendaryDropCount;
        
        // === ACHIEVEMENT REWARDS ===
        address achievementNFT;       // NFT contract address
        mapping(uint256 => AchievementRewardConfig) achievementRewardConfigs;  // achievementId => config
        mapping(address => mapping(uint256 => UserAchievementReward)) userAchievementRewards;  // user => achievementId => reward
        uint256 totalAchievementsCompleted;
        uint256 totalNFTsMinted;
        uint256 totalTokensDistributed;
        uint256 totalResourcesDistributed;

        // === NEW FIELDS - APPEND ONLY BELOW THIS LINE ===
        uint256[] configuredAchievementIds;  // List of configured achievement IDs
        mapping(uint256 => bool) isAchievementConfigured;  // Quick lookup for duplicate prevention
    }

    /**
     * @notice Get premium storage reference
     * @return ps Premium storage reference
     */
    function premiumStorage() internal pure returns (PremiumStorage storage ps) {
        bytes32 position = PREMIUM_STORAGE_POSITION;
        assembly {
            ps.slot := position
        }
    }
}
