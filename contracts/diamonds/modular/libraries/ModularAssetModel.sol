// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TraitPack, ChargeAccessory, Specimen, Calibration} from "./CollectionModel.sol";

/**
 * @title ModularAssetModel
 * @notice Complete data structures for modular asset functionality
 * @dev Pure data model supporting RMRK 2.0 features and ModularSpecimen integration
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */

// ==================== ENUMS ====================

enum PartType {
    None,    // Not equippable
    Slot,    // Can receive other NFTs
    Fixed    // Fixed part that can't be changed
}

enum AssetType {
    Media,      // Traditional media asset
    Catalog,    // Catalog composition asset
    Hybrid      // Mixed asset type
}

enum LayerBlendMode {
    Normal,
    Multiply,
    Screen,
    Overlay,
    SoftLight,
    HardLight,
    ColorBurn,
    ColorDodge
}

// ==================== ASSET STRUCTURES ====================

struct TokenAsset {
    uint64 id;
    string assetUri;
    string thumbnailUri;
    string mediaType;
    bool pending;
    bool replaceable;
    uint256 registrationTime;
    uint8 traitPackId;
    uint8 themeId;
}

struct CatalogAsset {
    uint64 id;
    uint64 catalogId;
    uint64[] selectedParts;
    string compositionURI;
    AssetType assetType;
    bool pending;
    bool replaceable;
    uint256 registrationTime;
    bytes32[] renderingContexts;
}

struct CatalogAssetData {
    uint64 catalogId;
    uint64[] fixedParts;
    uint64[] slotParts;
    string compositionURI;
    bytes4[] zIndexes;
}

struct ModularTraitPack {
    TraitPack base;
    uint64[] assetIds;
    uint64[] partIds;
    uint8[] compatibleVariants;
    bool composable;
    bool nestable;
    string[] compatibleSlots;
}

// ==================== EQUIPMENT STRUCTURES ====================

struct EquippablePart {
    uint64 id;
    string name;
    PartType partType;
    bytes4 zIndex;
    address[] equippableAddresses;
    string metadataURI;
    bool fixedToParent;
}

struct Equipment {
    uint64 slotPartId;
    address childContract;
    uint256 childTokenId;
    uint64 assetId;
    uint256 equippedTime;
    bool isPending;
    uint8 compatibilityScore;
    int8 calibrationEffect;
}

struct EnhancedAccessory {
    ChargeAccessory base;
    uint64 assetId;
    uint64 slotPartId;
    uint64[] compatibleAssetIds;
    bool nestable;
    bool transferableIfEquipped;
}

struct AccessoryType {
    uint8 typeId;
    string name;
    uint64[] compatibleSlots;
    uint8[] compatibleTraitPacks;
    bool rare;
}

// ==================== CHILD/PARENT STRUCTURES ====================

struct ChildToken {
    address childContract;
    uint256 childTokenId;
    uint256 addedTime;
    bool transferable;
    bool accepted;
}

struct ParentToken {
    address parentContract;
    uint256 parentTokenId;
    bool isPending;
}

// ==================== COMPOSITION STRUCTURES ====================

struct CompositionLayer {
    uint256 sourceCollectionId;    // Source collection
    uint256 sourceTokenId;         // Source token (0 for collection-level)
    uint64 sourceAssetId;          // Specific asset from source
    uint64 sourcePartId;           // Specific part from catalog
    uint256 zIndex;                // Rendering order (higher = front)
    LayerBlendMode blendMode;      // How layer blends with others
    bytes32 layerType;             // "background", "character", "accessory", "effect"
    bytes compositionData;         // Additional layer-specific data
    bool active;                   // Whether layer is currently active
    uint256 activationTime;        // When layer becomes active
    uint256 deactivationTime;      // When layer becomes inactive (0 = permanent)
}

struct CompositionRequest {
    uint256 targetCollectionId;    // Target collection for composition
    uint256 targetTokenId;         // Target token for composition
    CompositionLayer[] layers;     // Layers to compose
    uint8 compositionType;         // Type of composition (0=Static, 1=Dynamic, 2=Conditional, 3=Interactive)
    string outputFormat;           // "png", "svg", "json", "metadata"
    bytes32 contextHash;           // Context identifier for caching
    address requester;             // Who requested the composition
    uint256 requestTime;           // When composition was requested
    bool persistent;               // Whether to store composition permanently
}

struct CrossCollectionPermission {
    address authorizedCollection;   // Collection authorized to compose
    address targetCollection;      // Collection that can be composed
    bytes32[] allowedOperations;   // Specific operations allowed
    uint256 permissionLevel;       // 0=None, 1=Read, 2=Compose, 3=Modify
    uint256 expirationTime;        // When permission expires (0 = permanent)
    bool active;                   // Whether permission is active
}

// ==================== STATS AND EFFECTS ====================

struct SpecimenStats {
    uint16 strengthBonus;
    uint16 agilityBonus;
    uint16 intelligenceBonus;
    uint16 xpBonus;
}

