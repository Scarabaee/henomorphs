// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "./LibHenomorphsStorage.sol";
import {PodsUtils} from "../../../libraries/PodsUtils.sol";
import {ChargeAccessory, SpecimenCollection, TraitPackEquipment} from "../../../libraries/HenomorphsModel.sol";
import {ISpecimenCollection} from "../../../interfaces/ISpecimenCollection.sol";
import {ICollectionDiamond} from "../../modular/interfaces/ICollectionDiamond.sol";
import {IExternalCollection, IRankingFacet} from "../../staking/interfaces/IStakingInterfaces.sol";

/**
 * @title LibTraitPackHelper
 * @notice Enhanced helper library with cross-collection augment integration
 * @dev Version 2.0 with preparation for cross-system compatibility
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
library LibTraitPackHelper {
    // Error definitions
    error IncompatibleTraitPack(uint8 requiredTraitPack);
    error InvalidVariantRange();
    error InvalidTraitPackId();
    error TraitPackAlreadyRegistered();
    error TraitPackDoesNotExist();
    error AssetNotCompatible();
    
    // Constants for versioning and type identification
    bytes32 private constant TRAIT_PACK_TYPEHASH = keccak256("TraitPack(uint8 id,string name,bool enabled,uint32 registrationTime)");

    uint256 private constant MAX_ACCESSORIES_PER_EQUIPMENT = 50;
    uint256 private constant MAX_TOTAL_ACCESSORIES = 100;

    /**
     * @notice Structure for tracking applied bonuses
     * @dev Used for returning detailed bonus application results
     */
    struct AppliedBonuses {
        uint8 traitPackId;
        uint8 chargeEfficiencyBonus;
        uint8 regenRateBonus;
        uint8 maxChargeBonus;
        int8 calibrationMod;
        uint8 stakingBonus;
        bool applied;
    }

    /**
     * @notice Get aggregated equipment from all assigned augments and legacy trait packs
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return equipments Array of all trait pack equipments from assigned augments
     */
    function getAggregatedEquipment(
        uint256 collectionId,
        uint256 tokenId
    ) internal view returns (TraitPackEquipment[] memory equipments) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        
        // PRIMARY: CollectionDiamond for augment assignments
        if (collection.diamondAddress != address(0)) {
            try ICollectionDiamond(collection.diamondAddress).getSpecimenEquipment(
                collection.collectionAddress,
                tokenId
            ) returns (TraitPackEquipment memory equipment) {
                // Check for corrupted data
                if (equipment.accessoryIds.length > MAX_ACCESSORIES_PER_EQUIPMENT) {
                    equipment.accessoryIds = new uint64[](0);
                }
                
                if (equipment.traitPackTokenId > 0 || equipment.accessoryIds.length > 0) {
                    equipments = new TraitPackEquipment[](1);
                    equipments[0] = equipment;
                    return equipments;
                }
            } catch {
                // Diamond failed, try collection fallback
            }
        }
        
        // FALLBACK: Collection's own equipment definitions
        try IExternalCollection(collection.collectionAddress).getTokenEquipment(tokenId) returns (
            TraitPackEquipment memory equipment
        ) {
            if (equipment.accessoryIds.length > MAX_ACCESSORIES_PER_EQUIPMENT) {
                equipment.accessoryIds = new uint64[](0);
            }
            
            if (equipment.traitPackTokenId > 0 || equipment.accessoryIds.length > 0) {
                equipments = new TraitPackEquipment[](1);
                equipments[0] = equipment;
                return equipments;
            }
        } catch {
            // Collection equipment failed, try legacy
        }
        
        // LEGACY FALLBACK: itemEquipments()
        try IExternalCollection(collection.collectionAddress).itemEquipments(tokenId) returns (uint8[] memory traitPacks) {
            if (traitPacks.length > 0) {
                TraitPackEquipment memory equipment;
                equipment.traitPackCollection = collection.collectionAddress;
                equipment.traitPackTokenId = traitPacks[0];
                
                // Get variant
                try IExternalCollection(collection.collectionAddress).itemVariant(tokenId) returns (uint8 variant) {
                    equipment.variant = variant;
                } catch {
                    equipment.variant = 1;
                }
                
                // Get accessories
                equipment.accessoryIds = _getAccessoriesForTraitPack(uint8(equipment.traitPackTokenId));
                
                equipments = new TraitPackEquipment[](1);
                equipments[0] = equipment;
                return equipments;
            }
        } catch {
            // All methods failed
        }
        
        return new TraitPackEquipment[](0);
    }

    function getAccessoriesForTraitPack(uint8 traitPackId) internal view returns (uint64[] memory accessoryIds) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        uint8[] storage accessories = hs.traitPackAccessories[traitPackId];
        
        if (accessories.length == 0 || accessories.length > 15) {
            return new uint64[](0);
        }
        
        accessoryIds = new uint64[](accessories.length);
        
        for (uint256 i = 0; i < accessories.length; i++) {
            accessoryIds[i] = uint64(accessories[i]);
        }
        
        return accessoryIds;
    }


    /**
     * @notice Get all accessory IDs from assigned augments and legacy trait packs
     * @param collectionId Collection ID  
     * @param tokenId Token ID
     * @return accessoryIds Aggregated array of all accessory IDs
     */
    function getAllAccessoriesForToken(
        uint256 collectionId,
        uint256 tokenId
    ) internal view returns (uint64[] memory) {
        TraitPackEquipment[] memory equipments = getAggregatedEquipment(collectionId, tokenId);
        
        if (equipments.length == 0) {
            return new uint64[](0);
        }
        
        // Prevent memory issues
        uint256 totalAccessories = 0;
        for (uint256 i = 0; i < equipments.length; i++) {
            if (equipments[i].accessoryIds.length > MAX_ACCESSORIES_PER_EQUIPMENT) {
                return new uint64[](0);
            }
            totalAccessories += equipments[i].accessoryIds.length;
            if (totalAccessories > MAX_TOTAL_ACCESSORIES) {
                return new uint64[](0);
            }
        }
        
        uint64[] memory allAccessories = new uint64[](totalAccessories);
        uint256 index = 0;
        
        for (uint256 i = 0; i < equipments.length; i++) {
            for (uint256 j = 0; j < equipments[i].accessoryIds.length; j++) {
                allAccessories[index++] = equipments[i].accessoryIds[j];
            }
        }
        
        return allAccessories;
    }

    // 2. ADD TO AccessoryFacet.sol (duplicate for local use):
    function _getAccessoriesForTraitPack(uint8 traitPackId) internal view returns (uint64[] memory) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        uint8[] storage accessories = hs.traitPackAccessories[traitPackId];
        
        // Prevent corrupted data from causing memory issues
        if (accessories.length > MAX_ACCESSORIES_PER_EQUIPMENT) {
            return new uint64[](0);
        }
        
        uint64[] memory accessoryIds = new uint64[](accessories.length);
        
        for (uint256 i = 0; i < accessories.length; i++) {
            accessoryIds[i] = uint64(accessories[i]);
        }
        
        return accessoryIds;
    }

    /**
     * @notice Get augment equipments from registered collections
     * @param specimenCollection Specimen collection address
     * @param tokenId Token ID
     * @return equipments Array of trait pack equipments from assigned augments
     */
    function _getAugmentEquipments(
        address specimenCollection,
        uint256 tokenId
    ) private view returns (TraitPackEquipment[] memory equipments) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Find collection in registry
        uint256 collectionId = 0;
        for (uint256 i = 1; i <= hs.collectionCounter; i++) {
            if (hs.specimenCollections[i].collectionAddress == specimenCollection) {
                collectionId = i;
                break;
            }
        }
        
        if (collectionId == 0) {
            return new TraitPackEquipment[](0);
        }
        
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        
        // Check if collection has diamond and supports ModularSpecimen
        if (collection.diamondAddress != address(0) && collection.isModularSpecimen) {
            return _queryDiamondForAugments(collection.diamondAddress, specimenCollection, tokenId);
        } else {
            return _queryLegacyForAugments(specimenCollection, tokenId);
        }
    }

    /**
     * @notice Query Collection Diamond for augment assignments
     * @param diamondAddress Collection Diamond address
     * @param specimenCollection Specimen collection address
     * @param tokenId Token ID
     * @return equipments Array of trait pack equipments
     */
    function _queryDiamondForAugments(
        address diamondAddress,
        address specimenCollection,
        uint256 tokenId
    ) private view returns (TraitPackEquipment[] memory equipments) {
        try ICollectionDiamond(diamondAddress).getSpecimenEquipment(
            specimenCollection,
            tokenId
        ) returns (TraitPackEquipment memory equipment) {
            
            if (equipment.traitPackCollection != address(0)) {
                equipments = new TraitPackEquipment[](1);
                equipments[0] = equipment;
            } else {
                equipments = new TraitPackEquipment[](0);
            }
            
        } catch {
            equipments = new TraitPackEquipment[](0);
        }
        
        return equipments;
    }

    /**
     * @notice Query legacy collection for trait pack equipment
     * @param specimenCollection Specimen collection address
     * @param tokenId Token ID
     * @return equipments Array of trait pack equipments
     */
    function _queryLegacyForAugments(
        address specimenCollection,
        uint256 tokenId
    ) private view returns (TraitPackEquipment[] memory equipments) {
        try ISpecimenCollection(specimenCollection).getTokenEquipment(tokenId) returns (
            TraitPackEquipment memory equipment
        ) {
            if (equipment.traitPackCollection != address(0)) {
                equipments = new TraitPackEquipment[](1);
                equipments[0] = equipment;
            } else {
                equipments = new TraitPackEquipment[](0);
            }
        } catch {
            equipments = new TraitPackEquipment[](0);
        }
        
        return equipments;
    }

     /**
     * @notice Gets complete equipment data using enhanced ISpecimenCollection interface
     * @dev Tries both new and legacy methods with fallback mechanism
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return equipment Complete equipment data structure
     * @return success Whether retrieval was successful
     */
    function getTokenEquipmentData(
        uint256 collectionId,
        uint256 tokenId
    ) internal view returns (TraitPackEquipment memory equipment, bool success) {
        // Get collection data
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        
        // Default initialization
        equipment = TraitPackEquipment({
            traitPackCollection: address(0),
            traitPackTokenId: 0,
            accessoryIds: new uint64[](0),
            tier: 0,
            variant: 0,
            assignmentTime: 0,
            unlockTime: 0,
            locked: false
        });
        
        // Try enhanced method first
        try ISpecimenCollection(collection.collectionAddress).getTokenEquipment(tokenId) returns (
            TraitPackEquipment memory result
        ) {
            equipment = result;
            success = true;
            return (equipment, success);
        } catch {
            // Fallback to legacy method
            try ISpecimenCollection(collection.collectionAddress).itemEquipments(tokenId) returns (uint8[] memory traitPacks) {
                if (traitPacks.length > 0) {
                    equipment.traitPackCollection = collection.collectionAddress;
                    equipment.traitPackTokenId = traitPacks[0]; // Use the first trait pack
                    success = true;
                }
                return (equipment, success);
            } catch {
                // Both methods failed
                return (equipment, false);
            }
        }
    }

    /**
     * @notice Verifies if token has specified trait pack with extended validation
     * @dev Enhanced version of verifyTraitPack with equipment data retrieval
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param requiredTraitPackId Required trait pack ID (0 for any)
     * @return traitPackMatch Whether required trait pack matches
     * @return tokenTraitPacks Array of trait pack IDs
     * @return equipmentData Complete equipment data (if available)
     */
    function verifyTraitPackWithEquipment(
        uint256 collectionId,
        uint256 tokenId,
        uint8 requiredTraitPackId
    ) internal view returns (
        bool traitPackMatch,
        uint8[] memory tokenTraitPacks,
        TraitPackEquipment memory equipmentData
    ) {
        // Try to get equipment data first
        bool equipmentSuccess;
        (equipmentData, equipmentSuccess) = getTokenEquipmentData(collectionId, tokenId);
        
        // If equipment data retrieval successful
        if (equipmentSuccess && equipmentData.traitPackTokenId > 0) {
            // Check if matches required trait pack or no specific requirement
            if (requiredTraitPackId == 0 || uint8(equipmentData.traitPackTokenId) == requiredTraitPackId) {
                traitPackMatch = true;
                
                // Create array with a single trait pack ID
                tokenTraitPacks = new uint8[](1);
                tokenTraitPacks[0] = uint8(equipmentData.traitPackTokenId);
                
                return (traitPackMatch, tokenTraitPacks, equipmentData);
            }
        }
        
        // Fall back to legacy method if equipment data didn't match or wasn't available
        (traitPackMatch, tokenTraitPacks) = verifyTraitPack(collectionId, tokenId, requiredTraitPackId);
        
        return (traitPackMatch, tokenTraitPacks, equipmentData);
    }
    
    /**
     * @notice Enhanced verification for trait pack compatibility with extensibility hooks
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param requiredTraitPackId Required trait pack ID (0 means no requirement)
     * @return traitPackMatch Whether a match was found
     * @return tokenTraitPacks Array of token's trait packs
     * @return compatibilityData Additional compatibility data for cross-system integration
     */
    function verifyTraitPackExtended(
        uint256 collectionId,
        uint256 tokenId,
        uint8 requiredTraitPackId
    ) internal view returns (
        bool traitPackMatch, 
        uint8[] memory tokenTraitPacks,
        bytes memory compatibilityData
    ) {
        // Get collection data
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        
        // If no trait pack requirement, return immediately as matched
        if (requiredTraitPackId == 0) {
            try ISpecimenCollection(collection.collectionAddress).itemEquipments(tokenId) returns (uint8[] memory traitPacks) {
                // Package compatibility data for future extension
                compatibilityData = abi.encode(collection.collectionType, block.timestamp);
                return (true, traitPacks, compatibilityData);
            } catch {
                tokenTraitPacks = new uint8[](0);
                compatibilityData = abi.encode(collection.collectionType, block.timestamp);
                return (true, tokenTraitPacks, compatibilityData);
            }
        }
            
        // Default to empty array
        tokenTraitPacks = new uint8[](0);
        
        // Try to get token's trait packs
        try ISpecimenCollection(collection.collectionAddress).itemEquipments(tokenId) returns (uint8[] memory traitPacks) {
            tokenTraitPacks = traitPacks;
            
            // Check if any trait packs match the requirement
            for (uint256 i = 0; i < traitPacks.length; i++) {
                if (traitPacks[i] == requiredTraitPackId) {
                    // Package compatibility data for future extension
                    compatibilityData = abi.encode(collection.collectionType, block.timestamp);
                    return (true, tokenTraitPacks, compatibilityData);
                }
            }
        } catch {
            // If trait pack retrieval fails, check variant to see if token could potentially have trait packs
            try ISpecimenCollection(collection.collectionAddress).itemVariant(tokenId) returns (uint8 variant) {
                // If token has variant 0 (Genesis Core), it cannot have trait packs
                if (variant == 0) {
                    compatibilityData = abi.encode(collection.collectionType, variant, block.timestamp);
                    return (false, tokenTraitPacks, compatibilityData);
                }
                
                // Otherwise token could have trait packs, but doesn't have the required one
                compatibilityData = abi.encode(collection.collectionType, variant, block.timestamp);
                return (false, tokenTraitPacks, compatibilityData);
            } catch {
                // In case of error, return default values
                compatibilityData = abi.encode(0, 0, block.timestamp);
                return (false, tokenTraitPacks, compatibilityData);
            }
        }
        
        compatibilityData = abi.encode(collection.collectionType, 0, block.timestamp);
        return (false, tokenTraitPacks, compatibilityData);
    }
    
    /**
     * @notice Legacy verification method for backward compatibility
     * @dev Calls enhanced method internally but returns only the original values
     */
    function verifyTraitPack(
        uint256 collectionId,
        uint256 tokenId,
        uint8 requiredTraitPackId
    ) internal view returns (bool traitPackMatch, uint8[] memory tokenTraitPacks) {
        (traitPackMatch, tokenTraitPacks, ) = verifyTraitPackExtended(collectionId, tokenId, requiredTraitPackId);
        return (traitPackMatch, tokenTraitPacks);
    }

    /**
     * @notice Applies trait pack bonuses to a token
     * @dev Comprehensive bonus application with variant-specific effects
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param traitPackId Trait pack ID to apply
     * @return Applied bonuses structure
     */
    function applyTraitPackBonuses(
        uint256 collectionId,
        uint256 tokenId,
        uint8 traitPackId
    ) internal returns (AppliedBonuses memory) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        // Get token's variant
        uint8 tokenVariant = 1; // Default variant
        try ISpecimenCollection(hs.specimenCollections[collectionId].collectionAddress).itemVariant(tokenId) returns (uint8 variant) {
            tokenVariant = variant;
        } catch {
            // Use default if retrieval fails
        }
        
        // Get standardized bonuses
        (
            uint8 chargeEfficiencyBonus,
            uint8 regenRateBonus,
            uint8 maxChargeBonus,
            int8 calibrationMod,
            uint8 stakingBonus
        ) = calculateStandardizedBonuses(traitPackId, tokenVariant);
        
        // Apply bonuses to PowerMatrix
        AppliedBonuses memory bonuses;
        bonuses.traitPackId = traitPackId;
        bonuses.chargeEfficiencyBonus = chargeEfficiencyBonus;
        bonuses.regenRateBonus = regenRateBonus;
        bonuses.maxChargeBonus = maxChargeBonus;
        bonuses.calibrationMod = calibrationMod;
        bonuses.stakingBonus = stakingBonus;
        
        // Update the power matrix
        if (chargeEfficiencyBonus > 0 || regenRateBonus > 0 || maxChargeBonus > 0) {
            // Get the power matrix
            hs.performedCharges[combinedId].chargeEfficiency += chargeEfficiencyBonus;
            hs.performedCharges[combinedId].regenRate += uint16(regenRateBonus);
            hs.performedCharges[combinedId].maxCharge += uint128(maxChargeBonus);
            
            bonuses.applied = true;
        }
        
        return bonuses;
    }

    /**
     * @notice Determines if an asset is compatible with a trait pack (extended version)
     * @dev Uses existing function as base and adds integration data
     * @param traitPackId TraitPack ID
     * @param assetId Asset ID
     * @return isCompatible Whether asset is compatible
     * @return compatibilityData Additional compatibility data
     */
    function isAssetCompatibleWithTraitPackExtended(
        uint8 traitPackId,
        uint64 assetId
    ) internal view returns (bool isCompatible, bytes memory compatibilityData) {
        // Check basic conditions
        if (traitPackId == 0 || assetId == 0) {
            compatibilityData = abi.encode(0, 0);
            return (false, compatibilityData);
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Check if TraitPack exists
        if (bytes(hs.traitPacks[traitPackId].name).length == 0) {
            compatibilityData = abi.encode(1, 0);
            return (false, compatibilityData);
        }
        
        // Use original function without modifying its implementation
        isCompatible = isAssetCompatibleWithTraitPack(traitPackId, assetId);
        
        // Add integration data
        compatibilityData = abi.encode(
            isCompatible ? 1 : 0,  // Result code
            block.timestamp,       // Check timestamp
            traitPackId,           // TraitPack ID
            assetId                // Asset ID
        );
        
        return (isCompatible, compatibilityData);
    }
    
    /**
     * @notice Legacy asset compatibility check for backward compatibility
     * @dev Calls enhanced method internally but returns only the compatibility flag
     */
    function isAssetCompatibleWithTraitPack(
        uint8 traitPackId,
        uint64 assetId
    ) internal view returns (bool isCompatible) {
        (isCompatible, ) = isAssetCompatibleWithTraitPackExtended(traitPackId, assetId);
        return isCompatible;
    }
    
    /**
     * @notice Get calibration modifier with enhanced return values
     * @param traitPackId TraitPack ID
     * @param variant Henomorph variant
     * @return calibrationMod Calibration modifier
     * @return modifierSource Source of the modifier
     * @return extensionData Additional data for future extensibility
     */
    function getTraitPackCalibrationModExtended(
        uint8 traitPackId,
        uint8 variant
    ) internal view returns (int8 calibrationMod, uint8 modifierSource, bytes memory extensionData) {
        if (traitPackId == 0) {
            extensionData = abi.encode(0);
            return (0, 0, extensionData);
        }
        
        // Use ONLY existing function that already works correctly in the system
        calibrationMod = getTraitPackCalibrationMod(traitPackId, variant);
        
        // Determine the source of the modifier based solely on the result
        if (calibrationMod != 0) {
            modifierSource = 1; // We have some modifier, but don't know its exact source
        } else {
            modifierSource = 0; // No modifier
        }
        
        // Pack data
        extensionData = abi.encode(calibrationMod);
        
        return (calibrationMod, modifierSource, extensionData);
    }
        
    /**
     * @notice Legacy calibration modifier getter for backward compatibility 
     * @dev Calls enhanced method internally but returns only the modifier value
     */
    function getTraitPackCalibrationMod(
        uint8 traitPackId,
        uint8 variant
    ) internal view returns (int8 calibrationMod) {
        if (traitPackId == 0) {
            return 0;
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Get base modifier (stored at variant 0)
        int8 baseMod = hs.traitPackVariantBonuses[traitPackId][0];
        
        // Get variant-specific modifier
        int8 variantMod = hs.traitPackVariantBonuses[traitPackId][variant];
        
        // Return sum of base and variant-specific modifiers
        return baseMod + variantMod;
    }

    /**
     * @notice Calculate expected bonus values for a token
     * @dev Integration-ready method for deriving expected bonuses
     */
    function calculateExpectedBonuses(
        uint256 collectionId,
        uint256 tokenId
    ) 
        external 
        view 
        returns (
            uint256[] memory baseValues,
            uint256[] memory accessoryBonuses,
            uint256[] memory traitPackBonuses,
            uint256[] memory totalValues
        )
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        // Get token's accessories
        ChargeAccessory[] storage accessories = hs.equippedAccessories[combinedId];
        
        // Initialize return arrays
        baseValues = new uint256[](3);
        accessoryBonuses = new uint256[](3);
        traitPackBonuses = new uint256[](3);
        totalValues = new uint256[](3);
        
        // Define base values (without bonuses)
        baseValues[0] = 50;  // Base efficiency
        baseValues[1] = 5;   // Base regen
        baseValues[2] = 100; // Base max charge
        
        // Calculate accessory bonuses
        for (uint256 i = 0; i < accessories.length; i++) {
            ChargeAccessory storage accessory = accessories[i];
            
            // Efficiency bonuses
            accessoryBonuses[0] += accessory.efficiencyBoost;
            
            // Specialization efficiency bonus
            if ((accessory.specializationType == 0 || accessory.specializationType == 1) && 
                hs.performedCharges[combinedId].specialization == 1) {
                accessoryBonuses[0] += accessory.specializationBoostValue;
            }
            
            // Regen bonuses
            accessoryBonuses[1] += accessory.regenBoost;
            
            // Specialization regen bonus
            if ((accessory.specializationType == 0 || accessory.specializationType == 2) && 
                hs.performedCharges[combinedId].specialization == 2) {
                accessoryBonuses[1] += accessory.specializationBoostValue;
            }
            
            // Max charge bonuses
            accessoryBonuses[2] += accessory.chargeBoost;
        }
        
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        
        // Get token's trait packs directly from collection
        try ISpecimenCollection(collection.collectionAddress).itemEquipments(tokenId) returns (uint8[] memory tokenTraitPacks) {
            
            // Calculate trait pack bonuses
            for (uint256 i = 0; i < accessories.length; i++) {
                ChargeAccessory storage accessory = accessories[i];
                
                if (accessory.traitPackId > 0) {
                    // Check if token has this trait pack - direct comparison
                    bool traitPackMatch = false;
                    for (uint256 j = 0; j < tokenTraitPacks.length; j++) {
                        if (tokenTraitPacks[j] == accessory.traitPackId) {
                            traitPackMatch = true;
                            break;
                        }
                    }
                    
                    if (traitPackMatch) {
                        // Standard bonus values
                        traitPackBonuses[0] += 10;  // Standard bonus for charge efficiency
                        traitPackBonuses[1] += 5;   // Standard bonus for regen rate
                    }
                }
            }
            
        } catch {
            // If trait pack retrieval fails, skip trait pack bonuses
        }
        
        // Calculate total values
        for (uint256 i = 0; i < 3; i++) {
            totalValues[i] = baseValues[i] + accessoryBonuses[i] + traitPackBonuses[i];
        }
        
        return (baseValues, accessoryBonuses, traitPackBonuses, totalValues);
    }

    /**
     * @notice Calculate standardized bonus values for a trait pack
     * @dev Used for standardized bonus calculation across systems
     * @param traitPackId Trait pack ID
     * @param variant Specimen variant
     * @return chargeEfficiencyBonus Bonus to charge efficiency (percentage)
     * @return regenRateBonus Bonus to regen rate (flat points)
     * @return maxChargeBonus Bonus to max charge capacity (flat points)
     * @return calibrationMod Calibration modifier (-128 to 127)
     * @return stakingBonus Staking reward bonus (percentage)
     */
    function calculateStandardizedBonuses(
        uint8 traitPackId,
        uint8 variant
    ) internal view returns (
        uint8 chargeEfficiencyBonus,
        uint8 regenRateBonus,
        uint8 maxChargeBonus,
        int8 calibrationMod,
        uint8 stakingBonus
    ) {
        // Default values
        chargeEfficiencyBonus = 10;
        regenRateBonus = 5;
        maxChargeBonus = 0;
        calibrationMod = 0;
        stakingBonus = 0;
        
        // Return defaults if trait pack doesn't exist
        if (traitPackId == 0) {
            return (chargeEfficiencyBonus, regenRateBonus, maxChargeBonus, calibrationMod, stakingBonus);
        }
        
        // Use existing function to get calibration modifier
        calibrationMod = getTraitPackCalibrationMod(traitPackId, variant);
        
        // Add variant-specific bonuses as examples
        if (variant == 1) { // Example bonus for variant 1
            regenRateBonus += 2;
        } else if (variant == 2) { // Example bonus for variant 2
            chargeEfficiencyBonus += 3;
        } else if (variant == 3) { // Example bonus for variant 3
            maxChargeBonus += 10;
        } else if (variant == 4) { // Example bonus for variant 4
            stakingBonus += 5;
        }
        
        return (chargeEfficiencyBonus, regenRateBonus, maxChargeBonus, calibrationMod, stakingBonus);
    }

    /**
     * @notice Generate integration-ready trait pack data hash
     * @dev Used for cross-system verification
     * @param traitPackId Trait pack ID
     * @return dataHash Hash of trait pack data for verification
     */
    function generateTraitPackDataHash(uint8 traitPackId) internal view returns (bytes32 dataHash) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (traitPackId == 0 || bytes(hs.traitPacks[traitPackId].name).length == 0) {
            return bytes32(0);
        }
        
        // Create a hash of critical trait pack data
        return keccak256(abi.encode(
            traitPackId,
            keccak256(bytes(hs.traitPacks[traitPackId].name)),
            hs.traitPacks[traitPackId].enabled,
            hs.traitPacks[traitPackId].registrationTime
        ));
    }

    /**
     * @notice Apply trait pack based bonuses to an accessory
     * @dev Checks if an accessory's trait pack matches one of the token's trait packs
     * @param accessory The accessory to check
     * @param tokenTraitPacks Array of token's trait packs
     * @return hasBonus Whether a trait pack bonus applies
     */
    function applyTraitPackBonusForAccessory(
        uint256,
        uint256,
        ChargeAccessory memory accessory,
        uint8[] memory tokenTraitPacks
    ) internal pure returns (bool hasBonus) {
        // Skip if accessory has no trait pack or token has no trait packs
        if (accessory.traitPackId == 0 || tokenTraitPacks.length == 0) {
            return false;
        }
        
        // Check for trait pack match
        for (uint256 i = 0; i < tokenTraitPacks.length; i++) {
            if (tokenTraitPacks[i] == accessory.traitPackId) {
                return true;
            }
        }
        
        return false;
    }

    /**
     * @notice Get token variant and verify it's valid
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return variant Token variant (1-4)
     */
    function getValidTokenVariant(uint256 collectionId, uint256 tokenId) internal view returns (uint8 variant) {
        // Get collection data
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        
        // Try to get variant
        try ISpecimenCollection(collection.collectionAddress).itemVariant(tokenId) returns (uint8 v) {
            variant = v;
        } catch {
            // Default to variant 1 if variant retrieval fails to avoid reverts
            variant = 1;
        }
        
        // Validate variant range
        if (variant < 1 || variant > 4) {
            revert InvalidVariantRange();
        }
        
        return variant;
    }
}