// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title IColonyResourceCards
 * @notice Interface for Colony Resource Cards NFT contract
 * @dev Used by Colony Wars facets to communicate with Resource NFT contract
 */
interface IColonyResourceCards {

    enum ResourceType {
        BasicMaterials,  // 0 - Stone, Wood
        EnergyCrystals,  // 1 - Energy
        BioCompounds,    // 2 - Biological
        RareElements     // 3 - Rare minerals
    }

    enum Rarity {
        Common,      // 0
        Uncommon,    // 1
        Rare,        // 2
        Epic,        // 3
        Legendary    // 4
    }

    struct ResourceTraits {
        ResourceType resourceType;
        Rarity rarity;
        uint8 yieldBonus;     // Production yield bonus
        uint8 qualityLevel;   // Quality level (1-5)
        uint16 stackSize;     // Current stack size
        uint16 maxStack;      // Maximum stack size
    }

    // Minting
    function mintResource(
        address to,
        ResourceType resourceType,
        Rarity rarity
    ) external returns (uint256);

    function mintRandomResource(
        address to,
        ResourceType resourceType
    ) external returns (uint256);

    function batchMintResources(
        address to,
        ResourceType[] calldata types,
        Rarity[] calldata rarities
    ) external returns (uint256[] memory);

    // Staking (called by COLONY_WARS_ROLE)
    function stakeToNode(uint256 tokenId, uint256 nodeId) external;
    function unstakeFromNode(uint256 tokenId) external;

    // Combine (called by COLONY_WARS_ROLE)
    function combineResources(uint256[] calldata tokenIds) external returns (uint256);

    // Transfer functions (Model D: Conditional Transfer)
    function requestTransfer(uint256 tokenId, address to) external;
    function approveTransfer(uint256 tokenId, address to) external;
    function completeTransfer(address from, address to, uint256 tokenId) external;

    // View functions
    function getTraits(uint256 tokenId) external view returns (ResourceTraits memory);
    function getStakedNode(uint256 tokenId) external view returns (uint256);
    function isStaked(uint256 tokenId) external view returns (bool);
    function getTotalYield(uint256 tokenId) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function totalSupply() external view returns (uint256);
    function maxSupply() external view returns (uint256);

    // Events
    event ResourceMinted(uint256 indexed tokenId, address indexed recipient, ResourceType resourceType, Rarity rarity);
    event ResourceStaked(uint256 indexed tokenId, uint256 indexed nodeId);
    event ResourceUnstaked(uint256 indexed tokenId, uint256 indexed nodeId);
    event ResourcesCombined(uint256[] burnedTokens, uint256 indexed newTokenId);
    event TransferRequested(uint256 indexed tokenId, address indexed from, address indexed to);
    event TransferApproved(uint256 indexed tokenId, address indexed to);
}
