// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibStakingStorage} from "../libraries/LibStakingStorage.sol";
import {PodRewardRate, InfusionBonus} from "../../libraries/StakingModel.sol";
import {AccessControlBase} from "./AccessControlBase.sol";

/**
 * @title StakingRewardConfigurationFacet
 * @notice Dedicated facet for reward calculation configuration
 * @dev Contains all functions related to reward calculation parameters
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract StakingRewardConfigurationFacet is AccessControlBase {
    
    // Events specific to reward configuration
    event RewardCalculationConfigUpdated(string parameter, uint256 oldValue, uint256 newValue);
    event WearPenaltyConfigUpdated(bool useConfigurable, uint256 thresholdCount);
    event LoyaltyBonusConfigUpdated(bool enabled, uint256 maxBonus);
    event ProgressiveDecayConfigUpdated(uint256 baseDecayRate, uint256 minMultiplier);
    event TimeBonusConfigUpdated(bool enabled, uint256 maxBonus, bool applyToInfusion);
    event ConfigurationInitialized(uint256 configVersion);
    event BalanceAdjustmentConfigured(bool enabled, uint256 decayRate, uint256 minMultiplier, bool applyToInfusion);
    event TimeDecayConfigured(bool enabled, uint256 maxBonus, uint256 period);
    event BaseRewardRatesSet(PodRewardRate[] rates);
    event InfusionBonusesSet(InfusionBonus[] bonuses);
    event LevelMultipliersUpdated(uint256[] multipliers);
    event InfusionAPRUpdated(uint256 baseAPR, uint256 bonusPerVariant);
    event MaxInfusionByVariantSet(uint8 variant, uint256 maxAmount);
    
    // Errors specific to reward configuration
    error InvalidParameter();
    error MismatchedArrayLengths();
    error InvalidWearThresholds();
    error InvalidWearPenalties();
    error ConfigurationNotInitialized();
    error InvalidBonusConfiguration();

    /**
     * @notice Initialize configuration system with default values
     * @dev Should be called once during deployment or when upgrading to this version
     */
    function initializeConfiguration() external onlyAuthorized whenNotPaused {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Check if already initialized
        if (ss.configVersion > 0) {
            return; // Already initialized
        }
        
        // Initialize default configuration
        LibStakingStorage.initializeDefaultConfiguration();
        
        emit ConfigurationInitialized(ss.configVersion);
    }

    /**
     * @notice Configure reward calculation parameters
     * @param levelBonusNumerator Numerator for level bonus calculation (e.g., 50 for 0.5%)
     * @param levelBonusDenominator Denominator for level bonus calculation (e.g., 100)
     * @param maxLevelBonus Maximum level bonus percentage
     * @param variantBonusPerLevel Bonus percentage per variant level
     * @param maxVariantBonus Maximum variant bonus percentage
     */
    function configureRewardCalculation(
        uint256 levelBonusNumerator,
        uint256 levelBonusDenominator, 
        uint256 maxLevelBonus,
        uint256 variantBonusPerLevel,
        uint256 maxVariantBonus
    ) external onlyAuthorized whenNotPaused {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Ensure configuration is initialized
        if (ss.configVersion == 0) {
            revert ConfigurationNotInitialized();
        }
        
        // Validate parameters
        if (levelBonusDenominator == 0 || maxLevelBonus > 100 || maxVariantBonus > 50) {
            revert InvalidParameter();
        }
        
        LibStakingStorage.RewardCalculationConfig storage config = ss.rewardCalculationConfig;
        
        // Update parameters
        uint256 oldLevelNum = config.levelBonusNumerator;
        config.levelBonusNumerator = levelBonusNumerator;
        config.levelBonusDenominator = levelBonusDenominator;
        config.maxLevelBonus = maxLevelBonus;
        config.variantBonusPercentPerLevel = variantBonusPerLevel;
        config.maxVariantBonus = maxVariantBonus;
        
        emit RewardCalculationConfigUpdated("levelBonusNumerator", oldLevelNum, levelBonusNumerator);
    }

    /**
     * @notice Configure charge level bonuses
     * @param thresholds Array of 4 charge level thresholds
     * @param bonuses Array of 4 bonus percentages
     */
    function configureChargeBonuses(
        uint8[4] calldata thresholds,
        uint8[4] calldata bonuses
    ) external onlyAuthorized whenNotPaused {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        if (ss.configVersion == 0) {
            revert ConfigurationNotInitialized();
        }
        
        // Validate ascending order for thresholds
        for (uint256 i = 1; i < 4; i++) {
            if (thresholds[i] <= thresholds[i-1]) {
                revert InvalidParameter();
            }
        }
        
        // Validate bonuses are reasonable
        for (uint256 i = 0; i < 4; i++) {
            if (bonuses[i] > 50) { // Max 50% bonus per threshold
                revert InvalidParameter();
            }
        }
        
        LibStakingStorage.RewardCalculationConfig storage config = ss.rewardCalculationConfig;
        config.chargeBonusThresholds = thresholds;
        config.chargeBonusValues = bonuses;
        
        emit RewardCalculationConfigUpdated("chargeBonuses", 0, thresholds.length);
    }

    /**
     * @notice Configure infusion level bonuses
     * @param bonuses Array of bonuses for infusion levels 1-5 (index 0 unused)
     */
    function configureInfusionBonuses(uint8[6] calldata bonuses) external onlyAuthorized whenNotPaused {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        if (ss.configVersion == 0) {
            revert ConfigurationNotInitialized();
        }
        
        // Validate bonuses are reasonable and ascending
        for (uint256 i = 1; i < 6; i++) {
            if (bonuses[i] > 50) { // Max 50% bonus
                revert InvalidParameter();
            }
            if (i > 1 && bonuses[i] < bonuses[i-1]) { // Should be ascending
                revert InvalidParameter();
            }
        }
        
        LibStakingStorage.RewardCalculationConfig storage config = ss.rewardCalculationConfig;
        config.infusionBonuses = bonuses;
        
        emit RewardCalculationConfigUpdated("infusionBonuses", 0, bonuses.length);
    }

    /**
     * @notice Configure specialization bonuses
     * @param bonuses Array of bonuses for specializations 0-5
     */
    function configureSpecializationBonuses(uint8[6] calldata bonuses) external onlyAuthorized whenNotPaused {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        if (ss.configVersion == 0) {
            revert ConfigurationNotInitialized();
        }
        
        // Validate bonuses are reasonable
        for (uint256 i = 0; i < 6; i++) {
            if (bonuses[i] > 25) { // Max 25% bonus per specialization
                revert InvalidParameter();
            }
        }
        
        LibStakingStorage.RewardCalculationConfig storage config = ss.rewardCalculationConfig;
        config.specializationBonuses = bonuses;
        
        emit RewardCalculationConfigUpdated("specializationBonuses", 0, bonuses.length);
    }

    /**
     * @notice CRITICAL: Configure context multiplier behavior
     * @param useAdditive Whether to use additive (true) or multiplicative (false) context bonuses
     * @param maxCombinedBonus Maximum combined context bonus percentage
     */
    function configureContextMultiplier(
        bool useAdditive,
        uint256 maxCombinedBonus
    ) external onlyAuthorized whenNotPaused {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        if (ss.configVersion == 0) {
            revert ConfigurationNotInitialized();
        }
        
        if (maxCombinedBonus > 300) { // Max 300% total context bonus
            revert InvalidParameter();
        }
        
        LibStakingStorage.RewardCalculationConfig storage config = ss.rewardCalculationConfig;
        uint256 oldValue = config.useAdditiveContextBonuses ? 1 : 0;
        
        config.useAdditiveContextBonuses = useAdditive;
        config.maxCombinedContextBonus = maxCombinedBonus;
        
        emit RewardCalculationConfigUpdated("useAdditiveContextBonuses", oldValue, useAdditive ? 1 : 0);
    }

    /**
     * @notice Configure enhanced wear penalty system
     * @param useConfigurable Whether to use configurable thresholds
     * @param thresholds Array of wear level thresholds
     * @param penalties Array of penalty percentages
     * @param maxPenalty Maximum penalty percentage
     */
    function configureWearPenalties(
        bool useConfigurable,
        uint8[] calldata thresholds,
        uint8[] calldata penalties,
        uint8 maxPenalty
    ) external onlyAuthorized whenNotPaused {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        if (ss.configVersion == 0) {
            revert ConfigurationNotInitialized();
        }
        
        if (thresholds.length != penalties.length || thresholds.length == 0) {
            revert MismatchedArrayLengths();
        }
        
        if (maxPenalty > 95) { // Max 95% penalty
            revert InvalidParameter();
        }
        
        // Validate ascending order
        for (uint256 i = 1; i < thresholds.length; i++) {
            if (thresholds[i] <= thresholds[i-1]) {
                revert InvalidWearThresholds();
            }
            if (penalties[i] < penalties[i-1]) {
                revert InvalidWearPenalties();
            }
        }
        
        LibStakingStorage.WearPenaltyConfig storage config = ss.wearPenaltyConfig;
        config.useConfigurableThresholds = useConfigurable;
        config.maxWearPenalty = maxPenalty;
        
        // Clear and set new arrays
        delete config.wearThresholds;
        delete config.wearPenalties;
        
        for (uint256 i = 0; i < thresholds.length; i++) {
            config.wearThresholds.push(thresholds[i]);
            config.wearPenalties.push(penalties[i]);
        }
        
        emit WearPenaltyConfigUpdated(useConfigurable, thresholds.length);
    }

    /**
     * @notice Configure loyalty bonus system
     * @param enabled Whether loyalty bonuses are enabled
     * @param durationThresholds Array of duration thresholds in days
     * @param bonusPercentages Array of bonus percentages
     * @param maxBonus Maximum loyalty bonus percentage
     */
    function configureLoyaltyBonuses(
        bool enabled,
        uint256[] calldata durationThresholds,
        uint256[] calldata bonusPercentages,
        uint256 maxBonus
    ) external onlyAuthorized whenNotPaused {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        if (ss.configVersion == 0) {
            revert ConfigurationNotInitialized();
        }
        
        if (durationThresholds.length != bonusPercentages.length) {
            revert MismatchedArrayLengths();
        }
        
        if (maxBonus > 50) { // Max 50% loyalty bonus
            revert InvalidParameter();
        }
        
        // Validate ascending order
        for (uint256 i = 1; i < durationThresholds.length; i++) {
            if (durationThresholds[i] <= durationThresholds[i-1]) {
                revert InvalidParameter();
            }
            if (bonusPercentages[i] < bonusPercentages[i-1]) {
                revert InvalidParameter();
            }
        }
        
        LibStakingStorage.LoyaltyBonusConfig storage config = ss.loyaltyBonusConfig;
        config.enabled = enabled;
        config.maxLoyaltyBonus = maxBonus;
        
        // Clear and set new arrays
        delete config.durationThresholds;
        delete config.bonusPercentages;
        
        for (uint256 i = 0; i < durationThresholds.length; i++) {
            // Convert days to seconds
            config.durationThresholds.push(durationThresholds[i] * LibStakingStorage.SECONDS_PER_DAY);
            config.bonusPercentages.push(bonusPercentages[i]);
        }
        
        emit LoyaltyBonusConfigUpdated(enabled, maxBonus);
    }

    /**
     * @notice CRITICAL: Configure progressive decay system
     * @param shareThresholds Array of 4 share thresholds in basis points
     * @param decayMultipliers Array of 4 decay multipliers
     * @param maxDecayPercentage Maximum decay percentage
     * @param baseDecayRate Base decay rate
     * @param minMultiplier Minimum multiplier percentage
     */
    function configureProgressiveDecay(
        uint256[4] calldata shareThresholds,
        uint256[4] calldata decayMultipliers,
        uint256 maxDecayPercentage,
        uint256 baseDecayRate,
        uint256 minMultiplier
    ) external onlyAuthorized whenNotPaused {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        if (ss.configVersion == 0) {
            revert ConfigurationNotInitialized();
        }
        
        // Validate parameters
        if (maxDecayPercentage > 50 || baseDecayRate > 50 || minMultiplier < 10 || minMultiplier > 95) {
            revert InvalidParameter();
        }
        
        // Validate ascending share thresholds
        for (uint256 i = 1; i < 4; i++) {
            if (shareThresholds[i] <= shareThresholds[i-1]) {
                revert InvalidParameter();
            }
        }
        
        LibStakingStorage.ProgressiveDecayConfig storage config = ss.progressiveDecayConfig;
        uint256 oldDecayRate = config.baseDecayRate;
        uint256 oldMinMultiplier = config.minMultiplier;
        
        config.shareThresholds = shareThresholds;
        config.decayMultipliers = decayMultipliers;
        config.maxDecayPercentage = maxDecayPercentage;
        config.baseDecayRate = baseDecayRate;
        config.minMultiplier = minMultiplier;
        
        // Also update the existing balance adjustment settings for immediate effect
        ss.settings.balanceAdjustment.decayRate = baseDecayRate;
        ss.settings.balanceAdjustment.minMultiplier = minMultiplier;
        
        emit ProgressiveDecayConfigUpdated(baseDecayRate, minMultiplier);
        emit RewardCalculationConfigUpdated("baseDecayRate", oldDecayRate, baseDecayRate);
        emit RewardCalculationConfigUpdated("minMultiplier", oldMinMultiplier, minMultiplier);
    }

    /**
     * @notice CRITICAL: Configure time bonus system
     * @param enabled Whether time bonuses are enabled
     * @param maxTimeBonus Maximum time bonus percentage
     * @param timePeriodDays Time period in days to reach maximum bonus
     * @param applyToInfusion Whether to apply time bonus to infusion rewards
     */
    function configureTimeBonus(
        bool enabled,
        uint256 maxTimeBonus,
        uint256 timePeriodDays,
        bool applyToInfusion
    ) external onlyAuthorized whenNotPaused {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        if (ss.configVersion == 0) {
            revert ConfigurationNotInitialized();
        }
        
        if (maxTimeBonus > 50 || timePeriodDays == 0 || timePeriodDays > 730) { // Max 50% bonus, max 2 years
            revert InvalidParameter();
        }
        
        LibStakingStorage.TimeBonusConfig storage config = ss.timeBonusConfig;
        uint256 oldMaxBonus = config.maxTimeBonus;
        
        config.enabled = enabled;
        config.maxTimeBonus = maxTimeBonus;
        config.timePeriod = timePeriodDays * LibStakingStorage.SECONDS_PER_DAY;
        config.applyToInfusion = applyToInfusion;
        
        // Also update existing time decay settings for immediate effect
        ss.settings.timeDecay.enabled = enabled;
        ss.settings.timeDecay.maxBonus = maxTimeBonus;
        ss.settings.timeDecay.period = timePeriodDays * LibStakingStorage.SECONDS_PER_DAY;
        
        emit TimeBonusConfigUpdated(enabled, maxTimeBonus, applyToInfusion);
        emit RewardCalculationConfigUpdated("maxTimeBonus", oldMaxBonus, maxTimeBonus);
    }

    /**
     * @notice Configure balance adjustment parameters for reward calculations
     * @param enabled Whether balance adjustment is enabled
     * @param decayRate Decay rate parameter for balance adjustment
     * @param minMultiplier Minimum multiplier percentage (e.g., 75 = 75%)
     * @param applyToInfusion Whether to apply adjustment to infusion rewards
     */
    function configureBalanceAdjustment(
        bool enabled,
        uint256 decayRate,
        uint256 minMultiplier,
        bool applyToInfusion
    ) external onlyAuthorized whenNotPaused {
        // Validate parameters
        if (decayRate > 100 || minMultiplier > 100 || minMultiplier == 0) {
            revert InvalidParameter();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Update balance adjustment settings
        ss.settings.balanceAdjustment.enabled = enabled;
        ss.settings.balanceAdjustment.decayRate = decayRate;
        ss.settings.balanceAdjustment.minMultiplier = minMultiplier;
        ss.settings.balanceAdjustment.applyToInfusion = applyToInfusion;
        
        emit BalanceAdjustmentConfigured(enabled, decayRate, minMultiplier, applyToInfusion);
    }

    /**
     * @notice Configure time-based decay parameters for staking rewards
     * @param enabled Whether time decay is enabled
     * @param maxBonus Maximum time-based bonus percentage (e.g., 30 = 30%)
     * @param period Time period to reach maximum bonus (in seconds)
     */
    function configureTimeDecay(
        bool enabled,
        uint256 maxBonus,
        uint256 period
    ) external onlyAuthorized whenNotPaused {
        // Validate parameters
        if (maxBonus > 100 || period == 0) {
            revert InvalidParameter();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Update time decay settings
        ss.settings.timeDecay.enabled = enabled;
        ss.settings.timeDecay.maxBonus = maxBonus;
        ss.settings.timeDecay.period = period;
        
        emit TimeDecayConfigured(enabled, maxBonus, period);
    }

    /**
     * @notice Set base reward rates for variants
     * @param rates Array of reward rates
     */
    function setBaseRewardRates(uint256[] calldata rates) external onlyAuthorized whenNotPaused {
        if (rates.length != 4) {
            revert InvalidParameter();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Clear existing rates
        while (ss.settings.baseRewardRates.length > 0) {
            ss.settings.baseRewardRates.pop();
        }
        
        // Set new rates
        for (uint256 i = 0; i < rates.length; i++) {
            ss.settings.baseRewardRates.push(rates[i]);
        }
        
        // Prepare data for event emission according to PodRewardRate structure
        PodRewardRate[] memory rateObjects = new PodRewardRate[](rates.length);
        for (uint256 i = 0; i < rates.length; i++) {
            rateObjects[i] = PodRewardRate({
                variant: uint8(i + 1),
                baseRate: rates[i]
            });
        }
        
        emit BaseRewardRatesSet(rateObjects);
    }
    
    /**
     * @notice Set level multipliers
     * @param multipliers Array of level multipliers
     */
    function setLevelMultipliers(uint256[] calldata multipliers) external onlyAuthorized whenNotPaused {
        if (multipliers.length != 5) {
            revert InvalidParameter();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Clear existing multipliers
        while (ss.settings.levelRewardMultipliers.length > 0) {
            ss.settings.levelRewardMultipliers.pop();
        }
        
        // Set new multipliers
        for (uint256 i = 0; i < multipliers.length; i++) {
            ss.settings.levelRewardMultipliers.push(multipliers[i]);
        }
        
        emit LevelMultipliersUpdated(multipliers);
    }
    
    /**
     * @notice Update infusion APR settings
     * @param baseAPR Base APR
     * @param bonusPerVariant Bonus APR per variant
     */
    function updateInfusionAPR(uint256 baseAPR, uint256 bonusPerVariant) external onlyAuthorized whenNotPaused {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Use system limits for validation
        uint256 maxAPR = ss.systemLimits.maxInfusionAPR > 0 ? ss.systemLimits.maxInfusionAPR : 50;
        uint256 maxBonusAPR = ss.systemLimits.maxInfusionBonusPerVariant > 0 ? ss.systemLimits.maxInfusionBonusPerVariant : 20;
        
        if (baseAPR > maxAPR || bonusPerVariant > maxBonusAPR) {
            revert InvalidParameter();
        }
        
        ss.settings.baseInfusionAPR = baseAPR;
        ss.settings.bonusInfusionAPRPerVariant = bonusPerVariant;
        
        emit InfusionAPRUpdated(baseAPR, bonusPerVariant);
    }
    
    /**
     * @notice Set infusion level bonus
     * @param level Infusion level (1-5)
     * @param bonusPercent Percentage bonus
     */
    function setInfusionLevelBonus(uint8 level, uint16 bonusPercent) external onlyAuthorized whenNotPaused {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Use system limits for validation
        uint256 maxBonus = ss.systemLimits.maxInfusionBonusPercent > 0 ? ss.systemLimits.maxInfusionBonusPercent : 50;
        
        if (level < 1 || level > 5 || bonusPercent > maxBonus) {
            revert InvalidParameter();
        }
        
        ss.settings.infusionBonuses[level] = bonusPercent;
        
        // Prepare data for event emission according to InfusionBonus structure
        InfusionBonus[] memory bonuses = new InfusionBonus[](1);
        bonuses[0] = InfusionBonus({
            infusionLevel: level,
            bonusPercent: bonusPercent
        });
        
        emit InfusionBonusesSet(bonuses);
    }
    
    /**
     * @notice Set maximum infusion amount for variant
     * @param variant Variant (1-4)
     * @param maxAmount Maximum infusion amount
     */
    function setMaxInfusionAmount(uint8 variant, uint256 maxAmount) external onlyAuthorized whenNotPaused {
        if (variant < 1 || variant > 4) {
            revert InvalidParameter();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        ss.settings.baseMaxInfusionByVariant[variant] = maxAmount;
        
        emit MaxInfusionByVariantSet(variant, maxAmount);
    }

    /**
     * @notice Configure all reward balance settings in one transaction
     * @param balanceEnabled Whether balance adjustment is enabled
     * @param decayRate Decay rate for balance adjustment
     * @param minMultiplier Minimum multiplier percentage
     * @param applyToInfusion Whether to apply to infusion rewards
     * @param timeEnabled Whether time decay is enabled
     * @param maxTimeBonus Maximum time bonus percentage
     * @param timePeriod Time period for maximum bonus
     * @param maxTokensPerStaker Maximum tokens per staker (0 = unlimited)
     */
    function configureRewardBalanceSettings(
        bool balanceEnabled,
        uint256 decayRate,
        uint256 minMultiplier,
        bool applyToInfusion,
        bool timeEnabled,
        uint256 maxTimeBonus,
        uint256 timePeriod,
        uint256 maxTokensPerStaker
    ) external onlyAuthorized whenNotPaused {
        // Validate parameters
        if (decayRate > 100 || minMultiplier > 100 || minMultiplier == 0 ||
            maxTimeBonus > 100 || timePeriod == 0) {
            revert InvalidParameter();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Configure balance adjustment
        ss.settings.balanceAdjustment.enabled = balanceEnabled;
        ss.settings.balanceAdjustment.decayRate = decayRate;
        ss.settings.balanceAdjustment.minMultiplier = minMultiplier;
        ss.settings.balanceAdjustment.applyToInfusion = applyToInfusion;
        
        // Configure time decay
        ss.settings.timeDecay.enabled = timeEnabled;
        ss.settings.timeDecay.maxBonus = maxTimeBonus;
        ss.settings.timeDecay.period = timePeriod;
        
        // Set max tokens per staker
        ss.settings.maxTokensPerStaker = maxTokensPerStaker;
        
        emit BalanceAdjustmentConfigured(balanceEnabled, decayRate, minMultiplier, applyToInfusion);
        emit TimeDecayConfigured(timeEnabled, maxTimeBonus, timePeriod);
    }

    // View functions for configuration access

    /**
     * @notice Get current reward calculation configuration
     */
    function getRewardCalculationConfig() 
        external 
        view 
        returns (LibStakingStorage.RewardCalculationConfig memory config) 
    {
        return LibStakingStorage.getRewardCalculationConfig();
    }

    /**
     * @notice Get current wear penalty configuration
     */
    function getWearPenaltyConfig() 
        external 
        view 
        returns (LibStakingStorage.WearPenaltyConfig memory config) 
    {
        return LibStakingStorage.getWearPenaltyConfig();
    }

    /**
     * @notice Get current loyalty bonus configuration
     */
    function getLoyaltyBonusConfig() 
        external 
        view 
        returns (LibStakingStorage.LoyaltyBonusConfig memory config) 
    {
        return LibStakingStorage.getLoyaltyBonusConfig();
    }

    /**
     * @notice Get current progressive decay configuration
     */
    function getProgressiveDecayConfig() 
        external 
        view 
        returns (LibStakingStorage.ProgressiveDecayConfig memory config) 
    {
        return LibStakingStorage.getProgressiveDecayConfig();
    }

    /**
     * @notice Get current time bonus configuration
     */
    function getTimeBonusConfig() 
        external 
        view 
        returns (LibStakingStorage.TimeBonusConfig memory config) 
    {
        return LibStakingStorage.getTimeBonusConfig();
    }

    /**
     * @notice Get base reward rates
     */
    function getBaseRewardRates() external view returns (uint256[] memory) {
        return LibStakingStorage.stakingStorage().settings.baseRewardRates;
    }

    /**
     * @notice Get level multipliers
     */
    function getLevelMultipliers() external view returns (uint256[] memory) {
        return LibStakingStorage.stakingStorage().settings.levelRewardMultipliers;
    }

    /**
     * @notice Get infusion APR settings
     */
    function getInfusionAPRSettings() external view returns (uint256 baseAPR, uint256 bonusPerVariant) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        return (ss.settings.baseInfusionAPR, ss.settings.bonusInfusionAPRPerVariant);
    }

    /**
     * @notice Get infusion level bonus
     */
    function getInfusionLevelBonus(uint8 level) external view returns (uint256) {
        if (level < 1 || level > 5) {
            return 0;
        }
        return LibStakingStorage.stakingStorage().settings.infusionBonuses[level];
    }

    /**
     * @notice Get maximum infusion amount for variant
     */
    function getMaxInfusionAmount(uint8 variant) external view returns (uint256) {
        if (variant < 1 || variant > 4) {
            return 0;
        }
        return LibStakingStorage.stakingStorage().settings.baseMaxInfusionByVariant[variant];
    }
}