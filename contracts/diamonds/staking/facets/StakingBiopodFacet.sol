// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../../chargepod/libraries/LibHenomorphsStorage.sol";
import {LibStakingStorage} from "../libraries/LibStakingStorage.sol";
import {LibBiopodIntegration} from "../libraries/LibBiopodIntegration.sol";
import {PodsUtils} from "../../../libraries/PodsUtils.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ChargeAccessory, PowerMatrix, Calibration, SpecimenCollection} from "../../../libraries/HenomorphsModel.sol";
import {StakedSpecimen} from "../../../libraries/StakingModel.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {IExternalBiopod, IExternalAccessory, IExternalChargepod, IExternalCollection} from "../interfaces/IStakingInterfaces.sol";
import {IStakingIntegrationFacet} from "../interfaces/IStakingInterfaces.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";

/**
 * @title StakingBiopodFacet
 * @notice Facet that handles integration between staking system and Chargepod BiopodFacet
 * @dev All data is synchronized with Chargepod diamond (chargeSystemAddress) instead of external biopods
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract StakingBiopodFacet is AccessControlBase {
    using Math for uint256;
    
    // Events
    event BiopodCalibrationSynced(uint256 indexed collectionId, uint256 indexed tokenId, uint256 charge, uint256 level);
    event BiopodExperienceAdded(uint256 indexed collectionId, uint256 indexed tokenId, uint256 amount);
    event BiopodChargeUpdated(uint256 indexed collectionId, uint256 indexed tokenId, uint256 newCharge);
    event BiopodAddressUpdated(uint256 indexed collectionId, address biopodAddress);
    event BiopodFatigueApplied(uint256 indexed collectionId, uint256 indexed tokenId, uint256 amount);
    event BiopodSyncFailed(uint256 indexed collectionId, uint256 indexed tokenId);
    
    // Errors
    error NotStakedHenomorph();
    error InvalidOwner();
    error BiopodNotAvailable();
    error UnauthorizedCaller();
    error BiopodUpdateFailed();
    error InvalidVariantRange();
    error InvalidTokenId();
    error PowerCoreNotActivated();
    

    /**
     * @dev Modifier to check if caller is authorized to update token data
     * @param collectionId Collection ID
     * @param tokenId Token ID
     */
    modifier onlyTokenOwner(uint256 collectionId, uint256 tokenId) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        if (!staked.staked) {
            revert NotStakedHenomorph();
        }
        
        // Use AccessHelper for consistent access control
        if (LibMeta.msgSender() != staked.owner && !AccessHelper.isAuthorized() && !AccessHelper.isInternalCall()) {
            revert UnauthorizedCaller();
        }
        
        _;
    }

    /**
     * @notice Add experience to a token in Biopod - zoptymalizowane
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param amount Amount of experience to add
     * @return success Whether update was successful
     */
    function addExperienceToBiopod(uint256 collectionId, uint256 tokenId, uint256 amount) 
        external 
        onlyTokenOwner(collectionId, tokenId) 
        whenNotPaused
        returns (bool success) 
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Get collection data and validate biopod availability
        SpecimenCollection storage collection = validateBiopodAvailability(ss, collectionId);
        
        // Wykorzystanie funkcji z StakingIntegrationFacet do spójnego liczenia bonusów
        uint256 adjustedAmount = amount;
        try IStakingIntegrationFacet(address(this)).calculateExperienceBonus(
            collectionId, tokenId, amount
        ) returns (uint256 bonusAmount) {
            adjustedAmount = bonusAmount;
        } catch {
            // Używamy oryginalnej wartości jeśli wystąpił błąd
        }
        
        // Apply experience to biopod and update storage
        return applyBiopodExperience(ss, collectionId, tokenId, adjustedAmount, collection);
    }
            
    /**
     * @notice Apply fatigue to a token via Chargepod BiopodFacet
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param amount Amount of fatigue to add
     * @return success Whether update was successful
     */
    function applyFatigueToBiopod(uint256 collectionId, uint256 tokenId, uint256 amount) external onlyTokenOwner(collectionId, tokenId) returns (bool success) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        // Use Chargepod diamond for all collections
        if (ss.chargeSystemAddress == address(0)) {
            revert BiopodNotAvailable();
        }

        // Apply fatigue via Chargepod BiopodFacet
        try IExternalBiopod(ss.chargeSystemAddress).applyFatigue(collectionId, tokenId, amount) returns (bool result) {
            if (result) {
                emit BiopodFatigueApplied(collectionId, tokenId, amount);
            }
            return result;
        } catch {
            revert BiopodUpdateFailed();
        }
    }
    
    /**
     * @notice Update charge data via Chargepod BiopodFacet
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param charge New charge level
     * @return success Whether update was successful
     */
    function updateBiopodChargeLevel(uint256 collectionId, uint256 tokenId, uint256 charge) external onlyTokenOwner(collectionId, tokenId) returns (bool success) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        // Use Chargepod diamond for all collections
        if (ss.chargeSystemAddress == address(0)) {
            revert BiopodNotAvailable();
        }

        // Update charge via Chargepod BiopodFacet
        try IExternalBiopod(ss.chargeSystemAddress).updateChargeData(collectionId, tokenId, charge, block.timestamp) returns (bool result) {
            if (result) {
                // Update local storage as well
                uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
                StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
                staked.chargeLevel = uint8(charge);

                // Update charge bonus
                LibStakingStorage.updateChargeBonus(collectionId, tokenId, charge);

                emit BiopodChargeUpdated(collectionId, tokenId, charge);
            }
            return result;
        } catch {
            revert BiopodUpdateFailed();
        }
    }
    
    /**
     * @notice Sync with Chargepod to update power matrix data
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return success Whether sync was successful
     */
    function syncChargepodData(uint256 collectionId, uint256 tokenId) external onlyTokenOwner(collectionId, tokenId) whenNotPaused returns (bool success) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Check if Chargepod is connected
        if (ss.chargeSystemAddress == address(0)) {
            return false;
        }
        
        LibStakingStorage.ExternalModules storage es = ss.externalModules;
        // Get power matrix from Chargepod
        try IExternalChargepod(es.queryModuleAddress).queryPowerMatrix(collectionId, tokenId) returns (PowerMatrix memory matrix) {
            // Verify power core is activated
            if (matrix.lastChargeTime == 0) {
                revert PowerCoreNotActivated();
            }
            
            // Update charge bonus based on current charge
            LibStakingStorage.updateChargeBonus(collectionId, tokenId, matrix.currentCharge);
            
            // Update local data
            uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
            StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
            staked.chargeLevel = uint8(matrix.currentCharge);
            staked.specialization = matrix.specialization;
            
            return true;
        } catch {
            return false;
        }
    }

    /**
     * @notice Synchronize token data with Chargepod BiopodFacet
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return success Whether synchronization was successful
     */
    function syncBiopodData(uint256 collectionId, uint256 tokenId)
        external  // Must be external for the try/catch to work
        whenNotPaused
        returns (bool success)
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        // Use Chargepod diamond address for all collections
        if (ss.chargeSystemAddress == address(0)) {
            return false;
        }

        // Get token data
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];

        // Skip if token is not staked
        if (!staked.staked) {
            return false;
        }

        // Get calibration data from Chargepod BiopodFacet
        try IExternalBiopod(ss.chargeSystemAddress).probeCalibration(collectionId, tokenId) returns (Calibration memory cal) {
            // Update token data from calibration
            _updateTokenDataFromCalibration(collectionId, tokenId, cal);

            // Update last sync timestamp
            staked.lastSyncTimestamp = uint32(block.timestamp);

            emit BiopodCalibrationSynced(collectionId, tokenId, cal.charge, cal.bioLevel > 0 ? cal.bioLevel : cal.level);

            return true;
        } catch {
            emit BiopodSyncFailed(collectionId, tokenId);
            return false;
        }
    }
    
    /**
     * @notice Batch sync multiple tokens with Biopod
     * @param collectionId Collection ID
     * @param tokenIds Array of token IDs
     * @return successCount Number of successfully synced tokens
            */
    function batchSyncBiopod(uint256 collectionId, uint256[] calldata tokenIds) 
        external 
        whenNotPaused
        returns (uint256 successCount) 
    {
        if (!AccessHelper.isAuthorized()) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "");
        }
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            // The key fix: Use "this." to make it an external call
            try this.syncBiopodData(collectionId, tokenIds[i]) returns (bool success) {
                if (success) {
                    successCount++;
                }
            } catch {
                // Continue to next token on failure
            }
        }
        
        return successCount;
    }

    /**
    * @notice Update Biopod address for a collection
    * @param collectionId Collection ID
    * @param biopodAddress New Biopod address
    */
    function updateBiopodSystemAddress(uint256 collectionId, address biopodAddress) 
        external 
        onlyAuthorized 
        whenNotPaused 
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Validate collection ID
        if (collectionId == 0 || collectionId > ss.collectionCounter) {
            revert InvalidTokenId();
        }
        
        // Update Biopod address
        ss.collections[collectionId].biopodAddress = biopodAddress;
        
        emit BiopodAddressUpdated(collectionId, biopodAddress);
    }

    /**
     * @notice Get calibration data for a token from Chargepod BiopodFacet
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return exists Whether calibration exists
     * @return calibration Calibration data
     */
    function getBiopodCalibrationData(uint256 collectionId, uint256 tokenId) external view returns (bool exists, Calibration memory calibration) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        // Get collection data for owner lookup
        SpecimenCollection storage collection = ss.collections[collectionId];
        IERC721 nftCollection = IERC721(collection.collectionAddress);

        // Use Chargepod diamond for all collections
        if (ss.chargeSystemAddress == address(0)) {
            // Return default Calibration struct with all fields initialized to 0
            return (false, Calibration({
                charge: 0,
                experience: 0,
                bioLevel: 0,
                wear: 0,
                kinship: 0,
                level: 0,
                prowess: 0,
                agility: 0,
                intelligence: 0,
                lastInteraction: 0,
                lastCharge: 0,
                lastRecalibration: 0,
                calibrationCount: 0,
                locked: false,
                owner: nftCollection.ownerOf(tokenId),
                tokenId: tokenId
            }));
        }

        try IExternalBiopod(ss.chargeSystemAddress).probeCalibration(collectionId, tokenId) returns (Calibration memory cal) {
            return (true, cal);
        } catch {
            // Return default Calibration struct with all fields initialized to 0
            return (false, Calibration({
                charge: 0,
                experience: 0,
                bioLevel: 0,
                wear: 0,
                kinship: 0,
                level: 0,
                prowess: 0,
                agility: 0,
                intelligence: 0,
                lastInteraction: 0,
                lastCharge: 0,
                lastRecalibration: 0,
                calibrationCount: 0,
                locked: false,
                owner: nftCollection.ownerOf(tokenId),
                tokenId: tokenId
            }));
        }
    }
    
    /**
     * @notice Get Biopod address for a collection
     * @param collectionId Collection ID
     * @return Biopod address
     */
    function getBiopodSystemAddress(uint256 collectionId) external view returns (address) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        if (collectionId == 0 || collectionId > ss.collectionCounter) {
            revert InvalidTokenId();
        }
        
        return ss.collections[collectionId].biopodAddress;
    }
    
    /**
     * @notice Check if a token is staked and has Chargepod connection
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return isStaked Whether token is staked
     * @return hasBiopod Whether Chargepod is available
     */
    function checkTokenBiopodStatus(uint256 collectionId, uint256 tokenId) external view returns (bool isStaked, bool hasBiopod) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];

        isStaked = staked.staked;
        // Chargepod is available for all collections when chargeSystemAddress is set
        hasBiopod = ss.chargeSystemAddress != address(0);

        return (isStaked, hasBiopod);
    }

    /**
     * @dev Updates wear level locally based on time elapsed for tokens without Biopod
     * @param collectionId Collection ID
     * @param tokenId Token ID
     */
    function updateLocalWear(uint256 collectionId, uint256 tokenId) internal {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        // Skip if wear increase rate is 0
        if (ss.wearIncreasePerDay == 0) {
            return;
        }
        
        // Calculate time elapsed since last wear update
        uint256 timeElapsed = block.timestamp - staked.lastWearUpdateTime;
        
        // Skip if no time elapsed
        if (timeElapsed == 0) {
            return;
        }
        
        // Calculate wear increase based on daily rate
        uint256 wearIncrease = (timeElapsed * ss.wearIncreasePerDay) / 1 days;
        
        if (wearIncrease > 0) {
            uint256 oldWear = staked.wearLevel;
            uint256 newWear = oldWear + wearIncrease;
            
            // Cap at 100
            if (newWear > LibStakingStorage.MAX_WEAR_LEVEL) {
                newWear = LibStakingStorage.MAX_WEAR_LEVEL;
            }
            
            // Update wear level
            staked.wearLevel = uint8(newWear);
            
            // Update wear penalty based on thresholds
            updateWearPenalty(staked);
            
            // Update last wear update time
            staked.lastWearUpdateTime = uint32(block.timestamp);
        }
    }

    /**
     * @dev Updates wear penalty based on current wear level
     * @param staked Staked specimen data
     */
    function updateWearPenalty(StakedSpecimen storage staked) internal {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Reset penalty
        staked.wearPenalty = 0;
        
        // Find applicable penalty
        for (uint8 i = 0; i < ss.wearPenaltyThresholds.length; i++) {
            if (staked.wearLevel >= ss.wearPenaltyThresholds[i]) {
                staked.wearPenalty = uint8(ss.wearPenaltyValues[i]);
            }
        }
    }

    // Validate Chargepod availability and return collection
    function validateBiopodAvailability(LibStakingStorage.StakingStorage storage ss, uint256 collectionId)
        private
        view
        returns (SpecimenCollection storage)
    {
        // Check Chargepod diamond is set
        if (ss.chargeSystemAddress == address(0)) {
            revert BiopodNotAvailable();
        }

        // Get collection data
        SpecimenCollection storage collection = ss.collections[collectionId];

        return collection;
    }

    // Get token trait packs from collection
    function getTokenTraitPacks(address collectionAddress, uint256 tokenId) 
        private 
        view 
        returns (uint8[] memory) 
    {
        // Default empty array
        uint8[] memory tokenTraitPacks = new uint8[](0);
        
        // Try to get token's trait packs
        try IExternalCollection(collectionAddress).itemEquipments(tokenId) returns (uint8[] memory traitPacks) {
            return traitPacks;
        } catch {
            // Return empty array if trait pack retrieval fails
            return tokenTraitPacks;
        }
    }

    // Calculate adjusted experience amount with accessory bonuses
    function calculateExperienceBonus(
        LibStakingStorage.StakingStorage storage ss,
        uint256 collectionId, 
        uint256 tokenId, 
        uint256 amount,
        SpecimenCollection storage collection
    ) 
        private 
        view 
        returns (uint256) 
    {
        // Apply experience multiplier from accessories
        uint256 adjustedAmount = amount;
        
        // Get Chargepod address from storage
        address chargepodAddress = ss.chargeSystemAddress;
        
        if (chargepodAddress == address(0)) {
            return adjustedAmount;
        }

        LibStakingStorage.ExternalModules storage es = ss.externalModules;
        
        try IExternalAccessory(es.accessoryModuleAddress).equippedAccessories(collectionId, tokenId) returns (ChargeAccessory[] memory accessories) {
            // Get token's trait packs
            uint8[] memory tokenTraitPacks = getTokenTraitPacks(collection.collectionAddress, tokenId);
            
            // Calculate multiplier and return adjusted amount
            uint256 xpMultiplier = calculateXpMultiplier(accessories, tokenTraitPacks);
            
            // Apply combined multiplier
            return amount * xpMultiplier / 100;
        } catch {
            // Use original amount if accessory retrieval fails
            return adjustedAmount;
        }
    }

    // Calculate XP multiplier based on accessories and trait packs
    function calculateXpMultiplier(ChargeAccessory[] memory accessories, uint8[] memory tokenTraitPacks) 
        private 
        pure 
        returns (uint256) 
    {
        uint256 xpMultiplier = 100; // Base 100%
        
        for (uint256 i = 0; i < accessories.length; i++) {
            // Apply XP gain multiplier
            if (accessories[i].xpGainMultiplier > 0) {
                xpMultiplier += accessories[i].xpGainMultiplier - 100; // Adjust by the difference from 100%
            }
            
            // Check for trait pack match if accessory has a trait pack requirement
            if (accessories[i].traitPackId > 0) {
                // Check if any of the token's trait packs match the accessory's requirement
                bool traitPackMatch = false;
                
                for (uint256 j = 0; j < tokenTraitPacks.length; j++) {
                    if (tokenTraitPacks[j] == accessories[i].traitPackId) {
                        traitPackMatch = true;
                        break;
                    }
                }
                
                // If a match is found, apply additional XP bonus
                if (traitPackMatch) {
                    xpMultiplier += 15; // Extra 15% XP for matching trait pack
                }
            }
            
            // Rare accessories give additional XP boost
            if (accessories[i].rare) {
                xpMultiplier += 10; // Additional 10% XP for rare accessories
            }
        }
        
        return xpMultiplier;
    }

    // Apply experience to Chargepod BiopodFacet and update storage
    function applyBiopodExperience(
        LibStakingStorage.StakingStorage storage ss,
        uint256 collectionId,
        uint256 tokenId,
        uint256 adjustedAmount,
        SpecimenCollection storage
    )
        private
        returns (bool)
    {
        // Add experience to Chargepod BiopodFacet with adjusted amount
        try IExternalBiopod(ss.chargeSystemAddress).applyExperienceGain(collectionId, tokenId, adjustedAmount) returns (bool result) {
            if (result) {
                // Update local storage as well
                uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
                StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
                staked.experience += adjustedAmount;

                emit BiopodExperienceAdded(collectionId, tokenId, adjustedAmount);
            }
            return result;
        } catch {
            revert BiopodUpdateFailed();
        }
    }

    /**
     * @notice Update token data from Biopod calibration
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param cal Calibration data
     */
    function _updateTokenDataFromCalibration(uint256 collectionId, uint256 tokenId, Calibration memory cal) internal {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        // Only update if token is staked
        if (!staked.staked) {
            return;
        }
        
        // Update token data with calibration information
        staked.level = uint8(cal.bioLevel > 0 ? cal.bioLevel : cal.level);
        staked.experience = cal.experience;
        staked.chargeLevel = uint8(cal.charge);
        staked.wearLevel = uint8(cal.wear);
        
        // Update last sync timestamp
        staked.lastSyncTimestamp = uint32(block.timestamp);
        
        // Update wear penalty based on current wear level
        if (staked.wearLevel > 0) {
            for (uint8 i = 0; i < ss.wearPenaltyThresholds.length; i++) {
                if (staked.wearLevel >= ss.wearPenaltyThresholds[i]) {
                    staked.wearPenalty = ss.wearPenaltyValues[i];
                }
            }
        }
    }
}