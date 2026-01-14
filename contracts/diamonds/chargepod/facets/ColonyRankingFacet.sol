// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {PodsUtils} from "../../libraries/PodsUtils.sol";
import {ColonyHelper} from "../libraries/ColonyHelper.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {ColonyEvaluator} from "../libraries/ColonyEvaluator.sol";

/**
 * @title ColonyRankingFacet
 * @notice Provides functionality for ranking colonies based on staking bonuses and member characteristics
 * @author Based on ColonyViewFacet by rutilicus.eth (ArchXS)
 */
contract ColonyRankingFacet is AccessControlBase {

    /**
     * @notice Colony ranking item structure
     * @dev Used to return sorted colony ranking data
     */
    struct ColonyRankingItem {
        uint256 rank;            // Position in ranking
        bytes32 colonyId;        // Colony ID
        string name;             // Colony name
        address creator;         // Colony creator
        uint256 memberCount;     // Number of members
        uint256 rankingValue;    // Value used for ranking (scaled x100 for more precision)
        uint256 presumedBonus;
    }
    
    /**
     * @notice Get colonies ranked by their staking bonus and member quality
     * @param startIdx Starting index for pagination
     * @param count Maximum number of colonies to return
     * @return ranking Array of ranked colony items
     */
    function getColonyRanking(uint256 startIdx, uint256 count) public view returns (
        ColonyRankingItem[] memory ranking
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Get active colony IDs
        (bytes32[] memory colonyIds, ) = ColonyHelper.getActiveColonyIds(0, type(uint256).max);
        
        if (colonyIds.length == 0) {
            return new ColonyRankingItem[](0);
        }
        
        // Create temporary array to hold all colony data for sorting
        ColonyRankingItem[] memory allColonies = new ColonyRankingItem[](colonyIds.length);
        
        // Calculate ranking value for each colony
        for (uint256 i = 0; i < colonyIds.length; i++) {
            bytes32 colonyId = colonyIds[i];
            
            // Skip invalid colonies
            if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
                continue;
            }
            
            // Get colony data
            (, string memory colonyName) = ColonyHelper.findColonyNameHash(colonyId);
            address creator = hs.colonyCreators[colonyId];
            uint256 memberCount = hs.colonies[colonyId].length;
            
            // Calculate ranking value
            (uint256 rankingValue, uint256 presumedBonus) = calculateColonyRankingValue(colonyId);
            
            // Store data for sorting
            allColonies[i] = ColonyRankingItem({
                rank: 0, // Will be assigned after sorting
                colonyId: colonyId,
                name: colonyName,
                creator: creator,
                memberCount: memberCount,
                rankingValue: rankingValue,
                presumedBonus: presumedBonus
            });
        }
        
        // Sort colonies by ranking value (descending) using optimized sorting for gas efficiency
        quickSort(allColonies, 0, int(allColonies.length - 1));
        
        // Assign ranks after sorting
        for (uint256 i = 0; i < allColonies.length; i++) {
            allColonies[i].rank = i + 1;
        }
        
        // Handle pagination
        uint256 resultCount = count;
        if (startIdx >= allColonies.length) {
            return new ColonyRankingItem[](0);
        }
        
        if (startIdx + resultCount > allColonies.length) {
            resultCount = allColonies.length - startIdx;
        }
        
        // Create result array with pagination
        ranking = new ColonyRankingItem[](resultCount);
        for (uint256 i = 0; i < resultCount; i++) {
            ranking[i] = allColonies[startIdx + i];
        }
        
        return ranking;
    }
    
    /**
     * @notice Calculate ranking value for a colony with balanced scoring
     * @dev Combines explicit bonus and dynamic calculation based on member characteristics
     * @param colonyId Colony ID
     * @return rankingValue Calculated ranking value (scaled x100)
     */
    function calculateColonyRankingValue(bytes32 colonyId) public view returns (uint256 rankingValue, uint256 dynamicBonus) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Verify colony exists
        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            return (0, 0);
        }
        
        // Start with explicit staking bonus (if set)
        uint256 explicitBonus = hs.colonyStakingBonuses[colonyId];
        
        // Calculate dynamic bonus based on member characteristics
        dynamicBonus = ColonyEvaluator.calculateColonyDynamicBonus(colonyId);
        
        // More balanced weight distribution between explicit and dynamic bonuses
        // 45/55 split gives slight preference to dynamic bonus without overwhelming
        rankingValue = (explicitBonus * 45) + (dynamicBonus * 55);
        
        // Size factor - balanced contribution based on colony size
        uint256 memberCount = hs.colonies[colonyId].length;
        if (memberCount > 0) {
            // Progressive size bonus that plateaus
            uint256 sizeFactor;
            if (memberCount >= 15) {
                sizeFactor = 10; // Maximum size bonus at 15+ members
            } else if (memberCount >= 10) {
                sizeFactor = 8;  // 80% bonus at 10-14 members
            } else if (memberCount >= 5) {
                sizeFactor = 5;  // 50% bonus at 5-9 members
            } else {
                sizeFactor = memberCount; // Linear bonus for 1-4 members
            }
            
            rankingValue += sizeFactor * 15; // Add up to 150 points for size
        }
        
        return (rankingValue, dynamicBonus);
    }
    
    /**
     * @notice Get top ranked colonies
     * @param count Maximum number of colonies to return
     * @return ranking Array of top ranked colony items
     */
    function getTopRankedColonies(uint256 count) external view returns (
        ColonyRankingItem[] memory ranking
    ) {
        // Direct call without 'this.' to avoid external call overhead
        return getColonyRanking(0, count);
    }
    
    /**
     * @notice Stable quicksort implementation with secondary sorting key
     * @dev Uses colony ID as a secondary key for stable sorting when ranking values are equal
     * @param arr Array to sort
     * @param left Left index of partition
     * @param right Right index of partition
     */
    function quickSort(ColonyRankingItem[] memory arr, int left, int right) internal pure {
        int i = left;
        int j = right;
        if (i >= j) return;
        
        // Use middle element as pivot
        uint256 pivot = arr[uint256(left + (right - left) / 2)].rankingValue;
        bytes32 pivotId = arr[uint256(left + (right - left) / 2)].colonyId;
        
        // Partition
        while (i <= j) {
            // Primary key: rankingValue (descending)
            // Secondary key: colonyId (ascending) for stable sorting when rankingValues are equal
            while (arr[uint256(i)].rankingValue > pivot || 
                (arr[uint256(i)].rankingValue == pivot && arr[uint256(i)].colonyId < pivotId)) i++;
                
            while (arr[uint256(j)].rankingValue < pivot || 
                (arr[uint256(j)].rankingValue == pivot && arr[uint256(j)].colonyId > pivotId)) j--;
            
            if (i <= j) {
                // Swap
                ColonyRankingItem memory temp = arr[uint256(i)];
                arr[uint256(i)] = arr[uint256(j)];
                arr[uint256(j)] = temp;
                
                i++;
                j--;
            }
        }
        
        // Recursive calls - use same algorithm for all partitions to ensure consistency
        if (left < j) quickSort(arr, left, j);
        if (i < right) quickSort(arr, i, right);
    }
        
    /**
     * @notice Insertion sort for small partitions
     * @dev More efficient than quicksort for small arrays
     * @param arr Array to sort
     * @param start Start index
     * @param end End index
     */
    function insertionSort(ColonyRankingItem[] memory arr, uint256 start, uint256 end) internal pure {
        for (uint256 i = start + 1; i <= end; i++) {
            ColonyRankingItem memory key = arr[i];
            uint256 j = i;
            
            while (j > start && arr[j - 1].rankingValue < key.rankingValue) {
                arr[j] = arr[j - 1];
                j--;
            }
            
            arr[j] = key;
        }
    }
}