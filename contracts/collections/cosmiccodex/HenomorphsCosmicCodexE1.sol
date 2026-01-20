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

import {ICosmicCodexMetadataDescriptor} from "./ICosmicCodexMetadataDescriptor.sol";

/**
 * @title HenomorphsCosmicCodexE1
 * @notice ERC-1155 NFT Collection for "Henomorphs: Cosmic Codex" Edition 1
 * @dev OpenZeppelin v5+ contracts-upgradeable with UUPS proxy pattern
 *      62 unique cosmic illustrations with static IPFS images:
 *      - Token IDs 1-50: Cosmic theory illustrations
 *      - Token IDs 51-62: Gallery artworks
 *
 * Storage Pattern: ERC-7201 Namespaced Storage for upgrade safety
 *
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract HenomorphsCosmicCodexE1 is
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

    /// @notice Total number of unique tokens in Edition 1 (50 illustrations + 12 gallery)
    uint256 public constant MAX_TOKEN_ID = 62;

    /// @notice Minimum valid token ID
    uint256 public constant MIN_TOKEN_ID = 1;

    /// @notice Size of basic collection (illustrations only, tokens 1-50)
    uint256 public constant BASIC_COLLECTION_SIZE = 50;

    // ═══════════════════════════════════════════════════════════════════════════
    // ENUMS
    // ═══════════════════════════════════════════════════════════════════════════

    enum Category {
        None,           // 0 - Invalid
        Cosmology,      // 1 - Study of the universe's origin and structure
        QuantumPhysics, // 2 - Quantum mechanics and particle physics
        Astrobiology,   // 3 - Life in the universe
        DarkMatter,     // 4 - Dark matter and dark energy
        Multiverse,     // 5 - Parallel universes and dimensions
        TimeSpace       // 6 - Time and space manipulation
    }

    enum Difficulty {
        None,           // 0 - Invalid
        Novice,         // 1 - Beginner level theories
        Intermediate,   // 2 - Moderate complexity
        Advanced,       // 3 - Complex theories
        Expert,         // 4 - Highly advanced concepts
        Legendary       // 5 - Most profound cosmic mysteries
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    struct TheoryMetadata {
        uint16 theoryId;            // Theory number (1-50)
        string title;               // Theory title in English
        string description;         // Theory description in English
        string imageUri;            // IPFS URI for the theory illustration
        Category category;
        Difficulty difficulty;
        bool active;
    }

    /// @notice Collection configuration
    struct CollectionConfig {
        string name;
        string symbol;
        string description;
        string imageUri;             // Collection logo/image URI (full path)
        string baseUri;              // Base URI for individual theory images
        string externalLink;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERC-7201 NAMESPACED STORAGE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @custom:storage-location erc7201:henomorphs.cosmiccodex.e1.storage
    struct CosmicCodexStorage {
        /// @notice Theory metadata registry (theoryId => metadata)
        mapping(uint256 => TheoryMetadata) theories;
        /// @notice Collection configuration
        CollectionConfig config;
        /// @notice Total minted count across all tokens
        uint256 totalMinted;
        /// @notice Max supply per token (0 = unlimited)
        mapping(uint256 => uint256) maxSupply;
        /// @notice External metadata descriptor contract
        ICosmicCodexMetadataDescriptor metadataDescriptor;
        /// @notice Max mints per wallet per token (0 = unlimited)
        uint256 maxMintsPerWallet;
        /// @notice Minted count per wallet per token (wallet => tokenId => count)
        mapping(address => mapping(uint256 => uint256)) walletMints;
    }

    // keccak256(abi.encode(uint256(keccak256("henomorphs.cosmiccodex.e1.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant COSMIC_CODEX_STORAGE_LOCATION =
        0x9b1d0e9f2c3a4b5c6d7e8f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f809200;

    function _getCosmicCodexStorage() private pure returns (CosmicCodexStorage storage $) {
        assembly {
            $.slot := COSMIC_CODEX_STORAGE_LOCATION
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event TheoryRegistered(
        uint256 indexed theoryId,
        string title,
        Category category,
        Difficulty difficulty
    );

    event TheoryUpdated(uint256 indexed theoryId);
    event TheoryDeactivated(uint256 indexed theoryId);
    event ConfigUpdated();
    event MetadataDescriptorUpdated(address indexed newDescriptor);
    event MaxSupplySet(uint256 indexed tokenId, uint256 maxSupply);
    event MaxMintsPerWalletUpdated(uint256 maxMints);

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error InvalidTokenId(uint256 tokenId);
    error TheoryNotFound(uint256 theoryId);
    error TheoryNotActive(uint256 theoryId);
    error TheoryAlreadyRegistered(uint256 theoryId);
    error InvalidCategory();
    error InvalidDifficulty();
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

    modifier validTheory(uint256 theoryId) {
        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
        if (!$.theories[theoryId].active) {
            revert TheoryNotActive(theoryId);
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

        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
        $.config = _config;
        $.metadataDescriptor = ICosmicCodexMetadataDescriptor(_metadataDescriptor);

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
     * @notice Mint a single cosmic codex page to an address
     * @param to Recipient address
     * @param tokenId Token ID (theory number 1-50)
     * @param amount Number of tokens to mint
     */
    function mint(
        address to,
        uint256 tokenId,
        uint256 amount
    ) external onlyRole(MINTER_ROLE) whenNotPaused nonReentrant validTokenId(tokenId) validTheory(tokenId) {
        if (to == address(0)) revert ZeroAddress();

        CosmicCodexStorage storage $ = _getCosmicCodexStorage();

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
     * @notice Mint multiple cosmic codex pages to an address
     * @param to Recipient address
     * @param tokenIds Array of token IDs (theory numbers 1-50)
     * @param amounts Array of amounts to mint for each token
     */
    function mintBatch(
        address to,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts
    ) external onlyRole(MINTER_ROLE) whenNotPaused nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (tokenIds.length != amounts.length) revert("Length mismatch");

        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
        uint256 walletLimit = $.maxMintsPerWallet;

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (tokenIds[i] < MIN_TOKEN_ID || tokenIds[i] > MAX_TOKEN_ID) {
                revert InvalidTokenId(tokenIds[i]);
            }
            if (!$.theories[tokenIds[i]].active) {
                revert TheoryNotActive(tokenIds[i]);
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
     * @notice Mint the basic collection (illustrations only, tokens 1-50) to an address
     * @param to Recipient address
     */
    function mintBasicCollection(address to) external onlyRole(MINTER_ROLE) whenNotPaused nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
        uint256 walletLimit = $.maxMintsPerWallet;

        uint256[] memory tokenIds = new uint256[](BASIC_COLLECTION_SIZE);
        uint256[] memory amounts = new uint256[](BASIC_COLLECTION_SIZE);

        for (uint256 i = 0; i < BASIC_COLLECTION_SIZE; i++) {
            uint256 tokenId = i + 1;
            if (!$.theories[tokenId].active) {
                revert TheoryNotActive(tokenId);
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
        $.totalMinted += BASIC_COLLECTION_SIZE;
    }

    /**
     * @notice Mint the complete collection (all 62 tokens: 50 illustrations + 12 gallery) to an address
     * @param to Recipient address
     */
    function mintCompleteCollection(address to) external onlyRole(MINTER_ROLE) whenNotPaused nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
        uint256 walletLimit = $.maxMintsPerWallet;

        uint256[] memory tokenIds = new uint256[](MAX_TOKEN_ID);
        uint256[] memory amounts = new uint256[](MAX_TOKEN_ID);

        for (uint256 i = 0; i < MAX_TOKEN_ID; i++) {
            uint256 tokenId = i + 1;
            if (!$.theories[tokenId].active) {
                revert TheoryNotActive(tokenId);
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
     * @param tokenId Token ID (theory number 1-50)
     */
    function uri(uint256 tokenId) public view override validTokenId(tokenId) returns (string memory) {
        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
        TheoryMetadata storage theory = $.theories[tokenId];

        if (!theory.active && theory.theoryId == 0) {
            revert TheoryNotFound(tokenId);
        }

        if (address($.metadataDescriptor) == address(0)) {
            revert InvalidMetadataDescriptor();
        }

        return $.metadataDescriptor.tokenURI(
            tokenId,
            ICosmicCodexMetadataDescriptor.TheoryData({
                theoryId: theory.theoryId,
                title: theory.title,
                description: theory.description,
                imageUri: theory.imageUri,
                category: uint8(theory.category),
                difficulty: uint8(theory.difficulty)
            }),
            ICosmicCodexMetadataDescriptor.CollectionConfig({
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
     * @notice Register a new theory
     * @param theoryId Theory number (1-50)
     * @param title Theory title
     * @param description Theory description
     * @param imageUri IPFS URI for the illustration
     * @param category Category of the theory
     * @param difficulty Difficulty level
     */
    function registerTheory(
        uint256 theoryId,
        string calldata title,
        string calldata description,
        string calldata imageUri,
        Category category,
        Difficulty difficulty
    ) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (theoryId < MIN_TOKEN_ID || theoryId > MAX_TOKEN_ID) revert InvalidTokenId(theoryId);
        if (category == Category.None) revert InvalidCategory();
        if (difficulty == Difficulty.None) revert InvalidDifficulty();

        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
        if ($.theories[theoryId].active) revert TheoryAlreadyRegistered(theoryId);

        $.theories[theoryId] = TheoryMetadata({
            theoryId: uint16(theoryId),
            title: title,
            description: description,
            imageUri: imageUri,
            category: category,
            difficulty: difficulty,
            active: true
        });

        emit TheoryRegistered(theoryId, title, category, difficulty);
    }

    /**
     * @notice Batch register multiple theories
     * @param theoryIds Array of theory IDs
     * @param titles Array of titles
     * @param descriptions Array of descriptions
     * @param imageUris Array of IPFS URIs
     * @param categories Array of categories
     * @param difficulties Array of difficulties
     */
    function registerTheoriesBatch(
        uint256[] calldata theoryIds,
        string[] calldata titles,
        string[] calldata descriptions,
        string[] calldata imageUris,
        Category[] calldata categories,
        Difficulty[] calldata difficulties
    ) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (theoryIds.length != titles.length ||
            theoryIds.length != descriptions.length ||
            theoryIds.length != imageUris.length ||
            theoryIds.length != categories.length ||
            theoryIds.length != difficulties.length) {
            revert("Length mismatch");
        }

        CosmicCodexStorage storage $ = _getCosmicCodexStorage();

        for (uint256 i = 0; i < theoryIds.length; i++) {
            uint256 theoryId = theoryIds[i];
            if (theoryId < MIN_TOKEN_ID || theoryId > MAX_TOKEN_ID) revert InvalidTokenId(theoryId);
            if (categories[i] == Category.None) revert InvalidCategory();
            if (difficulties[i] == Difficulty.None) revert InvalidDifficulty();
            if ($.theories[theoryId].active) revert TheoryAlreadyRegistered(theoryId);

            $.theories[theoryId] = TheoryMetadata({
                theoryId: uint16(theoryId),
                title: titles[i],
                description: descriptions[i],
                imageUri: imageUris[i],
                category: categories[i],
                difficulty: difficulties[i],
                active: true
            });

            emit TheoryRegistered(theoryId, titles[i], categories[i], difficulties[i]);
        }
    }

    /**
     * @notice Update theory metadata
     * @param theoryId Theory number (1-50)
     * @param title New title
     * @param description New description
     * @param imageUri New IPFS URI
     */
    function updateTheory(
        uint256 theoryId,
        string calldata title,
        string calldata description,
        string calldata imageUri
    ) external onlyRole(REGISTRY_ADMIN_ROLE) validTheory(theoryId) {
        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
        TheoryMetadata storage theory = $.theories[theoryId];
        theory.title = title;
        theory.description = description;
        theory.imageUri = imageUri;

        emit TheoryUpdated(theoryId);
    }

    /**
     * @notice Deactivate a theory (prevents further minting)
     * @param theoryId Theory number (1-50)
     */
    function deactivateTheory(uint256 theoryId) external onlyRole(REGISTRY_ADMIN_ROLE) {
        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
        if (!$.theories[theoryId].active) {
            revert TheoryNotFound(theoryId);
        }

        $.theories[theoryId].active = false;
        emit TheoryDeactivated(theoryId);
    }

    /**
     * @notice Reactivate a deactivated theory
     * @param theoryId Theory number (1-50)
     */
    function reactivateTheory(uint256 theoryId) external onlyRole(REGISTRY_ADMIN_ROLE) {
        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
        if ($.theories[theoryId].theoryId == 0) revert TheoryNotFound(theoryId);
        $.theories[theoryId].active = true;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get theory metadata
     * @param theoryId Theory number (1-50)
     */
    function getTheory(uint256 theoryId) external view returns (TheoryMetadata memory) {
        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
        return $.theories[theoryId];
    }

    /**
     * @notice Get all active theory IDs
     */
    function getActiveTheoryIds() external view returns (uint256[] memory) {
        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
        uint256 count = 0;
        for (uint256 i = MIN_TOKEN_ID; i <= MAX_TOKEN_ID; i++) {
            if ($.theories[i].active) count++;
        }

        uint256[] memory ids = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = MIN_TOKEN_ID; i <= MAX_TOKEN_ID; i++) {
            if ($.theories[i].active) {
                ids[index++] = i;
            }
        }

        return ids;
    }

    /**
     * @notice Get theories by category
     * @param category Category to filter by
     */
    function getTheoriesByCategory(Category category) external view returns (uint256[] memory) {
        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
        uint256 count = 0;
        for (uint256 i = MIN_TOKEN_ID; i <= MAX_TOKEN_ID; i++) {
            if ($.theories[i].active && $.theories[i].category == category) count++;
        }

        uint256[] memory ids = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = MIN_TOKEN_ID; i <= MAX_TOKEN_ID; i++) {
            if ($.theories[i].active && $.theories[i].category == category) {
                ids[index++] = i;
            }
        }

        return ids;
    }

    /**
     * @notice Get theories by difficulty
     * @param difficulty Difficulty to filter by
     */
    function getTheoriesByDifficulty(Difficulty difficulty) external view returns (uint256[] memory) {
        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
        uint256 count = 0;
        for (uint256 i = MIN_TOKEN_ID; i <= MAX_TOKEN_ID; i++) {
            if ($.theories[i].active && $.theories[i].difficulty == difficulty) count++;
        }

        uint256[] memory ids = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = MIN_TOKEN_ID; i <= MAX_TOKEN_ID; i++) {
            if ($.theories[i].active && $.theories[i].difficulty == difficulty) {
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
        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
        return $.maxSupply[tokenId];
    }

    /**
     * @notice Get total minted count across all tokens
     */
    function totalMinted() external view returns (uint256) {
        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
        return $.totalMinted;
    }

    /**
     * @notice Get collection configuration
     */
    function config() external view returns (CollectionConfig memory) {
        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
        return $.config;
    }

    /**
     * @notice Get metadata descriptor address
     */
    function metadataDescriptor() external view returns (ICosmicCodexMetadataDescriptor) {
        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
        return $.metadataDescriptor;
    }

    function name() external view returns (string memory) {
        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
        return $.config.name;
    }

    function symbol() external view returns (string memory) {
        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
        return $.config.symbol;
    }

    function contractURI() external view returns (string memory) {
        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
        if (address($.metadataDescriptor) == address(0)) {
            revert InvalidMetadataDescriptor();
        }

        return $.metadataDescriptor.contractURI(
            ICosmicCodexMetadataDescriptor.CollectionConfig({
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
        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
        return $.maxMintsPerWallet;
    }

    /**
     * @notice Get minted count for a wallet for a specific token
     * @param wallet Wallet address
     * @param tokenId Token ID
     */
    function walletMints(address wallet, uint256 tokenId) external view returns (uint256) {
        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
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
        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
        $.config = _config;
        emit ConfigUpdated();
    }

    function setMetadataDescriptor(address newDescriptor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newDescriptor == address(0)) revert InvalidMetadataDescriptor();
        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
        $.metadataDescriptor = ICosmicCodexMetadataDescriptor(newDescriptor);
        emit MetadataDescriptorUpdated(newDescriptor);
    }

    function setMaxSupply(uint256 tokenId, uint256 newMaxSupply) external onlyRole(DEFAULT_ADMIN_ROLE) validTokenId(tokenId) {
        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
        $.maxSupply[tokenId] = newMaxSupply;
        emit MaxSupplySet(tokenId, newMaxSupply);
    }

    /**
     * @notice Set max mints per wallet per token
     * @param maxMints Max mints (0 = unlimited)
     */
    function setMaxMintsPerWallet(uint256 maxMints) external onlyRole(DEFAULT_ADMIN_ROLE) {
        CosmicCodexStorage storage $ = _getCosmicCodexStorage();
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
