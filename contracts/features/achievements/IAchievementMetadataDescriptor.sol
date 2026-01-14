// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title IAchievementMetadataDescriptor
 * @notice Interface for Achievement NFT metadata descriptor
 * @dev External metadata generation to reduce main contract size
 * @author rutilicus.eth (ArchXS)
 */
interface IAchievementMetadataDescriptor {
    // ═══════════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    struct AchievementData {
        uint256 achievementId;
        string name;
        string description;
        string imageUri;        // Achievement-specific image URI (optional)
        uint8 category;         // 1=Combat, 2=Territory, 3=Economic, 4=Collection, 5=Social, 6=Special
        uint8 tier;             // 1=Bronze, 2=Silver, 3=Gold, 4=Platinum
        uint8 maxTier;          // Maximum achievable tier
        bool soulbound;
        uint256 progressMax;    // Max progress (0 = not progressive)
        uint32 earnedAt;        // Timestamp when earned
        uint256 progress;       // Current progress
    }

    struct CollectionConfig {
        string name;
        string symbol;
        string description;
        string imageUri;        // Collection logo/image URI (full path)
        string baseUri;         // Base URI for individual badge images
        string externalLink;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Generate token URI for an achievement (with SVG overlay)
     * @param tokenId The token ID
     * @param achievement Achievement data with all attributes
     * @param collectionConfig Collection configuration for base URIs
     * @return Token URI as base64 encoded JSON data URI
     */
    function tokenURI(
        uint256 tokenId,
        AchievementData calldata achievement,
        CollectionConfig calldata collectionConfig
    ) external view returns (string memory);

    /**
     * @notice Generate simple token URI (direct IPFS image, no SVG overlay)
     * @param achievement Achievement data
     * @param collectionConfig Collection configuration for base URIs
     * @return Token URI as base64 encoded JSON data URI
     */
    function tokenURISimple(
        AchievementData calldata achievement,
        CollectionConfig calldata collectionConfig
    ) external view returns (string memory);

    /**
     * @notice Generate contract URI for the collection
     * @param collectionConfig Collection configuration
     * @return Contract URI as base64 encoded JSON data URI
     */
    function contractURI(
        CollectionConfig calldata collectionConfig
    ) external view returns (string memory);

    /**
     * @notice Get tier name from tier ID
     * @param tier Tier ID (1-4)
     * @return name Human-readable tier name
     */
    function getTierName(uint8 tier) external pure returns (string memory name);

    /**
     * @notice Get category name from category ID
     * @param category Category ID (1-6)
     * @return name Human-readable category name
     */
    function getCategoryName(uint8 category) external pure returns (string memory name);
}
