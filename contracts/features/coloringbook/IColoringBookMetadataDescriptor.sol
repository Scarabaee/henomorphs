// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title IColoringBookMetadataDescriptor
 * @notice Interface for generating metadata for Henomorphs Coloring Book NFTs
 * @dev External contract handles JSON and image URI generation
 * @author rutilicus.eth (ArchXS)
 */
interface IColoringBookMetadataDescriptor {

    /// @notice Chapter data for metadata generation
    struct ChapterData {
        uint16 chapterId;       // Chapter number (1-50)
        string title;           // Chapter title
        string story;           // Story description
        string imageUri;        // IPFS image URI
        uint8 territoryType;    // Territory type enum value
        uint8 region;           // Region enum value
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
     * @param tokenId Token ID (chapter number)
     * @param chapter Chapter data
     * @param collectionConfig Collection configuration
     * @return Base64 encoded JSON metadata URI
     */
    function tokenURI(
        uint256 tokenId,
        ChapterData memory chapter,
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
     * @notice Get territory type name
     * @param territoryType Territory type enum value
     * @return Human-readable territory type name
     */
    function getTerritoryTypeName(uint8 territoryType) external view returns (string memory);

    /**
     * @notice Get region name
     * @param region Region enum value
     * @return Human-readable region name
     */
    function getRegionName(uint8 region) external view returns (string memory);
}
