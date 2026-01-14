// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibGamingStorage} from "../libraries/LibGamingStorage.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PowerMatrix, ChargeActionType, SpecimenCollection, ChargeAccessory, ChargeSeason} from "../../libraries/HenomorphsModel.sol"; 

/**
 * @title ChargeCalculator
 * @notice Complete library for calculating charge-related values
 * @dev Contains pure functions for charge calculations with gaming integration
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
library ChargeCalculator {
    using Math for uint256;
    
    // Constants
    uint256 private constant MAX_CHARGE = 100;
    uint256 private constant MAX_FATIGUE = 100;
    uint256 private constant PERCENTAGE_BASE = 100;
    uint256 private constant SECONDS_PER_HOUR = 3600;
    uint256 private constant SECONDS_PER_DAY = 86400;
    
    /**
     * @notice Calculate charge regeneration with all bonuses
     * @param charge Power matrix data
     * @param elapsedTime Time elapsed since last update (in seconds)
     * @param chargeEventEnd End time of any active event
     * @param chargeEventBonus Event bonus percentage
     * @return Updated charge level
     */
    function calculateChargeRegen(
        PowerMatrix memory charge,
        uint256 elapsedTime,
        uint256 chargeEventEnd,
        uint8 chargeEventBonus
    ) public view returns (uint256) {
        if (elapsedTime == 0 || charge.currentCharge >= charge.maxCharge) {
            return charge.currentCharge;
        }
        
        // Calculate base regeneration
        uint256 regenAmount = (elapsedTime * charge.regenRate) / SECONDS_PER_HOUR;
        
        // Apply active boost
        if (charge.boostEndTime > block.timestamp) {
            regenAmount = Math.mulDiv(regenAmount, 100 + LibHenomorphsStorage.CHARGE_BOOST_PERCENTAGE, 100);
        }
        
        // Apply global charge events
        if (chargeEventEnd > block.timestamp && chargeEventBonus > 0) {
            regenAmount = Math.mulDiv(regenAmount, 100 + chargeEventBonus, 100);
        }
        
        // Apply specialization bonuses
        if (charge.specialization == 2) { // Regeneration specialization
            regenAmount = Math.mulDiv(regenAmount, 100 + LibHenomorphsStorage.REGEN_SPEC_BOOST, 100);
        }
        
        // Apply fatigue penalty
        if (charge.fatigueLevel > LibHenomorphsStorage.FATIGUE_PENALTY_THRESHOLD) {
            uint256 fatigueReduction = (charge.fatigueLevel - LibHenomorphsStorage.FATIGUE_PENALTY_THRESHOLD) / 2;
            regenAmount = Math.mulDiv(regenAmount, 100 - fatigueReduction, 100);
        }
        
        // Update charge level, not exceeding maximum
        return Math.min(charge.currentCharge + regenAmount, charge.maxCharge);
    }
    
    /**
     * @notice Calculate action reward with comprehensive bonuses
     * @param charge Power matrix data
     * @param action Action type configuration
     * @param collection Collection configuration
     * @param specimenId Combined ID
     * @param accessories Array of equipped accessories
     * @param currentSeason Current season data
     * @return Calculated reward amount
     */
    function calculateActionReward(
        PowerMatrix memory charge,
        ChargeActionType memory action,
        SpecimenCollection memory collection,
        uint256 specimenId,
        ChargeAccessory[] memory accessories,
        ChargeSeason memory currentSeason
    ) public pure returns (uint256) {
        // Base reward calculation
        uint256 reward = _calculateBaseReward(action, charge);
        
        // Apply collection multiplier
        reward = _applyCollectionBonus(reward, collection);
        
        // Apply charge efficiency
        reward = _applyChargeEfficiency(reward, charge);
        
        // Apply fatigue penalty
        reward = _applyFatiguePenalty(reward, charge);
        
        // Apply season bonus
        reward = _applySeasonBonus(reward, currentSeason);
        
        // Apply accessory bonuses
        reward = _applyAccessoryBonuses(reward, accessories, action);
        
        // Apply wear penalty
        reward = _applyWearPenalty(reward, specimenId);
        
        return reward;
    }
    
    /**
     * @notice Calculate enhanced reward with gaming bonuses
     * @param baseReward Base reward amount
     * @param user User address
     * @param actionId Action ID
     * @param difficulty Difficulty level
     * @return Enhanced reward amount
     */
    function calculateEnhancedReward(
        uint256 baseReward,
        address user,
        uint8 actionId,
        uint8 difficulty
    ) external view returns (uint256) {
        if (baseReward == 0) return 0;
        
        uint256 enhancedReward = baseReward;
        
        // Apply gaming bonuses
        enhancedReward = _applyGamingBonuses(enhancedReward, user, actionId);
        
        // Apply difficulty multiplier
        enhancedReward = _applyDifficultyBonus(enhancedReward, difficulty);
        
        // Apply global multipliers
        enhancedReward = _applyGlobalMultipliers(enhancedReward);
        
        return enhancedReward;
    }
    
    /**
     * @notice Calculate fee amount with dynamic adjustments
     * @param baseFeeAmount Base fee amount
     * @param feeType Type of fee
     * @param user User address
     * @return Adjusted fee amount
     */
    function calculateDynamicFee(
        uint256 baseFeeAmount,
        string memory feeType,
        address user
    ) external view returns (uint256) {
        uint256 adjustedFee = baseFeeAmount;
        
        // Apply time-based multipliers
        adjustedFee = _applyTimeBasedFeeModifiers(adjustedFee);
        
        // Apply user-specific discounts
        adjustedFee = _applyUserFeeDiscounts(adjustedFee, user);
        
        // Apply fee type specific modifiers
        adjustedFee = _applyFeeTypeModifiers(adjustedFee, feeType);
        
        return adjustedFee;
    }
    
    /**
     * @notice Try to get wear penalty from staking system
     * @param specimenId Combined specimen ID
     * @return Wear penalty percentage
     */
    function getWearPenalty(uint256 specimenId) public pure returns (uint256) {
        // Simplified implementation - in production would integrate with staking system
        specimenId; // Silence unused parameter warning
        return 0; // Default implementation returns 0
    }
    
    // =================== INTERNAL CALCULATION FUNCTIONS ===================
    
    /**
     * @dev Calculate base reward from action
     */
    function _calculateBaseReward(ChargeActionType memory action, PowerMatrix memory charge) 
        internal 
        pure 
        returns (uint256) 
    {
        uint256 baseReward = 10 * action.rewardMultiplier / 100;
        
        // Use masteryPoints instead of consecutiveActions for diminishing returns
        if (charge.masteryPoints > 50) {
            uint256 diminishingFactor = 100 - Math.min((charge.masteryPoints - 50) / 5, 20);
            baseReward = Math.mulDiv(baseReward, diminishingFactor, 100);
        }
        
        // Evolution level bonus (2% per level, max 20%)
        if (charge.evolutionLevel > 0) {
            uint256 evolutionBonus = Math.min(charge.evolutionLevel * 2, 20);
            baseReward = Math.mulDiv(baseReward, 100 + evolutionBonus, 100);
        }
        
        return baseReward;
    }
        
    /**
     * @dev Apply collection bonus to reward
     */
    function _applyCollectionBonus(uint256 reward, SpecimenCollection memory collection) 
        internal 
        pure 
        returns (uint256) 
    {
        if (collection.regenMultiplier > 100) {
            return Math.mulDiv(reward, collection.regenMultiplier, 100);
        }
        return reward;
    }
    
    /**
     * @dev Apply charge efficiency factor
     */
    function _applyChargeEfficiency(uint256 reward, PowerMatrix memory charge) 
        internal 
        pure 
        returns (uint256) 
    {
        return Math.mulDiv(reward, charge.chargeEfficiency, 100);
    }
    
    /**
     * @dev Apply fatigue penalty
     */
    function _applyFatiguePenalty(uint256 reward, PowerMatrix memory charge) 
        internal 
        pure 
        returns (uint256) 
    {
        if (charge.fatigueLevel > LibHenomorphsStorage.FATIGUE_PENALTY_THRESHOLD) {
            uint256 penalty = (charge.fatigueLevel - LibHenomorphsStorage.FATIGUE_PENALTY_THRESHOLD) / 2;
            return Math.mulDiv(reward, 100 - penalty, 100);
        }
        return reward;
    }
    
    /**
     * @dev Apply season bonus
     */
    function _applySeasonBonus(uint256 reward, ChargeSeason memory season) 
        internal 
        pure 
        returns (uint256) 
    {
        if (season.active && season.chargeBoostPercentage > 0) {
            return Math.mulDiv(reward, 100 + season.chargeBoostPercentage, 100);
        }
        return reward;
    }
    
    /**
     * @dev Apply accessory bonuses
     */
    function _applyAccessoryBonuses(
        uint256 reward, 
        ChargeAccessory[] memory accessories, 
        ChargeActionType memory action
    ) internal pure returns (uint256) {
        for (uint256 i = 0; i < accessories.length; i++) {
            // Efficiency boost affects rewards
            if (accessories[i].efficiencyBoost > 0) {
                reward = Math.mulDiv(reward, 100 + accessories[i].efficiencyBoost, 100);
            }
            
            // Action-specific boost if applicable
            if (accessories[i].actionBoostValue > 0 && 
                action.actionCategory == accessories[i].bonusActionType) {
                reward = Math.mulDiv(reward, 100 + accessories[i].actionBoostValue, 100);
            }
            
            // Rare accessories give additional boost
            if (accessories[i].rare) {
                reward = Math.mulDiv(reward, 110, 100); // 10% boost for rare accessories
            }
        }
        
        return reward;
    }
    
    /**
     * @dev Apply wear penalty
     */
    function _applyWearPenalty(uint256 reward, uint256 specimenId) 
        internal 
        pure 
        returns (uint256) 
    {
        uint256 wearPenalty = getWearPenalty(specimenId);
        if (wearPenalty > 0) {
            return Math.mulDiv(reward, 100 - wearPenalty, 100);
        }
        return reward;
    }
    
    /**
     * @dev Apply gaming bonuses from LibGamingStorage
     */
    function _applyGamingBonuses(uint256 reward, address user, uint8 actionId) 
        internal 
        view 
        returns (uint256) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        if (!hs.featureFlags["performanceTracking"]) {
            return reward;
        }
        
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        // Apply skill rating bonus
        uint256 skillRating = gs.userSkillRatings[user];
        if (skillRating > 1000) {
            uint256 skillBonus = Math.min((skillRating - 1000) / 100, 50); // Max 50% bonus
            reward = Math.mulDiv(reward, 100 + skillBonus, 100);
        }
        
        // Apply consistency score bonus
        uint256 consistencyScore = gs.userConsistencyScore[user];
        if (consistencyScore > 500) {
            uint256 consistencyBonus = Math.min((consistencyScore - 500) / 50, 20); // Max 20% bonus
            reward = Math.mulDiv(reward, 100 + consistencyBonus, 100);
        }
        
        // Silence unused parameter warning
        actionId;
        
        return reward;
    }
    
    /**
     * @dev Apply difficulty bonus
     */
    function _applyDifficultyBonus(uint256 reward, uint8 difficulty) 
        internal 
        pure 
        returns (uint256) 
    {
        uint256 multiplier;
        
        // Hardcoded difficulty multipliers (was broken due to uninitialized storage)
        if (difficulty == 1) multiplier = 100;      // 1x
        else if (difficulty == 2) multiplier = 125; // 1.25x
        else if (difficulty == 3) multiplier = 150; // 1.5x
        else if (difficulty == 4) multiplier = 200; // 2x
        else if (difficulty == 5) multiplier = 300; // 3x
        else return reward; // Invalid difficulty
        
        return Math.mulDiv(reward, multiplier, 100);
    }
    
    /**
     * @dev Apply global multipliers
     */
    function _applyGlobalMultipliers(uint256 reward) 
        internal 
        view 
        returns (uint256) 
    {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        if (gs.globalGameState.globalMultiplier > 100) {
            return Math.mulDiv(reward, gs.globalGameState.globalMultiplier, 100);
        }
        
        return reward;
    }
    
    /**
     * @dev Apply time-based fee modifiers
     */
    function _applyTimeBasedFeeModifiers(uint256 fee) 
        internal 
        view 
        returns (uint256) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        if (!hs.featureFlags["dynamicFees"]) {
            return fee;
        }
        
        uint32 currentHour = uint32((block.timestamp % SECONDS_PER_DAY) / SECONDS_PER_HOUR);
        
        // Hardcoded peak hours (was uninitialized in storage anyway)
        uint32 peakStartHour = 18; // 6 PM
        uint32 peakEndHour = 22;   // 10 PM
        uint256 peakHoursMultiplier = 120; // 20% increase
        uint256 offPeakDiscount = 10; // 10% discount
        
        if (currentHour >= peakStartHour && currentHour <= peakEndHour) {
            // Peak hours - apply multiplier
            return Math.mulDiv(fee, peakHoursMultiplier, 100);
        } else {
            // Off-peak hours - apply discount
            return Math.mulDiv(fee, 100 - offPeakDiscount, 100);
        }
    }
        
    /**
     * @dev Apply user-specific fee discounts
     */
    function _applyUserFeeDiscounts(uint256 fee, address user) 
        internal 
        view 
        returns (uint256) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        if (!hs.featureFlags["performanceTracking"]) {
            return fee;
        }
        
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        // Apply consistency score discount
        uint256 consistencyScore = gs.userConsistencyScore[user];
        if (consistencyScore > 800) {
            uint256 discount = Math.min((consistencyScore - 800) / 40, 15); // Max 15% discount
            return Math.mulDiv(fee, 100 - discount, 100);
        }
        
        return fee;
    }
    
    /**
     * @dev Apply fee type specific modifiers
     */
    function _applyFeeTypeModifiers(uint256 fee, string memory feeType) 
        internal 
        pure 
        returns (uint256) 
    {
        // Hardcoded reasonable fee limits (was uninitialized anyway)
        uint256 maxGamingFeeAmount = 1000 ether; // Reasonable max
        uint256 minGamingFeeAmount = 0.001 ether; // Reasonable min
        
        // Apply fee caps
        if (fee > maxGamingFeeAmount) {
            fee = maxGamingFeeAmount;
        }
        
        if (fee < minGamingFeeAmount) {
            fee = minGamingFeeAmount;
        }
        
        // Silence unused parameter warning
        feeType;
        
        return fee;
    }

    /**
     * @notice Calculate charge cost for an action
     * @param baseChargeCost Base charge cost
     * @param charge Power matrix data
     * @param action Action type data
     * @return Final charge cost
     */
    function calculateChargeCost(
        uint256 baseChargeCost,
        PowerMatrix memory charge,
        ChargeActionType memory action
    ) external pure returns (uint256) {
        uint256 chargeCost = baseChargeCost;
        
        // Consider efficiency specialization with evolution bonus
        if (charge.specialization == 1) { // Efficiency specialization
            uint256 efficiencyBonus = LibHenomorphsStorage.EFFICIENCY_SPEC_BOOST;
            
            // Evolution level enhances efficiency (1% per level)
            if (charge.evolutionLevel > 0) {
                efficiencyBonus += charge.evolutionLevel;
            }
            
            chargeCost = Math.mulDiv(chargeCost, 100 - Math.min(efficiencyBonus, 50), 100);
        }
        
        // Consider fatigue
        if (charge.fatigueLevel > 0) {
            uint256 fatigueIncrease = charge.fatigueLevel / 5;
            chargeCost = Math.mulDiv(chargeCost, 100 + fatigueIncrease, 100);
        }
        
        // Consider action difficulty
        if (action.difficultyTier > 1) {
            uint256 difficultyIncrease = (action.difficultyTier - 1) * 5;
            chargeCost = Math.mulDiv(chargeCost, 100 + difficultyIncrease, 100);
        }
        
        // Mastery points reduce charge cost (0.1% per point, max 5%)
        if (charge.masteryPoints > 0) {
            uint256 masteryReduction = Math.min(charge.masteryPoints / 10, 50);
            chargeCost = Math.mulDiv(chargeCost, 100 - masteryReduction, 100);
        }
        
        return chargeCost;
    }
    
    /**
     * @notice Calculate specialization bonus
     * @param baseValue Base value to modify
     * @param specialization Specialization type (1=efficiency, 2=regeneration)
     * @param bonusType Bonus type (1=efficiency, 2=regeneration, 3=reward)
     * @return Modified value with specialization bonus
     */
    function calculateSpecializationBonus(
        uint256 baseValue,
        uint8 specialization,
        uint8 bonusType,
        uint8 evolutionLevel  // NEW parameter
    ) external pure returns (uint256) {
        if (specialization == 0 || bonusType == 0) {
            return baseValue;
        }
        
        uint256 bonusPercentage = 0;
        
        if (specialization == 1 && bonusType == 1) { // Efficiency spec, efficiency bonus
            bonusPercentage = LibHenomorphsStorage.EFFICIENCY_SPEC_BOOST;
        } else if (specialization == 2 && bonusType == 2) { // Regen spec, regen bonus
            bonusPercentage = LibHenomorphsStorage.REGEN_SPEC_BOOST;
        }
        
        // Evolution enhances specialization bonuses (5% per level)
        if (bonusPercentage > 0 && evolutionLevel > 0) {
            uint256 evolutionMultiplier = 100 + (evolutionLevel * 5);
            bonusPercentage = Math.mulDiv(bonusPercentage, evolutionMultiplier, 100);
        }
        
        if (bonusPercentage > 0) {
            return Math.mulDiv(baseValue, 100 + bonusPercentage, 100);
        }
        
        return baseValue;
    }
}