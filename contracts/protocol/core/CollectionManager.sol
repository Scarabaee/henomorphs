// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {MarketplaceRegistry} from "./MarketplaceRegistry.sol";

/**
 * @title CollectionManager
 * @notice Manages whitelisted NFT collections and their specific configurations
 * @dev UUPS upgradeable contract - handles collection registration, validation, and per-collection settings
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract CollectionManager is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    using ERC165Checker for address;

    bytes32 public constant COLLECTION_ADMIN_ROLE = keccak256("COLLECTION_ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    struct CollectionConfig {
        bool isActive;
        uint256 platformFeePercent; // in basis points
        uint256 creatorRoyaltyPercent; // in basis points
        address royaltyRecipient;
        uint256 minimumPrice; // in wei
        uint256 maximumPrice; // in wei (0 = no limit)
        bool requiresNativeToken;
        bool allowBundles;
        uint256 maxBundleSize;
        string metadataURI; // optional additional metadata
    }

    struct CollectionStats {
        uint256 totalListings;
        uint256 totalSales;
        uint256 totalVolume;
        uint256 floorPrice;
        uint256 lastSalePrice;
        uint256 lastSaleTimestamp;
    }

    // State variables - mutable for upgradeability
    MarketplaceRegistry public registry;
    
    mapping(address => CollectionConfig) public collections;
    mapping(address => CollectionStats) public collectionStats;
    mapping(address => mapping(uint256 => bool)) public tokenBanned; // collection -> tokenId -> banned
    
    address[] public whitelistedCollections;
    
    // Events
    event CollectionAdded(address indexed collection, CollectionConfig config);
    event CollectionUpdated(address indexed collection, CollectionConfig config);
    event CollectionStatusChanged(address indexed collection, bool isActive);
    event TokenBanned(address indexed collection, uint256 indexed tokenId);
    event TokenUnbanned(address indexed collection, uint256 indexed tokenId);
    event CollectionStatsUpdated(address indexed collection, CollectionStats stats);

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
        _grantRole(COLLECTION_ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
    }

    /**
     * @notice Add a new collection to the whitelist
     */
    function addCollection(
        address _collection,
        CollectionConfig calldata _config
    ) external onlyRole(COLLECTION_ADMIN_ROLE) {
        require(_collection != address(0), "Invalid collection address");
        require(_collection.supportsInterface(type(IERC721).interfaceId), "Not an ERC721 contract");
        (uint256 maxPlatformFee,,,,,) = registry.globalConfig();
        require(_config.platformFeePercent <= maxPlatformFee, "Platform fee too high");
        require(_config.creatorRoyaltyPercent <= 2000, "Royalty too high"); // Max 20%
        require(_config.minimumPrice <= _config.maximumPrice || _config.maximumPrice == 0, "Invalid price range");

        // If collection doesn't exist yet, add to array
        if (!collections[_collection].isActive && collections[_collection].royaltyRecipient == address(0)) {
            whitelistedCollections.push(_collection);
        }

        collections[_collection] = _config;
        collections[_collection].isActive = true;

        emit CollectionAdded(_collection, _config);
    }

    /**
     * @notice Update an existing collection's configuration
     */
    function updateCollection(
        address _collection,
        CollectionConfig calldata _config
    ) external onlyRole(COLLECTION_ADMIN_ROLE) {
        require(collections[_collection].royaltyRecipient != address(0), "Collection not found");
        (uint256 maxPlatformFee,,,,,) = registry.globalConfig();
        require(_config.platformFeePercent <= maxPlatformFee, "Platform fee too high");
        require(_config.creatorRoyaltyPercent <= 2000, "Royalty too high");

        collections[_collection] = _config;
        emit CollectionUpdated(_collection, _config);
    }

    /**
     * @notice Activate or deactivate a collection
     */
    function setCollectionStatus(address _collection, bool _isActive) external onlyRole(COLLECTION_ADMIN_ROLE) {
        require(collections[_collection].royaltyRecipient != address(0), "Collection not found");
        collections[_collection].isActive = _isActive;
        emit CollectionStatusChanged(_collection, _isActive);
    }

    /**
     * @notice Ban a specific token from trading
     */
    function banToken(address _collection, uint256 _tokenId) external onlyRole(COLLECTION_ADMIN_ROLE) {
        require(isCollectionSupported(_collection), "Collection not supported");
        tokenBanned[_collection][_tokenId] = true;
        emit TokenBanned(_collection, _tokenId);
    }

    /**
     * @notice Unban a specific token
     */
    function unbanToken(address _collection, uint256 _tokenId) external onlyRole(COLLECTION_ADMIN_ROLE) {
        tokenBanned[_collection][_tokenId] = false;
        emit TokenUnbanned(_collection, _tokenId);
    }

    /**
     * @notice Update collection statistics (called by trading modules)
     */
    function updateCollectionStats(
        address _collection,
        uint256 _salePrice,
        bool _isNewListing
    ) external {
        require(registry.isAuthorizedCaller(msg.sender), "Unauthorized caller");
        
        CollectionStats storage stats = collectionStats[_collection];
        
        if (_isNewListing) {
            stats.totalListings++;
        } else {
            // This is a sale
            stats.totalSales++;
            stats.totalVolume += _salePrice;
            stats.lastSalePrice = _salePrice;
            stats.lastSaleTimestamp = block.timestamp;
            
            // Update floor price logic (simplified - in production you'd want more sophisticated floor tracking)
            if (stats.floorPrice == 0 || _salePrice < stats.floorPrice) {
                stats.floorPrice = _salePrice;
            }
        }
        
        emit CollectionStatsUpdated(_collection, stats);
    }

    // View functions
    function isCollectionSupported(address _collection) public view returns (bool) {
        return collections[_collection].isActive && collections[_collection].royaltyRecipient != address(0);
    }

    function isTokenTradeable(address _collection, uint256 _tokenId) external view returns (bool) {
        return isCollectionSupported(_collection) && !tokenBanned[_collection][_tokenId];
    }

    function validatePrice(address _collection, uint256 _price) external view returns (bool) {
        CollectionConfig memory config = collections[_collection];
        if (!config.isActive) return false;
        if (_price < config.minimumPrice) return false;
        if (config.maximumPrice > 0 && _price > config.maximumPrice) return false;
        return true;
    }

    function getCollectionConfig(address _collection) external view returns (CollectionConfig memory) {
        return collections[_collection];
    }

    function getCollectionStats(address _collection) external view returns (CollectionStats memory) {
        return collectionStats[_collection];
    }

    function getAllWhitelistedCollections() external view returns (address[] memory) {
        return whitelistedCollections;
    }

    function getActiveCollections() external view returns (address[] memory) {
        uint256 activeCount = 0;
        
        // Count active collections
        for (uint256 i = 0; i < whitelistedCollections.length; i++) {
            if (collections[whitelistedCollections[i]].isActive) {
                activeCount++;
            }
        }
        
        // Build active collections array
        address[] memory activeCollections = new address[](activeCount);
        uint256 currentIndex = 0;
        
        for (uint256 i = 0; i < whitelistedCollections.length; i++) {
            if (collections[whitelistedCollections[i]].isActive) {
                activeCollections[currentIndex] = whitelistedCollections[i];
                currentIndex++;
            }
        }
        
        return activeCollections;
    }

    /**
     * @notice Calculate total fees for a collection (platform + royalty)
     */
    function calculateTotalFees(address _collection, uint256 _salePrice, bool _usingNativeToken) 
        external 
        view 
        returns (uint256 platformFee, uint256 royaltyFee, uint256 totalFee) 
    {
        require(isCollectionSupported(_collection), "Collection not supported");
        
        CollectionConfig memory config = collections[_collection];
        
        // Get platform fee (with potential native token discount)
        uint256 platformFeePercent = config.platformFeePercent;
        if (_usingNativeToken) {
            platformFeePercent = registry.getEffectivePlatformFee(true);
        }
        
        platformFee = (_salePrice * platformFeePercent) / 10000;
        royaltyFee = (_salePrice * config.creatorRoyaltyPercent) / 10000;
        totalFee = platformFee + royaltyFee;
    }

    /**
     * @notice Update registry address (for upgrades)
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
}