// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {PodsUtils} from "../../../libraries/PodsUtils.sol";
import {LibTraitPackHelper} from "../libraries/LibTraitPackHelper.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import {AccessHelper} from "../../staking/libraries/AccessHelper.sol";
import {ControlFee, ChargeAccessory, SpecimenCollection, PowerMatrix, AccessoryTypeInfo, TraitPackEquipment} from "../../../libraries/HenomorphsModel.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {LibFeeCollection} from "../../staking/libraries/LibFeeCollection.sol";
import {LibAccessoryHelper} from "../libraries/LibAccessoryHelper.sol";
import {IExternalCollection, IColonyFacet, IChargeFacet} from "../../staking/interfaces/IStakingInterfaces.sol";
import {ICollectionDiamond} from "../../modular/interfaces/ICollectionDiamond.sol";
import {LibBiopodIntegration} from "../../staking/libraries/LibBiopodIntegration.sol";

/**
 * @title AccessoryFacet
 * @notice Gas-optimized accessory management with smart caching strategy
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract AccessoryFacet is AccessControlBase {
    using Strings for uint64;

    /**
     * @notice Token stats structure for external use
     */
    struct TokenStats {
        uint8 variant;
        uint256 currentCharge;
        uint256 maxCharge;
        uint8 fatigueLevel;
        uint256 wearLevel;
        uint256 accessoryBonus;
        bool hasValidCharge;
    }

    uint256 private constant MAX_LOCAL_ACCESSORIES = 5;
    uint256 private constant MAX_EXTERNAL_ACCESSORIES = 15;
    uint256 private constant CACHE_VALIDITY_PERIOD = 600; // 10 minutes
    uint256 private constant FRESH_DATA_THRESHOLD = 300; // 5 minutes for critical operations
    
    // Events
    event AccessoryEquipped(uint256 indexed collectionId, uint256 indexed tokenId, uint256 accessoryIndex);
    event AccessoryRemoved(uint256 indexed collectionId, uint256 indexed tokenId, uint256 accessoryIndex);
    event ChargeUpdated(uint256 indexed collectionId, uint256 indexed tokenId, uint256 newCharge, uint256 maxCharge);
    event AccessoryRegistered(uint8 indexed accessoryType, string name, bool indexed rare);
    event AccessoriesReset(uint256 indexed collectionId, uint256 indexed tokenId, uint256 removedCount);
    event CacheRefreshed(uint256 indexed combinedId, uint256 localCount, uint256 externalCount);

    function _checkChargeEnabled(uint256 collectionId, uint256 tokenId) internal view {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        SpecimenCollection storage _collection = hs.specimenCollections[collectionId];
        if (!_collection.enabled) {
            revert LibHenomorphsStorage.CollectionNotEnabled(collectionId);
        }
        
        if (!AccessHelper.checkTokenOwnership(collectionId, tokenId, LibMeta.msgSender(), AccessHelper.getStakingAddress())) {
            revert LibHenomorphsStorage.HenomorphControlForbidden(collectionId, tokenId);
        }
    }

    modifier whenChargeEnabled(uint256 collectionId, uint256 tokenId) {
        _checkChargeEnabled(collectionId, tokenId);
        _;
    }

    // ==================== MAIN INTERFACE ====================

    /**
     * @notice Get equipped accessories with smart caching
     * @dev Uses cache if valid, builds fresh data only when needed
     */
    function equippedAccessories(uint256 collectionId, uint256 tokenId) 
        public 
        view 
        returns (ChargeAccessory[] memory) 
    {
        if (collectionId == 0 || tokenId == 0) {
            return new ChargeAccessory[](0);
        }

        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (collectionId > hs.collectionCounter || !hs.specimenCollections[collectionId].enabled) {
            return new ChargeAccessory[](0);
        }

        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        // Use cache if valid
        if (_isCacheValid(hs, combinedId)) {
            return hs.accessoryCache[combinedId].accessories;
        }
        
        // Build fresh data and cache it
        return _buildAndCacheAccessories(hs, collectionId, tokenId, combinedId);
    }

    /**
     * @notice Get token accessories - consistent interface
     */
    function getTokenAccessories(uint256 collectionId, uint256 tokenId) 
        external 
        view 
        returns (ChargeAccessory[] memory) 
    {
        return equippedAccessories(collectionId, tokenId);
    }

    /**
     * @notice Get augmentation status with caching optimization
     */
    function getAugmentationStatus(uint256 collectionId, uint256 tokenId) external view returns (
        bool hasTraitPack,
        uint8 traitPackId,
        uint8 variant,
        uint256 accessoryCount,
        uint64[] memory accessoryIds,
        bool bonusesWouldApply,
        uint256 expectedEfficiencyBonus,
        uint256 expectedRegenBonus,
        uint256 expectedChargeBonus
    ) {
        if (collectionId == 0 || tokenId == 0) {
            return (false, 0, 0, 0, new uint64[](0), false, 0, 0, 0);
        }

        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (collectionId > hs.collectionCounter || !hs.specimenCollections[collectionId].enabled) {
            return (false, 0, 0, 0, new uint64[](0), false, 0, 0, 0);
        }

        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        // Try cached data first
        if (_isCacheValid(hs, combinedId)) {
            LibHenomorphsStorage.AccessoryCache storage cache = hs.accessoryCache[combinedId];
            
            if (cache.accessories.length > 0 && cache.accessories[0].traitPackId > 0) {
                hasTraitPack = true;
                traitPackId = cache.accessories[0].traitPackId;
            }
            
            accessoryIds = cache.externalIds;
            variant = _getTokenVariant(hs, collectionId, tokenId);
            accessoryCount = accessoryIds.length;
            bonusesWouldApply = hasTraitPack || accessoryCount > 0;

            if (bonusesWouldApply) {
                (expectedEfficiencyBonus, expectedRegenBonus, expectedChargeBonus) = 
                    _calculateBonuses(traitPackId, variant, accessoryIds);
            }
            
            return (hasTraitPack, traitPackId, variant, accessoryCount, accessoryIds, bonusesWouldApply, 
                    expectedEfficiencyBonus, expectedRegenBonus, expectedChargeBonus);
        }
        
        // Fall back to fresh data
        (hasTraitPack, traitPackId, variant, accessoryIds) = _getAugmentationDataWithFallback(hs, collectionId, tokenId);
        
        accessoryCount = accessoryIds.length;
        bonusesWouldApply = hasTraitPack || accessoryCount > 0;

        if (bonusesWouldApply) {
            (expectedEfficiencyBonus, expectedRegenBonus, expectedChargeBonus) = 
                _calculateBonuses(traitPackId, variant, accessoryIds);
        }

        return (hasTraitPack, traitPackId, variant, accessoryCount, accessoryIds, bonusesWouldApply, 
                expectedEfficiencyBonus, expectedRegenBonus, expectedChargeBonus);
    }

    /**
     * @notice Check if token has trait pack with caching
     */
    function checkTokenHasTraitPack(uint256 collectionId, uint256 tokenId) 
        external 
        view 
        returns (bool hasTraitPack, uint256 traitPackId) 
    {
        if (collectionId == 0 || tokenId == 0) {
            return (false, 0);
        }

        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (collectionId > hs.collectionCounter || !hs.specimenCollections[collectionId].enabled) {
            return (false, 0);
        }
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        // Use cache if available
        if (_isCacheValid(hs, combinedId)) {
            LibHenomorphsStorage.AccessoryCache storage cache = hs.accessoryCache[combinedId];
            if (cache.accessories.length > 0 && cache.accessories[0].traitPackId > 0) {
                return (true, cache.accessories[0].traitPackId);
            }
            return (false, 0);
        }
        
        // Fallback to fresh data
        (bool _hasTraitPack, uint8 _traitPackId,,) = _getAugmentationDataWithFallback(hs, collectionId, tokenId);
        hasTraitPack = _hasTraitPack;

        if (_hasTraitPack) {
            traitPackId = _traitPackId;
        }
        
        return (hasTraitPack, traitPackId);
    }

    /**
     * @notice Get comprehensive token stats for external systems (battles, staking, etc.)
     * @param collectionIds Array of collection IDs
     * @param tokenIds Array of token IDs
     * @return stats Array of token stats
     */
    function getTokenPerformanceStats(
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds
    ) external view returns (TokenStats[] memory stats) {
        require(collectionIds.length == tokenIds.length, "Array length mismatch");
        
        stats = new TokenStats[](collectionIds.length);
        
        for (uint256 i = 0; i < collectionIds.length; i++) {
            stats[i] = _getTokenPerformanceStats(collectionIds[i], tokenIds[i]);
        }
        
        return stats;
    }

    // ==================== OPTIMIZED BUILDING FUNCTIONS ====================

    /**
     * @notice Internal function to get comprehensive token stats
     */
    function _getTokenPerformanceStats(uint256 collectionId, uint256 tokenId) 
        internal view returns (TokenStats memory stats) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Basic validation
        if (collectionId == 0 || tokenId == 0 || collectionId > hs.collectionCounter) {
            return stats; // Return empty stats for invalid tokens
        }
        
        // Get variant safely
        stats.variant = _getTokenVariant(hs, collectionId, tokenId);
        
        // Get charge data from Henomorphs storage
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage charge = hs.performedCharges[combinedId];
        
        if (charge.lastChargeTime > 0) {
            stats.currentCharge = charge.currentCharge;
            stats.maxCharge = charge.maxCharge;
            stats.fatigueLevel = uint8(charge.fatigueLevel);
            stats.hasValidCharge = true;
        }
        
        // Get wear level using LibBiopodIntegration (no external call)
        (uint256 wearLevel,) = LibBiopodIntegration.getUnifiedWearLevel(collectionId, tokenId);
        stats.wearLevel = wearLevel;
        
        // Get accessory bonus efficiently
        stats.accessoryBonus = _calculateAccessoryBonus(hs, combinedId, collectionId, tokenId);
        
        return stats;
    }

    /**
     * @notice Calculate total accessory bonus efficiently
     */
    function _calculateAccessoryBonus(
        LibHenomorphsStorage.HenomorphsStorage storage hs,
        uint256 combinedId,
        uint256 collectionId,
        uint256 tokenId
    ) internal view returns (uint256 totalBonus) {
        // Try cache first
        if (_isCacheValid(hs, combinedId)) {
            ChargeAccessory[] storage accessories = hs.accessoryCache[combinedId].accessories;
            // POPRAWKA: Zwiększ limit do 10 zamiast 5
            for (uint256 j = 0; j < accessories.length && j < 10; j++) {
                totalBonus += accessories[j].stakingBoostPercentage;
            }
            return totalBonus;
        }
        
        // Get local accessories
        ChargeAccessory[] storage localAccessories = hs.equippedAccessories[combinedId];
        for (uint256 i = 0; i < localAccessories.length && i < 5; i++) {
            if (_isValidAccessory(localAccessories[i])) {
                totalBonus += localAccessories[i].stakingBoostPercentage;
            }
        }
        
        // Get external accessories if collection is valid
        if (hs.specimenCollections[collectionId].enabled) {
            ChargeAccessory[] memory externalAccessories = _getExternalAccessories(hs, collectionId, tokenId);
            // POPRAWKA: Zwiększ limit do 10 zamiast 5
            for (uint256 i = 0; i < externalAccessories.length && i < 10; i++) {
                totalBonus += externalAccessories[i].stakingBoostPercentage;
            }
        }
        
        return totalBonus;
    }

    /**
     * @notice Build accessories and update cache (for view functions)
     */
    function _buildAndCacheAccessories(
        LibHenomorphsStorage.HenomorphsStorage storage hs,
        uint256 collectionId,
        uint256 tokenId,
        uint256 combinedId
    ) internal view returns (ChargeAccessory[] memory) {
        
        ChargeAccessory[] memory localAccessories = _getLocalAccessories(hs, combinedId);
        ChargeAccessory[] memory externalAccessories = _getExternalAccessories(hs, collectionId, tokenId);
        ChargeAccessory[] memory combinedAccessories = _combineAccessories(localAccessories, externalAccessories);
        
        // Note: Can't update cache in view function, but we return the data
        return combinedAccessories;
    }

    /**
     * @notice Build accessories and update cache (for state-changing functions)
     */
    function _buildAndUpdateCache(
        LibHenomorphsStorage.HenomorphsStorage storage hs,
        uint256 collectionId,
        uint256 tokenId,
        uint256 combinedId
    ) internal {
        
        ChargeAccessory[] memory localAccessories = _getLocalAccessories(hs, combinedId);
        ChargeAccessory[] memory externalAccessories = _getExternalAccessories(hs, collectionId, tokenId);
        ChargeAccessory[] memory combinedAccessories = _combineAccessories(localAccessories, externalAccessories);
        
        // Update cache
        _updateCache(hs, combinedId, combinedAccessories, externalAccessories);
    }

    /**
     * @notice Get local accessories efficiently
     */
    function _getLocalAccessories(
        LibHenomorphsStorage.HenomorphsStorage storage hs,
        uint256 combinedId
    ) internal view returns (ChargeAccessory[] memory) {
        
        ChargeAccessory[] storage storedAccessories = hs.equippedAccessories[combinedId];
        
        if (storedAccessories.length == 0) {
            return new ChargeAccessory[](0);
        }
        
        uint256 maxCheck = storedAccessories.length > MAX_LOCAL_ACCESSORIES ? 
            MAX_LOCAL_ACCESSORIES : storedAccessories.length;
        
        // Quick validation and count
        uint256 validCount = 0;
        for (uint256 i = 0; i < maxCheck; i++) {
            if (_isValidAccessory(storedAccessories[i])) {
                validCount++;
            }
        }
        
        if (validCount == 0) {
            return new ChargeAccessory[](0);
        }
        
        ChargeAccessory[] memory validAccessories = new ChargeAccessory[](validCount);
        uint256 validIndex = 0;
        
        for (uint256 i = 0; i < maxCheck && validIndex < validCount; i++) {
            if (_isValidAccessory(storedAccessories[i])) {
                validAccessories[validIndex] = storedAccessories[i];
                validIndex++;
            }
        }
        
        return validAccessories;
    }

    /**
     * @notice Get external accessories with minimal calls
     */
    function _getExternalAccessories(
        LibHenomorphsStorage.HenomorphsStorage storage hs,
        uint256 collectionId,
        uint256 tokenId
    ) internal view returns (ChargeAccessory[] memory) {
        
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        
        // Try Diamond first (single call)
        if (collection.diamondAddress != address(0)) {
            try ICollectionDiamond(collection.diamondAddress).getSpecimenEquipment(
                collection.collectionAddress,
                tokenId
            ) returns (TraitPackEquipment memory equipment) {
                if (equipment.traitPackTokenId > 0 && equipment.accessoryIds.length > 0) {
                    return _convertAugmentAccessories(
                        equipment.accessoryIds,
                        uint8(equipment.traitPackTokenId),
                        equipment.variant > 0 ? equipment.variant : 1
                    );
                }
            } catch {
                // Continue to fallback
            }
        }
        
        // POPRAWKA: Dla kolekcji Genesis (collectionType == 0) użyj specjalnej obsługi
        if (collection.collectionType == 0) {
            // Sprawdź czy token ma przypisany augment
            try IExternalCollection(collection.collectionAddress).hasTraitPack(tokenId) returns (bool hasPack) {
                if (hasPack) {
                    // Pobierz trait packs
                    try IExternalCollection(collection.collectionAddress).itemEquipments(tokenId) 
                        returns (uint8[] memory traitPacks) {
                        if (traitPacks.length > 0) {
                            // Dla Genesis używamy hardcoded accessories based on traitPackId
                            uint64[] memory accessoryIds = _getGenesisAccessories(traitPacks[0]);
                            if (accessoryIds.length > 0) {
                                uint8 variant = _getTokenVariant(hs, collectionId, tokenId);
                                return _convertAugmentAccessories(accessoryIds, traitPacks[0], variant);
                            }
                        }
                    } catch {
                        // Fallback
                    }
                }
            } catch {
                // Continue to standard fallback
            }
        }
        
        // Standard fallback for other collections
        try IExternalCollection(collection.collectionAddress).itemEquipments(tokenId) 
            returns (uint8[] memory traitPacks) {
            if (traitPacks.length > 0) {
                uint64[] memory accessoryIds = LibTraitPackHelper.getAccessoriesForTraitPack(traitPacks[0]);
                if (accessoryIds.length > 0) {
                    uint8 variant = _getTokenVariant(hs, collectionId, tokenId);
                    return _convertAugmentAccessories(accessoryIds, traitPacks[0], variant);
                }
            }
        } catch {
            // All methods failed
        }
        
        return new ChargeAccessory[](0);
    }

    function _getGenesisAccessories(uint8 traitPackId) internal pure returns (uint64[] memory) {
        // Mapowanie trait pack ID na accessories dla Genesis
        if (traitPackId == 1) {
            uint64[] memory genesisAcc = new uint64[](2);
            genesisAcc[0] = 1; // JOI'S VISION
            genesisAcc[1] = 2; // K'S PROTOCOL
            return genesisAcc;
        } else if (traitPackId == 2) {
            uint64[] memory genesisAcc = new uint64[](1);
            genesisAcc[0] = 1; // Tylko jedna dla trait pack 2
            return genesisAcc;
        } else if (traitPackId == 3) {
            uint64[] memory genesisAcc = new uint64[](2);
            genesisAcc[0] = 1; // JOI'S VISION
            genesisAcc[1] = 3; // DECKARD'S REFUGE
            return genesisAcc;
        } else if (traitPackId == 4) {
            uint64[] memory genesisAcc = new uint64[](3);
            genesisAcc[0] = 1;
            genesisAcc[1] = 2;
            genesisAcc[2] = 3;
            return genesisAcc;
        }
        
        // Domyślny fallback
        uint64[] memory defaultAcc = new uint64[](1);
        defaultAcc[0] = 1;
        return defaultAcc;
    }

    /**
     * @notice Convert augment accessories to ChargeAccessory format
     */
    function _convertAugmentAccessories(
        uint64[] memory accessoryIds,
        uint8 traitPackId,
        uint8 variant
    ) internal view returns (ChargeAccessory[] memory) {
        
        if (accessoryIds.length == 0) {
            return new ChargeAccessory[](0);
        }
        
        // Limit processing to prevent gas issues
        uint256 maxProcess = accessoryIds.length > 10 ? 10 : accessoryIds.length;
        
        ChargeAccessory[] memory accessories = new ChargeAccessory[](maxProcess);
        
        for (uint256 i = 0; i < maxProcess; i++) {
            if (accessoryIds[i] > 0 && accessoryIds[i] <= 255) {
                accessories[i] = _createBasicAccessory(uint8(accessoryIds[i]), traitPackId, variant);
            }
        }
        
        return accessories;
    }

    /**
     * @notice Combine accessories without heavy duplication checks
     */
    function _combineAccessories(
        ChargeAccessory[] memory localAccessories,
        ChargeAccessory[] memory externalAccessories
    ) internal pure returns (ChargeAccessory[] memory) {
        
        if (localAccessories.length == 0 && externalAccessories.length == 0) {
            return new ChargeAccessory[](0);
        }
        
        if (localAccessories.length == 0) {
            return externalAccessories;
        }
        
        if (externalAccessories.length == 0) {
            return localAccessories;
        }
        
        // Simple concatenation with length limit (prioritize local)
        uint256 totalLength = localAccessories.length + externalAccessories.length;
        if (totalLength > 15) totalLength = 15;
        
        ChargeAccessory[] memory combined = new ChargeAccessory[](totalLength);
        uint256 index = 0;
        
        // Add local accessories first
        for (uint256 i = 0; i < localAccessories.length && index < totalLength; i++) {
            combined[index] = localAccessories[i];
            index++;
        }
        
        // Add external accessories
        for (uint256 i = 0; i < externalAccessories.length && index < totalLength; i++) {
            combined[index] = externalAccessories[i];
            index++;
        }
        
        return combined;
    }

    /**
     * @notice Get augmentation data with minimal external calls
     */
    function _getAugmentationDataWithFallback(
        LibHenomorphsStorage.HenomorphsStorage storage hs,
        uint256 collectionId,
        uint256 tokenId
    ) internal view returns (
        bool hasTraitPack,
        uint8 traitPackId,
        uint8 variant,
        uint64[] memory accessoryIds
    ) {
        
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        variant = _getTokenVariant(hs, collectionId, tokenId);
        
        // Single Diamond call
        if (collection.diamondAddress != address(0)) {
            try ICollectionDiamond(collection.diamondAddress).getSpecimenEquipment(
                collection.collectionAddress,
                tokenId
            ) returns (TraitPackEquipment memory equipment) {
                if (equipment.traitPackTokenId > 0) {
                    hasTraitPack = true;
                    traitPackId = uint8(equipment.traitPackTokenId);
                    accessoryIds = equipment.accessoryIds;
                    if (equipment.variant > 0) {
                        variant = equipment.variant;
                    }
                    return (hasTraitPack, traitPackId, variant, accessoryIds);
                }
            } catch {
                // Continue to fallback
            }
        }
        
        // Single collection call
        try IExternalCollection(collection.collectionAddress).itemEquipments(tokenId) 
            returns (uint8[] memory traitPacks) {
            if (traitPacks.length > 0) {
                hasTraitPack = true;
                traitPackId = traitPacks[0];
                accessoryIds = LibTraitPackHelper.getAccessoriesForTraitPack(traitPackId);
            }
        } catch {
            // All sources failed
        }
        
        return (hasTraitPack, traitPackId, variant, accessoryIds);
    }

    /**
     * @notice Get token variant with simple caching
     */
    function _getTokenVariant(
        LibHenomorphsStorage.HenomorphsStorage storage,
        uint256 collectionId,
        uint256 tokenId
    ) internal view returns (uint8) {
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        
        try IExternalCollection(collection.collectionAddress).itemVariant(tokenId) 
            returns (uint8 variant) {
            return variant > 0 ? variant : 1;
        } catch {
            return 1;
        }
    }

    /**
     * @notice Create basic accessory with minimal processing
     */
    function _createBasicAccessory(uint8 accessoryId, uint8 traitPackId, uint8) 
        internal 
        view 
        returns (ChargeAccessory memory accessory) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        accessory.accessoryType = accessoryId;
        accessory.traitPackId = traitPackId;
        accessory.traitURI = string(abi.encodePacked("augment://", Strings.toString(traitPackId), "/", Strings.toString(accessoryId)));
        
        // Set name
        if (bytes(hs.accessoryTypes[accessoryId].name).length > 0) {
            accessory.accessoryName = hs.accessoryTypes[accessoryId].name;
            accessory.rare = hs.accessoryTypes[accessoryId].defaultRare;
        } else {
            accessory.accessoryName = string(abi.encodePacked("Augment Accessory #", Strings.toString(accessoryId)));
            accessory.rare = false;
        }
        
        // POPRAWKA: Ustaw wartości zgodne z rzeczywistymi danymi
        if (accessoryId == 1) {
            accessory.chargeBoost = 5;
            accessory.regenBoost = 0;
            accessory.efficiencyBoost = 11;
            accessory.stakingBoostPercentage = 24;
        } else if (accessoryId == 2) {
            accessory.chargeBoost = 3;
            accessory.regenBoost = 7;
            accessory.efficiencyBoost = 3;
            accessory.stakingBoostPercentage = 26;
        } else if (accessoryId == 3) {
            accessory.chargeBoost = 15;
            accessory.regenBoost = 0;
            accessory.efficiencyBoost = 7;
            accessory.stakingBoostPercentage = 22;
        } else {
            // Domyślne wartości dla innych akcesoriów
            accessory.chargeBoost = 2;
            accessory.regenBoost = 2;
            accessory.efficiencyBoost = 2;
            accessory.stakingBoostPercentage = 20;
        }
        
        // Standard values - bez zmian
        accessory.calibrationBonus = 5;
        accessory.wearResistance = 10;
        accessory.kinshipBoost = 3;
        accessory.xpGainMultiplier = 105;
        
        return accessory;
    }

    // ==================== CACHE MANAGEMENT ====================

    /**
     * @notice Check if cache is valid
     */
    function _isCacheValid(
        LibHenomorphsStorage.HenomorphsStorage storage hs,
        uint256 combinedId
    ) internal view returns (bool) {
        uint256 timestamp = hs.accessoryCacheTimestamps[combinedId];
        uint256 validity = hs.cacheValidityPeriod > 0 ? hs.cacheValidityPeriod : CACHE_VALIDITY_PERIOD;
        return timestamp > 0 && 
               (block.timestamp - timestamp) < validity && 
               hs.accessoryCache[combinedId].valid;
    }

    /**
     * @notice Update cache efficiently
     */
    function _updateCache(
        LibHenomorphsStorage.HenomorphsStorage storage hs,
        uint256 combinedId,
        ChargeAccessory[] memory accessories,
        ChargeAccessory[] memory externalAccessories
    ) internal {
        
        // Extract external IDs for quick access
        uint64[] memory externalIds = new uint64[](externalAccessories.length);
        for (uint256 i = 0; i < externalAccessories.length; i++) {
            externalIds[i] = uint64(externalAccessories[i].accessoryType);
        }
        
        hs.accessoryCache[combinedId] = LibHenomorphsStorage.AccessoryCache({
            accessories: accessories,
            externalIds: externalIds,
            timestamp: block.timestamp,
            valid: true
        });
        hs.accessoryCacheTimestamps[combinedId] = block.timestamp;
        
        emit CacheRefreshed(combinedId, accessories.length - externalAccessories.length, externalAccessories.length);
    }

    /**
     * @notice Invalidate cache when local accessories change
     */
    function _invalidateCache(
        LibHenomorphsStorage.HenomorphsStorage storage hs,
        uint256 combinedId
    ) internal {
        delete hs.accessoryCache[combinedId];
        hs.accessoryCacheTimestamps[combinedId] = 0;
    }

    // ==================== EXTERNAL INVALIDATION ====================

    /**
     * @notice Invalidate cache for external systems (when augments change)
     */
    function invalidateAccessoryCache(uint256 collectionId, uint256 tokenId) 
        external 
        onlyAuthorized 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        _invalidateCache(hs, combinedId);
    }

    /**
     * @notice Batch invalidate cache for multiple tokens
     */
    function batchInvalidateAccessoryCache(uint256[] calldata collectionIds, uint256[] calldata tokenIds) 
        external 
        onlyAuthorized 
    {
        require(collectionIds.length == tokenIds.length, "Array length mismatch");
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        for (uint256 i = 0; i < collectionIds.length; i++) {
            uint256 combinedId = PodsUtils.combineIds(collectionIds[i], tokenIds[i]);
            _invalidateCache(hs, combinedId);
        }
    }

    // ==================== UTILITY FUNCTIONS ====================

    /**
     * @notice Check if accessory is valid
     */
    function _isValidAccessory(ChargeAccessory storage accessory) 
        internal 
        view 
        returns (bool) 
    {
        return accessory.accessoryType > 0 && 
               bytes(accessory.accessoryName).length > 0;
    }

    /**
     * @notice Calculate bonuses
     */
    function _calculateBonuses(
        uint8 traitPackId,
        uint8 variant,
        uint64[] memory accessoryIds
    ) internal pure returns (uint256 efficiencyBonus, uint256 regenBonus, uint256 chargeBonus) {
        
        // Base trait pack bonuses
        if (traitPackId > 0) {
            efficiencyBonus = 10;
            regenBonus = 5;
            chargeBonus = 0;
            
            // Variant modifiers
            if (variant > 1) {
                efficiencyBonus += (variant - 1) * 2;
                regenBonus += (variant - 1);
            }
        }
        
        // Accessory bonuses (limit processing)
        uint256 maxCheck = accessoryIds.length > 5 ? 5 : accessoryIds.length;
        for (uint256 i = 0; i < maxCheck; i++) {
            uint8 accessoryId = uint8(accessoryIds[i]);
            if (accessoryId == 1) {
                efficiencyBonus += 8;
            } else if (accessoryId == 2) {
                regenBonus += 7;
            } else if (accessoryId == 3) {
                chargeBonus += 15;
            } else {
                efficiencyBonus += 2;
                regenBonus += 2;
            }
        }
    }

    // ==================== ADMIN FUNCTIONS ====================

    /**
     * @notice Register a new accessory type
     */
    function registerAccessoryType(uint8 accessoryType, string calldata name, bool defaultRare) 
        external onlyAuthorized
    {
        if (accessoryType == 0) {
            revert LibHenomorphsStorage.InvalidAccessoryType();
        }

        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (bytes(hs.accessoryTypes[accessoryType].name).length > 0) {
            revert LibHenomorphsStorage.AccessoryAlreadyRegistered(accessoryType);
        }
        
        hs.accessoryTypes[accessoryType] = AccessoryTypeInfo({
            name: name,
            defaultRare: defaultRare,
            registrationTime: uint32(block.timestamp),
            enabled: true
        });
        
        hs.allAccessoryTypes.push(accessoryType);
        
        emit AccessoryRegistered(accessoryType, name, defaultRare);
    }

    /**
     * @notice Equip accessory with cache update
     */
    function equipAccessory(uint256 collectionId, uint256 tokenId, ChargeAccessory calldata accessory) 
        external 
        whenChargeEnabled(collectionId, tokenId) nonReentrant
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage charge = hs.performedCharges[combinedId];
        
        if (hs.equippedAccessories[combinedId].length >= MAX_LOCAL_ACCESSORIES) {
            revert LibHenomorphsStorage.MaxAccessoriesReached();
        }
        
        if (accessory.accessoryType == 0 || bytes(hs.accessoryTypes[accessory.accessoryType].name).length == 0) {
            revert LibHenomorphsStorage.InvalidAccessoryType();
        }
        
        bool traitPackMatch = true;
        if (accessory.traitPackId > 0) {
            (traitPackMatch, ) = LibTraitPackHelper.verifyTraitPack(
                collectionId, 
                tokenId, 
                accessory.traitPackId
            );
            
            if (!traitPackMatch) {
                revert LibTraitPackHelper.IncompatibleTraitPack(accessory.traitPackId);
            }
        }
        
        // Collect fee
        if (accessory.rare) {
            LibFeeCollection.collectFee(
                hs.chargeFees.accessoryRareFee.currency,
                LibMeta.msgSender(),
                hs.chargeFees.accessoryRareFee.beneficiary,
                hs.chargeFees.accessoryRareFee.amount,
                "equipAccessory"
            );
        } else {
            LibFeeCollection.collectFee(
                hs.chargeFees.accessoryBaseFee.currency,
                LibMeta.msgSender(),
                hs.chargeFees.accessoryBaseFee.beneficiary,
                hs.chargeFees.accessoryBaseFee.amount,
                "equipAccessory"
            );
        }
        
        ChargeAccessory memory sanitizedAccessory = _sanitizeAccessoryData(accessory);
        hs.equippedAccessories[combinedId].push(sanitizedAccessory);
        
        LibAccessoryHelper.applyAccessoryEffects(combinedId, sanitizedAccessory, true);
        LibAccessoryHelper.applyTraitPackBonus(combinedId, traitPackMatch, sanitizedAccessory.traitPackId, true);
        
        // Invalidate cache and rebuild
        _invalidateCache(hs, combinedId);
        _buildAndUpdateCache(hs, collectionId, tokenId, combinedId);
        
        emit AccessoryEquipped(collectionId, tokenId, hs.equippedAccessories[combinedId].length - 1);
        emit ChargeUpdated(collectionId, tokenId, charge.currentCharge, charge.maxCharge);
    }

    /**
     * @notice Remove accessory with cache update
     */
    function removeAccessory(uint256 collectionId, uint256 tokenId, uint256 accessoryIndex) 
        external 
        whenChargeEnabled(collectionId, tokenId) nonReentrant
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage charge = hs.performedCharges[combinedId];
        
        if (accessoryIndex >= hs.equippedAccessories[combinedId].length) {
            revert LibHenomorphsStorage.AccessoryDoesNotExist(accessoryIndex);
        }
        
        ChargeAccessory memory accessory = hs.equippedAccessories[combinedId][accessoryIndex];
        
        (bool traitPackMatch,) = accessory.traitPackId > 0 ? 
            LibTraitPackHelper.verifyTraitPack(collectionId, tokenId, accessory.traitPackId) : 
            (false, new uint8[](0));
            
        LibAccessoryHelper.applyAccessoryEffects(combinedId, accessory, false);
        LibAccessoryHelper.applyTraitPackBonus(combinedId, traitPackMatch, accessory.traitPackId, false);
        
        // Remove accessory from array (swap & pop)
        uint256 lastIndex = hs.equippedAccessories[combinedId].length - 1;
        if (accessoryIndex < lastIndex) {
            hs.equippedAccessories[combinedId][accessoryIndex] = hs.equippedAccessories[combinedId][lastIndex];
        }
        hs.equippedAccessories[combinedId].pop();
        
        // Invalidate cache and rebuild
        _invalidateCache(hs, combinedId);
        _buildAndUpdateCache(hs, collectionId, tokenId, combinedId);
        
        emit AccessoryRemoved(collectionId, tokenId, accessoryIndex);
        emit ChargeUpdated(collectionId, tokenId, charge.currentCharge, charge.maxCharge);
    }

    /**
     * @notice Reset token accessories
     */
    function resetTokenAccessories(uint256 collectionId, uint256 tokenId) 
        external 
        onlyAuthorized 
        returns (uint256 removedCount)
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        removedCount = hs.equippedAccessories[combinedId].length;
        delete hs.equippedAccessories[combinedId];
        
        // Invalidate cache
        _invalidateCache(hs, combinedId);
        
        emit AccessoriesReset(collectionId, tokenId, removedCount);
        return removedCount;
    }

    /**
     * @notice Get all registered accessory types
     */
    function getAccessoryTypes() external view returns (uint8[] memory) {
        return LibHenomorphsStorage.henomorphsStorage().allAccessoryTypes;
    }
    
    /**
     * @notice Get accessory type information
     */
    function getAccessoryTypeInfo(uint8 accessoryType) external view returns (
        string memory name,
        bool defaultRare,
        bool enabled
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        AccessoryTypeInfo storage info = hs.accessoryTypes[accessoryType];
        
        return (info.name, info.defaultRare, info.enabled);
    }

    /**
     * @notice Sanitize accessory data
     */
    function _sanitizeAccessoryData(ChargeAccessory memory accessory) internal pure returns (ChargeAccessory memory) {
        ChargeAccessory memory sanitized = accessory;
        
        sanitized.chargeBoost = _min(accessory.chargeBoost, 50);
        sanitized.regenBoost = _min(accessory.regenBoost, 20);
        sanitized.efficiencyBoost = _min(accessory.efficiencyBoost, 30);
        sanitized.kinshipBoost = _min(accessory.kinshipBoost, 25);
        sanitized.wearResistance = _min(accessory.wearResistance, 30);
        sanitized.calibrationBonus = _min(accessory.calibrationBonus, 25);
        sanitized.stakingBoostPercentage = _min(accessory.stakingBoostPercentage, 20);
        sanitized.xpGainMultiplier = _min(accessory.xpGainMultiplier, 150);
        sanitized.specializationBoostValue = _min(accessory.specializationBoostValue, 25);
        sanitized.prowessBoost = _min(accessory.prowessBoost, 15);
        sanitized.agilityBoost = _min(accessory.agilityBoost, 15);
        sanitized.intelligenceBoost = _min(accessory.intelligenceBoost, 15);
        
        return sanitized;
    }
    
    function _min(uint8 a, uint8 b) internal pure returns (uint8) {
        return a < b ? a : b;
    }
}