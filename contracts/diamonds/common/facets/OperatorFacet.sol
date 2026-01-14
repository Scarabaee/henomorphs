// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibDiamond} from "../../shared/libraries/LibDiamond.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {AccessControlBase} from "./AccessControlBase.sol";

/**
 * @title OperatorFacet
 * @notice Manages operator permissions and pause functionality
 * @dev Uses Ownable pattern through Diamond implementation
 */
contract OperatorFacet is AccessControlBase {
    // Events
    event OperatorStatusChanged(address indexed operator, bool enabled);
    event Paused(address account);
    event Unpaused(address account);
    
    /**
     * @notice Requires caller to be the contract owner
     */
    modifier onlyOwner() {
        if (LibMeta.msgSender() != LibDiamond.contractOwner()) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not contract owner");
        }
        _;
    }
    
    /**
     * @notice Sets operator status for an address
     * @param operator Address to change operator status for
     * @param enabled Whether the address should be an operator
     */
    function setOperator(address operator, bool enabled) external onlyOwner {
        if (operator == address(0)) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        hs.operators[operator] = enabled;
        
        emit OperatorStatusChanged(operator, enabled);
    }
    
    /**
     * @notice Checks if an address is an operator
     * @param operator Address to check
     * @return Whether the address is an operator
     */
    function isOperator(address operator) external view returns (bool) {
        return LibHenomorphsStorage.henomorphsStorage().operators[operator];
    }

    /**
     * @notice Pause the contract (emergency function)
     */
    function pause() external onlyOwner {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        hs.paused = true;
        emit Paused(LibMeta.msgSender());
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyOwner {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        hs.paused = false;
        emit Unpaused(LibMeta.msgSender());
    }

    /**
     * @notice Check if the contract is paused
     * @return Whether the contract is paused
     */
    function isPaused() external view returns (bool) {
        return AccessHelper.isPaused();
    }
}