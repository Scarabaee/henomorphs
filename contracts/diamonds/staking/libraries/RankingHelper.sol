// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../../chargepod/libraries/LibHenomorphsStorage.sol";
import {LibStakingStorage} from "./LibStakingStorage.sol";
import {PodsUtils} from "../../../libraries/PodsUtils.sol";
import {LibTraitPackHelper} from "../../chargepod/libraries/LibTraitPackHelper.sol";
import {StakedSpecimen, InfusedSpecimen} from "../../../libraries/StakingModel.sol";
import {ChargeAccessory} from "../../../libraries/HenomorphsModel.sol";

/**
 * @title RankingHelper
 * @notice Central library for token and owner ranking calculations
 * @dev Uses structures and modular approach to avoid stack too deep errors
 * @author rutilicus.eth (ArchXS)
 */
library RankingHelper {
    
    /**
     * @notice Structure for token ranking metrics
     * @dev Used to avoid stack too deep errors when returning multiple values
     */
    struct TokenRankingMetrics {
        uint256 variantScore;      // Score from variant (weighted)
        uint256 levelScore;        // Score from level (weighted)
        uint256 infusionScore;     // Score from infusion (weighted)
        uint256 colonyScore;       // Score from colony membership (weighted)
        uint256 accessoryScore;    // Score from accessories (weighted)
        uint256 traitPackScore;    // Score from trait packs (weighted)
        int256 wearPenalty;        // Penalty from wear level
        uint256 rankingValue;      // Final calculated ranking value
    }
    
    /**
     * @notice Structure for owner ranking metrics
     * @dev Used to avoid stack too deep errors when returning multiple values
     */
    struct OwnerRankingMetrics {
        uint256 tokenCountScore;    // Score from token count (weighted)
        uint256 infusionScore;      // Score from total infusion value (weighted)
        uint256 qualityScore;       // Score from token quality (weighted)
        uint256 loyaltyScore;       // Score from loyalty program (weighted)
        uint256 diversityScore;     // Score from variant diversity (weighted)
        uint256 rankingValue;       // Final calculated ranking value
    }
    
    /**
     * @notice Structure for owner token statistics
     * @dev Contains aggregated data about owner's tokens
     */
    struct OwnerTokenStats {
        uint256 tokenCount;        // Number of staked tokens
        uint256 infusedValue;      // Total infused ZICO value
        uint256 avgLevel;          // Average token level
        uint256 avgVariant;        // Average token variant (x100)
        uint256 variantDistribution; // Bitmap of variant distribution
    }
    
    // Component weights for token ranking
    uint256 private constant VARIANT_WEIGHT = 20;
    uint256 private constant LEVEL_WEIGHT = 15;
    uint256 private constant INFUSION_WEIGHT = 15;
    uint256 private constant COLONY_WEIGHT = 15;
    uint256 private constant ACCESSORY_WEIGHT = 15;
    uint256 private constant TRAIT_PACK_WEIGHT = 15;
    uint256 private constant WEAR_WEIGHT = 5;
    
    // Component weights for owner ranking
    uint256 private constant TOKEN_COUNT_WEIGHT = 35;
    uint256 private constant OWNER_INFUSION_WEIGHT = 30;
    uint256 private constant TOKEN_QUALITY_WEIGHT = 25;
    uint256 private constant LOYALTY_WEIGHT = 5;
    uint256 private constant DIVERSITY_WEIGHT = 5;
    
    /**
     * @notice Calculate all token ranking metrics in a single call
     * @dev Returns a structure to avoid stack too deep errors
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return metrics Comprehensive metrics structure with all scores
     */
    function calculateTokenRankingMetrics(
        uint256 collectionId, 
        uint256 tokenId
    ) public view returns (TokenRankingMetrics memory metrics) {
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Skip if not staked
        if (!ss.stakedSpecimens[combinedId].staked) {
            return TokenRankingMetrics(0, 0, 0, 0, 0, 0, 0, 0);
        }
        
        // Calculate all component scores
        metrics.variantScore = calculateVariantScore(combinedId);
        metrics.levelScore = calculateLevelScore(combinedId);
        metrics.infusionScore = calculateInfusionScore(combinedId);
        metrics.colonyScore = calculateColonyScore(combinedId);
        metrics.accessoryScore = calculateAccessoryScore(combinedId);
        metrics.traitPackScore = calculateTraitPackScore(collectionId, tokenId);
        metrics.wearPenalty = calculateWearPenalty(combinedId);
        
        // Calculate final ranking value
        uint256 positiveScores = metrics.variantScore + 
                                metrics.levelScore + 
                                metrics.infusionScore + 
                                metrics.colonyScore + 
                                metrics.accessoryScore + 
                                metrics.traitPackScore;
        
        // Apply wear penalty (can't reduce below 0)
        int256 adjustedScore = int256(positiveScores) + metrics.wearPenalty;
        metrics.rankingValue = adjustedScore > 0 ? uint256(adjustedScore) : 0;
        
        return metrics;
    }
    
    /**
     * @notice Calculate variant score component 
     * @param combinedId Combined token ID
     * @return score Variant score (weighted)
     */
    function calculateVariantScore(uint256 combinedId) internal view returns (uint256 score) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        // Calculate base score (0-100 scale)
        uint256 baseScore;
        if (staked.variant == 1) baseScore = 25;
        else if (staked.variant == 2) baseScore = 50;
        else if (staked.variant == 3) baseScore = 75;
        else if (staked.variant == 4) baseScore = 100;
        else baseScore = 10; // Default for invalid variants
        
        // Apply weight
        score = baseScore * VARIANT_WEIGHT / 100;
        
        return score;
    }
    
    /**
     * @notice Calculate level score component 
     * @param combinedId Combined token ID
     * @return score Level score (weighted)
     */
    function calculateLevelScore(uint256 combinedId) internal view returns (uint256 score) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        // Calculate base score (0-100 scale)
        uint256 baseScore = staked.level;
        if (baseScore > 100) baseScore = 100;
        
        // Apply weight
        score = baseScore * LEVEL_WEIGHT / 100;
        
        return score;
    }
    
    /**
     * @notice Calculate infusion score component 
     * @param combinedId Combined token ID
     * @return score Infusion score (weighted)
     */
    function calculateInfusionScore(uint256 combinedId) internal view returns (uint256 score) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        InfusedSpecimen storage infused = ss.infusedSpecimens[combinedId];
        
        // Calculate base score (0-100 scale)
        uint256 baseScore = 0;
        
        // Infusion level contribution (0-50 points)
        uint256 levelPoints = staked.infusionLevel * 10; // 10 points per level
        if (levelPoints > 50) levelPoints = 50;
        
        // Infused amount contribution (0-50 points)
        uint256 amountPoints = 0;
        if (infused.infused) {
            // 1 point per 10 ZICO infused, max 50 points
            amountPoints = (infused.infusedAmount / 10 ether);
            if (amountPoints > 50) amountPoints = 50;
        }
        
        baseScore = levelPoints + amountPoints;
        if (baseScore > 100) baseScore = 100;
        
        // Apply weight
        score = baseScore * INFUSION_WEIGHT / 100;
        
        return score;
    }
    
    /**
     * @notice Calculate colony membership score component 
     * @param combinedId Combined token ID
     * @return score Colony score (weighted)
     */
    function calculateColonyScore(uint256 combinedId) internal view returns (uint256 score) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        // Calculate base score (0-100 scale)
        uint256 baseScore = 0;
        
        if (staked.colonyId != bytes32(0)) {
            // Verify colony exists
            if (bytes(hs.colonyNamesById[staked.colonyId]).length > 0) {
                // Default score for belonging to any colony
                baseScore = 50;
                
                // If colony has an explicit bonus, factor it in
                if (ss.colonyStakingBonuses[staked.colonyId] > 0) {
                    // Calculate additional points based on colony bonus (max +25)
                    uint256 bonusPoints = ss.colonyStakingBonuses[staked.colonyId] / 4;
                    if (bonusPoints > 25) bonusPoints = 25;
                    baseScore += bonusPoints;
                }
                
                // Size bonus - larger colonies get additional points
                uint256 memberCount = hs.colonies[staked.colonyId].length;
                if (memberCount >= 15) {
                    baseScore += 25; // Maximum size bonus
                } else if (memberCount >= 10) {
                    baseScore += 15;
                } else if (memberCount >= 5) {
                    baseScore += 10;
                } else {
                    baseScore += 5;
                }
                
                // Cap at 100
                if (baseScore > 100) baseScore = 100;
            }
        }
        
        // Apply weight
        score = baseScore * COLONY_WEIGHT / 100;
        
        return score;
    }
    
    /**
     * @notice Calculate accessory score component 
     * @param combinedId Combined token ID
     * @return score Accessory score (weighted)
     */
    function calculateAccessoryScore(uint256 combinedId) internal view returns (uint256 score) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Calculate base score (0-100 scale)
        uint256 baseScore = 0;
        
        ChargeAccessory[] storage accessories = hs.equippedAccessories[combinedId];
        
        if (accessories.length > 0) {
            // Base points for each accessory (20 points each)
            baseScore = accessories.length * 20;
            
            // Additional points for rare accessories
            for (uint256 i = 0; i < accessories.length; i++) {
                if (accessories[i].rare) {
                    baseScore += 10; // Bonus for rare accessory
                }
            }
            
            // Cap at 100
            if (baseScore > 100) baseScore = 100;
        }
        
        // Apply weight
        score = baseScore * ACCESSORY_WEIGHT / 100;
        
        return score;
    }
    
    /**
     * @notice Calculate trait pack score component 
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return score Trait pack score (weighted)
     */
    function calculateTraitPackScore(uint256 collectionId, uint256 tokenId) internal view returns (uint256 score) {
        // Calculate base score (0-100 scale)
        uint256 baseScore = 0;
        
        (bool traitPackMatch, uint8[] memory tokenTraitPacks) = LibTraitPackHelper.verifyTraitPack(
            collectionId,
            tokenId,
            0 // 0 means we want all trait packs, not checking for a specific one
        );
        
        if (traitPackMatch && tokenTraitPacks.length > 0) {
            // 30 points per trait pack
            baseScore = tokenTraitPacks.length * 30;
            
            // Cap at 100
            if (baseScore > 100) baseScore = 100;
        }
        
        // Apply weight
        score = baseScore * TRAIT_PACK_WEIGHT / 100;
        
        return score;
    }
    
    /**
     * @notice Calculate wear penalty component 
     * @param combinedId Combined token ID
     * @return penalty Wear penalty (negative value, weighted)
     */
    function calculateWearPenalty(uint256 combinedId) internal view returns (int256 penalty) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        // Calculate base penalty (0 to -100 scale)
        int256 basePenalty = 0;
        
        if (staked.wearLevel > 0) {
            basePenalty = -int256(uint256(staked.wearLevel)); // Convert wear to negative score
        }
        
        // Apply weight
        penalty = basePenalty * int256(WEAR_WEIGHT) / 100;
        
        return penalty;
    }
    
    /**
     * @notice Get final token ranking value (simpler interface)
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return rankingValue Final ranking value
     */
    function getTokenRankingValue(uint256 collectionId, uint256 tokenId) public view returns (uint256 rankingValue) {
        TokenRankingMetrics memory metrics = calculateTokenRankingMetrics(collectionId, tokenId);
        return metrics.rankingValue;
    }
    
    /**
     * @notice Calculate token statistics for an owner address
     * @dev Aggregates data from all staked tokens owned by the address
     * @param owner Owner address
     * @return stats Structure with aggregated token statistics
     */
    function calculateOwnerTokenStats(address owner) public view returns (OwnerTokenStats memory stats) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Get tokens owned by this address
        uint256[] storage ownerTokens = ss.stakerTokens[owner];
        
        // Initialize counters
        uint256 totalLevel = 0;
        uint256 totalVariant = 0;
        stats.variantDistribution = 0;
        
        // Process each token to calculate statistics
        for (uint256 j = 0; j < ownerTokens.length; j++) {
            uint256 combinedId = ownerTokens[j];
            
            // Skip if not staked
            if (!ss.stakedSpecimens[combinedId].staked) {
                continue;
            }
            
            stats.tokenCount++;
            
            // Get token data
            StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
            InfusedSpecimen storage infused = ss.infusedSpecimens[combinedId];
            
            // Add infused value if any
            if (infused.infused) {
                stats.infusedValue += infused.infusedAmount;
            }
            
            // Accumulate level and variant stats
            totalLevel += staked.level;
            totalVariant += staked.variant;
            
            // Track variant distribution
            if (staked.variant > 0 && staked.variant < 5) {
                // Set bit in variant distribution bitmap
                stats.variantDistribution |= (1 << (staked.variant - 1));
            }
        }
        
        // Calculate averages if tokens exist
        if (stats.tokenCount > 0) {
            stats.avgLevel = totalLevel / stats.tokenCount;
            // Use x100 for more precision in average variant
            stats.avgVariant = (totalVariant * 100) / stats.tokenCount;
        }
        
        return stats;
    }
    
    /**
     * @notice Calculate owner ranking metrics
     * @dev Returns a structure to avoid stack too deep errors
     * @param owner Owner address
     * @return metrics Comprehensive owner metrics structure
     */
    function calculateOwnerRankingMetrics(address owner) public view returns (OwnerRankingMetrics memory metrics) {
        // Get aggregate token statistics
        OwnerTokenStats memory stats = calculateOwnerTokenStats(owner);
        
        // Calculate token count score (0-100 scale)
        uint256 tokenCountBaseScore;
        if (stats.tokenCount >= 15) {
            tokenCountBaseScore = 100;
        } else if (stats.tokenCount >= 10) {
            tokenCountBaseScore = 75;
        } else if (stats.tokenCount >= 5) {
            tokenCountBaseScore = 50;
        } else {
            tokenCountBaseScore = stats.tokenCount * 10; // 10 points per token for 1-4 tokens
        }
        
        // Apply weight to token count score
        metrics.tokenCountScore = tokenCountBaseScore * TOKEN_COUNT_WEIGHT / 100;
        
        // Calculate infusion value score (0-100 scale)
        uint256 infusionValueBaseScore;
        uint256 infusionValueScaled = stats.infusedValue / 1 ether; // Convert to whole tokens
        if (infusionValueScaled >= 5000) {
            infusionValueBaseScore = 100;
        } else {
            // 2 points per 100 ZICO infused
            infusionValueBaseScore = (infusionValueScaled / 100) * 2;
            if (infusionValueBaseScore > 100) infusionValueBaseScore = 100;
        }
        
        // Apply weight to infusion value score
        metrics.infusionScore = infusionValueBaseScore * OWNER_INFUSION_WEIGHT / 100;
        
        // Calculate token quality score based on average metrics
        uint256 qualityBaseScore = calculateOwnerTokenQualityScore(owner);
        
        // Apply weight to quality score
        metrics.qualityScore = qualityBaseScore * TOKEN_QUALITY_WEIGHT / 100;
        
        // Calculate loyalty score (0-100 scale)
        uint256 loyaltyBaseScore = calculateOwnerLoyaltyScore(owner);
        
        // Apply weight to loyalty score
        metrics.loyaltyScore = loyaltyBaseScore * LOYALTY_WEIGHT / 100;
        
        // Calculate diversity score based on variant distribution
        uint256 diversityBaseScore = calculateOwnerDiversityScore(stats.variantDistribution);
        
        // Apply weight to diversity score
        metrics.diversityScore = diversityBaseScore * DIVERSITY_WEIGHT / 100;
        
        // Calculate final ranking value
        metrics.rankingValue = metrics.tokenCountScore + 
                              metrics.infusionScore + 
                              metrics.qualityScore + 
                              metrics.loyaltyScore + 
                              metrics.diversityScore;
        
        return metrics;
    }
    
    /**
     * @notice Calculate quality score based on token characteristics
     * @dev Evaluates average token metrics
     * @param owner Owner address
     * @return qualityScore Score based on token quality metrics (0-100)
     */
    function calculateOwnerTokenQualityScore(address owner) internal view returns (uint256 qualityScore) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256[] storage ownerTokens = ss.stakerTokens[owner];
        
        if (ownerTokens.length == 0) {
            return 0;
        }
        
        // Initialize counters for various quality metrics
        uint256 totalVariantScore = 0;
        uint256 totalLevelScore = 0;
        uint256 totalInfusionScore = 0;
        uint256 validTokenCount = 0;
        
        // Analyze all tokens deterministically
        for (uint256 i = 0; i < ownerTokens.length; i++) {
            uint256 combinedId = ownerTokens[i];
            
            // Skip if not staked
            if (!ss.stakedSpecimens[combinedId].staked) {
                continue;
            }
            
            StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
            
            // Progressive variant scoring (higher variants worth more)
            uint256 variantScore;
            if (staked.variant == 1) variantScore = 2;
            else if (staked.variant == 2) variantScore = 4;
            else if (staked.variant == 3) variantScore = 7;
            else if (staked.variant == 4) variantScore = 10;
            else variantScore = 1; // Default for invalid variants
            
            // Level score (0-10 based on level/10)
            uint256 levelScore = staked.level / 10;
            if (levelScore > 10) levelScore = 10;
            
            // Infusion score (2 points per infusion level)
            uint256 infusionScore = staked.infusionLevel * 2;
            if (infusionScore > 10) infusionScore = 10;
            
            // Accumulate scores
            totalVariantScore += variantScore;
            totalLevelScore += levelScore;
            totalInfusionScore += infusionScore;
            validTokenCount++;
        }
        
        // Calculate average scores
        if (validTokenCount == 0) {
            return 0;
        }
        
        uint256 avgVariantScore = totalVariantScore / validTokenCount;
        uint256 avgLevelScore = totalLevelScore / validTokenCount;
        uint256 avgInfusionScore = totalInfusionScore / validTokenCount;
        
        // Combine scores with weights - total scale is 0-100
        qualityScore = (avgVariantScore * 40) + (avgLevelScore * 40) + (avgInfusionScore * 20);
        
        // Cap at 100 points
        if (qualityScore > 100) {
            qualityScore = 100;
        }
        
        return qualityScore;
    }
    
    /**
     * @notice Calculate loyalty score based on loyalty program tier
     * @param owner Owner address
     * @return loyaltyScore Score based on loyalty tier (0-100)
     */
    function calculateOwnerLoyaltyScore(address owner) internal view returns (uint256 loyaltyScore) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        loyaltyScore = 0;
        
        if (ss.loyaltyProgramEnabled) {
            LibStakingStorage.LoyaltyTierAssignment storage tierAssignment = ss.addressTierAssignments[owner];
            if (tierAssignment.tierLevel != LibStakingStorage.LoyaltyTierLevel.NONE && 
                (tierAssignment.expiryTime == 0 || block.timestamp <= tierAssignment.expiryTime)) {
                
                LibStakingStorage.LoyaltyTierConfig storage tierConfig = ss.loyaltyTierConfigs[tierAssignment.tierLevel];
                if (tierConfig.active) {
                    loyaltyScore = tierConfig.bonusPercent;
                    // Cap at 100 points
                    if (loyaltyScore > 100) loyaltyScore = 100;
                }
            }
        }
        
        return loyaltyScore;
    }
    
    /**
     * @notice Calculate diversity score based on variant distribution
     * @param variantDistribution Bitmap of variant distribution
     * @return diversityScore Score based on variant diversity (0-100)
     */
    function calculateOwnerDiversityScore(uint256 variantDistribution) internal pure returns (uint256 diversityScore) {
        // Count unique variants (bits set in distribution)
        uint256 uniqueVariantCount = 0;
        for (uint256 v = 0; v < 4; v++) {
            if ((variantDistribution & (1 << v)) != 0) {
                uniqueVariantCount++;
            }
        }
        
        // Score based on unique variants (25 points per variant)
        diversityScore = uniqueVariantCount * 25;
        
        // Cap at 100
        if (diversityScore > 100) {
            diversityScore = 100;
        }
        
        return diversityScore;
    }
    
    /**
     * @notice Get final owner ranking value (simpler interface)
     * @param owner Owner address
     * @return rankingValue Final ranking value
     */
    function getOwnerRankingValue(address owner) public view returns (uint256 rankingValue) {
        OwnerRankingMetrics memory metrics = calculateOwnerRankingMetrics(owner);
        return metrics.rankingValue;
    }

    /**
     * @notice Find staked tokens using multiple reliable methods
     * @dev Works even if activeStakers array is empty or missing
     * @param maxResults Maximum number of tokens to return
     * @return tokens Array of combined token IDs
     * @return owners Array of corresponding owners
     * @return count Actual number of tokens found
     */
    function findStakedTokens(uint256 maxResults) public view returns (
        uint256[] memory tokens,
        address[] memory owners,
        uint256 count
    ) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Initialize result arrays
        tokens = new uint256[](maxResults);
        owners = new address[](maxResults);
        count = 0;
        
        // METHOD 1: Try using stakerTokens for all known addresses (most reliable)
        // This will work as long as any tokens have been staked
        for (uint256 collId = 1; collId <= ss.collectionCounter && count < maxResults; collId++) {
            // Skip disabled collections
            if (!ss.collections[collId].enabled) continue;
            
            address collectionAddress = ss.collections[collId].collectionAddress;
            if (collectionAddress == address(0)) continue;
            
            // Use a practical upper limit for token IDs to avoid excessive gas usage
            uint256 maxTokensPerCollection = 1000;
            
            for (uint256 tokenId = 1; tokenId <= maxTokensPerCollection && count < maxResults; tokenId++) {
                uint256 combinedId = PodsUtils.combineIds(collId, tokenId);
                
                // Check if token is staked
                if (ss.stakedSpecimens[combinedId].staked) {
                    tokens[count] = combinedId;
                    owners[count] = ss.stakedSpecimens[combinedId].owner;
                    count++;
                }
            }
        }
        
        // If we found nothing, try a targeted approach with known token patterns
        if (count == 0) {
            // Sample from first few collections with some common token IDs
            uint256[] memory collectionSamples = new uint256[](5);
            uint256[] memory tokenSamples = new uint256[](10);
            
            // First 5 collections (likely to exist)
            for (uint256 i = 0; i < 5; i++) {
                collectionSamples[i] = i + 1;
            }
            
            // Common token ID patterns
            tokenSamples[0] = 1;
            tokenSamples[1] = 10;
            tokenSamples[2] = 100;
            tokenSamples[3] = 101;
            tokenSamples[4] = 1000;
            tokenSamples[5] = 1001;
            tokenSamples[6] = 10000;
            tokenSamples[7] = 10001;
            tokenSamples[8] = 42;  // Answer to everything
            tokenSamples[9] = 888; // Lucky number in some cultures
            
            // Check these sample combinations
            for (uint256 i = 0; i < collectionSamples.length && count < maxResults; i++) {
                for (uint256 j = 0; j < tokenSamples.length && count < maxResults; j++) {
                    uint256 combinedId = PodsUtils.combineIds(collectionSamples[i], tokenSamples[j]);
                    
                    if (ss.stakedSpecimens[combinedId].staked) {
                        tokens[count] = combinedId;
                        owners[count] = ss.stakedSpecimens[combinedId].owner;
                        count++;
                    }
                }
            }
        }
        
        return (tokens, owners, count);
    }

    /**
     * @notice Find all unique staker addresses in the system
     * @dev Works even if activeStakers array is empty or missing
     * @param maxResults Maximum number of addresses to return
     * @return stakers Array of staker addresses
     * @return count Actual number of stakers found
     */
    function findAllStakers(uint256 maxResults) public view returns (
        address[] memory stakers,
        uint256 count
    ) {
        // Initialize result array
        stakers = new address[](maxResults);
        count = 0;
        
        // Find tokens first
        (, address[] memory tokenOwners, uint256 tokenCount) = 
            findStakedTokens(maxResults * 2); // Look for more tokens to find more unique stakers
        
        // Add unique stakers - O(n²) algorithm but with manageable limits
        for (uint256 i = 0; i < tokenCount && count < maxResults; i++) {
            address owner = tokenOwners[i];
            bool isDuplicate = false;
            
            // Check if we already added this address
            for (uint256 j = 0; j < count; j++) {
                if (stakers[j] == owner) {
                    isDuplicate = true;
                    break;
                }
            }
            
            // Add if unique
            if (!isDuplicate) {
                stakers[count] = owner;
                count++;
            }
        }
        
        return (stakers, count);
    }
}