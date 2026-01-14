// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {PodsUtils} from "../../libraries/PodsUtils.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {ChargeAccessory, SpecimenCollection, Calibration} from "../../libraries/HenomorphsModel.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {IChargeFacet, IExternalBiopod, IExternalCollection, IExternalAccessory, IStakingSystem} from "../interfaces/IStakingInterfaces.sol";
import {LibTraitPackHelper} from "../libraries/LibTraitPackHelper.sol";
import {LibDiamond} from "../../shared/libraries/LibDiamond.sol";

/**
 * @title InventoryRankingFacet
 * @notice Implementation of ranking facet based on colony data with staking integration for ownership
 */
contract InventoryRankingFacet is AccessControlBase {
    // Component weights for token ranking
    uint256 private constant VARIANT_WEIGHT = 25;
    uint256 private constant LEVEL_WEIGHT = 25;
    uint256 private constant COLONY_WEIGHT = 20;
    uint256 private constant ACCESSORY_WEIGHT = 20;
    uint256 private constant TRAIT_PACK_WEIGHT = 10;
    
    // Component weights for owner ranking
    uint256 private constant TOKEN_COUNT_WEIGHT = 45;
    uint256 private constant TOKEN_QUALITY_WEIGHT = 40;
    uint256 private constant LOYALTY_WEIGHT = 5;
    uint256 private constant DIVERSITY_WEIGHT = 10;
    
    /**
     * @notice Token ranking item structure for output
     */
    struct TokenRankingItem {
        uint256 rank;              // Position in ranking
        uint256 collectionId;      // Collection ID
        uint256 tokenId;           // Token ID
        address owner;             // Owner address (staker or NFT owner)
        uint8 variant;             // Token variant
        uint8 level;               // Token level
        bytes32 colonyId;          // Colony ID (if any)
        uint256 rankingValue;      // Value used for ranking
    }
    
    /**
     * @notice Structure for token ranking metrics
     */
    struct TokenRankingMetrics {
        uint256 variantScore;      // Score from variant (weighted)
        uint256 levelScore;        // Score from level (weighted)
        uint256 colonyScore;       // Score from colony membership (weighted)
        uint256 accessoryScore;    // Score from accessories (weighted)
        uint256 traitPackScore;    // Score from trait packs (weighted)
        int256 wearPenalty;        // Penalty from wear level (from biopod)
        uint256 rankingValue;      // Final calculated ranking value
    }
    
    /**
     * @notice Owner ranking item structure for output
     */
    struct OwnerRankingItem {
        uint256 rank;              // Position in ranking
        address ownerAddress;      // Owner's address
        uint256 tokenCount;        // Number of owned tokens
        uint256 rankingValue;      // Value used for ranking
    }

    /**
     * @notice Detailed owner statistics structure for UI display
     */
    struct OwnerDetailedStats {
        uint256 avgTokenLevel;     // Average level across all tokens
        uint256 avgTokenVariant;   // Average variant across all tokens (x100)
        uint256 uniqueVariants;    // Number of unique variants owned
        uint256 highestLevelToken; // Level of highest level token
        uint256 longestChargedDays; // Days since earliest charge
    }
    
    /**
     * @notice Detailed owner metrics structure for UI display
     */
    struct OwnerDetailedMetrics {
        uint256 tokenCountScore;   // Score from token count (weighted)
        uint256 qualityScore;      // Score from token quality (weighted)
        uint256 loyaltyScore;      // Score from loyalty program (weighted)
        uint256 diversityScore;    // Score from variant diversity (weighted)
    }
    
    /**
     * @notice Structure for tracking owner token statistics
     */
    struct OwnerTokenStats {
        uint256 tokenCount;        // Number of tokens owned in colonies
        uint256 totalLevels;       // Sum of token levels
        uint256 totalVariants;     // Sum of token variants
        uint256 variantDistribution; // Bitmap of variant distribution
        uint256 highestLevel;      // Highest token level
        uint256 earliestChargeTime; // Earliest charge time among all tokens
    }

    /**
     * @notice Get tokens ranked by colony membership and charge data
     * @param startIdx Starting index for pagination
     * @param count Maximum number of tokens to return
     * @return ranking Array of ranked token items
     */
    function getTokenRanking(uint256 startIdx, uint256 count) public view returns (
        TokenRankingItem[] memory ranking
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Early return for edge cases
        if (count == 0) {
            return new TokenRankingItem[](0);
        }
        
        // First, find all colony IDs
        (bytes32[] memory colonyIds, ) = getActiveColonyIds(0, 100);
        
        if (colonyIds.length == 0) {
            return new TokenRankingItem[](0);
        }
        
        // Count total tokens in all colonies
        uint256 totalTokenCount = 0;
        uint256 maxTokensToProcess = 300; // Limit for gas reasons
        
        for (uint256 i = 0; i < colonyIds.length && totalTokenCount < maxTokensToProcess; i++) {
            bytes32 colonyId = colonyIds[i];
            uint256[] storage colonyMembers = hs.colonies[colonyId];
            
            totalTokenCount += colonyMembers.length > (maxTokensToProcess - totalTokenCount) ? 
                            (maxTokensToProcess - totalTokenCount) : colonyMembers.length;
        }
        
        // If no tokens found, return empty array
        if (totalTokenCount == 0) {
            return new TokenRankingItem[](0);
        }
        
        // Create array to hold all tokens for sorting
        TokenRankingItem[] memory allTokens = new TokenRankingItem[](totalTokenCount);
        uint256 tokenIndex = 0;
        
        // Gather token data from colonies
        for (uint256 i = 0; i < colonyIds.length && tokenIndex < totalTokenCount; i++) {
            bytes32 colonyId = colonyIds[i];
            uint256[] storage colonyMembers = hs.colonies[colonyId];
            
            for (uint256 j = 0; j < colonyMembers.length && tokenIndex < totalTokenCount; j++) {
                uint256 combinedId = colonyMembers[j];
                (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);
                
                // Verify token exists in colony
                if (hs.specimenColonies[combinedId] == colonyId) {
                    // Get token data
                    uint8 variant = getTokenVariant(collectionId, tokenId);
                    uint8 level = getTokenLevel(collectionId, tokenId);
                    
                    // Get token owner with proper staking checks
                    address owner = getTokenOwner(collectionId, tokenId);
                    
                    // Calculate detailed ranking metrics
                    TokenRankingMetrics memory metrics = calculateTokenRankingMetrics(collectionId, tokenId);
                    
                    // Store token data
                    allTokens[tokenIndex] = TokenRankingItem({
                        rank: 0, // Will be assigned after sorting
                        collectionId: collectionId,
                        tokenId: tokenId,
                        owner: owner,
                        variant: variant,
                        level: level,
                        colonyId: colonyId,
                        rankingValue: metrics.rankingValue
                    });
                    
                    tokenIndex++;
                }
            }
        }
        
        // If no valid tokens were added, return empty array
        if (tokenIndex == 0) {
            return new TokenRankingItem[](0);
        }
        
        // Sort tokens by ranking value (descending) - using safe sort
        safeSortTokens(allTokens, tokenIndex);
        
        // Assign ranks after sorting
        for (uint256 i = 0; i < tokenIndex; i++) {
            allTokens[i].rank = i + 1;
        }
        
        // Handle pagination
        uint256 resultCount = count;
        if (startIdx >= tokenIndex) {
            return new TokenRankingItem[](0);
        }
        
        if (startIdx + resultCount > tokenIndex) {
            resultCount = tokenIndex - startIdx;
        }
        
        // Create result array with pagination
        ranking = new TokenRankingItem[](resultCount);
        for (uint256 i = 0; i < resultCount; i++) {
            ranking[i] = allTokens[startIdx + i];
        }
        
        return ranking;
    }
    
    /**
     * @notice Get top ranked tokens
     * @param count Maximum number of tokens to return
     * @return ranking Array of top ranked token items
     */
    function getTopRankedTokens(uint256 count) external view returns (
        TokenRankingItem[] memory ranking
    ) {
        return getTokenRanking(0, count);
    }
    
    /**
     * @notice Calculate all token ranking metrics in a single call
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return metrics Comprehensive metrics structure with all scores
     */
    function calculateTokenRankingMetrics(
        uint256 collectionId, 
        uint256 tokenId
    ) public view returns (TokenRankingMetrics memory metrics) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        // Get basic token data
        uint8 variant = getTokenVariant(collectionId, tokenId);
        uint8 level = getTokenLevel(collectionId, tokenId);
        bytes32 colonyId = hs.specimenColonies[combinedId];
        
        // Calculate all component scores
        metrics.variantScore = calculateVariantScore(variant);
        metrics.levelScore = calculateLevelScore(level);
        metrics.colonyScore = calculateColonyScore(colonyId);
        metrics.accessoryScore = calculateAccessoryScore(combinedId);
        metrics.traitPackScore = calculateTraitPackScore(collectionId, tokenId);
        metrics.wearPenalty = calculateWearPenalty(collectionId, tokenId);
        
        // Calculate final ranking value
        uint256 positiveScores = metrics.variantScore + 
                                metrics.levelScore + 
                                metrics.colonyScore + 
                                metrics.accessoryScore + 
                                metrics.traitPackScore;
        
        // Apply wear penalty (can't reduce below 0)
        int256 adjustedScore = int256(positiveScores) + metrics.wearPenalty;
        metrics.rankingValue = adjustedScore > 0 ? uint256(adjustedScore) : 0;
        
        return metrics;
    }
    
    /**
     * @notice Get detailed ranking metrics for a specific token
     * @dev Returns weighted component scores and final ranking value
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return variantScore Score from variant (weighted)
     * @return levelScore Score from level (weighted)
     * @return colonyScore Score from colony membership (weighted)
     * @return accessoryScore Score from accessories (weighted)
     * @return traitPackScore Score from trait packs (weighted)
     * @return wearPenalty Penalty from wear level (negative value)
     * @return rankingValue Final ranking value
     */
    function getTokenRankingMetrics(
        uint256 collectionId,
        uint256 tokenId
    ) public view returns (
        uint256 variantScore,
        uint256 levelScore,
        uint256 colonyScore,
        uint256 accessoryScore,
        uint256 traitPackScore,
        int256 wearPenalty,
        uint256 rankingValue
    ) {
        // Use integrated calculateTokenRankingMetrics function
        TokenRankingMetrics memory metrics = calculateTokenRankingMetrics(collectionId, tokenId);
        
        return (
            metrics.variantScore,
            metrics.levelScore,
            metrics.colonyScore,
            metrics.accessoryScore,
            metrics.traitPackScore,
            metrics.wearPenalty,
            metrics.rankingValue
        );
    }
    
    /**
     * @notice Calculate variant score component
     * @param variant Token variant
     * @return score Variant score (weighted)
     */
    function calculateVariantScore(uint8 variant) internal pure returns (uint256 score) {
        // Calculate base score (0-100 scale)
        uint256 baseScore;
        if (variant == 1) baseScore = 25;
        else if (variant == 2) baseScore = 50;
        else if (variant == 3) baseScore = 75;
        else if (variant == 4) baseScore = 100;
        else baseScore = 10; // Default for invalid variants
        
        // Apply weight
        score = baseScore * VARIANT_WEIGHT / 100;
        
        return score;
    }
    
    /**
     * @notice Calculate level score component
     * @param level Token level
     * @return score Level score (weighted)
     */
    function calculateLevelScore(uint8 level) internal pure returns (uint256 score) {
        // Calculate base score (0-100 scale)
        uint256 baseScore = level;
        if (baseScore > 100) baseScore = 100;
        
        // Apply weight
        score = baseScore * LEVEL_WEIGHT / 100;
        
        return score;
    }
    
    /**
     * @notice Calculate colony membership score component
     * @param colonyId Colony ID
     * @return score Colony score (weighted)
     */
    function calculateColonyScore(bytes32 colonyId) internal view returns (uint256 score) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Calculate base score (0-100 scale)
        uint256 baseScore = 0;
        
        if (colonyId != bytes32(0)) {
            // Verify colony exists
            if (bytes(hs.colonyNamesById[colonyId]).length > 0) {
                // Default score for belonging to any colony
                baseScore = 50;
                
                // If colony has an explicit bonus, factor it in
                if (hs.colonyStakingBonuses[colonyId] > 0) {
                    // Calculate additional points based on colony bonus (max +25)
                    uint256 bonusPoints = hs.colonyStakingBonuses[colonyId] / 4;
                    if (bonusPoints > 25) bonusPoints = 25;
                    baseScore += bonusPoints;
                }
                
                // Size bonus - larger colonies get additional points
                uint256 memberCount = hs.colonies[colonyId].length;
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
     * @notice Calculate wear penalty from Biopod data
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return penalty Wear penalty (negative value, weighted)
     */
    function calculateWearPenalty(uint256 collectionId, uint256 tokenId) internal view returns (int256 penalty) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Default to 0 penalty
        penalty = 0;
        
        // Try to get wear from Biopod
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        if (collection.biopodAddress != address(0)) {
            try IExternalBiopod(collection.biopodAddress).probeCalibration(collectionId, tokenId) returns (Calibration memory cal) {
                if (cal.wear > 0) {
                    // Convert wear to negative score (0 to -100 scale)
                    int256 basePenalty = -int256(uint256(cal.wear > 100 ? 100 : cal.wear));
                    
                    // Apply weight - 5% weight for wear
                    penalty = basePenalty * 5 / 100;
                }
            } catch {
                // Ignore errors - use default 0 penalty
            }
        }
        
        return penalty;
    }
    
    /**
     * @notice Get token variant from collection
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return variant Token variant (1-4)
     */
    function getTokenVariant(uint256 collectionId, uint256 tokenId) internal view returns (uint8 variant) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Default variant if retrieval fails
        uint8 defaultVariant = 1;
        
        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            return defaultVariant;
        }
        
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        if (collection.collectionAddress == address(0)) {
            return defaultVariant;
        }
        
        try IExternalCollection(collection.collectionAddress).itemVariant(tokenId) returns (uint8 v) {
            // Ensure variant is in valid range
            if (v >= 1 && v <= 4) {
                return v;
            }
        } catch {
            // Ignore errors
        }
        
        return defaultVariant;
    }
    
    /**
     * @notice Get token level from charge system
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return level Token level (1-100)
     */
    function getTokenLevel(uint256 collectionId, uint256 tokenId) internal view returns (uint8 level) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Default level if retrieval fails
        uint8 defaultLevel = 1;
        
        address chargeModule = hs.internalModules.chargeModuleAddress;
        if (chargeModule == address(0)) {
            return defaultLevel;
        }
        
        try IChargeFacet(chargeModule).getSpecimenData(collectionId, tokenId) returns (
            uint256, uint256, uint256, uint8, uint256 chargeLevel
        ) {
            return uint8(chargeLevel > 100 ? 100 : chargeLevel);
        } catch {
            // Ignore errors
        }
        
        return defaultLevel;
    }
    
    /**
     * @notice Get token owner with staking awareness
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return owner Token owner address (staker or NFT owner)
     */
    function getTokenOwner(uint256 collectionId, uint256 tokenId) internal view returns (address owner) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // First check if token is staked - use staking system if available
        if (hs.stakingSystemAddress != address(0)) {
            try IStakingSystem(hs.stakingSystemAddress).isSpecimenStaked(collectionId, tokenId) returns (bool isStaked) {
                if (isStaked) {
                    // Instead, we'll use the fact that tokens in colonies belong to whoever controls them in the colony
                    uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
                    bytes32 colonyId = hs.specimenColonies[combinedId];
                    
                    if (colonyId != bytes32(0)) {
                        // Check if caller is the colony creator as fallback
                        address creator = hs.colonyCreators[colonyId];
                        if (creator != address(0)) {
                            return creator;
                        }
                    }
                    
                    return address(0); // Return zero address if we can't determine staker
                }
            } catch {
                // Ignore errors in staking system calls
            }
        }
        
        // Fall back to direct NFT ownership
        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            return address(0);
        }
        
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        if (collection.collectionAddress == address(0)) {
            return address(0);
        }
        
        try IERC721(collection.collectionAddress).ownerOf(tokenId) returns (address o) {
            return o;
        } catch {
            // Ignore errors
        }
        
        return address(0);
    }
    
    /**
     * @notice Get charge time for a token
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return chargeTime Last charge time or 0
     */
    function getTokenChargeTime(uint256 collectionId, uint256 tokenId) internal view returns (uint256 chargeTime) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        // Return 0 if no charge data
        if (hs.performedCharges[combinedId].lastChargeTime == 0) {
            return 0;
        }
        
        return hs.performedCharges[combinedId].lastChargeTime;
    }
    
    /**
     * @notice Get owners ranked by their colony tokens
     * @param startIdx Starting index for pagination
     * @param count Maximum number of owners to return
     * @return ranking Array of ranked owner items
     */
    function getOwnerRanking(uint256 startIdx, uint256 count) public view returns (
        OwnerRankingItem[] memory ranking
    ) {
        // Early return for edge cases
        if (count == 0) {
            return new OwnerRankingItem[](0);
        }
        
        // First get token ranking to find unique owners
        TokenRankingItem[] memory tokens = getTokenRanking(0, 300);
        
        if (tokens.length == 0) {
            return new OwnerRankingItem[](0);
        }
        
        // Find unique owners
        address[] memory uniqueOwners = new address[](100); // Maximum owners to track
        uint256 ownerCount = 0;
        
        for (uint256 i = 0; i < tokens.length; i++) {
            address owner = tokens[i].owner;
            
            // Skip invalid owners
            if (owner == address(0)) {
                continue;
            }
            
            // Check if already in list
            bool found = false;
            for (uint256 j = 0; j < ownerCount; j++) {
                if (uniqueOwners[j] == owner) {
                    found = true;
                    break;
                }
            }
            
            // Add if not found and we have space
            if (!found && ownerCount < 100) {
                uniqueOwners[ownerCount] = owner;
                ownerCount++;
            }
        }
        
        // If no owners found, return empty array
        if (ownerCount == 0) {
            return new OwnerRankingItem[](0);
        }
        
        // Calculate owner metrics
        OwnerRankingItem[] memory allOwners = new OwnerRankingItem[](ownerCount);
        
        for (uint256 i = 0; i < ownerCount; i++) {
            address owner = uniqueOwners[i];
            
            // Get owner statistics
            OwnerTokenStats memory stats = calculateOwnerTokenStats(owner, tokens);
            
            // Get owner metrics
            uint256 rankingValue = calculateOwnerRankingValue(owner, stats);
            
            // Store data
            allOwners[i] = OwnerRankingItem({
                rank: 0, // Will be assigned after sorting
                ownerAddress: owner,
                tokenCount: stats.tokenCount,
                rankingValue: rankingValue
            });
        }
        
        // Sort owners by ranking value (descending) - using safe sort
        safeSortOwners(allOwners, ownerCount);
        
        // Assign ranks after sorting
        for (uint256 i = 0; i < ownerCount; i++) {
            allOwners[i].rank = i + 1;
        }
        
        // Handle pagination
        uint256 resultCount = count;
        if (startIdx >= ownerCount) {
            return new OwnerRankingItem[](0);
        }
        
        if (startIdx + resultCount > ownerCount) {
            resultCount = ownerCount - startIdx;
        }
        
        // Create result array with pagination
        ranking = new OwnerRankingItem[](resultCount);
        for (uint256 i = 0; i < resultCount; i++) {
            ranking[i] = allOwners[startIdx + i];
        }
        
        return ranking;
    }
    
    /**
     * @notice Get top ranked owners
     * @param count Maximum number of owners to return
     * @return ranking Array of top ranked owner items
     */
    function getTopRankedOwners(uint256 count) external view returns (
        OwnerRankingItem[] memory ranking
    ) {
        return getOwnerRanking(0, count);
    }
    
    /**
     * @notice Calculate token statistics for an owner address
     * @param owner Owner address
     * @param tokens Token data array
     * @return stats Structure with aggregated token statistics
     */
    function calculateOwnerTokenStats(
        address owner,
        TokenRankingItem[] memory tokens
    ) internal view returns (OwnerTokenStats memory stats) {

        // Initialize stats
        stats.variantDistribution = 0;
        stats.highestLevel = 0;
        stats.earliestChargeTime = type(uint256).max;
        
        // Process each token owned by this address
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i].owner == owner) {
                stats.tokenCount++;
                
                // Track levels and variants
                stats.totalLevels += tokens[i].level;
                stats.totalVariants += tokens[i].variant;
                
                // Track highest level
                if (tokens[i].level > stats.highestLevel) {
                    stats.highestLevel = tokens[i].level;
                }
                
                // Track variant distribution
                if (tokens[i].variant >= 1 && tokens[i].variant <= 4) {
                    stats.variantDistribution |= (1 << (tokens[i].variant - 1));
                }
                
                // Check charge time
                uint256 chargeTime = getTokenChargeTime(tokens[i].collectionId, tokens[i].tokenId);
                if (chargeTime > 0 && chargeTime < stats.earliestChargeTime) {
                    stats.earliestChargeTime = chargeTime;
                }
            }
        }
        
        // Reset earliest charge time if no charges found
        if (stats.earliestChargeTime == type(uint256).max) {
            stats.earliestChargeTime = 0;
        }
        
        return stats;
    }
    
    /**
     * @notice Calculate ranking value for an owner
     * @param owner Owner address
     * @param stats Owner token statistics
     * @return rankingValue Calculated ranking value
     */
    function calculateOwnerRankingValue(
        address owner,
        OwnerTokenStats memory stats
    ) internal view returns (uint256 rankingValue) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Calculate token count score (0-100 scale)
        uint256 tokenCountBaseScore;
        if (stats.tokenCount >= 15) {
            tokenCountBaseScore = 100;
        } else if (stats.tokenCount >= 10) {
            tokenCountBaseScore = 75;
        } else if (stats.tokenCount >= 5) {
            tokenCountBaseScore = 50;
        } else if (stats.tokenCount > 0) {
            tokenCountBaseScore = stats.tokenCount * 10; // 10 points per token for 1-4 tokens
        }
        
        // Apply weight to token count score
        uint256 tokenCountScore = tokenCountBaseScore * TOKEN_COUNT_WEIGHT / 100;
        
        // Calculate token quality score
        uint256 qualityBaseScore;
        if (stats.tokenCount > 0) {
            // Average level and variant quality
            uint256 avgLevel = stats.totalLevels / stats.tokenCount;
            uint256 avgVariant = stats.totalVariants * 25 / stats.tokenCount;
            
            // Weight quality components
            qualityBaseScore = (avgLevel * 40 / 100) + (avgVariant * 60 / 100);
            
            // Cap at 100
            if (qualityBaseScore > 100) {
                qualityBaseScore = 100;
            }
        }
        
        // Apply weight to quality score
        uint256 qualityScore = qualityBaseScore * TOKEN_QUALITY_WEIGHT / 100;
        
        // Calculate loyalty score (0-100 scale) based on colony creation
        uint256 loyaltyBaseScore = 0;
        
        // Check if owner is a colony creator
        for (uint256 i = 0; i < hs.allColonyIds.length; i++) {
            bytes32 colonyId = hs.allColonyIds[i];
            if (hs.colonyCreators[colonyId] == owner) {
                loyaltyBaseScore = 100; // Max score for colony creators
                break;
            }
        }
        
        // Apply weight to loyalty score
        uint256 loyaltyScore = loyaltyBaseScore * LOYALTY_WEIGHT / 100;
        
        // Calculate diversity score based on variant distribution
        uint256 diversityBaseScore = calculateOwnerDiversityScore(stats.variantDistribution);
        
        // Apply weight to diversity score
        uint256 diversityScore = diversityBaseScore * DIVERSITY_WEIGHT / 100;
        
        // Calculate final ranking value
        rankingValue = tokenCountScore + qualityScore + loyaltyScore + diversityScore;
        
        return rankingValue;
    }
    
    /**
     * @notice Get detailed statistics for a specific owner
     * @param owner Owner address
     * @return stats Detailed owner statistics
     */
    function getOwnerDetailedStats(address owner) public view returns (OwnerDetailedStats memory stats) {
        // First get all tokens
        TokenRankingItem[] memory tokens = getTokenRanking(0, 300);
        
        // Calculate owner token stats
        OwnerTokenStats memory tokenStats = calculateOwnerTokenStats(owner, tokens);
        
        // Calculate unique variants count
        uint256 uniqueVariants = 0;
        for (uint256 v = 0; v < 4; v++) {
            if ((tokenStats.variantDistribution & (1 << v)) != 0) {
                uniqueVariants++;
            }
        }
        
        // Calculate days since earliest charge
        uint256 longestChargeDays = 0;
        if (tokenStats.earliestChargeTime > 0 && tokenStats.earliestChargeTime < block.timestamp) {
            longestChargeDays = (block.timestamp - tokenStats.earliestChargeTime) / 1 days;
        }
        
        // Populate statistics structure
        stats = OwnerDetailedStats({
            avgTokenLevel: tokenStats.tokenCount > 0 ? tokenStats.totalLevels / tokenStats.tokenCount : 0,
            avgTokenVariant: tokenStats.tokenCount > 0 ? (tokenStats.totalVariants * 100) / tokenStats.tokenCount : 0,
            uniqueVariants: uniqueVariants,
            highestLevelToken: tokenStats.highestLevel,
            longestChargedDays: longestChargeDays
        });
        
        return stats;
    }
    
    /**
     * @notice Get detailed ranking metrics for a specific owner
     * @param owner Owner address
     * @return metrics Detailed owner metrics
     * @return rankingValue Final ranking value
     */
    function getOwnerRankingMetrics(address owner) public view returns (
        OwnerDetailedMetrics memory metrics,
        uint256 rankingValue
    ) {
        // Get all tokens
        TokenRankingItem[] memory tokens = getTokenRanking(0, 300);
        
        // Calculate owner token stats
        OwnerTokenStats memory stats = calculateOwnerTokenStats(owner, tokens);
        
        // Calculate token count score (0-100 scale)
        uint256 tokenCountBaseScore;
        if (stats.tokenCount >= 15) {
            tokenCountBaseScore = 100;
        } else if (stats.tokenCount >= 10) {
            tokenCountBaseScore = 75;
        } else if (stats.tokenCount >= 5) {
            tokenCountBaseScore = 50;
        } else if (stats.tokenCount > 0) {
            tokenCountBaseScore = stats.tokenCount * 10; // 10 points per token for 1-4 tokens
        }
        
        metrics.tokenCountScore = tokenCountBaseScore * TOKEN_COUNT_WEIGHT / 100;
        
        // Calculate token quality score
        uint256 qualityBaseScore;
        if (stats.tokenCount > 0) {
            // Average level and variant quality
            uint256 avgLevel = stats.totalLevels / stats.tokenCount;
            uint256 avgVariant = stats.totalVariants * 25 / stats.tokenCount;
            
            // Weight quality components
            qualityBaseScore = (avgLevel * 40 / 100) + (avgVariant * 60 / 100);
            
            // Cap at 100
            if (qualityBaseScore > 100) {
                qualityBaseScore = 100;
            }
        }
        
        metrics.qualityScore = qualityBaseScore * TOKEN_QUALITY_WEIGHT / 100;
        
        // Calculate loyalty score (0-100 scale) based on colony creation
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 loyaltyBaseScore = 0;
        
        // Check if owner is a colony creator
        for (uint256 i = 0; i < hs.allColonyIds.length; i++) {
            bytes32 colonyId = hs.allColonyIds[i];
            if (hs.colonyCreators[colonyId] == owner) {
                loyaltyBaseScore = 100; // Max score for colony creators
                break;
            }
        }
        
        metrics.loyaltyScore = loyaltyBaseScore * LOYALTY_WEIGHT / 100;
        
        // Calculate diversity score based on variant distribution
        uint256 diversityBaseScore = calculateOwnerDiversityScore(stats.variantDistribution);
        metrics.diversityScore = diversityBaseScore * DIVERSITY_WEIGHT / 100;
        
        // Calculate final ranking value
        rankingValue = metrics.tokenCountScore + 
                       metrics.qualityScore + 
                       metrics.loyaltyScore + 
                       metrics.diversityScore;
        
        return (metrics, rankingValue);
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
     * @notice Safe sorting for owners using bubble sort (prevents overflow)
     * @param arr Array to sort
     * @param length Length of array to sort
     */
    function safeSortOwners(OwnerRankingItem[] memory arr, uint256 length) internal pure {
        if (length <= 1) return;
        
        for (uint256 i = 0; i < length - 1; i++) {
            for (uint256 j = 0; j < length - 1 - i; j++) {
                // Compare ranking values (descending order)
                bool shouldSwap = false;
                
                if (arr[j].rankingValue < arr[j + 1].rankingValue) {
                    shouldSwap = true;
                } else if (arr[j].rankingValue == arr[j + 1].rankingValue) {
                    // Secondary sort by address (ascending) for stable sorting
                    if (uint160(arr[j].ownerAddress) > uint160(arr[j + 1].ownerAddress)) {
                        shouldSwap = true;
                    }
                }
                
                if (shouldSwap) {
                    OwnerRankingItem memory temp = arr[j];
                    arr[j] = arr[j + 1];
                    arr[j + 1] = temp;
                }
            }
        }
    }
    
    /**
     * @notice Safe sorting for tokens using bubble sort (prevents overflow)
     * @param arr Array to sort
     * @param length Length of array to sort
     */
    function safeSortTokens(TokenRankingItem[] memory arr, uint256 length) internal pure {
        if (length <= 1) return;
        
        for (uint256 i = 0; i < length - 1; i++) {
            for (uint256 j = 0; j < length - 1 - i; j++) {
                // Compare ranking values (descending order)
                bool shouldSwap = false;
                
                if (arr[j].rankingValue < arr[j + 1].rankingValue) {
                    shouldSwap = true;
                } else if (arr[j].rankingValue == arr[j + 1].rankingValue) {
                    // Secondary sort by collection ID then token ID (ascending) for stable sorting
                    if (arr[j].collectionId > arr[j + 1].collectionId) {
                        shouldSwap = true;
                    } else if (arr[j].collectionId == arr[j + 1].collectionId) {
                        if (arr[j].tokenId > arr[j + 1].tokenId) {
                            shouldSwap = true;
                        }
                    }
                }
                
                if (shouldSwap) {
                    TokenRankingItem memory temp = arr[j];
                    arr[j] = arr[j + 1];
                    arr[j + 1] = temp;
                }
            }
        }
    }
    
    /**
     * @notice Get active colony IDs
     * @param start Starting index for pagination
     * @param limit Maximum number of colonies to return
     * @return colonyIds Array of colony IDs
     * @return total Total number of colonies
     */
    function getActiveColonyIds(uint256 start, uint256 limit) internal view returns (
        bytes32[] memory colonyIds,
        uint256 total
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Get colony IDs from registry if available
        if (hs.allColonyIds.length > 0) {
            uint256 totalColonies = hs.allColonyIds.length;
            
            // If start index is beyond total, return empty array
            if (start >= totalColonies) {
                return (new bytes32[](0), totalColonies);
            }
            
            // Calculate how many colonies to return
            uint256 maxCount = totalColonies - start >= limit ? limit : totalColonies - start;
            
            // Prepare result buffer
            colonyIds = new bytes32[](maxCount);
            
            // Fill buffer
            for (uint256 i = 0; i < maxCount; i++) {
                colonyIds[i] = hs.allColonyIds[start + i];
            }
            
            return (colonyIds, totalColonies);
        } else {
            // Fallback: try to find colonies from last known colony ID
            if (hs.lastColonyId != bytes32(0)) {
                colonyIds = new bytes32[](1);
                colonyIds[0] = hs.lastColonyId;
                return (colonyIds, 1);
            }
            
            // If all else fails, return empty array
            return (new bytes32[](0), 0);
        }
    }
}