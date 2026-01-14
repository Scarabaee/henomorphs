// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibCollectionStorage} from "../libraries/LibCollectionStorage.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {TraitPackEquipment, ItemTier} from "../libraries/CollectionModel.sol";

/**
 * @title IntegrationFacet
 * @notice Handles external collection integration and system callbacks
 * @dev Implements ICollectionDiamond interface methods for collection management
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract IntegrationFacet is AccessControlBase {
    uint256 private constant DEFAULT_VARIANT_COUNT = 4;
    
    // ==================== EVENTS ====================
    
    event TokenMinted(uint256 indexed collectionId, uint256 indexed tokenId, address indexed owner);
    event TokenTransferred(uint256 indexed collectionId, uint256 indexed tokenId, address indexed from, address to);
    event VariantAssigned(uint256 indexed collectionId, uint256 indexed tokenId, uint8 variant);
    event AugmentChanged(uint256 indexed collectionId, uint256 indexed tokenId, uint8 oldAugment, uint8 newAugment);
    
    // ==================== ERRORS ====================
    
    error InvalidVariant(uint8 variant);
    
    // ==================== CALLBACK FUNCTIONS ====================

    /**
     * @notice Admin force assign variant (bypasses all validation)
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param variant Variant (1-10)
     * @param tier Tier level
     */
    function adminForceVariant(
        uint256 collectionId,
        uint256 tokenId,
        uint8 variant,
        uint8 tier
    ) external onlyAuthorized whenNotPaused validCollection(collectionId) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Use collectionId->tier->tokenId mapping for variant assignment
        cs.itemsVariants[collectionId][tier][tokenId] = variant;
        
        // Track assignment time using collectionId->tokenId mapping
        cs.collectionItemsVarianted[collectionId][tokenId] = block.number;
        
        // Update hit counters using collectionId->tier->variant structure
        cs.hitVariantsCounters[collectionId][tier][variant]++;
        
        emit VariantAssigned(collectionId, tokenId, variant);
    }

    /**
     * @notice Admin batch assign variants
     * @param collectionId Collection ID
     * @param tokenIds Token IDs array
     * @param variants Variants array (same length)
     * @param tier Tier level
     */
    function adminBatchVariants(
        uint256 collectionId,
        uint256[] calldata tokenIds,
        uint8[] calldata variants,
        uint8 tier
    ) external onlyAuthorized whenNotPaused validCollection(collectionId) {
        require(tokenIds.length == variants.length, "Length mismatch");
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (variants[i] > 0 && variants[i] <= 10) {
                // Use collectionId->tier->tokenId mapping for variant assignment
                cs.itemsVariants[collectionId][tier][tokenIds[i]] = variants[i];
                cs.collectionItemsVarianted[collectionId][tokenIds[i]] = block.number;
                
                // Update hit counters using collectionId->tier->variant structure
                cs.hitVariantsCounters[collectionId][tier][variants[i]]++;
            }
        }
        
    }
    
    /**
     * @notice Get variant hit counts for collection and tier
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param variant Variant to check
     * @return count Number of times variant was assigned
     */
    function getVariantHitCount(uint256 collectionId, uint8 tier, uint8 variant) 
        external view validCollection(collectionId) returns (uint256 count) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        return cs.hitVariantsCounters[collectionId][tier][variant];
    }
        
    /**
     * @notice Handle token mint notification from external collections
     * @param collectionId Collection identifier in the Diamond system
     * @param tokenId Token identifier
     * @param owner Token owner address
     */
    function onTokenMinted(uint256 collectionId, uint256 tokenId, address owner) external onlySystem {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Verify collection exists and is enabled
        LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
        if (!collection.enabled) {
            revert CollectionNotFound(collectionId);
        }
        
        // Update collection supply tracking
        unchecked {
            collection.currentSupply++;
        }
        
        // Update last activity timestamp
        collection.lastUpdateTime = block.timestamp;
        
        emit TokenMinted(collectionId, tokenId, owner);
    }
    
    /**
     * @notice Handle token transfer notification from external collections
     * @param collectionId Collection identifier in the Diamond system
     * @param tokenId Token identifier
     * @param from Previous owner address
     * @param to New owner address
     */
    function onTokenTransferred(uint256 collectionId, uint256 tokenId, address from, address to) external onlySystem {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Verify collection exists
        LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
        if (!collection.enabled) {
            revert CollectionNotFound(collectionId);
        }
        
        // Update last activity timestamp
        collection.lastUpdateTime = block.timestamp;
        
        emit TokenTransferred(collectionId, tokenId, from, to);
    }
    
    /**
     * @notice Handle variant assignment notification from external collections
     * @param collectionId Collection identifier in the Diamond system
     * @param tokenId Token identifier
     * @param variant Assigned variant (1-4)
     * @dev NOTE: This function does NOT update hitVariantsCounters to avoid double-counting.
     *      Counter updates are handled by RepositoryFacet.updateVariantCounters() which is
     *      called separately by RollingFacet after assignVariant completes.
     */
    function onVariantAssigned(uint256 collectionId, uint256 tokenId, uint8 variant) external onlySystem {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();

        // Verify collection exists
        LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
        if (!collection.enabled) {
            revert CollectionNotFound(collectionId);
        }

        ItemTier storage itemTier = cs.itemTiers[collectionId][collection.defaultTier];
        uint256 variantCount = itemTier.variantsCount > 0 ? itemTier.variantsCount : DEFAULT_VARIANT_COUNT;

        // Validate variant range (1-4 typical for Henomorphs)
        if (variant > variantCount) {
            revert InvalidVariant(variant);
        }

        // Store variant mapping using collectionId->tier->tokenId structure
        // NOTE: hitVariantsCounters is NOT updated here - it's handled by
        // RepositoryFacet.updateVariantCounters() to avoid double-counting bug
        if (collection.defaultTier > 0) {
            cs.itemsVariants[collectionId][collection.defaultTier][tokenId] = variant;
            cs.collectionItemsVarianted[collectionId][tokenId] = block.number;
        }

        // Update last activity timestamp
        collection.lastUpdateTime = block.timestamp;

        emit VariantAssigned(collectionId, tokenId, variant);
    }
    
    /**
     * @notice Handle augment change notification from external collections
     * @param collectionId Collection identifier in the Diamond system
     * @param tokenId Token identifier
     * @param oldAugment Previous augment identifier
     * @param newAugment New augment identifier
     */
    function onAugmentChanged(uint256 collectionId, uint256 tokenId, uint8 oldAugment, uint8 newAugment) external onlySystem {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Verify collection exists
        LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
        if (!collection.enabled) {
            revert CollectionNotFound(collectionId);
        }
        
        // Update augment mapping using tokenId->variant->traitPackId structure
        if (newAugment > 0) {
            cs.variantToTraitPack[tokenId][collection.defaultVariant] = newAugment;
        } else {
            delete cs.variantToTraitPack[tokenId][collection.defaultVariant];
        }
        
        // Update last activity timestamp
        collection.lastUpdateTime = block.timestamp;
        
        emit AugmentChanged(collectionId, tokenId, oldAugment, newAugment);
    }
    
    // ==================== QUERY FUNCTIONS ====================

    function getCollection(uint256 collectionId) external view returns (LibCollectionStorage.CollectionData memory) {
        if (!LibCollectionStorage.collectionExists(collectionId)) {
            revert CollectionNotFound(collectionId);
        }
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        return cs.collections[collectionId];
    }
    
    
    /**
     * @notice Get specimen equipment data from augment assignments
     * @param specimenCollection Specimen collection contract address
     * @param tokenId Token identifier
     * @return equipment TraitPackEquipment structure with accessory data
     */
    function getSpecimenEquipment(address specimenCollection, uint256 tokenId) 
        external view returns (TraitPackEquipment memory equipment) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Get active augment assignment for specimen
        bytes32 assignmentKey = cs.specimenToAssignment[specimenCollection][tokenId];
        if (assignmentKey == bytes32(0)) {
            // Return empty equipment if no assignment
            return TraitPackEquipment({
                traitPackCollection: address(0),
                traitPackTokenId: 0,
                accessoryIds: new uint64[](0),
                tier: 0,
                variant: 0,
                assignmentTime: 0,
                unlockTime: 0,
                locked: false
            });
        }
        
        LibCollectionStorage.AugmentAssignment storage assignment = cs.augmentAssignments[assignmentKey];
        if (!assignment.active) {
            return TraitPackEquipment({
                traitPackCollection: address(0),
                traitPackTokenId: 0,
                accessoryIds: new uint64[](0),
                tier: 0,
                variant: 0,
                assignmentTime: 0,
                unlockTime: 0,
                locked: false
            });
        }
        
        // Convert uint8[] accessories to uint64[] for compatibility
        uint64[] memory accessoryIds = new uint64[](assignment.assignedAccessories.length);
        for (uint256 i = 0; i < assignment.assignedAccessories.length; i++) {
            accessoryIds[i] = uint64(assignment.assignedAccessories[i]);
        }
        
        return TraitPackEquipment({
            traitPackCollection: assignment.augmentCollection,
            traitPackTokenId: assignment.augmentTokenId,
            accessoryIds: accessoryIds,
            tier: assignment.tier,
            variant: assignment.specimenVariant,
            assignmentTime: assignment.assignmentTime,
            unlockTime: assignment.unlockTime,
            locked: assignment.active && (assignment.unlockTime == 0 || block.timestamp < assignment.unlockTime)
        });
    }
    
    /**
     * @notice Check if specimen has active augment assignment
     * @param specimenCollection Specimen collection contract address
     * @param tokenId Token identifier
     * @return hasAugment True if specimen has active augment
     */
    function hasSpecimenAugment(address specimenCollection, uint256 tokenId) external view returns (bool) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        bytes32 assignmentKey = cs.specimenToAssignment[specimenCollection][tokenId];
        if (assignmentKey == bytes32(0)) {
            return false;
        }
        
        LibCollectionStorage.AugmentAssignment storage assignment = cs.augmentAssignments[assignmentKey];
        return assignment.active && (
            assignment.unlockTime == 0 || // Permanent lock
            block.timestamp < assignment.unlockTime // Still locked
        );
    }
    
    /**
     * @notice Get comprehensive system status information
     * @return isActive Whether the Diamond system is active
     * @return totalCollections Total number of registered collections
     * @return totalAugments Total number of registered augment collections
     * @return totalAccessories Total number of defined accessories
     */
    function getSystemStatus() external view returns (
        bool isActive,
        uint256 totalCollections,
        uint256 totalAugments,
        uint256 totalAccessories
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // System is active if not paused and has owner
        isActive = !cs.paused && cs.contractOwner != address(0);
        
        // Count active collections
        totalCollections = 0;
        for (uint256 i = 1; i <= cs.collectionCounter; i++) {
            if (cs.collections[i].enabled) {
                totalCollections++;
            }
        }
        
        // Count registered augment collections
        totalAugments = 0;
        for (uint256 i = 0; i < cs.registeredAugmentCollections.length; i++) {
            if (cs.augmentCollections[cs.registeredAugmentCollections[i]].active) {
                totalAugments++;
            }
        }
        
        // Count defined accessories
        totalAccessories = cs.accessoryIds.length;
        
        return (isActive, totalCollections, totalAugments, totalAccessories);
    }

    /**
     * @notice Get collection statistics for specific collection
     * @param collectionId Collection ID
     */
    function getCollectionStatDetails(uint256 collectionId) external view validCollection(collectionId) returns (
        uint256 currentSupply,
        uint256 maxSupply,
        uint256 lastUpdateTime,
        bool multiAssetEnabled,
        bool nestableEnabled,
        bool equippableEnabled
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
        
        return (
            collection.currentSupply,
            collection.maxSupply,
            collection.lastUpdateTime,
            collection.multiAssetEnabled,
            collection.nestableEnabled,
            collection.equippableEnabled
        );
    }
}