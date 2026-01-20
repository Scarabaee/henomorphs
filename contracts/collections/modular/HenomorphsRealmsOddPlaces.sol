// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC721BurnableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721BurnableUpgradeable.sol";
import {ERC721EnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ModularSpecimen} from "../../diamonds/modular/base/ModularSpecimen.sol";
import {IssueInfo, ItemTier, TierVariant, TraitPackEquipment} from "../../diamonds/modular/libraries/CollectionModel.sol";
import {ICollectionDiamond} from "../../diamonds/modular/interfaces/ICollectionDiamond.sol";

/**
 * @title HenomorphsRealmsOddPlaces - THE ODD PLACES
 * @notice Mission Pass collection for Henomorphs Realms ecosystem
 * @dev Production-ready implementation featuring:
 *      - Mission Pass functionality for starting missions
 *      - 5 Mission variants (Sentry Station, Mission Mars, Mission Krosno, Mission Tomb, Mission Australia)
 *      - IDardionCollection interface for DardionDropManager compatibility
 *      - Diamond system integration for rolling mint
 *      - ERC721 ownerOf for Mission system validation
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 * @custom:version 1.0.0 - The Odd Places
 */
contract HenomorphsRealmsOddPlaces is
    Initializable,
    ERC721Upgradeable,
    ERC721EnumerableUpgradeable,
    ERC721BurnableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ModularSpecimen
{

    // ==================== ROLES ====================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant DIAMOND_ROLE = keccak256("DIAMOND_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ==================== EVENTS ====================

    event ItemsDispatched(uint256 issueId, uint8 tier, uint256 amount, address indexed recipient);
    event VariantAssigned(uint256 indexed tokenId, uint8 variant, bool syncedWithDiamond);
    event MissionPassMinted(uint256 indexed tokenId, uint8 variant, address indexed recipient);
    event MintRequested(
        uint256 indexed issueId,
        uint8 indexed tier,
        address indexed recipient,
        uint8 variant,
        uint256 quantity
    );

    // ==================== ERRORS ====================

    error InvalidMintParameters();
    error InvalidVariant(uint8 variant);
    error CollectionNotConfigured();
    error IssueNotSupported(uint256 issueId);
    error VariantSupplyExceeded(uint8 variant);
    error CollectionSoldOut();
    error TierNotFound(uint8 tier);
    error DiamondSyncFailed(uint256 tokenId, uint8 variant);
    error RollingNotSupported();

    // ==================== STATE VARIABLES ====================

    // URI configuration
    string private _contractUri;
    string public uriSuffix;

    // Collection tracking
    mapping(uint256 => mapping(uint8 => uint256)) private _itemsCounters;
    mapping(address => mapping(uint256 => mapping(uint8 => uint256))) private _itemsCollected;
    mapping(uint256 => mapping(uint8 => mapping(uint256 => uint8))) private _itemsVariants;

    // Collection state
    uint256 private _tokenIdCounter;
    uint256 public maxSupply;

    // Mission Pass specific mappings
    mapping(uint256 => string) private _variantNames;

    // DardionDropManager support
    uint256 public dropId;
    bool public rollingEnabled;

    // Internal struct to reduce stack depth in _mintVariant
    struct MintContext {
        uint256 issueId;
        uint8 tier;
        uint8 variant;
        address recipient;
    }


    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize The Odd Places Mission Pass collection
     * @param _name Collection name
     * @param _symbol Collection symbol
     * @param contractUri Contract metadata URI
     * @param diamondAddress Diamond contract address
     * @param newCollectionId Collection ID (5 for Odd Places)
     * @param issue Default issue ID
     * @param tier Default tier
     * @param maxSupply_ Maximum supply (1000)
     */
    function initialize(
        string memory _name,
        string memory _symbol,
        string memory contractUri,
        address diamondAddress,
        uint256 newCollectionId,
        uint256 issue,
        uint8 tier,
        uint256 maxSupply_
    ) public initializer {
        __ERC721_init(_name, _symbol);
        __ERC721Enumerable_init();
        __ERC721Burnable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        __ModularSpecimen_init(diamondAddress, newCollectionId, issue, tier);

        // Grant roles to deployer
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(DIAMOND_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);

        // Set configuration
        _contractUri = contractUri;
        uriSuffix = ".json";
        maxSupply = maxSupply_;
        rollingEnabled = true;

        _tokenIdCounter = 1;

        // Initialize Mission variant names
        _initializeVariantNames();
    }

    /**
     * @notice Initialize The Odd Places mission variant names
     */
    function _initializeVariantNames() internal {
        _variantNames[0] = "Sentry Station";
        _variantNames[1] = "Mission Mars";
        _variantNames[2] = "Mission Krosno";
        _variantNames[3] = "Mission Tomb";
        _variantNames[4] = "Mission Australia";
    }

    // ==================== IDARDION COLLECTION INTERFACE ====================

    /**
     * @notice Get the collection type
     * @return Collection type string
     */
    function getCollectionType() external pure returns (string memory) {
        return "ERC721";
    }

    /**
     * @notice Get the drop ID for DardionDropManager
     * @return The drop ID
     */
    function getDropId() external view returns (uint256) {
        return dropId;
    }

    /**
     * @notice Standard mint without variant - uses default variant (0)
     * @dev Called by DardionDropManager.mint()
     * @param to Recipient address
     * @param quantity Number of tokens to mint
     * @return tokenIds Array of minted token IDs
     */
    function mintTokens(
        address to,
        uint256 quantity,
        bytes calldata /*data*/
    ) external onlyRole(MINTER_ROLE) nonReentrant whenNotPaused returns (uint256[] memory tokenIds) {
        (tokenIds,) = _mintVariant(defaultIssue, defaultTier, 0, to, quantity);
        return tokenIds;
    }

    /**
     * @notice Mint with specific variant
     * @dev Called by DardionDropManager.mintWithVariant() or mintFromTierWithVariant()
     * @param to Recipient address
     * @param quantity Number of tokens to mint
     * @param variantId Variant ID (0-4)
     * @return tokenIds Array of minted token IDs
     */
    function mintTokensWithVariant(
        address to,
        uint256 quantity,
        uint256 variantId,
        bytes32 /* reservationId */,
        bytes calldata /*data*/
    ) external onlyRole(MINTER_ROLE) nonReentrant whenNotPaused returns (uint256[] memory tokenIds) {
        if (!rollingEnabled) {
            revert RollingNotSupported();
        }

        uint8 tier;
        uint8 variant;

        if (variantId > 255) {
            // Combined format: tierId in upper bits
            tier = uint8(variantId >> 8);
            variant = uint8(variantId & 0xFF);
        } else {
            // Simple format: use default tier
            tier = defaultTier;
            variant = uint8(variantId);
        }

        (tokenIds,) = _mintVariant(defaultIssue, tier, variant, to, quantity);
        return tokenIds;
    }

    /**
     * @notice Check if rolling mint is supported
     * @return Whether rolling is enabled
     */
    function supportsRolling() external view returns (bool) {
        return rollingEnabled;
    }

    /**
     * @notice Get token variant for DardionDropManager
     * @param tokenId Token ID
     * @return Variant ID
     */
    function getTokenVariant(uint256 tokenId) external view returns (uint256) {
        return _itemsVariants[defaultIssue][defaultTier][tokenId];
    }

    /**
     * @notice Get current supply
     * @return Current number of minted tokens
     */
    function getCurrentSupply() external view returns (uint256) {
        return totalSupply();
    }

    /**
     * @notice Get maximum supply
     * @return Maximum supply
     */
    function getMaxSupply() external view returns (uint256) {
        return maxSupply;
    }

    /**
     * @notice Check if supply is exhausted
     * @return Whether all tokens have been minted
     */
    function isSupplyExhausted() external view returns (bool) {
        return totalSupply() >= maxSupply;
    }

    // ==================== MINTING FUNCTIONS ====================

    /**
     * @notice Standard mintVariant interface required by MintingFacet
     */
    function mintVariant(
        uint256 issueId,
        uint8 tier,
        uint8 variant,
        address recipient,
        uint256 quantity
    ) external onlyRole(MINTER_ROLE) nonReentrant whenNotPaused returns (uint256[] memory tokenIds) {
        (tokenIds,) = _mintVariant(issueId, tier, variant, recipient, quantity);
        return tokenIds;
    }

    /**
     * @notice Extended mint variant for MintingFacet integration
     */
    function mintVariantExtended(
        uint256 issueId,
        uint8 tier,
        uint8 variant,
        address recipient,
        uint256 quantity
    ) external onlyRole(MINTER_ROLE) nonReentrant whenNotPaused returns (
        uint256[] memory tokenIds,
        uint8 assignedVariant,
        uint256 totalPaid
    ) {
        (tokenIds,) = _mintVariant(issueId, tier, variant, recipient, quantity);
        assignedVariant = variant;
        totalPaid = 0;
        return (tokenIds, assignedVariant, totalPaid);
    }

    /**
     * @notice Mint with variant assignment - primary interface for MintingFacet
     * @dev Called by MintingFacet._executeMinting() as first attempt
     * @param issueId Issue ID
     * @param tier Tier ID
     * @param variant Variant ID (0-4)
     * @param recipient Recipient address
     * @param quantity Number of tokens to mint
     * @return tokenIds Array of minted token IDs
     * @return variants Array of assigned variants
     */
    function mintWithVariantAssignment(
        uint256 issueId,
        uint8 tier,
        uint8 variant,
        address recipient,
        uint256 quantity,
        address /* specimenCollection */,
        uint256 /* specimenTokenId */
    ) external onlyRole(MINTER_ROLE) nonReentrant whenNotPaused returns (
        uint256[] memory tokenIds,
        uint8[] memory variants
    ) {
        // Mission Pass nie wymaga specimen assignment, więc ignorujemy te parametry
        // ale zachowujemy sygnaturę dla kompatybilności z MintingFacet
        return _mintVariant(issueId, tier, variant, recipient, quantity);
    }

    function _mintVariant(
        uint256 issueId,
        uint8 tier,
        uint8 variant,
        address recipient,
        uint256 quantity
    ) internal returns (uint256[] memory tokenIds, uint8[] memory variants) {
        emit MintRequested(issueId, tier, recipient, variant, quantity);

        if (quantity == 0 || recipient == address(0)) {
            revert InvalidMintParameters();
        }
        if (variant > 4) {
            revert InvalidVariant(variant);
        }

        uint256 tierSupply = _getCollectionMaxSupply(collectionId, tier);
        _validateIssueAndTier(issueId, tier);

        if (_itemsCounters[issueId][tier] + quantity > tierSupply) {
            revert CollectionSoldOut();
        }

        tokenIds = new uint256[](quantity);
        variants = new uint8[](quantity);

        MintContext memory ctx = MintContext({
            issueId: issueId,
            tier: tier,
            variant: variant,
            recipient: recipient
        });

        for (uint256 i = 0; i < quantity; i++) {
            (tokenIds[i], variants[i]) = _processSingleMint(ctx);
        }

        emit ItemsDispatched(issueId, tier, quantity, recipient);
        return (tokenIds, variants);
    }

    /**
     * @dev Internal function to process a single mint
     */
    function _processSingleMint(MintContext memory ctx) private returns (uint256 tokenId, uint8 assignedVariant) {
        tokenId = _getNextTokenId(ctx.issueId, ctx.tier);

        _safeMint(ctx.recipient, tokenId);
        _notifyTokenMinted(tokenId, ctx.recipient);

        assignedVariant = ctx.variant;

        bool syncSuccess = _assignVariantToToken(ctx.issueId, ctx.tier, tokenId, assignedVariant);

        unchecked {
            _itemsCounters[ctx.issueId][ctx.tier] += 1;
            _itemsCollected[ctx.recipient][ctx.issueId][ctx.tier] += 1;
        }

        emit VariantAssigned(tokenId, assignedVariant, syncSuccess);
        emit MissionPassMinted(tokenId, assignedVariant, ctx.recipient);

        return (tokenId, assignedVariant);
    }

    /**
     * @notice Admin mint function - mints tokens with specific variants and IDs
     */
    function adminMintWithVariants(
        uint256 issueId,
        uint8 tier,
        uint256[] calldata tokenIds,
        uint8[] calldata variants,
        address[] calldata recipients
    ) external onlyRole(ADMIN_ROLE) nonReentrant whenNotPaused {
        if (tokenIds.length == 0) {
            revert InvalidMintParameters();
        }
        if (tokenIds.length != variants.length || tokenIds.length != recipients.length) {
            revert InvalidMintParameters();
        }

        _validateIssueAndTier(issueId, tier);

        uint256 tierSupply = _getCollectionMaxSupply(collectionId, tier);
        if (_itemsCounters[issueId][tier] + tokenIds.length > tierSupply) {
            revert CollectionSoldOut();
        }

        _processAdminBatchMint(issueId, tier, tokenIds, variants, recipients);

        emit ItemsDispatched(issueId, tier, tokenIds.length, address(0));
    }

    /**
     * @dev Internal function to process admin batch mint
     */
    function _processAdminBatchMint(
        uint256 issueId,
        uint8 tier,
        uint256[] calldata tokenIds,
        uint8[] calldata variants,
        address[] calldata recipients
    ) private {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _processAdminSingleMint(issueId, tier, tokenIds[i], variants[i], recipients[i]);
        }
    }

    /**
     * @dev Internal function to process single admin mint
     */
    function _processAdminSingleMint(
        uint256 issueId,
        uint8 tier,
        uint256 tokenId,
        uint8 variant,
        address recipient
    ) private {
        if (recipient == address(0)) {
            revert InvalidMintParameters();
        }
        if (variant > 4) {
            revert InvalidVariant(variant);
        }

        if (_tokenExists(tokenId)) {
            return;
        }

        _safeMint(recipient, tokenId);
        _notifyTokenMinted(tokenId, recipient);

        bool syncSuccess = _assignVariantToToken(issueId, tier, tokenId, variant);

        unchecked {
            _itemsCounters[issueId][tier] += 1;
            _itemsCollected[recipient][issueId][tier] += 1;
        }

        emit VariantAssigned(tokenId, variant, syncSuccess);
        emit MissionPassMinted(tokenId, variant, recipient);
    }

    /**
     * @notice Assign variant to existing token
     */
    function assignVariant(
        uint256 issueId,
        uint8 tier,
        uint256 tokenId,
        uint8 variant
    ) external onlyRole(MINTER_ROLE) returns (uint8 assignedVariant) {
        if (!_tokenExists(tokenId)) {
            revert ERC721NonexistentToken(tokenId);
        }
        if (variant > 4) {
            revert InvalidVariant(variant);
        }

        uint8 currentVariant = _itemsVariants[issueId][tier][tokenId];
        if (currentVariant != 0) {
            revert InvalidVariant(currentVariant);
        }

        bool success = _assignVariantToToken(issueId, tier, tokenId, variant);
        if (!success) {
            revert DiamondSyncFailed(tokenId, variant);
        }

        return variant;
    }

    /**
     * @notice Reset token variant to 0 for rolling
     */
    function resetVariant(uint256 issueId, uint8 tier, uint256 tokenId) external onlyRole(DIAMOND_ROLE) {
        if (!_tokenExists(tokenId)) {
            revert ERC721NonexistentToken(tokenId);
        }

        _itemsVariants[issueId][tier][tokenId] = 0;
    }

    // ==================== TOKEN ID GENERATION ====================

    function _getNextTokenId(uint256 issueId, uint8 tier) internal view returns (uint256) {
        try diamond.getCollectionItemInfo(issueId, tier) returns (
            IssueInfo memory,
            ItemTier memory tierInfo
        ) {
            uint256 offset = _itemsCounters[issueId][tier] + tierInfo.offset;
            return offset + 1;
        } catch {
            return _tokenIdCounter + _itemsCounters[issueId][tier];
        }
    }

    // ==================== VARIANT MANAGEMENT ====================

    function _assignVariantToToken(
        uint256 issueId,
        uint8 tier,
        uint256 tokenId,
        uint8 variant
    ) internal returns (bool success) {
        _itemsVariants[issueId][tier][tokenId] = variant;

        success = true;
        if (address(diamond) != address(0) && collectionId != 0) {
            try diamond.onVariantAssigned(collectionId, tokenId, variant) {
                // Diamond sync successful
            } catch {
                success = false;
            }
        }

        return success;
    }

    // ==================== VIEW FUNCTIONS ====================

    function itemVariant(uint256 tokenId) external view override returns (uint8) {
        if (_ownerOf(tokenId) == address(0)) {
            return 0;
        }

        uint8 localVariant = _itemsVariants[defaultIssue][defaultTier][tokenId];

        if (address(diamond) != address(0)) {
            try diamond.getTokenVariant(collectionId, tokenId) returns (uint8 diamondVariant) {
                return diamondVariant;
            } catch {
                return localVariant;
            }
        }

        return localVariant;
    }

    function itemEquipments(uint256 tokenId) external view override returns (uint8[] memory) {
        if (_ownerOf(tokenId) == address(0)) {
            return new uint8[](0);
        }

        try this.getTokenEquipment(tokenId) returns (TraitPackEquipment memory equipment) {
            uint8[] memory accessories = new uint8[](equipment.accessoryIds.length);
            for (uint256 i = 0; i < equipment.accessoryIds.length; i++) {
                accessories[i] = uint8(equipment.accessoryIds[i]);
            }
            return accessories;
        } catch {
            return new uint8[](0);
        }
    }

    /**
     * @notice Get mission variant name for a token
     */
    function getVariantName(uint256 tokenId) external view returns (string memory) {
        if (!_tokenExists(tokenId)) {
            return "";
        }

        uint8 variant = this.itemVariant(tokenId);
        return _variantNames[variant];
    }

    /**
     * @notice Get mission variant for a token (alias for Mission system)
     */
    function getMissionVariant(uint256 tokenId) external view returns (uint8) {
        return this.itemVariant(tokenId);
    }

    function getAllVariantNames() external view returns (string[] memory) {
        string[] memory names = new string[](5);
        for (uint256 i = 0; i < 5; i++) {
            names[i] = _variantNames[i];
        }
        return names;
    }

    function totalItemsSupply(uint256 issueId, uint8 tier) external view returns (uint256) {
        return _itemsCounters[issueId][tier];
    }

    function collectedOf(address account, uint256 issueId, uint8 tier) external view returns (uint256) {
        return _itemsCollected[account][issueId][tier];
    }

    function hasTraitPack(uint256 tokenId) external view returns (bool) {
        return hasAugment(tokenId);
    }

    // ==================== TOKEN URI ====================

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return _generateTokenURI(tokenId);
    }

    function contractURI() public view returns (string memory) {
        return _contractUri;
    }

    // ==================== PAUSABLE FUNCTIONS ====================

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ==================== ADMIN FUNCTIONS ====================

    function setContractURI(string memory contractUri) external onlyRole(ADMIN_ROLE) {
        _contractUri = contractUri;
    }

    function setUriSuffix(string memory suffix) external onlyRole(ADMIN_ROLE) {
        uriSuffix = suffix;
    }

    function setMaxSupply(uint256 newMaxSupply) external onlyRole(ADMIN_ROLE) {
        require(newMaxSupply >= totalSupply(), "Cannot set below current supply");
        maxSupply = newMaxSupply;
    }

    function setVariantName(uint8 variant, string memory name) external onlyRole(ADMIN_ROLE) {
        require(variant <= 4, "Invalid variant");
        _variantNames[variant] = name;
    }

    function setDropId(uint256 _dropId) external onlyRole(ADMIN_ROLE) {
        dropId = _dropId;
    }

    function setRollingEnabled(bool enabled) external onlyRole(ADMIN_ROLE) {
        rollingEnabled = enabled;
    }

    /**
     * @notice Grant minter role (for DardionDropManager integration)
     */
    function grantMinterRole(address account) external onlyRole(ADMIN_ROLE) {
        _grantRole(MINTER_ROLE, account);
    }

    /**
     * @notice Revoke minter role
     */
    function revokeMinterRole(address account) external onlyRole(ADMIN_ROLE) {
        _revokeRole(MINTER_ROLE, account);
    }

    // ==================== INTERNAL HELPER FUNCTIONS ====================

    function _getCollectionMaxSupply(uint256 _collectionId, uint8 tier) internal view returns (uint256 configuredMaxSupply) {
        if (address(diamond) == address(0)) {
            return maxSupply;
        }

        try diamond.getCollectionItemInfo(_collectionId, tier) returns (
            IssueInfo memory,
            ItemTier memory tierInfo
        ) {
            return tierInfo.maxSupply > 0 ? tierInfo.maxSupply : maxSupply;
        } catch {
            return maxSupply;
        }
    }

    function _validateIssueAndTier(uint256 issueId, uint8 tier) internal view {
        if (address(diamond) == address(0)) {
            return;
        }

        try diamond.getCollectionItemInfo(issueId, tier) returns (
            IssueInfo memory issueInfo,
            ItemTier memory tierInfo
        ) {
            if (issueInfo.issueId == 0) {
                revert IssueNotSupported(issueId);
            }
            if (tierInfo.tier == 0) {
                revert TierNotFound(tier);
            }
        } catch {
            revert IssueNotSupported(issueId);
        }
    }

    function _tokenExists(uint256 tokenId) internal view override returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    function _checkDiamondPermission() internal view override {
        _checkRole(DIAMOND_ROLE);
    }

    // ==================== REQUIRED OVERRIDES ====================

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override(ERC721Upgradeable, ERC721EnumerableUpgradeable) returns (address) {
        address from = _ownerOf(tokenId);

        if (from != address(0) && to != address(0)) {
            _notifyTokenTransferred(tokenId, from, to);
        }

        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value)
        internal
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
    {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId) public view override(AccessControlUpgradeable, ERC721EnumerableUpgradeable, ERC721Upgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function isApprovedForAll(address owner, address operator) public view override(ERC721Upgradeable, IERC721) returns (bool) {
        // OpenSea proxy approval
        if (operator == address(0x58807baD0B376efc12F5AD86aAc70E78ed67deaE)) {
            return true;
        }
        return super.isApprovedForAll(owner, operator);
    }
}
