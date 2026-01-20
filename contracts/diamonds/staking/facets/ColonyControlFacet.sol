// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../../chargepod/libraries/LibHenomorphsStorage.sol";
import {LibStakingStorage} from "../libraries/LibStakingStorage.sol";
import {PodsUtils} from "../../../libraries/PodsUtils.sol";
import {ColonyHelper} from "../libraries/ColonyHelper.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {ControlFee, ColonyCriteria} from "../../../libraries/HenomorphsModel.sol";
import {IStakingSystem, IChargeFacet} from "../interfaces/IStakingInterfaces.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title ColonyControlFacet
 * @author rutilicus.eth (ArchXS)
 * @notice Functionality for managing colonies with staking integration
 */
contract ColonyControlFacet is AccessControlBase {
    // Events
    event ColonyFormed(bytes32 indexed colonyId, string name, address indexed creator, uint256 memberCount);
    event ColonyDissolved(bytes32 indexed colonyId, address dissolvedBy);
    event ColonyChargeAdded(bytes32 indexed colonyId, uint256 amount, address provider);
    event SpecimenJoinedColony(uint256 indexed collectionId, uint256 indexed tokenId, bytes32 indexed colonyId);
    event SpecimenLeftColony(uint256 indexed collectionId, uint256 indexed tokenId, bytes32 indexed colonyId);
    event ColonyBonusUpdated(bytes32 indexed colonyId, uint256 bonusPercentage);
    event StakingIntegrationSet(address stakingAddress);
    event OperationResult(string operation, bool success);
    event OperationError(string operation, string errorMessage);
    event ColonyMembershipFeeCollected(uint256 indexed collectionId, uint256 indexed tokenId, bytes32 indexed colonyId, bool isJoining, uint256 feeAmount);
    event ColonyJoinCriteriaSet(bytes32 indexed colonyId, uint8 minLevel, uint8 minVariant, uint8 requiredSpecialization, bool requiresApproval);
    event JoinRequestSubmitted(bytes32 indexed colonyId, uint256 indexed collectionId, uint256 indexed tokenId, address requester);
    event JoinRequestApproved(bytes32 indexed colonyId, uint256 indexed collectionId, uint256 indexed tokenId, address approver);
    event JoinRequestRejected(bytes32 indexed colonyId, uint256 indexed collectionId, uint256 indexed tokenId, address rejecter);
    event ColonyJoinRestrictionSet(bytes32 indexed colonyId, bool restricted);
    event GlobalEmptyJoinSet(bool allowed);
    event MaxCreatorBonusUpdated(uint256 maxBonus);
    event ColonyIndicesInitialized(uint256 colonyCount);
    event TokenExpelledFromColony(bytes32 indexed colonyId, uint256 indexed collectionId, uint256 indexed tokenId, address remover, string reason);

    // Errors
    error EmptyColonyJoinRestricted(bytes32 colonyId);

    /**
     * @notice Update colony bonus storage (internal use only)
     * @param colonyId Colony ID
     * @param bonusPercentage New bonus percentage
     * @dev Called by StakingColonyFacet to keep storage in sync
     */
    function updateColonyBonusStorage(bytes32 colonyId, uint256 bonusPercentage) external whenNotPaused {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Only allow calls from staking system or admins
        if (!AccessHelper.isAuthorized() && LibMeta.msgSender() != hs.stakingSystemAddress) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not authorized to update storage");
        }
        
        // Only update if colony exists
        if (bytes(hs.colonyNamesById[colonyId]).length > 0) {
            hs.colonyStakingBonuses[colonyId] = bonusPercentage;
            emit ColonyBonusUpdated(colonyId, bonusPercentage);
        }
    }

    /**
     * @notice Administrative function to control empty colony join restrictions
     * @dev Controls whether users can join specific colonies with zero members
     * @param colonyId Colony ID to configure
     * @param restricted If true, colony needs at least one member before others can join
     */
    function setColonyJoinRestriction(bytes32 colonyId, bool restricted) external onlyAuthorized whenNotPaused {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Verify colony exists by checking its registered name
        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            revert ColonyHelper.ColonyDoesNotExist(colonyId);
        }
        
        // Set join restriction flag for this specific colony
        hs.colonyJoinRestrictions[colonyId] = restricted;
        
        emit ColonyJoinRestrictionSet(colonyId, restricted);
    }

    /**
     * @notice Administrative function to globally control empty colony join permissions
     * @dev Sets the default behavior for all colonies without specific settings
     * @param allowed If true, users can join empty colonies by default
     */
    function setGlobalEmptyColonyJoin(bool allowed) external onlyAuthorized whenNotPaused {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Set global permission flag
        hs.allowEmptyColonyJoin = allowed;
        
        emit GlobalEmptyJoinSet(allowed);
    }
    
    /**
     * @notice Create a new colony
     * @param collectionIds Array of collection IDs
     * @param tokenIds Array of token IDs corresponding to the collection IDs
     * @param colonyName Name of the colony to create
     */
    function createColony(
        uint256[] calldata collectionIds, 
        uint256[] calldata tokenIds, 
        string calldata colonyName
    ) external nonReentrant whenNotPaused {
        // Basic validation
        _validateColonyInputs(collectionIds, tokenIds, colonyName);
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Collect fee first to fail early if payment issues
        LibFeeCollection.collectFee(
            hs.chargeFees.colonyFormationFee.currency,
            LibMeta.msgSender(),
            hs.chargeFees.colonyFormationFee.beneficiary,
            hs.chargeFees.colonyFormationFee.amount,
            "createColony"
        );

        // Setup colony and get ID
        bytes32 colonyId = _setupColony(colonyName, hs);
        
        // Process members with resilient approach
        _processColonyMembers(colonyId, collectionIds, tokenIds);
        
        // Notify staking system - don't let failures here affect the main transaction
        if (hs.stakingSystemAddress != address(0)) {
            _notifyStakingSystem(colonyId, hs);
        }

        ColonyHelper.safeAddColonyToRegistry(colonyId);
        
        emit ColonyFormed(colonyId, colonyName, LibMeta.msgSender(), hs.colonies[colonyId].length);
    }

    /**
     * @dev Validate inputs for colony creation
     */
    function _validateColonyInputs(
        uint256[] calldata collectionIds, 
        uint256[] calldata tokenIds, 
        string calldata colonyName
    ) internal view {
        if (collectionIds.length != tokenIds.length || 
            collectionIds.length < 2 || 
            collectionIds.length > ColonyHelper.MAX_COLONY_CAPACITY) {
            revert ColonyHelper.InvalidCallData();
        }
        
        (bool nameExists,) = ColonyHelper.checkColonyNameExists(colonyName);
        if (nameExists) {
            revert ColonyHelper.ColonyNameTaken();
        }
    }

    /**
     * @dev Setup basic colony information and return colony ID
     */
    function _setupColony(
        string calldata colonyName,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) internal returns (bytes32) {
        // Use the helper for colony ID generation
        (bytes32 colonyId, uint256 randomSeed) = ColonyHelper.generateColonyId(
            colonyName, 
            LibMeta.msgSender(), 
            hs.lastColonyId
        );
        
        // Calculate name hash
        bytes32 nameHash = keccak256(abi.encodePacked(colonyName));
        
        // Register colony to creator
        address creator = LibMeta.msgSender();
        
        // Save colony information
        hs.colonyNames[nameHash] = colonyName;
        hs.colonyNamesById[colonyId] = colonyName;
        hs.colonyChargePools[colonyId] = 0;
        hs.colonyStakingBonuses[colonyId] = 5; // Default 5% bonus
        hs.lastColonyId = colonyId;
        hs.userColonies[creator].push(colonyId);
        hs.colonyCreators[colonyId] = creator;
        
        // Initialize empty members array
        hs.colonies[colonyId] = new uint256[](0);
        
        // Set default join criteria
        hs.colonyCriteria[colonyId].minLevel = 0;
        hs.colonyCriteria[colonyId].minVariant = 1;
        hs.colonyCriteria[colonyId].requiredSpecialization = 0;
        hs.colonyCriteria[colonyId].requiresApproval = false;
        hs.colonyCriteria[colonyId].allowEmptyJoin = true;
        
        emit ColonyHelper.ColonyIdGenerated(colonyId, randomSeed);
        
        return colonyId;
    }

    /**
     * @dev Process members with resilience to individual failures
     * This function handles token validation without using try/catch for library functions
     */
    function _processColonyMembers(
        bytes32 colonyId,
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds
    ) private {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256[] memory validMembers = new uint256[](collectionIds.length);
        uint256 validCount = 0;
        
        // Process each token individually
        for (uint256 i = 0; i < collectionIds.length; i++) {
            uint256 collectionId = collectionIds[i];
            uint256 tokenId = tokenIds[i];
            uint256 combinedId = 0;
            
            // Validate control
            ColonyHelper.checkHenomorphControl(collectionId, tokenId, hs.stakingSystemAddress);
            
            // Check eligibility and get combinedId
            combinedId = ColonyHelper.checkTokenEligibility(collectionId, tokenId, colonyId, hs.stakingSystemAddress);
            
            // Only process valid tokens
            if (combinedId > 0) {
                validMembers[validCount++] = combinedId;
                hs.specimenColonies[combinedId] = colonyId;
                
                // Recalibrate power core using the helper function from ColonyHelper
                ColonyHelper.safeRecalibrateCore(collectionId, tokenId);
                
                emit SpecimenJoinedColony(collectionId, tokenId, colonyId);
            }
        }
        
        // If no tokens were processed successfully, revert the transaction
        if (validCount == 0) {
            revert ColonyHelper.InvalidCallData();
        }
        
        // Store only successful members
        uint256[] memory finalMembers = new uint256[](validCount);
        for (uint256 i = 0; i < validCount; i++) {
            finalMembers[i] = validMembers[i];
        }
        
        hs.colonies[colonyId] = finalMembers;
    }

    /**
     * @dev Notify staking system about colony creation and members
     * Uses the original code's approach with ColonyHelper functions
     */
    function _notifyStakingSystem(
        bytes32 colonyId,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) private {
        // Get colony data using helper
        (string memory colonyName, address creator, ) = 
            ColonyHelper.retrieveColonyInfo(colonyId);
        
        // Get staking system address
        address stakingSys = hs.stakingSystemAddress;
        if (stakingSys == address(0)) {
            return;
        }
        
        // First, sync colony creation
        bool creationSuccess = ColonyHelper.syncColonyWithStaking(colonyId, colonyName, creator, stakingSys);
        
        // If colony creation sync succeeded, also notify about members
        if (creationSuccess) {
            // Get colony members
            uint256[] storage memberIds = hs.colonies[colonyId];
            uint256 memberCount = memberIds.length;
            
            if (memberCount > 0) {
                uint256[] memory collectionIds = new uint256[](memberCount);
                uint256[] memory tokenIds = new uint256[](memberCount);
                
                for (uint256 i = 0; i < memberCount; i++) {
                    (collectionIds[i], tokenIds[i]) = PodsUtils.extractIds(memberIds[i]);
                }
                
                // Notify about members using the original helper function
                uint256 notifiedCount = ColonyHelper.batchNotifyColonyMembers(colonyId, collectionIds, tokenIds, stakingSys);
                emit OperationResult("MemberNotifications", notifiedCount > 0);
            }
        }
    }

    /**
     * @notice Create an empty colony (admin only)
     * @param colonyName Name of the colony to create
     * @param initialCreator Address to set as the creator (or zero address to use caller)
     * @return colonyId ID of the created colony
     */
    function createEmptyColony(
        string calldata colonyName,
        address initialCreator
    ) external onlyAuthorized whenNotPaused nonReentrant returns (bytes32 colonyId) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Validate colony name
        (bool nameExists, ) = ColonyHelper.checkColonyNameExists(colonyName);
        if (nameExists) {
            revert ColonyHelper.ColonyNameTaken();
        }

        // Use creator address (or caller if zero)
        address creator = initialCreator == address(0) ? LibMeta.msgSender() : initialCreator;
        
        // Use the helper for colony ID generation
        uint256 randomSeed;
        (colonyId, randomSeed) = ColonyHelper.generateColonyId(
            colonyName, 
            creator, 
            hs.lastColonyId
        );
        
        // Calculate name hash
        bytes32 nameHash = keccak256(abi.encodePacked(colonyName));
        
        // Save colony information
        hs.colonies[colonyId] = new uint256[](0);
        hs.colonyNames[nameHash] = colonyName;
        hs.colonyNamesById[colonyId] = colonyName;
        hs.colonyChargePools[colonyId] = 0;
        hs.colonyStakingBonuses[colonyId] = 5;
        hs.lastColonyId = colonyId;
        
        // Set creator
        hs.colonyCreators[colonyId] = creator;
        hs.userColonies[creator].push(colonyId);
        
        // Set default join criteria
        ColonyCriteria memory defaultCriteria = ColonyCriteria({
            minLevel: 0,
            minVariant: 0,
            requiredSpecialization: 0,
            requiresApproval: false,
            allowEmptyJoin: true  // Default to allow joining empty colony
        });
        
        hs.colonyCriteria[colonyId] = defaultCriteria;

        ColonyHelper.safeAddColonyToRegistry(colonyId);
        
        emit ColonyHelper.ColonyIdGenerated(colonyId, randomSeed);
        emit ColonyFormed(colonyId, colonyName, creator, 0);
        
        // Notify staking system - just creation notification
        ColonyHelper.syncColonyWithStaking(colonyId, colonyName, creator, hs.stakingSystemAddress);
        
        return colonyId;
    }

    /**
     * @notice Set join criteria for a colony
     * @param colonyId ID of the colony
     * @param joinCriteria Criteria for joining the colony
     */
    function setColonyJoinCriteria(bytes32 colonyId, ColonyCriteria calldata joinCriteria) external whenNotPaused {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            revert ColonyHelper.ColonyDoesNotExist(colonyId);
        }
        
        if (!ColonyHelper.isAuthorizedForColony(colonyId, hs.stakingSystemAddress) && !AccessHelper.isAuthorized()) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not authorized for this colony");
        }
        
        // Validate criteria with proper error handling
        ColonyCriteria memory validatedCriteria = ColonyHelper.validateJoinCriteria(joinCriteria);
        ColonyCriteria storage currentCriteria = hs.colonyCriteria[colonyId];
        
        // Check if criteria actually changed
        bool criteriaChanged = 
            currentCriteria.minLevel != validatedCriteria.minLevel ||
            currentCriteria.minVariant != validatedCriteria.minVariant ||
            currentCriteria.requiredSpecialization != validatedCriteria.requiredSpecialization ||
            currentCriteria.requiresApproval != validatedCriteria.requiresApproval ||
            currentCriteria.allowEmptyJoin != validatedCriteria.allowEmptyJoin;
            
        // Store criteria
        hs.colonyCriteria[colonyId] = validatedCriteria;
        
        emit ColonyJoinCriteriaSet(
            colonyId,
            validatedCriteria.minLevel,
            validatedCriteria.minVariant,
            validatedCriteria.requiredSpecialization,
            validatedCriteria.requiresApproval
        );
        
        // Sync with staking system only if criteria changed
        if (criteriaChanged && hs.stakingSystemAddress != address(0)) {
            try IStakingSystem(hs.stakingSystemAddress).setColonyJoinCriteria(colonyId, validatedCriteria) {
                emit OperationResult("CriteriaSync", true);
            } catch {
                emit OperationResult("CriteriaSync", false);
            }
        }
    }

    /**
     * @notice Process join requests for a colony
     * @param colonyId ID of the colony
     * @param requestIds Array of request indexes to process
     * @param approve Array of approval flags corresponding to each request
     */
    function processJoinRequests(bytes32 colonyId, uint256[] calldata requestIds, bool[] calldata approve) external nonReentrant whenNotPaused {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            revert ColonyHelper.ColonyDoesNotExist(colonyId);
        }
        
        if (!ColonyHelper.isAuthorizedForColony(colonyId, hs.stakingSystemAddress) && !AccessHelper.isAuthorized()) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not authorized for this colony");
        }
        
        if (requestIds.length != approve.length) {
            revert ColonyHelper.InvalidCallData();
        }
        
        uint256[] storage pendingRequestIds = hs.colonyPendingRequestIds[colonyId];
        
        for (uint256 i = 0; i < requestIds.length; i++) {
            uint256 requestIndex = requestIds[i];
            if (requestIndex >= pendingRequestIds.length) continue;
            
            uint256 combinedId = pendingRequestIds[requestIndex];
            address requester = hs.pendingJoinRequests[colonyId][combinedId];
            if (requester == address(0)) continue;
            
            (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);
            
            // Remove request
            delete hs.pendingJoinRequests[colonyId][combinedId];
            pendingRequestIds[requestIndex] = pendingRequestIds[pendingRequestIds.length - 1];
            pendingRequestIds.pop();
            
            if (approve[i]) {
                // Check current token colony status
                bytes32 currentColony = hs.specimenColonies[combinedId];
                
                // If token is already in this colony, skip
                if (currentColony == colonyId) {
                    continue;
                }
                
                // If token is in another colony, remove it from that colony first
                if (currentColony != bytes32(0)) {
                    // Remove token from existing colony
                    ColonyHelper.processColonyMembershipChange(currentColony, combinedId, false, hs.stakingSystemAddress);
                }
                
                // Process approval
                LibFeeCollection.collectFee(
                    hs.chargeFees.colonyMembershipFee.currency,
                    requester,
                    hs.chargeFees.colonyMembershipFee.beneficiary,
                    hs.chargeFees.colonyMembershipFee.amount,
                    "processJoinRequests"
                );

                emit ColonyMembershipFeeCollected(collectionId, tokenId, colonyId, true, hs.chargeFees.colonyMembershipFee.amount);

                // Process membership change
                ColonyHelper.processColonyMembershipChange(colonyId, combinedId, true, hs.stakingSystemAddress);

                ColonyHelper.updateColonyHealth(colonyId);

                emit SpecimenJoinedColony(collectionId, tokenId, colonyId);
                emit JoinRequestApproved(colonyId, collectionId, tokenId, LibMeta.msgSender());
            } else {
                emit JoinRequestRejected(colonyId, collectionId, tokenId, LibMeta.msgSender());
            }
        }
    }

    /**
     * @notice Join an existing colony
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param colonyId ID of the colony to join
     */
    function joinColony(uint256 collectionId, uint256 tokenId, bytes32 colonyId) external nonReentrant whenNotPaused {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        address stakingSys = hs.stakingSystemAddress;
        
        ColonyHelper.checkHenomorphControl(collectionId, tokenId, stakingSys);
        
        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            revert ColonyHelper.ColonyDoesNotExist(colonyId);
        }

        // Check for empty colony join restrictions
        if (!AccessHelper.isAuthorized() && hs.colonies[colonyId].length == 0) {
            // 1. If colony has specific restriction, apply it
            if (hs.colonyJoinRestrictions[colonyId]) {
                revert EmptyColonyJoinRestricted(colonyId);
            }
            
            // 2. If colony criteria explicitly allows empty joining, always allow
            if (!hs.colonyCriteria[colonyId].allowEmptyJoin) {
                // 3. Otherwise use global setting
                if (!hs.allowEmptyColonyJoin) {
                    revert EmptyColonyJoinRestricted(colonyId);
                }
            }
            // If none of the conditions are met, allow joining
        }
        
        // Check colony capacity
        (, bool atCapacity) = ColonyHelper.checkColonyCapacity(colonyId);
        if (atCapacity) {
            revert ColonyHelper.MaxColonyMembersReached();
        }
        
        // Check if token is already in a colony
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        bytes32 currentColony = hs.specimenColonies[combinedId];
        
        // If token is already in this colony, return error
        if (currentColony == colonyId) {
            revert ColonyHelper.HenomorphAlreadyInColony();
        }
        
        // Check token eligibility
        combinedId = ColonyHelper.checkTokenEligibility(collectionId, tokenId, colonyId, stakingSys);
        
        address creator = hs.colonyCreators[colonyId];
        address sender = LibMeta.msgSender();
        ColonyCriteria storage criteria = hs.colonyCriteria[colonyId];
        
        bool autoApprove = false;
        
        if (sender == creator || AccessHelper.isAuthorized()) {
            autoApprove = true;
        } else if (!criteria.requiresApproval) {
            ColonyHelper.checkJoinCriteriaEligibility(collectionId, tokenId, colonyId, stakingSys);
            autoApprove = true;
        } else {
            ColonyHelper.checkJoinCriteriaEligibility(collectionId, tokenId, colonyId, stakingSys);
            
            hs.pendingJoinRequests[colonyId][combinedId] = sender;
            hs.colonyPendingRequestIds[colonyId].push(combinedId);
            
            emit JoinRequestSubmitted(colonyId, collectionId, tokenId, sender);
            return;
        }
        
        if (autoApprove) {
            // If token is already in another colony, remove it from that colony first
            if (currentColony != bytes32(0)) {
                // Remove token from existing colony
                ColonyHelper.processColonyMembershipChange(currentColony, combinedId, false, stakingSys);
            }
            
            LibFeeCollection.collectFee(
                hs.chargeFees.colonyMembershipFee.currency,
                sender,
                hs.chargeFees.colonyMembershipFee.beneficiary, 
                hs.chargeFees.colonyMembershipFee.amount,
                "joinColony"
            );

            emit ColonyMembershipFeeCollected(collectionId, tokenId, colonyId, true, hs.chargeFees.colonyMembershipFee.amount);
            
            // Process membership change
            ColonyHelper.processColonyMembershipChange(colonyId, combinedId, true, stakingSys);

            ColonyHelper.updateColonyHealth(colonyId);
            
            emit SpecimenJoinedColony(collectionId, tokenId, colonyId);
        }
    }
    
    /**
     * @notice Leave colony
     * @param collectionId Collection ID
     * @param tokenId Token ID
     */
    function leaveColony(uint256 collectionId, uint256 tokenId) external nonReentrant whenNotPaused {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        address stakingSys = hs.stakingSystemAddress;
        
        ColonyHelper.checkHenomorphControl(collectionId, tokenId, stakingSys);
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        bytes32 colonyId = hs.specimenColonies[combinedId];
        if (colonyId == bytes32(0)) {
            revert ColonyHelper.HenomorphNotInColony();
        }

        LibFeeCollection.collectFee(
            hs.chargeFees.colonyMembershipFee.currency,
            LibMeta.msgSender(),
            hs.chargeFees.colonyMembershipFee.beneficiary,
            hs.chargeFees.colonyMembershipFee.amount,
            "leaveColony"
        );

        emit ColonyMembershipFeeCollected(collectionId, tokenId, colonyId, false, hs.chargeFees.colonyMembershipFee.amount);
            
        // Process membership change
        ColonyHelper.processColonyMembershipChange(colonyId, combinedId, false, stakingSys);

        ColonyHelper.updateColonyHealth(colonyId);

        emit SpecimenLeftColony(collectionId, tokenId, colonyId);
    }

    /**
     * @notice Remove a token from a colony (creator/admin only)
     * @dev Allows colony creators or admins to remove tokens they don't own from their colony
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param colonyId ID of the colony
     * @param reason Optional reason for removal (can be empty)
     * @return success Whether the removal was successful
     */
    function expellFromColony(
        uint256 collectionId, 
        uint256 tokenId, 
        bytes32 colonyId,
        string calldata reason
    ) external nonReentrant whenNotPaused returns (bool success) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        address stakingSys = hs.stakingSystemAddress;
        address sender = LibMeta.msgSender();
        
        // Verify colony exists using the standard pattern from the codebase
        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            revert ColonyHelper.ColonyDoesNotExist(colonyId);
        }
        
        // More comprehensive authorization check that aligns with other functions
        if (!ColonyHelper.isAuthorizedForColony(colonyId, stakingSys) && !AccessHelper.isAuthorized()) {
            revert AccessHelper.Unauthorized(sender, "Not authorized for this colony");
        }
        
        // Check if token is in the colony
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        bytes32 tokenColony = hs.specimenColonies[combinedId];
        
        if (tokenColony != colonyId) {
            revert ColonyHelper.HenomorphNotInColony();
        }
        
        // Verify that the token is not owned by the caller
        // This prevents misuse of the function to avoid membership fees
        address owner = ColonyHelper.getTokenOwner(collectionId, tokenId);
        if (owner == sender && !AccessHelper.isAuthorized()) {
            revert AccessHelper.Unauthorized(sender, "Use leaveColony for your own tokens");
        }
        
        // Collect membership fee from the admin/creator performing the removal
        // This ensures economic consistency with other colony membership operations
        LibFeeCollection.collectFee(
            hs.chargeFees.colonyMembershipFee.currency,
            sender,
            hs.chargeFees.colonyMembershipFee.beneficiary,
            hs.chargeFees.colonyMembershipFee.amount,
            "expellFromColony"
        );
        
        // Emit fee collection event
        emit ColonyMembershipFeeCollected(collectionId, tokenId, colonyId, false, hs.chargeFees.colonyMembershipFee.amount);
        
        // Process membership change
        success = ColonyHelper.processColonyMembershipChange(colonyId, combinedId, false, stakingSys);

        ColonyHelper.updateColonyHealth(colonyId);
        
        // Emit specific event with removal details
        emit TokenExpelledFromColony(colonyId, collectionId, tokenId, sender, reason);
        return success;
    }
    
    /**
     * @notice Dissolve a colony
     * @param colonyId ID of the colony to dissolve
     */
    function dissolveColony(bytes32 colonyId) external nonReentrant whenNotPaused {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256[] storage colonyMembers = hs.colonies[colonyId];
        
        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            revert ColonyHelper.ColonyDoesNotExist(colonyId);
        }
        
        if (!ColonyHelper.isAuthorizedForColony(colonyId, hs.stakingSystemAddress) && !AccessHelper.isAuthorized()) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not authorized for this colony");
        }
        
        // Notify staking system first
        if (hs.stakingSystemAddress != address(0)) {
            try IStakingSystem(hs.stakingSystemAddress).notifyColonyDissolved(colonyId) {
                emit OperationResult("StakingNotification", true);
            } catch {
                emit OperationResult("StakingNotification", false);
            }
        }
        
        // Get colony data before cleaning up
        address creator = hs.colonyCreators[colonyId];
        (bytes32 nameHash, ) = ColonyHelper.findColonyNameHash(colonyId);
        
        // Process all members
        for (uint256 i = 0; i < colonyMembers.length; i++) {
            uint256 combinedId = colonyMembers[i];
            delete hs.specimenColonies[combinedId];
            
            // Update power cores
            (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);
            // Use safe method without low-level call
            ColonyHelper.safeRecalibrateCore(collectionId, tokenId);
        }
        
        // Remove from creator's colonies list
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
        
        // Clean up all colony data
        delete hs.colonyPendingRequestIds[colonyId];
        delete hs.colonies[colonyId];
        delete hs.colonyChargePools[colonyId];
        delete hs.colonyStakingBonuses[colonyId];
        delete hs.colonyCriteria[colonyId];
        delete hs.colonyCreators[colonyId];
        delete hs.colonyJoinRestrictions[colonyId];
        
        if (nameHash != bytes32(0)) {
            delete hs.colonyNames[nameHash];
        }
        
        delete hs.colonyNamesById[colonyId];
        ColonyHelper.safeRemoveColonyFromRegistry(colonyId);
        
        emit ColonyDissolved(colonyId, LibMeta.msgSender());
    }

    /**
     * @notice Set maximum bonus percentage that colony creators can set
     * @param maxBonus Maximum bonus percentage for colony creators (0-50)
     * @dev Only callable by system administrators
     */
    function setMaxCreatorBonusPercentage(uint256 maxBonus) external onlyAuthorized whenNotPaused {
        require(maxBonus <= 50, "Cannot exceed absolute maximum of 50%");
        LibHenomorphsStorage.henomorphsStorage().maxCreatorBonusPercentage = maxBonus;
        emit MaxCreatorBonusUpdated(maxBonus);
    }

    /**
     * @notice Synchronize colony data with staking system
     * @param colonyId ID of the colony
     * @return success Whether the operation was successful
     */
    function syncColonyData(bytes32 colonyId) external whenNotPaused returns (bool success) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Verify colony exists by checking its registered name instead of member count
        if (bytes(hs.colonyNamesById[colonyId]).length == 0 || hs.stakingSystemAddress == address(0)) {
            return false;
        }
        
        // Get colony data with helper
        (string memory colonyName, address creator, uint256 bonusPercentage) = 
            ColonyHelper.retrieveColonyInfo(colonyId);
        
        // Notify colony creation
        bool creationSuccess = ColonyHelper.syncColonyWithStaking(colonyId, colonyName, creator, hs.stakingSystemAddress);
        
        // If successfully notified, also send colony members and bonus
        if (creationSuccess) {
            // Get colony members
            // Direct access to storage to get combined IDs
            uint256[] storage combinedIds = hs.colonies[colonyId];
            uint256 memberCount = combinedIds.length;
            uint256[] memory collectionIds = new uint256[](memberCount);
            uint256[] memory tokenIds = new uint256[](memberCount);
            
            for (uint256 i = 0; i < memberCount; i++) {
                (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedIds[i]);
                collectionIds[i] = collectionId;
                tokenIds[i] = tokenId;
            }
            
            // Batch notify about members - may be empty for empty colonies
            uint256 membersSuccess = 0;
            if (collectionIds.length > 0) {
                membersSuccess = ColonyHelper.batchNotifyColonyMembers(colonyId, collectionIds, tokenIds, hs.stakingSystemAddress);
            }
            
            // Update bonus if needed
            try IStakingSystem(hs.stakingSystemAddress).setStakingBonus(colonyId, bonusPercentage) {
                emit OperationResult("BonusSyncSuccess", true);
            } catch {
                emit OperationResult("BonusSyncSuccess", false);
            }
            
            // For empty colonies, consider synchronization successful even if members sync returns 0
            return collectionIds.length == 0 || membersSuccess > 0;
        }
        
        return false;
    }

}