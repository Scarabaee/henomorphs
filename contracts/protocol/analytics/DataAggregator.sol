// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../core/MarketplaceRegistry.sol";
import "../core/CollectionManager.sol";
import "../trading/AsksV1.sol";
import "./EventEmitter.sol";

/**
 * @title DataAggregator
 * @notice On-chain analytics and metrics aggregation system
 * @dev UUPS upgradeable - collects, processes and provides marketplace analytics data
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract DataAggregator is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    using Math for uint256;

    bytes32 public constant AGGREGATOR_ROLE = keccak256("AGGREGATOR_ROLE");
    bytes32 public constant UPDATER_ROLE = keccak256("UPDATER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    struct MarketplaceMetrics {
        uint256 totalListings;
        uint256 activeListings;
        uint256 totalSales;
        uint256 totalVolume;
        uint256 averagePrice;
        uint256 totalUsers;
        uint256 activeUsers; // users active in last 30 days
        uint256 lastUpdated;
    }

    struct CollectionMetrics {
        uint256 totalListings;
        uint256 activeListings;
        uint256 totalSales;
        uint256 totalVolume;
        uint256 floorPrice;
        uint256 averagePrice;
        uint256 highestSale;
        uint256 lastSalePrice;
        uint256 lastSaleTimestamp;
        uint256 uniqueOwners;
        uint256 listedPercent; // percentage of supply listed
        uint256 lastUpdated;
    }

    struct UserMetrics {
        uint256 totalListings;
        uint256 activeListings;
        uint256 totalSales;
        uint256 totalPurchases;
        uint256 totalVolumeAsSeller;
        uint256 totalVolumeAsBuyer;
        uint256 averageSalePrice;
        uint256 averagePurchasePrice;
        uint256 firstActivityTimestamp;
        uint256 lastActivityTimestamp;
        uint256 uniqueCollectionsListed;
        uint256 uniqueCollectionsPurchased;
    }

    struct TimeSeriesData {
        uint256 timestamp;
        uint256 value;
    }

    struct TrendingData {
        address collection;
        uint256 volume24h;
        uint256 volume7d;
        uint256 volumeChange;
        uint256 floorPrice;
        uint256 floorPriceChange;
        uint256 sales24h;
        uint256 salesChange;
        uint256 trendScore;
    }

    struct TopCollection {
        address collection;
        uint256 volume;
        uint256 sales;
        uint256 averagePrice;
        uint256 rank;
    }

    // Core dependencies - mutable for upgradeability
    MarketplaceRegistry public registry;
    CollectionManager public collectionManager;
    AsksV1 public asksV1;
    EventEmitter public eventEmitter;

    // Main metrics storage
    MarketplaceMetrics public globalMetrics;
    mapping(address => CollectionMetrics) public collectionMetrics;
    mapping(address => UserMetrics) public userMetrics;

    // Time series data (limited storage for gas efficiency)
    mapping(address => mapping(uint256 => uint256)) public dailyVolume; // collection -> day -> volume
    mapping(address => mapping(uint256 => uint256)) public dailySales; // collection -> day -> sales
    mapping(address => mapping(uint256 => uint256)) public dailyFloorPrice; // collection -> day -> floor price
    
    // Global time series
    mapping(uint256 => uint256) public globalDailyVolume; // day -> volume
    mapping(uint256 => uint256) public globalDailySales; // day -> sales
    mapping(uint256 => uint256) public globalDailyActiveUsers; // day -> active users

    // Trending and rankings
    mapping(uint256 => TrendingData[]) public dailyTrending; // day -> trending collections
    mapping(uint256 => TopCollection[]) public dailyTopCollections; // day -> top collections

    // User activity tracking
    mapping(address => mapping(uint256 => bool)) public userActiveOnDay; // user -> day -> active
    mapping(uint256 => address[]) public newUsersPerDay; // day -> new users

    // Price tracking
    mapping(address => uint256[]) public priceHistory; // collection -> price points
    mapping(address => uint256[]) public volumeHistory; // collection -> volume points

    // Settings
    uint256 public maxHistoryPoints;
    uint256 public maxTrendingItems;
    uint256 public maxTopCollections;
    uint256 public minVolumeForTrending;

    // Events
    event MetricsUpdated(
        string metricsType,
        address indexed subject,
        uint256 timestamp
    );

    event TrendingUpdated(
        uint256 indexed day,
        uint256 itemCount,
        uint256 timestamp
    );

    event RankingsUpdated(
        uint256 indexed day,
        uint256 itemCount,
        uint256 timestamp
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @param _registry MarketplaceRegistry contract address
     * @param _collectionManager CollectionManager contract address
     * @param _asksV1 AsksV1 contract address
     * @param _eventEmitter EventEmitter contract address
     * @param _admin Admin address
     */
    function initialize(
        address _registry,
        address _collectionManager,
        address _asksV1,
        address _eventEmitter,
        address _admin
    ) external initializer {
        require(_registry != address(0), "Invalid registry");
        require(_collectionManager != address(0), "Invalid collection manager");
        require(_asksV1 != address(0), "Invalid asks contract");
        require(_eventEmitter != address(0), "Invalid event emitter");
        require(_admin != address(0), "Invalid admin");

        __AccessControl_init();
        __UUPSUpgradeable_init();

        registry = MarketplaceRegistry(_registry);
        collectionManager = CollectionManager(_collectionManager);
        asksV1 = AsksV1(_asksV1);
        eventEmitter = EventEmitter(_eventEmitter);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(AGGREGATOR_ROLE, _admin);
        _grantRole(UPDATER_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);

        // Initialize global metrics
        globalMetrics.lastUpdated = block.timestamp;

        // Initialize settings
        maxHistoryPoints = 365; // 1 year of daily data
        maxTrendingItems = 50;
        maxTopCollections = 100;
        minVolumeForTrending = 1 ether;
    }

    /**
     * @notice Update global marketplace metrics
     */
    function updateGlobalMetrics() external onlyRole(UPDATER_ROLE) {
        // This would typically be called periodically (daily) to update global stats
        uint256 currentDay = block.timestamp / 1 days;
        
        // Calculate total active listings across all collections
        address[] memory collections = collectionManager.getAllWhitelistedCollections();
        uint256 totalActive = 0;
        uint256 totalVolume = 0;
        uint256 totalSales = 0;
        
        for (uint256 i = 0; i < collections.length; i++) {
            CollectionManager.CollectionStats memory stats = collectionManager.getCollectionStats(collections[i]);
            totalActive += stats.totalListings; // Simplified - would need actual active count
            totalVolume += stats.totalVolume;
            totalSales += stats.totalSales;
        }

        globalMetrics.activeListings = totalActive;
        globalMetrics.totalVolume = totalVolume;
        globalMetrics.totalSales = totalSales;
        globalMetrics.lastUpdated = block.timestamp;

        // Update daily global metrics
        globalDailyVolume[currentDay] = totalVolume;
        globalDailySales[currentDay] = totalSales;

        emit MetricsUpdated("global", address(0), block.timestamp);
    }

    /**
     * @notice Update metrics for a specific collection
     */
    function updateCollectionMetrics(address _collection) external onlyRole(UPDATER_ROLE) {
        require(collectionManager.isCollectionSupported(_collection), "Collection not supported");
        
        CollectionManager.CollectionStats memory stats = collectionManager.getCollectionStats(_collection);
        CollectionMetrics storage metrics = collectionMetrics[_collection];
        
        // Update basic metrics
        metrics.totalSales = stats.totalSales;
        metrics.totalVolume = stats.totalVolume;
        metrics.floorPrice = stats.floorPrice;
        metrics.lastSalePrice = stats.lastSalePrice;
        metrics.lastSaleTimestamp = stats.lastSaleTimestamp;
        
        // Calculate average price
        if (stats.totalSales > 0) {
            metrics.averagePrice = stats.totalVolume / stats.totalSales;
        }
        
        metrics.lastUpdated = block.timestamp;

        // Update daily metrics
        uint256 currentDay = block.timestamp / 1 days;
        dailyVolume[_collection][currentDay] = stats.totalVolume;
        dailySales[_collection][currentDay] = stats.totalSales;
        dailyFloorPrice[_collection][currentDay] = stats.floorPrice;

        emit MetricsUpdated("collection", _collection, block.timestamp);
    }

    /**
     * @notice Update metrics for a specific user
     */
    function updateUserMetrics(address _user) public onlyRole(UPDATER_ROLE) {
        UserMetrics storage metrics = userMetrics[_user];
        
        // Mark user as active today
        uint256 currentDay = block.timestamp / 1 days;
        if (!userActiveOnDay[_user][currentDay]) {
            userActiveOnDay[_user][currentDay] = true;
            
            // If first time active, add to new users
            if (metrics.firstActivityTimestamp == 0) {
                metrics.firstActivityTimestamp = block.timestamp;
                newUsersPerDay[currentDay].push(_user);
                globalMetrics.totalUsers++;
            }
        }
        
        metrics.lastActivityTimestamp = block.timestamp;

        emit MetricsUpdated("user", _user, block.timestamp);
    }

    /**
     * @notice Record a sale and update relevant metrics
     */
    function recordSale(
        address _collection,
        uint256 _tokenId,
        address _seller,
        address _buyer,
        uint256 _price,
        address _currency
    ) external onlyRole(UPDATER_ROLE) {
        // Update collection metrics
        CollectionMetrics storage collectionMetric = collectionMetrics[_collection];
        collectionMetric.totalSales++;
        collectionMetric.totalVolume += _price;
        collectionMetric.lastSalePrice = _price;
        collectionMetric.lastSaleTimestamp = block.timestamp;
        
        // Update highest sale if applicable
        if (_price > collectionMetric.highestSale) {
            collectionMetric.highestSale = _price;
        }
        
        // Update floor price if this sale is lower
        if (collectionMetric.floorPrice == 0 || _price < collectionMetric.floorPrice) {
            collectionMetric.floorPrice = _price;
        }
        
        // Recalculate average price
        if (collectionMetric.totalSales > 0) {
            collectionMetric.averagePrice = collectionMetric.totalVolume / collectionMetric.totalSales;
        }

        // Update seller metrics
        UserMetrics storage sellerMetrics = userMetrics[_seller];
        sellerMetrics.totalSales++;
        sellerMetrics.totalVolumeAsSeller += _price;
        if (sellerMetrics.totalSales > 0) {
            sellerMetrics.averageSalePrice = sellerMetrics.totalVolumeAsSeller / sellerMetrics.totalSales;
        }

        // Update buyer metrics
        UserMetrics storage buyerMetrics = userMetrics[_buyer];
        buyerMetrics.totalPurchases++;
        buyerMetrics.totalVolumeAsBuyer += _price;
        if (buyerMetrics.totalPurchases > 0) {
            buyerMetrics.averagePurchasePrice = buyerMetrics.totalVolumeAsBuyer / buyerMetrics.totalPurchases;
        }

        // Update global metrics
        globalMetrics.totalSales++;
        globalMetrics.totalVolume += _price;
        if (globalMetrics.totalSales > 0) {
            globalMetrics.averagePrice = globalMetrics.totalVolume / globalMetrics.totalSales;
        }

        // Update user activity
        updateUserMetrics(_seller);
        updateUserMetrics(_buyer);
    }

    /**
     * @notice Record a new listing
     */
    function recordListing(
        address _collection,
        uint256 _tokenId,
        address _seller,
        uint256 _price
    ) external onlyRole(UPDATER_ROLE) {
        // Update collection metrics
        CollectionMetrics storage metrics = collectionMetrics[_collection];
        metrics.totalListings++;
        metrics.activeListings++;

        // Update user metrics
        UserMetrics storage userMetric = userMetrics[_seller];
        userMetric.totalListings++;
        userMetric.activeListings++;

        // Update global metrics
        globalMetrics.totalListings++;
        globalMetrics.activeListings++;

        // Update user activity
        updateUserMetrics(_seller);
    }

    /**
     * @notice Record a listing cancellation
     */
    function recordListingCancellation(
        address _collection,
        uint256 _tokenId,
        address _seller
    ) external onlyRole(UPDATER_ROLE) {
        // Update collection metrics
        CollectionMetrics storage metrics = collectionMetrics[_collection];
        if (metrics.activeListings > 0) {
            metrics.activeListings--;
        }

        // Update user metrics
        UserMetrics storage userMetric = userMetrics[_seller];
        if (userMetric.activeListings > 0) {
            userMetric.activeListings--;
        }

        // Update global metrics
        if (globalMetrics.activeListings > 0) {
            globalMetrics.activeListings--;
        }
    }

    /**
     * @notice Calculate and update trending collections
     */
    function updateTrendingCollections() external onlyRole(AGGREGATOR_ROLE) {
        uint256 currentDay = block.timestamp / 1 days;
        uint256 yesterdayDay = currentDay - 1;
        
        address[] memory collections = collectionManager.getActiveCollections();
        TrendingData[] memory trending = new TrendingData[](collections.length);
        uint256 trendingCount = 0;

        for (uint256 i = 0; i < collections.length; i++) {
            address collection = collections[i];
            uint256 volume24h = dailyVolume[collection][currentDay];
            uint256 volumePrev = dailyVolume[collection][yesterdayDay];
            
            // Only include collections with minimum volume
            if (volume24h >= minVolumeForTrending) {
                uint256 volumeChange = 0;
                if (volumePrev > 0) {
                    volumeChange = ((volume24h * 10000) / volumePrev) - 10000; // Basis points change
                }

                uint256 sales24h = dailySales[collection][currentDay];
                uint256 salesPrev = dailySales[collection][yesterdayDay];
                uint256 salesChange = 0;
                if (salesPrev > 0) {
                    salesChange = ((sales24h * 10000) / salesPrev) - 10000;
                }

                // Calculate trend score (simplified algorithm)
                uint256 trendScore = (volumeChange + salesChange) / 2;

                trending[trendingCount] = TrendingData({
                    collection: collection,
                    volume24h: volume24h,
                    volume7d: _getWeeklyVolume(collection, currentDay),
                    volumeChange: volumeChange,
                    floorPrice: collectionMetrics[collection].floorPrice,
                    floorPriceChange: _getFloorPriceChange(collection, currentDay),
                    sales24h: sales24h,
                    salesChange: salesChange,
                    trendScore: trendScore
                });
                trendingCount++;
            }
        }

        // Sort by trend score (simplified - would use more sophisticated sorting)
        // For gas efficiency, we'll just store the first maxTrendingItems
        uint256 itemsToStore = trendingCount > maxTrendingItems ? maxTrendingItems : trendingCount;
        
        delete dailyTrending[currentDay];
        for (uint256 i = 0; i < itemsToStore; i++) {
            dailyTrending[currentDay].push(trending[i]);
        }

        emit TrendingUpdated(currentDay, itemsToStore, block.timestamp);
    }

    /**
     * @notice Calculate weekly volume for a collection
     */
    function _getWeeklyVolume(address _collection, uint256 _currentDay) internal view returns (uint256) {
        uint256 weeklyVolume = 0;
        for (uint256 i = 0; i < 7; i++) {
            if (_currentDay >= i) {
                weeklyVolume += dailyVolume[_collection][_currentDay - i];
            }
        }
        return weeklyVolume;
    }

    /**
     * @notice Calculate floor price change for a collection
     */
    function _getFloorPriceChange(address _collection, uint256 _currentDay) internal view returns (uint256) {
        if (_currentDay == 0) return 0;
        
        uint256 currentFloor = dailyFloorPrice[_collection][_currentDay];
        uint256 previousFloor = dailyFloorPrice[_collection][_currentDay - 1];
        
        if (previousFloor == 0) return 0;
        
        return ((currentFloor * 10000) / previousFloor) - 10000; // Basis points change
    }

    // View functions for analytics

    /**
     * @notice Get collection metrics
     */
    function getCollectionMetrics(address _collection) external view returns (CollectionMetrics memory) {
        return collectionMetrics[_collection];
    }

    /**
     * @notice Get user metrics
     */
    function getUserMetrics(address _user) external view returns (UserMetrics memory) {
        return userMetrics[_user];
    }

    /**
     * @notice Get trending collections for a specific day
     */
    function getTrendingCollections(uint256 _day) external view returns (TrendingData[] memory) {
        return dailyTrending[_day];
    }

    /**
     * @notice Get today's trending collections
     */
    function getTodaysTrending() external view returns (TrendingData[] memory) {
        uint256 today = block.timestamp / 1 days;
        return dailyTrending[today];
    }

    /**
     * @notice Get collection volume history
     */
    function getCollectionVolumeHistory(address _collection, uint256 _days) external view returns (uint256[] memory) {
        require(_days <= maxHistoryPoints, "Too many days requested");
        
        uint256[] memory history = new uint256[](_days);
        uint256 currentDay = block.timestamp / 1 days;
        
        for (uint256 i = 0; i < _days; i++) {
            if (currentDay >= i) {
                history[i] = dailyVolume[_collection][currentDay - i];
            }
        }
        
        return history;
    }

    /**
     * @notice Get global daily volume history
     */
    function getGlobalVolumeHistory(uint256 _days) external view returns (uint256[] memory) {
        require(_days <= maxHistoryPoints, "Too many days requested");
        
        uint256[] memory history = new uint256[](_days);
        uint256 currentDay = block.timestamp / 1 days;
        
        for (uint256 i = 0; i < _days; i++) {
            if (currentDay >= i) {
                history[i] = globalDailyVolume[currentDay - i];
            }
        }
        
        return history;
    }

    /**
     * @notice Get active users count for the last N days
     */
    function getActiveUsersHistory(uint256 _days) external view returns (uint256[] memory) {
        require(_days <= maxHistoryPoints, "Too many days requested");
        
        uint256[] memory history = new uint256[](_days);
        uint256 currentDay = block.timestamp / 1 days;
        
        for (uint256 i = 0; i < _days; i++) {
            if (currentDay >= i) {
                history[i] = globalDailyActiveUsers[currentDay - i];
            }
        }
        
        return history;
    }

    /**
     * @notice Get comprehensive marketplace overview
     */
    function getMarketplaceOverview() external view returns (
        MarketplaceMetrics memory global,
        uint256 todayVolume,
        uint256 todaySales,
        uint256 activeUsers24h,
        uint256 newUsers24h
    ) {
        uint256 today = block.timestamp / 1 days;
        
        return (
            globalMetrics,
            globalDailyVolume[today],
            globalDailySales[today],
            globalDailyActiveUsers[today],
            newUsersPerDay[today].length
        );
    }

    // Admin functions
    function setMaxHistoryPoints(uint256 _maxPoints) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_maxPoints >= 30, "Minimum 30 days");
        require(_maxPoints <= 1095, "Maximum 3 years"); // 3 years
        maxHistoryPoints = _maxPoints;
    }

    function setMaxTrendingItems(uint256 _maxItems) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_maxItems >= 10, "Minimum 10 items");
        require(_maxItems <= 200, "Maximum 200 items");
        maxTrendingItems = _maxItems;
    }

    function setMinVolumeForTrending(uint256 _minVolume) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minVolumeForTrending = _minVolume;
    }

    /**
     * @notice Update contract dependencies
     */
    function updateDependencies(
        address _registry,
        address _collectionManager,
        address _asksV1,
        address _eventEmitter
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_registry != address(0)) registry = MarketplaceRegistry(_registry);
        if (_collectionManager != address(0)) collectionManager = CollectionManager(_collectionManager);
        if (_asksV1 != address(0)) asksV1 = AsksV1(_asksV1);
        if (_eventEmitter != address(0)) eventEmitter = EventEmitter(_eventEmitter);
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
}