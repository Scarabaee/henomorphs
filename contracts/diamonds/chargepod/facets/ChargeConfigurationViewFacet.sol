// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibGamingStorage} from "../libraries/LibGamingStorage.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {ChargeSettings, ChargeFees, ChargeActionType, ChargeSeason, ControlFee} from "../../../libraries/HenomorphsModel.sol";

/**
 * @title ChargeConfigurationViewFacet
 * @notice View facet for charge system configuration and gaming data
 * @dev Contains all view/read-only functions matching existing selectors
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract ChargeConfigurationViewFacet {
    
    // Errors
    error InvalidCallData();
    error UnsupportedModuleType();

    // =================== CORE CONFIGURATION VIEW FUNCTIONS ===================

    /**
     * @notice Gets current charge settings
     * @return Current charge settings
     */
    function getChargeSettings() external view returns (ChargeSettings memory) {
        return LibHenomorphsStorage.henomorphsStorage().chargeSettings;
    }
    
    /**
     * @notice Gets current fee configuration
     * @return Current fee configuration
     */
    function getChargeFees() external view returns (ChargeFees memory) {
        return LibHenomorphsStorage.henomorphsStorage().chargeFees;
    }

    /**
     * @notice Gets treasury configuration
     * @return Current treasury configuration
     */
    function getChargeTreasury() external view returns (LibHenomorphsStorage.ChargeTreasury memory) {
        return LibHenomorphsStorage.henomorphsStorage().chargeTreasury;
    }
    
    /**
     * @notice Gets action type configuration
     * @param actionId Action ID (1-5)
     * @return Action type configuration
     */
    function getActionType(uint8 actionId) external view returns (ChargeActionType memory) {
        if (actionId == 0 || actionId > 10) {
            revert InvalidCallData();
        }
        
        return LibHenomorphsStorage.henomorphsStorage().actionTypes[actionId];
    }

    /**
     * @notice Get effective fee for an action
     * @param actionId Action ID (1-5)
     * @return fee Effective fee configuration
     * @return isCustom Whether using custom actionFee (true) or default baseCost (false)
     */
    function getEffectiveActionFee(uint8 actionId) 
        external view 
        returns (ControlFee memory fee, bool isCustom) 
    {
        if (actionId == 0 || actionId > 10) {
            revert InvalidCallData();
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Check if custom actionFee is set
        if (hs.actionFees[actionId].beneficiary != address(0)) {
            return (hs.actionFees[actionId], true);
        } else {
            // Return actionType.baseCost as default
            return (hs.actionTypes[actionId].baseCost, false);
        }
    }

    /**
     * @notice Get all action fees overview
     * @return actionIds Array of action IDs (1-5)
     * @return customFees Array of custom fees (zero address = using default)
     * @return defaultFees Array of default baseCost fees
     * @return usingCustom Array indicating which actions use custom fees
     */
    function getAllActionFeesOverview() 
        external view 
        returns (
            uint8[] memory actionIds,
            ControlFee[] memory customFees,
            ControlFee[] memory defaultFees, 
            bool[] memory usingCustom
        ) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        actionIds = new uint8[](10);
        customFees = new ControlFee[](10);
        defaultFees = new ControlFee[](10);
        usingCustom = new bool[](10);
        
        for (uint8 i = 1; i <= 10; i++) {
            actionIds[i-1] = i;
            customFees[i-1] = hs.actionFees[i];
            defaultFees[i-1] = hs.actionTypes[i].baseCost;
            usingCustom[i-1] = (hs.actionFees[i].beneficiary != address(0));
        }
    }

    /**
     * @notice Gets time control settings for an action
     * @param actionId Action ID (1-5)
     * @return enabled Whether time control is enabled
     * @return startTime Start timestamp
     * @return endTime End timestamp
     * @return temporaryMultiplier Temporary multiplier
     */
    function getActionSchedule(uint8 actionId) 
        external 
        view 
        returns (
            bool enabled, 
            uint256 startTime, 
            uint256 endTime, 
            uint256 temporaryMultiplier
        ) 
    {
        if (actionId == 0 || actionId > 10) {
            revert InvalidCallData();
        }
        
        ChargeActionType storage actionType = LibHenomorphsStorage.henomorphsStorage().actionTypes[actionId];
        return (
            actionType.timeControlEnabled, 
            actionType.startTime, 
            actionType.endTime, 
            actionType.temporaryMultiplier
        );
    }

    /**
     * @notice Gets complete information about all actions and their current status
     * @return actionIds Array of action IDs (1-5)
     * @return cooldowns Current cooldowns for each action
     * @return rewardMultipliers Current reward multipliers
     * @return timeControlEnabled Whether time control is active
     * @return currentlyAvailable Whether each action is currently available
     * @return temporaryMultipliers Any temporary multipliers active
     * @return streakBonuses Streak bonus multipliers
     */
    function getAllActionsStatus() 
        external 
        view 
        returns (
            uint8[] memory actionIds,
            uint256[] memory cooldowns,
            uint256[] memory rewardMultipliers,
            bool[] memory timeControlEnabled,
            bool[] memory currentlyAvailable,
            uint256[] memory temporaryMultipliers,
            uint256[] memory streakBonuses
        ) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        actionIds = new uint8[](10);
        cooldowns = new uint256[](10);
        rewardMultipliers = new uint256[](10);
        timeControlEnabled = new bool[](10);
        currentlyAvailable = new bool[](10);
        temporaryMultipliers = new uint256[](10);
        streakBonuses = new uint256[](10);
        
        for (uint8 i = 1; i <= 10; i++) {
            ChargeActionType storage actionType = hs.actionTypes[i];
            
            actionIds[i-1] = i;
            cooldowns[i-1] = actionType.cooldown;
            rewardMultipliers[i-1] = actionType.rewardMultiplier;
            timeControlEnabled[i-1] = actionType.timeControlEnabled;
            streakBonuses[i-1] = actionType.streakBonusMultiplier;
            
            // Check if currently available
            if (actionType.timeControlEnabled) {
                currentlyAvailable[i-1] = block.timestamp >= actionType.startTime && 
                                        block.timestamp <= actionType.endTime;
                if (currentlyAvailable[i-1] && actionType.temporaryMultiplier > 0) {
                    temporaryMultipliers[i-1] = actionType.temporaryMultiplier;
                } else {
                    temporaryMultipliers[i-1] = actionType.rewardMultiplier;
                }
            } else {
                currentlyAvailable[i-1] = true;
                temporaryMultipliers[i-1] = actionType.rewardMultiplier;
            }
        }
    }

    /**
     * @notice Gets detailed information about a specific action
     * @param actionId Action ID (1-5)
     * @return actionType Complete action type structure
     * @return isCurrentlyAvailable Whether action is currently available
     * @return timeRemaining Time remaining if time-controlled (0 if not applicable)
     * @return effectiveMultiplier Current effective multiplier
     */
    function getActionDetails(uint8 actionId) 
        external 
        view 
        returns (
            ChargeActionType memory actionType,
            bool isCurrentlyAvailable,
            uint256 timeRemaining,
            uint256 effectiveMultiplier
        ) 
    {
        if (actionId == 0 || actionId > 10) {
            revert InvalidCallData();
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Use the same approach as getActionType - direct storage access
        actionType = hs.actionTypes[actionId];
        
        // Calculate additional fields based on the actionType data
        if (actionType.timeControlEnabled) {
            isCurrentlyAvailable = (block.timestamp >= actionType.startTime && 
                                block.timestamp <= actionType.endTime);
            
            if (isCurrentlyAvailable && actionType.endTime != type(uint256).max) {
                timeRemaining = actionType.endTime - block.timestamp;
            } else {
                timeRemaining = 0;
            }
            
            effectiveMultiplier = (actionType.temporaryMultiplier > 0 && isCurrentlyAvailable) ? 
                                actionType.temporaryMultiplier : actionType.rewardMultiplier;
        } else {
            isCurrentlyAvailable = true;
            timeRemaining = 0;
            effectiveMultiplier = actionType.rewardMultiplier;
        }
    }

    // =================== MODULE VIEW FUNCTIONS ===================
    
    /**
     * @notice Gets verification status
     * @return lastVerified Last verification timestamp
     * @return allValid Whether all modules were valid
     */
    function getVerificationStatus() external view returns (uint256 lastVerified, bool allValid) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        return (
            hs.modulesRegistry.lastVerificationTimestamp, 
            hs.modulesRegistry.lastVerificationResult
        );
    }

    /**
     * @notice Gets verification error for a module
     * @param moduleType Module type
     * @return error Error message
     */
    function getModuleVerificationError(string calldata moduleType) 
        external 
        view 
        returns (string memory error) 
    {
        return LibHenomorphsStorage.henomorphsStorage().modulesRegistry.verificationErrors[moduleType];
    }
    
    /**
     * @notice Gets current modules settings
     * @return Current modules settings
     */
    function getModulesSettings() external view returns (LibHenomorphsStorage.InternalModules memory) {
        return LibHenomorphsStorage.henomorphsStorage().internalModules;
    }
    
    /**
     * @notice Gets address of a specific module
     * @param moduleType String identifier of the module type
     * @return Address of the specified module
     */
    function getModuleAddress(string calldata moduleType) external view returns (address) {
        return _getModuleAddress(moduleType);
    }
    
    /**
     * @notice Gets staking system address
     * @return The current staking system address
     */
    function getStakingSystemAddress() external view returns (address) {
        return LibHenomorphsStorage.henomorphsStorage().stakingSystemAddress;
    }

    // =================== GAMING SYSTEM VIEW FUNCTIONS ===================

    /**
     * @notice Check if feature is enabled
     * @param featureName Feature name
     * @return Whether feature is enabled
     */
    function isFeatureEnabled(string calldata featureName) external view returns (bool) {
        return LibHenomorphsStorage.henomorphsStorage().featureFlags[featureName];
    }

    /**
     * @notice Gets enabled features status
     * @return featureNames Array of feature names
     * @return enabled Array of enabled status for each feature
     */
    function getFeatureFlags() 
        external 
        view 
        returns (
            string[] memory featureNames,
            bool[] memory enabled
        ) 
    {
        featureNames = new string[](10);
        enabled = new bool[](10);
        
        featureNames[0] = "streaks";
        featureNames[1] = "dailyChallenges";
        featureNames[2] = "flashEvents";
        featureNames[3] = "achievements";
        featureNames[4] = "globalMultipliers";
        featureNames[5] = "rankings";
        featureNames[6] = "socialFeatures";
        featureNames[7] = "guilds";
        featureNames[8] = "specializationEvolution";
        featureNames[9] = "colonyEvents";
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        for (uint i = 0; i < 10; i++) {
            enabled[i] = hs.featureFlags[featureNames[i]];
        }
    }

    // =================== SYSTEM STATUS FUNCTIONS ===================

    /**
     * @notice Gets comprehensive system status
     * @return isPaused Whether system is paused
     * @return currentSeason Current season counter
     * @return activeFeaturesCount Number of active features
     * @return stakingIntegrationActive Whether staking integration is active
     * @return treasuryConfigured Whether treasury is configured
     * @return moduleVerificationStatus Last module verification result
     */
    function getSystemStatus() 
        external 
        view 
        returns (
            bool isPaused,
            uint32 currentSeason,
            uint256 activeFeaturesCount,
            bool stakingIntegrationActive,
            bool treasuryConfigured,
            bool moduleVerificationStatus
        ) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        isPaused = hs.paused;
        currentSeason = hs.seasonCounter;
        stakingIntegrationActive = hs.stakingSystemAddress != address(0);
        treasuryConfigured = hs.chargeTreasury.treasuryAddress != address(0);
        moduleVerificationStatus = hs.modulesRegistry.lastVerificationResult;
        
        // Count active features
        string[] memory features = new string[](10);
        features[0] = "streaks";
        features[1] = "dailyChallenges";
        features[2] = "flashEvents";
        features[3] = "achievements";
        features[4] = "globalMultipliers";
        features[5] = "rankings";
        features[6] = "socialFeatures";
        features[7] = "guilds";
        features[8] = "specializationEvolution";
        features[9] = "colonyEvents";
        
        for (uint i = 0; i < 10; i++) {
            if (hs.featureFlags[features[i]]) {
                activeFeaturesCount++;
            }
        }
    }

    /**
     * @notice Get specialization configuration
     * @param specializationType Type to query
     * @return config Specialization configuration
     */
    function getSpecializationConfig(uint8 specializationType) 
        external 
        view 
        returns (LibHenomorphsStorage.SpecializationConfig memory config) 
    {
        if (specializationType > 2) {
            revert LibHenomorphsStorage.InvalidSpecializationType();
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        config = hs.specializationConfigs[specializationType];
        
        // Return default values if not configured
        if (bytes(config.name).length == 0) {
            if (specializationType == 0) {
                config = LibHenomorphsStorage.SpecializationConfig("Balanced", 100, 100, true);
            } else if (specializationType == 1) {
                config = LibHenomorphsStorage.SpecializationConfig("Efficiency", 80, 130, true);
            } else if (specializationType == 2) {
                config = LibHenomorphsStorage.SpecializationConfig("Regeneration", 130, 85, true);
            }
        }
        
        return config;
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

    // =================== OPERATION FEES VIEW FUNCTIONS ===================

    /**
     * @notice Get specific operation fee configuration
     * @param feeType Fee type identifier ("chargeRepair", "wearRepair", "chargeBoost", "action", "specialization", "masteryAction")
     * @return fee Operation fee configuration
     */
    function getOperationFee(string memory feeType)
        external
        view
        returns (LibColonyWarsStorage.OperationFee memory fee)
    {
        return LibColonyWarsStorage.getOperationFeeByName(feeType);
    }

    /**
     * @notice Labeled operation fee with human-readable name
     */
    struct LabeledOperationFee {
        string label;
        LibColonyWarsStorage.OperationFee fee;
    }

    /**
     * @notice Get all operation fees with labels
     * @return fees Array of labeled operation fees
     */
    function getOperationFees()
        external
        view
        returns (LabeledOperationFee[] memory fees)
    {
        fees = new LabeledOperationFee[](15);

        string[15] memory names = [
            "raid", "maintenance", "repair", "scouting", "healing",
            "processing", "listing", "crafting", "chargeRepair", "wearRepair",
            "chargeBoost", "action", "specialization", "masteryAction", "inspection"
        ];

        for (uint256 i = 0; i < 15; i++) {
            fees[i] = LabeledOperationFee(names[i], LibColonyWarsStorage.getOperationFeeByName(names[i]));
        }
    }
}