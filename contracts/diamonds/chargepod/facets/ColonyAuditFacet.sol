// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {PodsUtils} from "../../libraries/PodsUtils.sol";
import {ColonyHelper} from "../libraries/ColonyHelper.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {IStakingSystem} from "../interfaces/IStakingInterfaces.sol";

/**
 * @title ColonyAuditFacet
 * @author rutilicus.eth (ArchXS)
 * @notice Audit and repair functionality for colony data
 */
contract ColonyAuditFacet is AccessControlBase {
    // Events
    event OperationResult(string operation, bool success);
    event OperationError(string operation, string errorMessage);
    event SpecimenLeftColony(uint256 indexed collectionId, uint256 indexed tokenId, bytes32 indexed colonyId);

    
    event ColonyCleaned(bytes32 indexed colonyId, uint256 originalCount, uint256 uniqueCount, uint256 duplicatesRemoved);
    event ColonyIndicesRebuilt(bytes32 indexed colonyId, uint256 indexedCount);

    /**
     * @notice Clean colony by removing duplicates and rebuilding indices
     * @param colonyId Colony ID to clean
     * @return duplicatesRemoved Number of duplicate entries removed
     */
    function cleanColony(bytes32 colonyId) external onlyAuthorized returns (uint256 duplicatesRemoved) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256[] storage members = hs.colonies[colonyId];
        
        uint256 originalCount = members.length;
        if (originalCount == 0) return 0;
        
        // Create array to track unique members
        uint256[] memory uniqueMembers = new uint256[](originalCount);
        uint256 uniqueCount = 0;
        
        // Remove duplicates using a more efficient approach
        for (uint256 i = 0; i < originalCount; i++) {
            uint256 combinedId = members[i];
            bool isDuplicate = false;
            
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (uniqueMembers[j] == combinedId) {
                    isDuplicate = true;
                    break;
                }
            }
            
            if (!isDuplicate) {
                uniqueMembers[uniqueCount] = combinedId;
                uniqueCount++;
            }
        }
        
        duplicatesRemoved = originalCount - uniqueCount;
        
        // Only rebuild if duplicates were found
        if (duplicatesRemoved > 0) {
            // Clear existing indices for all members first
            for (uint256 i = 0; i < originalCount; i++) {
                delete hs.colonyMemberIndices[colonyId][members[i]];
            }
            
            // Clear and rebuild colony array
            delete hs.colonies[colonyId];
            
            // Add unique members and rebuild indices
            for (uint256 i = 0; i < uniqueCount; i++) {
                uint256 combinedId = uniqueMembers[i];
                hs.colonies[colonyId].push(combinedId);
                // Store 1-based index
                hs.colonyMemberIndices[colonyId][combinedId] = i + 1;
                // Ensure specimen association is correct
                hs.specimenColonies[combinedId] = colonyId;
            }
            
            emit ColonyCleaned(colonyId, originalCount, uniqueCount, duplicatesRemoved);
        }
        
        return duplicatesRemoved;
    }
    
    /**
     * @notice Clean all colonies in the system
     * @return totalDuplicatesRemoved Total duplicates removed across all colonies
     * @return coloniesCleaned Number of colonies that had duplicates
     */
    function cleanAllColonies() external onlyAuthorized returns (
        uint256 totalDuplicatesRemoved,
        uint256 coloniesCleaned
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        totalDuplicatesRemoved = 0;
        coloniesCleaned = 0;
        
        // Iterate through all registered colonies
        for (uint256 i = 0; i < hs.allColonyIds.length; i++) {
            bytes32 colonyId = hs.allColonyIds[i];
            
            // Skip if colony doesn't exist
            if (bytes(hs.colonyNamesById[colonyId]).length == 0) continue;
            
            uint256 duplicates = this.cleanColony(colonyId);
            if (duplicates > 0) {
                totalDuplicatesRemoved += duplicates;
                coloniesCleaned++;
            }
        }
        
        return (totalDuplicatesRemoved, coloniesCleaned);
    }
    
    /**
     * @notice Rebuild indices for a colony without removing any members
     * @dev Use this after manual fixes or migrations
     * @param colonyId Colony ID to rebuild indices for
     * @return indexedCount Number of members indexed
     */
    function rebuildColonyIndices(bytes32 colonyId) external onlyAuthorized returns (uint256 indexedCount) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256[] storage members = hs.colonies[colonyId];
        
        indexedCount = 0;
        
        // First, clear all existing indices
        for (uint256 i = 0; i < members.length; i++) {
            delete hs.colonyMemberIndices[colonyId][members[i]];
        }
        
        // Rebuild indices (1-based)
        for (uint256 i = 0; i < members.length; i++) {
            uint256 combinedId = members[i];
            hs.colonyMemberIndices[colonyId][combinedId] = i + 1;
            // Also ensure specimen association is set
            hs.specimenColonies[combinedId] = colonyId;
            indexedCount++;
        }
        
        emit ColonyIndicesRebuilt(colonyId, indexedCount);
        return indexedCount;
    }
    
    /**
     * @notice Get diagnostic info about colony duplicates
     * @param colonyId Colony ID to diagnose
     * @return totalMembers Total members in array
     * @return uniqueMembers Number of unique members
     * @return duplicateCount Number of duplicates
     * @return duplicateTokens Array of duplicate combinedIds (first 10)
     */
    function diagnoseDuplicates(bytes32 colonyId) external view returns (
        uint256 totalMembers,
        uint256 uniqueMembers,
        uint256 duplicateCount,
        uint256[] memory duplicateTokens
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256[] storage members = hs.colonies[colonyId];
        
        totalMembers = members.length;
        if (totalMembers == 0) {
            return (0, 0, 0, new uint256[](0));
        }
        
        // Track seen combinedIds and duplicates
        uint256[] memory seen = new uint256[](totalMembers);
        uint256[] memory duplicates = new uint256[](10); // Max 10 duplicates returned
        uint256 seenCount = 0;
        uint256 dupCount = 0;
        
        for (uint256 i = 0; i < totalMembers; i++) {
            uint256 combinedId = members[i];
            bool found = false;
            
            for (uint256 j = 0; j < seenCount; j++) {
                if (seen[j] == combinedId) {
                    found = true;
                    if (dupCount < 10) {
                        duplicates[dupCount] = combinedId;
                    }
                    dupCount++;
                    break;
                }
            }
            
            if (!found) {
                seen[seenCount] = combinedId;
                seenCount++;
            }
        }
        
        // Trim duplicates array to actual size
        uint256 returnSize = dupCount > 10 ? 10 : dupCount;
        duplicateTokens = new uint256[](returnSize);
        for (uint256 i = 0; i < returnSize; i++) {
            duplicateTokens[i] = duplicates[i];
        }
        
        return (totalMembers, seenCount, dupCount, duplicateTokens);
    }

    function resetColony(bytes32 colonyId) external onlyAuthorized {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        delete hs.colonies[colonyId];
    }

    /**
     * @notice Napraw twórcę kolonii (tylko admin)
     */
    function fixColonyCreator(bytes32 colonyId, address creator) external onlyAuthorized {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        hs.colonyCreators[colonyId] = creator;
    }

    /**
     * @notice Adds a single colony to the registry
     * @param colonyId ID of the colony to add
     * @return success Whether the operation was successful
     */
    function addColonyToRegistry(bytes32 colonyId) external onlyAuthorized whenNotPaused returns (bool success) {
        return ColonyHelper.safeAddColonyToRegistry(colonyId);
    }

    /**
     * @notice Removes invalid colonies from the registry
     * @return removedCount Number of entries removed
     */
    function cleanupColonyRegistry() external onlyAuthorized whenNotPaused returns (uint256 removedCount) {
        return ColonyHelper.purgeInvalidColoniesFromRegistry();
    }
    
    /**
     * @notice Force remove token from any colony associations
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return success Whether operation was successful
     * @dev Administrative function to fix data inconsistencies
     */
    function forceRemoveTokenFromColony(
        uint256 collectionId, 
        uint256 tokenId
    ) external onlyAuthorized whenNotPaused returns (bool success) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        bytes32 colonyId = hs.specimenColonies[combinedId];
        
        if (colonyId != bytes32(0)) {
            // Clear token's association with colony
            delete hs.specimenColonies[combinedId];
            
            // Clear token's index in colony
            delete hs.colonyMemberIndices[colonyId][combinedId];
            
            // Try to remove token from colonies[colonyId] array if it exists there
            uint256[] storage members = hs.colonies[colonyId];
            for (uint256 i = 0; i < members.length; i++) {
                if (members[i] == combinedId) {
                    members[i] = members[members.length - 1];
                    members.pop();
                    break;
                }
            }
            
            // Notify staking system about the change
            if (hs.stakingSystemAddress != address(0)) {
                try IStakingSystem(hs.stakingSystemAddress).notifyColonyChange(
                    colonyId, collectionId, tokenId, false // isJoining = false
                ) {
                    emit OperationResult("StakingNotification", true);
                } catch {
                    emit OperationResult("StakingNotification", false);
                }
            }
            
            // Recalibrate token's power core
            ColonyHelper.safeRecalibrateCore(collectionId, tokenId);
            
            emit SpecimenLeftColony(collectionId, tokenId, colonyId);
            return true;
        }

        return false;
    }

    /**
     * @notice Force remove token from a SPECIFIC colony (for cross-colony duplicate repair)
     * @param targetColonyId Colony ID to remove token from
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return success Whether operation was successful
     * @dev This function removes token from the specified colony's members array only,
     *      without affecting specimenColonies mapping (which should point to the "correct" colony)
     */
    function forceRemoveTokenFromSpecificColony(
        bytes32 targetColonyId,
        uint256 collectionId,
        uint256 tokenId
    ) external onlyAuthorized whenNotPaused returns (bool success) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        // Verify colony exists
        if (bytes(hs.colonyNamesById[targetColonyId]).length == 0) {
            revert ColonyHelper.ColonyDoesNotExist(targetColonyId);
        }

        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        uint256[] storage members = hs.colonies[targetColonyId];

        // Find and remove token from the colony's members array
        bool found = false;
        for (uint256 i = 0; i < members.length; i++) {
            if (members[i] == combinedId) {
                // Swap with last and pop
                members[i] = members[members.length - 1];
                members.pop();
                found = true;

                // Clear index for this colony
                delete hs.colonyMemberIndices[targetColonyId][combinedId];

                // If specimenColonies points to this colony, clear it
                if (hs.specimenColonies[combinedId] == targetColonyId) {
                    delete hs.specimenColonies[combinedId];
                }

                // Notify staking system
                if (hs.stakingSystemAddress != address(0)) {
                    try IStakingSystem(hs.stakingSystemAddress).notifyColonyChange(
                        targetColonyId, collectionId, tokenId, false
                    ) {
                        emit OperationResult("StakingNotification", true);
                    } catch {
                        emit OperationResult("StakingNotification", false);
                    }
                }

                emit SpecimenLeftColony(collectionId, tokenId, targetColonyId);
                break;
            }
        }

        return found;
    }

    /**
     * @notice Fix token colony associations across the system
     * @param collectionId Collection ID to repair
     * @param tokenId Token ID to repair
     * @return success Whether repair was successful
     */
    function repairTokenColonyAssociation(
        uint256 collectionId, 
        uint256 tokenId
    ) external onlyAuthorized whenNotPaused returns (bool success) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        bytes32 colonyId = hs.specimenColonies[combinedId];
        
        // If token has a colony association
        if (colonyId != bytes32(0)) {
            // Check if token is actually in the colony members array
            uint256[] storage members = hs.colonies[colonyId];
            bool foundInMembers = false;
            
            for (uint256 i = 0; i < members.length; i++) {
                if (members[i] == combinedId) {
                    foundInMembers = true;
                    break;
                }
            }
            
            // If inconsistency found - token has colony ID but is not in members array
            if (!foundInMembers) {
                // Clear token's colony association
                delete hs.specimenColonies[combinedId];
                
                // Clear token's index in colony
                delete hs.colonyMemberIndices[colonyId][combinedId];
                
                // Notify staking system about the change
                if (hs.stakingSystemAddress != address(0)) {
                    try IStakingSystem(hs.stakingSystemAddress).notifyColonyChange(
                        colonyId, collectionId, tokenId, false // isJoining = false
                    ) {
                        emit OperationResult("StakingNotification", true);
                    } catch {
                        emit OperationResult("StakingNotification", false);
                    }
                }
                
                // Recalibrate token's power core
                ColonyHelper.safeRecalibrateCore(collectionId, tokenId);
                
                emit SpecimenLeftColony(collectionId, tokenId, colonyId);
                return true;
            }
        }
        
        return false;
    }

    /**
     * @notice Helper struct to store audit state between function calls
     * @dev Used to avoid stack too deep errors
     */
    struct AuditState {
        uint256[] inconsistentTokens;
        uint256 count;
    }

    /**
     * @notice Check for tokens with colony associations that aren't in colony members list
     * @param colonyId ID of the colony to audit
     * @param startIdx Starting index for pagination
     * @param limit Maximum number of inconsistencies to return
     * @return collectionIds Collection IDs of inconsistent tokens
     * @return tokenIds Token IDs of inconsistent tokens
     * @return total Total number of inconsistencies found
     */
    function auditColonyConsistency(
        bytes32 colonyId,
        uint256 startIdx,
        uint256 limit
    ) external view returns (
        uint256[] memory collectionIds,
        uint256[] memory tokenIds,
        uint256 total
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            revert ColonyHelper.ColonyDoesNotExist(colonyId);
        }
        
        // Find all tokens with inconsistencies
        AuditState memory state = _findAllInconsistencies(colonyId);
        
        // Pagination logic
        uint256 endIdx = (startIdx + limit > state.count) ? state.count : startIdx + limit;
        uint256 resultCount = (startIdx < state.count) ? endIdx - startIdx : 0;
        
        // Prepare result arrays
        collectionIds = new uint256[](resultCount);
        tokenIds = new uint256[](resultCount);
        
        // Extract results with pagination
        for (uint256 i = 0; i < resultCount; i++) {
            uint256 combinedId = state.inconsistentTokens[startIdx + i];
            (collectionIds[i], tokenIds[i]) = PodsUtils.extractIds(combinedId);
        }
        
        return (collectionIds, tokenIds, state.count);
    }

    /**
     * @dev Internal helper to find all inconsistencies for a colony
     * @param colonyId Colony ID to audit
     * @return state Audit state containing all inconsistent tokens
     */
    function _findAllInconsistencies(bytes32 colonyId) private view returns (AuditState memory state) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256[] storage colonyMembers = hs.colonies[colonyId];
        
        // Allocate buffer for inconsistent tokens (with reasonable limit)
        state.inconsistentTokens = new uint256[](100);
        state.count = 0;
        
        // Check recent collections first (optimization to avoid checking all possible tokens)
        uint256 collectionsToCheck = 5;
        collectionsToCheck = collectionsToCheck > hs.collectionCounter ? hs.collectionCounter : collectionsToCheck;
        
        for (uint256 c = 0; c < collectionsToCheck; c++) {
            // Start from the most recent collection
            uint256 collectionId = hs.collectionCounter - c;
            if (collectionId == 0 || !hs.specimenCollections[collectionId].enabled) continue;
            
            // Check tokens in this collection
            _checkCollectionForInconsistencies(colonyId, collectionId, colonyMembers, state);
        }
        
        return state;
    }

    /**
     * @dev Check specific collection for inconsistencies
     * @param colonyId Colony ID being audited
     * @param collectionId Collection ID to check
     * @param colonyMembers Array of current colony members
     * @param state Audit state to update
     */
    function _checkCollectionForInconsistencies(
        bytes32 colonyId,
        uint256 collectionId,
        uint256[] storage colonyMembers,
        AuditState memory state
    ) private view {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Check a reasonable number of tokens
        uint256 tokensToCheck = 1000;
        
        for (uint256 tokenId = 1; tokenId <= tokensToCheck; tokenId++) {
            uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
            bytes32 tokenColonyId = hs.specimenColonies[combinedId];
            
            // If token claims to be in this colony
            if (tokenColonyId == colonyId) {
                // Check if it's actually in the members array
                bool foundInMembers = false;
                
                for (uint256 i = 0; i < colonyMembers.length; i++) {
                    if (colonyMembers[i] == combinedId) {
                        foundInMembers = true;
                        break;
                    }
                }
                
                // If inconsistency found and we still have space in the results array
                if (!foundInMembers && state.count < state.inconsistentTokens.length) {
                    state.inconsistentTokens[state.count] = combinedId;
                    state.count++;
                }
            }
        }
    }
}