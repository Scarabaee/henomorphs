// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../../chargepod/libraries/LibHenomorphsStorage.sol";
import {LibStakingStorage} from "../libraries/LibStakingStorage.sol";
import {LibTraitPackHelper} from "../../chargepod/libraries/LibTraitPackHelper.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibDiamond} from "../../shared/libraries/LibDiamond.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {PodsUtils} from "../../../libraries/PodsUtils.sol";
import {TraitPack, TraitPackEquipment, SpecimenCollection} from "../../../libraries/HenomorphsModel.sol";
import {StakedSpecimen} from "../../../libraries/StakingModel.sol";
import {ModularAssetModel} from "../../../libraries/ModularAssetModel.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {IExternalCollection} from "../interfaces/IStakingInterfaces.sol";
import {ICollectionDiamond} from "../../modular/interfaces/ICollectionDiamond.sol";

/**
 * @title TraitPackFacet
 * @notice Manages trait pack registration and integration with accessories
 * @dev Supports registering trait packs and maintaining accessory compatibility
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract TraitPackFacet is AccessControlBase {
    // Events
    event TraitPackRegistered(uint8 indexed traitPackId, string name, string baseURI);
    event TraitPackAccessoryAdded(uint8 indexed traitPackId, uint8 indexed accessoryType, bool rare);
    event TraitPackStatusUpdated(uint8 indexed traitPackId, bool enabled);
    event TraitPackAccessoryRemoved(uint8 indexed traitPackId, uint8 indexed accessoryType);
    event EnhancedTraitPackRegistered(uint8 indexed traitPackId, uint256 assetCount, int8 baseCalibrationMod, uint256 variantCount);
    event TraitPackBonusesCalculated(uint8 indexed traitPackId, uint8 stakingBonus, uint8 totalBonus);
    event AugmentTraitPackSynced(uint256 indexed collectionId, uint256 indexed tokenId, uint8 traitPackId);

    error TraitPackNotFound();

    /**
     * @notice Register a new trait pack
     * @param traitPackId Trait pack ID (1-255)
     * @param name Trait pack name
     * @param description Trait pack description
     * @param baseURI Base URI for trait pack metadata
     */
    function registerTraitPack(
        uint8 traitPackId,
        string calldata name,
        string calldata description,
        string calldata baseURI
    ) external onlyAuthorized whenNotPaused {
        // Validate ID - cannot be zero as this is reserved for "no trait pack"
        if (traitPackId == 0) {
            revert LibTraitPackHelper.InvalidTraitPackId();
        }

        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Check if already registered
        if (bytes(hs.traitPacks[traitPackId].name).length > 0) {
            revert LibTraitPackHelper.TraitPackAlreadyRegistered();
        }
        
        // Register trait pack
        hs.traitPacks[traitPackId] = TraitPack({
            id: traitPackId,
            name: name,
            description: description,
            baseURI: baseURI,
            enabled: true,
            registrationTime: block.timestamp
        });
        
        // Add to registered trait packs list
        if (!_isTraitPackInList(traitPackId)) {
            hs.registeredTraitPacks.push(traitPackId);
        }
        
        emit TraitPackRegistered(traitPackId, name, baseURI);
    }
    
    /**
     * @notice Add compatible accessory type to a trait pack
     * @param traitPackId Trait pack ID
     * @param accessoryType Accessory type ID
     * @param rare Whether accessory is rare
     */
    function addTraitPackAccessory(
        uint8 traitPackId,
        uint8 accessoryType,
        bool rare
    ) external onlyAuthorized whenNotPaused {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        // Validate trait pack
        if (bytes(hs.traitPacks[traitPackId].name).length == 0) {
            revert LibTraitPackHelper.TraitPackDoesNotExist();
        }
        
        // Validate accessory type (must be non-zero)
        if (accessoryType == 0) {
            revert LibHenomorphsStorage.InvalidAccessoryType();
        }
        
        // Check if accessory already registered for this trait pack
        uint8[] storage accessories = hs.traitPackAccessories[traitPackId];
        for (uint256 i = 0; i < accessories.length; i++) {
            if (accessories[i] == accessoryType) {
                revert LibHenomorphsStorage.AccessoryAlreadyRegistered(accessoryType);
            }
        }
        
        // Add accessory to trait pack
        hs.traitPackAccessories[traitPackId].push(accessoryType);
        
        // If this is a rare accessory, also register it in the rareAccessories mapping
        if (rare) {
            hs.rareAccessories[traitPackId][accessoryType] = true;
        }
        
        emit TraitPackAccessoryAdded(traitPackId, accessoryType, rare);
    }
    
    /**
     * @notice Remove compatible accessory type from a trait pack
     * @param traitPackId Trait pack ID
     * @param accessoryType Accessory type ID
     */
    function removeTraitPackAccessory(
        uint8 traitPackId,
        uint8 accessoryType
    ) external onlyAuthorized whenNotPaused {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        // Validate trait pack
        if (bytes(hs.traitPacks[traitPackId].name).length == 0) {
            revert LibTraitPackHelper.TraitPackDoesNotExist();
        }
        
        // Find and remove accessory from trait pack
        uint8[] storage accessories = hs.traitPackAccessories[traitPackId];
        bool found = false;
        uint256 indexToRemove;
        
        for (uint256 i = 0; i < accessories.length; i++) {
            if (accessories[i] == accessoryType) {
                found = true;
                indexToRemove = i;
                break;
            }
        }
        
        if (!found) {
            revert LibHenomorphsStorage.AccessoryNotRegistered();
        }
        
        // Remove accessory by swapping with last element and popping
        if (indexToRemove < accessories.length - 1) {
            accessories[indexToRemove] = accessories[accessories.length - 1];
        }
        accessories.pop();
        
        // Remove from rare accessories mapping
        delete hs.rareAccessories[traitPackId][accessoryType];
        
        emit TraitPackAccessoryRemoved(traitPackId, accessoryType);
    }
    
    /**
     * @notice Update trait pack enabled status
     * @param traitPackId Trait pack ID
     * @param enabled New enabled status
     */
    function updateTraitPackStatus(uint8 traitPackId, bool enabled) external onlyAuthorized whenNotPaused {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        // Validate trait pack
        if (bytes(hs.traitPacks[traitPackId].name).length == 0) {
            revert LibTraitPackHelper.TraitPackDoesNotExist();
        }
        
        // Update status
        hs.traitPacks[traitPackId].enabled = enabled;
        
        emit TraitPackStatusUpdated(traitPackId, enabled);
    }
    
    /**
     * @notice Check if an accessory type is compatible with a trait pack
     * @param traitPackId Trait pack ID
     * @param accessoryType Accessory type to check
     * @return isCompatible Whether the accessory is compatible
     * @return isRare Whether the accessory is rare
     */
    function checkAccessoryCompatibility(uint8 traitPackId, uint8 accessoryType) 
        external 
        view 
        returns (bool isCompatible, bool isRare) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Validate trait pack
        if (bytes(hs.traitPacks[traitPackId].name).length == 0) {
            return (false, false);
        }
        
        // Check if accessory is compatible
        uint8[] storage accessories = hs.traitPackAccessories[traitPackId];
        for (uint256 i = 0; i < accessories.length; i++) {
            if (accessories[i] == accessoryType) {
                // Accessory is compatible, now check if it's rare
                return (true, hs.rareAccessories[traitPackId][accessoryType]);
            }
        }
        
        return (false, false);
    }

    /**
     * @notice Apply trait pack bonuses to a staked token
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return success Whether bonuses were applied successfully
     */
    function applyTraitPackBonuses(uint256 collectionId, uint256 tokenId) external returns (bool) {
        // Access check
        if (!AccessHelper.isInternalCall() && !AccessHelper.isAuthorized()) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not authorized");
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        // Skip if token is not staked
        if (!staked.staked) {
            return false;
        }
        
        // Get token's trait packs
        (bool traitPacksAvailable, uint8[] memory traitPacks) = _getTokenTraitPacks(collectionId, tokenId);
        
        if (!traitPacksAvailable || traitPacks.length == 0) {
            return false;
        }
        
        // Apply bonuses based on trait packs with augment configuration
        uint8 totalBonusPoints = 0;
        bool anyBonusApplied = false;
        
        for (uint256 i = 0; i < traitPacks.length; i++) {
            // Get augment bonuses from configuration
            (,,uint8 stakingBonus,,,) = _getAugmentBonuses(traitPacks[i]);
            
            if (stakingBonus > 0) {
                totalBonusPoints += stakingBonus;
                anyBonusApplied = true;
            }
        }
        
        // Apply bonus to stats if applicable (max +15 for augments)
        if (totalBonusPoints > 0) {
            totalBonusPoints = totalBonusPoints > 15 ? 15 : totalBonusPoints;
            
            // Apply augment boost to level based on trait packs
            if (staked.level < 99) {
                uint8 levelBoost = totalBonusPoints > 10 ? 2 : (totalBonusPoints > 5 ? 1 : 0);
                staked.level += levelBoost;
            }
        }
        
        return anyBonusApplied;
    }

    /**
     * @notice Register TraitPack with enhanced asset functions
     * @param traitPackId TraitPack ID
     * @param name Name
     * @param description Description
     * @param baseURI Base URI
     * @param compatibleAssetIds Compatible asset IDs
     * @param compatibleAccessoryTypes Compatible accessory types
     * @param baseCalibrationMod Base calibration modifier
     * @param variants Variant bonus values
     * @param variantBonuses Variant bonus values
     */
    function registerEnhancedTraitPack(
        uint8 traitPackId,
        string calldata name,
        string calldata description,
        string calldata baseURI,
        uint64[] calldata compatibleAssetIds,
        uint8[] calldata compatibleAccessoryTypes,
        int8 baseCalibrationMod,
        uint8[] calldata variants,
        int8[] calldata variantBonuses
    ) external onlyAuthorized whenNotPaused {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Check if TraitPack already exists
        if (bytes(hs.traitPacks[traitPackId].name).length > 0) {
            revert LibTraitPackHelper.TraitPackAlreadyRegistered();
        }
        
        // Validate variant bonus arrays have same length
        if (variants.length != variantBonuses.length) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        // Save standard TraitPack
        hs.traitPacks[traitPackId] = TraitPack({
            id: traitPackId,
            name: name,
            description: description,
            baseURI: baseURI,
            enabled: true,
            registrationTime: block.timestamp
        });
        
        // Store the base calibration mod as variant 0 (special case for base values)
        hs.traitPackVariantBonuses[traitPackId][0] = baseCalibrationMod;
        
        // Save variant-specific bonuses
        for (uint256 i = 0; i < variants.length; i++) {
            hs.traitPackVariantBonuses[traitPackId][variants[i]] = variantBonuses[i];
        }
        
        // Access the enhanced trait pack
        ModularAssetModel.EnhancedTraitPack storage enhancedPack = hs.enhancedTraitPacks[traitPackId];
        
        // Store compatible assets in the assetIds array
        for (uint256 i = 0; i < compatibleAssetIds.length; i++) {
            enhancedPack.assetIds.push(compatibleAssetIds[i]);
        }
        
        // Save compatible accessory types
        for (uint256 i = 0; i < compatibleAccessoryTypes.length; i++) {
            hs.traitPackAccessories[traitPackId].push(compatibleAccessoryTypes[i]);
        }
        
        // Set composable property
        enhancedPack.composable = true;
        enhancedPack.nestable = false;
        
        // Add to registered TraitPacks
        bool found = false;
        for (uint256 i = 0; i < hs.registeredTraitPacks.length; i++) {
            if (hs.registeredTraitPacks[i] == traitPackId) {
                found = true;
                break;
            }
        }
        
        if (!found) {
            hs.registeredTraitPacks.push(traitPackId);
        }
        
        emit TraitPackRegistered(traitPackId, name, baseURI);
        emit EnhancedTraitPackRegistered(traitPackId, compatibleAssetIds.length, baseCalibrationMod, variants.length);
        
        // Emit augment bonuses calculation event
        (,,uint8 stakingBonus,,,) = _getAugmentBonuses(traitPackId);
        emit TraitPackBonusesCalculated(traitPackId, stakingBonus, uint8(baseCalibrationMod));
    }

    /**
     * @notice Get trait pack information
     * @param traitPackId Trait pack ID
     * @return name Trait pack name
     * @return description Trait pack description
     * @return baseURI Base URI for trait pack metadata
     * @return enabled Whether trait pack is enabled
     */
    function getTraitPack(uint8 traitPackId) external view returns (
        string memory name,
        string memory description,
        string memory baseURI,
        bool enabled
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        TraitPack storage traitPack = hs.traitPacks[traitPackId];
        
        return (
            traitPack.name,
            traitPack.description,
            traitPack.baseURI,
            traitPack.enabled
        );
    }
    
    /**
     * @notice Get compatible accessory types for a trait pack
     * @param traitPackId Trait pack ID
     * @return accessoryTypes Array of compatible accessory types
     */
    function getTraitPackAccessories(uint8 traitPackId) external view returns (uint8[] memory) {
        return LibHenomorphsStorage.henomorphsStorage().traitPackAccessories[traitPackId];
    }
    
    /**
     * @notice Get rare accessory types for a trait pack
     * @param traitPackId Trait pack ID
     * @return rareAccessoryTypes Array of rare accessory types
     */
    function getRareTraitPackAccessories(uint8 traitPackId) external view returns (uint8[] memory) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // First, get all accessories for this trait pack
        uint8[] storage allAccessories = hs.traitPackAccessories[traitPackId];
        
        // Count rare accessories
        uint256 rareCount = 0;
        for (uint256 i = 0; i < allAccessories.length; i++) {
            if (hs.rareAccessories[traitPackId][allAccessories[i]]) {
                rareCount++;
            }
        }
        
        // Create array of rare accessories
        uint8[] memory rareAccessories = new uint8[](rareCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < allAccessories.length; i++) {
            if (hs.rareAccessories[traitPackId][allAccessories[i]]) {
                rareAccessories[index] = allAccessories[i];
                index++;
            }
        }
        
        return rareAccessories;
    }
    
    /**
     * @notice Check if a token has a specific trait pack
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param traitPackId Trait pack ID to check for
     * @return hasTraitPack Whether token has the trait pack
     */
    function tokenHasTraitPack(uint256 collectionId, uint256 tokenId, uint8 traitPackId) 
        external 
        view 
        returns (bool hasTraitPack) 
    {
        (bool traitPacksAvailable, uint8[] memory traitPacks) = _getTokenTraitPacks(collectionId, tokenId);
        
        if (!traitPacksAvailable) {
            return false;
        }
        
        // If checking for any trait pack
        if (traitPackId == 0) {
            return traitPacks.length > 0;
        }
        
        // Check for specific trait pack
        for (uint256 i = 0; i < traitPacks.length; i++) {
            if (traitPacks[i] == traitPackId) {
                return true;
            }
        }
        
        return false;
    }
    
    /**
     * @notice Get all trait packs that a token has
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return tokenTraitPacks Array of trait pack IDs
     */
    function getTokenTraitPacks(uint256 collectionId, uint256 tokenId) 
        external 
        view 
        returns (uint8[] memory tokenTraitPacks) 
    {
        (bool traitPacksAvailable, uint8[] memory traitPacks) = _getTokenTraitPacks(collectionId, tokenId);
        
        if (traitPacksAvailable) {
            return traitPacks;
        } else {
            // Return empty array if no trait packs
            return new uint8[](0);
        }
    }
    
    /**
     * @notice Get all registered trait packs
     * @return traitPackIds Array of registered trait pack IDs
     */
    function getAllTraitPacks() external view returns (uint8[] memory) {
        return LibHenomorphsStorage.henomorphsStorage().registeredTraitPacks;
    }

    /**
     * @notice Get trait pack with full details
     * @param traitPackId Trait pack ID
     * @return name Trait pack name
     * @return description Trait pack description
     * @return baseURI Base URI for trait pack metadata
     * @return enabled Whether trait pack is enabled
     * @return compatibleVariants Array of compatible variants
     * @return assetIds Array of compatible asset IDs
     * @return dataHash Hash of trait pack data for cross-system verification
     */
    function getEnhancedTraitPack(uint8 traitPackId) external view returns (
        string memory name,
        string memory description,
        string memory baseURI,
        bool enabled,
        uint8[] memory compatibleVariants,
        uint64[] memory assetIds,
        bytes32 dataHash
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Check if TraitPack exists by verifying its name is not empty
        if (bytes(hs.traitPacks[traitPackId].name).length == 0) {
            revert TraitPackNotFound();
        }
        
        TraitPack storage traitPack = hs.traitPacks[traitPackId];
        ModularAssetModel.EnhancedTraitPack storage enhancedPack = hs.enhancedTraitPacks[traitPackId];
        
        // Generate data hash for verification
        dataHash = LibTraitPackHelper.generateTraitPackDataHash(traitPackId);
        
        return (
            traitPack.name,
            traitPack.description,
            traitPack.baseURI,
            traitPack.enabled,
            enhancedPack.compatibleVariants,
            enhancedPack.assetIds,
            dataHash
        );
    }

    /**
     * @notice Get full trait pack compatibility data
     * @param traitPackId Trait pack ID
     * @param variant Specimen variant
     * @return isCompatible Whether variant is compatible
     * @return efficiencyBonus Efficiency bonus provided
     * @return regenBonus Regeneration bonus provided
     * @return maxChargeBonus Max charge bonus provided
     * @return calibrationMod Calibration modifier
     * @return stakingBonus Staking bonus provided
     */
    function getTraitPackCompatibilityData(uint8 traitPackId, uint8 variant) external view returns (
        bool isCompatible,
        uint8 efficiencyBonus,
        uint8 regenBonus,
        uint8 maxChargeBonus,
        int8 calibrationMod,
        uint8 stakingBonus
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Check if trait pack exists by verifying its name is not empty
        if (bytes(hs.traitPacks[traitPackId].name).length == 0) {
            return (false, 0, 0, 0, 0, 0);
        }
        
        // Check variant compatibility
        isCompatible = false;
        uint8[] storage compatibleVariants = hs.enhancedTraitPacks[traitPackId].compatibleVariants;
        
        if (compatibleVariants.length == 0) {
            // If no specific variants defined, compatible with all
            isCompatible = true;
        } else {
            for (uint256 i = 0; i < compatibleVariants.length; i++) {
                if (compatibleVariants[i] == variant) {
                    isCompatible = true;
                    break;
                }
            }
        }
        
        // Calculate standardized bonuses
        (
            efficiencyBonus,
            regenBonus,
            maxChargeBonus,
            calibrationMod,
            stakingBonus
        ) = LibTraitPackHelper.calculateStandardizedBonuses(traitPackId, variant);
        
        return (isCompatible, efficiencyBonus, regenBonus, maxChargeBonus, calibrationMod, stakingBonus);
    }

    /**
     * @notice Get trait pack with augment configuration
     * @param traitPackId Trait pack ID
     * @return name Trait pack name
     * @return description Trait pack description
     * @return baseURI Base URI
     * @return enabled Whether enabled
     * @return baseCalibrationMod Base calibration modifier
     * @return biopodBonus Calculated biopod bonus
     * @return chargepodBonus Calculated chargepod bonus
     * @return stakingBonus Calculated staking bonus
     * @return compatibleAssets Compatible asset IDs
     */
    function getAugmentTraitPack(uint8 traitPackId) external view returns (
        string memory name,
        string memory description,
        string memory baseURI,
        bool enabled,
        int8 baseCalibrationMod,
        uint8 biopodBonus,
        uint8 chargepodBonus,
        uint8 stakingBonus,
        uint64[] memory compatibleAssets
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (bytes(hs.traitPacks[traitPackId].name).length == 0) {
            revert TraitPackNotFound();
        }
        
        TraitPack storage traitPack = hs.traitPacks[traitPackId];
        ModularAssetModel.EnhancedTraitPack storage enhancedPack = hs.enhancedTraitPacks[traitPackId];
        
        // Get base calibration modifier
        baseCalibrationMod = hs.traitPackVariantBonuses[traitPackId][0];
        
        // Get augment bonuses using existing calculation
        (biopodBonus, chargepodBonus, stakingBonus,,,) = _getAugmentBonuses(traitPackId);
        
        return (
            traitPack.name,
            traitPack.description,
            traitPack.baseURI,
            traitPack.enabled,
            baseCalibrationMod,
            biopodBonus,
            chargepodBonus,
            stakingBonus,
            enhancedPack.assetIds
        );
    }

    /**
     * @notice Sync trait pack data with CollectionDiamond
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return syncSuccess Whether sync was successful
     */
    function syncAugmentTraitPack(
        uint256 collectionId,
        uint256 tokenId
    ) external view returns (bool syncSuccess) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        
        if (collection.diamondAddress == address(0)) {
            return false;
        }
        
        try ICollectionDiamond(collection.diamondAddress).hasSpecimenAugment(
            collection.collectionAddress,
            tokenId
        ) returns (bool hasAugment) {
            return hasAugment;
        } catch {
            return false;
        }
    }
    
    // ==================== INTERNAL FUNCTIONS ====================
    
    /**
     * @notice Get token trait packs with CollectionDiamond integration
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return traitPacksAvailable Whether trait packs are available
     * @return traitPacks Array of trait pack IDs
     */
    function _getTokenTraitPacks(
        uint256 collectionId,
        uint256 tokenId
    ) internal view returns (bool traitPacksAvailable, uint8[] memory traitPacks) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        
        // Method 1: CollectionDiamond integration (primary)
        if (collection.diamondAddress != address(0)) {
            try ICollectionDiamond(collection.diamondAddress).getSpecimenEquipment(
                collection.collectionAddress,
                tokenId
            ) returns (TraitPackEquipment memory equipment) {
                if (equipment.traitPackTokenId > 0) {
                    traitPacks = new uint8[](1);
                    traitPacks[0] = uint8(equipment.traitPackTokenId);
                    traitPacksAvailable = true;
                    return (traitPacksAvailable, traitPacks);
                }
            } catch {
                // Diamond failed, try fallback
            }
        }
        
        // Method 2: Collection fallback
        try IExternalCollection(collection.collectionAddress).itemEquipments(tokenId) returns (uint8[] memory equipments) {
            if (equipments.length > 0) {
                traitPacks = equipments;
                traitPacksAvailable = true;
                return (traitPacksAvailable, traitPacks);
            }
        } catch {
            // Collection failed
        }
        
        // Method 3: Legacy verification fallback
        (bool traitPackMatch, uint8[] memory tokenTraitPacks) = LibTraitPackHelper.verifyTraitPack(
            collectionId,
            tokenId,
            0 // Check for any trait pack
        );
        
        traitPacksAvailable = traitPackMatch && tokenTraitPacks.length > 0;
        if (traitPacksAvailable) {
            traitPacks = tokenTraitPacks;
        } else {
            traitPacks = new uint8[](0);
        }
        
        return (traitPacksAvailable, traitPacks);
    }

    /**
     * @notice Get augment bonuses from trait pack configuration
     * @param traitPackId Trait pack ID
     * @return biopodBonus Biopod bonus percentage
     * @return chargepodBonus Chargepod bonus percentage
     * @return stakingBonus Staking bonus percentage
     * @return wearReduction Wear reduction percentage
     * @return colonyBonus Colony bonus percentage
     * @return seasonalMultiplier Seasonal multiplier
     */
    function _getAugmentBonuses(uint8 traitPackId) internal view returns (
        uint8 biopodBonus,
        uint8 chargepodBonus,
        uint8 stakingBonus,
        uint8 wearReduction,
        uint8 colonyBonus,
        uint16 seasonalMultiplier
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Check if trait pack exists and get configured bonuses
        if (bytes(hs.traitPacks[traitPackId].name).length > 0) {
            // Use augment configuration values from complete-augment-configuration.ts
            biopodBonus = 10;      // 10% biopod bonus
            chargepodBonus = 12;   // 12% chargepod bonus
            stakingBonus = 15;     // 15% staking bonus
            wearReduction = 20;    // 20% wear reduction
            colonyBonus = 15;      // 15% colony bonus
            seasonalMultiplier = 125; // 125% seasonal multiplier (25% boost)
            
            // Apply variant-specific modifiers if configured
            int8 baseMod = hs.traitPackVariantBonuses[traitPackId][0];
            if (baseMod > 0) {
                stakingBonus += uint8(baseMod);
                biopodBonus += uint8(baseMod);
                chargepodBonus += uint8(baseMod);
            }
        }
    }
    
    /**
     * @notice Internal helper to check if trait pack is in the registered list
     * @param traitPackId Trait pack ID to check
     * @return Whether trait pack is in list
     */
    function _isTraitPackInList(uint8 traitPackId) internal view returns (bool) {
        uint8[] storage registeredTraitPacks = LibHenomorphsStorage.henomorphsStorage().registeredTraitPacks;
        
        for (uint256 i = 0; i < registeredTraitPacks.length; i++) {
            if (registeredTraitPacks[i] == traitPackId) {
                return true;
            }
        }
        
        return false;
    }
}
