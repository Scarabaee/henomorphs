// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibCollectionStorage} from "../libraries/LibCollectionStorage.sol";
import {IssueInfo, ItemTier, TierVariant, TraitPack, TraitPackEquipment} from"../libraries/CollectionModel.sol";
import {AccessoryEffects, AccessoryDefinition} from "../libraries/ModularAssetModel.sol";


interface ICollectionDiamond {
 // URI generation
    function generateTokenURI(uint256 collectionId, uint256 tokenId) external view returns (string memory);
    function generateSimpleTokenURI(uint256 collectionId, uint256 tokenId) external view returns (string memory);
    
    // Token lifecycle callbacks
    function onTokenMinted(uint256 collectionId, uint256 tokenId, address owner) external;
    function onTokenTransferred(uint256 collectionId, uint256 tokenId, address from, address to) external;
    function onVariantAssigned(uint256 collectionId, uint256 tokenId, uint8 variant) external;
    function onAugmentChanged(uint256 collectionId, uint256 tokenId, uint8 oldAugment, uint8 newAugment) external;
    
    // Token queries
    function getTokenVariant(uint256 collectionId, uint256 tokenId) external view returns (uint8);
    function getSpecimenEquipment(address specimenCollection, uint256 tokenId) external view returns (TraitPackEquipment memory);
    function hasSpecimenAugment(address specimenCollection, uint256 tokenId) external view returns (bool);
    
    // System status
    function getSystemStatus() external view returns (
        bool isActive,
        uint256 totalCollections,
        uint256 totalAugments,
        uint256 totalAccessories
    );

    /**
     * @notice Assign Augment NFT to Specimen
     * @dev ADD this function signature to ICollectionDiamond interface
     * @param specimenCollection Target specimen collection
     * @param specimenTokenId Target specimen token ID
     * @param augmentCollection Augment NFT collection
     * @param augmentTokenId Augment NFT ID
     * @param lockDuration Lock duration in seconds (0 = default)
     * @param createAccessories Whether to auto-create accessory NFTs
     */
    function assignAugment(
        address specimenCollection,
        uint256 specimenTokenId,
        address augmentCollection,
        uint256 augmentTokenId,
        uint256 lockDuration,
        bool createAccessories
    ) external;

    function altAssignAugment(
        address specimenCollection,
        uint256 specimenTokenId,
        address augmentCollection,
        uint256 augmentTokenId,
        uint256 lockDuration,
        bool createAccessories,
        bool skipFee
    ) external;

    /**
     * @notice Get collection item information
     * @dev ADD this function signature - used in HenomorphsAugmentsV1
     */
    function getCollectionItemInfo(
        uint256 issueId,
        uint8 tier
    ) external view returns (
        IssueInfo memory issueInfo,
        ItemTier memory tierInfo
    );

    /**
     * @notice Get collection configuration
     * @dev ADD this function signature - used in HenomorphsAugmentsV1
     */
    function getCollection(uint256 collectionId) external view returns (
        LibCollectionStorage.CollectionData memory
    );

    /**
     * @notice Get collection defaults
     * @dev ADD this function signature - used in HenomorphsAugmentsV1
     */
    function getCollectionDefaults(uint256 collectionId) external view returns (
        uint8 defaultVariant,
        uint8 defaultTier,
        uint256 defaultIssueId
    );

    /**
     * @notice Shuffle token variant
     * @dev ADD this function signature - used in HenomorphsAugmentsV1
     */
    function shuffleTokenVariant(
        uint256 collectionId,
        uint256 issueId,
        uint8 tier,
        uint256 tokenId
    ) external returns (uint8);

    /**
     * @notice Get collection tier variant
     * @dev ADD this function signature - used in HenomorphsAugmentsV1
     */
    function getCollectionTierVariant(
        uint256 issueId,
        uint8 tier,
        uint8 variant
    ) external view returns (TierVariant memory);

    /**
     * @notice Get assignment details
     * @dev ADD this function signature - used in HenomorphsAugmentsV1
     */
    function getAssignment(
        address collectionAddress,
        uint256 tokenId
    ) external view returns (
        LibCollectionStorage.AugmentAssignment memory
    );

    /**
     * @notice Check if variant is removable
     * @dev ADD this function signature - used in HenomorphsAugmentsV1
     */
    function isVariantRemovable(
        address collectionAddress,
        uint8 variant
    ) external view returns (bool);

    function getExternalSystemAddresses() external view returns (address, address, address);
}