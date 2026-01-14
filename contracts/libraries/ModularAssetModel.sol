// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TraitPack, ChargeAccessory, Specimen, Calibration, AccessoryTypeInfo} from "./HenomorphsModel.sol";

/**
 * @notice Integrated data model extending HenomorphsModel with advanced NFT features
 * @dev Combines existing structures from HenomorphsModel with MultiAsset and Nestable features
 * @custom:security-contact security@yourdomain.com
 */

// Custom errors
// error AssetNotFound();
// error AssetAlreadyExists();
// error AssetNotAccepted();
// error AssetNotCompatibleWithSlot();
// error ChildAlreadyExists();
// error ChildNotFound();
// error InvalidChildContract();
// error TokenNotExists();
// error MaxChildrenReached();
// error MaxTraitPacksReached();
// error MaxAccessoriesReached();
// error TraitPackNotFound();
// error TraitPackNotCompatible();
// error OperationNotSupported();
// error CannotTransferWithChildren();
// error InvalidParent();
// error NotAuthorized();
// error ArrayOutOfBounds();

/**
 * @dev Interface for ERC-5773 MultiAsset (Minimal)
 */
interface IERC5773 {
    function getAssetMetadata(uint256 tokenId, uint64 assetId) external view returns (string memory);
    function getActiveAssets(uint256 tokenId) external view returns (uint64[] memory);
    function getAssetReplacements(uint256 tokenId, uint64 newAssetId) external view returns (uint64);
    function acceptAsset(uint256 tokenId, uint64 assetId) external;
    function rejectAsset(uint256 tokenId, uint64 assetId) external;
}

/**
 * @dev Interface for ERC-7401 Nestable (Minimal)
 */
interface IERC7401 {
    function nestTransferFrom(address from, address to, uint256 tokenId, uint256 destinationId, bytes memory data) external;
    function childrenOf(uint256 tokenId) external view returns (uint256[] memory);
    function supportsNesting() external pure returns (bool);
    function proposeChild(uint256 tokenId, address childContract, uint256 childTokenId) external;
    function acceptChild(uint256 tokenId, address childContract, uint256 childTokenId) external;
    function rejectChild(uint256 tokenId, address childContract, uint256 childTokenId) external;
    function transferChild(uint256 tokenId, address childContract, uint256 childTokenId, address to) external;
    function onChildReceived(uint256 tokenId, address childContract, uint256 childTokenId, bytes calldata data) external returns (bytes4);
    function onChildTransferred(uint256 tokenId, address childContract, uint256 childTokenId, address from, address to, bytes calldata data) external returns (bytes4);
}

bytes32 constant ASSTES_STORAGE_POSITION = keccak256("henomorphs.assets.storage");

/**
 * @dev Structure for future storage expansion
 * Uses diamond storage pattern to avoid storage collisions during upgrades
 */
struct ModularAssetStorage {
    // Future storage for upgrades
    mapping(uint256 => mapping(address => uint256)) tokenExtension1;
    mapping(uint256 => uint256) tokenExtension2;
    mapping(uint256 => mapping(bytes4 => bool)) tokenCapabilities;
    mapping(bytes4 => bool) globalCapabilities;
    
    // Module versioning
    mapping(bytes4 => uint256) moduleVersions;
    mapping(bytes4 => bool) moduleEnabled;
    
    // Extension for Henomorph Model integration
    mapping(uint256 => mapping(uint8 => int8)) tokenVariantBonuses;
    mapping(uint8 => mapping(uint8 => int8)) traitPackVariantBonuses;
}

/**
 * @dev Gets the future storage
 * @return fs The future storage struct
 */
function _getModularAssetStorage() pure returns (ModularAssetStorage storage fs) {
    bytes32 position = ASSTES_STORAGE_POSITION;
    assembly {
        fs.slot := position
    }
}

