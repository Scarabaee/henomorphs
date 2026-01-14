// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Calibration, PowerMatrix, ChargeAccessory, TraitPackEquipment} from "../libraries/CollectionModel.sol";

/**
 * @title External System Interfaces
 * @notice Interfaces for integration with Biopod, Chargepod, and Staking systems
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */

interface IBiopod {
    function probeCalibration(uint256 collectionId, uint256 tokenId) external view returns (Calibration memory);
    function hasCalibrationData(uint256 collectionId, uint256 tokenId) external view returns (bool);
}

interface IChargepod {
    function queryPowerMatrix(uint256 collectionId, uint256 tokenId) external view returns (PowerMatrix memory);
    function getTokenAccessories(uint256 collectionId, uint256 tokenId) external view returns (ChargeAccessory[] memory);
    function hasPowerCore(uint256 collectionId, uint256 tokenId) external view returns (bool);
}

// ==================== STAKING SYSTEM ====================

interface IStaking {
    function getTokenStaker(address collectionAddress, uint256 tokenId) external view returns (address staker);
    function isTokenStaker(uint256 collectionId, uint256 tokenId, address staker) external view returns (bool);
    function getStakingInfo(uint256 collectionId, uint256 tokenId) external view returns (
        bool isStaked,
        uint256 stakingStartTime,
        uint256 totalRewards,
        uint8 currentMultiplier
    );
    function isSpecimenStaked(uint256 collectionId, uint256 tokenId) external view returns (bool);
    function getColonyInfo(uint256 collectionId, uint256 tokenId) external view returns (
        bytes32 colony,
        uint8 bonus
    );
}

// ==================== SPECIMEN COLLECTION ====================

interface ISpecimenCollection {
    // ERC721 basics
    function ownerOf(uint256 tokenId) external view returns (address);
    
    // Specimen data
    function itemVariant(uint256 tokenId) external view returns (uint8);
    function itemEquipments(uint256 tokenId) external view returns (uint8[] memory);
    function getTokenEquipment(uint256 tokenId) external view returns (TraitPackEquipment memory);

    function hasTraitPack(uint256 tokenId) external view returns (bool);

    function mintVariant(
        uint256 issueId,
        uint8 tier,
        uint8 variant,
        address recipient,
        uint256 quantity
    ) external returns (uint256[] memory tokenIds);

    // Optional extended mint function for advanced collections
    function mintVariantExtended(
        uint256 issueId,
        uint8 tier,
        uint8 variant,
        address recipient,
        uint256 quantity
    ) external returns (
        uint256[] memory tokenIds,
        uint8 assignedVariant,
        uint256 totalPaid
    );

    function mintWithVariantAssignment(
        uint256 issueId,
        uint8 tier,
        uint8 variant,
        address recipient,
        uint256 quantity,
        address specimenCollection,
        uint256 specimenTokenId
    ) external returns (uint256[] memory tokenIds, uint8[] memory variants);

    function assignVariant(
        uint256 issueId,
        uint8 tier,
        uint256 token,
        uint8 variant
    ) external returns (uint8 assignedVariant);

    /**
     * @notice Reset token variant to base state (variant 0)
     * @param issueId Issue ID
     * @param tier Tier level
     * @param tokenId Token ID to reset
     */
    function resetVariant(uint256 issueId, uint8 tier, uint256 tokenId) external;
    
    function totalItemsSupply(uint256 issueId, uint8 tier) external view returns (uint256);
    
    // Augment callbacks
    function onAugmentAssigned(uint256 tokenId, address augmentCollection, uint256 augmentTokenId) external;
    function onAugmentRemoved(uint256 tokenId, address augmentCollection, uint256 augmentTokenId) external;
}

