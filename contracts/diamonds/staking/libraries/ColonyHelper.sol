// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "./LibHenomorphsStorage.sol";
import {LibStakingStorage} from "./LibStakingStorage.sol";
import {PodsUtils} from "../../libraries/PodsUtils.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SpecimenCollection, ColonyCriteria, PowerMatrix} from "../../libraries/HenomorphsModel.sol"; 
import {LibDiamond} from "../../shared/libraries/LibDiamond.sol";
import {AccessHelper} from "./AccessHelper.sol";
import {IStakingSystem, IChargeFacet, IExternalCollection, IStakingCoreFacet} from "../interfaces/IStakingInterfaces.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {StakedSpecimen} from "../../libraries/StakingModel.sol";

/**
 * @title ColonyHelper
 * @notice Library with helper functions for colony management
 * @dev Enhanced with additional colony management functionalities and optimized for gas efficiency
 * @author rutilicus.eth (ArchXS)
 */
library ColonyHelper {
    uint8 constant MAX_COLONY_CAPACITY = 40;

    // Events
    event OperationResult(string operation, bool success);
    event OperationError(string operation, string errorMessage);
    event ColonyIdGenerated(bytes32 indexed colonyId, uint256 randomSeed);
    event MembersSynchronized(bytes32 indexed colonyId, uint256 batchSize, uint256 successCount);
    event ColonySynchronized(bytes32 indexed colonyId, bool stakingSystemUpdated);

    // Errors
    error HenomorphControlForbidden(uint256 collectionId, uint256 tokenId);
    error HenomorphAlreadyInColony();
    error HenomorphNotInColony();
    error InvalidCallData();
    error ForbiddenRequest();
    error ColonyDoesNotExist(bytes32 colonyId);
    error CollectionNotEnabled(uint256 collectionId);
    error InvalidColonyName();
    error ColonyNameTaken();
    error MaxColonyMembersReached();
    error TokenNotEligible();
    error InvalidParameterValue(string paramName, string reason);
    error InsufficientLevel(uint8 required, uint8 actual);
    error InsufficientVariant(uint8 required, uint8 actual);
    error WrongSpecialization(uint8 required, uint8 actual);
    error InvalidVariantRange();
    
    struct ColonyRegistryItem {
        bytes32 colonyId;
        string name;
        address creator;
        uint256 memberCount;
        bool requiresApproval;
    }
    
    struct PendingRequests {
        uint256[] collectionIds;
        uint256[] tokenIds;
        address[] requesters;
    }

    /**
     * @dev Check if colony exists based on registered name
     * @param colonyId Colony ID to check
     * @return exists Whether the colony exists
     */
    function colonyExists(bytes32 colonyId) internal view returns (bool exists) {
        return bytes(LibHenomorphsStorage.henomorphsStorage().colonyNamesById[colonyId]).length > 0;
    }

    /**
     * @dev Verify colony exists or revert with proper error
     * @param colonyId Colony ID to verify
     */
    function requireColonyExists(bytes32 colonyId) internal view {
        if (!colonyExists(colonyId)) {
            revert ColonyDoesNotExist(colonyId);
        }
    }

    /**
     * @dev Checks if caller has control over the henomorph token
     */
    function checkHenomorphControl(
        uint256 collectionId, 
        uint256 tokenId, 
        address stakingListener
    ) internal view {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Basic validations
        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            revert InvalidCallData();
        }
        
        SpecimenCollection storage _collection = hs.specimenCollections[collectionId];
        if (!_collection.enabled) {
            revert CollectionNotEnabled(collectionId);
        }
        
        // Check if caller is owner or operator
        address sender = LibMeta.msgSender();
        if (sender == LibDiamond.contractOwner() || hs.operators[sender]) {
            return; // Owner or Operators can control any henomorph
        }
        
        // FIRST CHECK: Check if token is staked and caller is the staker
        if (stakingListener != address(0)) {
            try IStakingSystem(stakingListener).isSpecimenStaked(collectionId, tokenId) returns (bool isStaked) {
                if (isStaked) {
                    try IStakingSystem(stakingListener).isTokenStaker(collectionId, tokenId, sender) returns (bool isStaker) {
                        if (isStaker) {
                            return; // User is staker of this token
                        }
                    } catch {
                        // Fall through to direct ownership check
                    }
                }
            } catch {
                // Fall through to normal ownership check if staking check fails
            }
        }
        
        // SECOND CHECK: Only perform direct ownership check if token is NOT staked
        address owner = getTokenOwner(collectionId, tokenId);
        if (owner == address(0) || owner != sender) {
            revert HenomorphControlForbidden(collectionId, tokenId);
        }
    }

    /**
     * @dev Retrieves the owner of a token from the collection
     */
    function getTokenOwner(uint256 collectionId, uint256 tokenId) internal view returns (address) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        address stakingListener = hs.stakingSystemAddress;
        
        // Single try-catch for staking check - if token is staked, get staker directly
        if (stakingListener != address(0)) {
            try IStakingCoreFacet(stakingListener).getStakedTokenData(collectionId, tokenId) returns (StakedSpecimen memory stakedData) {
                if (stakedData.staked && stakedData.owner != address(0)) {
                    return stakedData.owner;
                }
            } catch {
                // Fall through to NFT owner
            }
        }
        
        // Get NFT owner
        try IERC721(hs.specimenCollections[collectionId].collectionAddress).ownerOf(tokenId) returns (address nftOwner) {
            return nftOwner;
        } catch {
            return address(0);
        }
    }
    
    /**
     * @dev Check if a colony with the given name already exists
     * @param colonyName Colony name
     * @return exists Whether colony exists
     * @return nameHash Hash of the colony name
     */
    function checkColonyNameExists(string memory colonyName) internal view returns (bool exists, bytes32 nameHash) {
        // Validate the colony name (3-50 chars)
        if (bytes(colonyName).length < 3 || bytes(colonyName).length > 50) {
            revert InvalidColonyName();
        }
        
        // Check if name is already taken
        nameHash = keccak256(abi.encodePacked(colonyName));
        string memory existingColony = LibHenomorphsStorage.henomorphsStorage().colonyNames[nameHash];
        exists = bytes(existingColony).length > 0;
        
        return (exists, nameHash);
    }

    /**
     * @dev Check if token can be added to a colony
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param colonyId Target colony ID
     * @param stakingListener Staking listener address
     * @return combinedId Combined token ID
     */
    function checkTokenEligibility(
        uint256 collectionId, 
        uint256 tokenId,
        bytes32 colonyId, 
        address stakingListener
    ) internal view returns (uint256 combinedId) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        combinedId = PodsUtils.combineIds(collectionId, tokenId);

        // Validate variant is within range (1-4) similar to staking
        uint8 variant = getSpecimenVariant(collectionId, tokenId);
        if (variant < 1 || variant > 4) {
            revert InvalidVariantRange();
        }
        
        // Check if token is already in a colony
        bytes32 currentColony = hs.specimenColonies[combinedId];
        if (currentColony != bytes32(0)) {
            // If token is already in this same colony, that's fine
            if (colonyId != bytes32(0) && currentColony == colonyId) {
                return combinedId;
            }
            revert HenomorphAlreadyInColony();
        }
        
        // Check power core status for eligibility
        if (!_checkTokenPowerCoreStatus(collectionId, tokenId, stakingListener)) {
            revert TokenNotEligible();
        }
        
        return combinedId;
    }

    /**
     * @dev Internal function to check token's power core status
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param stakingListener Staking system address
     * @return isEligible Whether token is eligible
     */
    function _checkTokenPowerCoreStatus(
        uint256 collectionId,
        uint256 tokenId,
        address stakingListener
    ) private view returns (bool isEligible) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        // Check if power core is activated in Chargepod
        if (hs.performedCharges[combinedId].lastChargeTime != 0) {
            return true;
        }
        
        // If not eligible by power core, check staking as a fallback
        if (stakingListener != address(0)) {
            try IStakingSystem(stakingListener).isSpecimenStaked(collectionId, tokenId) returns (bool _isStaked) {
                return _isStaked;
            } catch {
                // Ignore errors from staking system
            }
        }
        
        return false;
    }

    /**
     * @dev Find colony name hash from colony ID
     * @param colonyId Colony ID
     * @return nameHash Hash of the colony name
     * @return colonyName Colony name
     */
    function findColonyNameHash(bytes32 colonyId) internal view returns (bytes32 nameHash, string memory colonyName) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // First try direct lookup from colony name storage - this is the optimized path
        string memory name = hs.colonyNamesById[colonyId];
        if (bytes(name).length > 0) {
            return (colonyId, name);
        }
        
        // Fall back to legacy enumeration method
        uint256 maxIterations = type(uint8).max;
        
        for (uint256 i = 0; i < maxIterations; i++) {
            bytes32 testHash = bytes32(i);
            string memory testName = hs.colonyNames[testHash];
            
            if (bytes(testName).length > 0) {
                // Try to reconstruct the colony ID
                bytes32 reconstructedId = keccak256(abi.encodePacked(
                    testName, 
                    hs.colonyCreators[colonyId],
                    colonyId
                ));
                
                // If we find a match, return it
                if (reconstructedId == colonyId) {
                    return (testHash, testName);
                }
            }
        }
        
        return (bytes32(0), "");
    }

    /**
     * @dev Check if caller is authorized to manage a colony
     * @param colonyId Colony ID
     * @param stakingListener Optional staking listener address
     * @return isAuthorized Whether caller is authorized
     */
    function isAuthorizedForColony(
        bytes32 colonyId, 
        address stakingListener
    ) internal view returns (bool isAuthorized) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        address sender = LibMeta.msgSender();
        
        // Super-user checks - these are gas-efficient and should be first
        // Owner or operator can manage any colony
        if (sender == LibDiamond.contractOwner() || hs.operators[sender]) {
            return true;
        }
        
        // External systems with special permissions
        if (stakingListener != address(0) && sender == stakingListener) {
            return true;
        }
        
        // Check if sender is the colony creator (works for both empty and non-empty colonies)
        // This check is efficient and important, especially for empty colonies
        if (hs.colonyCreators[colonyId] == sender) {
            return true;
        }
        
        // Member ownership checks - only relevant for non-empty colonies
        // Get colony members array reference (storage, not memory to save gas)
        uint256[] storage members = hs.colonies[colonyId];
        
        // Iterate through colony members (no iteration for empty colonies)
        for (uint256 i = 0; i < members.length; i++) {
            (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(members[i]);
            
            // Check NFT ownership - external call, more expensive
            SpecimenCollection storage collection = hs.specimenCollections[collectionId];
            try IERC721(collection.collectionAddress).ownerOf(tokenId) returns (address owner) {
                if (owner == sender) {
                    return true;
                }
            } catch {
                // Ignore errors and continue checking
            }
            
            // Check staking ownership if integrated - external call, most expensive
            if (stakingListener != address(0)) {
                try IStakingSystem(stakingListener).isTokenStaker(collectionId, tokenId, sender) returns (bool isStaker) {
                    if (isStaker) {
                        return true;
                    }
                } catch {
                    // Ignore errors and continue checking
                }
            }
        }
        
        // If we get here, authorization failed
        return false;
    }

    /**
     * @dev Check if caller is the original creator of the colony
     * @dev Used for critical operations like season registration, stake changes
     */
    function isColonyCreator(
        bytes32 colonyId, 
        address stakingListener
    ) internal view returns (bool isAuthorized) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        address sender = LibMeta.msgSender();
        
        // Super-user checks
        if (sender == LibDiamond.contractOwner() || hs.operators[sender]) {
            return true;
        }
        
        // External systems
        if (stakingListener != address(0) && sender == stakingListener) {
            return true;
        }
        
        // Only colony creator can perform ownership operations
        return hs.colonyCreators[colonyId] == sender;
    }

    /**
     * @dev Process colony membership change for a token
     * @param colonyId Colony ID
     * @param combinedId Combined token ID
     * @param isJoining Whether token is joining (true) or leaving (false)
     * @return success Whether operation was successful
     */
    function processColonyMembershipChange(
        bytes32 colonyId, 
        uint256 combinedId, 
        bool isJoining,
        address stakingSystemAddress
    ) internal returns (bool success) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Extract IDs for events and update power core
        (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);
        
        if (isJoining) {
            // CRITICAL FIX: Check if token already exists in colony using index
            uint256 existingIndex = hs.colonyMemberIndices[colonyId][combinedId];
            if (existingIndex > 0) {
                // Token already in colony - verify consistency and skip adding
                hs.specimenColonies[combinedId] = colonyId; // Ensure association is set
                emit OperationResult("TokenAlreadyInColony", true);
                // Skip adding to array - already present
            } else {
                // Token not in colony - add it
                uint256 newIndex = hs.colonies[colonyId].length;
                hs.colonies[colonyId].push(combinedId);
                // Store index (1-based to distinguish from 0)
                hs.colonyMemberIndices[colonyId][combinedId] = newIndex + 1;
                hs.specimenColonies[combinedId] = colonyId;
            }
        } else {
            // MODIFIED removal code - fixes the main issue
            uint256 storedIndexPlusOne = hs.colonyMemberIndices[colonyId][combinedId];
            
            if (storedIndexPlusOne > 0) { // If index exists (1-based)
                uint256 storedIndex = storedIndexPlusOne - 1;
                uint256[] storage _colonyMembers = hs.colonies[colonyId];
                
                // Validate index
                if (storedIndex < _colonyMembers.length) {
                    // Get last index
                    uint256 lastIndex = _colonyMembers.length - 1;
                    
                    // If not the last element, swap with last
                    if (storedIndex < lastIndex) {
                        uint256 lastMemberId = _colonyMembers[lastIndex];
                        _colonyMembers[storedIndex] = lastMemberId;
                        // Update index of the moved element
                        hs.colonyMemberIndices[colonyId][lastMemberId] = storedIndexPlusOne;
                    }
                    
                    // Remove last element
                    _colonyMembers.pop();
                    
                    // Clear index
                    delete hs.colonyMemberIndices[colonyId][combinedId];
                }
            } else {
                // If token has no index, emit event for debugging purposes
                emit OperationError("ColonyLeave", string(abi.encodePacked(
                    "Token has no index in colony. CollectionId: ", 
                    Strings.toString(collectionId), 
                    ", TokenId: ", 
                    Strings.toString(tokenId)
                )));
                
                // Try to manually find the token in array and remove it (fallback)
                uint256[] storage _colonyMembers = hs.colonies[colonyId];
                for (uint256 i = 0; i < _colonyMembers.length; i++) {
                    if (_colonyMembers[i] == combinedId) {
                        // Found the token, remove it by swapping with last element
                        _colonyMembers[i] = _colonyMembers[_colonyMembers.length - 1];
                        _colonyMembers.pop();
                        emit OperationResult("ManualTokenRemoval", true);
                        break;
                    }
                }
            }
            
            // KEY CHANGE: ALWAYS clear the token's colony association, regardless of index
            delete hs.specimenColonies[combinedId];
        }
        
        // Rest of existing code without changes...
        address chargeModule = hs.internalModules.chargeModuleAddress;
        if (chargeModule != address(0)) {
            try IChargeFacet(chargeModule).recalibrateCore(collectionId, tokenId) {
                emit OperationResult("CoreRecalibration", true);
            } catch Error(string memory reason) {
                emit OperationError("CoreRecalibration", reason);
            } catch {
                emit OperationResult("CoreRecalibration", false);
            }
        }
        
        // Notify staking system with unified method
        notifyColonyMembershipChange(collectionId, tokenId, colonyId, isJoining, stakingSystemAddress);
        
        return true;
    }

    /**
     * @notice Checks remaining capacity in a colony
     * @param colonyId Colony ID to check
     * @return remaining Number of remaining spots in the colony
     * @return atCapacity Whether the colony is at full capacity
     */
    function checkColonyCapacity(bytes32 colonyId) internal view returns (uint256 remaining, bool atCapacity) {
        uint256 currentSize = LibHenomorphsStorage.henomorphsStorage().colonies[colonyId].length;
        
        if (currentSize >= MAX_COLONY_CAPACITY) {
            return (0, true);
        }
        
        return (MAX_COLONY_CAPACITY - currentSize, false);
    }
    
    /**
     * @dev Create colony structure without processing members or notifying staking
     * @dev Used to reduce contract size in ColonyFacet
     */
    function createColonyStructure(
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds,
        string calldata colonyName,
        address stakingSystemAddress
    ) internal returns (bytes32 colonyId) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Generate randomized seed with better entropy 
        uint256 randomSeed = uint256(keccak256(abi.encodePacked(
            blockhash(block.number - 1) != bytes32(0) ? blockhash(block.number - 1) : bytes32(uint256(1)),
            block.timestamp,
            LibMeta.msgSender(),
            hs.lastColonyId,
            colonyName
        )));
        
        // Generate colony ID
        colonyId = keccak256(abi.encodePacked(colonyName, LibMeta.msgSender(), block.timestamp, randomSeed));
        
        // Validate tokens and create combined IDs
        uint256[] memory combinedIds = new uint256[](collectionIds.length);
        for (uint256 i = 0; i < collectionIds.length; i++) {
            checkHenomorphControl(collectionIds[i], tokenIds[i], stakingSystemAddress);
            combinedIds[i] = checkTokenEligibility(collectionIds[i], tokenIds[i], colonyId, stakingSystemAddress);
        }
        
        // Calculate name hash
        bytes32 nameHash = keccak256(abi.encodePacked(colonyName));
        
        // Save colony information
        hs.colonies[colonyId] = combinedIds;
        hs.colonyNames[nameHash] = colonyName;
        hs.colonyNamesById[colonyId] = colonyName;
        hs.colonyChargePools[colonyId] = 0;
        hs.colonyStakingBonuses[colonyId] = 5;
        hs.lastColonyId = colonyId;
        
        // Register colony to creator
        address creator = LibMeta.msgSender();
        hs.userColonies[creator].push(colonyId);
        hs.colonyCreators[colonyId] = creator;
        
        // Set default join criteria
        hs.colonyCriteria[colonyId].minLevel = 0;
        hs.colonyCriteria[colonyId].minVariant = 1;
        hs.colonyCriteria[colonyId].requiredSpecialization = 0;
        hs.colonyCriteria[colonyId].requiresApproval = false;
        
        emit ColonyIdGenerated(colonyId, randomSeed);
        
        return colonyId;
    }

    /**
     * @dev Notifies staking system about colony membership change
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param colonyId Colony ID
     * @param isJoining Whether token is joining the colony
     * @param stakingSystemAddress Staking system address
     * @return success Whether operation was successful
     */
    function notifyColonyMembershipChange(
        uint256 collectionId,
        uint256 tokenId,
        bytes32 colonyId,
        bool isJoining,
        address stakingSystemAddress
    ) internal returns (bool success) {
        if (stakingSystemAddress == address(0)) {
            return false;
        }
        
        // Try to use unified method first
        try IStakingSystem(stakingSystemAddress).notifyColonyChange(colonyId, collectionId, tokenId, isJoining) returns (bool result) {
            emit OperationResult(isJoining ? "SpecimenJoinNotification" : "SpecimenLeaveNotification", true);
            return result;
        } catch {
            // Fall back to legacy methods if unified method fails
            if (isJoining) {
                try IStakingSystem(stakingSystemAddress).notifySpecimenJoinedColony(collectionId, tokenId, colonyId) {
                    emit OperationResult("SpecimenJoinNotification", true);
                    return true;
                } catch {
                    emit OperationResult("SpecimenJoinNotification", false);
                    return false;
                }
            } else {
                try IStakingSystem(stakingSystemAddress).notifySpecimenLeftColony(collectionId, tokenId, colonyId) {
                    emit OperationResult("SpecimenLeaveNotification", true);
                    return true;
                } catch {
                    emit OperationResult("SpecimenLeaveNotification", false);
                    return false;
                }
            }
        }
    }

    /**
     * @dev Batch notify colony members with improved reliability
     * @param colonyId Colony ID
     * @param collectionIds Array of collection IDs
     * @param tokenIds Array of token IDs
     * @param stakingSystemAddress Staking system address
     * @return successCount Number of successful notifications
     */
    function batchNotifyColonyMembers(
        bytes32 colonyId, 
        uint256[] memory collectionIds, 
        uint256[] memory tokenIds,
        address stakingSystemAddress
    ) internal returns (uint256 successCount) {
        if (stakingSystemAddress == address(0) || collectionIds.length != tokenIds.length || collectionIds.length == 0) {
            return 0;
        }
        
        successCount = 0;
        
        // CRITICAL CHANGE: Notify tokens one by one instead of in batches
        // This avoids batch processing entirely which seems to be failing
        for (uint256 i = 0; i < collectionIds.length; i++) {
            // Try direct unified method first
            bool success = false;
            
            try IStakingSystem(stakingSystemAddress).notifyColonyChange(
                colonyId,
                collectionIds[i],
                tokenIds[i],
                true // isJoining = true
            ) returns (bool result) {
                if (result) {
                    successCount++;
                    success = true;
                }
            } catch {
                // Failed with unified method, try legacy method
                try IStakingSystem(stakingSystemAddress).notifySpecimenJoinedColony(
                    collectionIds[i],
                    tokenIds[i],
                    colonyId
                ) {
                    successCount++;
                    success = true;
                } catch {
                    // Both methods failed, log the failure
                    emit OperationError("MemberNotification", 
                        string(abi.encodePacked(
                            "Failed for token: ", 
                            Strings.toString(collectionIds[i]), 
                            "/",
                            Strings.toString(tokenIds[i])
                        ))
                    );
                }
            }
            
            // Log individual result
            if (success) {
                emit OperationResult(
                    string(abi.encodePacked(
                        "MemberNotification_",
                        Strings.toString(collectionIds[i]),
                        "_",
                        Strings.toString(tokenIds[i])
                    )),
                    true
                );
            }
        }
        
        emit MembersSynchronized(colonyId, collectionIds.length, successCount);
        return successCount;
    }

    /**
     * @dev Synchronize colony with staking system - simplified version
     * @param colonyId Colony ID
     * @param colonyName Colony name
     * @param creator Colony creator
     * @param stakingSystemAddress Address of staking system
     * @return success Whether synchronization was successful
     */
    function syncColonyWithStaking(
        bytes32 colonyId,
        string memory colonyName,
        address creator,
        address stakingSystemAddress
    ) internal returns (bool success) {
        if (stakingSystemAddress == address(0)) {
            return false;
        }
        
        // Notify about colony creation using more robust error handling
        try IStakingSystem(stakingSystemAddress).notifyColonyCreated(
            colonyId, colonyName, creator
        ) {
            emit OperationResult("ColonyCreationSync", true);
            return true;
        } catch Error(string memory reason) {
            emit OperationError("ColonyCreationSync", reason);
            return false;
        } catch {
            emit OperationResult("ColonyCreationSync", false);
            return false;
        }
    }
        
    /**
     * @dev Safely recalibrate power core
     */
    function safeRecalibrateCore(uint256 collectionId, uint256 tokenId) internal {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        address chargeModule = hs.internalModules.chargeModuleAddress;
        
        if (chargeModule == address(0)) {
            return;
        }
        
        try IChargeFacet(chargeModule).recalibrateCore(collectionId, tokenId) returns (uint256) {
            emit OperationResult("CoreRecalibration", true);
        } catch Error(string memory reason) {
            emit OperationError("CoreRecalibration", reason);
        } catch {
            emit OperationResult("CoreRecalibration", false);
        }
    }
    
    /**
     * @dev Check join criteria eligibility with enforced variant validation
     */
    function checkJoinCriteriaEligibility(
        uint256 collectionId, 
        uint256 tokenId, 
        bytes32 colonyId,
        address stakingSystemAddress
    ) internal view {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        ColonyCriteria storage criteria = hs.colonyCriteria[colonyId];
        
        // Always validate variant range (similar to staking system)
        uint8 variant = getSpecimenVariant(collectionId, tokenId);
        if (variant < 1 || variant > 4) {
            revert InvalidVariantRange();
        }
        
        // Skip if no other criteria
        if (criteria.minLevel == 0 && criteria.minVariant == 0 && criteria.requiredSpecialization == 0) {
            return;
        }
        
        // Check level if needed
        if (criteria.minLevel > 0) {
            uint8 level = getSpecimenLevel(collectionId, tokenId, stakingSystemAddress);
            if (level < criteria.minLevel) {
                revert InsufficientLevel(criteria.minLevel, level);
            }
        }
        
        // Check variant against colony criteria (additional to global check)
        if (criteria.minVariant > 0) {
            if (variant < criteria.minVariant) {
                revert InsufficientVariant(criteria.minVariant, variant);
            }
        }
        
        // Check specialization if needed
        if (criteria.requiredSpecialization > 0) {
            uint8 specialization = getSpecimenSpecialization(collectionId, tokenId);
            if (specialization != criteria.requiredSpecialization) {
                revert WrongSpecialization(criteria.requiredSpecialization, specialization);
            }
        }
    }
    
    /**
     * @dev Get specimen level from staking or charge system
     */
    function getSpecimenLevel(uint256 collectionId, uint256 tokenId, address stakingSystemAddress) internal view returns (uint8 level) {
        // Try staking system first
        if (stakingSystemAddress != address(0)) {
            try IStakingSystem(stakingSystemAddress).getSpecimenLevel(collectionId, tokenId) returns (uint8 specLevel) {
                return specLevel;
            } catch {}
        }
        
        // Fall back to charge system if level still 0
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
     * @dev Get specimen variant from staking system
     */
    function getSpecimenVariant(uint256 collectionId, uint256 tokenId) internal view returns (uint8 variant) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        
        try IExternalCollection(collection.collectionAddress).itemVariant(tokenId) returns (uint8 v) {
            variant = v;
        } catch {
            // Set a default variant if retrieval fails
            variant = 0;
        }
        
        return variant;
    }

    /**
     * @dev Get specimen specialization from charge system
     */
    function getSpecimenSpecialization(uint256 collectionId, uint256 tokenId) internal view returns (uint8 specialization) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        address chargeModule = hs.internalModules.chargeModuleAddress;
        
        if (chargeModule != address(0)) {
            try IChargeFacet(chargeModule).getSpecimenData(collectionId, tokenId) returns (
                uint256, uint256, uint256, uint8 spec, uint256
            ) {
                return spec;
            } catch {}
        }
        
        return 0;
    }
    
    /**
     * @dev Validate colony join criteria parameters
     * @param criteria Colony join criteria to validate
     * @return validated Validated and capped criteria
     */
    function validateJoinCriteria(ColonyCriteria calldata criteria) internal pure returns (ColonyCriteria memory validated) {
        validated = criteria;
        
        // Validate level constraint
        if (validated.minLevel > 10) {
            revert InvalidParameterValue("minLevel", "Cannot exceed 10");
        }
        
        // Validate variant constraint
        if (validated.minVariant > 4) {
            revert InvalidParameterValue("minVariant", "Cannot exceed 4");
        }

        // Ensure minVariant is at least 1 (unlike before where 0 was allowed)
        if (validated.minVariant < 1) {
            validated.minVariant = 1; // Default to variant 1 as minimum
        }
           
        // Validate specialization constraint
        if (validated.requiredSpecialization > 2) {
            revert InvalidParameterValue("requiredSpecialization", "Invalid specialization value");
        }
        
        return validated;
    }
    
    /**
     * @dev Get active colony IDs using global registry with existence verification
     * @param start Starting index for pagination
     * @param limit Maximum number of colonies to return
     * @return colonyIds Array of colony IDs
     * @return total Total number of colonies in the registry
     */
    function getActiveColonyIds(uint256 start, uint256 limit) internal view returns (
        bytes32[] memory colonyIds,
        uint256 total
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Get total colonies from registry
        uint256 totalColonies = hs.allColonyIds.length;
        
        // If start index is beyond total, return empty array
        if (start >= totalColonies) {
            return (new bytes32[](0), totalColonies);
        }
        
        // Calculate how many colonies to return
        uint256 maxCount = totalColonies - start >= limit ? limit : totalColonies - start;
        
        // Prepare result buffer with validation
        bytes32[] memory validColonies = new bytes32[](maxCount);
        uint256 validCount = 0;
        
        // Fill buffer with only valid colonies
        for (uint256 i = 0; i < maxCount; i++) {
            bytes32 colonyId = hs.allColonyIds[start + i];
            
            // Verify colony still exists
            if (bytes(hs.colonyNamesById[colonyId]).length > 0) {
                validColonies[validCount++] = colonyId;
            }
        }
        
        // If all colonies are valid, return the original buffer
        if (validCount == maxCount) {
            return (validColonies, totalColonies);
        }
        
        // Otherwise, create a properly sized array
        colonyIds = new bytes32[](validCount);
        for (uint256 i = 0; i < validCount; i++) {
            colonyIds[i] = validColonies[i];
        }
        
        return (colonyIds, totalColonies);
    }

    /**
     * @dev Checks if a colony exists in the global registry
     * @param colonyId Colony ID to check
     * @return exists Whether the colony exists in the registry
     * @return index Index of the colony in the registry (or type(uint256).max if not found)
     */
    function colonyExistsInRegistry(bytes32 colonyId) internal view returns (bool exists, uint256 index) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        for (uint256 i = 0; i < hs.allColonyIds.length; i++) {
            if (hs.allColonyIds[i] == colonyId) {
                return (true, i);
            }
        }
        
        return (false, type(uint256).max);
    }

    /**
     * @dev Safely adds a colony to the global registry, preventing duplicates
     * @param colonyId Colony ID to add
     * @return success Whether the addition was successful
     */
    function safeAddColonyToRegistry(bytes32 colonyId) internal returns (bool success) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Verify colony exists in the main colony data
        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            return false;
        }
        
        // Check if already in registry to avoid duplicates
        (bool exists, ) = colonyExistsInRegistry(colonyId);
        if (exists) {
            return false; // Already exists
        }
        
        // Add to registry
        hs.allColonyIds.push(colonyId);
        return true;
    }

    /**
     * @dev Safely removes a colony from the global registry
     * @param colonyId Colony ID to remove
     * @return success Whether the removal was successful
     */
    function safeRemoveColonyFromRegistry(bytes32 colonyId) internal returns (bool success) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Find colony in registry
        (bool exists, uint256 index) = colonyExistsInRegistry(colonyId);
        if (!exists) {
            return false;
        }
        
        // Remove from registry using gas-efficient swap and pop
        uint256 lastIndex = hs.allColonyIds.length - 1;
        if (index != lastIndex) {
            hs.allColonyIds[index] = hs.allColonyIds[lastIndex];
        }
        hs.allColonyIds.pop();
        return true;
    }

    /**
     * @dev Migrates existing colonies to the global registry
     * @notice This is a one-time operation to initialize the registry
     * @return count Number of colonies migrated
     */
    function migrateColoniesToRegistry() internal returns (uint256 count) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Clear existing registry to avoid duplicates
        while (hs.allColonyIds.length > 0) {
            hs.allColonyIds.pop();
        }
        
        count = 0;
        
        // Use a comprehensive strategy to find existing colonies
        
        // 1. Process colonies from userColonies mapping for contract owner
        address owner = LibDiamond.contractOwner();
        bytes32[] storage ownerColonies = hs.userColonies[owner];
        
        // Add owner's colonies
        for (uint256 i = 0; i < ownerColonies.length; i++) {
            bytes32 colonyId = ownerColonies[i];
            if (bytes(hs.colonyNamesById[colonyId]).length > 0) {
                hs.allColonyIds.push(colonyId);
                count++;
            }
        }
        
        // 2. Check lastColonyId as it's likely to be valid
        if (hs.lastColonyId != bytes32(0) && bytes(hs.colonyNamesById[hs.lastColonyId]).length > 0) {
            // Check if already in registry
            bool alreadyAdded = false;
            for (uint256 i = 0; i < hs.allColonyIds.length; i++) {
                if (hs.allColonyIds[i] == hs.lastColonyId) {
                    alreadyAdded = true;
                    break;
                }
            }
            
            if (!alreadyAdded) {
                hs.allColonyIds.push(hs.lastColonyId);
                count++;
            }
        }
        
        // NOTE: This function doesn't attempt to find all colonies due to Solidity's limitations
        // with mapping enumeration. Admin must use addColonyToRegistry for any missing colonies.
        
        return count;
    }

    /**
     * @dev Removes invalid colonies from the registry
     * @return removedCount Number of invalid entries removed
     */
    function purgeInvalidColoniesFromRegistry() internal returns (uint256 removedCount) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        removedCount = 0;
        uint256 i = 0;
        
        while (i < hs.allColonyIds.length) {
            bytes32 colonyId = hs.allColonyIds[i];
            
            // Check if colony still exists
            if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
                // Colony doesn't exist - remove from registry
                hs.allColonyIds[i] = hs.allColonyIds[hs.allColonyIds.length - 1];
                hs.allColonyIds.pop();
                removedCount++;
                // Don't increment i as there's now a new element at this position
            } else {
                // Colony exists - move to next
                i++;
            }
        }
        
        return removedCount;
    }
    
    /**
     * @dev Initialize indices for existing colony members
     * @param colonyId Colony ID
     * @return count Number of members indexed
     */
    function initializeColonyIndices(bytes32 colonyId) internal returns (uint256 count) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256[] storage members = hs.colonies[colonyId];
        
        count = 0;
        
        // Initialize indices for all members
        for (uint256 i = 0; i < members.length; i++) {
            uint256 combinedId = members[i];
            // Use 1-based index (index + 1) to distinguish from uninitialized 0
            hs.colonyMemberIndices[colonyId][combinedId] = i + 1;
            count++;
        }
        
        return count;
    }

    /**
     * @dev Generate colony ID with randomized seed
     * @param colonyName Name of the colony
     * @param creator Creator address 
     * @param lastColonyId Last colony ID created
     * @return colonyId Generated colony ID
     * @return randomSeed Random seed used for generation
     */
    function generateColonyId(
        string memory colonyName,
        address creator,
        bytes32 lastColonyId
    ) internal view returns (bytes32 colonyId, uint256 randomSeed) {
        // Generate randomized seed with better entropy 
        randomSeed = uint256(keccak256(abi.encodePacked(
            blockhash(block.number - 1) != bytes32(0) ? blockhash(block.number - 1) : bytes32(uint256(1)),
            block.timestamp,
            creator,
            lastColonyId,
            colonyName
        )));
        
        // Generate colony ID
        colonyId = keccak256(abi.encodePacked(colonyName, creator, block.timestamp, randomSeed));
        
        return (colonyId, randomSeed);
    }

    /**
     * @dev Retrieve colony information
     * @param colonyId Colony ID
     * @return colonyName Colony name
     * @return creator Colony creator
     * @return bonusPercentage Staking bonus percentage
     */
    function retrieveColonyInfo(bytes32 colonyId) internal view returns (
        string memory colonyName,
        address creator,
        uint256 bonusPercentage
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        colonyName = hs.colonyNamesById[colonyId];
        creator = hs.colonyCreators[colonyId];
        bonusPercentage = hs.colonyStakingBonuses[colonyId];
        return (colonyName, creator, bonusPercentage);
    }

   /**
    * @notice Calculate current colony health with decay
    * @param colonyId Colony ID
    * @return healthLevel Current health after decay
    * @return daysSinceActivity Days since last activity
    */
    function calculateColonyHealth(bytes32 colonyId) internal view returns (uint8 healthLevel, uint32 daysSinceActivity) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibHenomorphsStorage.ColonyHealth storage health = hs.colonyHealth[colonyId];
        
        uint32 currentDay = uint32(block.timestamp / 86400);
        
        if (health.lastActivityDay == 0) {
            return (100, 0); // New colony starts healthy
        }
        
        daysSinceActivity = currentDay - health.lastActivityDay;
        
        // Calculate decay with boost consideration
        uint8 decayRate = 3; // Base 3 points per day
        
        // Premium restoration boost reduces decay
        if (health.boostEndTime > block.timestamp) {
            decayRate = 1; // Reduced decay during boost
        }
        
        uint8 totalDecay = uint8(daysSinceActivity * decayRate);
        
        if (totalDecay >= health.healthLevel) {
            healthLevel = 0;
        } else {
            healthLevel = health.healthLevel - totalDecay;
        }
    }

    /**
    * @notice Update colony health with proper decay and restoration
    * @param colonyId Colony ID
    */
    function updateColonyHealth(bytes32 colonyId) internal {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibHenomorphsStorage.ColonyHealth storage health = hs.colonyHealth[colonyId];
        
        uint32 currentDay = uint32(block.timestamp / 86400);
        
        // Initialize new colonies
        if (health.lastActivityDay == 0) {
            health.lastActivityDay = currentDay;
            health.healthLevel = 100;
            return;
        }
        
        // Apply decay if days have passed
        if (health.lastActivityDay != currentDay) {
            (uint8 currentHealth,) = calculateColonyHealth(colonyId);
            health.healthLevel = currentHealth;
            health.lastActivityDay = currentDay;
            
            // Apply penalties for very unhealthy colonies
            if (currentHealth < 30) {
                _applyColonyHealthPenalties(colonyId, currentHealth);
            }
        }
        
        // Activity restoration
        if (health.healthLevel < 100) {
            uint8 restoration = 5; // Base restoration
            
            // Premium boost gives extra restoration
            if (health.boostEndTime > block.timestamp) {
                restoration = 10;
            }
            
            health.healthLevel += restoration;
            if (health.healthLevel > 100) health.healthLevel = 100;
        }
    }

    /**
    * @notice Apply penalties to unhealthy colonies
    * @param colonyId Colony ID  
    * @param healthLevel Current health level
    */
    function _applyColonyHealthPenalties(bytes32 colonyId, uint8 healthLevel) internal {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256[] storage members = hs.colonies[colonyId];
        
        // Calculate penalty severity (0-10%)
        uint8 penaltySeverity = (30 - healthLevel) / 3;
        uint256 membersAffected = 0;
        
        // Apply to limited number of members for gas efficiency
        uint256 maxMembers = members.length > 15 ? 15 : members.length;
        
        for (uint256 i = 0; i < maxMembers; i++) {
            uint256 combinedId = members[i];
            PowerMatrix storage charge = hs.performedCharges[combinedId];
            
            if (charge.currentCharge > 0) {
                // Drain charge based on penalty severity
                uint256 chargeDrain = (charge.currentCharge * penaltySeverity) / 100;
                charge.currentCharge = charge.currentCharge > chargeDrain ? 
                    charge.currentCharge - chargeDrain : 0;
                membersAffected++;
            }
            
            // Increase fatigue
            if (charge.fatigueLevel < 95) {
                uint8 fatigueIncrease = penaltySeverity;
                charge.fatigueLevel += fatigueIncrease;
                if (charge.fatigueLevel > 100) charge.fatigueLevel = 100;
            }
        }
        
        if (membersAffected > 0) {
            // Would emit event but we're in library - calling facet should emit
        }
    }
}