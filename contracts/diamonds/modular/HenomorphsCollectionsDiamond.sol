// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibDiamond} from "../shared/libraries/LibDiamond.sol";
import {LibCollectionStorage} from "../libraries/LibCollectionStorage.sol";
import {IDiamondCut} from "../shared/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../shared/interfaces/IDiamondLoupe.sol";
import {IERC173} from "../shared/interfaces/IERC173.sol";
import {IERC165} from "../shared/interfaces/IERC165.sol"; 

/**
 * @title HenomorphsAugmentsDiamondNo1
 * @notice Diamond contract for the Henomorphs Augments collection management system
 * @dev Implements EIP-2535 Diamond Pattern for modular NFT collection management
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract HenomorphsCollectionsDiamond {
    // Version constants
    uint256 public constant DIAMOND_VERSION = 1;
    string public constant DIAMOND_NAME = "HenomorphsCollections";

    // Events
    event DiamondCut(IDiamondCut.FacetCut[] _diamondCut, address _init, bytes _calldata);
    event EmergencyAction(string indexed action, address indexed executor, uint256 amount);

    // Custom errors
    error FunctionDoesNotExist(bytes4 selector);
    error EmergencyActionFailed(string reason);
    error InvalidConstructorParams();

    /**
     * @notice Constructor for the diamond
     * @param _owner Address of the contract owner
     * @param _diamondCutFacet Address of the DiamondCutFacet
     */
    constructor(address _owner, address _diamondCutFacet) {
        if (_owner == address(0) || _diamondCutFacet == address(0)) {
            revert InvalidConstructorParams();
        }
        
        // Verify diamondCutFacet is a contract
        uint256 size;
        assembly {
            size := extcodesize(_diamondCutFacet)
        }
        if (size == 0) {
            revert InvalidConstructorParams();
        }

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
        
        emit EmergencyAction("DiamondInitialized", _owner, 0);
    }

    /**
     * @notice Diamond Cut function that cannot be removed
     * @param _diamondCut Array of facet cuts to perform
     * @param _init Address of contract to call for initialization
     * @param _calldata Calldata for initialization
     */
    function diamondCut(
        IDiamondCut.FacetCut[] calldata _diamondCut,
        address _init,
        bytes calldata _calldata
    ) external {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.diamondCut(_diamondCut, _init, _calldata);
        emit DiamondCut(_diamondCut, _init, _calldata);
    }

    /**
     * @notice Emergency function to withdraw native currency
     * @dev Last resort if facets are compromised
     */
    function emergencyRescueNative() external {
        LibDiamond.enforceIsContractOwner();
        
        uint256 balance = address(this).balance;
        if (balance == 0) {
            revert EmergencyActionFailed("No balance to rescue");
        }

        address _owner = LibDiamond.contractOwner();
        (bool success, ) = payable(_owner).call{value: balance}("");
        if (!success) {
            revert EmergencyActionFailed("Transfer failed");
        }
        
        emit EmergencyAction("NativeRescued", _owner, balance);
    }

    /**
     * @notice Emergency function to rescue ERC20 tokens
     * @param tokenAddress Address of the ERC20 token to rescue
     */
    function emergencyRescueERC20(address tokenAddress) external {
        LibDiamond.enforceIsContractOwner();
        
        if (tokenAddress == address(0)) {
            revert EmergencyActionFailed("Invalid token address");
        }
        
        // Check if it's a contract
        uint256 size;
        assembly {
            size := extcodesize(tokenAddress)
        }
        if (size == 0) {
            revert EmergencyActionFailed("Not a contract");
        }

        // Get balance
        (bool successBalance, bytes memory balanceData) = tokenAddress.staticcall(
            abi.encodeWithSignature("balanceOf(address)", address(this))
        );
        if (!successBalance) {
            revert EmergencyActionFailed("Failed to get token balance");
        }
        
        uint256 balance = abi.decode(balanceData, (uint256));
        if (balance == 0) {
            revert EmergencyActionFailed("No tokens to rescue");
        }

        // Transfer tokens
        (bool successTransfer, ) = tokenAddress.call(
            abi.encodeWithSignature(
                "transfer(address,uint256)", 
                LibDiamond.contractOwner(), 
                balance
            )
        );
        if (!successTransfer) {
            revert EmergencyActionFailed("Token transfer failed");
        }
        
        emit EmergencyAction("ERC20Rescued", LibDiamond.contractOwner(), balance);
    }

    /**
     * @notice Emergency pause function
     */
    function emergencyPause() external {
        LibDiamond.enforceIsContractOwner();
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        cs.paused = true;
        emit EmergencyAction("EmergencyPaused", LibDiamond.contractOwner(), 0);
    }

    /**
     * @notice Emergency unpause function
     */
    function emergencyUnpause() external {
        LibDiamond.enforceIsContractOwner();
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        cs.paused = false;
        emit EmergencyAction("EmergencyUnpaused", LibDiamond.contractOwner(), 0);
    }

    /**
     * @notice Get diamond information
     * @return version Diamond version
     * @return name Diamond name
     */
    function getDiamondInfo() external pure returns (uint256 version, string memory name) {
        return (DIAMOND_VERSION, DIAMOND_NAME);
    }

    /**
     * @notice Check if system is paused
     * @return Whether system is currently paused
     */
    function isPaused() external view returns (bool) {
        return LibCollectionStorage.collectionStorage().paused;
    }

    /**
     * @notice Get contract owner
     * @return Owner address
     */
    function owner() external view returns (address) {
        return LibDiamond.contractOwner();
    }

    /**
     * @notice Fallback function for delegating calls to facets
     */
    fallback() external payable {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        
        address facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
        if (facet == address(0)) {
            revert FunctionDoesNotExist(msg.sig);
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