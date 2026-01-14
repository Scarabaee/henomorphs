// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TraitPackEquipment} from "../libraries/HenomorphsModel.sol";

/**
 * @dev Interface for Henomorphs collection contracts
 */
interface ISpecimenCollection is IERC721 {
    /**
     * @dev Returns the variant of a Henomorph token
     * @param tokenId Token ID
     * @return Variant number (0-4)
     */
    function itemVariant(uint256 tokenId) external view returns (uint8);

    function itemEquipments(uint256 tokenId) external view returns (uint8[] memory); // Returns multiple trait pack IDs

    /**
     * @notice Enhanced method for returning complete equipment data
     * @param tokenId Token ID
     * @return Equipment structure with trait pack and accessories information
     */
    function getTokenEquipment(uint256 tokenId) external view returns (TraitPackEquipment memory);
    
    /**
     * @notice Checks if a token has an active trait pack
     * @param tokenId Token ID
     * @return Whether the token has a trait pack
     */
    function hasTraitPack(uint256 tokenId) external view returns (bool);

    function onAugmentAssigned(uint256 tokenId, address augmentCollection, uint256 augmentTokenId) external;
    function onAugmentRemoved(uint256 tokenId, address augmentCollection, uint256 augmentTokenId) external;
}