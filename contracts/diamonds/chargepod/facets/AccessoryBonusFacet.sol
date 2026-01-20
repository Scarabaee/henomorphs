// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibTraitPackHelper} from "../libraries/LibTraitPackHelper.sol";
import {LibAccessoryHelper} from "../libraries/LibAccessoryHelper.sol";
import {PodsUtils} from "../../../libraries/PodsUtils.sol";
import {ChargeAccessory, PowerMatrix} from "../../../libraries/HenomorphsModel.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";

/**
 * @title BonusValidationFacet
 * @notice Facet for validating and verifying bonuses across systems
 * @dev Provides integration-ready interfaces for bonus validation
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract AccessoryBonusFacet is AccessControlBase {
    // Events
    event BonusDataVerified(uint256 indexed collectionId, uint256 indexed tokenId, bytes32 bonusDataHash);
    event BonusesReconciled(uint256 indexed collectionId, uint256 indexed tokenId, uint8 reconciliationReason);
    
    // Constants
    uint32 private constant BONUS_VALIDATION_VERSION = 1;
    
    /**
     * @notice Returns the bonus validation version
     * @dev Used for version checking in cross-system integration
     * @return version The current version of the bonus validation system
     */
    function getBonusValidationVersion() external pure returns (uint32) {
        return BONUS_VALIDATION_VERSION;
    }
    
    /**
     * @notice Validate token bonuses match expected values
     * @dev Integration-ready method for cross-system validation
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param expectedEfficiency Expected charge efficiency value
     * @param expectedRegen Expected regen rate value
     * @param expectedMaxCharge Expected max charge value
     * @return isValid Whether values match expected values
     * @return actualValues Array of actual values
     * @return validationHash Hash of validation data
     */
    function validateTokenBonuses(
        uint256 collectionId,
        uint256 tokenId,
        uint256 expectedEfficiency,
        uint256 expectedRegen,
        uint256 expectedMaxCharge
    ) 
        external 
        view 
        returns (bool isValid, uint256[] memory actualValues, bytes32 validationHash)
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        // Get actual power matrix values
        PowerMatrix storage matrix = hs.performedCharges[combinedId];
        
        // Create array of actual values for comparison
        actualValues = new uint256[](3);
        actualValues[0] = matrix.chargeEfficiency;
        actualValues[1] = matrix.regenRate;
        actualValues[2] = matrix.maxCharge;
        
        // Check if values match
        isValid = (
            matrix.chargeEfficiency == expectedEfficiency &&
            matrix.regenRate == expectedRegen &&
            matrix.maxCharge == expectedMaxCharge
        );
        
        // Create validation hash
        validationHash = keccak256(abi.encode(
            collectionId,
            tokenId,
            actualValues,
            block.timestamp
        ));
        
        return (isValid, actualValues, validationHash);
    }
    
    /**
     * @notice Calculate expected bonus values for a token
     * @dev Integration-ready method for deriving expected bonuses
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return baseValues Base values without bonuses
     * @return accessoryBonuses Bonuses from accessories
     * @return traitPackBonuses Bonuses from trait packs
     * @return totalValues Total combined values
     */
    function calculateExpectedBonuses(
        uint256 collectionId,
        uint256 tokenId
    ) 
        external 
        view 
        returns (
            uint256[] memory baseValues,
            uint256[] memory accessoryBonuses,
            uint256[] memory traitPackBonuses,
            uint256[] memory totalValues
        )
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        // Get token's accessories
        ChargeAccessory[] storage accessories = hs.equippedAccessories[combinedId];
        
        // Initialize return arrays
        baseValues = new uint256[](3);
        accessoryBonuses = new uint256[](3);
        traitPackBonuses = new uint256[](3);
        totalValues = new uint256[](3);
        
        // Define base values (without bonuses)
        baseValues[0] = 50;  // Base efficiency
        baseValues[1] = 5;   // Base regen
        baseValues[2] = 100; // Base max charge
        
        // Calculate accessory bonuses
        for (uint256 i = 0; i < accessories.length; i++) {
            ChargeAccessory storage accessory = accessories[i];
            
            // Efficiency bonuses
            accessoryBonuses[0] += accessory.efficiencyBoost;
            
            // Specialization efficiency bonus
            if ((accessory.specializationType == 0 || accessory.specializationType == 1) && 
                hs.performedCharges[combinedId].specialization == 1) {
                accessoryBonuses[0] += accessory.specializationBoostValue;
            }
            
            // Regen bonuses
            accessoryBonuses[1] += accessory.regenBoost;
            
            // Specialization regen bonus
            if ((accessory.specializationType == 0 || accessory.specializationType == 2) && 
                hs.performedCharges[combinedId].specialization == 2) {
                accessoryBonuses[1] += accessory.specializationBoostValue;
            }
            
            // Max charge bonuses
            accessoryBonuses[2] += accessory.chargeBoost;
        }
        
        // Calculate trait pack bonuses - używamy prostego podejścia
        // zamiast wywoływania potencjalnie nieistniejącej funkcji
        for (uint256 i = 0; i < accessories.length; i++) {
            ChargeAccessory storage accessory = accessories[i];
            
            if (accessory.traitPackId > 0) {
                // Check if token has this trait pack
                (bool traitPackMatch, ) = LibTraitPackHelper.verifyTraitPack(
                    collectionId,
                    tokenId,
                    accessory.traitPackId
                );
                
                if (traitPackMatch) {
                    // Standardowe wartości bonusów
                    traitPackBonuses[0] += 10;  // Standardowy bonus dla charge efficiency
                    traitPackBonuses[1] += 5;   // Standardowy bonus dla regen rate
                }
            }
        }
        
        // Calculate total values
        for (uint256 i = 0; i < 3; i++) {
            totalValues[i] = baseValues[i] + accessoryBonuses[i] + traitPackBonuses[i];
        }
        
        return (baseValues, accessoryBonuses, traitPackBonuses, totalValues);
    }
    
    /**
     * @notice Reconcile bonus values if they don't match expected values
     * @dev Integration-ready method for correcting inconsistencies
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return reconciliationPerformed Whether reconciliation was performed
     * @return reason Reason code for reconciliation
     * @return newValues New values after reconciliation
     */
    function reconcileBonusValues(
        uint256 collectionId,
        uint256 tokenId
    ) 
        external 
        whenNotPaused
        onlyAuthorized 
        returns (bool reconciliationPerformed, uint8 reason, uint256[] memory newValues)
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        // Calculate expected values
        (,,, uint256[] memory expectedTotalValues) = this.calculateExpectedBonuses(collectionId, tokenId);
        
        // Get actual values
        PowerMatrix storage matrix = hs.performedCharges[combinedId];
        uint256[] memory actualValues = new uint256[](3);
        actualValues[0] = matrix.chargeEfficiency;
        actualValues[1] = matrix.regenRate;
        actualValues[2] = matrix.maxCharge;
        
        // Check if reconciliation is needed
        bool needsReconciliation = false;
        for (uint256 i = 0; i < 3; i++) {
            if (actualValues[i] != expectedTotalValues[i]) {
                needsReconciliation = true;
                break;
            }
        }
        
        if (!needsReconciliation) {
            return (false, 0, actualValues);
        }
        
        // Perform reconciliation
        matrix.chargeEfficiency = uint256(expectedTotalValues[0]);
        matrix.regenRate = uint16(expectedTotalValues[1]);
        matrix.maxCharge = uint128(expectedTotalValues[2]);
        
        // Ensure current charge doesn't exceed max charge
        if (matrix.currentCharge > matrix.maxCharge) {
            matrix.currentCharge = matrix.maxCharge;
        }
        
        // Set reason code
        // 1 = Efficiency mismatch, 2 = Regen mismatch, 3 = Max charge mismatch, 4 = Multiple mismatches
        if (actualValues[0] != expectedTotalValues[0] && 
            actualValues[1] != expectedTotalValues[1] && 
            actualValues[2] != expectedTotalValues[2]) {
            reason = 4; // Multiple mismatches
        } else if (actualValues[0] != expectedTotalValues[0]) {
            reason = 1; // Efficiency mismatch
        } else if (actualValues[1] != expectedTotalValues[1]) {
            reason = 2; // Regen mismatch
        } else {
            reason = 3; // Max charge mismatch
        }
        
        // Update newValues
        newValues = new uint256[](3);
        newValues[0] = matrix.chargeEfficiency;
        newValues[1] = matrix.regenRate;
        newValues[2] = matrix.maxCharge;
        
        // Emit reconciliation event
        emit BonusesReconciled(collectionId, tokenId, reason);
        
        return (true, reason, newValues);
    }
}