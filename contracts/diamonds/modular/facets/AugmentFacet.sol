// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibCollectionStorage} from "../libraries/LibCollectionStorage.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {ISpecimenCollection, IStaking} from "../interfaces/IExternalSystems.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";

interface IAccessoryCollection {
    function mintAccessory(address to, uint8 accessoryId, string calldata tokenURI) external returns (uint256);
    function burn(uint256 tokenId) external;
}

/**
 * @title AugmentFacet - Core User Operations with Fixed Variant Logic
 * @notice Fixed augment assignment with proper separation of augment and specimen variants with unified collection support
 * @dev Maintains strict separation between augment collection variants and specimen collection variants
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 * @custom:version 1.1.0 - Updated for unified collection system
 */
contract AugmentFacet is AccessControlBase {
    using Address for address payable;
    using Strings for uint256;
    using Strings for uint8;

    struct AugmentLockInfo {
        bool hasAssignment;      // Whether specimen has assigned augment
        bool isLocked;          // Whether augment is currently locked
        bool isPermanent;       // Whether lock is permanent
        uint256 unlockTime;     // When lock expires (0 if permanent)
        uint256 timeRemaining;  // Seconds remaining until unlock (0 if unlocked/permanent)
    }
    
    // ==================== EVENTS ====================
    
    event OperationResult(string operation, bool success, string message);
    
    event AugmentAssigned(
        address indexed specimenCollection,
        uint256 indexed specimenTokenId,
        address indexed augmentCollection,
        uint256 augmentTokenId,
        uint8 augmentTier,
        uint8 augmentVariant,
        uint8 specimenVariant,
        uint256 unlockTime,
        uint256 feePaid
    );
    
    event AugmentRemoved(
        address indexed specimenCollection,
        uint256 indexed specimenTokenId,
        address indexed augmentCollection,
        uint256 augmentTokenId,
        uint8 augmentTier,
        uint8 augmentVariant
    );

    event AugmentLockExtended(
        address indexed specimenCollection,
        uint256 indexed specimenTokenId,
        uint256 additionalDuration,
        uint256 extensionFee
    );

    event AccessoriesAutoCreated(
        address indexed specimenCollection,
        uint256 indexed specimenTokenId,
        address indexed accessoryCollection,
        uint256[] accessoryTokenIds,
        uint8[] accessoryIds
    );

    event AugmentVariantConfigured(
        address indexed augmentCollection,
        uint256 indexed augmentTokenId,
        uint8 augmentTier,
        uint8 augmentVariant,
        uint8[] accessories
    );
        
    // ==================== STRUCTURES ====================

    struct AugmentInfo {
        uint8 tier;
        uint8 variant;
        uint8[] accessoryIds;
        string[] accessoryNames;
        bool isAssigned;
        bool isRemovable;
    }

    struct AugmentConfig {
        uint8 tier;
        uint8 variant;
        uint8[] accessoryIds;
        bool shared;
        uint256 maxUsage;
        bool configured;
    }

    struct AugmentAttachment {
        bool isAttached;                 // Whether augment is currently attached
        address specimenCollection;      // Specimen collection address (0x0 if not attached)
        uint256 specimenTokenId;         // Specimen token ID (0 if not attached)
        uint8 tier;                      // Augment tier
        uint8 augmentVariant;            // Augment's own variant
        uint8 specimenVariant;           // Specimen's variant
        uint256 assignmentTime;          // When augment was assigned
        uint256 unlockTime;              // When lock expires (0 if permanent)
        bool isPermanent;                // Whether lock is permanent
        uint256 totalFeePaid;            // Total fee paid for this assignment
        uint8[] assignedAccessories;     // Accessory IDs assigned with this augment
    }
    
    // ==================== ERRORS ====================
    
    error AugmentNotFound(uint8 augmentId);
    error AugmentAlreadyAssigned(address collection, uint256 tokenId);
    error AugmentUsageLimitExceeded(uint256 tokenId, uint256 maxUsage);
    error AugmentLocked(address collection, uint256 tokenId, address locker, uint256 unlockTime);
    error NotTokenOwner(address collection, uint256 tokenId);
    error InvalidConfiguration();
    error CollectionNotSupported(address collection);
    error UnauthorizedAugmentOperation(address caller, address collection, uint256 tokenId);
    error AugmentNotRemovable(address collection, uint256 tokenId, uint8 variant);
    error PermanentLockCannotBeRemoved(uint256 tokenId, uint8 variant);
    error LockDurationTooShort(uint256 requested, uint256 minimum);
    error LockDurationTooLong(uint256 requested, uint256 maximum);
    error AugmentVariantNotConfigured(address collection, uint8 tier, uint8 variant);
    error AccessoryMismatch(uint8[] expected, uint8[] actual);
    error AugmentTokenNotConfigured(address collection, uint256 tokenId);
    error AugmentNotAllowed(uint256 collectionId, address augmentCollection);
    error TokensMustHaveSameOwner();

    // ==================== CONSTANTS ====================
    
    uint256 private constant MAX_LOCK_DURATION = 365 days;
    uint256 private constant MIN_LOCK_DURATION = 1 hours;
    uint256 private constant DEFAULT_LOCK_DURATION = 30 days;

    modifier onlyTokenController(address collection, uint256 tokenId) override {
        address caller = LibMeta.msgSender();
        
        if (!_hasTokenAccess(collection, tokenId) && !AccessHelper.isInternalCall()) {
            revert AccessHelper.Unauthorized(caller, "Token level access required");
        }
        _;
    }
    
    // ==================== USER FUNCTIONS ====================
        
    /**
     * @notice Assign augment to specimen with proper variant separation
     * @dev Uses augment's own tier/variant for configuration, stores specimen variant separately
     * @param specimenCollection Specimen collection address
     * @param specimenTokenId Specimen token ID
     * @param augmentCollection Augment collection address
     * @param augmentTokenId Augment token ID
     * @param lockDuration Lock duration in seconds (0 for default)
     * @param createAccessories Whether to auto-create accessories
     * @param skipFee Whether to skip fee collection
     */
    function altAssignAugment(
        address specimenCollection,
        uint256 specimenTokenId,
        address augmentCollection,
        uint256 augmentTokenId,
        uint256 lockDuration,
        bool createAccessories,
        bool skipFee
    ) external whenNotPaused onlyTokenController(specimenCollection, specimenTokenId) {
        _assignAugment(
            specimenCollection,
            specimenTokenId,
            augmentCollection,
            augmentTokenId,
            lockDuration,
            createAccessories,
            skipFee
        );
    }

    /**
     * @notice Backward compatibility overload
     */
    function assignAugment(
        address specimenCollection,
        uint256 specimenTokenId,
        address augmentCollection,
        uint256 augmentTokenId,
        uint256 lockDuration,
        bool createAccessories
    ) external {
        _assignAugment(
            specimenCollection,
            specimenTokenId,
            augmentCollection,
            augmentTokenId,
            lockDuration,
            createAccessories,
            false
        );
    }

    function _assignAugment(
        address specimenCollection,
        uint256 specimenTokenId,
        address augmentCollection,
        uint256 augmentTokenId,
        uint256 lockDuration,
        bool createAccessories,
        bool skipFee
    ) internal {
        
        bool isAdminOperation = _isAuthorized() || 
                        _isRegisteredAugmentCollection(LibMeta.msgSender()) || 
                        AccessHelper.isInternalCall();

        _validateAugmentAssignment(specimenCollection, specimenTokenId, augmentCollection, augmentTokenId);
        
        // NEW: Cross-ownership validation when called by augment collection
        address caller = LibMeta.msgSender();
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (cs.augmentCollections[caller].active) {
            // If caller is augment collection, validate cross-ownership
            _validateCrossOwnership(specimenCollection, specimenTokenId, augmentCollection, augmentTokenId);
        }
        
        // Rest of function unchanged...
        AugmentConfig memory augmentConfig = _getAugmentConfiguration(augmentCollection, augmentTokenId);
        uint8 specimenVariant = _getSpecimenVariant(specimenCollection, specimenTokenId);
        
        uint256 configLockDuration = lockDuration == 0 ? DEFAULT_LOCK_DURATION : lockDuration;
        
        if (augmentConfig.shared) {
            _checkAugmentUsageLimits(augmentCollection, augmentTokenId, augmentConfig.maxUsage);
        }

        bool isRemovable = _validateAugmentRemovability(augmentCollection, augmentConfig.variant);
        
        if (isRemovable) {
            _validateLockDuration(augmentConfig.tier, configLockDuration);
        }
        
        uint256 totalFee = 0;
        
        if (!skipFee && !isAdminOperation) {
            totalFee = _processAssignmentPayment(augmentConfig.tier, configLockDuration);
        }
        
        _lockAugmentToken(
            augmentCollection, 
            augmentTokenId, 
            specimenCollection,
            specimenTokenId,
            configLockDuration, 
            totalFee,
            augmentConfig.variant,
            isRemovable
        );
        
        bytes32 assignmentKey = _createAugmentAssignmentRecord(
            specimenCollection,
            specimenTokenId,
            augmentCollection,
            augmentTokenId,
            augmentConfig.tier,
            augmentConfig.variant,
            specimenVariant,
            configLockDuration,
            totalFee,
            augmentConfig.accessoryIds,
            isRemovable
        );
        
        if (createAccessories && augmentConfig.accessoryIds.length > 0) {
            _autoCreateAccessories(
                specimenCollection,
                specimenTokenId,
                augmentCollection,
                augmentTokenId,
                augmentConfig.accessoryIds,
                assignmentKey
            );
        }
        
        _notifySpecimenCollection(
            specimenCollection,
            specimenTokenId,
            augmentCollection,
            augmentTokenId,
            true
        );
        
        emit AugmentAssigned(
            specimenCollection,
            specimenTokenId,
            augmentCollection,
            augmentTokenId,
            augmentConfig.tier,
            augmentConfig.variant,
            specimenVariant,
            isRemovable ? (block.timestamp + configLockDuration) : 0,
            totalFee
        );
    }

    /**
     * @notice Remove augment from specimen
     * @dev Checks CURRENT removability config - if variant is now removable, old permanent locks can be removed
     */
    function removeAugment(
        address specimenCollection,
        uint256 specimenTokenId,
        bool removeAccessories,
        bool forceUnlock
    ) external whenNotPaused nonReentrant {

        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();

        bytes32 assignmentKey = cs.specimenToAssignment[specimenCollection][specimenTokenId];
        if (assignmentKey == bytes32(0)) {
            revert AugmentNotFound(0);
        }

        LibCollectionStorage.AugmentAssignment storage assignment = cs.augmentAssignments[assignmentKey];
        if (!assignment.active) {
            revert AugmentNotFound(assignment.tier);
        }

        if (!forceUnlock) {
            if (!_hasTokenAccess(specimenCollection, specimenTokenId) && !_isAuthorized()) {
                revert UnauthorizedAugmentOperation(msg.sender, specimenCollection, specimenTokenId);
            }

            // Check CURRENT removability config instead of stored unlockTime
            // This allows admin to globally enable removal by changing variant config
            bool isCurrentlyRemovable = _validateAugmentRemovability(
                assignment.augmentCollection,
                assignment.augmentVariant
            );

            if (!isCurrentlyRemovable) {
                // Variant is configured as non-removable
                revert PermanentLockCannotBeRemoved(assignment.augmentTokenId, assignment.augmentVariant);
            }

            // If removable but has time lock, check if expired
            if (assignment.unlockTime > 0 && block.timestamp < assignment.unlockTime) {
                revert AugmentLocked(
                    assignment.augmentCollection,
                    assignment.augmentTokenId,
                    assignment.specimenCollection,
                    assignment.unlockTime
                );
            }
        } else {
            if (!_isAuthorized()) {
                revert UnauthorizedAugmentOperation(msg.sender, specimenCollection, specimenTokenId);
            }
        }
        
        address augmentCollection = assignment.augmentCollection;
        uint256 augmentTokenId = assignment.augmentTokenId;
        uint8 augmentTier = assignment.tier;
        uint8 augmentVariant = assignment.augmentVariant;
        
        if (removeAccessories) {
            _removeAutoCreatedAccessories(specimenCollection, specimenTokenId, assignmentKey);
        }
        
        _unlockAugmentToken(augmentCollection, augmentTokenId);
        assignment.active = false;
        
        delete cs.specimenToAssignment[specimenCollection][specimenTokenId];
        delete cs.augmentTokenToAssignment[augmentCollection][augmentTokenId];
        
        _notifySpecimenCollection(
            specimenCollection,
            specimenTokenId,
            augmentCollection,
            augmentTokenId,
            false
        );
        
        emit AugmentRemoved(specimenCollection, specimenTokenId, augmentCollection, augmentTokenId, augmentTier, augmentVariant);
    }

    /**
     * @notice Extend augment lock duration
     */
    function extendAugmentLock(
        address specimenCollection,
        uint256 specimenTokenId,
        uint256 additionalDuration
    ) external whenNotPaused onlyTokenController(specimenCollection, specimenTokenId) nonReentrant {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        bytes32 assignmentKey = cs.specimenToAssignment[specimenCollection][specimenTokenId];
        if (assignmentKey == bytes32(0)) {
            revert AugmentNotFound(0);
        }
        
        LibCollectionStorage.AugmentAssignment storage assignment = cs.augmentAssignments[assignmentKey];
        if (!assignment.active) {
            revert AugmentNotFound(assignment.tier);
        }
        
        if (assignment.unlockTime == 0) {
            revert PermanentLockCannotBeRemoved(assignment.augmentTokenId, assignment.augmentVariant);
        }
        
        if (additionalDuration > MAX_LOCK_DURATION) {
            revert LockDurationTooLong(additionalDuration, MAX_LOCK_DURATION);
        }
        
        bool isAdminOperation = _isAuthorized();
        uint256 extensionFee = 0;
        
        if (!isAdminOperation) {
            LibCollectionStorage.AugmentFeeConfig storage feeConfig = cs.augmentFeeConfigs[assignment.tier];
            if (feeConfig.feeActive && feeConfig.extensionFee.amount > 0) {
                uint256 extensionDays = (additionalDuration + 1 days - 1) / 1 days;
                extensionFee = feeConfig.extensionFee.amount * extensionDays;
                
                LibFeeCollection.collectFee(
                    feeConfig.extensionFee.currency,
                    LibMeta.msgSender(),
                    feeConfig.extensionFee.beneficiary,
                    extensionFee,
                    "extend_augment_lock"
                );
            }
        }
        
        assignment.unlockTime += additionalDuration;
        assignment.totalFeePaid += extensionFee;
        
        LibCollectionStorage.TokenLock storage tokenLock = cs.tokenLocks[assignment.augmentCollection][assignment.augmentTokenId];
        tokenLock.unlockTime += additionalDuration;
        tokenLock.lockFee += extensionFee;

        emit AugmentLockExtended(specimenCollection, specimenTokenId, additionalDuration, extensionFee);
    }
    
    // ==================== INTERNAL HELPER FUNCTIONS ====================

    /**
     * @notice Validate both tokens have same owner as transaction initiator
     * @dev Ensures augment collections can only operate when both tokens belong to tx.origin
     * @param specimenCollection Specimen collection address
     * @param specimenTokenId Specimen token ID
     * @param augmentCollection Augment collection address
     * @param augmentTokenId Augment token ID
     */
    function _validateCrossOwnership(
        address specimenCollection,
        uint256 specimenTokenId,
        address augmentCollection,
        uint256 augmentTokenId
    ) internal view {
        address specimenOwner = _getTokenOwner(specimenCollection, specimenTokenId);
        address augmentOwner = _getTokenOwner(augmentCollection, augmentTokenId);
        
        if (specimenOwner != augmentOwner || specimenOwner == address(0)) {
            revert TokensMustHaveSameOwner();
        }
    }

    /**
     * @notice Get effective token owner (including staked tokens)
     * @dev Returns the actual controller of the token, whether directly owned or staked
     * @param collection Collection contract address
     * @param tokenId Token ID to check
     * @return owner Effective owner address (address(0) if token doesn't exist)
     */
    function _getTokenOwner(address collection, uint256 tokenId) internal view returns (address) {
        try IERC721(collection).ownerOf(tokenId) returns (address owner) {
            address stakingAddr = LibCollectionStorage.collectionStorage().stakingSystemAddress;
            if (stakingAddr != address(0) && owner == stakingAddr) {
                try IStaking(stakingAddr).getTokenStaker(collection, tokenId) returns (address staker) {
                    return staker;
                } catch {
                    return owner;
                }
            }
            return owner;
        } catch {
            return address(0);
        }
    }

    function _validateAugmentCompatibility(
        address specimenCollection,
        address augmentCollection
    ) internal view {
        
        uint256 collectionId = LibCollectionStorage.getCollectionIdByAddress(specimenCollection);
        
        // Skip for external collections
        if (collectionId == 0 || !LibCollectionStorage.isInternalCollection(collectionId)) {
            return;
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Check restrictions
        if (!cs.augmentRestrictions[collectionId]) {
            return; // No restrictions
        }
        
        // Check if allowed
        if (!cs.allowedAugments[collectionId][augmentCollection]) {
            revert AugmentNotAllowed(collectionId, augmentCollection);
        }
    }

    /**
     * @notice Get augment configuration with collection-scoped trait pack support
     * @dev Enhanced to check collection-scoped trait packs first, then fall back to existing logic
     */
    function _getAugmentConfiguration(
        address augmentCollection,
        uint256 augmentTokenId
    ) internal view returns (AugmentConfig memory config) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Get collection ID for this augment collection
        uint256 collectionId = LibCollectionStorage.getCollectionIdByAddress(augmentCollection);
        
        // Get augment token's individual configuration first (EXISTING LOGIC - UNCHANGED)
        bytes32 tokenKey = keccak256(abi.encodePacked(augmentCollection, augmentTokenId));
        LibCollectionStorage.AugmentTokenConfig storage tokenConfig = cs.augmentTokenConfigs[tokenKey];
        
        if (tokenConfig.configured) {
            // Use individual token configuration (EXISTING - UNCHANGED)
            config.tier = tokenConfig.tier;
            config.shared = tokenConfig.shared;
            config.maxUsage = tokenConfig.maxUsage;
            config.configured = true;
            
            if (tokenConfig.customAccessories.length > 0) {
                config.accessoryIds = tokenConfig.customAccessories;
                config.variant = _deriveVariantFromAccessories(augmentCollection, tokenConfig.customAccessories);
            } else {
                config.variant = _getAugmentTokenVariant(augmentCollection, augmentTokenId);
                // ENHANCED: Try collection-scoped trait pack first
                config.accessoryIds = _getAccessories(collectionId, config.tier, config.variant, cs);
            }
        } else {
            // Use collection defaults (EXISTING + ENHANCED)
            LibCollectionStorage.AugmentCollectionConfig storage collectionConfig = cs.augmentCollections[augmentCollection];
            
            bool isRegistered = collectionConfig.active;
            
            if (!isRegistered) {
                if (collectionId == 0 || !LibCollectionStorage.collectionExists(collectionId)) {
                    revert CollectionNotSupported(augmentCollection);
                }
                
                config.tier = 1;
                config.shared = false;
                config.maxUsage = 0;
                config.configured = false;
            } else {
                config.tier = 1;
                config.shared = collectionConfig.shared;
                config.maxUsage = collectionConfig.maxUsagePerToken;
                config.configured = false;
            }
            
            config.variant = _getAugmentTokenVariant(augmentCollection, augmentTokenId);
            // ENHANCED: Try collection-scoped trait pack first
            config.accessoryIds = _getAccessories(collectionId, config.tier, config.variant, cs);
        }
        
        // Validate configuration exists
        if (config.accessoryIds.length == 0) {
            revert AugmentVariantNotConfigured(augmentCollection, config.tier, config.variant);
        }
        
        return config;
    }

    /**
     * @notice Get accessories for variant with collection-scoped priority
     * @dev Checks collection trait packs first, then falls back to tier-variant accessories
     */
    function _getAccessories(
        uint256 collectionId,
        uint8 tier,
        uint8 variant,
        LibCollectionStorage.CollectionStorage storage cs
    ) internal view returns (uint8[] memory accessoryIds) {
        // PRIORITY 1: Collection-scoped trait pack (NEW)
        if (collectionId > 0) {
            uint8 scopedTraitPackId = cs.collectionVariantToTraitPack[collectionId][variant];
            if (scopedTraitPackId > 0 && cs.collectionTraitPackExists[collectionId][scopedTraitPackId]) {
                LibCollectionStorage.CollectionTraitPack storage traitPack = cs.collectionTraitPacks[collectionId][scopedTraitPackId];
                if (traitPack.accessoryIds.length > 0) {
                    return traitPack.accessoryIds;
                }
            }
        }
        
        // PRIORITY 2: Tier-variant accessories (EXISTING)
        (address augmentCollection,, bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (exists && augmentCollection != address(0)) {
            uint8[] memory tierVariantAccessories = cs.tierVariantAccessories[augmentCollection][tier][variant];
            if (tierVariantAccessories.length > 0) {
                return tierVariantAccessories;
            }
        }
        
        // PRIORITY 3: Empty array (will trigger validation error)
        return new uint8[](0);
    }
        
    /**
     * @notice Get augment token's own variant (independent of specimen)
     * @dev This should query the augment collection for the token's variant
     * @param augmentCollection Augment collection address
     * @param augmentTokenId Augment token ID
     * @return variant Augment token's own variant
     */
    function _getAugmentTokenVariant(
        address augmentCollection,
        uint256 augmentTokenId
    ) internal view returns (uint8 variant) {
        // Try to get variant from augment collection itself
        try ISpecimenCollection(augmentCollection).itemVariant(augmentTokenId) returns (uint8 tokenVariant) {
            return tokenVariant > 0 ? tokenVariant : 1;
        } catch {
            // Fallback: derive from token ID using collection's variant distribution
            return _deriveVariantFromTokenId(augmentCollection, augmentTokenId);
        }
    }
    
    /**
     * @notice Derive variant from token ID based on collection's distribution
     * @dev Uses collection-specific logic to determine variant from token ID
     * @param augmentTokenId Augment token ID
     * @return variant Derived variant
     */
    function _deriveVariantFromTokenId(
        address,
        uint256 augmentTokenId
    ) internal pure returns (uint8 variant) {
        // Example logic for Henomorphs Augments v1 distribution
        // This should match the collection's actual variant distribution
        if (augmentTokenId <= 495) return 1;      // Variant 1: tokens 1-495
        if (augmentTokenId <= 915) return 2;      // Variant 2: tokens 496-915
        if (augmentTokenId <= 1275) return 3;     // Variant 3: tokens 916-1275
        return 4;                                 // Variant 4: tokens 1276-1500
    }
    
    /**
     * @notice Derive variant from accessories configuration
     * @dev Reverse lookup to find which variant uses these accessories
     * @param augmentCollection Augment collection address
     * @param accessories Array of accessory IDs
     * @return variant Variant that uses these accessories
     */
    function _deriveVariantFromAccessories(
        address augmentCollection,
        uint8[] memory accessories
    ) internal view returns (uint8 variant) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Check each variant to find matching accessories
        for (uint8 v = 1; v <= 4; v++) {
            uint8[] memory variantAccessories = cs.tierVariantAccessories[augmentCollection][1][v];
            if (_areAccessoryArraysEqual(accessories, variantAccessories)) {
                return v;
            }
        }
        
        return 1; // Fallback to variant 1
    }
    
    /**
     * @notice Get specimen variant (separate from augment variant)
     * @dev This is for specimen collection tokens only
     * @param specimenCollection Specimen collection address
     * @param specimenTokenId Specimen token ID
     * @return variant Specimen's own variant
     */
    function _getSpecimenVariant(address specimenCollection, uint256 specimenTokenId) internal view returns (uint8) {
        try ISpecimenCollection(specimenCollection).itemVariant(specimenTokenId) returns (uint8 variant) {
            return variant > 0 ? variant : 1;
        } catch {
            return 1;
        }
    }
    
    /**
     * @notice Validate augment assignment prerequisites
     */
    function _validateAugmentAssignment(
        address specimenCollection,
        uint256 specimenTokenId,
        address augmentCollection,
        uint256 augmentTokenId
    ) internal view {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Check if augment collection is valid (either registered or in unified system)
        bool isValidCollection = false;
        if (cs.augmentCollections[augmentCollection].active) {
            isValidCollection = true;
        } else {
            uint256 collectionId = LibCollectionStorage.getCollectionIdByAddress(augmentCollection);
            if (collectionId > 0 && LibCollectionStorage.collectionExists(collectionId)) {
                isValidCollection = true;
            }
        }
        
        if (!isValidCollection) {
            revert CollectionNotSupported(augmentCollection);
        }

        if (!_hasTokenAccess(augmentCollection, augmentTokenId) && !AccessHelper.isInternalCall()) {
            revert UnauthorizedAugmentOperation(LibMeta.msgSender(), augmentCollection, augmentTokenId);
        }
            
        bytes32 existingAssignment = cs.specimenToAssignment[specimenCollection][specimenTokenId];
        if (existingAssignment != bytes32(0) && cs.augmentAssignments[existingAssignment].active) {
            revert AugmentAlreadyAssigned(specimenCollection, specimenTokenId);
        }
        
        LibCollectionStorage.TokenLock storage lock = cs.tokenLocks[augmentCollection][augmentTokenId];
        if (lock.lockedBy != address(0) && lock.lockedBy != LibMeta.msgSender()) {
            if (!_isAuthorized()) {
                if (lock.permanentLock || block.timestamp < lock.unlockTime) {
                    revert AugmentLocked(
                        augmentCollection, 
                        augmentTokenId, 
                        lock.lockedBy, 
                        lock.unlockTime
                    );
                }
            }
        }

        _validateAugmentCompatibility(specimenCollection, augmentCollection);
    }
    
    /**
     * @notice Validate lock duration against tier configuration
     */
    function _validateLockDuration(uint8 tier, uint256 duration) internal view {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.AugmentFeeConfig storage feeConfig = cs.augmentFeeConfigs[tier];
        
        uint256 minDuration = feeConfig.feeActive && feeConfig.minLockDuration > 0 
            ? feeConfig.minLockDuration 
            : MIN_LOCK_DURATION;
            
        uint256 maxDuration = feeConfig.feeActive && feeConfig.maxLockDuration > 0 
            ? feeConfig.maxLockDuration 
            : MAX_LOCK_DURATION;
        
        if (duration < minDuration) {
            revert LockDurationTooShort(duration, minDuration);
        }
        
        if (duration > maxDuration) {
            revert LockDurationTooLong(duration, maxDuration);
        }
    }

    /**
     * @notice Check augment usage limits
     */
    function _checkAugmentUsageLimits(
        address augmentCollection,
        uint256 augmentTokenId,
        uint256 maxUsage
    ) internal view {
        if (maxUsage == 0) return;
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        bytes32 tokenKey = keccak256(abi.encodePacked(augmentCollection, augmentTokenId));
        
        LibCollectionStorage.AugmentTokenConfig storage config = cs.augmentTokenConfigs[tokenKey];
        if (config.currentUsage >= maxUsage) {
            revert AugmentUsageLimitExceeded(augmentTokenId, maxUsage);
        }
    }

    /**
     * @notice Process assignment payment
     */
    function _processAssignmentPayment(uint8 tier, uint256 lockDuration) internal returns (uint256 totalFee) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.AugmentFeeConfig storage feeConfig = cs.augmentFeeConfigs[tier];
        
        if (!feeConfig.feeActive || !feeConfig.requiresPayment) {
            return 0;
        }
        
        totalFee = feeConfig.assignmentFee.amount;
        
        uint256 lockDays = (lockDuration + 1 days - 1) / 1 days;
        totalFee += feeConfig.dailyLockFee.amount * lockDays;
        
        if (totalFee > 0) {
            LibFeeCollection.collectFee(
                feeConfig.assignmentFee.currency,
                LibMeta.msgSender(),
                feeConfig.assignmentFee.beneficiary,
                totalFee,
                "assign_augment"
            );
        }
        
        return totalFee;
    }

    /**
     * @notice Lock augment token
     */
    function _lockAugmentToken(
        address augmentCollection,
        uint256 augmentTokenId,
        address specimenCollection,
        uint256 specimenTokenId,
        uint256 lockDuration,
        uint256 lockFee,
        uint8,
        bool isRemovable
    ) internal {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        LibCollectionStorage.TokenLock storage lock = cs.tokenLocks[augmentCollection][augmentTokenId];
        lock.lockedBy = LibMeta.msgSender();
        lock.lockedForCollection = specimenCollection;
        lock.lockedForTokenId = specimenTokenId;
        lock.lockTime = block.timestamp;
        lock.lockFee = lockFee;
        lock.usageCount++;
        
        if (isRemovable) {
            lock.unlockTime = block.timestamp + lockDuration;
            lock.permanentLock = false;
        } else {
            lock.unlockTime = 0;
            lock.permanentLock = true;
        }
    }

    /**
     * @notice Create augment assignment record with separate variant tracking
     */
    function _createAugmentAssignmentRecord(
        address specimenCollection,
        uint256 specimenTokenId,
        address augmentCollection,
        uint256 augmentTokenId,
        uint8 augmentTier,
        uint8 augmentVariant,
        uint8 specimenVariant,
        uint256 lockDuration,
        uint256 totalFee,
        uint8[] memory accessoryIds,
        bool isRemovable
    ) internal returns (bytes32 assignmentKey) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        assignmentKey = keccak256(abi.encodePacked(
            specimenCollection,
            specimenTokenId,
            augmentCollection,
            augmentTokenId
        ));

        LibCollectionStorage.AugmentAssignment storage assignment = cs.augmentAssignments[assignmentKey];
        assignment.augmentCollection = augmentCollection;
        assignment.augmentTokenId = augmentTokenId;
        assignment.specimenCollection = specimenCollection;
        assignment.specimenTokenId = specimenTokenId;
        assignment.tier = augmentTier;
        assignment.augmentVariant = augmentVariant;     // Store augment's variant
        assignment.specimenVariant = specimenVariant;   // Store specimen's variant separately
        assignment.assignmentTime = block.timestamp;
        
        if (isRemovable) {
            assignment.unlockTime = block.timestamp + lockDuration;
        } else {
            assignment.unlockTime = 0;
        }
        
        assignment.active = true;
        assignment.totalFeePaid = totalFee;
        assignment.assignedAccessories = accessoryIds;
        
        cs.specimenToAssignment[specimenCollection][specimenTokenId] = assignmentKey;
        cs.augmentTokenToAssignment[augmentCollection][augmentTokenId] = assignmentKey;
        
        return assignmentKey;
    }

    /**
     * @notice Validate augment removability using augment variant
     */
    function _validateAugmentRemovability(
        address augmentCollection,
        uint8 augmentVariant
    ) internal view returns (bool removable) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (cs.variantAugmentConfigs[augmentCollection][augmentVariant].configured) {
            return cs.variantRemovabilityCache[augmentCollection][augmentVariant];
        }
        
        return cs.collectionDefaultRemovable[augmentCollection];
    }

    /**
     * @notice Notify specimen collection
     */
    function _notifySpecimenCollection(
        address specimenCollection,
        uint256 specimenTokenId,
        address augmentCollection,
        uint256 augmentTokenId,
        bool isAssignment
    ) internal {
        if (isAssignment) {
            try ISpecimenCollection(specimenCollection).onAugmentAssigned(
                specimenTokenId,
                augmentCollection,
                augmentTokenId
            ) {
                // Success
            } catch Error(string memory reason) {
                emit OperationResult("SpecimenCallbackAssign", false, reason);
            } catch {
                emit OperationResult("SpecimenCallbackAssign", false, "Unknown callback error");
            }
        } else {
            try ISpecimenCollection(specimenCollection).onAugmentRemoved(
                specimenTokenId,
                augmentCollection,
                augmentTokenId
            ) {
                // Success
            } catch Error(string memory reason) {
                emit OperationResult( "SpecimenCallbackRemove", false, reason);
            } catch {
                emit OperationResult("SpecimenCallbackRemove", false, "Unknown callback error");
            }
        }
    }

    /**
     * @notice Auto-create accessories
     */
    function _autoCreateAccessories(
        address specimenCollection,
        uint256 specimenTokenId,
        address augmentCollection,
        uint256 augmentTokenId,
        uint8[] memory accessoryIds,
        bytes32
    ) internal {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.AugmentCollectionConfig storage config = cs.augmentCollections[augmentCollection];
        
        if (!config.autoCreateAccessories || config.accessoryCollection == address(0)) {
            return;
        }
        
        uint256[] memory createdTokenIds = new uint256[](accessoryIds.length);
        
        for (uint256 i = 0; i < accessoryIds.length; i++) {
            uint8 accessoryId = accessoryIds[i];
            
            string memory tokenURI = string(abi.encodePacked(
                "accessory/", accessoryId.toString(), "/", specimenTokenId.toString()
            ));
            
            try IAccessoryCollection(config.accessoryCollection).mintAccessory(
                LibMeta.msgSender(),
                accessoryId,
                tokenURI
            ) returns (uint256 tokenId) {
                createdTokenIds[i] = tokenId;
                
                bytes32 recordKey = keccak256(abi.encodePacked(
                    config.accessoryCollection,
                    tokenId,
                    block.timestamp
                ));
                
                LibCollectionStorage.AccessoryCreationRecord storage record = cs.accessoryCreationRecords[recordKey];
                record.accessoryCollection = config.accessoryCollection;
                record.accessoryTokenId = tokenId;
                record.augmentCollection = augmentCollection;
                record.augmentTokenId = augmentTokenId;
                record.accessoryId = accessoryId;
                record.specimenCollection = specimenCollection;
                record.specimenTokenId = specimenTokenId;
                record.creationTime = block.timestamp;
                record.autoCreated = true;
                record.nested = config.autoNestAccessories;
                
                cs.specimenToAccessoryRecords[specimenCollection][specimenTokenId].push(recordKey);
                
            } catch {
                // Continue if minting fails
            }
        }
        
        if (createdTokenIds.length > 0) {
            emit AccessoriesAutoCreated(
                specimenCollection,
                specimenTokenId,
                config.accessoryCollection,
                createdTokenIds,
                accessoryIds
            );
        }
    }

    /**
     * @notice Unlock augment token
     */
    function _unlockAugmentToken(address augmentCollection, uint256 augmentTokenId) internal {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        LibCollectionStorage.TokenLock storage lock = cs.tokenLocks[augmentCollection][augmentTokenId];
        lock.lockedBy = address(0);
        lock.lockedForCollection = address(0);
        lock.lockedForTokenId = 0;
        lock.lockTime = 0;
        lock.unlockTime = 0;
        lock.permanentLock = false;
    }

    /**
     * @notice Remove auto-created accessories
     */
    function _removeAutoCreatedAccessories(
        address specimenCollection,
        uint256 specimenTokenId,
        bytes32
    ) internal {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        bytes32[] storage recordKeys = cs.specimenToAccessoryRecords[specimenCollection][specimenTokenId];
        
        for (uint256 i = 0; i < recordKeys.length; i++) {
            LibCollectionStorage.AccessoryCreationRecord storage record = cs.accessoryCreationRecords[recordKeys[i]];
            
            if (record.autoCreated && record.accessoryCollection != address(0)) {
                try IAccessoryCollection(record.accessoryCollection).burn(record.accessoryTokenId) {
                    // Successfully burned
                } catch {
                    // Continue if burn fails
                }
            }
        }
        
        delete cs.specimenToAccessoryRecords[specimenCollection][specimenTokenId];
    }

    /**
     * @notice Check if caller is registered augment collection
     */
    function _isRegisteredAugmentCollection(address caller) internal view returns (bool) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Check both augment registry and unified system
        if (cs.augmentCollections[caller].active) {
            return true;
        }
        
        uint256 collectionId = LibCollectionStorage.getCollectionIdByAddress(caller);
        return collectionId > 0 && LibCollectionStorage.collectionExists(collectionId);
    }

    /**
     * @notice Check if two accessory arrays are equal
     */
    function _areAccessoryArraysEqual(
        uint8[] memory array1,
        uint8[] memory array2
    ) internal pure returns (bool equal) {
        if (array1.length != array2.length) {
            return false;
        }
        
        for (uint256 i = 0; i < array1.length; i++) {
            if (array1[i] != array2[i]) {
                return false;
            }
        }
        
        return true;
    }
    
    // ==================== VIEW FUNCTIONS ====================

    /**
     * @notice Get augment information including accessories
     * @param collectionId Diamond collection ID
     * @param augmentTokenId Augment token ID
     * @return info Basic augment information with accessories
     */
    function getAugmentInfo(
        uint256 collectionId,
        uint256 augmentTokenId
    ) external view returns (AugmentInfo memory info) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Get collection address from unified system
        (address augmentCollection,, bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (!exists || augmentCollection == address(0)) {
            revert CollectionNotFound(collectionId);
        }
        
        // Validate collection
        bool isValidCollection = false;
        if (cs.augmentCollections[augmentCollection].active) {
            isValidCollection = true;
        } else if (LibCollectionStorage.collectionExists(collectionId)) {
            isValidCollection = true;
        }
        
        if (!isValidCollection) {
            revert CollectionNotSupported(augmentCollection);
        }
        
        // Get configuration with collection-scoped support
        AugmentConfig memory config = _getAugmentConfiguration(augmentCollection, augmentTokenId);
        
        // Get accessory details
        string[] memory accessoryNames = new string[](config.accessoryIds.length);
        for (uint256 i = 0; i < config.accessoryIds.length; i++) {
            uint8 accessoryId = config.accessoryIds[i];
            if (cs.accessoryExists[accessoryId]) {
                accessoryNames[i] = cs.accessoryDefinitions[accessoryId].name;
            } else {
                accessoryNames[i] = string(abi.encodePacked("Accessory #", Strings.toString(accessoryId)));
            }
        }
        
        // Check if assigned
        bytes32 assignmentKey = cs.augmentTokenToAssignment[augmentCollection][augmentTokenId];
        bool isAssigned = (assignmentKey != bytes32(0)) && cs.augmentAssignments[assignmentKey].active;
        
        info = AugmentInfo({
            tier: config.tier,
            variant: config.variant,
            accessoryIds: config.accessoryIds,
            accessoryNames: accessoryNames,
            isAssigned: isAssigned,
            isRemovable: _validateAugmentRemovability(augmentCollection, config.variant)
        });
    }
    
    /**
     * @notice Get assignment with proper variant separation
     */
    function getAssignment(
        address specimenCollection,
        uint256 specimenTokenId
    ) external view returns (LibCollectionStorage.AugmentAssignment memory assignment) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        bytes32 assignmentKey = cs.specimenToAssignment[specimenCollection][specimenTokenId];
        if (assignmentKey != bytes32(0)) {
            return cs.augmentAssignments[assignmentKey];
        }
        
        return LibCollectionStorage.AugmentAssignment({
            augmentCollection: address(0),
            augmentTokenId: 0,
            specimenCollection: address(0),
            specimenTokenId: 0,
            tier: 0,
            augmentVariant: 0,
            specimenVariant: 0,
            assignmentTime: 0,
            unlockTime: 0,
            active: false,
            totalFeePaid: 0,
            assignedAccessories: new uint8[](0)
        });
    }

    /**
     * @notice Get assignment by collection ID
     */
    function getAssignmentById(
        uint256 specimenCollectionId,
        uint256 specimenTokenId
    ) external view returns (LibCollectionStorage.AugmentAssignment memory assignment) {
        (address specimenCollection,, bool exists) = LibCollectionStorage.getCollectionInfo(specimenCollectionId);
        if (!exists || specimenCollection == address(0)) {
            return LibCollectionStorage.AugmentAssignment({
                augmentCollection: address(0),
                augmentTokenId: 0,
                specimenCollection: address(0),
                specimenTokenId: 0,
                tier: 0,
                augmentVariant: 0,
                specimenVariant: 0,
                assignmentTime: 0,
                unlockTime: 0,
                active: false,
                totalFeePaid: 0,
                assignedAccessories: new uint8[](0)
            });
        }

        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        bytes32 assignmentKey = cs.specimenToAssignment[specimenCollection][specimenTokenId];
        if (assignmentKey != bytes32(0)) {
            return cs.augmentAssignments[assignmentKey];
        }

        return LibCollectionStorage.AugmentAssignment({
            augmentCollection: address(0),
            augmentTokenId: 0,
            specimenCollection: address(0),
            specimenTokenId: 0,
            tier: 0,
            augmentVariant: 0,
            specimenVariant: 0,
            assignmentTime: 0,
            unlockTime: 0,
            active: false,
            totalFeePaid: 0,
            assignedAccessories: new uint8[](0)
        });
    }

    /**
     * @notice Get token lock information
     */
    function getTokenLock(address collection, uint256 tokenId)
        external view returns (LibCollectionStorage.TokenLock memory) {
        return LibCollectionStorage.collectionStorage().tokenLocks[collection][tokenId];
    }

    /**
     * @notice Get token lock information by collection ID
     */
    function getTokenLockById(uint256 collectionId, uint256 tokenId)
        external view returns (LibCollectionStorage.TokenLock memory) {
        (address collection,, bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (!exists || collection == address(0)) {
            return LibCollectionStorage.TokenLock({
                lockedBy: address(0),
                lockedForCollection: address(0),
                lockedForTokenId: 0,
                lockTime: 0,
                unlockTime: 0,
                lockFee: 0,
                permanentLock: false,
                usageCount: 0
            });
        }
        return LibCollectionStorage.collectionStorage().tokenLocks[collection][tokenId];
    }

    /**
     * @notice Check augment lock status for specimen
     * @param specimenCollectionId Specimen collection ID  
     * @param specimenTokenId Specimen token ID
     * @return lockInfo Complete lock status information
     */
    function getAugmentLockInfo(
        uint256 specimenCollectionId, 
        uint256 specimenTokenId
    ) external view returns (AugmentLockInfo memory lockInfo) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Get collection address from unified system
        (address specimenCollection,, bool exists) = LibCollectionStorage.getCollectionInfo(specimenCollectionId);
        if (!exists || specimenCollection == address(0)) {
            return AugmentLockInfo({
                hasAssignment: false,
                isLocked: false,
                isPermanent: false,
                unlockTime: 0,
                timeRemaining: 0
            });
        }
        
        bytes32 assignmentKey = cs.specimenToAssignment[specimenCollection][specimenTokenId];
        
        // No assignment found
        if (assignmentKey == bytes32(0)) {
            return AugmentLockInfo({
                hasAssignment: false,
                isLocked: false,
                isPermanent: false,
                unlockTime: 0,
                timeRemaining: 0
            });
        }
        
        LibCollectionStorage.AugmentAssignment storage assignment = cs.augmentAssignments[assignmentKey];
        
        // Inactive assignment
        if (!assignment.active) {
            return AugmentLockInfo({
                hasAssignment: false,
                isLocked: false,
                isPermanent: false,
                unlockTime: 0,
                timeRemaining: 0
            });
        }
        
        // Active assignment - check lock type
        bool isPermanent = assignment.unlockTime == 0;
        bool isLocked;
        uint256 timeRemaining = 0;
        
        if (isPermanent) {
            isLocked = true;
        } else {
            isLocked = block.timestamp < assignment.unlockTime;
            if (isLocked) {
                timeRemaining = assignment.unlockTime - block.timestamp;
            }
        }
        
        return AugmentLockInfo({
            hasAssignment: true,
            isLocked: isLocked,
            isPermanent: isPermanent,
            unlockTime: assignment.unlockTime,
            timeRemaining: timeRemaining
        });
    }

    /**
     * @notice Check if specimen has active augment (regardless of lock status)
     * @param specimenCollectionId Specimen collection ID
     * @param specimenTokenId Specimen token ID  
     * @return hasActive Whether specimen has active augment assignment
     */
    function hasActiveAugment(
        uint256 specimenCollectionId, 
        uint256 specimenTokenId
    ) external view returns (bool hasActive) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Get collection address from unified system
        (address specimenCollection,, bool exists) = LibCollectionStorage.getCollectionInfo(specimenCollectionId);
        if (!exists || specimenCollection == address(0)) {
            return false;
        }
        
        bytes32 assignmentKey = cs.specimenToAssignment[specimenCollection][specimenTokenId];
        
        if (assignmentKey == bytes32(0)) return false;
        
        return cs.augmentAssignments[assignmentKey].active;
    }

    /**
     * @notice Get augment token configuration
     */
    function getAugmentTokenConfiguration(
        address augmentCollection,
        uint256 augmentTokenId
    ) external view returns (AugmentConfig memory config) {
        return _getAugmentConfiguration(augmentCollection, augmentTokenId);
    }

    /**
     * @notice Get augment attachment details by collection ID and token ID
     * @dev Returns information about which specimen token an augment is attached to
     * @param augmentCollectionId Augment collection ID in the unified system
     * @param augmentTokenId Augment token ID
     * @return attachment Complete attachment information including specimen details and parameters
     */
    function getAugmentAttachment(
        uint256 augmentCollectionId,
        uint256 augmentTokenId
    ) external view returns (AugmentAttachment memory attachment) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();

        // Get collection address from unified system
        (address augmentCollection,, bool exists) = LibCollectionStorage.getCollectionInfo(augmentCollectionId);
        if (!exists || augmentCollection == address(0)) {
            return AugmentAttachment({
                isAttached: false,
                specimenCollection: address(0),
                specimenTokenId: 0,
                tier: 0,
                augmentVariant: 0,
                specimenVariant: 0,
                assignmentTime: 0,
                unlockTime: 0,
                isPermanent: false,
                totalFeePaid: 0,
                assignedAccessories: new uint8[](0)
            });
        }

        // Get assignment key for this augment token
        bytes32 assignmentKey = cs.augmentTokenToAssignment[augmentCollection][augmentTokenId];

        // No assignment found
        if (assignmentKey == bytes32(0)) {
            return AugmentAttachment({
                isAttached: false,
                specimenCollection: address(0),
                specimenTokenId: 0,
                tier: 0,
                augmentVariant: 0,
                specimenVariant: 0,
                assignmentTime: 0,
                unlockTime: 0,
                isPermanent: false,
                totalFeePaid: 0,
                assignedAccessories: new uint8[](0)
            });
        }

        LibCollectionStorage.AugmentAssignment storage assignment = cs.augmentAssignments[assignmentKey];

        // Inactive assignment
        if (!assignment.active) {
            return AugmentAttachment({
                isAttached: false,
                specimenCollection: address(0),
                specimenTokenId: 0,
                tier: 0,
                augmentVariant: 0,
                specimenVariant: 0,
                assignmentTime: 0,
                unlockTime: 0,
                isPermanent: false,
                totalFeePaid: 0,
                assignedAccessories: new uint8[](0)
            });
        }

        // Return full attachment details
        return AugmentAttachment({
            isAttached: true,
            specimenCollection: assignment.specimenCollection,
            specimenTokenId: assignment.specimenTokenId,
            tier: assignment.tier,
            augmentVariant: assignment.augmentVariant,
            specimenVariant: assignment.specimenVariant,
            assignmentTime: assignment.assignmentTime,
            unlockTime: assignment.unlockTime,
            isPermanent: assignment.unlockTime == 0,
            totalFeePaid: assignment.totalFeePaid,
            assignedAccessories: assignment.assignedAccessories
        });
    }
}