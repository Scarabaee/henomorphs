// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibCollectionStorage} from "../libraries/LibCollectionStorage.sol";
import {ModularConfigData, ModularConfigIndices, EquippablePart, PartType, Equipment, ChildToken} from "../libraries/ModularAssetModel.sol";
import {AccessControlBase} from "./AccessControlBase.sol";

/**
 * @title EquippableFacet
 * @notice PRODUCTION-READY: ERC-6220 Equippable functionality with full collection-tier architecture support
 * @dev Manages equipment slots, child token equipping, and compatibility validation with collection-tier context
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 * @custom:version 4.1.0 - Full collection-tier integration for production deployment
 */
contract EquippableFacet is AccessControlBase {
    using Strings for uint256;
    using Strings for uint64;
    
    // Events for monitoring equipment operations with collection-tier context
    event ChildAssetEquipped(uint256 indexed collectionId, uint8 indexed tier, uint256 indexed tokenId, uint64 assetId, uint64 slotPartId, address childContract, uint256 childTokenId);
    event ChildAssetUnequipped(uint256 indexed collectionId, uint8 indexed tier, uint256 indexed tokenId, uint64 assetId, uint64 slotPartId, address childContract, uint256 childTokenId);
    event ValidParentEquippableGroupIdSet(uint256 indexed equippableGroupId, uint64 indexed slotPartId, address parentAddress);
    event EquipmentSlotDefined(uint64 indexed slotPartId, string name, PartType partType);
    event EquippablePartAdded(uint64 indexed partId, uint256 indexed equippableGroupId);
    event EquipmentLimitUpdated(uint256 indexed collectionId, uint16 maxSlots);
    event EquipmentCompatibilityUpdated(uint64 indexed slotPartId, address[] equippableAddresses);
    event EquipmentStatusChanged(uint256 indexed collectionId, uint8 indexed tier, uint256 indexed tokenId, uint64 slotPartId, bool equipped);
    
    // Custom errors for better debugging
    error EquippableNotEnabled(uint256 collectionId);
    error TokenNotExists(uint256 tokenId);
    error TokenNotInCollectionTier(uint256 tokenId, uint256 collectionId, uint8 tier);
    error SlotNotFound(uint64 slotPartId);
    error PartNotFound(uint64 partId);
    error ChildNotFound();
    error AssetNotFound(uint64 assetId);
    error SlotAlreadyOccupied(uint64 slotPartId);
    error SlotNotOccupied(uint64 slotPartId);
    error IncompatibleEquippable(address childContract, uint64 slotPartId);
    error MaxSlotsReached(uint256 maxSlots);
    error InvalidEquippableData();
    error EquipmentIndexOutOfBounds();
    error NotAuthorizedForEquipment();
    error InvalidChildAsset();
    error EquipmentOperationFailed();
    error UnauthorizedEquipmentOperation(address caller, uint256 tokenId);
    error InvalidCollectionTierContext();
    
    // Constants for system limits
    uint256 private constant MAX_EQUIPMENT_SLOTS = 50;
    uint256 private constant MAX_EQUIPPABLE_ADDRESSES = 100;
    
    /**
     * @notice Equip child token to parent token slot with full collection-tier context
     * @param collectionId Collection identifier
     * @param tier Tier level within collection
     * @param tokenId Token identifier within collection-tier
     * @param assetId Parent asset ID
     * @param slotPartId Slot part identifier
     * @param childIndex Index of child in children array
     * @param childAssetId Child asset ID to equip
     */
    function equip(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        uint64 assetId,
        uint64 slotPartId,
        uint256 childIndex,
        uint64 childAssetId
    ) external whenNotPaused validCollection(collectionId) {
        
        // Validate collection has equippable capability
        _validateEquippableCollection(collectionId);
        
        // Validate token exists in collection-tier context
        _validateTokenInCollectionTier(collectionId, tier, tokenId);
        
        // Validate caller authorization for this specific token
        _validateTokenController(collectionId, tokenId);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // FIXED: Use collection-tier pattern for modular configs
        ModularConfigData storage config = cs.modularConfigsData[collectionId][tier][tokenId];
        ModularConfigIndices storage indices = cs.modularConfigsIndices[collectionId][tier][tokenId];
        
        // Initialize config if this is first equipment operation for this token
        if (config.lastUpdateTime == 0) {
            config.lastUpdateTime = block.timestamp;
        }
        
        // Validate asset exists and is accepted
        bool assetFound = false;
        for (uint256 i = 0; i < config.acceptedAssets.length; i++) {
            if (config.acceptedAssets[i] == assetId) {
                assetFound = true;
                break;
            }
        }
        if (!assetFound) {
            revert AssetNotFound(assetId);
        }
        
        // Validate child exists
        if (childIndex >= config.children.length) {
            revert ChildNotFound();
        }
        
        ChildToken storage child = config.children[childIndex];
        
        // Validate slot part
        if (!cs.partExists[slotPartId]) {
            revert SlotNotFound(slotPartId);
        }
        
        EquippablePart storage slotPart = cs.parts[slotPartId];
        if (slotPart.partType != PartType.Slot) {
            revert InvalidEquippableData();
        }
        
        // Check compatibility
        bool contractAuthorized = false;
        for (uint256 i = 0; i < slotPart.equippableAddresses.length; i++) {
            if (slotPart.equippableAddresses[i] == child.childContract) {
                contractAuthorized = true;
                break;
            }
        }
        if (!contractAuthorized) {
            revert IncompatibleEquippable(child.childContract, slotPartId);
        }
        
        // Check if slot is occupied
        if (indices.slotEquipIndices[slotPartId] != 0) {
            revert SlotAlreadyOccupied(slotPartId);
        }
        
        // Check equipment limit using collection-specific configuration
        uint16 maxEquipmentSlots = _getMaxEquipmentSlots(collectionId);
        
        if (config.equipments.length >= maxEquipmentSlots) {
            revert MaxSlotsReached(maxEquipmentSlots);
        }
        
        // Create equipment
        Equipment memory newEquipment = Equipment({
            slotPartId: slotPartId,
            childContract: child.childContract,
            childTokenId: child.childTokenId,
            assetId: childAssetId,
            equippedTime: block.timestamp,
            isPending: false,
            compatibilityScore: 100, // Default high compatibility
            calibrationEffect: 0 // No effect by default
        });
        
        // Add equipment
        config.equipments.push(newEquipment);
        uint256 equipmentIndex = config.equipments.length - 1;
        
        // Update indices
        indices.slotEquipIndices[slotPartId] = equipmentIndex + 1;
        
        // Update last modification time
        config.lastUpdateTime = block.timestamp;
        
        emit ChildAssetEquipped(collectionId, tier, tokenId, assetId, slotPartId, child.childContract, child.childTokenId);
        emit EquipmentStatusChanged(collectionId, tier, tokenId, slotPartId, true);
    }
    
    /**
     * @notice Unequip child token from parent token slot with collection-tier context
     * @param collectionId Collection identifier
     * @param tier Tier level within collection
     * @param tokenId Token identifier within collection-tier
     * @param assetId Parent asset ID
     * @param slotPartId Slot part identifier
     * @param childIndex Index of child in children array
     * @param childAssetId Child asset ID to unequip
     */
    function unequip(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        uint64 assetId,
        uint64 slotPartId,
        uint256 childIndex,
        uint64 childAssetId
    ) external whenNotPaused validCollection(collectionId) {
        
        // Validate token exists in collection-tier context
        _validateTokenInCollectionTier(collectionId, tier, tokenId);
        
        // Validate caller authorization
        _validateTokenController(collectionId, tokenId);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // FIXED: Use collection-tier pattern for modular configs
        ModularConfigData storage config = cs.modularConfigsData[collectionId][tier][tokenId];
        ModularConfigIndices storage indices = cs.modularConfigsIndices[collectionId][tier][tokenId];
        
        // Check if slot is occupied
        uint256 equipmentIndex = indices.slotEquipIndices[slotPartId];
        if (equipmentIndex == 0) {
            revert SlotNotOccupied(slotPartId);
        }
        
        equipmentIndex -= 1; // Convert to 0-based index
        
        if (equipmentIndex >= config.equipments.length) {
            revert EquipmentIndexOutOfBounds();
        }
        
        Equipment storage equipment = config.equipments[equipmentIndex];
        
        // Validate equipment matches parameters
        if (equipment.slotPartId != slotPartId || equipment.assetId != childAssetId) {
            revert InvalidEquippableData();
        }
        
        // Validate child index
        if (childIndex >= config.children.length) {
            revert ChildNotFound();
        }
        
        ChildToken storage child = config.children[childIndex];
        if (equipment.childContract != child.childContract || 
            equipment.childTokenId != child.childTokenId) {
            revert ChildNotFound();
        }
        
        // Remove equipment
        _removeEquipment(collectionId, tier, tokenId, equipmentIndex);
        
        // Update last modification time
        config.lastUpdateTime = block.timestamp;
        
        emit ChildAssetUnequipped(collectionId, tier, tokenId, assetId, slotPartId, child.childContract, child.childTokenId);
        emit EquipmentStatusChanged(collectionId, tier, tokenId, slotPartId, false);
    }
    
    /**
     * @notice Set valid parent addresses for equippable group
     * @param equippableGroupId Group identifier for equippable compatibility
     * @param slotPartId Slot part identifier
     * @param parentAddress Parent contract address
     */
    function setValidParentForEquippableGroup(
        uint256 equippableGroupId,
        uint64 slotPartId,
        address parentAddress
    ) external onlyAuthorized whenNotPaused {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!cs.partExists[slotPartId]) {
            revert SlotNotFound(slotPartId);
        }
        
        if (parentAddress == address(0)) {
            revert InvalidEquippableData();
        }
        
        cs.validParentSlots[equippableGroupId][slotPartId] = parentAddress;
        
        emit ValidParentEquippableGroupIdSet(equippableGroupId, slotPartId, parentAddress);
    }
    
    /**
     * @notice Update equippable addresses for slot part
     * @param slotPartId Slot part identifier
     * @param equippableAddresses Array of contract addresses that can equip to this slot
     */
    function updateEquippableAddresses(
        uint64 slotPartId,
        address[] calldata equippableAddresses
    ) external onlyAuthorized whenNotPaused {
        
        if (equippableAddresses.length > MAX_EQUIPPABLE_ADDRESSES) {
            revert InvalidEquippableData();
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!cs.partExists[slotPartId]) {
            revert SlotNotFound(slotPartId);
        }
        
        EquippablePart storage part = cs.parts[slotPartId];
        
        if (part.partType != PartType.Slot) {
            revert InvalidEquippableData();
        }
        
        // Clear existing addresses
        delete part.equippableAddresses;
        
        // Add new addresses
        for (uint256 i = 0; i < equippableAddresses.length; i++) {
            if (equippableAddresses[i] == address(0)) {
                revert InvalidEquippableData();
            }
            part.equippableAddresses.push(equippableAddresses[i]);
        }
        
        emit EquipmentCompatibilityUpdated(slotPartId, equippableAddresses);
    }

    /**
     * @notice Batch equip multiple child tokens with collection-tier context
     * @param collectionId Collection identifier
     * @param tier Tier level
     * @param tokenId Token identifier
     * @param equipmentData Array of equipment data structs
     */
    function batchEquip(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        EquipmentData[] calldata equipmentData
    ) external whenNotPaused validCollection(collectionId) {
        
        if (equipmentData.length == 0 || equipmentData.length > 10) {
            revert InvalidEquippableData();
        }
        
        for (uint256 i = 0; i < equipmentData.length; i++) {
            EquipmentData calldata data = equipmentData[i];
            this.equip(
                collectionId,
                tier,
                tokenId,
                data.assetId,
                data.slotPartId,
                data.childIndex,
                data.childAssetId
            );
        }
    }

    /**
     * @notice Batch unequip multiple child tokens with collection-tier context
     * @param collectionId Collection identifier
     * @param tier Tier level
     * @param tokenId Token identifier
     * @param unequipmentData Array of unequipment data structs
     */
    function batchUnequip(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        EquipmentData[] calldata unequipmentData
    ) external whenNotPaused validCollection(collectionId) {
        
        if (unequipmentData.length == 0 || unequipmentData.length > 10) {
            revert InvalidEquippableData();
        }
        
        for (uint256 i = 0; i < unequipmentData.length; i++) {
            EquipmentData calldata data = unequipmentData[i];
            this.unequip(
                collectionId,
                tier,
                tokenId,
                data.assetId,
                data.slotPartId,
                data.childIndex,
                data.childAssetId
            );
        }
    }

    // ==================== STRUCTS ====================

    struct EquipmentData {
        uint64 assetId;
        uint64 slotPartId;
        uint256 childIndex;
        uint64 childAssetId;
    }
    
    // ==================== VIEW FUNCTIONS (COLLECTION-TIER AWARE) ====================
    
    /**
     * @notice Get equipment information for specific slot with collection-tier context
     * @param collectionId Collection identifier
     * @param tier Tier level
     * @param tokenId Token identifier
     * @param slotPartId Slot part identifier
     */
    function getEquipment(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        uint64 slotPartId
    ) external view validCollection(collectionId) returns (
        address childContract,
        uint256 childTokenId,
        uint64 childAssetId,
        uint256 equippedTime,
        bool occupied
    ) {
        // Validate token exists in collection-tier context
        _validateTokenInCollectionTier(collectionId, tier, tokenId);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // FIXED: Use collection-tier pattern
        ModularConfigIndices storage indices = cs.modularConfigsIndices[collectionId][tier][tokenId];
        
        uint256 equipmentIndex = indices.slotEquipIndices[slotPartId];
        if (equipmentIndex == 0) {
            return (address(0), 0, 0, 0, false);
        }
        
        equipmentIndex -= 1; // Convert to 0-based index
        Equipment storage equipment = cs.modularConfigsData[collectionId][tier][tokenId].equipments[equipmentIndex];
        
        return (
            equipment.childContract,
            equipment.childTokenId,
            equipment.assetId,
            equipment.equippedTime,
            true
        );
    }
    
    /**
     * @notice Get all equipments for a token with collection-tier context
     * @param collectionId Collection identifier
     * @param tier Tier level
     * @param tokenId Token identifier
     */
    function getEquipments(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId
    ) external view validCollection(collectionId) returns (Equipment[] memory equipments) {
        // Validate token exists in collection-tier context
        _validateTokenInCollectionTier(collectionId, tier, tokenId);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        return cs.modularConfigsData[collectionId][tier][tokenId].equipments;
    }

    /**
     * @notice Get equipment summary for token
     * @param collectionId Collection identifier
     * @param tier Tier level
     * @param tokenId Token identifier
     */
    function getEquipmentSummary(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId
    ) external view validCollection(collectionId) returns (
        uint256 totalEquipped,
        uint256 maxSlots,
        uint64[] memory occupiedSlots,
        uint256[] memory equipmentTimes
    ) {
        // Validate token exists in collection-tier context
        _validateTokenInCollectionTier(collectionId, tier, tokenId);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        Equipment[] memory equipments = cs.modularConfigsData[collectionId][tier][tokenId].equipments;
        
        totalEquipped = equipments.length;
        maxSlots = _getMaxEquipmentSlots(collectionId);
        
        occupiedSlots = new uint64[](totalEquipped);
        equipmentTimes = new uint256[](totalEquipped);
        
        for (uint256 i = 0; i < totalEquipped; i++) {
            occupiedSlots[i] = equipments[i].slotPartId;
            equipmentTimes[i] = equipments[i].equippedTime;
        }
        
        return (totalEquipped, maxSlots, occupiedSlots, equipmentTimes);
    }
    
    /**
     * @notice Get all part IDs
     */
    function getAllParts() external view returns (uint64[] memory) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        return cs.partIds;
    }
    
    /**
     * @notice Check if address can equip to slot
     * @param slotPartId Slot part identifier
     * @param targetAddress Contract address to check
     */
    function canEquipToSlot(uint64 slotPartId, address targetAddress) external view returns (bool canEquip) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!cs.partExists[slotPartId]) {
            return false;
        }
        
        EquippablePart storage part = cs.parts[slotPartId];
        
        // Check if address is in equippable list
        for (uint256 i = 0; i < part.equippableAddresses.length; i++) {
            if (part.equippableAddresses[i] == targetAddress) {
                return true;
            }
        }
        
        return false;
    }
    
    /**
     * @notice Get valid parent for equippable group
     * @param equippableGroupId Group identifier
     * @param slotPartId Slot part identifier
     */
    function getValidParentForEquippableGroup(
        uint256 equippableGroupId,
        uint64 slotPartId
    ) external view returns (address parentAddress) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        return cs.validParentSlots[equippableGroupId][slotPartId];
    }
    
    /**
     * @notice Check if equippable is enabled for collection
     * @param collectionId Collection identifier
     */
    function isEquippableEnabled(uint256 collectionId) external view returns (bool) {
        if (!LibCollectionStorage.collectionExists(collectionId)) {
            return false;
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (LibCollectionStorage.isInternalCollection(collectionId)) {
            return cs.collections[collectionId].enabled && cs.collections[collectionId].equippableEnabled;
        } else {
            // For external collections, check if they're enabled
            return cs.externalCollections[collectionId].enabled;
        }
    }
    
    /**
     * @notice Get equipment slots count for token with collection-tier context
     * @param collectionId Collection identifier
     * @param tier Tier level
     * @param tokenId Token identifier
     */
    function getEquipmentSlotsCount(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId
    ) external view validCollection(collectionId) returns (uint256) {
        // Validate token exists in collection-tier context
        _validateTokenInCollectionTier(collectionId, tier, tokenId);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        return cs.modularConfigsData[collectionId][tier][tokenId].equipments.length;
    }
    
    // ==================== INTERNAL FUNCTIONS ====================
    
    /**
     * @notice Validate collection has equippable capability enabled
     * @param collectionId Collection identifier
     */
    function _validateEquippableCollection(uint256 collectionId) internal view {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (LibCollectionStorage.isInternalCollection(collectionId)) {
            if (!cs.collections[collectionId].equippableEnabled) {
                revert EquippableNotEnabled(collectionId);
            }
        } else if (LibCollectionStorage.isExternalCollection(collectionId)) {
            if (!cs.externalCollections[collectionId].enabled) {
                revert EquippableNotEnabled(collectionId);
            }
        } else {
            revert CollectionNotFound(collectionId);
        }
    }
    
    /**
     * @notice Validate token exists in specific collection-tier context
     * @dev PRODUCTION-CRITICAL: Ensures equipment operations are performed in correct collection-tier context
     * @param collectionId Collection identifier
     * @param tier Tier level
     * @param tokenId Token identifier
     */
    function _validateTokenInCollectionTier(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId
    ) internal view {
        // Check if token has existing context in this collection-tier
        LibCollectionStorage.TokenContext memory context = LibCollectionStorage.getTokenContext(collectionId, tokenId);
        if (context.exists) {
            if (context.collectionId == collectionId && context.tier == tier) {
                return; // Valid context match
            } else {
                revert TokenNotInCollectionTier(tokenId, collectionId, tier);
            }
        }
        
        // If no context exists, validate token exists in collection
        (address contractAddress, , bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (!exists) {
            revert InvalidCollectionTierContext();
        }
        
        // Validate token exists by checking ownership
        try IERC721(contractAddress).ownerOf(tokenId) returns (address) {
            // Token exists, context will be set when first equipment is added
            return;
        } catch {
            revert TokenNotExists(tokenId);
        }
    }

    /**
     * @notice Validate caller has permission to control token
     * @param collectionId Collection identifier  
     * @param tokenId Token identifier
     */
    function _validateTokenController(uint256 collectionId, uint256 tokenId) internal view {
        (address contractAddress, , bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (!exists) {
            revert InvalidCollectionTierContext();
        }
        
        // Check if caller owns the token or is approved
        try IERC721(contractAddress).ownerOf(tokenId) returns (address owner) {
            if (msg.sender == owner) {
                return; // Owner can always control
            }
            
            // Check if caller is approved for this token
            try IERC721(contractAddress).getApproved(tokenId) returns (address approved) {
                if (msg.sender == approved) {
                    return; // Approved for this specific token
                }
            } catch {}
            
            // Check if caller is approved for all tokens of this owner
            try IERC721(contractAddress).isApprovedForAll(owner, msg.sender) returns (bool approvedForAll) {
                if (approvedForAll) {
                    return; // Approved for all tokens
                }
            } catch {}
            
            revert UnauthorizedEquipmentOperation(msg.sender, tokenId);
        } catch {
            revert TokenNotExists(tokenId);
        }
    }

    /**
     * @notice Get maximum equipment slots for collection
     * @param collectionId Collection identifier
     */
    function _getMaxEquipmentSlots(uint256 collectionId) internal view returns (uint16) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (LibCollectionStorage.isInternalCollection(collectionId)) {
            return cs.collections[collectionId].maxEquipmentSlots;
        } else {
            // For external collections, use default limit
            return uint16(MAX_EQUIPMENT_SLOTS);
        }
    }
    
    /**
     * @notice Remove equipment from storage with proper array management
     * @param collectionId Collection identifier
     * @param tier Tier level
     * @param tokenId Token identifier
     * @param equipmentIndex Index of equipment to remove
     */
    function _removeEquipment(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        uint256 equipmentIndex
    ) internal {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // FIXED: Use collection-tier pattern
        ModularConfigData storage config = cs.modularConfigsData[collectionId][tier][tokenId];
        ModularConfigIndices storage indices = cs.modularConfigsIndices[collectionId][tier][tokenId];
        
        uint256 lastIndex = config.equipments.length - 1;
        Equipment storage equipmentToRemove = config.equipments[equipmentIndex];
        
        // Clear slot index
        delete indices.slotEquipIndices[equipmentToRemove.slotPartId];
        
        // Move last equipment to removed position
        if (equipmentIndex < lastIndex) {
            Equipment storage lastEquipment = config.equipments[lastIndex];
            config.equipments[equipmentIndex] = lastEquipment;
            indices.slotEquipIndices[lastEquipment.slotPartId] = equipmentIndex + 1;
        }
        
        // Remove last element
        config.equipments.pop();
    }
}