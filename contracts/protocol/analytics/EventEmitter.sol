// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../core/MarketplaceRegistry.sol";

/**
 * @title EventEmitter
 * @notice Centralized event emission system for marketplace analytics and indexing
 * @dev UUPS upgradeable - provides standardized events across all marketplace modules for easier indexing
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract EventEmitter is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    bytes32 public constant EMITTER_ROLE = keccak256("EMITTER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // Core dependencies - mutable for upgradeability
    MarketplaceRegistry public registry;

    // Event counters for analytics
    uint256 public totalEventsEmitted;
    mapping(string => uint256) public eventTypeCounters;

    // Standardized Events for Core Trading
    event ListingCreated(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed seller,
        uint256 price,
        address currency,
        uint256 timestamp,
        uint256 expiresAt,
        string eventId
    );

    event ListingUpdated(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed seller,
        uint256 oldPrice,
        uint256 newPrice,
        address currency,
        uint256 timestamp,
        string eventId
    );

    event ListingCanceled(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed seller,
        uint256 timestamp,
        string reason,
        string eventId
    );

    event NFTSold(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed seller,
        address buyer,
        uint256 price,
        address currency,
        uint256 platformFee,
        uint256 royaltyFee,
        uint256 timestamp,
        string eventId
    );

    // Bundle Events
    event BundleCreated(
        bytes32 indexed bundleId,
        address indexed creator,
        address[] collections,
        uint256[] tokenIds,
        uint256 totalPrice,
        address currency,
        uint256 itemCount,
        uint256 timestamp,
        string bundleName,
        string eventId
    );

    event BundleSold(
        bytes32 indexed bundleId,
        address indexed seller,
        address indexed buyer,
        uint256 totalPrice,
        address currency,
        uint256 itemCount,
        uint256 timestamp,
        string eventId
    );

    // Batch Operation Events
    event BatchListingCreated(
        address indexed collection,
        address indexed seller,
        uint256[] tokenIds,
        uint256[] prices,
        address currency,
        uint256 successCount,
        uint256 totalValue,
        uint256 timestamp,
        string eventId
    );

    event BatchListingCanceled(
        address indexed collection,
        address indexed seller,
        uint256[] tokenIds,
        uint256 successCount,
        uint256 timestamp,
        string eventId
    );

    // Collection Events
    event CollectionAdded(
        address indexed collection,
        string name,
        string symbol,
        uint256 platformFee,
        uint256 royaltyFee,
        address royaltyRecipient,
        uint256 timestamp,
        string eventId
    );

    event CollectionStatsUpdated(
        address indexed collection,
        uint256 totalListings,
        uint256 totalSales,
        uint256 totalVolume,
        uint256 floorPrice,
        uint256 timestamp,
        string eventId
    );

    // User Activity Events
    event UserRegistered(
        address indexed user,
        uint256 timestamp,
        string referralCode,
        string eventId
    );

    event UserActivityUpdate(
        address indexed user,
        uint256 totalListings,
        uint256 totalPurchases,
        uint256 totalVolume,
        uint256 timestamp,
        string eventId
    );

    // Payment Events
    event PaymentProcessed(
        address indexed payer,
        address indexed recipient,
        uint256 amount,
        address currency,
        uint256 platformFee,
        uint256 royaltyFee,
        uint256 timestamp,
        string paymentType,
        string eventId
    );

    // Fee Events
    event FeesDistributed(
        address indexed recipient,
        uint256 amount,
        address currency,
        string feeType,
        uint256 timestamp,
        string eventId
    );

    // Analytics Events
    event PriceUpdate(
        address indexed collection,
        uint256 indexed tokenId,
        uint256 oldPrice,
        uint256 newPrice,
        address currency,
        int256 percentChange,
        uint256 timestamp,
        string eventId
    );

    event FloorPriceUpdate(
        address indexed collection,
        uint256 oldFloorPrice,
        uint256 newFloorPrice,
        address currency,
        int256 percentChange,
        uint256 timestamp,
        string eventId
    );

    event VolumeUpdate(
        address indexed collection,
        uint256 dailyVolume,
        uint256 weeklyVolume,
        uint256 monthlyVolume,
        uint256 totalVolume,
        address currency,
        uint256 timestamp,
        string eventId
    );

    // System Events
    event SystemAlert(
        string alertType,
        string message,
        address triggeredBy,
        uint256 severity, // 1=info, 2=warning, 3=error, 4=critical
        uint256 timestamp,
        string eventId
    );

    event ContractUpgrade(
        address indexed oldContract,
        address indexed newContract,
        string contractName,
        string version,
        uint256 timestamp,
        string eventId
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @param _registry MarketplaceRegistry contract address
     * @param _admin Admin address
     */
    function initialize(address _registry, address _admin) external initializer {
        require(_registry != address(0), "Invalid registry");
        require(_admin != address(0), "Invalid admin");

        __AccessControl_init();
        __UUPSUpgradeable_init();

        registry = MarketplaceRegistry(_registry);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(EMITTER_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
    }

    /**
     * @notice Emit a listing created event
     */
    function emitListingCreated(
        address _collection,
        uint256 _tokenId,
        address _seller,
        uint256 _price,
        address _currency,
        uint256 _expiresAt
    ) external onlyRole(EMITTER_ROLE) {
        string memory eventId = _generateEventId("listing_created");
        
        emit ListingCreated(
            _collection,
            _tokenId,
            _seller,
            _price,
            _currency,
            block.timestamp,
            _expiresAt,
            eventId
        );

        _incrementEventCounter("listing_created");
    }

    /**
     * @notice Emit a listing updated event
     */
    function emitListingUpdated(
        address _collection,
        uint256 _tokenId,
        address _seller,
        uint256 _oldPrice,
        uint256 _newPrice,
        address _currency
    ) external onlyRole(EMITTER_ROLE) {
        string memory eventId = _generateEventId("listing_updated");
        
        emit ListingUpdated(
            _collection,
            _tokenId,
            _seller,
            _oldPrice,
            _newPrice,
            _currency,
            block.timestamp,
            eventId
        );

        _incrementEventCounter("listing_updated");
    }

    /**
     * @notice Emit a listing canceled event
     */
    function emitListingCanceled(
        address _collection,
        uint256 _tokenId,
        address _seller,
        string calldata _reason
    ) external onlyRole(EMITTER_ROLE) {
        string memory eventId = _generateEventId("listing_canceled");
        
        emit ListingCanceled(
            _collection,
            _tokenId,
            _seller,
            block.timestamp,
            _reason,
            eventId
        );

        _incrementEventCounter("listing_canceled");
    }

    /**
     * @notice Emit an NFT sold event
     */
    function emitNFTSold(
        address _collection,
        uint256 _tokenId,
        address _seller,
        address _buyer,
        uint256 _price,
        address _currency,
        uint256 _platformFee,
        uint256 _royaltyFee
    ) external onlyRole(EMITTER_ROLE) {
        string memory eventId = _generateEventId("nft_sold");
        
        emit NFTSold(
            _collection,
            _tokenId,
            _seller,
            _buyer,
            _price,
            _currency,
            _platformFee,
            _royaltyFee,
            block.timestamp,
            eventId
        );

        _incrementEventCounter("nft_sold");
    }

    /**
     * @notice Emit a bundle created event
     */
    function emitBundleCreated(
        bytes32 _bundleId,
        address _creator,
        address[] calldata _collections,
        uint256[] calldata _tokenIds,
        uint256 _totalPrice,
        address _currency,
        string calldata _bundleName
    ) external onlyRole(EMITTER_ROLE) {
        string memory eventId = _generateEventId("bundle_created");
        
        // emit BundleCreated(
        //     _bundleId,
        //     _creator,
        //     _collections,
        //     _tokenIds,
        //     _totalPrice,
        //     _currency,
        //     _tokenIds.length,
        //     block.timestamp,
        //     _bundleName,
        //     eventId
        // ); //TODO FIX: Stack too deep

        _incrementEventCounter("bundle_created");
    }

    /**
     * @notice Emit a bundle sold event
     */
    function emitBundleSold(
        bytes32 _bundleId,
        address _seller,
        address _buyer,
        uint256 _totalPrice,
        address _currency,
        uint256 _itemCount
    ) external onlyRole(EMITTER_ROLE) {
        string memory eventId = _generateEventId("bundle_sold");
        
        emit BundleSold(
            _bundleId,
            _seller,
            _buyer,
            _totalPrice,
            _currency,
            _itemCount,
            block.timestamp,
            eventId
        );

        _incrementEventCounter("bundle_sold");
    }

    /**
     * @notice Emit a batch listing created event
     */
    function emitBatchListingCreated(
        address _collection,
        address _seller,
        uint256[] calldata _tokenIds,
        uint256[] calldata _prices,
        address _currency,
        uint256 _successCount,
        uint256 _totalValue
    ) external onlyRole(EMITTER_ROLE) {
        string memory eventId = _generateEventId("batch_listing_created");
        
        emit BatchListingCreated(
            _collection,
            _seller,
            _tokenIds,
            _prices,
            _currency,
            _successCount,
            _totalValue,
            block.timestamp,
            eventId
        );

        _incrementEventCounter("batch_listing_created");
    }

    /**
     * @notice Emit a collection added event
     */
    function emitCollectionAdded(
        address _collection,
        string calldata _name,
        string calldata _symbol,
        uint256 _platformFee,
        uint256 _royaltyFee,
        address _royaltyRecipient
    ) external onlyRole(EMITTER_ROLE) {
        string memory eventId = _generateEventId("collection_added");
        
        emit CollectionAdded(
            _collection,
            _name,
            _symbol,
            _platformFee,
            _royaltyFee,
            _royaltyRecipient,
            block.timestamp,
            eventId
        );

        _incrementEventCounter("collection_added");
    }

    /**
     * @notice Emit collection stats updated event
     */
    function emitCollectionStatsUpdated(
        address _collection,
        uint256 _totalListings,
        uint256 _totalSales,
        uint256 _totalVolume,
        uint256 _floorPrice
    ) external onlyRole(EMITTER_ROLE) {
        string memory eventId = _generateEventId("collection_stats_updated");
        
        emit CollectionStatsUpdated(
            _collection,
            _totalListings,
            _totalSales,
            _totalVolume,
            _floorPrice,
            block.timestamp,
            eventId
        );

        _incrementEventCounter("collection_stats_updated");
    }

    /**
     * @notice Emit user activity update event
     */
    function emitUserActivityUpdate(
        address _user,
        uint256 _totalListings,
        uint256 _totalPurchases,
        uint256 _totalVolume
    ) external onlyRole(EMITTER_ROLE) {
        string memory eventId = _generateEventId("user_activity_update");
        
        emit UserActivityUpdate(
            _user,
            _totalListings,
            _totalPurchases,
            _totalVolume,
            block.timestamp,
            eventId
        );

        _incrementEventCounter("user_activity_update");
    }

    /**
     * @notice Emit payment processed event
     */
    function emitPaymentProcessed(
        address _payer,
        address _recipient,
        uint256 _amount,
        address _currency,
        uint256 _platformFee,
        uint256 _royaltyFee,
        string calldata _paymentType
    ) external onlyRole(EMITTER_ROLE) {
        string memory eventId = _generateEventId("payment_processed");
        
        emit PaymentProcessed(
            _payer,
            _recipient,
            _amount,
            _currency,
            _platformFee,
            _royaltyFee,
            block.timestamp,
            _paymentType,
            eventId
        );

        _incrementEventCounter("payment_processed");
    }

    /**
     * @notice Emit price update event
     */
    function emitPriceUpdate(
        address _collection,
        uint256 _tokenId,
        uint256 _oldPrice,
        uint256 _newPrice,
        address _currency
    ) external onlyRole(EMITTER_ROLE) {
        string memory eventId = _generateEventId("price_update");
        
        int256 percentChange = 0;
        if (_oldPrice > 0) {
            percentChange = (int256(_newPrice) - int256(_oldPrice)) * 10000 / int256(_oldPrice);
        }
        
        emit PriceUpdate(
            _collection,
            _tokenId,
            _oldPrice,
            _newPrice,
            _currency,
            percentChange,
            block.timestamp,
            eventId
        );

        _incrementEventCounter("price_update");
    }

    /**
     * @notice Emit floor price update event
     */
    function emitFloorPriceUpdate(
        address _collection,
        uint256 _oldFloorPrice,
        uint256 _newFloorPrice,
        address _currency
    ) external onlyRole(EMITTER_ROLE) {
        string memory eventId = _generateEventId("floor_price_update");
        
        int256 percentChange = 0;
        if (_oldFloorPrice > 0) {
            percentChange = (int256(_newFloorPrice) - int256(_oldFloorPrice)) * 10000 / int256(_oldFloorPrice);
        }
        
        emit FloorPriceUpdate(
            _collection,
            _oldFloorPrice,
            _newFloorPrice,
            _currency,
            percentChange,
            block.timestamp,
            eventId
        );

        _incrementEventCounter("floor_price_update");
    }

    /**
     * @notice Emit volume update event
     */
    function emitVolumeUpdate(
        address _collection,
        uint256 _dailyVolume,
        uint256 _weeklyVolume,
        uint256 _monthlyVolume,
        uint256 _totalVolume,
        address _currency
    ) external onlyRole(EMITTER_ROLE) {
        string memory eventId = _generateEventId("volume_update");
        
        emit VolumeUpdate(
            _collection,
            _dailyVolume,
            _weeklyVolume,
            _monthlyVolume,
            _totalVolume,
            _currency,
            block.timestamp,
            eventId
        );

        _incrementEventCounter("volume_update");
    }

    /**
     * @notice Emit system alert event
     */
    function emitSystemAlert(
        string calldata _alertType,
        string calldata _message,
        address _triggeredBy,
        uint256 _severity
    ) external onlyRole(EMITTER_ROLE) {
        string memory eventId = _generateEventId("system_alert");
        
        emit SystemAlert(
            _alertType,
            _message,
            _triggeredBy,
            _severity,
            block.timestamp,
            eventId
        );

        _incrementEventCounter("system_alert");
    }

    /**
     * @notice Emit contract upgrade event
     */
    function emitContractUpgrade(
        address _oldContract,
        address _newContract,
        string calldata _contractName,
        string calldata _version
    ) external onlyRole(EMITTER_ROLE) {
        string memory eventId = _generateEventId("contract_upgrade");
        
        emit ContractUpgrade(
            _oldContract,
            _newContract,
            _contractName,
            _version,
            block.timestamp,
            eventId
        );

        _incrementEventCounter("contract_upgrade");
    }

    /**
     * @notice Generate unique event ID
     */
    function _generateEventId(string memory _eventType) internal view returns (string memory) {
        return string(abi.encodePacked(
            _eventType,
            "_",
            _toString(block.timestamp),
            "_",
            _toString(totalEventsEmitted)
        ));
    }

    /**
     * @notice Increment event counter
     */
    function _incrementEventCounter(string memory _eventType) internal {
        eventTypeCounters[_eventType]++;
        totalEventsEmitted++;
    }

    /**
     * @notice Convert uint256 to string
     */
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    // View functions
    function getEventTypeCount(string calldata _eventType) external view returns (uint256) {
        return eventTypeCounters[_eventType];
    }

    function getTotalEventsEmitted() external view returns (uint256) {
        return totalEventsEmitted;
    }

    /**
     * @notice Get event statistics for analytics
     */
    function getEventStats() external view returns (
        uint256 totalEvents,
        uint256 listingEvents,
        uint256 saleEvents,
        uint256 bundleEvents,
        uint256 systemEvents
    ) {
        return (
            totalEventsEmitted,
            eventTypeCounters["listing_created"] + eventTypeCounters["listing_updated"] + eventTypeCounters["listing_canceled"],
            eventTypeCounters["nft_sold"] + eventTypeCounters["bundle_sold"],
            eventTypeCounters["bundle_created"] + eventTypeCounters["bundle_sold"],
            eventTypeCounters["system_alert"] + eventTypeCounters["contract_upgrade"]
        );
    }

    /**
     * @notice Batch emit multiple events (gas optimization)
     */
    function batchEmitEvents(
        string[] calldata _eventTypes,
        bytes[] calldata _eventData
    ) external onlyRole(EMITTER_ROLE) {
        require(_eventTypes.length == _eventData.length, "Array length mismatch");
        require(_eventTypes.length <= 50, "Too many events"); // Gas limit protection

        for (uint256 i = 0; i < _eventTypes.length; i++) {
            _incrementEventCounter(_eventTypes[i]);
            // Event data would be decoded and emitted based on type
            // Implementation would depend on specific event types
        }
    }

    /**
     * @notice Update registry address
     */
    function updateRegistry(address _newRegistry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_newRegistry != address(0), "Invalid registry");
        registry = MarketplaceRegistry(_newRegistry);
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
        view
        override 
        onlyRole(UPGRADER_ROLE) 
    {
        require(newImplementation != address(0), "Invalid implementation");
    }

    // Admin functions
    function resetEventCounters() external onlyRole(DEFAULT_ADMIN_ROLE) {
        totalEventsEmitted = 0;
        // Note: Individual event type counters would need to be reset manually
        // or we'd need to maintain an array of all event types
    }
}