// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibCollectionStorage} from "../libraries/LibCollectionStorage.sol";
import {CollectionType, AccessoryDefinition, ExternalCollection} from "../libraries/ModularAssetModel.sol";
import {TraitPack} from "../libraries/CollectionModel.sol";
import {AccessControlBase} from "./AccessControlBase.sol";

/**
 * @title CollectionControlFacet - Collection-Scoped Trait Pack Management
 * @notice Complete collection lifecycle management with collection-specific trait packs
 * @dev PRODUCTION-READY: Maintains backward compatibility while adding collection-scoped functionality
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 * @custom:version 4.2.0 - Collection-scoped trait packs
 */
contract CollectionControlFacet is AccessControlBase {
    
    // ==================== CONSTANTS & LIMITS ====================
    
    uint256 private constant MAX_STRING_LENGTH = 250;
    uint256 private constant MAX_URI_LENGTH = 500;
    uint256 private constant MAX_ARRAY_LENGTH = 100;
    uint256 private constant MIN_MAX_SUPPLY = 1;
    uint256 private constant MAX_MAX_SUPPLY = 1000000;
    uint8 private constant MAX_TIER = 10;
    uint8 private constant MAX_VARIANT = 255;
    uint8 private constant MAX_FORM = 10;
    uint8 private constant MAX_GENERATION = 10;
    uint8 private constant MAX_AUGMENTATION = 10;
    
    // ==================== EXISTING STRUCTS (unchanged) ====================
    
    struct CreateCollectionParams {
        uint256 collectionId;
        string name;
        string symbol;
        string description;
        string baseURI;
        string contractURI;
        uint256 maxSupply;
        address contractAddress;
        CollectionType collectionType;
        uint256 defaultIssueId;
        uint8 defaultTier;
        uint8 defaultVariant;
        string animationBaseURI;  // Optional: dedicated URI for animations
        bool allowDefaultMint;      // NEW: Include in creation params
    }
    
    struct CollectionFeatures {
        bool multiAssetEnabled;
        bool nestableEnabled;
        bool equippableEnabled;
        uint16 maxAssetsPerToken;
        uint16 maxChildrenPerToken;
        uint16 maxEquipmentSlots;
        bool externalSystemsEnabled;
        address catalogAddress;
    }
    
    struct CreateSpecimenParams {
        uint256 collectionId;
        uint8 variant;
        uint8 tier;
        uint8 form;
        string formName;
        string description;
        uint8 generation;
        uint8 augmentation;
        string baseUri;
    }
    
    struct CreateAccessoryParams {
        uint256 collectionId;
        uint256 tokenId;
        uint8 accessoryId;
        string name;
        string description;
        string imageURI;
        uint8[] compatibleVariants;
        AccessoryProperty[] properties;
    }
    
    struct AccessoryProperty {
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
    
    // ==================== NEW: COLLECTION-SCOPED TRAIT PACK STRUCTS ====================
    
    /**
     * @notice Collection-specific trait pack creation parameters
     * @dev Scoped to specific collection, allows same ID across collections
     */
    struct CreateCollectionTraitPackParams {
        uint256 collectionId;           // Target collection ID
        uint8 traitPackId;              // Trait pack ID (unique within collection)
        string name;                    // Trait pack name (1-50 chars)
        string description;             // Description (0-200 chars)
        string baseURI;                 // Base URI for metadata
        uint8[] accessoryIds;           // Accessories in this trait pack
        uint8[] compatibleVariants;     // Compatible variants (0-255)
        bool enabled;                   // Initial enabled state
    }

    /**
     * @notice Legacy trait pack creation (for backward compatibility)
     * @dev DEPRECATED: Use CreateCollectionTraitPackParams instead
     */
    struct CreateTraitPackParams {
        uint8 traitPackId;
        string name;
        string description;
        string baseURI;
        uint8[] accessoryIds;
        uint8[] compatibleVariants;
        bool enabled;
    }
    
    struct CreateThemeParams {
        uint256 collectionId;
        string themeName;
        string technologyBase;
        string evolutionContext;
        string universeContext;
        string preRevealHint;
        bool customNaming;
    }
    
    struct RegisterExternalParams {
        uint256 collectionId;
        address collectionAddress;
        CollectionType collectionType;
        uint8 defaultTier;
        string name;
        string symbol;
        string description;
    }

    // ==================== EVENTS ====================
    
    event CollectionCreated(
        uint256 indexed collectionId, 
        CollectionType indexed collectionType, 
        string name, 
        address indexed contractAddress
    );
    event CollectionUpdated(uint256 indexed collectionId, bytes32 indexed updateHash);
    event CollectionStatusChanged(uint256 indexed collectionId, bool indexed enabled);
    event SpecimenDefined(
        uint256 indexed collectionId, 
        uint8 indexed variant, 
        uint8 indexed tier, 
        string formName
    );
    event SpecimenUpdated(uint256 indexed collectionId, uint8 indexed variant, uint8 indexed tier);
    event AccessoryDefined(
        uint256 indexed collectionId, 
        uint256 indexed tokenId, 
        uint8 indexed accessoryId
    );
    event AccessoryUpdated(uint256 indexed collectionId, uint256 indexed tokenId);
    
    // NEW: Collection-scoped trait pack events
    event CollectionTraitPackCreated(
        uint256 indexed collectionId, 
        uint8 indexed traitPackId, 
        string name
    );
    event CollectionTraitPackUpdated(
        uint256 indexed collectionId, 
        uint8 indexed traitPackId
    );
    event CollectionTraitPackEnabled(
        uint256 indexed collectionId, 
        uint8 indexed traitPackId, 
        bool enabled
    );
    event CollectionVariantTraitPackConfigured(
        uint256 indexed collectionId, 
        uint8 indexed variant, 
        uint8 indexed traitPackId
    );
    
    // DEPRECATED: Legacy trait pack events (maintained for compatibility)
    event TraitPackCreated(uint8 indexed traitPackId, string name);
    event TraitPackVariantConfigured(
        uint256 indexed collectionId, 
        uint8 indexed variant, 
        uint8 indexed traitPackId
    );
    
    event ExternalCollectionRegistered(
        uint256 indexed collectionId, 
        address indexed collectionAddress, 
        CollectionType indexed collectionType
    );
    event ThemeCreated(uint256 indexed collectionId, string themeName);
    event VariantThemeSet(uint256 indexed collectionId, uint8 tier, uint8 indexed variant);
    
    // ==================== ERRORS ====================
    
    // Collection errors
    error CollectionAlreadyExists(uint256 collectionId);
    error CollectionAddressAlreadyUsed(address contractAddress);
    error CollectionTypeNotSupported(CollectionType collectionType);
    error CollectionNotEnabled(uint256 collectionId);
    
    // Validation errors
    error InvalidStringLength(string field, uint256 length, uint256 maxLength);
    error InvalidNumericValue(string field, uint256 value, uint256 min, uint256 max);
    error InvalidAddress(string field, address addr);
    error InvalidURI(string field, string uri);
    error InvalidArrayLength(string field, uint256 length, uint256 maxLength);
    error EmptyRequiredField(string field);
    error InvalidEnumValue(string field, uint256 value);
    
    // Business logic errors
    error SpecimenAlreadyDefined(uint8 variant, uint8 tier);
    error SpecimenNotFound(uint8 variant, uint8 tier);
    error AccessoryAlreadyDefined(uint256 tokenId);
    error AccessoryNotFound(uint256 tokenId);
    
    // NEW: Collection-scoped trait pack errors
    error CollectionTraitPackAlreadyExists(uint256 collectionId, uint8 traitPackId);
    error CollectionTraitPackNotFound(uint256 collectionId, uint8 traitPackId);
    error InvalidCollectionForTraitPack(uint256 collectionId);
    
    // DEPRECATED: Legacy trait pack errors (maintained for compatibility)
    error TraitPackAlreadyExists(uint8 traitPackId);
    error TraitPackNotFound(uint8 traitPackId);
    
    error ThemeAlreadyExists(uint256 collectionId);
    error ThemeNotFound(uint256 collectionId);
    error IncompatibleCollectionType(CollectionType actual, CollectionType required);
    error VariantAlreadyMapped(uint256 collectionId, uint8 variant);
    error ContractNotDeployed(address contractAddress);
    error DuplicateThemeName(string themeName);
    
    // System errors
    error SystemInMaintenance();
    error InsufficientPermissions(address caller);
    error OperationNotPermitted(string operation);

    // ==================== COLLECTION MANAGEMENT (unchanged) ====================

    function createCollection(
        CreateCollectionParams calldata params,
        CollectionFeatures calldata features
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        _validateCreateCollectionParams(params);
        _validateCollectionFeatures(features, params.collectionType);
        _validateCollectionUniqueness(params.collectionId, params.contractAddress);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        _createCollectionInternal(params, features, cs);
        
        emit CollectionCreated(
            params.collectionId, 
            params.collectionType, 
            params.name, 
            params.contractAddress
        );
    }

    function registerExternalCollection(
        RegisterExternalParams calldata params
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        _validateRegisterExternalParams(params);
        _validateContractInterface(params.collectionAddress, params.collectionType);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        _registerExternalCollectionInternal(params, cs);
        
        emit ExternalCollectionRegistered(
            params.collectionId, 
            params.collectionAddress, 
            params.collectionType
        );
    }

    function updateCollection(
        uint256 collectionId,
        CreateCollectionParams calldata params,
        CollectionFeatures calldata features
    ) external onlyAuthorized whenNotPaused nonReentrant validInternalCollection(collectionId) {
        
        _validateCollectionUpdateParams(params);
        _validateCollectionFeatures(features, params.collectionType);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        bytes32 updateHash = _updateCollectionInternal(collectionId, params, features, cs);
        
        emit CollectionUpdated(collectionId, updateHash);
    }

    function setCollectionEnabled(
        uint256 collectionId, 
        bool enabled
    ) external onlyAuthorized whenNotPaused validInternalCollection(collectionId) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
        
        collection.enabled = enabled;
        collection.lastUpdateTime = block.timestamp;
        
        emit CollectionStatusChanged(collectionId, enabled);
    }

    function updateCollectionSupply(uint256 collectionId, int256 increment) external onlySystem validInternalCollection(collectionId) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
        
        if (increment > 0) {
            collection.currentSupply += uint256(increment);
        } else if (increment < 0 && collection.currentSupply >= uint256(-increment)) {
            collection.currentSupply -= uint256(-increment);
        }
        
        collection.lastUpdateTime = block.timestamp;
    }

    // ==================== SPECIMEN MANAGEMENT (unchanged) ====================

    function defineSpecimen(
        CreateSpecimenParams calldata params
    ) external onlyAuthorized whenNotPaused nonReentrant validInternalCollection(params.collectionId) {
        
        _validateCreateSpecimenParams(params);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        _validateCollectionTypeForSpecimen(cs, params.collectionId);
        
        uint256 specimenKey = _getSpecimenKey(params.variant, params.tier);
        if (cs.tokenSpecimens[params.collectionId][specimenKey].defined) {
            revert SpecimenAlreadyDefined(params.variant, params.tier);
        }
        
        _defineSpecimenInternal(params, specimenKey, cs);
        
        emit SpecimenDefined(params.collectionId, params.variant, params.tier, params.formName);
    }

    function updateSpecimen(
        CreateSpecimenParams calldata params
    ) external onlyAuthorized whenNotPaused nonReentrant validInternalCollection(params.collectionId) {
        
        _validateCreateSpecimenParams(params);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        uint256 specimenKey = _getSpecimenKey(params.variant, params.tier);
        
        if (!cs.tokenSpecimens[params.collectionId][specimenKey].defined) {
            revert SpecimenNotFound(params.variant, params.tier);
        }
        
        _updateSpecimenInternal(params, specimenKey, cs);
        
        emit SpecimenUpdated(params.collectionId, params.variant, params.tier);
    }

    function deleteSpecimen(
        uint256 collectionId,
        uint8 variant,
        uint8 tier
    ) external onlyAuthorized whenNotPaused nonReentrant validInternalCollection(collectionId) {
        
        if (variant > MAX_VARIANT) {
            revert InvalidNumericValue("variant", variant, 0, MAX_VARIANT);
        }
        if (tier == 0 || tier > MAX_TIER) {
            revert InvalidNumericValue("tier", tier, 1, MAX_TIER);
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        uint256 specimenKey = _getSpecimenKey(variant, tier);
        
        if (!cs.tokenSpecimens[collectionId][specimenKey].defined) {
            revert SpecimenNotFound(variant, tier);
        }
        
        cs.tokenSpecimens[collectionId][specimenKey].defined = false;
        
        emit SpecimenUpdated(collectionId, variant, tier);
    }

    // ==================== ACCESSORY MANAGEMENT (unchanged) ====================

    function defineAccessory(
        CreateAccessoryParams calldata params
    ) external onlyAuthorized whenNotPaused nonReentrant validInternalCollection(params.collectionId) {
        
        _validateCreateAccessoryParams(params);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        _validateCollectionTypeForAccessory(cs, params.collectionId);
        
        if (cs.accessoryTokens[params.collectionId][params.tokenId].defined) {
            revert AccessoryAlreadyDefined(params.tokenId);
        }
        
        _defineAccessoryInternal(params, cs);
        
        emit AccessoryDefined(params.collectionId, params.tokenId, params.accessoryId);
    }

    function updateAccessory(
        CreateAccessoryParams calldata params
    ) external onlyAuthorized whenNotPaused nonReentrant validInternalCollection(params.collectionId) {
        
        _validateCreateAccessoryParams(params);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!cs.accessoryTokens[params.collectionId][params.tokenId].defined) {
            revert AccessoryNotFound(params.tokenId);
        }
        
        _updateAccessoryInternal(params, cs);
        
        emit AccessoryUpdated(params.collectionId, params.tokenId);
    }

    function deleteAccessory(
        uint256 collectionId,
        uint256 tokenId
    ) external onlyAuthorized whenNotPaused nonReentrant validInternalCollection(collectionId) {
        
        if (tokenId == 0) {
            revert InvalidNumericValue("tokenId", tokenId, 1, type(uint256).max);
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!cs.accessoryTokens[collectionId][tokenId].defined) {
            revert AccessoryNotFound(tokenId);
        }
        
        cs.accessoryTokens[collectionId][tokenId].defined = false;
        
        emit AccessoryUpdated(collectionId, tokenId);
    }

    // ==================== NEW: COLLECTION-SCOPED TRAIT PACK MANAGEMENT ====================

    /**
     * @notice Create trait pack for specific collection
     * @dev Production-ready with comprehensive validation
     * @param params Collection-specific trait pack parameters
     */
    function createCollectionTraitPack(
        CreateCollectionTraitPackParams calldata params
    ) external onlyAuthorized whenNotPaused nonReentrant validInternalCollection(params.collectionId) {
        
        _validateCreateCollectionTraitPackParams(params);
        
        LibCollectionStorage.createCollectionTraitPack(
            params.collectionId,
            params.traitPackId,
            params.name,
            params.description,
            params.baseURI,
            params.accessoryIds,
            params.compatibleVariants
        );
        
        // Set enabled state if different from default
        if (!params.enabled) {
            LibCollectionStorage.setCollectionTraitPackEnabled(
                params.collectionId,
                params.traitPackId,
                false
            );
        }
        
        emit CollectionTraitPackCreated(params.collectionId, params.traitPackId, params.name);
    }

    /**
     * @notice Update existing collection trait pack
     * @param params Updated trait pack parameters
     */
    function updateCollectionTraitPack(
        CreateCollectionTraitPackParams calldata params
    ) external onlyAuthorized whenNotPaused nonReentrant validInternalCollection(params.collectionId) {
        
        _validateCreateCollectionTraitPackParams(params);
        
        if (!LibCollectionStorage.collectionTraitPackExists(params.collectionId, params.traitPackId)) {
            revert CollectionTraitPackNotFound(params.collectionId, params.traitPackId);
        }
        
        // Recreate trait pack with updated data
        LibCollectionStorage.createCollectionTraitPack(
            params.collectionId,
            params.traitPackId,
            params.name,
            params.description,
            params.baseURI,
            params.accessoryIds,
            params.compatibleVariants
        );
        
        LibCollectionStorage.setCollectionTraitPackEnabled(
            params.collectionId,
            params.traitPackId,
            params.enabled
        );
        
        emit CollectionTraitPackUpdated(params.collectionId, params.traitPackId);
    }

    /**
     * @notice Enable/disable collection trait pack
     * @param collectionId Collection ID
     * @param traitPackId Trait pack ID
     * @param enabled New enabled state
     */
    function setCollectionTraitPackEnabled(
        uint256 collectionId,
        uint8 traitPackId,
        bool enabled
    ) external onlyAuthorized whenNotPaused validInternalCollection(collectionId) {
        
        if (!LibCollectionStorage.collectionTraitPackExists(collectionId, traitPackId)) {
            revert CollectionTraitPackNotFound(collectionId, traitPackId);
        }
        
        LibCollectionStorage.setCollectionTraitPackEnabled(collectionId, traitPackId, enabled);
        
        emit CollectionTraitPackEnabled(collectionId, traitPackId, enabled);
    }

    /**
     * @notice Configure variant to trait pack mapping (collection-scoped)
     * @param collectionId Collection ID
     * @param variant Variant number (0-255)
     * @param traitPackId Trait pack ID (0 to clear)
     */
    function configureCollectionVariantTraitPack(
        uint256 collectionId,
        uint8 variant,
        uint8 traitPackId
    ) external onlyAuthorized whenNotPaused nonReentrant validInternalCollection(collectionId) {
        
        if (variant > MAX_VARIANT) {
            revert InvalidNumericValue("variant", variant, 0, MAX_VARIANT);
        }
        
        if (traitPackId != 0 && !LibCollectionStorage.collectionTraitPackExists(collectionId, traitPackId)) {
            revert CollectionTraitPackNotFound(collectionId, traitPackId);
        }
        
        LibCollectionStorage.setCollectionVariantTraitPack(collectionId, variant, traitPackId);
        
        emit CollectionVariantTraitPackConfigured(collectionId, variant, traitPackId);
    }

    /**
     * @notice Delete collection trait pack
     * @param collectionId Collection ID
     * @param traitPackId Trait pack ID
     */
    function deleteCollectionTraitPack(
        uint256 collectionId,
        uint8 traitPackId
    ) external onlyAuthorized whenNotPaused nonReentrant validInternalCollection(collectionId) {
        
        if (!LibCollectionStorage.collectionTraitPackExists(collectionId, traitPackId)) {
            revert CollectionTraitPackNotFound(collectionId, traitPackId);
        }
        
        // Clear all variant mappings for this trait pack
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        for (uint16 variant = 0; variant <= MAX_VARIANT; variant++) {
            if (cs.collectionVariantToTraitPack[collectionId][uint8(variant)] == traitPackId) {
                cs.collectionVariantToTraitPack[collectionId][uint8(variant)] = 0;
            }
        }
        
        // Remove from existence mapping
        cs.collectionTraitPackExists[collectionId][traitPackId] = false;
        
        // Remove from ID list
        uint8[] storage idList = cs.collectionTraitPackIds[collectionId];
        for (uint256 i = 0; i < idList.length; i++) {
            if (idList[i] == traitPackId) {
                idList[i] = idList[idList.length - 1];
                idList.pop();
                break;
            }
        }
        
        emit CollectionTraitPackUpdated(collectionId, traitPackId);
    }

    // ==================== DEPRECATED: LEGACY TRAIT PACK MANAGEMENT ====================
    
    /**
     * @notice Create legacy trait pack (for backward compatibility)
     * @dev DEPRECATED: Use createCollectionTraitPack instead
     * @param params Legacy trait pack parameters
     */
    function createTraitPack(
        CreateTraitPackParams calldata params
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        _validateCreateTraitPackParams(params);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (cs.traitPackExists[params.traitPackId]) {
            revert TraitPackAlreadyExists(params.traitPackId);
        }
        
        _createTraitPackInternal(params, cs);
        
        emit TraitPackCreated(params.traitPackId, params.name);
    }

    /**
     * @notice Configure variant to legacy trait pack mapping
     * @dev DEPRECATED: Use configureCollectionVariantTraitPack instead
     * @param collectionId Collection ID
     * @param variant Variant number (0-255)
     * @param traitPackId Legacy trait pack ID (0 to clear)
     */
    function configureVariantTraitPack(
        uint256 collectionId,
        uint8 variant,
        uint8 traitPackId
    ) external onlyAuthorized whenNotPaused nonReentrant validInternalCollection(collectionId) {
        
        if (variant > MAX_VARIANT) {
            revert InvalidNumericValue("variant", variant, 0, MAX_VARIANT);
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (traitPackId != 0 && !cs.traitPackExists[traitPackId]) {
            revert TraitPackNotFound(traitPackId);
        }
        
        cs.variantToTraitPack[collectionId][variant] = traitPackId;
        
        emit TraitPackVariantConfigured(collectionId, variant, traitPackId);
    }

    // ==================== THEME MANAGEMENT (unchanged) ====================

    function createCollectionTheme(
        CreateThemeParams calldata params
    ) external onlyAuthorized whenNotPaused nonReentrant validInternalCollection(params.collectionId) {
        
        _validateCreateThemeParams(params);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (cs.collectionThemeActive[params.collectionId]) {
            revert ThemeAlreadyExists(params.collectionId);
        }
        
        _validateThemeNameUniqueness(params.themeName, cs);
        
        _createThemeInternal(params, cs);
        
        emit ThemeCreated(params.collectionId, params.themeName);
    }

    function setVariantTheme(
        uint256 collectionId,
        uint8 tier,
        uint8 variant,
        string calldata evolutionStage,
        string calldata powerLevel
    ) external onlyAuthorized whenNotPaused nonReentrant validInternalCollection(collectionId) {
        
        if (variant > MAX_VARIANT) {
            revert InvalidNumericValue("variant", variant, 0, MAX_VARIANT);
        }
        
        _validateString("evolutionStage", evolutionStage, 1, 50);
        _validateString("powerLevel", powerLevel, 1, 50);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!cs.collectionThemeActive[collectionId]) {
            revert ThemeNotFound(collectionId);
        }
        
        LibCollectionStorage.VariantTheme storage variantTheme = cs.variantThemes[collectionId][tier][variant];
        variantTheme.evolutionStage = evolutionStage;
        variantTheme.powerLevel = powerLevel;
        variantTheme.hasCustomTheme = true;
        
        emit VariantThemeSet(collectionId, tier, variant);
    }

    function setCollectionThemeActive(
        uint256 collectionId,
        bool active
    ) external onlyAuthorized whenNotPaused nonReentrant validInternalCollection(collectionId) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (active && bytes(cs.collectionThemes[collectionId].themeName).length == 0) {
            revert EmptyRequiredField("themeName");
        }
        
        cs.collectionThemeActive[collectionId] = active;
        cs.collectionThemes[collectionId].updatedAt = block.timestamp;
    }

    // ==================== VALIDATION FUNCTIONS ====================

    function _validateCreateCollectionTraitPackParams(CreateCollectionTraitPackParams calldata params) private pure {
        if (params.collectionId == 0) {
            revert InvalidNumericValue("collectionId", params.collectionId, 1, type(uint256).max);
        }
        
        if (params.traitPackId == 0) {
            revert InvalidNumericValue("traitPackId", params.traitPackId, 1, type(uint8).max);
        }
        
        _validateString("name", params.name, 1, 50);
        _validateString("description", params.description, 0, MAX_STRING_LENGTH);
        _validateURI("baseURI", params.baseURI);
        
        if (params.accessoryIds.length > 50) {
            revert InvalidArrayLength("accessoryIds", params.accessoryIds.length, 50);
        }
        
        for (uint256 i = 0; i < params.accessoryIds.length; i++) {
            if (params.accessoryIds[i] == 0) {
                revert InvalidNumericValue("accessoryId", params.accessoryIds[i], 1, type(uint8).max);
            }
        }
        
        if (params.compatibleVariants.length > MAX_ARRAY_LENGTH) {
            revert InvalidArrayLength("compatibleVariants", params.compatibleVariants.length, MAX_ARRAY_LENGTH);
        }
        
        for (uint256 i = 0; i < params.compatibleVariants.length; i++) {
            if (params.compatibleVariants[i] > MAX_VARIANT) {
                revert InvalidNumericValue("compatibleVariant", params.compatibleVariants[i], 0, MAX_VARIANT);
            }
        }
    }

    // ==================== REMAINING VALIDATION & INTERNAL FUNCTIONS ====================

    function _validateCreateCollectionParams(CreateCollectionParams calldata params) private pure {
        if (params.collectionId == 0) {
            revert InvalidNumericValue("collectionId", params.collectionId, 1, type(uint256).max);
        }
        
        _validateString("name", params.name, 1, 50);
        _validateString("symbol", params.symbol, 1, 10);
        _validateString("description", params.description, 1, MAX_STRING_LENGTH);
        _validateURI("baseURI", params.baseURI);
        _validateURI("contractURI", params.contractURI);
        
        if (params.maxSupply < MIN_MAX_SUPPLY || params.maxSupply > MAX_MAX_SUPPLY) {
            revert InvalidNumericValue("maxSupply", params.maxSupply, MIN_MAX_SUPPLY, MAX_MAX_SUPPLY);
        }
        
        if (params.contractAddress == address(0)) {
            revert InvalidAddress("contractAddress", params.contractAddress);
        }
        
        if (uint8(params.collectionType) > 6) {
            revert InvalidEnumValue("collectionType", uint8(params.collectionType));
        }
        
        if (params.defaultTier > MAX_TIER) {
            revert InvalidNumericValue("defaultTier", params.defaultTier, 0, MAX_TIER);
        }
        
        if (params.defaultVariant > MAX_VARIANT) {
            revert InvalidNumericValue("defaultVariant", params.defaultVariant, 0, MAX_VARIANT);
        }
    }

    function _validateCollectionFeatures(
        CollectionFeatures calldata features, 
        CollectionType collectionType
    ) private pure {
        if (collectionType == CollectionType.Accessory) {
            if (features.nestableEnabled) {
                revert IncompatibleCollectionType(collectionType, CollectionType.Main);
            }
        }
        
        if (features.maxAssetsPerToken > 1000) {
            revert InvalidNumericValue("maxAssetsPerToken", features.maxAssetsPerToken, 0, 1000);
        }
        
        if (features.maxChildrenPerToken > 100) {
            revert InvalidNumericValue("maxChildrenPerToken", features.maxChildrenPerToken, 0, 100);
        }
        
        if (features.maxEquipmentSlots > 50) {
            revert InvalidNumericValue("maxEquipmentSlots", features.maxEquipmentSlots, 0, 50);
        }
    }

    function _validateCreateSpecimenParams(CreateSpecimenParams calldata params) private pure {
        if (params.collectionId == 0) {
            revert InvalidNumericValue("collectionId", params.collectionId, 1, type(uint256).max);
        }
        
        if (params.variant > MAX_VARIANT) {
            revert InvalidNumericValue("variant", params.variant, 0, MAX_VARIANT);
        }
        
        if (params.tier == 0 || params.tier > MAX_TIER) {
            revert InvalidNumericValue("tier", params.tier, 1, MAX_TIER);
        }
        
        if (params.form > MAX_FORM) {
            revert InvalidNumericValue("form", params.form, 0, MAX_FORM);
        }
        
        if (params.generation > MAX_GENERATION) {
            revert InvalidNumericValue("generation", params.generation, 0, MAX_GENERATION);
        }
        
        if (params.augmentation > MAX_AUGMENTATION) {
            revert InvalidNumericValue("augmentation", params.augmentation, 0, MAX_AUGMENTATION);
        }
        
        _validateString("formName", params.formName, 1, 50);
        _validateString("description", params.description, 1, MAX_STRING_LENGTH);
        _validateURI("baseUri", params.baseUri);
    }

    function _validateCreateAccessoryParams(CreateAccessoryParams calldata params) private pure {
        if (params.collectionId == 0) {
            revert InvalidNumericValue("collectionId", params.collectionId, 1, type(uint256).max);
        }
        
        if (params.accessoryId == 0) {
            revert InvalidNumericValue("accessoryId", params.accessoryId, 1, type(uint8).max);
        }
        
        _validateString("name", params.name, 1, 50);
        _validateString("description", params.description, 0, MAX_STRING_LENGTH);
        _validateURI("imageURI", params.imageURI);
        
        if (params.compatibleVariants.length > MAX_ARRAY_LENGTH) {
            revert InvalidArrayLength("compatibleVariants", params.compatibleVariants.length, MAX_ARRAY_LENGTH);
        }
        
        for (uint256 i = 0; i < params.compatibleVariants.length; i++) {
            if (params.compatibleVariants[i] > MAX_VARIANT) {
                revert InvalidNumericValue("compatibleVariant", params.compatibleVariants[i], 0, MAX_VARIANT);
            }
        }
        
        if (params.properties.length > 20) {
            revert InvalidArrayLength("properties", params.properties.length, 20);
        }
        
        for (uint256 i = 0; i < params.properties.length; i++) {
            _validateAccessoryProperty(params.properties[i]);
        }
    }

    function _validateAccessoryProperty(AccessoryProperty calldata property) private pure {
        if (property.propertyType == 0 || property.propertyType > 10) {
            revert InvalidNumericValue("propertyType", property.propertyType, 1, 10);
        }
        
        _validateString("propertyName", property.propertyName, 1, 30);
        
        if (property.chargeBoost > 100) {
            revert InvalidNumericValue("chargeBoost", property.chargeBoost, 0, 100);
        }
        
        if (property.regenBoost > 100) {
            revert InvalidNumericValue("regenBoost", property.regenBoost, 0, 100);
        }
        
        if (property.efficiencyBoost > 100) {
            revert InvalidNumericValue("efficiencyBoost", property.efficiencyBoost, 0, 100);
        }
        
        if (property.kinshipBonus > 100) {
            revert InvalidNumericValue("kinshipBonus", property.kinshipBonus, 0, 100);
        }
        
        if (property.wearResistance > 100) {
            revert InvalidNumericValue("wearResistance", property.wearResistance, 0, 100);
        }
        
        if (property.calibrationBonus > 100) {
            revert InvalidNumericValue("calibrationBonus", property.calibrationBonus, 0, 100);
        }
        
        if (property.stakingBoostPercentage > 200) {
            revert InvalidNumericValue("stakingBoostPercentage", property.stakingBoostPercentage, 0, 200);
        }
        
        if (property.xpGainMultiplier < 100 || property.xpGainMultiplier > 300) {
            revert InvalidNumericValue("xpGainMultiplier", property.xpGainMultiplier, 100, 300);
        }
    }

    function _validateCreateTraitPackParams(CreateTraitPackParams calldata params) private pure {
        if (params.traitPackId == 0) {
            revert InvalidNumericValue("traitPackId", params.traitPackId, 1, type(uint8).max);
        }
        
        _validateString("name", params.name, 1, 50);
        _validateString("description", params.description, 0, MAX_STRING_LENGTH);
        _validateURI("baseURI", params.baseURI);
        
        if (params.accessoryIds.length > 50) {
            revert InvalidArrayLength("accessoryIds", params.accessoryIds.length, 50);
        }
        
        for (uint256 i = 0; i < params.accessoryIds.length; i++) {
            if (params.accessoryIds[i] == 0) {
                revert InvalidNumericValue("accessoryId", params.accessoryIds[i], 1, type(uint8).max);
            }
        }
        
        if (params.compatibleVariants.length > MAX_ARRAY_LENGTH) {
            revert InvalidArrayLength("compatibleVariants", params.compatibleVariants.length, MAX_ARRAY_LENGTH);
        }
        
        for (uint256 i = 0; i < params.compatibleVariants.length; i++) {
            if (params.compatibleVariants[i] > MAX_VARIANT) {
                revert InvalidNumericValue("compatibleVariant", params.compatibleVariants[i], 0, MAX_VARIANT);
            }
        }
    }

    function _validateCreateThemeParams(CreateThemeParams calldata params) private pure {
        if (params.collectionId == 0) {
            revert InvalidNumericValue("collectionId", params.collectionId, 1, type(uint256).max);
        }
        
        _validateString("themeName", params.themeName, 1, 50);
        _validateString("technologyBase", params.technologyBase, 1, 100);
        _validateString("evolutionContext", params.evolutionContext, 1, 100);
        _validateString("universeContext", params.universeContext, 0, 100);
        _validateString("preRevealHint", params.preRevealHint, 0, MAX_STRING_LENGTH);
    }

    function _validateRegisterExternalParams(RegisterExternalParams calldata params) private view {
        if (params.collectionAddress == address(0)) {
            revert InvalidAddress("collectionAddress", params.collectionAddress);
        }
        if (params.collectionId == 0) {
            revert InvalidNumericValue("collectionId", params.collectionId, 1, type(uint256).max);
        }
        if (params.defaultTier == 0 || params.defaultTier > MAX_TIER) {
            revert InvalidNumericValue("defaultTier", params.defaultTier, 1, MAX_TIER);
        }
        
        _validateString("name", params.name, 1, 50);
        _validateString("symbol", params.symbol, 1, 10);
        _validateString("description", params.description, 0, MAX_STRING_LENGTH);
        
        if (LibCollectionStorage.collectionExists(params.collectionId)) {
            revert CollectionAlreadyExists(params.collectionId);
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        if (cs.externalCollectionsByAddress[params.collectionAddress] != 0) {
            revert CollectionAddressAlreadyUsed(params.collectionAddress);
        }
    }

    function _validateCollectionUpdateParams(CreateCollectionParams calldata params) private pure {
        if (bytes(params.name).length > 50) {
            revert InvalidStringLength("name", bytes(params.name).length, 50);
        }
        if (bytes(params.symbol).length > 10) {
            revert InvalidStringLength("symbol", bytes(params.symbol).length, 10);
        }
        if (bytes(params.description).length > MAX_STRING_LENGTH) {
            revert InvalidStringLength("description", bytes(params.description).length, MAX_STRING_LENGTH);
        }
        if (bytes(params.baseURI).length > MAX_URI_LENGTH) {
            revert InvalidStringLength("baseURI", bytes(params.baseURI).length, MAX_URI_LENGTH);
        }
        if (bytes(params.contractURI).length > MAX_URI_LENGTH) {
            revert InvalidStringLength("contractURI", bytes(params.contractURI).length, MAX_URI_LENGTH);
        }
        
        if (params.maxSupply > MAX_MAX_SUPPLY) {
            revert InvalidNumericValue("maxSupply", params.maxSupply, 0, MAX_MAX_SUPPLY);
        }
    }

    function _validateString(string memory fieldName, string calldata value, uint256 minLength, uint256 maxLength) private pure {
        bytes memory valueBytes = bytes(value);
        
        if (valueBytes.length < minLength) {
            if (minLength > 0) {
                revert EmptyRequiredField(fieldName);
            }
        }
        
        if (valueBytes.length > maxLength) {
            revert InvalidStringLength(fieldName, valueBytes.length, maxLength);
        }
    }

    function _validateURI(string memory fieldName, string calldata uri) private pure {
        bytes memory uriBytes = bytes(uri);
        
        if (uriBytes.length > MAX_URI_LENGTH) {
            revert InvalidStringLength(fieldName, uriBytes.length, MAX_URI_LENGTH);
        }
    }

    function _validateCollectionUniqueness(uint256 collectionId, address contractAddress) private view {
        if (LibCollectionStorage.collectionExists(collectionId)) {
            revert CollectionAlreadyExists(collectionId);
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        if (cs.collectionsByAddress[contractAddress] != 0) {
            revert CollectionAddressAlreadyUsed(contractAddress);
        }
    }

    function _validateCollectionTypeForSpecimen(
        LibCollectionStorage.CollectionStorage storage cs,
        uint256 collectionId
    ) private view {
        if (cs.collections[collectionId].collectionType != CollectionType.Main) {
            revert IncompatibleCollectionType(cs.collections[collectionId].collectionType, CollectionType.Main);
        }
    }

    function _validateCollectionTypeForAccessory(
        LibCollectionStorage.CollectionStorage storage cs,
        uint256 collectionId
    ) private view {
        if ((cs.collections[collectionId].collectionType != CollectionType.Accessory) && (cs.collections[collectionId].collectionType != CollectionType.Augment)) {
            revert IncompatibleCollectionType(cs.collections[collectionId].collectionType, CollectionType.Accessory);
        }
    }

    function _validateContractInterface(address contractAddress, CollectionType) private view {
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(contractAddress)
        }
        
        if (codeSize == 0) {
            revert ContractNotDeployed(contractAddress);
        }
    }

    function _validateThemeNameUniqueness(
        string calldata themeName,
        LibCollectionStorage.CollectionStorage storage cs
    ) private view {
        bytes32 themeNameHash = keccak256(bytes(themeName));
        
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            if (cs.collectionThemeActive[i]) {
                if (keccak256(bytes(cs.collectionThemes[i].themeName)) == themeNameHash) {
                    revert DuplicateThemeName(themeName);
                }
            }
        }
    }

    function _validateNoDuplicateSpecimens(CreateSpecimenParams[] calldata specimens) private pure {
        for (uint256 i = 0; i < specimens.length; i++) {
            for (uint256 j = i + 1; j < specimens.length; j++) {
                if (specimens[i].collectionId == specimens[j].collectionId &&
                    specimens[i].variant == specimens[j].variant &&
                    specimens[i].tier == specimens[j].tier) {
                    revert SpecimenAlreadyDefined(specimens[i].variant, specimens[i].tier);
                }
            }
        }
    }

    function _validateNoDuplicateAccessories(CreateAccessoryParams[] calldata accessories) private pure {
        for (uint256 i = 0; i < accessories.length; i++) {
            for (uint256 j = i + 1; j < accessories.length; j++) {
                if (accessories[i].collectionId == accessories[j].collectionId &&
                    accessories[i].tokenId == accessories[j].tokenId) {
                    revert AccessoryAlreadyDefined(accessories[i].tokenId);
                }
            }
        }
    }

    function _validateNoDuplicateCollectionTraitPacks(CreateCollectionTraitPackParams[] calldata traitPacks) private pure {
        for (uint256 i = 0; i < traitPacks.length; i++) {
            for (uint256 j = i + 1; j < traitPacks.length; j++) {
                if (traitPacks[i].collectionId == traitPacks[j].collectionId &&
                    traitPacks[i].traitPackId == traitPacks[j].traitPackId) {
                    revert CollectionTraitPackAlreadyExists(traitPacks[i].collectionId, traitPacks[i].traitPackId);
                }
            }
        }
    }

    // ==================== INTERNAL IMPLEMENTATION FUNCTIONS ====================

    function _createCollectionInternal(
        CreateCollectionParams calldata params,
        CollectionFeatures calldata features,
        LibCollectionStorage.CollectionStorage storage cs
    ) private {
        LibCollectionStorage.CollectionData storage collection = cs.collections[params.collectionId];
        
        collection.contractAddress = params.contractAddress;
        collection.name = params.name;
        collection.symbol = params.symbol;
        collection.description = params.description;
        collection.collectionType = params.collectionType;
        collection.enabled = true;
        collection.maxSupply = params.maxSupply;
        collection.currentSupply = 0;
        collection.baseURI = params.baseURI;
        collection.animationBaseURI = params.animationBaseURI;
        collection.contractURI = params.contractURI;
        collection.defaultIssueId = params.defaultIssueId != 0 ? params.defaultIssueId : params.collectionId;
        collection.defaultTier = params.defaultTier != 0 ? params.defaultTier : 1;
        collection.defaultVariant = params.defaultVariant;
        collection.allowDefaultMint = params.allowDefaultMint;  // NEW: Set during creation
        
        collection.multiAssetEnabled = features.multiAssetEnabled;
        collection.nestableEnabled = features.nestableEnabled;
        collection.equippableEnabled = features.equippableEnabled;
        collection.maxAssetsPerToken = features.maxAssetsPerToken != 0 ? features.maxAssetsPerToken : 10;
        collection.maxChildrenPerToken = features.maxChildrenPerToken;
        collection.maxEquipmentSlots = features.maxEquipmentSlots;
        collection.externalSystemsEnabled = features.externalSystemsEnabled;
        collection.catalogAddress = features.catalogAddress;
        
        collection.creationTime = block.timestamp;
        collection.lastUpdateTime = block.timestamp;
        collection.metadataMode = LibCollectionStorage.MetadataMode.Dynamic;
        
        cs.collectionsByAddress[params.contractAddress] = params.collectionId;
        
        if (params.collectionId >= cs.collectionCounter) {
            cs.collectionCounter = params.collectionId + 1;
        }
    }

    function _registerExternalCollectionInternal(
        RegisterExternalParams calldata params,
        LibCollectionStorage.CollectionStorage storage cs
    ) private {
        ExternalCollection storage _external = cs.externalCollections[params.collectionId];
        _external.collectionAddress = params.collectionAddress;
        _external.collectionId = params.collectionId;
        _external.collectionType = params.collectionType;
        _external.enabled = true;
        _external.registrationTime = block.timestamp;

        cs.externalCollectionsByAddress[params.collectionAddress] = params.collectionId;
        
        LibCollectionStorage.CollectionData storage collection = cs.collections[params.collectionId];
        collection.contractAddress = params.collectionAddress;
        collection.name = params.name;
        collection.symbol = params.symbol;
        collection.description = params.description;
        collection.collectionType = params.collectionType;
        collection.defaultTier = params.defaultTier;
        collection.defaultIssueId = params.collectionId;
        collection.enabled = true;
        collection.creationTime = block.timestamp;
        collection.lastUpdateTime = block.timestamp;
        
        cs.collectionsByAddress[params.collectionAddress] = params.collectionId;
        
        if (params.collectionId >= cs.collectionCounter) {
            cs.collectionCounter = params.collectionId + 1;
        }
    }

    function _updateCollectionInternal(
        uint256 collectionId,
        CreateCollectionParams calldata params,
        CollectionFeatures calldata features,
        LibCollectionStorage.CollectionStorage storage cs
    ) private returns (bytes32 updateHash) {
        LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
        
        bytes memory updateData;
        
        if (bytes(params.name).length > 0 && keccak256(bytes(params.name)) != keccak256(bytes(collection.name))) {
            collection.name = params.name;
            updateData = abi.encodePacked(updateData, "name:", params.name);
        }
        if (bytes(params.symbol).length > 0 && keccak256(bytes(params.symbol)) != keccak256(bytes(collection.symbol))) {
            collection.symbol = params.symbol;
            updateData = abi.encodePacked(updateData, "symbol:", params.symbol);
        }
        if (bytes(params.description).length > 0 && keccak256(bytes(params.description)) != keccak256(bytes(collection.description))) {
            collection.description = params.description;
            updateData = abi.encodePacked(updateData, "description:", params.description);
        }
        if (bytes(params.baseURI).length > 0 && keccak256(bytes(params.baseURI)) != keccak256(bytes(collection.baseURI))) {
            collection.baseURI = params.baseURI;
            updateData = abi.encodePacked(updateData, "baseURI:", params.baseURI);
        }
        if (bytes(params.animationBaseURI).length > 0 && keccak256(bytes(params.animationBaseURI)) != keccak256(bytes(collection.animationBaseURI))) {
            collection.animationBaseURI = params.animationBaseURI;
            updateData = abi.encodePacked(updateData, "animationBaseURI:", params.animationBaseURI);
        }
        if (bytes(params.contractURI).length > 0 && keccak256(bytes(params.contractURI)) != keccak256(bytes(collection.contractURI))) {
            collection.contractURI = params.contractURI;
            updateData = abi.encodePacked(updateData, "contractURI:", params.contractURI);
        }
        if (params.maxSupply > 0 && params.maxSupply != collection.maxSupply) {
            collection.maxSupply = params.maxSupply;
            updateData = abi.encodePacked(updateData, "maxSupply:", params.maxSupply);
        }
        if (params.allowDefaultMint != collection.allowDefaultMint) {
            collection.allowDefaultMint = params.allowDefaultMint;
            updateData = abi.encodePacked(updateData, "allowDefaultMint:", params.allowDefaultMint ? "true" : "false");
        }
        
        collection.multiAssetEnabled = features.multiAssetEnabled;
        collection.nestableEnabled = features.nestableEnabled;
        collection.equippableEnabled = features.equippableEnabled;
        collection.maxAssetsPerToken = features.maxAssetsPerToken;
        collection.maxChildrenPerToken = features.maxChildrenPerToken;
        collection.maxEquipmentSlots = features.maxEquipmentSlots;
        collection.externalSystemsEnabled = features.externalSystemsEnabled;
        
        if (features.catalogAddress != address(0)) {
            collection.catalogAddress = features.catalogAddress;
        }
        
        collection.lastUpdateTime = block.timestamp;
        updateHash = keccak256(updateData);
        
        return updateHash;
    }

    function _defineSpecimenInternal(
        CreateSpecimenParams calldata params,
        uint256 specimenKey,
        LibCollectionStorage.CollectionStorage storage cs
    ) private {
        LibCollectionStorage.TokenSpecimen storage specimen = cs.tokenSpecimens[params.collectionId][specimenKey];
        
        specimen.variant = params.variant;
        specimen.tier = params.tier;
        specimen.form = params.form;
        specimen.formName = params.formName;
        specimen.description = params.description;
        specimen.generation = params.generation;
        specimen.augmentation = params.augmentation;
        specimen.baseUri = params.baseUri;
        specimen.defined = true;
        specimen.definitionTime = block.timestamp;
    }

    function _updateSpecimenInternal(
        CreateSpecimenParams calldata params,
        uint256 specimenKey,
        LibCollectionStorage.CollectionStorage storage cs
    ) private {
        LibCollectionStorage.TokenSpecimen storage specimen = cs.tokenSpecimens[params.collectionId][specimenKey];
        
        specimen.form = params.form;
        specimen.formName = params.formName;
        specimen.description = params.description;
        specimen.generation = params.generation;
        specimen.augmentation = params.augmentation;
        specimen.baseUri = params.baseUri;
    }

    function _defineAccessoryInternal(
        CreateAccessoryParams calldata params,
        LibCollectionStorage.CollectionStorage storage cs
    ) private {
        LibCollectionStorage.AccessoryToken storage accessory = cs.accessoryTokens[params.collectionId][params.tokenId];
        
        accessory.accessoryId = params.accessoryId;
        accessory.name = params.name;
        accessory.description = params.description;
        accessory.imageURI = params.imageURI;
        accessory.compatibleVariants = params.compatibleVariants;
        accessory.defined = true;
        accessory.creationTime = block.timestamp;
        
        for (uint256 i = 0; i < params.properties.length; i++) {
            LibCollectionStorage.AccessoryProperties memory prop = LibCollectionStorage.AccessoryProperties({
                propertyType: params.properties[i].propertyType,
                propertyName: params.properties[i].propertyName,
                rare: params.properties[i].rare,
                chargeBoost: params.properties[i].chargeBoost,
                regenBoost: params.properties[i].regenBoost,
                efficiencyBoost: params.properties[i].efficiencyBoost,
                kinshipBonus: params.properties[i].kinshipBonus,
                wearResistance: params.properties[i].wearResistance,
                calibrationBonus: params.properties[i].calibrationBonus,
                stakingBoostPercentage: params.properties[i].stakingBoostPercentage,
                xpGainMultiplier: params.properties[i].xpGainMultiplier
            });
            accessory.properties.push(prop);
        }
    }

    function _updateAccessoryInternal(
        CreateAccessoryParams calldata params,
        LibCollectionStorage.CollectionStorage storage cs
    ) private {
        LibCollectionStorage.AccessoryToken storage accessory = cs.accessoryTokens[params.collectionId][params.tokenId];
        
        accessory.accessoryId = params.accessoryId;
        accessory.name = params.name;
        accessory.description = params.description;
        accessory.imageURI = params.imageURI;
        accessory.compatibleVariants = params.compatibleVariants;
        
        delete accessory.properties;
        for (uint256 i = 0; i < params.properties.length; i++) {
            LibCollectionStorage.AccessoryProperties memory prop = LibCollectionStorage.AccessoryProperties({
                propertyType: params.properties[i].propertyType,
                propertyName: params.properties[i].propertyName,
                rare: params.properties[i].rare,
                chargeBoost: params.properties[i].chargeBoost,
                regenBoost: params.properties[i].regenBoost,
                efficiencyBoost: params.properties[i].efficiencyBoost,
                kinshipBonus: params.properties[i].kinshipBonus,
                wearResistance: params.properties[i].wearResistance,
                calibrationBonus: params.properties[i].calibrationBonus,
                stakingBoostPercentage: params.properties[i].stakingBoostPercentage,
                xpGainMultiplier: params.properties[i].xpGainMultiplier
            });
            accessory.properties.push(prop);
        }
    }

    function _createTraitPackInternal(
        CreateTraitPackParams calldata params,
        LibCollectionStorage.CollectionStorage storage cs
    ) private {
        TraitPack storage traitPack = cs.traitPacks[params.traitPackId];
        traitPack.id = params.traitPackId;
        traitPack.name = params.name;
        traitPack.description = params.description;
        traitPack.baseURI = params.baseURI;
        traitPack.enabled = params.enabled;
        traitPack.registrationTime = block.timestamp;
        
        cs.traitPackExists[params.traitPackId] = true;
        cs.traitPackAccessories[params.traitPackId] = params.accessoryIds;
        cs.traitPackCompatibleVariants[params.traitPackId] = params.compatibleVariants;
    }

    function _createThemeInternal(
        CreateThemeParams calldata params,
        LibCollectionStorage.CollectionStorage storage cs
    ) private {
        LibCollectionStorage.CollectionTheme storage theme = cs.collectionThemes[params.collectionId];
        theme.themeName = params.themeName;
        theme.technologyBase = params.technologyBase;
        theme.evolutionContext = params.evolutionContext;
        theme.universeContext = params.universeContext;
        theme.preRevealHint = params.preRevealHint;
        theme.customNaming = params.customNaming;
        theme.createdAt = block.timestamp;
        theme.updatedAt = block.timestamp;
        
        cs.collectionThemeActive[params.collectionId] = true;
    }

    function _getSpecimenKey(uint8 variant, uint8 tier) private pure returns (uint256) {
        return (uint256(variant) << 8) | uint256(tier);
    }
}