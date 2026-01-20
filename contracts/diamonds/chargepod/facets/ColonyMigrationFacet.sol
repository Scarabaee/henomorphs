// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {AccessHelper} from "../../staking/libraries/AccessHelper.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {PodsUtils} from "../../../libraries/PodsUtils.sol";
import {ColonyCriteria} from "../../../libraries/HenomorphsModel.sol";

/**
 * @title ColonyMigrationFacet
 * @notice EMERGENCY MIGRATION FACET - Only for data restoration after facet upgrades
 * @dev NO FEES, NO OWNERSHIP CHECKS, NO SECURITY - ADMIN ONLY
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract ColonyMigrationFacet is AccessControlBase {
    
    // Events for tracking restoration
    event ColonyRestored(bytes32 indexed colonyId, string name, address creator, uint256 memberCount, uint256 pendingCount);
    event BatchRestored(uint256 coloniesCount, uint256 membersCount, uint256 pendingCount);
    event GlobalSettingsRestored(uint256 maxCreatorBonus, bool allowEmptyJoin);
    event UserColoniesRestored(address indexed user, uint256 coloniesCount);
    event StorageCleared(string component);
    event MigrationCompleted(uint256 totalColonies, uint256 totalMembers, uint256 totalPending);
    
    /**
     * @notice Complete colony data structure for restoration
     */
    struct ColonyRestoreData {
        bytes32 id;
        string name;
        address creator;
        uint256 stakingBonus;
        uint256 chargePool;
        bool isJoinRestricted;
        ColonyCriteria joinCriteria;
        TokenMember[] members;
        PendingJoinRequest[] pendingRequests;
    }
    
    /**
     * @notice Member data structure
     */
    struct TokenMember {
        uint256 collectionId;
        uint256 tokenId;
    }
    
    /**
     * @notice Pending join request structure
     */
    struct PendingJoinRequest {
        uint256 collectionId;
        uint256 tokenId;
        address requester;
    }
    
    /**
     * @notice Global settings structure
     */
    struct GlobalSettings {
        uint256 maxCreatorBonusPercentage;
        bool allowEmptyColonyJoin;
    }
    
    /**
     * @notice Clear storage components before restoration
     * @param clearColonies Clear colony main data
     * @param clearMembers Clear member mappings  
     * @param clearRegistry Clear global registry
     * @param clearUserMappings Clear user->colony mappings
     * @param clearPendingRequests Clear pending join requests
     */
    function clearMigrationStorage(
        bool clearColonies,
        bool clearMembers,
        bool clearRegistry,
        bool clearUserMappings,
        bool clearPendingRequests
    ) external onlyAuthorized whenNotPaused {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (clearRegistry) {
            delete hs.allColonyIds;
            emit StorageCleared("registry");
        }
        
        if (clearColonies) {
            // Note: Cannot iterate all mappings, but we signal the intent
            emit StorageCleared("colonies");
        }
        
        if (clearMembers) {
            emit StorageCleared("members");
        }
        
        if (clearUserMappings) {
            emit StorageCleared("userMappings");  
        }
        
        if (clearPendingRequests) {
            emit StorageCleared("pendingRequests");
        }
    }
    
    /**
     * @notice Restore global settings
     * @param settings Global settings to restore
     */
    function restoreGlobalSettings(GlobalSettings calldata settings) 
        external 
        onlyAuthorized 
        whenNotPaused 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        hs.maxCreatorBonusPercentage = settings.maxCreatorBonusPercentage;
        hs.allowEmptyColonyJoin = settings.allowEmptyColonyJoin;
        
        emit GlobalSettingsRestored(
            settings.maxCreatorBonusPercentage,
            settings.allowEmptyColonyJoin
        );
    }
    
    /**
     * @notice Restore single colony with all data - NO CHECKS, NO FEES
     * @param colonyData Complete colony data to restore
     */
    function restoreColony(ColonyRestoreData calldata colonyData) 
        external 
        onlyAuthorized 
        whenNotPaused 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        _restoreColonyData(colonyData, hs);
        
        emit ColonyRestored(
            colonyData.id,
            colonyData.name,
            colonyData.creator,
            colonyData.members.length,
            colonyData.pendingRequests.length
        );
    }
    
    /**
     * @notice Batch restore multiple colonies - NO CHECKS, NO FEES
     * @param colonies Array of colonies to restore
     */
    function batchRestoreColonies(ColonyRestoreData[] calldata colonies) 
        external 
        onlyAuthorized 
        whenNotPaused 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        uint256 totalMembers = 0;
        uint256 totalPending = 0;
        
        for (uint256 i = 0; i < colonies.length; i++) {
            _restoreColonyData(colonies[i], hs);
            totalMembers += colonies[i].members.length;
            totalPending += colonies[i].pendingRequests.length;
        }
        
        emit BatchRestored(colonies.length, totalMembers, totalPending);
    }
    
    /**
     * @notice Restore user->colony mappings - NO CHECKS, NO FEES
     * @param users Array of user addresses
     * @param userColonies Array of colony arrays for each user
     */
    function restoreUserColonies(
        address[] calldata users,
        bytes32[][] calldata userColonies
    ) external onlyAuthorized whenNotPaused {
        require(users.length == userColonies.length, "Arrays length mismatch");
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            
            // Clear existing user colonies
            delete hs.userColonies[user];
            
            // Restore user colonies
            for (uint256 j = 0; j < userColonies[i].length; j++) {
                hs.userColonies[user].push(userColonies[i][j]);
            }
            
            emit UserColoniesRestored(user, userColonies[i].length);
        }
    }
    
    /**
     * @notice Remove specific corrupted colony - NO CHECKS
     * @param colonyId Colony ID to remove completely
     */
    function removeCorruptedColony(bytes32 colonyId) 
        external 
        onlyAuthorized 
        whenNotPaused 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Get data before clearing
        address creator = hs.colonyCreators[colonyId];
        uint256[] storage members = hs.colonies[colonyId];
        
        // Clear member references
        for (uint256 i = 0; i < members.length; i++) {
            uint256 combinedId = members[i];
            delete hs.specimenColonies[combinedId];
            delete hs.colonyMemberIndices[colonyId][combinedId];
        }
        
        // Clear pending requests
        uint256[] storage pendingIds = hs.colonyPendingRequestIds[colonyId];
        for (uint256 i = 0; i < pendingIds.length; i++) {
            delete hs.pendingJoinRequests[colonyId][pendingIds[i]];
        }
        delete hs.colonyPendingRequestIds[colonyId];
        
        // Clear all colony data
        delete hs.colonies[colonyId];
        delete hs.colonyCreators[colonyId];
        delete hs.colonyStakingBonuses[colonyId];
        delete hs.colonyChargePools[colonyId];
        delete hs.colonyCriteria[colonyId];
        delete hs.colonyJoinRestrictions[colonyId];
        delete hs.colonyNamesById[colonyId];
        
        // Find and clear name hash
        string memory name = hs.colonyNamesById[colonyId];
        if (bytes(name).length > 0) {
            bytes32 nameHash = keccak256(abi.encodePacked(name));
            delete hs.colonyNames[nameHash];
        }
        
        // Remove from user colonies
        if (creator != address(0)) {
            bytes32[] storage userColonies = hs.userColonies[creator];
            for (uint256 i = 0; i < userColonies.length; i++) {
                if (userColonies[i] == colonyId) {
                    userColonies[i] = userColonies[userColonies.length - 1];
                    userColonies.pop();
                    break;
                }
            }
        }
        
        // Remove from global registry
        for (uint256 i = 0; i < hs.allColonyIds.length; i++) {
            if (hs.allColonyIds[i] == colonyId) {
                hs.allColonyIds[i] = hs.allColonyIds[hs.allColonyIds.length - 1];
                hs.allColonyIds.pop();
                break;
            }
        }
    }
    
    /**
     * @notice Complete migration process
     * @param totalColonies Total number of colonies restored  
     * @param totalMembers Total number of members restored
     * @param totalPending Total number of pending requests restored
     */
    function completeMigration(
        uint256 totalColonies,
        uint256 totalMembers, 
        uint256 totalPending
    ) external onlyAuthorized whenNotPaused {
        emit MigrationCompleted(totalColonies, totalMembers, totalPending);
    }
    
    /**
     * @notice Internal function to restore colony data
     */
    function _restoreColonyData(
        ColonyRestoreData calldata colonyData,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) internal {
        bytes32 colonyId = colonyData.id;
        
        // Store basic colony info
        bytes32 nameHash = keccak256(abi.encodePacked(colonyData.name));
        hs.colonyNames[nameHash] = colonyData.name;
        hs.colonyNamesById[colonyId] = colonyData.name;
        hs.colonyCreators[colonyId] = colonyData.creator;
        hs.colonyStakingBonuses[colonyId] = colonyData.stakingBonus;
        hs.colonyChargePools[colonyId] = colonyData.chargePool;
        hs.colonyJoinRestrictions[colonyId] = colonyData.isJoinRestricted;
        
        // Store join criteria
        hs.colonyCriteria[colonyId] = colonyData.joinCriteria;
        
        // Restore members
        uint256[] memory memberIds = new uint256[](colonyData.members.length);
        for (uint256 i = 0; i < colonyData.members.length; i++) {
            uint256 combinedId = PodsUtils.combineIds(
                colonyData.members[i].collectionId,
                colonyData.members[i].tokenId
            );
            
            memberIds[i] = combinedId;
            hs.specimenColonies[combinedId] = colonyId;
            hs.colonyMemberIndices[colonyId][combinedId] = i + 1; // 1-based index
        }
        
        hs.colonies[colonyId] = memberIds;
        
        // Restore pending join requests
        for (uint256 i = 0; i < colonyData.pendingRequests.length; i++) {
            uint256 combinedId = PodsUtils.combineIds(
                colonyData.pendingRequests[i].collectionId,
                colonyData.pendingRequests[i].tokenId
            );
            
            hs.pendingJoinRequests[colonyId][combinedId] = colonyData.pendingRequests[i].requester;
            hs.colonyPendingRequestIds[colonyId].push(combinedId);
        }
        
        // Add to user colonies
        hs.userColonies[colonyData.creator].push(colonyId);
        
        // Add to global registry
        hs.allColonyIds.push(colonyId);
    }
    
    /**
     * @notice Emergency function to fix colony member indices
     * @param colonyId Colony ID to fix indices for
     */
    function fixColonyMemberIndices(bytes32 colonyId) 
        external 
        onlyAuthorized 
        whenNotPaused 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        uint256[] storage members = hs.colonies[colonyId];
        
        // Clear existing indices
        for (uint256 i = 0; i < members.length; i++) {
            delete hs.colonyMemberIndices[colonyId][members[i]];
        }
        
        // Set correct indices (1-based)
        for (uint256 i = 0; i < members.length; i++) {
            hs.colonyMemberIndices[colonyId][members[i]] = i + 1;
        }
    }
    
    /**
     * @notice Get migration statistics
     * @return totalColonies Total colonies in system
     * @return totalRegistryEntries Entries in global registry
     */
    function getMigrationStats() external view returns (
        uint256 totalColonies,
        uint256 totalRegistryEntries
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        totalRegistryEntries = hs.allColonyIds.length;
        totalColonies = totalRegistryEntries; // Assuming registry is accurate
        
        return (totalColonies, totalRegistryEntries);
    }
    
    /**
     * @notice Validate colony data integrity
     * @param colonyId Colony ID to validate
     * @return isValid Whether colony data is consistent
     * @return memberCount Number of members
     * @return pendingCount Number of pending requests
     */
    function validateColonyIntegrity(bytes32 colonyId) external view returns (
        bool isValid,
        uint256 memberCount,
        uint256 pendingCount
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Check if colony exists
        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            return (false, 0, 0);
        }
        
        memberCount = hs.colonies[colonyId].length;
        pendingCount = hs.colonyPendingRequestIds[colonyId].length;
        
        // Basic validation - colony exists and has creator
        isValid = hs.colonyCreators[colonyId] != address(0);
        
        return (isValid, memberCount, pendingCount);
    }
    
    /**
     * @notice Storage diagnostic information
     */
    struct StorageDiagnostic {
        bool existsInNamesById;
        bool existsInNames; 
        bool hasCreator;
        bool hasMembers;
        bool hasPendingRequests;
        bool existsInRegistry;
        bool existsInUserColonies;
        uint256 memberCount;
        uint256 pendingCount;
        uint256 stakingBonus;
        uint256 chargePool;
        bool isJoinRestricted;
        string name;
        address creator;
    }
    
    /**
     * @notice Comprehensive colony storage diagnostic
     * @param colonyId Colony ID to diagnose
     * @return diagnostic Complete storage diagnostic information
     */
    function diagnoseColonyStorage(bytes32 colonyId) external view returns (StorageDiagnostic memory diagnostic) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Basic existence checks
        diagnostic.name = hs.colonyNamesById[colonyId];
        diagnostic.existsInNamesById = bytes(diagnostic.name).length > 0;
        
        diagnostic.creator = hs.colonyCreators[colonyId];
        diagnostic.hasCreator = diagnostic.creator != address(0);
        
        // Check if exists in names mapping (by hash)
        if (diagnostic.existsInNamesById) {
            bytes32 nameHash = keccak256(abi.encodePacked(diagnostic.name));
            diagnostic.existsInNames = keccak256(abi.encodePacked(hs.colonyNames[nameHash])) == keccak256(abi.encodePacked(diagnostic.name));
        }
        
        // Member information
        diagnostic.memberCount = hs.colonies[colonyId].length;
        diagnostic.hasMembers = diagnostic.memberCount > 0;
        
        // Pending requests
        diagnostic.pendingCount = hs.colonyPendingRequestIds[colonyId].length;
        diagnostic.hasPendingRequests = diagnostic.pendingCount > 0;
        
        // Other colony data
        diagnostic.stakingBonus = hs.colonyStakingBonuses[colonyId];
        diagnostic.chargePool = hs.colonyChargePools[colonyId];
        diagnostic.isJoinRestricted = hs.colonyJoinRestrictions[colonyId];
        
        // Check if exists in global registry
        for (uint256 i = 0; i < hs.allColonyIds.length; i++) {
            if (hs.allColonyIds[i] == colonyId) {
                diagnostic.existsInRegistry = true;
                break;
            }
        }
        
        // Check if exists in user colonies
        if (diagnostic.hasCreator) {
            bytes32[] storage userColonies = hs.userColonies[diagnostic.creator];
            for (uint256 i = 0; i < userColonies.length; i++) {
                if (userColonies[i] == colonyId) {
                    diagnostic.existsInUserColonies = true;
                    break;
                }
            }
        }
        
        return diagnostic;
    }
    
    /**
     * @notice Get detailed member information for a colony
     * @param colonyId Colony ID to check
     * @return combinedIds Array of combined member IDs
     * @return collectionIds Array of collection IDs
     * @return tokenIds Array of token IDs
     * @return memberIndices Array of member indices (1-based, 0 = not found)
     */
    function getColonyMemberDetails(bytes32 colonyId) external view returns (
        uint256[] memory combinedIds,
        uint256[] memory collectionIds,
        uint256[] memory tokenIds,
        uint256[] memory memberIndices
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        combinedIds = hs.colonies[colonyId];
        uint256 memberCount = combinedIds.length;
        
        collectionIds = new uint256[](memberCount);
        tokenIds = new uint256[](memberCount);
        memberIndices = new uint256[](memberCount);
        
        for (uint256 i = 0; i < memberCount; i++) {
            uint256 combinedId = combinedIds[i];
            
            // Extract collection and token IDs (reverse of PodsUtils.combineIds)
            collectionIds[i] = uint256(combinedId >> 128);
            tokenIds[i] = uint256(combinedId & ((1 << 128) - 1));
            
            // Get member index
            memberIndices[i] = hs.colonyMemberIndices[colonyId][combinedId];
        }
        
        return (combinedIds, collectionIds, tokenIds, memberIndices);
    }
    
    /**
     * @notice Get pending join requests details
     * @param colonyId Colony ID to check
     * @return pendingIds Array of pending combined IDs
     * @return collectionIds Array of collection IDs for pending requests
     * @return tokenIds Array of token IDs for pending requests
     * @return requesters Array of requester addresses
     */
    function getPendingRequestsDetails(bytes32 colonyId) external view returns (
        uint256[] memory pendingIds,
        uint256[] memory collectionIds,
        uint256[] memory tokenIds,
        address[] memory requesters
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        pendingIds = hs.colonyPendingRequestIds[colonyId];
        uint256 pendingCount = pendingIds.length;
        
        collectionIds = new uint256[](pendingCount);
        tokenIds = new uint256[](pendingCount);
        requesters = new address[](pendingCount);
        
        for (uint256 i = 0; i < pendingCount; i++) {
            uint256 combinedId = pendingIds[i];
            
            // Extract collection and token IDs
            collectionIds[i] = uint256(combinedId >> 128);
            tokenIds[i] = uint256(combinedId & ((1 << 128) - 1));
            
            // Get requester
            requesters[i] = hs.pendingJoinRequests[colonyId][combinedId];
        }
        
        return (pendingIds, collectionIds, tokenIds, requesters);
    }
    
    /**
     * @notice Check storage consistency across all mappings
     * @return totalColoniesInRegistry Number of colonies in global registry
     * @return totalUniqueCreators Number of unique creators found
     * @return totalMembersAcrossColonies Total members across all colonies
     * @return totalPendingAcrossColonies Total pending requests across all colonies
     * @return inconsistentColonies Number of colonies with storage inconsistencies
     */
    function checkStorageConsistency() external view returns (
        uint256 totalColoniesInRegistry,
        uint256 totalUniqueCreators,
        uint256 totalMembersAcrossColonies,
        uint256 totalPendingAcrossColonies,
        uint256 inconsistentColonies
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        totalColoniesInRegistry = hs.allColonyIds.length;
        
        // Track unique creators
        address[] memory creators = new address[](totalColoniesInRegistry);
        uint256 uniqueCreatorCount = 0;
        
        // Analyze each colony in registry
        for (uint256 i = 0; i < totalColoniesInRegistry; i++) {
            bytes32 colonyId = hs.allColonyIds[i];
            
            // Count members and pending requests
            totalMembersAcrossColonies += hs.colonies[colonyId].length;
            totalPendingAcrossColonies += hs.colonyPendingRequestIds[colonyId].length;
            
            // Track creators
            address creator = hs.colonyCreators[colonyId];
            if (creator != address(0)) {
                bool isNewCreator = true;
                for (uint256 j = 0; j < uniqueCreatorCount; j++) {
                    if (creators[j] == creator) {
                        isNewCreator = false;
                        break;
                    }
                }
                if (isNewCreator) {
                    creators[uniqueCreatorCount] = creator;
                    uniqueCreatorCount++;
                }
            }
            
            // Check for basic inconsistencies
            if (bytes(hs.colonyNamesById[colonyId]).length == 0 || creator == address(0)) {
                inconsistentColonies++;
            }
        }
        
        totalUniqueCreators = uniqueCreatorCount;
        
        return (
            totalColoniesInRegistry,
            totalUniqueCreators,
            totalMembersAcrossColonies,
            totalPendingAcrossColonies,
            inconsistentColonies
        );
    }
}