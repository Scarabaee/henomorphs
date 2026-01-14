// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./MarketplaceRegistry.sol";
import "./CollectionManager.sol";
import "./ERC721TransferHelper.sol";

/**
 * @title ModuleManager
 * @notice Zora-style module coordinator that manages all trading modules
 * @dev UUPS upgradeable - central hub for module registration, validation, and inter-module communication
 * @author rutilicus.eth (ArchXS)  
 * @custom:security-contact contact@archxs.com
 */
contract ModuleManager is 
    Initializable, 
    AccessControlUpgradeable, 
    PausableUpgradeable, 
    UUPSUpgradeable 
{
    bytes32 public constant MODULE_ADMIN_ROLE = keccak256("MODULE_ADMIN_ROLE");
    bytes32 public constant APPROVED_MODULE_ROLE = keccak256("APPROVED_MODULE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // Custom errors
    error InvalidAddress();
    error InvalidName();
    error ModuleAlreadyRegistered();
    error NameAlreadyTaken();
    error ModuleNotFound();
    error ModuleNotActive();
    error ModuleAlreadyInactive();
    error ModuleAlreadyActive();
    error ArrayLengthMismatch();
    error TooManyModules();
    error ModuleManagerPaused();
    error InvalidImplementation();

    struct ModuleInfo {
        address moduleAddress;
        bool isActive;
        string name;
        string version;
        uint256 registeredAt;
        bytes4[] supportedInterfaces;
    }

    struct ModuleCall {
        address module;
        bytes4 selector;
        bytes data;
    }

    // Core dependencies - mutable for upgradeability
    MarketplaceRegistry public registry;
    CollectionManager public collectionManager;
    ERC721TransferHelper public transferHelper;

    // State
    mapping(address => ModuleInfo) public modules;
    mapping(string => address) public modulesByName;
    address[] public registeredModules;
    
    // Module interface tracking
    mapping(bytes4 => address[]) public modulesByInterface;
    mapping(address => mapping(bytes4 => bool)) public moduleInterfaceSupport;
    
    // User approvals for modules
    mapping(address => mapping(address => bool)) public userModuleApprovals;

    // Gap for future storage variables
    uint256[44] private __gap;

    // Events
    event ModuleRegistered(
        address indexed module,
        string name,
        string version,
        bytes4[] supportedInterfaces
    );
    event ModuleDeactivated(address indexed module, string reason);
    event ModuleReactivated(address indexed module);
    event UserApprovalGranted(address indexed user, address indexed module);
    event UserApprovalRevoked(address indexed user, address indexed module);
    event ModuleCallExecuted(address indexed module, bytes4 selector, bool success);
    event DependencyUpdated(string indexed dependencyName, address indexed oldAddress, address indexed newAddress);

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @param _registry MarketplaceRegistry contract address
     * @param _collectionManager CollectionManager contract address  
     * @param _transferHelper ERC721TransferHelper contract address
     * @param _admin Admin address
     */
    function initialize(
        address _registry,
        address _collectionManager,
        address _transferHelper,
        address _admin
    ) external initializer {
        if (_registry == address(0)) revert InvalidAddress();
        if (_collectionManager == address(0)) revert InvalidAddress();
        if (_transferHelper == address(0)) revert InvalidAddress();
        if (_admin == address(0)) revert InvalidAddress();

        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        registry = MarketplaceRegistry(_registry);
        collectionManager = CollectionManager(_collectionManager);
        transferHelper = ERC721TransferHelper(_transferHelper);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MODULE_ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
    }

    /**
     * @notice Register a new trading module
     * @param _module Address of the module contract
     * @param _name Human-readable name
     * @param _version Version string
     * @param _supportedInterfaces Array of interface selectors this module supports
     */
    function registerModule(
        address _module,
        string calldata _name,
        string calldata _version,
        bytes4[] calldata _supportedInterfaces
    ) external onlyRole(MODULE_ADMIN_ROLE) {
        if (_module == address(0)) revert InvalidAddress();
        if (bytes(_name).length == 0) revert InvalidName();
        if (modules[_module].moduleAddress != address(0)) revert ModuleAlreadyRegistered();
        if (modulesByName[_name] != address(0)) revert NameAlreadyTaken();

        // Initialize module info
        ModuleInfo storage moduleInfo = modules[_module];
        moduleInfo.moduleAddress = _module;
        moduleInfo.isActive = true;
        moduleInfo.name = _name;
        moduleInfo.version = _version;
        moduleInfo.registeredAt = block.timestamp;
        moduleInfo.supportedInterfaces = _supportedInterfaces;

        // Register supported interfaces
        for (uint256 i = 0; i < _supportedInterfaces.length; i++) {
            bytes4 interfaceId = _supportedInterfaces[i];
            moduleInterfaceSupport[_module][interfaceId] = true;
            modulesByInterface[interfaceId].push(_module);
        }

        // Add to registries
        registeredModules.push(_module);
        modulesByName[_name] = _module;

        // Grant module role for inter-contract calls
        _grantRole(APPROVED_MODULE_ROLE, _module);

        emit ModuleRegistered(_module, _name, _version, _supportedInterfaces);
    }

    /**
     * @notice Deactivate a module (emergency use)
     */
    function deactivateModule(address _module, string calldata _reason) external onlyRole(MODULE_ADMIN_ROLE) {
        if (modules[_module].moduleAddress == address(0)) revert ModuleNotFound();
        if (!modules[_module].isActive) revert ModuleAlreadyInactive();

        modules[_module].isActive = false;
        emit ModuleDeactivated(_module, _reason);
    }

    /**
     * @notice Reactivate a previously deactivated module
     */
    function reactivateModule(address _module) external onlyRole(MODULE_ADMIN_ROLE) {
        if (modules[_module].moduleAddress == address(0)) revert ModuleNotFound();
        if (modules[_module].isActive) revert ModuleAlreadyActive();

        modules[_module].isActive = true;
        emit ModuleReactivated(_module);
    }

    /**
     * @notice User grants approval for a specific module to act on their behalf
     */
    function setUserApprovalForModule(address _module, bool _approved) external {
        if (modules[_module].moduleAddress == address(0)) revert ModuleNotFound();
        if (!modules[_module].isActive) revert ModuleNotActive();

        userModuleApprovals[msg.sender][_module] = _approved;

        if (_approved) {
            emit UserApprovalGranted(msg.sender, _module);
        } else {
            emit UserApprovalRevoked(msg.sender, _module);
        }
    }

    /**
     * @notice Batch set approvals for multiple modules
     */
    function setUserApprovalForModules(address[] calldata _modules, bool[] calldata _approvals) external {
        if (_modules.length != _approvals.length) revert ArrayLengthMismatch();
        if (_modules.length > 50) revert TooManyModules(); // Gas limit protection

        for (uint256 i = 0; i < _modules.length; i++) {
            if (modules[_modules[i]].moduleAddress == address(0)) revert ModuleNotFound();
            if (!modules[_modules[i]].isActive) revert ModuleNotActive();

            userModuleApprovals[msg.sender][_modules[i]] = _approvals[i];

            if (_approvals[i]) {
                emit UserApprovalGranted(msg.sender, _modules[i]);
            } else {
                emit UserApprovalRevoked(msg.sender, _modules[i]);
            }
        }
    }

    /**
     * @notice Execute a call to a registered module (for inter-module communication)
     */
    function executeModuleCall(
        address _module,
        bytes4 _selector,
        bytes calldata _data
    ) external onlyRole(APPROVED_MODULE_ROLE) returns (bool success, bytes memory returnData) {
        if (modules[_module].moduleAddress == address(0)) revert ModuleNotFound();
        if (!modules[_module].isActive) revert ModuleNotActive();
        if (paused()) revert ModuleManagerPaused();

        (success, returnData) = _module.call(abi.encodePacked(_selector, _data));
        
        emit ModuleCallExecuted(_module, _selector, success);
    }

    /**
     * @notice Validate that a user has approved a module and the module is active
     */
    function validateModuleCall(address _user, address _module) external view returns (bool) {
        return modules[_module].isActive && 
               userModuleApprovals[_user][_module] && 
               !paused();
    }

    /**
     * @notice Check if a module supports a specific interface
     */
    function moduleSupportsInterface(address _module, bytes4 _interfaceId) external view returns (bool) {
        return moduleInterfaceSupport[_module][_interfaceId];
    }

    /**
     * @notice Get all modules that support a specific interface
     */
    function getModulesByInterface(bytes4 _interfaceId) external view returns (address[] memory) {
        return modulesByInterface[_interfaceId];
    }

    /**
     * @notice Get all registered modules
     */
    function getAllModules() external view returns (address[] memory) {
        return registeredModules;
    }

    /**
     * @notice Get all active modules
     */
    function getActiveModules() external view returns (address[] memory) {
        uint256 activeCount = 0;
        
        // Count active modules
        for (uint256 i = 0; i < registeredModules.length; i++) {
            if (modules[registeredModules[i]].isActive) {
                activeCount++;
            }
        }
        
        // Build active modules array
        address[] memory activeModules = new address[](activeCount);
        uint256 currentIndex = 0;
        
        for (uint256 i = 0; i < registeredModules.length; i++) {
            if (modules[registeredModules[i]].isActive) {
                activeModules[currentIndex] = registeredModules[i];
                currentIndex++;
            }
        }
        
        return activeModules;
    }

    /**
     * @notice Get module info by address
     */
    function getModuleInfo(address _module) external view returns (
        string memory name,
        string memory,
        bool isActive,
        uint256 registeredAt,
        bytes4[] memory supportedInterfaces
    ) {
        ModuleInfo storage info = modules[_module];
        return (info.name, info.version, info.isActive, info.registeredAt, info.supportedInterfaces);
    }

    /**
     * @notice Get module address by name
     */
    function getModuleByName(string calldata _name) external view returns (address) {
        return modulesByName[_name];
    }

    /**
     * @notice Check if user has approved a specific module
     */
    function isModuleApprovedForUser(address _user, address _module) external view returns (bool) {
        return userModuleApprovals[_user][_module];
    }

    /**
     * @notice Get all modules approved by a user
     */
    function getUserApprovedModules(address _user) external view returns (address[] memory) {
        uint256 approvedCount = 0;
        
        // Count approved modules
        for (uint256 i = 0; i < registeredModules.length; i++) {
            if (userModuleApprovals[_user][registeredModules[i]]) {
                approvedCount++;
            }
        }
        
        // Build approved modules array
        address[] memory approvedModules = new address[](approvedCount);
        uint256 currentIndex = 0;
        
        for (uint256 i = 0; i < registeredModules.length; i++) {
            if (userModuleApprovals[_user][registeredModules[i]]) {
                approvedModules[currentIndex] = registeredModules[i];
                currentIndex++;
            }
        }
        
        return approvedModules;
    }

    /**
     * @notice Emergency pause all module operations
     */
    function emergencyPause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Resume module operations
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Update contract dependencies
     */
    function updateDependencies(
        address _registry,
        address _collectionManager,
        address _transferHelper
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
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
        if (newImplementation == address(0)) revert InvalidImplementation();
    }

    /**
     * @notice Interface support check
     */
    function supportsInterface(bytes4 interfaceId) 
        public 
        view 
        virtual 
        override(AccessControlUpgradeable) 
        returns (bool) 
    {
        return super.supportsInterface(interfaceId);
    }
}