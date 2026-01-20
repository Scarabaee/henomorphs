
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../libraries/CollectionModel.sol";
import "../interfaces/ICollectionRepository.sol";
import "../interfaces/IAirdropSupplier.sol";
import "../interfaces/IMintableCollection.sol";
import "../interfaces/ISpecimenCollection.sol";
import "../utils/IssueHelper.sol";
import "../libraries/HenomorphsModel.sol";
import "../libraries/HenomorphsMetadata.sol";
import {ICollectionDiamond} from "../diamonds/modular/interfaces/ICollectionDiamond.sol";


/**
 * @notice Contract module which provide a definition of the Henomorphs Genesis collection.
 *
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */

interface IBiopod {
    function probeCalibration(uint256 tokenId) external view returns (Calibration memory);
}

contract HenomorphsGenesis is Initializable, ERC721Upgradeable, AccessControlUpgradeable, ERC721BurnableUpgradeable, ERC721EnumerableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable, ISpecimenCollection, IAirdropSupplier, IMintableCollection  {
    // Add the library methods
    using SafeERC20 for IERC20;
    using Strings for uint256;

    /**
     * @dev Emitted when `contract` mints item tokens of specific series.
     * @notice The amont of tokens minted is attached to the event.
     */
    event ItemsDispatched(uint256 issueId, uint8 tier, uint256 amount, ItemType itemType, address indexed recipient);

    /**
     * @dev Invalid call data.
     */
    error InvalidCallData();

    /**
     * @dev Invalid issue data.
     */
    error InvalidIssueData();

    /**
     * @dev Invalid mint offset.
     */
    error InvalidMintOffset(uint256 offset);

    /**
     * @dev Tojen ID already exists.
     */
    error TokenAlreadyExists(uint256 tokenId);

    /**
     * @dev Invalid value sent.
     */
    error NotEnoughValueSent();

    /**
     * @dev Invalid token ID.
     */
    error TokenAlreadyMinted();

    /**
     * @dev Invalid item tier.
     */
    error InvalidItemTier(uint256 tokenId);

    /**
     * @dev Invalid token range.
     */
    error TokenOutOfRange(uint256 tokenId);

    /**
     * @dev Dispatch of tokens to the given recipient is not allowed.
     */
    error DispatchNotAllowed(address recipient);

    /**
     * @dev The tier max supply has been exceeded.
     */
    error TierSupplyExceeded();

    /**
     * @dev Mint not allowed yet.
     */
    error MintNotAllowed();

    /**
     * @dev Forbidden claim.
     */
    error ForbiddenRequest();

    /**
     * @dev Emitted when `contract` assigns a vatiant to a specific token.
     */
    event VariantShuffled(uint256 tokenId, uint8 variant);
    event TransferBlockingStatusChanged(uint256 indexed tokenId, bool blocked, string reason);

    /**
     * @dev Invalid item state for tranfer.
     */
    error ItemShufflingFailed(uint256 tokenId);

    /**
     * @dev Invalid currency token.
     */
    error UnsupportedCurrency();
    event AugmentAssigned(uint256 indexed tokenId, address indexed augmentCollection, uint256 indexed augmentTokenId, uint8 variant);
    error InvalidAddress();
    error UnstakingFailed();
    error TransferIsBlocked(uint256 tokenId, string reason);
    
    event AugmentRemoved(
        uint256 indexed specimenTokenId,
        address indexed specimenCollection,
        uint256 indexed augmentTokenId
    );

    /**
     * @dev Struct that keeps issue tiers item specific properties.
     */
    struct HatchRequest {
        // The tokenId to hatch.
        uint256 tokenId;
        // The value of hatching an item.
        uint256 value;
        // Hatching currency        
        IERC20 currency;
    }

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant CLAIMER_ROLE = keccak256("CLAIMER_ROLE");
    bytes32 public constant BOOSTER_ROLE = keccak256("BOOSTER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // Mapping to indicate supported issues
    mapping(uint256 => bool) public supportedIssues;

    uint256 public defaultIssueId;
    uint256 public defaultItemTier;
    ItemType public allowedItemType;

    // Holds the OpenSea like contract metadata for the collection
    string private _contractUri;
    string public uriSuffix;

    // Mapping from issue ID to onchain minted tokens per tier counter
    mapping(uint256 => mapping(uint8 => uint256)) private _itemsCounters;
    // Mapping from account to issue series per wallet counter 
    mapping(address => mapping(uint256 => uint256)) private _itemsCollected;
    // Mapping from issue ID to onchain minted tokens per tier to its variant
    mapping(uint8 => mapping(uint256 => uint8)) private _itemsVariants;

    ICollectionRepository private collectionRepository;

    IERC20 private constant ZICO = IERC20(0x486ebcFEe0466Def0302A944Bd6408cD2CB3E806);

    // Storage for mapping item varionts to their respective specimen data
    mapping(uint8 => Specimen) public _specimens;
    IBiopod private _calibrationBiopod;

     // Dodaj mapowanie dla zatwierdzonych procesorów
    mapping(address => bool) private _approvedProcessors;

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
     * The contract constructor.
     * 
     * @param contractUri The uri for OpenSea related collection metadata.
     * @param issueId The default supported issue Id.
     * @param repositoryContract The configuration repository contract address
     */
    /// @custom:oz-upgrades-validate-as-initializer
    function initialize(string memory contractUri, uint256 issueId, address repositoryContract) public initializer {
        __ERC721_init("Henomorphs Genesis", "HMS");
        __ERC721Enumerable_init();
        __ERC721Burnable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(CLAIMER_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);

        uriSuffix = ".json";
        _contractUri = contractUri;
        
        allowedItemType = ItemType.Vignette;
        supportedIssues[issueId] = true;
        defaultIssueId = issueId;
        defaultItemTier = 1;

        collectionRepository = ICollectionRepository(repositoryContract);
    }

    /**
     * @dev Not implemented.
     */
    function dropItems(uint256, uint8, uint256, address) external virtual override nonReentrant onlyRole(CLAIMER_ROLE) returns (bool) {
        revert("Function not implementd");
    }

    /**
     * @dev See {IMintableCollection-mintItems}.
     */
    function mintItems(uint256, uint8, uint256, address) external virtual override nonReentrant onlyRole(MINTER_ROLE) returns (bool) {
        return false;
    }

    function mint(uint256 issueId, uint8 tier, uint256, uint8 variant, address recipient) external virtual nonReentrant onlyPrivileged returns (bool) {
        if (!supportedIssues[issueId]) {
            revert InvalidIssueData();
        }

        if (tier != defaultItemTier) {
            revert InvalidItemTier(tier);
        }

        (, ItemTier memory _itemTier) = collectionRepository.getItemInfo(allowedItemType, issueId, tier);
        uint256 _offset = _itemsCounters[issueId][tier] + _itemTier.offset;
        uint256 tokenId = _offset + 1;

        address owner = _ownerOf(tokenId);
        if (owner == address(0)) {
            _safeMint(recipient, tokenId);

            _itemsVariants[uint8(defaultItemTier)][tokenId] = variant;

            unchecked {
                _itemsCounters[issueId][tier] += 1;  
                _itemsCollected[recipient][tier] += 1; 
            }      

            return true;    
        }
        
        return false;
    }

    /**
     * @notice OpenSea related metadata of the smart contract.
     * @param contractUri Storefront-level metadata for contract.
     */
    function setContractURI(string memory contractUri) external onlyPrivileged {
        _contractUri = contractUri;
    }

    /**
     * @dev Optional possibility to set up URI suffix for IPFS gateways flexibility.
     */
    function setUriSuffix(string memory suffix) public onlyPrivileged {
        uriSuffix = suffix;
    }

    /**
     * @notice Allows to setup a new collection repository contract.
     * @param repositoryContract A address to set for the new repository contract.
     */
    function setCollectionRepository(address repositoryContract) external onlyPrivileged {
        if (repositoryContract == address(0)) {
            revert InvalidCallData();
        }
        collectionRepository = ICollectionRepository(repositoryContract);
    }

    /**
     * @notice Allows to setup a new biopod contract.
     * @param biopodContract A address to set for the new biopod contract.
     */
    function setCalibrationBiopod(address biopodContract) external onlyPrivileged {
        if (biopodContract == address(0)) {
            revert InvalidCallData();
        }

        _calibrationBiopod = IBiopod(biopodContract);
    }

    /**
     * @dev Sets processor approval
     * @param processor Processor address
     * @param approved Approval status
     */
    function setProcessorApproval(address processor, bool approved) external onlyPrivileged {
        if (processor == address(0)) {
            revert InvalidCallData();
        }
        
        _approvedProcessors[processor] = approved;
    }

    /**
     * @dev Checks if processor is approved - alternative function name for compatibility
     * @param processor Processor address 
     * @return Whether processor is approved
     */
    function isProcessorApproved(address processor) external view returns (bool) {
        return _approvedProcessors[processor];
    }

    /**

    /**
     * @dev Allows to overwrite if already exists the specimens for specific variants.
     */
    function defineSpecimens(Specimen[] calldata specimens) external onlyPrivileged {
        for (uint8 i = 0; i < specimens.length; i++) {
            _specimens[specimens[i].variant] = Specimen({
                variant: specimens[i].variant,
                formName: specimens[i].formName,
                form: specimens[i].form,
                description: specimens[i].description,
                generation: specimens[i].generation,
                augmentation: specimens[i].augmentation,
                baseUri: specimens[i].baseUri
            });
        }
    }

    /**
     * @notice OpenSea related metadata of the smart contract.
     * @return Storefront-level metadata for contract.
     */
    function contractURI() public view returns (string memory) {
        return _contractUri;
    }

    /**
     * @dev See {IERC721Metadata-tokenURI}.
     */
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        _requireOwned(tokenId);
        
        // Check if token has assigned augment
        if (_hasAssignedAugment[tokenId]) {
            return _generateAugmentedTokenURI(tokenId);
        }
        
        // Standard URI generation
        return _generateStandardTokenURI(tokenId);
    }

    /**
     * @dev Return assigned item variant.
     */
    function itemVariant(uint256 tokenId) public view returns (uint8) {
        return _itemsVariants[uint8(defaultItemTier)][tokenId];
    }

    function itemEquipments(uint256 tokenId) external view override returns (uint8[] memory) {
        if (!_hasAssignedAugment[tokenId]) {
            return new uint8[](0);
        }
        
        uint8[] memory traitPacks = new uint8[](1);
        traitPacks[0] = _assignedAugmentVariant[tokenId];
        return traitPacks;
    }

    function getTokenEquipment(uint256 tokenId) external view override returns (TraitPackEquipment memory) {
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
            assignmentTime: block.timestamp, // Set current time
            unlockTime: 0,
            locked: false
        });
    }
    
    function hasTraitPack(uint256 tokenId) external view override returns (bool) {
        return _hasAssignedAugment[tokenId];
    }

    /**
     * @dev Allows to set suppored series ID of the existing collection.
     *
     * @param issueIds - Supported issue IDs.
     * @param approvals - Whether allow or disallow the issues.
     */
    function supportIssues(uint256[] calldata issueIds, bool[] calldata approvals) public onlyPrivileged {
        if (issueIds.length != approvals.length) {
            revert InvalidCallData();
        }

        for (uint256 i = 0;  i < issueIds.length; i++) {
            IssueInfo memory issue = collectionRepository.getIssueInfo(allowedItemType, issueIds[i]);
            if (issue.issueId == 0) {
                revert InvalidIssueData();
            }

            supportedIssues[issueIds[i]] = approvals[i];
        }
    }

    /**
     * @dev Returns total amount of tokens issued within given issue and tier.
     */
    function totalItemsSupply(uint256 issueId, uint8 tier) public view virtual override (IAirdropSupplier, IMintableCollection) returns (uint256) {
        return _itemsCounters[issueId][tier];
    }

    function hatchItem(HatchRequest calldata request) external payable nonContract nonReentrant returns (uint256 variant) { 
        _requireOwned(request.tokenId);

        address owner = _ownerOf(request.tokenId);
        if (owner != _msgSender()) {
            revert ForbiddenRequest();
        }

        if (_itemsVariants[uint8(defaultItemTier)][request.tokenId] > 0) {
            revert ForbiddenRequest();
        }

        variant = 1;

        if (request.value > 0) {
            variant = _shuffleItemVariant(request.tokenId);
            _acceptPayment(request.currency, _msgSender(), request.value, (variant > 1 ? false : true));
        }  

        _itemsVariants[uint8(defaultItemTier)][request.tokenId] = uint8(variant);
        emit VariantShuffled(request.tokenId, uint8(variant)); 
    }

    function forceShuffleVariant(uint256 tokenId) external onlyPrivileged returns (uint256 variant) {
        variant = _shuffleItemVariant(tokenId);
        _itemsVariants[uint8(defaultItemTier)][tokenId] = uint8(variant);
    }

    /**
     * @dev See {IAirdropSupplier-collectedOf}.
     */
    function collectedOf(address account, uint256, uint8 tier) public view virtual override(IAirdropSupplier, IMintableCollection) returns (uint256) {
        return _itemsCollected[account][tier];
    }

    /**
     * @notice Check if token transfer is blocked
     * @param tokenId Token to check
     * @return blocked Whether transfer is blocked
     * @return reason Reason for blocking
     */
    function isTransferBlocked(uint256 tokenId) external view returns (bool blocked, string memory reason) {
        return _checkTransferBlocking(tokenId);
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

    /**
     * @notice Enhanced onAugmentAssigned with proper validation
     * @dev Complete callback implementation with error handling
     */
    function onAugmentAssigned(
        uint256 tokenId,
        address augmentCollection,
        uint256 augmentTokenId
    ) external override nonReentrant onlyAutorizedBooster {
        // Validate token exists
        _requireOwned(tokenId);
        
        // Validate augment token exists
        try IERC721(augmentCollection).ownerOf(augmentTokenId) returns (address) {
            // Token exists, continue
        } catch {
            revert("Augment token does not exist");
        }
        
        // Get augment variant safely
        uint8 augmentVariant = _getAugmentVariant(augmentCollection, augmentTokenId);
        
        // Update assignments
        _hasAssignedAugment[tokenId] = true;
        _assignedAugmentCollection[tokenId] = augmentCollection;
        _assignedAugmentTokenId[tokenId] = augmentTokenId;
        _assignedAugmentVariant[tokenId] = augmentVariant;
        
        emit AugmentAssigned(tokenId, augmentCollection, augmentTokenId, augmentVariant);
        emit TransferBlockingStatusChanged(tokenId, true, "Augment assigned");
    }

    /**
     * @notice Remove augment assignment
     * @dev Add missing removal callback
     */
    function onAugmentRemoved(
        uint256 tokenId,
        address augmentCollection,
        uint256 augmentTokenId
    ) external nonReentrant onlyAutorizedBooster {
        _requireOwned(tokenId);
        
        // Validate current assignment
        if (!_hasAssignedAugment[tokenId] || 
            _assignedAugmentCollection[tokenId] != augmentCollection ||
            _assignedAugmentTokenId[tokenId] != augmentTokenId) {
            revert("Invalid augment removal");
        }
        
        // Clear assignments
        _hasAssignedAugment[tokenId] = false;
        delete _assignedAugmentCollection[tokenId];
        delete _assignedAugmentTokenId[tokenId];
        delete _assignedAugmentVariant[tokenId];
        
        emit AugmentRemoved(tokenId, augmentCollection, augmentTokenId);
        emit TransferBlockingStatusChanged(tokenId, false, "Augment removed"); 
    }
    
    // ************************************* 
    // Utility methods
    // *************************************

    /**
     * @notice Generate augmented token URI with Diamond integration
     * @dev Complete implementation with fallback mechanisms
     */
    function _generateAugmentedTokenURI(uint256 tokenId) internal view returns (string memory) {
        // Try Diamond integration first if available
        address diamondAddr = _getDiamondAddress();
        if (diamondAddr != address(0)) {
            try ICollectionDiamond(diamondAddr).generateTokenURI(1, tokenId) returns (string memory uri) {
                if (bytes(uri).length > 0) {
                    return uri;
                }
            } catch {
                // Diamond unavailable, use local generation
            }
        }
        
        // Fallback to local augmented generation
        return _generateLocalAugmentedURI(tokenId);
    }

    /**
     * @notice Generate local augmented URI when Diamond unavailable
     * @dev Complete local implementation with all augment data
     */
    function _generateLocalAugmentedURI(uint256 tokenId) internal view returns (string memory) {
        // Get base data - avoid stack too deep
        AugmentedTokenData memory tokenData;
        
        {
            (, ItemTier memory tier) = collectionRepository.getItemInfo(allowedItemType, defaultIssueId, uint8(defaultItemTier));
            tokenData.tier = tier.tier;
            tokenData.specimenVariant = _itemsVariants[tier.tier][tokenId];
            tokenData.specimen = _specimens[tokenData.specimenVariant];
        }
        
        // Get calibration data with error handling
        {
            if (address(_calibrationBiopod) != address(0)) {
                try _calibrationBiopod.probeCalibration(tokenId) returns (Calibration memory cal) {
                    tokenData.calibration = cal;
                    tokenData.hasCalibration = true;
                } catch {
                    // Use default calibration values
                    tokenData.calibration = _getDefaultCalibration(tokenId);
                    tokenData.hasCalibration = false;
                }
            } else {
                tokenData.calibration = _getDefaultCalibration(tokenId);
                tokenData.hasCalibration = false;
            }
        }
        
        // Get augment data
        {
            tokenData.traitPackData = TraitPackEquipment({
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
        
        // Generate URI
        HenomorphsMetadata.TokenURIParams memory params = HenomorphsMetadata.TokenURIParams({
            tokenId: tokenId,
            tier: tokenData.tier,
            specimen: tokenData.specimen,
            externalUrl: "https://zico.network",
            calibration: tokenData.calibration,
            traitPackData: tokenData.traitPackData
        });
        
        return HenomorphsMetadata.generateAugmentedTokenURI(params);
    }

    /**
     * @notice Generate standard token URI without augments
     * @dev Optimized standard generation
     */
    function _generateStandardTokenURI(uint256 tokenId) internal view returns (string memory) {
        (, ItemTier memory tier) = collectionRepository.getItemInfo(allowedItemType, defaultIssueId, uint8(defaultItemTier));
        
        uint8 variant = _itemsVariants[tier.tier][tokenId];
        Specimen memory specimen = _specimens[variant];
        
        // Get calibration with fallback
        Calibration memory calibration;
        if (address(_calibrationBiopod) != address(0)) {
            try _calibrationBiopod.probeCalibration(tokenId) returns (Calibration memory cal) {
                calibration = cal;
            } catch {
                calibration = _getDefaultCalibration(tokenId);
            }
        } else {
            calibration = _getDefaultCalibration(tokenId);
        }
        
        HenomorphsMetadata.TokenURIParams memory params = HenomorphsMetadata.TokenURIParams({
            tokenId: tokenId,
            tier: tier.tier,
            specimen: specimen,
            externalUrl: "https://zico.network",
            calibration: calibration,
            traitPackData: TraitPackEquipment({
                traitPackCollection: address(0),
                traitPackTokenId: 0,
                accessoryIds: new uint64[](0),
                tier: 0,
                variant: 0,
                assignmentTime: 0,
                unlockTime: 0,
                locked: false
            })
        });
        
        return HenomorphsMetadata.generateTokenURI(params);
    }

    /**
     * @notice Get default calibration when Biopod unavailable
     * @dev Reasonable defaults based on token data
     */
    function _getDefaultCalibration(uint256 tokenId) internal view returns (Calibration memory) {
        uint8 variant = _itemsVariants[uint8(defaultItemTier)][tokenId];
        
        return Calibration({
            tokenId: tokenId,
            owner: _ownerOf(tokenId),
            kinship: 50, // Neutral starting point
            lastInteraction: block.timestamp,
            experience: 0,
            charge: 0,
            lastCharge: block.timestamp,
            level: variant * 10 + 10, // Variant-based level
            prowess: variant * 5 + 15, // Variant-based prowess
            wear: 0,
            lastRecalibration: block.timestamp,
            calibrationCount: 0,
            locked: false,
            agility: variant * 3 + 12, // Variant-based agility
            intelligence: variant * 4 + 18, // Variant-based intelligence
            bioLevel: 1
        });
    }

    /**
     * @notice Get Diamond address with proper error handling
     * @dev Safe Diamond address retrieval
     */
    function _getDiamondAddress() internal pure returns (address) {
        // This would be set by admin - for now return zero
        // In production, this should be a storage variable set during initialization
        return address(0);
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
            accessories[0] = 1; // JOI'S VISION
            accessories[1] = 2; // K'S PROTOCOL
            return accessories;
        } else if (variant == 2) {
            uint64[] memory accessories = new uint64[](2);
            accessories[0] = 2; // K'S PROTOCOL
            accessories[1] = 3; // DECKARD'S REFUGE
            return accessories;
        } else if (variant == 3) {
            uint64[] memory accessories = new uint64[](2);
            accessories[0] = 1; // JOI'S VISION
            accessories[1] = 3; // DECKARD'S REFUGE
            return accessories;
        } else if (variant == 4) {
            uint64[] memory accessories = new uint64[](3);
            accessories[0] = 1; // JOI'S VISION
            accessories[1] = 2; // K'S PROTOCOL
            accessories[2] = 3; // DECKARD'S REFUGE
            return accessories;
        } else {
            return new uint64[](0);
        }
    }

   function _acceptPayment(IERC20 currency, address from, uint256 amount, bool forceRefund) internal virtual returns (uint256) {
        if (currency != ZICO) {
            revert UnsupportedCurrency();
        }

        if (amount > 0 && !forceRefund) {
            (IssueInfo memory issueInfo, ItemTier memory tierInfo) = collectionRepository.getItemInfo(allowedItemType, defaultIssueId, uint8(defaultItemTier));

            if (amount < tierInfo.price) {
                revert NotEnoughValueSent();
            }

            currency.safeTransferFrom(from, address(this), amount);
            currency.safeTransfer(issueInfo.beneficiary, tierInfo.price);

            uint256 _rest = amount - tierInfo.price;

            if (_rest > 0) {
                currency.safeTransfer(from, _rest);
            }

            return tierInfo.price;
        }
        return 0;
    }

    function _resolveUri(uint256 tokenId) internal view returns (string memory) {
        (, ItemTier memory tier) = collectionRepository.getItemInfo(allowedItemType, defaultIssueId, uint8(defaultItemTier));

        uint8 _variant = _itemsVariants[tier.tier][tokenId];
        Specimen memory _specimen = _specimens[_variant];
        Calibration memory _calibration = _calibrationBiopod.probeCalibration(tokenId);

        // Generate token URI using the library
        return HenomorphsMetadata.generateTokenURI(
            HenomorphsMetadata.TokenURIParams({
                tokenId: tokenId,
                tier: tier.tier,
                specimen: _specimen, 
                externalUrl: "https://zico.network", // Corrected parameter name
                calibration: _calibration,
                traitPackData: TraitPackEquipment({
                    traitPackCollection: address(0),
                    traitPackTokenId: 0,
                    accessoryIds: new uint64[](0),
                    tier: 0,
                    variant: 0,
                    assignmentTime: 0,
                    unlockTime: 0,
                    locked: false
                })
            })
        );
    }

    function _dispatchItems(uint256 issueId, uint8 tier, address[] memory recipients, uint256[] memory ids) internal {
        if (recipients.length == 0) {
            revert InvalidCallData();
        }

        (, ItemTier memory _itemTier) = collectionRepository.getItemInfo(allowedItemType, issueId, tier);

        for (uint256 i = 0; i < recipients.length; i++) {
            if (_itemsCollected[recipients[i]][tier] + 1 > _itemTier.maxMints) {
                revert DispatchNotAllowed(recipients[i]);
            }

            if (_itemsCounters[issueId][tier] + 1 > _itemTier.maxSupply) {
                revert TierSupplyExceeded();
            }

            uint256 _offset = _itemsCounters[issueId][tier] + _itemTier.offset;
            uint256 tokenId = _offset + 1;

            if (ids.length == recipients.length) {
                tokenId = ids[i];
            }

            if (tokenId > _itemTier.limit) {
                revert TokenOutOfRange(tokenId);
            }

            address owner = _ownerOf(tokenId);
            if (owner != address(0)) {
                _safeTransfer(address(this), recipients[i], tokenId, "");
            } else {
                if (!_itemTier.isMintable) {
                    revert MintNotAllowed();
                }
                _safeMint(recipients[i], tokenId);
            }

            unchecked {
                _itemsCounters[issueId][tier] += 1;  
                _itemsCollected[recipients[i]][tier] += 1;           
            }
        }
    }

    function _shuffleItemVariant(uint256 tokenId) internal returns (uint256) {
        (, ItemTier memory _itemTier) = collectionRepository.getItemInfo(allowedItemType, defaultIssueId, uint8(defaultItemTier));

        if (_itemTier.variantsCount > 1 && _itemsVariants[uint8(_itemTier.tier)][tokenId] == 0) {
            try collectionRepository.shuffleItemVariant(allowedItemType, defaultIssueId, uint8(_itemTier.tier), tokenId) returns (uint8 _variant) {
                return _variant;
            } catch {
            }
        }
        return 0;
    }

    /**
     * @notice Check if token transfer is blocked due to augment assignment
     * @param tokenId Token to check
     * @return blocked Whether transfer is blocked
     * @return reason Reason for blocking
     */
    function _checkTransferBlocking(uint256 tokenId) internal view returns (bool blocked, string memory reason) {
        // Skip blocking checks during unstaking operations
        if (_isUnstaking) {
            return (false, "");
        }
        
        // Check if token has assigned augment
        if (_hasAssignedAugment[tokenId]) {
            return (true, "Active augment assignment");
        }
        
        return (false, "");
    }

    // *************************************
    // Modifiers
    // ************************************* 

    /**
     * @dev Throws if called by a contract
     */
    modifier nonContract() {
        if (tx.origin != _msgSender()) {
            revert ("Call forbidden");
        }
        _;
    }

    /**
     * @dev Throws if called by any account other than the priviledged ones.
     */
    modifier onlyPrivileged() {
        _checkPrivileged();
        _;
    }

    modifier onlyAutorizedBooster() {
        require(
            _approvedProcessors[msg.sender] || 
            hasRole(DEFAULT_ADMIN_ROLE, _msgSender()) ||
            hasRole(BOOSTER_ROLE, msg.sender) || 
            hasRole(BOOSTER_ROLE, _msgSender()),
            "Unathorized call"
        );
        _;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkPrivileged() internal view virtual {
        address _sender = _msgSender();
        if (!hasRole(DEFAULT_ADMIN_ROLE, _sender) && !hasRole(ADMIN_ROLE, _sender)) {
            revert("Caller is not privileged");
        }
    }

    /**
     * Override isApprovedForAll to auto-approve OS's proxy contract
     */
    function isApprovedForAll(
        address _owner,
        address _operator
    ) public override (IERC721, ERC721Upgradeable) view returns (bool isOperator) {
        // if OpenSea's ERC721 Proxy Address is detected, auto-return true
    	if (_operator == address(0x58807baD0B376efc12F5AD86aAc70E78ed67deaE)) {
            return true;
        }
        
        // otherwise, use the default ERC721.isApprovedForAll()
        return ERC721Upgradeable.isApprovedForAll(_owner, _operator);
    }

    // The following functions are overrides required by Solidity.

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyPrivileged
        override
    {}

     function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
        returns (address)
    {
        address from = _ownerOf(tokenId);
        
        // Check for transfer blocking during regular transfers (not minting/burning)
        if (from != address(0) && to != address(0)) {
            (bool blocked, string memory reason) = _checkTransferBlocking(tokenId);
            
            if (blocked) {
                revert TransferIsBlocked(tokenId, reason);
            }
        }
        
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value)
        internal
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
    {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlUpgradeable, ERC721EnumerableUpgradeable, ERC721Upgradeable, IERC165)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

}