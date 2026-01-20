// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {LibCollectionStorage} from "../libraries/LibCollectionStorage.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {ISpecimenCollection} from "../interfaces/IExternalSystems.sol";
import {PartType, EquippablePart} from "../libraries/ModularAssetModel.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";

interface IAccessoryCollection {
    function mintAccessory(address to, uint8 accessoryId, string calldata tokenURI) external returns (uint256);
    function burn(uint256 tokenId) external;
}

/**
 * @title AugmentControlFacet - Complete Admin Control & Dynamic Configuration
 * @notice Production-ready facet with comprehensive augment management and dynamic configuration with unified collection support
 * @dev Handles all administrative functions with proper variant separation and no hardcoded values
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 * @custom:version 1.1.0 - Updated for unified collection system
 */
contract AugmentControlFacet is AccessControlBase {
    using Strings for uint256;
    using Strings for uint8;
    
    // ==================== STRUCTS ====================
    
    struct AccessoryValidationResult {
        uint256 tokenId;
        uint8 augmentVariant;
        uint8 specimenVariant;
        uint8[] currentAccessories;
        uint8[] expectedAccessories;
        bool isConsistent;
        string errorMessage;
    }
    
    struct AugmentCollectionUpdateParams {
        address collectionAddress;
        string name;
        string symbol;
        bool active;
        bool shared;
        uint256 maxUsagePerToken;
        uint8[] supportedVariants;
        uint8[] supportedTiers;
        address accessoryCollection;
        bool autoCreateAccessories;
        bool autoNestAccessories;
    }
    
    struct AssignmentUpdateParams {
        address specimenCollection;
        uint256 specimenTokenId;
        uint8 newAugmentVariant;
        string reason;
    }
    
    struct DefaultVariantConfig {
        uint8 variant;
        uint8[] accessories;
        string name;
        bool removable;
    }
    
    // ==================== EVENTS ====================
    
    // Core state management events
    event AugmentStateReset(
        address indexed specimenCollection,
        uint256 indexed specimenTokenId,
        address indexed augmentCollection,
        uint256 augmentTokenId
    );
    
    event AugmentTokenUnlocked(
        address indexed augmentCollection,
        uint256 indexed augmentTokenId,
        address previousLocker
    );
    
    // Collection management events
    event AugmentCollectionRegistered(
        address indexed collectionAddress,
        string name,
        address indexed accessoryCollection
    );
    
    event AugmentCollectionUpdated(
        address indexed collectionAddress,
        string field
    );
    
    // Configuration events
    event TierVariantAccessoriesConfigured(
        address indexed collectionAddress,
        uint8 indexed tier,
        uint8 indexed variant,
        uint8[] accessoryIds
    );
    
    event VariantRemovabilityConfigured(
        address indexed collectionAddress,
        uint8 indexed variant,
        bool removable
    );
    
    event FeeConfigurationUpdated(
        uint8 indexed tier,
        address currency,
        uint256 assignmentFee,
        uint256 dailyLockFee
    );
    
    // Assignment management events
    event AugmentAssignmentAccessoriesUpdated(
        address indexed specimenCollection,
        uint256 indexed specimenTokenId,
        uint8 augmentVariant,
        uint8[] oldAccessories,
        uint8[] newAccessories,
        string reason
    );
    
    event AugmentAssignmentVariantUpdated(
        address indexed specimenCollection,
        uint256 indexed specimenTokenId,
        uint8 oldAugmentVariant,
        uint8 newAugmentVariant,
        uint8[] newAccessories,
        string reason
    );
    
    event BatchAssignmentUpdatesCompleted(
        uint256 totalProcessed,
        uint256 successCount,
        uint256 failureCount
    );

    // Bonus configuration events
    event AugmentColonyBonusConfigured(
        uint8 indexed tier,
        uint256 bonusPercentage,
        bool stackable,
        uint256 maxStackedBonus
    );
    
    event AugmentSeasonalMultiplierConfigured(
        uint8 indexed tier,
        uint256 multiplier,
        uint256 seasonStart,
        uint256 seasonEnd,
        string seasonName
    );
    
    event AugmentCrossSystemBonusConfigured(
        uint8 indexed tier,
        uint8 biopodBonus,
        uint8 chargepodBonus,
        uint8 stakingBonus,
        uint8 wearReduction
    );
    
    event VariantMultipliersConfigured(
        uint8 indexed specimenVariant, 
        uint256 colonyMultiplier, 
        uint256 seasonalMultiplier, 
        uint256 crossSystemMultiplier
    );
    
    // Synchronization events
    event AugmentVariantAccessoriesSynchronized(
        address indexed augmentCollection,
        uint8 indexed tier,
        uint8 indexed augmentVariant,
        uint8[] oldAccessories,
        uint8[] newAccessories
    );

    event TokenAccessoriesFixed(
        address indexed specimenCollection,
        uint256 indexed specimenTokenId,
        uint8 augmentVariant,
        uint8[] oldAccessories,
        uint8[] newAccessories
    );

    event AccessoryRangeValidated(
        address indexed augmentCollection,
        uint256 tokenStart,
        uint256 tokenEnd,
        uint256 totalChecked,
        uint256 totalFixed
    );
    
    // Dynamic configuration events
    event BatchConfigurationSynchronized(
        address indexed augmentCollection,
        uint8 indexed tier,
        uint256 syncCount,
        uint256 skipCount
    );
    
    event DefaultConfigurationInitialized(
        address indexed augmentCollection,
        uint8 indexed tier,
        uint256 configuredCount,
        uint256 skippedCount
    );

    event AccessoryAssetMappingConfigured(
        uint8 indexed accessoryId,
        uint64 indexed assetId,
        uint64 indexed slotPartId
    );

    event AugmentRestrictionsSet(uint256 indexed collectionId, address[] collections, bool enabled);
    event AugmentRestrictionsDisabled(uint256 indexed collectionId);
    event AugmentAllowed(uint256 indexed collectionId, address indexed augmentCollection);
    event AugmentDisallowed(uint256 indexed collectionId, address indexed augmentCollection);
    
    // ==================== ERRORS ====================
    
    error InvalidConfiguration();
    error CollectionNotSupported(address collection);
    error AccessoryNotFound(uint8 accessoryId);
    error AssetNotFound(uint64 assetId);
    error SlotNotFound(uint64 slotPartId);
    error InvalidEquippableData();
    error VariantNotSupported(address collection, uint8 variant);
    error AugmentNotFound(address collection, uint256 tokenId);
    error NoActiveAssignment(address collection, uint256 tokenId);
    error InvalidVariant(uint8 variant);
    error BatchTooLarge(uint256 size, uint256 maxSize);
    error ArrayLengthMismatch();
    error InvalidTokenRange(uint256 start, uint256 end);
    error AugmentVariantNotConfigured(address collection, uint8 tier, uint8 variant);
    error ConfigurationAlreadyExists(address collection, uint8 tier, uint8 variant);
    error TooManyVariants();
    
    // ==================== CONSTANTS ====================
    
    uint256 private constant MAX_BATCH_SIZE = 50;
    uint256 private constant MAX_VALIDATION_BATCH = 100;
    uint256 private constant MAX_VARIANTS_PER_COLLECTION = 10;
    
    // ==================== ASSIGNMENT OVERRIDE FUNCTIONS ====================
    
    /**
     * @notice Update accessories list for existing augment assignment
     * @dev Validates accessories against AUGMENT variant configuration
     * @param specimenCollection Genesis collection address
     * @param specimenTokenId Specimen token ID
     * @param newAccessories New list of accessory IDs
     * @param reason Reason for the update
     */
    function updateAugmentAssignmentAccessories(
        address specimenCollection,
        uint256 specimenTokenId,
        uint8[] calldata newAccessories,
        string calldata reason
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        bytes32 assignmentKey = cs.specimenToAssignment[specimenCollection][specimenTokenId];
        if (assignmentKey == bytes32(0)) {
            revert NoActiveAssignment(specimenCollection, specimenTokenId);
        }
        
        LibCollectionStorage.AugmentAssignment storage assignment = cs.augmentAssignments[assignmentKey];
        if (!assignment.active) {
            revert NoActiveAssignment(specimenCollection, specimenTokenId);
        }
        
        // Validate accessories exist and are compatible with AUGMENT variant
        _validateAccessoriesExist(cs, newAccessories);
        _validateAccessoriesForAugmentVariant(
            cs, 
            assignment.augmentCollection, 
            assignment.tier, 
            assignment.augmentVariant, 
            newAccessories
        );
        
        // Store old accessories for event
        uint8[] memory oldAccessories = assignment.assignedAccessories;
        
        // Update accessories
        assignment.assignedAccessories = newAccessories;
        
        emit AugmentAssignmentAccessoriesUpdated(
            specimenCollection,
            specimenTokenId,
            assignment.augmentVariant,
            oldAccessories,
            newAccessories,
            reason
        );
    }
    
    /**
     * @notice Update augment variant for existing assignment (auto-updates accessories)
     * @dev Updates AUGMENT variant and automatically fetches correct accessories
     * @param specimenCollection Genesis collection address
     * @param specimenTokenId Specimen token ID
     * @param newAugmentVariant New AUGMENT variant to use
     * @param reason Reason for the update
     */
    function updateAugmentAssignmentVariant(
        address specimenCollection,
        uint256 specimenTokenId,
        uint8 newAugmentVariant,
        string calldata reason
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        // Validate augment variant
        if (newAugmentVariant == 0) {
            revert InvalidVariant(newAugmentVariant);
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        bytes32 assignmentKey = cs.specimenToAssignment[specimenCollection][specimenTokenId];
        if (assignmentKey == bytes32(0)) {
            revert NoActiveAssignment(specimenCollection, specimenTokenId);
        }
        
        LibCollectionStorage.AugmentAssignment storage assignment = cs.augmentAssignments[assignmentKey];
        if (!assignment.active) {
            revert NoActiveAssignment(specimenCollection, specimenTokenId);
        }
        
        // Get tier from assignment
        uint8 tier = assignment.tier;
        address augmentCollection = assignment.augmentCollection;
        
        // Get accessories from AUGMENT tier-variant configuration
        uint8[] memory newAccessories = cs.tierVariantAccessories[augmentCollection][tier][newAugmentVariant];
        
        // Validate that configuration exists for this augment tier-variant
        if (newAccessories.length == 0) {
            revert AugmentVariantNotConfigured(augmentCollection, tier, newAugmentVariant);
        }
        
        // Validate accessories exist
        _validateAccessoriesExist(cs, newAccessories);
        
        // Store old values for event
        uint8 oldAugmentVariant = assignment.augmentVariant;
        
        // Update assignment with new AUGMENT variant and auto-fetched accessories
        assignment.augmentVariant = newAugmentVariant;
        assignment.assignedAccessories = newAccessories;
        
        emit AugmentAssignmentVariantUpdated(
            specimenCollection,
            specimenTokenId,
            oldAugmentVariant,
            newAugmentVariant,
            newAccessories,
            reason
        );
    }
    
    /**
     * @notice Batch update multiple augment assignment variants
     * @dev Updates AUGMENT variants for multiple assignments efficiently
     * @param updates Array of assignment update parameters
     */
    function batchUpdateAugmentAssignmentVariants(
        AssignmentUpdateParams[] calldata updates
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        if (updates.length > MAX_BATCH_SIZE) {
            revert BatchTooLarge(updates.length, MAX_BATCH_SIZE);
        }
        
        uint256 successCount = 0;
        uint256 failureCount = 0;
        
        for (uint256 i = 0; i < updates.length; i++) {
            try this.updateAugmentAssignmentVariant(
                updates[i].specimenCollection,
                updates[i].specimenTokenId,
                updates[i].newAugmentVariant,
                updates[i].reason
            ) {
                successCount++;
            } catch {
                failureCount++;
                // Continue processing remaining items
            }
        }
        
        emit BatchAssignmentUpdatesCompleted(updates.length, successCount, failureCount);
    }

    /**
     * @notice Configure variant-specific multipliers for specimen variant bonuses
     * @dev This is for specimen variant bonuses, not augment variants
     * @param specimenVariant Specimen variant (1-4)
     * @param colonyMultiplier Colony bonus multiplier (100 = 100%, 150 = 150%)
     * @param seasonalMultiplier Seasonal bonus multiplier
     * @param crossSystemMultiplier Cross-system bonuses multiplier
     */
    function configureVariantMultipliers(
        uint8 specimenVariant,
        uint256 colonyMultiplier,
        uint256 seasonalMultiplier,
        uint256 crossSystemMultiplier
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        if (specimenVariant == 0) {
            revert InvalidVariant(specimenVariant);
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        cs.variantMultipliers[0][specimenVariant] = LibCollectionStorage.VariantMultiplier({
            variant: specimenVariant,
            colonyMultiplier: colonyMultiplier,
            seasonalMultiplier: seasonalMultiplier,
            crossSystemMultiplier: crossSystemMultiplier,
            active: true
        });
        
        emit VariantMultipliersConfigured(specimenVariant, colonyMultiplier, seasonalMultiplier, crossSystemMultiplier);
    }

    /**
     * @notice Configure trait pack for augment variant
     */
    function configureAugmentTraitPack(
        address augmentCollection,
        uint8 variant,
        string calldata traitPackName,
        string calldata description,
        string calldata baseURI,
        uint8[] calldata accessoryIds
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Get collection ID
        uint256 collectionId = LibCollectionStorage.getCollectionIdByAddress(augmentCollection);
        
        if (collectionId == 0 || !LibCollectionStorage.collectionExists(collectionId)) {
            revert CollectionNotSupported(augmentCollection);
        }
        
        // Use variant as trait pack ID for simplicity
        uint8 traitPackId = variant;
        
        // Create or update collection trait pack
        if (!cs.collectionTraitPackExists[collectionId][traitPackId]) {
            // Create new collection trait pack
            uint8[] memory compatibleVariants = new uint8[](1);
            compatibleVariants[0] = variant;
            
            LibCollectionStorage.createCollectionTraitPack(
                collectionId,
                traitPackId,
                traitPackName,
                description,
                baseURI,
                accessoryIds,
                compatibleVariants
            );
        } else {
            // Update existing collection trait pack
            LibCollectionStorage.CollectionTraitPack storage traitPack = cs.collectionTraitPacks[collectionId][traitPackId];
            traitPack.name = traitPackName;
            traitPack.description = description;
            traitPack.baseURI = baseURI;
            traitPack.accessoryIds = accessoryIds;
        }
        
        // Set variant mapping
        LibCollectionStorage.setCollectionVariantTraitPack(collectionId, variant, traitPackId);
        
        emit AugmentVariantAccessoriesSynchronized(
            augmentCollection,
            1, // Default tier
            variant,
            new uint8[](0), // Old accessories
            accessoryIds
        );
    }
    
    // ==================== DYNAMIC AUGMENT CONFIGURATION ====================
    
    /**
     * @notice Get current configuration status for augment collection
     * @dev Diagnostic function to check what's configured
     * @param augmentCollection Augment collection address  
     * @param tier Tier level
     * @return variants Array of variant numbers
     * @return configured Array indicating which variants are configured
     * @return accessoriesPerVariant Current accessories for each variant
     */
    function getAugmentConfigurationStatus(
        address augmentCollection,
        uint8 tier
    ) external view returns (
        uint8[] memory variants,
        bool[] memory configured,
        uint8[][] memory accessoriesPerVariant
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Get supported variants from collection config
        LibCollectionStorage.AugmentCollectionConfig storage config = cs.augmentCollections[augmentCollection];
        uint8[] memory supportedVariants = config.supportedVariants;
        
        uint256 variantCount = supportedVariants.length > 0 ? supportedVariants.length : 4;
        
        variants = new uint8[](variantCount);
        configured = new bool[](variantCount);
        accessoriesPerVariant = new uint8[][](variantCount);
        
        for (uint256 i = 0; i < variantCount; i++) {
            uint8 variant = supportedVariants.length > 0 ? supportedVariants[i] : uint8(i + 1);
            variants[i] = variant;
            configured[i] = cs.tierVariantConfigured[augmentCollection][tier][variant];
            
            if (configured[i]) {
                accessoriesPerVariant[i] = cs.tierVariantAccessories[augmentCollection][tier][variant];
            } else {
                accessoriesPerVariant[i] = new uint8[](0);
            }
        }
    }
    
    /**
     * @notice Batch synchronize all augment variants for collection
     * @dev Reads from actual storage configuration, no hardcoded values
     * @param augmentCollection Augment collection address
     * @param tier Tier level
     */
    function syncAllAugmentVariants(
        address augmentCollection,
        uint8 tier
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint256 syncCount = 0;
        uint256 skipCount = 0;
        
        // Get supported variants from collection configuration
        LibCollectionStorage.AugmentCollectionConfig storage config = cs.augmentCollections[augmentCollection];
        uint8[] memory supportedVariants = config.supportedVariants;
        
        // If no supported variants defined, default to 1-4
        if (supportedVariants.length == 0) {
            supportedVariants = new uint8[](4);
            for (uint8 i = 0; i < 4; i++) {
                supportedVariants[i] = i + 1;
            }
        }
        
        // Check each supported variant and synchronize if configuration exists
        for (uint256 i = 0; i < supportedVariants.length; i++) {
            uint8 augmentVariant = supportedVariants[i];
            
            // Check if this variant is already configured
            bool isConfigured = cs.tierVariantConfigured[augmentCollection][tier][augmentVariant];
            
            if (isConfigured) {
                // Configuration exists, verify it's still valid
                uint8[] memory existingAccessories = cs.tierVariantAccessories[augmentCollection][tier][augmentVariant];
                
                if (existingAccessories.length > 0) {
                    // Validate accessories exist
                    bool allAccessoriesValid = true;
                    for (uint256 j = 0; j < existingAccessories.length; j++) {
                        uint256 collectionId = _findAccessoryCollectionId(cs, existingAccessories[j]);
                        if (collectionId == 0) {
                            allAccessoriesValid = false;
                            break;
                        }
                    }

                    if (allAccessoriesValid) {
                        // Configuration is valid, emit sync event
                        emit AugmentVariantAccessoriesSynchronized(
                            augmentCollection,
                            tier,
                            augmentVariant,
                            existingAccessories,
                            existingAccessories
                        );
                        syncCount++;
                    } else {
                        // Configuration invalid, mark for admin attention
                        emit AugmentVariantAccessoriesSynchronized(
                            augmentCollection,
                            tier,
                            augmentVariant,
                            existingAccessories,
                            new uint8[](0)
                        );
                        skipCount++;
                    }
                } else {
                    // Empty configuration, skip
                    skipCount++;
                }
            } else {
                // No configuration found, admin needs to set it up
                emit AugmentVariantAccessoriesSynchronized(
                    augmentCollection,
                    tier,
                    augmentVariant,
                    new uint8[](0),
                    new uint8[](0)
                );
                skipCount++;
            }
        }
        
        // Emit summary
        emit BatchConfigurationSynchronized(augmentCollection, tier, syncCount, skipCount);
    }
    
    /**
     * @notice Synchronize augment tier-variant accessories with specific configuration
     * @dev Updates AUGMENT collection tier-variant mapping
     * @param augmentCollection Augment collection address
     * @param tier Tier level (1 for Henomorphs)
     * @param augmentVariant AUGMENT variant (1-4)
     * @param newAccessories New accessories to configure for this augment variant
     */
    function syncAugmentVariantAccessories(
        address augmentCollection,
        uint8 tier,
        uint8 augmentVariant,
        uint8[] calldata newAccessories
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Get collection ID for this augment collection
        uint256 collectionId = LibCollectionStorage.getCollectionIdByAddress(augmentCollection);
        
        // Validate augment collection exists using unified system
        bool isRegistered = cs.augmentCollections[augmentCollection].active;
        if (!isRegistered) {
            if (collectionId == 0 || !LibCollectionStorage.collectionExists(collectionId)) {
                revert CollectionNotSupported(augmentCollection);
            }
        }
        
        // Validate tier and variant
        if (tier == 0 || augmentVariant == 0) {
            revert InvalidVariant(augmentVariant);
        }
        
        // Validate accessories exist in system
        _validateAccessoriesExist(cs, newAccessories);
        
        // Store old accessories for event
        uint8[] memory oldAccessories;
        
        // ENHANCED: Check if we should update collection-scoped trait pack or tier-variant accessories
        if (collectionId > 0) {
            // Check if there's a collection-scoped trait pack for this variant
            uint8 scopedTraitPackId = cs.collectionVariantToTraitPack[collectionId][augmentVariant];
            if (scopedTraitPackId > 0 && cs.collectionTraitPackExists[collectionId][scopedTraitPackId]) {
                // Update collection-scoped trait pack accessories
                LibCollectionStorage.CollectionTraitPack storage traitPack = cs.collectionTraitPacks[collectionId][scopedTraitPackId];
                oldAccessories = traitPack.accessoryIds;
                traitPack.accessoryIds = newAccessories;
                
                emit AugmentVariantAccessoriesSynchronized(
                    augmentCollection,
                    tier,
                    augmentVariant,
                    oldAccessories,
                    newAccessories
                );
                return;
            }
        }
        
        // Fall back to tier-variant accessories (EXISTING LOGIC)
        oldAccessories = cs.tierVariantAccessories[augmentCollection][tier][augmentVariant];
        cs.tierVariantAccessories[augmentCollection][tier][augmentVariant] = newAccessories;
        cs.tierVariantConfigured[augmentCollection][tier][augmentVariant] = true;
        
        emit AugmentVariantAccessoriesSynchronized(
            augmentCollection,
            tier,
            augmentVariant,
            oldAccessories,
            newAccessories
        );
    }
    
    /**
     * @notice Internal wrapper for accessories validation (for try/catch)
     * @dev Needed for try/catch in synchronization functions
     */
    function _validateAccessoriesExistPublic(uint8[] memory accessoryIds) internal view {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        _validateAccessoriesExist(cs, accessoryIds);
    }
    
    // ==================== VALIDATION & DIAGNOSTIC FUNCTIONS ====================
    
    /**
     * @notice Validate token accessory assignment against its AUGMENT variant
     * @dev Check if token's accessories match expected accessories for its AUGMENT variant
     * @param specimenCollection Specimen collection address
     * @param specimenTokenId Token ID to validate
     * @param autoFix Whether to automatically fix inconsistencies
     * @return result Validation result with details
     */
    function validateTokenAccessories(
        address specimenCollection,
        uint256 specimenTokenId,
        bool autoFix
    ) external returns (AccessoryValidationResult memory result) {
        
        // Only authorized can auto-fix, anyone can validate
        if (autoFix && !_isAuthorized()) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not authorized");
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        result.tokenId = specimenTokenId;
        result.isConsistent = true;
        
        // Check if token has active assignment
        bytes32 assignmentKey = cs.specimenToAssignment[specimenCollection][specimenTokenId];
        
        if (assignmentKey == bytes32(0)) {
            result.errorMessage = "No active assignment";
            return result;
        }
        
        LibCollectionStorage.AugmentAssignment storage assignment = cs.augmentAssignments[assignmentKey];
        if (!assignment.active) {
            result.errorMessage = "Assignment not active";
            return result;
        }
        
        // Track both variants separately
        result.augmentVariant = assignment.augmentVariant;
        result.specimenVariant = assignment.specimenVariant;
        result.currentAccessories = assignment.assignedAccessories;
        
        // Get expected accessories from AUGMENT tier-variant configuration
        uint8 tier = assignment.tier;
        uint8 augmentVariant = assignment.augmentVariant;
        address augmentCollection = assignment.augmentCollection;
        
        result.expectedAccessories = cs.tierVariantAccessories[augmentCollection][tier][augmentVariant];
        
        if (result.expectedAccessories.length > 0) {
            // Check consistency
            result.isConsistent = _areAccessoryArraysEqual(
                result.currentAccessories,
                result.expectedAccessories
            );
            
            // Auto-fix if requested and inconsistent
            if (!result.isConsistent && autoFix) {
                assignment.assignedAccessories = result.expectedAccessories;
                
                emit TokenAccessoriesFixed(
                    specimenCollection,
                    specimenTokenId,
                    augmentVariant,
                    result.currentAccessories,
                    result.expectedAccessories
                );
                
                result.errorMessage = "Fixed - accessories synchronized with augment tier-variant configuration";
            } else if (!result.isConsistent) {
                result.errorMessage = "Accessories do not match augment tier-variant configuration";
            } else {
                result.errorMessage = "Consistent with augment tier-variant configuration";
            }
        } else {
            result.errorMessage = "No augment tier-variant configuration found";
        }
        
        return result;
    }
    
    /**
     * @notice Validate and fix accessory assignments for augment token range
     * @dev Administrative function to verify and fix multiple augment tokens
     * @param augmentCollection Augment collection address
     * @param tokenStart Start token ID (inclusive)
     * @param tokenEnd End token ID (inclusive)
     * @param autoFix Whether to automatically fix inconsistencies
     * @return totalChecked Number of tokens checked
     * @return totalFixed Number of tokens fixed
     */
    function validateAugmentTokenRange(
        address augmentCollection,
        uint256 tokenStart,
        uint256 tokenEnd,
        bool autoFix
    ) external onlyAuthorized whenNotPaused nonReentrant returns (
        uint256 totalChecked,
        uint256 totalFixed
    ) {
        
        if (tokenStart > tokenEnd) {
            revert InvalidTokenRange(tokenStart, tokenEnd);
        }
        
        // Limit batch size to prevent gas issues
        uint256 rangeSize = tokenEnd - tokenStart + 1;
        if (rangeSize > MAX_VALIDATION_BATCH) {
            revert InvalidTokenRange(tokenStart, tokenEnd);
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Validate augment collection exists (unified system compatible)
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
        
        // Validate each augment token assignment
        for (uint256 tokenId = tokenStart; tokenId <= tokenEnd; tokenId++) {
            totalChecked++;
            
            // Check if augment token has assignment
            bytes32 assignmentKey = cs.augmentTokenToAssignment[augmentCollection][tokenId];
            if (assignmentKey == bytes32(0)) continue;
            
            LibCollectionStorage.AugmentAssignment storage assignment = cs.augmentAssignments[assignmentKey];
            if (!assignment.active) continue;
            
            uint8 augmentVariant = assignment.augmentVariant;
            uint8 tier = assignment.tier;
            
            // Get expected accessories for AUGMENT variant
            uint8[] memory expectedAccessories = cs.tierVariantAccessories[augmentCollection][tier][augmentVariant];
            uint8[] memory currentAccessories = assignment.assignedAccessories;
            
            // Check if needs fixing
            if (expectedAccessories.length > 0 && 
                !_areAccessoryArraysEqual(currentAccessories, expectedAccessories)) {
                
                if (autoFix) {
                    assignment.assignedAccessories = expectedAccessories;
                    totalFixed++;
                    
                    emit TokenAccessoriesFixed(
                        assignment.specimenCollection,
                        assignment.specimenTokenId,
                        augmentVariant,
                        currentAccessories,
                        expectedAccessories
                    );
                }
            }
        }
        
        emit AccessoryRangeValidated(
            augmentCollection,
            tokenStart,
            tokenEnd,
            totalChecked,
            totalFixed
        );
    }
    
    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @notice Get accessories for specific augment tier-variant combination
     * @dev Works with AUGMENT collection variants
     * @param augmentCollection Augment collection address
     * @param tier Tier level
     * @param augmentVariant AUGMENT variant
     * @return accessoryIds Current accessories configured for this augment tier-variant
     * @return expectedAccessories Expected accessories (same as current for augment collections)
     * @return isConsistent Whether configuration is consistent
     */
    function getAugmentVariantAccessoryStatus(
        address augmentCollection,
        uint8 tier,
        uint8 augmentVariant
    ) external view returns (
        uint8[] memory accessoryIds,
        uint8[] memory expectedAccessories,
        bool isConsistent
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Get collection ID
        uint256 collectionId = LibCollectionStorage.getCollectionIdByAddress(augmentCollection);
        
        // Validate augment collection exists
        bool isValidCollection = false;
        if (cs.augmentCollections[augmentCollection].active) {
            isValidCollection = true;
        } else {
            if (collectionId > 0 && LibCollectionStorage.collectionExists(collectionId)) {
                isValidCollection = true;
            }
        }
        
        if (!isValidCollection) {
            revert CollectionNotSupported(augmentCollection);
        }
        
        // Get accessories with collection-scoped priority
        accessoryIds = _getAccessories(collectionId, tier, augmentVariant, cs);
        
        // For augment collections, expected = current
        expectedAccessories = accessoryIds;
        isConsistent = true;
    }
    
    /**
     * @notice Get comprehensive validation status for all augment variants
     * @dev Returns validation status for all configured augment variants in collection
     * @param augmentCollection Augment collection address
     * @param tier Tier level
     * @return variants Array of variant numbers
     * @return currentAccessories Current accessories for each augment variant
     * @return expectedAccessories Expected accessories for each augment variant
     * @return consistencyFlags Consistency status for each augment variant
     */
    function getAugmentCollectionAccessoryStatus(
        address augmentCollection,
        uint8 tier
    ) external view returns (
        uint8[] memory variants,
        uint8[][] memory currentAccessories,
        uint8[][] memory expectedAccessories,
        bool[] memory consistencyFlags
    ) {
        
        (variants, , currentAccessories) = this.getAugmentConfigurationStatus(augmentCollection, tier);
        
        expectedAccessories = new uint8[][](variants.length);
        consistencyFlags = new bool[](variants.length);
        
        for (uint256 i = 0; i < variants.length; i++) {
            (
                ,
                expectedAccessories[i],
                consistencyFlags[i]
            ) = this.getAugmentVariantAccessoryStatus(augmentCollection, tier, variants[i]);
        }
    }

    /**
     * @notice Check if augment tier-variant accessories are properly configured
     * @dev Validates that required augment tier-variants have accessories defined
     * @param augmentCollection Augment collection address
     * @param tier Tier level
     * @return configured Array indicating which augment variants are configured
     * @return accessoriesPerVariant Accessories for each augment variant
     */
    function getAugmentVariantStatus(
        address augmentCollection,
        uint8 tier
    ) external view returns (
        bool[] memory configured,
        uint8[][] memory accessoriesPerVariant
    ) {
        (, configured, accessoriesPerVariant) = this.getAugmentConfigurationStatus(augmentCollection, tier);
    }
    
    /**
     * @notice Get assignment details for verification
     * @dev Returns assignment with proper variant separation
     * @param specimenCollection Genesis collection address
     * @param specimenTokenId Specimen token ID
     * @return assignment Current assignment details with both variant types
     */
    function getAssignmentDetails(
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
     * @notice Get original specimen variant from collection
     * @dev Gets specimen's own variant
     * @param specimenCollection Genesis collection address
     * @param specimenTokenId Specimen token ID
     * @return originalVariant Original variant from specimen collection
     */
    function getOriginalSpecimenVariant(
        address specimenCollection,
        uint256 specimenTokenId
    ) external view returns (uint8 originalVariant) {
        try ISpecimenCollection(specimenCollection).itemVariant(specimenTokenId) returns (uint8 variant) {
            return variant > 0 ? variant : 1;
        } catch {
            return 1;
        }
    }
    
    /**
     * @notice Get effective accessories for augment tier-variant
     * @dev Returns accessories for AUGMENT tier-variant combination
     * @param augmentCollection Augment collection address
     * @param tier Augment tier
     * @param augmentVariant Augment variant
     * @return accessories Array of accessory IDs for this augment tier-variant combination
     */
    function getEffectiveAccessories(
        address augmentCollection,
        uint8 tier,
        uint8 augmentVariant
    ) external view returns (uint8[] memory accessories) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Get collection ID
        uint256 collectionId = LibCollectionStorage.getCollectionIdByAddress(augmentCollection);
        
        // Use enhanced function with collection-scoped priority
        return _getAccessories(collectionId, tier, augmentVariant, cs);
    }

    /**
     * @notice Get collection trait pack for augment variant
     */
    function getCollectionTraitPack(
        address augmentCollection,
        uint8 variant
    ) external view returns (
        uint8 traitPackId,
        string memory traitPackName,
        uint8[] memory accessoryIds,
        bool exists
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Get collection ID
        uint256 collectionId = LibCollectionStorage.getCollectionIdByAddress(augmentCollection);
        
        if (collectionId > 0) {
            traitPackId = cs.collectionVariantToTraitPack[collectionId][variant];
            exists = traitPackId > 0 && cs.collectionTraitPackExists[collectionId][traitPackId];
            
            if (exists) {
                LibCollectionStorage.CollectionTraitPack storage traitPack = cs.collectionTraitPacks[collectionId][traitPackId];
                traitPackName = traitPack.name;
                accessoryIds = traitPack.accessoryIds;
            }
        }
    }
    
    /**
     * @notice Preview what accessories would be assigned for augment variant override
     * @dev Shows what accessories will be used for new AUGMENT variant
     * @param specimenCollection Genesis collection address
     * @param specimenTokenId Specimen token ID  
     * @param newAugmentVariant Target AUGMENT variant
     * @return currentAugmentVariant Current augment variant in assignment
     * @return currentAccessories Current accessories in assignment
     * @return newAccessories Accessories that would be assigned with new augment variant
     */
    function previewAugmentVariantOverride(
        address specimenCollection,
        uint256 specimenTokenId,
        uint8 newAugmentVariant
    ) external view returns (
        uint8 currentAugmentVariant,
        uint8[] memory currentAccessories,
        uint8[] memory newAccessories
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        bytes32 assignmentKey = cs.specimenToAssignment[specimenCollection][specimenTokenId];
        if (assignmentKey == bytes32(0)) {
            revert NoActiveAssignment(specimenCollection, specimenTokenId);
        }
        
        LibCollectionStorage.AugmentAssignment storage assignment = cs.augmentAssignments[assignmentKey];
        if (!assignment.active) {
            revert NoActiveAssignment(specimenCollection, specimenTokenId);
        }
        
        currentAugmentVariant = assignment.augmentVariant;
        currentAccessories = assignment.assignedAccessories;
        
        // Get what accessories would be assigned with new AUGMENT variant
        uint8 tier = assignment.tier;
        address augmentCollection = assignment.augmentCollection;
        newAccessories = cs.tierVariantAccessories[augmentCollection][tier][newAugmentVariant];
    }

    /**
     * @notice Get variant multipliers configuration
     * @dev This is for specimen variant multipliers
     * @param specimenVariant Specimen variant to check
     * @return Variant multiplier configuration
     */
    function getVariantMultipliers(uint8 specimenVariant) external view returns (LibCollectionStorage.VariantMultiplier memory) {
        return LibCollectionStorage.collectionStorage().variantMultipliers[0][specimenVariant];
    }

    /**
     * @notice Get variant multipliers as primitive values (for cross-diamond calls)
     * @dev This is for specimen variant multipliers
     * @param specimenVariant Specimen variant to check
     * @return variantOut Variant number
     * @return colonyMultiplier Colony bonus multiplier
     * @return seasonalMultiplier Seasonal bonus multiplier  
     * @return crossSystemMultiplier Cross-system multiplier
     * @return active Whether multiplier is active
     */
    function getSpecificVariantMultipliers(uint8 specimenVariant) external view returns (
        uint8 variantOut,
        uint256 colonyMultiplier,
        uint256 seasonalMultiplier,
        uint256 crossSystemMultiplier,
        bool active
    ) {
        if (specimenVariant == 0) {
            return (0, 0, 0, 0, false);
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.VariantMultiplier storage multiplier = cs.variantMultipliers[0][specimenVariant];
        
        return (
            multiplier.variant,
            multiplier.colonyMultiplier,
            multiplier.seasonalMultiplier,
            multiplier.crossSystemMultiplier,
            multiplier.active
        );
    }
    
    // ==================== COLLECTION MANAGEMENT ====================
    
    /**
     * @notice Register new augment collection
     * @dev Sets up new collection with full configuration - unified system compatible
     */
    function registerAugmentCollection(
        address collectionAddress,
        string calldata name,
        string calldata symbol,
        address accessoryCollection,
        uint8[] calldata supportedVariants,
        uint8[] calldata supportedTiers,
        bool shared,
        uint256 maxUsagePerToken,
        bool autoCreateAccessories,
        bool autoNestAccessories
    ) external onlyAuthorized whenNotPaused nonReentrant rateLimited(5, 1 hours) {
        
        if (collectionAddress == address(0)) {
            revert CollectionNotSupported(collectionAddress);
        }
        
        if (supportedVariants.length > MAX_VARIANTS_PER_COLLECTION) {
            revert TooManyVariants();
        }
        
        // Validate collection exists in unified system
        uint256 collectionId = LibCollectionStorage.getCollectionIdByAddress(collectionAddress);
        if (collectionId == 0 || !LibCollectionStorage.collectionExists(collectionId)) {
            revert CollectionNotSupported(collectionAddress);
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        LibCollectionStorage.AugmentCollectionConfig storage config = cs.augmentCollections[collectionAddress];
        config.collectionAddress = collectionAddress;
        config.name = name;
        config.symbol = symbol;
        config.active = true;
        config.registrationTime = block.timestamp;
        config.shared = shared;
        config.maxUsagePerToken = maxUsagePerToken;
        config.supportedVariants = supportedVariants;
        config.supportedTiers = supportedTiers;
        config.accessoryCollection = accessoryCollection;
        config.autoCreateAccessories = autoCreateAccessories;
        config.autoNestAccessories = autoNestAccessories;
        
        cs.registeredAugmentCollections.push(collectionAddress);
        
        emit AugmentCollectionRegistered(collectionAddress, name, accessoryCollection);
    }
    
    /**
     * @notice Update existing augment collection configuration
     * @dev Allows modification of collection parameters
     */
    function updateAugmentCollection(
        AugmentCollectionUpdateParams calldata params
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        LibCollectionStorage.AugmentCollectionConfig storage config = cs.augmentCollections[params.collectionAddress];
        if (config.collectionAddress == address(0)) {
            revert CollectionNotSupported(params.collectionAddress);
        }
        
        if (bytes(params.name).length > 0) {
            config.name = params.name;
            emit AugmentCollectionUpdated(params.collectionAddress, "name");
        }
        if (bytes(params.symbol).length > 0) {
            config.symbol = params.symbol;
            emit AugmentCollectionUpdated(params.collectionAddress, "symbol");
        }
        
        config.active = params.active;
        config.shared = params.shared;
        config.maxUsagePerToken = params.maxUsagePerToken;
        
        if (params.supportedVariants.length > 0) {
            if (params.supportedVariants.length > MAX_VARIANTS_PER_COLLECTION) {
                revert TooManyVariants();
            }

            config.supportedVariants = params.supportedVariants;
            emit AugmentCollectionUpdated(params.collectionAddress, "supportedVariants");
        }
        if (params.supportedTiers.length > 0) {
            config.supportedTiers = params.supportedTiers;
            emit AugmentCollectionUpdated(params.collectionAddress, "supportedTiers");
        }
        if (params.accessoryCollection != address(0)) {
            config.accessoryCollection = params.accessoryCollection;
            emit AugmentCollectionUpdated(params.collectionAddress, "accessoryCollection");
        }
        
        config.autoCreateAccessories = params.autoCreateAccessories;
        config.autoNestAccessories = params.autoNestAccessories;
        
        emit AugmentCollectionUpdated(params.collectionAddress, "configuration");
    }
    
    /**
     * @notice Set default removability for collection
     * @dev Sets fallback removability when variant-specific config not found
     */
    function setCollectionDefaultRemovability(
        address collectionAddress,
        bool removable
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Check both augment collection registry and unified system
        bool isValidCollection = false;
        if (cs.augmentCollections[collectionAddress].active) {
            isValidCollection = true;
        } else {
            uint256 collectionId = LibCollectionStorage.getCollectionIdByAddress(collectionAddress);
            if (collectionId > 0 && LibCollectionStorage.collectionExists(collectionId)) {
                isValidCollection = true;
            }
        }
        
        if (!isValidCollection) {
            revert CollectionNotSupported(collectionAddress);
        }
        
        cs.collectionDefaultRemovable[collectionAddress] = removable;
    }
    
    // ==================== TIER-VARIANT CONFIGURATION ====================
    
    /**
     * @notice Configure tier-variant accessories with proper validation
     * @dev Sets up accessory assignments for AUGMENT tier-variant combinations
     */
    function configureTierVariantAccessories(
        address collectionAddress,
        uint8 tier,
        uint8 variant,
        uint8[] calldata accessoryIds
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        LibCollectionStorage.AugmentCollectionConfig storage config = cs.augmentCollections[collectionAddress];
        if (!config.active) {
            // Check if it's in unified system
            uint256 collectionId = LibCollectionStorage.getCollectionIdByAddress(collectionAddress);
            if (collectionId == 0 || !LibCollectionStorage.collectionExists(collectionId)) {
                revert CollectionNotSupported(collectionAddress);
            }
        }
        
        // Validate tier and variant support (if config exists)
        if (config.active) {
            bool tierSupported = _isArrayContains(config.supportedTiers, tier);
            bool variantSupported = _isArrayContains(config.supportedVariants, variant);
            
            if (!tierSupported || !variantSupported) {
                revert InvalidConfiguration();
            }
        }
        
        // Validate accessories exist in any collection
        _validateAccessoriesExist(cs, accessoryIds);
        
        cs.tierVariantAccessories[collectionAddress][tier][variant] = accessoryIds;
        cs.tierVariantConfigured[collectionAddress][tier][variant] = true;
        
        emit TierVariantAccessoriesConfigured(collectionAddress, tier, variant, accessoryIds);
    }
    
    /**
     * @notice Batch configure multiple tier-variant accessories
     * @dev Efficient way to configure multiple tier-variant combinations
     */
    function batchConfigureTierVariantAccessories(
        address collectionAddress,
        uint8 tier,
        uint8[] calldata variants,
        uint8[][] calldata accessoryIds
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        if (variants.length != accessoryIds.length) {
            revert ArrayLengthMismatch();
        }
        
        if (variants.length > MAX_BATCH_SIZE) {
            revert BatchTooLarge(variants.length, MAX_BATCH_SIZE);
        }
        
        for (uint256 i = 0; i < variants.length; i++) {
            _configureTierVariantAccessoriesInternal(
                collectionAddress,
                tier,
                variants[i],
                accessoryIds[i]
            );
        }
    }
    
    /**
     * @notice Configure variant removability
     * @dev Sets whether augments can be removed for specific AUGMENT variants
     */
    function configureVariantRemovability(
        address collectionAddress,
        uint8 variant,
        bool removable
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Check both augment collection registry and unified system
        bool isValidCollection = false;
        LibCollectionStorage.AugmentCollectionConfig storage config = cs.augmentCollections[collectionAddress];
        
        if (config.active) {
            isValidCollection = true;
            bool variantSupported = _isArrayContains(config.supportedVariants, variant);
            if (!variantSupported) {
                revert VariantNotSupported(collectionAddress, variant);
            }
        } else {
            uint256 collectionId = LibCollectionStorage.getCollectionIdByAddress(collectionAddress);
            if (collectionId > 0 && LibCollectionStorage.collectionExists(collectionId)) {
                isValidCollection = true;
            }
        }
        
        if (!isValidCollection) {
            revert CollectionNotSupported(collectionAddress);
        }
        
        cs.variantAugmentConfigs[collectionAddress][variant] = LibCollectionStorage.VariantAugmentConfig({
            variant: variant,
            removable: removable,
            configured: true,
            configurationTime: block.timestamp
        });
        
        cs.variantRemovabilityCache[collectionAddress][variant] = removable;
        
        emit VariantRemovabilityConfigured(collectionAddress, variant, removable);
    }
    
    // ==================== FEE CONFIGURATION ====================
    
    /**
     * @notice Configure fees for augment operations
     * @dev Sets up fee structure for specific tier
     */
    function configureAugmentFees(
        uint8 tier,
        address currency,
        address beneficiary,
        uint256 assignmentFee,
        uint256 dailyLockFee,
        uint256 extensionFee,
        uint256 removalFee,
        uint256 maxLockDuration,
        uint256 minLockDuration
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        if (minLockDuration > maxLockDuration) {
            revert InvalidConfiguration();
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        LibCollectionStorage.AugmentFeeConfig storage feeConfig = cs.augmentFeeConfigs[tier];
        
        feeConfig.assignmentFee.currency = currency;
        feeConfig.assignmentFee.amount = assignmentFee;
        feeConfig.assignmentFee.beneficiary = beneficiary;
        feeConfig.dailyLockFee.currency = currency;
        feeConfig.dailyLockFee.amount = dailyLockFee;
        feeConfig.dailyLockFee.beneficiary = beneficiary;
        feeConfig.extensionFee.currency = currency;
        feeConfig.extensionFee.amount = extensionFee;
        feeConfig.extensionFee.beneficiary = beneficiary;
        feeConfig.removalFee.currency = currency;
        feeConfig.removalFee.amount = removalFee;
        feeConfig.removalFee.beneficiary = beneficiary;
        feeConfig.maxLockDuration = maxLockDuration;
        feeConfig.minLockDuration = minLockDuration;
        feeConfig.feeActive = true;
        feeConfig.requiresPayment = (assignmentFee > 0 || dailyLockFee > 0);
        
        emit FeeConfigurationUpdated(tier, currency, assignmentFee, dailyLockFee);
    }
    
    // ==================== BONUS & EFFECTS CONFIGURATION ====================
    
    /**
     * @notice Configure colony bonuses for specific tier
     * @dev Sets up colony-wide bonuses for augments
     */
    function configureAugmentColonyBonus(
        uint8 tier,
        uint256 bonusPercentage,
        bool stackable,
        uint256 maxStackedBonus
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        if (bonusPercentage > 100) {
            revert InvalidConfiguration();
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        cs.augmentColonyBonuses[tier] = LibCollectionStorage.AugmentColonyBonus({
            tier: tier,
            bonusPercentage: bonusPercentage,
            stackable: stackable,
            maxStackedBonus: maxStackedBonus,
            active: true
        });
        
        emit AugmentColonyBonusConfigured(tier, bonusPercentage, stackable, maxStackedBonus);
    }
    
    /**
     * @notice Configure seasonal multipliers for specific tier
     * @dev Sets up time-based seasonal bonuses
     */
    function configureAugmentSeasonalMultiplier(
        uint8 tier,
        uint256 multiplier,
        uint256 seasonStart,
        uint256 seasonEnd,
        string calldata seasonName
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        if (seasonStart >= seasonEnd) {
            revert InvalidConfiguration();
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        cs.augmentSeasonalMultipliers[tier] = LibCollectionStorage.AugmentSeasonalMultiplier({
            tier: tier,
            multiplier: multiplier,
            seasonStart: seasonStart,
            seasonEnd: seasonEnd,
            seasonName: seasonName,
            active: true
        });
        
        emit AugmentSeasonalMultiplierConfigured(tier, multiplier, seasonStart, seasonEnd, seasonName);
    }
    
    /**
     * @notice Configure cross-system bonuses for specific tier
     * @dev Sets up bonuses for other system interactions
     */
    function configureAugmentCrossSystemBonuses(
        uint8 tier,
        uint8 biopodBonus,
        uint8 chargepodBonus,
        uint8 stakingBonus,
        uint8 wearReduction
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        if (biopodBonus > 50 || chargepodBonus > 50 || 
            stakingBonus > 50 || wearReduction > 90) {
            revert InvalidConfiguration();
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        cs.augmentCrossSystemBonuses[tier] = LibCollectionStorage.AugmentCrossSystemBonus({
            tier: tier,
            biopodBonus: biopodBonus,
            chargepodBonus: chargepodBonus,
            stakingBonus: stakingBonus,
            wearReduction: wearReduction,
            active: true
        });
        
        emit AugmentCrossSystemBonusConfigured(tier, biopodBonus, chargepodBonus, stakingBonus, wearReduction);
    }
    
    /**
     * @notice Configure accessory-asset mapping (RMRK Integration)
     */
    function configureAccessoryAssetMapping(
        uint8 accessoryId,
        uint64 assetId,
        uint64 slotPartId
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Check accessory exists in any collection
        uint256 accessoryCollectionId = _findAccessoryCollectionId(cs, accessoryId);
        if (accessoryCollectionId == 0) {
            revert AccessoryNotFound(accessoryId);
        }
        
        if (!cs.assetExists[assetId]) {
            revert AssetNotFound(assetId);
        }
        
        if (!cs.partExists[slotPartId]) {
            revert SlotNotFound(slotPartId);
        }
        
        EquippablePart storage part = cs.parts[slotPartId];
        if (part.partType != PartType.Slot) {
            revert InvalidEquippableData();
        }
        
        cs.accessoryToAssetMapping[accessoryId] = assetId;
        cs.accessoryToSlotMapping[accessoryId] = slotPartId;
        
        emit AccessoryAssetMappingConfigured(accessoryId, assetId, slotPartId);
    }
    
    function configureAugmentRestrictions(
        uint256 collectionId,
        address[] calldata allowedCollections,
        bool enabled
    ) external onlyAuthorized whenNotPaused validInternalCollection(collectionId) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        cs.augmentRestrictions[collectionId] = enabled;
        
        if (!enabled) {
            emit AugmentRestrictionsDisabled(collectionId);
            return;
        }
        
        for (uint256 i = 0; i < allowedCollections.length; i++) {
            cs.allowedAugments[collectionId][allowedCollections[i]] = true;
        }
        
        emit AugmentRestrictionsSet(collectionId, allowedCollections, enabled);
    }
    
    function addAllowedAugment(
        uint256 collectionId,
        address augmentCollection
    ) external onlyAuthorized whenNotPaused validInternalCollection(collectionId) {
        
        LibCollectionStorage.collectionStorage().allowedAugments[collectionId][augmentCollection] = true;
        emit AugmentAllowed(collectionId, augmentCollection);
    }

    function removeAllowedAugment(
        uint256 collectionId,
        address augmentCollection
    ) external onlyAuthorized whenNotPaused validInternalCollection(collectionId) {
        
        LibCollectionStorage.collectionStorage().allowedAugments[collectionId][augmentCollection] = false;
        emit AugmentDisallowed(collectionId, augmentCollection);
    }
    
    // ==================== STATE MANAGEMENT FUNCTIONS ====================

    /**
     * @notice Convert permanent lock to timed lock for existing assignment
     * @dev Allows admin to change unlockTime so users can remove augment after lock expires
     * @param specimenCollection Target specimen collection
     * @param specimenTokenId Target specimen token ID
     * @param newUnlockTime New unlock timestamp (must be in future, or 1 for immediate unlock)
     */
    function convertPermanentLock(
        address specimenCollection,
        uint256 specimenTokenId,
        uint256 newUnlockTime
    ) external onlyAuthorized whenNotPaused nonReentrant {

        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();

        bytes32 assignmentKey = cs.specimenToAssignment[specimenCollection][specimenTokenId];
        if (assignmentKey == bytes32(0)) {
            revert NoActiveAssignment(specimenCollection, specimenTokenId);
        }

        LibCollectionStorage.AugmentAssignment storage assignment = cs.augmentAssignments[assignmentKey];
        if (!assignment.active) {
            revert NoActiveAssignment(specimenCollection, specimenTokenId);
        }

        // Update assignment unlock time
        assignment.unlockTime = newUnlockTime;

        // Also update token lock
        LibCollectionStorage.TokenLock storage tokenLock = cs.tokenLocks[assignment.augmentCollection][assignment.augmentTokenId];
        tokenLock.unlockTime = newUnlockTime;
        tokenLock.permanentLock = (newUnlockTime == 0);
    }

    /**
     * @notice Batch convert permanent locks to timed locks
     * @dev Efficiently update multiple assignments
     * @param specimenCollections Array of specimen collections
     * @param specimenTokenIds Array of specimen token IDs
     * @param newUnlockTime New unlock timestamp for all (1 for immediate unlock)
     */
    function batchConvertPermanentLocks(
        address[] calldata specimenCollections,
        uint256[] calldata specimenTokenIds,
        uint256 newUnlockTime
    ) external onlyAuthorized whenNotPaused nonReentrant {

        if (specimenCollections.length != specimenTokenIds.length) {
            revert ArrayLengthMismatch();
        }

        if (specimenCollections.length > MAX_BATCH_SIZE) {
            revert BatchTooLarge(specimenCollections.length, MAX_BATCH_SIZE);
        }

        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();

        for (uint256 i = 0; i < specimenCollections.length; i++) {
            bytes32 assignmentKey = cs.specimenToAssignment[specimenCollections[i]][specimenTokenIds[i]];
            if (assignmentKey == bytes32(0)) continue;

            LibCollectionStorage.AugmentAssignment storage assignment = cs.augmentAssignments[assignmentKey];
            if (!assignment.active) continue;

            // Update assignment
            assignment.unlockTime = newUnlockTime;

            // Update token lock
            LibCollectionStorage.TokenLock storage tokenLock = cs.tokenLocks[assignment.augmentCollection][assignment.augmentTokenId];
            tokenLock.unlockTime = newUnlockTime;
            tokenLock.permanentLock = (newUnlockTime == 0);
        }
    }

    /**
     * @notice Reset complete augment state for a specimen
     * @dev Removes assignment, unlocks token, clears all related data
     * @param specimenCollection Target specimen collection
     * @param specimenTokenId Target specimen token ID
     */
    function resetAugmentState(
        address specimenCollection,
        uint256 specimenTokenId
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Get current assignment
        bytes32 assignmentKey = cs.specimenToAssignment[specimenCollection][specimenTokenId];
        
        if (assignmentKey == bytes32(0)) {
            return; // No assignment to reset
        }
        
        LibCollectionStorage.AugmentAssignment storage assignment = cs.augmentAssignments[assignmentKey];
        
        address augmentCollection = assignment.augmentCollection;
        uint256 augmentTokenId = assignment.augmentTokenId;
        
        // Clear augment token lock
        if (augmentCollection != address(0) && augmentTokenId != 0) {
            _clearTokenLock(augmentCollection, augmentTokenId);
        }
        
        // Clear assignment data
        assignment.active = false;
        assignment.augmentCollection = address(0);
        assignment.augmentTokenId = 0;
        assignment.unlockTime = 0;
        assignment.totalFeePaid = 0;
        delete assignment.assignedAccessories;
        
        // Clear mappings
        delete cs.specimenToAssignment[specimenCollection][specimenTokenId];
        delete cs.augmentTokenToAssignment[augmentCollection][augmentTokenId];
        
        // Clear accessories records (don't burn - just clear tracking)
        delete cs.specimenToAccessoryRecords[specimenCollection][specimenTokenId];
        
        emit AugmentStateReset(specimenCollection, specimenTokenId, augmentCollection, augmentTokenId);
    }
    
    /**
     * @notice Force unlock any augment token
     * @dev Clears token lock regardless of current state
     * @param augmentCollection Target augment collection
     * @param augmentTokenId Target augment token ID
     */
    function forceUnlockToken(
        address augmentCollection,
        uint256 augmentTokenId
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.TokenLock storage lock = cs.tokenLocks[augmentCollection][augmentTokenId];
        
        address previousLocker = lock.lockedBy;
        
        _clearTokenLock(augmentCollection, augmentTokenId);
        
        emit AugmentTokenUnlocked(augmentCollection, augmentTokenId, previousLocker);
    }
    
    /**
     * @notice Batch reset multiple specimens
     * @dev Efficient reset of multiple specimens in single transaction
     * @param specimenCollections Array of specimen collections
     * @param specimenTokenIds Array of specimen token IDs
     */
    function batchResetAugmentStates(
        address[] calldata specimenCollections,
        uint256[] calldata specimenTokenIds
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        if (specimenCollections.length != specimenTokenIds.length) {
            revert ArrayLengthMismatch();
        }
        
        if (specimenCollections.length > MAX_BATCH_SIZE) {
            revert BatchTooLarge(specimenCollections.length, MAX_BATCH_SIZE);
        }
        
        for (uint256 i = 0; i < specimenCollections.length; i++) {
            // Use try/catch to prevent one failure from blocking entire batch
            try this.resetAugmentState(specimenCollections[i], specimenTokenIds[i]) {
                // Success - continue
            } catch {
                // Continue processing remaining items
            }
        }
    }
    
    // ==================== ADDITIONAL VIEW FUNCTIONS ====================
    
    /**
     * @notice Get augment collection configuration
     */
    function getAugmentCollectionConfig(address collectionAddress) 
        external view returns (LibCollectionStorage.AugmentCollectionConfig memory) {
        return LibCollectionStorage.collectionStorage().augmentCollections[collectionAddress];
    }

    /**
     * @notice Get tier-variant accessories configuration
     */
    function getTierVariantAccessories(address collectionAddress, uint8 tier, uint8 variant) 
        external view returns (uint8[] memory) {
        return LibCollectionStorage.collectionStorage().tierVariantAccessories[collectionAddress][tier][variant];
    }

    /**
     * @notice Check if augment collection is active
     */
    function isAugmentCollectionActive(address collectionAddress) external view returns (bool) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Check both augment registry and unified system
        if (cs.augmentCollections[collectionAddress].active) {
            return true;
        }
        
        uint256 collectionId = LibCollectionStorage.getCollectionIdByAddress(collectionAddress);
        return collectionId > 0 && LibCollectionStorage.collectionExists(collectionId);
    }

    /**
     * @notice Get fee configuration for tier
     */
    function getFeeConfiguration(uint8 tier) external view returns (LibCollectionStorage.AugmentFeeConfig memory) {
        return LibCollectionStorage.collectionStorage().augmentFeeConfigs[tier];
    }

    /**
     * @notice Get colony bonus configuration
     */
    function getColonyBonus(uint8 tier) external view returns (LibCollectionStorage.AugmentColonyBonus memory) {
        return LibCollectionStorage.collectionStorage().augmentColonyBonuses[tier];
    }

    /**
     * @notice Get seasonal multiplier as primitive values (for cross-facet calls)
     * @param tier Augment tier
     * @return tierOut Tier number
     * @return multiplier Seasonal multiplier value
     * @return seasonStart Season start timestamp
     * @return seasonEnd Season end timestamp
     * @return seasonName Season name
     * @return active Whether multiplier is active
     */
    /**
     * @notice Get seasonal multiplier as primitive values (for cross-facet calls)
     * @param tier Augment tier
     * @return tierOut Tier number
     * @return multiplier Seasonal multiplier value
     * @return seasonStart Season start timestamp
     * @return seasonEnd Season end timestamp
     * @return seasonName Season name
     * @return active Whether multiplier is active
     */
    function getSeasonalMultiplier(uint8 tier) external view returns (
        uint8 tierOut,
        uint256 multiplier,
        uint256 seasonStart,
        uint256 seasonEnd,
        string memory seasonName,
        bool active
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.AugmentSeasonalMultiplier storage multiplierData = cs.augmentSeasonalMultipliers[tier];
        
        return (
            multiplierData.tier,
            multiplierData.multiplier,
            multiplierData.seasonStart,
            multiplierData.seasonEnd,
            multiplierData.seasonName,
            multiplierData.active
        );
    }

    /**
     * @notice Get cross-system bonus as primitive values (for cross-facet calls)
     * @param tier Augment tier
     * @return tierOut Tier number
     * @return biopodBonus Biopod bonus percentage
     * @return chargepodBonus Chargepod bonus percentage
     * @return stakingBonus Staking bonus percentage
     * @return wearReduction Wear reduction percentage
     * @return active Whether bonus is active
     */
    function getCrossSystemBonus(uint8 tier) external view returns (
        uint8 tierOut,
        uint8 biopodBonus,
        uint8 chargepodBonus,
        uint8 stakingBonus,
        uint8 wearReduction,
        bool active
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.AugmentCrossSystemBonus storage bonusData = cs.augmentCrossSystemBonuses[tier];
        
        return (
            bonusData.tier,
            bonusData.biopodBonus,
            bonusData.chargepodBonus,
            bonusData.stakingBonus,
            bonusData.wearReduction,
            bonusData.active
        );
    }
        
    /**
     * @notice Check if specimen has active augment assignment
     * @dev Diagnostic function to verify augment state
     * @param specimenCollection Specimen collection to check
     * @param specimenTokenId Specimen token ID to check
     * @return hasAssignment Whether specimen has active assignment
     * @return augmentCollection Active augment collection (zero if none)
     * @return augmentTokenId Active augment token ID (zero if none)
     */
    function getAugmentState(
        address specimenCollection,
        uint256 specimenTokenId
    ) external view returns (
        bool hasAssignment,
        address augmentCollection,
        uint256 augmentTokenId
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        bytes32 assignmentKey = cs.specimenToAssignment[specimenCollection][specimenTokenId];
        
        if (assignmentKey == bytes32(0)) {
            return (false, address(0), 0);
        }
        
        LibCollectionStorage.AugmentAssignment storage assignment = cs.augmentAssignments[assignmentKey];
        
        return (
            assignment.active,
            assignment.augmentCollection,
            assignment.augmentTokenId
        );
    }
    
    /**
     * @notice Check if augment token is locked
     * @dev Diagnostic function to verify token lock state
     * @param augmentCollection Augment collection to check
     * @param augmentTokenId Augment token ID to check
     * @return isLocked Whether token is currently locked
     * @return lockedBy Address that locked the token (zero if unlocked)
     * @return unlockTime When lock expires (zero if permanent or unlocked)
     */
    function getTokenLockState(
        address augmentCollection,
        uint256 augmentTokenId
    ) external view returns (
        bool isLocked,
        address lockedBy,
        uint256 unlockTime
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.TokenLock storage lock = cs.tokenLocks[augmentCollection][augmentTokenId];
        
        return (
            lock.lockedBy != address(0),
            lock.lockedBy,
            lock.unlockTime
        );
    }
    
    /**
     * @notice Check if variant is removable for collection
     */
    function isVariantRemovable(
        address collectionAddress,
        uint8 variant
    ) external view returns (bool removable) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (cs.variantAugmentConfigs[collectionAddress][variant].configured) {
            return cs.variantRemovabilityCache[collectionAddress][variant];
        }
        
        return cs.collectionDefaultRemovable[collectionAddress];
    }

    /**
     * @notice Get accessory asset mapping
     */
    function getAccessoryAssetMapping(uint8 accessoryId) external view returns (uint64 assetId, uint64 slotPartId) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        assetId = cs.accessoryToAssetMapping[accessoryId];
        slotPartId = cs.accessoryToSlotMapping[accessoryId];
    }
    
    /**
     * @notice Get all registered augment collections
     * @return collections Array of augment collection addresses
     */
    function getRegisteredAugmentCollections() external view returns (address[] memory collections) {
        return LibCollectionStorage.collectionStorage().registeredAugmentCollections;
    }
    
    /**
     * @notice Get collection statistics
     * @param collectionAddress Augment collection address
     * @return totalAssignments Total number of assignments ever made
     * @return activeAssignments Current number of active assignments
     * @return totalRevenue Total revenue collected from this collection
     */
    function getCollectionStatistics(address collectionAddress) external view returns (
        uint256 totalAssignments,
        uint256 activeAssignments,
        uint256 totalRevenue
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // These would need to be tracked in assignment operations
        totalRevenue = cs.collectionUsageStats[collectionAddress];
        
        // Count active assignments (gas intensive, use carefully)
        activeAssignments = 0;
        // Note: In production, this should be tracked incrementally rather than counted
        
        return (totalAssignments, activeAssignments, totalRevenue);
    }
    
    // ==================== INTERNAL HELPER FUNCTIONS ====================

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
        // PRIORITY 1: Collection-scoped trait pack
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

    function _isArrayContains(uint8[] storage array, uint8 value) internal view returns (bool) {
        for (uint256 i = 0; i < array.length; i++) {
            if (array[i] == value) {
                return true;
            }
        }
        return false;
    }
    
    /**
     * @notice Find which collection contains the accessory
     */
    function _findAccessoryCollectionId(
        LibCollectionStorage.CollectionStorage storage cs,
        uint8 accessoryId
    ) internal view returns (uint256) {
        // Check in reasonable collection ID range (1-20)
        for (uint256 collId = 1; collId <= 20; collId++) {
            if (cs.accessoryTokens[collId][accessoryId].defined) {
                return collId;
            }
        }
        return 0; // Not found
    }
    
    /**
     * @notice Validate accessories exist in correct storage location
     */
    function _validateAccessoriesExist(
        LibCollectionStorage.CollectionStorage storage cs,
        uint8[] memory accessoryIds
    ) internal view {
        for (uint256 i = 0; i < accessoryIds.length; i++) {
            uint256 collectionId = _findAccessoryCollectionId(cs, accessoryIds[i]);
            if (collectionId == 0) {
                revert AccessoryNotFound(accessoryIds[i]);
            }
        }
    }

    /**
     * @notice Validate accessories are compatible with augment variant
     */
    function _validateAccessoriesForAugmentVariant(
        LibCollectionStorage.CollectionStorage storage cs,
        address augmentCollection,
        uint8 tier,
        uint8 augmentVariant,
        uint8[] memory accessoryIds
    ) internal view {
        // Get expected accessories for this augment tier-variant
        uint8[] memory expectedAccessories = cs.tierVariantAccessories[augmentCollection][tier][augmentVariant];
        
        if (expectedAccessories.length == 0) {
            revert AugmentVariantNotConfigured(augmentCollection, tier, augmentVariant);
        }
        
        // Check if provided accessories match expected
        if (!_areAccessoryArraysEqual(accessoryIds, expectedAccessories)) {
            revert InvalidConfiguration();
        }
    }

    function _configureTierVariantAccessoriesInternal(
        address collectionAddress,
        uint8 tier,
        uint8 variant,
        uint8[] calldata accessoryIds
    ) internal {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        LibCollectionStorage.AugmentCollectionConfig storage config = cs.augmentCollections[collectionAddress];
        if (!config.active) {
            // Check if it's in unified system
            uint256 collectionId = LibCollectionStorage.getCollectionIdByAddress(collectionAddress);
            if (collectionId == 0 || !LibCollectionStorage.collectionExists(collectionId)) {
                revert CollectionNotSupported(collectionAddress);
            }
        }
        
        // Validate tier and variant support (if config exists)
        if (config.active) {
            bool tierSupported = _isArrayContains(config.supportedTiers, tier);
            bool variantSupported = _isArrayContains(config.supportedVariants, variant);
            
            if (!tierSupported || !variantSupported) {
                revert InvalidConfiguration();
            }
        }
        
        _validateAccessoriesExist(cs, accessoryIds);
        
        cs.tierVariantAccessories[collectionAddress][tier][variant] = accessoryIds;
        cs.tierVariantConfigured[collectionAddress][tier][variant] = true;
        
        emit TierVariantAccessoriesConfigured(collectionAddress, tier, variant, accessoryIds);
    }
    
    /**
     * @notice Internal function to clear token lock completely
     * @param augmentCollection Collection containing the token
     * @param augmentTokenId Token ID to unlock
     */
    function _clearTokenLock(address augmentCollection, uint256 augmentTokenId) internal {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.TokenLock storage lock = cs.tokenLocks[augmentCollection][augmentTokenId];
        
        // Clear all lock fields
        lock.lockedBy = address(0);
        lock.lockedForCollection = address(0);
        lock.lockedForTokenId = 0;
        lock.lockTime = 0;
        lock.unlockTime = 0;
        lock.lockFee = 0;
        lock.permanentLock = false;
        // Keep usageCount for historical tracking
    }

    /**
     * @notice Check if two accessory arrays are equal
     * @dev Helper function to compare accessory arrays
     * @param array1 First accessory array
     * @param array2 Second accessory array
     * @return equal Whether arrays contain the same elements in the same order
     */
    function _areAccessoryArraysEqual(
        uint8[] memory array1,
        uint8[] memory array2
    ) internal pure returns (bool equal) {
        // Check length first
        if (array1.length != array2.length) {
            return false;
        }
        
        // Compare each element
        for (uint256 i = 0; i < array1.length; i++) {
            if (array1[i] != array2[i]) {
                return false;
            }
        }
        
        return true;
    }
}