// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "./LibHenomorphsStorage.sol";
import {LibStakingStorage} from "./LibStakingStorage.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibDiamond} from "../../shared/libraries/LibDiamond.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SpecimenCollection} from "../../libraries/HenomorphsModel.sol";
import {RateLimits} from "../../libraries/StakingModel.sol";

/**
 * @dev Interface for staking authorization checks
 */
interface IStakingAuthorizer {
    function isSpecimenStaked(uint256 collectionId, uint256 tokenId) external view returns (bool);
    function isTokenStaker(uint256 collectionId, uint256 tokenId, address staker) external view returns (bool);
}

/**
 * @title AccessHelper
 * @notice Universal helper library for access control with standardized functions
 * @dev Centralizes common access control patterns used across facets
 */
library AccessHelper {
    // Events 
    event AccessAttempt(address caller, string function_name, bool granted);
    
    // Errors
    error Unauthorized(address caller, string reason); 
    error PausedContract();
    error InsufficientFunds(uint256 required, uint256 available);
    error InvalidOperationForToken(uint256 collectionId, uint256 tokenId, string reason);
    error RateLimitExceeded(address caller, bytes4 selector);

    /**
     * @notice Optimized staking system address retrieval
     * @dev Direct retrieval from storage for consistency
     */
    function getStakingAddress() internal view returns (address) {
        return LibHenomorphsStorage.henomorphsStorage().stakingSystemAddress;
    }

    /**
     * @notice Check if caller has admin privileges
     * @dev Consistent admin check used throughout all facets
     * @return True if caller is contract owner or registered operator
     */
    function isAuthorized() internal view returns (bool) {
        address originalCaller = LibMeta.msgSender();
        address directCaller = msg.sender;

        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Owner or operator access
        if (originalCaller == LibDiamond.contractOwner() || hs.operators[originalCaller]) {
            return true;
        }

        if (directCaller != originalCaller) {
            return (directCaller == LibDiamond.contractOwner() || hs.operators[directCaller]);
        }
        
        return false;
    }

    /**
     * @notice Require caller to have admin privileges
     * @dev Utility function that automatically reverts if not authorized
     */
    function requireAuthorized() internal view {
        if (!isAuthorized()) {
            revert Unauthorized(LibMeta.msgSender(), "Not authorized");
        }
    }
    
    /**
     * @notice Check if system is paused
     * @dev Centralized pause check for consistency
     * @return True if system is in paused state
     */
    function isPaused() internal view returns (bool) {
        return LibHenomorphsStorage.henomorphsStorage().paused;
    }

    /**
     * @notice Check if token is owned by the specified address
     * @dev Utility for token ownership verification
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param owner Address to check ownership against
     * @param stakingAddress Optional staking address for staking checks
     * @return True if the address owns or is authorized for the token
     */
    function checkTokenOwnership(
        uint256 collectionId,
        uint256 tokenId,
        address owner,
        address stakingAddress
    ) internal view returns (bool) {
        if (owner == address(0)) {
            return false;
        }
        
        // Admin check
        if (isAuthorized() && owner == LibMeta.msgSender()) {
            return true;
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        
        // Staking check
        if (stakingAddress != address(0)) {
            try IStakingAuthorizer(stakingAddress).isTokenStaker(collectionId, tokenId, owner) returns (bool isStaker) {
                if (isStaker) {
                    return true;
                }
            } catch {
                // Continue to normal ownership check
            }
        }
        
        // Direct ownership check
        try IERC721(collection.collectionAddress).ownerOf(tokenId) returns (address tokenOwner) {
            return tokenOwner == owner;
        } catch {
            return false;
        }
    }

    /**
     * @notice Comprehensive token authorization check
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param stakingAddress Optional staking address for additional checks
     * @return True if caller is authorized to control this token
     * @dev Checks admin status, token ownership, and staking status
     */
    function authorizeForToken(
        uint256 collectionId, 
        uint256 tokenId, 
        address stakingAddress
    ) internal view returns (bool) {
        address sender = LibMeta.msgSender();
        
        // Admin check (always authorized)
        if (isAuthorized()) {
            return true;
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Collection validation
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        if (!collection.enabled) {
            return false;
        }
        
        // Check staking system if address provided
        if (stakingAddress != address(0)) {
            // Use a safe call pattern to avoid breaking on staking system errors
            try IStakingAuthorizer(stakingAddress).isTokenStaker(collectionId, tokenId, sender) returns (bool isStaker) {
                if (isStaker) {
                    return true;
                }
            } catch {
                // Continue to normal ownership check
            }
        }
        
        // Direct ownership check
        try IERC721(collection.collectionAddress).ownerOf(tokenId) returns (address owner) {
            return owner == sender;
        } catch {
            return false;
        }
    }

    /**
     * @notice Check if current call is from within the diamond contract
     * @dev Used to validate inter-facet calls
     * @return True if call originated from the contract itself
     */
    function isInternalCall() internal view returns (bool) {
        return msg.sender == address(this);
    }
    
    /**
     * @notice Enforce rate limiting for operations
     * @param caller Address performing the operation
     * @param selector Function selector being called
     * @param maxCalls Maximum allowed calls in the period
     * @param period Time period for rate limiting
     * @return True if operation is allowed within rate limits
     */
    function enforceRateLimit(
        address caller, 
        bytes4 selector, 
        uint256 maxCalls, 
        uint256 period
    ) internal returns (bool) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Get current time
        uint256 currentTime = block.timestamp;
        
        // Access rate limit data with proper key structure
        RateLimits storage rateData = ss.rateLimits[caller][selector];
        
        // If period has passed, reset counter
        if (currentTime > rateData.windowStart + period) {
            rateData.operationCount = 1;
            rateData.windowStart = currentTime;
            return true;
        }
        
        // Check if limit exceeded
        if (rateData.operationCount >= maxCalls) {
            return false;
        }
        
        // Increment call count
        rateData.operationCount++;
        return true;
    }
}