// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../../chargepod/libraries/LibHenomorphsStorage.sol";
import {LibStakingStorage} from "../libraries/LibStakingStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PodRewardRate, StakingFees, Colony} from "../../../libraries/StakingModel.sol";
import {ControlFee, SpecimenCollection} from "../../../libraries/HenomorphsModel.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";

/**
 * @title StakingConfigurationViewFacet
 * @notice View facet for staking system configuration - provides read access to configuration
 * @dev Contains only view functions to query staking parameters and settings
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract StakingConfigurationViewFacet {

    /**
     * @notice Get comprehensive reward calculation configuration
     * @return config Complete reward calculation configuration
     */
    function getRewardCalculationConfig() external view returns (LibStakingStorage.RewardCalculationConfig memory config) {
        return LibStakingStorage.getRewardCalculationConfig();
    }

    /**
     * @notice Get wear penalty configuration
     * @return config Complete wear penalty configuration
     */
    function getWearPenaltyConfig() external view returns (LibStakingStorage.WearPenaltyConfig memory config) {
        return LibStakingStorage.getWearPenaltyConfig();
    }

    /**
     * @notice Get loyalty bonus configuration
     * @return config Complete loyalty bonus configuration
     */
    function getLoyaltyBonusConfig() external view returns (LibStakingStorage.LoyaltyBonusConfig memory config) {
        return LibStakingStorage.getLoyaltyBonusConfig();
    }

    /**
     * @notice Get progressive decay configuration
     * @return config Complete progressive decay configuration
     */
    function getProgressiveDecayConfig() external view returns (LibStakingStorage.ProgressiveDecayConfig memory config) {
        return LibStakingStorage.getProgressiveDecayConfig();
    }

    /**
     * @notice Get time bonus configuration
     * @return config Complete time bonus configuration
     */
    function getTimeBonusConfig() external view returns (LibStakingStorage.TimeBonusConfig memory config) {
        return LibStakingStorage.getTimeBonusConfig();
    }

    /**
     * @notice Get level bonus configuration details
     * @return numerator Level bonus numerator
     * @return denominator Level bonus denominator  
     * @return maxBonus Maximum level bonus percentage
     * @return currentFormula Description of current formula
     */
    function getLevelBonusConfiguration() external view returns (
        uint256 numerator,
        uint256 denominator,
        uint256 maxBonus,
        string memory currentFormula
    ) {
        LibStakingStorage.RewardCalculationConfig storage config = LibStakingStorage.getRewardCalculationConfig();
        
        numerator = config.levelBonusNumerator;
        denominator = config.levelBonusDenominator;
        maxBonus = config.maxLevelBonus;
        
        if (denominator > 0) {
            currentFormula = "level * numerator / denominator (configurable)";
        } else {
            currentFormula = "level / 2 (hardcoded fallback)";
        }
        
        return (numerator, denominator, maxBonus, currentFormula);
    }

    /**
     * @notice Get variant bonus configuration details
     * @return bonusPerLevel Bonus percentage per variant level
     * @return maxBonus Maximum variant bonus percentage
     * @return currentFormula Description of current formula
     */
    function getVariantBonusConfiguration() external view returns (
        uint256 bonusPerLevel,
        uint256 maxBonus,
        string memory currentFormula
    ) {
        LibStakingStorage.RewardCalculationConfig storage config = LibStakingStorage.getRewardCalculationConfig();
        
        bonusPerLevel = config.variantBonusPercentPerLevel;
        maxBonus = config.maxVariantBonus;
        currentFormula = bonusPerLevel > 0 ? "configurable per-level bonus" : "hardcoded 5% per level";
        
        return (bonusPerLevel, maxBonus, currentFormula);
    }

    /**
     * @notice Get charge bonus configuration
     * @return thresholds Array of charge level thresholds
     * @return bonuses Array of bonus percentages
     * @return isConfigured Whether custom thresholds are configured
     */
    function getChargeBonusConfiguration() external view returns (
        uint8[4] memory thresholds,
        uint8[4] memory bonuses,
        bool isConfigured
    ) {
        LibStakingStorage.RewardCalculationConfig storage config = LibStakingStorage.getRewardCalculationConfig();
        
        thresholds = config.chargeBonusThresholds;
        bonuses = config.chargeBonusValues;
        isConfigured = (thresholds[0] > 0);
        
        return (thresholds, bonuses, isConfigured);
    }

    /**
     * @notice Get infusion bonus configuration
     * @return bonuses Array of bonuses for levels 1-5 (index 0 unused)
     * @return isConfigured Whether custom bonuses are configured
     */
    function getInfusionBonusConfiguration() external view returns (
        uint8[6] memory bonuses,
        bool isConfigured
    ) {
        LibStakingStorage.RewardCalculationConfig storage config = LibStakingStorage.getRewardCalculationConfig();
        
        bonuses = config.infusionBonuses;
        isConfigured = (bonuses[1] > 0);
        
        return (bonuses, isConfigured);
    }

    /**
     * @notice Get specialization bonus configuration
     * @return bonuses Array of bonuses for specializations 0-5
     * @return isConfigured Whether custom bonuses are configured
     */
    function getSpecializationBonusConfiguration() external view returns (
        uint8[6] memory bonuses,
        bool isConfigured
    ) {
        LibStakingStorage.RewardCalculationConfig storage config = LibStakingStorage.getRewardCalculationConfig();
        
        bonuses = config.specializationBonuses;
        isConfigured = (bonuses[1] > 0 || bonuses[2] > 0);
        
        return (bonuses, isConfigured);
    }

    /**
     * @notice Get context multiplier configuration
     * @return useAdditive Whether additive context bonuses are used
     * @return maxCombinedBonus Maximum combined context bonus
     * @return description Description of current behavior
     */
    function getContextMultiplierConfiguration() external view returns (
        bool useAdditive,
        uint256 maxCombinedBonus,
        string memory description
    ) {
        LibStakingStorage.RewardCalculationConfig storage config = LibStakingStorage.getRewardCalculationConfig();
        
        useAdditive = config.useAdditiveContextBonuses;
        maxCombinedBonus = config.maxCombinedContextBonus;
        
        if (useAdditive) {
            description = "Additive: colony + loyalty + accessory bonuses are summed";
        } else {
            description = "Multiplicative: bonuses are applied sequentially (compounds)";
        }
        
        return (useAdditive, maxCombinedBonus, description);
    }

    /**
     * @notice Get detailed progressive decay configuration
     * @return shareThresholds Share thresholds in basis points
     * @return decayMultipliers Decay multipliers for each tier
     * @return maxDecayPercentage Maximum decay percentage
     * @return baseDecayRate Base decay rate parameter
     * @return minMultiplier Minimum multiplier percentage
     * @return description Description of progressive decay behavior
     */
    function getProgressiveDecayDetails() external view returns (
        uint256[4] memory shareThresholds,
        uint256[4] memory decayMultipliers,
        uint256 maxDecayPercentage,
        uint256 baseDecayRate,
        uint256 minMultiplier,
        string memory description
    ) {
        LibStakingStorage.ProgressiveDecayConfig storage config = LibStakingStorage.getProgressiveDecayConfig();
        
        shareThresholds = config.shareThresholds;
        decayMultipliers = config.decayMultipliers;
        maxDecayPercentage = config.maxDecayPercentage;
        baseDecayRate = config.baseDecayRate;
        minMultiplier = config.minMultiplier;
        description = "Progressive decay with gentle curves to discourage concentration while staying fair";
        
        return (shareThresholds, decayMultipliers, maxDecayPercentage, baseDecayRate, minMultiplier, description);
    }

    /**
     * @notice Returns the current vault configuration for tokens
     * @return useExternalVault Whether an external vault is being used
     * @return vaultAddress The configured external vault address (only relevant when useExternalVault is true)
     * @return actualVaultAddress The actual address where tokens are stored (diamond or external vault)
     */
    function getStakingVaultConfig() external view returns (
        bool useExternalVault,
        address vaultAddress,
        address actualVaultAddress
    ) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        useExternalVault = ss.vaultConfig.useExternalVault;
        vaultAddress = ss.vaultConfig.vaultAddress;
        actualVaultAddress = useExternalVault ? vaultAddress : address(this);
        
        return (useExternalVault, vaultAddress, actualVaultAddress);
    }

    /**
     * @notice Gets the complete fee configuration
     * @return Complete staking fees structure
     */
    function getStakingFees() external view returns (StakingFees memory) {
        return LibStakingStorage.stakingStorage().fees;
    }

    /**
     * @notice Get fee configuration info for UI/testing
     * @param feeType Operation type
     * @return amount Fee amount
     * @return beneficiary Fee beneficiary
     * @return token Fee token address
     */
    function getFeeInfo(string memory feeType) 
        external 
        view 
        returns (uint256 amount, address beneficiary, address token) 
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        ControlFee storage fee = LibFeeCollection.getOperationFee(feeType, ss);
        
        return (
            fee.amount,
            fee.beneficiary,
            address(fee.currency)
        );
    }

    /**
     * @notice Check if staking is enabled
     */
    function isStakingEnabled() external view returns (bool) {
        return LibStakingStorage.stakingStorage().stakingEnabled;
    }

    /**
     * @notice Get detailed information about a collection
     * @param collectionId Collection ID to query
     * @return exists Whether the collection exists
     * @return isEnabled Whether the collection is enabled
     * @return collectionAddress Address of the collection contract
     * @return biopodAddress Address of the associated Biopod
     * @return diamondAddress Address of the associated Diamond
     * @return augmentsAddress Address of the associated Augments
     * @return name Name of the collection
     * @return regenMultiplier Regeneration multiplier
     * @return maxChargeBonus Maximum charge bonus
     */
    function getCollectionStatus(uint256 collectionId) external view returns (
        bool exists,
        bool isEnabled,
        address collectionAddress,
        address biopodAddress,
        address diamondAddress,
        address augmentsAddress,
        string memory name,
        uint256 regenMultiplier,
        uint256 maxChargeBonus
    ) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        if (collectionId == 0 || collectionId > ss.collectionCounter) {
            return (false, false, address(0), address(0), address(0), address(0), "", 0, 0);
        }
        
        SpecimenCollection storage collection = ss.collections[collectionId];
        collectionAddress = collection.collectionAddress;
        
        if (collectionAddress == address(0)) {
            return (false, false, address(0), address(0), address(0), address(0), "", 0, 0);
        }
        
        return (
            true,
            collection.enabled,
            collectionAddress,
            collection.biopodAddress,
            collection.diamondAddress,
            collection.augmentsAddress,
            collection.name,
            collection.regenMultiplier,
            collection.maxChargeBonus
        );
    }

    /**
     * @notice Get tiered fee configuration
     * @dev Returns current tiered fee settings
     * @return enabled Whether tiered fees are enabled
     * @return thresholds Array of thresholds for fee tiers
     * @return feeBps Array of fee percentages in basis points
     */
    function getTieredFeeConfiguration() external view returns (
        bool enabled,
        uint256[] memory thresholds,
        uint256[] memory feeBps
    ) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        LibStakingStorage.TieredFeeParams storage params = ss.settings.tieredFees;
        
        // Copy threshold and fee arrays
        uint256 length = params.thresholds.length;
        thresholds = new uint256[](length);
        feeBps = new uint256[](length);
        
        for (uint256 i = 0; i < length; i++) {
            thresholds[i] = params.thresholds[i];
            feeBps[i] = params.feeBps[i];
        }
        
        return (params.enabled, thresholds, feeBps);
    }

    /**
     * @notice Get modules settings
     * @return Current modules settings
     */
    function getModulesSettings()
        external
        view
        returns (LibStakingStorage.InternalModules memory)
    {
        return LibStakingStorage.stakingStorage().internalModules;
    }

    /**
     * @notice Get external modules settings
     * @return Current external modules settings
     */
    function getExternalModules()
        external
        view
        returns (LibStakingStorage.ExternalModules memory)
    {
        return LibStakingStorage.stakingStorage().externalModules;
    }

    /**
     * @notice Get verification status
     * @return lastVerified Last verification timestamp
     * @return allValid Whether all interfaces are valid
     */
    function getVerificationStatus()
        external
        view
        returns (uint256 lastVerified, bool allValid)
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        return (
            ss.moduleRegistry.lastVerificationTimestamp,
            ss.moduleRegistry.lastVerificationResult
        );
    }

    /**
     * @notice Get current treasury address
     * @return Current treasury address
     */
    function getTreasuryAddress() external view returns (address) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        return ss.settings.treasuryAddress;
    }

     /**
     * @notice Get currency used for staking
     * @return Staking currency token
     */
    function getStakingCurrency() external view returns (address) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        return address(ss.zicoToken);
    }

     /**
     * @notice Ckecks the behavior of colony repair regarding inconsistent data
     */
    function isForceOverrideInconsistentColonies() external view returns (bool) {
        return LibStakingStorage.stakingStorage().forceOverrideInconsistentColonies;
    }

    /**
     * @notice Get system-wide staking statistics for context
     * @return totalStakers Number of active stakers
     * @return totalStakedTokens Total number of staked tokens
     * @return averageTokensPerStaker Average tokens per staker
     */
    function getStakingSystemStats() external view returns (
        uint256 totalStakers,
        uint256 totalStakedTokens,
        uint256 averageTokensPerStaker
    ) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        totalStakers = ss.activeStakers.length;
        totalStakedTokens = ss.totalStakedSpecimens;
        
        if (totalStakers > 0) {
            averageTokensPerStaker = totalStakedTokens / totalStakers;
        }
        
        return (totalStakers, totalStakedTokens, averageTokensPerStaker);
    }

    /**
     * @notice Get tiered fees configuration details
     * @return thresholds Array of fee tier thresholds
     * @return feeBps Array of fee rates in basis points
     */
    function getTieredFeesConfiguration() external view returns (
        uint256[] memory thresholds,
        uint256[] memory feeBps
    ) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        return (
            ss.settings.tieredFees.thresholds,
            ss.settings.tieredFees.feeBps
        );
    }

    /**
     * @notice Get wear penalty configuration
     * @return thresholds Array of wear levels where penalties kick in
     * @return penalties Array of penalty percentages for each threshold
     */
    function getWearPenaltySettings() external view returns (
        uint8[] memory thresholds,
        uint8[] memory penalties
    ) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        return (
            ss.wearPenaltyThresholds,
            ss.wearPenaltyValues
        );
    }

    /**
     * @notice Get comprehensive staking system settings
     * @return stakingEnabled Whether staking is enabled
     * @return maxTokensPerStaker Maximum tokens per staker (0 = unlimited)
     * @return stakingCooldown Cooldown period after unstaking
     * @return minimumStakingPeriod Minimum time before unstaking
     * @return requirePowerCore Whether power core is required for staking
     * @return treasuryAddress Treasury address for fees
     * @return configVersion Configuration version
     * @return useAdditiveContextBonuses Whether additive context bonuses are used
     */
    function getStakingSystemSettings() external view returns (
        bool stakingEnabled,
        uint256 maxTokensPerStaker,
        uint256 stakingCooldown,
        uint256 minimumStakingPeriod,
        bool requirePowerCore,
        address treasuryAddress,
        uint256 configVersion,
        bool useAdditiveContextBonuses
    ) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        LibStakingStorage.RewardCalculationConfig storage rewardConfig = ss.rewardCalculationConfig;

        return (
            ss.stakingEnabled,
            ss.settings.maxTokensPerStaker,
            ss.settings.stakingCooldown,
            ss.settings.minimumStakingPeriod,
            ss.requirePowerCoreForStaking,
            ss.settings.treasuryAddress,
            ss.configVersion,
            rewardConfig.useAdditiveContextBonuses
        );
    }

    /**
     * @notice Get reward balance configuration
     * @return balanceEnabled Whether balance adjustment is enabled
     * @return decayRate Decay rate parameter
     * @return minMultiplier Minimum multiplier percentage
     * @return applyToInfusion Whether to apply to infusion rewards
     * @return timeEnabled Whether time decay is enabled
     * @return maxTimeBonus Maximum time-based bonus
     * @return timePeriod Period for maximum bonus
     * @return tieredFeesEnabled Whether tiered fees are enabled
     * @return maxTokensPerStaker Maximum tokens per staker (0 = unlimited)
     * @return useConfigurableDecay Whether configurable decay is set up
     */
    function getRewardBalanceConfiguration() external view returns (
        bool balanceEnabled,
        uint256 decayRate,
        uint256 minMultiplier,
        bool applyToInfusion,
        bool timeEnabled,
        uint256 maxTimeBonus,
        uint256 timePeriod,
        bool tieredFeesEnabled,
        uint256 maxTokensPerStaker,
        bool useConfigurableDecay
    ) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        LibStakingStorage.ProgressiveDecayConfig storage decayConfig = ss.progressiveDecayConfig;

        return (
            ss.settings.balanceAdjustment.enabled,
            ss.settings.balanceAdjustment.decayRate,
            ss.settings.balanceAdjustment.minMultiplier,
            ss.settings.balanceAdjustment.applyToInfusion,
            ss.settings.timeDecay.enabled,
            ss.settings.timeDecay.maxBonus,
            ss.settings.timeDecay.period,
            ss.settings.tieredFees.enabled,
            ss.settings.maxTokensPerStaker,
            (decayConfig.shareThresholds[0] > 0)
        );
    }

    /**
     * @notice Get wear system configuration
     * @return wearIncreasePerDay Daily wear increase rate (0 = disabled)
     * @return autoRepairEnabled Whether auto-repair is enabled
     * @return autoRepairThreshold Wear level that triggers auto-repair
     * @return autoRepairAmount Amount repaired during auto-repair
     * @return repairCostPerPoint Cost in ZICO per repair point
     * @return autoRepairInterval Time between auto-repairs
     * @return freeAutoRepair Whether auto-repair is free
     * @return useConfigurableThresholds Whether configurable thresholds are used
     * @return configuredThresholdCount Number of configured thresholds
     */
    function getWearSystemSettings() external view returns (
        uint256 wearIncreasePerDay,
        bool autoRepairEnabled,
        uint256 autoRepairThreshold,
        uint256 autoRepairAmount,
        uint256 repairCostPerPoint,
        uint256 autoRepairInterval,
        bool freeAutoRepair,
        bool useConfigurableThresholds,
        uint256 configuredThresholdCount
    ) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        LibStakingStorage.WearPenaltyConfig storage wearConfig = ss.wearPenaltyConfig;

        return (
            ss.wearIncreasePerDay,
            ss.wearAutoRepairConfig.enabled,
            ss.wearAutoRepairConfig.triggerThreshold,
            ss.wearAutoRepairConfig.repairAmount,
            ss.wearRepairCostPerPoint,
            ss.wearAutoRepairConfig.repairInterval,
            ss.wearAutoRepairConfig.freeAutoRepair,
            wearConfig.useConfigurableThresholds,
            wearConfig.wearThresholds.length
        );
    }

    /**
     * @notice Get current base reward rates for all variants
     * @return rates Array of base reward rates for variants 1-4
     */
    function getBaseRewardRates() external view returns (uint256[] memory rates) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        return ss.settings.baseRewardRates;
    }

}