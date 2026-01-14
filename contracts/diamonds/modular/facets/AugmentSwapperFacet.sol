// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {LibCollectionStorage} from "../libraries/LibCollectionStorage.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {LibMeta} from "../shared/libraries/LibMeta.sol";

    // ==================== INTERFACES ====================

    /**
     * @notice Interface for calling AugmentFacet functions with skipFee parameter
     */
    interface IAugmentFacet {
        function altAssignAugment(
            address specimenCollection,
            uint256 specimenTokenId,
            address augmentCollection,
            uint256 augmentTokenId,
            uint256 lockDuration,
            bool createAccessories,
            bool skipFee
        ) external;
        
        function removeAugment(
            address specimenCollection,
            uint256 specimenTokenId,
            bool removeAccessories,
            bool forceUnlock
        ) external;
    }

/**
 * @title AugmentSwapperFacet
 * @notice Provides paid augment swapping functionality for Genesis and other collections
 * @dev Uses skipFee parameter in AugmentFacet to prevent double fee charging
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract AugmentSwapperFacet is AccessControlBase {
    using Address for address payable;

    // ==================== EVENTS ====================
    
    /**
     * @notice Emitted when an existing augment is swapped for a new one
     */
    event AugmentSwapped(
        uint256 indexed collectionId,
        uint256 indexed specimenTokenId,
        address indexed newAugmentCollection,
        uint256 newAugmentTokenId,
        address oldAugmentCollection,
        uint256 oldAugmentTokenId,
        uint256 feePaid
    );
    
    /**
     * @notice Emitted when an augment is assigned to a clean specimen token
     */
    event AugmentAssignedViaPaidSwapper(
        uint256 indexed collectionId,
        uint256 indexed specimenTokenId,
        address indexed augmentCollection,
        uint256 augmentTokenId,
        uint256 feePaid
    );

    /**
     * @notice Emitted when swap fees are configured for a collection
     */
    event SwapFeesConfigured(
        uint256 indexed collectionId,
        address currency,
        uint256 swapFee,
        uint256 assignFee,
        address beneficiary,
        bool enabled
    );

    // ==================== ERRORS ====================
    
    error SwapNotEnabled();
    error InsufficientFee(uint256 required, uint256 provided);
    error AugmentNotOwned();
    error AugmentAlreadyUsed();
    error SameAugmentSwap();
    error NoExistingAugment();
    error HasExistingAugment();
    error InvalidConfiguration();
    error CollectionNotSupported(uint256 collectionId);
    error AugmentFacetCallFailed(string reason);
    error AugmentNotAllowed(uint256 collectionId, address augmentCollection);

    // ==================== ADMIN FUNCTIONS ====================

    /**
     * @notice Configure swap fees for a collection
     * @param collectionId Target collection ID
     * @param currency Fee currency address (e.g., ZICO token)
     * @param swapFee Fee amount for swapping existing augment
     * @param assignFee Fee amount for assigning to clean token
     * @param beneficiary Address to receive fees
     * @param enabled Whether swapping is enabled for this collection
     */
    function configureSwapFees(
        uint256 collectionId,
        address currency,
        uint256 swapFee,
        uint256 assignFee,
        address beneficiary,
        bool enabled
    ) external onlyAuthorized whenNotPaused nonReentrant validCollection(collectionId) {
        
        if ((swapFee > 0 || assignFee > 0) && beneficiary == address(0)) {
            revert InvalidConfiguration();
        }

        // Get storage reference - using collectionId instead of address
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.AugmentSwapFeeConfig storage config = cs.augmentSwapFeeConfigs[collectionId];
        
        // Configure swap fee
        config.swapFee.currency = currency;
        config.swapFee.amount = swapFee;
        config.swapFee.beneficiary = beneficiary;
        
        // Configure assignment fee
        config.assignFee.currency = currency;
        config.assignFee.amount = assignFee;
        config.assignFee.beneficiary = beneficiary;
        
        // Set operational flags
        config.enabled = enabled;
        config.requiresPayment = (swapFee > 0 || assignFee > 0);

        emit SwapFeesConfigured(collectionId, currency, swapFee, assignFee, beneficiary, enabled);
    }

    /**
     * @notice Enable or disable swapping for a collection
     * @param collectionId Collection to update
     * @param enabled Whether to enable swapping
     */
    function setSwapEnabled(
        uint256 collectionId,
        bool enabled
    ) external onlyAuthorized whenNotPaused nonReentrant validCollection(collectionId) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Ensure collection is configured
        if (cs.augmentSwapFeeConfigs[collectionId].swapFee.currency == address(0)) {
            revert CollectionNotSupported(collectionId);
        }
        
        cs.augmentSwapFeeConfigs[collectionId].enabled = enabled;
    }

    /**
     * @notice Update fee amounts for an already configured collection
     * @param collectionId Collection to update
     * @param swapFee New swap fee amount
     * @param assignFee New assignment fee amount
     */
    function updateFeeAmounts(
        uint256 collectionId,
        uint256 swapFee,
        uint256 assignFee
    ) external onlyAuthorized whenNotPaused nonReentrant validCollection(collectionId) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.AugmentSwapFeeConfig storage config = cs.augmentSwapFeeConfigs[collectionId];
        
        // Ensure collection is configured
        if (config.swapFee.currency == address(0)) {
            revert CollectionNotSupported(collectionId);
        }
        
        config.swapFee.amount = swapFee;
        config.assignFee.amount = assignFee;
        config.requiresPayment = (swapFee > 0 || assignFee > 0);
        
        emit SwapFeesConfigured(
            collectionId, 
            config.swapFee.currency, 
            swapFee, 
            assignFee, 
            config.swapFee.beneficiary, 
            config.enabled
        );
    }

    // ==================== USER FUNCTIONS ====================

    /**
     * @notice Swap existing augment for a new one
     * @param collectionId Collection ID
     * @param specimenTokenId Token ID to swap augment for
     * @param newAugmentCollection New augment collection address
     * @param newAugmentTokenId New augment token ID
     * @param maxFee Maximum fee willing to pay (slippage protection)
     */
    function swapAugment(
        uint256 collectionId,
        uint256 specimenTokenId,
        address newAugmentCollection,
        uint256 newAugmentTokenId,
        uint256 maxFee
    ) external whenNotPaused nonReentrant validCollection(collectionId) {
        
        address specimenCollection = _getCollectionAddress(collectionId);
        
        // Validate caller owns specimen token
        _requireTokenOwnership(specimenCollection, specimenTokenId);
        
        // Validate caller owns new augment and it's available
        _requireAugmentOwnership(newAugmentCollection, newAugmentTokenId);
        
        // Validate swapping is enabled for this collection
        _requireSwapEnabled(collectionId);

        _validateAugmentCompatibility(specimenCollection, newAugmentCollection);

        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Check specimen has existing augment assignment
        bytes32 assignmentKey = cs.specimenToAssignment[specimenCollection][specimenTokenId];
        if (assignmentKey == bytes32(0) || !cs.augmentAssignments[assignmentKey].active) {
            revert NoExistingAugment();
        }

        LibCollectionStorage.AugmentAssignment storage existing = cs.augmentAssignments[assignmentKey];
        
        // Prevent swapping to same augment
        if (existing.augmentCollection == newAugmentCollection && 
            existing.augmentTokenId == newAugmentTokenId) {
            revert SameAugmentSwap();
        }

        // Validate fee amount
        LibCollectionStorage.AugmentSwapFeeConfig storage config = cs.augmentSwapFeeConfigs[collectionId];
        if (config.swapFee.amount > maxFee) {
            revert InsufficientFee(config.swapFee.amount, maxFee);
        }

        // Collect swap fee
        uint256 feePaid = _collectFee(config.swapFee, "swap_augment");

        // Store old augment info for event emission
        address oldAugmentCollection = existing.augmentCollection;
        uint256 oldAugmentTokenId = existing.augmentTokenId;

        // Remove existing augment (force unlock since this is admin operation)
        _callRemoveAugment(specimenCollection, specimenTokenId);

        // Assign new augment with skipFee=true to prevent double charging
        _callAssignAugment(
            specimenCollection,
            specimenTokenId,
            newAugmentCollection,
            newAugmentTokenId
        );

        emit AugmentSwapped(
            collectionId,
            specimenTokenId,
            newAugmentCollection,
            newAugmentTokenId,
            oldAugmentCollection,
            oldAugmentTokenId,
            feePaid
        );
    }

    /**
     * @notice Assign augment to specimen token without existing assignment
     * @param collectionId Collection ID
     * @param specimenTokenId Token ID to assign augment to
     * @param augmentCollection Augment collection address
     * @param augmentTokenId Augment token ID
     * @param maxFee Maximum fee willing to pay (slippage protection)
     */
    function assignAugmentViaPaidSwapper(
        uint256 collectionId,
        uint256 specimenTokenId,
        address augmentCollection,
        uint256 augmentTokenId,
        uint256 maxFee
    ) external whenNotPaused nonReentrant validCollection(collectionId) {
        
        address specimenCollection = _getCollectionAddress(collectionId);
        
        // Validate caller owns specimen token
        _requireTokenOwnership(specimenCollection, specimenTokenId);
        
        // Validate caller owns augment and it's available
        _requireAugmentOwnership(augmentCollection, augmentTokenId);
        
        // Validate swapping is enabled for this collection
        _requireSwapEnabled(collectionId);

        _validateAugmentCompatibility(specimenCollection, augmentCollection);

        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Check specimen has NO existing augment assignment
        bytes32 existingKey = cs.specimenToAssignment[specimenCollection][specimenTokenId];
        if (existingKey != bytes32(0) && cs.augmentAssignments[existingKey].active) {
            revert HasExistingAugment();
        }

        // Validate fee amount
        LibCollectionStorage.AugmentSwapFeeConfig storage config = cs.augmentSwapFeeConfigs[collectionId];
        if (config.assignFee.amount > maxFee) {
            revert InsufficientFee(config.assignFee.amount, maxFee);
        }

        // Collect assignment fee
        uint256 feePaid = _collectFee(config.assignFee, "assign_augment_via_swapper");

        // Assign augment with skipFee=true to prevent double charging
        _callAssignAugment(specimenCollection, specimenTokenId, augmentCollection, augmentTokenId);

        emit AugmentAssignedViaPaidSwapper(collectionId, specimenTokenId, augmentCollection, augmentTokenId, feePaid);
    }

    // ==================== VIEW FUNCTIONS ====================

    /**
     * @notice Get complete swap configuration for a collection
     * @param collectionId Collection to query
     * @return config Complete swap fee configuration
     */
    function getSwapConfig(uint256 collectionId) 
        external view validCollection(collectionId) returns (LibCollectionStorage.AugmentSwapFeeConfig memory config) {
        return LibCollectionStorage.collectionStorage().augmentSwapFeeConfigs[collectionId];
    }

    /**
     * @notice Calculate required fee for an operation
     * @param collectionId Collection to check
     * @param specimenTokenId Token to check
     * @return fee Required fee amount
     * @return currency Fee currency address
     * @return isSwap True if swap operation (has existing augment), false if assign
     */
    function calculateRequiredFee(
        uint256 collectionId,
        uint256 specimenTokenId
    ) external view validCollection(collectionId) returns (uint256 fee, address currency, bool isSwap) {
        
        address specimenCollection = _getCollectionAddress(collectionId);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.AugmentSwapFeeConfig storage config = cs.augmentSwapFeeConfigs[collectionId];
        
        // Check if specimen has existing augment
        bytes32 assignmentKey = cs.specimenToAssignment[specimenCollection][specimenTokenId];
        
        if (assignmentKey != bytes32(0) && cs.augmentAssignments[assignmentKey].active) {
            // Has existing augment - return swap fee
            return (config.swapFee.amount, config.swapFee.currency, true);
        } else {
            // No existing augment - return assignment fee
            return (config.assignFee.amount, config.assignFee.currency, false);
        }
    }

    /**
     * @notice Check if swapping is enabled for a collection
     * @param collectionId Collection to check
     * @return enabled Whether swapping is enabled
     */
    function isSwapEnabled(uint256 collectionId) external view validCollection(collectionId) returns (bool enabled) {
        return LibCollectionStorage.collectionStorage().augmentSwapFeeConfigs[collectionId].enabled;
    }

    /**
     * @notice Get fee breakdown for a collection
     * @param collectionId Collection to check
     * @return swapFee Swap fee amount
     * @return assignFee Assignment fee amount
     * @return currency Fee currency address
     * @return beneficiary Fee recipient address
     */
    function getFeeBreakdown(uint256 collectionId) 
        external view validCollection(collectionId) returns (uint256 swapFee, uint256 assignFee, address currency, address beneficiary) {
        
        LibCollectionStorage.AugmentSwapFeeConfig storage config = 
            LibCollectionStorage.collectionStorage().augmentSwapFeeConfigs[collectionId];
        
        return (
            config.swapFee.amount,
            config.assignFee.amount,
            config.swapFee.currency,
            config.swapFee.beneficiary
        );
    }

    // ==================== INTERNAL HELPER FUNCTIONS ====================

    function _validateAugmentCompatibility(
        address specimenCollection,
        address augmentCollection
    ) internal view {
        
        uint256 collectionId = LibCollectionStorage.getCollectionIdByAddress(specimenCollection);
        
        // Skip for external collections
        if (collectionId == 0 || !LibCollectionStorage.isInternalCollection(collectionId)) {
            return;
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Check restrictions
        if (!cs.augmentRestrictions[collectionId]) {
            return; // No restrictions
        }
        
        // Check if allowed
        if (!cs.allowedAugments[collectionId][augmentCollection]) {
            revert AugmentNotAllowed(collectionId, augmentCollection);
        }
    }

    /**
     * @notice Validate caller owns the specimen token
     */
    function _requireTokenOwnership(address collection, uint256 tokenId) internal view {
        try IERC721(collection).ownerOf(tokenId) returns (address owner) {
            if (owner != LibMeta.msgSender()) {
                revert AugmentNotOwned();
            }
        } catch {
            revert AugmentNotOwned();
        }
    }

    /**
     * @notice Validate caller owns the augment and it's available for assignment
     */
    function _requireAugmentOwnership(address collection, uint256 tokenId) internal view {
        // Check caller owns the augment
        try IERC721(collection).ownerOf(tokenId) returns (address owner) {
            if (owner != LibMeta.msgSender()) {
                revert AugmentNotOwned();
            }
        } catch {
            revert AugmentNotOwned();
        }

        // Check augment is not already assigned elsewhere
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        bytes32 augmentKey = cs.augmentTokenToAssignment[collection][tokenId];
        
        if (augmentKey != bytes32(0) && cs.augmentAssignments[augmentKey].active) {
            revert AugmentAlreadyUsed();
        }
    }

    /**
     * @notice Validate swapping is enabled for the collection
     */
    function _requireSwapEnabled(uint256 collectionId) internal view {
        LibCollectionStorage.AugmentSwapFeeConfig storage config = 
            LibCollectionStorage.collectionStorage().augmentSwapFeeConfigs[collectionId];
            
        if (!config.enabled) {
            revert SwapNotEnabled();
        }
    }

    /**
     * @notice Collect fee using LibFeeCollection
     */
    function _collectFee(
        LibCollectionStorage.ControlFee memory feeConfig,
        string memory purpose
    ) internal returns (uint256 feePaid) {
        
        // Skip if no fee required
        if (feeConfig.amount == 0) {
            return 0;
        }

        // Collect fee using system library
        LibFeeCollection.collectFee(
            feeConfig.currency,
            LibMeta.msgSender(),
            feeConfig.beneficiary,
            feeConfig.amount,
            purpose
        );

        return feeConfig.amount;
    }

    /**
     * @notice Call AugmentFacet.removeAugment with proper error handling
     */
    function _callRemoveAugment(
        address specimenCollection,
        uint256 specimenTokenId
    ) internal {
        
        try IAugmentFacet(address(this)).removeAugment(
            specimenCollection,
            specimenTokenId,
            true,  // Remove accessories
            true   // Force unlock (admin operation)
        ) {
            // Success - continue
        } catch Error(string memory reason) {
            revert AugmentFacetCallFailed(reason);
        } catch {
            revert AugmentFacetCallFailed("Unknown error in removeAugment");
        }
    }

    /**
     * @notice Call AugmentFacet.assignAugment with skipFee=true and proper error handling
     */
    function _callAssignAugment(
        address specimenCollection,
        uint256 specimenTokenId,
        address augmentCollection,
        uint256 augmentTokenId
    ) internal {
        
        try IAugmentFacet(address(this)).altAssignAugment(
            specimenCollection,
            specimenTokenId,
            augmentCollection,
            augmentTokenId,
            0,     // Default lock duration
            true,  // Create accessories
            true   // Skip fee (we already collected it)
        ) {
            // Success - continue
        } catch Error(string memory reason) {
            revert AugmentFacetCallFailed(reason);
        } catch {
            revert AugmentFacetCallFailed("Unknown error in assignAugment");
        }
    }
}