// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../../chargepod/libraries/LibHenomorphsStorage.sol";
import {IDiamondLoupe} from "../../shared/interfaces/IDiamondLoupe.sol";
import {PodsUtils} from "../../../libraries/PodsUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PodRewardRate, InfusionBonus, StakingFees, StakedSpecimen, 
        InfusedSpecimen, SeasonRewardMultiplier, Colony, 
        SpecialEvent, ColonyStats, RateLimits, RewardCalcData, InfusionCalcData} from "../../../libraries/StakingModel.sol";
import {SpecimenCollection, Calibration, ColonyCriteria, ChargeAccessory} from "../../../libraries/HenomorphsModel.sol";
import {IExternalBiopod, IExternalAccessory, IColonyFacet} from "../interfaces/IStakingInterfaces.sol"; 
import {RewardCalculator} from "../libraries/RewardCalculator.sol";
import {LibBiopodIntegration} from "./LibBiopodIntegration.sol";  

/**
 * @title LibStakingStorage
 * @notice Library for managing staking storage and calculations with enhanced safety
 * @dev Provides functions for reward calculations and storage management with overflow protection
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
library LibStakingStorage {
    using Math for uint256;
    
    bytes32 constant STAKING_STORAGE_POSITION = keccak256("henomorphs.staking.storage");

    /**
     * @dev Error for rate limit exceeded
     */
    error RateLimitExceeded();
    
    /**
     * @dev Error for token not staked
     */
    error TokenNotStaked();

    error InvalidCollectionId(uint256 collectionId);
    error CollectionNotFound(uint256 collectionId);
    error TokenHasReceipt(uint256 combinedId, uint256 receiptId);
    
    // Constants - using uint8 for those that will be compared with uint8 fields
    uint256 public constant SECONDS_PER_DAY = 86400; 
    uint256 public constant DAYS_PER_YEAR = 365;
    uint256 public constant MAX_REWARD_PERIOD = 365 days;     // Maximum staking period for reward calculations
    uint256 public constant MAX_BASE_RATE = 1000 ether;       // Maximum base reward rate per day
    uint256 public constant MAX_MULTIPLIER_PERCENTAGE = 500;  // Maximum multiplier (500%)
    uint256 public constant MAX_SAFE_INTEGER = 2**200;        // Safe computation threshold
    
    // Constants used with uint8 values
    uint8 public constant MAX_WEAR_LEVEL = 100;
    uint8 public constant MAX_CHARGE_LEVEL = 100;
    uint8 public constant MAX_INFUSION_LEVEL = 5;             // Maximum infusion level
    uint8 public constant MAX_TOKEN_LEVEL = 100;              // Maximum token level
    uint8 public constant MAX_VARIANT = 4;                    // Maximum variant

    uint256 public constant DEFAULT_DECAY_RATE = 10;        // Default decay rate for moderate balance adjustment
    uint256 public constant DEFAULT_MIN_MULTIPLIER = 50;    // Default minimum multiplier (50%)
    uint256 public constant DEFAULT_TIME_BONUS = 30;        // Default time bonus (30%)
    uint256 public constant DEFAULT_TIME_PERIOD = 90 days;  // Default period to reach maximum bonus (90 days)

    struct RewardCalculationConfig {
        // Level bonus configuration
        uint256 levelBonusNumerator;        // e.g., 50 for 0.5% per level (50/100)
        uint256 levelBonusDenominator;      // e.g., 100
        uint256 maxLevelBonus;              // e.g., 50 for maximum 50% bonus
        
        // Variant bonus configuration  
        uint256 variantBonusPercentPerLevel; // e.g., 5 for 5% per variant level above 1
        uint256 maxVariantBonus;            // e.g., 15 for maximum 15% bonus
        
        // Charge level bonus configuration
        uint8[4] chargeBonusThresholds;     // e.g., [40, 60, 80, 100]
        uint8[4] chargeBonusValues;         // e.g., [0, 4, 8, 12] for 0%, 4%, 8%, 12%
        
        // Infusion level bonuses (per level 1-5)
        uint8[6] infusionBonuses;           // Index 0 unused, 1-5 for levels 1-5
        
        // Specialization bonuses
        uint8[6] specializationBonuses;     // Index 0 = none, 1-5 for different specializations
        
        // Accessory and colony limits
        uint256 maxAccessoryBonus;          // e.g., 50 for maximum 50% accessory bonus
        uint256 maxColonyBonus;             // e.g., 35 for maximum 35% colony bonus
        uint256 maxAdminColonyBonus;        // e.g., 10 for admin-set limit
        
        // Context multiplier configuration
        bool useAdditiveContextBonuses;     // TRUE = additive, FALSE = multiplicative
        uint256 maxCombinedContextBonus;    // e.g., 100 for maximum 100% combined bonus
    }

    // Enhanced wear penalty configuration
    struct WearPenaltyConfig {
        bool useConfigurableThresholds;     // Whether to use arrays or default calculation
        uint8[] wearThresholds;             // e.g., [10, 20, 30, 40, 50, 60, 70, 80, 90]
        uint8[] wearPenalties;              // e.g., [1, 3, 5, 10, 15, 20, 30, 40, 50]
        uint8 maxWearPenalty;               // e.g., 95 for maximum 95% penalty
    }

    // Loyalty bonus configuration
    struct LoyaltyBonusConfig {
        bool enabled;                       // Whether loyalty bonuses are active
        uint256[] durationThresholds;       // e.g., [30, 90, 180, 365] days in seconds
        uint256[] bonusPercentages;         // e.g., [5, 10, 15, 25] percentages
        uint256 maxLoyaltyBonus;            // e.g., 30 for maximum 30% bonus
    }

    // Progressive decay configuration
    struct ProgressiveDecayConfig {
        // Tier thresholds in basis points (10000 = 100%)
        uint256[4] shareThresholds;         // e.g., [100, 500, 1000, 2000] for 1%, 5%, 10%, 20%
        
        // Decay rates for each tier (multipliers for base decay rate)
        uint256[4] decayMultipliers;        // e.g., [0, 20, 40, 60] for 0%, 0.2x, 0.4x, 0.6x
        
        // Maximum decay percentage
        uint256 maxDecayPercentage;         // e.g., 30 for maximum 30% decay
        
        // Base parameters
        uint256 baseDecayRate;              // e.g., 10 for base decay rate
        uint256 minMultiplier;              // e.g., 35 for minimum 35% multiplier
    }

    // Time bonus configuration  
    struct TimeBonusConfig {
        bool enabled;                       // Whether time bonuses are active
        uint256 maxTimeBonus;               // e.g., 12 for maximum 12% bonus
        uint256 timePeriod;                 // e.g., 90 days for period to reach max bonus
        bool applyToInfusion;               // Whether to apply time bonus to infusion
    }

    // ENHANCED: System limits with more comprehensive coverage
    struct SystemLimits {
        // Fee limits
        uint256 maxBasicOperationFee;       // Max fee for basic operations (stake, unstake, claim)
        uint256 maxSpecialOperationFee;     // Max fee for special operations (infusion, colony)
        uint256 maxTieredFeeBps;            // Max tiered fee in basis points
        
        // APR and bonus limits
        uint256 maxInfusionAPR;             // Max infusion APR
        uint256 maxInfusionBonusPerVariant; // Max bonus per variant for infusion
        uint256 maxInfusionBonusPercent;    // Max infusion bonus percent
        
        // Wear system limits
        uint256 maxWearThreshold;           // Max wear threshold for auto-repair
        uint256 maxWearIncreasePerDay;      // Max daily wear increase
        
        // Reward limits
        uint256 maxBaseRewardRate;          // Max base reward rate per day
        uint256 maxSeasonMultiplier;        // Max season multiplier
        uint256 maxTokensPerStaker;         // Max tokens per staker
        
        // Bonus limits
        uint256 maxLoyaltyBonus;            // Max loyalty bonus
        uint256 maxColonyBonus;             // Max colony bonus
        uint256 maxAccessoryBonus;          // Max accessory bonus
        uint256 maxCombinedBonus;           // Max combined bonus from all sources
    }

    struct ExternalModules {
        address chargeModuleAddress;
        address biopodModuleAddress;
        address accessoryModuleAddress; 
        address queryModuleAddress; 
        address colonyModuleAddress; 
        address specializationModuleAddress; 
    }

    struct InternalModules {
        address coreModuleAddress;
        address biopodModuleAddress;
        address wearModuleAddress;
        address integrationModuleAddress;
        address colonyModuleAddress;
    }

    struct ModuleRegistry {
        // Expected selectors for each module type
        mapping(string => bytes4[]) expectedSelectors;
        // Last verification timestamp
        uint256 lastVerificationTimestamp;
        // Result of last verification
        bool lastVerificationResult;
        // Module verification errors
        mapping(string => string) verificationErrors;
    }

    /**
     * @notice Enum defining loyalty tier levels
     */
    enum LoyaltyTierLevel {
        NONE,     // 0 - No tier assigned (default state)
        BASIC,    // 1 - Basic tier (whitelist entry level)
        SILVER,   // 2 - Silver tier 
        GOLD,     // 3 - Gold tier
        PLATINUM, // 4 - Platinum tier
        DIAMOND   // 5 - Diamond tier (highest premium level)
    }

    /**
     * @notice Configuration for a loyalty tier
     */
    struct LoyaltyTierConfig {
        string name;           // Tier name (e.g., "Basic", "Silver", etc.)
        uint256 bonusPercent;  // Bonus percentage (e.g., 5, 10, 20)
        bool active;           // Whether the tier is active
        uint256 stakingRequirement; // Optional minimum staking amount requirement (0 = no requirement)
        uint256 durationRequirement; // Optional minimum staking duration in days (0 = no requirement)
    }

    /**
     * @notice Assignment of tier to address
     */
    struct LoyaltyTierAssignment {
        LoyaltyTierLevel tierLevel;  // Assigned tier level
        uint256 expiryTime;      // Expiration timestamp (0 = never expires)
        uint256 assignedAt;      // When the tier was assigned
    }

    /**
     * @notice Parameters for stake balance adjustment
     */
    struct BalanceAdjustmentParams {
        bool enabled;                // Whether balance adjustment is enabled
        uint256 decayRate;           // Decay rate parameter 
        uint256 minMultiplier;       // Minimum multiplier percentage
        bool applyToInfusion;        // Whether to apply to infusion rewards
    }

    /**
     * @notice Parameters for time-based decay
     */
    struct TimeDecayParams {
        bool enabled;                // Whether time decay is enabled
        uint256 maxBonus;            // Maximum time-based bonus
        uint256 period;              // Time period for maximum bonus
    }

    /**
     * @notice Parameters for tiered fee structure
     */
    struct TieredFeeParams {
        bool enabled;                // Whether tiered fees are enabled
        uint256[] thresholds;        // Thresholds for fee tiers
        uint256[] feeBps;            // Fee rates in basis points
    }

    /**
     * @notice Configuration for the staking vault - determines where staked tokens are stored
     * @dev Default configuration sets useExternalVault to false and vault address to treasury
     */
    struct VaultConfig {
        bool useExternalVault;          // Whether to use an external vault instead of the diamond
        address vaultAddress;           // Vault address (always set - defaults to treasury)
    }

    struct WearAutoRepairConfig {
        bool enabled;                // Whether auto-repair is enabled
        uint256 repairInterval;      // Time between auto-repairs (e.g., 1 day)
        uint8 repairAmount;          // Amount to repair when triggered (e.g., 5 points)
        uint8 triggerThreshold;      // Threshold to trigger repair (e.g., 30%)
        bool freeAutoRepair;         // Whether auto-repair is free
    }

    /**
     * @dev Struct for storing all staking-related data
     */
    struct StakingStorage {
        // Version tracking
        uint256 storageVersion;
        
        // Main configuration
        bool stakingEnabled;
        IERC20 zicoToken;
        
        // Collection management
        mapping(uint256 => SpecimenCollection) collections;
        uint256 collectionCounter;
        
        // Staked tokens tracking
        mapping(uint256 => StakedSpecimen) stakedSpecimens;
        mapping(address => uint256[]) stakerTokens;
        mapping(uint256 => uint256) tokenCollectionIds;
        uint256 totalStakedSpecimens;
        
        // Infusion tracking
        mapping(uint256 => InfusedSpecimen) infusedSpecimens;
        uint256 totalInfusedSpecimens;
        uint256 totalInfusedZico;
        
        // Rewards and settings
        StakingSettings settings;
        StakingFees fees;
        uint256 totalRewardsDistributed;
        
        // Seasons and events
        SeasonRewardMultiplier currentSeason;
        mapping(uint256 => SpecialEvent) specialEvents;
        uint256 specialEventCounter;
        
        // Colonies integration
        mapping(bytes32 => bool) colonyActive;
        mapping(bytes32 => string) colonyNameById;
        mapping(bytes32 => address) colonyCreators;
        mapping(bytes32 => uint256) colonyStakingBonuses;
        mapping(bytes32 => uint256[]) colonyMembers;
        mapping(bytes32 => ColonyStats) colonyStats;
        mapping(bytes32 => Colony) colonies;
        bytes32[] allColonyIds;
        
        // Chargeopod integration
        address chargeSystemAddress;
        // Staking integration
        address stakingSystemAddress;
        
        // Cooldown tracking
        mapping(uint256 => uint32) stakingCooldowns;
        
        // Rate limiting
        mapping(address => mapping(bytes4 => mapping(uint256 => uint256))) rateLimit;
        mapping(address => mapping(bytes4 => RateLimits)) rateLimits; // Updated rate limiting
        
        // Wear system
        uint256 wearIncreasePerDay;
        bool wearAutoRepairEnabled;
        uint256 wearAutoRepairThreshold;
        uint256 wearAutoRepairAmount;
        uint256 wearRepairCostPerPoint;
        uint8[] wearPenaltyThresholds;
        uint8[] wearPenaltyValues;

        // New mapping to track charge bonuses by token
        mapping(uint256 => uint8) tokenChargeBonuses;

        // Module configuration
        InternalModules internalModules;  // Added field for module configuration
        ExternalModules externalModules;  // Added field for module configuration

        // Module verification
        ModuleRegistry moduleRegistry;
        mapping(address => uint16) collectionIndexes;

        // Loyalty Program
        mapping(LoyaltyTierLevel => LoyaltyTierConfig) loyaltyTierConfigs;  // Tier configurations
        mapping(address => LoyaltyTierAssignment) addressTierAssignments;   // Address tier assignments
        address[] loyaltyProgramAddresses;                                  // List of all addresses in the program
        bool loyaltyProgramEnabled;                                         // Global toggle for the program
        bool autoTierUpgradesEnabled;                                       // Whether automatic tier upgrades are enabled

        // Colony criteria - identical to Chargepod's implementation
        mapping(bytes32 => ColonyCriteria) colonyCriteria;   // Colony join criteria
        mapping(bytes32 => mapping(uint256 => address)) pendingJoinRequests; // Same as Chargepod
        mapping(bytes32 => uint256[]) colonyPendingRequestIds; // Same as Chargepod

        // ADDED: Power Core related settings
        bool requirePowerCoreForStaking;            // Whether to require power core activation for staking
        mapping(uint256 => bool) powerCoreBypass;   // Token ID => Bypass power core requirement

        // ADDED: Structures to track active stakers
        address[] activeStakers;                       // List of all unique addresses with staked tokens
        mapping(address => bool) isActiveStaker;       // Quick lookup to check if address is an active staker
        mapping(address => uint256) stakerTokenCount;  // Count of actively staked tokens per address

        mapping(address => uint256) stakerGracePeriods;  // Staker => Grace period end timestamp

        VaultConfig vaultConfig;        // Configuration for staked tokens storage
        WearAutoRepairConfig wearAutoRepairConfig;

        mapping(uint256 => bytes32) tokenPendingColonyAssignments; // combinedId => colonyId for tokens not yet staked
        bool forceOverrideInconsistentColonies; 
        
        SystemLimits systemLimits;

        RewardCalculationConfig rewardCalculationConfig;  // Comprehensive reward calculation settings
        WearPenaltyConfig wearPenaltyConfig;             // Enhanced wear penalty configuration  
        LoyaltyBonusConfig loyaltyBonusConfig;           // Configurable loyalty bonuses
        ProgressiveDecayConfig progressiveDecayConfig;    // Progressive decay configuration
        TimeBonusConfig timeBonusConfig;                 // Time bonus configuration

        uint256 configVersion;

        // Batch optimization storage
        mapping(uint256 => uint256) cachedAccessoryBonuses;
        mapping(uint256 => uint256) cacheTimestamps;
        uint256 cacheValidityPeriod; // e.g., 1 hour = 3600
        
        // YLW token integration
        address rewardToken;
        mapping(address => uint256) userLastClaimIndex;  // user => last processed token index
        mapping(address => mapping(uint256 => uint256)) userDailyRewardTokenUsed;  // user => day => total YLW (swap + claim)

        // ============ Staking Receipt Token Storage ============
        /// @notice Receipt token contract address (stkHENO)
        address receiptTokenContract;
        /// @notice Counter for receipt token IDs
        uint256 receiptTokenCounter;
        /// @notice Mapping from combinedId to receiptId
        mapping(uint256 => uint256) combinedIdToReceiptId;
        /// @notice Mapping from receiptId to combinedId
        mapping(uint256 => uint256) receiptIdToCombinedId;
        /// @notice Flag indicating if token has active receipt
        mapping(uint256 => bool) hasReceiptToken;
    }
    
    /**
     * @dev Internal struct for staking settings
     */
    struct StakingSettings {
        // Base reward rates by variant
        uint256[] baseRewardRates;
        
        // Level-based multipliers
        uint256[] levelRewardMultipliers;
        
        // Infusion settings
        uint256 baseInfusionAPR;
        uint256 bonusInfusionAPRPerVariant;
        mapping(uint8 => uint256) infusionBonuses;
        
        // Time periods and limits
        uint256 minimumStakingPeriod;
        uint256 minInfusionAmount;
        uint256 earlyUnstakingFeePercentage;
        uint256 stakingCooldown;
        
        // Max infusion by variant
        mapping(uint8 => uint256) baseMaxInfusionByVariant;
        
        // Loyalty bonuses
        mapping(uint256 => uint256) loyaltyBonusThresholds;
        
        // Treasury address
        address treasuryAddress;

        // Stake balance mechanism
        BalanceAdjustmentParams balanceAdjustment;
        TimeDecayParams timeDecay;
        TieredFeeParams tieredFees;
        uint256 maxTokensPerStaker;  // Maximum tokens per staker (0 = unlimited)
    }
    
    /**
     * @notice Get staking storage
     * @return ss Storage reference
     */
    function stakingStorage() internal pure returns (StakingStorage storage ss) {
        bytes32 position = STAKING_STORAGE_POSITION;
        assembly {
            ss.slot := position
        }
    }

    /**
     * @notice Initialize base reward rates
     */
    function initializeBaseRewardRates() internal {
        StakingStorage storage ss = stakingStorage();
        
        if (ss.settings.baseRewardRates.length == 0) {
            ss.settings.baseRewardRates.push(1 ether);   // Variant 1: 1 ZICO/day
            ss.settings.baseRewardRates.push(2 ether);   // Variant 2: 2 ZICO/day  
            ss.settings.baseRewardRates.push(3 ether);   // Variant 3: 3 ZICO/day
            ss.settings.baseRewardRates.push(5 ether);   // Variant 4: 5 ZICO/day
        }
        
        // Initialize cache system
        if (ss.cacheValidityPeriod == 0) {
            ss.cacheValidityPeriod = 1800; // 30 minutes
        }
    }

    /**
     * @notice Initialize default configuration values
     * @dev Should be called once during deployment or upgrade
     */
    function initializeDefaultConfiguration() internal {
        StakingStorage storage ss = stakingStorage();

        // Initialize base reward rates
        initializeBaseRewardRates();
        
        // Optimized reward calculation config
        RewardCalculationConfig storage rewardConfig = ss.rewardCalculationConfig;
        rewardConfig.levelBonusNumerator = 40;           // 0.4% per level (40/100)
        rewardConfig.levelBonusDenominator = 100;
        rewardConfig.maxLevelBonus = 40;                 // Max 40% bonus
        
        rewardConfig.variantBonusPercentPerLevel = 4;    // 4% per variant
        rewardConfig.maxVariantBonus = 12;               // Max 12% from variant
        
        // Charge bonuses
        rewardConfig.chargeBonusThresholds = [40, 60, 80, 100];
        rewardConfig.chargeBonusValues = [0, 3, 6, 10];
        
        // Infusion bonuses
        rewardConfig.infusionBonuses = [0, 8, 12, 16, 20, 28];
        
        // Specialization bonuses
        rewardConfig.specializationBonuses = [0, 4, 6, 0, 0, 0];
        
        rewardConfig.maxAccessoryBonus = 40;
        rewardConfig.maxColonyBonus = 30;
        rewardConfig.maxAdminColonyBonus = 8;
        
        // Use additive context bonuses to prevent compounding explosion
        rewardConfig.useAdditiveContextBonuses = true;
        rewardConfig.maxCombinedContextBonus = 75;
        
        // Wear penalty config
        WearPenaltyConfig storage wearConfig = ss.wearPenaltyConfig;
        wearConfig.useConfigurableThresholds = true;
        
        // Clear arrays before setting new values
        delete wearConfig.wearThresholds;
        delete wearConfig.wearPenalties;
        
        // Set wear thresholds and penalties
        wearConfig.wearThresholds.push(10);
        wearConfig.wearThresholds.push(20);
        wearConfig.wearThresholds.push(30);
        wearConfig.wearThresholds.push(40);
        wearConfig.wearThresholds.push(50);
        wearConfig.wearThresholds.push(60);
        wearConfig.wearThresholds.push(70);
        wearConfig.wearThresholds.push(80);
        wearConfig.wearThresholds.push(90);
        
        wearConfig.wearPenalties.push(1);
        wearConfig.wearPenalties.push(3);
        wearConfig.wearPenalties.push(5);
        wearConfig.wearPenalties.push(8);
        wearConfig.wearPenalties.push(12);
        wearConfig.wearPenalties.push(18);
        wearConfig.wearPenalties.push(25);
        wearConfig.wearPenalties.push(35);
        wearConfig.wearPenalties.push(45);
        
        wearConfig.maxWearPenalty = 92;
        
        // Loyalty bonus config - aligned with 90-day minimum staking period
        LoyaltyBonusConfig storage loyaltyConfig = ss.loyaltyBonusConfig;
        loyaltyConfig.enabled = true;
        
        delete loyaltyConfig.durationThresholds;
        delete loyaltyConfig.bonusPercentages;
        
        loyaltyConfig.durationThresholds.push(90 * SECONDS_PER_DAY);   // 90 days (min period)
        loyaltyConfig.durationThresholds.push(180 * SECONDS_PER_DAY);  // 180 days  
        loyaltyConfig.durationThresholds.push(365 * SECONDS_PER_DAY);  // 365 days
        loyaltyConfig.durationThresholds.push(730 * SECONDS_PER_DAY);  // 730 days (2 years)
        
        loyaltyConfig.bonusPercentages.push(5);   // 5% for 90+ days
        loyaltyConfig.bonusPercentages.push(10);  // 10% for 180+ days
        loyaltyConfig.bonusPercentages.push(18);  // 18% for 365+ days
        loyaltyConfig.bonusPercentages.push(25);  // 25% for 730+ days
        
        loyaltyConfig.maxLoyaltyBonus = 28;
        
        // Progressive decay config - targeted for large holders
        ProgressiveDecayConfig storage decayConfig = ss.progressiveDecayConfig;
        decayConfig.shareThresholds = [56, 333, 778, 1667];  // 0.5%, 3%, 7.8%, 15%
        decayConfig.decayMultipliers = [0, 10, 40, 70];
        decayConfig.maxDecayPercentage = 32;
        decayConfig.baseDecayRate = 10;
        decayConfig.minMultiplier = 55;
        
        // Time bonus config
        TimeBonusConfig storage timeConfig = ss.timeBonusConfig;
        timeConfig.enabled = true;
        timeConfig.maxTimeBonus = 16;
        timeConfig.timePeriod = 90 * SECONDS_PER_DAY;
        timeConfig.applyToInfusion = false;
        
        // System limits
        SystemLimits storage limits = ss.systemLimits;
        limits.maxBasicOperationFee = 10 ether;
        limits.maxSpecialOperationFee = 50 ether;
        limits.maxTieredFeeBps = 2000;
        limits.maxInfusionAPR = 50;
        limits.maxInfusionBonusPerVariant = 20;
        limits.maxInfusionBonusPercent = 50;
        limits.maxWearThreshold = 100;
        limits.maxWearIncreasePerDay = 10;
        limits.maxBaseRewardRate = 1000 ether;
        limits.maxSeasonMultiplier = 300;
        limits.maxTokensPerStaker = 90;
        limits.maxLoyaltyBonus = 28;
        limits.maxColonyBonus = 30;
        limits.maxAccessoryBonus = 40;
        limits.maxCombinedBonus = 150;
        
        // Update existing balance adjustment settings
        ss.settings.balanceAdjustment.enabled = true;
        ss.settings.balanceAdjustment.decayRate = 10;
        ss.settings.balanceAdjustment.minMultiplier = 55;
        ss.settings.balanceAdjustment.applyToInfusion = false;
        
        ss.settings.timeDecay.enabled = true;
        ss.settings.timeDecay.maxBonus = 16;
        ss.settings.timeDecay.period = 90 * SECONDS_PER_DAY;
        
        ss.settings.maxTokensPerStaker = 100;
        
        ss.configVersion = 2;
    }

    /**
     * @notice Get reward calculation configuration
     */
    function getRewardCalculationConfig() internal view returns (RewardCalculationConfig storage) {
        return stakingStorage().rewardCalculationConfig;
    }

    /**
     * @notice Get wear penalty configuration  
     */
    function getWearPenaltyConfig() internal view returns (WearPenaltyConfig storage) {
        return stakingStorage().wearPenaltyConfig;
    }

    /**
     * @notice Get loyalty bonus configuration
     */
    function getLoyaltyBonusConfig() internal view returns (LoyaltyBonusConfig storage) {
        return stakingStorage().loyaltyBonusConfig;
    }

    /**
     * @notice Get progressive decay configuration
     */
    function getProgressiveDecayConfig() internal view returns (ProgressiveDecayConfig storage) {
        return stakingStorage().progressiveDecayConfig;
    }

    /**
     * @notice Get time bonus configuration
     */
    function getTimeBonusConfig() internal view returns (TimeBonusConfig storage) {
        return stakingStorage().timeBonusConfig;
    }

    /**
     * @notice Get maximum creator bonus percentage from proper source
     */
    function getMaxCreatorBonusPercentage() internal view returns (uint256 maxBonus) {
        StakingStorage storage ss = stakingStorage();
        
        // Use configured value if available
        if (ss.rewardCalculationConfig.maxAdminColonyBonus > 0) {
            return ss.rewardCalculationConfig.maxAdminColonyBonus;
        }
        
        // Fallback to checking charge system
        maxBonus = 10; // Default
        
        if (ss.chargeSystemAddress != address(0)) {
            try IColonyFacet(ss.chargeSystemAddress).getMaxCreatorBonusPercentage() returns (uint256 bonus) {
                if (bonus > 0) {
                    maxBonus = bonus;
                }
            } catch {
                // Use default value if call fails
            }
        }
        
        return maxBonus;
    }

    /**
     * @notice Helper to get accessories for a token
     */
    function getTokenAccessories(
        StakingStorage storage ss,
        uint256 collectionId,
        uint256 tokenId
    ) internal view returns (ChargeAccessory[] memory accessories) {
        if (ss.externalModules.chargeModuleAddress == address(0)) {
            return new ChargeAccessory[](0);
        }
        
        try IExternalAccessory(ss.externalModules.chargeModuleAddress)
            .getTokenAccessories(collectionId, tokenId) returns (ChargeAccessory[] memory acc) {
            
            // Prevent gas bombs and corrupted data
            if (acc.length > 15) {
                return new ChargeAccessory[](0);
            }
            
            // Basic validation
            for (uint256 i = 0; i < acc.length; i++) {
                if (acc[i].stakingBoostPercentage > 100 || 
                    acc[i].specializationBoostValue > 100) {
                    return new ChargeAccessory[](0);
                }
            }
            
            return acc;
        } catch {
            return new ChargeAccessory[](0);
        }
    }

    /**
     * @notice Verify module implements expected interface
     */
    function verifyModuleInterface(
        string memory moduleType,
        address moduleAddress
    ) internal view returns (bool valid) {
        StakingStorage storage ss = stakingStorage();
        
        // Get expected selectors
        bytes4[] storage selectors = ss.moduleRegistry.expectedSelectors[moduleType];
        if (selectors.length == 0) {
            return false; // No selectors registered
        }
        
        // Use diamond loupe to check interfaces
        address diamondAddress = address(this);
        
        // Check each selector
        for (uint256 i = 0; i < selectors.length; i++) {
            bytes4 selector = selectors[i];
            
            // Get facet for this selector
            try IDiamondLoupe(diamondAddress).facetAddress(selector) returns (address facet) {
                if (facet != moduleAddress) {
                    return false; // Mismatch
                }
            } catch {
                return false; // Error in lookup
            }
        }
        
        return true; // All selectors match
    }

    /**
     * @notice Get base daily reward rate without unit conversion issues
     */
    function getBaseDailyRewardRate(uint8 variant) internal view returns (uint256 rate) {
        StakingStorage storage ss = stakingStorage();
        
        uint8 safeVariant = variant == 0 ? 1 : (variant > MAX_VARIANT ? MAX_VARIANT : variant);
        
        if (ss.settings.baseRewardRates.length >= safeVariant) {
            rate = ss.settings.baseRewardRates[safeVariant - 1];
        } else {
            // Hardcoded defaults - keeping original values
            if (safeVariant == 1) rate = 1 ether;
            else if (safeVariant == 2) rate = 2 ether;
            else if (safeVariant == 3) rate = 3 ether;
            else if (safeVariant == 4) rate = 5 ether;
            else rate = 1 ether;
        }
        
        return rate;
    }

    /**
     * @notice DEPRECATED: Keep for backward compatibility but fix the bug
     */
    function getBaseRewardRate(uint8 variant) internal view returns (uint256 rate) {
        // Return daily rate divided by hours for hourly rate
        uint256 dailyRate = getBaseDailyRewardRate(variant);
        return dailyRate / 24; // Convert to hourly rate only once
    }

    /**
     * @notice Get unified token reward data with proper base reward calculation
     */
    function getUnifiedTokenRewardData(uint256 collectionId, uint256 tokenId) 
        internal 
        view 
        returns (RewardCalcData memory rewardData) 
    {
        StakingStorage storage ss = stakingStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        if (!staked.staked) {
            return rewardData; // Return empty struct
        }
        
        // Calculate time since last claim with safety cap
        uint256 timeElapsed = block.timestamp - staked.lastClaimTimestamp;
        if (timeElapsed > MAX_REWARD_PERIOD) {
            timeElapsed = MAX_REWARD_PERIOD;
        }
        
        // Use RewardCalculator for proper base reward calculation
        rewardData.baseReward = RewardCalculator.calculateBaseTimeReward(staked.variant, timeElapsed);
        
        // Set basic token data
        rewardData.level = staked.level;
        rewardData.variant = staked.variant;
        rewardData.chargeLevel = staked.chargeLevel;
        rewardData.infusionLevel = staked.infusionLevel;
        rewardData.specialization = staked.specialization;
        
        // Get current wear data using existing integration
        (uint256 currentWear,) = LibBiopodIntegration.getStakingWearLevel(collectionId, tokenId);
        rewardData.wearLevel = uint8(currentWear > 100 ? 100 : currentWear);
        
        // Use configurable wear penalty calculation
        rewardData.wearPenalty = uint8(calculateWearPenalty(rewardData.wearLevel));
        
        // Colony bonus with proper processing
        if (staked.colonyId != bytes32(0)) {
            uint256 rawBonus = getColonyStakingBonus(staked.colonyId);
            rewardData.colonyBonus = RewardCalculator.processColonyBonus(rawBonus, getMaxCreatorBonusPercentage());
        }
        
        // Season multiplier
        if (ss.currentSeason.active) {
            rewardData.seasonMultiplier = ss.currentSeason.multiplier;
        } else {
            rewardData.seasonMultiplier = 100; // Default 100%
        }
        
        // Loyalty bonus
        uint256 stakingDuration = block.timestamp - staked.stakedSince;
        rewardData.loyaltyBonus = calculateLoyaltyBonus(stakingDuration);
        
        // Accessory bonus
        ChargeAccessory[] memory accessories = getTokenAccessories(ss, collectionId, tokenId);
        rewardData.accessoryBonus = RewardCalculator.calculateAccessoryBonus(accessories, staked.specialization);
        
        rewardData.baseMultiplier = 100;
        
        return rewardData;
    }

    /**
     * @notice Get unified infusion reward data with proper APR calculation
     */
    function getUnifiedInfusionRewardData(uint256 collectionId, uint256 tokenId)
        internal view
        returns (InfusionCalcData memory data)
    {
        StakingStorage storage ss = stakingStorage();
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        InfusedSpecimen storage infused = ss.infusedSpecimens[combinedId];
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        // Skip if not infused or not staked
        if (!infused.infused || !staked.staked) {
            return data;
        }
        
        // Get infused amount with safety cap
        data.infusedAmount = infused.infusedAmount > MAX_SAFE_INTEGER ? 
                            MAX_SAFE_INTEGER : infused.infusedAmount;
        
        // Calculate time elapsed with safety
        if (block.timestamp <= infused.lastHarvestTime) {
            data.timeElapsed = 0;
        } else {
            data.timeElapsed = block.timestamp - infused.lastHarvestTime;
            data.timeElapsed = data.timeElapsed > MAX_REWARD_PERIOD ? MAX_REWARD_PERIOD : data.timeElapsed;
        }
        
        if (data.timeElapsed == 0 || data.infusedAmount == 0) {
            return data;
        }
        
        // Calculate APR with proper safety
        uint256 baseAPR = ss.settings.baseInfusionAPR > 100 ? 100 : ss.settings.baseInfusionAPR;
        uint8 safeVariant = staked.variant == 0 ? 1 : 
                           (staked.variant > MAX_VARIANT ? MAX_VARIANT : staked.variant);
        
        uint256 variantBonus = Math.mulDiv(ss.settings.bonusInfusionAPRPerVariant, (safeVariant - 1), 1);
        variantBonus = variantBonus > 50 ? 50 : variantBonus;
        
        data.apr = baseAPR + variantBonus;
        
        // Add infusion level bonuses
        uint8 safeInfusionLevel = staked.infusionLevel > MAX_INFUSION_LEVEL ? 
                                 MAX_INFUSION_LEVEL : staked.infusionLevel;
        
        if (safeInfusionLevel > 0) {
            uint256 infusionBonus = ss.settings.infusionBonuses[safeInfusionLevel];
            if (infusionBonus == 0) {
                // Default values
                if (safeInfusionLevel == 1) infusionBonus = 10;
                else if (safeInfusionLevel == 2) infusionBonus = 15;
                else if (safeInfusionLevel == 3) infusionBonus = 20;
                else if (safeInfusionLevel == 4) infusionBonus = 25;
                else if (safeInfusionLevel == 5) infusionBonus = 35;
            }
            infusionBonus = infusionBonus > 50 ? 50 : infusionBonus;
            data.apr += infusionBonus;
        }
        
        // Apply season multiplier safely
        if (ss.currentSeason.active) {
            uint256 safeMultiplier = ss.currentSeason.multiplier == 0 ? 100 : ss.currentSeason.multiplier;
            safeMultiplier = safeMultiplier > MAX_MULTIPLIER_PERCENTAGE ? MAX_MULTIPLIER_PERCENTAGE : safeMultiplier;
            data.apr = Math.mulDiv(data.apr, safeMultiplier, 100);
        }
        
        // Cap final APR
        data.apr = data.apr > 200 ? 200 : data.apr;
        
        // Calculate intelligence safely
        uint8 safeLevel = staked.level > MAX_TOKEN_LEVEL ? MAX_TOKEN_LEVEL : staked.level;
        uint16 intelligence = (uint16(safeLevel) / 2) + (uint16(safeVariant) * 3);
        data.intelligence = intelligence > 100 ? 100 : uint8(intelligence);
        
        // Get wear level safely
        data.wearLevel = staked.wearLevel > MAX_WEAR_LEVEL ? MAX_WEAR_LEVEL : staked.wearLevel;
        
        return data;
    }
    
    /**
     * @notice Checks if collection is valid and active
     */
    function isValidCollection(uint256 collectionId) internal view returns (bool isValid) {
        StakingStorage storage ss = stakingStorage();
        
        // Must have non-zero ID
        if (collectionId == 0 || collectionId > ss.collectionCounter) {
            return false;
        }
        
        // Collection must exist (have a non-zero address)
        if (ss.collections[collectionId].collectionAddress == address(0)) {
            return false;
        }
        
        // Collection must be enabled
        if (!ss.collections[collectionId].enabled) {
            return false;
        }
        
        return true;
    }

    /**
     * @notice Update charge bonus for token
     */
    function updateChargeBonus(uint256 collectionId, uint256 tokenId, uint256 chargeLevel) internal {
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakingStorage storage ss = stakingStorage();
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        // Skip if not staked
        if (!staked.staked) {
            return;
        }
        
        // Cap charge level at 100 and convert to uint8
        uint8 cappedChargeLevel;
        if (chargeLevel > MAX_CHARGE_LEVEL) {
            cappedChargeLevel = MAX_CHARGE_LEVEL;
        } else {
            cappedChargeLevel = uint8(chargeLevel);
        }
        
        // Only update if charge level changed
        if (staked.chargeLevel != cappedChargeLevel) {
            staked.chargeLevel = cappedChargeLevel;
            
            // Calculate charge bonus (0-20%)
            uint8 chargeBonus = 0;
            
            if (cappedChargeLevel > 50) {
                // Calculate the excess charge above 50
                uint8 excessCharge = cappedChargeLevel - 50;
                
                // Calculate bonus: 0-20% range (2% per 5 charge points)
                uint16 tempBonus = (uint16(excessCharge) * 2) / 5;
                
                // Ensure the result fits in uint8
                chargeBonus = tempBonus > 20 ? 20 : uint8(tempBonus);
            }
            
            ss.tokenChargeBonuses[combinedId] = chargeBonus;
        }
    }

    /**
     * @notice Get colony staking bonus
     */
    function getColonyStakingBonus(bytes32 colonyId) internal view returns (uint256 bonus) {
        StakingStorage storage ss = stakingStorage();
        
        if (colonyId == bytes32(0)) {
            return 0;
        }
        
        // Check explicit bonus first
        if (ss.colonyStakingBonuses[colonyId] > 0) {
            return ss.colonyStakingBonuses[colonyId];
        }
        
        // Check colony struct bonus
        if (ss.colonies[colonyId].stakingBonus > 0) {
            return ss.colonies[colonyId].stakingBonus;
        }
        
        // Calculate dynamic bonus if no explicit bonus set
        return calculateWeightedColonyBonus(ss, colonyId, 0, 0, 0);
    }

    /**
     * @notice Calculate loyalty bonus based on staking duration
     */
    function calculateLoyaltyBonus(uint256 stakingDuration) internal view returns (uint256 bonus) {
        StakingStorage storage ss = stakingStorage();
        LoyaltyBonusConfig storage config = ss.loyaltyBonusConfig;
        
        if (!config.enabled || stakingDuration == 0) {
            return 0;
        }
        
        // Use configured thresholds if available
        if (config.durationThresholds.length > 0 && 
            config.durationThresholds.length == config.bonusPercentages.length) {
            
            // Find the highest threshold that applies
            for (uint256 i = config.durationThresholds.length; i > 0; i--) {
                if (stakingDuration >= config.durationThresholds[i - 1]) {
                    bonus = config.bonusPercentages[i - 1];
                    break;
                }
            }
            
            // Apply maximum limit
            if (bonus > config.maxLoyaltyBonus) {
                bonus = config.maxLoyaltyBonus;
            }
            
            return bonus;
        }
        
        // Fallback to original hardcoded logic for backward compatibility
        if (!ss.loyaltyProgramEnabled || stakingDuration == 0) {
            return 0;
        }
        
        uint256 stakingDays = stakingDuration / SECONDS_PER_DAY;
        
        // Check storage thresholds first
        if (ss.settings.loyaltyBonusThresholds[365] > 0 && stakingDays >= 365) {
            return ss.settings.loyaltyBonusThresholds[365];
        }
        if (ss.settings.loyaltyBonusThresholds[180] > 0 && stakingDays >= 180) {
            return ss.settings.loyaltyBonusThresholds[180];
        }
        if (ss.settings.loyaltyBonusThresholds[90] > 0 && stakingDays >= 90) {
            return ss.settings.loyaltyBonusThresholds[90];
        }
        if (ss.settings.loyaltyBonusThresholds[30] > 0 && stakingDays >= 30) {
            return ss.settings.loyaltyBonusThresholds[30];
        }
        
        // Final fallback to hardcoded values
        if (stakingDays >= 365) return 25;
        if (stakingDays >= 180) return 15;
        if (stakingDays >= 90) return 10;
        if (stakingDays >= 30) return 5;
        
        return 0;
    }

    /**
     * @notice Calculate wear penalty using configurable thresholds
     */
    function calculateWearPenalty(uint8 wearLevel) internal view returns (uint256 penalty) {
        if (wearLevel == 0) {
            return 0;
        }
        
        StakingStorage storage ss = stakingStorage();
        WearPenaltyConfig storage config = ss.wearPenaltyConfig;
        
        // Use configurable thresholds if enabled and properly configured
        if (config.useConfigurableThresholds && 
            config.wearThresholds.length > 0 && 
            config.wearThresholds.length == config.wearPenalties.length) {
            
            penalty = 0;
            
            // Find the highest threshold that applies
            for (uint256 i = 0; i < config.wearThresholds.length; i++) {
                if (wearLevel >= config.wearThresholds[i]) {
                    penalty = config.wearPenalties[i];
                }
            }
            
            // Apply maximum limit
            if (penalty > config.maxWearPenalty) {
                penalty = config.maxWearPenalty;
            }
            
            return penalty;
        }
        
        // Fallback to storage arrays
        if (ss.wearPenaltyThresholds.length > 0 && ss.wearPenaltyThresholds.length == ss.wearPenaltyValues.length) {
            penalty = 0;
            
            for (uint256 i = 0; i < ss.wearPenaltyThresholds.length; i++) {
                if (wearLevel >= ss.wearPenaltyThresholds[i]) {
                    penalty = ss.wearPenaltyValues[i];
                }
            }
            
            return penalty;
        }
        
        // Final fallback to hardcoded values
        if (wearLevel >= 90) return 45;
        if (wearLevel >= 80) return 35;
        if (wearLevel >= 70) return 25;
        if (wearLevel >= 60) return 18;
        if (wearLevel >= 50) return 12;
        if (wearLevel >= 40) return 8;
        if (wearLevel >= 30) return 5;
        if (wearLevel >= 20) return 3;
        if (wearLevel >= 10) return 1;
        return 0;
    }

    /**
     * @notice Calculate rewards using RewardCalculator
     */
    function calculateRewards(uint256 collectionId, uint256 tokenId) internal view returns (uint256 amount) {
        RewardCalcData memory data = getUnifiedTokenRewardData(collectionId, tokenId);
        return RewardCalculator.calculateRewardFromData(data);
    }

    /**
     * @notice Enhanced reward calculation with proper balance adjustment
     */
    function calculateRewardsEnhanced(uint256 collectionId, uint256 tokenId) internal view returns (uint256 amount) {
        return calculateRewards(collectionId, tokenId);
    }

    /**
     * @notice Calculate infusion rewards with proper precision
     */
    function calculateInfusionRewards(uint256 collectionId, uint256 tokenId) internal view returns (uint256 amount) {
        InfusionCalcData memory data = getUnifiedInfusionRewardData(collectionId, tokenId);
        return RewardCalculator.calculateInfusionRewardFromData(data);
    }

    /**
     * @notice Calculate weighted colony bonus based on member characteristics
     */
    function calculateWeightedColonyBonus(
        StakingStorage storage ss,
        bytes32 colonyId,
        uint256,
        uint256,
        uint256
    ) internal view returns (uint256 bonus) {
        // Check if explicit bonus is set - use it if available
        if (ss.colonies[colonyId].stakingBonus > 0) {
            bonus = ss.colonies[colonyId].stakingBonus;
        } else if (ss.colonyStakingBonuses[colonyId] > 0) {
            bonus = ss.colonyStakingBonuses[colonyId];
        } else {
            // No explicit bonus - calculate based on colony members
            bonus = calculateDynamicColonyBonus(ss, colonyId);
        }

        // Process bonus according to rules using the RewardCalculator
        bonus = RewardCalculator.processColonyBonus(
            bonus,
            getMaxCreatorBonusPercentage()
        );
        
        return bonus;
    }

    /**
     * @notice Calculate dynamic colony bonus based on deterministic member analysis
     */
    function calculateDynamicColonyBonus(
        StakingStorage storage ss,
        bytes32 colonyId
    ) internal view returns (uint256 bonus) {
        // Start with base bonus
        bonus = 10; // Default 10% base
        
        // Get colony members
        uint256[] storage members = ss.colonyMembers[colonyId];
        if (members.length == 0) {
            return bonus; // Empty colony - return minimal bonus
        }
        
        // Deterministic sampling logic
        uint256 maxSamples = members.length < 10 ? members.length : 10;
        
        // Tracking variables
        uint256 totalCalibrationScore = 0;
        uint256 totalAccessoryScore = 0;
        uint256 totalVariantScore = 0;
        uint256 validSampleCount = 0;
        
        // Variant tracking for diversity bonus
        uint8[5] memory variantCounts = [0, 0, 0, 0, 0];
        uint8 uniqueVariantsCount = 0;
        
        // Replace random sampling with deterministic selection
        for (uint256 i = 0; i < maxSamples; i++) {
            // Select members at equally spaced intervals throughout the array
            uint256 sampleIndex = (i * members.length) / maxSamples;
            if (sampleIndex >= members.length) sampleIndex = members.length - 1;
            
            uint256 memberCombinedId = members[sampleIndex];
            (uint256 memberCollectionId, uint256 memberTokenId) = PodsUtils.extractIds(memberCombinedId);
            StakedSpecimen storage member = ss.stakedSpecimens[memberCombinedId];
            
            // Skip invalid members
            if (!member.staked) continue;
            
            // Calculate scores
            uint256 calibrationScore = calculateBalancedCalibrationScore(member.level, member.variant);
            uint256 accessoryScore = getSimplifiedAccessoryScore(ss, memberCollectionId, memberTokenId);
            uint256 variantScore = calculateProgressiveVariantScore(member.variant);
            
            totalCalibrationScore += calibrationScore;
            totalAccessoryScore += accessoryScore;
            totalVariantScore += variantScore;
            validSampleCount++;
            
            // Track variant distribution
            if (member.variant >= 1 && member.variant <= 4) {
                if (variantCounts[member.variant] == 0) {
                    uniqueVariantsCount++;
                }
                variantCounts[member.variant]++;
            }
        }
        
        if (validSampleCount == 0) {
            return bonus;
        }
        
        uint256 avgCalibrationScore = totalCalibrationScore / validSampleCount;
        uint256 avgAccessoryScore = totalAccessoryScore / validSampleCount;
        uint256 avgVariantScore = totalVariantScore / validSampleCount;
        
        uint256 calibrationContribution = (avgCalibrationScore * 45) / 100;
        uint256 accessoryContribution = (avgAccessoryScore * 30) / 100;
        uint256 variantContribution = (avgVariantScore * 25) / 100;
        
        uint256 additionalBonus = calibrationContribution + accessoryContribution + variantContribution;
        
        // Add diversity bonus (0-5%)
        uint256 diversityBonus = 0;
        if (validSampleCount >= 3) {
            if (uniqueVariantsCount >= 4) {
                diversityBonus = 5; // All 4 variants present
            } else if (uniqueVariantsCount == 3) {
                diversityBonus = 3; // 3 different variants
            } else if (uniqueVariantsCount == 2) {
                diversityBonus = 1; // 2 different variants
            }
        }
        
        // Cap total additional bonus (including diversity) at 40%
        uint256 totalAdditionalBonus = additionalBonus + diversityBonus;
        totalAdditionalBonus = totalAdditionalBonus > 40 ? 40 : totalAdditionalBonus;
        
        // Add to base bonus
        bonus += totalAdditionalBonus;
        
        return bonus;
    }

    /**
     * @notice Calculate balanced calibration score with reduced variant impact
     */
    function calculateBalancedCalibrationScore(uint8 level, uint8 variant) private pure returns (uint256) {
        uint256 baseScore = level/10; // 0-10 points based on level
        uint256 variantBonus = (variant * 3) / 2;
        return baseScore + variantBonus; // Range 0-16
    }

    /**
     * @notice Calculate progressive variant score with non-linear scaling
     */
    function calculateProgressiveVariantScore(uint8 variant) private pure returns (uint256) {
        if (variant == 1) return 3;
        else if (variant == 2) return 7;
        else if (variant == 3) return 12;
        else if (variant == 4) return 18;
        else return 3; // Default to variant 1 for invalid values
    }

    /**
     * @notice Get simplified accessory score
     */
    function getSimplifiedAccessoryScore(
        StakingStorage storage ss,
        uint256 collectionId,
        uint256 tokenId
    ) private view returns (uint256 score) {
        ChargeAccessory[] memory accessories = getTokenAccessories(ss, collectionId, tokenId);
        
        score = 0;
        for (uint256 i = 0; i < accessories.length; i++) {
            score += 2; // Base points per accessory
            
            if (accessories[i].rare) {
                score += 3; // Bonus points for rare accessory
            }
        }
        
        return score; // Typical range 0-15
    }

    /**
     * @notice Get token reward data for calculating rewards
     */
    function getTokenRewardData(uint256 collectionId, uint256 tokenId) 
        internal view 
        returns (
            uint256 baseReward,
            uint8 level,
            uint8 variant,
            uint8 chargeLevel,
            uint8 infusionLevel,
            uint8 specialization,
            uint256 colonyBonus,
            uint256 seasonMultiplier,
            uint8 wearLevel,
            uint256 loyaltyBonus
        ) 
    {
        // Using the optimized RewardCalcData structure
        RewardCalcData memory data = getUnifiedTokenRewardData(collectionId, tokenId);
        
        return (
            data.baseReward,
            data.level,
            data.variant,
            data.chargeLevel,
            data.infusionLevel,
            data.specialization,
            data.colonyBonus,
            data.seasonMultiplier,
            data.wearLevel,
            data.loyaltyBonus
        );
    }

    /**
     * @notice Get infusion reward data
     */
    function getInfusionRewardData(uint256 collectionId, uint256 tokenId)
        internal view
        returns (
            uint256 infusedAmount,
            uint256 apr,
            uint256 timeElapsed,
            uint8 intelligence,
            uint8 wearLevel
        )
    {
        // Using the optimized InfusionCalcData structure
        InfusionCalcData memory data = getUnifiedInfusionRewardData(collectionId, tokenId);
        
        return (
            data.infusedAmount,
            data.apr,
            data.timeElapsed,
            data.intelligence,
            data.wearLevel
        );
    }

    /**
     * @notice Calculate current wear level with time considerations
     */
    function calculateCurrentWear(uint256 collectionId, uint256 tokenId) internal view returns (uint256) {
        StakingStorage storage ss = stakingStorage();
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        // Skip if not staked
        if (!staked.staked) {
            return 0;
        }
        
        // Get current wear level
        uint256 currentWear = staked.wearLevel;
        
        // Skip if wear increase rate is 0
        if (ss.wearIncreasePerDay == 0) {
            return currentWear;
        }
        
        // Calculate time elapsed since last wear update
        uint256 timeElapsed = block.timestamp - staked.lastWearUpdateTime;
        
        // Skip if no time elapsed
        if (timeElapsed == 0) {
            return currentWear;
        }
        
        // Calculate wear increase based on daily rate
        uint256 wearIncrease = (timeElapsed * ss.wearIncreasePerDay) / SECONDS_PER_DAY;
        
        if (wearIncrease > 0) {
            currentWear += wearIncrease;
            
            // Cap at maximum wear level
            if (currentWear > MAX_WEAR_LEVEL) {
                currentWear = MAX_WEAR_LEVEL;
            }
        }
        
        return currentWear;
    }

    /**
     * @notice Check if a colony exists through multiple indicators
     */
    function isColonyValid(StakingStorage storage ss, bytes32 colonyId) internal view returns (bool valid) {
        // Check existence through multiple indicators for resilience
        if (ss.colonies[colonyId].stakingBonus > 0) {
            return true;
        }
        
        if (ss.colonyStakingBonuses[colonyId] > 0) {
            return true;
        }
        
        if (ss.colonyStats[colonyId].memberCount > 0) {
            return true;
        }
        
        // Check if colony has any members
        if (ss.colonyMembers[colonyId].length > 0) {
            return true;
        }
        
        // Additional check for colony name
        if (bytes(ss.colonyNameById[colonyId]).length > 0) {
            return true;
        }
        
        return false;
    }

    /**
     * @notice Retrieves collection address based on ID
     */
    function getCollectionAddress(uint256 collectionId) internal view returns (address collectionAddress) {
        StakingStorage storage ss = stakingStorage();
        
        if (collectionId == 0 || collectionId > ss.collectionCounter) {
            return address(0);
        }
        
        return ss.collections[collectionId].collectionAddress;
    }

    /**
     * @notice Retrieves collection ID based on address
     */
    function getCollectionId(address collectionAddress) internal view returns (uint256 collectionId) {
        StakingStorage storage ss = stakingStorage();
        
        if (collectionAddress == address(0)) {
            return 0;
        }
        
        uint16 id = ss.collectionIndexes[collectionAddress];
        
        // Additional verification that the index actually points to this address
        if (id != 0 && ss.collections[id].collectionAddress == collectionAddress) {
            return id;
        }
        
        return 0;
    }

    /**
     * @notice Retrieves reference to collection with validation
     */
    function getCollection(uint256 collectionId) internal view returns (SpecimenCollection storage collection) {
        StakingStorage storage ss = stakingStorage();
        
        // Basic validation
        if (collectionId == 0 || collectionId > ss.collectionCounter) {
            revert InvalidCollectionId(collectionId);
        }
        
        collection = ss.collections[collectionId];
        
        // Check if collection exists
        if (collection.collectionAddress == address(0)) {
            revert CollectionNotFound(collectionId);
        }
        
        return collection;
    }

    /**
     * @notice Add staker to active stakers list if not already there
     */
    function addActiveStaker(address staker) internal {
        StakingStorage storage ss = stakingStorage();
        
        // Add to active stakers only if not already tracked
        if (!ss.isActiveStaker[staker]) {
            ss.activeStakers.push(staker);
            ss.isActiveStaker[staker] = true;
        }
        
        // Increment token count for this staker
        ss.stakerTokenCount[staker]++;
    }

    /**
     * @notice Remove staker from active stakers if they have no more tokens staked
     */
    function removeActiveStakerIfEmpty(address staker) internal {
        StakingStorage storage ss = stakingStorage();
        
        // Decrement token count
        if (ss.stakerTokenCount[staker] > 0) {
            ss.stakerTokenCount[staker]--;
        }
        
        // If staker has no more tokens, remove from active stakers
        if (ss.stakerTokenCount[staker] == 0 && ss.isActiveStaker[staker]) {
            // Find and remove from active stakers array
            for (uint256 i = 0; i < ss.activeStakers.length; i++) {
                if (ss.activeStakers[i] == staker) {
                    // Swap with last element and pop
                    ss.activeStakers[i] = ss.activeStakers[ss.activeStakers.length - 1];
                    ss.activeStakers.pop();
                    break;
                }
            }
            
            // Update tracking map
            ss.isActiveStaker[staker] = false;
        }
    }

    /**
     * @notice Synchronize colony statistics between the separate and composed structures
     */
    function syncColonyStats(bytes32 colonyId) internal {
        StakingStorage storage ss = stakingStorage();
        
        // Check if colony exists
        if (!ss.colonyActive[colonyId]) {
            return;
        }
        
        // Two-way synchronization
        ss.colonies[colonyId].stats.memberCount = ss.colonyStats[colonyId].memberCount;
        ss.colonies[colonyId].stats.totalActiveMembers = ss.colonyStats[colonyId].totalActiveMembers;
        ss.colonies[colonyId].stats.totalStakedAmount = ss.colonyStats[colonyId].totalStakedAmount;
        ss.colonies[colonyId].stats.priorityStatus = ss.colonyStats[colonyId].priorityStatus;
        ss.colonies[colonyId].stats.ageInDays = ss.colonyStats[colonyId].ageInDays;
        ss.colonies[colonyId].stats.totalPower = ss.colonyStats[colonyId].totalPower;
        
        // Then update the legacy colonyStats from Colony.stats for backward compatibility
        ss.colonyStats[colonyId] = ss.colonies[colonyId].stats;
        
        // Update additional fields in Colony from other mappings for completeness
        ss.colonies[colonyId].name = ss.colonyNameById[colonyId];
        ss.colonies[colonyId].creator = ss.colonyCreators[colonyId];
        ss.colonies[colonyId].active = ss.colonyActive[colonyId];
        ss.colonies[colonyId].stakingBonus = ss.colonyStakingBonuses[colonyId];
    }

    /**
     * @notice Get current wear level with consistent handling across view and state-changing functions
     */
    function getCurrentWearLevel(
        uint256 collectionId, 
        uint256 tokenId, 
        bool
    ) internal view returns (uint256 currentWear) {
        StakingStorage storage ss = stakingStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        if (!staked.staked) {
            return 0;
        }
        
        // STRATEGY 1: Try to get from Biopod (most reliable source)
        SpecimenCollection storage collection = ss.collections[collectionId];
        if (collection.biopodAddress != address(0)) {
            try IExternalBiopod(collection.biopodAddress).probeCalibration(collectionId, tokenId) returns (Calibration memory cal) {
                // Apply wear resistance from accessories
                currentWear = LibBiopodIntegration.applyWearResistanceToLevel(collectionId, tokenId, cal.wear);
                return currentWear;
            } catch {
                // Continue to next strategy
            }
        }
        
        // STRATEGY 2: Use stored wear level (reliable)
        currentWear = staked.wearLevel;
        
        // STRATEGY 3: Only add time-based wear if it's been a significant time
        // and only if wear increase rate is configured
        if (ss.wearIncreasePerDay > 0) {
            uint256 timeElapsed = block.timestamp - staked.lastWearUpdateTime;
            
            // Only apply time-based increase if more than 1 hour has passed
            // This prevents micro-fluctuations during operations
            if (timeElapsed > 3600) { // 1 hour minimum
                uint256 wearIncrease = (timeElapsed * ss.wearIncreasePerDay) / SECONDS_PER_DAY;
                currentWear = currentWear + wearIncrease;
                
                // Cap at maximum
                if (currentWear > MAX_WEAR_LEVEL) {
                    currentWear = MAX_WEAR_LEVEL;
                }
            }
        }
        
        return currentWear;
    }

    /**
     * @notice Get stored wear level from staked specimen
     */
    function getStoredWearLevel(uint256 collectionId, uint256 tokenId) internal view returns (uint256) {
        StakingStorage storage ss = stakingStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        if (!staked.staked) {
            return 0;
        }
        
        return staked.wearLevel;
    }

    // =================== CACHE FUNCTIONS ===================

    /**
     * @notice Check if cache is valid for a given token
     * @param combinedId Combined token ID
     * @return valid Whether cache is valid
     */
    function isCacheValid(uint256 combinedId) internal view returns (bool) {
        StakingStorage storage ss = stakingStorage();
        uint256 timestamp = ss.cacheTimestamps[combinedId];
        uint256 cacheValidityPeriod = (ss.cacheValidityPeriod != 0 ? ss.cacheValidityPeriod : 600); // 10 minutes default
        return timestamp > 0 && (block.timestamp - timestamp) < cacheValidityPeriod;
    }

    /**
     * @notice Update cache with new value
     * @param combinedId Combined token ID
     * @param value Value to cache
     */
    function updateCache(uint256 combinedId, uint256 value) internal {
        StakingStorage storage ss = stakingStorage();
        ss.cachedAccessoryBonuses[combinedId] = value;
        ss.cacheTimestamps[combinedId] = block.timestamp;
    }

    /**
     * @notice Get cached accessory bonus if valid
     * @param combinedId Combined token ID
     * @return bonus Cached bonus value
     * @return valid Whether cache is valid
     */
    function getCachedAccessoryBonus(uint256 combinedId) internal view returns (uint256 bonus, bool valid) {
        StakingStorage storage ss = stakingStorage();
        
        if (isCacheValid(combinedId)) {
            return (ss.cachedAccessoryBonuses[combinedId], true);
        }
        
        return (0, false);
    }

    /**
     * @notice Initialize cache system
     */
    function initializeCacheSystem() internal {
        StakingStorage storage ss = stakingStorage();
        
        // Only initialize if not already set
        if (ss.cacheValidityPeriod == 0) {
            ss.cacheValidityPeriod = 600; // 30 minutes default
        }
    }

    /**
     * @notice Clear cache for specific token
     */
    function clearCache(uint256 combinedId) internal {
        StakingStorage storage ss = stakingStorage();
        ss.cachedAccessoryBonuses[combinedId] = 0;
        ss.cacheTimestamps[combinedId] = 0;
    }

    /**
     * @notice Batch clear cache for multiple tokens
     */
    function batchClearCache(uint256[] memory combinedIds) internal {
        StakingStorage storage ss = stakingStorage();
        
        for (uint256 i = 0; i < combinedIds.length; i++) {
            ss.cachedAccessoryBonuses[combinedIds[i]] = 0;
            ss.cacheTimestamps[combinedIds[i]] = 0;
        }
    }

    /**
     * @notice Check and consume shared daily limit for YLW (swap + claim combined)
     * @param ss Storage reference
     * @param user User address
     * @param amount Amount to use
     * @return success Whether the limit check passed
     * @return remaining Remaining limit after consumption
     */
    function checkAndConsumeYlwLimit(
        StakingStorage storage ss,
        address user,
        uint256 amount
    ) internal returns (bool success, uint256 remaining) {
        uint256 DAILY_REWARD_TOKEN_LIMIT = 20000 ether; // 20,000 reward tokens per day
        uint256 currentDay = block.timestamp / 1 days;

        uint256 used = ss.userDailyRewardTokenUsed[user][currentDay];
        uint256 available = used >= DAILY_REWARD_TOKEN_LIMIT ? 0 : DAILY_REWARD_TOKEN_LIMIT - used;

        if (amount > available) {
            return (false, available);
        }

        ss.userDailyRewardTokenUsed[user][currentDay] = used + amount;
        remaining = available - amount;
        success = true;
    }

    /**
     * @notice Get available YLW limit for user today
     * @param ss Storage reference
     * @param user User address
     * @return available Available limit remaining
     */
    function getAvailableYlwLimit(
        StakingStorage storage ss,
        address user
    ) internal view returns (uint256 available) {
        uint256 DAILY_REWARD_TOKEN_LIMIT = 20000 ether; // 20,000 reward tokens per day
        uint256 currentDay = block.timestamp / 1 days;

        uint256 used = ss.userDailyRewardTokenUsed[user][currentDay];
        return used >= DAILY_REWARD_TOKEN_LIMIT ? 0 : DAILY_REWARD_TOKEN_LIMIT - used;
    }

    // =================== RECEIPT TOKEN HELPERS ===================

    /**
     * @notice Check if a staked token has an associated receipt token
     * @param combinedId Combined collection+token ID
     * @return hasReceipt True if token has an active receipt
     */
    function tokenHasReceipt(uint256 combinedId) internal view returns (bool hasReceipt) {
        StakingStorage storage ss = stakingStorage();
        return ss.hasReceiptToken[combinedId];
    }

    /**
     * @notice Get receipt ID for a staked token
     * @param combinedId Combined collection+token ID
     * @return receiptId The receipt token ID (0 if none)
     */
    function getReceiptId(uint256 combinedId) internal view returns (uint256 receiptId) {
        StakingStorage storage ss = stakingStorage();
        return ss.combinedIdToReceiptId[combinedId];
    }

    /**
     * @notice Require that a token does not have a receipt
     * @dev Reverts with TokenHasReceipt if token has an active receipt
     * @param combinedId Combined collection+token ID
     */
    function requireNoReceipt(uint256 combinedId) internal view {
        StakingStorage storage ss = stakingStorage();
        if (ss.hasReceiptToken[combinedId]) {
            revert TokenHasReceipt(combinedId, ss.combinedIdToReceiptId[combinedId]);
        }
    }

    /**
     * @notice Get the staked token combinedId from a receipt ID
     * @param receiptId Receipt token ID
     * @return combinedId Combined collection+token ID (0 if not found)
     */
    function getCombinedIdFromReceipt(uint256 receiptId) internal view returns (uint256 combinedId) {
        StakingStorage storage ss = stakingStorage();
        return ss.receiptIdToCombinedId[receiptId];
    }

    /**
     * @notice Register a receipt token for a staked position
     * @param combinedId Combined collection+token ID
     * @param receiptId Receipt token ID
     */
    function registerReceipt(uint256 combinedId, uint256 receiptId) internal {
        StakingStorage storage ss = stakingStorage();
        ss.combinedIdToReceiptId[combinedId] = receiptId;
        ss.receiptIdToCombinedId[receiptId] = combinedId;
        ss.hasReceiptToken[combinedId] = true;
    }

    /**
     * @notice Unregister a receipt token when burned
     * @param combinedId Combined collection+token ID
     * @param receiptId Receipt token ID
     */
    function unregisterReceipt(uint256 combinedId, uint256 receiptId) internal {
        StakingStorage storage ss = stakingStorage();
        delete ss.combinedIdToReceiptId[combinedId];
        delete ss.receiptIdToCombinedId[receiptId];
        ss.hasReceiptToken[combinedId] = false;
    }

    /**
     * @notice Get next receipt token ID and increment counter
     * @return receiptId The next available receipt ID
     */
    function getNextReceiptId() internal returns (uint256 receiptId) {
        StakingStorage storage ss = stakingStorage();
        receiptId = ++ss.receiptTokenCounter;
    }

    /**
     * @notice Check if a token's receipt has been transferred to another owner
     * @dev Returns true if token has receipt AND receipt owner != expectedOwner
     *      This allows original staker to claim normally until receipt is sold
     * @param combinedId Combined collection+token ID
     * @param expectedOwner Address expected to own the receipt (usually the claimer)
     * @return transferred True if receipt exists and belongs to someone else
     */
    function isReceiptTransferred(uint256 combinedId, address expectedOwner) internal view returns (bool transferred) {
        StakingStorage storage ss = stakingStorage();

        // No receipt = not transferred
        if (!ss.hasReceiptToken[combinedId]) {
            return false;
        }

        // No receipt contract configured = not transferred
        if (ss.receiptTokenContract == address(0)) {
            return false;
        }

        uint256 receiptId = ss.combinedIdToReceiptId[combinedId];
        if (receiptId == 0) {
            return false;
        }

        // Check receipt owner - use try/catch in case receipt was burned
        try IERC721(ss.receiptTokenContract).ownerOf(receiptId) returns (address receiptOwner) {
            return receiptOwner != expectedOwner;
        } catch {
            // Receipt might be burned or invalid - treat as not transferred
            return false;
        }
    }

    /**
     * @notice Get receipt token contract address
     * @return contractAddress The receipt token contract address
     */
    function getReceiptTokenContract() internal view returns (address contractAddress) {
        StakingStorage storage ss = stakingStorage();
        return ss.receiptTokenContract;
    }

    /**
     * @notice Set receipt token contract address
     * @param contractAddress The receipt token contract address
     */
    function setReceiptTokenContract(address contractAddress) internal {
        StakingStorage storage ss = stakingStorage();
        ss.receiptTokenContract = contractAddress;
    }

}