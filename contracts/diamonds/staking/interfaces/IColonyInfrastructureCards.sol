// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title IColonyInfrastructureCards
 * @notice Interface for Colony Infrastructure Cards NFT contract
 * @dev Used by TerritoryEquipmentFacet to communicate with Infrastructure NFT contract
 */
interface IColonyInfrastructureCards {
    
    enum InfrastructureType { 
        MiningDrill,        // 0 - Stone/Resource production
        EnergyHarvester,    // 1 - Energy production
        ProcessingPlant,    // 2 - Resource processing
        DefenseTurret,      // 3 - Territory defense
        ResearchLab,        // 4 - Tech advancement
        StorageFacility     // 5 - Resource capacity
    }
    
    enum Rarity {
        Common,      // 0
        Uncommon,    // 1
        Rare,        // 2
        Epic,        // 3
        Legendary    // 4
    }

    struct InfrastructureTraits {
        InfrastructureType infraType;
        Rarity rarity;
        uint8 efficiencyBonus;    // Production/processing efficiency
        uint8 capacityBonus;      // Storage/defense capacity
        uint8 techLevel;          // Tech requirement level
        uint8 durability;         // Current durability (0-100)
    }

    // Minting (called by MINTER_ROLE)
    function mintInfrastructure(
        address to,
        InfrastructureType infraType,
        Rarity rarity
    ) external returns (uint256);

    // Equipment state queries
    function getTraits(uint256 tokenId) external view returns (InfrastructureTraits memory);
    function getEquippedColony(uint256 tokenId) external view returns (uint256);
    function isEquipped(uint256 tokenId) external view returns (bool);
    function ownerOf(uint256 tokenId) external view returns (address);
    function totalSupply() external view returns (uint256);
    function maxSupply() external view returns (uint256);

    // Colony integration (called by COLONY_WARS_ROLE)
    function equipToColony(uint256 tokenId, uint256 colonyId) external;
    function unequipFromColony(uint256 tokenId) external;
    function useInfrastructure(uint256 tokenId) external returns (bool);
    function repairInfrastructure(uint256 tokenId, uint8 durabilityToRestore) external returns (uint256 cost);
    
    // Transfer functions (Model D: Conditional Transfer)
    function requestTransfer(uint256 tokenId, address to) external;
    function approveTransfer(uint256 tokenId, address to) external;
    function completeTransfer(address from, address to, uint256 tokenId) external;
    
    // Events
    event InfrastructureEquipped(uint256 indexed tokenId, uint256 indexed colonyId);
    event InfrastructureUnequipped(uint256 indexed tokenId, uint256 indexed colonyId);
    event InfrastructureUsed(uint256 indexed tokenId, uint256 indexed colonyId);
    event InfrastructureRepaired(uint256 indexed tokenId, uint8 durabilityRestored, uint256 costPaid);
}
