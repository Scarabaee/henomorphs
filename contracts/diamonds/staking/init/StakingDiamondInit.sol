// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibDiamond} from "../../shared/libraries/LibDiamond.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibStakingStorage} from "../libraries/LibStakingStorage.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PodRewardRate, InfusionBonus, StakingFees, SeasonRewardMultiplier, SpecialEvent, RateLimits} from "../../libraries/StakingModel.sol";
import {ControlFee} from "../../libraries/HenomorphsModel.sol";

/**
 * @title StakingDiamondInit
 * @notice Comprehensive initializer for staking diamond with enhanced fee handling
 * @dev Used in diamondCut to initialize the staking diamond
 */
contract StakingDiamondInit {
    // Custom errors
    error ZeroAddress();
    error InvalidToken();
    error InvalidTreasury();
    error InvalidAdmin();
    
    // Events
    event StorageInitialized(address treasury);
    event OperatorApproved(address operator, bool approved);
    event StakingConfigured(uint256 baseAPR, uint256 version);
    event SeasonStarted(uint256 seasonId, uint256 multiplier);
    event StorageVersion(uint256 version);
    event ModuleRegistryInitialized();
    event StakingFeesInitialized(address feeToken, address beneficiary); 
    event WearRepairFeeInitialized(uint256 costPerPoint, address beneficiary);
    event PowerCoreRequirementsInitialized(bool required);
    event RateLimitsInitialized();

    /**
     * @notice Initializes the state of the diamond contract with comprehensive configuration
     * @param zicoToken Address of the ZICO token
     * @param treasury Address of the treasury for fees
     * @param admin Address of the administrator to set as operator
     * @param chargepodAddress Address of the Chargepod system for integration
     */
    function init(address zicoToken, address treasury, address admin, address chargepodAddress) external {
        // Validate addresses
        if (admin == address(0)) revert InvalidAdmin();
        if (treasury == address(0)) revert InvalidTreasury();
        if (zicoToken == address(0)) revert InvalidToken();
        if (chargepodAddress == address(0)) revert ZeroAddress();
        
        // Initialize basic storage settings
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Set storage version - useful for tracking and migration
        ss.storageVersion = 1;
        emit StorageVersion(1);
        
        // Set admin as operator if not the owner
        if (admin != LibDiamond.contractOwner()) {
            hs.operators[admin] = true;
            emit OperatorApproved(admin, true);
        }
        
        // Enable staking and set ZICO token
        ss.stakingEnabled = true;
        ss.zicoToken = IERC20(zicoToken);
        
        // Initialize staking settings
        _initializeStakingSettings(ss, treasury);
        
        // Initialize base reward rates
        _initializeBaseRewardRates(ss);
        
        // Initialize level multipliers
        _initializeLevelMultipliers(ss);
        
        // Initialize infusion settings
        _initializeInfusionSettings(ss);
        
        // Initialize wear system
        _initializeWearSystem(ss, treasury);
        
        // Initialize season
        _initializeSeason(ss);
        
        // Initialize module registry with provided chargepod address
        _initializeModuleRegistry(ss, chargepodAddress);
        
        // Initialize default fees
        _initializeDefaultFees(ss, treasury);
        
        // Initialize Power Core requirements
        _initializePowerCoreRequirements(ss);
        
        // Initialize rate limits
        _initializeRateLimits(ss);
        
        // Set Chargepod address for direct integration
        ss.chargeSystemAddress = chargepodAddress;
        
        emit StorageInitialized(treasury);
        emit StakingConfigured(ss.settings.baseInfusionAPR, 1);
    }

    /**
     * @notice Initialize staking settings with core parameters
     * @param ss Reference to staking storage
     * @param treasury Treasury address
     */
    function _initializeStakingSettings(LibStakingStorage.StakingStorage storage ss, address treasury) private {
        // Set treasury address
        ss.settings.treasuryAddress = treasury;
        
        // Set time periods
        ss.settings.minimumStakingPeriod = 1 days;  // Minimum 1 day
        ss.settings.minInfusionAmount = 10 ether;   // Minimum 10 ZICO
        ss.settings.earlyUnstakingFeePercentage = 10; // 10% penalty
        ss.settings.stakingCooldown = 6 hours;      // 6 hours cooldown
        
        // Initialize loyalty bonuses
        ss.settings.loyaltyBonusThresholds[30] = 5;   // 5% after 30 days
        ss.settings.loyaltyBonusThresholds[90] = 10;  // 10% after 90 days
        ss.settings.loyaltyBonusThresholds[180] = 15; // 15% after 180 days
        ss.settings.loyaltyBonusThresholds[365] = 25; // 25% after 365 days
        
        // Set token limits per staker (0 = unlimited)
        ss.settings.maxTokensPerStaker = 0;  // No limit on tokens per staker

        // Initialize vault configuration - defaults to treasury address as required
        ss.vaultConfig = LibStakingStorage.VaultConfig({
            useExternalVault: true,    // Default to using the diamond itself
            vaultAddress: treasury      // Default to the same address as treasury
        });
    
    }
    
    /**
     * @notice Initialize base reward rates for variants 1-4
     * @param ss Reference to staking storage
     */
    function _initializeBaseRewardRates(LibStakingStorage.StakingStorage storage ss) private {
        // Initialize base rates for variants 1-4 (UPDATED VALUES)
        uint256[] memory baseRates = new uint256[](4);
        baseRates[0] = 0.75 ether; // 0.75 ZICO daily for variant 1
        baseRates[1] = 1.5 ether;  // 1.5 ZICO daily for variant 2
        baseRates[2] = 2.5 ether;  // 2.5 ZICO daily for variant 3
        baseRates[3] = 4 ether;    // 4 ZICO daily for variant 4
        
        // Set base rates
        for (uint8 i = 0; i < 4; i++) {
            ss.settings.baseRewardRates.push(baseRates[i]);
        }
    }
    
    /**
     * @notice Initialize level multipliers
     * @param ss Reference to staking storage
     */
    function _initializeLevelMultipliers(LibStakingStorage.StakingStorage storage ss) private {
        // Initialize level multipliers (UPDATED VALUES)
        uint256[] memory levelMultipliers = new uint256[](5);
        levelMultipliers[0] = 100; // 100% for levels 1-10
        levelMultipliers[1] = 130; // 130% for levels 11-25
        levelMultipliers[2] = 160; // 160% for levels 26-50
        levelMultipliers[3] = 190; // 190% for levels 51-75
        levelMultipliers[4] = 225; // 225% for levels 76+
        
        for (uint8 i = 0; i < 5; i++) {
            ss.settings.levelRewardMultipliers.push(levelMultipliers[i]);
        }
    }
    
    /**
     * @notice Initialize infusion settings
     * @param ss Reference to staking storage
     */
    function _initializeInfusionSettings(LibStakingStorage.StakingStorage storage ss) private {
        // Initialize infusion settings (UPDATED VALUES)
        ss.settings.baseInfusionAPR = 20; // 20% APR
        ss.settings.bonusInfusionAPRPerVariant = 5; // +5% per variant
        
        // Initialize infusion bonuses by level
        ss.settings.infusionBonuses[1] = 10;  // 10% bonus for level 1
        ss.settings.infusionBonuses[2] = 15;  // 15% bonus for level 2
        ss.settings.infusionBonuses[3] = 20;  // 20% bonus for level 3
        ss.settings.infusionBonuses[4] = 25;  // 25% bonus for level 4
        ss.settings.infusionBonuses[5] = 35;  // 35% bonus for level 5
        
        // Initialize max infusion by variant
        ss.settings.baseMaxInfusionByVariant[1] = 100 ether; // 100 ZICO for variant 1
        ss.settings.baseMaxInfusionByVariant[2] = 200 ether; // 200 ZICO for variant 2
        ss.settings.baseMaxInfusionByVariant[3] = 350 ether; // 350 ZICO for variant 3
        ss.settings.baseMaxInfusionByVariant[4] = 500 ether; // 500 ZICO for variant 4
    }
    
    /**
     * @notice Initialize wear system with standardized fee handling
     * @param ss Reference to staking storage
     * @param treasury Treasury address for fees
     */
    function _initializeWearSystem(LibStakingStorage.StakingStorage storage ss, address treasury) private {
        // Initialize wear system with optimized values
        ss.wearAutoRepairEnabled = true;
        ss.wearAutoRepairThreshold = 85; // Increased from 75%
        ss.wearAutoRepairAmount = 25;
        ss.wearRepairCostPerPoint = 0.0075 ether; // Reduced by 25% from 0.01 ZICO
        
        // Set reduced wear increase rate
        ss.wearIncreasePerDay = 4; // Assuming original is 5, reduced by 20%
        
        // Set default wear thresholds and penalties
        ss.wearPenaltyThresholds.push(30);
        ss.wearPenaltyThresholds.push(50);
        ss.wearPenaltyThresholds.push(70);
        ss.wearPenaltyThresholds.push(90);
        
        ss.wearPenaltyValues.push(5);
        ss.wearPenaltyValues.push(15);
        ss.wearPenaltyValues.push(30);
        ss.wearPenaltyValues.push(50);
        
        emit WearRepairFeeInitialized(ss.wearRepairCostPerPoint, treasury);
    }
    
    /**
     * @notice Initialize default season
     * @param ss Reference to staking storage
     */
    function _initializeSeason(LibStakingStorage.StakingStorage storage ss) private {
        // Initialize default season
        ss.currentSeason = SeasonRewardMultiplier({
            seasonId: 1,
            multiplier: 20, // 20% (default)
            active: true
        });
        
        emit SeasonStarted(1, 100);
    }

    /**
     * @notice Initialize module registry with dynamic Chargepod address
     * @param ss Reference to staking storage
     * @param chargepodAddress Address of the Chargepod system
     */
    function _initializeModuleRegistry(LibStakingStorage.StakingStorage storage ss, address chargepodAddress) private {
        // Initialize module registry
        ss.moduleRegistry.lastVerificationTimestamp = block.timestamp;
        ss.moduleRegistry.lastVerificationResult = true;
        
        // Set up external modules with provided chargepod address
        ss.externalModules.chargeModuleAddress = chargepodAddress;
        ss.externalModules.queryModuleAddress = chargepodAddress;
        ss.externalModules.accessoryModuleAddress = chargepodAddress;
        ss.externalModules.biopodModuleAddress = chargepodAddress;
        ss.externalModules.colonyModuleAddress = chargepodAddress;
        ss.externalModules.specializationModuleAddress = chargepodAddress;
        
        // Set up internal modules template
        ss.internalModules.coreModuleAddress = address(this);
        ss.internalModules.biopodModuleAddress = address(this);
        ss.internalModules.wearModuleAddress = address(this);
        ss.internalModules.integrationModuleAddress = address(this);
        ss.internalModules.colonyModuleAddress = address(this);
        
        emit ModuleRegistryInitialized();
    }

    /**
     * @notice Initialize Power Core requirements configuration
     * @param ss Reference to staking storage
     */
    function _initializePowerCoreRequirements(LibStakingStorage.StakingStorage storage ss) private {
        // By default, don't require power core for staking
        // This can be changed later by governance if needed
        ss.requirePowerCoreForStaking = true;
        
        emit PowerCoreRequirementsInitialized(true);
    }
    
    /**
    * @notice Initialize rate limits to support the existing check in unstakeSpecimen
    * @param ss Reference to staking storage
    */
    function _initializeRateLimits(LibStakingStorage.StakingStorage storage ss) private {
        // Initialize unstake limit to match the one already used in the function
        bytes4 unstakeSelector = bytes4(keccak256("unstakeSpecimen(uint256,uint256)"));
        
        // Set values matching what's already checked in the unstakeSpecimen function
        ss.rateLimits[address(0)][unstakeSelector] = RateLimits({
            maxOperations: 5,
            windowDuration: 1 hours,
            windowStart: 0,
            operationCount: 0
        });
        
        // Add a limit for claimAllRewards as it could be computationally expensive
        bytes4 claimAllSelector = bytes4(keccak256("claimAllRewards()"));
        ss.rateLimits[address(0)][claimAllSelector] = RateLimits({
            maxOperations: 3,
            windowDuration: 1 hours,
            windowStart: 0,
            operationCount: 0
        });
        
        emit RateLimitsInitialized();
    }

    /**
     * @notice Initialize default staking fees
     * @param ss Reference to staking storage
     * @param treasury Treasury address (fee beneficiary)
     */
    function _initializeDefaultFees(LibStakingStorage.StakingStorage storage ss, address treasury) private {
        // Set moderate fees to encourage system usage
        
        // Stake fee - no fee to encourage entry into the system
        uint256 stakeFeeAmount = 0.5 ether;
        
        // Unstake fee - small fee, 1 ZICO
        uint256 unstakeFeeAmount = 1 ether; 
        
        // Infusion fee - slightly higher due to potential larger rewards, 1 ZICO
        uint256 infusionFeeAmount = 1 ether;
        
        // Claim fee - very small to encourage frequent claiming, 1 ZICO
        uint256 claimFeeAmount = 1 ether; 
        
        // Harvest fee - same as claim fee, 1 ZICO
        uint256 harvestFeeAmount = 1 ether;
        
        // Withdrawal fee - same as unstake fee, 1 ZICO
        uint256 withdrawalFeeAmount = 1 ether;
        
        // Reinvest fee - lower than regular infusion to encourage reinvestment, 0.5 ZICO
        uint256 reinvestFeeAmount = 0.5 ether;

        // Colony creation fee - high since it's an advanced feature, 20 ZICO
        uint256 colonyCreationFeeAmount = 20 ether;
        
        // Colony membership fee for joining/leaving - moderate fee, 5 ZICO
        uint256 colonyMembershipFeeAmount = 5 ether;
        
        // Set fee beneficiary - default to treasury
        address beneficiary = treasury;
        
        // Configure fees in enhanced StakingFees structure
        // CRITICAL: Order must match StakingFees struct definition in StakingModel.sol:
        // 1. unstakeFee, 2. infusionFee, 3. claimFee, 4. colonyCreationFee,
        // 5. wearRepairFee, 6. colonyMembershipFee, 7. stakeFee, 8. harvestFee,
        // 9. withdrawalFee, 10. reinvestFee
        ss.fees = StakingFees({
            unstakeFee: ControlFee({
                currency: ss.zicoToken,
                amount: unstakeFeeAmount,
                beneficiary: beneficiary,
                burnOnCollect: true
            }),
            infusionFee: ControlFee({
                currency: ss.zicoToken,
                amount: infusionFeeAmount,
                beneficiary: beneficiary,
                burnOnCollect: true
            }),
            claimFee: ControlFee({
                currency: ss.zicoToken,
                amount: claimFeeAmount,
                beneficiary: beneficiary,
                burnOnCollect: true
            }),
            colonyCreationFee: ControlFee({
                currency: ss.zicoToken,
                amount: colonyCreationFeeAmount,
                beneficiary: beneficiary,
                burnOnCollect: true
            }),
            wearRepairFee: ControlFee({
                currency: ss.zicoToken,
                amount: 0, // Amount is managed through wearRepairCostPerPoint
                beneficiary: beneficiary,
                burnOnCollect: true
            }),
            colonyMembershipFee: ControlFee({
                currency: ss.zicoToken,
                amount: colonyMembershipFeeAmount,
                beneficiary: beneficiary,
                burnOnCollect: true
            }),
            stakeFee: ControlFee({
                currency: ss.zicoToken,
                amount: stakeFeeAmount,
                beneficiary: beneficiary,
                burnOnCollect: true
            }),
            harvestFee: ControlFee({
                currency: ss.zicoToken,
                amount: harvestFeeAmount,
                beneficiary: beneficiary,
                burnOnCollect: true
            }),
            withdrawalFee: ControlFee({
                currency: ss.zicoToken,
                amount: withdrawalFeeAmount,
                beneficiary: beneficiary,
                burnOnCollect: true
            }),
            reinvestFee: ControlFee({
                currency: ss.zicoToken,
                amount: reinvestFeeAmount,
                beneficiary: beneficiary,
                burnOnCollect: true
            })
        });
        
        // Initialize tiered fee structure
        _initializeTieredFees(ss);
        
        emit StakingFeesInitialized(address(ss.zicoToken), beneficiary);
    }

    /**
     * @notice Initialize tiered fee structure for percentage-based fees
     * @param ss Reference to staking storage
     */
    function _initializeTieredFees(LibStakingStorage.StakingStorage storage ss) private {
        // Enable tiered fees
        ss.settings.tieredFees.enabled = true;
        
        // Set up thresholds for different tiers
        ss.settings.tieredFees.thresholds.push(100 ether);   // Tier 1: 0-100 ZICO
        ss.settings.tieredFees.thresholds.push(1000 ether);  // Tier 2: 100-1000 ZICO
        ss.settings.tieredFees.thresholds.push(10000 ether); // Tier 3: >1000 ZICO
        
        // Set fee percentages for each tier (in basis points, 100 = 1%)
        ss.settings.tieredFees.feeBps.push(100); // Tier 1: 1% fee
        ss.settings.tieredFees.feeBps.push(200); // Tier 2: 2% fee
        ss.settings.tieredFees.feeBps.push(300); // Tier 3: 3% fee
        
        // Initialize stake balance adjustment parameters
        ss.settings.balanceAdjustment.enabled = true;
        ss.settings.balanceAdjustment.decayRate = LibStakingStorage.DEFAULT_DECAY_RATE;
        ss.settings.balanceAdjustment.minMultiplier = LibStakingStorage.DEFAULT_MIN_MULTIPLIER;
        ss.settings.balanceAdjustment.applyToInfusion = true;
        
        // Initialize time decay parameters
        ss.settings.timeDecay.enabled = true;
        ss.settings.timeDecay.maxBonus = LibStakingStorage.DEFAULT_TIME_BONUS;
        ss.settings.timeDecay.period = LibStakingStorage.DEFAULT_TIME_PERIOD;
    }
}