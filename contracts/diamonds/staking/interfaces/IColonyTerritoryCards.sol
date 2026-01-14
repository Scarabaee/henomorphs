// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title IColonyTerritoryCards
 * @notice Interface for Colony Territory Cards NFT contract
 * @dev Used by TerritoryNFTIntegrationFacet to communicate with NFT contract
 */
interface IColonyTerritoryCards {
    
    enum TerritoryType { ZicoMine, TradeHub, Fortress, Observatory, Sanctuary }
    enum Rarity { Common, Uncommon, Rare, Epic, Legendary }

    struct TerritoryTraits {
        TerritoryType territoryType;
        Rarity rarity;
        uint8 productionBonus;
        uint8 defenseBonus;
        uint8 techLevel;
        uint16 chickenPopulation;
        uint8 colonyWarsType;
    }

    // Minting
    function mintTerritory(
        address to, 
        TerritoryType territoryType, 
        Rarity rarity
    ) external returns (uint256);

    function batchMintTerritories(
        address to, 
        TerritoryType[] calldata types, 
        Rarity[] calldata rarities
    ) external returns (uint256[] memory);

    // Territory management
    function assignTerritoryToColony(uint256 tokenId, uint256 colonyId) external;
    function activateTerritory(uint256 tokenId, uint256 colonyId) external;
    function deactivateTerritory(uint256 tokenId, uint256 colonyId) external;

    // Transfer management (Model D - Conditional Transfer)
    function approveTransfer(uint256 tokenId, address to) external;
    function rejectTransfer(uint256 tokenId, address to, string calldata reason) external;
    function clearTransferApproval(uint256 tokenId) external;

    // View functions
    function getTerritoryTraits(uint256 tokenId) external view returns (TerritoryTraits memory);
    function getAssignedColony(uint256 tokenId) external view returns (uint256);
    function isTerritoryActive(uint256 tokenId) external view returns (bool);
    function getApprovedTransferTarget(uint256 tokenId) external view returns (address);
    function ownerOf(uint256 tokenId) external view returns (address);
    function totalSupply() external view returns (uint256);

    // Events (for listening)
    event TerritoryMinted(uint256 indexed tokenId, address indexed recipient, TerritoryType territoryType, Rarity rarity);
    event TerritoryAssignedToColony(uint256 indexed tokenId, uint256 indexed colonyId);
    event TerritoryActivated(uint256 indexed tokenId, uint256 indexed colonyId);
    event TerritoryDeactivated(uint256 indexed tokenId, uint256 indexed colonyId);
    event TransferRequested(uint256 indexed tokenId, address indexed from, address indexed to);
    event TransferApproved(uint256 indexed tokenId, address indexed to);
    event TransferRejected(uint256 indexed tokenId, address indexed to, string reason);
}
