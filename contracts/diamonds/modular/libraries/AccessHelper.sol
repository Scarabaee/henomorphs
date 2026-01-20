// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibCollectionStorage} from "./LibCollectionStorage.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibDiamond} from "../../shared/libraries/LibDiamond.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IStaking} from "../interfaces/IExternalSystems.sol"; 

/**
 * @title AccessHelper
 * @notice Production-ready unified access control library for ModularAsset Diamond
 * @dev Centralizes all access control patterns with comprehensive token ownership verification
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
library AccessHelper {
    // Events for monitoring and debugging
    event RateLimitTriggered(address indexed caller, bytes4 indexed selector, uint256 count);
    
    // Comprehensive error definitions
    error Unauthorized(address caller, string reason); 
    error PausedContract();
    error InsufficientFunds(uint256 required, uint256 available);
    error InvalidOperationForToken(uint256 collectionId, uint256 tokenId, string reason);
    error RateLimitExceeded(address caller, bytes4 selector);
    error TokenNotFound(uint256 tokenId);
    error CollectionNotFound(address collectionAddress);
    error InvalidTokenAccess(address caller, address collection, uint256 tokenId);
    error SystemCallRequired(address caller, string operation);

    /**
     * @notice Check if caller has admin privileges (owner or operator)
     * @dev Primary authorization check for administrative functions
     * @return True if caller is contract owner or registered operator
     */
    function isAuthorized() internal view returns (bool) {
        address sender = LibMeta.msgSender();
        LibCollectionStorage.CollectionStorage storage ds = LibCollectionStorage.collectionStorage();
        
        return sender == LibDiamond.contractOwner() || ds.operators[sender];
    }
    
    /**
     * @notice Require caller to have admin privileges
     * @dev Reverts if caller lacks administrative access
     */
    function requireAuthorized() internal view {
        if (!isAuthorized()) {
            revert Unauthorized(LibMeta.msgSender(), "Admin access required");
        }
    }
    
    /**
     * @notice Check if current call originates from within the diamond contract
     * @dev Used to validate inter-facet calls for internal operations
     * @return True if call originated from the diamond contract itself
     */
    function isInternalCall() internal view returns (bool) {
        return msg.sender == address(this);
    }
    
    /**
     * @notice Check if caller is an approved external system
     * @param caller Address to verify
     * @return True if caller is approved system (staking, chargepod, biopod) or internal call
     */
    function isApprovedSystem(address caller) internal view returns (bool) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        // Existing approved systems
        if (caller == cs.stakingSystemAddress ||
            caller == cs.chargepodAddress ||
            caller == cs.biopodAddress ||
            isInternalCall()) {
            return true;
        }
        
        // Check if caller is a registered collection contract
        // This allows collection contracts to call Diamond functions
        LibCollectionStorage.CollectionData storage collection = cs.collections[cs.collectionsByAddress[caller]];
        if (collection.contractAddress == caller && collection.enabled) {
            return true;
        }
 
        return false;
    }

    /**
     * @notice Comprehensive token access verification
     * @dev Checks owner, approved operators, and staking status
     * @param collectionAddress Collection contract address
     * @param tokenId Token ID to verify access for
     * @param user User requesting access
     * @return True if user has legitimate access to the token
     */
    function hasTokenAccess(
        address collectionAddress,
        uint256 tokenId,
        address user
    ) internal view returns (bool) {
        if (collectionAddress == address(0) || user == address(0)) return false;

        if (isAuthorized()) {
            return true;
        }
        
        try IERC721(collectionAddress).ownerOf(tokenId) returns (address owner) {
            // Direct ownership
            if (owner == user) return true;
            
            // Check staking - token owned by staking contract
            address stakingAddr = getStakingAddress();
            if (stakingAddr != address(0)) {
                try IStaking(stakingAddr).getTokenStaker(collectionAddress, tokenId) returns (address staker) {
                    if (staker == user) return true;
                } catch {
                    // Staking system unavailable, continue with other checks
                }
            }
            
            // Check approvals
            try IERC721(collectionAddress).isApprovedForAll(owner, user) returns (bool approved) {
                if (approved) return true;
            } catch {}
            
            try IERC721(collectionAddress).getApproved(tokenId) returns (address approved) {
                if (approved == user) return true;
            } catch {}
            
        } catch {
            return false;
        }
        
        return false;
    }
 
    function checkTokenOwnership(
        address collectionAddress,
        uint256 tokenId,
        address user,
        address
    ) internal view returns (bool) {
        // Delegate to existing hasTokenAccess method
        return hasTokenAccess(collectionAddress, tokenId, user);
    }

    /**
     * @notice Require token controller access
     * @dev Reverts if caller lacks access to the specified token
     * @param collectionAddress Collection contract address
     * @param tokenId Token ID to verify access for
     */
    function requireTokenAccess(
        address collectionAddress,
        uint256 tokenId
    ) internal view {
        address caller = LibMeta.msgSender();
        
        if (!hasTokenAccess(collectionAddress, tokenId, caller)) {
            revert InvalidTokenAccess(caller, collectionAddress, tokenId);
        }
    }

    /**
     * @notice Require system-level access (admin, internal, or approved system)
     * @dev Used for functions that should only be called by trusted systems
     */
    function requireSystemAccess() internal view {
        address caller = LibMeta.msgSender();
        
        if (!isAuthorized() && !isInternalCall() && !isApprovedSystem(caller)) {
            revert SystemCallRequired(caller, "Internal or approved system access required");
        }
    }

    /**
     * @notice Check if the system is currently paused
     * @return True if system is in paused state
     */
    function isPaused() internal view returns (bool) {
        return LibCollectionStorage.collectionStorage().paused;
    }

    /**
     * @notice Get configured staking system address
     * @return Address of the staking system contract (address(0) if not configured)
     */
    function getStakingAddress() internal view returns (address) {
        return LibCollectionStorage.collectionStorage().stakingSystemAddress;
    }

    /**
     * @notice Get the current staker of a token from the staking system
     * @dev Safe call that returns address(0) if staking system unavailable
     * @param collectionAddress Collection contract address
     * @param tokenId Token ID to query
     * @return Address of the token staker (address(0) if not staked or system unavailable)
     */
    function getStaker(address collectionAddress, uint256 tokenId) internal view returns (address) {
        address stakingAddr = getStakingAddress();
        if (stakingAddr == address(0)) return address(0);
        
        try IStaking(stakingAddr).getTokenStaker(collectionAddress, tokenId) returns (address staker) {
            return staker;
        } catch {
            // Return zero address if staking system call fails
            return address(0);
        }
    }

    /**
     * @notice Enforce rate limiting for operations
     * @dev Reverts if rate limit is exceeded, otherwise increments counter
     * @param caller Address performing the operation
     * @param selector Function selector being called
     * @param maxCalls Maximum allowed calls in the time period
     * @param period Time period for rate limiting in seconds
     */
    function enforceRateLimit(
        address caller, 
        bytes4 selector, 
        uint256 maxCalls, 
        uint256 period
    ) internal {
        LibCollectionStorage.CollectionStorage storage ds = LibCollectionStorage.collectionStorage();
        
        uint256 currentTime = block.timestamp;
        LibCollectionStorage.RateLimits storage rateData = ds.rateLimits[caller][selector];
        
        // Reset window if period has passed
        if (currentTime > rateData.windowStart + period) {
            rateData.operationCount = 1;
            rateData.windowStart = currentTime;
            return;
        }
        
        // Check if limit would be exceeded
        if (rateData.operationCount >= maxCalls) {
            emit RateLimitTriggered(caller, selector, rateData.operationCount);
            revert RateLimitExceeded(caller, selector);
        }
        
        // Increment call count
        rateData.operationCount++;
    }

    /**
     * @notice Find collection address for a given token ID
     * @dev Searches through registered collections to find token owner
     * @param tokenId Token ID to locate
     * @return collectionAddress Address of the collection containing the token
     */
    function findTokenCollection(uint256 tokenId) internal view returns (address collectionAddress) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Search through registered collections
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            if (cs.collections[i].enabled && cs.collections[i].contractAddress != address(0)) {
                try IERC721(cs.collections[i].contractAddress).ownerOf(tokenId) returns (address) {
                    return cs.collections[i].contractAddress;
                } catch {
                    // Continue searching if token not found in this collection
                }
            }
        }
        
        revert TokenNotFound(tokenId);
    }

    /**
     * @notice Validate that a collection is properly registered and active
     * @param collectionId Collection ID to validate
     */
    function requireValidCollection(uint256 collectionId) internal view {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (collectionId == 0 || collectionId >= cs.collectionCounter) {
            revert CollectionNotFound(address(0));
        }
        
        if (!cs.collections[collectionId].enabled) {
            revert CollectionNotFound(cs.collections[collectionId].contractAddress);
        }
    }

    /**
     * @notice Get collection address by collection ID
     * @param collectionId Collection ID
     * @return Address of the collection contract
     */
    function getCollectionAddress(uint256 collectionId) internal view returns (address) {
        requireValidCollection(collectionId);
        return LibCollectionStorage.collectionStorage().collections[collectionId].contractAddress;
    }
}