library ModularAssetModel {
    // Parts Types for Equippable assets
    enum PartType {
        None,           // Not equippable
        Slot,           // Can receive other NFTs (e.g., a hand can hold items)
        Fixed           // Fixed part (e.g., a body part that can't be changed)
    }

    /**
     * @dev Structure for specimen stats
     * Moved from HenomorphsMetadata to ensure consistency
     */
    struct SpecimenStats {
        uint16 strengthBonus;
        uint16 agilityBonus;
        uint16 intelligenceBonus;
        uint16 xpBonus;
    }

    /**
     * @dev Structure for equipment data
     * Used to track equipped items in slots
     */
    struct Equipment {
        uint64 slotPartId;            // ID of the slot part where item is equipped
        address childContract;        // Contract address of the equipped item
        uint256 childTokenId;         // Token ID of the equipped item
        uint64 assetId;               // Asset ID to display when equipped
        uint256 equippedTime;         // When item was equipped
        bool isPending;               // If true, equipment is pending acceptance
        uint8 compatibilityScore;     // How well the item fits this slot (0-100)
        int8 calibrationEffect;       // Effect on parent's calibration
    }
    
    /**
     * @dev Structure for enhanced accessory with equippable features
     * Extends the ChargeAccessory model with equippable capabilities
     * IMPORTANT: Defined without mappings to allow memory usage
     */
    struct EnhancedAccessory {
        // Base accessory from HenomorphsModel
        ChargeAccessory base;
        
        // Equippable extensions
        uint64 assetId;              // Associated asset ID for visual representation
        uint64 slotPartId;           // Slot part ID where this can be equipped
        uint64[] compatibleAssetIds; // Assets this accessory is compatible with
        
        // Composition properties
        bool nestable;               // If true, can contain other NFTs
        bool transferableIfEquipped; // If true, can be transferred while equipped
    }
    
    /**
     * @dev Storage structure for enhanced accessory boosts
     * Separated from EnhancedAccessory to allow memory usage of the latter
     */
    struct EnhancedAccessoryBoosts {
        uint64 accessoryId;           // ID to link with EnhancedAccessory
        mapping(uint64 => uint8) assetBoosts; // Specific boosts for assets
    }

    /**
     * @dev Structure for token assets (ERC-5773 MultiAsset)
     * Extends the token metadata concept with multi-asset support
     */
    struct TokenAsset {
        uint64 id;                    // Asset identifier
        string assetUri;              // URI to the asset metadata
        string thumbnailUri;          // URI to the asset thumbnail
        string mediaType;             // MIME type of the asset (e.g., "image/png", "audio/mp3")
        bool pending;                 // If true, asset is not active yet
        bool replaceable;             // If true, asset can be replaced by owner
        uint256 registrationTime;     // When asset was registered
        
        // Trait pack relationship
        uint8 traitPackId;            // Associated trait pack (0 if none)
        uint8 themeId;                // Theme identifier
    }

    /**
     * @dev Structure for equippable parts
     */
    struct EquippablePart {
        uint64 id;                    // Part identifier
        string name;                  // Human-readable name
        PartType partType;            // Type of part
        bytes4 zIndex;                // Z-index for layering
        address[] equippableAddresses;   // Contracts that can equip this part
        string metadataURI;           // URI to the part metadata
        bool fixedToParent;           // If true, part cannot be removed from its parent
    }

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

    /**
     * @dev Structure for child token relationships (ERC-7401 Nestable)
     */
    struct ChildToken {
        address childContract;        // Address of child NFT contract
        uint256 childTokenId;         // Token ID of child NFT
        uint256 addedTime;            // When child was added
        bool transferable;            // If true, child can be transferred out
        bool accepted;                // If true, child is accepted (not pending)
    }

    /**
     * @dev Structure for parent token reference
     */
    struct ParentToken {
        address parentContract;       // Address of parent NFT contract
        uint256 parentTokenId;        // Token ID of parent NFT
        bool isPending;               // If true, parent relationship is pending acceptance
    }

    /**
     * @dev Indeksy do szybkiego wyszukiwania w ModularConfig
     * Zawiera wszystkie mapowania przeniesione z ModularConfig
     */
    struct ModularConfigIndices {
        // Multi-asset management indices
        mapping(uint64 => uint256) pendingAssetIndices;  // assetId => index in pendingAssets (1-based)
        mapping(uint64 => uint256) acceptedAssetIndices; // assetId => index in acceptedAssets (1-based)
        
        // Nestable properties indices
        mapping(address => mapping(uint256 => uint256)) childIndices; // childContract => childTokenId => index in children (1-based)
        mapping(address => mapping(uint256 => uint256)) pendingChildIndices; // childContract => childTokenId => index in pendingChildren (1-based)
        
        // Trait pack indices
        mapping(uint8 => uint256) traitPackIndices;      // traitPackId => index in traitPackIds (1-based)
        
        // Equipment indices
        mapping(uint64 => uint256) slotEquipIndices;     // slotPartId => index in equipments (1-based)
    }

    /**
     * @dev Advanced token configuration - bez mapowań, może być używana jako memory
     */
    struct ModularConfigData {
        // Multi-asset management (ERC-5773)
        uint64[] pendingAssets;       // Assets waiting for acceptance
        uint64[] acceptedAssets;      // Accepted assets
        uint64 activeAssetId;         // Currently active asset ID
        
        // Nestable properties (ERC-7401)
        ChildToken[] children;        // Child tokens
        ChildToken[] pendingChildren; // Child tokens pending acceptance
        ParentToken parent;           // Parent token reference
        
        // Trait pack extensions
        uint8[] traitPackIds;         // Assigned trait pack IDs
        uint8 activeTraitPackId;      // Currently active trait pack ID
        
        // Equipped accessories with enhancement
        ChargeAccessory[] equippedAccessories; // Standard accessories
        EnhancedAccessory[] equippedEnhancedAccessories; // Enhanced accessories
        uint64[] enhancedAccessoryIds;         // IDs for enhanced accessories
        
        // Equipment for equippable module
        Equipment[] equipments;       // Equipped items
        
        // Additional features
        uint256 lastUpdateTime;       // Last update timestamp
    }
    
    /**
     * @dev Combined structure for a complete enhanced Henomorph
     * Integrates original Henomorph data with all extensions
     * Now uses ModularConfigData instead of ModularConfig
     */
    struct ModularHenomorph {
        // Original Henomorph data
        uint256 tokenId;
        Specimen specimen;
        Calibration calibration;
        
        // Enhanced features
        ModularConfigData modularConfig; // Changed from ModularConfig to ModularConfigData
        
        // Cached attributes for efficient access
        bool isNestable;             // If true, can be nested in other tokens
        bool isComposable;           // If true, can be composed with other tokens
        uint256 lastCalibrationSync; // Last time calibration was synced with enhanced features
    }

    /**
     * @dev Collection configuration with enhancements
     */
    struct ModularCollectionConfig {
        string name;
        string symbol;
        string baseURI;
        string contractURI;
        
        uint256 maxSupply;
        uint256 maxTraitPacksPerToken;
        uint256 maxAccessoriesPerToken;
        uint256 maxChildrenPerToken;
        
        address catalogAddress;       // Catalog for equippable parts
        address royaltyRecipient;
        uint16 royaltyPercentage;     // In basis points (e.g., 250 = 2.5%)
        
        bool multiAssetEnabled;       // Master switch for multi-asset features
        bool nestableEnabled;         // Master switch for nestable features
        bool equippableEnabled;       // Master switch for equippable features
        mapping(uint8 => bool) enabledModules; // Control individual modules
    }

    /**
     * @dev Enhanced accessory type with compatibility data
     */
    struct EnhancedAccessoryType {
        AccessoryTypeInfo baseInfo;
        uint64[] compatiblePartIds;   // Part IDs compatible with this accessory type
        uint64[] compatibleSlotIds;   // Slot IDs this accessory type can be equipped in
        uint8[] compatibleTraitPacks; // Trait packs this accessory type is compatible with
    }

    /**
     * @dev Structures for operations to avoid stack too deep errors
     */
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
    
    struct TraitPackAssignData {
        uint256 tokenId;
        uint8 traitPackId;
        bool setAsActive;
    }
    
    struct AccessoryEquipData {
        uint256 tokenId;
        uint8 accessoryType;
        uint64 slotPartId;
        uint64 assetId;
    }

    /**
     * @dev Structure for calibration effects
     * Maps how advanced features affect the calibration system
     */
    struct CalibrationEffects {
        // How trait packs affect calibration
        mapping(uint8 => int8) traitPackCalibrationMods;
        
        // How equipped accessories affect calibration
        mapping(uint8 => int8) accessoryTypeCalibrationMods;
        
        // How child tokens affect parent's calibration
        mapping(address => mapping(uint8 => int8)) childContractCalibrationMods;
        
        // Exponential decay parameters for calibration
        uint256 baseDecayRate;
        uint256 decayInterval;
        
        // Calibration boost from active assets
        mapping(uint64 => int8) assetCalibrationBoosts;
    }
    
    /**
     * @dev Structure for asset priority settings
     */
    struct AssetPriorityConfig {
        uint64[] priorityOrder;      // Assets in priority order (highest first)
        mapping(uint8 => uint8) traitPackPriorities; // Priority by trait pack (higher = higher priority)
        bool automaticPriority;      // If true, priorities are managed automatically
    }


}