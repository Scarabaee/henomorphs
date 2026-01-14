// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {AccessControlBase} from "./AccessControlBase.sol";

/**
 * @title PausableFacet
 * @notice Provides pausable functionality for the diamond
 * @dev The pause state is stored in the LibHenomorphsStorage for persistence
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract PausableFacet is AccessControlBase {
    // Events
    event ContractPaused();
    event ContractUnpaused();
    
    /**
     * @notice Pause the contract system
     * @dev Only callable by authorized roles
     */
    function pause() external onlyAuthorized {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        hs.paused = true;
        emit ContractPaused();
    }
    
    /**
     * @notice Unpause the contract system
     * @dev Only callable by authorized roles
     */
    function unpause() external onlyAuthorized {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        hs.paused = false;
        emit ContractUnpaused();
    }
    
    /**
     * @notice Check if the contract system is paused
     * @return Whether the system is currently paused
     */
    function isPaused() external view returns (bool) {
        return LibHenomorphsStorage.henomorphsStorage().paused;
    }
}