// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC173} from "../interfaces/IERC173.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol"; 

/**
 * @title Faucet for contract ownership management
 *
 * @author rutilicus.eth (ArchXS)
 * @custom:website https://zicodao.io
 */
contract OwnershipFacet is IERC173 {
    function transferOwnership(address _newOwner) external override {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.setContractOwner(_newOwner);
    }

    function owner() external view override returns (address owner_) {
        owner_ = LibDiamond.contractOwner();
    }
}