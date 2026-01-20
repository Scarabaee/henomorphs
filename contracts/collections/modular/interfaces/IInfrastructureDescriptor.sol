// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {InfrastructureSVGLib} from "../../../diamonds/modular/libraries/InfrastructureSVGLib.sol";

/// @title IInfrastructureDescriptor
/// @notice Interface for Infrastructure Card metadata and SVG generation
/// @dev External contract pattern - descriptor can be upgraded independently
interface IInfrastructureDescriptor {

    /// @notice Metadata structure for infrastructure tokens
    struct InfrastructureMetadata {
        uint256 tokenId;
        InfrastructureSVGLib.InfrastructureType infraType;
        InfrastructureSVGLib.Rarity rarity;
        uint8 efficiencyBonus;
        uint8 capacityBonus;
        uint8 techLevel;
        uint8 durability;
        bool isEquipped;
        uint256 equippedToColony;
    }

    /// @notice Generate complete token URI with metadata and SVG
    /// @param metadata Infrastructure metadata
    /// @return uri Complete data URI with JSON and embedded SVG
    function tokenURI(InfrastructureMetadata memory metadata) external view returns (string memory uri);

    /// @notice Generate SVG image for infrastructure token
    /// @param metadata Infrastructure metadata
    /// @return svg Complete SVG as string
    function generateSVG(InfrastructureMetadata memory metadata) external view returns (string memory svg);

    /// @notice Generate collection metadata URI (OpenSea contractURI)
    /// @return uri Collection metadata data URI
    function contractURI() external view returns (string memory uri);
}
