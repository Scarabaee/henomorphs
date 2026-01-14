// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import "../interfaces/ICollectionRepository.sol";
import "../common/CollectionModel.sol";

/**
 * @notice The implementation of the ICollectionRepository interface holding 
 *      ZicoDAO's collections data. 
 *
 * @custom:website https://zicodao.io
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract HenomorphsCollectionsRepository is Initializable, ContextMixin, AccessControlUpgradeable, UUPSUpgradeable, ICollectionRepository {
   /**
     * @dev Invalid call data.
     */
    error InvalidCallData();

    /**
     * @dev Invalid issue data.
     */
    error InvalidIssueData();

    /**
     * @dev Issue modifications already forbidden.
     */
    error InvalidIssueState();

    /**
     * @dev Variant has been already assigned.
     */
    error ItemAleadyVarianted(uint256 tokenId);

    /**
     * @dev Item tier is not varianted.
     */
    error InvalidIssueTier(uint8 tier);

    uint8 private constant DEFAULT_DECIMALS = 8;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant SVA_ROLE = keccak256("SVA_ROLE");

    // Mapping for storing issue definitions
    mapping(ItemType => mapping(uint256 => IssueInfo)) private _issueInfos;
    // Mapping from issueId => tier => tier definition
    mapping(ItemType => mapping(uint256 => mapping(uint8 => ItemTier))) private _itemTiers;
    // Mapping from issueId to its tier counter
    mapping(ItemType => mapping(uint256 => uint8)) private _tierCounters;
    // Mapping from issueId to its tier and vatiant settings
    mapping(ItemType => mapping(uint256 => mapping(uint8 => mapping(uint8 => TierVariant)))) private _tierVariants;
    // Mapping from issueId to its tier and its picked vatiants counter
    mapping(ItemType => mapping(uint256 => mapping(uint8 => mapping(uint8 => uint256)))) private _hitVariantsCounters;
    // Mapping from tokenId to a block at which the variant has been picked
    mapping(uint256 => uint256) private _itemsVarianted;

    // Mapping from issue ID to issue phase specific properties.
    mapping(ItemType => mapping(uint256 => mapping(uint8 => mapping(IssuePhase => PhaseInfo)))) _phaseInfos;

    // Exchange rates data feed
    AggregatorV3Interface private basePriceFeed;
    AggregatorV3Interface private quotePriceFeed;

    uint8 private _defaultVariant;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address baseContract, address quoteContract) initializer public {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(SVA_ROLE, msg.sender);

        __HenomorphsCollectionsRepository_init_unchained(baseContract, quoteContract);
    }

    /**
     * @dev Initializes the contract with the initial quotations contracts.
     */
    function __HenomorphsCollectionsRepository_init_unchained(address baseContract, address quoteContract) internal onlyInitializing {
        setDataFeedContracts(baseContract, quoteContract);
        _defaultVariant = 1;
    }

    // ************************************* 
    // Administrative methods
    // *************************************

    /**
     * @dev Allows to define or overwrite if already exists the issue data.
     */
    function defineCollection(IssueInfo calldata issue, ItemTier[] calldata tiers) external onlyPrivileged {
        if (issue.issueId == 0) {
            revert InvalidCallData();
        }

        _issueInfos[issue.itemType][issue.issueId] = issue;

        for (uint256 i = 0; i < tiers.length; i++) {
           _itemTiers[issue.itemType][issue.issueId][tiers[i].tier] = ItemTier(tiers[i].tier, tiers[i].tierUri, tiers[i].maxSupply, tiers[i].price, tiers[i].maxMints, tiers[i].isMintable, tiers[i].isSwappable, tiers[i].isBoostable, tiers[i].revealTimestamp, tiers[i].offset, tiers[i].limit, tiers[i].isSequential, tiers[i].variantsCount, tiers[i].features);
        }

        _tierCounters[issue.itemType][issue.issueId] = uint8(tiers.length);
    }

    /**
     * @dev Allows to define or overwrite if already exists the issue properties.
     */
    function updateCollection(uint256 issueId, IssueInfo calldata issue) external onlyPrivileged {
        if ((_issueInfos[issue.itemType][issueId].issueId == 0) || (_issueInfos[issue.itemType][issueId].issueId != issue.issueId)) {
            revert InvalidIssueData();
        }

        _issueInfos[issue.itemType][issue.issueId] = issue;
    }

    /**
     * @dev Allows to delete the entire issue configuration.
     */
    function deleteCollection(uint256 issueId, ItemType itemType) external onlyPrivileged {
        if ((_issueInfos[itemType][issueId].issueId == 0) || (_issueInfos[itemType][issueId].issueId != issueId)) {
            revert InvalidIssueData();
        }

        for (uint8 i = 0; i < _tierCounters[itemType][issueId]; i++) {
            delete _itemTiers[itemType][issueId][i + 1];
        }
        delete _issueInfos[itemType][issueId];
        delete _tierCounters[itemType][issueId];
    }

    /**
     * @dev Allows to overwrite if already exists the issue data.
     */
    function updateTiers(uint256 issueId, ItemType itemType, ItemTier[] calldata tiers) external onlyPrivileged {
        if ((_issueInfos[itemType][issueId].issueId == 0) || _issueInfos[itemType][issueId].isFixed) {
            revert InvalidIssueState();
        }

        for (uint256 i = 0; i < tiers.length; i++) {
             _itemTiers[itemType][issueId][tiers[i].tier] = ItemTier(tiers[i].tier, tiers[i].tierUri, tiers[i].maxSupply, tiers[i].price, tiers[i].maxMints, tiers[i].isMintable, tiers[i].isSwappable, tiers[i].isBoostable, tiers[i].revealTimestamp, tiers[i].offset, tiers[i].limit, tiers[i].isSequential, tiers[i].variantsCount, tiers[i].features);
        }
    }

    /**
     * @dev Allows to overwrite if already exists the tiers variant data.
     */
    function updateVariants(uint256 issueId, ItemType itemType, TierVariant[] calldata variants) external onlyPrivileged {
        if ((_issueInfos[itemType][issueId].issueId == 0) || _issueInfos[itemType][issueId].isFixed) {
            revert InvalidIssueState();
        }

        for (uint8 i = 0; i < variants.length; i++) {
            _tierVariants[itemType][issueId][variants[i].tier][i] = TierVariant(variants[i].variant, variants[i].tier, variants[i].maxSupply);
        }
    }

    /**
     * @dev Allows to delete if already exists the issue data.
     */
    function deleteVariants(uint256 issueId, ItemType itemType, TierVariant[] calldata variants) external onlyPrivileged {
        if ((_issueInfos[itemType][issueId].issueId == 0) || _issueInfos[itemType][issueId].isFixed) {
            revert InvalidIssueState();
        }

        for (uint8 i = 0; i < variants.length; i++) {
            delete _tierVariants[itemType][issueId][variants[i].tier][i];
        }
    }

    /**
     * @dev Allows delete existing the issue data.
     */
    function deleteTiers(uint256 issueId, ItemType itemType, ItemTier[] calldata tiers) external onlyPrivileged {
        if ((_issueInfos[itemType][issueId].issueId == 0) || _issueInfos[itemType][issueId].isFixed) {
            revert InvalidIssueState();
        }

        for (uint256 i = 0; i < tiers.length; i++) {
            delete _itemTiers[itemType][issueId][tiers[i].tier];
        }
    }

    /**
     * @dev Allows to set up coresponding data feed contract.
     * @param baseContract New address to set for the base `MATIC/USD` contract.
     * @param quoteContract New address to set for the quote `PLN/USD` contract.
     */
    function setDataFeedContracts(address baseContract, address quoteContract) public onlyPrivileged {
        if (baseContract == address(0) || quoteContract == address(0)) {
            revert InvalidCallData();
        }

        basePriceFeed = AggregatorV3Interface(baseContract);
        quotePriceFeed = AggregatorV3Interface(quoteContract);
    }

    /**
     * @dev Allows to set up default variant.
     *  @param variant New default variant to set.
     */
    function setDefaultVariant(uint8 variant) public onlyPrivileged {
        if (variant == 0) {
            revert InvalidCallData();
        }
        _defaultVariant = variant;
    }

    // ************************************* 
    // Implementations
    // *************************************

    /**
     * @dev See {ICollectionRepository-getIssueInfo}.
     */
    function getIssueInfo(ItemType itemType, uint256 issueId) external view returns (IssueInfo memory) {
        return _issueInfos[itemType][issueId];
    }

    /**
     * @dev See {ICollectionRepository-getItemInfo}.
     */
    function getItemInfo(ItemType itemType, uint256 issueId, uint8 tier) external view returns (IssueInfo memory, ItemTier memory) {
        return (_issueInfos[itemType][issueId], _itemTiers[itemType][issueId][tier]);
    }

    /**
     * @dev See {ICollectionRepository-getTierCount}.
     */
    function getTiersCount(ItemType itemType, uint256 issueId) external view returns (uint8) {
        return _tierCounters[itemType][issueId];
    }

    /**
     * @dev See {ICollectionRepository-getPhaseInfo}.
     */
    function getPhaseInfo(ItemType itemType, uint256 issueId, uint8 tier, IssuePhase phase) external view returns (PhaseInfo memory) {
        return _phaseInfos[itemType][issueId][tier][phase];
    }

    /**
     * @dev See {ICollectionRepository-getTierVariant}.
     */
    function getTierVariant(ItemType itemType, uint256 issueId, uint8 tier, uint8 variant) external view returns (TierVariant memory) {
        return _tierVariants[itemType][issueId][tier][variant];
    }

    /**
     * @dev Allows to check variants hit count.
     */
    function getVariantHitCount(ItemType itemType, uint256 issueId, uint8 tier, uint8 variant) external view returns (uint256) {
        return _hitVariantsCounters[itemType][issueId][tier][variant];
    }

    /**
     * @dev See {ICollectionRepository-getDerivedItemPrice}.
     */
    function getDerivedItemPrice(ItemType itemType, uint256 issueId, uint8 tier, uint80[2] calldata rounds) external view returns (uint256, uint80[2] memory) {
        ItemTier storage item = _itemTiers[itemType][issueId][tier];
        return _derivePrice(item.price, rounds);
    }

    /**
     * @dev Allows to change the issue phase of the collection.
     *
     * @param issueId - The existing series collection ID.
     * @param phase - The isse phase to set.
     */
    function ajustIssuePhase(uint256 issueId, ItemType itemType, IssuePhase phase) external virtual onlyPrivileged {
        _issueInfos[itemType][issueId].issuePhase = phase;
    }

    /**
     * @notice Sets the specific parameters for a given issue phase.
     * 
     * @param phase The phase to set as minting one.
     * @param tier The item tier which phase settings concers.
     * @param phaseInfo Phase specific parameters.
     */
    function setPhaseInfo(ItemType itemType, uint256 issueId, uint8 tier, IssuePhase phase, PhaseInfo calldata phaseInfo) external onlyPrivileged {
        _phaseInfos[itemType][issueId][tier][phase] = phaseInfo;
    }

    /**
     * @dev Allows to irreversibly change the series configuration as fixed.
     *
     * @param issueId - The existing series collection ID.
     */
    function toggleSeriesFixed(uint256 issueId, ItemType itemType) external virtual onlyPrivileged {
         _issueInfos[itemType][issueId].isFixed = true;
    }
    
    /**
     * @dev See {ICollectionRepository-shuffleItemVariant}.
     */
    function shuffleItemVariant(ItemType itemType, uint256 issueId, uint8 tier, uint256 tokenId) external onlyRole(SVA_ROLE) returns (uint8) {
        uint256 _pickingBlock = _itemsVarianted[tokenId];
        if (_pickingBlock != 0) {
            revert ItemAleadyVarianted(tokenId);
        }

        ItemTier storage _itemTier = _itemTiers[itemType][issueId][uint8(tier)];
        if (_itemTier.variantsCount <= 1) {
            revert InvalidIssueTier(_itemTier.tier);
        }

        uint256[] memory _invariantedCounts = _unpickedVatiantsCount(itemType, issueId, uint8(tier));

        if (_invariantedCounts[_itemTier.variantsCount - 1] == 0) {
            return _defaultVariant;
        }

        _pickingBlock = block.number;
        uint256 _variant = uint256(keccak256(abi.encodePacked(blockhash(_pickingBlock - 1), tokenId))) % _invariantedCounts[_itemTier.variantsCount - 1];

        uint8 _pickedIndex = 0;
        for (uint8 i = 0; i < _itemTier.variantsCount; i++) {
            _pickedIndex  = i;
            if (_variant < _invariantedCounts[i]) {
                break;
            }
        }

        TierVariant storage _pickedVariant = _tierVariants[itemType][issueId][tier][_pickedIndex];

        _itemsVarianted[tokenId] = _pickingBlock;

        _hitVariantsCounters[itemType][issueId][uint8(tier)][_pickedVariant.variant]++;

        return _pickedVariant.variant;
    }

    // *************************************
    // Modifiers
    // ************************************* 

    /**
     * @dev Throws if called by any account other than the priviledged ones.
     */
    modifier onlyPrivileged() {
        _checkPrivileged();
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

    // ************************************* 
    // Utility methods
    // *************************************

    /**
     * @dev Used to derive current token price from the base value in PLN.
     */
    function _derivePrice(uint256 listPrice, uint80[2] memory rounds) internal view virtual returns (uint256 price, uint80[2] memory roundIds) {
        (uint80 _baseRoundId, int256 _basePrice, uint256 _baseTimestamp, bool _callLatestBase) = (0, 0, 0, true);
        (uint80 _quoteRoundId, int256 _quotePrice, uint256 _quoteTimestamp, bool _callLatestQuote) = (0, 0, 0, true);

        if (rounds[0] != 0 && rounds[1] != 0) {
            (_baseRoundId, _basePrice,, _baseTimestamp,) = basePriceFeed.getRoundData(rounds[0]);
            (_quoteRoundId, _quotePrice,, _quoteTimestamp,) = quotePriceFeed.getRoundData(rounds[1]);
            uint256 validTimestamp = block.timestamp - 1 hours;

            _callLatestBase = (_baseTimestamp < validTimestamp);
            _callLatestQuote = (_quoteTimestamp < validTimestamp);
        } 

        if (_callLatestBase) {
            (_baseRoundId, _basePrice,, _baseTimestamp,) = basePriceFeed.latestRoundData();
        }
        if (_callLatestQuote) {
            (_quoteRoundId, _quotePrice,, _quoteTimestamp,) = quotePriceFeed.latestRoundData();
        }

        require(_basePrice > 0 && _quotePrice > 0, "Invalid rates");

        int256 _decimals = int256(10 ** uint256(DEFAULT_DECIMALS));
        _basePrice = _scalePrice(_basePrice, basePriceFeed.decimals(), DEFAULT_DECIMALS);
        _quotePrice = _scalePrice(_quotePrice, quotePriceFeed.decimals(), DEFAULT_DECIMALS);

        price = (uint256(_decimals) * listPrice) / uint256(_basePrice * _decimals / _quotePrice);
        roundIds = [_baseRoundId, _quoteRoundId];
    }

    function _scalePrice(int256 price, uint8 priceDecimals, uint8 decimals) internal pure virtual returns (int256) {
        if (priceDecimals < decimals) {
            return price * int256(10 ** uint256(decimals - priceDecimals));
        } else if (priceDecimals > decimals) {
            return price / int256(10 ** uint256(priceDecimals - decimals));
        }
        return price;
    }

    function _unpickedVatiantsCount(ItemType itemType, uint256 issueId, uint8 tier) internal view returns (uint256[] memory) {
        ItemTier storage _itemTier = _itemTiers[itemType][issueId][tier];

        uint256 _totalPicked = 0;
        uint256[] memory _pickedCount  = new uint256[](_itemTier.variantsCount); 
        for (uint8 i = 0; i < _itemTier.variantsCount; i++) {
            TierVariant storage variant = _tierVariants[itemType][issueId][tier][i];

            if (variant.tier == tier) {
                 _totalPicked += variant.maxSupply - _hitVariantsCounters[itemType][issueId][tier][variant.variant];
                 _pickedCount[i] = _totalPicked;
            }
        }

        return _pickedCount;
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyPrivileged
        override
    {}
}