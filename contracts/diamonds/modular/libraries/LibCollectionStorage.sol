// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {PodsUtils} from "../utils/PodsUtils.sol";
import {ModularConfigData, ModularConfigIndices, TokenAsset, EquippablePart, CatalogAsset, CompositionLayer, CompositionRequest, CrossCollectionPermission, ExternalCollection, AccessoryDefinition, AccessoryEffects, CollectionType, AssetCombination} from "./ModularAssetModel.sol";
import {IssueInfo, ItemTier, TierVariant, TraitPack} from "./CollectionModel.sol";

/**
 * @title LibCollectionStorage - FIXED: Minimal Changes for Collection-Tier System
 * @notice Diamond-safe storage library with minimal required changes for collection-tier support
 * @dev Production-ready storage with targeted fixes only where necessary
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 * @custom:version 4.1.0 - Minimal collection-tier fixes
 */
library LibCollectionStorage {
    
    bytes32 constant COLLECTION_STORAGE_POSITION = keccak256("diamond.standard.collection.storage.v1");

    uint8 private constant DEFAULT_PRICE_DECIMALS = 8;
    uint256 private constant PRICE_STALENESS_THRESHOLD = 1 hours;

    // ==================== ROLLING SYSTEM STRUCTS ====================
    
    struct MintingConfig {
        uint256 startTime;
        uint256 endTime;
        uint8 defaultVariant;
        bool isActive;
        uint256 maxMints;
        uint256 currentMints;
        bool allowRolling;          
        bool randomMint;   
    }

    struct AssignmentPricing {
        uint256 regular;
        uint256 discounted;
        IERC20 currency;
        address beneficiary;
        bool onSale;
        bool isActive;
    }

    struct VariantMultiplier {
        uint8 variant;
        uint256 colonyMultiplier;      
        uint256 seasonalMultiplier;    
        uint256 crossSystemMultiplier; 
        bool active;
    }
    
    struct RollingConfiguration {
        uint256 reservationTimeSeconds;
        uint8 maxRerollsPerUser;
        uint256 randomMintCooldown;
        bool enabled;
    }

    struct CouponConfiguration {
        uint256 maxRollsPerCoupon;
        uint256 freeRollsPerCoupon;
        bool rateLimitingEnabled;
        uint256 cooldownBetweenRolls;
    }

    struct RollingPricing {
        uint256 regular;
        uint256 discounted;
        bool chargeNative;
        IERC20 currency;
        address beneficiary;
        bool onSale;
        bool isActive;
        bool useExchangeRate;
    }

    struct MintPricing {
        uint256 regular;
        uint256 discounted;
        bool chargeNative;
        IERC20 currency;
        address beneficiary;
        bool onSale;
        bool isActive;
        uint256 freeMints;
        bool useExchangeRate;
        uint256 maxMints;
        uint256 maxMintsPerWallet;  // NEW: Collection-wide wallet limit per tier
    }

    struct CouponCollection {
        address collectionAddress;
        uint256 collectionId;
        address stakingContract;
        bool stakingIntegration;
        bool requireStaking;
        uint8[] excludedVariants;
        bool active;
        bool allowSelfRolling;  // true = allows variant 0 (self-rolling), false = requires variant > 0 (coupon)
    }

    struct RollCoupon {
        uint256 collectionId;
        uint256 tokenId;
        uint256 usedRolls;
        uint256 freeRollsUsed;
        uint256 totalRollsEver;
        uint256 lastRollTime;
        bool active;
    }

    struct VariantRoll {
        address user;
        uint8 variant;
        uint256 expiresAt;
        uint8 rerollsUsed;
        bool exists;
        uint256 issueId; 
        uint8 tier;
        uint256 couponCollectionId;
        uint256 couponTokenId;
        uint256 totalPaid;
        uint256 nonce;
    }

    struct TempReservation {
        bytes32 rollHash;
        uint256 expiresAt;
        bool active;
    }

    struct MintedToken {
        uint256 tokenId;
        uint8 variant;
        address recipient;
        uint256 mintTime;
        uint256 couponCollectionId;
        uint256 couponTokenId;
    }

    // ==================== SYSTEM CONFIGURATION STRUCTS ====================

    struct ControlFee {
        address currency; 
        uint256 amount; 
        address beneficiary;
    }

    struct SystemTreasury {
        address treasuryAddress;
        address treasuryCurrency;
    }

    struct CurrencyExchange {
        AggregatorV3Interface basePriceFeed;
        AggregatorV3Interface quotePriceFeed;
        uint8 baseDecimals;
        uint8 quoteDecimals;
        bool isActive;
        uint256 lastUpdateTime;
    }
    
    enum MetadataMode {
        Dynamic,
        Static,
        Hybrid
    }
    
    // ==================== CORE COLLECTION STRUCTS ====================
    
    struct CollectionData {
        address contractAddress;
        string name;
        string symbol;
        string description;
        CollectionType collectionType;
        bool enabled;
        
        uint256 maxSupply;
        uint256 currentSupply;
        
        MetadataMode metadataMode;
        string baseURI;
        string contractURI;
        
        uint256 defaultIssueId;
        uint8 defaultTier;
        uint8 defaultVariant;
        
        bool multiAssetEnabled;
        bool nestableEnabled;
        bool equippableEnabled;
        
        uint16 maxAssetsPerToken;
        uint16 maxChildrenPerToken;
        uint16 maxEquipmentSlots;
        
        bool externalSystemsEnabled;
        address catalogAddress;
        
        uint256 creationTime;
        uint256 lastUpdateTime;

        string animationBaseURI;  // dedicated URI for animations
        bool allowDefaultMint;    // Enable default mint for any collection type
    }
    
    struct TokenSpecimen {
        uint8 variant;
        uint8 tier;
        uint8 form;
        string formName;
        string description;
        uint8 generation;
        uint8 augmentation;
        string baseUri;
        bool defined;
        uint256 definitionTime;
    }
    
    struct AccessoryToken {
        uint8 accessoryId;
        string name;
        string description;
        string imageURI;
        uint8[] compatibleVariants;
        AccessoryProperties[] properties;
        bool defined;
        uint256 creationTime;
    }
    
    struct AccessoryProperties {
        uint8 propertyType;
        string propertyName;
        bool rare;
        uint8 chargeBoost;
        uint8 regenBoost;
        uint8 efficiencyBoost;
        uint8 kinshipBonus;
        uint8 wearResistance;
        uint8 calibrationBonus;
        uint8 stakingBoostPercentage;
        uint8 xpGainMultiplier;
    }
    
    // ==================== AUGMENT SYSTEM STRUCTS ====================

    struct AugmentAssignment {
        address augmentCollection;
        uint256 augmentTokenId;
        address specimenCollection;
        uint256 specimenTokenId;
        uint8 tier;
        uint8 specimenVariant;
        uint256 assignmentTime;
        uint256 unlockTime;
        bool active;
        uint256 totalFeePaid;
        uint8[] assignedAccessories;
        uint8 augmentVariant;
    }

    struct AugmentCollectionConfig {
        address collectionAddress;
        string name;
        string symbol;
        bool active;
        uint256 registrationTime;
        bool shared;
        uint256 maxUsagePerToken;
        uint8[] supportedVariants;
        uint8[] supportedTiers;
        address accessoryCollection;
        bool autoCreateAccessories;
        bool autoNestAccessories;
    }

    struct AugmentTokenConfig {
        uint8 tier;
        bool configured;
        uint256 maxUsage;
        uint256 currentUsage;
        bool shared;
        uint8[] customAccessories;
    }

    struct VariantAugmentConfig {
        uint8 variant;
        bool removable;
        bool configured;
        uint256 configurationTime;
    }

    struct TokenLock {
        address lockedBy;
        address lockedForCollection;
        uint256 lockedForTokenId;
        uint256 lockTime;
        uint256 unlockTime;
        bool permanentLock;
        uint256 lockFee;
        uint256 usageCount;
    }

    struct AugmentFeeConfig {
        ControlFee assignmentFee;
        ControlFee dailyLockFee;
        ControlFee extensionFee;
        ControlFee removalFee;
        uint256 maxLockDuration;
        uint256 minLockDuration;
        bool feeActive;
        bool requiresPayment;
    }

    struct AccessoryCreationRecord {
        address accessoryCollection;
        uint256 accessoryTokenId;
        address augmentCollection;
        uint256 augmentTokenId;
        uint8 accessoryId;
        address specimenCollection;
        uint256 specimenTokenId;
        uint256 creationTime;
        bool autoCreated;
        bool nested;
    }

    struct AugmentColonyBonus {
        uint8 tier;
        uint256 bonusPercentage;
        bool stackable;
        uint256 maxStackedBonus;
        bool active;
    }

    struct AugmentSeasonalMultiplier {
        uint8 tier;
        uint256 multiplier;
        uint256 seasonStart;
        uint256 seasonEnd;
        string seasonName;
        bool active;
    }

    struct AugmentCrossSystemBonus {
        uint8 tier;
        uint8 biopodBonus;
        uint8 chargepodBonus;
        uint8 stakingBonus;
        uint8 wearReduction;
        bool active;
    }

    struct AugmentEffectsCache {
        uint256 lastUpdate;
        uint256 colonyBonus;
        uint256 seasonalMultiplier;
        uint8 biopodBonus;
        uint8 chargepodBonus;
        uint8 stakingBonus;
        uint8 wearReduction;
        bool valid;
    }

    struct UsageStatistics {
        uint256 totalAssignments;
        uint256 activeAssignments;
        uint256 totalRevenue;
        uint256 averageLockDuration;
    }
    
    struct SpecimenAugment {
        address specimenCollection;
        bool assigned;
        uint8 specimenVariant;
        uint8 augmentVariant;
        uint256 specimenTokenId;
        address augmentCollection;
        uint256 augmentTokenId;
        uint256 assignedTime;
        uint8[] customAccessories;
    }

    struct AugmentConfig {
        uint8 tier;
        uint8[] accessoryIds; 
        bool shared;
        uint256 maxUsage;
        uint256 lockDuration;
    }

    struct AssignmentData {
        uint8 specimenVariant;
        bytes32 key;
    }

    struct RateLimits {
        uint256 operationCount;
        uint256 windowStart;
        uint256 lastOperation;
    }

    struct PriceFeedData {
        uint80 roundId;
        int256 price;
        uint256 timestamp;
        bool useLatest;
    }

    struct AugmentSwapFeeConfig {
        ControlFee swapFee;
        ControlFee assignFee;
        bool enabled;
        bool requiresPayment;
    }

    struct CollectionTheme {
        string themeName;           // e.g., "Henomorphs Matrix"
        string technologyBase;      // e.g., "cybernetic bio-mechanical"
        string evolutionContext;    // e.g., "digital transcendence"
        string universeContext;     // e.g., "reality matrix", "quantum realm"
        string preRevealHint;       // Hint text for pre-reveal state
        bool customNaming;          // Whether to use custom naming scheme
        uint256 createdAt;
        uint256 updatedAt;
    }

    struct VariantTheme {
        string customTechnology;    // Override technology for this variant
        string customContext;       // Override context for this variant
        string evolutionStage;      // e.g., "awakened", "evolved", "transcendent"
        string powerLevel;          // e.g., "basic", "advanced", "apex"
        bool hasCustomTheme;        // Whether variant has custom theme
    }

    // ==================== TOKEN-COLLECTION MAPPING (NEW) ====================
    
    /**
     * @dev Critical addition: Maps tokenId to its collection and tier context
     * This enables proper validation of token ownership within collection-tier system
     */
    struct TokenContext {
        uint256 collectionId;    // Which collection this token belongs to
        uint8 tier;              // Which tier this token belongs to
        address contractAddress; // Contract address for validation
        bool exists;             // Whether token context is defined
    }

    struct SelfResetPricing {
        ControlFee resetFee;       // Reuse existing ControlFee pattern
        bool isActive;             // Whether self-reset is enabled
    }

    // ==================== NEW: COLLECTION-SCOPED TRAIT PACK STRUCT ====================
    
    /**
     * @notice Collection-specific trait pack (minimal addition to existing TraitPack)
     * @dev Extends functionality without breaking Diamond storage layout
     */
    struct CollectionTraitPack {
        uint8 id;                       // Trait pack ID (unique within collection)
        uint256 collectionId;           // Parent collection ID
        string name;                    // Trait pack name
        string description;             // Description
        string baseURI;                 // Base metadata URI
        bool enabled;                   // Whether trait pack is active
        uint256 registrationTime;       // When trait pack was created
        uint8[] accessoryIds;           // Accessories in this trait pack
        uint8[] compatibleVariants;     // Compatible variants (0-255)
    }
    
    
    // ==================== MAIN STORAGE STRUCT ====================
    
    struct CollectionStorage {
        // ==================== CORE SYSTEM ====================
        address contractOwner;
        mapping(address => bool) operators;
        bool paused;

        SystemTreasury systemTreasury;
        CurrencyExchange currencyExchange;
        
        // ==================== UNIFIED COLLECTION SYSTEM ====================
        mapping(uint256 => CollectionData) collections;
        mapping(address => uint256) collectionsByAddress;
        uint256 collectionCounter;

        mapping(uint256 => ExternalCollection) externalCollections;
        mapping(address => uint256) externalCollectionsByAddress;

        mapping(address => uint256) userNonces;
        
        // ==================== ISSUE/VARIANT SYSTEM ====================
        mapping(uint256 => IssueInfo) issueInfos;
        mapping(uint256 => mapping(uint8 => ItemTier)) itemTiers;
        mapping(uint256 => uint8) tierCounters;
        mapping(uint256 => mapping(uint8 => mapping(uint8 => TierVariant))) tierVariants;
        mapping(uint256 => mapping(uint8 => mapping(uint8 => uint256))) hitVariantsCounters;
        mapping(uint256 => uint256) itemsVarianted;
        mapping(uint256 => mapping(uint8 => mapping(uint256 => uint8))) itemsVariants;

        // ==================== TOKEN DEFINITIONS ====================
        // Keep existing pattern used by CollectionFacet - [collectionId][specimenKey]
        mapping(uint256 => mapping(uint256 => TokenSpecimen)) tokenSpecimens;
        mapping(uint256 => mapping(uint256 => AccessoryToken)) accessoryTokens;
        
        // ==================== MODULAR CONFIGURATIONS ====================
        // Updated to support collection-tier pattern for modular configs
        mapping(uint256 => mapping(uint8 => mapping(uint256 => ModularConfigData))) modularConfigsData;
        mapping(uint256 => mapping(uint8 => mapping(uint256 => ModularConfigIndices))) modularConfigsIndices;
        
        // ==================== TOKEN CONTEXT MAPPING (NEW) ====================
        // Essential for validating token belongs to specific collection-tier
        mapping(uint256 => mapping(uint256 => TokenContext)) tokenContexts;
        
        // ==================== ASSETS ====================
        mapping(uint64 => TokenAsset) assetRegistry;
        uint64[] assetIds;
        mapping(uint64 => bool) assetExists;
        
        // ==================== TRAITPACKS ====================
        mapping(uint8 => TraitPack) traitPacks;
        uint8[] traitPackIds;
        mapping(uint8 => bool) traitPackExists;
        
        // ==================== PARTS AND CATALOGS ====================
        mapping(uint64 => EquippablePart) parts;
        uint64[] partIds;
        mapping(uint64 => bool) partExists;
        
        mapping(uint64 => CatalogAsset) catalogAssets;
        mapping(uint64 => bool) catalogAssetExists;
        
        mapping(uint256 => mapping(uint256 => string)) tokenURIOverrides;
        
        // ==================== EXTERNAL SYSTEMS ====================
        address biopodAddress;
        address chargepodAddress;
        address stakingSystemAddress;
        
        // ==================== ASSET MANAGEMENT ====================
        mapping(uint256 => mapping(uint64 => uint64)) assetReplacements;
        mapping(uint256 => mapping(uint64 => address)) validParentSlots;
        mapping(uint256 => mapping(uint256 => bytes32)) tokenColonies;
        
        // ==================== ACCESSORY DEFINITIONS ====================
        mapping(uint8 => uint8[]) traitPackCompatibleVariants;
        mapping(uint8 => uint8[]) traitPackAccessories;
        mapping(uint8 => AccessoryDefinition) accessoryDefinitions;
        mapping(uint8 => bool) accessoryExists;
        uint8[] accessoryIds;
        
        // ==================== SPECIMEN RELATIONSHIPS ====================
        mapping(bytes32 => SpecimenAugment[]) specimenAugments;
        mapping(bytes32 => bytes32) augmentToSpecimenMapping;
        mapping(uint256 => mapping(uint8 => uint8)) variantToTraitPack;

        // ==================== RATE LIMITING ====================
        mapping(address => mapping(bytes32 => mapping(uint256 => uint256))) rateLimit;
        mapping(address => mapping(bytes32 => RateLimits)) rateLimits;
        
        // ==================== AUGMENT ASSIGNMENT SYSTEM ====================
        mapping(bytes32 => AugmentAssignment) augmentAssignments;
        mapping(address => mapping(uint256 => bytes32)) specimenToAssignment;
        mapping(address => mapping(uint256 => bytes32)) augmentTokenToAssignment;

        mapping(address => AugmentCollectionConfig) augmentCollections;
        address[] registeredAugmentCollections;

        mapping(bytes32 => AugmentTokenConfig) augmentTokenConfigs;

        mapping(address => mapping(uint256 => TokenLock)) tokenLocks;

        mapping(uint8 => AugmentFeeConfig) augmentFeeConfigs;

        mapping(bytes32 => AccessoryCreationRecord) accessoryCreationRecords;
        mapping(address => mapping(uint256 => bytes32[])) specimenToAccessoryRecords;

        mapping(uint8 => uint64) accessoryToAssetMapping;
        mapping(uint8 => uint64) accessoryToSlotMapping;

        mapping(uint8 => AugmentColonyBonus) augmentColonyBonuses;
        mapping(uint8 => AugmentSeasonalMultiplier) augmentSeasonalMultipliers;
        mapping(uint8 => AugmentCrossSystemBonus) augmentCrossSystemBonuses;
        mapping(bytes32 => AugmentEffectsCache) augmentEffectsCache;

        UsageStatistics usageStats;
        mapping(uint8 => uint256) augmentUsageStats;
        mapping(address => uint256) collectionUsageStats;

        mapping(address => mapping(uint8 => mapping(uint8 => uint8[]))) tierVariantAccessories;
        mapping(address => mapping(uint8 => mapping(uint8 => bool))) tierVariantConfigured;
        
        // ==================== COMPOSITION SYSTEM ====================
        mapping(uint256 => mapping(bytes32 => uint64)) contextAssetMapping;
        mapping(uint256 => bytes32[]) tokenRenderingContexts;
        
        mapping(uint256 => mapping(uint256 => bytes32[])) tokenCompositions;
        mapping(bytes32 => string) compositionURIs;
        mapping(bytes32 => bool) compositionExists;
        mapping(bytes32 => CompositionRequest) storedCompositions;

        mapping(uint256 => mapping(uint256 => bool)) collectionCompatibility;
        mapping(uint256 => bytes32[]) collectionInterfaces;
        mapping(bytes32 => uint256[]) interfaceCollections;

        mapping(bytes32 => address[]) globalItemCompatibility;
        mapping(bytes32 => uint256) globalItemUsage;
        mapping(address => mapping(bytes32 => uint256)) collectionItemUsage;
        mapping(bytes32 => uint256) dynamicRarity;
        
        mapping(bytes32 => CompositionLayer[]) compositionLayers;
        mapping(uint256 => mapping(uint256 => uint256)) compositionCount;
        
        mapping(bytes32 => CrossCollectionPermission) crossCollectionPermissions;
        mapping(address => mapping(address => uint256)) collectionPermissionLevels;
        
        mapping(bytes32 => string) compositionCache;
        mapping(bytes32 => uint256) compositionCacheTimestamp;
        
        mapping(bytes32 => uint256) compositionComplexityScores;
        mapping(uint256 => mapping(uint256 => bytes32[])) activeCompositions;
        mapping(bytes32 => bool) compositionLocked;

        mapping(address => mapping(uint8 => VariantAugmentConfig)) variantAugmentConfigs;
        mapping(address => bool) collectionDefaultRemovable;
        mapping(address => mapping(uint8 => bool)) variantRemovabilityCache;

        mapping(uint64 => AssetCombination) assetCombinations;

        mapping(uint256 => AugmentSwapFeeConfig) augmentSwapFeeConfigs;

        // ==================== USER TRACKING ====================
        mapping(address => mapping(uint256 => mapping(uint8 => uint256))) userMintCounters;
        mapping(address => uint256) lastRandomMintTimeByUser;
        mapping(address => mapping(uint256 => mapping(uint8 => uint256))) usageCounters;

        // ==================== WHITELIST SYSTEM ====================
        mapping(uint256 => mapping(uint8 => mapping(address => uint256))) eligibleRecipients;
        mapping(uint256 => mapping(uint8 => mapping(address => uint256))) exemptedQuantities;
        mapping(uint256 => mapping(uint8 => bytes32)) merkleRoots;

        mapping(uint256 => mapping(uint8 => address[])) eligibleRecipientsList;
        mapping(uint256 => mapping(uint8 => mapping(address => uint256))) eligibleRecipientsIndex;
        mapping(uint256 => mapping(uint8 => address[])) exemptedQuantitiesList;
        mapping(uint256 => mapping(uint8 => mapping(address => uint256))) exemptedQuantitiesIndex;

        // ==================== ROLLING SYSTEM STORAGE ====================
        RollingConfiguration rollingConfiguration;
        CouponConfiguration couponConfiguration;
        
        mapping(uint256 => mapping(uint8 => RollingPricing)) rollingPricingByTier;
        mapping(uint256 => mapping(uint8 => MintPricing)) mintPricingByTier;

        mapping(uint256 => CouponCollection) couponCollections;
        
        mapping(uint256 => RollCoupon) rollCouponsByTokenId;
        mapping(bytes32 => VariantRoll) variantRollsByHash;
        mapping(bytes32 => bool) mintedRollsByHash;
        mapping(bytes32 => MintedToken) mintedTokensByHash;

        mapping(uint256 => mapping(uint8 => mapping(uint8 => TempReservation[]))) tempReservationsByVariant;
        mapping(bytes32 => uint256) rollToReservationIndexByHash;

        mapping(uint256 => mapping(uint8 => VariantMultiplier)) variantMultipliers;

        // ==================== MINTING SYSTEM STORAGE ====================
        mapping(uint256 => mapping(uint8 => MintingConfig)) mintingConfigs;
        mapping(uint256 => mapping(uint8 => AssignmentPricing)) assignmentPricingByTier;
        mapping(uint256 => mapping(uint8 => mapping(uint256 => bytes32))) tokenToRollHash;
        mapping(bytes32 => bool) assignedRollsByHash;

        // ==================== COLLECTION THEME SYSTEM ====================
        mapping(uint256 => CollectionTheme) collectionThemes;           // Collection themes
        mapping(uint256 => mapping(uint8 => mapping(uint8 => VariantTheme))) variantThemes; // Per-variant theme overrides
        mapping(uint256 => bool) collectionThemeActive;                 // Whether theme is active

        // SECRET ROLLING - nowe dedykowane pola
        mapping(uint256 => mapping(uint8 => bytes32)) secretPasswordHashes;
        mapping(uint256 => mapping(uint8 => uint256)) secretStartTimes;
        mapping(uint256 => mapping(uint8 => uint256)) publicStartTimes;
        mapping(uint256 => mapping(uint8 => mapping(address => bool))) secretUsedByUser;
        mapping(uint256 => mapping(uint8 => bool)) secretRollingActive;

        mapping(uint256 => mapping(uint8 => mapping(uint256 => bool))) secretUsedByToken;

        // DODAĆ NOWE (na końcu SECRET ROLLING sekcji):
        mapping(uint256 => mapping(uint8 => uint256)) secretEndTimes;
        mapping(uint256 => mapping(uint8 => uint256)) secretRevealTimes;
        mapping(uint256 => mapping(uint8 => bool)) secretRevealed;
        mapping(uint256 => mapping(uint8 => bytes32)) secretCommitments;

        // Per-token submission tracking:
        mapping(uint256 => mapping(uint8 => mapping(uint256 => string))) tokenSecretSubmissions;
        mapping(uint256 => mapping(uint8 => mapping(uint256 => uint256))) tokenNonceSubmissions;
        mapping(uint256 => mapping(uint8 => mapping(uint256 => address))) tokenOwnerSubmissions;

        mapping(uint256 => bytes32[]) couponActiveRolls; // combinedId → active rollHashes[]

        mapping(uint256 => mapping(uint256 => uint256)) collectionItemsVarianted;

        mapping(uint256 => mapping(uint8 => SelfResetPricing)) selfResetPricingByTier; // collectionId => tier => pricing
        mapping(uint256 => mapping(uint256 => bool)) tokenSelfResetUsed; // collectionId => tokenId => used
        mapping(uint256 => mapping(uint256 => bool)) tokenRollingUnlocked; // collectionId => tokenId => unlocked

        // ==================== AUGMENT COLLECTION RESTRICTIONS ====================

        // mainCollectionId -> augmentCollectionAddress -> allowed
        mapping(uint256 => mapping(address => bool)) allowedAugments;

        // mainCollectionId -> has restrictions enabled
        mapping(uint256 => bool) augmentRestrictions;

        // ==================== NEW: COLLECTION-SCOPED TRAIT PACK STORAGE ====================
        
        // Primary storage: collectionId => traitPackId => CollectionTraitPack
        mapping(uint256 => mapping(uint8 => CollectionTraitPack)) collectionTraitPacks;
        
        // Track existence: collectionId => traitPackId => exists
        mapping(uint256 => mapping(uint8 => bool)) collectionTraitPackExists;
        
        // List of trait pack IDs per collection: collectionId => uint8[]
        mapping(uint256 => uint8[]) collectionTraitPackIds;
        
        // Variant to trait pack mapping (collection-scoped): collectionId => variant => traitPackId
        mapping(uint256 => mapping(uint8 => uint8)) collectionVariantToTraitPack;

        // Track Main collection coupon usage (prevent double-spending)
        mapping(uint256 => mapping(uint256 => bool)) collectionCouponUsed; // collectionId => tokenId => used
    }

    // ==================== STORAGE ACCESSOR ====================

    function collectionStorage() internal pure returns (CollectionStorage storage cs) {
        bytes32 position = COLLECTION_STORAGE_POSITION;
        assembly { cs.slot := position }
    }
    
    // ==================== TOKEN CONTEXT MANAGEMENT ====================
    
    function setTokenContext(
        uint256 tokenId, 
        uint256 collectionId, 
        uint8 tier, 
        address contractAddress
    ) internal {
        CollectionStorage storage cs = collectionStorage();
        cs.tokenContexts[collectionId][tokenId] = TokenContext({
            collectionId: collectionId,
            tier: tier,
            contractAddress: contractAddress,
            exists: true
        });
    }
    
    function getTokenContext(uint256 collectionId, uint256 tokenId) internal view returns (TokenContext memory) {
        return collectionStorage().tokenContexts[collectionId][tokenId];
    }
    
    function validateTokenInCollectionTier(
        uint256 tokenId, 
        uint256 expectedCollectionId, 
        uint8 expectedTier
    ) internal view returns (bool) {
        TokenContext memory context = getTokenContext(expectedCollectionId, tokenId);
        
        if (!context.exists) {
            return false;
        }
        
        return context.collectionId == expectedCollectionId && context.tier == expectedTier;
    }
    
    // ==================== COLLECTION MANAGEMENT HELPERS ====================

    function isInternalCollection(uint256 collectionId) internal view returns (bool isInternal) {
        CollectionStorage storage cs = collectionStorage();
        return cs.collections[collectionId].enabled;
    }

    function isExternalCollection(uint256 collectionId) internal view returns (bool isExternal) {
        CollectionStorage storage cs = collectionStorage();
        return cs.externalCollections[collectionId].collectionAddress != address(0) && 
               cs.externalCollections[collectionId].enabled;
    }

    function getCollectionIdByAddress(address collectionAddress) internal view returns (uint256 collectionId) {
        CollectionStorage storage cs = collectionStorage();
        
        collectionId = cs.collectionsByAddress[collectionAddress];
        if (collectionId != 0) return collectionId;
        
        return cs.externalCollectionsByAddress[collectionAddress];
    }

    function collectionExists(uint256 collectionId) internal view returns (bool exists) {
        return isInternalCollection(collectionId) || isExternalCollection(collectionId);
    }

    function getCollectionInfo(uint256 collectionId) internal view returns (
        address contractAddress,
        uint8 defaultTier,
        bool exists
    ) {
        CollectionStorage storage cs = collectionStorage();
        
        if (isInternalCollection(collectionId)) {
            CollectionData storage collection = cs.collections[collectionId];
            return (collection.contractAddress, collection.defaultTier, true);
        }
        
        if (isExternalCollection(collectionId)) {
            ExternalCollection storage collection = cs.externalCollections[collectionId];
            uint8 tier = cs.collections[collectionId].defaultTier;
            if (tier == 0) tier = 1;
            return (collection.collectionAddress, tier, true);
        }
        
        return (address(0), 0, false);
    }

    // ==================== NEW: COLLECTION-SCOPED TRAIT PACK FUNCTIONS ====================

    /**
     * @notice Create trait pack for specific collection
     * @dev Production-ready function with comprehensive validation
     * @param collectionId Target collection ID
     * @param traitPackId Trait pack ID (unique within collection)
     * @param name Trait pack name
     * @param description Description
     * @param baseURI Base URI for metadata
     * @param accessoryIds Array of accessory IDs
     * @param compatibleVariants Array of compatible variants
     */
    function createCollectionTraitPack(
        uint256 collectionId,
        uint8 traitPackId,
        string memory name,
        string memory description,
        string memory baseURI,
        uint8[] memory accessoryIds,
        uint8[] memory compatibleVariants
    ) internal {
        CollectionStorage storage cs = collectionStorage();
        
        require(collectionExists(collectionId), "Collection does not exist");
        require(traitPackId > 0, "Invalid trait pack ID");
        require(!cs.collectionTraitPackExists[collectionId][traitPackId], "Trait pack already exists");
        require(bytes(name).length > 0 && bytes(name).length <= 50, "Invalid name length");
        
        CollectionTraitPack storage traitPack = cs.collectionTraitPacks[collectionId][traitPackId];
        traitPack.id = traitPackId;
        traitPack.collectionId = collectionId;
        traitPack.name = name;
        traitPack.description = description;
        traitPack.baseURI = baseURI;
        traitPack.enabled = true;
        traitPack.registrationTime = block.timestamp;
        traitPack.accessoryIds = accessoryIds;
        traitPack.compatibleVariants = compatibleVariants;
        
        cs.collectionTraitPackExists[collectionId][traitPackId] = true;
        cs.collectionTraitPackIds[collectionId].push(traitPackId);
    }

    /**
     * @notice Get trait pack for specific collection
     * @param collectionId Collection ID
     * @param traitPackId Trait pack ID
     * @return traitPack The trait pack data
     */
    function getCollectionTraitPack(
        uint256 collectionId, 
        uint8 traitPackId
    ) internal view returns (CollectionTraitPack memory traitPack) {
        CollectionStorage storage cs = collectionStorage();
        require(cs.collectionTraitPackExists[collectionId][traitPackId], "Trait pack does not exist");
        return cs.collectionTraitPacks[collectionId][traitPackId];
    }

    /**
     * @notice Check if collection trait pack exists
     * @param collectionId Collection ID
     * @param traitPackId Trait pack ID
     * @return exists Whether trait pack exists
     */
    function collectionTraitPackExists(
        uint256 collectionId, 
        uint8 traitPackId
    ) internal view returns (bool exists) {
        return collectionStorage().collectionTraitPackExists[collectionId][traitPackId];
    }

    /**
     * @notice Get all trait pack IDs for collection
     * @param collectionId Collection ID
     * @return traitPackIds Array of trait pack IDs
     */
    function getCollectionTraitPackIds(
        uint256 collectionId
    ) internal view returns (uint8[] memory traitPackIds) {
        return collectionStorage().collectionTraitPackIds[collectionId];
    }

    /**
     * @notice Set variant to trait pack mapping (collection-scoped)
     * @param collectionId Collection ID
     * @param variant Variant number (0-255)
     * @param traitPackId Trait pack ID (0 to clear)
     */
    function setCollectionVariantTraitPack(
        uint256 collectionId,
        uint8 variant,
        uint8 traitPackId
    ) internal {
        CollectionStorage storage cs = collectionStorage();
        
        if (traitPackId != 0) {
            require(cs.collectionTraitPackExists[collectionId][traitPackId], "Trait pack does not exist");
        }
        
        cs.collectionVariantToTraitPack[collectionId][variant] = traitPackId;
    }

    /**
     * @notice Get trait pack ID for variant (collection-scoped)
     * @param collectionId Collection ID  
     * @param variant Variant number
     * @return traitPackId Trait pack ID (0 if not set)
     */
    function getCollectionVariantTraitPack(
        uint256 collectionId,
        uint8 variant
    ) internal view returns (uint8 traitPackId) {
        return collectionStorage().collectionVariantToTraitPack[collectionId][variant];
    }

    /**
     * @notice Enable/disable collection trait pack
     * @param collectionId Collection ID
     * @param traitPackId Trait pack ID
     * @param enabled New status
     */
    function setCollectionTraitPackEnabled(
        uint256 collectionId,
        uint8 traitPackId,
        bool enabled
    ) internal {
        CollectionStorage storage cs = collectionStorage();
        require(cs.collectionTraitPackExists[collectionId][traitPackId], "Trait pack does not exist");
        
        cs.collectionTraitPacks[collectionId][traitPackId].enabled = enabled;
    }

    // ==================== EXISTING HELPER FUNCTIONS (unchanged) ====================

    function getAndIncrementNonce(address user) internal returns (uint256) {
        CollectionStorage storage cs = collectionStorage();
        uint256 currentNonce = cs.userNonces[user];
        unchecked {
            cs.userNonces[user] = currentNonce + 1;
        }
        return currentNonce;
    }

    function getCurrentNonce(address user) internal view returns (uint256) {
        return collectionStorage().userNonces[user];
    }
    
    function isMainCollection(uint256 collectionId) internal view returns (bool) {
        return collectionStorage().collections[collectionId].collectionType == CollectionType.Main;
    }
    
    function isAccessoryCollection(uint256 collectionId) internal view returns (bool) {
        CollectionType cType = collectionStorage().collections[collectionId].collectionType;
        return cType == CollectionType.Accessory;
    }
    
    function getSpecimenKey(address collection, uint256 tokenId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(collection, tokenId));
    }
    
    function getAugmentKey(address collection, uint256 tokenId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(collection, tokenId));
    }
    
    function traitPackExists(uint8 traitPackId) internal view returns (bool) {
        return collectionStorage().traitPackExists[traitPackId];
    }
    
    function accessoryExists(uint8 accessoryId) internal view returns (bool) {
        return collectionStorage().accessoryExists[accessoryId];
    }
    
    function getTraitPackCompatibleVariants(uint8 traitPackId) internal view returns (uint8[] storage) {
        return collectionStorage().traitPackCompatibleVariants[traitPackId];
    }
    
    function getTraitPackAccessories(uint8 traitPackId) internal view returns (uint8[] storage) {
        return collectionStorage().traitPackAccessories[traitPackId];
    }
    
    function getAccessoryDefinition(uint8 accessoryId) internal view returns (AccessoryDefinition storage) {
        return collectionStorage().accessoryDefinitions[accessoryId];
    }
    
    function isVariantCompatibleWithTraitPack(uint8 traitPackId, uint8 variant) internal view returns (bool) {
        uint8[] storage compatibleVariants = getTraitPackCompatibleVariants(traitPackId);
        
        if (compatibleVariants.length == 0) {
            return true;
        }
        
        for (uint256 i = 0; i < compatibleVariants.length; i++) {
            if (compatibleVariants[i] == variant) {
                return true;
            }
        }
        
        return false;
    }

    // ==================== AUGMENT HELPER FUNCTIONS ====================
    
    function assignAugmentToSpecimen(
        address specimenCollection,
        uint256 specimenTokenId,
        address augmentCollection,
        uint256 augmentTokenId,
        uint8 specimenVariant,
        uint8 augmentVariant
    ) internal {
        CollectionStorage storage cs = collectionStorage();
        
        bytes32 specimenKey = getSpecimenKey(specimenCollection, specimenTokenId);
        bytes32 augmentKey = getAugmentKey(augmentCollection, augmentTokenId);
        
        require(cs.augmentToSpecimenMapping[augmentKey] == bytes32(0), "Augment already assigned");
        
        SpecimenAugment memory augment = SpecimenAugment({
            specimenCollection: specimenCollection,
            assigned: true,
            specimenVariant: specimenVariant,
            augmentVariant: augmentVariant,
            specimenTokenId: specimenTokenId,
            augmentCollection: augmentCollection,
            augmentTokenId: augmentTokenId,
            assignedTime: block.timestamp,
            customAccessories: new uint8[](0)
        });
        
        cs.specimenAugments[specimenKey].push(augment);
        cs.augmentToSpecimenMapping[augmentKey] = specimenKey;
    }
    
    function removeAugmentFromSpecimen(
        address specimenCollection,
        uint256 specimenTokenId,
        address augmentCollection,
        uint256 augmentTokenId
    ) internal returns (bool) {
        CollectionStorage storage cs = collectionStorage();
        
        bytes32 specimenKey = getSpecimenKey(specimenCollection, specimenTokenId);
        bytes32 augmentKey = getAugmentKey(augmentCollection, augmentTokenId);
        
        SpecimenAugment[] storage augments = cs.specimenAugments[specimenKey];
        
        for (uint256 i = 0; i < augments.length; i++) {
            if (augments[i].augmentCollection == augmentCollection && 
                augments[i].augmentTokenId == augmentTokenId) {
                
                augments[i] = augments[augments.length - 1];
                augments.pop();
                
                delete cs.augmentToSpecimenMapping[augmentKey];
                return true;
            }
        }
        
        return false;
    }
    
    function getSpecimenAugments(address specimenCollection, uint256 specimenTokenId) 
        internal view returns (SpecimenAugment[] storage) {
        bytes32 specimenKey = getSpecimenKey(specimenCollection, specimenTokenId);
        return collectionStorage().specimenAugments[specimenKey];
    }
    
    function isAugmentAssigned(address augmentCollection, uint256 augmentTokenId) 
        internal view returns (bool) {
        bytes32 augmentKey = getAugmentKey(augmentCollection, augmentTokenId);
        return collectionStorage().augmentToSpecimenMapping[augmentKey] != bytes32(0);
    }

    function isVariantRemovableForCollection(address collectionAddress, uint8 variant) internal view returns (bool) {
        CollectionStorage storage cs = collectionStorage();
        
        if (cs.variantAugmentConfigs[collectionAddress][variant].configured) {
            return cs.variantRemovabilityCache[collectionAddress][variant];
        }
        
        return cs.collectionDefaultRemovable[collectionAddress];
    }

    // ==================== CURRENCY EXCHANGE FUNCTIONS ====================
    
    function derivePriceFromExchange(
        uint256 listPrice,
        uint80[2] memory rounds
    ) internal view returns (uint256 derivedPrice, uint80[2] memory usedRounds) {
        CollectionStorage storage cs = collectionStorage();
        CurrencyExchange storage exchange = cs.currencyExchange;
        
        if (!exchange.isActive || address(exchange.basePriceFeed) == address(0)) {
            return (0, [uint80(0), uint80(0)]);
        }
        
        (PriceFeedData memory baseData, PriceFeedData memory quoteData) = _getPriceFeedData(exchange, rounds);
        
        require(baseData.price > 0 && quoteData.price > 0, "Invalid exchange rates");
        
        derivedPrice = _calculateDerivedPrice(listPrice, baseData.price, quoteData.price, exchange);
        
        usedRounds = [baseData.roundId, quoteData.roundId];
    }

    function _getPriceFeedData(
        CurrencyExchange storage exchange,
        uint80[2] memory rounds
    ) private view returns (PriceFeedData memory baseData, PriceFeedData memory quoteData) {
        baseData.useLatest = true;
        quoteData.useLatest = true;
        
        if (rounds[0] != 0 && rounds[1] != 0) {
            (baseData.roundId, baseData.price,, baseData.timestamp,) = exchange.basePriceFeed.getRoundData(rounds[0]);
            (quoteData.roundId, quoteData.price,, quoteData.timestamp,) = exchange.quotePriceFeed.getRoundData(rounds[1]);
            
            uint256 staleThreshold = block.timestamp - PRICE_STALENESS_THRESHOLD;
            baseData.useLatest = (baseData.timestamp < staleThreshold);
            quoteData.useLatest = (quoteData.timestamp < staleThreshold);
        }
        
        if (baseData.useLatest) {
            (baseData.roundId, baseData.price,, baseData.timestamp,) = exchange.basePriceFeed.latestRoundData();
        }
        if (quoteData.useLatest) {
            (quoteData.roundId, quoteData.price,, quoteData.timestamp,) = exchange.quotePriceFeed.latestRoundData();
        }
    }

    function _calculateDerivedPrice(
        uint256 listPrice,
        int256 basePrice,
        int256 quotePrice,
        CurrencyExchange storage exchange
    ) private view returns (uint256 derivedPrice) {
        int256 scaledBasePrice = _scalePrice(basePrice, exchange.baseDecimals, DEFAULT_PRICE_DECIMALS);
        int256 scaledQuotePrice = _scalePrice(quotePrice, exchange.quoteDecimals, DEFAULT_PRICE_DECIMALS);
        
        int256 decimalsMultiplier = int256(10 ** uint256(DEFAULT_PRICE_DECIMALS));
        derivedPrice = (uint256(decimalsMultiplier) * listPrice) / uint256(scaledBasePrice * decimalsMultiplier / scaledQuotePrice);
    }
    
    function _scalePrice(
        int256 price,
        uint8 priceDecimals,
        uint8 targetDecimals
    ) internal pure returns (int256) {
        if (priceDecimals < targetDecimals) {
            return price * int256(10 ** uint256(targetDecimals - priceDecimals));
        } else if (priceDecimals > targetDecimals) {
            return price / int256(10 ** uint256(priceDecimals - targetDecimals));
        }
        return price;
    }
    
    function isExchangeConfigured() internal view returns (bool configured) {
        CurrencyExchange storage exchange = collectionStorage().currencyExchange;
        return exchange.isActive && 
               address(exchange.basePriceFeed) != address(0) && 
               address(exchange.quotePriceFeed) != address(0);
    }
    
    function getExchangeConfig() internal view returns (CurrencyExchange memory exchange) {
        return collectionStorage().currencyExchange;
    }

    // ==================== WHITELIST FUNCTIONS ====================

    function addEligibleRecipient(uint256 collectionId, uint8 tier, address recipient, uint256 amount) internal {
        CollectionStorage storage cs = collectionStorage();
        
        cs.eligibleRecipients[collectionId][tier][recipient] = amount;
        
        if (cs.eligibleRecipientsIndex[collectionId][tier][recipient] == 0) {
            cs.eligibleRecipientsList[collectionId][tier].push(recipient);
            cs.eligibleRecipientsIndex[collectionId][tier][recipient] = cs.eligibleRecipientsList[collectionId][tier].length;
        }
    }

    function removeEligibleRecipient(uint256 collectionId, uint8 tier, address recipient) internal returns (bool) {
        CollectionStorage storage cs = collectionStorage();
        
        uint256 indexPlusOne = cs.eligibleRecipientsIndex[collectionId][tier][recipient];
        if (indexPlusOne == 0) return false;
        
        uint256 index = indexPlusOne - 1;
        address[] storage list = cs.eligibleRecipientsList[collectionId][tier];
        
        if (index != list.length - 1) {
            address lastRecipient = list[list.length - 1];
            list[index] = lastRecipient;
            cs.eligibleRecipientsIndex[collectionId][tier][lastRecipient] = indexPlusOne;
        }
        
        list.pop();
        delete cs.eligibleRecipientsIndex[collectionId][tier][recipient];
        delete cs.eligibleRecipients[collectionId][tier][recipient];
        
        return true;
    }

    function addExemptedQuantity(uint256 collectionId, uint8 tier, address recipient, uint256 amount) internal {
        CollectionStorage storage cs = collectionStorage();
        
        cs.exemptedQuantities[collectionId][tier][recipient] = amount;
        
        if (cs.exemptedQuantitiesIndex[collectionId][tier][recipient] == 0) {
            cs.exemptedQuantitiesList[collectionId][tier].push(recipient);
            cs.exemptedQuantitiesIndex[collectionId][tier][recipient] = cs.exemptedQuantitiesList[collectionId][tier].length;
        }
    }

    function removeExemptedQuantity(uint256 collectionId, uint8 tier, address recipient) internal returns (bool) {
        CollectionStorage storage cs = collectionStorage();
        
        uint256 indexPlusOne = cs.exemptedQuantitiesIndex[collectionId][tier][recipient];
        if (indexPlusOne == 0) return false;
        
        uint256 index = indexPlusOne - 1;
        address[] storage list = cs.exemptedQuantitiesList[collectionId][tier];
        
        if (index != list.length - 1) {
            address lastRecipient = list[list.length - 1];
            list[index] = lastRecipient;
            cs.exemptedQuantitiesIndex[collectionId][tier][lastRecipient] = indexPlusOne;
        }
        
        list.pop();
        delete cs.exemptedQuantitiesIndex[collectionId][tier][recipient];
        delete cs.exemptedQuantities[collectionId][tier][recipient];
        
        return true;
    }

    function getEligibleRecipientsCount(uint256 collectionId, uint8 tier) internal view returns (uint256) {
        return collectionStorage().eligibleRecipientsList[collectionId][tier].length;
    }

    function getExemptedQuantitiesCount(uint256 collectionId, uint8 tier) internal view returns (uint256) {
        return collectionStorage().exemptedQuantitiesList[collectionId][tier].length;
    }

    function eligibleRecipientExists(uint256 collectionId, uint8 tier, address recipient) internal view returns (bool) {
        return collectionStorage().eligibleRecipientsIndex[collectionId][tier][recipient] > 0;
    }

    function exemptedQuantityExists(uint256 collectionId, uint8 tier, address recipient) internal view returns (bool) {
        return collectionStorage().exemptedQuantitiesIndex[collectionId][tier][recipient] > 0;
    }

    function getCollectionTheme(uint256 collectionId) internal view returns (CollectionTheme memory) {
        return collectionStorage().collectionThemes[collectionId];
    }

    function getVariantTheme(uint256 collectionId, uint8 tier, uint8 variant) internal view returns (VariantTheme memory) {
        return collectionStorage().variantThemes[collectionId][tier][variant];
    }

    function isThemeActive(uint256 collectionId) internal view returns (bool) {
        return collectionStorage().collectionThemeActive[collectionId];
    }

    /**
     * @notice Get total mints by wallet in collection (across all tiers)
     */
    function getTotalWalletMints(uint256 collectionId, address wallet) internal view returns (uint256 total) {
        CollectionStorage storage cs = collectionStorage();
        uint8 tierCount = cs.tierCounters[collectionId];
        
        for (uint8 tier = 1; tier <= tierCount; tier++) {
            total += cs.userMintCounters[wallet][collectionId][tier];
        }
    }
}