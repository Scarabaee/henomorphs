// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {PodsUtils} from "../../../libraries/PodsUtils.sol";
import {ColonyHelper} from "../../staking/libraries/ColonyHelper.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {AccessHelper} from "../../staking/libraries/AccessHelper.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {ColonyCriteria} from "../../../libraries/HenomorphsModel.sol";

/**
 * @title ColonyViewFacet
 * @notice View functions for colonies data access
 * @author rutilicus.eth (ArchXS)
 */
contract ColonyViewFacet is AccessControlBase {
    // Events
    event UserColoniesRequested(address indexed user);
    event PendingRequestsAccessed(bytes32 indexed colonyId, address indexed accessor, uint256 requestCount);
    
    /**
     * @notice Get colony members
     * @param colonyId ID of the colony
     * @return collectionIds Array of collection IDs
     * @return tokenIds Array of token IDs
     */
    function getColonyMembers(bytes32 colonyId) external view returns (
        uint256[] memory collectionIds,
        uint256[] memory tokenIds
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            revert ColonyHelper.ColonyDoesNotExist(colonyId);
        }
        
        uint256[] storage combinedIds = hs.colonies[colonyId];
        uint256 memberCount = combinedIds.length;
        
        collectionIds = new uint256[](memberCount);
        tokenIds = new uint256[](memberCount);
        
        for (uint256 i = 0; i < memberCount; i++) {
            (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedIds[i]);
            collectionIds[i] = collectionId;
            tokenIds[i] = tokenId;
        }
        
        return (collectionIds, tokenIds);
    }
    
    /**
     * @notice Get colony info
     * @param colonyId ID of the colony
     * @return name Colony name
     * @return creator Colony creator address
     * @return active Whether colony is active
     * @return stakingBonus Staking bonus percentage
     * @return memberCount Number of members
     */
    function getColonyInfo(bytes32 colonyId) external view returns (
        string memory name,
        address creator,
        bool active,
        uint256 stakingBonus,
        uint32 memberCount
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            revert ColonyHelper.ColonyDoesNotExist(colonyId);
        }
        
        name = hs.colonyNamesById[colonyId];
        creator = hs.colonyCreators[colonyId];
        active = true; // If colony exists, it's active
        stakingBonus = hs.colonyStakingBonuses[colonyId];
        memberCount = uint32(hs.colonies[colonyId].length);
        
        return (name, creator, active, stakingBonus, memberCount);
    }

    /**
    * @notice Get colony info with health status
    * @param colonyId ID of the colony  
    * @dev Only adds health info to existing getColonyInfo - keeps ViewFacet focused
    */
    function getColonyInfoWithHealth(bytes32 colonyId) external view returns (
        string memory name,
        address creator,
        bool active,
        uint256 stakingBonus,
        uint32 memberCount,
        uint8 healthLevel,
        bool needsAttention,
        uint32 daysSinceActivity
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            revert ColonyHelper.ColonyDoesNotExist(colonyId);
        }
        
        // Reuse existing logic
        name = hs.colonyNamesById[colonyId];
        creator = hs.colonyCreators[colonyId];
        active = true;
        stakingBonus = hs.colonyStakingBonuses[colonyId];
        memberCount = uint32(hs.colonies[colonyId].length);
        
        // Add health calculation (delegate to helper)
        (healthLevel, daysSinceActivity) = ColonyHelper.calculateColonyHealth(colonyId);
        needsAttention = healthLevel < 50;
}

    /**
     * @notice Get colony join criteria
     * @param colonyId ID of the colony
     * @return Colony join criteria
     */
    function getColonyJoinCriteria(bytes32 colonyId) external view returns (ColonyCriteria memory) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            revert ColonyHelper.ColonyDoesNotExist(colonyId);
        }
        
        return hs.colonyCriteria[colonyId];
    }
    
    /**
     * @notice Get token's colony
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return Colony ID of the token's colony
     */
    function getTokenColony(uint256 collectionId, uint256 tokenId) external view returns (bytes32) {
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        return LibHenomorphsStorage.henomorphsStorage().specimenColonies[combinedId];
    }
    
    /**
     * @notice Get staking bonus for a colony
     * @param colonyId ID of the colony
     * @return Staking bonus percentage
     */
    function getStakingBonus(bytes32 colonyId) external view returns (uint256) {
        return LibHenomorphsStorage.henomorphsStorage().colonyStakingBonuses[colonyId];
    }
    
    /**
     * @notice Get staking listener address
     * @return Address of the staking listener
     */
    function getStakingListener() external view returns (address) {
        return LibHenomorphsStorage.henomorphsStorage().stakingSystemAddress;
    }

    /**
     * @notice Get list of all colonies with basic info - optimized implementation
     * @param startIdx Starting index
     * @return colonies Array of colony registry items
     */
    function getAllColonies(uint256 startIdx) external view returns (
        ColonyHelper.ColonyRegistryItem[] memory colonies
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Get active colony IDs using optimized helper
        (bytes32[] memory colonyIds, ) = ColonyHelper.getActiveColonyIds(startIdx, 50);
        
        if (colonyIds.length == 0) {
            return new ColonyHelper.ColonyRegistryItem[](0);
        }
        
        // Prepare the result array
        colonies = new ColonyHelper.ColonyRegistryItem[](colonyIds.length);
        
        // Populate colony registry items
        for (uint256 i = 0; i < colonyIds.length; i++) {
            bytes32 colonyId = colonyIds[i];
            
            (, string memory colonyName) = ColonyHelper.findColonyNameHash(colonyId);
            
            colonies[i].colonyId = colonyId;
            colonies[i].name = colonyName;
            colonies[i].creator = hs.colonyCreators[colonyId];
            colonies[i].memberCount = hs.colonies[colonyId].length;
            colonies[i].requiresApproval = hs.colonyCriteria[colonyId].requiresApproval;
        }
        
        return colonies;
    }

    /**
     * @notice Get colonies created by a specific user - view function that can be called by anyone
     * @param user Address of the user to get colonies for
     * @return colonies Array of colony registry items
     */
    function getUserColonies(address user) public view returns (ColonyHelper.ColonyRegistryItem[] memory colonies) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        bytes32[] storage userColonies = hs.userColonies[user];
        uint256 colonyCount = userColonies.length;
        
        colonies = new ColonyHelper.ColonyRegistryItem[](colonyCount);
        
        for (uint256 i = 0; i < colonyCount; i++) {
            bytes32 colonyId = userColonies[i];
            
            (, string memory colonyName) = ColonyHelper.findColonyNameHash(colonyId);
            
            colonies[i].colonyId = colonyId;
            colonies[i].name = colonyName;
            colonies[i].creator = hs.colonyCreators[colonyId];
            colonies[i].memberCount = hs.colonies[colonyId].length;
            colonies[i].requiresApproval = hs.colonyCriteria[colonyId].requiresApproval;
        }
        
        return colonies;
    }
    
    /**
     * @notice Get colonies created by the calling user
     * @dev Non-view for backward compatibility, emits event and returns data for caller
     * @return colonies Array of colony registry items
     */
    function getMyColonies() external returns (ColonyHelper.ColonyRegistryItem[] memory colonies) {
        address user = LibMeta.msgSender();
        emit UserColoniesRequested(user);
        
        return getUserColonies(user);
    }

    /**
     * @notice Get pending join requests for a colony (with access logging)
     * @dev Emits event for access tracking, but doesn't modify storage
     * @param colonyId ID of the colony
     * @return requests Pending join requests
     */
    function getPendingJoinRequests(bytes32 colonyId) external returns (
        ColonyHelper.PendingRequests memory requests
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Check if colony exists
        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            revert ColonyHelper.ColonyDoesNotExist(colonyId);
        }
        
        address caller = LibMeta.msgSender();
        address colonyOwner = hs.colonyCreators[colonyId];
        
        // Authorization check
        if (caller != colonyOwner && !AccessHelper.isAuthorized()) {
            revert AccessHelper.Unauthorized(caller, "Not authorized for this colony");
        }
        
        uint256[] storage pendingIds = hs.colonyPendingRequestIds[colonyId];
        uint256 requestCount = pendingIds.length;
        
        requests.collectionIds = new uint256[](requestCount);
        requests.tokenIds = new uint256[](requestCount);
        requests.requesters = new address[](requestCount);
        
        for (uint256 i = 0; i < requestCount; i++) {
            uint256 combinedId = pendingIds[i];
            address requester = hs.pendingJoinRequests[colonyId][combinedId];
            
            if (requester == address(0)) continue;
            
            (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);
            requests.collectionIds[i] = collectionId;
            requests.tokenIds[i] = tokenId;
            requests.requesters[i] = requester;
        }
        
        // Event dla auditingu - nie modyfikuje storage!
        emit PendingRequestsAccessed(colonyId, caller, requestCount);
        
        return requests;
    }

    /**
     * @notice Check if empty colony join is allowed globally
     * @return Whether joining empty colonies is allowed by default
     */
    function isEmptyColonyJoinAllowed() external view returns (bool) {
        return LibHenomorphsStorage.henomorphsStorage().allowEmptyColonyJoin;
    }

    /**
     * @notice Check if joining empty colony is restricted for a specific colony
     * @param colonyId ID of the colony
     * @return restricted Whether empty colony joining is restricted
     */
    function isColonyJoinRestricted(bytes32 colonyId) external view returns (bool restricted) {
        return LibHenomorphsStorage.henomorphsStorage().colonyJoinRestrictions[colonyId];
    }

    /**
     * @notice Get maximum bonus percentage that can be set for a colony creator
     */
    function getMaxCreatorBonusPercentage() external view returns (uint256) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        return hs.maxCreatorBonusPercentage;
    }

    /**
     * @notice Get maximum bonus percentage that can be set for a colony
     * @param colonyId Colony ID to check
     * @return maxBonus Maximum bonus percentage
     */
    function getMaxColonyBonus(bytes32 colonyId) external view returns (uint256 maxBonus) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Check if the caller is authorized to manage this colony
        bool isAdmin = AccessHelper.isAuthorized();
        bool isColonyOwner = ColonyHelper.isAuthorizedForColony(colonyId, hs.stakingSystemAddress);
        
        // Return appropriate max bonus based on caller's role
        if (isAdmin) {
            return 50; // Admins can set up to 50%
        } else if (isColonyOwner) {
            // Default to 25% if maxCreatorBonusPercentage is not set
            return hs.maxCreatorBonusPercentage > 0 ? hs.maxCreatorBonusPercentage : 25;
        } else {
            // Caller is not authorized to set any bonus
            return 0;
        }
    }

}