// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibMeta} from "../shared/libraries/LibMeta.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibCollectionStorage} from "../libraries/LibCollectionStorage.sol";
import {ModularConfigData, ModularConfigIndices, ChildToken, ParentToken} from "../libraries/ModularAssetModel.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";

// Required interface for external nesting support
interface INestableFacet {
    function proposeChild(uint256 collectionId, uint256 parentTokenId, address childContract, uint256 childTokenId) external;
    function supportsNesting() external view returns (bool);
}

/**
 * @title NestableFacet - Collection-Tier Enhanced
 * @notice Production-ready ERC-7401 Nestable functionality with collection-tier support
 * @dev Manages parent-child relationships between NFTs with proper collection-tier awareness
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 * @custom:version 4.1.0 - Added collection-tier support
 */
contract NestableFacet is AccessControlBase {
    using Strings for uint256;

    // Events for monitoring nesting operations - enhanced with collection context
    event ChildProposed(uint256 indexed collectionId, uint8 indexed tier, uint256 indexed tokenId, uint256 childIndex, address childAddress, uint256 childId);
    event ChildAccepted(uint256 indexed collectionId, uint8 indexed tier, uint256 indexed tokenId, uint256 childIndex, address childAddress, uint256 childId);
    event ChildRejected(uint256 indexed collectionId, uint8 indexed tier, uint256 indexed tokenId, uint256 childIndex, address childAddress, uint256 childId);
    event AllChildrenRejected(uint256 indexed collectionId, uint8 indexed tier, uint256 indexed tokenId);
    event ChildTransferred(uint256 indexed collectionId, uint8 indexed tier, uint256 indexed tokenId, uint256 childIndex, address childAddress, uint256 childId, bool fromPending, bool toZero);
    event NestTransfer(address indexed from, address indexed to, uint256 fromCollectionId, uint8 fromTier, uint256 fromTokenId, uint256 toCollectionId, uint8 toTier, uint256 toTokenId, uint256 indexed tokenId);
    event ParentUpdated(uint256 indexed collectionId, uint8 indexed tier, uint256 indexed tokenId, address parentContract, uint256 parentTokenId);
    event ChildStatusUpdated(uint256 indexed collectionId, uint8 indexed tier, uint256 indexed parentTokenId, address childContract, uint256 childTokenId, ChildStatus status);
    event NestingLimitUpdated(uint256 indexed collectionId, uint8 indexed tier, uint16 maxChildren);
    
    // Custom errors enhanced with collection-tier context
    error NestableNotEnabled(uint256 collectionId, uint8 tier);
    error TokenNotExists(uint256 collectionId, uint8 tier, uint256 tokenId);
    error ChildNotFound();
    error ChildAlreadyExists();
    error MaxChildrenReached(uint256 maxChildren);
    error NotAuthorizedForNesting();
    error InvalidChildContract();
    error CannotNestToSelf();
    error ChildNotPending();
    error ChildNotAccepted();
    error InvalidNestingTarget();
    error CircularNesting();
    error ChildIndexOutOfBounds();
    error InvalidChildData();
    error NestingOperationFailed();
    error ParentNotFound();
    error InvalidParentReference();
    error UnauthorizedChildOperation(address caller, uint256 collectionId, uint8 tier, uint256 tokenId);
    error InvalidTierForCollection(uint256 collectionId, uint8 tier);
    
    // Constants for system limits
    uint256 private constant MAX_CHILDREN_PER_TOKEN = 100;
    uint256 private constant MAX_NESTING_DEPTH = 10;
    
    // Child status enumeration
    enum ChildStatus {
        None,
        Pending,
        Accepted
    }
    
    // ==================== ENHANCED STORAGE ACCESS ====================
    
    /**
     * @notice Get modular config data with collection-tier support
     */
    function _getModularConfigData(uint256 collectionId, uint8 tier, uint256 tokenId) 
        internal view returns (ModularConfigData storage) {
        return LibCollectionStorage.collectionStorage().modularConfigsData[collectionId][tier][tokenId];
    }
    
    /**
     * @notice Get modular config indices with collection-tier support
     */
    function _getModularConfigIndices(uint256 collectionId, uint8 tier, uint256 tokenId)
        internal view returns (ModularConfigIndices storage) {
        return LibCollectionStorage.collectionStorage().modularConfigsIndices[collectionId][tier][tokenId];
    }
    
    /**
     * @notice Initialize modular config if needed
     */
    function _initializeModularConfig(uint256 collectionId, uint8 tier, uint256 tokenId) internal {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (cs.modularConfigsData[collectionId][tier][tokenId].lastUpdateTime == 0) {
            cs.modularConfigsData[collectionId][tier][tokenId].lastUpdateTime = block.timestamp;
            
            // Set token context for validation
            LibCollectionStorage.setTokenContext(tokenId, collectionId, tier, address(this));
        }
    }
    
    // ==================== MAIN NESTING FUNCTIONS ====================
    
    /**
     * @notice Propose child NFT to parent NFT with collection-tier support
     * @param collectionId Parent collection ID
     * @param tier Parent tier level
     * @param parentTokenId Parent token ID
     * @param childContract Child contract address
     * @param childTokenId Child token ID
     */
    function proposeChild(
        uint256 collectionId,
        uint8 tier,
        uint256 parentTokenId,
        address childContract,
        uint256 childTokenId
    ) external whenNotPaused validInternalCollection(collectionId) {
        
        // Validate collection-tier combination
        _validateCollectionTier(collectionId, tier);
        
        // Validate nesting capability and parent token
        _validateNestingOperation(collectionId, tier, parentTokenId);
        
        // Validate child ownership and contract
        _validateChildForProposal(childContract, childTokenId, parentTokenId);
        
        // Check collection-tier specific nesting constraints
        _checkNestingConstraints(collectionId, tier, parentTokenId, childContract, childTokenId);
        
        // Initialize config if needed
        _initializeModularConfig(collectionId, tier, parentTokenId);
        
        ModularConfigData storage config = _getModularConfigData(collectionId, tier, parentTokenId);
        ModularConfigIndices storage indices = _getModularConfigIndices(collectionId, tier, parentTokenId);
        
        // Create new child token
        ChildToken memory newChild = ChildToken({
            childContract: childContract,
            childTokenId: childTokenId,
            addedTime: block.timestamp,
            transferable: true,
            accepted: false
        });
        
        // Add to pending children
        config.pendingChildren.push(newChild);
        uint256 childIndex = config.pendingChildren.length - 1;
        indices.pendingChildIndices[childContract][childTokenId] = childIndex + 1;
        
        emit ChildProposed(collectionId, tier, parentTokenId, childIndex, childContract, childTokenId);
        emit ChildStatusUpdated(collectionId, tier, parentTokenId, childContract, childTokenId, ChildStatus.Pending);
    }
    
    /**
     * @notice Accept proposed child NFT
     * @param collectionId Parent collection ID
     * @param tier Parent tier level
     * @param parentTokenId Parent token ID
     * @param childIndex Index in pending children array
     * @param childContract Child contract address
     * @param childTokenId Child token ID
     */
    function acceptChild(
        uint256 collectionId,
        uint8 tier,
        uint256 parentTokenId,
        uint256 childIndex,
        address childContract,
        uint256 childTokenId
    ) external whenNotPaused validInternalCollection(collectionId) {
        
        // Validate access to parent token
        _requireTokenController(collectionId, tier, parentTokenId);
        
        ModularConfigData storage config = _getModularConfigData(collectionId, tier, parentTokenId);
        ModularConfigIndices storage indices = _getModularConfigIndices(collectionId, tier, parentTokenId);
        
        if (childIndex >= config.pendingChildren.length) {
            revert ChildNotFound();
        }
        
        ChildToken storage pendingChild = config.pendingChildren[childIndex];
        
        if (pendingChild.childContract != childContract || 
            pendingChild.childTokenId != childTokenId) {
            revert ChildNotFound();
        }
        
        // Check collection-tier specific children limit
        uint16 maxChildrenPerToken = _getMaxChildrenPerToken(collectionId);
        
        if (config.children.length >= maxChildrenPerToken) {
            revert MaxChildrenReached(maxChildrenPerToken);
        }
        
        // Remove from pending
        _removeFromPendingChildren(collectionId, tier, parentTokenId, childIndex);
        
        // Add to accepted
        ChildToken memory acceptedChild = pendingChild;
        acceptedChild.accepted = true;
        
        config.children.push(acceptedChild);
        uint256 acceptedIndex = config.children.length - 1;
        indices.childIndices[childContract][childTokenId] = acceptedIndex + 1;
        
        // Update parent reference in child if same contract
        _updateChildParentReference(childContract, childTokenId, address(this), parentTokenId);
        
        emit ChildAccepted(collectionId, tier, parentTokenId, acceptedIndex, childContract, childTokenId);
        emit ChildStatusUpdated(collectionId, tier, parentTokenId, childContract, childTokenId, ChildStatus.Accepted);
    }
    
    /**
     * @notice Reject proposed child NFT
     * @param collectionId Parent collection ID
     * @param tier Parent tier level
     * @param parentTokenId Parent token ID
     * @param childIndex Index in pending children array
     * @param childContract Child contract address
     * @param childTokenId Child token ID
     */
    function rejectChild(
        uint256 collectionId,
        uint8 tier,
        uint256 parentTokenId,
        uint256 childIndex,
        address childContract,
        uint256 childTokenId
    ) external whenNotPaused validInternalCollection(collectionId) {
        
        // Validate access to parent token
        _requireTokenController(collectionId, tier, parentTokenId);
        
        ModularConfigData storage config = _getModularConfigData(collectionId, tier, parentTokenId);
        
        if (childIndex >= config.pendingChildren.length) {
            revert ChildNotFound();
        }
        
        ChildToken storage pendingChild = config.pendingChildren[childIndex];
        
        if (pendingChild.childContract != childContract || 
            pendingChild.childTokenId != childTokenId) {
            revert ChildNotFound();
        }
        
        _removeFromPendingChildren(collectionId, tier, parentTokenId, childIndex);
        
        emit ChildRejected(collectionId, tier, parentTokenId, childIndex, childContract, childTokenId);
        emit ChildTransferred(collectionId, tier, parentTokenId, childIndex, childContract, childTokenId, true, true);
        emit ChildStatusUpdated(collectionId, tier, parentTokenId, childContract, childTokenId, ChildStatus.None);
    }
    
    /**
     * @notice Reject all pending children
     * @param collectionId Parent collection ID
     * @param tier Parent tier level
     * @param parentTokenId Parent token ID
     */
    function rejectAllChildren(
        uint256 collectionId,
        uint8 tier,
        uint256 parentTokenId
    ) external whenNotPaused validInternalCollection(collectionId) {
        
        // Validate access to parent token
        _requireTokenController(collectionId, tier, parentTokenId);
        
        ModularConfigData storage config = _getModularConfigData(collectionId, tier, parentTokenId);
        ModularConfigIndices storage indices = _getModularConfigIndices(collectionId, tier, parentTokenId);
        
        // Clear all pending children
        ChildToken[] storage pendingChildren = config.pendingChildren;
        
        // Emit events for each rejected child
        for (uint256 i = 0; i < pendingChildren.length; i++) {
            ChildToken storage child = pendingChildren[i];
            delete indices.pendingChildIndices[child.childContract][child.childTokenId];
            
            emit ChildStatusUpdated(collectionId, tier, parentTokenId, child.childContract, child.childTokenId, ChildStatus.None);
        }
        
        // Clear the array
        delete config.pendingChildren;
        
        emit AllChildrenRejected(collectionId, tier, parentTokenId);
    }
    
    /**
     * @notice Transfer child NFT out of parent
     * @param collectionId Parent collection ID
     * @param tier Parent tier level
     * @param parentTokenId Parent token ID
     * @param to Destination address
     * @param childIndex Child index in array
     * @param childContract Child contract address
     * @param childTokenId Child token ID
     * @param isPending Whether child is pending or accepted
     * @param data Additional data for transfer
     */
    function transferChild(
        uint256 collectionId,
        uint8 tier,
        uint256 parentTokenId,
        address to,
        uint256 childIndex,
        address childContract,
        uint256 childTokenId,
        bool isPending,
        bytes calldata data
    ) external whenNotPaused validInternalCollection(collectionId) {
        
        // Validate access to parent token
        _requireTokenController(collectionId, tier, parentTokenId);
        
        ModularConfigData storage config = _getModularConfigData(collectionId, tier, parentTokenId);
        
        ChildToken storage child;
        
        if (isPending) {
            if (childIndex >= config.pendingChildren.length) {
                revert ChildNotFound();
            }
            child = config.pendingChildren[childIndex];
        } else {
            if (childIndex >= config.children.length) {
                revert ChildNotFound();
            }
            child = config.children[childIndex];
            
            if (!child.transferable) {
                revert NotAuthorizedForNesting();
            }
        }
        
        if (child.childContract != childContract || 
            child.childTokenId != childTokenId) {
            revert ChildNotFound();
        }
        
        if (isPending) {
            _removeFromPendingChildren(collectionId, tier, parentTokenId, childIndex);
        } else {
            _removeFromAcceptedChildren(collectionId, tier, parentTokenId, childIndex);
            _updateChildParentReference(childContract, childTokenId, address(0), 0);
        }
        
        // Execute external transfer
        IERC721(childContract).safeTransferFrom(address(this), to, childTokenId, data);
        
        emit ChildTransferred(collectionId, tier, parentTokenId, childIndex, childContract, childTokenId, isPending, to == address(0));
        emit ChildStatusUpdated(collectionId, tier, parentTokenId, childContract, childTokenId, ChildStatus.None);
    }
    
    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @notice Get accepted children of parent token
     * @param collectionId Parent collection ID
     * @param tier Parent tier level
     * @param parentTokenId Parent token ID
     */
    function childrenOf(uint256 collectionId, uint8 tier, uint256 parentTokenId) external view returns (
        address[] memory childContracts,
        uint256[] memory childTokenIds
    ) {
        _requireTokenExists(collectionId, tier, parentTokenId);
        
        ModularConfigData storage config = _getModularConfigData(collectionId, tier, parentTokenId);
        ChildToken[] storage children = config.children;
        
        childContracts = new address[](children.length);
        childTokenIds = new uint256[](children.length);
        
        for (uint256 i = 0; i < children.length; i++) {
            childContracts[i] = children[i].childContract;
            childTokenIds[i] = children[i].childTokenId;
        }
        
        return (childContracts, childTokenIds);
    }
    
    /**
     * @notice Get pending children of parent token
     * @param collectionId Parent collection ID
     * @param tier Parent tier level
     * @param parentTokenId Parent token ID
     */
    function pendingChildrenOf(uint256 collectionId, uint8 tier, uint256 parentTokenId) external view returns (
        address[] memory childContracts,
        uint256[] memory childTokenIds
    ) {
        _requireTokenExists(collectionId, tier, parentTokenId);
        
        ModularConfigData storage config = _getModularConfigData(collectionId, tier, parentTokenId);
        ChildToken[] storage pendingChildren = config.pendingChildren;
        
        childContracts = new address[](pendingChildren.length);
        childTokenIds = new uint256[](pendingChildren.length);
        
        for (uint256 i = 0; i < pendingChildren.length; i++) {
            childContracts[i] = pendingChildren[i].childContract;
            childTokenIds[i] = pendingChildren[i].childTokenId;
        }
        
        return (childContracts, childTokenIds);
    }
    
    /**
     * @notice Get parent of token
     * @param collectionId Token collection ID
     * @param tier Token tier level
     * @param tokenId Token ID
     */
    function parentOf(uint256 collectionId, uint8 tier, uint256 tokenId) external view returns (
        address parentContract,
        uint256 parentTokenId,
        bool isPending
    ) {
        _requireTokenExists(collectionId, tier, tokenId);
        
        ModularConfigData storage config = _getModularConfigData(collectionId, tier, tokenId);
        ParentToken storage parent = config.parent;
        
        return (parent.parentContract, parent.parentTokenId, parent.isPending);
    }
    
    /**
     * @notice Check if contract supports nesting
     */
    function supportsNesting() external pure returns (bool) {
        return true;
    }
    
    /**
     * @notice Get child status
     * @param collectionId Parent collection ID
     * @param tier Parent tier level
     * @param parentTokenId Parent token ID
     * @param childContract Child contract address
     * @param childTokenId Child token ID
     */
    function getChildStatus(
        uint256 collectionId,
        uint8 tier,
        uint256 parentTokenId,
        address childContract,
        uint256 childTokenId
    ) external view returns (ChildStatus status) {
        
        ModularConfigIndices storage indices = _getModularConfigIndices(collectionId, tier, parentTokenId);
        
        if (indices.childIndices[childContract][childTokenId] != 0) {
            return ChildStatus.Accepted;
        } else if (indices.pendingChildIndices[childContract][childTokenId] != 0) {
            return ChildStatus.Pending;
        } else {
            return ChildStatus.None;
        }
    }
    
    /**
     * @notice Check if nestable is enabled for collection-tier
     * @param collectionId Collection ID
     * @param tier Tier level
     */
    function isNestableEnabled(uint256 collectionId, uint8 tier) external view returns (bool) {
        if (!LibCollectionStorage.collectionExists(collectionId)) {
            return false;
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (LibCollectionStorage.isInternalCollection(collectionId)) {
            return cs.collections[collectionId].enabled && 
                   cs.collections[collectionId].nestableEnabled &&
                   _isValidTierForCollection(collectionId, tier);
        } else {
            return cs.externalCollections[collectionId].enabled &&
                   _isValidTierForCollection(collectionId, tier);
        }
    }
    
    // ==================== INTERNAL VALIDATION FUNCTIONS ====================
    
    /**
     * @notice Validate collection and tier combination
     */
    function _validateCollectionTier(uint256 collectionId, uint8 tier) internal view {
        if (!_isValidTierForCollection(collectionId, tier)) {
            revert InvalidTierForCollection(collectionId, tier);
        }
    }
    
    /**
     * @notice Check if tier is valid for collection
     */
    function _isValidTierForCollection(uint256 collectionId, uint8 tier) internal view returns (bool) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (LibCollectionStorage.isInternalCollection(collectionId)) {
            // Check if tier exists in itemTiers mapping
            return cs.itemTiers[collectionId][tier].tier != 0;
        } else {
            // For external collections, accept tier 1-4 as valid
            return tier >= 1 && tier <= 4;
        }
    }
    
    /**
     * @notice Validate nesting operation prerequisites
     */
    function _validateNestingOperation(uint256 collectionId, uint8 tier, uint256 parentTokenId) internal view {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (LibCollectionStorage.isInternalCollection(collectionId)) {
            if (!cs.collections[collectionId].nestableEnabled) {
                revert NestableNotEnabled(collectionId, tier);
            }
        } else if (LibCollectionStorage.isExternalCollection(collectionId)) {
            if (!cs.externalCollections[collectionId].enabled) {
                revert NestableNotEnabled(collectionId, tier);
            }
        } else {
            revert CollectionNotFound(collectionId);
        }
        
        _requireTokenExists(collectionId, tier, parentTokenId);
    }
    
    /**
     * @notice Get max children per token for collection
     */
    function _getMaxChildrenPerToken(uint256 collectionId) internal view returns (uint16) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (LibCollectionStorage.isInternalCollection(collectionId)) {
            uint16 maxChildren = cs.collections[collectionId].maxChildrenPerToken;
            return maxChildren > 0 ? maxChildren : uint16(MAX_CHILDREN_PER_TOKEN);
        } else {
            return uint16(MAX_CHILDREN_PER_TOKEN);
        }
    }
    
    /**
     * @notice Validate child for proposal
     */
    function _validateChildForProposal(
        address childContract,
        uint256 childTokenId,
        uint256 parentTokenId
    ) internal view {
        
        if (childContract == address(0)) {
            revert InvalidChildContract();
        }
        
        // Check child ownership
        IERC721 childNFT = IERC721(childContract);
        address childOwner = childNFT.ownerOf(childTokenId);
        address caller = LibMeta.msgSender();
        
        // Check if caller has access to child token
        bool hasAccess = false;
        
        // Direct ownership
        if (childOwner == caller) {
            hasAccess = true;
        } else {
            // Check approvals
            try childNFT.isApprovedForAll(childOwner, caller) returns (bool approved) {
                if (approved) hasAccess = true;
            } catch {}
            
            if (!hasAccess) {
                try childNFT.getApproved(childTokenId) returns (address approved) {
                    if (approved == caller) hasAccess = true;
                } catch {}
            }
        }
        
        if (!hasAccess) {
            revert NotAuthorizedForNesting();
        }
        
        // Prevent self-nesting
        if (childContract == address(this) && childTokenId == parentTokenId) {
            revert CannotNestToSelf();
        }
    }
    
    /**
     * @notice Check nesting constraints and limits
     */
    function _checkNestingConstraints(
        uint256 collectionId,
        uint8 tier,
        uint256 parentTokenId,
        address childContract,
        uint256 childTokenId
    ) internal view {
        
        ModularConfigData storage config = _getModularConfigData(collectionId, tier, parentTokenId);
        ModularConfigIndices storage indices = _getModularConfigIndices(collectionId, tier, parentTokenId);
        
        // Check if child already exists
        if (indices.childIndices[childContract][childTokenId] != 0 || 
            indices.pendingChildIndices[childContract][childTokenId] != 0) {
            revert ChildAlreadyExists();
        }
        
        // Check children limit
        uint16 maxChildrenPerToken = _getMaxChildrenPerToken(collectionId);
        uint256 totalChildren = config.children.length + config.pendingChildren.length;
        
        if (totalChildren >= maxChildrenPerToken) {
            revert MaxChildrenReached(maxChildrenPerToken);
        }
        
        // Check circular nesting
        _checkCircularNesting(parentTokenId, childContract, childTokenId);
    }
    
    // ==================== INTERNAL HELPER FUNCTIONS ====================
    
    /**
     * @notice Remove child from pending children array with proper indexing
     */
    function _removeFromPendingChildren(uint256 collectionId, uint8 tier, uint256 parentTokenId, uint256 childIndex) internal {
        ModularConfigData storage config = _getModularConfigData(collectionId, tier, parentTokenId);
        ModularConfigIndices storage indices = _getModularConfigIndices(collectionId, tier, parentTokenId);
        
        uint256 lastIndex = config.pendingChildren.length - 1;
        ChildToken storage childToRemove = config.pendingChildren[childIndex];
        
        // Clear index mapping
        delete indices.pendingChildIndices[childToRemove.childContract][childToRemove.childTokenId];
        
        // Move last element to removed position
        if (childIndex < lastIndex) {
            ChildToken storage lastChild = config.pendingChildren[lastIndex];
            config.pendingChildren[childIndex] = lastChild;
            indices.pendingChildIndices[lastChild.childContract][lastChild.childTokenId] = childIndex + 1;
        }
        
        // Remove last element
        config.pendingChildren.pop();
    }
    
    /**
     * @notice Remove child from accepted children array with proper indexing
     */
    function _removeFromAcceptedChildren(uint256 collectionId, uint8 tier, uint256 parentTokenId, uint256 childIndex) internal {
        ModularConfigData storage config = _getModularConfigData(collectionId, tier, parentTokenId);
        ModularConfigIndices storage indices = _getModularConfigIndices(collectionId, tier, parentTokenId);
        
        uint256 lastIndex = config.children.length - 1;
        ChildToken storage childToRemove = config.children[childIndex];
        
        // Clear index mapping
        delete indices.childIndices[childToRemove.childContract][childToRemove.childTokenId];
        
        // Move last element to removed position
        if (childIndex < lastIndex) {
            ChildToken storage lastChild = config.children[lastIndex];
            config.children[childIndex] = lastChild;
            indices.childIndices[lastChild.childContract][lastChild.childTokenId] = childIndex + 1;
        }
        
        // Remove last element
        config.children.pop();
    }
    
    /**
     * @notice Check for circular nesting dependencies
     */
    function _checkCircularNesting(
        uint256 parentTokenId,
        address childContract,
        uint256 childTokenId
    ) internal view {
        if (childContract == address(this) && childTokenId == parentTokenId) {
            revert CircularNesting();
        }
        
        // Additional depth check if same contract
        if (childContract == address(this)) {
            uint256 depth = _calculateNestingDepth(childTokenId);
            if (depth >= MAX_NESTING_DEPTH) {
                revert CircularNesting();
            }
        }
    }
    
    /**
     * @notice Calculate nesting depth for token - simplified for base version
     */
    function _calculateNestingDepth(uint256 tokenId) internal view returns (uint256) {
        // Simplified implementation - in collection-tier version this would need enhancement
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint256 depth = 0;
        address currentContract = address(this);
        uint256 currentTokenId = tokenId;
        
        // Basic traversal - assumes default collection/tier for simplicity
        for (uint256 i = 0; i < MAX_NESTING_DEPTH; i++) {
            if (currentContract != address(this)) {
                break;
            }
            
            // Try to find parent in any collection/tier combination
            bool foundParent = false;
            for (uint256 collectionId = 1; collectionId <= 10 && !foundParent; collectionId++) {
                for (uint8 tier = 1; tier <= 4 && !foundParent; tier++) {
                    if (cs.modularConfigsData[collectionId][tier][currentTokenId].lastUpdateTime != 0) {
                        ParentToken storage parent = cs.modularConfigsData[collectionId][tier][currentTokenId].parent;
                        
                        if (parent.parentContract != address(0)) {
                            depth++;
                            currentContract = parent.parentContract;
                            currentTokenId = parent.parentTokenId;
                            foundParent = true;
                            
                            if (currentContract == address(this) && currentTokenId == tokenId) {
                                revert CircularNesting();
                            }
                        }
                    }
                }
            }
            
            if (!foundParent) break;
        }
        
        return depth;
    }
    
    /**
     * @notice Update child parent reference for internal tokens
     */
    function _updateChildParentReference(
        address childContract,
        uint256 childTokenId,
        address parentContract,
        uint256 parentTokenId
    ) internal {
        if (childContract == address(this)) {
            // Find child in any collection/tier and update parent reference
            LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
            
            // Try to find child token in storage
            for (uint256 collectionId = 1; collectionId <= 10; collectionId++) {
                for (uint8 tier = 1; tier <= 4; tier++) {
                    if (cs.modularConfigsData[collectionId][tier][childTokenId].lastUpdateTime != 0) {
                        ModularConfigData storage childConfig = cs.modularConfigsData[collectionId][tier][childTokenId];
                        
                        childConfig.parent = ParentToken({
                            parentContract: parentContract,
                            parentTokenId: parentTokenId,
                            isPending: false
                        });
                        
                        emit ParentUpdated(collectionId, tier, childTokenId, parentContract, parentTokenId);
                        return;
                    }
                }
            }
        }
    }
    
    /**
     * @notice Check if contract supports nesting interface
     */
    function _supportsNesting(address contractAddress) internal view returns (bool) {
        try INestableFacet(contractAddress).supportsNesting() returns (bool result) {
            return result;
        } catch {
            return false;
        }
    }
    
    /**
     * @notice Require token exists in the collection-tier system
     */
    function _requireTokenExists(uint256 collectionId, uint8 tier, uint256 tokenId) internal view {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Check if modular config exists for this collection-tier-token combination
        if (cs.modularConfigsData[collectionId][tier][tokenId].lastUpdateTime == 0) {
            revert TokenNotExists(collectionId, tier, tokenId);
        }
    }
    
    /**
     * @notice Simple token controller validation using existing AccessHelper
     */
    function _requireTokenController(uint256 collectionId, uint8 tier, uint256 tokenId) internal view {
        // First ensure token exists
        _requireTokenExists(collectionId, tier, tokenId);
        
        // Get collection contract address for validation
        (address contractAddress,,) = LibCollectionStorage.getCollectionInfo(collectionId);
        
        if (contractAddress != address(0)) {
            // Use standard AccessHelper validation
            AccessHelper.requireTokenAccess(contractAddress, tokenId);
        } else {
            revert TokenNotExists(collectionId, tier, tokenId);
        }
    }
}