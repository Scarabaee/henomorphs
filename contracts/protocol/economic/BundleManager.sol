// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../core/MarketplaceRegistry.sol";
import "../core/CollectionManager.sol";
import "../core/ERC721TransferHelper.sol";
import {PaymentProcessor} from"./PaymentProcessor.sol";

/**
 * @title BundleManager
 * @notice Manages creation and trading of NFT bundles
 * @dev UUPS upgradeable - allows multiple NFTs to be packaged and sold together as atomic transactions
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract BundleManager is 
    Initializable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable 
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    struct BundleItem {
        address collection;
        uint256 tokenId;
        bool isIncluded; // for gas optimization when removing items
    }

    struct Bundle {
        address creator;
        address fundsRecipient;
        BundleItem[] items;
        uint256 totalPrice;
        address currency; // address(0) for ETH
        uint256 createdAt;
        uint256 expiresAt; // 0 for no expiration
        bool isActive;
        string bundleName;
        string description;
    }

    struct BundleOffer {
        address buyer;
        uint256 offerPrice;
        address currency;
        uint256 expiresAt;
        bool isActive;
    }

    // Core dependencies - mutable for upgradeability
    MarketplaceRegistry public registry;
    CollectionManager public collectionManager;
    ERC721TransferHelper public transferHelper;
    PaymentProcessor public paymentProcessor;

    // State
    mapping(bytes32 => Bundle) public bundles;
    mapping(bytes32 => mapping(address => BundleOffer)) public bundleOffers;
    mapping(address => bytes32[]) public userBundles;
    mapping(address => mapping(uint256 => bytes32)) public tokenToBundle; // collection -> tokenId -> bundleId
    
    bytes32[] public allBundles;
    
    // Settings
    uint256 public maxBundleSize;
    uint256 public maxBundleDuration;
    uint256 public minBundlePrice;

    // Events
    event BundleCreated(
        bytes32 indexed bundleId,
        address indexed creator,
        uint256 itemCount,
        uint256 totalPrice,
        address currency,
        string bundleName
    );

    event BundleUpdated(
        bytes32 indexed bundleId,
        uint256 newPrice,
        address newCurrency,
        uint256 newExpiresAt
    );

    event BundleCanceled(
        bytes32 indexed bundleId,
        address indexed creator
    );

    event BundleSold(
        bytes32 indexed bundleId,
        address indexed buyer,
        address indexed seller,
        uint256 totalPrice,
        address currency,
        uint256 itemCount
    );

    event BundleOfferMade(
        bytes32 indexed bundleId,
        address indexed buyer,
        uint256 offerPrice,
        address currency,
        uint256 expiresAt
    );

    event BundleOfferAccepted(
        bytes32 indexed bundleId,
        address indexed seller,
        address indexed buyer,
        uint256 acceptedPrice
    );

    event BundleOfferCanceled(
        bytes32 indexed bundleId,
        address indexed buyer
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @param _registry MarketplaceRegistry contract address
     * @param _collectionManager CollectionManager contract address
     * @param _transferHelper ERC721TransferHelper contract address
     * @param _paymentProcessor PaymentProcessor contract address
     * @param _admin Admin address
     */
    function initialize(
        address _registry,
        address _collectionManager,
        address _transferHelper,
        address _paymentProcessor,
        address _admin
    ) external initializer {
        require(_registry != address(0), "Invalid registry");
        require(_collectionManager != address(0), "Invalid collection manager");
        require(_transferHelper != address(0), "Invalid transfer helper");
        require(_paymentProcessor != address(0), "Invalid payment processor");
        require(_admin != address(0), "Invalid admin");

        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        registry = MarketplaceRegistry(_registry);
        collectionManager = CollectionManager(_collectionManager);
        transferHelper = ERC721TransferHelper(_transferHelper);
        // paymentProcessor = PaymentProcessor(_paymentProcessor); //TODO FIX

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);

        // Initialize settings
        maxBundleSize = 50;
        maxBundleDuration = 365 days;
        minBundlePrice = 0.001 ether;
    }

    /**
     * @notice Create a new NFT bundle
     * @param _items Array of NFTs to include in bundle
     * @param _totalPrice Total price for the bundle
     * @param _currency Payment currency (address(0) for ETH)
     * @param _fundsRecipient Address to receive payment
     * @param _duration Bundle duration in seconds (0 for no expiration)
     * @param _bundleName Human-readable bundle name
     * @param _description Bundle description
     */
    function createBundle(
        BundleItem[] calldata _items,
        uint256 _totalPrice,
        address _currency,
        address _fundsRecipient,
        uint256 _duration,
        string calldata _bundleName,
        string calldata _description
    ) external nonReentrant returns (bytes32 bundleId) {
        require(_items.length > 1, "Bundle needs multiple items");
        require(_items.length <= maxBundleSize, "Bundle too large");
        require(_totalPrice >= minBundlePrice, "Price too low");
        require(_fundsRecipient != address(0), "Invalid funds recipient");
        require(_duration == 0 || _duration <= maxBundleDuration, "Duration too long");
        require(bytes(_bundleName).length > 0, "Bundle name required");

        // Validate all items
        for (uint256 i = 0; i < _items.length; i++) {
            require(collectionManager.isTokenTradeable(_items[i].collection, _items[i].tokenId), "Token not tradeable");
            require(IERC721(_items[i].collection).ownerOf(_items[i].tokenId) == msg.sender, "Not token owner");
            require(tokenToBundle[_items[i].collection][_items[i].tokenId] == bytes32(0), "Token already bundled");
        }

        // Validate currency
        // require(paymentProcessor.isCurrencySupported(_currency), "Currency not supported"); //TODO FIX

        // Generate bundle ID
        bundleId = keccak256(abi.encodePacked(
            msg.sender,
            _items.length,
            _totalPrice,
            block.timestamp,
            block.number
        ));

        require(bundles[bundleId].creator == address(0), "Bundle ID collision");

        uint256 expiresAt = _duration > 0 ? block.timestamp + _duration : 0;

        // Create bundle
        Bundle storage bundle = bundles[bundleId];
        bundle.creator = msg.sender;
        bundle.fundsRecipient = _fundsRecipient;
        bundle.totalPrice = _totalPrice;
        bundle.currency = _currency;
        bundle.createdAt = block.timestamp;
        bundle.expiresAt = expiresAt;
        bundle.isActive = true;
        bundle.bundleName = _bundleName;
        bundle.description = _description;

        // Add items to bundle
        for (uint256 i = 0; i < _items.length; i++) {
            bundle.items.push(BundleItem({
                collection: _items[i].collection,
                tokenId: _items[i].tokenId,
                isIncluded: true
            }));
            
            // Mark token as bundled
            tokenToBundle[_items[i].collection][_items[i].tokenId] = bundleId;
        }

        // Add to tracking arrays
        userBundles[msg.sender].push(bundleId);
        allBundles.push(bundleId);

        emit BundleCreated(bundleId, msg.sender, _items.length, _totalPrice, _currency, _bundleName);

        return bundleId;
    }

    /**
     * @notice Update bundle pricing and expiration
     */
    function updateBundle(
        bytes32 _bundleId,
        uint256 _newPrice,
        address _newCurrency,
        uint256 _newDuration
    ) external {
        Bundle storage bundle = bundles[_bundleId];
        require(bundle.creator == msg.sender, "Not bundle creator");
        require(bundle.isActive, "Bundle not active");
        require(!_isBundleExpired(_bundleId), "Bundle expired");
        require(_newPrice >= minBundlePrice, "Price too low");
        // require(paymentProcessor.isCurrencySupported(_newCurrency), "Currency not supported"); //TODO FIX

        uint256 newExpiresAt = _newDuration > 0 ? block.timestamp + _newDuration : 0;

        bundle.totalPrice = _newPrice;
        bundle.currency = _newCurrency;
        bundle.expiresAt = newExpiresAt;

        emit BundleUpdated(_bundleId, _newPrice, _newCurrency, newExpiresAt);
    }

    /**
     * @notice Cancel a bundle and release all NFTs
     */
    function cancelBundle(bytes32 _bundleId) external {
        Bundle storage bundle = bundles[_bundleId];
        require(bundle.creator == msg.sender, "Not bundle creator");
        require(bundle.isActive, "Bundle not active");

        // Release all tokens from bundle
        for (uint256 i = 0; i < bundle.items.length; i++) {
            if (bundle.items[i].isIncluded) {
                delete tokenToBundle[bundle.items[i].collection][bundle.items[i].tokenId];
            }
        }

        bundle.isActive = false;

        emit BundleCanceled(_bundleId, msg.sender);
    }

    /**
     * @notice Purchase a bundle (buy all NFTs at once)
     */
    function purchaseBundle(bytes32 _bundleId) external payable nonReentrant {
        Bundle memory bundle = bundles[_bundleId];
        require(bundle.isActive, "Bundle not active");
        require(!_isBundleExpired(_bundleId), "Bundle expired");
        require(bundle.creator != msg.sender, "Cannot buy own bundle");

        // Validate ownership of all items
        uint256 activeItems = 0;
        for (uint256 i = 0; i < bundle.items.length; i++) {
            if (bundle.items[i].isIncluded) {
                require(
                    IERC721(bundle.items[i].collection).ownerOf(bundle.items[i].tokenId) == bundle.creator,
                    "Seller no longer owns NFT"
                );
                activeItems++;
            }
        }

        require(activeItems > 0, "No items in bundle");

        // Calculate total fees across all collections
        uint256 totalPlatformFee = 0;
        uint256 totalRoyaltyFee = 0;
        address[] memory royaltyRecipients = new address[](bundle.items.length);
        uint256[] memory individualRoyalties = new uint256[](bundle.items.length);

        for (uint256 i = 0; i < bundle.items.length; i++) {
            if (bundle.items[i].isIncluded) {
                // Calculate proportional fees for each item (simplified: equal distribution)
                uint256 itemPrice = bundle.totalPrice / activeItems;
                (,,,address nativeToken,,) = registry.globalConfig();

                (uint256 platformFee, uint256 royaltyFee,) = collectionManager.calculateTotalFees(
                    bundle.items[i].collection,
                    itemPrice,
                    bundle.currency == nativeToken
                );

                totalPlatformFee += platformFee;
                totalRoyaltyFee += royaltyFee;

                CollectionManager.CollectionConfig memory config = collectionManager.getCollectionConfig(bundle.items[i].collection);
                royaltyRecipients[i] = config.royaltyRecipient;
                individualRoyalties[i] = royaltyFee;
            }
        }

        uint256 sellerReceives = bundle.totalPrice - totalPlatformFee - totalRoyaltyFee;

        // Process payment
        // PaymentProcessor.PaymentRequest memory paymentRequest = PaymentProcessor.PaymentRequest({
        //     buyer: msg.sender,
        //     seller: bundle.creator,
        //     sellerFundsRecipient: bundle.fundsRecipient,
        //     currency: bundle.currency,
        //     totalAmount: bundle.totalPrice,
        //     platformFee: totalPlatformFee,
        //     royaltyFee: totalRoyaltyFee,
        //     royaltyRecipient: royaltyRecipients[0], // Simplified: use first recipient
        //     finderFee: 0,
        //     finder: address(0),
        //     sellerAmount: sellerReceives
        // }); //TODO FIX

        // PaymentProcessor.PaymentResult memory result = paymentProcessor.processPayment{value: msg.value}(paymentRequest);
        // require(result.success, "Payment failed"); //TODO FIX

        // Transfer all NFTs
        for (uint256 i = 0; i < bundle.items.length; i++) {
            if (bundle.items[i].isIncluded) {
                transferHelper.safeTransferFrom(
                    bundle.items[i].collection,
                    bundle.creator,
                    msg.sender,
                    bundle.items[i].tokenId
                );

                // Release token from bundle tracking
                delete tokenToBundle[bundle.items[i].collection][bundle.items[i].tokenId];

                // Update collection stats
                collectionManager.updateCollectionStats(bundle.items[i].collection, bundle.totalPrice / activeItems, false);
            }
        }

        // Deactivate bundle
        bundles[_bundleId].isActive = false;

        emit BundleSold(_bundleId, msg.sender, bundle.creator, bundle.totalPrice, bundle.currency, activeItems);
    }

    /**
     * @notice Make an offer on a bundle
     */
    function makeBundleOffer(
        bytes32 _bundleId,
        uint256 _offerPrice,
        address _currency,
        uint256 _duration
    ) external payable nonReentrant {
        Bundle memory bundle = bundles[_bundleId];
        require(bundle.isActive, "Bundle not active");
        require(!_isBundleExpired(_bundleId), "Bundle expired");
        require(bundle.creator != msg.sender, "Cannot offer on own bundle");
        require(_offerPrice > 0, "Invalid offer price");
        // require(paymentProcessor.isCurrencySupported(_currency), "Currency not supported"); //TODO FIX

        uint256 expiresAt = _duration > 0 ? block.timestamp + _duration : 0;

        // Handle payment escrow
        if (_currency == address(0)) {
            require(msg.value >= _offerPrice, "Insufficient ETH sent");
        } else {
            require(msg.value == 0, "ETH not accepted for ERC20 offers");
            // Note: For production, implement proper escrow for ERC20 tokens
        }

        bundleOffers[_bundleId][msg.sender] = BundleOffer({
            buyer: msg.sender,
            offerPrice: _offerPrice,
            currency: _currency,
            expiresAt: expiresAt,
            isActive: true
        });

        emit BundleOfferMade(_bundleId, msg.sender, _offerPrice, _currency, expiresAt);
    }

    /**
     * @notice Accept a bundle offer
     */
    function acceptBundleOffer(bytes32 _bundleId, address _buyer) external nonReentrant {
        Bundle memory bundle = bundles[_bundleId];
        require(bundle.creator == msg.sender, "Not bundle creator");
        require(bundle.isActive, "Bundle not active");

        BundleOffer memory offer = bundleOffers[_bundleId][_buyer];
        require(offer.isActive, "Offer not active");
        require(offer.expiresAt == 0 || block.timestamp <= offer.expiresAt, "Offer expired");

        // Similar to purchaseBundle but using offer price
        // Implementation would follow similar pattern to purchaseBundle
        // For brevity, showing simplified version

        bundles[_bundleId].isActive = false;
        bundleOffers[_bundleId][_buyer].isActive = false;

        emit BundleOfferAccepted(_bundleId, msg.sender, _buyer, offer.offerPrice);
    }

    /**
     * @notice Cancel a bundle offer
     */
    function cancelBundleOffer(bytes32 _bundleId) external {
        BundleOffer storage offer = bundleOffers[_bundleId][msg.sender];
        require(offer.isActive, "Offer not active");

        offer.isActive = false;

        // Refund escrowed funds if ETH
        if (offer.currency == address(0)) {
            payable(msg.sender).transfer(offer.offerPrice);
        }

        emit BundleOfferCanceled(_bundleId, msg.sender);
    }

    /**
     * @notice Check if bundle is expired
     */
    function _isBundleExpired(bytes32 _bundleId) internal view returns (bool) {
        Bundle memory bundle = bundles[_bundleId];
        return bundle.expiresAt > 0 && block.timestamp > bundle.expiresAt;
    }

    // View functions
    function getBundle(bytes32 _bundleId) external view returns (Bundle memory) {
        return bundles[_bundleId];
    }

    function getBundleItems(bytes32 _bundleId) external view returns (BundleItem[] memory) {
        return bundles[_bundleId].items;
    }

    function getBundleOffer(bytes32 _bundleId, address _buyer) external view returns (BundleOffer memory) {
        return bundleOffers[_bundleId][_buyer];
    }

    function getUserBundles(address _user) external view returns (bytes32[] memory) {
        return userBundles[_user];
    }

    function getAllBundles() external view returns (bytes32[] memory) {
        return allBundles;
    }

    function getActiveBundles() external view returns (bytes32[] memory) {
        uint256 activeCount = 0;
        
        // Count active bundles
        for (uint256 i = 0; i < allBundles.length; i++) {
            if (bundles[allBundles[i]].isActive && !_isBundleExpired(allBundles[i])) {
                activeCount++;
            }
        }
        
        // Build active bundles array
        bytes32[] memory activeBundles = new bytes32[](activeCount);
        uint256 currentIndex = 0;
        
        for (uint256 i = 0; i < allBundles.length; i++) {
            if (bundles[allBundles[i]].isActive && !_isBundleExpired(allBundles[i])) {
                activeBundles[currentIndex] = allBundles[i];
                currentIndex++;
            }
        }
        
        return activeBundles;
    }

    function isBundleActive(bytes32 _bundleId) external view returns (bool) {
        return bundles[_bundleId].isActive && !_isBundleExpired(_bundleId);
    }

    function isTokenBundled(address _collection, uint256 _tokenId) external view returns (bool) {
        return tokenToBundle[_collection][_tokenId] != bytes32(0);
    }

    // Admin functions
    function setMaxBundleSize(uint256 _maxSize) external onlyRole(ADMIN_ROLE) {
        require(_maxSize > 1, "Max size too small");
        require(_maxSize <= 200, "Max size too large"); // Gas limit protection
        maxBundleSize = _maxSize;
    }

    function setMaxBundleDuration(uint256 _maxDuration) external onlyRole(ADMIN_ROLE) {
        require(_maxDuration >= 1 days, "Duration too short");
        require(_maxDuration <= 730 days, "Duration too long");
        maxBundleDuration = _maxDuration;
    }

    function setMinBundlePrice(uint256 _minPrice) external onlyRole(ADMIN_ROLE) {
        minBundlePrice = _minPrice;
    }

    /**
     * @notice Update contract dependencies
     */
    function updateDependencies(
        address _registry,
        address _collectionManager,
        address _transferHelper,
        address _paymentProcessor
    ) external onlyRole(ADMIN_ROLE) {
        if (_registry != address(0)) registry = MarketplaceRegistry(_registry);
        if (_collectionManager != address(0)) collectionManager = CollectionManager(_collectionManager);
        if (_transferHelper != address(0)) transferHelper = ERC721TransferHelper(_transferHelper);
        // if (_paymentProcessor != address(0)) paymentProcessor = PaymentProcessor(_paymentProcessor); //TODO FXI
    }

    /**
     * @notice Get contract version
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }

    /**
     * @notice Authorize upgrade - only UPGRADER_ROLE can upgrade
     */
    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyRole(UPGRADER_ROLE) 
    {
        require(newImplementation != address(0), "Invalid implementation");
    }

    // Emergency function to clean up expired bundles
    function cleanupExpiredBundle(bytes32 _bundleId) external {
        require(_isBundleExpired(_bundleId), "Bundle not expired");
        require(bundles[_bundleId].isActive, "Bundle not active");

        Bundle storage bundle = bundles[_bundleId];
        
        // Release all tokens from bundle
        for (uint256 i = 0; i < bundle.items.length; i++) {
            if (bundle.items[i].isIncluded) {
                delete tokenToBundle[bundle.items[i].collection][bundle.items[i].tokenId];
            }
        }

        bundle.isActive = false;
    }
}