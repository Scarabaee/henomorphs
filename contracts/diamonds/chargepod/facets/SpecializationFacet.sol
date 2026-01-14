// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {PodsUtils} from "../../libraries/PodsUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ControlFee, SpecimenCollection, PowerMatrix} from "../../libraries/HenomorphsModel.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {LibAchievementTrigger} from "../libraries/LibAchievementTrigger.sol";

// Interface for ChargeFacet
interface IChargeFacet {
    function recalibrateCore(uint256 collectionId, uint256 tokenId) external returns (uint256);
}

// Dodajemy interfejs na początku kontraktu
interface IStakingSystem {
    function isTokenStaker(uint256 collectionId, uint256 tokenId, address staker) external view returns (bool);
}
    
/**
 * @title SpecializationFacet
 * @notice Manages henomorph specializations
 * @dev Uses AccessControlFacet for permission management
 */
contract SpecializationFacet is AccessControlBase {
    using Math for uint256;
    
    // Events
    event SpecializationChanged(uint256 indexed collectionId, uint256 indexed tokenId, uint8 newSpecialization);

    /**
     * @dev Checks if caller has control over the henomorph token
     * @param collectionId Collection ID
     * @param tokenId Token ID
     */
    function _checkChargeEnabled(uint256 collectionId, uint256 tokenId) internal view {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        SpecimenCollection storage _collection = hs.specimenCollections[collectionId];
        if (!_collection.enabled) {
            revert LibHenomorphsStorage.CollectionNotEnabled(collectionId);
        }
        
        // Use standardized access control
        if (AccessHelper.authorizeForToken(collectionId, tokenId, hs.stakingSystemAddress)) {
            return; // Caller is authorized
        }
        
        // If we get here, the caller is not authorized
        revert LibHenomorphsStorage.HenomorphControlForbidden(collectionId, tokenId);
    }
    
    /**
     * @dev Modifier to check henomorph control permissions
     */
    modifier whenChargeEnabled(uint256 collectionId, uint256 tokenId) {
        _checkChargeEnabled(collectionId, tokenId);
        _;
    }

    /**
     * @notice Change specialization of a henomorph
     * @param collectionId Collection ID
     * @param tokenId Henomorph token ID
     * @param specialization New specialization (0=balanced, 1=efficiency, 2=regeneration)
     */
    function changeSpecialization(uint256 collectionId, uint256 tokenId, uint8 specialization) 
        external 
        whenChargeEnabled(collectionId, tokenId) 
    {
        if (specialization > 2) {
            revert LibHenomorphsStorage.InvalidSpecializationType();
        }

        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 _combinedId = PodsUtils.combineIds(collectionId, tokenId);
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        PowerMatrix storage _charge = hs.performedCharges[_combinedId];

        // Core activation check
        if (_charge.lastChargeTime == 0) { 
            revert LibHenomorphsStorage.PowerCoreNotActivated(collectionId, tokenId);
        }

        // Minimum maxCharge requirement
        if (_charge.maxCharge <= 80) {
            revert LibHenomorphsStorage.InsufficientCharge();
        }

        // Check if specialization change is needed
        if (_charge.specialization == specialization) {
            revert LibHenomorphsStorage.SpecializationAlreadySet();
        }

        // GET SPECIALIZATION CONFIG - replaces hardcoded values
        LibHenomorphsStorage.SpecializationConfig storage config = hs.specializationConfigs[specialization];
        
        // Check if specialization is enabled
        if (!config.enabled) {
            revert LibHenomorphsStorage.InvalidSpecializationType();
        }

        // Update power using ChargeFacet (call via address(this) for internal diamond call)
        try IChargeFacet(address(this)).recalibrateCore(collectionId, tokenId) returns (uint256) {
            // Success - power updated
        } catch {
            // Continue without power update if it fails
        }

        // Use dual token specialization fee (YELLOW with burn)
        LibColonyWarsStorage.OperationFee storage specializationFee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_SPECIALIZATION);
        LibFeeCollection.processOperationFee(
            specializationFee.currency,
            specializationFee.beneficiary,
            specializationFee.baseAmount,
            specializationFee.multiplier,
            specializationFee.burnOnCollect,
            specializationFee.enabled,
            LibMeta.msgSender(),
            1,  // single operation
            "specialization"
        );
        
        // Change specialization
        _charge.specialization = specialization;
        
        // Calculate base regen rate (safe because maxCharge > 80)
        uint16 baseRegenRate = uint16(hs.chargeSettings.baseRegenRate + (_charge.maxCharge - 80) / 5);
        
        // APPLY CONFIGURABLE MULTIPLIERS - replaces hardcoded logic
        _charge.regenRate = uint16(Math.mulDiv(baseRegenRate, config.regenMultiplier, 100));
        _charge.chargeEfficiency = config.efficiencyMultiplier;
        
        // Apply collection multiplier
        _charge.regenRate = uint16(Math.mulDiv(_charge.regenRate, collection.regenMultiplier, 100));
        
        emit SpecializationChanged(collectionId, tokenId, specialization);

        // Trigger specialization achievement
        LibAchievementTrigger.triggerSpecializationChange(LibMeta.msgSender());
    }

    /**
     * @notice Force change specialization of a henomorph (admin only)
     * @param collectionId Collection ID
     * @param tokenId Henomorph token ID
     * @param specialization New specialization (0=balanced, 1=efficiency, 2=regeneration)
     */
    function adminChangeSpecialization(uint256 collectionId, uint256 tokenId, uint8 specialization) 
        external 
        onlyAuthorized 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        if (specialization > 2) {
            revert LibHenomorphsStorage.InvalidSpecializationType();
        }

        // GET SPECIALIZATION CONFIG - replaces hardcoded values
        LibHenomorphsStorage.SpecializationConfig storage config = hs.specializationConfigs[specialization];
        
        if (!config.enabled) {
            revert LibHenomorphsStorage.InvalidSpecializationType();
        }

        uint256 _combinedId = PodsUtils.combineIds(collectionId, tokenId);
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        PowerMatrix storage _charge = hs.performedCharges[_combinedId];

        if (_charge.lastChargeTime == 0) { 
            revert LibHenomorphsStorage.PowerCoreNotActivated(collectionId, tokenId);
        }

        // Change specialization without fee
        _charge.specialization = specialization;
        
        // Calculate base regen rate
        uint16 baseRegenRate = uint16(hs.chargeSettings.baseRegenRate + (_charge.maxCharge - 80) / 5);
        
        // APPLY CONFIGURABLE MULTIPLIERS
        _charge.regenRate = uint16(Math.mulDiv(baseRegenRate, config.regenMultiplier, 100));
        _charge.chargeEfficiency = config.efficiencyMultiplier;
        
        // Apply collection multiplier
        _charge.regenRate = uint16(Math.mulDiv(_charge.regenRate, collection.regenMultiplier, 100));
        
        emit SpecializationChanged(collectionId, tokenId, specialization);
    }
        
    /**
     * @notice Get current specialization of a henomorph
     * @param collectionId Collection ID
     * @param tokenId Henomorph token ID
     * @return Current specialization
     */
    function getSpecialization(uint256 collectionId, uint256 tokenId) external view returns (uint8) {
        uint256 _combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage _charge = LibHenomorphsStorage.henomorphsStorage().performedCharges[_combinedId];
        
        if (_charge.lastChargeTime == 0) { 
            revert LibHenomorphsStorage.PowerCoreNotActivated(collectionId, tokenId);
        }
        
        return _charge.specialization;
    }

}