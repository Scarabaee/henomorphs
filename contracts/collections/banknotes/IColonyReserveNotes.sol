// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title IColonyReserveNotes
 * @notice Interface for Colony Reserve Notes - YLW-backed banknote NFT collection
 * @dev ERC-721 collection with configurable series, denominations, and rarity variants
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
interface IColonyReserveNotes {
    // ============================================
    // ENUMS
    // ============================================

    /**
     * @notice Rarity levels for notes
     * @dev Each rarity has different probability and may have bonus multiplier
     */
    enum Rarity {
        Common,
        Uncommon,
        Rare,
        Epic,
        Legendary
    }

    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice Collection-level configuration
     */
    struct CollectionConfig {
        string name;              // Collection name (e.g., "Colony Reserve Notes")
        string symbol;            // Token symbol (e.g., "CRN")
        string description;       // Collection description
        string externalLink;      // Website URL
        string bannerImage;       // Collection banner image (IPFS/URL)
    }

    /**
     * @notice Series configuration - each series has its own base image URI
     */
    struct SeriesConfig {
        bytes1 seriesId;          // Series identifier ('A', 'B', 'C', etc.)
        string name;              // Series name (e.g., "Genesis Series")
        string baseImageUri;      // IPFS base URL for this series
        uint32 maxSupply;         // Max supply for entire series (0 = unlimited)
        uint32 mintedCount;       // Current minted count
        uint32 startTime;         // Series start timestamp (0 = immediate)
        uint32 endTime;           // Series end timestamp (0 = no end)
        bool active;              // Is series active
    }

    /**
     * @notice Denomination configuration - defines YLW value and image subpath
     */
    struct DenominationConfig {
        uint8 denominationId;     // Denomination ID (0, 1, 2, ...)
        string name;              // Denomination name (e.g., "Bronze Note", "Gold Note")
        uint256 ylwValue;         // Value in YLW (in wei, e.g., 1000e18)
        string imageSubpath;      // Image subpath (e.g., "1000-ylw")
        bool active;              // Is denomination active
    }

    /**
     * @notice Rarity configuration - defines probability and visual variant
     */
    struct RarityConfig {
        Rarity rarity;            // Rarity level
        string name;              // Display name (e.g., "Common", "Holographic")
        string imageSuffix;       // Image suffix (e.g., "-common", "-legendary")
        uint16 weightBps;         // Weight in basis points (sum of all = 10000)
        uint16 bonusMultiplierBps; // Bonus multiplier (10000 = 100%, 11000 = 110%)
    }

    /**
     * @notice Individual note data stored per token
     */
    struct NoteData {
        uint8 denominationId;     // Reference to DenominationConfig
        bytes1 seriesId;          // Reference to SeriesConfig
        Rarity rarity;            // Rolled rarity
        uint32 serialNumber;      // Sequential per series+denomination
        uint32 mintedAt;          // Mint timestamp
    }

    // ============================================
    // EVENTS
    // ============================================

    event NoteMinted(
        uint256 indexed tokenId,
        address indexed to,
        uint8 denominationId,
        bytes1 seriesId,
        Rarity rarity,
        uint32 serialNumber
    );

    event NoteRedeemed(
        uint256 indexed tokenId,
        address indexed redeemer,
        uint256 ylwAmount,
        Rarity rarity
    );

    event CollectionConfigured(string name, string symbol);
    event SeriesConfigured(bytes1 indexed seriesId, string name, string baseImageUri);
    event SeriesActiveChanged(bytes1 indexed seriesId, bool active);
    event DenominationConfigured(uint8 indexed denominationId, string name, uint256 ylwValue);
    event DenominationActiveChanged(uint8 indexed denominationId, bool active);
    event RarityConfigured(Rarity indexed rarity, string name, uint16 weightBps, uint16 bonusMultiplierBps);
    event MinterUpdated(address indexed minter, bool authorized);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event YlwTokenUpdated(address indexed oldToken, address indexed newToken);

    // ============================================
    // ERRORS
    // ============================================

