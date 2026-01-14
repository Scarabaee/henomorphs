// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "./LibHenomorphsStorage.sol";
import {PodsUtils} from "../../libraries/PodsUtils.sol";
import {ChargeAccessory, PowerMatrix} from "../../libraries/HenomorphsModel.sol";
import {LibTraitPackHelper} from "./LibTraitPackHelper.sol";

/**
 * @title LibAccessoryHelper
 * @notice Enhanced central library for accessory operations with integration readiness
 * @dev Version 2.0 with standardized bonus calculation and extensibility
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
library LibAccessoryHelper {
    
    // Struct for standardized bonus tracking
    struct BonusApplication {
        uint8 source;         // 1=accessory, 2=trait pack, 3=combined
        uint8 bonusType;      // 1=charge efficiency, 2=regen rate, 3=max charge, etc.
        uint16 bonusValue;    // Value applied
        uint32 timestamp;     // When applied
        bool isActive;        // Whether currently active
    }

    /**
     * @dev Enhanced application of accessory effects with detailed tracking
     * @param combinedId Combined token ID
     * @param accessory Accessory to apply
     * @param isAdding True if adding effects, False if removing
     */
    function applyAccessoryEffectsExtended(
        uint256 combinedId,
        ChargeAccessory memory accessory,
        bool isAdding
    ) internal returns (BonusApplication[] memory) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        PowerMatrix storage charge = hs.performedCharges[combinedId];
        
        // Prepare array to track applied bonuses
        BonusApplication[] memory appliedBonuses = new BonusApplication[](5);
        uint8 bonusCount = 0;
        
        // Modify chargeBoost
        if (accessory.chargeBoost > 0) {
            if (isAdding) {
                charge.maxCharge += uint128(accessory.chargeBoost);
                
                // Track bonus application
                appliedBonuses[bonusCount] = BonusApplication({
                    source: 1, // Accessory
                    bonusType: 3, // Max charge
                    bonusValue: accessory.chargeBoost,
                    timestamp: uint32(block.timestamp),
                    isActive: true
                });
                bonusCount++;
            } else {
                // Prevent underflow
                charge.maxCharge = charge.maxCharge > uint128(accessory.chargeBoost) ?
                    charge.maxCharge - uint128(accessory.chargeBoost) : 0;
                
                // Check if currentCharge exceeds maxCharge
                if (charge.currentCharge > charge.maxCharge) {
                    charge.currentCharge = charge.maxCharge;
                }
                
                // Track bonus removal
                appliedBonuses[bonusCount] = BonusApplication({
                    source: 1, // Accessory
                    bonusType: 3, // Max charge
                    bonusValue: accessory.chargeBoost,
                    timestamp: uint32(block.timestamp),
                    isActive: false
                });
                bonusCount++;
            }
        }
        
        // Modify regenBoost
        if (accessory.regenBoost > 0) {
            if (isAdding) {
                charge.regenRate += uint16(accessory.regenBoost);
                
                // Track bonus application
                appliedBonuses[bonusCount] = BonusApplication({
                    source: 1, // Accessory
                    bonusType: 2, // Regen rate
                    bonusValue: accessory.regenBoost,
                    timestamp: uint32(block.timestamp),
                    isActive: true
                });
                bonusCount++;
            } else {
                // Prevent underflow
                charge.regenRate = charge.regenRate > uint16(accessory.regenBoost) ?
                    charge.regenRate - uint16(accessory.regenBoost) : 0;
                
                // Track bonus removal
                appliedBonuses[bonusCount] = BonusApplication({
                    source: 1, // Accessory
                    bonusType: 2, // Regen rate
                    bonusValue: accessory.regenBoost,
                    timestamp: uint32(block.timestamp),
                    isActive: false
                });
                bonusCount++;
            }
        }
        
        // Modify efficiencyBoost
        if (accessory.efficiencyBoost > 0) {
            if (isAdding) {
                charge.chargeEfficiency += accessory.efficiencyBoost;
                
                // Track bonus application
                appliedBonuses[bonusCount] = BonusApplication({
                    source: 1, // Accessory
                    bonusType: 1, // Charge efficiency
                    bonusValue: accessory.efficiencyBoost,
                    timestamp: uint32(block.timestamp),
                    isActive: true
                });
                bonusCount++;
            } else {
                // Prevent underflow
                charge.chargeEfficiency = charge.chargeEfficiency > accessory.efficiencyBoost ?
                    charge.chargeEfficiency - accessory.efficiencyBoost : 0;
                
                // Track bonus removal
                appliedBonuses[bonusCount] = BonusApplication({
                    source: 1, // Accessory
                    bonusType: 1, // Charge efficiency
                    bonusValue: accessory.efficiencyBoost,
                    timestamp: uint32(block.timestamp),
                    isActive: false
                });
                bonusCount++;
            }
        }
        
        // Modify specialization effects
        if (accessory.specializationType == charge.specialization || accessory.specializationType == 0) {
            if (charge.specialization == 1) { // Efficiency specialization
                if (isAdding) {
                    charge.chargeEfficiency += accessory.specializationBoostValue;
                    
                    // Track bonus application
                    appliedBonuses[bonusCount] = BonusApplication({
                        source: 1, // Accessory
                        bonusType: 4, // Specialization efficiency
                        bonusValue: accessory.specializationBoostValue,
                        timestamp: uint32(block.timestamp),
                        isActive: true
                    });
                    bonusCount++;
                } else {
                    // Prevent underflow
                    charge.chargeEfficiency = charge.chargeEfficiency > accessory.specializationBoostValue ?
                        charge.chargeEfficiency - accessory.specializationBoostValue : 0;
                    
                    // Track bonus removal
                    appliedBonuses[bonusCount] = BonusApplication({
                        source: 1, // Accessory
                        bonusType: 4, // Specialization efficiency
                        bonusValue: accessory.specializationBoostValue,
                        timestamp: uint32(block.timestamp),
                        isActive: false
                    });
                    bonusCount++;
                }
            } else if (charge.specialization == 2) { // Regeneration specialization
                if (isAdding) {
                    charge.regenRate += uint16(accessory.specializationBoostValue);
                    
                    // Track bonus application
                    appliedBonuses[bonusCount] = BonusApplication({
                        source: 1, // Accessory
                        bonusType: 5, // Specialization regen
                        bonusValue: accessory.specializationBoostValue,
                        timestamp: uint32(block.timestamp),
                        isActive: true
                    });
                    bonusCount++;
                } else {
                    // Prevent underflow
                    charge.regenRate = charge.regenRate > uint16(accessory.specializationBoostValue) ?
                        charge.regenRate - uint16(accessory.specializationBoostValue) : 0;
                    
                    // Track bonus removal
                    appliedBonuses[bonusCount] = BonusApplication({
                        source: 1, // Accessory
                        bonusType: 5, // Specialization regen
                        bonusValue: accessory.specializationBoostValue,
                        timestamp: uint32(block.timestamp),
                        isActive: false
                    });
                    bonusCount++;
                }
            }
        }
        
        // Track bonus applications in storage for potential future integration
        // This would be implemented when integration is fully realized
        
        return appliedBonuses;
    }
    
    /**
     * @dev Legacy method for backward compatibility
     * @param combinedId Combined token ID
     * @param accessory Accessory to apply
     * @param isAdding True if adding effects, False if removing
     */
    function applyAccessoryEffects(
        uint256 combinedId,
        ChargeAccessory memory accessory,
        bool isAdding
    ) internal {
        // Call extended version but ignore return value
        applyAccessoryEffectsExtended(combinedId, accessory, isAdding);
    }
    
    /**
     * @dev Enhanced trait pack bonus application with standardized calculation
     * @param combinedId Combined token ID
     * @param traitPackMatch Whether trait pack matches
     * @param traitPackId Trait pack ID
     * @param variant Specimen variant
     * @param isAdding True if adding effects, False if removing
     * @return Applied bonuses for integration tracking
     */
    function applyTraitPackBonusExtended(
        uint256 combinedId,
        bool traitPackMatch,
        uint8 traitPackId,
        uint8 variant,
        bool isAdding
    ) internal returns (BonusApplication[] memory) {
        if (!traitPackMatch || traitPackId == 0) {
            return new BonusApplication[](0); // No bonus to apply
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        PowerMatrix storage charge = hs.performedCharges[combinedId];
        
        // Use standardized bonus calculation from trait pack helper
        (
            uint8 efficiencyBonus,
            uint8 regenBonus,
            uint8 maxChargeBonus,,
        ) = LibTraitPackHelper.calculateStandardizedBonuses(traitPackId, variant);
        
        // Prepare array to track applied bonuses
        BonusApplication[] memory appliedBonuses = new BonusApplication[](3);
        uint8 bonusCount = 0;
        
        // Apply calculated bonuses
        if (isAdding) {
            charge.chargeEfficiency += efficiencyBonus;
            charge.regenRate += uint16(regenBonus);
            
            if (maxChargeBonus > 0) {
                charge.maxCharge += uint128(maxChargeBonus);
            }
            
            // Track bonus applications
            appliedBonuses[bonusCount++] = BonusApplication({
                source: 2, // Trait pack
                bonusType: 1, // Charge efficiency
                bonusValue: efficiencyBonus,
                timestamp: uint32(block.timestamp),
                isActive: true
            });
            
            appliedBonuses[bonusCount++] = BonusApplication({
                source: 2, // Trait pack
                bonusType: 2, // Regen rate
                bonusValue: regenBonus,
                timestamp: uint32(block.timestamp),
                isActive: true
            });
            
            if (maxChargeBonus > 0) {
                appliedBonuses[bonusCount++] = BonusApplication({
                    source: 2, // Trait pack
                    bonusType: 3, // Max charge
                    bonusValue: maxChargeBonus,
                    timestamp: uint32(block.timestamp),
                    isActive: true
                });
            }
        } else {
            // Remove bonuses with underflow protection
            charge.chargeEfficiency = charge.chargeEfficiency > efficiencyBonus ? 
                charge.chargeEfficiency - efficiencyBonus : 0;
                
            charge.regenRate = charge.regenRate > uint16(regenBonus) ? 
                charge.regenRate - uint16(regenBonus) : 0;
                
            if (maxChargeBonus > 0) {
                charge.maxCharge = charge.maxCharge > uint128(maxChargeBonus) ?
                    charge.maxCharge - uint128(maxChargeBonus) : 0;
                    
                // Check if currentCharge exceeds maxCharge after removal
                if (charge.currentCharge > charge.maxCharge) {
                    charge.currentCharge = charge.maxCharge;
                }
            }
            
            // Track bonus removals
            appliedBonuses[bonusCount++] = BonusApplication({
                source: 2, // Trait pack
                bonusType: 1, // Charge efficiency
                bonusValue: efficiencyBonus,
                timestamp: uint32(block.timestamp),
                isActive: false
            });
            
            appliedBonuses[bonusCount++] = BonusApplication({
                source: 2, // Trait pack
                bonusType: 2, // Regen rate
                bonusValue: regenBonus,
                timestamp: uint32(block.timestamp),
                isActive: false
            });
            
            if (maxChargeBonus > 0) {
                appliedBonuses[bonusCount++] = BonusApplication({
                    source: 2, // Trait pack
                    bonusType: 3, // Max charge
                    bonusValue: maxChargeBonus,
                    timestamp: uint32(block.timestamp),
                    isActive: false
                });
            }
        }
        
        // Track bonus applications in storage for potential future integration
        // This would be implemented when integration is fully realized
        
        return appliedBonuses;
    }
    
    /**
     * @dev Legacy trait pack bonus application for backward compatibility
     * @param combinedId Combined token ID
     * @param traitPackMatch Whether trait pack matches
     * @param traitPackId Trait pack ID
     * @param isAdding True if adding effects, False if removing
     */
    function applyTraitPackBonus(
        uint256 combinedId,
        bool traitPackMatch,
        uint8 traitPackId,
        bool isAdding
    ) internal {
        // Use default variant 1 for backward compatibility
        applyTraitPackBonusExtended(combinedId, traitPackMatch, traitPackId, 1, isAdding);
    }
    
    /**
     * @notice Record bonus application for future external system integration
     * @dev Framework for tracking bonuses applied to tokens
     * @param combinedId Combined token ID
     * @param source Source of bonus (1=accessory, 2=trait pack, etc.)
     * @param bonusType Type of bonus (1=efficiency, 2=regen, etc.)
     * @param value Value of bonus
     * @param isActive Whether bonus is being applied (true) or removed (false)
     */
    function recordBonusApplication(
        uint256 combinedId,
        uint8 source,
        uint8 bonusType,
        uint16 value,
        bool isActive
    ) internal view returns (uint256 recordId) {
        // Implementation would be added when integration is implemented
        // For now, return a placeholder record ID
        return uint256(keccak256(abi.encode(combinedId, source, bonusType, value, isActive, block.timestamp)));
    }
    
    /**
     * @notice Get all active bonuses for a token
     * @dev Utility for integration preparation
     * @return activeBonuses Array of all active bonuses
     */
    function getActiveTokenBonuses(uint256) internal pure returns (BonusApplication[] memory) {
        // uint256 combinedId
        // This is a placeholder implementation
        // Would be fully implemented during integration
        BonusApplication[] memory placeholderBonuses = new BonusApplication[](0);
        return placeholderBonuses;
    }
}