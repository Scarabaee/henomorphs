// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../core/MarketplaceRegistry.sol";

/**
 * @title EmergencyControls
 * @notice Centralized emergency controls and circuit breakers for the marketplace
 * @dev UUPS upgradeable - provides emergency pause, fund recovery, and system-wide safety mechanisms
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract EmergencyControls is 
    Initializable, 
    AccessControlUpgradeable, 
    PausableUpgradeable, 
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable 
{
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant RECOVERY_ROLE = keccak256("RECOVERY_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    enum EmergencyLevel {
        NONE,           // 0 - Normal operations
        WARNING,        // 1 - Warning state, monitoring increased
        CRITICAL,       // 2 - Critical issues, some features disabled
        EMERGENCY,      // 3 - Emergency state, trading paused
        LOCKDOWN        // 4 - Full lockdown, all operations stopped
    }

    struct EmergencyAction {
        address initiator;
        string reason;
        uint256 timestamp;
        EmergencyLevel level;
        bool isActive;
    }

    struct CircuitBreaker {
        uint256 threshold;      // Threshold value
        uint256 timeWindow;     // Time window in seconds
        uint256 currentCount;   // Current count in window
        uint256 windowStart;    // Window start timestamp
        bool isTripped;         // Whether circuit breaker is tripped
        string name;            // Human readable name
    }

    struct RecoveryRequest {
        address requester;
        address asset;          // address(0) for ETH
        address recipient;
        uint256 amount;
        string reason;
        uint256 timestamp;
        uint256 approvals;
        bool executed;
        mapping(address => bool) hasApproved;
    }

    // Core dependencies - mutable for upgradeability
    MarketplaceRegistry public registry;

    // Emergency state
    EmergencyLevel public currentEmergencyLevel;
    mapping(uint256 => EmergencyAction) public emergencyActions;
    uint256 public emergencyActionCount;

    // Circuit breakers
    mapping(string => CircuitBreaker) public circuitBreakers;
    string[] public circuitBreakerNames;

    // Recovery system
    mapping(bytes32 => RecoveryRequest) public recoveryRequests;
    bytes32[] public recoveryRequestIds;
    uint256 public requiredRecoveryApprovals;

    // Blacklist system
    mapping(address => bool) public blacklistedUsers;
    mapping(address => bool) public blacklistedContracts;
    
    // Emergency settings
    uint256 public emergencyDelay;
    uint256 public maxEmergencyDuration;
    bool public emergencyWithdrawalsEnabled;

    // Events
    event EmergencyLevelChanged(
        EmergencyLevel indexed oldLevel,
        EmergencyLevel indexed newLevel,
        address indexed initiator,
        string reason
    );

    event CircuitBreakerTripped(
        string indexed name,
        uint256 threshold,
        uint256 actualValue,
        address indexed triggeredBy
    );

    event CircuitBreakerReset(
        string indexed name,
        address indexed resetBy
    );

    event EmergencyPause(
        address indexed initiator,
        string reason,
        uint256 timestamp
    );

    event EmergencyUnpause(
        address indexed initiator,
        string reason,
        uint256 timestamp
    );

    event UserBlacklisted(
        address indexed user,
        address indexed admin,
        string reason
    );

    event UserWhitelisted(
        address indexed user,
        address indexed admin
    );

    event RecoveryRequested(
        bytes32 indexed requestId,
        address indexed requester,
        address asset,
        uint256 amount,
        string reason
    );

    event RecoveryApproved(
        bytes32 indexed requestId,
        address indexed approver,
        uint256 totalApprovals
    );

    event RecoveryExecuted(
        bytes32 indexed requestId,
        address recipient,
        address asset,
        uint256 amount
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
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        registry = MarketplaceRegistry(_registry);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
        _grantRole(GUARDIAN_ROLE, _admin);
        _grantRole(RECOVERY_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);

        currentEmergencyLevel = EmergencyLevel.NONE;
        requiredRecoveryApprovals = 3;
        emergencyDelay = 1 hours;
        maxEmergencyDuration = 7 days;
        emergencyWithdrawalsEnabled = false;

        // Initialize default circuit breakers
        _initializeCircuitBreakers();
    }

    /**
     * @notice Set emergency level with reason
     * @param _level Emergency level to set
     * @param _reason Reason for emergency
     */
    function setEmergencyLevel(EmergencyLevel _level, string memory _reason) public onlyRole(EMERGENCY_ROLE) {
        require(bytes(_reason).length > 0, "Reason required");
        
        EmergencyLevel oldLevel = currentEmergencyLevel;
        currentEmergencyLevel = _level;

        // Record emergency action
        emergencyActions[emergencyActionCount] = EmergencyAction({
            initiator: msg.sender,
            reason: _reason,
            timestamp: block.timestamp,
            level: _level,
            isActive: true
        });
        emergencyActionCount++;

        // Auto-pause based on level
        if (_level >= EmergencyLevel.EMERGENCY && !paused()) {
            _pause();
            emit EmergencyPause(msg.sender, _reason, block.timestamp);
        } else if (_level < EmergencyLevel.EMERGENCY && paused()) {
            _unpause();
            emit EmergencyUnpause(msg.sender, _reason, block.timestamp);
        }

        emit EmergencyLevelChanged(oldLevel, _level, msg.sender, _reason);
    }

    /**
     * @notice Emergency pause all marketplace operations
     * @param _reason Reason for pause
     */
    function emergencyPause(string calldata _reason) external onlyRole(EMERGENCY_ROLE) {
        require(!paused(), "Already paused");
        require(bytes(_reason).length > 0, "Reason required");

        _pause();
        
        if (currentEmergencyLevel < EmergencyLevel.EMERGENCY) {
            currentEmergencyLevel = EmergencyLevel.EMERGENCY;
        }

        emit EmergencyPause(msg.sender, _reason, block.timestamp);
    }

    /**
     * @notice Unpause marketplace operations
     * @param _reason Reason for unpause
     */
    function emergencyUnpause(string calldata _reason) external onlyRole(EMERGENCY_ROLE) {
        require(paused(), "Not paused");
        require(bytes(_reason).length > 0, "Reason required");

        _unpause();
        
        if (currentEmergencyLevel >= EmergencyLevel.EMERGENCY) {
            currentEmergencyLevel = EmergencyLevel.WARNING;
        }

        emit EmergencyUnpause(msg.sender, _reason, block.timestamp);
    }

    /**
     * @notice Initialize circuit breakers with default values
     */
    function _initializeCircuitBreakers() internal {
        // Large transaction circuit breaker
        circuitBreakers["large_transactions"] = CircuitBreaker({
            threshold: 10,          // 10 large transactions
            timeWindow: 1 hours,    // in 1 hour
            currentCount: 0,
            windowStart: block.timestamp,
            isTripped: false,
            name: "Large Transaction Monitor"
        });
        circuitBreakerNames.push("large_transactions");

        // Failed transaction circuit breaker
        circuitBreakers["failed_transactions"] = CircuitBreaker({
            threshold: 50,          // 50 failed transactions
            timeWindow: 1 hours,    // in 1 hour
            currentCount: 0,
            windowStart: block.timestamp,
            isTripped: false,
            name: "Failed Transaction Monitor"
        });
        circuitBreakerNames.push("failed_transactions");

        // High gas usage circuit breaker
        circuitBreakers["high_gas_usage"] = CircuitBreaker({
            threshold: 20,          // 20 high gas transactions
            timeWindow: 30 minutes, // in 30 minutes
            currentCount: 0,
            windowStart: block.timestamp,
            isTripped: false,
            name: "High Gas Usage Monitor"
        });
        circuitBreakerNames.push("high_gas_usage");
    }

    /**
     * @notice Trigger a circuit breaker check
     * @param _name Circuit breaker name
     */
    function triggerCircuitBreaker(string calldata _name) external onlyRole(GUARDIAN_ROLE) {
        CircuitBreaker storage cb = circuitBreakers[_name];
        require(bytes(cb.name).length > 0, "Circuit breaker not found");

        // Reset window if expired
        if (block.timestamp >= cb.windowStart + cb.timeWindow) {
            cb.currentCount = 0;
            cb.windowStart = block.timestamp;
        }

        cb.currentCount++;

        // Check if threshold exceeded
        if (cb.currentCount >= cb.threshold && !cb.isTripped) {
            cb.isTripped = true;
            
            // Auto-escalate emergency level
            if (currentEmergencyLevel < EmergencyLevel.CRITICAL) {
                setEmergencyLevel(EmergencyLevel.CRITICAL, string.concat("Circuit breaker tripped: ", _name));
            }

            emit CircuitBreakerTripped(_name, cb.threshold, cb.currentCount, msg.sender);
        }
    }

    /**
     * @notice Reset a circuit breaker
     * @param _name Circuit breaker name
     */
    function resetCircuitBreaker(string calldata _name) external onlyRole(EMERGENCY_ROLE) {
        CircuitBreaker storage cb = circuitBreakers[_name];
        require(bytes(cb.name).length > 0, "Circuit breaker not found");

        cb.isTripped = false;
        cb.currentCount = 0;
        cb.windowStart = block.timestamp;

        emit CircuitBreakerReset(_name, msg.sender);
    }

    /**
     * @notice Add or update a circuit breaker
     * @param _name Circuit breaker name
     * @param _threshold Threshold value
     * @param _timeWindow Time window in seconds
     * @param _displayName Human readable name
     */
    function setCircuitBreaker(
        string calldata _name,
        uint256 _threshold,
        uint256 _timeWindow,
        string calldata _displayName
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_threshold > 0, "Invalid threshold");
        require(_timeWindow > 0, "Invalid time window");
        require(bytes(_displayName).length > 0, "Display name required");

        bool isNew = bytes(circuitBreakers[_name].name).length == 0;
        
        circuitBreakers[_name] = CircuitBreaker({
            threshold: _threshold,
            timeWindow: _timeWindow,
            currentCount: 0,
            windowStart: block.timestamp,
            isTripped: false,
            name: _displayName
        });

        if (isNew) {
            circuitBreakerNames.push(_name);
        }
    }

    /**
     * @notice Blacklist a user
     * @param _user User address to blacklist
     * @param _reason Reason for blacklisting
     */
    function blacklistUser(address _user, string calldata _reason) external onlyRole(EMERGENCY_ROLE) {
        require(_user != address(0), "Invalid user");
        require(!hasRole(DEFAULT_ADMIN_ROLE, _user), "Cannot blacklist admin");

        blacklistedUsers[_user] = true;
        emit UserBlacklisted(_user, msg.sender, _reason);
    }

    /**
     * @notice Remove user from blacklist
     * @param _user User address to whitelist
     */
    function removeFromBlacklist(address _user) external onlyRole(EMERGENCY_ROLE) {
        blacklistedUsers[_user] = false;
        emit UserWhitelisted(_user, msg.sender);
    }

    /**
     * @notice Blacklist a contract
     * @param _contract Contract address to blacklist
     * @param _reason Reason for blacklisting
     */
    function blacklistContract(address _contract, string calldata _reason) external onlyRole(EMERGENCY_ROLE) {
        require(_contract != address(0), "Invalid contract");
        require(_contract.code.length > 0, "Not a contract");

        blacklistedContracts[_contract] = true;
        emit UserBlacklisted(_contract, msg.sender, _reason);
    }

    /**
     * @notice Request emergency fund recovery
     * @param _asset Asset to recover (address(0) for ETH)
     * @param _recipient Recovery recipient
     * @param _amount Amount to recover
     * @param _reason Reason for recovery
     */
    function requestRecovery(
        address _asset,
        address _recipient,
        uint256 _amount,
        string calldata _reason
    ) external onlyRole(RECOVERY_ROLE) returns (bytes32 requestId) {
        require(_recipient != address(0), "Invalid recipient");
        require(_amount > 0, "Invalid amount");
        require(bytes(_reason).length > 0, "Reason required");

        requestId = keccak256(abi.encodePacked(
            msg.sender,
            _asset,
            _recipient,
            _amount,
            block.timestamp
        ));

        RecoveryRequest storage request = recoveryRequests[requestId];
        request.requester = msg.sender;
        request.asset = _asset;
        request.recipient = _recipient;
        request.amount = _amount;
        request.reason = _reason;
        request.timestamp = block.timestamp;
        request.approvals = 0;
        request.executed = false;

        recoveryRequestIds.push(requestId);

        emit RecoveryRequested(requestId, msg.sender, _asset, _amount, _reason);
        return requestId;
    }

    /**
     * @notice Approve a recovery request
     * @param _requestId Recovery request ID
     */
    function approveRecovery(bytes32 _requestId) external onlyRole(RECOVERY_ROLE) {
        RecoveryRequest storage request = recoveryRequests[_requestId];
        require(request.requester != address(0), "Request not found");
        require(!request.executed, "Already executed");
        require(!request.hasApproved[msg.sender], "Already approved");

        request.hasApproved[msg.sender] = true;
        request.approvals++;

        emit RecoveryApproved(_requestId, msg.sender, request.approvals);

        // Auto-execute if enough approvals
        if (request.approvals >= requiredRecoveryApprovals) {
            _executeRecovery(_requestId);
        }
    }

    /**
     * @notice Execute a recovery request
     * @param _requestId Recovery request ID
     */
    function executeRecovery(bytes32 _requestId) external onlyRole(RECOVERY_ROLE) {
        RecoveryRequest storage request = recoveryRequests[_requestId];
        require(request.approvals >= requiredRecoveryApprovals, "Insufficient approvals");
        _executeRecovery(_requestId);
    }

    /**
     * @notice Internal function to execute recovery
     */
    function _executeRecovery(bytes32 _requestId) internal nonReentrant {
        RecoveryRequest storage request = recoveryRequests[_requestId];
        require(!request.executed, "Already executed");

        request.executed = true;

        if (request.asset == address(0)) {
            // ETH recovery
            require(address(this).balance >= request.amount, "Insufficient ETH balance");
            payable(request.recipient).transfer(request.amount);
        } else {
            // ERC20 recovery
            IERC20 token = IERC20(request.asset);
            require(token.balanceOf(address(this)) >= request.amount, "Insufficient token balance");
            require(token.transfer(request.recipient, request.amount), "Transfer failed");
        }

        emit RecoveryExecuted(_requestId, request.recipient, request.asset, request.amount);
    }

    // View functions
    function isBlacklisted(address _user) external view returns (bool) {
        return blacklistedUsers[_user] || blacklistedContracts[_user];
    }

    function getCircuitBreakerStatus(string calldata _name) external view returns (
        uint256 threshold,
        uint256 timeWindow,
        uint256 currentCount,
        uint256 windowStart,
        bool isTripped
    ) {
        CircuitBreaker memory cb = circuitBreakers[_name];
        return (cb.threshold, cb.timeWindow, cb.currentCount, cb.windowStart, cb.isTripped);
    }

    function getAllCircuitBreakers() external view returns (string[] memory) {
        return circuitBreakerNames;
    }

    function getRecoveryRequest(bytes32 _requestId) external view returns (
        address requester,
        address asset,
        address recipient,
        uint256 amount,
        string memory reason,
        uint256 timestamp,
        uint256 approvals,
        bool executed
    ) {
        RecoveryRequest storage request = recoveryRequests[_requestId];
        return (
            request.requester,
            request.asset,
            request.recipient,
            request.amount,
            request.reason,
            request.timestamp,
            request.approvals,
            request.executed
        );
    }

    function getAllRecoveryRequests() external view returns (bytes32[] memory) {
        return recoveryRequestIds;
    }

    function hasApprovedRecovery(bytes32 _requestId, address _approver) external view returns (bool) {
        return recoveryRequests[_requestId].hasApproved[_approver];
    }

    // Admin functions
    function setRequiredRecoveryApprovals(uint256 _required) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_required > 0, "Invalid approval count");
        require(_required <= 10, "Too many required approvals");
        requiredRecoveryApprovals = _required;
    }

    function setEmergencyDelay(uint256 _delay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_delay <= 24 hours, "Delay too long");
        emergencyDelay = _delay;
    }

    function setMaxEmergencyDuration(uint256 _duration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_duration >= 1 hours, "Duration too short");
        require(_duration <= 30 days, "Duration too long");
        maxEmergencyDuration = _duration;
    }

    function setEmergencyWithdrawalsEnabled(bool _enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emergencyWithdrawalsEnabled = _enabled;
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

    // Emergency fund reception
    receive() external payable {
        // Allow contract to receive ETH for emergency recovery
    }

    function emergencyTokenDeposit(address _token, uint256 _amount) external {
        require(_token != address(0), "Invalid token");
        require(IERC20(_token).transferFrom(msg.sender, address(this), _amount), "Transfer failed");
    }
}