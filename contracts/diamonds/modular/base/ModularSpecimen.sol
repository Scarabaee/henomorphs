// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {TraitPackEquipment} from "../libraries/CollectionModel.sol";
import {ICollectionDiamond} from "../interfaces/ICollectionDiamond.sol";
import {ISpecimenCollection} from "../interfaces/IExternalSystems.sol";

/**
 * @title ModularSpecimen
 * @notice Abstract base contract for NFT collections with Diamond integration
 * @dev Provides Diamond communication without NFT logic implementation
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
abstract contract ModularSpecimen is Initializable {
    
    // Diamond integration
    ICollectionDiamond public diamond;
    uint256 public collectionId;
    
    // Collection configuration
    uint8 public defaultTier;
    uint256 public defaultIssue;
    
    // Events
    event DiamondUpdated(address indexed oldDiamond, address indexed newDiamond);
    event CollectionIdUpdated(uint256 indexed oldId, uint256 indexed newId);
    
    // Errors
    error DiamondNotSet();
    error InvalidAddress();
    error InvalidCollectionId();
    error TokenNotExists();
    error Unauthorized();
    
    modifier diamondRequired() {
        if (address(diamond) == address(0)) revert DiamondNotSet();
        _;
    }
    
    /**
     * @notice Initialize Diamond integration
     * @param diamondAddress Diamond contract address
     * @param newCollectionId Collection ID in Diamond
     * @param issue Default issue ID for this collection
     * @param tier Default tier for this collection
     */
    function __ModularSpecimen_init(
        address diamondAddress,
        uint256 newCollectionId,
        uint256 issue,
        uint8 tier
    ) internal onlyInitializing {
        _setDiamond(diamondAddress);
        _setCollectionId(newCollectionId);
        defaultIssue = issue;
        defaultTier = tier;
    }
    
    /**
     * @notice Set Diamond contract address
     * @param diamondAddress New Diamond address
     */
    function setDiamond(address diamondAddress) external virtual {
        _checkDiamondPermission();
        _setDiamond(diamondAddress);
    }
    
    /**
     * @notice Set collection ID in Diamond system
     * @param newCollectionId New collection ID
     */
    function setCollectionId(uint256 newCollectionId) external virtual {
        _checkDiamondPermission();
        _setCollectionId(newCollectionId);
    }
    
    /**
     * @notice Get token variant from Diamond
     * @param tokenId Token ID
     * @return Token variant number
     */
    function itemVariant(uint256 tokenId) external view virtual diamondRequired returns (uint8) {
        _requireTokenExists(tokenId);
        return diamond.getTokenVariant(collectionId, tokenId); // Return unconditionally - variant 0 is valid
    }
    
    /**
     * @notice Get token equipment data from Diamond
     * @param tokenId Token ID
     * @return Equipment data structure
     */
    function getTokenEquipment(uint256 tokenId) public view virtual diamondRequired returns (TraitPackEquipment memory) {
        _requireTokenExists(tokenId);
        return diamond.getSpecimenEquipment(address(this), tokenId);
    }
    
    /**
     * @notice Check if token has augment from Diamond
     * @param tokenId Token ID
     * @return Whether token has active augment
     */
    function hasAugment(uint256 tokenId) public view virtual diamondRequired returns (bool) {
        _requireTokenExists(tokenId);
        return diamond.hasSpecimenAugment(address(this), tokenId);
    }
    
    /**
     * @notice Legacy equipment method for backward compatibility
     * @param tokenId Token ID
     * @return Empty array (deprecated)
     */
    function itemEquipments(uint256 tokenId) external view virtual returns (uint8[] memory) {
        _requireTokenExists(tokenId);
        return new uint8[](0);
    }
    
    /**
     * @notice Generate token URI using Diamond
     * @param tokenId Token ID
     * @return Token metadata URI
     */
    function _generateTokenURI(uint256 tokenId) internal view diamondRequired returns (string memory) {
        _requireTokenExists(tokenId);
        return diamond.generateTokenURI(collectionId, tokenId);
    }
    
    /**
     * @notice Notify Diamond about token mint
     * @param tokenId Token ID
     * @param owner Token owner
     */
    function _notifyTokenMinted(uint256 tokenId, address owner) internal {
        if (address(diamond) != address(0) && collectionId != 0) {
            try diamond.onTokenMinted(collectionId, tokenId, owner) {
                // Success - notification sent
            } catch {
                // Ignore errors to prevent mint failures
            }
        }
    }
    
    /**
     * @notice Notify Diamond about variant assignment
     * @param tokenId Token ID
     * @param variant Assigned variant
     */
    function _notifyVariantAssigned(uint256 tokenId, uint8 variant) internal {
        if (address(diamond) != address(0) && collectionId != 0) {
            try diamond.onVariantAssigned(collectionId, tokenId, variant) {
                // Success - notification sent
            } catch {
                // Ignore errors to prevent operation failures
            }
        }
    }
    
    /**
     * @notice Notify Diamond about token transfer
     * @param tokenId Token ID
     * @param from Previous owner
     * @param to New owner
     */
    function _notifyTokenTransferred(uint256 tokenId, address from, address to) internal {
        if (address(diamond) != address(0) && collectionId != 0) {
            try diamond.onTokenTransferred(collectionId, tokenId, from, to) {
                // Success - notification sent
            } catch {
                // Ignore errors to prevent transfer failures
            }
        }
    }
    
    /**
     * @notice Notify Diamond about augment change
     * @param tokenId Token ID
     * @param oldAugment Previous augment
     * @param newAugment New augment
     */
    function _notifyAugmentChanged(uint256 tokenId, uint8 oldAugment, uint8 newAugment) internal {
        if (address(diamond) != address(0) && collectionId != 0) {
            try diamond.onAugmentChanged(collectionId, tokenId, oldAugment, newAugment) {
                // Success - notification sent
            } catch {
                // Ignore errors to prevent operation failures
            }
        }
    }
    
    /**
     * @notice Check if token exists (must be implemented by derived contract)
     * @param tokenId Token ID to check
     * @return Whether token exists
     */
    function _tokenExists(uint256 tokenId) internal view virtual returns (bool);
    
    /**
     * @notice Check Diamond management permission (must be implemented by derived contract)
     */
    function _checkDiamondPermission() internal view virtual;
    
    function _setDiamond(address diamondAddress) private {
        if (diamondAddress == address(0)) revert InvalidAddress();
        
        address oldDiamond = address(diamond);
        diamond = ICollectionDiamond(diamondAddress);
        
        emit DiamondUpdated(oldDiamond, diamondAddress);
    }
    
    function _setCollectionId(uint256 newCollectionId) private {
        if (newCollectionId == 0) revert InvalidCollectionId();
        
        uint256 oldId = collectionId;
        collectionId = newCollectionId;
        
        emit CollectionIdUpdated(oldId, newCollectionId);
    }
    
    function _requireTokenExists(uint256 tokenId) private view {
        if (!_tokenExists(tokenId)) revert TokenNotExists();
    }
}