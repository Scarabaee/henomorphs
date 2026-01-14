// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "./LibHenomorphsStorage.sol";
import {LibStakingStorage} from "./LibStakingStorage.sol";
import {PodsUtils} from "../../libraries/PodsUtils.sol";
import {LibTraitPackHelper} from "./LibTraitPackHelper.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StakedSpecimen} from "../../libraries/StakingModel.sol";
import {Calibration, ChargeAccessory, SpecimenCollection} from "../../libraries/HenomorphsModel.sol";
import {IExternalBiopod, IExternalAccessory, IExternalCollection} from "../interfaces/IStakingInterfaces.sol";


/**
 * @title LibBiopodIntegration
 * @notice Helper library for biopod integration functions
 * @dev Centralizes logic for accessing Biopod across multiple facets
  * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
library LibBiopodIntegration {
    // Version tracking for upgrades
    uint8 public constant LIBRARY_VERSION = 2;
    
    // Error definitions
    error BiopodNotAvailable();
    error TokenNotStaked();
    error BiopodUpdateFailed();
    error InvalidTokenVariant();
    error InvalidSpecialization();

    /**
     * @notice Apply wear repair to a token
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param repairAmount Amount of repair to apply
     * @return success Whether repair was successful
     */
    function applyWearRepair(uint256 collectionId, uint256 tokenId, uint256 repairAmount) internal returns (bool) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];

        if (!staked.staked) {
            return false;
        }

        // SAFE AUTO-FIX: Initialize repair time for existing tokens
        if (staked.lastWearRepairTime == 0) {
            uint256 cooldownBuffer = 86400; // 24 hours
            uint256 safeTime = block.timestamp > cooldownBuffer ?
                            block.timestamp - cooldownBuffer :
                            staked.stakedSince;
            staked.lastWearRepairTime = uint32(safeTime);
        }

        // Calculate current wear INCLUDING time-based accumulation
        uint256 currentWear = calculateCurrentWear(collectionId, tokenId);

        if (currentWear == 0) {
            return false; // Nothing to repair
        }

        // Calculate actual repair amount (can't repair more than current wear)
        uint256 actualRepair = repairAmount > currentWear ? currentWear : repairAmount;
        uint256 newWear = currentWear - actualRepair;

        // Update storage with new wear value and reset time tracking
        staked.wearLevel = uint8(newWear);
        staked.lastWearUpdateTime = uint32(block.timestamp); // Reset time-based accumulation
        staked.lastWearRepairTime = uint32(block.timestamp);
        _updateWearPenalty(staked, ss);

        return true;
    }

    /**
     * @notice Update wear penalty based on current wear level
     * @param staked Staked specimen data
     */
    function _updateWearPenalty(StakedSpecimen storage staked, LibStakingStorage.StakingStorage storage) private {
        // Use the optimized penalty calculation from LibStakingStorage
        staked.wearPenalty = uint8(LibStakingStorage.calculateWearPenalty(staked.wearLevel));
    }
        
    /**
     * @notice Calculate current wear considering time elapsed and wear rate
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return currentWear Current wear value
     */
    function calculateCurrentWear(uint256 collectionId, uint256 tokenId) internal view returns (uint256 currentWear) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];

        // CRITICAL: If lastWearUpdateTime is 0, this is a legacy token with corrupted data
        // Reset to 0 wear - these tokens had incorrect wear calculation before
        if (staked.lastWearUpdateTime == 0) {
            return 0;
        }

        // Start with stored wear level
        currentWear = staked.wearLevel;

        // Skip if wear increase rate is 0
        if (ss.wearIncreasePerDay == 0) {
            return currentWear;
        }

        // Calculate time elapsed since last wear update
        uint256 timeElapsed = block.timestamp - staked.lastWearUpdateTime;

        // Calculate wear increase based on daily rate
        uint256 wearIncrease = (timeElapsed * ss.wearIncreasePerDay) / 1 days;

        if (wearIncrease > 0) {
            currentWear += wearIncrease;

            // Cap at 100
            if (currentWear > LibStakingStorage.MAX_WEAR_LEVEL) {
                currentWear = LibStakingStorage.MAX_WEAR_LEVEL;
            }
        }

        return currentWear;
    }
    
    /**
     * @notice Apply accessory effects to Biopod calibration
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param calibration Original calibration data
     * @param accessoryContractAddress The address of the contract to call for accessory data
     * @return Enhanced calibration data with accessory effects applied
     */
    function applyAccessoryEffectsToBiopod(
        uint256 collectionId,
        uint256 tokenId,
        Calibration memory calibration,
        address accessoryContractAddress
    ) internal view returns (Calibration memory) {
        // Skip if no accessory contract provided
        if (accessoryContractAddress == address(0)) {
            return calibration;
        }
        
        // Get token's trait packs
        (bool traitPacksAvailable, uint8[] memory tokenTraitPacks) = LibTraitPackHelper.verifyTraitPack(
            collectionId,
            tokenId,
            0 // 0 means we want all trait packs, not checking for a specific one
        );
        
        // Get accessories from contract
        try IExternalAccessory(accessoryContractAddress).equippedAccessories(collectionId, tokenId) returns (
            ChargeAccessory[] memory accessories
        ) {
            // Apply effects from each accessory
            for (uint256 i = 0; i < accessories.length; i++) {
                // Apply kinship boost
                if (accessories[i].kinshipBoost > 0) {
                    calibration.kinship = Math.min(100, calibration.kinship + accessories[i].kinshipBoost);
                }
                
                // Apply calibration bonus
                if (accessories[i].calibrationBonus > 0) {
                    // Enhance level-based calculations
                    calibration.level = calibration.level + (calibration.level * accessories[i].calibrationBonus / 100);
                }
                
                // Apply wear resistance - reduce wear value
                if (accessories[i].wearResistance > 0 && calibration.wear > 0) {
                    uint256 wearReduction = calibration.wear * accessories[i].wearResistance / 100;
                    calibration.wear = calibration.wear > wearReduction ? calibration.wear - wearReduction : 0;
                }
                
                // Apply stat boosts
                if (accessories[i].prowessBoost > 0) {
                    calibration.prowess += accessories[i].prowessBoost;
                }
                if (accessories[i].agilityBoost > 0) {
                    calibration.agility += accessories[i].agilityBoost;
                }
                if (accessories[i].intelligenceBoost > 0) {
                    calibration.intelligence += accessories[i].intelligenceBoost;
                }
                
                // Apply trait pack specific bonuses if applicable
                if (traitPacksAvailable && accessories[i].traitPackId > 0) {
                    bool traitPackMatch = LibTraitPackHelper.applyTraitPackBonusForAccessory(
                        collectionId,
                        tokenId,
                        accessories[i],
                        tokenTraitPacks
                    );
                    
                    if (traitPackMatch) {
                        // Additional kinship boost
                        calibration.kinship = Math.min(100, calibration.kinship + 5);
                        
                        // Additional wear resistance
                        if (calibration.wear > 0) {
                            uint256 extraWearReduction = calibration.wear * 10 / 100;
                            calibration.wear = calibration.wear > extraWearReduction ? calibration.wear - extraWearReduction : 0;
                        }
                        
                        // Additional stat boosts for matching trait packs
                        calibration.prowess += 2;
                        calibration.agility += 1;
                        calibration.intelligence += 1;
                        calibration.level = Math.min(100, calibration.level + 1);
                    }
                }
            }
        } catch {
            // Skip accessory effects if retrieval fails
        }
        
        return calibration;
    }
    
    /**
     * @notice Update trait pack metadata for a token
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return tokenTraitPacks Array of token's trait packs
     */
    function updateTokenTraitPacks(uint256 collectionId, uint256 tokenId) internal view returns (uint8[] memory tokenTraitPacks) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        
        // Default to empty array
        tokenTraitPacks = new uint8[](0);
        
        // Try to get token's trait packs
        try IExternalCollection(collection.collectionAddress).itemEquipments(tokenId) returns (uint8[] memory traitPacks) {
            tokenTraitPacks = traitPacks;
        } catch {
            // Default to empty array if trait pack retrieval fails
        }
        
        return tokenTraitPacks;
    }
    
    /**
     * @notice Update wear penalty based on current wear level
     * @param staked Staked specimen data
     * @param ss Staking storage 
     */
    function updateWearPenalty(
        StakedSpecimen storage staked,
        LibStakingStorage.StakingStorage storage ss
    ) internal {
        // Reset penalty
        staked.wearPenalty = 0;
        
        // Find applicable penalty
        for (uint8 i = 0; i < ss.wearPenaltyThresholds.length; i++) {
            if (staked.wearLevel >= ss.wearPenaltyThresholds[i]) {
                staked.wearPenalty = uint8(ss.wearPenaltyValues[i]);
            }
        }
    }
    
    /**
     * @notice Apply effects from specialization to a token's calibration
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param calibration Current calibration data
     * @return updatedCalibration Updated calibration with specialization effects
     */
    function applySpecializationEffects(
        uint256 collectionId,
        uint256 tokenId,
        Calibration memory calibration
    ) internal view returns (Calibration memory updatedCalibration) {
        updatedCalibration = calibration;
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        // Apply effects based on specialization type
        if (staked.specialization == 0) {
            // Balanced: No special effects
            return updatedCalibration;
        } else if (staked.specialization == 1) {
            // Efficiency: Boost intelligence, reduce wear
            updatedCalibration.intelligence += 5;
            if (updatedCalibration.wear > 10) {
                updatedCalibration.wear -= 10;
            } else {
                updatedCalibration.wear = 0;
            }
        } else if (staked.specialization == 2) {
            // Regeneration: Boost prowess, improve charge rate
            updatedCalibration.prowess += 5;
            updatedCalibration.charge = Math.min(100, updatedCalibration.charge + 10);
        } else {
            // Invalid specialization
            revert InvalidSpecialization();
        }
        
        return updatedCalibration;
    }
    
    /**
     * @notice Check and validate token variant
     * @param collectionId Collection ID  
     * @param tokenId Token ID
     * @return variant The token variant (1-4)
     */
    function validateTokenVariant(uint256 collectionId, uint256 tokenId) internal view returns (uint8 variant) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        
        try IExternalCollection(collection.collectionAddress).itemVariant(tokenId) returns (uint8 v) {
            variant = v;
            
            // Validate variant is in acceptable range (1-4)
            if (variant < 1 || variant > 4) {
                revert InvalidTokenVariant();
            }
        } catch {
            revert InvalidTokenVariant();
        }
        
        return variant;
    }

    /**
     * @notice Get unified wear level with all resistance and fallback logic
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return wearLevel Unified wear level
     * @return dataSource Source of data ("biopod", "local", or "unavailable")
     */
    function getStakingWearLevel(uint256 collectionId, uint256 tokenId) 
        internal view returns (uint256 wearLevel, string memory dataSource) {
        return getUnifiedWearLevel(collectionId, tokenId);
    }

    /**
     * @notice Get wear level from Henomorphs context (for BiopodFacet)
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return wearLevel Wear level from biopod or 0
     * @return dataSource Source of data
     */
    function getChargepodWearLevel(uint256 collectionId, uint256 tokenId) 
        internal view returns (uint256 wearLevel, string memory dataSource) {
        return getUnifiedWearLevel(collectionId, tokenId);
    }

    /**
     * @notice Apply wear resistance from accessories to a wear level
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param baseWear Base wear level before resistance
     * @return adjustedWear Wear level after resistance applied
     */
    function applyWearResistanceToLevel(
        uint256 collectionId,
        uint256 tokenId,
        uint256 baseWear
    ) internal view returns (uint256 adjustedWear) {
        if (baseWear == 0) {
            return 0;
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        SpecimenCollection storage collection = ss.collections[collectionId];
        
        adjustedWear = baseWear;
        address accessoryModuleAddress = ss.externalModules.accessoryModuleAddress;
        
        if (accessoryModuleAddress != address(0)) {
            try IExternalAccessory(accessoryModuleAddress).equippedAccessories(collectionId, tokenId) returns (ChargeAccessory[] memory accessories) {
                uint256 totalWearResistance = 0;
                
                // Get token's trait packs for matching bonuses
                uint8[] memory tokenTraitPacks = new uint8[](0);
                try IExternalCollection(collection.collectionAddress).itemEquipments(tokenId) returns (uint8[] memory traitPacks) {
                    tokenTraitPacks = traitPacks;
                } catch {
                    // Use empty array if trait pack retrieval fails
                }
                
                // FIXED: Loop with early termination to prevent overflow scenarios
                for (uint256 i = 0; i < accessories.length && totalWearResistance < 95; i++) {
                    // Apply base wear resistance
                    if (accessories[i].wearResistance > 0) {
                        totalWearResistance += accessories[i].wearResistance;
                        
                        // Additional bonus for rare accessories
                        if (accessories[i].rare) {
                            totalWearResistance += 5;
                        }
                    }
                    
                    // Check for trait pack match
                    if (accessories[i].traitPackId > 0) {
                        bool traitPackMatch = false;
                        
                        for (uint256 j = 0; j < tokenTraitPacks.length; j++) {
                            if (tokenTraitPacks[j] == accessories[i].traitPackId) {
                                traitPackMatch = true;
                                break;
                            }
                        }
                        
                        if (traitPackMatch) {
                            totalWearResistance += 10;
                        }
                    }
                    
                    // FIXED: Cap during accumulation to prevent overflow
                    if (totalWearResistance > 95) {
                        totalWearResistance = 95;
                        break;
                    }
                }
                
                // Apply wear reduction (max 95% to always have some wear)
                uint256 wearReduction = adjustedWear * totalWearResistance / 100;
                adjustedWear = adjustedWear > wearReduction ? adjustedWear - wearReduction : 0;
            } catch {
                // Return base wear if accessory retrieval fails
            }
        }
        
        return adjustedWear;
    }

    /**
     * @notice Unified wear level retrieval with clear source hierarchy
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return wearLevel Unified wear level
     * @return dataSource Source of data ("biopod_staking", "local_staking", "biopod_henomorphs", "unavailable")
     */
    function getUnifiedWearLevel(uint256 collectionId, uint256 tokenId)
        internal view returns (uint256 wearLevel, string memory dataSource) {

        // Priority 1: Staking system (if token is staked)
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        if (collectionId <= ss.collectionCounter) {
            uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
            StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];

            if (staked.staked) {
                // Use local time-based calculation for staked tokens
                // This is the authoritative source - no external Biopod calls
                wearLevel = calculateCurrentWear(collectionId, tokenId);
                return (wearLevel, "local_staking");
            }
        }

        // Priority 2: Henomorphs system (for non-staked tokens)
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        if (collectionId <= hs.collectionCounter) {
            // For non-staked tokens, return 0 wear (they don't accumulate wear)
            return (0, "not_staked");
        }

        return (0, "unavailable");
    }

    /**
     * @notice Calculate wear penalty based on wear level
     * @param wearLevel Current wear level
     * @return penalty Wear penalty percentage
     */
    function calculateWearPenalty(uint256 wearLevel) internal view returns (uint256 penalty) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        penalty = 0;
        
        // Find applicable penalty based on thresholds
        for (uint8 i = 0; i < ss.wearPenaltyThresholds.length; i++) {
            if (wearLevel >= ss.wearPenaltyThresholds[i]) {
                penalty = ss.wearPenaltyValues[i];
            }
        }
        
        return penalty;
    }
}