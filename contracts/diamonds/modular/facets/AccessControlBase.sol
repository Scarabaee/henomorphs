// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibCollectionStorage} from "../libraries/LibCollectionStorage.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";  
import {LibMeta} from "../../shared/libraries/LibMeta.sol";

/**
 * @title AccessControlBase
 * @notice Production-ready base contract providing unified access control for Diamond facets
 * @dev All facets should inherit from this to ensure consistent access control patterns
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
abstract contract AccessControlBase {
    
    // Events for monitoring and debugging
    event SystemPaused();
    event SystemUnpaused();
    
    // Optimized custom errors for gas efficiency
    error NotAuthorized();
    error SystemIsPaused();
    error RateLimitExceeded();
    error TokenNotFound();
    error NoTokenAccess();
    error InvalidCollection();
    error SystemCallRequired();
    error CollectionNotFound(uint256 collectionId);
    error UnsupportedCollectionType(uint256 collectionId, string expected);
    
    /**
     * @notice Modifier requiring administrative privileges (owner or operator)
     * @dev Use for functions that modify system configuration or manage collections
     */
    modifier onlyAuthorized() {
        AccessHelper.requireAuthorized();
        _;
    }
    
    /**
     * @notice Modifier ensuring system is not paused
     * @dev All state-changing operations should use this modifier
     */
    modifier whenNotPaused() {
        if (AccessHelper.isPaused()) {
            revert SystemIsPaused();
        }
        _;
    }
    
    /**
     * @notice Modifier for system-level access (admin, internal, or approved system)
     * @dev Use for functions that should only be called by trusted systems
     */
    modifier onlySystem() {
        AccessHelper.requireSystemAccess();
        _;
    }
    
    /**
     * @notice Modifier requiring token controller access (owner, approved, or staker)
     * @dev Use for functions that operate on specific tokens
     * @param collectionAddress Collection contract address
     * @param tokenId Token identifier
     */
    modifier onlyTokenController(address collectionAddress, uint256 tokenId) virtual {
        AccessHelper.requireTokenAccess(collectionAddress, tokenId);
        _;
    }
    
    /**
     * @notice Rate limiting modifier to prevent spam and DoS attacks
     * @dev Configure limits based on function sensitivity and expected usage
     * @param maxCalls Maximum calls allowed in the time window
     * @param window Time window in seconds
     */
    modifier rateLimited(uint256 maxCalls, uint256 window) {
        AccessHelper.enforceRateLimit(msg.sender, msg.sig, maxCalls, window);
        _;
    }

    /**
     * @notice Modifier to validate collection exists and is active
     * @param collectionId Collection ID to validate
     */
    modifier validCollection(uint256 collectionId) {
        if (!LibCollectionStorage.collectionExists(collectionId)) {
            revert CollectionNotFound(collectionId);
        }
        _;
    }

    modifier validInternalCollection(uint256 collectionId) {
        if (!LibCollectionStorage.isInternalCollection(collectionId)) {
            revert UnsupportedCollectionType(collectionId, "internal");
        }
        _;
    }

    modifier validExternalCollection(uint256 collectionId) {
        if (!LibCollectionStorage.isExternalCollection(collectionId)) {
            revert UnsupportedCollectionType(collectionId, "external");
        }
        _;
    }
        
    /**
     * @notice Emergency pause function for system administrators
     * @dev Can be called by owner or operators in emergency situations
     */
    function emergencyPause() external onlyAuthorized {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        cs.paused = true;
        
        // Emit event for monitoring
        emit SystemPaused();
    }
    
    /**
     * @notice Emergency unpause function for system administrators
     * @dev Can be called by owner or operators to restore normal operations
     */
    function emergencyUnpause() external onlyAuthorized {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        cs.paused = false;
        
        // Emit event for monitoring
        emit SystemUnpaused();
    }

    /**
     * @notice Get collection address for token (helper function)
     * @dev Searches through registered collections to find token
     * @param tokenId Token ID to locate
     * @return collectionAddress Address of the collection containing the token
     */
    function _getTokenCollection(uint256 tokenId) internal view returns (address collectionAddress) {
        return AccessHelper.findTokenCollection(tokenId);
    }

    /**
     * @notice Get collection address by collection ID
     * @param collectionId Collection ID
     * @return Address of the collection contract
     */
    function _getCollectionAddress(uint256 collectionId) internal virtual view returns (address) {
        return AccessHelper.getCollectionAddress(collectionId);
    }

    /**
     * @notice Check if caller has token access without reverting
     * @dev Useful for conditional logic based on access rights
     * @param collectionAddress Collection contract address
     * @param tokenId Token ID
     * @return True if caller has access to the token
     */
    function _hasTokenAccess(address collectionAddress, uint256 tokenId) internal view returns (bool) {
        address originalCaller = LibMeta.msgSender();
        address directCaller = msg.sender;
        
        if (AccessHelper.hasTokenAccess(collectionAddress, tokenId, originalCaller)) {
            return true;
        }
        
        if (directCaller != originalCaller) {
            return AccessHelper.hasTokenAccess(collectionAddress, tokenId, directCaller);
        }
        
        return false;
    }

    /**
     * @notice Check if caller is authorized without reverting
     * @dev Useful for conditional logic based on admin privileges
     * @return True if caller has administrative privileges
     */
    function _isAuthorized() internal view returns (bool) {
        return AccessHelper.isAuthorized();
    }

    /**
     * @notice Check if caller is an approved system without reverting
     * @dev Useful for conditional logic based on system privileges
     * @return True if caller is an approved system
     */
    function _isApprovedSystem() internal view returns (bool) {
        return AccessHelper.isApprovedSystem(msg.sender);
    }

    /**
     * @notice Get current system pause status
     * @return True if system is paused
     */
    function isPaused() external view returns (bool) {
        return AccessHelper.isPaused();
    }

    /**
     * @notice Standardized modifier preventing reentrancy attacks
     * @dev Dodany modyfikator zapobiegający atakom typu reentrancy
     */
    modifier nonReentrant() {
        ReentrancyGuard.nonReentrantBefore();
        _;
        ReentrancyGuard.nonReentrantAfter();
    }
}