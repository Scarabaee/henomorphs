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
import {LibCollectionStorage} from "../../diamonds/modular/libraries/LibCollectionStorage.sol";
import {ModularSpecimen} from "../../diamonds/modular/base/ModularSpecimen.sol";
import {ISpecimenCollection, IStaking} from "../../diamonds/modular/interfaces/IExternalSystems.sol";
import {IssueInfo, ItemTier, TierVariant, TraitPackEquipment} from "../../diamonds/modular/libraries/CollectionModel.sol";
import {ICollectionDiamond} from "../../diamonds/modular/interfaces/ICollectionDiamond.sol";

/**
 * @title HenomorphsAugmentsV2 - DIGITAL AWAKENING
 * @notice Advanced Matrix-themed augmentation collection with Diamond integration
 * @dev Production-ready implementation compatible with OpenZeppelin v5 featuring:
 *      - Matrix-themed trait packs (FOLLOW THE RABBIT, THERE IS NO SPOON, etc.)
 *      - Enhanced bonuses and compatibility with Henomorphs Matrix collection
 *      - Standard mintVariant interface for ecosystem compatibility
 *      - Synchronized variant management with Diamond system
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 * @custom:version 2.0.0 - Digital Awakening (Matrix Compatible)
 */
contract HenomorphsAugmentsV2 is 
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
    event DigitalAwakeningMinted(uint256 indexed tokenId, uint8 variant, address indexed recipient);
    event MatrixCompatibilityEnabled(uint256 indexed tokenId, bool enabled);
    event AssignmentRequested(uint256 indexed augmentTokenId, address indexed targetCollection, uint256 indexed targetTokenId);
    event AssignmentCompleted(uint256 indexed augmentTokenId, address indexed specimenCollection, uint256 indexed specimenTokenId);
    event TransferBlocked(uint256 indexed tokenId, string reason);
    event MintRequested(
        uint256 indexed issueId,
        uint8 indexed tier,
        address indexed recipient,
        uint8 variant,
        uint256 quantity,
        address specimenCollection,
        uint256 specimenTokenId
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
    error InvalidTokenAccess(address collection, uint256 tokenId, address caller);
    error TransferIsBlocked(uint256 tokenId, string reason);

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

    // Vol.2 specific mappings
    mapping(uint256 => string) private _variantNames;
    mapping(uint256 => bool) private _matrixCompatible;

    // Pending assignments for auto-assignment
    struct PendingAssignment {
        address specimenCollection;
        uint256 specimenTokenId;
        uint256 timestamp;
        bool processed;
    }
    mapping(uint256 => PendingAssignment) private _pendingAssignments;

    // Internal struct to reduce stack depth in _mintVariant
    struct MintContext {
        uint256 issueId;
        uint8 tier;
        uint8 variant;
        address recipient;
        address specimenCollection;
        uint256 specimenTokenId;
    }
    

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the Digital Awakening collection
     * @param _name Collection name
     * @param _symbol Collection symbol  
     * @param contractUri Contract metadata URI
     * @param diamondAddress Diamond contract address
     * @param newCollectionId Collection ID (4 for vol.2)
     * @param issue Default issue ID
     * @param tier Default tier
     * @param maxSupply_ Maximum supply (1800)
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
        
        _tokenIdCounter = 1;

        // Initialize vol.2 variant names
        _initializeVariantNames();
    }

    /**
     * @notice Initialize Digital Awakening variant names
     */
    function _initializeVariantNames() internal {
        _variantNames[0] = "Digital Core";
        _variantNames[1] = "FOLLOW THE RABBIT";
        _variantNames[2] = "THERE IS NO SPOON";
        _variantNames[3] = "DODGE THIS";
        _variantNames[4] = "I AM THE ONE";
    }

    // ==================== MINTING FUNCTIONS ====================

    /**
     * @notice Complete MintingFacet interface - main minting function
     * @dev Supports both specimen-based and default minting
     */
    function mintWithVariantAssignment(
        uint256 issueId,
        uint8 tier,
        uint8 variant,
        address recipient,
        uint256 quantity,
        address specimenCollection,
        uint256 specimenTokenId
    ) external onlyRole(MINTER_ROLE) nonReentrant whenNotPaused returns (uint256[] memory tokenIds, uint8[] memory variants) {
        return _mintVariant(issueId, tier, variant, recipient, quantity, specimenCollection, specimenTokenId);
    }

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
        (tokenIds,) = _mintVariant(issueId, tier, variant, recipient, quantity, address(0), 0);
        return (tokenIds);
    }

    /**
     * @notice Extended mint variant with specimen support for MintingFacet integration
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
        (tokenIds,) = _mintVariant(issueId, tier, variant, recipient, quantity, address(0), 0);
        assignedVariant = variant;
        totalPaid = 0;
        return (tokenIds, assignedVariant, totalPaid);
    }

    function _mintVariant(
        uint256 issueId,
        uint8 tier,
        uint8 variant,
        address recipient,
        uint256 quantity,
        address specimenCollection,
        uint256 specimenTokenId
    ) internal returns (uint256[] memory tokenIds, uint8[] memory variants) {
        // Emit the event at the beginning
        emit MintRequested(
            issueId,
            tier,
            recipient,
            variant,
            quantity,
            specimenCollection,
            specimenTokenId
        );

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

        // Use struct to reduce stack depth
        MintContext memory ctx = MintContext({
            issueId: issueId,
            tier: tier,
            variant: variant,
            recipient: recipient,
            specimenCollection: specimenCollection,
            specimenTokenId: specimenTokenId
        });

        for (uint256 i = 0; i < quantity; i++) {
            (tokenIds[i], variants[i]) = _processSingleMint(ctx);
        }

        emit ItemsDispatched(issueId, tier, quantity, recipient);
        return (tokenIds, variants);
    }

    /**
     * @dev Internal function to process a single mint, extracted to reduce stack depth
     */
    function _processSingleMint(MintContext memory ctx) private returns (uint256 tokenId, uint8 assignedVariant) {
        tokenId = _getNextTokenId(ctx.issueId, ctx.tier);

        _safeMint(ctx.recipient, tokenId);
        _notifyTokenMinted(tokenId, ctx.recipient);

        // Determine assigned variant
        if (ctx.variant == 0) {
            // Digital Core - for later rolling
            assignedVariant = 0;
        } else if (ctx.variant >= 1 && ctx.variant <= 4) {
            assignedVariant = ctx.variant;
        } else {
            assignedVariant = 0;
        }

        // All variants are matrix compatible
        _matrixCompatible[tokenId] = true;

        bool syncSuccess = _assignVariantToToken(ctx.issueId, ctx.tier, tokenId, assignedVariant);

        unchecked {
            _itemsCounters[ctx.issueId][ctx.tier] += 1;
            _itemsCollected[ctx.recipient][ctx.issueId][ctx.tier] += 1;
        }

        // Store pending assignment for processing by MintingFacet
        if (ctx.specimenCollection != address(0) &&
            ctx.specimenTokenId > 0 &&
            assignedVariant > 0) {

            _pendingAssignments[tokenId] = PendingAssignment({
                specimenCollection: ctx.specimenCollection,
                specimenTokenId: ctx.specimenTokenId,
                timestamp: block.timestamp,
                processed: false
            });

            emit AssignmentRequested(tokenId, ctx.specimenCollection, ctx.specimenTokenId);
        }

        emit VariantAssigned(tokenId, assignedVariant, syncSuccess);
        emit DigitalAwakeningMinted(tokenId, assignedVariant, ctx.recipient);
        emit MatrixCompatibilityEnabled(tokenId, true);

        return (tokenId, assignedVariant);
    }
    
    /**
     * @notice Admin mint function - mints tokens with specific variants and IDs
     * @param issueId Issue ID for the tokens
     * @param tier Tier for the tokens
     * @param tokenIds Array of specific token IDs to mint
     * @param variants Array of variants to assign (must match tokenIds length)
     * @param recipients Array of recipient addresses (must match tokenIds length)
     */
    function adminMintWithVariants(
        uint256 issueId,
        uint8 tier,
        uint256[] calldata tokenIds,
        uint8[] calldata variants,
        address[] calldata recipients
    ) external onlyRole(ADMIN_ROLE) nonReentrant whenNotPaused {
        // Validate input arrays
        if (tokenIds.length == 0) {
            revert InvalidMintParameters();
        }
        if (tokenIds.length != variants.length || tokenIds.length != recipients.length) {
            revert InvalidMintParameters();
        }

        // Validate issue and tier
        _validateIssueAndTier(issueId, tier);

        // Check supply limits
        uint256 tierSupply = _getCollectionMaxSupply(collectionId, tier);
        if (_itemsCounters[issueId][tier] + tokenIds.length > tierSupply) {
            revert CollectionSoldOut();
        }

        // Process each token
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            uint8 variant = variants[i];
            address recipient = recipients[i];

            // Validate parameters
            if (recipient == address(0)) {
                revert InvalidMintParameters();
            }
            if (variant > 4) {
                revert InvalidVariant(variant);
            }

            // Check if token already exists
            if (_tokenExists(tokenId)) {
                continue; // Skip existing tokens
            }

            // Mint the token
            _safeMint(recipient, tokenId);

            // Notify Diamond about mint
            _notifyTokenMinted(tokenId, recipient);

            // Assign variant and sync with Diamond
            bool syncSuccess = _assignVariantToToken(issueId, tier, tokenId, variant);

            // Set Matrix compatibility for variants 1-4
            if (variant >= 1 && variant <= 4) {
                _matrixCompatible[tokenId] = true;
            }

            // Update counters
            unchecked {
                _itemsCounters[issueId][tier] += 1;
                _itemsCollected[recipient][issueId][tier] += 1;
            }

            // Emit events
            emit VariantAssigned(tokenId, variant, syncSuccess);
            emit DigitalAwakeningMinted(tokenId, variant, recipient);
            emit MatrixCompatibilityEnabled(tokenId, variant >= 1 && variant <= 4);
        }

        // Emit batch dispatch event
        emit ItemsDispatched(issueId, tier, tokenIds.length, address(0)); // address(0) for batch
    }

    /**
     * @notice Assign variant to existing token (called by MintingFacet or admin)
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
        
        // Check current variant - must be 0 for assignment
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
     * @notice Reset token variant to 0 for rolling (called by Diamond admin)
     */
    function resetVariant(uint256 issueId, uint8 tier, uint256 tokenId) external onlyRole(DIAMOND_ROLE) {
        if (!_tokenExists(tokenId)) {
            revert ERC721NonexistentToken(tokenId);
        }
        
        _itemsVariants[issueId][tier][tokenId] = 0;
    }

    // ==================== ASSIGNMENT PROCESSING ====================

    function processAssignment(uint256 augmentTokenId) external onlyRole(ADMIN_ROLE) returns (bool success) {
        PendingAssignment storage assignment = _pendingAssignments[augmentTokenId];
        
        if (assignment.timestamp == 0) {
            revert("Assignment not found");
        }
        
        if (assignment.processed) {
            revert("Assignment already processed");
        }
        
        address augmentOwner = ownerOf(augmentTokenId);
        if (!_validateTokenAccess(assignment.specimenCollection, assignment.specimenTokenId, augmentOwner)) {
            revert InvalidTokenAccess(assignment.specimenCollection, assignment.specimenTokenId, augmentOwner);
        }
        
        assignment.processed = true;
        
        success = true;
        emit AssignmentCompleted(augmentTokenId, assignment.specimenCollection, assignment.specimenTokenId);
        
        return success;
    }

    function getPendingAssignment(uint256 tokenId) external view returns (PendingAssignment memory assignment) {
        return _pendingAssignments[tokenId];
    }

    function hasPendingAssignment(uint256 tokenId) external view returns (bool hasPending) {
        PendingAssignment memory assignment = _pendingAssignments[tokenId];
        return assignment.timestamp > 0 && !assignment.processed;
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

    // ==================== ACCESS VALIDATION ====================

    function _validateTokenAccess(
        address collectionAddress,
        uint256 tokenId,
        address caller
    ) internal view returns (bool) {
        if (collectionAddress == address(0) || caller == address(0)) return false;

        if (hasRole(DEFAULT_ADMIN_ROLE, caller) || hasRole(ADMIN_ROLE, caller)) {
            return true;
        }

        try IERC721(collectionAddress).ownerOf(tokenId) returns (address owner) {
            
            if (owner == caller) return true;

            if (_isStakedByUser(collectionAddress, tokenId, caller, owner)) {
                return true;
            }

            try IERC721(collectionAddress).isApprovedForAll(owner, caller) returns (bool approved) {
                if (approved) return true;
            } catch {}

            try IERC721(collectionAddress).getApproved(tokenId) returns (address approved) {
                if (approved == caller) return true;
            } catch {}

        } catch {
            return false;
        }

        return false;
    }

    function _isStakedByUser(
        address collectionAddress,
        uint256 tokenId,
        address user,
        address owner
    ) internal view returns (bool) {
        if (address(diamond) == address(0)) return false;

        try ICollectionDiamond(address(diamond)).getExternalSystemAddresses() 
            returns (address, address, address stakingAddress) {
            
            if (stakingAddress == address(0)) {
                return false;
            }

            try IStaking(stakingAddress).getTokenStaker(collectionAddress, tokenId) 
                returns (address staker) {
                return (staker == user || staker == owner);
            } catch {
                return false;
            }
        } catch {
            return false;
        }
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

    function getVariantName(uint256 tokenId) external view returns (string memory) {
        if (!_tokenExists(tokenId)) {
            return "";
        }
        
        uint8 variant = this.itemVariant(tokenId);
        return _variantNames[variant];
    }

    function isSpecimenCompatible(uint256 tokenId) external view returns (bool) {
        return _matrixCompatible[tokenId];
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

    // ==================== TRANSFER CONTROL ====================

    function _isTransferBlocked(uint256 tokenId) internal view returns (bool blocked, string memory reason) {
        try diamond.getAssignment(address(this), tokenId) returns (
            LibCollectionStorage.AugmentAssignment memory assignment
        ) {
            if (assignment.active) {
                if (assignment.unlockTime == 0) {
                    return (true, "permanent");
                }
                
                if (block.timestamp < assignment.unlockTime) {
                    return (true, "timelocked");
                }
                
                return (true, "active");
            }
        } catch {
            return (false, "");
        }
        
        return (false, "");
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

        // ==================== AUGMENT CALLBACKS ====================

    function onAugmentAssigned(
        uint256 tokenId,
        address augmentCollection,
        uint256 augmentTokenId
    ) external nonReentrant onlyRole(MINTER_ROLE) {
    }

    function onAugmentRemoved(
        uint256 tokenId,
        address augmentCollection,
        uint256 augmentTokenId
    ) external nonReentrant onlyRole(MINTER_ROLE) {
    }

    // ==================== INTERNAL HELPER FUNCTIONS ====================

    function _getCollectionMaxSupply(uint256 collectionId, uint8 tier) internal view returns (uint256 configuredMaxSupply) {
        if (address(diamond) == address(0)) {
            return maxSupply;
        }

        try diamond.getCollectionItemInfo(collectionId, tier) returns (
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
            (bool blocked, string memory reason) = _isTransferBlocked(tokenId);
            
            if (blocked) {
                revert TransferIsBlocked(tokenId, reason);
            }
        }
        
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
        if (operator == address(0x58807baD0B376efc12F5AD86aAc70E78ed67deaE)) {
            return true;
        }
        return super.isApprovedForAll(owner, operator);
    }
}