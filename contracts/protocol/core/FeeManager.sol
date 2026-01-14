// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./MarketplaceRegistry.sol";
import "./CollectionManager.sol";

/**
 * @title FeeManager
 * @notice Handles all fee calculations, collections, and distributions
 * @dev UUPS upgradeable - manages platform fees, royalties, native token discounts, and fee distribution
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract FeeManager is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant COLLECTOR_ROLE = keccak256("COLLECTOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    struct FeeBreakdown {
        uint256 platformFee;
        uint256 royaltyFee;
        uint256 finderFee;
        uint256 totalFees;
        uint256 sellerReceives;
    }

    struct FeeDistribution {
        address recipient;
        uint256 amount;
        bool isSent;
    }

    struct NativeTokenDiscount {
        bool isActive;
        uint256 discountPercent; // in basis points
        uint256 minimumHolding; // minimum tokens to hold for discount
        uint256 stakingBonus; // additional discount for staked tokens
    }

    // Core dependencies - mutable for upgradeability
    MarketplaceRegistry public registry;
    CollectionManager public collectionManager;

    // State
    mapping(address => uint256) public collectedPlatformFees; // currency -> amount
    mapping(address => uint256) public collectedRoyalties; // royaltyRecipient -> amount
    mapping(address => mapping(address => uint256)) public pendingWithdrawals; // user -> currency -> amount
    
    NativeTokenDiscount public nativeTokenDiscount;
    
    // Fee tracking
    mapping(address => uint256) public totalVolumeByCollection;
    mapping(address => uint256) public totalFeesCollectedByCollection;
    uint256 public totalPlatformFeesCollected;
    uint256 public totalRoyaltiesDistributed;

    // Emergency settings
    bool public emergencyFeeOverride;
    uint256 public emergencyFeePercent;

    // Events
    event FeesCalculated(
        address indexed collection,
        uint256 indexed tokenId,
        uint256 salePrice,
        FeeBreakdown feeBreakdown
    );

    event FeesCollected(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed currency,
        uint256 platformFee,
        uint256 royaltyFee,
        uint256 finderFee
    );

    event FeesDistributed(
        address indexed recipient,
        address indexed currency,
        uint256 amount,
        string feeType
    );

    event NativeTokenDiscountUpdated(
        bool isActive,
        uint256 discountPercent,
        uint256 minimumHolding,
        uint256 stakingBonus
    );

    event EmergencyFeeOverrideSet(bool enabled, uint256 feePercent);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @param _registry MarketplaceRegistry contract address
     * @param _collectionManager CollectionManager contract address
     * @param _admin Admin address
     */
    function initialize(
        address _registry, 
        address _collectionManager,
        address _admin
    ) external initializer {
        require(_registry != address(0), "Invalid registry");
        require(_collectionManager != address(0), "Invalid collection manager");
        require(_admin != address(0), "Invalid admin");

        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        registry = MarketplaceRegistry(_registry);
        collectionManager = CollectionManager(_collectionManager);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(COLLECTOR_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);

        // Initialize native token discount
        nativeTokenDiscount = NativeTokenDiscount({
            isActive: true,
            discountPercent: 250, // 2.5%
            minimumHolding: 1000 * 10**18, // 1000 tokens
            stakingBonus: 100 // additional 1%
        });
    }

    /**
     * @notice Calculate all fees for a sale
     * @param _collection NFT collection address
     * @param _salePrice Sale price in wei
     * @param _currency Payment currency (address(0) for ETH)
     * @param _finderFeeBps Finder fee in basis points
     * @param _buyer Buyer address (for native token discount calculation)
     * @return breakdown Detailed fee breakdown
     */
    function calculateFees(
        address _collection,
        uint256 _salePrice,
        address _currency,
        uint256 _finderFeeBps,
        address _buyer
    ) external view returns (FeeBreakdown memory breakdown) {
        require(_salePrice > 0, "Invalid sale price");
        require(collectionManager.isCollectionSupported(_collection), "Collection not supported");

        // Get collection config
        CollectionManager.CollectionConfig memory config = collectionManager.getCollectionConfig(_collection);

        // Calculate platform fee with potential native token discount
        uint256 platformFeePercent = config.platformFeePercent;
        if (emergencyFeeOverride) {
            platformFeePercent = emergencyFeePercent;
        } else if (_isUsingNativeToken(_currency) && _qualifiesForDiscount(_buyer)) {
            platformFeePercent = _calculateDiscountedFee(platformFeePercent, _buyer);
        }

        breakdown.platformFee = (_salePrice * platformFeePercent) / 10000;
        breakdown.royaltyFee = (_salePrice * config.creatorRoyaltyPercent) / 10000;
        breakdown.finderFee = (_salePrice * _finderFeeBps) / 10000;
        breakdown.totalFees = breakdown.platformFee + breakdown.royaltyFee + breakdown.finderFee;
        breakdown.sellerReceives = _salePrice - breakdown.totalFees;

        return breakdown;
    }

    /**
     * @notice Collect and distribute fees from a completed sale
     * @param _collection NFT collection address
     * @param _tokenId Token ID
     * @param _salePrice Sale price
     * @param _currency Payment currency
     * @param _feeBreakdown Pre-calculated fee breakdown
     * @param _seller Seller address
     * @param _finder Finder address (can be address(0))
     */
    function collectFees(
        address _collection,
        uint256 _tokenId,
        uint256 _salePrice,
        address _currency,
        FeeBreakdown memory _feeBreakdown,
        address _seller,
        address _finder
    ) external onlyRole(COLLECTOR_ROLE) nonReentrant {
        require(_feeBreakdown.totalFees <= _salePrice, "Invalid fee breakdown");

        // Update tracking
        totalVolumeByCollection[_collection] += _salePrice;
        totalFeesCollectedByCollection[_collection] += _feeBreakdown.totalFees;
        totalPlatformFeesCollected += _feeBreakdown.platformFee;

        // Collect platform fees
        if (_feeBreakdown.platformFee > 0) {
            collectedPlatformFees[_currency] += _feeBreakdown.platformFee;
        }

        // Collect royalties
        if (_feeBreakdown.royaltyFee > 0) {
            CollectionManager.CollectionConfig memory config = collectionManager.getCollectionConfig(_collection);
            collectedRoyalties[config.royaltyRecipient] += _feeBreakdown.royaltyFee;
            totalRoyaltiesDistributed += _feeBreakdown.royaltyFee;
        }

        // Handle finder fee
        if (_feeBreakdown.finderFee > 0 && _finder != address(0)) {
            pendingWithdrawals[_finder][_currency] += _feeBreakdown.finderFee;
        }

        emit FeesCalculated(_collection, _tokenId, _salePrice, _feeBreakdown);
        emit FeesCollected(_collection, _tokenId, _currency, _feeBreakdown.platformFee, _feeBreakdown.royaltyFee, _feeBreakdown.finderFee);
    }

    /**
     * @notice Distribute platform fees to recipients
     * @param _currency Currency to distribute
     * @param _amount Amount to distribute
     */
    function distributePlatformFees(address _currency, uint256 _amount) external onlyRole(ADMIN_ROLE) nonReentrant {
        require(_amount <= collectedPlatformFees[_currency], "Insufficient collected fees");
        require(_amount > 0, "Amount must be > 0");

        (,,address feeRecipient,,,) = registry.globalConfig();
        collectedPlatformFees[_currency] -= _amount;

        _sendPayment(feeRecipient, _currency, _amount);
        emit FeesDistributed(feeRecipient, _currency, _amount, "platform");
    }

    /**
     * @notice Distribute royalties to creator
     * @param _creator Creator address
     * @param _currency Currency to distribute
     * @param _amount Amount to distribute
     */
    function distributeRoyalties(address _creator, address _currency, uint256 _amount) external onlyRole(ADMIN_ROLE) nonReentrant {
        require(_amount <= collectedRoyalties[_creator], "Insufficient collected royalties");
        require(_amount > 0, "Amount must be > 0");

        collectedRoyalties[_creator] -= _amount;

        _sendPayment(_creator, _currency, _amount);
        emit FeesDistributed(_creator, _currency, _amount, "royalty");
    }

    /**
     * @notice Allow users to withdraw their pending fees (finder fees, etc.)
     * @param _currency Currency to withdraw
     */
    function withdrawPendingFees(address _currency) external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender][_currency];
        require(amount > 0, "No pending withdrawals");

        pendingWithdrawals[msg.sender][_currency] = 0;

        _sendPayment(msg.sender, _currency, amount);
        emit FeesDistributed(msg.sender, _currency, amount, "withdrawal");
    }

    /**
     * @notice Update native token discount settings
     */
    function updateNativeTokenDiscount(
        bool _isActive,
        uint256 _discountPercent,
        uint256 _minimumHolding,
        uint256 _stakingBonus
    ) external onlyRole(ADMIN_ROLE) {
        require(_discountPercent <= 1000, "Discount too high"); // Max 10%
        require(_stakingBonus <= 500, "Staking bonus too high"); // Max 5%

        nativeTokenDiscount = NativeTokenDiscount({
            isActive: _isActive,
            discountPercent: _discountPercent,
            minimumHolding: _minimumHolding,
            stakingBonus: _stakingBonus
        });

        emit NativeTokenDiscountUpdated(_isActive, _discountPercent, _minimumHolding, _stakingBonus);
    }

    /**
     * @notice Emergency fee override (for crisis situations)
     */
    function setEmergencyFeeOverride(bool _enabled, uint256 _feePercent) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_feePercent <= 2000, "Emergency fee too high"); // Max 20%
        
        emergencyFeeOverride = _enabled;
        emergencyFeePercent = _feePercent;

        emit EmergencyFeeOverrideSet(_enabled, _feePercent);
    }

    /**
     * @notice Internal function to send payments
     */
    function _sendPayment(address _recipient, address _currency, uint256 _amount) internal {
        if (_currency == address(0)) {
            // ETH payment
            payable(_recipient).transfer(_amount);
        } else {
            // ERC20 payment
            require(IERC20(_currency).transfer(_recipient, _amount), "Transfer failed");
        }
    }

    /**
     * @notice Check if using native token
     */
    function _isUsingNativeToken(address _currency) internal view returns (bool) {
        (,,,address nativeToken,,) = registry.globalConfig();
        return _currency == nativeToken;
    }

    /**
     * @notice Check if buyer qualifies for native token discount
     */
    function _qualifiesForDiscount(address _buyer) internal view returns (bool) {
        if (!nativeTokenDiscount.isActive) return false;
        
        (,,,address nativeToken,,) = registry.globalConfig();
        if (nativeToken == address(0)) return false;

        try IERC20(nativeToken).balanceOf(_buyer) returns (uint256 balance) {
            return balance >= nativeTokenDiscount.minimumHolding;
        } catch {
            return false;
        }
    }

    /**
     * @notice Calculate discounted fee for native token holders
     */
    function _calculateDiscountedFee(uint256 _originalFeePercent, address _buyer) internal view returns (uint256) {
        uint256 discount = nativeTokenDiscount.discountPercent;
        
        // TODO: Add staking bonus logic here
        // This would require integration with a staking contract
        
        uint256 discountAmount = (_originalFeePercent * discount) / 10000;
        return _originalFeePercent - discountAmount;
    }

    // View functions
    function getPendingWithdrawal(address _user, address _currency) external view returns (uint256) {
        return pendingWithdrawals[_user][_currency];
    }

    function getCollectedPlatformFees(address _currency) external view returns (uint256) {
        return collectedPlatformFees[_currency];
    }

    function getCollectedRoyalties(address _creator) external view returns (uint256) {
        return collectedRoyalties[_creator];
    }

    function getCollectionStats(address _collection) external view returns (uint256 volume, uint256 fees) {
        return (totalVolumeByCollection[_collection], totalFeesCollectedByCollection[_collection]);
    }

    function getGlobalStats() external view returns (uint256 platformFees, uint256 royalties) {
        return (totalPlatformFeesCollected, totalRoyaltiesDistributed);
    }

    function estimateDiscount(address _buyer) external view returns (uint256 discountPercent) {
        if (!_qualifiesForDiscount(_buyer)) return 0;
        return nativeTokenDiscount.discountPercent;
    }

    /**
     * @notice Update contract dependencies
     */
    function updateDependencies(
        address _registry,
        address _collectionManager
    ) external onlyRole(ADMIN_ROLE) {
        if (_registry != address(0)) registry = MarketplaceRegistry(_registry);
        if (_collectionManager != address(0)) collectionManager = CollectionManager(_collectionManager);
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

    // Admin function to recover any stuck funds
    function emergencyWithdraw(address _currency, uint256 _amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        (,,address feeRecipient,,,) = registry.globalConfig();
        _sendPayment(feeRecipient, _currency, _amount);
    }

    // Emergency fund reception
    receive() external payable {
        // Allow contract to receive ETH for fee collection
    }
}