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
import {LibCollectionStorage} from "../libraries/LibCollectionStorage.sol";
import {ModularSpecimen} from "../base/ModularSpecimen.sol";
import {ISpecimenCollection, IStaking} from "../interfaces/IExternalSystems.sol";
import {IssueInfo, ItemTier, TierVariant, TraitPackEquipment} from"../libraries/CollectionModel.sol";
import {ICollectionDiamond} from "../interfaces/ICollectionDiamond.sol";

/**
 * @title HenomorphsMatrix
 * @notice Advanced cybernetic poultry collection with Diamond integration
 * @dev Production-ready implementation compatible with OpenZeppelin v5 featuring:
 *      - Unified mintVariant interface compatible with ecosystem
 *      - Proper tokenId generation using Diamond's tier offset system
 *      - Synchronized variant management between local and Diamond systems
 *      - Standard OpenZeppelin Pausable for emergency controls
 *      - Full OpenZeppelin v5 compatibility (no deprecated functions)
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 * @custom:version 1.0.0 - Production Ready (OZ v5 Compatible)
 */
contract HenomorphsMatrix is 
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
    event TransferBlockingStatusChanged(uint256 indexed tokenId, bool blocked, string reason);

    // ==================== ERRORS ====================
    
    error InvalidMintParameters();
    error InvalidVariant(uint8 variant);
    error CollectionNotConfigured();
    error IssueNotSupported(uint256 issueId);
    error VariantSupplyExceeded(uint8 variant);
    error CollectionSoldOut();
    error TierNotFound(uint8 tier);
    error TokenAlreadyHasVariant(uint256 tokenId, uint8 currentVariant);
    error InvalidVariantValue(uint8 variant);
    error TransferIsBlocked(uint256 tokenId, string reason);
    error DiamondSyncFailed(uint256 tokenId, uint8 variant);
    error UnstakingFailed();

    // ==================== STATE VARIABLES ====================
    
    // URI configuration
    string private _contractUri;
    string public uriSuffix;

    // Collection tracking - following HenomorphsAugments pattern
    mapping(uint256 => mapping(uint8 => uint256)) private _itemsCounters;
    mapping(address => mapping(uint256 => mapping(uint8 => uint256))) private _itemsCollected;
    mapping(uint256 => mapping(uint8 => mapping(uint256 => uint8))) private _itemsVariants;

    // Collection state
    uint256 private _tokenIdCounter;
    uint256 public maxSupply;

    // Augment assignment tracking
    mapping(uint256 => bool) private _hasAssignedAugment;
    mapping(uint256 => address) private _assignedAugmentCollection;  
    mapping(uint256 => uint256) private _assignedAugmentTokenId;
    mapping(uint256 => uint8) private _assignedAugmentVariant;

    bytes32 public constant STAKING_ROLE = keccak256("STAKING_ROLE");
    bool private _isUnstaking;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the collection contract
     * @param _name Collection name
     * @param _symbol Collection symbol
     * @param contractUri Contract metadata URI
     * @param diamondAddress Diamond contract address
     * @param newCollectionId Collection ID in Diamond system
     * @param issue Default issue ID for this collection
     * @param tier Default tier for this collection
     * @param maxSupply_ Maximum supply for this collection
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
    }

    // ==================== MINTING FUNCTIONS ====================

    /**
     * @notice Main minting function for Main collections - generates random variant
     * @dev Complete interface for MintingFacet with post-mint variant assignment
     */
    function _mintVariantedItems(
        uint256 issueId,
        uint8 tier,
        uint256 amount,
        uint8 variant,
        address recipient,
        address, // specimenCollection - not used for Main collections
        uint256  // specimenTokenId - not used for Main collections
    ) internal returns (bool) {
        
        if (recipient == address(0) || amount == 0) {
            revert InvalidMintParameters();
        }

        (uint256 configuredMaxSupply) = _getCollectionMaxSupply();
        _validateIssueAndTier(issueId, tier);
        
        if (_itemsCounters[issueId][tier] + amount > configuredMaxSupply) {
            revert CollectionSoldOut();
        }

        for (uint256 i = 0; i < amount; i++) {
            uint256 tokenId = _getNextTokenId(issueId, tier);
            
            _safeMint(recipient, tokenId);
            _notifyTokenMinted(tokenId, recipient);
            
            // For Main collections, assign the variant passed from MintingFacet
            uint8 assignedVariant = variant > 0 ? variant : 1; // Default to 1 if 0
            
            bool syncSuccess = _assignVariantToToken(issueId, tier, tokenId, assignedVariant);
            
            unchecked {
                _itemsCounters[issueId][tier] += 1;
                _itemsCollected[recipient][issueId][tier] += 1;
            }
            
            emit VariantAssigned(tokenId, assignedVariant, syncSuccess);
        }

        emit ItemsDispatched(issueId, tier, amount, recipient);
        return true;
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
    ) public onlyRole(MINTER_ROLE) nonReentrant whenNotPaused returns (uint256[] memory tokenIds) {
        
        bool success = _mintVariantedItems(issueId, tier, quantity, variant, recipient, address(0), 0);
        require(success, "Minting failed");

        tokenIds = new uint256[](quantity);
        uint256 currentCounter = _itemsCounters[issueId][tier];
        
        for (uint256 i = 0; i < quantity; i++) {
            tokenIds[i] = currentCounter - quantity + i + 1;
        }
        
        return tokenIds;
    }

    /**
     * @notice Extended mint variant for MintingFacet compatibility
     */
    function mintVariantExtended(
        uint256 issueId,
        uint8 tier,
        uint8 variant,
        address recipient,
        uint256 quantity
    ) public onlyRole(MINTER_ROLE) nonReentrant whenNotPaused returns (
        uint256[] memory tokenIds,
        uint8 assignedVariant,
        uint256 totalPaid
    ) {
        tokenIds = mintVariant(issueId, tier, variant, recipient, quantity);
        assignedVariant = variant;
        totalPaid = 0;
        return (tokenIds, assignedVariant, totalPaid);
    }

    /**
     * @notice Assign variant to existing token (MintingFacet interface)
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
        if (variant == 0 || variant > 4) {
            revert InvalidVariantValue(variant);
        }
        
        bool success = _assignVariantToToken(issueId, tier, tokenId, variant);
        if (!success) {
            revert DiamondSyncFailed(tokenId, variant);
        }
        
        return variant;
    }

    /**
     * @notice Reset token variant (called by Diamond admin)
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
        // NOTE: We only call _notifyVariantAssigned which internally calls diamond.onVariantAssigned
        // Previously there was a direct call here + _notifyVariantAssigned = double notification
        // This caused triple-counting of hitVariantsCounters (2x here + 1x in updateVariantCounters)
        _notifyVariantAssigned(tokenId, variant);

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
        
        if (_hasAssignedAugment[tokenId]) {
            uint8[] memory equipment = new uint8[](1);
            equipment[0] = _assignedAugmentVariant[tokenId];
            return equipment;
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

    function getTokenEquipment(uint256 tokenId) public view override returns (TraitPackEquipment memory) {
        if (!_hasAssignedAugment[tokenId]) {
            return TraitPackEquipment({
                traitPackCollection: address(0),
                traitPackTokenId: 0,
                accessoryIds: new uint64[](0),
                tier: 0,
                variant: 0,
                assignmentTime: 0,
                unlockTime: 0,
                locked: false
            });
        }
        
        return TraitPackEquipment({
            traitPackCollection: _assignedAugmentCollection[tokenId],
            traitPackTokenId: _assignedAugmentTokenId[tokenId],
            accessoryIds: _getTraitPackAccessories(_assignedAugmentVariant[tokenId]),
            tier: 1,
            variant: _assignedAugmentVariant[tokenId],
            assignmentTime: block.timestamp,
            unlockTime: 0,
            locked: false
        });
    }

    function hasTraitPack(uint256 tokenId) external view returns (bool) {
        return _hasAssignedAugment[tokenId] || hasAugment(tokenId);
    }

    function totalItemsSupply(uint256 issueId, uint8 tier) external view returns (uint256) {
        return _itemsCounters[issueId][tier];
    }

    function collectedOf(address account, uint256 issueId, uint8 tier) external view returns (uint256) {
        return _itemsCollected[account][issueId][tier];
    }

    // ==================== AUGMENT CALLBACKS ====================

    function onAugmentAssigned(
        uint256 tokenId,
        address augmentCollection,
        uint256 augmentTokenId
    ) external nonReentrant onlyRole(MINTER_ROLE) {
        _requireOwned(tokenId);
        
        uint8 augmentVariant = _getAugmentVariant(augmentCollection, augmentTokenId);
        
        _hasAssignedAugment[tokenId] = true;
        _assignedAugmentCollection[tokenId] = augmentCollection;
        _assignedAugmentTokenId[tokenId] = augmentTokenId;
        _assignedAugmentVariant[tokenId] = augmentVariant;
        
        emit TransferBlockingStatusChanged(tokenId, true, "Augment assigned");
    }

    function onAugmentRemoved(
        uint256 tokenId,
        address augmentCollection,
        uint256 augmentTokenId
    ) external nonReentrant onlyRole(MINTER_ROLE) {
        _requireOwned(tokenId);
        
        if (!_hasAssignedAugment[tokenId] || 
            _assignedAugmentCollection[tokenId] != augmentCollection ||
            _assignedAugmentTokenId[tokenId] != augmentTokenId) {
            revert("Invalid augment removal");
        }
        
        _hasAssignedAugment[tokenId] = false;
        delete _assignedAugmentCollection[tokenId];
        delete _assignedAugmentTokenId[tokenId];
        delete _assignedAugmentVariant[tokenId];
        
        emit TransferBlockingStatusChanged(tokenId, false, "Augment removed");
    }

    /**
     * @notice Force transfer for unstaking operations only
     * @dev Temporarily disables transfer blocking during legitimate unstaking operations
     * @param from Current token owner (should be staking contract)
     * @param to Destination address (original staker)
     * @param tokenId Token to transfer
     */
    function forceUnstakeTransfer(
        address from,
        address to,
        uint256 tokenId
    ) external onlyRole(STAKING_ROLE) nonReentrant {
        if (from != _ownerOf(tokenId) || to == address(0) || _isUnstaking) {
            revert InvalidAddress();
        }
        
        _isUnstaking = true;
        
        try this.safeTransferFrom(from, to, tokenId) { 
            _isUnstaking = false;
        } catch {
            _isUnstaking = false;
            revert UnstakingFailed();
        }
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

    function isTransferBlocked(uint256 tokenId) external view returns (bool blocked, string memory reason) {
        return _checkTransferBlocking(tokenId);
    }

    function _checkTransferBlocking(uint256 tokenId) internal view returns (bool blocked, string memory reason) {
        // Skip blocking checks during unstaking operations
        if (_isUnstaking) {
            return (false, "");
        }
        
        if (address(diamond) == address(0)) {
            return (false, "");
        }
        
        try diamond.getAssignment(address(this), tokenId) returns (
            LibCollectionStorage.AugmentAssignment memory assignment
        ) {
            if (assignment.active) {
                if (assignment.unlockTime == 0) {
                    return (true, "Permanent augment lock");
                }
                
                if (block.timestamp < assignment.unlockTime) {
                    return (true, "Time-locked augment");
                }
                
                return (true, "Active augment assignment");
            }
        } catch {
            // Diamond unavailable - allow transfer
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

    // ==================== INTERNAL HELPER FUNCTIONS ====================

    function _getCollectionMaxSupply() internal view returns (uint256 configuredMaxSupply) {
        if (address(diamond) == address(0)) {
            return maxSupply;
        }
        
        try diamond.getCollection(collectionId) returns (
            LibCollectionStorage.CollectionData memory collectionData
        ) {
            return collectionData.maxSupply > 0 ? collectionData.maxSupply : maxSupply;
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

    function _getAugmentVariant(address augmentCollection, uint256 augmentTokenId) internal view returns (uint8) {
        try ISpecimenCollection(augmentCollection).itemVariant(augmentTokenId) returns (uint8 variant) {
            return variant > 0 ? variant : 1;
        } catch {
            return 1;
        }
    }

    function _getTraitPackAccessories(uint8 variant) internal pure returns (uint64[] memory) {
        if (variant == 1) {
            uint64[] memory accessories = new uint64[](2);
            accessories[0] = 1;
            accessories[1] = 2;
            return accessories;
        } else if (variant == 2) {
            uint64[] memory accessories = new uint64[](2);
            accessories[0] = 2;
            accessories[1] = 3;
            return accessories;
        } else if (variant == 3) {
            uint64[] memory accessories = new uint64[](2);
            accessories[0] = 1;
            accessories[1] = 3;
            return accessories;
        } else if (variant == 4) {
            uint64[] memory accessories = new uint64[](3);
            accessories[0] = 1;
            accessories[1] = 2;
            accessories[2] = 3;
            return accessories;
        } else {
            return new uint64[](0);
        }
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
            (bool blocked, string memory reason) = _checkTransferBlocking(tokenId);
            
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