// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibStakingStorage} from "../libraries/LibStakingStorage.sol";
import {PodsUtils} from "../../../libraries/PodsUtils.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {Calibration, ColonyCriteria} from "../../../libraries/HenomorphsModel.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {IColonyFacet, IStakingBiopodFacet} from "../interfaces/IStakingInterfaces.sol";
import {StakedSpecimen} from "../../../libraries/StakingModel.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title StakingColonyFacet
 * @author rutilicus.eth (ArchXS)
 * @notice Facet for colony management in the staking system
 * @dev Optimized to use ColonyFacet as the single source of truth with minimal cross-diamond communication
 */
contract StakingColonyFacet is AccessControlBase {
    // Events
    event SpecimenJoinedColony(uint256 indexed collectionId, uint256 indexed tokenId, bytes32 indexed colonyId);
    event SpecimenLeftColony(uint256 indexed collectionId, uint256 indexed tokenId, bytes32 indexed colonyId);
    event ColonyCreated(bytes32 indexed colonyId, string name, address indexed creator);
    event ColonyDissolved(bytes32 indexed colonyId);
    event ColonyBonusSet(bytes32 indexed colonyId, uint256 bonusPercentage);
    event ColonyJoinCriteriaSet(bytes32 indexed colonyId, ColonyCriteria criteria);
    event OperationResult(string operation, bool success);
    event ChargepodAddressSet(address chargepodAddress);
    event MembersSynchronized(bytes32 indexed colonyId, uint256 batchSize, uint256 successCount);
    
    // Event to track data cleaning operations
    event TokenDataCleaned(uint256 count, string operation);

    // Event to track specific token fixes
    event TokenColonyReferenceFixed(uint256 indexed collectionId, uint256 indexed tokenId, bytes32 invalidColonyId);
    
    // Errors
    error InvalidColonyId(bytes32 colonyId);
    error NoChargeSystemAddress();
    
    /**
     * @notice Set Chargepod address for colony data retrieval
     * @param chargeSystemAddress Address of the Chargepod system
     */
    function setChargeSystemAddress(address chargeSystemAddress) external whenNotPaused {
        // Only allow calls from authorized users or from the Chargepod system itself
        address sender = LibMeta.msgSender();
        address currentChargepod = LibStakingStorage.stakingStorage().chargeSystemAddress;
        
        if (!AccessHelper.isAuthorized() && 
            currentChargepod != address(0) && 
            sender != currentChargepod) {
            revert AccessHelper.Unauthorized(sender, "Not authorized for Chargepod configuration");
        }
        
        // Update Chargepod address
        LibStakingStorage.stakingStorage().chargeSystemAddress = chargeSystemAddress;
        
        emit ChargepodAddressSet(chargeSystemAddress);
    }

    /**
     * @notice Batch notify colony changes for multiple specimens
     * @param colonyId Colony ID
     * @param collectionIds Array of collection IDs
     * @param tokenIds Array of token IDs
     * @param isJoining Whether specimens are joining or leaving colony
     * @return successCount Number of specimens successfully processed
     */
    function batchNotifyColonyChanges(
        bytes32 colonyId,
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds,
        bool isJoining
    ) external whenNotPaused nonReentrant returns (uint256 successCount) {
        // Only allow calls from the Chargepod system or authorized users
        if (!AccessHelper.isAuthorized() && !_isFromChargepod() && !AccessHelper.isInternalCall()) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not authorized for batch operations");
        }
        
        // Validate input
        if (collectionIds.length != tokenIds.length || collectionIds.length == 0) {
            return 0;
        }
        
        successCount = 0;
        
        // Process tokens directly, using internal implementation instead of this.notifyColonyChange()
        for (uint256 i = 0; i < collectionIds.length; i++) {
            bool success = _processColonyChangeInternal(colonyId, collectionIds[i], tokenIds[i], isJoining);
            if (success) {
                successCount++;
            }
        }
        
        emit MembersSynchronized(colonyId, collectionIds.length, successCount);
        return successCount;
    }
        
    /**
     * @notice Unified notification for colony membership changes
     * @param colonyId Colony ID
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param isJoining Whether specimen is joining or leaving colony
     * @return success Whether operation was successful
     */
    function notifyColonyChange(
        bytes32 colonyId,
        uint256 collectionId,
        uint256 tokenId,
        bool isJoining
    ) public nonReentrant returns (bool success) {
        // Only allow calls from the Chargepod system
        _onlyChargepod();
        
        // Use the internal implementation
        return _processColonyChangeInternal(colonyId, collectionId, tokenId, isJoining);
    }
        
    /**
     * @notice Legacy method - notify when a specimen joins a colony
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param colonyId Colony ID
     */
    function notifySpecimenJoinedColony(
        uint256 collectionId, 
        uint256 tokenId, 
        bytes32 colonyId
    ) external whenNotPaused {
        // IMPROVED AUTHORIZATION: Accept calls from Chargepod, internal calls, or admins
        // This ensures compatibility with all call patterns
        if (!AccessHelper.isAuthorized() && !_isFromChargepod() && !AccessHelper.isInternalCall()) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not authorized for this operation");
        }
        
        // Use the unified method
        _processColonyChangeInternal(colonyId, collectionId, tokenId, true);
    }
        
    /**
     * @notice Legacy method - notify when a specimen leaves a colony
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param colonyId Colony ID
     */
    function notifySpecimenLeftColony(
        uint256 collectionId, 
        uint256 tokenId, 
        bytes32 colonyId
    ) external whenNotPaused {
        // Only allow calls from the Chargepod system
        _onlyChargepod();
        
        // Use the unified method
        notifyColonyChange(colonyId, collectionId, tokenId, false);
    }
    
    /**
     * @notice Notify when a colony is created
     * @param colonyId Colony ID
     * @param name Colony name
     * @param creator Colony creator address
     */
    function notifyColonyCreated(
        bytes32 colonyId,
        string calldata name,
        address creator
    ) external whenNotPaused {
        // Only allow calls from the Chargepod system
        _onlyChargepod();
        
        // Initialize essential colony data
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Only initialize if colony doesn't exist yet
        if (!ss.colonyActive[colonyId]) {
            // Store colony metadata - minimal required data
            ss.colonyActive[colonyId] = true;
            ss.colonyNameById[colonyId] = name;
            ss.colonyCreators[colonyId] = creator;
            ss.colonyStakingBonuses[colonyId] = 5; // Default 5% bonus
            
            // Initialize stats
            ss.colonyStats[colonyId].memberCount = 0;
            
            // Initialize coherent colony structure (new pattern)
            ss.colonies[colonyId].name = name;
            ss.colonies[colonyId].creator = creator;
            ss.colonies[colonyId].active = true;
            ss.colonies[colonyId].stakingBonus = 5;
            ss.colonies[colonyId].stats.memberCount = 0;
            
            // Add to list of all colonies if not already present
            bool alreadyInList = false;
            for (uint256 i = 0; i < ss.allColonyIds.length; i++) {
                if (ss.allColonyIds[i] == colonyId) {
                    alreadyInList = true;
                    break;
                }
            }
            
            if (!alreadyInList) {
                ss.allColonyIds.push(colonyId);
            }
        }
        
        emit ColonyCreated(colonyId, name, creator);
    }
    
    /**
     * @notice Notify when a colony is dissolved
     * @param colonyId Colony ID
     */
    function notifyColonyDissolved(bytes32 colonyId) external whenNotPaused {
        // Only allow calls from the Chargepod system
        _onlyChargepod();
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Clear colony data
        if (ss.colonyActive[colonyId]) {
            // Clear all members first
            uint256[] storage members = ss.colonyMembers[colonyId];
            
            // Remove colony association from each member
            for (uint256 i = 0; i < members.length; i++) {
                uint256 combinedId = members[i];
                StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
                
                // Only update if the specimen is staked and belongs to this colony
                if (staked.staked && staked.colonyId == colonyId) {
                    staked.colonyId = bytes32(0);
                    staked.lastSyncTimestamp = uint32(block.timestamp); // Update timestamp to trigger recalculation
                    
                    // Extract collection and token IDs for event
                    (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);
                    emit SpecimenLeftColony(collectionId, tokenId, colonyId);
                }
            }
            
            // Clear members array
            delete ss.colonyMembers[colonyId];
            
            // Update colony state
            ss.colonyActive[colonyId] = false;
            ss.colonies[colonyId].active = false;
            
            // Do not delete name, creator or other metadata - just mark as inactive
        }
        
        emit ColonyDissolved(colonyId);
    }


    /**
     * @notice Set staking bonus for a colony
     * @param colonyId Colony ID
     * @param bonusPercentage Bonus percentage
     */
    function setStakingBonus(bytes32 colonyId, uint256 bonusPercentage) external whenNotPaused {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        address sender = LibMeta.msgSender();
        address chargepodAddress = ss.chargeSystemAddress;
        
        // Determine call type and authorization
        bool isAdmin = AccessHelper.isAuthorized();
        bool isFromChargepod = (chargepodAddress != address(0) && sender == chargepodAddress);
        bool isInternalCall = AccessHelper.isInternalCall();
        bool isDirectUserCall = (!isAdmin && !isFromChargepod && !isInternalCall);
        
        // Check if direct user call - needs colony ownership verification
        if (isDirectUserCall) {
            bool isColonyOwner = false;
            
            // Check local colony data first
            if (ss.colonyCreators[colonyId] == sender) {
                isColonyOwner = true;
            } 
            // If not found locally and we have Chargepod address, check there
            else if (chargepodAddress != address(0)) {
                try IColonyFacet(chargepodAddress).getColonyInfo(colonyId) returns (
                    string memory, address creator, bool exists, uint256, uint32
                ) {
                    if (exists && creator == sender) {
                        isColonyOwner = true;
                    }
                } catch {
                    // Ignore errors - default to not authorized
                }
            }
            
            if (!isColonyOwner) {
                revert AccessHelper.Unauthorized(sender, "Not authorized for this colony");
            }
            
            // For colony owners, apply the max creator bonus limit
            uint256 maxCreatorBonus = 25; // Default
            
            if (chargepodAddress != address(0)) {
                try IColonyFacet(chargepodAddress).getMaxCreatorBonusPercentage() returns (uint256 maxBonus) {
                    if (maxBonus > 0) {
                        maxCreatorBonus = maxBonus;
                    }
                } catch {
                    // Default to 25% if call fails
                }
            }
            
            if (bonusPercentage > maxCreatorBonus) {
                revert(string(abi.encodePacked(
                    "Creator bonus percentage cannot exceed ", 
                    Strings.toString(maxCreatorBonus), 
                    "%"
                )));
            }
        }
        // For admins, apply the 50% cap
        else if (isAdmin && !isFromChargepod && !isInternalCall) {
            if (bonusPercentage > 50) {
                bonusPercentage = 50; // Cap at 50%
            }
        }
        // For calls from Chargepod, accept value as is (already validated)
        
        // Update bonus in staking storage
        ss.colonyStakingBonuses[colonyId] = bonusPercentage;
        
        // Also update in unified structure
        if (ss.colonies[colonyId].active) {
            ss.colonies[colonyId].stakingBonus = bonusPercentage;
        }
        
        // Synchronize data between separate and composed structures
        LibStakingStorage.syncColonyStats(colonyId);
        
        // If this is a direct call (not from Chargepod), update Chargepod's storage too
        if (!isFromChargepod && chargepodAddress != address(0)) {
            try IColonyFacet(chargepodAddress).updateColonyBonusStorage(colonyId, bonusPercentage) {
                emit OperationResult("ChargepodStorageUpdate", true);
            } catch {
                emit OperationResult("ChargepodStorageUpdate", false); 
            }
        }
        
        emit ColonyBonusSet(colonyId, bonusPercentage);
    }

    /**
     * @notice Set join criteria for a colony
     * @param colonyId Colony ID
     * @param joinCriteria Colony join criteria
     */
    function setColonyJoinCriteria(bytes32 colonyId, ColonyCriteria calldata joinCriteria) external whenNotPaused {
        // Only allow calls from the Chargepod system or authorized users
        if (!AccessHelper.isAuthorized() && !_isFromChargepod() && !AccessHelper.isInternalCall()) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not authorized to set join criteria");
        }
        
        // Validate and store criteria
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Validate level constraint
        uint8 minLevel = joinCriteria.minLevel;
        if (minLevel > 10) {
            minLevel = 10; // Cap at level 10
        }
        
        // Validate variant constraint
        uint8 minVariant = joinCriteria.minVariant;
        if (minVariant > 4) {
            minVariant = 4; // Cap at variant 4
        }
        
        // Validate specialization constraint
        uint8 requiredSpecialization = joinCriteria.requiredSpecialization;
        if (requiredSpecialization > 2) {
            requiredSpecialization = 0; // Reset invalid specialization
        }
        
        // Store validated criteria
        ColonyCriteria storage criteria = ss.colonyCriteria[colonyId];
        criteria.minLevel = minLevel;
        criteria.minVariant = minVariant;
        criteria.requiredSpecialization = requiredSpecialization;
        criteria.requiresApproval = joinCriteria.requiresApproval;
        
        emit ColonyJoinCriteriaSet(colonyId, criteria);
    }
    
    /**
     * @notice Sync colony data from Chargepod
     * @param colonyId Colony ID
     * @return success Whether sync was successful
     */
    function syncColonyData(bytes32 colonyId) external whenNotPaused returns (bool success) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        address chargepodAddress = ss.chargeSystemAddress;
        
        if (chargepodAddress == address(0)) {
            return false;
        }
        
        try IColonyFacet(chargepodAddress).getColonyInfo(colonyId) returns (
            string memory name,
            address creator,
            bool exists,
            uint256 stakingBonus,
            uint32 memberCount
        ) {
            if (!exists) {
                return false;
            }
            
            // Update colony data in StakingStorage
            ss.colonyActive[colonyId] = exists;
            ss.colonyNameById[colonyId] = name;
            ss.colonyCreators[colonyId] = creator;
            ss.colonyStakingBonuses[colonyId] = stakingBonus;
            
            // Update coherent colony structure (new pattern)
            ss.colonies[colonyId].name = name;
            ss.colonies[colonyId].creator = creator;
            ss.colonies[colonyId].active = exists;
            ss.colonies[colonyId].stakingBonus = stakingBonus;
            
            // Only update member count if we don't have members locally
            if (ss.colonyMembers[colonyId].length == 0 && memberCount > 0) {
                // We need to retrieve all members from Chargepod
                try IColonyFacet(chargepodAddress).getColonyMembers(colonyId) returns (
                    uint256[] memory collectionIds,
                    uint256[] memory tokenIds
                ) {
                    if (collectionIds.length > 0 && collectionIds.length == tokenIds.length) {
                        // Call batchNotifyColonyMembers to add members
                        try this.batchNotifyColonyMembers(colonyId, collectionIds, tokenIds) returns (uint256 successCount) {
                            emit MembersSynchronized(colonyId, collectionIds.length, successCount);
                        } catch {
                            // Continue even if batch sync fails
                        }
                    }
                } catch {
                    // Continue even if members retrieval fails
                }
            }
            
            // Synchronize statistics
            LibStakingStorage.syncColonyStats(colonyId);
            
            return true;
        } catch {
            return false;
        }
    }

    /**
     * @notice Synchronize colony membership for a specific token
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return synchronized Whether synchronization was successful
     */
    function syncTokenColonyMembership(uint256 collectionId, uint256 tokenId) external whenNotPaused returns (bool synchronized) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        address chargepodAddress = ss.chargeSystemAddress;
        
        if (chargepodAddress == address(0)) {
            return false;
        }
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        try IColonyFacet(chargepodAddress).getTokenColony(collectionId, tokenId) returns (bytes32 colonyId) {
            if (colonyId != bytes32(0)) {
                // Token belongs to a colony in Chargepod
                StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
                
                // Update staked token if it's staked
                if (staked.staked) {
                    staked.colonyId = colonyId;
                    staked.lastSyncTimestamp = uint32(block.timestamp);
                } else {
                    // Set pending assignment for non-staked tokens
                    ss.tokenPendingColonyAssignments[combinedId] = colonyId;
                }
                
                // Ensure token is in colony members list
                _addTokenToColonyMembers(colonyId, combinedId);
                
                // Remove from any other colonies
                _removeTokenFromOtherColonies(combinedId, colonyId);
                
                return true;
            } else {
                // Token doesn't belong to any colony, clear any colony assignments
                _clearAllColonyAssignments(combinedId);
                return true;
            }
        } catch {
            return false;
        }
    }

    /**
     * @notice Repair colony membership data for all colonies or a specific colony
     * @dev Administrative function to fix synchronization issues between Chargepod and Staking
     * @param targetColonyId Colony ID to repair, or bytes32(0) to repair all colonies
     * @return repairedCount Number of tokens repaired
     */
    function repairColonyMembership(bytes32 targetColonyId) external onlyAuthorized whenNotPaused returns (uint256 repairedCount) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        address chargepodAddress = ss.chargeSystemAddress;
        
        if (chargepodAddress == address(0)) {
            return 0;
        }
        
        repairedCount = 0;
        
        // Process a single colony or all colonies based on parameter
        if (targetColonyId != bytes32(0)) {
            // Process only the specified colony
            repairedCount = _repairSingleColony(targetColonyId, chargepodAddress);
        } else {
            // Process all active colonies
            for (uint256 i = 0; i < ss.allColonyIds.length; i++) {
                bytes32 colonyId = ss.allColonyIds[i];
                if (!ss.colonyActive[colonyId]) {
                    continue;
                }
                
                repairedCount += _repairSingleColony(colonyId, chargepodAddress);
            }
        }
        
        return repairedCount;
    }

    /**
     * @dev Internal helper to repair a single colony's membership
     * @param colonyId Colony ID to repair
     * @param chargepodAddress Address of the Chargepod contract
     * @return repairedCount Number of tokens repaired for this colony
     */
    function _repairSingleColony(bytes32 colonyId, address chargepodAddress) private returns (uint256 repairedCount) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        repairedCount = 0;
        
        try IColonyFacet(chargepodAddress).getColonyMembers(colonyId) returns (
            uint256[] memory collectionIds, 
            uint256[] memory tokenIds
        ) {
            // Track which tokens should be in the colony according to Chargepod
            uint256[] memory validMembers = new uint256[](collectionIds.length);
            
            // Process each member from Chargepod
            for (uint256 j = 0; j < collectionIds.length; j++) {
                uint256 combinedId = PodsUtils.combineIds(collectionIds[j], tokenIds[j]);
                validMembers[j] = combinedId;
                
                // Update staked token if needed
                StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
                if (staked.staked) {
                    // Check for data inconsistency - token already assigned to different colony
                    bytes32 currentColonyId = staked.colonyId;
                    if (currentColonyId != bytes32(0) && currentColonyId != colonyId) {
                        // Log an inconsistency and handle based on flag
                        emit OperationResult(
                            string(abi.encodePacked(
                                "TokenColonyInconsistency_", 
                                Strings.toHexString(uint256(uint160(collectionIds[j])), 20),
                                "_",
                                Strings.toString(tokenIds[j])
                            )), 
                            false
                        );
                        
                        // Only replace if explicitly allowed
                        if (ss.forceOverrideInconsistentColonies) {
                            staked.colonyId = colonyId;
                            staked.lastSyncTimestamp = uint32(block.timestamp);
                            repairedCount++;
                        }
                    } else if (currentColonyId == bytes32(0)) {
                        // If not assigned to any colony, assign to this one
                        staked.colonyId = colonyId;
                        staked.lastSyncTimestamp = uint32(block.timestamp);
                        repairedCount++;
                    }
                } else {
                    // For non-staked tokens, set pending assignment
                    bytes32 pendingColony = ss.tokenPendingColonyAssignments[combinedId];
                    if (pendingColony != colonyId) {
                        ss.tokenPendingColonyAssignments[combinedId] = colonyId;
                        repairedCount++;
                    }
                }
                
                // Ensure token is in local colony members list
                bool tokenAdded = _addTokenToColonyMembers(colonyId, combinedId);
                if (tokenAdded) {
                    repairedCount++;
                    
                    // Log individual token additions for better diagnostics
                    emit OperationResult(
                        string(abi.encodePacked(
                            "TokenAddedToColony_",
                            Strings.toString(collectionIds[j]),
                            "_",
                            Strings.toString(tokenIds[j])
                        )),
                        true
                    );
                }
            }
            
            // Remove tokens that are no longer members in Chargepod
            uint256 removedCount = _removeInvalidColonyMembers(colonyId, validMembers);
            if (removedCount > 0) {
                repairedCount += removedCount;
                emit OperationResult(
                    string(abi.encodePacked("RemovedInvalidMembers_", Strings.toHexString(uint256(colonyId), 32))), 
                    true
                );
            }
            
            // Log overall result for this colony
            emit MembersSynchronized(colonyId, collectionIds.length, repairedCount);
            
        } catch {
            // If we can't retrieve members, log the error but continue with other colonies
            emit OperationResult(
                string(abi.encodePacked("FailedToGetColonyMembers_", Strings.toHexString(uint256(colonyId), 32))), 
                false
            );
        }
        
        return repairedCount;
    }
        
    /**
     * @notice Batch notify colony members
     * @param colonyId Colony ID
     * @param collectionIds Array of collection IDs
     * @param tokenIds Array of token IDs
     * @return successCount Number of members successfully processed
     */
    function batchNotifyColonyMembers(
        bytes32 colonyId,
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds
    ) external whenNotPaused nonReentrant returns (uint256 successCount) {
        // Only allow calls from the Chargepod system or authorized users
        if (!AccessHelper.isAuthorized() && !_isFromChargepod() && !AccessHelper.isInternalCall()) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not authorized for batch operations");
        }
        
        // Validate input
        if (collectionIds.length != tokenIds.length || collectionIds.length == 0) {
            return 0;
        }
        
        successCount = 0;
        
        // Process members directly without using this.function()
        for (uint256 i = 0; i < collectionIds.length; i++) {
            bool success = _processColonyChangeInternal(colonyId, collectionIds[i], tokenIds[i], true);
            if (success) {
                successCount++;
            }
        }
        
        emit MembersSynchronized(colonyId, collectionIds.length, successCount);
        return successCount;
    }

    /**
     * @notice Get staking bonus for a colony
     * @param colonyId Colony ID
     * @return bonus Staking bonus percentage
     */
    function getStakingColonyBonus(bytes32 colonyId) external view returns (uint256) {
        if (colonyId == bytes32(0)) {
            return 0;
        }
        
        // First check in our own storage
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // First try the unified structure
        if (ss.colonies[colonyId].active) {
            uint256 _bonus = ss.colonies[colonyId].stakingBonus;
            if (_bonus > 0) {
                return _bonus;
            }
        }
        
        // Then try the separated field
        uint256 bonus = ss.colonyStakingBonuses[colonyId];
        if (bonus > 0) {
            return bonus;
        }
        
        // If not found in our storage, check ColonyFacet
        address chargepodAddress = ss.chargeSystemAddress;
        if (chargepodAddress != address(0)) {
            try IColonyFacet(chargepodAddress).getStakingBonus(colonyId) returns (uint256 podBonus) {
                return podBonus;
            } catch {
                // Ignore errors
            }
        }
        
        // Default bonus (5%) if not found anywhere
        return 5;
    }
    
    /**
     * @notice Get colony for a token
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return colonyId Colony ID
     */
    function getSpecimenColony(uint256 collectionId, uint256 tokenId) external view returns (bytes32) {
        // Check our local tracking in StakedSpecimen
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        // CHANGE: For staked tokens, always use local state
        if (staked.staked) {
            return staked.colonyId; // Return local value, even if it's zero
        }
        
        // Check pending assignment for non-staked tokens
        bytes32 pendingColony = ss.tokenPendingColonyAssignments[combinedId];
        if (pendingColony != bytes32(0)) {
            return pendingColony;
        }
        
        // Finally, if token is not staked and has no pending assignment,
        // check in Chargepod
        address chargepodAddress = ss.chargeSystemAddress;
        if (chargepodAddress != address(0)) {
            try IColonyFacet(chargepodAddress).getTokenColony(collectionId, tokenId) returns (bytes32 podColonyId) {
                return podColonyId;
            } catch {
                // Return zero if retrieval fails
            }
        }
        
        return bytes32(0);
    }

    /**
     * @notice Check if a token is in a colony
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return inColony Whether token is in a colony
     */
    function isInColony(uint256 collectionId, uint256 tokenId) external view returns (bool) {
        bytes32 colonyId = this.getSpecimenColony(collectionId, tokenId);
        return colonyId != bytes32(0);
    }
    
    /**
     * @notice Apply colony bonus to staking calculations
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param baseAmount Base amount to apply bonus to
     * @return bonusAmount Additional amount from colony bonus
     */
    function applyColonyBonus(
        address,
        uint256 collectionId,
        uint256 tokenId,
        uint256 baseAmount
    ) external view returns (uint256 bonusAmount) {
        // Get colony for token
        bytes32 colonyId = this.getSpecimenColony(collectionId, tokenId);
        if (colonyId == bytes32(0)) {
            return 0; // No colony, no bonus
        }
        
        // Get bonus percentage
        uint256 bonusPercentage = this.getStakingColonyBonus(colonyId);
        if (bonusPercentage == 0) {
            return 0; // No bonus percentage, no bonus
        }
        
        // Calculate bonus amount
        return (baseAmount * bonusPercentage) / 100;
    }

    /**
     * @dev Internal implementation of notifyColonyChange without authorization checks
     * @param colonyId Colony ID
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param isJoining Whether specimen is joining or leaving colony
     * @return success Whether operation was successful
     */
    function _processColonyChangeInternal(
        bytes32 colonyId,
        uint256 collectionId,
        uint256 tokenId,
        bool isJoining
    ) private returns (bool success) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        // Get reference to staked specimen
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        // Update local tracking data - keep minimal colony data for staking calculations
        if (isJoining) {
            // Token is joining a colony
            
            // Add token to colony members list if not already there
            bool alreadyInColony = false;
            uint256[] storage members = ss.colonyMembers[colonyId];
            
            for (uint256 i = 0; i < members.length; i++) {
                if (members[i] == combinedId) {
                    alreadyInColony = true;
                    break;
                }
            }
            
            if (!alreadyInColony) {
                members.push(combinedId);
                
                // Update colony stats
                ss.colonyStats[colonyId].memberCount = members.length;
                
                // Also update the unified structure
                ss.colonies[colonyId].stats.memberCount = members.length;
                
                // Set colony as active if it wasn't
                if (!ss.colonyActive[colonyId]) {
                    ss.colonyActive[colonyId] = true;
                }
            }
            
            // CORE OF THE SOLUTION: Update colony assignment
            // This addresses both new tokens and colony creation
            if (staked.staked) {
                // For staked tokens, directly update colonyId
                // This ensures the token is properly registered even during colony creation
                staked.colonyId = colonyId;
                staked.lastSyncTimestamp = uint32(block.timestamp);
            } else {
                // For non-staked tokens, store pending assignment
                ss.tokenPendingColonyAssignments[combinedId] = colonyId;
            }
            
            emit SpecimenJoinedColony(collectionId, tokenId, colonyId);
        } else {
            // Token is leaving a colony
            
            // Clean up any pending assignments first
            delete ss.tokenPendingColonyAssignments[combinedId];
            
            // Remove from colony members
            uint256[] storage members = ss.colonyMembers[colonyId];
            
            for (uint256 i = 0; i < members.length; i++) {
                if (members[i] == combinedId) {
                    // Replace with last element and pop
                    members[i] = members[members.length - 1];
                    members.pop();
                    
                    // Update colony stats
                    ss.colonyStats[colonyId].memberCount = members.length;
                    
                    // Also update the unified structure
                    ss.colonies[colonyId].stats.memberCount = members.length;
                    
                    break;
                }
            }
            
            // IMPROVED HANDLING: For staked tokens, clear colony association
            if (staked.staked) {
                // Only clear if token has a colony association
                if (staked.colonyId != bytes32(0)) {
                    // Check for inconsistency but still proceed with clearing
                    if (staked.colonyId != colonyId) {
                        emit OperationResult("ColonyIdInconsistency", false);
                    }
                    
                    // Clear colony association
                    staked.colonyId = bytes32(0);
                    staked.lastSyncTimestamp = uint32(block.timestamp);
                }
            }
            
            emit SpecimenLeftColony(collectionId, tokenId, colonyId);
        }
        
        // Try to sync with Biopod for updated stats if token is staked
        if (staked.staked) {
            address biopodModule = ss.internalModules.biopodModuleAddress;
            if (biopodModule != address(0)) {
                try IStakingBiopodFacet(biopodModule).syncBiopodData(collectionId, tokenId) {
                    emit OperationResult("BiopodSync", true);
                } catch {
                    emit OperationResult("BiopodSync", false);
                }
            }
        }
        
        return true;
    }

    /**
     * @notice Dedicated function to clean invalid colony references
     * @dev This function's sole responsibility is fixing data inconsistencies
     * @return cleanedCount Number of tokens with fixed colony references
     */
    function cleanInvalidColonyReferences() external nonReentrant returns (uint256 cleanedCount) {
        address sender = LibMeta.msgSender();
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Rate limit to prevent abuse
        if (!AccessHelper.enforceRateLimit(sender, this.cleanInvalidColonyReferences.selector, 2, 1 hours)) {
            revert AccessHelper.RateLimitExceeded(sender, this.cleanInvalidColonyReferences.selector);
        }
        
        // Get all tokens for the staker
        uint256[] storage tokens = ss.stakerTokens[sender];
        cleanedCount = 0;
        
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 combinedId = tokens[i];
            StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
            
            // Skip if token is not staked or not owned by sender
            if (!staked.staked || staked.owner != sender) {
                continue;
            }
            
            // Only check tokens with colony references
            if (staked.colonyId != bytes32(0)) {
                bool validColony = LibStakingStorage.isColonyValid(ss, staked.colonyId);
                
                if (!validColony) {
                    // Store the invalid colony ID for event
                    bytes32 invalidColonyId = staked.colonyId;
                    
                    // Clear invalid reference
                    staked.colonyId = bytes32(0);
                    staked.lastSyncTimestamp = uint32(block.timestamp);
                    cleanedCount++;
                    
                    // Extract collection and token ids for event
                    (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);
                    
                    // Emit event for each cleaned reference
                    emit TokenColonyReferenceFixed(collectionId, tokenId, invalidColonyId);
                }
            }
        }
        
        // Emit summary event
        if (cleanedCount > 0) {
            emit TokenDataCleaned(cleanedCount, "Colony references cleaned");
        }
        
        return cleanedCount;
    }

    /**
     * @notice Add token to colony members if not already present
     * @param colonyId Colony ID
     * @param combinedId Combined token ID
     * @return added Whether token was added
     */
    function _addTokenToColonyMembers(bytes32 colonyId, uint256 combinedId) private returns (bool added) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256[] storage members = ss.colonyMembers[colonyId];
        
        // Check if token is already in colony
        for (uint256 i = 0; i < members.length; i++) {
            if (members[i] == combinedId) {
                return false; // Already a member
            }
        }
        
        // Add to colony members
        members.push(combinedId);
        
        // Update colony stats
        ss.colonyStats[colonyId].memberCount = members.length;
        ss.colonies[colonyId].stats.memberCount = members.length;
        
        return true;
    }

    /**
     * @notice Remove invalid tokens from colony members
     * @param colonyId Colony ID
     * @param validMemberIds Array of valid member IDs
     * @return removedCount Number of tokens removed
     */
    function _removeInvalidColonyMembers(bytes32 colonyId, uint256[] memory validMemberIds) private returns (uint256 removedCount) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256[] storage members = ss.colonyMembers[colonyId];
        
        removedCount = 0;
        uint256 i = 0;
        
        while (i < members.length) {
            uint256 combinedId = members[i];
            bool isValid = false;
            
            // Check if member is in validMemberIds
            for (uint256 j = 0; j < validMemberIds.length; j++) {
                if (validMemberIds[j] == combinedId) {
                    isValid = true;
                    break;
                }
            }
            
            if (!isValid) {
                // Remove invalid member
                members[i] = members[members.length - 1];
                members.pop();
                removedCount++;
                
                // Clear colony association in staked specimen if necessary
                StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
                if (staked.staked && staked.colonyId == colonyId) {
                    staked.colonyId = bytes32(0);
                    staked.lastSyncTimestamp = uint32(block.timestamp);
                }
                
                // Don't increment i since we swapped a new element into this position
            } else {
                i++;
            }
        }
        
        // Update colony stats if tokens were removed
        if (removedCount > 0) {
            ss.colonyStats[colonyId].memberCount = members.length;
            ss.colonies[colonyId].stats.memberCount = members.length;
        }
        
        return removedCount;
    }

    /**
     * @notice Remove token from all colonies except the specified one
     * @param combinedId Combined token ID
     * @param validColonyId Colony ID to keep token in
     */
    function _removeTokenFromOtherColonies(uint256 combinedId, bytes32 validColonyId) private {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        for (uint256 i = 0; i < ss.allColonyIds.length; i++) {
            bytes32 colonyId = ss.allColonyIds[i];
            if (colonyId == validColonyId || !ss.colonyActive[colonyId]) {
                continue;
            }
            
            uint256[] storage members = ss.colonyMembers[colonyId];
            
            for (uint256 j = 0; j < members.length; j++) {
                if (members[j] == combinedId) {
                    // Remove token from this colony
                    members[j] = members[members.length - 1];
                    members.pop();
                    
                    // Update colony stats
                    ss.colonyStats[colonyId].memberCount = members.length;
                    ss.colonies[colonyId].stats.memberCount = members.length;
                    
                    break;
                }
            }
        }
    }

    /**
     * @notice Clear all colony assignments for a token
     * @param combinedId Combined token ID
     */
    function _clearAllColonyAssignments(uint256 combinedId) private {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Clear pending assignment
        delete ss.tokenPendingColonyAssignments[combinedId];
        
        // Clear staked specimen colony if token is staked
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        if (staked.staked && staked.colonyId != bytes32(0)) {
            staked.colonyId = bytes32(0);
            staked.lastSyncTimestamp = uint32(block.timestamp);
        }
        
        // Remove from all colony member lists
        for (uint256 i = 0; i < ss.allColonyIds.length; i++) {
            bytes32 colonyId = ss.allColonyIds[i];
            if (!ss.colonyActive[colonyId]) {
                continue;
            }
            
            uint256[] storage members = ss.colonyMembers[colonyId];
            
            for (uint256 j = 0; j < members.length; j++) {
                if (members[j] == combinedId) {
                    // Remove token from this colony
                    members[j] = members[members.length - 1];
                    members.pop();
                    
                    // Update colony stats
                    ss.colonyStats[colonyId].memberCount = members.length;
                    ss.colonies[colonyId].stats.memberCount = members.length;
                    
                    break;
                }
            }
        }
    }
     
    /**
     * @notice Check if caller is the Chargepod system
     * @return isChargepod Whether caller is the Chargepod system
     */
    function _isFromChargepod() internal view returns (bool) {
        // Use LibMeta.msgSender() instead of msg.sender to support delegated calls
        address sender = LibMeta.msgSender();
        address chargepodAddress = LibStakingStorage.stakingStorage().chargeSystemAddress;
        return chargepodAddress != address(0) && sender == chargepodAddress;
    }

    /**
     * @notice Require caller to be the Chargepod system
     */
    function _onlyChargepod() internal view {
        if (!_isFromChargepod() && !AccessHelper.isInternalCall()) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Only Chargepod system can access this function");
        }
    }
}