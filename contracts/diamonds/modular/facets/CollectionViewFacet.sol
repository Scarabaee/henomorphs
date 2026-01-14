// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibCollectionStorage} from "../libraries/LibCollectionStorage.sol";
import {CollectionType, AccessoryDefinition, ExternalCollection} from "../libraries/ModularAssetModel.sol";
import {TraitPack} from "../libraries/CollectionModel.sol";
import {AccessControlBase} from "./AccessControlBase.sol";

/**
 * @title CollectionViewFacet - Collection-Scoped Trait Pack Views
 * @notice Clean, efficient read-only interface with collection-specific trait pack support
 * @dev PRODUCTION-READY: Maintains backward compatibility while adding collection-scoped views
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 * @custom:version 4.2.0 - Collection-scoped trait pack views
 */
contract CollectionViewFacet is AccessControlBase {
    
    // ==================== CUSTOM ERRORS ====================
    
    error InvalidCollectionType(uint256 collectionId, CollectionType expected);
    error SpecimenNotFound(uint256 collectionId, uint8 variant, uint8 tier);
    error AccessoryNotFound(uint256 collectionId, uint256 tokenId);
    error TraitPackNotFound(uint8 traitPackId);
    error CollectionTraitPackNotFound(uint256 collectionId, uint8 traitPackId);
    error AccessoryDefinitionNotFound(uint8 accessoryId);
    error ThemeNotFound(uint256 collectionId);
    error ExternalCollectionNotFound(uint256 collectionId);
    error InvalidVariant(uint8 variant);
    error InvalidTier(uint8 tier);
    error InvalidTokenId(uint256 tokenId);
    error InvalidAccessoryId(uint8 accessoryId);
    error InvalidTraitPackId(uint8 traitPackId);
    error AddressNotFound(address contractAddress);
    
    // ==================== CORE DATA STRUCTURES ====================
    
    struct SystemOverview {
        uint256 totalCollections;
        uint256 totalSpecimens;
        uint256 totalAccessories;
        uint256 totalTraitPacks;
        uint256 totalCollectionTraitPacks;
        CollectionTypeCounts typeCounts;
        uint256 snapshotTime;
    }
    
    struct CollectionTypeCounts {
        uint256 mainCollections;
        uint256 accessoryCollections;
        uint256 augmentCollections;
        uint256 externalCollections;
        uint256 enabledCollections;
    }
    
    struct CollectionInfo {
        uint256 collectionId;
        string name;
        string symbol;
        CollectionType collectionType;
        address contractAddress;
        bool enabled;
        
        uint256 currentSupply;
        uint256 maxSupply;
        uint256 utilizationPercent;
        
        ContentCounts content;
        CollectionFeatures features;
        
        uint256 createdAt;
        uint256 lastUpdated;

        // NEW: Add animation support indicator
        bool hasAnimationSupport;  // Whether collection has animation base URI configured
        bool allowDefaultMint;      // NEW: Show default mint capability
    }
    
    struct ContentCounts {
        uint256 specimens;
        uint256 accessories;
        uint256 traitPacks;
        uint256 collectionTraitPacks;
        uint8 configuredTiers;
        bool hasTheme;
        bool hasVariantThemes;
        uint256 themedVariants;
    }
    
    struct CollectionFeatures {
        bool multiAssetEnabled;
        bool nestableEnabled;
        bool equippableEnabled;
        bool externalSystemsEnabled;
        uint16 maxAssetsPerToken;
        uint16 maxChildrenPerToken;
        uint16 maxEquipmentSlots;
        address catalogAddress;
    }
    
    struct ThemeData {
        string themeName;
        string technologyBase;
        string evolutionContext;
        string universeContext;
        string preRevealHint;
        bool customNaming;
        bool active;
        uint256 createdAt;
        uint256 updatedAt;
    }
    
    struct VariantThemeData {
        uint8 variant;
        string customTechnology;
        string customContext;
        string evolutionStage;
        string powerLevel;
        bool hasCustomTheme;
    }
    
    struct ExternalCollectionData {
        uint256 collectionId;
        address collectionAddress;
        CollectionType collectionType;
        string name;
        string symbol;
        string description;
        uint8 defaultTier;
        bool enabled;
        uint256 registrationTime;
    }
    
    struct SpecimenData {
        uint8 variant;
        uint8 tier;
        string formName;
        string description;
        string baseUri;
        bool defined;
        uint256 definitionTime;
    }
    
    struct AccessoryData {
        uint256 tokenId;
        uint8 accessoryId;
        string name;
        string description;
        uint8[] compatibleVariants;
        bool defined;
        uint256 creationTime;
    }
    
    // ==================== NEW: COLLECTION-SCOPED TRAIT PACK STRUCTS ====================
    
    /**
     * @notice Collection-specific trait pack data
     * @dev Complete information about collection-scoped trait pack
     */
    struct CollectionTraitPackData {
        uint8 id;
        uint256 collectionId;
        string name;
        string description;
        string baseURI;
        bool enabled;
        uint8[] compatibleVariants;
        uint8[] accessoryIds;
        uint256 registrationTime;
    }
    
    /**
     * @notice Variant mapping information for collection
     * @dev Shows which variants are mapped to which trait packs
     */
    struct VariantTraitPackMapping {
        uint8 variant;
        uint8 traitPackId;
        string traitPackName;
        bool isCollectionScoped;
    }
    
    // ==================== EXISTING STRUCTS (unchanged) ====================
    
    struct TraitPackData {
        uint8 id;
        string name;
        string description;
        bool enabled;
        uint8[] compatibleVariants;
        uint8[] accessoryIds;
        uint256 registrationTime;
    }
    
    struct AccessoryDefinitionData {
        uint8 id;
        string name;
        string description;
        bool enabled;
        uint8[] compatibleTraitPacks;
        uint256 creationTime;
    }
    
    // ==================== SYSTEM OVERVIEW ====================
    
    function getSystemOverview() external view returns (SystemOverview memory overview) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        (overview.totalCollections, overview.typeCounts) = _countCollections(cs);
        overview.totalSpecimens = _countAllSpecimens(cs);
        overview.totalAccessories = _countAllAccessories(cs);
        overview.totalTraitPacks = _countTraitPacks(cs);
        overview.totalCollectionTraitPacks = _countCollectionTraitPacks(cs);
        overview.snapshotTime = block.timestamp;
    }
    
    // ==================== COLLECTION VIEWS ====================
    
    function getAllCollections() external view returns (CollectionInfo[] memory collections) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint256 count = 0;
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            if (LibCollectionStorage.collectionExists(i)) count++;
        }
        
        collections = new CollectionInfo[](count);
        uint256 index = 0;
        
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            if (LibCollectionStorage.collectionExists(i)) {
                collections[index] = _buildCollectionInfo(i, cs);
                index++;
            }
        }
    }
    
    function getCollectionsByType(CollectionType collectionType) external view returns (CollectionInfo[] memory collections) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint256 count = 0;
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            if (LibCollectionStorage.collectionExists(i) && _getCollectionType(i, cs) == collectionType) {
                count++;
            }
        }
        
        collections = new CollectionInfo[](count);
        uint256 index = 0;
        
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            if (LibCollectionStorage.collectionExists(i) && _getCollectionType(i, cs) == collectionType) {
                collections[index] = _buildCollectionInfo(i, cs);
                index++;
            }
        }
    }
    
    function getCollectionInfo(uint256 collectionId) external view returns (CollectionInfo memory) {
        if (!LibCollectionStorage.collectionExists(collectionId)) {
            revert CollectionNotFound(collectionId);
        }
        return _buildCollectionInfo(collectionId, LibCollectionStorage.collectionStorage());
    }
    
    function getEnabledCollections() external view returns (CollectionInfo[] memory collections) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint256 count = 0;
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            if (LibCollectionStorage.collectionExists(i) && _isCollectionEnabled(i, cs)) {
                count++;
            }
        }
        
        collections = new CollectionInfo[](count);
        uint256 index = 0;
        
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            if (LibCollectionStorage.collectionExists(i) && _isCollectionEnabled(i, cs)) {
                collections[index] = _buildCollectionInfo(i, cs);
                index++;
            }
        }
    }
    
    // ==================== SPECIMEN VIEWS (unchanged) ====================
    
    function getCollectionSpecimens(uint256 collectionId) external view returns (SpecimenData[] memory specimens) {
        if (!LibCollectionStorage.isInternalCollection(collectionId)) {
            revert InvalidCollectionType(collectionId, CollectionType.Main);
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint256 count = 0;
        for (uint16 variant = 0; variant <= 255; variant++) {
            for (uint8 tier = 1; tier <= 10; tier++) {
                uint256 specimenKey = _getSpecimenKey(uint8(variant), tier);
                if (cs.tokenSpecimens[collectionId][specimenKey].defined) {
                    count++;
                }
            }
        }
        
        specimens = new SpecimenData[](count);
        uint256 index = 0;
        
        for (uint16 variant = 0; variant <= 255; variant++) {
            for (uint8 tier = 1; tier <= 10; tier++) {
                uint256 specimenKey = _getSpecimenKey(uint8(variant), tier);
                LibCollectionStorage.TokenSpecimen storage specimen = cs.tokenSpecimens[collectionId][specimenKey];
                
                if (specimen.defined) {
                    specimens[index] = SpecimenData({
                        variant: uint8(variant),
                        tier: tier,
                        formName: specimen.formName,
                        description: specimen.description,
                        baseUri: specimen.baseUri,
                        defined: true,
                        definitionTime: specimen.definitionTime
                    });
                    index++;
                }
            }
        }
    }
    
    function getSpecimensByVariant(uint256 collectionId, uint8 variant) external view returns (SpecimenData[] memory specimens) {
        if (!LibCollectionStorage.isInternalCollection(collectionId)) {
            revert InvalidCollectionType(collectionId, CollectionType.Main);
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint256 count = 0;
        for (uint8 tier = 1; tier <= 10; tier++) {
            uint256 specimenKey = _getSpecimenKey(variant, tier);
            if (cs.tokenSpecimens[collectionId][specimenKey].defined) {
                count++;
            }
        }
        
        specimens = new SpecimenData[](count);
        uint256 index = 0;
        
        for (uint8 tier = 1; tier <= 10; tier++) {
            uint256 specimenKey = _getSpecimenKey(variant, tier);
            LibCollectionStorage.TokenSpecimen storage specimen = cs.tokenSpecimens[collectionId][specimenKey];
            
            if (specimen.defined) {
                specimens[index] = SpecimenData({
                    variant: variant,
                    tier: tier,
                    formName: specimen.formName,
                    description: specimen.description,
                    baseUri: specimen.baseUri,
                    defined: true,
                    definitionTime: specimen.definitionTime
                });
                index++;
            }
        }
    }
    
    function getSpecimen(uint256 collectionId, uint8 variant, uint8 tier) external view returns (SpecimenData memory specimen) {
        if (!LibCollectionStorage.isInternalCollection(collectionId)) {
            revert InvalidCollectionType(collectionId, CollectionType.Main);
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        uint256 specimenKey = _getSpecimenKey(variant, tier);
        LibCollectionStorage.TokenSpecimen storage storedSpecimen = cs.tokenSpecimens[collectionId][specimenKey];
        
        if (!storedSpecimen.defined) {
            revert SpecimenNotFound(collectionId, variant, tier);
        }
        
        specimen = SpecimenData({
            variant: variant,
            tier: tier,
            formName: storedSpecimen.formName,
            description: storedSpecimen.description,
            baseUri: storedSpecimen.baseUri,
            defined: true,
            definitionTime: storedSpecimen.definitionTime
        });
    }
    
    // ==================== ACCESSORY VIEWS (unchanged) ====================
    
    function getCollectionAccessories(uint256 collectionId) external view returns (AccessoryData[] memory accessories) {
        if (!LibCollectionStorage.isInternalCollection(collectionId)) {
            revert InvalidCollectionType(collectionId, CollectionType.Accessory);
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
        
        uint256 count = 0;
        for (uint256 i = 1; i <= collection.maxSupply; i++) {
            if (cs.accessoryTokens[collectionId][i].defined) {
                count++;
            }
        }
        
        accessories = new AccessoryData[](count);
        uint256 index = 0;
        
        for (uint256 i = 1; i <= collection.maxSupply; i++) {
            LibCollectionStorage.AccessoryToken storage accessory = cs.accessoryTokens[collectionId][i];
            if (accessory.defined) {
                accessories[index] = AccessoryData({
                    tokenId: i,
                    accessoryId: accessory.accessoryId,
                    name: accessory.name,
                    description: accessory.description,
                    compatibleVariants: accessory.compatibleVariants,
                    defined: true,
                    creationTime: accessory.creationTime
                });
                index++;
            }
        }
    }
    
    function getAccessory(uint256 collectionId, uint256 tokenId) external view returns (AccessoryData memory accessory) {
        if (!LibCollectionStorage.isInternalCollection(collectionId)) {
            revert InvalidCollectionType(collectionId, CollectionType.Accessory);
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.AccessoryToken storage storedAccessory = cs.accessoryTokens[collectionId][tokenId];
        
        if (!storedAccessory.defined) {
            revert AccessoryNotFound(collectionId, tokenId);
        }
        
        accessory = AccessoryData({
            tokenId: tokenId,
            accessoryId: storedAccessory.accessoryId,
            name: storedAccessory.name,
            description: storedAccessory.description,
            compatibleVariants: storedAccessory.compatibleVariants,
            defined: true,
            creationTime: storedAccessory.creationTime
        });
    }
    
    // ==================== NEW: COLLECTION-SCOPED TRAIT PACK VIEWS ====================
    
    /**
     * @notice Get all trait packs for specific collection
     * @param collectionId Collection ID
     * @return traitPacks Array of collection-specific trait packs
     */
    function getCollectionTraitPacks(uint256 collectionId) external view validCollection(collectionId) returns (CollectionTraitPackData[] memory traitPacks) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint8[] memory traitPackIds = cs.collectionTraitPackIds[collectionId];
        traitPacks = new CollectionTraitPackData[](traitPackIds.length);
        
        for (uint256 i = 0; i < traitPackIds.length; i++) {
            uint8 traitPackId = traitPackIds[i];
            if (cs.collectionTraitPackExists[collectionId][traitPackId]) {
                LibCollectionStorage.CollectionTraitPack storage pack = cs.collectionTraitPacks[collectionId][traitPackId];
                traitPacks[i] = CollectionTraitPackData({
                    id: pack.id,
                    collectionId: pack.collectionId,
                    name: pack.name,
                    description: pack.description,
                    baseURI: pack.baseURI,
                    enabled: pack.enabled,
                    compatibleVariants: pack.compatibleVariants,
                    accessoryIds: pack.accessoryIds,
                    registrationTime: pack.registrationTime
                });
            }
        }
    }
    
    /**
     * @notice Get specific collection trait pack
     * @param collectionId Collection ID
     * @param traitPackId Trait pack ID
     * @return traitPack Collection-specific trait pack data
     */
    function getCollectionTraitPack(uint256 collectionId, uint8 traitPackId) external view validCollection(collectionId) returns (CollectionTraitPackData memory traitPack) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!cs.collectionTraitPackExists[collectionId][traitPackId]) {
            revert CollectionTraitPackNotFound(collectionId, traitPackId);
        }
        
        LibCollectionStorage.CollectionTraitPack storage pack = cs.collectionTraitPacks[collectionId][traitPackId];
        traitPack = CollectionTraitPackData({
            id: pack.id,
            collectionId: pack.collectionId,
            name: pack.name,
            description: pack.description,
            baseURI: pack.baseURI,
            enabled: pack.enabled,
            compatibleVariants: pack.compatibleVariants,
            accessoryIds: pack.accessoryIds,
            registrationTime: pack.registrationTime
        });
    }
    
    /**
     * @notice Get enabled trait packs for specific collection
     * @param collectionId Collection ID
     * @return traitPacks Array of enabled collection-specific trait packs
     */
    function getEnabledCollectionTraitPacks(uint256 collectionId) external view validCollection(collectionId) returns (CollectionTraitPackData[] memory traitPacks) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint8[] memory traitPackIds = cs.collectionTraitPackIds[collectionId];
        uint256 enabledCount = 0;
        
        // Count enabled trait packs
        for (uint256 i = 0; i < traitPackIds.length; i++) {
            uint8 traitPackId = traitPackIds[i];
            if (cs.collectionTraitPackExists[collectionId][traitPackId] && 
                cs.collectionTraitPacks[collectionId][traitPackId].enabled) {
                enabledCount++;
            }
        }
        
        traitPacks = new CollectionTraitPackData[](enabledCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < traitPackIds.length; i++) {
            uint8 traitPackId = traitPackIds[i];
            if (cs.collectionTraitPackExists[collectionId][traitPackId] && 
                cs.collectionTraitPacks[collectionId][traitPackId].enabled) {
                LibCollectionStorage.CollectionTraitPack storage pack = cs.collectionTraitPacks[collectionId][traitPackId];
                traitPacks[index] = CollectionTraitPackData({
                    id: pack.id,
                    collectionId: pack.collectionId,
                    name: pack.name,
                    description: pack.description,
                    baseURI: pack.baseURI,
                    enabled: pack.enabled,
                    compatibleVariants: pack.compatibleVariants,
                    accessoryIds: pack.accessoryIds,
                    registrationTime: pack.registrationTime
                });
                index++;
            }
        }
    }
    
    /**
     * @notice Get variant to trait pack mappings for collection (collection-scoped)
     * @param collectionId Collection ID
     * @return mappings Array of variant-trait pack mappings
     */
    function getCollectionVariantTraitPackMappings(uint256 collectionId) external view validCollection(collectionId) returns (VariantTraitPackMapping[] memory mappings) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint256 count = 0;
        for (uint16 i = 0; i <= 255; i++) {
            if (cs.collectionVariantToTraitPack[collectionId][uint8(i)] != 0) {
                count++;
            }
        }
        
        mappings = new VariantTraitPackMapping[](count);
        uint256 index = 0;
        
        for (uint16 i = 0; i <= 255; i++) {
            uint8 traitPackId = cs.collectionVariantToTraitPack[collectionId][uint8(i)];
            if (traitPackId != 0) {
                string memory traitPackName = "";
                if (cs.collectionTraitPackExists[collectionId][traitPackId]) {
                    traitPackName = cs.collectionTraitPacks[collectionId][traitPackId].name;
                }
                
                mappings[index] = VariantTraitPackMapping({
                    variant: uint8(i),
                    traitPackId: traitPackId,
                    traitPackName: traitPackName,
                    isCollectionScoped: true
                });
                index++;
            }
        }
    }
    
    /**
     * @notice Get trait pack for specific variant (collection-scoped)
     * @param collectionId Collection ID
     * @param variant Variant number
     * @return traitPackId Trait pack ID (0 if not set)
     * @return traitPack Trait pack data
     * @return exists Whether mapping exists
     */
    function getCollectionVariantTraitPack(uint256 collectionId, uint8 variant) external view validCollection(collectionId) returns (uint8 traitPackId, CollectionTraitPackData memory traitPack, bool exists) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        traitPackId = cs.collectionVariantToTraitPack[collectionId][variant];
        exists = traitPackId != 0 && cs.collectionTraitPackExists[collectionId][traitPackId];
        
        if (exists) {
            LibCollectionStorage.CollectionTraitPack storage pack = cs.collectionTraitPacks[collectionId][traitPackId];
            traitPack = CollectionTraitPackData({
                id: pack.id,
                collectionId: pack.collectionId,
                name: pack.name,
                description: pack.description,
                baseURI: pack.baseURI,
                enabled: pack.enabled,
                compatibleVariants: pack.compatibleVariants,
                accessoryIds: pack.accessoryIds,
                registrationTime: pack.registrationTime
            });
        }
    }
    
    /**
     * @notice Get all collections that have trait packs defined
     * @return collections Array of collections with trait packs
     */
    function getCollectionsWithTraitPacks() external view returns (CollectionInfo[] memory collections) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint256 count = 0;
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            if (LibCollectionStorage.collectionExists(i) && cs.collectionTraitPackIds[i].length > 0) {
                count++;
            }
        }
        
        collections = new CollectionInfo[](count);
        uint256 index = 0;
        
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            if (LibCollectionStorage.collectionExists(i) && cs.collectionTraitPackIds[i].length > 0) {
                collections[index] = _buildCollectionInfo(i, cs);
                index++;
            }
        }
    }
    
    // ==================== LEGACY: GLOBAL TRAIT PACK VIEWS (maintained for compatibility) ====================
    
    function getAllTraitPacks() external view returns (TraitPackData[] memory traitPacks) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint256 count = 0;
        for (uint8 i = 1; i <= 255; i++) {
            if (cs.traitPackExists[i]) count++;
        }
        
        traitPacks = new TraitPackData[](count);
        uint256 index = 0;
        
        for (uint8 i = 1; i <= 255; i++) {
            if (cs.traitPackExists[i]) {
                TraitPack storage pack = cs.traitPacks[i];
                traitPacks[index] = TraitPackData({
                    id: i,
                    name: pack.name,
                    description: pack.description,
                    enabled: pack.enabled,
                    compatibleVariants: cs.traitPackCompatibleVariants[i],
                    accessoryIds: cs.traitPackAccessories[i],
                    registrationTime: pack.registrationTime
                });
                index++;
            }
        }
    }
    
    function getTraitPack(uint8 traitPackId) external view returns (TraitPackData memory traitPack) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        if (!cs.traitPackExists[traitPackId]) {
            revert TraitPackNotFound(traitPackId);
        }
        
        TraitPack storage pack = cs.traitPacks[traitPackId];
        traitPack = TraitPackData({
            id: traitPackId,
            name: pack.name,
            description: pack.description,
            enabled: pack.enabled,
            compatibleVariants: cs.traitPackCompatibleVariants[traitPackId],
            accessoryIds: cs.traitPackAccessories[traitPackId],
            registrationTime: pack.registrationTime
        });
    }
    
    function getEnabledTraitPacks() external view returns (TraitPackData[] memory traitPacks) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint256 count = 0;
        for (uint8 i = 1; i <= 255; i++) {
            if (cs.traitPackExists[i] && cs.traitPacks[i].enabled) count++;
        }
        
        traitPacks = new TraitPackData[](count);
        uint256 index = 0;
        
        for (uint8 i = 1; i <= 255; i++) {
            if (cs.traitPackExists[i] && cs.traitPacks[i].enabled) {
                TraitPack storage pack = cs.traitPacks[i];
                traitPacks[index] = TraitPackData({
                    id: i,
                    name: pack.name,
                    description: pack.description,
                    enabled: pack.enabled,
                    compatibleVariants: cs.traitPackCompatibleVariants[i],
                    accessoryIds: cs.traitPackAccessories[i],
                    registrationTime: pack.registrationTime
                });
                index++;
            }
        }
    }
    
    /**
     * @notice Get legacy variant to trait pack mappings (global mapping)
     * @dev DEPRECATED: Use getCollectionVariantTraitPackMappings instead
     * @param collectionId Collection ID
     * @return variants Array of variant numbers
     * @return traitPackIds Array of trait pack IDs
     */
    function getVariantTraitPackMappings(uint256 collectionId) external view returns (uint8[] memory variants, uint8[] memory traitPackIds) {
        if (!LibCollectionStorage.isInternalCollection(collectionId)) {
            revert InvalidCollectionType(collectionId, CollectionType.Main);
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint256 count = 0;
        for (uint16 i = 0; i <= 255; i++) {
            if (cs.variantToTraitPack[collectionId][uint8(i)] != 0) {
                count++;
            }
        }
        
        variants = new uint8[](count);
        traitPackIds = new uint8[](count);
        uint256 index = 0;
        
        for (uint16 i = 0; i <= 255; i++) {
            uint8 traitPackId = cs.variantToTraitPack[collectionId][uint8(i)];
            if (traitPackId != 0) {
                variants[index] = uint8(i);
                traitPackIds[index] = traitPackId;
                index++;
            }
        }
    }
    
    // ==================== ACCESSORY DEFINITION VIEWS (unchanged) ====================
    
    function getAllAccessoryDefinitions() external view returns (AccessoryDefinitionData[] memory definitions) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint256 count = 0;
        for (uint8 i = 1; i <= 255; i++) {
            if (cs.accessoryExists[i]) count++;
        }
        
        definitions = new AccessoryDefinitionData[](count);
        uint256 index = 0;
        
        for (uint8 i = 1; i <= 255; i++) {
            if (cs.accessoryExists[i]) {
                AccessoryDefinition storage def = cs.accessoryDefinitions[i];
                definitions[index] = AccessoryDefinitionData({
                    id: i,
                    name: def.name,
                    description: def.description,
                    enabled: def.enabled,
                    compatibleTraitPacks: def.compatibleTraitPacks,
                    creationTime: def.creationTime
                });
                index++;
            }
        }
    }
    
    function getAccessoryDefinition(uint8 accessoryId) external view returns (AccessoryDefinitionData memory definition) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        if (!cs.accessoryExists[accessoryId]) {
            revert AccessoryDefinitionNotFound(accessoryId);
        }
        
        AccessoryDefinition storage def = cs.accessoryDefinitions[accessoryId];
        definition = AccessoryDefinitionData({
            id: accessoryId,
            name: def.name,
            description: def.description,
            enabled: def.enabled,
            compatibleTraitPacks: def.compatibleTraitPacks,
            creationTime: def.creationTime
        });
    }
    
    // ==================== THEME VIEWS (unchanged) ====================
    
    function getCollectionTheme(uint256 collectionId) external view returns (ThemeData memory theme) {
        if (!LibCollectionStorage.isInternalCollection(collectionId)) {
            revert InvalidCollectionType(collectionId, CollectionType.Main);
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        LibCollectionStorage.CollectionTheme storage storedTheme = cs.collectionThemes[collectionId];
        bool active = cs.collectionThemeActive[collectionId];
        
        theme = ThemeData({
            themeName: storedTheme.themeName,
            technologyBase: storedTheme.technologyBase,
            evolutionContext: storedTheme.evolutionContext,
            universeContext: storedTheme.universeContext,
            preRevealHint: storedTheme.preRevealHint,
            customNaming: storedTheme.customNaming,
            active: active,
            createdAt: storedTheme.createdAt,
            updatedAt: storedTheme.updatedAt
        });
    }
    
    function getVariantThemes(uint256 collectionId, uint8 tier) external view returns (VariantThemeData[] memory themes) {
        if (!LibCollectionStorage.isInternalCollection(collectionId)) {
            revert InvalidCollectionType(collectionId, CollectionType.Main);
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint256 count = 0;
        for (uint16 i = 0; i <= 255; i++) {
            if (cs.variantThemes[collectionId][tier][uint8(i)].hasCustomTheme) {
                count++;
            }
        }
        
        themes = new VariantThemeData[](count);
        uint256 index = 0;
        
        for (uint16 i = 0; i <= 255; i++) {
            LibCollectionStorage.VariantTheme storage variantTheme = cs.variantThemes[collectionId][tier][uint8(i)];
            if (variantTheme.hasCustomTheme) {
                themes[index] = VariantThemeData({
                    variant: uint8(i),
                    customTechnology: variantTheme.customTechnology,
                    customContext: variantTheme.customContext,
                    evolutionStage: variantTheme.evolutionStage,
                    powerLevel: variantTheme.powerLevel,
                    hasCustomTheme: true
                });
                index++;
            }
        }
    }
    
    function getVariantTheme(uint256 collectionId, uint8 tier, uint8 variant) external view validInternalCollection(collectionId) returns (VariantThemeData memory theme) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        LibCollectionStorage.VariantTheme storage variantTheme = cs.variantThemes[collectionId][tier][variant];
        
        theme = VariantThemeData({
            variant: variant,
            customTechnology: variantTheme.customTechnology,
            customContext: variantTheme.customContext,
            evolutionStage: variantTheme.evolutionStage,
            powerLevel: variantTheme.powerLevel,
            hasCustomTheme: variantTheme.hasCustomTheme
        });
    }
    
    function getAllThemedCollections() external view returns (CollectionInfo[] memory collections) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint256 count = 0;
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            if (LibCollectionStorage.isInternalCollection(i) && cs.collectionThemeActive[i]) {
                count++;
            }
        }
        
        collections = new CollectionInfo[](count);
        uint256 index = 0;
        
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            if (LibCollectionStorage.isInternalCollection(i) && cs.collectionThemeActive[i]) {
                collections[index] = _buildCollectionInfo(i, cs);
                index++;
            }
        }
    }
    
    // ==================== EXTERNAL COLLECTION VIEWS (unchanged) ====================
    
    function getAllExternalCollections() external view returns (ExternalCollectionData[] memory collections) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint256 count = 0;
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            if (LibCollectionStorage.isExternalCollection(i)) {
                count++;
            }
        }
        
        collections = new ExternalCollectionData[](count);
        uint256 index = 0;
        
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            if (LibCollectionStorage.isExternalCollection(i)) {
                collections[index] = _buildExternalCollectionData(i, cs);
                index++;
            }
        }
    }
    
    function getExternalCollection(uint256 collectionId) external view returns (ExternalCollectionData memory collection) {
        if (!LibCollectionStorage.isExternalCollection(collectionId)) {
            revert ExternalCollectionNotFound(collectionId);
        }
        return _buildExternalCollectionData(collectionId, LibCollectionStorage.collectionStorage());
    }
    
    function getExternalCollectionByAddress(address contractAddress) external view returns (ExternalCollectionData memory collection, bool exists) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        uint256 collectionId = cs.externalCollectionsByAddress[contractAddress];
        
        exists = collectionId != 0 && LibCollectionStorage.isExternalCollection(collectionId);
        if (exists) {
            collection = _buildExternalCollectionData(collectionId, cs);
        } else if (contractAddress == address(0)) {
            revert AddressNotFound(contractAddress);
        }
    }
    
    // ==================== COLLECTION FEATURES VIEW (unchanged) ====================
    
    function getCollectionFeatures(uint256 collectionId) external view returns (CollectionFeatures memory features) {
        if (!LibCollectionStorage.isInternalCollection(collectionId)) {
            revert InvalidCollectionType(collectionId, CollectionType.Main);
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
        
        features = CollectionFeatures({
            multiAssetEnabled: collection.multiAssetEnabled,
            nestableEnabled: collection.nestableEnabled,
            equippableEnabled: collection.equippableEnabled,
            externalSystemsEnabled: collection.externalSystemsEnabled,
            maxAssetsPerToken: collection.maxAssetsPerToken,
            maxChildrenPerToken: collection.maxChildrenPerToken,
            maxEquipmentSlots: collection.maxEquipmentSlots,
            catalogAddress: collection.catalogAddress
        });
    }
    
    function getCollectionsWithFeature(string calldata featureName) external view returns (CollectionInfo[] memory collections) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        bytes32 featureHash = keccak256(bytes(featureName));
        
        uint256 count = 0;
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            if (LibCollectionStorage.isInternalCollection(i) && _hasFeature(i, featureHash, cs)) {
                count++;
            }
        }
        
        collections = new CollectionInfo[](count);
        uint256 index = 0;
        
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            if (LibCollectionStorage.isInternalCollection(i) && _hasFeature(i, featureHash, cs)) {
                collections[index] = _buildCollectionInfo(i, cs);
                index++;
            }
        }
    }
    
    // ==================== UTILITY FUNCTIONS ====================
    
    function collectionExists(uint256 collectionId) external view returns (bool) {
        return LibCollectionStorage.collectionExists(collectionId);
    }
    
    function isInternalCollection(uint256 collectionId) external view returns (bool) {
        return LibCollectionStorage.isInternalCollection(collectionId);
    }
    
    function isExternalCollection(uint256 collectionId) external view returns (bool) {
        return LibCollectionStorage.isExternalCollection(collectionId);
    }
    
    function specimenExists(uint256 collectionId, uint8 variant, uint8 tier) external view returns (bool) {
        if (!LibCollectionStorage.isInternalCollection(collectionId)) return false;
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        uint256 specimenKey = _getSpecimenKey(variant, tier);
        return cs.tokenSpecimens[collectionId][specimenKey].defined;
    }
    
    function accessoryExists(uint256 collectionId, uint256 tokenId) external view returns (bool) {
        if (!LibCollectionStorage.isInternalCollection(collectionId)) return false;
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        return cs.accessoryTokens[collectionId][tokenId].defined;
    }
    
    function traitPackExists(uint8 traitPackId) external view returns (bool) {
        return LibCollectionStorage.collectionStorage().traitPackExists[traitPackId];
    }
    
    /**
     * @notice Check if collection trait pack exists
     * @param collectionId Collection ID
     * @param traitPackId Trait pack ID
     * @return exists Whether collection trait pack exists
     */
    function collectionTraitPackExists(uint256 collectionId, uint8 traitPackId) external view returns (bool exists) {
        return LibCollectionStorage.collectionTraitPackExists(collectionId, traitPackId);
    }
    
    function accessoryDefinitionExists(uint8 accessoryId) external view returns (bool) {
        return LibCollectionStorage.collectionStorage().accessoryExists[accessoryId];
    }

    function isAugmentAllowed(
        uint256 collectionId,
        address augmentCollection
    ) external view returns (bool allowed, bool hasRestrictions) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        hasRestrictions = cs.augmentRestrictions[collectionId];
        allowed = !hasRestrictions || cs.allowedAugments[collectionId][augmentCollection];
        
        return (allowed, hasRestrictions);
    }
    
    // ==================== INTERNAL HELPERS ====================
    
    function _countCollections(LibCollectionStorage.CollectionStorage storage cs) 
        internal view returns (uint256 total, CollectionTypeCounts memory counts) {
        
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            if (!LibCollectionStorage.collectionExists(i)) continue;
            
            total++;
            
            if (_isCollectionEnabled(i, cs)) {
                counts.enabledCollections++;
            }
            
            CollectionType cType = _getCollectionType(i, cs);
            if (cType == CollectionType.Main) {
                counts.mainCollections++;
            } else if (cType == CollectionType.Accessory) {
                counts.accessoryCollections++;
            } else if (cType == CollectionType.Augment) {
                counts.augmentCollections++;
            }
            
            if (LibCollectionStorage.isExternalCollection(i)) {
                counts.externalCollections++;
            }
        }
    }
    
    function _countAllSpecimens(LibCollectionStorage.CollectionStorage storage cs) internal view returns (uint256 total) {
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            if (LibCollectionStorage.isInternalCollection(i) && _getCollectionType(i, cs) == CollectionType.Main) {
                total += _countCollectionSpecimens(i, cs);
            }
        }
    }
    
    function _countAllAccessories(LibCollectionStorage.CollectionStorage storage cs) internal view returns (uint256 total) {
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            if (LibCollectionStorage.isInternalCollection(i) && _getCollectionType(i, cs) == CollectionType.Accessory) {
                total += _countCollectionAccessories(i, cs);
            }
        }
    }
    
    function _countTraitPacks(LibCollectionStorage.CollectionStorage storage cs) internal view returns (uint256 count) {
        for (uint8 i = 1; i <= 255; i++) {
            if (cs.traitPackExists[i]) count++;
        }
    }
    
    /**
     * @notice Count collection-scoped trait packs across all collections
     * @param cs Collection storage
     * @return count Total number of collection trait packs
     */
    function _countCollectionTraitPacks(LibCollectionStorage.CollectionStorage storage cs) internal view returns (uint256 count) {
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            if (LibCollectionStorage.collectionExists(i)) {
                count += cs.collectionTraitPackIds[i].length;
            }
        }
    }
    
    function _buildCollectionInfo(uint256 collectionId, LibCollectionStorage.CollectionStorage storage cs) 
        internal view returns (CollectionInfo memory info) {
        
        if (LibCollectionStorage.isInternalCollection(collectionId)) {
            LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
            
            info.collectionId = collectionId;
            info.name = collection.name;
            info.symbol = collection.symbol;
            info.collectionType = collection.collectionType;
            info.contractAddress = collection.contractAddress;
            info.enabled = collection.enabled;
            info.currentSupply = collection.currentSupply;
            info.maxSupply = collection.maxSupply;
            info.utilizationPercent = collection.maxSupply > 0 ? 
                (collection.currentSupply * 100) / collection.maxSupply : 0;
            info.createdAt = collection.creationTime;
            info.lastUpdated = collection.lastUpdateTime;
            
            // Content counts
            if (collection.collectionType == CollectionType.Main) {
                info.content.specimens = _countCollectionSpecimens(collectionId, cs);
            } else if (collection.collectionType == CollectionType.Accessory) {
                info.content.accessories = _countCollectionAccessories(collectionId, cs);
            }
            
            // NEW: Add collection trait pack counts
            info.content.collectionTraitPacks = cs.collectionTraitPackIds[collectionId].length;
            
            info.content.configuredTiers = _countConfiguredTiers(collectionId, cs);
            info.content.hasTheme = cs.collectionThemeActive[collectionId];
            info.content.hasVariantThemes = _hasVariantThemes(collectionId, cs);
            info.content.themedVariants = _countThemedVariants(collectionId, cs);
            info.hasAnimationSupport = bytes(collection.animationBaseURI).length > 0;
            info.allowDefaultMint = collection.allowDefaultMint;  // NEW: Include in view
            
            // Collection features
            info.features = CollectionFeatures({
                multiAssetEnabled: collection.multiAssetEnabled,
                nestableEnabled: collection.nestableEnabled,
                equippableEnabled: collection.equippableEnabled,
                externalSystemsEnabled: collection.externalSystemsEnabled,
                maxAssetsPerToken: collection.maxAssetsPerToken,
                maxChildrenPerToken: collection.maxChildrenPerToken,
                maxEquipmentSlots: collection.maxEquipmentSlots,
                catalogAddress: collection.catalogAddress
            });
            
        } else if (LibCollectionStorage.isExternalCollection(collectionId)) {
            ExternalCollection storage _external = cs.externalCollections[collectionId];
            LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
            
            info.collectionId = collectionId;
            info.name = collection.name;
            info.symbol = collection.symbol;
            info.collectionType = _external.collectionType;
            info.contractAddress = _external.collectionAddress;
            info.enabled = _external.enabled;
            info.createdAt = _external.registrationTime;
            info.lastUpdated = _external.registrationTime;
            
            // External collections may also have collection trait packs
            info.content.collectionTraitPacks = cs.collectionTraitPackIds[collectionId].length;
        }
    }
    
    function _countCollectionSpecimens(uint256 collectionId, LibCollectionStorage.CollectionStorage storage cs) 
        internal view returns (uint256 count) {
        
        for (uint16 variant = 0; variant <= 255; variant++) {
            for (uint8 tier = 1; tier <= 10; tier++) {
                uint256 specimenKey = _getSpecimenKey(uint8(variant), tier);
                if (cs.tokenSpecimens[collectionId][specimenKey].defined) {
                    count++;
                }
            }
        }
    }
    
    function _countCollectionAccessories(uint256 collectionId, LibCollectionStorage.CollectionStorage storage cs) 
        internal view returns (uint256 count) {
        
        LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
        for (uint256 i = 1; i <= collection.maxSupply; i++) {
            if (cs.accessoryTokens[collectionId][i].defined) {
                count++;
            }
        }
    }
    
    function _countConfiguredTiers(uint256 collectionId, LibCollectionStorage.CollectionStorage storage cs) 
        internal view returns (uint8 count) {
        
        bool[11] memory tierHasContent; // Index 0 unused, 1-10 for tiers
        
        for (uint16 variant = 0; variant <= 255; variant++) {
            for (uint8 tier = 1; tier <= 10; tier++) {
                uint256 specimenKey = _getSpecimenKey(uint8(variant), tier);
                if (cs.tokenSpecimens[collectionId][specimenKey].defined) {
                    tierHasContent[tier] = true;
                }
            }
        }
        
        for (uint8 tier = 1; tier <= 10; tier++) {
            if (tierHasContent[tier]) count++;
        }
    }
    
    function _getCollectionType(uint256 collectionId, LibCollectionStorage.CollectionStorage storage cs) 
        internal view returns (CollectionType) {
        
        if (LibCollectionStorage.isInternalCollection(collectionId)) {
            return cs.collections[collectionId].collectionType;
        } else if (LibCollectionStorage.isExternalCollection(collectionId)) {
            return cs.externalCollections[collectionId].collectionType;
        }
        
        revert("Collection not found");
    }
    
    function _isCollectionEnabled(uint256 collectionId, LibCollectionStorage.CollectionStorage storage cs) 
        internal view returns (bool) {
        
        if (LibCollectionStorage.isInternalCollection(collectionId)) {
            return cs.collections[collectionId].enabled;
        } else if (LibCollectionStorage.isExternalCollection(collectionId)) {
            return cs.externalCollections[collectionId].enabled;
        }
        
        return false;
    }
    
    function _buildExternalCollectionData(uint256 collectionId, LibCollectionStorage.CollectionStorage storage cs) 
        internal view returns (ExternalCollectionData memory data) {
        
        ExternalCollection storage _external = cs.externalCollections[collectionId];
        LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
        
        data = ExternalCollectionData({
            collectionId: collectionId,
            collectionAddress: _external.collectionAddress,
            collectionType: _external.collectionType,
            name: collection.name,
            symbol: collection.symbol,
            description: collection.description,
            defaultTier: collection.defaultTier,
            enabled: _external.enabled,
            registrationTime: _external.registrationTime
        });
    }
    
    function _hasFeature(uint256 collectionId, bytes32 featureHash, LibCollectionStorage.CollectionStorage storage cs) 
        internal view returns (bool) {
        
        LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
        
        if (featureHash == keccak256("multiAsset")) {
            return collection.multiAssetEnabled;
        } else if (featureHash == keccak256("nestable")) {
            return collection.nestableEnabled;
        } else if (featureHash == keccak256("equippable")) {
            return collection.equippableEnabled;
        } else if (featureHash == keccak256("externalSystems")) {
            return collection.externalSystemsEnabled;
        }
        
        return false;
    }
    
    function _hasVariantThemes(uint256 collectionId, LibCollectionStorage.CollectionStorage storage cs) 
        internal view returns (bool) {
        
        for (uint8 tier = 1; tier <= 10; tier++) {
            for (uint16 variant = 0; variant <= 255; variant++) {
                if (cs.variantThemes[collectionId][tier][uint8(variant)].hasCustomTheme) {
                    return true;
                }
            }
        }
        return false;
    }
    
    function _countThemedVariants(uint256 collectionId, LibCollectionStorage.CollectionStorage storage cs) 
        internal view returns (uint256 count) {
        
        for (uint8 tier = 1; tier <= 10; tier++) {
            for (uint16 variant = 0; variant <= 255; variant++) {
                if (cs.variantThemes[collectionId][tier][uint8(variant)].hasCustomTheme) {
                    count++;
                }
            }
        }
    }

    function _getSpecimenKey(uint8 variant, uint8 tier) internal pure returns (uint256) {
        return (uint256(variant) << 8) | uint256(tier);
    }
}