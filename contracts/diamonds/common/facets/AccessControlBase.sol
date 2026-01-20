// Nowy plik: AccessControlBase.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../../chargepod/libraries/LibHenomorphsStorage.sol";
import {AccessHelper} from "../../staking/libraries/AccessHelper.sol";
import {ReentrancyGuard} from "../../../libraries/ReentrancyGuard.sol";

/**
 * @title AccessControlBase
 * @notice Base contract with standardized access control modifiers
 * @dev Should be inherited by all facets requiring standardized access control
 * author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
abstract contract AccessControlBase {

    /**
     * @notice Standard modifier for ensuring contract is not paused
     */
    modifier whenNotPaused() {
        if (AccessHelper.isPaused()) {
            revert AccessHelper.PausedContract();
        }
        _;
    }

    /**
     * @notice Standard modifier for functions requiring owner/operator authorization
     */
    modifier onlyAuthorized() {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (!AccessHelper.isAuthorized() && !hs.operators[msg.sender])  {
            revert AccessHelper.Unauthorized(msg.sender, "Not authorized");
        }
        _;
    }

    /**
     * @notice Standardized modifier for token control functions
     * @param collectionId Collection ID
     * @param tokenId Token ID
     */
    modifier onlyTokenController(uint256 collectionId, uint256 tokenId) {
        if (!AccessHelper.authorizeForToken(collectionId, tokenId, AccessHelper.getStakingAddress())) {
            revert AccessHelper.Unauthorized(msg.sender, "Not token controller");
        }
        _;
    }
    
    /**
     * @notice Modifier for inter-facet calls
     */
    modifier onlyInternal() {
        if (!AccessHelper.isInternalCall()) {
            revert AccessHelper.Unauthorized(msg.sender, "External call not allowed");
        }
        _;
    }

    /**
     * @notice Modifier for trusted system calls (inter-facet, staking diamond, or admin)
     */
    modifier onlyTrusted() {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        if (!AccessHelper.isInternalCall() && msg.sender != hs.stakingSystemAddress && !AccessHelper.isAuthorized()) {
            revert AccessHelper.Unauthorized(msg.sender, "Not trusted");
        }
        _;
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