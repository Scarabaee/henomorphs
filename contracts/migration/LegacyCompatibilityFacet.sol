// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibDiamond} from "../diamonds/shared/libraries/LibDiamond.sol";

/**
 * @title LegacyCompatibilityFacet
 * @notice Provides backward-compatible function signatures for Genesis/AugmentsV1 NFT contracts
 * @dev Maps ItemType-based signatures to collection-centric storage in hms-protocol-v1 diamond
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 * @custom:version 1.0.0
 *
 * This facet is designed to be deployed on the hms-protocol-v1 diamond to provide
 * compatibility with existing NFT contracts (HenomorphsGenesis.sol, HenomorphsAugmentsV1.sol)
 * that use ItemType-based function signatures.
 */

// ItemType enum from pcs-nft-v4 for signature compatibility
enum ItemType {
    Thaler,    // 0 - Main items
    Stamp,     // 1 - Stamps
    Vignette,  // 2 - Genesis uses this
    Envelope,  // 3 - Envelopes
    Folder,    // 4 - Folders
    Card,      // 5 - Cards
    Other      // 6 - AugmentsV1 uses this
}

// Re-declare necessary structs for interface compatibility
struct IssueInfo {
    uint256 issueId;
    uint256 collectionId;
    string designation;
    address beneficiary;
    uint256 tiersCount;
    string baseUri;
    bool isFixed;
    uint256 issueTimestamp;
    uint8 issuePhase;
}

struct ItemTier {
    uint8 tier;
    uint256 collectionId;
    string tierUri;
    uint256 maxSupply;
    uint256 price;
    uint256 maxMints;
    bool isMintable;
    bool isSwappable;
    bool isBoostable;
    uint256 revealTimestamp;
    uint256 offset;
    uint256 limit;
    bool isSequential;
    uint256 variantsCount;
    uint256 features;
}

struct TierVariant {
    uint8 variant;
    uint8 tier;
    uint256 collectionId;
    string name;
    string description;
    string imageURI;
    uint256 maxSupply;
    uint256 currentSupply;
    uint256 mintPrice;
    bool active;
}

struct AugmentAssignment {
    address augmentCollection;
    uint256 augmentTokenId;
    address specimenCollection;
    uint256 specimenTokenId;
    uint8 tier;
    uint8 specimenVariant;
    uint256 assignmentTime;
    uint256 unlockTime;
    bool active;
    uint256 totalFeePaid;
    uint8[] assignedAccessories;
    uint8 augmentVariant;
}

/**
 * @dev Interface for the new diamond's existing facets
 */
interface INewDiamondFacets {
    function getCollectionItemInfo(uint256 issueId, uint8 tier)
        external view returns (IssueInfo memory, ItemTier memory);

    function shuffleTokenVariant(uint256 collectionId, uint256 issueId, uint8 tier, uint256 tokenId)
        external returns (uint8);

    function getCollectionTierVariant(uint256 issueId, uint8 tier, uint8 variant)
        external view returns (TierVariant memory);

    function getAssignment(address collectionAddress, uint256 tokenId)
        external view returns (AugmentAssignment memory);

    function isVariantRemovable(address collectionAddress, uint8 variant)
        external view returns (bool);
}

