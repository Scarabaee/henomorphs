// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibCollectionStorage} from "./LibCollectionStorage.sol";
import {Calibration, PowerMatrix} from "./CollectionModel.sol";


// Support structures for fallback calculations
struct ModularAssetData {
    uint8 tokenVariant;
    uint8 activeTraitPackId;
    uint8[] traitPackIds;
}

struct AccessoryBonuses {
    uint8 efficiencyBonus;
    uint8 regenBonus;
    uint8 maxChargeBonus;
    uint8 kinshipBonus;
    uint8 wearResistance;
    uint8 calibrationBonus;
    uint8 stakingBonus;
    uint8 xpMultiplier;
}

struct StakingStatus {
    bool isStaked;
    uint256 stakingStartTime;
    uint256 totalStakingTime;
    uint256 stakingRewards;
    uint8 stakingMultiplier;
    bytes32 colonyId;
    uint8 colonyBonus;
}

struct CompatibilityScores {
    uint8 overallScore;
    uint8 traitPackCompatibility;
    uint8 variantBonus;
    uint8 accessoryCompatibility;
}

/**
 * @title MetadataFallback
 * @notice Fallback calculations when external systems are unavailable
 * @dev Provides default values and calculations for metadata generation
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
library MetadataFallback {
    
    // Default calibration values by variant
    function _getBaseCalibrationByVariant(uint8 variant) private pure returns (uint8) {
        if (variant == 0) return 40; // Matrix Core - already correct
        if (variant == 1) return 45;
        if (variant == 2) return 50;
        if (variant == 3) return 55;
        if (variant == 4) return 60;
        if (variant == 5) return 65;
        return 40; // Default fallback
    }
    
    // Default power matrix values  
    uint256 internal constant DEFAULT_MAX_CHARGE = 100;
    uint256 internal constant DEFAULT_REGEN_RATE = 5;
    uint256 internal constant DEFAULT_EFFICIENCY = 50;
    
    /**
     * @notice Calculate fallback calibration data when Biopod unavailable
     * @param tokenId Token ID
     * @param assetData ModularAsset data for the token
     * @return calibration Fallback calibration structure
     */
    function calculateFallbackCalibration(
        uint256 tokenId,
        ModularAssetData memory assetData
    ) internal view returns (Calibration memory calibration) {
        
        // Get token variant from asset data or use default
        uint8 variant = assetData.tokenVariant > 0 ? assetData.tokenVariant : 1;
        
        // Base calibration from variant
        uint256 baseCalibration = _getBaseCalibrationByVariant(variant > 4 ? 4 : variant);
        
        // Apply trait pack modifiers
        uint256 traitPackBonus = 0;
        if (assetData.activeTraitPackId > 0) {
            traitPackBonus = 10; // Standard trait pack bonus
        }
        
        // Apply accessory bonuses
        uint256 accessoryBonus = assetData.traitPackIds.length * 2; // 2 points per trait pack
        
        // Calculate final calibration level
        uint256 finalCalibration = baseCalibration + traitPackBonus + accessoryBonus;
        if (finalCalibration > 100) finalCalibration = 100;
        
        // Build calibration structure with reasonable defaults
        calibration = Calibration({
            tokenId: tokenId,
            owner: address(0), // Will be filled by caller
            kinship: 50, // Default neutral kinship
            lastInteraction: block.timestamp,
            experience: 0, // Start with no experience
            charge: 0, // Start with no charge
            lastCharge: block.timestamp,
            level: finalCalibration,
            prowess: finalCalibration / 2, // Half of calibration level
            wear: 0, // Start with no wear
            lastRecalibration: block.timestamp,
            calibrationCount: 0, // No calibrations yet
            locked: false, // Not locked by default
            agility: finalCalibration / 3, // Third of calibration level
            intelligence: finalCalibration / 3, // Third of calibration level
            bioLevel: 1 // Default bio level
        });
        
        return calibration;
    }
    
    /**
     * @notice Calculate fallback power matrix when Chargepod unavailable
     * @param assetData ModularAsset data for the token
     * @return powerMatrix Fallback power matrix structure
     */
    function calculateFallbackPowerMatrix(
        uint256,
        ModularAssetData memory assetData
    ) internal view returns (PowerMatrix memory powerMatrix) {
        
        // Base values
        uint256 maxCharge = DEFAULT_MAX_CHARGE;
        uint256 regenRate = DEFAULT_REGEN_RATE;
        uint256 efficiency = DEFAULT_EFFICIENCY;
        
        // Apply trait pack bonuses
        if (assetData.activeTraitPackId > 0) {
            maxCharge += 20; // Trait pack adds max charge
            regenRate += 3; // Trait pack improves regen
            efficiency += 15; // Trait pack improves efficiency
        }
        
        // Apply multiple trait pack bonuses
        uint256 additionalTraitPacks = assetData.traitPackIds.length;
        if (additionalTraitPacks > 1) {
            maxCharge += (additionalTraitPacks - 1) * 10;
            regenRate += (additionalTraitPacks - 1) * 2;
            efficiency += (additionalTraitPacks - 1) * 8;
        }
        
        // Cap values at reasonable maximums
        if (maxCharge > 200) maxCharge = 200;
        if (regenRate > 20) regenRate = 20;
        if (efficiency > 100) efficiency = 100;
        
        // Get specialization based on token variant
        uint8 variant = assetData.tokenVariant > 0 ? assetData.tokenVariant : 1;
        uint8 specialization = variant <= 2 ? 1 : 2; // Lower variants = efficiency, higher = regen
        
        powerMatrix = PowerMatrix({
            currentCharge: 0, // Start with no charge
            maxCharge: maxCharge,
            lastChargeTime: block.timestamp,
            regenRate: regenRate,
            fatigueLevel: 0, // Start with no fatigue
            boostEndTime: 0, // No active boost
            chargeEfficiency: efficiency,
            consecutiveActions: 0, // No actions yet
            flags: 0, // No flags set
            specialization: specialization,
            seasonPoints: 0 // No season points yet
        });
        
        return powerMatrix;
    }
    
    /**
     * @notice Calculate fallback accessory bonuses when external systems unavailable
     * @param assetData ModularAsset data for the token
     * @return bonuses Fallback accessory bonus structure
     */
    function calculateFallbackBonuses(
        uint256,
        ModularAssetData memory assetData
    ) internal pure returns (AccessoryBonuses memory bonuses) {
        
        // Base bonuses from trait packs
        uint8 traitPackCount = uint8(assetData.traitPackIds.length);
        
        bonuses = AccessoryBonuses({
            efficiencyBonus: traitPackCount * 5, // 5% per trait pack
            regenBonus: traitPackCount * 3, // 3 points per trait pack
            maxChargeBonus: traitPackCount * 10, // 10 points per trait pack
            kinshipBonus: traitPackCount * 2, // 2 points per trait pack
            wearResistance: traitPackCount * 5, // 5% per trait pack
            calibrationBonus: traitPackCount * 3, // 3% per trait pack
            stakingBonus: traitPackCount * 2, // 2% per trait pack
            xpMultiplier: 100 + (traitPackCount * 10) // Base 100% + 10% per trait pack
        });
        
        // Cap bonuses at reasonable values
        if (bonuses.efficiencyBonus > 30) bonuses.efficiencyBonus = 30;
        if (bonuses.regenBonus > 15) bonuses.regenBonus = 15;
        if (bonuses.maxChargeBonus > 50) bonuses.maxChargeBonus = 50;
        if (bonuses.kinshipBonus > 20) bonuses.kinshipBonus = 20;
        if (bonuses.wearResistance > 25) bonuses.wearResistance = 25;
        if (bonuses.calibrationBonus > 20) bonuses.calibrationBonus = 20;
        if (bonuses.stakingBonus > 15) bonuses.stakingBonus = 15;
        if (bonuses.xpMultiplier > 150) bonuses.xpMultiplier = 150;
        
        return bonuses;
    }
    
    /**
     * @notice Calculate fallback staking status when Staking system unavailable
     * @dev Returns default "not staked" status - no parameters needed
     * @return stakingStatus Default staking status structure
     */
    function calculateFallbackStakingStatus() internal pure returns (StakingStatus memory stakingStatus) {
        
        stakingStatus = StakingStatus({
            isStaked: false, // Default not staked
            stakingStartTime: 0, // No staking start time
            totalStakingTime: 0, // No total staking time
            stakingRewards: 0, // No rewards accumulated
            stakingMultiplier: 100, // Base 100% multiplier
            colonyId: bytes32(0), // No colony
            colonyBonus: 0 // No colony bonus
        });
        
        return stakingStatus;
    }
    
    /**
     * @notice Calculate compatibility scores between trait packs and token variant
     * @param assetData ModularAsset data for the token
     * @return compatibility Compatibility score structure
     */
    function calculateCompatibilityScores(
        uint256,
        ModularAssetData memory assetData
    ) internal pure returns (CompatibilityScores memory compatibility) {
        
        uint8 variant = assetData.tokenVariant > 0 ? assetData.tokenVariant : 1;
        uint8 traitPackCount = uint8(assetData.traitPackIds.length);
        
        // Calculate base compatibility (assume good compatibility by default)
        uint8 baseScore = 80; // Good base compatibility
        
        // Bonus for having trait packs
        uint8 traitPackBonus = traitPackCount * 5; // 5 points per trait pack
        
        // Variant-specific bonuses (some variants work better with trait packs)
        uint8 variantBonus = variant >= 3 ? 10 : 5; // Higher variants get better compatibility
        
        uint8 totalScore = baseScore + traitPackBonus + variantBonus;
        if (totalScore > 100) totalScore = 100;
        
        compatibility = CompatibilityScores({
            overallScore: totalScore,
            traitPackCompatibility: traitPackCount > 0 ? totalScore : 50, // Lower if no trait packs
            variantBonus: variantBonus,
            accessoryCompatibility: traitPackCount * 10 // 10 points per trait pack for accessories
        });
        
        return compatibility;
    }
}
