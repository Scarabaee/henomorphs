// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "../core/MarketplaceRegistry.sol";
import "../core/CollectionManager.sol";

/**
 * @title PaymentProcessor
 * @notice UUPS upgradeable payment processing system for the marketplace
 * @dev Handles all payment distributions, fee calculations, and multi-token support
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract PaymentProcessor is 
    Initializable, 
    ReentrancyGuardUpgradeable, 
    AccessControlUpgradeable, 
    PausableUpgradeable,
    UUPSUpgradeable 
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // Custom errors
    error InvalidRecipient();
    error InvalidAmount();
    error TransferFailed();
    error InsufficientBalance();
    error UnsupportedToken();
    error InvalidDistribution();
    error ExcessiveSlippage();
    error InvalidDependency();

    struct PaymentDistribution {
        address recipient;
        uint256 amount;
        string description;
    }

    struct TokenInfo {
        bool isSupported;
        uint256 minAmount;
        uint256 maxAmount;
        uint256 processingFee; // in basis points
    }

    struct PaymentSummary {
        address token;
        uint256 totalAmount;
        uint256 platformFee;
        uint256 royaltyFee;
        uint256 sellerAmount;
        uint256 finderFee;
        uint256 processingFee;
    }

    // Core dependencies - changed from immutable to storage for upgradeability
    MarketplaceRegistry public registry;
    CollectionManager public collectionManager;

    // Storage
    mapping(address => TokenInfo) public supportedTokens;
    mapping(address => uint256) public tokenBalances;
    mapping(address => mapping(address => uint256)) public userTokenBalances;
    address[] public supportedTokenList;

    // Settings
    uint256 public maxSlippageBps; // Maximum acceptable slippage
    uint256 public defaultProcessingFeeBps;
    address public emergencyWithdrawRecipient;

    // Gap for future storage variables
    uint256[44] private __gap;

    // Events
    event PaymentProcessed(
        address indexed from,
        address indexed token,
        uint256 amount,
        bytes32 indexed transactionId
    );

    event DistributionExecuted(
        bytes32 indexed transactionId,
        PaymentDistribution[] distributions
    );

    event TokenAdded(address indexed token, uint256 minAmount, uint256 maxAmount);
    event TokenUpdated(address indexed token, bool isSupported);
    event TokenRemoved(address indexed token);
    
    event FeesDistributed(
        address indexed collection,
        uint256 indexed tokenId,
        address token,
        uint256 platformFee,
        uint256 royaltyFee,
        uint256 sellerAmount
    );

    event EmergencyWithdrawal(address indexed token, uint256 amount, address indexed recipient);
    event DependencyUpdated(string indexed dependencyName, address indexed oldAddress, address indexed newAddress);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _registry,
        address _collectionManager,
        address _admin,
        address _emergencyWithdrawRecipient
    ) external initializer {
        if (_registry == address(0)) revert InvalidRecipient();
        if (_collectionManager == address(0)) revert InvalidRecipient();
        if (_admin == address(0)) revert InvalidRecipient();
        if (_emergencyWithdrawRecipient == address(0)) revert InvalidRecipient();

        __ReentrancyGuard_init();
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        registry = MarketplaceRegistry(_registry);
        collectionManager = CollectionManager(_collectionManager);
        emergencyWithdrawRecipient = _emergencyWithdrawRecipient;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);

        maxSlippageBps = 50; // 0.5% max slippage
        defaultProcessingFeeBps = 25; // 0.25% processing fee

        // Add ETH as default supported token
        supportedTokens[address(0)] = TokenInfo({
            isSupported: true,
            minAmount: 0.001 ether,
            maxAmount: 1000 ether,
            processingFee: 0
        });
    }

    /**
     * @notice Process payment for NFT sale
     * @param _token Payment token address (address(0) for ETH)
     * @param _totalAmount Total payment amount
     * @param _collection NFT collection address
     * @param _tokenId NFT token ID
     * @param _seller Seller address
     * @param _finder Finder address (can be address(0))
     * @param _finderFeeBps Finder fee in basis points
     */
    function processPayment(
        address _token,
        uint256 _totalAmount,
        address _collection,
        uint256 _tokenId,
        address _seller,
        address _finder,
        uint16 _finderFeeBps
    ) external payable nonReentrant whenNotPaused onlyRole(OPERATOR_ROLE) returns (PaymentSummary memory) {
        if (_totalAmount == 0) revert InvalidAmount();
        if (!supportedTokens[_token].isSupported) revert UnsupportedToken();

        (,,,address nativeToken,,) = registry.globalConfig();

        // Calculate all fees
        // (uint256 platformFee, uint256 royaltyFee, uint256 totalProtocolFee) = collectionManager.calculateTotalFees(
        //     _collection,
        //     _totalAmount,
        //     _token == nativeToken
        // ); //TODO FIX Stack too deep

        uint256 finderFee = (_totalAmount * _finderFeeBps) / 10000;
        // uint256 processingFee = (_totalAmount * supportedTokens[_token].processingFee) / 10000;
        // uint256 sellerAmount = _totalAmount - totalProtocolFee - finderFee - processingFee; //TODO FIX Stack too deep

        // Handle payment collection
        if (_token == address(0)) {
            // ETH payment
            if (msg.value != _totalAmount) revert InvalidAmount();
        } else {
            // ERC20 payment
            if (msg.value != 0) revert InvalidAmount();
            IERC20 token = IERC20(_token);
            if (!token.transferFrom(msg.sender, address(this), _totalAmount)) revert TransferFailed();
        }

        // Create payment distributions
        PaymentDistribution[] memory distributions = new PaymentDistribution[](5);
        uint256 distributionCount = 0;
        // (,,address feeRecipient,,,) = registry.globalConfig();

        // Platform fee
            // if (platformFee > 0) {
            //     distributions[distributionCount] = PaymentDistribution({
            //         recipient: feeRecipient,
            //         amount: platformFee,
            //         description: "Platform Fee"
            //     });
            //     distributionCount++;
            // }

        // Royalty fee
        // if (royaltyFee > 0) {
        //     CollectionManager.CollectionConfig memory config = collectionManager.getCollectionConfig(_collection);
        //     distributions[distributionCount] = PaymentDistribution({
        //         recipient: config.royaltyRecipient,
        //         amount: royaltyFee,
        //         description: "Royalty Fee"
        //     });
        //     distributionCount++;
        // } TODO FIX Stack too deep

        // Finder fee
        if (finderFee > 0 && _finder != address(0)) {
            distributions[distributionCount] = PaymentDistribution({
                recipient: _finder,
                amount: finderFee,
                description: "Finder Fee"
            });
            distributionCount++;
        }

        // Processing fee (kept by contract)
        // if (processingFee > 0) {
        //     tokenBalances[_token] += processingFee;
        //     distributions[distributionCount] = PaymentDistribution({
        //         recipient: address(this),
        //         amount: processingFee,
        //         description: "Processing Fee"
        //     });
        //     distributionCount++;
        // }    TODO FIX Stack too deep

        // Seller amount
        // distributions[distributionCount] = PaymentDistribution({
        //     recipient: _seller,
        //     amount: sellerAmount,
        //     description: "Seller Payment"
        // });
        // distributionCount++;  // TODO FIX Stack too deep

        // Execute distributions
        // bytes32 transactionId = keccak256(abi.encodePacked(block.timestamp, _collection, _tokenId, _totalAmount));
        // _executeDistributions(_token, distributions, distributionCount);

        // emit PaymentProcessed(msg.sender, _token, _totalAmount, transactionId); // TODO FIX Stack too deep
        // emit FeesDistributed(_collection, _tokenId, _token, platformFee, royaltyFee, sellerAmount); // TODO FIX Stack too deep

        // return PaymentSummary({
        //     token: _token,
        //     totalAmount: _totalAmount,
        //     platformFee: platformFee,
        //     royaltyFee: royaltyFee,
        //     sellerAmount: sellerAmount,
        //     finderFee: finderFee,
        //     processingFee: processingFee
        // }); // TODO FIX Stack too deep

        return PaymentSummary({
            token: _token,
            totalAmount: _totalAmount,
            platformFee: 0,
            royaltyFee: 0,
            sellerAmount: 0,
            finderFee: 0,
            processingFee: 0
        });
    }

    /**
     * @notice Execute payment distributions
     */
    function _executeDistributions(
        address _token,
        PaymentDistribution[] memory _distributions,
        uint256 _count
    ) internal {
        for (uint256 i = 0; i < _count; i++) {
            PaymentDistribution memory distribution = _distributions[i];
            
            if (distribution.recipient == address(this)) {
                // Skip internal accounting
                continue;
            }

            if (_token == address(0)) {
                // ETH transfer
                (bool success, ) = payable(distribution.recipient).call{value: distribution.amount}("");
                if (!success) revert TransferFailed();
            } else {
                // ERC20 transfer
                IERC20 token = IERC20(_token);
                if (!token.transfer(distribution.recipient, distribution.amount)) revert TransferFailed();
            }
        }

        bytes32 transactionId = keccak256(abi.encodePacked(block.timestamp, _distributions.length)); //TODO FIX!!
        emit DistributionExecuted(transactionId, _distributions);
    }

    /**
     * @notice Add supported payment token
     */
    function addSupportedToken(
        address _token,
        uint256 _minAmount,
        uint256 _maxAmount,
        uint256 _processingFeeBps
    ) external onlyRole(ADMIN_ROLE) {
        if (_processingFeeBps > 1000) revert InvalidAmount(); // Max 10%
        if (_minAmount >= _maxAmount) revert InvalidAmount();

        if (!supportedTokens[_token].isSupported) {
            supportedTokenList.push(_token);
        }

        supportedTokens[_token] = TokenInfo({
            isSupported: true,
            minAmount: _minAmount,
            maxAmount: _maxAmount,
            processingFee: _processingFeeBps
        });

        emit TokenAdded(_token, _minAmount, _maxAmount);
    }

    /**
     * @notice Update token support status
     */
    function updateTokenStatus(address _token, bool _isSupported) external onlyRole(ADMIN_ROLE) {
        supportedTokens[_token].isSupported = _isSupported;
        emit TokenUpdated(_token, _isSupported);
    }

    /**
     * @notice Remove supported token
     */
    function removeSupportedToken(address _token) external onlyRole(ADMIN_ROLE) {
        if (_token == address(0)) revert InvalidRecipient(); // Cannot remove ETH
        
        delete supportedTokens[_token];
        
        // Remove from array
        for (uint256 i = 0; i < supportedTokenList.length; i++) {
            if (supportedTokenList[i] == _token) {
                supportedTokenList[i] = supportedTokenList[supportedTokenList.length - 1];
                supportedTokenList.pop();
                break;
            }
        }

        emit TokenRemoved(_token);
    }

    /**
     * @notice Withdraw accumulated processing fees
     */
    function withdrawProcessingFees(address _token, uint256 _amount) external onlyRole(ADMIN_ROLE) {
        if (_amount > tokenBalances[_token]) revert InsufficientBalance();
        
        tokenBalances[_token] -= _amount;

        if (_token == address(0)) {
            (bool success, ) = payable(emergencyWithdrawRecipient).call{value: _amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20 token = IERC20(_token);
            if (!token.transfer(emergencyWithdrawRecipient, _amount)) revert TransferFailed();
        }
    }

    /**
     * @notice Emergency withdrawal function
     */
    function emergencyWithdraw(address _token) external onlyRole(ADMIN_ROLE) {
        uint256 amount;
        
        if (_token == address(0)) {
            amount = address(this).balance;
            (bool success, ) = payable(emergencyWithdrawRecipient).call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20 token = IERC20(_token);
            amount = token.balanceOf(address(this));
            if (!token.transfer(emergencyWithdrawRecipient, amount)) revert TransferFailed();
        }

        emit EmergencyWithdrawal(_token, amount, emergencyWithdrawRecipient);
    }

    /**
     * @notice Update dependencies for upgradeability
     */
    function updateDependencies(
        address _registry,
        address _collectionManager
    ) external onlyRole(ADMIN_ROLE) {
        if (_registry != address(0)) {
            emit DependencyUpdated("registry", address(registry), _registry);
            registry = MarketplaceRegistry(_registry);
        }
        if (_collectionManager != address(0)) {
            emit DependencyUpdated("collectionManager", address(collectionManager), _collectionManager);
            collectionManager = CollectionManager(_collectionManager);
        }
    }

    // View functions
    function isTokenSupported(address _token) external view returns (bool) {
        return supportedTokens[_token].isSupported;
    }

    function getTokenInfo(address _token) external view returns (TokenInfo memory) {
        return supportedTokens[_token];
    }

    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokenList;
    }

    function getTokenBalance(address _token) external view returns (uint256) {
        return tokenBalances[_token];
    }

    function calculatePaymentBreakdown(
        address _collection,
        uint256 _amount,
        address _token,
        uint16 _finderFeeBps
    ) external view returns (PaymentSummary memory) {
        (,,,address nativeToken,,) = registry.globalConfig();
        (uint256 platformFee, uint256 royaltyFee, uint256 totalProtocolFee) = collectionManager.calculateTotalFees(
            _collection,
            _amount,
            _token == nativeToken
        );

        uint256 finderFee = (_amount * _finderFeeBps) / 10000;
        uint256 processingFee = (_amount * supportedTokens[_token].processingFee) / 10000;
        uint256 sellerAmount = _amount - totalProtocolFee - finderFee - processingFee;

        return PaymentSummary({
            token: _token,
            totalAmount: _amount,
            platformFee: platformFee,
            royaltyFee: royaltyFee,
            sellerAmount: sellerAmount,
            finderFee: finderFee,
            processingFee: processingFee
        });
    }

    // Admin functions
    function setMaxSlippage(uint256 _maxSlippageBps) external onlyRole(ADMIN_ROLE) {
        if (_maxSlippageBps > 1000) revert InvalidAmount(); // Max 10%
        maxSlippageBps = _maxSlippageBps;
    }

    function setDefaultProcessingFee(uint256 _processingFeeBps) external onlyRole(ADMIN_ROLE) {
        if (_processingFeeBps > 1000) revert InvalidAmount(); // Max 10%
        defaultProcessingFeeBps = _processingFeeBps;
    }

    function setEmergencyWithdrawRecipient(address _recipient) external onlyRole(ADMIN_ROLE) {
        if (_recipient == address(0)) revert InvalidRecipient();
        emergencyWithdrawRecipient = _recipient;
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Authorize upgrade - only UPGRADER_ROLE can upgrade
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // Receive ETH
    receive() external payable {
        tokenBalances[address(0)] += msg.value;
    }
}