    error NotOwner();
    error NotMinter();
    error NotAdmin();
    error TokenDoesNotExist(uint256 tokenId);
    error SeriesNotFound(bytes1 seriesId);
    error SeriesNotActive(bytes1 seriesId);
    error SeriesMaxSupplyReached(bytes1 seriesId);
    error SeriesNotStarted(bytes1 seriesId);
    error SeriesEnded(bytes1 seriesId);
    error DenominationNotFound(uint8 denominationId);
    error DenominationNotActive(uint8 denominationId);
    error RarityNotConfigured(Rarity rarity);
    error InvalidAddress();
    error InvalidRarityWeights();
    error AlreadyInitialized();
    error NotInitialized();
    error InsufficientTreasuryBalance(uint256 required, uint256 available);

    // ============================================
    // MINTING FUNCTIONS
    // ============================================

    /**
     * @notice Mint a note with random rarity
     * @param to Recipient address
     * @param denominationId Denomination to mint
     * @param seriesId Series to mint from
     * @return tokenId Minted token ID
     */
    function mintNote(
        address to,
        uint8 denominationId,
        bytes1 seriesId
    ) external returns (uint256 tokenId);

    /**
     * @notice Mint a note with specific rarity (for special rewards)
     * @param to Recipient address
     * @param denominationId Denomination to mint
     * @param seriesId Series to mint from
     * @param rarity Specific rarity to assign
     * @return tokenId Minted token ID
     */
    function mintNoteWithRarity(
        address to,
        uint8 denominationId,
        bytes1 seriesId,
        Rarity rarity
    ) external returns (uint256 tokenId);

    /**
     * @notice Batch mint notes
     * @param to Recipient address
     * @param denominationIds Array of denomination IDs
     * @param seriesId Series to mint from
     * @return tokenIds Array of minted token IDs
     */
    function mintNoteBatch(
        address to,
        uint8[] calldata denominationIds,
        bytes1 seriesId
    ) external returns (uint256[] memory tokenIds);

    // ============================================
    // REDEMPTION FUNCTIONS
    // ============================================

    /**
     * @notice Redeem a note for YLW tokens (burns the NFT)
     * @param tokenId Token to redeem
     */
    function redeemNote(uint256 tokenId) external;

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get the YLW value of a note (including rarity bonus)
     * @param tokenId Token to query
     * @return ylwAmount YLW value in wei
     */
    function getNoteValue(uint256 tokenId) external view returns (uint256 ylwAmount);

    /**
     * @notice Get complete note data
     * @param tokenId Token to query
     * @return data NoteData struct
     */
    function getNoteData(uint256 tokenId) external view returns (NoteData memory data);

    /**
     * @notice Get formatted serial number
     * @param tokenId Token to query
     * @return serial Formatted serial number string
     */
    function getSerialNumber(uint256 tokenId) external view returns (string memory serial);

    /**
     * @notice Get series configuration
     * @param seriesId Series to query
     * @return config SeriesConfig struct
     */
    function getSeriesConfig(bytes1 seriesId) external view returns (SeriesConfig memory config);

    /**
     * @notice Get denomination configuration
     * @param denominationId Denomination to query
     * @return config DenominationConfig struct
     */
    function getDenominationConfig(uint8 denominationId) external view returns (DenominationConfig memory config);

    /**
     * @notice Get rarity configuration
     * @param rarity Rarity to query
     * @return config RarityConfig struct
     */
    function getRarityConfig(Rarity rarity) external view returns (RarityConfig memory config);

    /**
     * @notice Get all active series IDs
     * @return seriesIds Array of active series IDs
     */
    function getActiveSeriesIds() external view returns (bytes1[] memory seriesIds);

    /**
     * @notice Get all active denomination IDs
     * @return denominationIds Array of active denomination IDs
     */
    function getActiveDenominationIds() external view returns (uint8[] memory denominationIds);

    // ============================================
    // METADATA FUNCTIONS
    // ============================================

    /**
     * @notice Get collection-level metadata URI (OpenSea standard)
     * @return uri JSON metadata URI
     */
    function contractURI() external view returns (string memory uri);
}