struct CalibrationEffects {
    uint256 baseDecayRate;
    uint256 decayInterval;
}

// ==================== TOKEN CONFIGURATION ====================

struct ModularConfigData {
    // MultiAsset (ERC-5773)
    uint64[] pendingAssets;
    uint64[] acceptedAssets;
    uint64 activeAssetId;
    
    // Nestable (ERC-7401)
    ChildToken[] children;
    ChildToken[] pendingChildren;
    ParentToken parent;
    
    // Trait pack extensions
    uint8[] traitPackIds;
    uint8 activeTraitPackId;
    uint8[] augmentIds;
    uint8 activeAugmentId;
    
    // Equipment (ERC-6220)
    Equipment[] equipments;
    ChargeAccessory[] equippedAccessories;
    EnhancedAccessory[] equippedEnhancedAccessories;
    uint64[] enhancedAccessoryIds;
    
    // System
    uint256 lastUpdateTime;
    bool locked;
}

struct ModularConfigIndices {
    // MultiAsset indices (1-based, 0 means not found)
    mapping(uint64 => uint256) pendingAssetIndices;
    mapping(uint64 => uint256) acceptedAssetIndices;
    
    // Nestable indices
    mapping(address => mapping(uint256 => uint256)) childIndices;
    mapping(address => mapping(uint256 => uint256)) pendingChildIndices;
    
    // Trait pack indices
    mapping(uint8 => uint256) traitPackIndices;
    
    // Equipment indices
    mapping(uint64 => uint256) slotEquipIndices;
}

// ==================== COMPLETE SPECIMEN STRUCTURE ====================

struct ModularSpecimen {
    // Core token data
    uint256 tokenId;
    Specimen specimen;
    Calibration calibration;
    
    // Modular features
    ModularConfigData modularConfig;
    
    // Feature flags
    bool isNestable;
    bool isComposable;
    uint256 lastCalibrationSync;
}

// ==================== OPERATION HELPERS ====================

struct AssetAddData {
    uint256 tokenId;
    uint64 assetId;
    uint64 replacesAssetId;
    uint8 traitPackId;
}

struct ChildAddData {
    uint256 parentTokenId;
    address childContract;
    uint256 childTokenId;
    bool asAccepted;
}

struct AugmentAssignData {
    uint256 tokenId;
    uint8 augmentId;
    bool setAsActive;
}

struct AccessoryEquipData {
    uint256 tokenId;
    uint8 accessoryType;
    uint64 slotPartId;
    uint64 assetId;
}

struct AssetPriorityConfig {
    uint64[] priorityOrder;
    bool automaticPriority;
}

// ==================== RATE LIMITING & EXTERNAL COLLECTIONS ====================

struct ExternalCollection {
    address collectionAddress;
    uint256 collectionId;
    CollectionType collectionType;
    bool isModularSpecimen; 
    uint256 registrationTime;
    bool enabled;
}

// ==================== ACCESSORY DEFINITIONS ====================

struct AccessoryDefinition {
    uint8 accessoryId;
    string name;
    string description;
    AccessoryEffects effects;
    uint8[] compatibleTraitPacks;
    bool enabled;
    uint256 creationTime;
}

struct AccessoryEffects {
    uint8 chargeBoost;
    uint8 regenBoost;
    uint8 efficiencyBoost;
    uint8 kinshipBonus;
    uint8 wearResistance;
    uint8 calibrationBonus;
    uint8 stakingBonus;
    uint8 xpMultiplier;
    bool rare;
}

// ==================== COLLECTION TYPES ====================

enum CollectionType {
    Main,           // Primary collections (characters, avatars)
    Accessory,      // Items, weapons, clothing
    Augment,        // TraitPacks, upgrades
    Modular,        // Full RMRK collections
    Catalog,        // Part definitions
    Nestable,       // Parent-child collections
    Equippable,     // Equipment collections
    Realm           // Realm collections - Mission Pass (M prefix)
}

struct AssetCombination {
    uint64 combinedAssetId;
    uint64[] sourceAssetIds;
    string combinedURI;
    uint8 combinationType; // 0=Layered, 1=Merged, 2=Contextual
    uint256 creationTime;
    bool replaceable;
}

// ==================== FOR COMPATIBILITY ====================

/**
 * @dev Structure for enhanced trait pack integrating multi-asset capabilities
 * Extends the existing TraitPack model
 */
struct EnhancedTraitPack {
    // Base trait pack from HenomorphsModel
    TraitPack base;
    
    // Multi-asset extensions
    uint64[] assetIds;           // Associated asset IDs
    uint64[] partIds;            // Associated part IDs
    uint8[] compatibleVariants;  // Compatible Henomorph variants
    
    // Advanced features
    bool composable;             // If true, can be composed with other trait packs
    bool nestable;               // If true, can contain child NFTs
    
    // Slots and equippable configuration
    string[] compatibleSlots;    // Slot names this trait pack can be equipped in
    mapping(uint8 => int8) variantBonuses;  // Bonus/penalty by variant
}