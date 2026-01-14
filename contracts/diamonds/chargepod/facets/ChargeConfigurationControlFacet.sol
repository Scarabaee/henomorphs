// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibDiamond} from "../../shared/libraries/LibDiamond.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibGamingStorage} from "../libraries/LibGamingStorage.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {ChargeSettings, ChargeFees, ControlFee, ChargeActionType} from "../../libraries/HenomorphsModel.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {IDiamondLoupe} from "../../shared/interfaces/IDiamondLoupe.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";

/**
 * @title ChargeConfigurationControlFacet
 * @notice Administrative control facet for charge system configuration
 * @dev Contains administrative functions matching existing selectors
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract ChargeConfigurationControlFacet is AccessControlBase {
    using SafeERC20 for IERC20;
    
    // Events
    event ChargeSettingsUpdated(ChargeSettings settings);
    event FeesConfigUpdated(ChargeFees fees);
    event TreasuryConfigUpdated(LibHenomorphsStorage.ChargeTreasury treasury);
    event ActionTypeUpdated(uint8 indexed actionTypeId, ChargeActionType actionType);
    event ModulesSettingsUpdated(LibHenomorphsStorage.InternalModules settings);
    event ModuleAddressUpdated(string indexed moduleType, address moduleAddress);
    event ModuleVerified(string moduleType, address moduleAddress, bool success);
    event AllModulesVerified(bool allValid, uint256 timestamp);
    event StakingAddressSet(address stakingAddress);
    event RegistryInitialized();
    event ActionScheduleSet(uint8 indexed actionId, uint256 startTime, uint256 endTime, uint256 temporaryMultiplier, bool enabled);
    event ActionScheduleRemoved(uint8 indexed actionId);
    event ActionGameplayConfigSet(uint8 indexed actionId, uint256 streakBonusMultiplier, bool eligibleForSpecialEvents, uint8 difficultyTier);
    event FeatureFlagSet(string featureName, bool enabled);
    event ActionFeeUpdated(uint8 indexed actionId, uint256 amount, address beneficiary);
    event FeeUpdated(string feeType, uint256 amount, address beneficiary, address tokenAddress);
    event SpecializationConfigured(
        uint8 indexed specializationType, 
        string name, 
        uint16 regenMultiplier, 
        uint16 efficiencyMultiplier
    );
        
    // Errors
    error InvalidCallData();
    error ForbiddenRequest();
    error InvalidFeeConfiguration();
    error EmergencyWithdrawalFailed();
    error InvalidModuleAddress();
    error UnsupportedModuleType();
    error InterfaceVerificationFailed(string moduleType, address moduleAddress);
    error ModuleTypeNotRegistered(string moduleType);
    error InvalidTreasuryConfiguration();
    error InvalidDifficultyTier(uint8 tier);

    bool public emergencyWithdrawalsEnabled = true;
    bool public skipInterfaceVerification = true;

    // =================== CHARGE SETTINGS FUNCTIONS ===================

    /**
     * @notice Sets charge settings configuration
     * @param settings New charge settings
     */
    function setChargeSettings(ChargeSettings calldata settings) external onlyAuthorized whenNotPaused {
        if (settings.baseRegenRate == 0 || settings.maxConsecutiveActions == 0) {
            revert InvalidCallData();
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        hs.chargeSettings = settings;
        emit ChargeSettingsUpdated(settings);
    }

    /**
     * @notice Sets charge fees configuration
     * @param fees New fee configuration
     */
    function setChargeFees(ChargeFees calldata fees) external onlyAuthorized whenNotPaused {
        // Basic fee validation for essential fees only
        if (fees.repairFee.beneficiary == address(0) ||
            fees.colonyFormationFee.beneficiary == address(0) ||
            fees.claimRewardsFee.beneficiary == address(0)) {
            revert InvalidFeeConfiguration();
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        hs.chargeFees = fees;
        emit FeesConfigUpdated(fees);
    }

    /**
     * @notice Sets individual operation fee (simplified version)
     * @param feeType Operation type ("repair", "boost", "claim", "colony", "achievement", "season")
     * @param amount Fee amount
     * @param beneficiary Address receiving the fee
     * @param tokenAddress Token to collect fee in (address(0) for treasury currency)
     */
    function setSimplifiedFee(
        string memory feeType,
        uint256 amount,
        address beneficiary,
        address tokenAddress
    ) external onlyAuthorized whenNotPaused {
        if (beneficiary == address(0)) {
            revert InvalidFeeConfiguration();
        }
        
        // Apply reasonable fee limits (simplified)
        if (amount > 50 ether) {
            revert InvalidFeeConfiguration();
        }
        
        // PROBLEM 4 FIX: Cache storage reference
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Determine currency to use
        IERC20 currency;
        if (tokenAddress == address(0)) {
            currency = IERC20(hs.chargeTreasury.treasuryCurrency);
        } else {
            currency = IERC20(tokenAddress);
        }
        
        // Configure the fee based on type (simplified mapping)
        // Default burnOnCollect to true for YELLOW token economy
        if (_stringEquals(feeType, "repair")) {
            hs.chargeFees.repairFee = ControlFee(currency, amount, beneficiary, true);
        } else if (_stringEquals(feeType, "boost")) {
            hs.chargeFees.boostFee = ControlFee(currency, amount, beneficiary, true);
        } else if (_stringEquals(feeType, "specialization")) {
            hs.chargeFees.specializationFee = ControlFee(currency, amount, beneficiary, true);
        } else if (_stringEquals(feeType, "colonyFormation")) {
            hs.chargeFees.colonyFormationFee = ControlFee(currency, amount, beneficiary, true);
        } else if (_stringEquals(feeType, "colonyMembership")) {
            hs.chargeFees.colonyMembershipFee = ControlFee(currency, amount, beneficiary, true);
        } else if (_stringEquals(feeType, "accessoryBase")) {
            hs.chargeFees.accessoryBaseFee = ControlFee(currency, amount, beneficiary, true);
        } else if (_stringEquals(feeType, "accessoryRare")) {
            hs.chargeFees.accessoryRareFee = ControlFee(currency, amount, beneficiary, true);
        } else if (_stringEquals(feeType, "claim")) {
            hs.chargeFees.claimRewardsFee = ControlFee(currency, amount, beneficiary, true);
        } else if (_stringEquals(feeType, "event")) {
            hs.chargeFees.eventFee = ControlFee(currency, amount, beneficiary, true);
        } else if (_stringEquals(feeType, "evolution")) {
            hs.chargeFees.evolutionFee = ControlFee(currency, amount, beneficiary, true);
        }
        
        emit FeeUpdated(feeType, amount, beneficiary, tokenAddress);
    }

    /**
     * @notice Set dual token operation fee (YELLOW with burn support)
     * @param feeType Operation type ("chargeRepair", "wearRepair", "chargeBoost", "action", "specialization", "masteryAction")
     * @param currency Token address
     * @param beneficiary Destination address (treasury)
     * @param baseAmount Base fee amount
     * @param multiplier Scaling factor (100 = 1x, 200 = 2x)
     * @param burnOnCollect Whether to burn tokens after collection
     * @param enabled Whether operation is enabled
     */
    function setOperationFee(
        string memory feeType,
        address currency,
        address beneficiary,
        uint256 baseAmount,
        uint256 multiplier,
        bool burnOnCollect,
        bool enabled
    ) external onlyAuthorized whenNotPaused {
        if (beneficiary == address(0) || currency == address(0)) {
            revert InvalidFeeConfiguration();
        }
        
        if (multiplier == 0 || multiplier > 1000) { // Max 10x multiplier
            revert InvalidFeeConfiguration();
        }
        
        LibColonyWarsStorage.OperationFee memory opFee = LibColonyWarsStorage.OperationFee({
            currency: currency,
            beneficiary: beneficiary,
            baseAmount: baseAmount,
            multiplier: multiplier,
            burnOnCollect: burnOnCollect,
            enabled: enabled
        });

        // Use keccak256 hash of feeType as key
        LibColonyWarsStorage.setOperationFeeByName(feeType, opFee);

        emit FeeUpdated(feeType, baseAmount, beneficiary, currency);
    }

    /**
     * @notice Set individual action fee
     * @param actionId Action ID (1-10)
     * @param fee Fee configuration
     */
    function setActionFee(uint8 actionId, ControlFee calldata fee) external onlyAuthorized whenNotPaused {
        if (actionId == 0 || actionId > 10) {
            revert InvalidCallData();
        }
        
        if (fee.beneficiary == address(0)) {
            revert InvalidFeeConfiguration();
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        hs.actionFees[actionId] = fee;
        
        emit ActionFeeUpdated(actionId, fee.amount, fee.beneficiary);
    }

    /**
     * @notice Reset all action fees to use actionType.baseCost defaults
     */
    function resetActionFeesToDefaults() external onlyAuthorized whenNotPaused {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        for (uint8 i = 1; i <= 5; i++) {
            delete hs.actionFees[i]; // Reset to zero - będzie używać baseCost
            emit ActionFeeUpdated(i, 0, address(0));
        }
    }

    /**
     * @notice Sets treasury configuration
     * @param treasury Treasury configuration
     */
    function setChargeTreasury(LibHenomorphsStorage.ChargeTreasury calldata treasury) external onlyAuthorized whenNotPaused {
        if (treasury.treasuryAddress == address(0) || treasury.treasuryCurrency == address(0)) {
            revert InvalidTreasuryConfiguration();
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        hs.chargeTreasury = treasury;
        emit TreasuryConfigUpdated(treasury);
    }

    /**
     * @notice Configures a specific action type
     * @param actionId Action ID (1-5)
     * @param actionType Action type configuration
     */
    function setActionType(uint8 actionId, ChargeActionType calldata actionType) external onlyAuthorized whenNotPaused {
        if (actionId == 0 || actionId > 10) {
            revert InvalidCallData();
        }
        
        if (actionType.cooldown == 0 || actionType.rewardMultiplier == 0 || actionType.baseCost.beneficiary == address(0)) {
            revert InvalidCallData();
        }

        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        hs.actionTypes[actionId] = actionType;
        emit ActionTypeUpdated(actionId, actionType);
    }

    /**
     * @notice Sets time control for an action
     * @param actionId Action ID (1-5)
     * @param startTime Start timestamp (0 = immediate)
     * @param endTime End timestamp (0 = no end)
     * @param temporaryMultiplier Temporary multiplier override (0 = use default)
     * @param enabled Whether time control should be enabled
     */
    function setActionSchedule(
        uint8 actionId,
        uint256 startTime, 
        uint256 endTime,
        uint256 temporaryMultiplier,
        bool enabled
    ) external onlyAuthorized whenNotPaused {
        if (actionId == 0 || actionId > 10) {
            revert InvalidCallData();
        }
        
        if (endTime > 0 && endTime <= startTime) {
            revert InvalidCallData();
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        ChargeActionType storage actionType = hs.actionTypes[actionId];
        
        if (actionType.baseCost.beneficiary == address(0)) {
            revert InvalidCallData();
        }
        
        actionType.timeControlEnabled = enabled;
        actionType.startTime = startTime == 0 ? block.timestamp : startTime;
        actionType.endTime = endTime == 0 ? type(uint256).max : endTime;
        actionType.temporaryMultiplier = temporaryMultiplier;
        
        emit ActionScheduleSet(actionId, actionType.startTime, actionType.endTime, temporaryMultiplier, enabled);
    }

    /**
     * @notice Sets gameplay configuration for an action
     * @param actionId Action ID (1-5)
     * @param streakBonusMultiplier Streak bonus multiplier
     * @param eligibleForSpecialEvents Whether eligible for special events
     * @param difficultyTier Difficulty tier (1-5)
     */
    function setActionGameplayConfig(
        uint8 actionId,
        uint256 streakBonusMultiplier,
        bool eligibleForSpecialEvents,
        uint8 difficultyTier
    ) external onlyAuthorized whenNotPaused {
        if (actionId == 0 || actionId > 10) {
            revert InvalidCallData();
        }
        
        if (difficultyTier == 0 || difficultyTier > 5) {
            revert InvalidDifficultyTier(difficultyTier);
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        ChargeActionType storage actionType = hs.actionTypes[actionId];
        
        actionType.streakBonusMultiplier = streakBonusMultiplier;
        actionType.eligibleForSpecialEvents = eligibleForSpecialEvents;
        actionType.difficultyTier = difficultyTier;
        
        emit ActionGameplayConfigSet(actionId, streakBonusMultiplier, eligibleForSpecialEvents, difficultyTier);
    }

    /**
     * @notice Removes time control for an action
     * @param actionId Action ID (1-5)
     */
    function removeActionSchedule(uint8 actionId) external onlyAuthorized whenNotPaused {
        if (actionId == 0 || actionId > 10) {
            revert InvalidCallData();
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        ChargeActionType storage actionType = hs.actionTypes[actionId];
        
        actionType.timeControlEnabled = false;
        actionType.startTime = 0;
        actionType.endTime = 0;
        actionType.temporaryMultiplier = 0;
        
        emit ActionScheduleRemoved(actionId);
    }

    // =================== GAMING SYSTEM FUNCTIONS ===================

    /**
     * @notice Sets feature flags for gradual rollout
     * @param featureName Feature name
     * @param enabled Whether feature is enabled
     */
    function setFeatureFlag(string calldata featureName, bool enabled) external onlyAuthorized whenNotPaused {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        hs.featureFlags[featureName] = enabled;
        
        emit FeatureFlagSet(featureName, enabled);
    }

    // =================== MODULE MANAGEMENT FUNCTIONS ===================

    /**
     * @notice Sets staking system address for authorization checks
     * @param stakingAddress Address of the staking system
     */
    function setStakingSystemAddress(address stakingAddress) external onlyAuthorized whenNotPaused {
        if (stakingAddress == address(0)) {
            revert InvalidModuleAddress();
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        hs.stakingSystemAddress = stakingAddress;
        emit StakingAddressSet(stakingAddress);
    }

    /**
     * @notice Sets complete modules settings
     * @param settings New modules settings containing all module addresses
     */
    function setModulesSettings(LibHenomorphsStorage.InternalModules calldata settings) 
        external 
        onlyAuthorized 
        whenNotPaused
    {
        if (settings.chargeModuleAddress == address(0) || 
            settings.traitsModuleAddress == address(0) ||
            settings.configModuleAddress == address(0)) {
            revert InvalidModuleAddress();
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        hs.internalModules = settings;
        hs.modulesRegistry.lastVerificationTimestamp = block.timestamp;
        hs.modulesRegistry.lastVerificationResult = true;
        
        emit ModulesSettingsUpdated(settings);
        emit AllModulesVerified(true, block.timestamp);
    }

    /**
     * @notice Updates a specific module address with verification
     * @param moduleType String identifier of the module type
     * @param moduleAddress New address for the specified module
     */
    function updateModuleAddress(string calldata moduleType, address moduleAddress) 
        external 
        onlyAuthorized 
        whenNotPaused
    {
        if (moduleAddress == address(0)) {
            revert InvalidModuleAddress();
        }

        // Update module address without verification if skipInterfaceVerification is true
        if (skipInterfaceVerification) {
            _setModuleAddress(moduleType, moduleAddress);
            emit ModuleAddressUpdated(moduleType, moduleAddress);
            return;
        }

        // Store original address in case verification fails
        address originalAddress = _getModuleAddress(moduleType);
        
        // Update the module address
        _setModuleAddress(moduleType, moduleAddress);
        
        // Special handling for config module - skip verification
        bytes32 moduleTypeHash = keccak256(bytes(moduleType));
        if (moduleTypeHash == keccak256(bytes("config"))) {
            LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
            hs.modulesRegistry.lastVerificationTimestamp = block.timestamp;
            hs.modulesRegistry.lastVerificationResult = true;
            
            emit ModuleAddressUpdated(moduleType, moduleAddress);
            emit ModuleVerified(moduleType, moduleAddress, true);
            return;
        }
        
        // For other modules - standard verification
        try this.verifyModule(moduleType) returns (bool valid) {
            if (!valid) {
                _setModuleAddress(moduleType, originalAddress);
                revert InterfaceVerificationFailed(moduleType, moduleAddress);
            }
            
            emit ModuleAddressUpdated(moduleType, moduleAddress);
            emit ModuleVerified(moduleType, moduleAddress, true);
        } catch {
            _setModuleAddress(moduleType, originalAddress);
            revert InterfaceVerificationFailed(moduleType, moduleAddress);
        }
    }

    /**
     * @notice Verifies a specific module implements expected interface
     * @param moduleType Module type (e.g., "charge", "traits", "config")
     * @return valid Whether module implements expected interface
     */
    function verifyModule(string calldata moduleType) 
        external 
        view 
        returns (bool valid) 
    {
        if (skipInterfaceVerification) {
            return true;
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        bytes4[] memory expectedSelectors = hs.modulesRegistry.expectedSelectors[moduleType];
        if (expectedSelectors.length == 0) {
            revert ModuleTypeNotRegistered(moduleType);
        }
        
        address moduleAddress = _getModuleAddress(moduleType);
        if (moduleAddress == address(0)) {
            return false;
        }
        
        IDiamondLoupe diamondLoupe = IDiamondLoupe(address(this));
        valid = true;
        
        for (uint256 i = 0; i < expectedSelectors.length; i++) {
            address facetAddress = diamondLoupe.facetAddress(expectedSelectors[i]);
            if (facetAddress != moduleAddress) {
                valid = false;
                break;
            }
        }
        
        return valid;
    }

    /**
     * @notice Verifies all core modules
     * @return allValid Whether all core modules implement expected interfaces
     */
    function verifyAllModules() 
        external 
        view 
        returns (bool allValid) 
    {
        if (skipInterfaceVerification) {
            return true;
        }

        string[3] memory moduleTypes = [
            "charge", "traits", "config"
        ];
        
        allValid = true;
        
        for (uint256 i = 0; i < moduleTypes.length; i++) {
            if (keccak256(bytes(moduleTypes[i])) == keccak256(bytes("config"))) {
                continue;
            }
            
            try this.verifyModule(moduleTypes[i]) returns (bool valid) {
                if (!valid) {
                    allValid = false;
                    break;
                }
            } catch {
                allValid = false;
                break;
            }
        }
        
        return allValid;
    }

    /**
     * @notice Set whether to skip interface verification
     * @param skip Whether to skip verification
     */
    function setSkipInterfaceVerification(bool skip) external onlyAuthorized whenNotPaused {
        skipInterfaceVerification = skip;
    }

    /**
     * @notice Configure specialization parameters
     * @param specializationType Type (0=balanced, 1=efficiency, 2=regeneration)
     * @param name Human readable name
     * @param regenMultiplier Regeneration rate multiplier (100 = 100%)
     * @param efficiencyMultiplier Efficiency multiplier (100 = 100%)
     * @param enabled Whether this specialization is available
     */
    function setSpecializationConfig(
        uint8 specializationType,
        string calldata name,
        uint16 regenMultiplier,
        uint16 efficiencyMultiplier,
        bool enabled
    ) external onlyAuthorized {
        if (specializationType > 2) {
            revert LibHenomorphsStorage.InvalidSpecializationType();
        }
        
        // Validate multipliers (10% to 300% range)
        if (regenMultiplier < 10 || regenMultiplier > 300 || 
            efficiencyMultiplier < 10 || efficiencyMultiplier > 300) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        hs.specializationConfigs[specializationType] = LibHenomorphsStorage.SpecializationConfig({
            name: name,
            regenMultiplier: regenMultiplier,
            efficiencyMultiplier: efficiencyMultiplier,
            enabled: enabled
        });
        
        emit SpecializationConfigured(specializationType, name, regenMultiplier, efficiencyMultiplier);
    }

    // =================== EMERGENCY FUNCTIONS ===================

    /**
     * @notice Emergency withdrawal function
     * @param tokenAddress Token address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address tokenAddress, uint256 amount) external onlyAuthorized nonReentrant {
        if (!emergencyWithdrawalsEnabled) {
            revert ForbiddenRequest();
        }
        
        IERC20(tokenAddress).safeTransfer(LibMeta.msgSender(), amount);
    }

    /**
     * @notice Toggle emergency withdrawals
     * @param enabled Whether emergency withdrawals are enabled
     */
    function setEmergencyWithdrawalsEnabled(bool enabled) external onlyAuthorized {
        emergencyWithdrawalsEnabled = enabled;
    }

    // =================== INTERNAL HELPER FUNCTIONS ===================

    /**
     * @dev Helper to get module address
     */
    function _getModuleAddress(string memory moduleType) internal view returns (address) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibHenomorphsStorage.InternalModules memory modules = hs.internalModules;
        
        bytes32 moduleTypeHash = keccak256(bytes(moduleType));
        
        if (moduleTypeHash == keccak256(bytes("charge"))) {
            return modules.chargeModuleAddress;
        } else if (moduleTypeHash == keccak256(bytes("traits"))) {
            return modules.traitsModuleAddress;
        } else if (moduleTypeHash == keccak256(bytes("config"))) {
            return modules.configModuleAddress;
        } else if (moduleTypeHash == keccak256(bytes("staking"))) {
            return hs.stakingSystemAddress;
        } else {
            revert UnsupportedModuleType();
        }
    }

    /**
     * @dev Helper to set module address
     */
    function _setModuleAddress(string memory moduleType, address moduleAddress) internal {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibHenomorphsStorage.InternalModules storage modules = hs.internalModules;
        
        bytes32 moduleTypeHash = keccak256(bytes(moduleType));
        
        if (moduleTypeHash == keccak256(bytes("charge"))) {
            modules.chargeModuleAddress = moduleAddress;
        } else if (moduleTypeHash == keccak256(bytes("traits"))) {
            modules.traitsModuleAddress = moduleAddress;
        } else if (moduleTypeHash == keccak256(bytes("config"))) {
            modules.configModuleAddress = moduleAddress;
        } else if (moduleTypeHash == keccak256(bytes("staking"))) {
            hs.stakingSystemAddress = moduleAddress;
        } else {
            revert UnsupportedModuleType();
        }
    }

    // =================== INTERNAL HELPER FUNCTIONS ===================

    /**
     * @notice String comparison helper
     * @param a First string
     * @param b Second string
     * @return equal Whether strings are equal
     */
    function _stringEquals(string memory a, string memory b) private pure returns (bool equal) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}