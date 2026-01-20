// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {RewardCalcData, InfusionCalcData, StakeBalanceParams} from "../../../libraries/StakingModel.sol";
import {ChargeAccessory} from "../../../libraries/HenomorphsModel.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibStakingStorage} from "../libraries/LibStakingStorage.sol";

/**
 * @title RewardCalculator
 * @notice Shared reward calculation library
 * @author rutilicus.eth (ArchXS)
 */
library RewardCalculator {
    using Math for uint256;
    
    // Safety constants
    uint256 private constant MAX_SAFE_INTEGER = 2**200;
    uint256 private constant MAX_REWARD = 2**224;
    uint8 private constant MAX_LEVEL = 100;
    uint8 private constant MAX_VARIANT = 4;
    uint8 private constant MAX_CHARGE = 100;
    uint8 private constant MAX_WEAR = 100;
    
    // Time constants
    uint256 private constant SECONDS_PER_DAY = 86400;

    // Simple struct to reduce stack depth
    struct Multipliers {
        uint256 token;
        uint256 context; 
        uint256 balance;
    }

    /**
     * @notice Calculate base time reward
     */
    function calculateBaseTimeReward(uint8 variant, uint256 timeElapsed) 
        public 
        view 
        returns (uint256 baseReward) 
    {
        if (timeElapsed == 0) return 0;
        
        uint256 dailyRate = LibStakingStorage.getBaseDailyRewardRate(variant);
        uint256 safeTimeElapsed = timeElapsed > 365 days ? 365 days : timeElapsed;
        baseReward = Math.mulDiv(dailyRate, safeTimeElapsed, SECONDS_PER_DAY);
        
        return baseReward > MAX_SAFE_INTEGER ? MAX_SAFE_INTEGER : baseReward;
    }
    
    /**
     * @notice Process colony bonus with limits
     */
    function processColonyBonus(uint256 rawColonyBonus, uint256 adminLimit) 
        public 
        view 
        returns (uint256 processedBonus) 
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        LibStakingStorage.RewardCalculationConfig storage config = ss.rewardCalculationConfig;
        
        uint256 effectiveAdminLimit = adminLimit > 0 ? adminLimit : config.maxAdminColonyBonus;
        if (effectiveAdminLimit == 0) effectiveAdminLimit = 8;
        
        uint256 dynamicLimit = config.maxColonyBonus > 0 ? config.maxColonyBonus : 30;
        uint256 absoluteLimit = 35;
        
        if (rawColonyBonus <= effectiveAdminLimit) return rawColonyBonus;
        if (rawColonyBonus <= dynamicLimit) return rawColonyBonus;
        if (rawColonyBonus <= absoluteLimit) return dynamicLimit;
        
        return absoluteLimit;
    }

    /**
     * @notice Calculate accessory bonus
     */
    function calculateAccessoryBonus(
        ChargeAccessory[] memory accessories,
        uint8 specialization
    ) public view returns (uint256 accessoryBonus) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256 maxBonus = ss.rewardCalculationConfig.maxAccessoryBonus;
        if (maxBonus == 0) maxBonus = 40;
        
        if (accessories.length > 20) return 0;
        
        accessoryBonus = 0;
        for (uint256 i = 0; i < accessories.length; i++) {
            if (accessories[i].stakingBoostPercentage > 0) {
                accessoryBonus += accessories[i].stakingBoostPercentage;
                if (accessoryBonus >= maxBonus) return maxBonus;
            }
            
            if ((accessories[i].specializationType == 0 || 
                accessories[i].specializationType == specialization) && 
                specialization > 0 && 
                accessories[i].specializationBoostValue > 0) {
                
                uint256 specBonus = accessories[i].specializationBoostValue / 2;
                accessoryBonus += specBonus;
                if (accessoryBonus >= maxBonus) return maxBonus;
            }
            
            if (accessories[i].rare) {
                accessoryBonus += 5;
                if (accessoryBonus >= maxBonus) return maxBonus;
            }
        }
        
        return accessoryBonus;
    }
    
    /**
     * @notice Calculate reward from data - MAIN METHOD
     */
    function calculateRewardFromData(RewardCalcData memory data) 
        public 
        view 
        returns (uint256 amount) 
    {
        if (data.baseReward == 0) return 0;
        
        data = _applySafetyCaps(data);
        
        Multipliers memory mults;
        mults.token = _calculateTokenMultiplier(
            data.level, data.variant, data.chargeLevel, data.infusionLevel, data.specialization
        );
        
        mults.context = _calculateContextMultiplier(
            data.seasonMultiplier, data.colonyBonus, data.loyaltyBonus, data.accessoryBonus
        );
        
        amount = Math.mulDiv(
            data.baseReward, 
            Math.mulDiv(mults.token, mults.context, 100), 
            100
        );
        
        uint8 wearPenalty = data.wearPenalty > 0 ? data.wearPenalty : 
            uint8(LibStakingStorage.calculateWearPenalty(data.wearLevel));
        
        if (wearPenalty > 0) {
            amount = _applyWearPenalty(amount, wearPenalty);
        }
        
        return amount > MAX_REWARD ? MAX_REWARD : amount;
    }

    /**
     * @notice Calculate reward with stake balance adjustment - MAIN METHOD WITH BALANCE
     */
    function calculateRewardWithStakeBalance(
        RewardCalcData memory data,
        StakeBalanceParams memory params
    ) public view returns (uint256 amount) {
        if (data.baseReward == 0) return 0;
        
        amount = calculateRewardFromData(data);
        
        if (!params.balanceEnabled || amount == 0) return amount;
        
        uint256 balanceMultiplier = calculateStakeBalanceMultiplier(
            params.userStakedCount,
            params.totalStakedCount, 
            params.stakingDuration,
            params.balanceEnabled,
            params.decayRate,
            params.minMultiplier,
            params.timeEnabled,
            params.maxTimeBonus,
            params.timePeriod
        );
        
        amount = Math.mulDiv(amount, balanceMultiplier, 100);
        
        return amount > MAX_REWARD ? MAX_REWARD : amount;
    }

    /**
     * @notice Calculate stake balance multiplier
     */
    function calculateStakeBalanceMultiplier(
        uint256 userStakedCount,
        uint256 totalStakedCount,
        uint256 stakingDuration,
        bool balanceEnabled,
        uint256 decayRate,
        uint256 minMultiplier,
        bool timeEnabled,
        uint256 maxTimeBonus,
        uint256 timePeriod
    ) public pure returns (uint256 multiplier) {
        if (!balanceEnabled || totalStakedCount == 0) return 100;
        
        uint256 userShareBps = Math.mulDiv(userStakedCount, 10000, totalStakedCount);
        multiplier = _calculateBalanceMultiplier(userShareBps, decayRate, minMultiplier);
        
        if (timeEnabled && stakingDuration > 0) {
            multiplier += _calculateTimeBonus(stakingDuration, maxTimeBonus, timePeriod);
        }
        
        return multiplier;
    }

    // =================== INTERNAL HELPERS ===================

    /**
     * @notice Apply safety caps to data
     */
    function _applySafetyCaps(RewardCalcData memory data) 
        private 
        pure 
        returns (RewardCalcData memory) 
    {
        data.baseReward = data.baseReward > MAX_SAFE_INTEGER ? MAX_SAFE_INTEGER : data.baseReward;
        data.level = data.level > MAX_LEVEL ? MAX_LEVEL : data.level;
        data.variant = data.variant == 0 ? 1 : (data.variant > MAX_VARIANT ? MAX_VARIANT : data.variant);
        data.chargeLevel = data.chargeLevel > MAX_CHARGE ? MAX_CHARGE : data.chargeLevel;
        data.wearLevel = data.wearLevel > MAX_WEAR ? MAX_WEAR : data.wearLevel;
        data.colonyBonus = data.colonyBonus > 100 ? 100 : data.colonyBonus;
        data.seasonMultiplier = data.seasonMultiplier == 0 ? 100 : 
            (data.seasonMultiplier > 300 ? 300 : data.seasonMultiplier);
        data.loyaltyBonus = data.loyaltyBonus > 28 ? 28 : data.loyaltyBonus;
        data.accessoryBonus = data.accessoryBonus > 40 ? 40 : data.accessoryBonus;
        
        return data;
    }

    /**
     * @notice Apply wear penalty
     */
    function _applyWearPenalty(uint256 reward, uint8 wearPenalty) 
        private 
        pure 
        returns (uint256) 
    {
        if (wearPenalty == 0 || reward == 0) return reward;
        
        uint8 safePenalty = wearPenalty > 92 ? 92 : wearPenalty;
        uint256 penaltyMultiplier = 100 - safePenalty;
        return Math.mulDiv(reward, penaltyMultiplier, 100);
    }

    /**
     * @notice Calculate balance multiplier
     */
    function _calculateBalanceMultiplier(
        uint256 userShareBps,
        uint256 decayRate,
        uint256 minMultiplier
    ) private pure returns (uint256 multiplier) {
        uint256 decayAmount = _calculateDecay(userShareBps, decayRate);
        
        if (decayAmount >= 100) {
            multiplier = minMultiplier;
        } else {
            multiplier = 100 - decayAmount;
            if (multiplier < minMultiplier) {
                multiplier = minMultiplier;
            }
        }
        
        return multiplier;
    }

    /**
     * @notice Calculate decay amount
     */
    function _calculateDecay(uint256 userShareBps, uint256 baseDecayRate) 
        private 
        pure 
        returns (uint256 decayAmount) 
    {
        if (userShareBps <= 100) { // 1%
            return 0;
        } else if (userShareBps <= 500) { // 5%
            return Math.mulDiv(userShareBps - 100, baseDecayRate, 500);
        } else if (userShareBps <= 1000) { // 10%
            return 2 + Math.mulDiv(userShareBps - 500, baseDecayRate, 250);
        } else if (userShareBps <= 2000) { // 20%
            return 4 + Math.mulDiv(userShareBps - 1000, baseDecayRate * 3, 500);
        } else {
            uint256 excessDecay = Math.mulDiv(userShareBps - 2000, baseDecayRate, 400);
            uint256 totalDecay = 10 + excessDecay;
            return totalDecay > 30 ? 30 : totalDecay;
        }
    }

    /**
     * @notice Calculate time bonus
     */
    function _calculateTimeBonus(uint256 stakingDuration, uint256 maxTimeBonus, uint256 timePeriod) 
        private 
        pure 
        returns (uint256) 
    {
        uint256 effectiveMaxBonus = maxTimeBonus > 25 ? 16 : maxTimeBonus;
        uint256 effectivePeriod = timePeriod == 0 ? (90 * SECONDS_PER_DAY) : timePeriod;
        
        if (stakingDuration >= effectivePeriod) {
            return effectiveMaxBonus;
        } else {
            return Math.mulDiv(stakingDuration, effectiveMaxBonus, effectivePeriod);
        }
    }

    /**
     * @notice Calculate token multiplier - REDUCED STACK USAGE
     */
    function _calculateTokenMultiplier(
        uint8 level,
        uint8 variant, 
        uint8 chargeLevel,
        uint8 infusionLevel,
        uint8 specialization
    ) private view returns (uint256) {
        uint256 multiplier = 100;
        
        multiplier += _getLevelBonus(level);
        
        if (variant > 1) {
            multiplier += _getVariantBonus(variant);
        }
        
        multiplier += _getChargeBonus(chargeLevel);
        multiplier += _getInfusionBonus(infusionLevel);
        multiplier += _getSpecializationBonus(specialization);
        
        return multiplier;
    }

    /**
     * @notice Calculate context multiplier - REDUCED STACK USAGE
     */
    function _calculateContextMultiplier(
        uint256 seasonMultiplier,
        uint256 colonyBonus, 
        uint256 loyaltyBonus,
        uint256 accessoryBonus
    ) private view returns (uint256) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        LibStakingStorage.RewardCalculationConfig storage config = ss.rewardCalculationConfig;
        
        bool useAdditive = config.useAdditiveContextBonuses || ss.configVersion >= 2;
        uint256 maxCombined = config.maxCombinedContextBonus > 0 ? 
                            config.maxCombinedContextBonus : 50;
        
        if (useAdditive) {
            uint256 totalContextBonus = colonyBonus + loyaltyBonus + accessoryBonus;
            
            if (totalContextBonus > maxCombined) {
                totalContextBonus = maxCombined;
            }
            
            uint256 baseWithContext = 100 + totalContextBonus;
            uint256 safeSeasonMultiplier = seasonMultiplier > 150 ? 150 : seasonMultiplier;
            if (safeSeasonMultiplier == 0) safeSeasonMultiplier = 100;
            
            return Math.mulDiv(baseWithContext, safeSeasonMultiplier, 100);
        } else {
            uint256 multiplier = seasonMultiplier == 0 ? 100 : seasonMultiplier;
            
            multiplier = Math.mulDiv(multiplier, (100 + colonyBonus), 100);
            multiplier = Math.mulDiv(multiplier, (100 + loyaltyBonus), 100);
            multiplier = Math.mulDiv(multiplier, (100 + accessoryBonus), 100);
            
            return multiplier;
        }
    }

    // =================== BONUS GETTERS ===================

    function _getLevelBonus(uint8 level) private view returns (uint256) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        LibStakingStorage.RewardCalculationConfig storage config = ss.rewardCalculationConfig;
        
        if (config.levelBonusDenominator > 0) {
            uint256 levelBonus = Math.mulDiv(level, config.levelBonusNumerator, config.levelBonusDenominator);
            return levelBonus > config.maxLevelBonus ? config.maxLevelBonus : levelBonus;
        }
        
        return (level * 40) / 100; // 0.4% per level fallback
    }

    function _getVariantBonus(uint8 variant) private view returns (uint256) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        LibStakingStorage.RewardCalculationConfig storage config = ss.rewardCalculationConfig;
        
        if (config.variantBonusPercentPerLevel > 0) {
            uint256 variantBonus = (variant - 1) * config.variantBonusPercentPerLevel;
            return variantBonus > config.maxVariantBonus ? config.maxVariantBonus : variantBonus;
        }
        
        return (variant - 1) * 4; // 4% per variant fallback
    }

    function _getChargeBonus(uint8 chargeLevel) private view returns (uint256) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        LibStakingStorage.RewardCalculationConfig storage config = ss.rewardCalculationConfig;
        
        if (config.chargeBonusThresholds[0] > 0) {
            for (uint256 i = 3; i > 0; i--) {
                if (chargeLevel >= config.chargeBonusThresholds[i]) {
                    return config.chargeBonusValues[i];
                }
            }
            return config.chargeBonusValues[0];
        }
        
        if (chargeLevel >= 80) return 10;
        if (chargeLevel >= 60) return 6;
        if (chargeLevel >= 40) return 3;
        return 0;
    }

    function _getInfusionBonus(uint8 infusionLevel) private view returns (uint256) {
        if (infusionLevel == 0 || infusionLevel > 5) return 0;
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        LibStakingStorage.RewardCalculationConfig storage config = ss.rewardCalculationConfig;
        
        if (config.infusionBonuses[infusionLevel] > 0) {
            return config.infusionBonuses[infusionLevel];
        }
        
        if (infusionLevel == 1) return 8;
        if (infusionLevel == 2) return 12;
        if (infusionLevel == 3) return 16;
        if (infusionLevel == 4) return 20;
        if (infusionLevel == 5) return 28;
        
        return 0;
    }

    function _getSpecializationBonus(uint8 specialization) private view returns (uint256) {
        if (specialization == 0 || specialization > 5) return 0;
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        LibStakingStorage.RewardCalculationConfig storage config = ss.rewardCalculationConfig;
        
        if (config.specializationBonuses[specialization] > 0) {
            return config.specializationBonuses[specialization];
        }
        
        if (specialization == 1) return 4;  // Efficiency: 4%
        if (specialization == 2) return 6;  // Regeneration: 6%
        
        return 0;
    }

    // =================== INFUSION CALCULATION ===================

    /**
     * @notice Calculate infusion reward
     */
    function calculateInfusionRewardFromData(InfusionCalcData memory data)
        public 
        view
        returns (uint256 amount)
    {
        if (data.infusedAmount == 0 || data.timeElapsed == 0) return 0;
        
        uint256 safeApr = data.apr == 0 ? 1 : data.apr;
        uint256 safeAmount = data.infusedAmount > MAX_SAFE_INTEGER ? MAX_SAFE_INTEGER : data.infusedAmount;
        uint256 safeTimeElapsed = data.timeElapsed > 365 days ? 365 days : data.timeElapsed;
        safeApr = safeApr > 200 ? 200 : safeApr;
        
        uint256 yearInSeconds = 365 days;
        
        amount = Math.mulDiv(
            Math.mulDiv(safeAmount, safeApr, 100),
            safeTimeElapsed,
            yearInSeconds
        );
        
        if (data.intelligence > 0) {
            uint8 safeIntelligence = data.intelligence > 100 ? 100 : data.intelligence;
            uint256 intelligenceBonus = Math.mulDiv(safeIntelligence, 25, 100);
            if (intelligenceBonus > 0) {
                amount = Math.mulDiv(amount, (100 + intelligenceBonus), 100);
            }
        }
        
        if (data.wearLevel > 0) {
            uint8 safeWearLevel = data.wearLevel > MAX_WEAR ? MAX_WEAR : data.wearLevel;
            uint256 calculatedPenalty = LibStakingStorage.calculateWearPenalty(safeWearLevel);
            if (calculatedPenalty > 0) {
                amount = _applyWearPenalty(amount, uint8(calculatedPenalty));
            }
        }
        
        return amount > MAX_REWARD ? MAX_REWARD : amount;
    }

    /**
     * @notice Calculate infusion APR
     */
    function calculateInfusionAPR(
        uint256 baseAPR,
        uint8 variant,
        uint8 infusionLevel,
        uint256 seasonMultiplier
    ) public pure returns (uint256 apr) {
        uint256 safeBaseAPR = baseAPR > 100 ? 100 : baseAPR;
        uint8 safeVariant = variant == 0 ? 1 : (variant > MAX_VARIANT ? MAX_VARIANT : variant);
        uint8 safeInfusionLevel = infusionLevel > 5 ? 5 : infusionLevel;
        uint256 safeSeasonMultiplier = seasonMultiplier == 0 ? 100 : 
            (seasonMultiplier > 300 ? 300 : seasonMultiplier);
        
        apr = safeBaseAPR;
        apr += (uint256(safeVariant) * 5);
        
        if (safeInfusionLevel == 1) apr += 8;
        else if (safeInfusionLevel == 2) apr += 12;
        else if (safeInfusionLevel == 3) apr += 16;
        else if (safeInfusionLevel == 4) apr += 20;
        else if (safeInfusionLevel == 5) apr += 28;
        
        apr = Math.mulDiv(apr, safeSeasonMultiplier, 100);
        return apr > 200 ? 200 : apr;
    }
}