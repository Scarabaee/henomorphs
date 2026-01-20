// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {PodsUtils} from "../../../libraries/PodsUtils.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibTraitPackHelper} from "../libraries/LibTraitPackHelper.sol";
import {LibBiopodIntegration} from "../../staking/libraries/LibBiopodIntegration.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Calibration, SpecimenCollection, PowerMatrix, ChargeAccessory, ChargeActionType} from "../../../libraries/HenomorphsModel.sol";
import {ISpecimenBiopod} from "../../../interfaces/ISpecimenBiopod.sol";
import {AccessHelper} from "../../staking/libraries/AccessHelper.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {IStakingSystem} from "../../staking/interfaces/IStakingInterfaces.sol";
import {LibFeeCollection} from "../../staking/libraries/LibFeeCollection.sol";

// Interface for external collections
interface ISpecimenCollection {
    function itemVariant(uint256 tokenId) external view returns (uint8);
    function itemEquipments(uint256 tokenId) external view returns (uint8[] memory); // Returns multiple trait pack IDs
}

/**
 * @title BiopodFacet
 * @notice Handles biopod integration for henomorphs
 * @dev Uses AccessControlFacet for permission management
 */
contract BiopodFacet is AccessControlBase {
    using Math for uint256;

    // ============================================
    // INSPECTION CONSTANTS
    // ============================================

    uint256 private constant RECALIBRATION_MAX = 100;
    uint256 private constant MAX_LEVEL = 99;
    uint256 private constant DEFAULT_INTERACT_PERIOD = 12; // hours - must match HenomorphsBiopod CalibrationSettings

    
    // Events
    event ChargeUpdated(uint256 indexed collectionId, uint256 indexed tokenId, uint256 newCharge, uint256 maxCharge);
    event BatchSyncCompleted(uint256 indexed collectionId, uint256 processedCount);
    event BiopodAddressUpdated(uint256 indexed collectionId, address biopodAddress);
    event WearUpdated(uint256 indexed collectionId, uint256 indexed tokenId, uint256 oldWear, uint256 newWear);
    event WearRepairApplied(uint256 indexed collectionId, uint256 indexed tokenId, uint256 repairAmount);
    event TraitPackBoost(uint256 indexed collectionId, uint256 indexed tokenId, uint8 traitPackId, uint256 boostAmount);
    event InspectionHandled(uint256 indexed collectionId, uint256 indexed tokenId, uint256 kinship, uint256 level, uint256 experience);
    event CalibrationImported(uint256 indexed collectionId, uint256 indexed tokenId, address biopodSource);


    function getSpecimenData(uint256 collectionId, uint256 tokenId) external view returns (
        uint256 currentCharge,
        uint256 maxCharge,
        uint256 regenRate,
        uint8 specialization,
        uint8 evolutionLevel
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 _combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage _charge = hs.performedCharges[_combinedId];

        if (_charge.lastChargeTime == 0) {
            return (0, 0, 0, 0, 0);
        }

        return (
            _charge.currentCharge,
            _charge.maxCharge,
            _charge.regenRate,
            _charge.specialization,
            _charge.evolutionLevel
        );
    }

    /**
     * @notice Get calibration data from local storage (compatible with ISpecimenBiopod interface)
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return Calibration struct with data from local PowerMatrix storage
     */
    function probeCalibration(uint256 collectionId, uint256 tokenId) external view returns (Calibration memory) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 _combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage _charge = hs.performedCharges[_combinedId];

        // Get token owner
        address tokenOwner;
        if (collectionId > 0 && collectionId <= hs.collectionCounter) {
            SpecimenCollection storage _collection = hs.specimenCollections[collectionId];
            try IERC721(_collection.collectionAddress).ownerOf(tokenId) returns (address owner) {
                tokenOwner = owner;
            } catch {}
        }

        // Return default values if not initialized
        if (_charge.lastChargeTime == 0 && _charge.lastInteraction == 0) {
            return Calibration({
                tokenId: tokenId,
                owner: tokenOwner,
                kinship: 50,
                lastInteraction: 0,
                experience: 0,
                charge: 100,
                lastCharge: 0,
                level: 1,
                prowess: 1,
                wear: 0,
                lastRecalibration: 0,
                calibrationCount: 0,
                locked: false,
                agility: 10,
                intelligence: 10,
                bioLevel: 0
            });
        }

        // Calculate current kinship with decay
        uint256 currentKinship = _calculateCurrentKinship(_charge, hs);

        // Get actual wear level using unified function
        (uint256 actualWear, ) = LibBiopodIntegration.getUnifiedWearLevel(collectionId, tokenId);

        // Map PowerMatrix to Calibration using all new fields
        // Use fallback defaults for legacy tokens where new fields are 0
        return Calibration({
            tokenId: tokenId,
            owner: tokenOwner,
            kinship: currentKinship,
            lastInteraction: _charge.lastInteraction,
            experience: _charge.evolutionXP,
            charge: _charge.currentCharge,
            lastCharge: _charge.lastChargeTime,
            level: _charge.evolutionLevel,
            prowess: _charge.prowess > 0 ? _charge.prowess : 1,
            wear: actualWear,
            lastRecalibration: _charge.lastInteraction,
            calibrationCount: _charge.calibrationCount,
            locked: false,
            agility: _charge.agility > 0 ? _charge.agility : 10,
            intelligence: _charge.intelligence > 0 ? _charge.intelligence : 10,
            bioLevel: _charge.evolutionLevel
        });
    }

    /**
     * @dev Calculate current kinship with decay (view function for probeCalibration)
     */
    function _calculateCurrentKinship(
        PowerMatrix storage _charge,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) private view returns (uint256) {
        // Return stored kinship if no last interaction
        if (_charge.lastInteraction == 0) {
            return _charge.kinship > 0 ? _charge.kinship : 50;
        }

        uint256 interactPeriod = _getInteractPeriod(hs);
        uint256 interval = block.timestamp - _charge.lastInteraction;
        uint256 daysPassed = interval / (interactPeriod * 2 hours);

        uint256 currentKinship = _charge.kinship;
        return daysPassed >= currentKinship ? 0 : currentKinship - daysPassed;
    }

    /**
     * @notice Synchronize token with biopod (only for tokens without local calibration data)
     * @dev Imports full calibration data from legacy biopod - one-time operation
     * @param collectionId Collection ID
     * @param tokenId Henomorph token ID
     */
    function syncWithBiopod(uint256 collectionId, uint256 tokenId) public {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            revert LibHenomorphsStorage.InvalidCallData();
        }

        SpecimenCollection storage _collection = hs.specimenCollections[collectionId];
        if (!_collection.enabled) {
            revert LibHenomorphsStorage.CollectionNotEnabled(collectionId);
        }

        if (_collection.biopodAddress == address(0)) {
            revert LibBiopodIntegration.BiopodNotAvailable();
        }

        uint256 _combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage _charge = hs.performedCharges[_combinedId];

        // Block sync if token already has full calibration data
        // Check both timestamps to ensure no partial data exists
        if (_hasFullCalibrationData(_charge)) {
            revert LibHenomorphsStorage.ForbiddenRequest();
        }

        // Check if caller is system, admin, operator, biopod, or token owner
        IERC721 collection = IERC721(_collection.collectionAddress);
        address owner = collection.ownerOf(tokenId);

        if (owner != LibMeta.msgSender() && !AccessHelper.isAuthorized()) {
            revert LibHenomorphsStorage.ForbiddenRequest();
        }

        // Get calibration from Biopod
        Calibration memory _calibration;
        try ISpecimenBiopod(_collection.biopodAddress).probeCalibration(collectionId, tokenId) returns (Calibration memory cal) {
            _calibration = cal;
        } catch {
            revert LibBiopodIntegration.BiopodNotAvailable();
        }

        // Apply accessory effects to calibration data
        _calibration = LibBiopodIntegration.applyAccessoryEffectsToBiopod(
            collectionId,
            tokenId,
            _calibration,
            address(this)
        );

        // Initialize with data from external biopod
        uint8 _variant = LibTraitPackHelper.getValidTokenVariant(collectionId, tokenId);
        uint256 _baseMaxCharge = 80 + (_variant * 5) + _collection.maxChargeBonus;
        uint256 _adjustedRegenRate = hs.chargeSettings.baseRegenRate + _variant;
        _adjustedRegenRate = Math.mulDiv(_adjustedRegenRate, _collection.regenMultiplier, 100);

        // Set charge system fields
        _charge.maxCharge = uint128(_baseMaxCharge);
        _charge.regenRate = uint16(_adjustedRegenRate);
        _charge.chargeEfficiency = 100;
        _charge.specialization = 0;
        _charge.flags = 0;
        _charge.currentCharge = uint128(_calibration.charge);
        _charge.evolutionXP = _calibration.experience;
        _charge.evolutionLevel = uint8(_calibration.level > 0 ? _calibration.level : 1);
        _charge.fatigueLevel = uint8(_calibration.wear);
        _charge.lastChargeTime = uint32(block.timestamp);

        // Import all calibration-compatible fields (full parity with HenomorphsBiopod)
        _charge.kinship = uint8(_calibration.kinship > 0 ? _calibration.kinship : 50);
        _charge.prowess = uint8(_calibration.prowess > 0 ? _calibration.prowess : 1);
        _charge.agility = uint8(_calibration.agility > 0 ? _calibration.agility : 10);
        _charge.intelligence = uint8(_calibration.intelligence > 0 ? _calibration.intelligence : 10);
        _charge.calibrationCount = uint32(_calibration.calibrationCount);
        _charge.lastInteraction = uint32(block.timestamp);

        emit ChargeUpdated(collectionId, tokenId, _calibration.charge, _charge.maxCharge);
        emit CalibrationImported(collectionId, tokenId, _collection.biopodAddress);
    }

    /**
     * @dev Check if PowerMatrix has full calibration data (not just partial)
     * @return true if token has been fully initialized with calibration data
     */
    function _hasFullCalibrationData(PowerMatrix storage _charge) private view returns (bool) {
        // Token has full data if both timestamps are set OR if calibrationCount > 0
        // This ensures we don't re-sync tokens that have already been calibrated
        return (_charge.lastChargeTime != 0 && _charge.lastInteraction != 0) ||
               _charge.calibrationCount > 0;
    }

    /**
     * @notice ADMIN ONLY: Force sync token with biopod (bypasses permissions and existing data check)
     * @dev Imports ALL calibration fields from external biopod, overwriting local data
     * @param collectionId Collection ID
     * @param tokenId Token ID
     */
    function forceSyncWithBiopod(uint256 collectionId, uint256 tokenId) external onlyAuthorized {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            revert LibHenomorphsStorage.InvalidCallData();
        }

        SpecimenCollection storage _collection = hs.specimenCollections[collectionId];
        if (!_collection.enabled) {
            revert LibHenomorphsStorage.CollectionNotEnabled(collectionId);
        }

        if (_collection.biopodAddress == address(0)) {
            revert LibBiopodIntegration.BiopodNotAvailable();
        }

        // Get calibration from Biopod (admin bypass)
        Calibration memory _calibration;
        try ISpecimenBiopod(_collection.biopodAddress).probeCalibration(collectionId, tokenId) returns (Calibration memory cal) {
            _calibration = cal;
        } catch {
            // If biopod call fails, we can't sync
            revert LibBiopodIntegration.BiopodNotAvailable();
        }

        uint256 _combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage _charge = hs.performedCharges[_combinedId];

        // Apply accessory effects to calibration data
        _calibration = LibBiopodIntegration.applyAccessoryEffectsToBiopod(
            collectionId,
            tokenId,
            _calibration,
            address(this)
        );

        // Initialize base charge parameters if not exists
        if (_charge.maxCharge == 0) {
            uint8 _variant = LibTraitPackHelper.getValidTokenVariant(collectionId, tokenId);
            uint256 _baseMaxCharge = 80 + (_variant * 5) + _collection.maxChargeBonus;
            uint256 _adjustedRegenRate = hs.chargeSettings.baseRegenRate + _variant;
            _adjustedRegenRate = Math.mulDiv(_adjustedRegenRate, _collection.regenMultiplier, 100);

            _charge.maxCharge = uint128(_baseMaxCharge);
            _charge.regenRate = uint16(_adjustedRegenRate);
            _charge.chargeEfficiency = 100;
            _charge.specialization = 0;
            _charge.flags = 0;
        }

        // Force update ALL fields from external biopod (full parity with syncWithBiopod)
        _charge.currentCharge = uint128(_calibration.charge);
        _charge.evolutionXP = _calibration.experience;
        _charge.evolutionLevel = uint8(_calibration.level > 0 ? _calibration.level : 1);
        _charge.fatigueLevel = uint8(_calibration.wear);
        _charge.lastChargeTime = uint32(block.timestamp);

        // Import ALL calibration-compatible fields
        _charge.kinship = uint8(_calibration.kinship > 0 ? _calibration.kinship : 50);
        _charge.prowess = uint8(_calibration.prowess > 0 ? _calibration.prowess : 1);
        _charge.agility = uint8(_calibration.agility > 0 ? _calibration.agility : 10);
        _charge.intelligence = uint8(_calibration.intelligence > 0 ? _calibration.intelligence : 10);
        _charge.calibrationCount = uint32(_calibration.calibrationCount);
        _charge.lastInteraction = uint32(block.timestamp);

        emit ChargeUpdated(collectionId, tokenId, _calibration.charge, _charge.maxCharge);
        emit CalibrationImported(collectionId, tokenId, _collection.biopodAddress);
    }
            
    /**
     * @notice Batch sync multiple tokens with biopod
     * @param collectionId Collection ID
     * @param tokenIds Array of token IDs
     */
    function batchSyncWithBiopod(uint256 collectionId, uint256[] calldata tokenIds) external {
        if (collectionId == 0 || collectionId > LibHenomorphsStorage.henomorphsStorage().collectionCounter || tokenIds.length > 50) {
            revert LibHenomorphsStorage.InvalidCallData();
        }    
        
        uint256 processedCount = 0;
        uint256 failedCount = 0;
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            try this.syncWithBiopod(collectionId, tokenIds[i]) {
                processedCount++;
            } catch {
                failedCount++;
            }
        }
        
        emit BatchSyncCompleted(collectionId, processedCount);
    }
    
     /**
     * @notice Update biopod address for a collection (admin only)
     * @param collectionId Collection ID
     * @param biopodAddress New biopod address
     */
    function updateBiopodAddress(uint256 collectionId, address biopodAddress) external onlyAuthorized {
        // Remove the call to AccessHelper.requireAuthorized() as we now use the onlyAuthorized modifier
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        if (biopodAddress == address(0)) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        // Update biopod address
        hs.specimenCollections[collectionId].biopodAddress = biopodAddress;
        
        emit BiopodAddressUpdated(collectionId, biopodAddress);
    }
    
    /**
     * @notice Get biopod address for a collection
     * @param collectionId Collection ID
     * @return Biopod address
     */
    function getBiopodAddress(uint256 collectionId) external view returns (address) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        return hs.specimenCollections[collectionId].biopodAddress;
    }
    
    /**
     * @notice Check if a token has biopod calibration
     * @dev Prefers local data if exists, falls back to external biopod only if no local data
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return exists Whether calibration exists
     * @return calibration Calibration data
     */
    function checkBiopodCalibration(uint256 collectionId, uint256 tokenId) external view returns (bool exists, Calibration memory calibration) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            revert LibHenomorphsStorage.InvalidCallData();
        }

        SpecimenCollection storage _collection = hs.specimenCollections[collectionId];
        uint256 _combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage _charge = hs.performedCharges[_combinedId];

        // Get token owner
        IERC721 collection = IERC721(_collection.collectionAddress);
        address tokenOwner;
        try collection.ownerOf(tokenId) returns (address _owner) {
            tokenOwner = _owner;
        } catch {
            tokenOwner = address(0);
        }

        // PRIORITY: Return local data if token has full calibration data
        if (_hasFullCalibrationDataView(_charge)) {
            uint256 currentKinship = _calculateCurrentKinship(_charge, hs);

            // Get actual wear level using unified function
            (uint256 actualWear, ) = LibBiopodIntegration.getUnifiedWearLevel(collectionId, tokenId);

            return (true, Calibration({
                tokenId: tokenId,
                owner: tokenOwner,
                kinship: currentKinship,
                lastInteraction: _charge.lastInteraction,
                experience: _charge.evolutionXP,
                charge: _charge.currentCharge,
                lastCharge: _charge.lastChargeTime,
                level: _charge.evolutionLevel,
                prowess: _charge.prowess > 0 ? _charge.prowess : 1,
                wear: actualWear,
                lastRecalibration: _charge.lastInteraction,
                calibrationCount: _charge.calibrationCount,
                locked: false,
                agility: _charge.agility > 0 ? _charge.agility : 10,
                intelligence: _charge.intelligence > 0 ? _charge.intelligence : 10,
                bioLevel: _charge.evolutionLevel
            }));
        }

        // No local data - try external biopod (one-time fetch scenario)
        if (_collection.biopodAddress == address(0)) {
            return (false, _emptyCalibration(tokenId, tokenOwner));
        }

        try ISpecimenBiopod(_collection.biopodAddress).probeCalibration(collectionId, tokenId) returns (Calibration memory cal) {
            // Check if calibration has meaningful data
            if (cal.charge > 0 || cal.experience > 0 || cal.kinship > 0 || cal.level > 0) {
                return (true, cal);
            } else {
                return (false, cal);
            }
        } catch {
            return (false, _emptyCalibration(tokenId, tokenOwner));
        }
    }

    /**
     * @dev View helper to check if PowerMatrix has full calibration data
     */
    function _hasFullCalibrationDataView(PowerMatrix storage _charge) private view returns (bool) {
        return (_charge.lastChargeTime != 0 && _charge.lastInteraction != 0) ||
               _charge.calibrationCount > 0;
    }

    /**
     * @dev Helper to create empty calibration struct
     */
    function _emptyCalibration(uint256 tokenId, address tokenOwner) private pure returns (Calibration memory) {
        return Calibration({
            tokenId: tokenId,
            owner: tokenOwner,
            kinship: 0,
            lastInteraction: 0,
            experience: 0,
            charge: 0,
            lastCharge: 0,
            level: 0,
            prowess: 0,
            wear: 0,
            lastRecalibration: 0,
            calibrationCount: 0,
            locked: false,
            agility: 0,
            intelligence: 0,
            bioLevel: 0
        });
    }
    
    /**
     * @notice Apply wear repair to a henomorph token
     * @dev Internal use only - external users should use StakingWearFacet.repairTokenWear()
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param repairAmount Amount of wear to repair
     * @return success Whether repair was successful
     */
    function applyWearRepair(uint256 collectionId, uint256 tokenId, uint256 repairAmount) 
        external 
        whenNotPaused
        returns (bool success) 
    {
        if (collectionId == 0 || repairAmount == 0 || repairAmount > 100) {
            revert LibHenomorphsStorage.InvalidCallData();
        }

        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (collectionId > hs.collectionCounter || !hs.specimenCollections[collectionId].enabled) {
            revert LibHenomorphsStorage.CollectionNotEnabled(collectionId);
        }

        // Check authorization and collect fee
        _processRepairAuthorization(collectionId, tokenId, repairAmount, hs);

        return LibBiopodIntegration.applyWearRepair(collectionId, tokenId, repairAmount);
    }

    /**
     * @notice Update wear data for a henomorph token
     * @dev PRIMARY: Updates local storage. SECONDARY: Syncs to external biopod if available
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param wear New wear value (0-100)
     * @return success Whether update was successful
     */
    function updateWearData(uint256 collectionId, uint256 tokenId, uint256 wear) external returns (bool success) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        if (collectionId == 0 || collectionId > hs.collectionCounter || wear > 100) {
            revert LibHenomorphsStorage.InvalidCallData();
        }

        SpecimenCollection storage _collection = hs.specimenCollections[collectionId];

        // Check if caller is owner, admin, or system
        if (!AccessHelper.isAuthorized()) {
            // Check if caller is token owner
            IERC721 collection = IERC721(_collection.collectionAddress);
            address owner = collection.ownerOf(tokenId);

            if (owner != LibMeta.msgSender()) {
                revert LibHenomorphsStorage.ForbiddenRequest();
            }
        }

        uint256 _combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage _charge = hs.performedCharges[_combinedId];

        // PRIMARY: Update local storage
        uint256 oldWear = _charge.fatigueLevel;
        _charge.fatigueLevel = uint8(wear);

        emit WearUpdated(collectionId, tokenId, oldWear, wear);

        // SECONDARY: Try to sync to external biopod (non-blocking, for backwards compatibility)
        if (_collection.biopodAddress != address(0)) {
            try ISpecimenBiopod(_collection.biopodAddress).updateWearData(collectionId, tokenId, wear) {} catch {}
        }

        // Notify Staking system of wear change
        if (hs.stakingSystemAddress != address(0)) {
            try IStakingSystem(hs.stakingSystemAddress).notifyWearChange(collectionId, tokenId, wear) {} catch {}
        }

        return true;
    }
    
    /**
     * @notice Get current wear level from biopod
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return wearLevel Current wear level
     */
    function getWearLevel(uint256 collectionId, uint256 tokenId) external view returns (uint256 wearLevel) {
        // UPDATED: Use unified wear level function
        (wearLevel, ) = LibBiopodIntegration.getUnifiedWearLevel(collectionId, tokenId);
        return wearLevel;
    }
        
    /**
     * @notice Get token's trait packs
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return traitPacks Array of trait pack IDs
     */
    function getSpecimenTraitPacks(uint256 collectionId, uint256 tokenId) external view returns (uint8[] memory traitPacks) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            return new uint8[](0);
        }
        
        SpecimenCollection storage _collection = hs.specimenCollections[collectionId];
        
        try ISpecimenCollection(_collection.collectionAddress).itemEquipments(tokenId) returns (uint8[] memory _traitPacks) {
            return _traitPacks;
        } catch {
            return new uint8[](0);
        }
    }

    // ============================================
    // INSPECTION FUNCTIONS
    // ============================================

    /**
     * @notice Inspect multiple tokens - updates kinship and gains experience
     * @dev On first inspection, imports calibration data from legacy ISpecimenBiopod contract
     * @param collectionIds Array of collection IDs
     * @param tokenIds Array of token IDs (must match collectionIds length)
     * @return count Number of successfully inspected tokens
     */
    function inspect(uint256[] calldata collectionIds, uint256[] calldata tokenIds)
        external
        whenNotPaused
        returns (uint256 count)
    {
        if (collectionIds.length != tokenIds.length || collectionIds.length == 0) {
            revert LibHenomorphsStorage.InvalidCallData();
        }

        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        for (uint256 i = 0; i < collectionIds.length; i++) {
            if (_processInspection(collectionIds[i], tokenIds[i], hs)) {
                count++;
            }
        }

        // Collect fee for all successful inspections
        if (count > 0) {
            _collectInspectionFee(count);
        }
    }

    /**
     * @notice Inspect a single token
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return success Whether inspection was successful
     */
    function inspectSingle(uint256 collectionId, uint256 tokenId)
        external
        whenNotPaused
        returns (bool success)
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        if (_processInspection(collectionId, tokenId, hs)) {
            _collectInspectionFee(1);
            return true;
        }
        return false;
    }

    /**
     * @notice Inspect multiple tokens from a single collection
     * @dev More gas efficient than inspect() when all tokens are from the same collection
     * @param collectionId Collection ID
     * @param tokenIds Array of token IDs to inspect
     * @return count Number of successfully inspected tokens
     */
    function inspectCollection(uint256 collectionId, uint256[] calldata tokenIds)
        external
        whenNotPaused
        returns (uint256 count)
    {
        if (tokenIds.length == 0 || tokenIds.length > 50) {
            revert LibHenomorphsStorage.InvalidCallData();
        }

        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        // Validate collection once
        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            revert LibHenomorphsStorage.InvalidCallData();
        }

        SpecimenCollection storage _collection = hs.specimenCollections[collectionId];
        if (!_collection.enabled) {
            revert LibHenomorphsStorage.CollectionNotEnabled(collectionId);
        }

        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (_processInspection(collectionId, tokenIds[i], hs)) {
                count++;
            }
        }

        // Collect fee for all successful inspections
        if (count > 0) {
            _collectInspectionFee(count);
        }
    }

    /**
     * @notice Check if token can be inspected
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param operator Address to check authorization for
     * @return canInspect Whether inspection is possible
     * @return reason Reason if inspection not possible
     */
    function canInspect(uint256 collectionId, uint256 tokenId, address operator)
        external
        view
        returns (bool, string memory reason)
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        // Check pause state
        if (hs.paused) {
            return (false, "Contract is paused");
        }

        // Check collection validity
        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            return (false, "Invalid collection ID");
        }

        SpecimenCollection storage _collection = hs.specimenCollections[collectionId];
        if (!_collection.enabled) {
            return (false, "Collection is disabled");
        }

        // Check token authorization
        if (!_isTokenOperator(collectionId, tokenId, operator, hs)) {
            return (false, "Not authorized to inspect this token");
        }

        // Check cooldown using lastInteraction and configurable period
        uint256 _combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage _charge = hs.performedCharges[_combinedId];

        if (_charge.lastInteraction != 0) {
            uint256 interactPeriod = _getInteractPeriodView(hs);
            uint256 cooldownEnd = _charge.lastInteraction + (interactPeriod * 1 hours);
            if (block.timestamp < cooldownEnd) {
                return (false, "Cooldown period active");
            }
        }

        return (true, "Ready for inspection");
    }

    /**
     * @dev Get interact period for kinship calculations (view version)
     * @notice Uses actionTypes[1].cooldown but with minimum of 12h
     */
    function _getInteractPeriodView(LibHenomorphsStorage.HenomorphsStorage storage hs) private view returns (uint256) {
        ChargeActionType storage actionType = hs.actionTypes[1];
        if (actionType.cooldown > 0) {
            uint256 configuredPeriod = actionType.cooldown / 1 hours;
            return configuredPeriod < DEFAULT_INTERACT_PERIOD ? DEFAULT_INTERACT_PERIOD : configuredPeriod;
        }
        return DEFAULT_INTERACT_PERIOD;
    }

    /**
     * @dev Process a single inspection - full HenomorphsBiopod parity
     */
    function _processInspection(
        uint256 collectionId,
        uint256 tokenId,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) private returns (bool) {
        // Validate collection
        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            return false;
        }

        SpecimenCollection storage _collection = hs.specimenCollections[collectionId];
        if (!_collection.enabled) {
            return false;
        }

        // Check authorization
        if (!_isTokenOperator(collectionId, tokenId, LibMeta.msgSender(), hs)) {
            return false;
        }

        uint256 _combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage _charge = hs.performedCharges[_combinedId];

        // Get interact period from settings (default 1 hour if not set)
        uint256 interactPeriod = _getInteractPeriod(hs);

        // Check cooldown using lastInteraction (separate from lastChargeTime)
        if (_charge.lastInteraction != 0 &&
            block.timestamp < _charge.lastInteraction + (interactPeriod * 1 hours)) {
            return false;
        }

        // First inspection - import from legacy biopod if no full calibration data exists
        // Uses same check as syncWithBiopod to ensure one-time import
        if (!_hasFullCalibrationData(_charge)) {
            _importFromLegacyBiopod(collectionId, tokenId, _collection, _charge, hs);
        }

        // Get variant for experience calculation
        uint8 _variant = LibTraitPackHelper.getValidTokenVariant(collectionId, tokenId);

        // Calculate kinship with decay and update
        uint256 newKinship = _calculateUpdatedKinship(_charge, interactPeriod);
        _charge.kinship = uint8(newKinship);

        // Calculate experience gain with time bonus and first inspection bonus
        uint256 xpGain = _calculateExperienceGainFull(
            _variant,
            _charge.evolutionLevel,
            _charge.lastInteraction,
            _charge.calibrationCount
        );

        // Update evolution XP
        _charge.evolutionXP += xpGain;

        // Check for level up and update stats
        uint256 oldLevel = _charge.evolutionLevel;
        _checkLevelUpWithStats(_charge, _variant, tokenId);

        // Update timestamps and counters
        _charge.lastInteraction = uint32(block.timestamp);
        _charge.lastChargeTime = uint32(block.timestamp);
        _charge.calibrationCount += 1;

        // Small chance to repair wear (33%)
        if (_charge.fatigueLevel > 0 && _randomChance(tokenId, 33)) {
            _charge.fatigueLevel = _charge.fatigueLevel > 1 ? _charge.fatigueLevel - 1 : 0;

            // Notify Staking system of wear reduction
            if (hs.stakingSystemAddress != address(0)) {
                try IStakingSystem(hs.stakingSystemAddress).notifyWearChange(collectionId, tokenId, _charge.fatigueLevel) {} catch {}
            }
        }

        emit InspectionHandled(collectionId, tokenId, newKinship, _charge.evolutionLevel, xpGain);

        // Emit level up if occurred
        if (_charge.evolutionLevel > oldLevel) {
            emit ChargeUpdated(collectionId, tokenId, _charge.currentCharge, _charge.maxCharge);
        }

        return true;
    }

    /**
     * @dev Import calibration data from legacy ISpecimenBiopod contract
     */
    function _importFromLegacyBiopod(
        uint256 collectionId,
        uint256 tokenId,
        SpecimenCollection storage _collection,
        PowerMatrix storage _charge,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) private {
        // Calculate base charge values first
        uint8 _variant = LibTraitPackHelper.getValidTokenVariant(collectionId, tokenId);
        uint256 _baseMaxCharge = 80 + (_variant * 5) + _collection.maxChargeBonus;
        uint256 _adjustedRegenRate = hs.chargeSettings.baseRegenRate + _variant;
        _adjustedRegenRate = Math.mulDiv(_adjustedRegenRate, _collection.regenMultiplier, 100);

        // Always set core charge fields
        _charge.maxCharge = uint128(_baseMaxCharge);
        _charge.regenRate = uint16(_adjustedRegenRate);
        _charge.chargeEfficiency = 100;

        // Try to get data from legacy biopod
        if (_collection.biopodAddress != address(0)) {
            try ISpecimenBiopod(_collection.biopodAddress).probeCalibration(collectionId, tokenId) returns (Calibration memory cal) {
                // Import all relevant data including new fields
                _charge.currentCharge = uint128(cal.charge > 0 ? cal.charge : _baseMaxCharge);
                _charge.evolutionXP = cal.experience;
                _charge.evolutionLevel = uint8(cal.level > 0 ? cal.level : 1);
                _charge.fatigueLevel = uint8(cal.wear);
                // Import new calibration-compatible fields
                _charge.kinship = uint8(cal.kinship > 0 ? cal.kinship : 50);
                _charge.prowess = uint8(cal.prowess > 0 ? cal.prowess : 1);
                _charge.agility = uint8(cal.agility > 0 ? cal.agility : 10);
                _charge.intelligence = uint8(cal.intelligence > 0 ? cal.intelligence : 10);
                _charge.calibrationCount = uint32(cal.calibrationCount);

                emit CalibrationImported(collectionId, tokenId, _collection.biopodAddress);
            } catch {
                // Initialize with defaults if biopod call fails
                _initializeDefaults(collectionId, tokenId, _collection, _charge, hs);
            }
        } else {
            // No biopod, initialize with defaults
            _initializeDefaults(collectionId, tokenId, _collection, _charge, hs);
        }
    }

    /**
     * @dev Initialize PowerMatrix with default values
     */
    function _initializeDefaults(
        uint256 collectionId,
        uint256 tokenId,
        SpecimenCollection storage _collection,
        PowerMatrix storage _charge,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) private {
        uint8 _variant = LibTraitPackHelper.getValidTokenVariant(collectionId, tokenId);

        uint256 _baseMaxCharge = 80 + (_variant * 5) + _collection.maxChargeBonus;
        uint256 _adjustedRegenRate = hs.chargeSettings.baseRegenRate + _variant;
        _adjustedRegenRate = Math.mulDiv(_adjustedRegenRate, _collection.regenMultiplier, 100);

        _charge.currentCharge = uint128(_baseMaxCharge);
        _charge.maxCharge = uint128(_baseMaxCharge);
        _charge.regenRate = uint16(_adjustedRegenRate);
        _charge.chargeEfficiency = 100;
        _charge.evolutionLevel = 1;
        _charge.evolutionXP = 0;
        _charge.fatigueLevel = 0;
        _charge.specialization = 0;
        _charge.flags = 0;
        // Initialize new calibration-compatible fields
        _charge.kinship = 50;
        _charge.prowess = 1;
        _charge.agility = 10;
        _charge.intelligence = 10;
        _charge.calibrationCount = 0;
        _charge.lastInteraction = uint32(block.timestamp);
    }

    /**
     * @dev Get interact period for kinship calculations
     * @notice Uses actionTypes[1].cooldown but with minimum of DEFAULT_INTERACT_PERIOD (12h)
     * to match HenomorphsBiopod CalibrationSettings behavior
     */
    function _getInteractPeriod(LibHenomorphsStorage.HenomorphsStorage storage hs) private view returns (uint256) {
        ChargeActionType storage actionType = hs.actionTypes[1];
        if (actionType.cooldown > 0) {
            uint256 configuredPeriod = actionType.cooldown / 1 hours;
            // Minimum 12 hours for kinship decay to match HenomorphsBiopod
            return configuredPeriod < DEFAULT_INTERACT_PERIOD ? DEFAULT_INTERACT_PERIOD : configuredPeriod;
        }
        return DEFAULT_INTERACT_PERIOD;
    }

    /**
     * @dev Calculate kinship with decay and bonus for neglected tokens (HenomorphsBiopod parity)
     */
    function _calculateUpdatedKinship(PowerMatrix storage _charge, uint256 interactPeriod) private view returns (uint256) {
        uint256 currentKinship = _charge.kinship;

        // First interaction - no decay needed
        if (_charge.lastInteraction == 0) {
            currentKinship = currentKinship > 0 ? currentKinship : 50;
        } else {
            // Calculate decay: 1 kinship per (interactPeriod * 2 hours) since last interaction
            uint256 interval = block.timestamp - _charge.lastInteraction;
            uint256 daysPassed = interval / (interactPeriod * 2 hours);
            currentKinship = daysPassed >= currentKinship ? 0 : currentKinship - daysPassed;
        }

        // Standard tune value
        uint256 tuneValue = 1;

        // Neglect bonus: if kinship dropped below 40, give extra boost
        uint256 neglectBonus = (currentKinship < 40) ? tuneValue + 1 : 0;

        uint256 newKinship = currentKinship + tuneValue + neglectBonus;
        return (newKinship > RECALIBRATION_MAX) ? RECALIBRATION_MAX : newKinship;
    }

    /**
     * @dev Calculate experience gain with time bonus and first inspection bonus (HenomorphsBiopod parity)
     */
    function _calculateExperienceGainFull(
        uint8 variant,
        uint256 level,
        uint32 lastInteraction,
        uint32 calibrationCount
    ) private view returns (uint256) {
        // Base XP: 10 + (variant * 5)
        uint256 baseXP = 10 + (uint256(variant) * 5);

        // First inspection bonus: 3x XP
        if (calibrationCount == 0) {
            return baseXP * 3;
        }

        // Time bonus calculation
        uint256 timeFactor = 100;
        if (lastInteraction > 0) {
            uint256 daysSinceLastCalibration = (block.timestamp - lastInteraction) / 1 days;

            if (daysSinceLastCalibration > 1) {
                if (daysSinceLastCalibration <= 7) {
                    // Gradual increase: up to 150% for 7 days
                    timeFactor = 100 + ((daysSinceLastCalibration - 1) * 50 / 6);
                } else {
                    // Slower increase with sqrt: up to 200% cap
                    timeFactor = 150 + Math.sqrt((daysSinceLastCalibration - 7) * 100);
                    timeFactor = timeFactor > 200 ? 200 : timeFactor;
                }
            }
        }

        // Level scaling (reduce XP gain at higher levels)
        uint256 levelFactor = 100;
        if (level > 10) {
            if (level <= 50) {
                levelFactor = 100 - ((level - 10) * 50 / 40);
            } else {
                levelFactor = 50;
            }
        }

        return (baseXP * timeFactor * levelFactor) / 10000;
    }

    /**
     * @dev Check and process level up with stat increases (HenomorphsBiopod parity)
     */
    function _checkLevelUpWithStats(PowerMatrix storage _charge, uint8 variant, uint256 tokenId) private {
        uint256 currentXP = _charge.evolutionXP;
        uint8 currentLevel = _charge.evolutionLevel;
        uint8 newLevel = currentLevel;

        // Level formula: level^2 * 100 XP required
        for (uint8 i = currentLevel + 1; i <= MAX_LEVEL; i++) {
            uint256 requiredXP = uint256(i) * uint256(i) * 100;
            if (currentXP >= requiredXP) {
                newLevel = i;
            } else {
                break;
            }
        }

        if (newLevel > currentLevel) {
            // Update stats for each level gained
            for (uint8 i = currentLevel + 1; i <= newLevel; i++) {
                uint256 prowessGain = _variantStatGain(tokenId, variant, 0); // 0 = prowess
                uint256 agilityGain = _variantStatGain(tokenId, variant, 1); // 1 = agility
                uint256 intelligenceGain = _variantStatGain(tokenId, variant, 2); // 2 = intelligence

                _charge.prowess += uint8(prowessGain);
                _charge.agility += uint8(agilityGain);
                _charge.intelligence += uint8(intelligenceGain);
            }

            _charge.evolutionLevel = newLevel;
            // Increase max charge on level up
            _charge.maxCharge = uint128(uint256(_charge.maxCharge) + (newLevel - currentLevel) * 2);
        }
    }

    /**
     * @dev Calculate stat gain based on variant and stat type (HenomorphsBiopod parity)
     * @param statType 0 = prowess, 1 = agility, 2 = intelligence
     */
    function _variantStatGain(uint256 tokenId, uint8 variant, uint8 statType) private view returns (uint256) {
        // Base value by variant: 1=1, 2=2, 3=2, 4=3, else=1
        uint256 baseValue = variant == 1 ? 1 : variant == 2 ? 2 : variant == 3 ? 2 : variant == 4 ? 3 : 1;

        // Stat-specific bonuses
        if (statType == 0) { // prowess
            if (variant == 3 || variant == 4) baseValue += 1;
        } else if (statType == 1) { // agility
            if (variant == 2 || variant == 4) baseValue += 1;
        } else if (statType == 2) { // intelligence
            if (variant == 2 || variant == 4) baseValue += 1;
        }

        // Random factor: -1, 0, or +1
        uint256 randomFactor = uint256(keccak256(abi.encodePacked(block.timestamp, tokenId, statType))) % 3;
        if (randomFactor == 0 && baseValue > 0) {
            return baseValue - 1;
        } else if (randomFactor == 2) {
            return baseValue + 1;
        }
        return baseValue;
    }

    /**
     * @dev Random chance helper
     */
    function _randomChance(uint256 tokenId, uint256 percentage) private view returns (bool) {
        uint256 randomValue = uint256(keccak256(abi.encodePacked(block.timestamp, tokenId, LibMeta.msgSender()))) % 100;
        return randomValue < percentage;
    }

    /**
     * @dev Check if address is authorized to operate on token
     */
    function _isTokenOperator(
        uint256 collectionId,
        uint256 tokenId,
        address operator,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) private view returns (bool) {
        // Admin/system bypass
        if (AccessHelper.isAuthorized()) {
            return true;
        }

        SpecimenCollection storage _collection = hs.specimenCollections[collectionId];

        // Check staking first
        address stakingListener = hs.stakingSystemAddress;
        if (stakingListener != address(0)) {
            try IStakingSystem(stakingListener).isSpecimenStaked(collectionId, tokenId) returns (bool isStaked) {
                if (isStaked) {
                    try IStakingSystem(stakingListener).isTokenStaker(collectionId, tokenId, operator) returns (bool isStaker) {
                        if (isStaker) return true;
                    } catch {}
                }
            } catch {}
        }

        // Check direct ownership
        try IERC721(_collection.collectionAddress).ownerOf(tokenId) returns (address owner) {
            return owner == operator;
        } catch {
            return false;
        }
    }

    /**
     * @dev Collect inspection fee using standardized fee collection
     */
    function _collectInspectionFee(uint256 count) private {
        LibColonyWarsStorage.OperationFee storage inspectionFee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_INSPECTION);

        if (!inspectionFee.enabled || inspectionFee.baseAmount == 0) {
            return;
        }

        LibFeeCollection.processOperationFee(
            inspectionFee.currency,
            inspectionFee.beneficiary,
            inspectionFee.baseAmount,
            inspectionFee.multiplier,
            inspectionFee.burnOnCollect,
            inspectionFee.enabled,
            LibMeta.msgSender(),
            count,
            "inspection"
        );
    }

    /**
     * @dev Process repair authorization and fee collection
     */
    function _processRepairAuthorization(
        uint256 collectionId, 
        uint256 tokenId, 
        uint256 repairAmount,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) private {
        // Admin bypass
        if (AccessHelper.isAuthorized()) {
            return;
        }
        
        // Check token control (staked or unstaked)
        _checkTokenControl(collectionId, tokenId, hs);
        
        // Collect repair fee
        _collectRepairFee(repairAmount);
    }

    /**
     * @dev Check if caller has control over the token (based on ColonyHelper pattern)
     */
    function _checkTokenControl(
        uint256 collectionId, 
        uint256 tokenId,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) private view {
        address caller = LibMeta.msgSender();
        address stakingListener = hs.stakingSystemAddress;
        
        // Check if token is staked and caller is the staker
        if (stakingListener != address(0)) {
            try IStakingSystem(stakingListener).isSpecimenStaked(collectionId, tokenId) returns (bool isStaked) {
                if (isStaked) {
                    try IStakingSystem(stakingListener).isTokenStaker(collectionId, tokenId, caller) returns (bool isStaker) {
                        if (isStaker) {
                            return; // Caller is staker
                        }
                    } catch {
                        // Fall through to direct ownership check
                    }
                }
            } catch {
                // Fall through to direct ownership check
            }
        }
        
        // Check direct NFT ownership
        try IERC721(hs.specimenCollections[collectionId].collectionAddress).ownerOf(tokenId) returns (address owner) {
            if (owner != caller) {
                revert LibHenomorphsStorage.ForbiddenRequest();
            }
        } catch {
            revert LibHenomorphsStorage.TokenNotFound(tokenId);
        }
    }

    /**
     * @dev Collect repair fee using standardized fee collection
     */
    function _collectRepairFee(uint256 repairAmount) private {
        LibColonyWarsStorage.OperationFee storage wearRepairFee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_WEAR_REPAIR);

        // Use dual token wear repair fee (YELLOW with burn, 2x multiplier)
        LibFeeCollection.processOperationFee(
            wearRepairFee.currency,
            wearRepairFee.beneficiary,
            wearRepairFee.baseAmount,
            wearRepairFee.multiplier,  // Already 2x (200)
            wearRepairFee.burnOnCollect,
            wearRepairFee.enabled,
            LibMeta.msgSender(),
            repairAmount,  // multiplier per wear point
            "wear_repair"
        );
    }
}