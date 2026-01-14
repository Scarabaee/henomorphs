// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title MarketplaceRegistry
 * @notice Central registry for all marketplace components and global settings
 * @dev UUPS upgradeable contract serving as the entry point and coordinator.
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract MarketplaceRegistry is Initializable, AccessControlUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // Custom errors
    error InvalidAddress();
    error FeeTooHigh();
    error ModuleNotFound();
    error UnauthorizedCaller();
    error InvalidParameter();

    struct ModuleInfo {
        address moduleAddress;
        bool isActive;
        uint256 version;
        string name;
    }

    struct GlobalConfig {
        uint256 maxPlatformFee; // in basis points (10000 = 100%)
        uint256 defaultPlatformFee;
        address feeRecipient;
        address nativeToken;
        bool requireNativeTokenDiscount;
        uint256 nativeTokenDiscountPercent; // in basis points
    }

    // State variables
    GlobalConfig public globalConfig;
    mapping(string => ModuleInfo) public modules;
    mapping(address => bool) public authorizedCallers;
    string[] public moduleNames;

    // Events
    event ModuleRegistered(string indexed name, address indexed moduleAddress, uint256 version);
    event ModuleUpdated(string indexed name, address indexed oldAddress, address indexed newAddress);
    event ModuleStatusChanged(string indexed name, bool isActive);
    event GlobalConfigUpdated(string indexed parameter, uint256 oldValue, uint256 newValue);
    event AuthorizedCallerAdded(address indexed caller);
    event AuthorizedCallerRemoved(address indexed caller);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _admin,
        address _feeRecipient,
        address _nativeToken,
        uint256 _defaultPlatformFee
    ) external initializer {
        if (_admin == address(0)) revert InvalidAddress();
        if (_feeRecipient == address(0)) revert InvalidAddress();
        if (_defaultPlatformFee > 1000) revert FeeTooHigh();

        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);

        globalConfig = GlobalConfig({
            maxPlatformFee: 1000, // 10%
            defaultPlatformFee: _defaultPlatformFee,
            feeRecipient: _feeRecipient,
            nativeToken: _nativeToken,
            requireNativeTokenDiscount: false,
            nativeTokenDiscountPercent: 250 // 2.5% discount
        });
    }

    /**
     * @notice Register a new module in the marketplace
     */
    function registerModule(
        string calldata _name,
        address _moduleAddress,
        uint256 _version
    ) external onlyRole(ADMIN_ROLE) {
        if (_moduleAddress == address(0)) revert InvalidAddress();
        if (bytes(_name).length == 0) revert InvalidParameter();
        
        if (modules[_name].moduleAddress == address(0)) {
            moduleNames.push(_name);
        }

        modules[_name] = ModuleInfo({
            moduleAddress: _moduleAddress,
            isActive: true,
            version: _version,
            name: _name
        });

        emit ModuleRegistered(_name, _moduleAddress, _version);
    }

    /**
     * @notice Update an existing module
     */
    function updateModule(
        string calldata _name,
        address _newModuleAddress,
        uint256 _newVersion
    ) external onlyRole(ADMIN_ROLE) {
        if (modules[_name].moduleAddress == address(0)) revert ModuleNotFound();
        if (_newModuleAddress == address(0)) revert InvalidAddress();

        address oldAddress = modules[_name].moduleAddress;
        modules[_name].moduleAddress = _newModuleAddress;
        modules[_name].version = _newVersion;

        emit ModuleUpdated(_name, oldAddress, _newModuleAddress);
    }

    /**
     * @notice Activate or deactivate a module
     */
    function setModuleStatus(string calldata _name, bool _isActive) external onlyRole(ADMIN_ROLE) {
        if (modules[_name].moduleAddress == address(0)) revert ModuleNotFound();
        modules[_name].isActive = _isActive;
        emit ModuleStatusChanged(_name, _isActive);
    }

    /**
     * @notice Update global configuration
     */
    function updateGlobalConfig(
        uint256 _maxPlatformFee,
        uint256 _defaultPlatformFee,
        address _feeRecipient,
        uint256 _nativeTokenDiscountPercent
    ) external onlyRole(ADMIN_ROLE) {
        if (_maxPlatformFee > 2000) revert FeeTooHigh();
        if (_defaultPlatformFee > _maxPlatformFee) revert FeeTooHigh();
        if (_feeRecipient == address(0)) revert InvalidAddress();
        if (_nativeTokenDiscountPercent > 1000) revert FeeTooHigh();

        globalConfig.maxPlatformFee = _maxPlatformFee;
        globalConfig.defaultPlatformFee = _defaultPlatformFee;
        globalConfig.feeRecipient = _feeRecipient;
        globalConfig.nativeTokenDiscountPercent = _nativeTokenDiscountPercent;
    }

    /**
     * @notice Add authorized caller (for inter-contract communication)
     */
    function addAuthorizedCaller(address _caller) external onlyRole(ADMIN_ROLE) {
        if (_caller == address(0)) revert InvalidAddress();
        authorizedCallers[_caller] = true;
        emit AuthorizedCallerAdded(_caller);
    }

    /**
     * @notice Remove authorized caller
     */
    function removeAuthorizedCaller(address _caller) external onlyRole(ADMIN_ROLE) {
        authorizedCallers[_caller] = false;
        emit AuthorizedCallerRemoved(_caller);
    }

    /**
     * @notice Emergency pause all marketplace operations
     */
    function emergencyPause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /**
     * @notice Resume marketplace operations
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // View functions
    function getModule(string calldata _name) external view returns (ModuleInfo memory) {
        return modules[_name];
    }

    function isModuleActive(string calldata _name) external view returns (bool) {
        return modules[_name].isActive && !paused();
    }

    function getAllModules() external view returns (string[] memory) {
        return moduleNames;
    }

    function isAuthorizedCaller(address _caller) external view returns (bool) {
        return authorizedCallers[_caller];
    }

    /**
     * @notice Get effective platform fee (with native token discount if applicable)
     */
    function getEffectivePlatformFee(bool _usingNativeToken) external view returns (uint256) {
        if (_usingNativeToken && globalConfig.requireNativeTokenDiscount) {
            uint256 discount = (globalConfig.defaultPlatformFee * globalConfig.nativeTokenDiscountPercent) / 10000;
            return globalConfig.defaultPlatformFee - discount;
        }
        return globalConfig.defaultPlatformFee;
    }

    /**
     * @notice Authorize upgrade - only UPGRADER_ROLE can upgrade
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}