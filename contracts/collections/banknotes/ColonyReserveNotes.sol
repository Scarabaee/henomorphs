// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC721EnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

import {IColonyReserveNotes} from "./IColonyReserveNotes.sol";

/**
 * @title IYellowToken
 * @notice Interface for YLW token with mint capability
 */
interface IYellowToken is IERC20 {
    function mint(address to, uint256 amount, string calldata reason) external;
}

/**
 * @title ColonyReserveNotes
 * @notice ERC-721 NFT collection representing YLW-backed banknotes
 * @dev Features:
 *   - Configurable collection metadata
 *   - Multiple series with individual base image URIs
 *   - Configurable denominations with YLW values
 *   - Configurable rarity variants with probability weights
 *   - On-chain metadata generation (tokenURI, contractURI)
 *   - Treasury + Mint fallback for YLW redemption
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract ColonyReserveNotes is
    Initializable,
    ERC721Upgradeable,
    ERC721EnumerableUpgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    IColonyReserveNotes
{
    using SafeERC20 for IERC20;
    using Strings for uint256;
    using Strings for uint32;

    // ============================================
    // STORAGE
    // ============================================

    /// @notice Collection configuration
    CollectionConfig public collectionConfig;

    /// @notice Series configurations by series ID
    mapping(bytes1 => SeriesConfig) private _series;

    /// @notice List of all series IDs
    bytes1[] private _seriesIds;

    /// @notice Denomination configurations by denomination ID
    mapping(uint8 => DenominationConfig) private _denominations;

    /// @notice List of all denomination IDs
    uint8[] private _denominationIds;

    /// @notice Rarity configurations
    mapping(Rarity => RarityConfig) private _rarityConfigs;

    /// @notice Note data per token
    mapping(uint256 => NoteData) private _notes;

    /// @notice Serial counters: seriesId => denominationId => counter
    mapping(bytes1 => mapping(uint8 => uint32)) public serialCounters;

    /// @notice Next token ID
    uint256 private _nextTokenId;

    /// @notice Authorized minters
    mapping(address => bool) public minters;

    /// @notice YLW token address
    address public ylwToken;

    /// @notice Treasury address for YLW transfers
    address public treasury;

    /// @notice Total rarity weight (should be 10000)
    uint16 public totalRarityWeight;

    /// @notice Storage gap for upgrades
    uint256[40] private __gap;

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyMinter() {
        if (!minters[msg.sender]) revert NotMinter();
        _;
    }

    modifier tokenExists(uint256 tokenId) {
        if (_ownerOf(tokenId) == address(0)) revert TokenDoesNotExist(tokenId);
        _;
    }

    // ============================================
    // INITIALIZER
    // ============================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @param name_ Token name
     * @param symbol_ Token symbol
     * @param ylwToken_ YLW token address
     * @param treasury_ Treasury address
     * @param owner_ Contract owner
     */
    function initialize(
        string memory name_,
        string memory symbol_,
        address ylwToken_,
        address treasury_,
        address owner_
    ) external initializer {
        if (ylwToken_ == address(0)) revert InvalidAddress();
        if (treasury_ == address(0)) revert InvalidAddress();
        if (owner_ == address(0)) revert InvalidAddress();

        __ERC721_init(name_, symbol_);
        __ERC721Enumerable_init();
        __ReentrancyGuard_init();
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();

        ylwToken = ylwToken_;
        treasury = treasury_;
        _nextTokenId = 1;

        collectionConfig.name = name_;
        collectionConfig.symbol = symbol_;

        // Initialize default rarity configs
        _initializeDefaultRarities();
    }

    // ============================================
    // ADMIN: COLLECTION CONFIG
    // ============================================

    /**
     * @notice Configure collection metadata
     */
    function configureCollection(CollectionConfig calldata config) external onlyOwner {
        collectionConfig = config;
        emit CollectionConfigured(config.name, config.symbol);
    }

    /**
     * @notice Set collection description
     */
    function setCollectionDescription(string calldata description) external onlyOwner {
        collectionConfig.description = description;
    }

    /**
     * @notice Set collection external link
     */
    function setCollectionExternalLink(string calldata externalLink) external onlyOwner {
        collectionConfig.externalLink = externalLink;
    }

    /**
     * @notice Set collection banner image
     */
    function setCollectionBannerImage(string calldata bannerImage) external onlyOwner {
        collectionConfig.bannerImage = bannerImage;
    }

    // ============================================
    // ADMIN: SERIES CONFIG
    // ============================================

    /**
     * @notice Configure a series
     */
    function configureSeries(SeriesConfig calldata config) external onlyOwner {
        bytes1 seriesId = config.seriesId;

        // Track new series
        if (_series[seriesId].seriesId == 0) {
            _seriesIds.push(seriesId);
        }

        _series[seriesId] = config;
        emit SeriesConfigured(seriesId, config.name, config.baseImageUri);
    }

    /**
     * @notice Set series active status
     */
    function setSeriesActive(bytes1 seriesId, bool active) external onlyOwner {
        if (_series[seriesId].seriesId == 0) revert SeriesNotFound(seriesId);
        _series[seriesId].active = active;
        emit SeriesActiveChanged(seriesId, active);
    }

    /**
     * @notice Update series base image URI
     */
    function setSeriesBaseImageUri(bytes1 seriesId, string calldata baseImageUri) external onlyOwner {
        if (_series[seriesId].seriesId == 0) revert SeriesNotFound(seriesId);
        _series[seriesId].baseImageUri = baseImageUri;
        emit SeriesConfigured(seriesId, _series[seriesId].name, baseImageUri);
    }

    // ============================================
    // ADMIN: DENOMINATION CONFIG
    // ============================================

    /**
     * @notice Configure a denomination
     */
    function configureDenomination(DenominationConfig calldata config) external onlyOwner {
        uint8 denomId = config.denominationId;

        // Track new denomination
        bool exists = false;
        for (uint256 i = 0; i < _denominationIds.length; i++) {
            if (_denominationIds[i] == denomId) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            _denominationIds.push(denomId);
        }

        _denominations[denomId] = config;
        emit DenominationConfigured(denomId, config.name, config.ylwValue);
    }

    /**
     * @notice Set denomination active status
     */
    function setDenominationActive(uint8 denominationId, bool active) external onlyOwner {
        if (bytes(_denominations[denominationId].name).length == 0) {
            revert DenominationNotFound(denominationId);
        }
        _denominations[denominationId].active = active;
        emit DenominationActiveChanged(denominationId, active);
    }

    // ============================================
    // ADMIN: RARITY CONFIG
    // ============================================

    /**
     * @notice Configure a rarity level
     * @dev Sum of all weights should equal 10000 for proper probability distribution
     */
    function configureRarity(RarityConfig calldata config) external onlyOwner {
        // Update total weight
        totalRarityWeight = totalRarityWeight - _rarityConfigs[config.rarity].weightBps + config.weightBps;

        _rarityConfigs[config.rarity] = config;
        emit RarityConfigured(config.rarity, config.name, config.weightBps, config.bonusMultiplierBps);
    }

    /**
     * @notice Batch configure all rarities
     */
    function configureRarities(RarityConfig[] calldata configs) external onlyOwner {
        uint16 newTotalWeight = 0;

        for (uint256 i = 0; i < configs.length; i++) {
            _rarityConfigs[configs[i].rarity] = configs[i];
            newTotalWeight += configs[i].weightBps;
            emit RarityConfigured(
                configs[i].rarity,
                configs[i].name,
                configs[i].weightBps,
                configs[i].bonusMultiplierBps
            );
        }

        totalRarityWeight = newTotalWeight;

        if (newTotalWeight != 10000) revert InvalidRarityWeights();
    }

    // ============================================
    // ADMIN: ACCESS CONTROL
    // ============================================

    /**
     * @notice Set minter authorization
     */
    function setMinter(address minter, bool authorized) external onlyOwner {
        if (minter == address(0)) revert InvalidAddress();
        minters[minter] = authorized;
        emit MinterUpdated(minter, authorized);
    }

    /**
     * @notice Set treasury address
     */
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert InvalidAddress();
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @notice Set YLW token address
     */
    function setYlwToken(address newYlwToken) external onlyOwner {
        if (newYlwToken == address(0)) revert InvalidAddress();
        address oldToken = ylwToken;
        ylwToken = newYlwToken;
        emit YlwTokenUpdated(oldToken, newYlwToken);
    }

    // ============================================
    // MINTING
    // ============================================

    /**
     * @inheritdoc IColonyReserveNotes
     */
    function mintNote(
        address to,
        uint8 denominationId,
        bytes1 seriesId
    ) external onlyMinter returns (uint256 tokenId) {
        _validateMintParams(denominationId, seriesId);

        uint256 seed = _generateSeed(to, _nextTokenId);
        Rarity rarity = _selectRarity(seed);

        return _mintNote(to, denominationId, seriesId, rarity);
    }

    /**
     * @inheritdoc IColonyReserveNotes
     */
    function mintNoteWithRarity(
        address to,
        uint8 denominationId,
        bytes1 seriesId,
        Rarity rarity
    ) external onlyMinter returns (uint256 tokenId) {
        _validateMintParams(denominationId, seriesId);
        if (_rarityConfigs[rarity].weightBps == 0) revert RarityNotConfigured(rarity);

        return _mintNote(to, denominationId, seriesId, rarity);
    }

    /**
     * @inheritdoc IColonyReserveNotes
     */
    function mintNoteBatch(
        address to,
        uint8[] calldata denominationIds,
        bytes1 seriesId
    ) external onlyMinter returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](denominationIds.length);

        for (uint256 i = 0; i < denominationIds.length; i++) {
            _validateMintParams(denominationIds[i], seriesId);

            uint256 seed = _generateSeed(to, _nextTokenId + i);
            Rarity rarity = _selectRarity(seed);

            tokenIds[i] = _mintNote(to, denominationIds[i], seriesId, rarity);
        }

        return tokenIds;
    }

    // ============================================
    // REDEMPTION
    // ============================================

    /**
     * @inheritdoc IColonyReserveNotes
     */
    function redeemNote(uint256 tokenId) external nonReentrant tokenExists(tokenId) {
        if (ownerOf(tokenId) != msg.sender) revert NotOwner();

        NoteData memory note = _notes[tokenId];
        uint256 ylwAmount = _calculateNoteValue(note);

        // Burn NFT first
        _burn(tokenId);
        delete _notes[tokenId];

        // Send YLW with Treasury + Mint fallback
        _sendYlwWithFallback(msg.sender, ylwAmount);

        emit NoteRedeemed(tokenId, msg.sender, ylwAmount, note.rarity);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @inheritdoc IColonyReserveNotes
     */
    function getNoteValue(uint256 tokenId) external view tokenExists(tokenId) returns (uint256 ylwAmount) {
        return _calculateNoteValue(_notes[tokenId]);
    }

    /**
     * @inheritdoc IColonyReserveNotes
     */
    function getNoteData(uint256 tokenId) external view tokenExists(tokenId) returns (NoteData memory data) {
        return _notes[tokenId];
    }

    /**
     * @inheritdoc IColonyReserveNotes
     */
    function getSerialNumber(uint256 tokenId) external view tokenExists(tokenId) returns (string memory serial) {
        return _formatSerialNumber(_notes[tokenId]);
    }

    /**
     * @inheritdoc IColonyReserveNotes
     */
    function getSeriesConfig(bytes1 seriesId) external view returns (SeriesConfig memory config) {
        return _series[seriesId];
    }

    /**
     * @inheritdoc IColonyReserveNotes
     */
    function getDenominationConfig(uint8 denominationId) external view returns (DenominationConfig memory config) {
        return _denominations[denominationId];
    }

    /**
     * @inheritdoc IColonyReserveNotes
     */
    function getRarityConfig(Rarity rarity) external view returns (RarityConfig memory config) {
        return _rarityConfigs[rarity];
    }

    /**
     * @inheritdoc IColonyReserveNotes
     */
    function getActiveSeriesIds() external view returns (bytes1[] memory seriesIds) {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < _seriesIds.length; i++) {
            if (_series[_seriesIds[i]].active) activeCount++;
        }

        seriesIds = new bytes1[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < _seriesIds.length; i++) {
            if (_series[_seriesIds[i]].active) {
                seriesIds[index++] = _seriesIds[i];
            }
        }
    }

    /**
     * @inheritdoc IColonyReserveNotes
     */
    function getActiveDenominationIds() external view returns (uint8[] memory denominationIds) {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < _denominationIds.length; i++) {
            if (_denominations[_denominationIds[i]].active) activeCount++;
        }

        denominationIds = new uint8[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < _denominationIds.length; i++) {
            if (_denominations[_denominationIds[i]].active) {
                denominationIds[index++] = _denominationIds[i];
            }
        }
    }

    /**
     * @notice Get all series IDs
     */
    function getAllSeriesIds() external view returns (bytes1[] memory) {
        return _seriesIds;
    }

    /**
     * @notice Get all denomination IDs
     */
    function getAllDenominationIds() external view returns (uint8[] memory) {
        return _denominationIds;
    }

    // ============================================
    // METADATA (ON-CHAIN)
    // ============================================

    /**
     * @notice Generate token metadata URI on-chain
     */
    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721Upgradeable)
        tokenExists(tokenId)
        returns (string memory)
    {
        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(bytes(_buildTokenJsonForId(tokenId)))
        ));
    }

    function _buildTokenJsonForId(uint256 tokenId) internal view returns (string memory) {
        NoteData memory note = _notes[tokenId];
        DenominationConfig memory denomConf = _denominations[note.denominationId];
        RarityConfig memory rarityConf = _rarityConfigs[note.rarity];
        uint256 finalValue = (denomConf.ylwValue * rarityConf.bonusMultiplierBps) / 10000;
        string memory serialNum = _formatSerialNumber(note);

        return string(abi.encodePacked(
            '{"name":"', collectionConfig.name, ' #', serialNum, '",',
            '"description":"', denomConf.name, ' - ', _formatYlw(finalValue), ' YLW Note",',
            '"image":"', _buildImageUrlForNote(note), '",',
            '"attributes":', _buildAttributesForNote(note, finalValue, serialNum), '}'
        ));
    }

    function _buildImageUrlForNote(NoteData memory note) internal view returns (string memory) {
        SeriesConfig memory seriesConf = _series[note.seriesId];
        DenominationConfig memory denomConf = _denominations[note.denominationId];
        RarityConfig memory rarityConf = _rarityConfigs[note.rarity];

        return string(abi.encodePacked(
            seriesConf.baseImageUri,
            denomConf.imageSubpath,
            rarityConf.imageSuffix,
            ".png"
        ));
    }

    function _buildAttributesForNote(
        NoteData memory note,
        uint256 finalValue,
        string memory serialNum
    ) internal view returns (string memory) {
        DenominationConfig memory denomConf = _denominations[note.denominationId];
        SeriesConfig memory seriesConf = _series[note.seriesId];
        RarityConfig memory rarityConf = _rarityConfigs[note.rarity];

        return string(abi.encodePacked(
            '[{"trait_type":"Denomination","value":"', denomConf.name, '"},',
            '{"trait_type":"Value","value":"', _formatYlw(finalValue), ' YLW"},',
            '{"trait_type":"Series","value":"', seriesConf.name, '"},',
            '{"trait_type":"Rarity","value":"', rarityConf.name, '"},',
            '{"trait_type":"Serial Number","value":"', serialNum, '"},',
            '{"display_type":"date","trait_type":"Minted","value":', uint256(note.mintedAt).toString(), '}]'
        ));
    }

    /**
     * @inheritdoc IColonyReserveNotes
     */
    function contractURI() external view returns (string memory uri) {
        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(bytes(abi.encodePacked(
                '{"name":"', collectionConfig.name, '",',
                '"description":"', collectionConfig.description, '",',
                '"image":"', collectionConfig.bannerImage, '",',
                '"external_link":"', collectionConfig.externalLink, '",',
                '"seller_fee_basis_points":0,',
                '"fee_recipient":"0x0000000000000000000000000000000000000000"}'
            )))
        ));
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    function _initializeDefaultRarities() internal {
        _rarityConfigs[Rarity.Common] = RarityConfig({
            rarity: Rarity.Common,
            name: "Common",
            imageSuffix: "-common",
            weightBps: 6000,
            bonusMultiplierBps: 10000
        });
        _rarityConfigs[Rarity.Uncommon] = RarityConfig({
            rarity: Rarity.Uncommon,
            name: "Uncommon",
            imageSuffix: "-uncommon",
            weightBps: 2500,
            bonusMultiplierBps: 10000
        });
        _rarityConfigs[Rarity.Rare] = RarityConfig({
            rarity: Rarity.Rare,
            name: "Rare",
            imageSuffix: "-rare",
            weightBps: 1000,
            bonusMultiplierBps: 10250
        });
        _rarityConfigs[Rarity.Epic] = RarityConfig({
            rarity: Rarity.Epic,
            name: "Epic",
            imageSuffix: "-epic",
            weightBps: 400,
            bonusMultiplierBps: 10500
        });
        _rarityConfigs[Rarity.Legendary] = RarityConfig({
            rarity: Rarity.Legendary,
            name: "Legendary",
            imageSuffix: "-legendary",
            weightBps: 100,
            bonusMultiplierBps: 11000
        });

        totalRarityWeight = 10000;
    }

    function _validateMintParams(uint8 denominationId, bytes1 seriesId) internal view {
        SeriesConfig storage seriesConf = _series[seriesId];
        if (seriesConf.seriesId == 0) revert SeriesNotFound(seriesId);
        if (!seriesConf.active) revert SeriesNotActive(seriesId);
        if (seriesConf.maxSupply > 0 && seriesConf.mintedCount >= seriesConf.maxSupply) {
            revert SeriesMaxSupplyReached(seriesId);
        }
        if (seriesConf.startTime > 0 && block.timestamp < seriesConf.startTime) {
            revert SeriesNotStarted(seriesId);
        }
        if (seriesConf.endTime > 0 && block.timestamp > seriesConf.endTime) {
            revert SeriesEnded(seriesId);
        }

        DenominationConfig storage denomConf = _denominations[denominationId];
        if (bytes(denomConf.name).length == 0) revert DenominationNotFound(denominationId);
        if (!denomConf.active) revert DenominationNotActive(denominationId);
    }

    function _mintNote(
        address to,
        uint8 denominationId,
        bytes1 seriesId,
        Rarity rarity
    ) internal returns (uint256 tokenId) {
        tokenId = _nextTokenId++;

        // Increment counters
        _series[seriesId].mintedCount++;
        uint32 serialNumber = ++serialCounters[seriesId][denominationId];

        // Store note data
        _notes[tokenId] = NoteData({
            denominationId: denominationId,
            seriesId: seriesId,
            rarity: rarity,
            serialNumber: serialNumber,
            mintedAt: uint32(block.timestamp)
        });

        _safeMint(to, tokenId);

        emit NoteMinted(tokenId, to, denominationId, seriesId, rarity, serialNumber);
    }

    function _selectRarity(uint256 seed) internal view returns (Rarity) {
        uint256 roll = seed % 10000;
        uint256 cumulative = 0;

        for (uint8 i = 0; i <= uint8(Rarity.Legendary); i++) {
            Rarity r = Rarity(i);
            cumulative += _rarityConfigs[r].weightBps;
            if (roll < cumulative) {
                return r;
            }
        }
        return Rarity.Common;
    }

    function _generateSeed(address to, uint256 tokenId) internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            to,
            tokenId,
            _nextTokenId,
            blockhash(block.number - 1)
        )));
    }

    function _calculateNoteValue(NoteData memory note) internal view returns (uint256) {
        DenominationConfig memory denomConf = _denominations[note.denominationId];
        RarityConfig memory rarityConf = _rarityConfigs[note.rarity];
        return (denomConf.ylwValue * rarityConf.bonusMultiplierBps) / 10000;
    }

    function _sendYlwWithFallback(address recipient, uint256 amount) internal {
        uint256 treasuryBalance = IERC20(ylwToken).balanceOf(treasury);

        if (treasuryBalance >= amount) {
            IERC20(ylwToken).safeTransferFrom(treasury, recipient, amount);
        } else {
            if (treasuryBalance > 0) {
                IERC20(ylwToken).safeTransferFrom(treasury, recipient, treasuryBalance);
            }
            uint256 shortfall = amount - treasuryBalance;
            IYellowToken(ylwToken).mint(recipient, shortfall, "note_redeem");
        }
    }

    function _formatSerialNumber(NoteData memory note) internal view returns (string memory) {
        DenominationConfig memory denomConf = _denominations[note.denominationId];

        return string(abi.encodePacked(
            collectionConfig.symbol,
            "-",
            string(abi.encodePacked(note.seriesId)),
            "-",
            denomConf.imageSubpath,
            "-",
            _padNumber(note.serialNumber, 6)
        ));
    }

    function _padNumber(uint32 num, uint8 length) internal pure returns (string memory) {
        bytes memory numStr = bytes(uint256(num).toString());
        if (numStr.length >= length) return string(numStr);

        bytes memory padded = new bytes(length);
        uint8 padLength = length - uint8(numStr.length);

        for (uint8 i = 0; i < padLength; i++) {
            padded[i] = "0";
        }
        for (uint8 i = 0; i < numStr.length; i++) {
            padded[padLength + i] = numStr[i];
        }

        return string(padded);
    }

    function _formatYlw(uint256 amount) internal pure returns (string memory) {
        uint256 whole = amount / 1e18;
        return whole.toString();
    }

    // ============================================
    // OVERRIDES
    // ============================================

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
        returns (address)
    {
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
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
