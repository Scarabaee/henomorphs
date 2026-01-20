// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ResourceSVGLib} from "../../../diamonds/modular/libraries/ResourceSVGLib.sol";

/// @title IResourceDescriptor
/// @notice Interface for Resource Card metadata and SVG generation
/// @dev External contract pattern - descriptor can be upgraded independently
interface IResourceDescriptor {

    /// @notice Metadata structure for resource tokens
    struct ResourceMetadata {
        uint256 tokenId;
        ResourceSVGLib.ResourceType resourceType;
        ResourceSVGLib.Rarity rarity;
        uint8 yieldBonus;
        uint8 qualityLevel;
        uint16 stackSize;
        uint16 maxStack;
        bool isStaked;
        uint256 stakedToNode;
    }

    /// @notice Generate complete token URI with metadata and SVG
    /// @param metadata Resource metadata
    /// @return uri Complete data URI with JSON and embedded SVG
    function tokenURI(ResourceMetadata memory metadata) external view returns (string memory uri);

    /// @notice Generate SVG image for resource token
    /// @param metadata Resource metadata
    /// @return svg Complete SVG as string
    function generateSVG(ResourceMetadata memory metadata) external view returns (string memory svg);

    /// @notice Generate collection metadata URI (OpenSea contractURI)
    /// @return uri Collection metadata data URI
    function contractURI() external view returns (string memory uri);
}
