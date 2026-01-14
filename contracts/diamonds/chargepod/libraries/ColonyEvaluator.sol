// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "./LibHenomorphsStorage.sol";
import {PodsUtils} from "../../libraries/PodsUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ChargeAccessory, SpecimenCollection} from "../../libraries/HenomorphsModel.sol";
import {IExternalAccessory, IExternalCollection, IChargeFacet} from "../interfaces/IStakingInterfaces.sol";

/**
 * @title ColonyEvaluator
 * @notice Library for evaluating and ranking colonies based on their members and attributes
 * @dev Provides specialized functions for colony quality assessment
 */
library ColonyEvaluator {
    using Math for uint256;
    
    // Constants for score calculation
    uint8 private constant MAX_VARIANT = 4;
    uint8 private constant DEFAULT_VARIANT = 1;
    uint8 private constant MAX_SAMPLE_SIZE = 10;

    // Struct to group related score data
    struct ColonyScores {
        uint256 totalCalibration;
        uint256 totalAccessory;
        uint256 totalVariant;
        uint256 validSamples;
        // New fields to track variant distribution
        uint8[5] variantCounts; // Index 0 unused, indices 1-4 for variants
        uint8 uniqueVariantsCount;
    }
    
     /**
     * @notice Calculate individual token scores with adjusted variant scoring
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return calibration Calibration score
     * @return accessory Accessory score
     * @return variant Variant score with non-linear scaling
     */
    function calculateTokenScores(uint256 collectionId, uint256 tokenId) 
        internal view returns (uint256 calibration, uint256 accessory, uint256 variant) 
    {
        calibration = calculateTokenCalibrationScore(collectionId, tokenId);
        accessory = calculateTokenAccessoryScore(collectionId, tokenId);
        
        // Non-linear variant scoring to reduce extreme advantages
        uint8 tokenVariant = getTokenVariant(collectionId, tokenId);
        
        // Progressive scale: 3, 7, 12, 18 points for variants 1-4
        // This provides meaningful steps without excessive weighting for higher variants
        if (tokenVariant == 1) variant = 3;
        else if (tokenVariant == 2) variant = 7;
        else if (tokenVariant == 3) variant = 12;
        else variant = 18; // variant 4
    }

    /**
     * @notice Calculate bonus from average scores with adjusted weights and diversity bonus
     * @param scores Colony score data including variant distribution
     * @return Final calculated bonus percentage
     */
    function calculateBonusFromScores(ColonyScores memory scores) internal pure returns (uint256) {
        if (scores.validSamples == 0) {
            return 10; // Base bonus if no valid samples
        }
        
        // Calculate average scores
        uint256 avgCalibration = scores.totalCalibration / scores.validSamples;
        uint256 avgAccessory = scores.totalAccessory / scores.validSamples;
        uint256 avgVariant = scores.totalVariant / scores.validSamples;
        
        // Apply adjusted weighting to reduce variant dominance
        // Increased calibration weight (45%), kept accessory weight (30%), reduced variant weight (25%)
        uint256 additionalBonus = 
            ((avgCalibration * 45) / 100) + 
            ((avgAccessory * 30) / 100) + 
            ((avgVariant * 25) / 100);
            
        // Add diversity bonus (0-5 points based on unique variants present)
        uint256 diversityBonus = 0;
        if (scores.validSamples >= 3) { // Only apply to colonies with at least 3 valid samples
            if (scores.uniqueVariantsCount >= 4) {
                diversityBonus = 5; // Max bonus for all 4 variants
            } else if (scores.uniqueVariantsCount == 3) {
                diversityBonus = 3; // Good bonus for 3 variants
            } else if (scores.uniqueVariantsCount == 2) {
                diversityBonus = 1; // Small bonus for 2 variants
            }
        }
        
        // Cap total additional bonus at 40%
        uint256 totalBonus = additionalBonus + diversityBonus;
        return 10 + (totalBonus > 40 ? 40 : totalBonus);
    }

    /**
     * @notice Calculate dynamic bonus for a colony with variant diversity consideration
     * @param colonyId Colony ID to evaluate
     * @return Calculated bonus percentage
     */
    function calculateColonyDynamicBonus(bytes32 colonyId) internal view returns (uint256) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Verify colony exists
        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            return 0;
        }
        
        // Get colony members
        uint256[] storage members = hs.colonies[colonyId];
        if (members.length == 0) {
            return 10; // Empty colony - return minimal bonus
        }
        
        // Determine sample size - dynamic based on colony size
        uint256 sampleSize;
        if (members.length <= MAX_SAMPLE_SIZE) {
            sampleSize = members.length; // Sample all for small colonies
        } else {
            // For larger colonies, use a percentage-based approach
            sampleSize = members.length < 50 ? MAX_SAMPLE_SIZE : members.length / 5;
            // Cap at a reasonable maximum to avoid excessive gas usage
            if (sampleSize > 20) sampleSize = 20;
        }
        
        // Initialize scores tracking with enhanced variant distribution tracking
        ColonyScores memory scores;
        scores.variantCounts = [0, 0, 0, 0, 0]; // Initialize array
        scores.uniqueVariantsCount = 0;
        
        // Deterministic but pseudo-random sampling with distributed indices
        uint256 step = members.length / sampleSize;
        uint256 offset = uint256(colonyId) % members.length;
        
        // Examine sampled members
        for (uint256 i = 0; i < sampleSize; i++) {
            uint256 sampleIndex = (offset + i * step) % members.length;
            uint256 memberCombinedId = members[sampleIndex];
            
            (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(memberCombinedId);
            
            // Calculate all scores in one call
            (uint256 calibration, uint256 accessory, uint256 variant) = calculateTokenScores(collectionId, tokenId);
            
            // Only count valid tokens (with non-zero scores)
            if (calibration > 0 || accessory > 0 || variant > 0) {
                scores.totalCalibration += calibration;
                scores.totalAccessory += accessory;
                scores.totalVariant += variant;
                scores.validSamples++;
                
                // Track variant distribution for diversity calculation
                uint8 tokenVariant = getTokenVariant(collectionId, tokenId);
                if (tokenVariant >= 1 && tokenVariant <= 4) {
                    // First occurrence of this variant
                    if (scores.variantCounts[tokenVariant] == 0) {
                        scores.uniqueVariantsCount++;
                    }
                    scores.variantCounts[tokenVariant]++;
                }
            }
        }
        
        // Calculate final bonus
        return calculateBonusFromScores(scores);
    }
    
    /**
     * @notice Calculate token calibration score with adjusted variant contribution
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return score Calibration score for the token
     */
    function calculateTokenCalibrationScore(uint256 collectionId, uint256 tokenId) private view returns (uint256 score) {
        // Get token level
        uint8 level = getTokenLevel(collectionId, tokenId);
        
        // Get token variant
        uint8 variant = getTokenVariant(collectionId, tokenId);
        
        // Modified scoring system: emphasize level more, reduce variant impact
        uint256 baseScore = level/10; // 0-10 points based on level
        
        // Adjusted variant bonus with smaller increments: 1.5, 3, 4.5, 6 points
        uint256 variantBonus = (variant * 3) / 2; 
        
        return baseScore + variantBonus; // Range 0-16
    }
    
    /**
     * @notice Calculate token accessory score for ranking
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return score Accessory score for the token
     */
    function calculateTokenAccessoryScore(uint256 collectionId, uint256 tokenId) private view returns (uint256 score) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Try to get accessories from charge module
        address chargeModule = hs.internalModules.chargeModuleAddress;
        if (chargeModule == address(0)) {
            return 0;
        }
        
        try IExternalAccessory(chargeModule).getTokenAccessories(collectionId, tokenId) returns (ChargeAccessory[] memory accessories) {
            score = 0;
            for (uint256 i = 0; i < accessories.length; i++) {
                score += 2; // Base points per accessory
                
                if (accessories[i].rare) {
                    score += 3; // Bonus points for rare accessory
                }
                
                // Additional points for specialized accessories
                if (accessories[i].stakingBoostPercentage > 0) {
                    score += 2;
                }
            }
        } catch {
            // If call fails, return 0
            return 0;
        }
        
        return score; // Typical range 0-15
    }
    
    /**
     * @notice Get token level from charge system
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return level Token level
     */
    function getTokenLevel(uint256 collectionId, uint256 tokenId) private view returns (uint8 level) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        address chargeModule = hs.internalModules.chargeModuleAddress;
        
        if (chargeModule != address(0)) {
            try IChargeFacet(chargeModule).getSpecimenData(collectionId, tokenId) returns (
                uint256, uint256, uint256, uint8, uint256 chargeLevel
            ) {
                return uint8(chargeLevel);
            } catch {}
        }
        
        return 0;
    }
    
    /**
     * @notice Get token variant from collection
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return variant Token variant (1-4)
     */
    function getTokenVariant(uint256 collectionId, uint256 tokenId) private view returns (uint8 variant) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            return DEFAULT_VARIANT; // Default to 1 if invalid collection
        }
        
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        
        if (collection.collectionAddress == address(0)) {
            return DEFAULT_VARIANT;
        }
        
        try IExternalCollection(collection.collectionAddress).itemVariant(tokenId) returns (uint8 v) {
            variant = v;
        } catch {
            // Set a default variant if retrieval fails
            variant = DEFAULT_VARIANT;
        }
        
        // Variant should be in range 1-4
        if (variant < 1 || variant > MAX_VARIANT) {
            variant = DEFAULT_VARIANT;
        }
        
        return variant;
    }
}