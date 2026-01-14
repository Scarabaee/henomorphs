// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol"; 
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MarketplaceRegistry} from "../core/MarketplaceRegistry.sol";
import "../core/CollectionManager.sol";
import "../core/ERC721TransferHelper.sol";
import "../core/ModuleManager.sol";

/**
 * @title AsksV1
 * @notice UUPS upgradeable fixed price listing module - the core trading contract
 * @dev Handles creation, management and fulfillment of fixed-price NFT listings
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract AsksV1 is Initializable, ReentrancyGuardUpgradeable, AccessControlUpgradeable, UUPSUpgradeable {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    event ExpiredAskRemoved(address indexed collection, uint256 indexed tokenId, address indexed seller);

    // Custom errors
    error TokenNotTradeable();
    error NotTokenOwner();
    error InvalidPrice();
    error InvalidRecipient();
    error FindersFeeTooHigh();
    error DurationTooLong();
    error AskAlreadyExists();
    error InvalidCurrency();
    error MustUseNativeToken();
    error NotAskCreator();
    error AskExpired();
    error AskNotFound();
    error CannotBuyOwnNFT();
    error SellerNoLongerOwns();
    error InsufficientPayment();
    error TransferFailed();
    error InvalidDependency();

    struct Ask {
        address seller;
        address sellerFundsRecipient;
        address askCurrency; // address(0) for ETH
        uint16 findersFeeBps; // fee for facilitating the sale (in basis points)
        uint256 askPrice;
        uint256 createdAt;
        uint256 expiresAt; // 0 for no expiration
    }

    // Core dependencies - changed from immutable to storage for upgradeability
    MarketplaceRegistry public registry;
    CollectionManager public collectionManager;
    ERC721TransferHelper public transferHelper;
    ModuleManager public moduleManager;

    // Storage
    mapping(address => mapping(uint256 => Ask)) public askForNFT;
    mapping(address => uint256) public userActiveAsks;
    
    // Global settings
    uint16 public maxFindersFeeBps;
    uint256 public maxAskDuration;

    // Gap for future storage variables
    uint256[44] private __gap;

    // Events
    event AskCreated(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed seller,
        address sellerFundsRecipient,
        address askCurrency,
        uint256 askPrice,
        uint16 findersFeeBps,
        uint256 expiresAt
    );

    event AskUpdated(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed seller,
        address askCurrency,
        uint256 askPrice,
        uint16 findersFeeBps,
        uint256 expiresAt
    );

    event AskCanceled(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed seller
    );

    event AskFilled(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed buyer,
        address seller,
        address finder,
        address askCurrency,
        uint256 askPrice,
        uint256 sellerReceived,
        uint256 finderFee,
        uint256 platformFee,
        uint256 royaltyFee
    );

    event DependencyUpdated(string indexed dependencyName, address indexed oldAddress, address indexed newAddress);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _registry,
        address _collectionManager,
        address _transferHelper,
        address _moduleManager,
        address _admin
    ) external initializer {
        if (_registry == address(0)) revert InvalidRecipient();
        if (_collectionManager == address(0)) revert InvalidRecipient();
        if (_transferHelper == address(0)) revert InvalidRecipient();
        if (_moduleManager == address(0)) revert InvalidRecipient();
        if (_admin == address(0)) revert InvalidRecipient();

        __ReentrancyGuard_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        registry = MarketplaceRegistry(_registry);
        collectionManager = CollectionManager(_collectionManager);
        transferHelper = ERC721TransferHelper(_transferHelper);
        moduleManager = ModuleManager(_moduleManager);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);

        maxFindersFeeBps = 1000; // 10% max
        maxAskDuration = 365 days;
    }

    /**
     * @notice Create a fixed-price listing for an NFT
     * @param _collection NFT contract address
     * @param _tokenId Token ID to list
     * @param _askCurrency Currency for payment (address(0) for ETH)
     * @param _askPrice Listing price
     * @param _sellerFundsRecipient Address to receive seller funds
     * @param _findersFeeBps Fee for sale facilitator (in basis points)
     * @param _duration Listing duration in seconds (0 for no expiration)
     */
    function createAsk(
        address _collection,
        uint256 _tokenId,
        address _askCurrency,
        uint256 _askPrice,
        address _sellerFundsRecipient,
        uint16 _findersFeeBps,
        uint256 _duration
    ) external nonReentrant {
        if (!collectionManager.isTokenTradeable(_collection, _tokenId)) revert TokenNotTradeable();
        if (IERC721(_collection).ownerOf(_tokenId) != msg.sender) revert NotTokenOwner();
        if (_askPrice == 0) revert InvalidPrice();
        if (!collectionManager.validatePrice(_collection, _askPrice)) revert InvalidPrice();
        if (_sellerFundsRecipient == address(0)) revert InvalidRecipient();
        if (_findersFeeBps > maxFindersFeeBps) revert FindersFeeTooHigh();
        if (_duration != 0 && _duration > maxAskDuration) revert DurationTooLong();

        // Check if ask already exists
        if (askForNFT[_collection][_tokenId].seller != address(0)) revert AskAlreadyExists();

        // Validate currency
        if (_askCurrency != address(0)) {
            // For ERC20, ensure it's a valid contract
            if (_askCurrency.code.length == 0) revert InvalidCurrency();
        }

        // Check collection-specific requirements
        CollectionManager.CollectionConfig memory config = collectionManager.getCollectionConfig(_collection);
        // if (config.requiresNativeToken) {
        //     if (_askCurrency != registry.globalConfig().nativeToken) revert MustUseNativeToken(); //TODO FIX
        // }

        uint256 expiresAt = _duration > 0 ? block.timestamp + _duration : 0;

        askForNFT[_collection][_tokenId] = Ask({
            seller: msg.sender,
            sellerFundsRecipient: _sellerFundsRecipient,
            askCurrency: _askCurrency,
            findersFeeBps: _findersFeeBps,
            askPrice: _askPrice,
            createdAt: block.timestamp,
            expiresAt: expiresAt
        });

        userActiveAsks[msg.sender]++;

        // Update collection stats
        collectionManager.updateCollectionStats(_collection, _askPrice, true);

        emit AskCreated(
            _collection,
            _tokenId,
            msg.sender,
            _sellerFundsRecipient,
            _askCurrency,
            _askPrice,
            _findersFeeBps,
            expiresAt
        );
    }

    /**
     * @notice Update an existing ask
     */
    function updateAsk(
        address _collection,
        uint256 _tokenId,
        address _askCurrency,
        uint256 _askPrice,
        uint16 _findersFeeBps,
        uint256 _duration
    ) external {
        Ask storage ask = askForNFT[_collection][_tokenId];
        if (ask.seller != msg.sender) revert NotAskCreator();
        if (_isAskExpired(_collection, _tokenId)) revert AskExpired();
        if (_askPrice == 0) revert InvalidPrice();
        if (!collectionManager.validatePrice(_collection, _askPrice)) revert InvalidPrice();
        if (_findersFeeBps > maxFindersFeeBps) revert FindersFeeTooHigh();

        uint256 expiresAt = _duration > 0 ? block.timestamp + _duration : 0;

        ask.askCurrency = _askCurrency;
        ask.askPrice = _askPrice;
        ask.findersFeeBps = _findersFeeBps;
        ask.expiresAt = expiresAt;

        emit AskUpdated(_collection, _tokenId, msg.sender, _askCurrency, _askPrice, _findersFeeBps, expiresAt);
    }

    /**
     * @notice Cancel an ask
     */
    function cancelAsk(address _collection, uint256 _tokenId) external {
        Ask storage ask = askForNFT[_collection][_tokenId];
        if (ask.seller != msg.sender) revert NotAskCreator();

        userActiveAsks[msg.sender]--;
        delete askForNFT[_collection][_tokenId];

        emit AskCanceled(_collection, _tokenId, msg.sender);
    }

    /**
     * @notice Fill an ask (buy the NFT)
     * @param _collection NFT contract address
     * @param _tokenId Token ID to purchase
     * @param _finder Address that facilitated the sale (for finder's fee)
     */
    function fillAsk(
        address _collection,
        uint256 _tokenId,
        address _finder
    ) external payable nonReentrant {
        Ask memory ask = askForNFT[_collection][_tokenId];
        if (ask.seller == address(0)) revert AskNotFound();
        if (_isAskExpired(_collection, _tokenId)) revert AskExpired();
        if (ask.seller == msg.sender) revert CannotBuyOwnNFT();
        if (IERC721(_collection).ownerOf(_tokenId) != ask.seller) revert SellerNoLongerOwns();

        // Calculate fees
        // (uint256 platformFee, uint256 royaltyFee, uint256 totalProtocolFee) = collectionManager.calculateTotalFees(
        //     _collection,
        //     ask.askPrice,
        //     ask.askCurrency == registry.globalConfig().nativeToken
        // );

        (uint256 platformFee, uint256 royaltyFee, uint256 totalProtocolFee) = collectionManager.calculateTotalFees(
            _collection,
            ask.askPrice,
            ask.askCurrency == address(0) //TODO FIX
        );

        uint256 finderFee = (ask.askPrice * ask.findersFeeBps) / 10000;
        uint256 sellerReceives = ask.askPrice - totalProtocolFee - finderFee;

        // Handle payment
        if (ask.askCurrency == address(0)) {
            // ETH payment
            if (msg.value < ask.askPrice) revert InsufficientPayment();
            _handleETHPayment(ask, platformFee, royaltyFee, finderFee, sellerReceives, _finder, _collection);
            
            // Refund excess
            if (msg.value > ask.askPrice) {
                (bool success, ) = payable(msg.sender).call{value: msg.value - ask.askPrice}("");
                if (!success) revert TransferFailed();
            }
        } else {
            // ERC20 payment
            if (msg.value != 0) revert InvalidPrice();
            _handleERC20Payment(ask, platformFee, royaltyFee, finderFee, sellerReceives, _finder, _collection);
        }

        // Transfer NFT
        transferHelper.safeTransferFrom(_collection, ask.seller, msg.sender, _tokenId);

        // Update state
        userActiveAsks[ask.seller]--;
        delete askForNFT[_collection][_tokenId];

        // Update collection stats
        collectionManager.updateCollectionStats(_collection, ask.askPrice, false);

        emit AskFilled(
            _collection,
            _tokenId,
            msg.sender,
            ask.seller,
            _finder,
            ask.askCurrency,
            ask.askPrice,
            sellerReceives,
            finderFee,
            platformFee,
            royaltyFee
        );
    }

    /**
     * @notice Clean up expired asks (public function for gas optimization)
     */
    function removeExpiredAsk(address _collection, uint256 _tokenId) external {
        if (!_isAskExpired(_collection, _tokenId)) revert AskExpired();
        
        Ask memory ask = askForNFT[_collection][_tokenId];
        userActiveAsks[ask.seller]--;
        delete askForNFT[_collection][_tokenId];

        emit ExpiredAskRemoved(_collection, _tokenId, ask.seller);
    }

    /**
     * @notice Handle ETH payment distribution
     */
    function _handleETHPayment(
        Ask memory ask,
        uint256 platformFee,
        uint256 royaltyFee,
        uint256 finderFee,
        uint256 sellerReceives,
        address finder,
        address collection
    ) internal {
        // Pay platform fee
        // if (platformFee > 0) {
        //     (bool _success, ) = payable(registry.globalConfig().feeRecipient).call{value: platformFee}("");
        //     if (!_success) revert TransferFailed();
        // } //TODO FIX

        // Pay royalty
        if (royaltyFee > 0) {
            CollectionManager.CollectionConfig memory config = collectionManager.getCollectionConfig(collection);
            (bool _success, ) = payable(config.royaltyRecipient).call{value: royaltyFee}("");
            if (!_success) revert TransferFailed();
        }

        // Pay finder fee
        if (finderFee > 0 && finder != address(0)) {
            (bool _success, ) = payable(finder).call{value: finderFee}("");
            if (!_success) revert TransferFailed();
        }

        // Pay seller
        (bool success, ) = payable(ask.sellerFundsRecipient).call{value: sellerReceives}("");
        if (!success) revert TransferFailed();
    }

    /**
     * @notice Handle ERC20 payment distribution
     */
    function _handleERC20Payment(
        Ask memory ask,
        uint256 platformFee,
        uint256 royaltyFee,
        uint256 finderFee,
        uint256 sellerReceives,
        address finder,
        address collection
    ) internal {
        IERC20 token = IERC20(ask.askCurrency);

        // Transfer total amount from buyer
        if (!token.transferFrom(msg.sender, address(this), ask.askPrice)) revert TransferFailed();

        // Distribute payments
        // if (platformFee > 0) {
        //     if (!token.transfer(registry.globalConfig().feeRecipient, platformFee)) revert TransferFailed();
        // } //TODO FIX

        if (royaltyFee > 0) {
            CollectionManager.CollectionConfig memory config = collectionManager.getCollectionConfig(collection);
            if (!token.transfer(config.royaltyRecipient, royaltyFee)) revert TransferFailed();
        }

        if (finderFee > 0 && finder != address(0)) {
            if (!token.transfer(finder, finderFee)) revert TransferFailed();
        }

        if (!token.transfer(ask.sellerFundsRecipient, sellerReceives)) revert TransferFailed();
    }

    /**
     * @notice Check if an ask is expired
     */
    function _isAskExpired(address _collection, uint256 _tokenId) internal view returns (bool) {
        Ask memory ask = askForNFT[_collection][_tokenId];
        return ask.expiresAt > 0 && block.timestamp > ask.expiresAt;
    }

    // View functions
    function getAsk(address _collection, uint256 _tokenId) external view returns (Ask memory) {
        return askForNFT[_collection][_tokenId];
    }

    function isAskActive(address _collection, uint256 _tokenId) external view returns (bool) {
        Ask memory ask = askForNFT[_collection][_tokenId];
        return ask.seller != address(0) && !_isAskExpired(_collection, _tokenId);
    }

    function getUserActiveAskCount(address _user) external view returns (uint256) {
        return userActiveAsks[_user];
    }

    // Admin functions
    function setMaxFindersFeeBps(uint16 _maxFindersFeeBps) external onlyRole(ADMIN_ROLE) {
        if (_maxFindersFeeBps > 2000) revert FindersFeeTooHigh();
        maxFindersFeeBps = _maxFindersFeeBps;
    }

    function setMaxAskDuration(uint256 _maxAskDuration) external onlyRole(ADMIN_ROLE) {
        if (_maxAskDuration < 1 days) revert DurationTooLong();
        if (_maxAskDuration > 730 days) revert DurationTooLong();
        maxAskDuration = _maxAskDuration;
    }

    /**
     * @notice Update dependencies for upgradeability
     */
    function updateDependencies(
        address _registry,
        address _collectionManager,
        address _transferHelper,
        address _moduleManager
    ) external onlyRole(ADMIN_ROLE) {
        if (_registry != address(0)) {
            emit DependencyUpdated("registry", address(registry), _registry);
            registry = MarketplaceRegistry(_registry);
        }
        if (_collectionManager != address(0)) {
            emit DependencyUpdated("collectionManager", address(collectionManager), _collectionManager);
            collectionManager = CollectionManager(_collectionManager);
        }
        if (_transferHelper != address(0)) {
            emit DependencyUpdated("transferHelper", address(transferHelper), _transferHelper);
            transferHelper = ERC721TransferHelper(_transferHelper);
        }
        if (_moduleManager != address(0)) {
            emit DependencyUpdated("moduleManager", address(moduleManager), _moduleManager);
            moduleManager = ModuleManager(_moduleManager);
        }
    }

    /**
     * @notice Authorize upgrade - only UPGRADER_ROLE can upgrade
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}