contract LegacyCompatibilityFacet {

    // ==================== STORAGE ====================

    bytes32 constant LEGACY_STORAGE_POSITION = keccak256("diamond.legacy.compatibility.storage.v1");

    struct LegacyStorage {
        // Mapping: (ItemType, issueId) => collectionId
        // Set during migration to route legacy calls to correct collections
        mapping(uint8 => mapping(uint256 => uint256)) itemTypeIssueToCollection;

        // Mapping: collectionAddress => collectionId
        mapping(address => uint256) collectionAddressToId;

        // Admin role tracking
        mapping(address => bool) operators;

        // Configuration status
        bool initialized;
    }

    function legacyStorage() internal pure returns (LegacyStorage storage ls) {
        bytes32 position = LEGACY_STORAGE_POSITION;
        assembly { ls.slot := position }
    }

    // ==================== ERRORS ====================

    error NotOperator();
    error LegacyMappingNotConfigured(uint8 itemType, uint256 issueId);
    error AlreadyInitialized();
    error InvalidAddress();
    error InvalidParameters();

    // ==================== EVENTS ====================

    event LegacyMappingConfigured(uint8 indexed itemType, uint256 indexed issueId, uint256 collectionId);
    event CollectionMappingConfigured(address indexed collectionAddress, uint256 collectionId);
    event OperatorUpdated(address indexed operator, bool status);
    event LegacyFacetInitialized(address indexed initializer);

    // ==================== MODIFIERS ====================

    modifier onlyOperator() {
        LegacyStorage storage ls = legacyStorage();
        if (!ls.operators[msg.sender] && msg.sender != LibDiamond.contractOwner()) {
            revert NotOperator();
        }
        _;
    }

    // ==================== INITIALIZATION ====================

    /**
     * @notice Initialize the legacy compatibility facet
     * @dev Should be called once after diamond cut
     */
    function initializeLegacyFacet() external {
        LegacyStorage storage ls = legacyStorage();

        if (ls.initialized) revert AlreadyInitialized();

        ls.operators[msg.sender] = true;
        ls.initialized = true;

        emit LegacyFacetInitialized(msg.sender);
    }

    // ==================== ADMIN FUNCTIONS ====================

    /**
     * @notice Configure legacy ItemType -> Collection mapping
     * @dev Called during migration to set up routing
     * @param itemType ItemType enum value (e.g., 2 for Vignette/Genesis, 6 for Other/AugmentsV1)
     * @param issueId Issue ID from the old system
     * @param collectionId Collection ID in the new diamond
     */
    function configureLegacyMapping(
        uint8 itemType,
        uint256 issueId,
        uint256 collectionId
    ) external onlyOperator {
        if (collectionId == 0) revert InvalidParameters();

        LegacyStorage storage ls = legacyStorage();
        ls.itemTypeIssueToCollection[itemType][issueId] = collectionId;

        emit LegacyMappingConfigured(itemType, issueId, collectionId);
    }

    /**
     * @notice Configure batch of legacy mappings
     * @dev Efficient batch configuration during migration
     * @param itemTypes Array of ItemType enum values
     * @param issueIds Array of issue IDs
     * @param collectionIds Array of collection IDs
     */
    function configureLegacyMappingBatch(
        uint8[] calldata itemTypes,
        uint256[] calldata issueIds,
        uint256[] calldata collectionIds
    ) external onlyOperator {
        if (itemTypes.length != issueIds.length || issueIds.length != collectionIds.length) {
            revert InvalidParameters();
        }

        LegacyStorage storage ls = legacyStorage();

        for (uint256 i = 0; i < itemTypes.length; i++) {
            if (collectionIds[i] == 0) revert InvalidParameters();
            ls.itemTypeIssueToCollection[itemTypes[i]][issueIds[i]] = collectionIds[i];
            emit LegacyMappingConfigured(itemTypes[i], issueIds[i], collectionIds[i]);
        }
    }

    /**
     * @notice Configure collection address to ID mapping
     * @dev Used for functions that take collection address instead of ID
     * @param collectionAddress Address of the collection contract
     * @param collectionId Collection ID in the new diamond
     */
    function configureCollectionMapping(
        address collectionAddress,
        uint256 collectionId
    ) external onlyOperator {
        if (collectionAddress == address(0)) revert InvalidAddress();
        if (collectionId == 0) revert InvalidParameters();

        LegacyStorage storage ls = legacyStorage();
        ls.collectionAddressToId[collectionAddress] = collectionId;

        emit CollectionMappingConfigured(collectionAddress, collectionId);
    }

    /**
     * @notice Update operator status
     * @param operator Address to update
     * @param status New status
     */
    function setOperator(address operator, bool status) external onlyOperator {
        if (operator == address(0)) revert InvalidAddress();

        LegacyStorage storage ls = legacyStorage();
        ls.operators[operator] = status;

        emit OperatorUpdated(operator, status);
    }

    // ==================== LEGACY COMPATIBLE FUNCTIONS ====================

    /**
     * @notice Legacy getCollectionItemInfo with ItemType parameter
     * @dev Routes to collection-centric storage using mapping
     * @param itemType ItemType enum from old system
     * @param issueId Issue ID
     * @param tier Tier number
     * @return issueInfo Issue information
     * @return tierInfo Tier information
     */
    function getCollectionItemInfo(
        ItemType itemType,
        uint256 issueId,
        uint8 tier
    ) external view returns (IssueInfo memory issueInfo, ItemTier memory tierInfo) {
        LegacyStorage storage ls = legacyStorage();
        uint256 collectionId = ls.itemTypeIssueToCollection[uint8(itemType)][issueId];

        if (collectionId == 0) {
            revert LegacyMappingNotConfigured(uint8(itemType), issueId);
        }

        // Delegate to new signature
        return INewDiamondFacets(address(this)).getCollectionItemInfo(issueId, tier);
    }

    /**
     * @notice Legacy shuffleTokenVariant with ItemType parameter
     * @param collectionId Collection ID
     * @param itemType ItemType enum (ignored, kept for signature compatibility)
     * @param issueId Issue ID
     * @param tier Tier number
     * @param tokenId Token ID
     * @return variant Assigned variant
     */
    function shuffleTokenVariant(
        uint256 collectionId,
        ItemType itemType,
        uint256 issueId,
        uint8 tier,
        uint256 tokenId
    ) external returns (uint8) {
        // ItemType is ignored - we use collectionId directly
        // Validate that the mapping exists for this ItemType/issueId pair
        LegacyStorage storage ls = legacyStorage();
        uint256 mappedCollectionId = ls.itemTypeIssueToCollection[uint8(itemType)][issueId];

        // Use provided collectionId if mapping doesn't exist (backwards compat)
        uint256 effectiveCollectionId = mappedCollectionId != 0 ? mappedCollectionId : collectionId;

        // Delegate to new signature
        return INewDiamondFacets(address(this)).shuffleTokenVariant(
            effectiveCollectionId,
            issueId,
            tier,
            tokenId
        );
    }

    /**
     * @notice Legacy getCollectionTierVariant with ItemType parameter
     * @param itemType ItemType enum from old system
     * @param issueId Issue ID
     * @param tier Tier number
     * @param variant Variant number
     * @return tierVariant Tier variant information
     */
    function getCollectionTierVariant(
        ItemType itemType,
        uint256 issueId,
        uint8 tier,
        uint8 variant
    ) external view returns (TierVariant memory) {
        // Validate mapping exists
        LegacyStorage storage ls = legacyStorage();
        uint256 collectionId = ls.itemTypeIssueToCollection[uint8(itemType)][issueId];

        if (collectionId == 0) {
            revert LegacyMappingNotConfigured(uint8(itemType), issueId);
        }

        // Delegate to new signature
        return INewDiamondFacets(address(this)).getCollectionTierVariant(issueId, tier, variant);
    }

    // ==================== VIEW FUNCTIONS ====================

    /**
     * @notice Get collection ID for ItemType/issueId pair
     * @param itemType ItemType enum value
     * @param issueId Issue ID
     * @return collectionId Mapped collection ID (0 if not configured)
     */
    function getLegacyCollectionId(uint8 itemType, uint256 issueId) external view returns (uint256) {
        return legacyStorage().itemTypeIssueToCollection[itemType][issueId];
    }

    /**
     * @notice Get collection ID for collection address
     * @param collectionAddress Collection contract address
     * @return collectionId Mapped collection ID (0 if not configured)
     */
    function getCollectionIdByAddress(address collectionAddress) external view returns (uint256) {
        return legacyStorage().collectionAddressToId[collectionAddress];
    }

    /**
     * @notice Check if an address is an operator
     * @param operator Address to check
     * @return isOperator Whether address is an operator
     */
    function isOperator(address operator) external view returns (bool) {
        LegacyStorage storage ls = legacyStorage();
        return ls.operators[operator] || operator == LibDiamond.contractOwner();
    }

    /**
     * @notice Check if facet is initialized
     * @return initialized Whether facet is initialized
     */
    function isLegacyFacetInitialized() external view returns (bool) {
        return legacyStorage().initialized;
    }

    // ==================== MIGRATION ADMIN FUNCTIONS ====================

    /**
     * @notice Admin function to recreate assignments during migration
     * @dev Preserves original timestamps for historical accuracy
     * @param specimenCollection Specimen collection address
     * @param specimenTokenId Specimen token ID
     * @param augmentCollection Augment collection address
     * @param augmentTokenId Augment token ID
     * @param unlockTime Original unlock time
     * @param originalAssignmentTime Original assignment timestamp
     * @param augmentVariant Augment variant
     */
    function adminRecreateAssignment(
        address specimenCollection,
        uint256 specimenTokenId,
        address augmentCollection,
        uint256 augmentTokenId,
        uint256 unlockTime,
        uint256 originalAssignmentTime,
        uint8 augmentVariant
    ) external onlyOperator {
        // This function should be implemented in the main AugmentFacet
        // Here we just provide the interface for migration scripts
        // The actual implementation would call internal storage functions

        // For now, we emit an event to track the call
        emit AssignmentRecreated(
            specimenCollection,
            specimenTokenId,
            augmentCollection,
            augmentTokenId,
            originalAssignmentTime,
            augmentVariant
        );
    }

    /**
     * @notice Bulk import token variants
     * @param collectionId Collection ID
     * @param issueId Issue ID
     * @param tier Tier number
     * @param tokenIds Array of token IDs
     * @param variants Array of variant values
     */
    function adminBulkSetTokenVariants(
        uint256 collectionId,
        uint256 issueId,
        uint8 tier,
        uint256[] calldata tokenIds,
        uint8[] calldata variants
    ) external onlyOperator {
        if (tokenIds.length != variants.length) revert InvalidParameters();

        // This would call internal storage to set variants
        // Implementation depends on the target diamond's storage structure

        emit TokenVariantsBulkSet(collectionId, issueId, tier, tokenIds.length);
    }

    // ==================== MIGRATION EVENTS ====================

    event AssignmentRecreated(
        address indexed specimenCollection,
        uint256 indexed specimenTokenId,
        address augmentCollection,
        uint256 augmentTokenId,
        uint256 originalAssignmentTime,
        uint8 augmentVariant
    );

    event TokenVariantsBulkSet(
        uint256 indexed collectionId,
        uint256 indexed issueId,
        uint8 tier,
        uint256 count
    );
}
