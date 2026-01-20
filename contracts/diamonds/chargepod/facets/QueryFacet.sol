// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {PodsUtils} from "../../../libraries/PodsUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PowerMatrix, ChargeAccessory, ChargeSeason, SpecimenCollection, ChargeSettings, ChargeFees} from "../../../libraries/HenomorphsModel.sol";

/**
 * @title QueryFacet
 * @notice Provides view functions for querying state
 * @dev Contains read-only functions for viewing the contract state
 */
contract QueryFacet {
    using Math for uint256;
    
    /**
     * @notice Get power matrix data for a henomorph
     * @param collectionId Collection ID
     * @param tokenId Henomorph token ID
     * @return Power matrix data
     */
    function queryPowerMatrix(uint256 collectionId, uint256 tokenId) external view returns (PowerMatrix memory) {
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        return LibHenomorphsStorage.henomorphsStorage().performedCharges[combinedId];
    }
    
    /**
     * @notice Simulate power update without affecting state
     * @param collectionId Collection ID
     * @param tokenId Henomorph token ID
     * @return Simulated power matrix
     */
    function simulatePowerUpdate(uint256 collectionId, uint256 tokenId) external view returns (PowerMatrix memory) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix memory charge = hs.performedCharges[combinedId];
        
        // Skip if power core not initialized
        if (charge.lastChargeTime == 0) {
            return charge;
        }
        
        // Calculate time elapsed since last update
        uint256 elapsedTime = block.timestamp - charge.lastChargeTime;
        
        // Update charge only if time has passed and maximum not reached
        if (elapsedTime > 0 && charge.currentCharge < charge.maxCharge && (charge.flags & 1) == 0) {
            // Calculate base regeneration
            uint256 regenAmount = (elapsedTime * charge.regenRate) / 3600;
            
            // Consider active boost using storage constant
            if (charge.boostEndTime > block.timestamp) {
                regenAmount = Math.mulDiv(regenAmount, 100 + LibHenomorphsStorage.CHARGE_BOOST_PERCENTAGE, 100);
            }
            
            // Consider global charge events
            if (hs.chargeEventEnd > block.timestamp) {
                regenAmount = Math.mulDiv(regenAmount, 100 + hs.chargeEventBonus, 100);
            }
            
            // Consider specialization using storage constant
            if (charge.specialization == 2) { // Regeneration specialization
                regenAmount = Math.mulDiv(regenAmount, 100 + LibHenomorphsStorage.REGEN_SPEC_BOOST, 100);
            }
            
            // Reduce regeneration at high fatigue level
            if (charge.fatigueLevel > LibHenomorphsStorage.FATIGUE_PENALTY_THRESHOLD) {
                regenAmount = Math.mulDiv(regenAmount, 150 - charge.fatigueLevel, 100);
            }
            
            // Update charge level, not exceeding maximum
            charge.currentCharge = uint128(Math.min(charge.currentCharge + regenAmount, charge.maxCharge));
        }
        
        // Update fatigue level (decreases over time)
        if (charge.fatigueLevel > 0 && elapsedTime > 0) {
            uint256 fatigueReduction = (elapsedTime * hs.chargeSettings.fatigueRecoveryRate) / 3600;
            charge.fatigueLevel = charge.fatigueLevel > uint8(fatigueReduction) ? charge.fatigueLevel - uint8(fatigueReduction) : 0;
        }
        
        return charge;
    }
    
    /**
     * @notice Get equipped accessories
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return Array of accessories
     */
    function queryEquippedAccessories(uint256 collectionId, uint256 tokenId) external view returns (ChargeAccessory[] memory) {
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        return LibHenomorphsStorage.henomorphsStorage().equippedAccessories[combinedId];
    }

    /**
     * @notice Get token's colony
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return Colony ID
     */
    function querySpecimenColony(uint256 collectionId, uint256 tokenId) external view returns (bytes32) {
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        return LibHenomorphsStorage.henomorphsStorage().specimenColonies[combinedId];
    }

    /**
     * @notice Get colony members
     * @param colonyId Colony ID
     * @return Array of combined token IDs
     */
    function queryColonyMembers(bytes32 colonyId) external view returns (uint256[] memory) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            revert LibHenomorphsStorage.ColonyDoesNotExist(colonyId);
        }

        return LibHenomorphsStorage.henomorphsStorage().colonies[colonyId];
    }

    /**
     * @notice Get colony name
     * @param colonyId Colony ID
     * @return Colony name
     */
    function queryColonyName(bytes32 colonyId) external view returns (string memory) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            revert LibHenomorphsStorage.ColonyDoesNotExist(colonyId);
        }
        return LibHenomorphsStorage.henomorphsStorage().colonyNamesById[colonyId];
    }

    /**
     * @notice Get colony charge pool amount
     * @param colonyId Colony ID
     * @return Current charge in the colony pool
     */
    function queryColonyChargePool(bytes32 colonyId) external view returns (uint256) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            revert LibHenomorphsStorage.ColonyDoesNotExist(colonyId);
        }
        return LibHenomorphsStorage.henomorphsStorage().colonyChargePools[colonyId];
    }

    /**
     * @notice Get operator season points
     * @param operator Operator address
     * @param seasonId Season ID
     * @return Season points
     */
    function queryOperatorSeasonPoints(address operator, uint32 seasonId) external view returns (uint32) {
        return LibHenomorphsStorage.henomorphsStorage().operatorSeasonPoints[operator][seasonId];
    }

    /**
     * @notice Get current season info
     * @return Current season data
     */
    function queryCurrentSeason() external view returns (ChargeSeason memory) {
        return LibHenomorphsStorage.henomorphsStorage().currentSeason;
    }

    /**
     * @notice Get global charge event status
     */
    function queryChargeEventStatus() external view returns (bool active, uint256 endTime, uint8 bonusPercentage) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (hs.chargeEventEnd > block.timestamp) {
            return (true, hs.chargeEventEnd, hs.chargeEventBonus);
        } else {
            return (false, 0, 0);
        }
    }

    /**
     * @notice Get collection configuration
     * @param collectionId Collection ID
     * @return Collection configuration
     */
    function querySpecimenCollection(uint256 collectionId) external view returns (SpecimenCollection memory) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        return hs.specimenCollections[collectionId];
    }

    /**
     * @notice Get collection ID from address
     * @param collectionAddress Collection address
     * @return Collection ID
     */
    function querySpecimenCollectionId(address collectionAddress) external view returns (uint16) {
        if (collectionAddress == address(0)) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        return LibHenomorphsStorage.henomorphsStorage().collectionIndexes[collectionAddress];
    }

    /**
     * @notice Get collection counter
     * @return Current collection counter
     */
    function queryCountRegisteredSpecimens() external view returns (uint16) {
        return LibHenomorphsStorage.henomorphsStorage().collectionCounter;
    }
    
    /**
     * @notice Get current charge settings
     * @return Current charge settings
     */
    function queryChargeSettings() external view returns (ChargeSettings memory) {
        return LibHenomorphsStorage.henomorphsStorage().chargeSettings;
    }
    
    /**
     * @notice Get current charge fees
     * @return Current charge fees
     */
    function queryChargeFees() external view returns (ChargeFees memory) {
        return LibHenomorphsStorage.henomorphsStorage().chargeFees;
    }

    /**
     * @notice Check if henomorph has calibration data
     * @param collectionId Collection ID
     * @param tokenId Henomorph token ID
     * @return True if calibration data exists, false otherwise
     */
    function hasCalibrationData(uint256 collectionId, uint256 tokenId) external view returns (bool) {
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix memory charge = LibHenomorphsStorage.henomorphsStorage().performedCharges[combinedId];
        
        // Calibration data exists if power core has been initialized (lastChargeTime > 0)
        return charge.lastChargeTime > 0;
    }

    /**
     * @notice Check if henomorph has power core
     * @param collectionId Collection ID
     * @param tokenId Henomorph token ID
     * @return True if power core exists, false otherwise
     */
    function hasPowerCore(uint256 collectionId, uint256 tokenId) external view returns (bool) {
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix memory charge = LibHenomorphsStorage.henomorphsStorage().performedCharges[combinedId];
        
        // Power core exists if maxCharge > 0 (indicates core has been set up)
        return charge.maxCharge > 0;
    }
}