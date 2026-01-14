// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibCollectionStorage} from "../libraries/LibCollectionStorage.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {MetadataHelper} from "../libraries/MetadataHelper.sol";
import {MetadataFallback, ModularAssetData, StakingStatus, AccessoryBonuses, CompatibilityScores} from "../libraries/MetadataFallback.sol";
import {ModularConfigData, Equipment, CollectionType} from "../libraries/ModularAssetModel.sol";
import {IBiopod, IChargepod, IStaking} from "../interfaces/IExternalSystems.sol"; 
import {ItemTier, TierVariant, Specimen, Calibration, PowerMatrix, ChargeAccessory, TraitPack} from "../libraries/CollectionModel.sol";
import {ISpecimenCollection} from "../interfaces/IExternalSystems.sol"; 

/**
 * @title MetadataFacet
 * @notice PRODUCTION READY: Metadata generation with theme support via MetadataHelper library
 * @dev Uses MetadataHelper library functions for theme integration
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 * @custom:version 4.1.1 - Production with theme support in library
 */
contract MetadataFacet is AccessControlBase {
    using Strings for uint256;
    using Strings for uint8;

    // Events
    event MetadataGenerated(uint256 indexed collectionId, uint256 indexed tokenId, uint8 discoveredTier, string metadataType);
    event MetadataOverrideSet(uint256 indexed collectionId, uint256 indexed tokenId, string customURI);
    event ExternalSystemQueried(uint256 indexed collectionId, address indexed systemAddress, bool success);
    
    // Custom errors
    error InvalidMetadataMode();
    error AccessoryCollectionNotSupported(uint256 collectionId);
    error TokenNotFoundInCollection(uint256 tokenId, uint256 collectionId);
    error InvalidCollectionTierContext();
    error MetadataGenerationFailed();
    error TierDiscoveryFailed(uint256 tokenId, uint256 collectionId);
    
    /**
     * @notice Generate token URI with automatic tier discovery and theme support
     */
    function generateTokenURI(
        uint256 collectionId,
        uint256 tokenId
    ) external view validCollection(collectionId) returns (string memory) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!LibCollectionStorage.isInternalCollection(collectionId)) {
            revert CollectionNotFound(collectionId);
        }
        
        _validateTokenInCollection(collectionId, tokenId);
        
        LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
        
        if (collection.collectionType == CollectionType.Accessory) {
            revert AccessoryCollectionNotSupported(collectionId);
        }
        
        // Auto-discover tier for this token
        uint8 discoveredTier = _discoverTokenTier(collectionId, tokenId);
        
        // Check override first
        string memory overrideUri = cs.tokenURIOverrides[collectionId][tokenId];
        if (bytes(overrideUri).length > 0) {
            return overrideUri;
        }

        // Get variant using discovered tier
        uint8 tokenVariant = _getTokenVariant(collectionId, discoveredTier, tokenId);
        
        // Get tier data from collection-specific mapping
        ItemTier storage tierData = cs.itemTiers[collectionId][discoveredTier];

        string memory uri = _generateURIByMode(collection, tierData, tokenVariant, collectionId, discoveredTier, tokenId);
        
        return uri;
    }
    
    /**
     * @notice Generate simple token URI with theme integration via library
     */
    function generateSimpleTokenURI(
        uint256 collectionId,
        uint256 tokenId
    ) external view validCollection(collectionId) returns (string memory) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!LibCollectionStorage.isInternalCollection(collectionId)) {
            revert CollectionNotFound(collectionId);
        }
        
        _validateTokenInCollection(collectionId, tokenId);
        
        LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
        
        if (collection.collectionType == CollectionType.Accessory) {
            revert AccessoryCollectionNotSupported(collectionId);
        }
        
        uint8 discoveredTier = _discoverTokenTier(collectionId, tokenId);
        
        string memory uri = _generateSimpleMetadata(collection, collectionId, discoveredTier, tokenId);
        
        return uri;
    }

    /**
     * @notice Set metadata override for specific token
     */
    function setTokenURIOverride(
        uint256 collectionId,
        uint256 tokenId,
        string calldata customURI
    ) external onlyAuthorized whenNotPaused validCollection(collectionId) {
        
        _validateTokenInCollection(collectionId, tokenId);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        cs.tokenURIOverrides[collectionId][tokenId] = customURI;
        
        emit MetadataOverrideSet(collectionId, tokenId, customURI);
    }

    /**
     * @notice Get metadata override for token
     */
    function getTokenURIOverride(
        uint256 collectionId,
        uint256 tokenId
    ) external view validCollection(collectionId) returns (string memory) {
        
        _validateTokenInCollection(collectionId, tokenId);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        return cs.tokenURIOverrides[collectionId][tokenId];
    }

    /**
     * @notice Get token metadata summary with theme information
     */
    function getTokenMetadataSummary(
        uint256 collectionId,
        uint256 tokenId
    ) external view validCollection(collectionId) returns (
        string memory tokenURI,
        string memory simpleURI,
        uint8 discoveredTier,
        uint8 variant,
        string memory overrideURI,
        bool hasExternalData,
        uint256 lastUpdateTime,
        string memory tierSource,
        bool hasTheme,
        string memory themeName
    ) {
        
        _validateTokenInCollection(collectionId, tokenId);
        
        (discoveredTier, tierSource) = _discoverTokenTierWithSource(collectionId, tokenId);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        tokenURI = this.generateTokenURI(collectionId, tokenId);
        simpleURI = this.generateSimpleTokenURI(collectionId, tokenId);
        variant = _getTokenVariant(collectionId, discoveredTier, tokenId);
        overrideURI = cs.tokenURIOverrides[collectionId][tokenId];
        hasExternalData = _hasExternalSystemData(collectionId, tokenId);
        
        // Theme information
        hasTheme = cs.collectionThemeActive[collectionId];
        if (hasTheme) {
            themeName = cs.collectionThemes[collectionId].themeName;
        }
        
        ModularConfigData storage config = cs.modularConfigsData[collectionId][discoveredTier][tokenId];
        lastUpdateTime = config.lastUpdateTime;
        
        return (tokenURI, simpleURI, discoveredTier, variant, overrideURI, hasExternalData, lastUpdateTime, tierSource, hasTheme, themeName);
    }

    /**
     * @notice Discover what tier a token belongs to in a collection
     */
    function discoverTokenTier(
        uint256 collectionId,
        uint256 tokenId
    ) external view validCollection(collectionId) returns (uint8 discoveredTier, string memory source) {
        
        _validateTokenInCollection(collectionId, tokenId);
        
        return _discoverTokenTierWithSource(collectionId, tokenId);
    }

    /**
     * @notice Check if token exists in collection
     */
    function tokenExistsInCollection(
        uint256 collectionId,
        uint256 tokenId
    ) external view validCollection(collectionId) returns (bool exists, uint8 discoveredTier) {
        _validateTokenInCollection(collectionId, tokenId);

        try this.discoverTokenTier(collectionId, tokenId) returns (uint8 tier, string memory) {
            return (true, tier);
        } catch {
            return (true, 0);
        }
    }
    
    /**
     * @notice Get external system status
     */
    function getExternalSystemStatus() external view returns (
        bool biopodAvailable,
        bool chargepodAvailable, 
        bool stakingAvailable
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        return (
            _isSystemAvailable(cs.biopodAddress),
            _isSystemAvailable(cs.chargepodAddress),
            _isSystemAvailable(cs.stakingSystemAddress)
        );
    }

    // ==================== TIER DISCOVERY LOGIC ====================
    
    function _discoverTokenTierWithSource(
        uint256 collectionId,
        uint256 tokenId
    ) internal view returns (uint8 discoveredTier, string memory source) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        LibCollectionStorage.TokenContext memory context = LibCollectionStorage.getTokenContext(collectionId, tokenId);
        if (context.exists && context.collectionId == collectionId) {
            return (context.tier, "TokenContext");
        }
        
        for (uint8 tier = 1; tier <= 10; tier++) {
            ModularConfigData storage config = cs.modularConfigsData[collectionId][tier][tokenId];
            if (config.lastUpdateTime > 0) {
                return (tier, "ModularConfig");
            }
        }
        
        LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
        for (uint8 tier = 1; tier <= 10; tier++) {
            uint8 variant = cs.itemsVariants[collectionId][tier][tokenId];
            if (variant > 0) {
                return (tier, "VariantAssignment");
            }
        }
        
        if (cs.collectionItemsVarianted[collectionId][tokenId] > 0) {
            return (collection.defaultTier, "CollectionDefault");
        }
        
        if (collection.defaultTier > 0) {
            return (collection.defaultTier, "FallbackDefault");
        }
        
        return (1, "SystemFallback");
    }
    
    function _discoverTokenTier(uint256 collectionId, uint256 tokenId) internal view returns (uint8) {
        (uint8 tier, ) = _discoverTokenTierWithSource(collectionId, tokenId);
        return tier;
    }

    // ==================== URI GENERATION WITH THEME SUPPORT ====================
    
    /**
     * @notice Generate URI based on metadata mode with theme support
     */
    function _generateURIByMode(
        LibCollectionStorage.CollectionData storage collection,
        ItemTier storage tierData,
        uint8 variant,
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId
    ) internal view returns (string memory) {
        
        if (collection.metadataMode == LibCollectionStorage.MetadataMode.Static) {
            return _generateStaticURIWithTheme(collection, tierData, variant, collectionId, tier);
        }
        
        if (collection.metadataMode == LibCollectionStorage.MetadataMode.Dynamic) {
            return _generateDynamicURI(collection, collectionId, tier, tokenId);
        }
        
        if (collection.metadataMode == LibCollectionStorage.MetadataMode.Hybrid) {
            return _generateHybridURI(collection, collectionId, tier, tokenId);
        }
        
        revert InvalidMetadataMode();
    }

    /**
     * @notice Generate static URI with theme awareness
     */
    function _generateStaticURIWithTheme(
        LibCollectionStorage.CollectionData storage collection,
        ItemTier storage tierData,
        uint8 variant,
        uint256 collectionId,
        uint8 tier
    ) internal view returns (string memory) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        string memory prefix = collection.collectionType == CollectionType.Main ? "H" : "A";
        string memory _tokenUri = string.concat(
            collection.baseURI,
            prefix,
            tier.toString(),
            "_s"
        );
        
        // Theme-based variant naming
        if (cs.collectionThemeActive[collectionId]) {
            LibCollectionStorage.VariantTheme storage variantTheme = cs.variantThemes[collectionId][tier][variant];
            if (variantTheme.hasCustomTheme && bytes(variantTheme.evolutionStage).length > 0) {
                _tokenUri = string.concat(_tokenUri, "_", variantTheme.evolutionStage);
            } else if (tierData.variantsCount > 1) {
                _tokenUri = string.concat(_tokenUri, "_", variant.toString());
            }
        } else if (tierData.variantsCount > 1) {
            _tokenUri = string.concat(_tokenUri, "_", variant.toString());
        }
        
        return string.concat(_tokenUri, ".json");
    }
    
    /**
     * @notice Generate dynamic URI with theme support
     */
    function _generateDynamicURI(
        LibCollectionStorage.CollectionData storage collection,
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId
    ) internal view returns (string memory) {
        
        if (collection.collectionType == CollectionType.Main) {
            return _buildMainTokenMetadata(collectionId, tier, tokenId);
        }
        
        if (collection.collectionType == CollectionType.Augment) {
            return _buildAugmentTokenMetadata(collectionId, tier, tokenId);
        }
        
        revert UnsupportedCollectionType(collectionId, "");
    }
    
    /**
     * @notice Generate hybrid URI with theme fallback
     */
    function _generateHybridURI(
        LibCollectionStorage.CollectionData storage collection,
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId
    ) internal view returns (string memory) {
        
        try this.generateTokenURI(collectionId, tokenId) returns (string memory uri) {
            return uri;
        } catch {
            return string.concat(
                collection.baseURI,
                collectionId.toString(),
                "_",
                tier.toString(),
                "_",
                tokenId.toString(),
                ".json"
            );
        }
    }
    
    // ==================== MAIN TOKEN METADATA WITH THEME ====================
    
    /**
     * @notice Build main token metadata with theme integration
     * Uses MetadataHelper library functions
     */
    function _buildMainTokenMetadata(uint256 collectionId, uint8 tier, uint256 tokenId) internal view returns (string memory) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
        
        uint8 tokenVariant = _getTokenVariant(collectionId, tier, tokenId);
        
        // Check if token has active augment assignment
        bytes32 assignmentKey = cs.specimenToAssignment[collection.contractAddress][tokenId];
        bool hasActiveAugment = false;
        string memory augmentName = "";
        
        if (assignmentKey != bytes32(0)) {
            LibCollectionStorage.AugmentAssignment storage assignment = cs.augmentAssignments[assignmentKey];
            hasActiveAugment = assignment.active && 
                            (assignment.unlockTime == 0 || block.timestamp < assignment.unlockTime);
            
            if (hasActiveAugment) {
                augmentName = _getAugmentName(assignment.augmentCollection, assignment.augmentTokenId, assignment.augmentVariant);
            }
        }
        
        // Build core data
        MetadataHelper.CoreTokenData memory coreData = MetadataHelper.CoreTokenData({
            tokenId: tokenId,
            tokenTier: tier,
            tokenVariant: tokenVariant,
            baseUri: collection.baseURI,
            externalUrl: "https://zico.network",
            animationUri: _determineAnimationUri(collection, collectionId, tier, tokenVariant, tokenId)
        });
        
        // Build system data
        MetadataHelper.SystemData memory systemData = MetadataHelper.SystemData({
            specimen: _buildSpecimenData(collectionId, tier, tokenVariant),
            calibration: _getCalibrationWithFallback(collectionId, tier, tokenId, tokenVariant),
            powerMatrix: _getPowerMatrixWithFallback(collectionId, tier, tokenId, tokenVariant),
            stakingStatus: _getStakingStatusWithFallback(collectionId, tier, tokenId),
            accessoryBonuses: _calculateAccessoryBonuses(collectionId, tier, tokenId),
            compatibility: _calculateCompatibilityScores(tokenVariant, collectionId, tier, tokenId)
        });
        
        // Build modular data with augment information
        ModularConfigData storage modularConfig = cs.modularConfigsData[collectionId][tier][tokenId];
        (string memory traitPackName, string memory traitPackUri) = _getTraitPackInfo(modularConfig.activeTraitPackId);
        string memory assetUri = _getAssetUri(modularConfig.activeAssetId);
        
        // Override with augment info if present
        if (hasActiveAugment) {
            traitPackName = augmentName;
            traitPackUri = ""; // Augments use base collection URI
        }
        
        MetadataHelper.ModularData memory modularData = MetadataHelper.ModularData({
            activeTraitPackId: hasActiveAugment ? cs.augmentAssignments[assignmentKey].augmentVariant : modularConfig.activeTraitPackId,
            traitPackName: traitPackName,
            traitPackUri: traitPackUri,
            activeAssetId: modularConfig.activeAssetId,
            assetUri: assetUri,
            equipments: modularConfig.equipments
        });
        
        // Build theme data
        MetadataHelper.ThemeData memory themeData = _buildThemeData(collectionId, tier, tokenVariant);
        
        // Generate metadata with theme support
        string memory json;
        if (themeData.hasTheme) {
            json = MetadataHelper.generateTokenMetadataWithTheme(coreData, systemData, modularData, themeData);
        } else {
            json = MetadataHelper.generateTokenMetadataFromData(coreData, systemData, modularData);
        }
        
        return MetadataHelper.encodeTokenURI(json);
    }

    /**
     * @notice Get augment name from collection-scoped trait packs
     * @dev PRODUCTION: Reads actual configured names, not hardcoded values
     */
    function _getAugmentName(address augmentCollection, uint256, uint8 augmentVariant) internal view returns (string memory) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Get collection ID for this augment collection
        uint256 collectionId = LibCollectionStorage.getCollectionIdByAddress(augmentCollection);
        
        if (collectionId > 0) {
            // PRIORITY 1: Check collection-scoped trait pack
            if (cs.collectionTraitPackExists[collectionId][augmentVariant]) {
                LibCollectionStorage.CollectionTraitPack storage traitPack = cs.collectionTraitPacks[collectionId][augmentVariant];
                if (bytes(traitPack.name).length > 0) {
                    return traitPack.name;
                }
            }
            
            // PRIORITY 2: Check global trait pack
            if (cs.traitPackExists[augmentVariant]) {
                TraitPack storage globalTraitPack = cs.traitPacks[augmentVariant];
                if (bytes(globalTraitPack.name).length > 0) {
                    return globalTraitPack.name;
                }
            }
            
            // PRIORITY 3: Use collection name + variant
            LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
            if (bytes(collection.name).length > 0) {
                return string.concat(collection.name, " V", augmentVariant.toString());
            }
        }
        
        // FALLBACK: Generic naming only if no configuration found
        return string.concat("Augment V", augmentVariant.toString());
    }
    
    /**
     * @notice Build augment token metadata with theme support
     */
    function _buildAugmentTokenMetadata(uint256 collectionId, uint8 tier, uint256 tokenId) internal view returns (string memory) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
        
        uint8 tokenVariant = _getTokenVariant(collectionId, tier, tokenId);
        string memory animationUri = _getAugmentAnimationUri(collection, collectionId, tier, tokenId);
        
        string memory json = MetadataHelper.generateAugmentMetadata(
            collectionId,
            tokenId,
            tier,
            tokenVariant,
            collection.contractAddress,
            collection.name,
            collection.baseURI,
            animationUri
        );
        
        return MetadataHelper.encodeTokenURI(json);
    }
    
    // ==================== SIMPLE METADATA WITH THEME ====================
    
    /**
     * @notice Generate simple metadata using ONLY existing MetadataHelper library functions
     */
    function _generateSimpleMetadata(
        LibCollectionStorage.CollectionData storage collection,
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId
    ) internal view returns (string memory) {
        
        uint8 tokenVariant = _getTokenVariant(collectionId, tier, tokenId);
        
        if (collection.collectionType == CollectionType.Main) {
            // Build simple main metadata using existing library functions
            LibCollectionStorage.TokenSpecimen storage specimenStorage = _findTokenSpecimen(collectionId, tier, tokenVariant);
            
            // Build core data for library
            MetadataHelper.CoreTokenData memory coreData = MetadataHelper.CoreTokenData({
                tokenId: tokenId,
                tokenTier: tier,
                tokenVariant: tokenVariant,
                baseUri: collection.baseURI,
                externalUrl: "https://zico.network",
                animationUri: "" // Simple metadata doesn't need animation
            });
            
            // Build minimal system data for simple metadata
            Specimen memory specimen = Specimen({
                variant: tokenVariant,
                form: specimenStorage.form,
                formName: specimenStorage.formName,
                description: specimenStorage.description,
                generation: specimenStorage.generation,
                augmentation: specimenStorage.augmentation,
                baseUri: specimenStorage.baseUri
            });
            
            // Create minimal calibration for simple metadata
            Calibration memory calibration = Calibration({
                tokenId: tokenId,
                owner: address(0),
                kinship: 50,
                lastInteraction: 0,
                experience: 0,
                charge: 0,
                lastCharge: 0,
                level: 1,
                prowess: 0,
                wear: 0,
                lastRecalibration: 0,
                calibrationCount: 0,
                locked: false,
                agility: 0,
                intelligence: 0,
                bioLevel: 1
            });
            
            // Create minimal system data
            MetadataHelper.SystemData memory systemData = MetadataHelper.SystemData({
                specimen: specimen,
                calibration: calibration,
                powerMatrix: _getMinimalPowerMatrix(),
                stakingStatus: _getMinimalStakingStatus(),
                accessoryBonuses: _getMinimalAccessoryBonuses(),
                compatibility: _getMinimalCompatibilityScores()
            });
            
            // Create minimal modular data
            MetadataHelper.ModularData memory modularData = MetadataHelper.ModularData({
                activeTraitPackId: 0,
                traitPackName: "",
                traitPackUri: "",
                activeAssetId: 0,
                assetUri: "",
                equipments: new Equipment[](0)
            });
            
            // Build theme data
            MetadataHelper.ThemeData memory themeData = _buildThemeData(collectionId, tier, tokenVariant);
            
            // Use existing library functions to generate metadata
            string memory json;
            if (themeData.hasTheme) {
                json = MetadataHelper.generateTokenMetadataWithTheme(coreData, systemData, modularData, themeData);
            } else {
                json = MetadataHelper.generateTokenMetadataFromData(coreData, systemData, modularData);
            }
            
            return MetadataHelper.encodeTokenURI(json);
            
        } else if (collection.collectionType == CollectionType.Augment) {
            // Use existing library function for augment metadata
            string memory animationUri = _getAugmentAnimationUri(collection, collectionId, tier, tokenId);
            
            return MetadataHelper.generateAugmentMetadata(
                collectionId,
                tokenId,
                tier,
                tokenVariant,
                collection.contractAddress,
                collection.name,
                collection.baseURI,
                animationUri 
            );
        }
        
        revert UnsupportedCollectionType(collectionId, "");
    }
    
    /**
     * @notice Get minimal power matrix for simple metadata
     */
    function _getMinimalPowerMatrix() internal pure returns (PowerMatrix memory) {
        return PowerMatrix({
            currentCharge: 0,
            maxCharge: 100,
            lastChargeTime: 0,
            regenRate: 5,
            fatigueLevel: 0,
            boostEndTime: 0,
            chargeEfficiency: 50,
            consecutiveActions: 0,
            flags: 0,
            specialization: 0,
            seasonPoints: 0
        });
    }
    
    /**
     * @notice Get minimal staking status for simple metadata
     */
    function _getMinimalStakingStatus() internal pure returns (StakingStatus memory) {
        return StakingStatus({
            isStaked: false,
            stakingStartTime: 0,
            totalStakingTime: 0,
            stakingRewards: 0,
            stakingMultiplier: 100,
            colonyId: bytes32(0),
            colonyBonus: 0
        });
    }
    
    /**
     * @notice Get minimal accessory bonuses for simple metadata
     */
    function _getMinimalAccessoryBonuses() internal pure returns (AccessoryBonuses memory) {
        return AccessoryBonuses({
            efficiencyBonus: 0,
            regenBonus: 0,
            maxChargeBonus: 0,
            kinshipBonus: 0,
            wearResistance: 0,
            calibrationBonus: 0,
            stakingBonus: 0,
            xpMultiplier: 100
        });
    }
    
    /**
     * @notice Get minimal compatibility scores for simple metadata
     */
    function _getMinimalCompatibilityScores() internal pure returns (CompatibilityScores memory) {
        return CompatibilityScores({
            overallScore: 80,
            traitPackCompatibility: 80,
            variantBonus: 0,
            accessoryCompatibility: 0
        });
    }

    // ==================== THEME DATA BUILDERS ====================
    
    /**
     * @notice Build PRACTICAL theme data - only used fields
     */
    function _buildThemeData(uint256 collectionId, uint8 tier, uint8 tokenVariant) internal view returns (MetadataHelper.ThemeData memory) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        bool hasTheme = cs.collectionThemeActive[collectionId];
        
        if (!hasTheme) {
            return MetadataHelper.ThemeData({
                hasTheme: false,
                themeName: "",
                technologyBase: "",
                evolutionContext: "",
                universeContext: "",
                evolutionStage: "",
                powerLevel: "",
                hasCustomVariantTheme: false
            });
        }
        
        LibCollectionStorage.CollectionTheme storage collectionTheme = cs.collectionThemes[collectionId];
        LibCollectionStorage.VariantTheme storage variantTheme = cs.variantThemes[collectionId][tier][tokenVariant];
        
        return MetadataHelper.ThemeData({
            hasTheme: true,
            themeName: collectionTheme.themeName,
            technologyBase: collectionTheme.technologyBase,
            evolutionContext: collectionTheme.evolutionContext,
            universeContext: collectionTheme.universeContext,
            evolutionStage: variantTheme.evolutionStage,
            powerLevel: variantTheme.powerLevel,
            hasCustomVariantTheme: variantTheme.hasCustomTheme
        });
    }

    // ==================== DATA BUILDERS WITH THEME ====================
    
    /**
     * @notice Build specimen data with theme enhancement
     */
    function _buildSpecimenData(uint256 collectionId, uint8 tier, uint8 tokenVariant) internal view returns (Specimen memory) {
        LibCollectionStorage.TokenSpecimen storage tokenSpecimen = _findTokenSpecimen(collectionId, tier, tokenVariant);
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        string memory enhancedDescription = tokenSpecimen.description;
        
        // ENHANCED: Check for augment and add to description (minimal addition)
        // Note: This is simplified - in practice we'd need tokenId to check assignments
        // For now, just add theme enhancement as before
        if (cs.collectionThemeActive[collectionId]) {
            LibCollectionStorage.VariantTheme storage variantTheme = cs.variantThemes[collectionId][tier][tokenVariant];
            if (variantTheme.hasCustomTheme) {
                enhancedDescription = string.concat(
                    tokenSpecimen.description,
                    " Evolved to the ",
                    variantTheme.evolutionStage,
                    " stage."
                );
            }
        }
        
        return Specimen({
            variant: tokenVariant,
            form: tokenSpecimen.form,
            formName: tokenSpecimen.formName,
            description: enhancedDescription,
            generation: tokenSpecimen.generation,
            augmentation: tokenSpecimen.augmentation,
            baseUri: tokenSpecimen.baseUri
        });
    }
        
    /**
     * @notice Determine animation URI - FIXED: NO theme suffixes in file names
     */
    function _determineAnimationUri(
        LibCollectionStorage.CollectionData storage collection,
        uint256,
        uint8 tier,
        uint8 tokenVariant,
        uint256 tokenId
    ) internal view returns (string memory) {
        
        if (bytes(collection.animationBaseURI).length == 0) {
            return ""; // No animation support configured
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Check if token has active augment assignment
        bytes32 assignmentKey = cs.specimenToAssignment[collection.contractAddress][tokenId];
        if (assignmentKey != bytes32(0)) {
            LibCollectionStorage.AugmentAssignment storage assignment = cs.augmentAssignments[assignmentKey];
            
            if (assignment.active && (assignment.unlockTime == 0 || block.timestamp < assignment.unlockTime)) {
                // Token has active augment - use augmented naming (following HenomorphsMetadata pattern)
                return string.concat(
                    collection.animationBaseURI,
                    "H",
                    tier.toString(),
                    "_a_",
                    tokenVariant.toString(),
                    "_T",  // Trait pack marker (like HenomorphsMetadata)
                    assignment.augmentVariant.toString(),
                    ".mp4"
                );
            }
        }
        
        // Standard animation naming (unchanged)
        return string.concat(
            collection.animationBaseURI,
            "H",
            tier.toString(),
            "_a_",
            tokenVariant.toString(),
            ".mp4"
        );
    }
            
    /**
     * @notice Get augment animation URI with theme context
     */
    function _getAugmentAnimationUri(
        LibCollectionStorage.CollectionData storage collection,
        uint256,
        uint8,
        uint256
    ) internal view returns (string memory) {
        
        if (bytes(collection.baseURI).length > 0) {
            return "enabled";
        }
        
        return "";
    }

    // ==================== HELPER FUNCTIONS ====================
    
    function _validateTokenInCollection(uint256 collectionId, uint256 tokenId) internal view {
        (address contractAddress, , bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (!exists) {
            revert InvalidCollectionTierContext();
        }
        
        try IERC721(contractAddress).ownerOf(tokenId) returns (address) {
            return;
        } catch {
            revert TokenNotFoundInCollection(tokenId, collectionId);
        }
    }

    function _hasExternalSystemData(uint256 collectionId, uint256 tokenId) internal view returns (bool) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (cs.biopodAddress != address(0)) {
            try IBiopod(cs.biopodAddress).probeCalibration(collectionId, tokenId) returns (Calibration memory) {
                return true;
            } catch {}
        }
        
        if (cs.chargepodAddress != address(0)) {
            try IChargepod(cs.chargepodAddress).queryPowerMatrix(collectionId, tokenId) returns (PowerMatrix memory) {
                return true;
            } catch {}
        }
        
        if (cs.stakingSystemAddress != address(0)) {
            try IStaking(cs.stakingSystemAddress).getStakingInfo(collectionId, tokenId) returns (bool, uint256, uint256, uint8) {
                return true;
            } catch {}
        }
        
        return false;
    }
    
    function _getTokenVariant(uint256 collectionId, uint8 tier, uint256 tokenId) internal view returns (uint8) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
        
        // Check collection contract first
        if (collection.contractAddress != address(0)) {
            try ISpecimenCollection(collection.contractAddress).itemVariant(tokenId) returns (uint8 _variant) {
                return _variant; // Return unconditionally - variant 0 is valid (Matrix Core)
            } catch {}
        }
        
        // Check local storage
        uint8 variant = cs.itemsVariants[collectionId][tier][tokenId];
        
        // If token was ever varianted, return its variant (including 0)
        if (cs.collectionItemsVarianted[collectionId][tokenId] > 0) {
            return variant;
        }
        
        // Fallback to collection default
        if (collection.enabled && collection.defaultVariant > 0) {
            return collection.defaultVariant;
        }
        
        return 0; // Matrix Core for unrevealed tokens
    }
    
    function _findTokenSpecimen(
        uint256 collectionId,
        uint8 tier,
        uint8 tokenVariant
    ) internal view returns (LibCollectionStorage.TokenSpecimen storage) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint256 specimenKey = _getSpecimenKey(tokenVariant, tier);
        LibCollectionStorage.TokenSpecimen storage specimen = cs.tokenSpecimens[collectionId][specimenKey];
        
        if (specimen.defined) {
            return specimen;
        }
        
        specimenKey = _getSpecimenKey(tokenVariant, 1);
        return cs.tokenSpecimens[collectionId][specimenKey];
    }
    
    function _getSpecimenKey(uint8 variant, uint8 tier) internal pure returns (uint256) {
        return (uint256(variant) << 8) | uint256(tier);
    }
    
    function _isSystemAvailable(address systemAddress) internal pure returns (bool) {
        return systemAddress != address(0);
    }
    
    function _getTraitPackInfo(uint8 traitPackId) internal view returns (string memory name, string memory uri) {
        if (traitPackId == 0) return ("", "");
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (cs.traitPackExists[traitPackId]) {
            TraitPack storage traitPack = cs.traitPacks[traitPackId];
            return (traitPack.name, traitPack.baseURI);
        }
        
        return ("", "");
    }
    
    function _getAssetUri(uint64 assetId) internal view returns (string memory) {
        if (assetId == 0) return "";
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (cs.assetExists[assetId]) {
            return cs.assetRegistry[assetId].assetUri;
        }
        
        return "";
    }
    
    function _getColonyInfo(uint256 collectionId, uint256 tokenId) internal view returns (bytes32 colonyId, uint8 colonyBonus) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (cs.stakingSystemAddress != address(0)) {
            try IStaking(cs.stakingSystemAddress).getColonyInfo(collectionId, tokenId) returns (
                bytes32 colony,
                uint8 bonus
            ) {
                return (colony, bonus);
            } catch {}
        }
        
        return (bytes32(0), 0);
    }
    
    // ==================== EXTERNAL SYSTEM INTEGRATION ====================
    
    function _getCalibrationWithFallback(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        uint8 tokenVariant
    ) internal view returns (Calibration memory) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (cs.biopodAddress != address(0)) {
            try IBiopod(cs.biopodAddress).probeCalibration(collectionId, tokenId) returns (
                Calibration memory calibration
            ) {
                return calibration;
            } catch {}
        }
        
        ModularConfigData storage config = cs.modularConfigsData[collectionId][tier][tokenId];
        ModularAssetData memory assetData = ModularAssetData({
            tokenVariant: tokenVariant,
            activeTraitPackId: config.activeTraitPackId,
            traitPackIds: config.traitPackIds
        });
        
        return MetadataFallback.calculateFallbackCalibration(tokenId, assetData);
    }
    
    function _getPowerMatrixWithFallback(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        uint8 tokenVariant
    ) internal view returns (PowerMatrix memory) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (cs.chargepodAddress != address(0)) {
            try IChargepod(cs.chargepodAddress).queryPowerMatrix(collectionId, tokenId) returns (
                PowerMatrix memory powerMatrix
            ) {
                return powerMatrix;
            } catch {}
        }
        
        ModularConfigData storage config = cs.modularConfigsData[collectionId][tier][tokenId];
        ModularAssetData memory assetData = ModularAssetData({
            tokenVariant: tokenVariant,
            activeTraitPackId: config.activeTraitPackId,
            traitPackIds: config.traitPackIds
        });
        
        return MetadataFallback.calculateFallbackPowerMatrix(tokenId, assetData);
    }
    
    function _getStakingStatusWithFallback(
        uint256 collectionId,
        uint8,
        uint256 tokenId
    ) internal view returns (StakingStatus memory) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (cs.stakingSystemAddress != address(0)) {
            try IStaking(cs.stakingSystemAddress).getStakingInfo(collectionId, tokenId) returns (
                bool isStaked,
                uint256 stakingStartTime,
                uint256 totalRewards,
                uint8 currentMultiplier
            ) {
                (bytes32 colonyId, uint8 colonyBonus) = _getColonyInfo(collectionId, tokenId);
                
                return StakingStatus({
                    isStaked: isStaked,
                    stakingStartTime: stakingStartTime,
                    totalStakingTime: isStaked ? block.timestamp - stakingStartTime : 0,
                    stakingRewards: totalRewards,
                    stakingMultiplier: currentMultiplier,
                    colonyId: colonyId,
                    colonyBonus: colonyBonus
                });
                
            } catch {}
        }
        
        return MetadataFallback.calculateFallbackStakingStatus();
    }
    
    function _calculateAccessoryBonuses(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId
    ) internal view returns (AccessoryBonuses memory) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (cs.chargepodAddress != address(0)) {
            try IChargepod(cs.chargepodAddress).getTokenAccessories(collectionId, tokenId) returns (
                ChargeAccessory[] memory accessories
            ) {
                return _calculateBonusesFromAccessories(accessories);
            } catch {}
        }
        
        ModularConfigData storage modularConfig = cs.modularConfigsData[collectionId][tier][tokenId];
        return _calculateBonusesFromEquipments(modularConfig.equipments);
    }
    
    function _calculateCompatibilityScores(
        uint8 tokenVariant,
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId
    ) internal view returns (CompatibilityScores memory) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        ModularConfigData storage modularConfig = cs.modularConfigsData[collectionId][tier][tokenId];
        
        ModularAssetData memory assetData = ModularAssetData({
            tokenVariant: tokenVariant,
            activeTraitPackId: modularConfig.activeTraitPackId,
            traitPackIds: modularConfig.traitPackIds
        });
        
        return MetadataFallback.calculateCompatibilityScores(0, assetData);
    }
    
    function _calculateBonusesFromAccessories(
        ChargeAccessory[] memory accessories
    ) internal pure returns (AccessoryBonuses memory bonuses) {
        
        for (uint256 i = 0; i < accessories.length; i++) {
            bonuses.efficiencyBonus += accessories[i].efficiencyBoost;
            bonuses.regenBonus += accessories[i].regenBoost;
            bonuses.maxChargeBonus += accessories[i].chargeBoost;
            bonuses.kinshipBonus += accessories[i].kinshipBoost;
            bonuses.wearResistance += accessories[i].wearResistance;
            bonuses.calibrationBonus += accessories[i].calibrationBonus;
            bonuses.stakingBonus += accessories[i].stakingBoostPercentage;
            
            if (accessories[i].xpGainMultiplier > bonuses.xpMultiplier) {
                bonuses.xpMultiplier = accessories[i].xpGainMultiplier;
            }
        }
        
        return bonuses;
    }
    
    function _calculateBonusesFromEquipments(
        Equipment[] storage equipments
    ) internal view returns (AccessoryBonuses memory bonuses) {
        
        for (uint256 i = 0; i < equipments.length; i++) {
            bonuses.efficiencyBonus += 5;
            bonuses.regenBonus += 2;
            bonuses.maxChargeBonus += 8;
        }
        
        return bonuses;
    }
}