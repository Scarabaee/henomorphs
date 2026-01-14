// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AccessControlBase} from "./AccessControlBase.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {LibCollectionStorage} from "../libraries/LibCollectionStorage.sol";

/**
 * @notice Complete recipient status information
 */
struct RecipientStatus {
    bool isEligible;
    uint256 allowedAmount;
    uint256 usedAmount;
    uint256 availableAmount;
    uint256 exemptedAmount;
    uint256 freeAvailable;
    bool merkleVerified;
    uint256 finalAvailable;
}

/**
 * @title WhitelistFacet
 * @notice Production-ready whitelist management for Diamond collections using unified collection system
 * @dev Optimized implementation with single source of truth pattern and improved gas efficiency
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 * @custom:version 2.1.0 - Updated for unified collection system
 */
contract WhitelistFacet is AccessControlBase {
    
    // ==================== EVENTS ====================
    
    event EligibleRecipientsUpdated(uint256 indexed collectionId, uint8 indexed tier, uint256 count);
    event ExemptedQuantitiesUpdated(uint256 indexed collectionId, uint8 indexed tier, uint256 count);
    event EligibleRecipientAdded(uint256 indexed collectionId, uint8 indexed tier, address indexed recipient, uint256 amount);
    event EligibleRecipientRemoved(uint256 indexed collectionId, uint8 indexed tier, address indexed recipient);
    event ExemptedQuantitySet(uint256 indexed collectionId, uint8 indexed tier, address indexed recipient, uint256 amount);
    event ExemptedQuantityRemoved(uint256 indexed collectionId, uint8 indexed tier, address indexed recipient);
    event MerkleRootUpdated(uint256 indexed collectionId, uint8 indexed tier, bytes32 newRoot);
    event WhitelistCleared(uint256 indexed collectionId, uint8 indexed tier, bool resetCounters);
    event UsageRecorded(uint256 indexed collectionId, uint8 indexed tier, address indexed recipient, uint256 amount, uint256 newTotal);
    
    // ==================== CUSTOM ERRORS ====================
    
    error InvalidCallData();
    error InvalidTier(uint8 tier);
    error InvalidMerkleProof();
    error RecipientNotEligible(address recipient);
    error InvalidArrayLengths();
    error WhitelistEmpty(uint8 tier);
    error ZeroAddress();
    error InvalidAmount();
    
    // ==================== ELIGIBLE RECIPIENTS MANAGEMENT ====================
    
    /**
     * @notice Set eligible recipients for a collection tier (batch operation)
     * @dev Replaces any existing recipients with new list
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param recipients Array of recipient addresses
     * @param amounts Array of allowed amounts per recipient
     */
    function setEligibleRecipients(
        uint256 collectionId,
        uint8 tier,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external onlyAuthorized whenNotPaused {
        
        if (recipients.length != amounts.length) {
            revert InvalidArrayLengths();
        }
        
        if (recipients.length == 0) {
            revert InvalidCallData();
        }
        
        // Validate collection exists using unified system
        if (!LibCollectionStorage.collectionExists(collectionId)) {
            revert CollectionNotFound(collectionId);
        }
        
        // Validate inputs before processing
        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i] == address(0)) {
                revert ZeroAddress();
            }
        }
        
        // Process all recipients
        for (uint256 i = 0; i < recipients.length; i++) {
            if (amounts[i] > 0) {
                LibCollectionStorage.addEligibleRecipient(collectionId, tier, recipients[i], amounts[i]);
                emit EligibleRecipientAdded(collectionId, tier, recipients[i], amounts[i]);
            } else {
                // Remove if amount is 0
                if (LibCollectionStorage.eligibleRecipientExists(collectionId, tier, recipients[i])) {
                    LibCollectionStorage.removeEligibleRecipient(collectionId, tier, recipients[i]);
                    emit EligibleRecipientRemoved(collectionId, tier, recipients[i]);
                }
            }
        }
        
        emit EligibleRecipientsUpdated(collectionId, tier, recipients.length);
    }
    
    /**
     * @notice Add single eligible recipient
     * @dev Adds or updates existing recipient's allowed amount
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param recipient Recipient address
     * @param amount Allowed amount
     */
    function addEligibleRecipient(
        uint256 collectionId,
        uint8 tier,
        address recipient,
        uint256 amount
    ) external onlyAuthorized whenNotPaused {
        
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        
        if (amount == 0) {
            revert InvalidAmount();
        }
        
        // Validate collection exists using unified system
        if (!LibCollectionStorage.collectionExists(collectionId)) {
            revert CollectionNotFound(collectionId);
        }
        
        LibCollectionStorage.addEligibleRecipient(collectionId, tier, recipient, amount);
        emit EligibleRecipientAdded(collectionId, tier, recipient, amount);
    }
    
    /**
     * @notice Remove eligible recipient
     * @dev Removes recipient from whitelist and enumeration list
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param recipient Recipient address
     */
    function removeEligibleRecipient(
        uint256 collectionId,
        uint8 tier,
        address recipient
    ) external onlyAuthorized whenNotPaused {
        
        if (!LibCollectionStorage.eligibleRecipientExists(collectionId, tier, recipient)) {
            revert RecipientNotEligible(recipient);
        }
        
        LibCollectionStorage.removeEligibleRecipient(collectionId, tier, recipient);
        emit EligibleRecipientRemoved(collectionId, tier, recipient);
    }
    
    /**
     * @notice Clear all eligible recipients for collection tier
     * @dev Removes all recipients and optionally resets usage counters
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param resetCounters Whether to reset usage counters
     */
    function clearEligibleRecipients(
        uint256 collectionId,
        uint8 tier,
        bool resetCounters
    ) external onlyAuthorized whenNotPaused {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        address[] memory recipients = cs.eligibleRecipientsList[collectionId][tier];
        
        // Create a copy of the list before clearing to avoid array modification during iteration
        uint256 recipientCount = recipients.length;
        
        for (uint256 i = 0; i < recipientCount; i++) {
            if (i < cs.eligibleRecipientsList[collectionId][tier].length) {
                address recipient = recipients[i];
                LibCollectionStorage.removeEligibleRecipient(collectionId, tier, recipient);
                
                if (resetCounters) {
                    delete cs.usageCounters[recipient][collectionId][tier];
                }
                
                emit EligibleRecipientRemoved(collectionId, tier, recipient);
            }
        }
        
        emit WhitelistCleared(collectionId, tier, resetCounters);
    }
    
    // ==================== EXEMPTED QUANTITIES MANAGEMENT ====================
    
    /**
     * @notice Set exempted quantities for recipients (free allocations)
     * @dev Recipients with exempted quantities can mint for free
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param recipients Array of recipient addresses
     * @param amounts Array of exempted amounts per recipient
     */
    function setExemptedQuantities(
        uint256 collectionId,
        uint8 tier,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external onlyAuthorized whenNotPaused {
        
        if (recipients.length != amounts.length) {
            revert InvalidArrayLengths();
        }
        
        if (recipients.length == 0) {
            revert InvalidCallData();
        }
        
        // Validate collection exists using unified system
        if (!LibCollectionStorage.collectionExists(collectionId)) {
            revert CollectionNotFound(collectionId);
        }
        
        // Validate inputs
        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i] == address(0)) {
                revert ZeroAddress();
            }
        }
        
        // Process all recipients
        for (uint256 i = 0; i < recipients.length; i++) {
            if (amounts[i] > 0) {
                LibCollectionStorage.addExemptedQuantity(collectionId, tier, recipients[i], amounts[i]);
                emit ExemptedQuantitySet(collectionId, tier, recipients[i], amounts[i]);
            } else {
                // Remove if amount is 0
                if (LibCollectionStorage.exemptedQuantityExists(collectionId, tier, recipients[i])) {
                    LibCollectionStorage.removeExemptedQuantity(collectionId, tier, recipients[i]);
                    emit ExemptedQuantityRemoved(collectionId, tier, recipients[i]);
                }
            }
        }
        
        emit ExemptedQuantitiesUpdated(collectionId, tier, recipients.length);
    }
    
    /**
     * @notice Add single exempted quantity
     * @dev Adds or updates existing recipient's exempted amount
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param recipient Recipient address
     * @param amount Exempted amount
     */
    function addExemptedQuantity(
        uint256 collectionId,
        uint8 tier,
        address recipient,
        uint256 amount
    ) external onlyAuthorized whenNotPaused {
        
        if (recipient == address(0)) {
            revert ZeroAddress();
        }
        
        if (amount == 0) {
            revert InvalidAmount();
        }
        
        // Validate collection exists using unified system
        if (!LibCollectionStorage.collectionExists(collectionId)) {
            revert CollectionNotFound(collectionId);
        }
        
        LibCollectionStorage.addExemptedQuantity(collectionId, tier, recipient, amount);
        emit ExemptedQuantitySet(collectionId, tier, recipient, amount);
    }
    
    /**
     * @notice Remove exempted quantity
     * @dev Removes recipient's exempted amount
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param recipient Recipient address
     */
    function removeExemptedQuantity(
        uint256 collectionId,
        uint8 tier,
        address recipient
    ) external onlyAuthorized whenNotPaused {
        
        if (!LibCollectionStorage.exemptedQuantityExists(collectionId, tier, recipient)) {
            revert RecipientNotEligible(recipient);
        }
        
        LibCollectionStorage.removeExemptedQuantity(collectionId, tier, recipient);
        emit ExemptedQuantityRemoved(collectionId, tier, recipient);
    }
    
    /**
     * @notice Clear all exempted quantities for collection tier
     * @dev Removes all exempted quantities for the specified collection tier
     * @param collectionId Collection ID
     * @param tier Tier level
     */
    function clearExemptedQuantities(
        uint256 collectionId,
        uint8 tier
    ) external onlyAuthorized whenNotPaused {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        address[] memory recipients = cs.exemptedQuantitiesList[collectionId][tier];
        uint256 recipientCount = recipients.length;
        
        for (uint256 i = 0; i < recipientCount; i++) {
            if (i < cs.exemptedQuantitiesList[collectionId][tier].length) {
                address recipient = recipients[i];
                LibCollectionStorage.removeExemptedQuantity(collectionId, tier, recipient);
                emit ExemptedQuantityRemoved(collectionId, tier, recipient);
            }
        }
    }
    
    // ==================== MERKLE TREE MANAGEMENT ====================
    
    /**
     * @notice Set Merkle root for collection tier-based verification
     * @dev Used for additional verification layer with Merkle proofs
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param newRoot New Merkle root
     */
    function setMerkleRoot(
        uint256 collectionId,
        uint8 tier,
        bytes32 newRoot
    ) external onlyAuthorized whenNotPaused {
        
        // Validate collection exists using unified system
        if (!LibCollectionStorage.collectionExists(collectionId)) {
            revert CollectionNotFound(collectionId);
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        cs.merkleRoots[collectionId][tier] = newRoot;
        emit MerkleRootUpdated(collectionId, tier, newRoot);
    }
    
    /**
     * @notice Verify Merkle proof for recipient
     * @dev Verifies if recipient is included in Merkle tree
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param recipient Recipient address
     * @param seed Additional seed for leaf generation
     * @param merkleProof Merkle proof
     * @return valid Whether proof is valid
     */
    function verifyMerkleProof(
        uint256 collectionId,
        uint8 tier,
        address recipient,
        uint256 seed,
        bytes32[] calldata merkleProof
    ) external view returns (bool valid) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        bytes32 root = cs.merkleRoots[collectionId][tier];
        
        if (root == bytes32(0)) {
            return true; // No Merkle verification required
        }
        
        bytes32 leaf = keccak256(abi.encodePacked(recipient, seed));
        return MerkleProof.verify(merkleProof, root, leaf);
    }
    
    // ==================== USAGE TRACKING ====================
    
    /**
     * @notice Record usage for recipient
     * @dev Called by other facets to track whitelist usage. Uses onlyAuthorized for inter-facet calls
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param recipient Recipient address
     * @param amount Amount used
     */
    function recordUsage(uint256 collectionId, uint8 tier, address recipient, uint256 amount) external onlySystem whenNotPaused {
        if (amount == 0) return; // Skip zero amounts
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint256 previousUsage = cs.usageCounters[recipient][collectionId][tier];
        uint256 newUsage = previousUsage + amount;
        
        cs.usageCounters[recipient][collectionId][tier] = newUsage;
        
        emit UsageRecorded(collectionId, tier, recipient, amount, newUsage);
    }
        
    /**
     * @notice Reset usage counter for recipient
     * @dev Admin function to reset specific recipient's usage
     * @param collectionId Collection ID (for event logging)
     * @param tier Tier level
     * @param recipient Recipient address
     */
    function resetUsageCounter(
        uint256 collectionId,
        uint8 tier,
        address recipient
    ) external onlyAuthorized whenNotPaused {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        uint256 previousUsage = cs.usageCounters[recipient][collectionId][tier];
        delete cs.usageCounters[recipient][collectionId][tier];
        
        emit UsageRecorded(collectionId, tier, recipient, previousUsage, 0);
    }
    
    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @notice Check if recipient is eligible and get allowed amount
     * @dev Returns comprehensive eligibility information
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param recipient Recipient address
     * @return eligible Whether recipient is eligible
     * @return allowedAmount Total allowed amount
     * @return usedAmount Amount already used
     * @return availableAmount Remaining available amount
     */
    function checkEligibility(
        uint256 collectionId,
        uint8 tier,
        address recipient
    ) external view returns (
        bool eligible,
        uint256 allowedAmount,
        uint256 usedAmount,
        uint256 availableAmount
    ) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        allowedAmount = cs.eligibleRecipients[collectionId][tier][recipient];
        eligible = allowedAmount > 0;
        
        if (!eligible) {
            return (false, 0, 0, 0);
        }
        
        usedAmount = cs.usageCounters[recipient][collectionId][tier];
        
        if (usedAmount >= allowedAmount) {
            availableAmount = 0;
        } else {
            availableAmount = allowedAmount - usedAmount;
        }
        
        return (eligible, allowedAmount, usedAmount, availableAmount);
    }
    
    /**
     * @notice Get exempted quantity for recipient
     * @dev Returns information about free allocation
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param recipient Recipient address
     * @return exemptedAmount Amount that can be used for free
     * @return usedAmount Amount already used
     * @return freeAvailable Remaining free amount
     */
    function getExemptedQuantity(
        uint256 collectionId,
        uint8 tier,
        address recipient
    ) external view returns (
        uint256 exemptedAmount,
        uint256 usedAmount,
        uint256 freeAvailable
    ) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        exemptedAmount = cs.exemptedQuantities[collectionId][tier][recipient];
        if (exemptedAmount == 0) {
            return (0, 0, 0);
        }
        
        usedAmount = cs.usageCounters[recipient][collectionId][tier];
        
        if (usedAmount >= exemptedAmount) {
            freeAvailable = 0;
        } else {
            freeAvailable = exemptedAmount - usedAmount;
        }
        
        return (exemptedAmount, usedAmount, freeAvailable);
    }
    
    /**
     * @notice Get current usage for recipient
     * @dev Returns total amount used by recipient in collection tier
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param recipient Recipient address
     * @return used Amount used by recipient
     */
    function getUsage(
        uint256 collectionId,
        uint8 tier,
        address recipient
    ) external view returns (uint256 used) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        return cs.usageCounters[recipient][collectionId][tier];
    }
    
    /**
     * @notice Get Merkle root for collection tier
     * @dev Returns current Merkle root for verification
     * @param collectionId Collection ID
     * @param tier Tier level
     * @return root Current Merkle root
     */
    function getMerkleRoot(uint256 collectionId, uint8 tier) external view returns (bytes32 root) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        return cs.merkleRoots[collectionId][tier];
    }
    
    /**
     * @notice Get all eligible recipients for collection tier
     * @dev Returns complete list with amounts for enumeration
     * @param collectionId Collection ID
     * @param tier Tier level
     * @return recipients Array of eligible addresses
     * @return amounts Array of allowed amounts
     */
    function getAllEligibleRecipients(
        uint256 collectionId,
        uint8 tier
    ) external view returns (
        address[] memory recipients,
        uint256[] memory amounts
    ) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        recipients = cs.eligibleRecipientsList[collectionId][tier];
        amounts = new uint256[](recipients.length);
        
        for (uint256 i = 0; i < recipients.length; i++) {
            amounts[i] = cs.eligibleRecipients[collectionId][tier][recipients[i]];
        }
        
        return (recipients, amounts);
    }
    
    /**
     * @notice Get all exempted quantities for collection tier
     * @dev Returns complete list with amounts for enumeration
     * @param collectionId Collection ID
     * @param tier Tier level
     * @return recipients Array of exempted addresses
     * @return amounts Array of exempted amounts
     */
    function getAllExemptedQuantities(
        uint256 collectionId,
        uint8 tier
    ) external view returns (
        address[] memory recipients,
        uint256[] memory amounts
    ) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        recipients = cs.exemptedQuantitiesList[collectionId][tier];
        amounts = new uint256[](recipients.length);
        
        for (uint256 i = 0; i < recipients.length; i++) {
            amounts[i] = cs.exemptedQuantities[collectionId][tier][recipients[i]];
        }
        
        return (recipients, amounts);
    }
    
    /**
     * @notice Get whitelist statistics for collection tier
     * @dev Returns summary statistics for monitoring
     * @param collectionId Collection ID
     * @param tier Tier level
     * @return eligibleCount Number of eligible recipients
     * @return exemptedCount Number of exempted recipients
     * @return hasMerkleRoot Whether Merkle root is set
     */
    function getWhitelistStats(
        uint256 collectionId,
        uint8 tier
    ) external view returns (
        uint256 eligibleCount,
        uint256 exemptedCount,
        bool hasMerkleRoot
    ) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        return (
            cs.eligibleRecipientsList[collectionId][tier].length,
            cs.exemptedQuantitiesList[collectionId][tier].length,
            cs.merkleRoots[collectionId][tier] != bytes32(0)
        );
    }
    
    /**
     * @notice Get whitelist summary for collection tier
     * @dev Comprehensive overview of whitelist configuration
     * @param collectionId Collection ID
     * @param tier Tier level
     * @return hasWhitelist Whether whitelist exists
     * @return hasMerkleRoot Whether Merkle root is set
     * @return hasExemptions Whether exemptions exist
     * @return whitelistCount Number of whitelisted addresses
     * @return exemptedCount Number of exempted addresses
     * @return merkleRoot Current Merkle root
     */
    function getWhitelistSummary(uint256 collectionId, uint8 tier) external view returns (
        bool hasWhitelist,
        bool hasMerkleRoot,
        bool hasExemptions,
        uint256 whitelistCount,
        uint256 exemptedCount,
        bytes32 merkleRoot
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        whitelistCount = LibCollectionStorage.getEligibleRecipientsCount(collectionId, tier);
        exemptedCount = LibCollectionStorage.getExemptedQuantitiesCount(collectionId, tier);
        merkleRoot = cs.merkleRoots[collectionId][tier];
        
        hasWhitelist = whitelistCount > 0;
        hasMerkleRoot = merkleRoot != bytes32(0);
        hasExemptions = exemptedCount > 0;
        
        return (hasWhitelist, hasMerkleRoot, hasExemptions, whitelistCount, exemptedCount, merkleRoot);
    }
    
    /**
     * @notice Simple availability check for quick access verification
     * @dev Returns true if user has ANY form of access (whitelist, exempted, or fallback)
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param recipient Recipient address
     * @return hasAccess Whether user has any form of access
     */
    function hasAnyAccess(uint256 collectionId, uint8 tier, address recipient) external view returns (bool hasAccess) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Check whitelist access
        uint256 whitelistAmount = cs.eligibleRecipients[collectionId][tier][recipient];
        uint256 usedAmount = cs.usageCounters[recipient][collectionId][tier];
        
        if (whitelistAmount > usedAmount) {
            return true;
        }
        
        // Check exempted access
        uint256 exemptedAmount = cs.exemptedQuantities[collectionId][tier][recipient];
        if (exemptedAmount > usedAmount) {
            return true;
        }
        
        // If no whitelist exists, user might have fallback access
        uint256 whitelistCount = LibCollectionStorage.getEligibleRecipientsCount(collectionId, tier);
        if (whitelistCount == 0) {
            return true; // No restrictions, fallback to freeMints in other facets
        }
        
        return false;
    }
    
    /**
     * @notice Enhanced recipient status calculation - PRODUCTION READY
     * @dev Fixed finalAvailable calculation to handle empty whitelist properly with unified collection system
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param recipient Recipient address
     * @param seed Seed for Merkle verification
     * @param merkleProof Merkle proof (can be empty)
     * @return status Complete status information
     */
    function getRecipientStatus(
        uint256 collectionId,
        uint8 tier,
        address recipient,
        uint256 seed,
        bytes32[] calldata merkleProof
    ) external view returns (RecipientStatus memory status) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Check whitelist eligibility
        status.allowedAmount = cs.eligibleRecipients[collectionId][tier][recipient];
        status.isEligible = status.allowedAmount > 0;
        status.usedAmount = cs.usageCounters[recipient][collectionId][tier];
        
        // Calculate remaining whitelist allocation
        if (status.usedAmount >= status.allowedAmount) {
            status.availableAmount = 0;
        } else {
            status.availableAmount = status.allowedAmount - status.usedAmount;
        }
        
        // Check exempted quantities (free allocations)
        status.exemptedAmount = cs.exemptedQuantities[collectionId][tier][recipient];
        
        if (status.usedAmount >= status.exemptedAmount) {
            status.freeAvailable = 0;
        } else {
            status.freeAvailable = status.exemptedAmount - status.usedAmount;
        }
        
        // Merkle verification
        if (cs.merkleRoots[collectionId][tier] != bytes32(0)) {
            bytes32 leaf = keccak256(abi.encodePacked(recipient, seed));
            status.merkleVerified = MerkleProof.verify(merkleProof, cs.merkleRoots[collectionId][tier], leaf);
        } else {
            status.merkleVerified = true; // No Merkle verification required
        }
        
        // FIXED: finalAvailable calculation
        uint256 whitelistCount = LibCollectionStorage.getEligibleRecipientsCount(collectionId, tier);
        
        if (whitelistCount == 0) {
            // No whitelist exists - everyone can access if Merkle passes (or no Merkle required)
            status.finalAvailable = status.merkleVerified ? type(uint256).max : 0;
        } else {
            // Whitelist exists - only eligible users get their allocation if Merkle verified
            status.finalAvailable = (status.merkleVerified && status.isEligible) ? status.availableAmount : 0;
        }
        
        return status;
    }

    /**
     * @notice Get effective tier for collection
     * @dev Helper function to determine tier, with fallback for unified collection system
     * @param collectionId Collection ID
     * @return effectiveTier The tier to use
     */
    function _getEffectiveTier(uint256 collectionId) internal view returns (uint8) {
        // Get collection info using unified system
        (, uint8 defaultTier, bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        
        if (exists && defaultTier > 0) {
            return defaultTier;
        }
        
        return 1; // System fallback
    }
}