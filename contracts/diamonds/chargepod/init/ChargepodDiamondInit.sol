// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibDiamond} from "../../shared/libraries/LibDiamond.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDiamondLoupe} from "../../shared/interfaces/IDiamondLoupe.sol";
import {IDiamondCut} from "../../shared/interfaces/IDiamondCut.sol";
import {IERC173} from "../../shared/interfaces/IERC173.sol";
import {IERC165} from "../../shared/interfaces/IERC165.sol";
import {ChargeSettings, ControlFee, ChargeFees, ChargeActionType, ChargeSeason} from "../../libraries/HenomorphsModel.sol";

/**
 * @title ChargepodDiamondInit
 * @notice Initialization contract for HenomorphsChargepod Diamond
 * @dev Used ONCE in diamondCut for initial setup of the diamond
  * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract ChargepodDiamondInit {
    // ZICO token address for fees
    address private constant ZICO_ADDRESS = 0x486ebcFEe0466Def0302A944Bd6408cD2CB3E806;
    
    // Events
    event StorageInitialized(address beneficiary);
    event OperatorApproved(address operator, bool approved);
    event SeasonStarted(uint256 seasonId, string theme);
    event StorageVersion(uint256 version);
    event ModulesConfigured(address chargeModule, address traitsModule, address configModule, address stakingModule);
    event ModuleRegistryInitialized();
    
    /**
     * @notice Initializes the diamond contract state with comprehensive configuration
     * @param admin Admin address who will be set as an operator
     *  function init(address admin, address beneficiary) external {
     */
    function init(address admin, address) external {
        require(admin != address(0), "Admin cannot be zero address");
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Set storage version - useful for tracking and migrations
        hs.storageVersion = 1;
        emit StorageVersion(1);
        
        // Initialize operator status - use simple operator mapping
        if (admin != LibDiamond.contractOwner()) {
            hs.operators[admin] = true;
            emit OperatorApproved(admin, true);
        }
        
        // Initialize default charge settings
        _initializeChargeSettings(hs);
        
        // Initialize fee structure
        // _initializeFees(hs, beneficiary);
        
        // Initialize action types
        // _initializeActionTypes(hs, admin);
        
        // Initialize first season
        // _initializeSeason(hs);
        
        // Initial module discovery and setup - done only once during deployment
        _detectAndConfigureModules(hs);
        
        // Initialize module registry for later verification
        _initializeModulesRegistry(hs);
        
        emit StorageInitialized(admin);
    }
    
    /**
     * @notice Initialize charge settings
     * @param hs Storage reference
     */
    function _initializeChargeSettings(LibHenomorphsStorage.HenomorphsStorage storage hs) private {
        hs.chargeSettings = ChargeSettings({
            baseRegenRate: 5,           // 5 points per hour
            fatigueIncreaseRate: 10,    // +10 fatigue per action
            fatigueRecoveryRate: 2,     // -2 fatigue per hour
            maxConsecutiveActions: 5,   // 5 consecutive actions before additional fatigue
            chargeEventBonus: 20        // 20% bonus during events
        });
    }
    
    /**
     * @notice Initialize fees
     * @param hs Storage reference
     * @param _beneficiary Fees beneficiary
     */
    // function _initializeFees(LibHenomorphsStorage.HenomorphsStorage storage hs, address _beneficiary) private {
    //     // Define control fees with the correct structure
    //     hs.chargeFees = ChargeFees({
    //         repairFee: ControlFee({
    //             currency: IERC20(ZICO_ADDRESS),
    //             amount: 1 ether,
    //             beneficiary: _beneficiary
    //         }),
    //         boostFee: ControlFee({
    //             currency: IERC20(ZICO_ADDRESS),
    //             amount: 5 ether,
    //             beneficiary: _beneficiary
    //         }),
    //         specializationFee: ControlFee({
    //             currency: IERC20(ZICO_ADDRESS),
    //             amount: 10 ether,
    //             beneficiary: _beneficiary
    //         }),
    //         accessoryBaseFee: ControlFee({
    //             currency: IERC20(ZICO_ADDRESS),
    //             amount: 20 ether,
    //             beneficiary: _beneficiary
    //         }),
    //         accessoryRareFee: ControlFee({
    //             currency: IERC20(ZICO_ADDRESS),
    //             amount: 30 ether,
    //             beneficiary: _beneficiary
    //         }),
    //         colonyFormationFee: ControlFee({
    //             currency: IERC20(ZICO_ADDRESS),
    //             amount: 20 ether,
    //             beneficiary: _beneficiary
    //         }),
    //         colonyMembershipFee: ControlFee({ // NEW: Initialize colony membership fee
    //             currency: IERC20(ZICO_ADDRESS),
    //             amount: 5 ether, // Set to 5 ZICO tokens - can be adjusted as needed
    //             beneficiary: _beneficiary
    //         })
    //     });
    // }
    
    /**
     * @notice Initialize action types
     * @param hs Storage reference
     * @param _beneficiary Fees beneficiary
     */
    // function _initializeActionTypes(LibHenomorphsStorage.HenomorphsStorage storage hs, address _beneficiary) private {
    //     // Initialize default action types
    //     for (uint8 i = 1; i <= 5; i++) {
    //         uint256 baseFeeAmount = 0.001 ether * i; // Increasing fee per action type
            
    //         hs.actionTypes[i] = ChargeActionType({
    //             baseCost: ControlFee({
    //                 currency: IERC20(ZICO_ADDRESS),
    //                 amount: baseFeeAmount,
    //                 beneficiary: _beneficiary
    //             }),
    //             actionCategory: i,                // Each type has its own category
    //             cooldown: 3600 * i,               // Increasing cooldowns per type
    //             rewardMultiplier: 100 + (i * 10), // Increasing rewards per type
    //             special: i >= 4                   // Types 4-5 are special
    //         });
    //     }
    // }
    
    /**
     * @notice Initialize season
     * @param hs Storage reference
     */
    // function _initializeSeason(LibHenomorphsStorage.HenomorphsStorage storage hs) private {
    //     hs.seasonCounter = 1;
    //     hs.currentSeason = ChargeSeason({
    //         startTime: uint32(block.timestamp),
    //         endTime: uint32(block.timestamp + 90 days),
    //         chargeBoostPercentage: 10, // 10% base season bonus
    //         theme: "Genesis Season",
    //         active: true
    //     });
        
    //     // Initialize global event bonus
    //     hs.chargeEventBonus = 20; // 20% default bonus
        
    //     emit SeasonStarted(1, "Genesis Season");
    // }
    
    /**
     * @notice Initial module discovery during deployment
     * @param hs Storage reference
     * @dev Called ONCE during diamond initialization
     */
    function _detectAndConfigureModules(LibHenomorphsStorage.HenomorphsStorage storage hs) private {
        // Get the IDiamondLoupe interface for this contract
        IDiamondLoupe diamondLoupe = IDiamondLoupe(address(this));
        
        // Define function selectors to identify each module
        bytes4 chargeSelector = bytes4(keccak256("performAction(uint256,uint256,uint8)"));
        bytes4 traitsSelector = bytes4(keccak256("getTokenTraitPacks(uint256,uint256)"));
        bytes4 configSelector = bytes4(keccak256("setChargeSettings(ChargeSettings)"));
        
        // Configure core modules
        hs.internalModules.chargeModuleAddress = diamondLoupe.facetAddress(chargeSelector);
        hs.internalModules.traitsModuleAddress = diamondLoupe.facetAddress(traitsSelector);
        hs.internalModules.configModuleAddress = diamondLoupe.facetAddress(configSelector);
        
        // Staking module address will be set later via ChargeConfigurationFacet
        
        emit ModulesConfigured(
            hs.internalModules.chargeModuleAddress,
            hs.internalModules.traitsModuleAddress,
            hs.internalModules.configModuleAddress,
            address(0) // stakingModule not yet set
        );
    }

    /**
     * @notice Setup module registry for interface verification
     * @param hs Storage reference
     * @dev Called ONCE during diamond initialization
     */
    function _initializeModulesRegistry(LibHenomorphsStorage.HenomorphsStorage storage hs) private {
        // Charge Module
        bytes4[] memory chargeSelectors = new bytes4[](2);
        chargeSelectors[0] = bytes4(keccak256("performAction(uint256,uint256,uint8)"));
        chargeSelectors[1] = bytes4(keccak256("recalibrateCore(uint256,uint256)"));
        hs.modulesRegistry.expectedSelectors["charge"] = chargeSelectors;
        
        // Traits Module
        bytes4[] memory traitsSelectors = new bytes4[](2);
        traitsSelectors[0] = bytes4(keccak256("getTokenTraitPacks(uint256,uint256)"));
        traitsSelectors[1] = bytes4(keccak256("checkAccessoryCompatibility(uint8,uint8)"));
        hs.modulesRegistry.expectedSelectors["traits"] = traitsSelectors;
        
        // Config Module
        bytes4[] memory configSelectors = new bytes4[](2);
        configSelectors[0] = bytes4(keccak256("setChargeSettings(ChargeSettings)"));
        configSelectors[1] = bytes4(keccak256("collectFee(ControlFee,uint256,address)"));
        hs.modulesRegistry.expectedSelectors["config"] = configSelectors;
        
        // No selectors for staking module since it doesn't have a dedicated facet
        
        // Set initial verification timestamp and result
        hs.modulesRegistry.lastVerificationTimestamp = block.timestamp;
        hs.modulesRegistry.lastVerificationResult = true;
        
        emit ModuleRegistryInitialized();
    }
}