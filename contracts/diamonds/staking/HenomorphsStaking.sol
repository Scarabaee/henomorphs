// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibDiamond} from "../shared/libraries/LibDiamond.sol";
import {LibHenomorphsStorage} from "../chargepod/libraries/LibHenomorphsStorage.sol";
import {LibStakingStorage} from "./libraries/LibStakingStorage.sol";
import {LibMeta} from "../shared/libraries/LibMeta.sol";
import {IDiamondCut} from "../shared/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../shared/interfaces/IDiamondLoupe.sol";
import {IERC173} from "../shared/interfaces/IERC173.sol";
import {IERC165} from "../shared/interfaces/IERC165.sol";

/**
 * @title HenomorphsStaking
 * @notice Diamond contract for the Henomorphs staking system
 * @dev Implements EIP-2535 Diamond Pattern for upgradeability with Ownable pattern
 * @dev Full system initialization is performed via StakingDiamondInit.init()
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract HenomorphsStaking {
    // Version constant for tracking
    uint256 public constant DIAMOND_VERSION = 1;

    // Events
    event DiamondCut(IDiamondCut.FacetCut[] _diamondCut, address _init, bytes _calldata);

    // Error definitions
    error FunctionDoesNotExist();

    /**
     * @notice Constructor for the diamond
     * @dev Only sets essential elements: owner and diamondCut function
     * @dev Full initialization is performed through StakingDiamondInit.init()
     * @param _owner Address of the contract owner
     * @param _diamondCutFacet Address of the DiamondCutFacet for initial configuration
     */
    constructor(address _owner, address _diamondCutFacet) {
        // Initialize diamond storage
        LibDiamond.setContractOwner(_owner);
        
        // Add DiamondCut function
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        bytes4[] memory functionSelectors = new bytes4[](1);
        functionSelectors[0] = IDiamondCut.diamondCut.selector;
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: _diamondCutFacet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: functionSelectors
        });
        
        LibDiamond.diamondCut(cuts, address(0), "");
        
        // Register standard interfaces
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.supportedInterfaces[type(IERC165).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondCut).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondLoupe).interfaceId] = true;
        ds.supportedInterfaces[type(IERC173).interfaceId] = true;
        
        // Zabezpieczenie - przypisz tę funkcję jako immutable (nie można jej usunąć)
        bytes4 diamondCutSelector = IDiamondCut.diamondCut.selector;
        ds.selectorToFacetAndPosition[diamondCutSelector].facetAddress = _diamondCutFacet;
    }

    /**
     * @notice Diamond Cut funkcja, która nie może być usunięta
     * @dev Ta funkcja jest zaimplementowana bezpośrednio w diamencie jako zabezpieczenie
     * @dev W przypadku usunięcia wszystkich selektorów, ta funkcja będzie wciąż dostępna
     */
    function diamondCut(
        IDiamondCut.FacetCut[] calldata _diamondCut,
        address _init,
        bytes calldata _calldata
    ) external {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.diamondCut(_diamondCut, _init, _calldata);
    }

    /**
     * @notice Emergency function to withdraw native currency directly from the diamond
     * @dev This is a last resort if facets are compromised
     */
    function emergencyRescueNative() external {
        LibDiamond.enforceIsContractOwner();
        payable(LibDiamond.contractOwner()).transfer(address(this).balance);
    }

    /**
     * @notice Emergency function to rescue ERC20 tokens
     * @dev Critical for recovering tokens that might otherwise be locked forever
     * @param tokenAddress Address of the ERC20 token to rescue
     */
    function emergencyRescueERC20(address tokenAddress) external {
        LibDiamond.enforceIsContractOwner();
        // Simple ERC20 interface for balanceOf and transfer
        (bool successBalance, bytes memory balanceData) = tokenAddress.call(
            abi.encodeWithSignature("balanceOf(address)", address(this))
        );
        require(successBalance, "Failed to get token balance");
        uint256 balance = abi.decode(balanceData, (uint256));
        
        if (balance > 0) {
            (bool successTransfer, ) = tokenAddress.call(
                abi.encodeWithSignature(
                    "transfer(address,uint256)", 
                    LibDiamond.contractOwner(), 
                    balance
                )
            );
            require(successTransfer, "Token transfer failed");
        }
    }

    /**
     * @notice Emergency pause that persists in the main diamond storage
     * @dev This can be used even if facet with pause function is compromised
     */
    function emergencyPause() external {
        LibDiamond.enforceIsContractOwner();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        hs.paused = true;
    }

    /**
     * @notice Emergency unpause function
     * @dev Only callable by contract owner
     */
    function emergencyUnpause() external {
        LibDiamond.enforceIsContractOwner();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        hs.paused = false;
    }

    /**
     * @notice Fallback function handling function delegation to facets
     * @dev Allows direct calls to the diamond itself
     */
    fallback() external payable {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        
        address facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
        if (facet == address(0)) {
            revert FunctionDoesNotExist();
        }
        
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
                case 0 {
                    revert(0, returndatasize())
                }
                default {
                    return(0, returndatasize())
                }
        }
    }

    /**
     * @notice Receive function to accept ETH transfers
     */
    receive() external payable {}
}