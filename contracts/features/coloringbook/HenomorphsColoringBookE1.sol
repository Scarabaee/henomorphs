// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC1155Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {ERC1155SupplyUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155SupplyUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IColoringBookMetadataDescriptor} from "./IColoringBookMetadataDescriptor.sol";

/**
 * @title HenomorphsColoringBookE1
 * @notice ERC-1155 NFT Collection for "Henomorphs: The Nexus Quest" Coloring Book Edition 1
 * @dev OpenZeppelin v5+ contracts-upgradeable with UUPS proxy pattern
 *      50 unique coloring book illustrations (Token IDs 1-50) with static IPFS images
 *      Each token represents a chapter from the Nexus Quest story
 *
 * Storage Pattern: ERC-7201 Namespaced Storage for upgrade safety
 *
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract HenomorphsColoringBookE1 is
    Initializable,
    ERC1155Upgradeable,
    ERC1155SupplyUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using Strings for uint256;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS - Roles
    // ═══════════════════════════════════════════════════════════════════════════

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant REGISTRY_ADMIN_ROLE = keccak256("REGISTRY_ADMIN_ROLE");

    /// @notice Total number of unique illustrations in Edition 1
    uint256 public constant MAX_TOKEN_ID = 50;

    /// @notice Minimum valid token ID
    uint256 public constant MIN_TOKEN_ID = 1;

    // ═══════════════════════════════════════════════════════════════════════════
    // ENUMS
    // ═══════════════════════════════════════════════════════════════════════════

    enum TerritoryType {
        None,           // 0 - Invalid
        ZICOMine,       // 1 - ZICO crystal mining territories
        TradeHub,       // 2 - Trading and commerce areas
        Fortress,       // 3 - Military fortifications
        Observatory,    // 4 - Research and observation posts
        Sanctuary       // 5 - Healing and spiritual locations
    }

    enum Region {
        None,                   // 0 - Invalid
        NorthernGoldenRoost,    // 1 - Northern Region: The Golden Roost (Chapters 1-8)
        CentralMarketplace,     // 2 - Central Region: The Great Marketplace (Chapters 9-18)
        SouthernFortressPeaks,  // 3 - Southern Region: The Fortress Peaks (Chapters 19-27)
        EasternWildTerritories, // 4 - Eastern Region: The Wild Territories (Chapters 28-35)
        WesternDigitalPlains,   // 5 - Western Region: The Digital Plains (Chapters 36-42)
        SacredGrounds           // 6 - Sacred Grounds: Territory 42 (Chapters 43-50)
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    struct ChapterMetadata {
        uint16 chapterId;           // Chapter number (1-50)
        string title;               // Chapter title in English
        string story;               // Short story description in English
        string imageUri;            // IPFS URI for the coloring book illustration
        TerritoryType territoryType;
        Region region;
        bool active;
    }

    /// @notice Collection configuration
    struct CollectionConfig {
        string name;
        string symbol;
        string description;
        string imageUri;             // Collection logo/image URI (full path)
        string baseUri;              // Base URI for individual chapter images
        string externalLink;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERC-7201 NAMESPACED STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @custom:storage-location erc7201:henomorphs.coloringbook.e1.storage
    struct ColoringBookStorage {
        /// @notice Chapter metadata registry (chapterId => metadata)
        mapping(uint256 => ChapterMetadata) chapters;
        /// @notice Collection configuration
        CollectionConfig config;
        /// @notice Total minted count across all tokens
        uint256 totalMinted;
        /// @notice Max supply per token (0 = unlimited)
        mapping(uint256 => uint256) maxSupply;
        /// @notice External metadata descriptor contract
        IColoringBookMetadataDescriptor metadataDescriptor;
        /// @notice Max mints per wallet per token (0 = unlimited)
        uint256 maxMintsPerWallet;
        /// @notice Minted count per wallet per token (wallet => tokenId => count)
        mapping(address => mapping(uint256 => uint256)) walletMints;
    }

    // keccak256(abi.encode(uint256(keccak256("henomorphs.coloringbook.e1.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant COLORING_BOOK_STORAGE_LOCATION =
        0x8a0c9d8ec1d9f8b8e8c8f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8091a00;

    function _getColoringBookStorage() private pure returns (ColoringBookStorage storage $) {
        assembly {
            $.slot := COLORING_BOOK_STORAGE_LOCATION
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event ChapterRegistered(
        uint256 indexed chapterId,
        string title,
        TerritoryType territoryType,
        Region region
    );

    event ChapterUpdated(uint256 indexed chapterId);
    event ChapterDeactivated(uint256 indexed chapterId);
    event ConfigUpdated();
    event MetadataDescriptorUpdated(address indexed newDescriptor);
    event MaxSupplySet(uint256 indexed tokenId, uint256 maxSupply);
    event MaxMintsPerWalletUpdated(uint256 maxMints);

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error InvalidTokenId(uint256 tokenId);
    error ChapterNotFound(uint256 chapterId);
    error ChapterNotActive(uint256 chapterId);
    error ChapterAlreadyRegistered(uint256 chapterId);
    error InvalidTerritoryType();
    error InvalidRegion();
    error ZeroAddress();
    error InvalidMetadataDescriptor();
    error MaxSupplyExceeded(uint256 tokenId, uint256 requested, uint256 available);
    error WalletMintLimitExceeded(address wallet, uint256 tokenId, uint256 requested, uint256 available);

    // ═══════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════

    modifier validTokenId(uint256 tokenId) {
        if (tokenId < MIN_TOKEN_ID || tokenId > MAX_TOKEN_ID) {
            revert InvalidTokenId(tokenId);
        }
        _;
    }

    modifier validChapter(uint256 chapterId) {
        ColoringBookStorage storage $ = _getColoringBookStorage();
        if (!$.chapters[chapterId].active) {
            revert ChapterNotActive(chapterId);
        }
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZER (replaces constructor for UUPS)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract (called once via proxy)
     * @param admin Address to receive admin roles
     * @param _config Initial collection configuration
     * @param _metadataDescriptor External metadata descriptor address
     */
    function initialize(
        address admin,
        CollectionConfig calldata _config,
        address _metadataDescriptor
    ) public initializer {
        if (admin == address(0)) revert ZeroAddress();
        if (_metadataDescriptor == address(0)) revert InvalidMetadataDescriptor();

        __ERC1155_init("");
        __ERC1155Supply_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(REGISTRY_ADMIN_ROLE, admin);

        ColoringBookStorage storage $ = _getColoringBookStorage();
        $.config = _config;
        $.metadataDescriptor = IColoringBookMetadataDescriptor(_metadataDescriptor);

        // Default: 1 mint per wallet per token
        $.maxMintsPerWallet = 1;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UUPS UPGRADE AUTHORIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}

    // ═══════════════════════════════════════════════════════════════════════════
    // ERC1155 OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal virtual override(ERC1155Upgradeable, ERC1155SupplyUpgradeable) {
        super._update(from, to, ids, values);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MINTING
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Mint a single coloring book page to an address
     * @param to Recipient address
     * @param tokenId Token ID (chapter number 1-50)
     * @param amount Number of tokens to mint
     */
    function mint(
        address to,
        uint256 tokenId,
        uint256 amount
    ) external onlyRole(MINTER_ROLE) whenNotPaused nonReentrant validTokenId(tokenId) validChapter(tokenId) {
        if (to == address(0)) revert ZeroAddress();

        ColoringBookStorage storage $ = _getColoringBookStorage();

        // Check max supply if set
        uint256 maxSup = $.maxSupply[tokenId];
        if (maxSup > 0) {
            uint256 currentSupply = totalSupply(tokenId);
            if (currentSupply + amount > maxSup) {
                revert MaxSupplyExceeded(tokenId, amount, maxSup - currentSupply);
            }
        }

        // Check wallet mint limit if set
        uint256 walletLimit = $.maxMintsPerWallet;
        if (walletLimit > 0) {
            uint256 walletMinted = $.walletMints[to][tokenId];
            if (walletMinted + amount > walletLimit) {
                revert WalletMintLimitExceeded(to, tokenId, amount, walletLimit - walletMinted);
            }
            $.walletMints[to][tokenId] = walletMinted + amount;
        }

        _mint(to, tokenId, amount, "");
        $.totalMinted += amount;
    }

    /**
     * @notice Mint multiple coloring book pages to an address
     * @param to Recipient address
     * @param tokenIds Array of token IDs (chapter numbers 1-50)
     * @param amounts Array of amounts to mint for each token
     */
    function mintBatch(
        address to,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts
    ) external onlyRole(MINTER_ROLE) whenNotPaused nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (tokenIds.length != amounts.length) revert("Length mismatch");

        ColoringBookStorage storage $ = _getColoringBookStorage();
        uint256 walletLimit = $.maxMintsPerWallet;

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (tokenIds[i] < MIN_TOKEN_ID || tokenIds[i] > MAX_TOKEN_ID) {
                revert InvalidTokenId(tokenIds[i]);
            }
            if (!$.chapters[tokenIds[i]].active) {
                revert ChapterNotActive(tokenIds[i]);
            }

            // Check max supply if set
            uint256 maxSup = $.maxSupply[tokenIds[i]];
            if (maxSup > 0) {
                uint256 currentSupply = totalSupply(tokenIds[i]);
                if (currentSupply + amounts[i] > maxSup) {
                    revert MaxSupplyExceeded(tokenIds[i], amounts[i], maxSup - currentSupply);
                }
            }

            // Check wallet mint limit if set
            if (walletLimit > 0) {
                uint256 walletMinted = $.walletMints[to][tokenIds[i]];
                if (walletMinted + amounts[i] > walletLimit) {
                    revert WalletMintLimitExceeded(to, tokenIds[i], amounts[i], walletLimit - walletMinted);
                }
                $.walletMints[to][tokenIds[i]] = walletMinted + amounts[i];
            }

            totalAmount += amounts[i];
        }

        _mintBatch(to, tokenIds, amounts, "");
        $.totalMinted += totalAmount;
    }

    /**
     * @notice Mint the complete collection (all 50 pages) to an address
     * @param to Recipient address
     */
    function mintCompleteCollection(address to) external onlyRole(MINTER_ROLE) whenNotPaused nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        ColoringBookStorage storage $ = _getColoringBookStorage();
        uint256 walletLimit = $.maxMintsPerWallet;

        uint256[] memory tokenIds = new uint256[](MAX_TOKEN_ID);
        uint256[] memory amounts = new uint256[](MAX_TOKEN_ID);

        for (uint256 i = 0; i < MAX_TOKEN_ID; i++) {
            uint256 tokenId = i + 1;
            if (!$.chapters[tokenId].active) {
                revert ChapterNotActive(tokenId);
            }

            // Check max supply if set
            uint256 maxSup = $.maxSupply[tokenId];
            if (maxSup > 0) {
                uint256 currentSupply = totalSupply(tokenId);
                if (currentSupply + 1 > maxSup) {
                    revert MaxSupplyExceeded(tokenId, 1, maxSup - currentSupply);
                }
            }

            // Check wallet mint limit if set
            if (walletLimit > 0) {
                uint256 walletMinted = $.walletMints[to][tokenId];
                if (walletMinted + 1 > walletLimit) {
                    revert WalletMintLimitExceeded(to, tokenId, 1, walletLimit - walletMinted);
                }
                $.walletMints[to][tokenId] = walletMinted + 1;
            }

            tokenIds[i] = tokenId;
            amounts[i] = 1;
        }

        _mintBatch(to, tokenIds, amounts, "");
        $.totalMinted += MAX_TOKEN_ID;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // METADATA
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Returns the URI for a token
     * @param tokenId Token ID (chapter number 1-50)
     */
    function uri(uint256 tokenId) public view override validTokenId(tokenId) returns (string memory) {
        ColoringBookStorage storage $ = _getColoringBookStorage();
        ChapterMetadata storage chapter = $.chapters[tokenId];

        if (!chapter.active && chapter.chapterId == 0) {
            revert ChapterNotFound(tokenId);
        }

        if (address($.metadataDescriptor) == address(0)) {
            revert InvalidMetadataDescriptor();
        }

        return $.metadataDescriptor.tokenURI(
            tokenId,
            IColoringBookMetadataDescriptor.ChapterData({
                chapterId: chapter.chapterId,
                title: chapter.title,
                story: chapter.story,
                imageUri: chapter.imageUri,
                territoryType: uint8(chapter.territoryType),
                region: uint8(chapter.region)
            }),
            IColoringBookMetadataDescriptor.CollectionConfig({
                name: $.config.name,
                symbol: $.config.symbol,
                description: $.config.description,
                imageUri: $.config.imageUri,
                baseUri: $.config.baseUri,
                externalLink: $.config.externalLink
            })
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // REGISTRY MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Register a new chapter
     * @param chapterId Chapter number (1-50)
     * @param title Chapter title
     * @param story Short story description
     * @param imageUri IPFS URI for the illustration
     * @param territoryType Type of territory
     * @param region Region where chapter takes place
     */
    function registerChapter(
        uint256 chapterId,
        string calldata title,
        string calldata story,
        string calldata imageUri,
        TerritoryType territoryType,
        Region region
    ) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (chapterId < MIN_TOKEN_ID || chapterId > MAX_TOKEN_ID) revert InvalidTokenId(chapterId);
        if (territoryType == TerritoryType.None) revert InvalidTerritoryType();
        if (region == Region.None) revert InvalidRegion();

        ColoringBookStorage storage $ = _getColoringBookStorage();
        if ($.chapters[chapterId].active) revert ChapterAlreadyRegistered(chapterId);

        $.chapters[chapterId] = ChapterMetadata({
            chapterId: uint16(chapterId),
            title: title,
            story: story,
            imageUri: imageUri,
            territoryType: territoryType,
            region: region,
            active: true
        });

        emit ChapterRegistered(chapterId, title, territoryType, region);
    }

    /**
     * @notice Batch register multiple chapters
     * @param chapterIds Array of chapter IDs
     * @param titles Array of titles
     * @param stories Array of stories
     * @param imageUris Array of IPFS URIs
     * @param territoryTypes Array of territory types
     * @param regions Array of regions
     */
    function registerChaptersBatch(
        uint256[] calldata chapterIds,
        string[] calldata titles,
        string[] calldata stories,
        string[] calldata imageUris,
        TerritoryType[] calldata territoryTypes,
        Region[] calldata regions
    ) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (chapterIds.length != titles.length ||
            chapterIds.length != stories.length ||
            chapterIds.length != imageUris.length ||
            chapterIds.length != territoryTypes.length ||
            chapterIds.length != regions.length) {
            revert("Length mismatch");
        }

        ColoringBookStorage storage $ = _getColoringBookStorage();

        for (uint256 i = 0; i < chapterIds.length; i++) {
            uint256 chapterId = chapterIds[i];
            if (chapterId < MIN_TOKEN_ID || chapterId > MAX_TOKEN_ID) revert InvalidTokenId(chapterId);
            if (territoryTypes[i] == TerritoryType.None) revert InvalidTerritoryType();
            if (regions[i] == Region.None) revert InvalidRegion();
            if ($.chapters[chapterId].active) revert ChapterAlreadyRegistered(chapterId);

            $.chapters[chapterId] = ChapterMetadata({
                chapterId: uint16(chapterId),
                title: titles[i],
                story: stories[i],
                imageUri: imageUris[i],
                territoryType: territoryTypes[i],
                region: regions[i],
                active: true
            });

            emit ChapterRegistered(chapterId, titles[i], territoryTypes[i], regions[i]);
        }
    }

    /**
     * @notice Update chapter metadata
     * @param chapterId Chapter number (1-50)
     * @param title New title
     * @param story New story
     * @param imageUri New IPFS URI
     */
    function updateChapter(
        uint256 chapterId,
        string calldata title,
        string calldata story,
        string calldata imageUri
    ) external onlyRole(REGISTRY_ADMIN_ROLE) validChapter(chapterId) {
        ColoringBookStorage storage $ = _getColoringBookStorage();
        ChapterMetadata storage chapter = $.chapters[chapterId];
        chapter.title = title;
        chapter.story = story;
        chapter.imageUri = imageUri;

        emit ChapterUpdated(chapterId);
    }

    /**
     * @notice Deactivate a chapter (prevents further minting)
     * @param chapterId Chapter number (1-50)
     */
    function deactivateChapter(uint256 chapterId) external onlyRole(REGISTRY_ADMIN_ROLE) {
        ColoringBookStorage storage $ = _getColoringBookStorage();
        if (!$.chapters[chapterId].active) {
            revert ChapterNotFound(chapterId);
        }

        $.chapters[chapterId].active = false;
        emit ChapterDeactivated(chapterId);
    }

    /**
     * @notice Reactivate a deactivated chapter
     * @param chapterId Chapter number (1-50)
     */
    function reactivateChapter(uint256 chapterId) external onlyRole(REGISTRY_ADMIN_ROLE) {
        ColoringBookStorage storage $ = _getColoringBookStorage();
        if ($.chapters[chapterId].chapterId == 0) revert ChapterNotFound(chapterId);
        $.chapters[chapterId].active = true;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get chapter metadata
     * @param chapterId Chapter number (1-50)
     */
    function getChapter(uint256 chapterId) external view returns (ChapterMetadata memory) {
        ColoringBookStorage storage $ = _getColoringBookStorage();
        return $.chapters[chapterId];
    }

    /**
     * @notice Get all active chapter IDs
     */
    function getActiveChapterIds() external view returns (uint256[] memory) {
        ColoringBookStorage storage $ = _getColoringBookStorage();
        uint256 count = 0;
        for (uint256 i = MIN_TOKEN_ID; i <= MAX_TOKEN_ID; i++) {
            if ($.chapters[i].active) count++;
        }

        uint256[] memory ids = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = MIN_TOKEN_ID; i <= MAX_TOKEN_ID; i++) {
            if ($.chapters[i].active) {
                ids[index++] = i;
            }
        }

        return ids;
    }

    /**
     * @notice Get chapters by region
     * @param region Region to filter by
     */
    function getChaptersByRegion(Region region) external view returns (uint256[] memory) {
        ColoringBookStorage storage $ = _getColoringBookStorage();
        uint256 count = 0;
        for (uint256 i = MIN_TOKEN_ID; i <= MAX_TOKEN_ID; i++) {
            if ($.chapters[i].active && $.chapters[i].region == region) count++;
        }

        uint256[] memory ids = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = MIN_TOKEN_ID; i <= MAX_TOKEN_ID; i++) {
            if ($.chapters[i].active && $.chapters[i].region == region) {
                ids[index++] = i;
            }
        }

        return ids;
    }

    /**
     * @notice Get chapters by territory type
     * @param territoryType Territory type to filter by
     */
    function getChaptersByTerritoryType(TerritoryType territoryType) external view returns (uint256[] memory) {
        ColoringBookStorage storage $ = _getColoringBookStorage();
        uint256 count = 0;
        for (uint256 i = MIN_TOKEN_ID; i <= MAX_TOKEN_ID; i++) {
            if ($.chapters[i].active && $.chapters[i].territoryType == territoryType) count++;
        }

        uint256[] memory ids = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = MIN_TOKEN_ID; i <= MAX_TOKEN_ID; i++) {
            if ($.chapters[i].active && $.chapters[i].territoryType == territoryType) {
                ids[index++] = i;
            }
        }

        return ids;
    }

    /**
     * @notice Check if token exists (has been minted)
     * @param tokenId Token ID to check
     */
    function exists(uint256 tokenId) public view override returns (bool) {
        return super.exists(tokenId);
    }

    /**
     * @notice Get max supply for a token (0 = unlimited)
     * @param tokenId Token ID to check
     */
    function maxSupply(uint256 tokenId) external view returns (uint256) {
        ColoringBookStorage storage $ = _getColoringBookStorage();
        return $.maxSupply[tokenId];
    }

    /**
     * @notice Get total minted count across all tokens
     */
    function totalMinted() external view returns (uint256) {
        ColoringBookStorage storage $ = _getColoringBookStorage();
        return $.totalMinted;
    }

    /**
     * @notice Get collection configuration
     */
    function config() external view returns (CollectionConfig memory) {
        ColoringBookStorage storage $ = _getColoringBookStorage();
        return $.config;
    }

    /**
     * @notice Get metadata descriptor address
     */
    function metadataDescriptor() external view returns (IColoringBookMetadataDescriptor) {
        ColoringBookStorage storage $ = _getColoringBookStorage();
        return $.metadataDescriptor;
    }

    function name() external view returns (string memory) {
        ColoringBookStorage storage $ = _getColoringBookStorage();
        return $.config.name;
    }

    function symbol() external view returns (string memory) {
        ColoringBookStorage storage $ = _getColoringBookStorage();
        return $.config.symbol;
    }

    function contractURI() external view returns (string memory) {
        ColoringBookStorage storage $ = _getColoringBookStorage();
        if (address($.metadataDescriptor) == address(0)) {
            revert InvalidMetadataDescriptor();
        }

        return $.metadataDescriptor.contractURI(
            IColoringBookMetadataDescriptor.CollectionConfig({
                name: $.config.name,
                symbol: $.config.symbol,
                description: $.config.description,
                imageUri: $.config.imageUri,
                baseUri: $.config.baseUri,
                externalLink: $.config.externalLink
            })
        );
    }

    /**
     * @notice Get max mints per wallet per token (0 = unlimited)
     */
    function maxMintsPerWallet() external view returns (uint256) {
        ColoringBookStorage storage $ = _getColoringBookStorage();
        return $.maxMintsPerWallet;
    }

    /**
     * @notice Get minted count for a wallet for a specific token
     * @param wallet Wallet address
     * @param tokenId Token ID
     */
    function walletMints(address wallet, uint256 tokenId) external view returns (uint256) {
        ColoringBookStorage storage $ = _getColoringBookStorage();
        return $.walletMints[wallet][tokenId];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function setConfig(CollectionConfig calldata _config) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ColoringBookStorage storage $ = _getColoringBookStorage();
        $.config = _config;
        emit ConfigUpdated();
    }

    function setMetadataDescriptor(address newDescriptor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newDescriptor == address(0)) revert InvalidMetadataDescriptor();
        ColoringBookStorage storage $ = _getColoringBookStorage();
        $.metadataDescriptor = IColoringBookMetadataDescriptor(newDescriptor);
        emit MetadataDescriptorUpdated(newDescriptor);
    }

    function setMaxSupply(uint256 tokenId, uint256 newMaxSupply) external onlyRole(DEFAULT_ADMIN_ROLE) validTokenId(tokenId) {
        ColoringBookStorage storage $ = _getColoringBookStorage();
        $.maxSupply[tokenId] = newMaxSupply;
        emit MaxSupplySet(tokenId, newMaxSupply);
    }

    /**
     * @notice Set max mints per wallet per token
     * @param maxMints Max mints (0 = unlimited)
     */
    function setMaxMintsPerWallet(uint256 maxMints) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ColoringBookStorage storage $ = _getColoringBookStorage();
        $.maxMintsPerWallet = maxMints;
        emit MaxMintsPerWalletUpdated(maxMints);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // REQUIRED OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
