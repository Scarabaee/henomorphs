// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title ICosmicCodexMetadataDescriptor
 * @notice Interface for generating metadata for Henomorphs Cosmic Codex NFTs
 * @dev External contract handles JSON and image URI generation
 * @author rutilicus.eth (ArchXS)
 */
interface ICosmicCodexMetadataDescriptor {

    /// @notice Theory data for metadata generation
    struct TheoryData {
        uint16 theoryId;        // Theory number (1-50)
        string title;           // Theory title
        string description;     // Theory description
        string imageUri;        // IPFS image URI
        uint8 category;         // Category enum value
        uint8 difficulty;       // Difficulty enum value
    }

    /// @notice Collection configuration
    struct CollectionConfig {
        string name;
        string symbol;
        string description;
        string imageUri;
        string baseUri;
        string externalLink;
    }

    /**
     * @notice Generate token URI with full metadata
     * @param tokenId Token ID (theory number)
     * @param theory Theory data
     * @param collectionConfig Collection configuration
     * @return Base64 encoded JSON metadata URI
     */
    function tokenURI(
        uint256 tokenId,
        TheoryData memory theory,
        CollectionConfig memory collectionConfig
    ) external view returns (string memory);

    /**
     * @notice Generate collection-level contract URI
     * @param collectionConfig Collection configuration
     * @return Base64 encoded JSON contract metadata URI
     */
    function contractURI(
        CollectionConfig memory collectionConfig
    ) external view returns (string memory);

    /**
     * @notice Get category name
     * @param category Category enum value
     * @return Human-readable category name
     */
    function getCategoryName(uint8 category) external view returns (string memory);

    /**
     * @notice Get difficulty name
     * @param difficulty Difficulty enum value
     * @return Human-readable difficulty name
     */
    function getDifficultyName(uint8 difficulty) external view returns (string memory);
}
