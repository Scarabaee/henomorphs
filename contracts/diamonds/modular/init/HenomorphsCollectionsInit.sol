// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibDiamond} from "../../shared/libraries/LibDiamond.sol";
import {LibCollectionStorage} from "../../libraries/LibCollectionStorage.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title HenomorphsCollectionsInit
 * @notice Initialization facet for HenomorphsMatrix Diamond
 * @dev Performs one-time initialization with default configuration
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract HenomorphsCollectionsInit {
    
    uint256 private constant MAX_OPERATORS = 10;
    
    // Default addresses
    address private constant DEFAULT_TREASURY_CURRENCY = 0x486ebcFEe0466Def0302A944Bd6408cD2CB3E806;
    address private constant DEFAULT_TREASURY_ADDRESS = 0x8B4F045d8127E587E3083baBB31D4bC35f0065Cc;
    address private constant DEFAULT_BASE_PRICE_FEED = 0xAB594600376Ec9fD91F8e885dADF0CE036862dE0;
    address private constant DEFAULT_QUOTE_PRICE_FEED = 0xB34BCE11040702f71c11529D00179B2959BcE6C0;
    
    struct InitParams {
        address contractOwner;
        address biopodAddress;
        address chargepodAddress;
        address stakingSystemAddress;
        bool paused;
        address[] initialOperators;
    }
    
    event InitializationComplete(address indexed owner, uint256 timestamp);
    
    error AlreadyInitialized();
    error InvalidAddress();
    error InvalidParameter();
    error TooManyOperators();

    function init(InitParams calldata params) external {
        LibDiamond.enforceIsContractOwner();
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        if (cs.contractOwner != address(0)) {
            revert AlreadyInitialized();
        }
        
        // Basic validation
        if (params.contractOwner == address(0)) revert InvalidAddress();
        if (params.initialOperators.length > MAX_OPERATORS) revert TooManyOperators();
        
        // Core setup
        cs.contractOwner = params.contractOwner;
        cs.paused = params.paused;
        
        // External systems
        cs.biopodAddress = params.biopodAddress;
        cs.chargepodAddress = params.chargepodAddress;
        cs.stakingSystemAddress = params.stakingSystemAddress;
        
        // Treasury defaults
        cs.systemTreasury.treasuryAddress = DEFAULT_TREASURY_ADDRESS;
        cs.systemTreasury.treasuryCurrency = DEFAULT_TREASURY_CURRENCY;
        
        // Price feeds defaults
        cs.currencyExchange.basePriceFeed = AggregatorV3Interface(DEFAULT_BASE_PRICE_FEED);
        cs.currencyExchange.quotePriceFeed = AggregatorV3Interface(DEFAULT_QUOTE_PRICE_FEED);
        cs.currencyExchange.baseDecimals = 8;
        cs.currencyExchange.quoteDecimals = 8;
        cs.currencyExchange.isActive = true;
        cs.currencyExchange.lastUpdateTime = block.timestamp;
        
        // Operators
        for (uint256 i = 0; i < params.initialOperators.length; i++) {
            if (params.initialOperators[i] != address(0)) {
                cs.operators[params.initialOperators[i]] = true;
            }
        }
        
        // Initialize counters
        cs.collectionCounter = 0;
        
        emit InitializationComplete(params.contractOwner, block.timestamp);
    }

    function getInitializationStatus() external view returns (bool initialized, address owner) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        return (cs.contractOwner != address(0), cs.contractOwner);
    }
    
    function createDefaultParams(
        address owner,
        string calldata baseURI_
    ) external pure returns (InitParams memory) {
        if (owner == address(0)) revert InvalidAddress();
        if (bytes(baseURI_).length == 0) revert InvalidParameter();
        
        return InitParams({
            contractOwner: owner,
            biopodAddress: address(0),
            chargepodAddress: address(0),
            stakingSystemAddress: address(0),
            paused: false,
            initialOperators: new address[](0)
        });
    }
}