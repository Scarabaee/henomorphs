// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title EnhancedReentrancyGuard
 * @notice Improved reentrancy protection for all state-modifying functions
 * @dev Supports function-specific and contract-specific locks
 */
library ReentrancyGuard {
    // Storage slot for reentrancy guard
    bytes32 constant REENTRANCY_GUARD_STORAGE = keccak256("enhanced.reentrancy.guard.storage");

    // Error for reentrancy detection
    error ReentrancyGuardReentrantCall();
    
    // Reentrancy status enum
    enum ReentrancyStatus {
        NotEntered,
        Entered
    }
    
    // Reentrancy storage structure
    struct ReentrancyStorage {
        // Global reentrancy lock
        ReentrancyStatus status;
        // Function-specific locks (selector => lock status)
        mapping(bytes4 => ReentrancyStatus) functionLocks;
        // Contract-specific locks (contract address => lock status)
        mapping(address => ReentrancyStatus) contractLocks;
    }
    
    // Access reentrancy storage
    function getStorage() internal pure returns (ReentrancyStorage storage rs) {
        bytes32 position = REENTRANCY_GUARD_STORAGE;
        assembly {
            rs.slot := position
        }
    }
    
    /**
     * @dev Prevents global reentrancy
     */
    function nonReentrantBefore() internal {
        ReentrancyStorage storage rs = getStorage();
        
        // Check global status
        if (rs.status == ReentrancyStatus.Entered) {
            revert ReentrancyGuardReentrantCall();
        }
        
        // Set locked status
        rs.status = ReentrancyStatus.Entered;
    }
    
    /**
     * @dev Releases global reentrancy lock
     */
    function nonReentrantAfter() internal {
        ReentrancyStorage storage rs = getStorage();
        
        // Reset locked status
        rs.status = ReentrancyStatus.NotEntered;
    }
    
    /**
     * @dev Prevents reentrancy for a specific function
     * @param functionSelector Function selector to protect
     */
    function guardFunction(bytes4 functionSelector) internal {
        ReentrancyStorage storage rs = getStorage();
        
        // Check global status
        if (rs.status == ReentrancyStatus.Entered) {
            revert ReentrancyGuardReentrantCall();
        }
        
        // Check function-specific status
        if (rs.functionLocks[functionSelector] == ReentrancyStatus.Entered) {
            revert ReentrancyGuardReentrantCall();
        }
        
        // Set locked status
        rs.status = ReentrancyStatus.Entered;
        rs.functionLocks[functionSelector] = ReentrancyStatus.Entered;
    }
    
    /**
     * @dev Releases reentrancy lock after function execution
     * @param functionSelector Function selector to unlock
     */
    function releaseFunction(bytes4 functionSelector) internal {
        ReentrancyStorage storage rs = getStorage();
        
        // Reset locked status
        rs.status = ReentrancyStatus.NotEntered;
        rs.functionLocks[functionSelector] = ReentrancyStatus.NotEntered;
    }
    
    /**
     * @dev Prevents reentrancy for a specific contract
     * @param targetContract Contract address to protect
     */
    function guardContract(address targetContract) internal {
        ReentrancyStorage storage rs = getStorage();
        
        // Check contract-specific status
        if (rs.contractLocks[targetContract] == ReentrancyStatus.Entered) {
            revert ReentrancyGuardReentrantCall();
        }
        
        // Set locked status
        rs.contractLocks[targetContract] = ReentrancyStatus.Entered;
    }
    
    /**
     * @dev Releases reentrancy lock for a contract
     * @param targetContract Contract address to unlock
     */
    function releaseContract(address targetContract) internal {
        ReentrancyStorage storage rs = getStorage();
        
        // Reset locked status
        rs.contractLocks[targetContract] = ReentrancyStatus.NotEntered;
    }
}