// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibStakingStorage} from "../libraries/LibStakingStorage.sol";
import {PodsUtils} from "../../libraries/PodsUtils.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StakedSpecimen, Colony, RewardCalcData} from "../../libraries/StakingModel.sol";
import {Calibration, ChargeAccessory, PowerMatrix, SpecimenCollection} from "../../libraries/HenomorphsModel.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {IExternalBiopod, IExternalAccessory, 
        IExternalChargepod, ISpecializationFacet, 
        IExternalCollection, IColonyFacet, IChargeFacet} from "../interfaces/IStakingInterfaces.sol";
import {AccessControlBase} from "./AccessControlBase.sol";

/**
 * @title StakingIntegrationFacet - Enhanced & Centralized
 * @notice Central integration point between Staking and Chargepod systems
 * @dev Consolidates all Chargepod/Biopod integrations to reduce duplication
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract StakingIntegrationFacet is AccessControlBase {
    using Math for uint256;
    
    // Events
    event ChargepodAddressChanged(address indexed oldAddress, address indexed newAddress);
    event ColonyCallbackReceived(bytes32 indexed colonyId, string actionType);
    event TokenCallbackReceived(uint256 indexed collectionId, uint256 indexed tokenId, string actionType);
    event RewardMultiplierApplied(uint256 indexed collectionId, uint256 indexed tokenId, uint256 baseMultiplier, uint256 totalMultiplier);
    event OperationResult(string operation, bool success, string message);
    event PowerCoreStatusUpdated(uint256 indexed collectionId, uint256 indexed tokenId, bool isActive);
    event IntegrationSynced(string integrationName, bool success);
    event TokenMilestoneReached(uint8 level, string milestoneName);
    
    // Errors
    error InvalidAddress();
    error TokenNotStaked();
    error InvalidCollectionId();
    error ChargepodNotInitialized();
    error PowerCoreNotActive(uint256 collectionId, uint256 tokenId);
    error SynchronizationFailed(string reason);

    /**
     * @notice Set Chargepod address for integration - CENTRALIZED METHOD
     * @dev Single point of configuration for Chargepod integration
     * @param chargepodAddress Address of the Chargepod system
     */
    function setChargepodSystemAddress(address chargepodAddress) external {
        // Combined access control - admin OR the Chargepod itself
        if (!AccessHelper.isAuthorized() && msg.sender != chargepodAddress) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not authorized");
        }
        
        if (chargepodAddress == address(0)) {
            revert InvalidAddress();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        address oldAddress = ss.chargeSystemAddress;
        
        // Update address in ALL locations for consistency
        ss.chargeSystemAddress = chargepodAddress;
        ss.externalModules.chargeModuleAddress = chargepodAddress;
        
        // Update query module if not set
        if (ss.externalModules.queryModuleAddress == address(0) || 
            ss.externalModules.queryModuleAddress == oldAddress) {
            ss.externalModules.queryModuleAddress = chargepodAddress;
        }
        
        // Try to register as staking listener
        try IColonyFacet(chargepodAddress).setStakingListener(address(this)) {
            emit OperationResult("StakingListenerRegistration", true, "Successfully registered");
        } catch {
            emit OperationResult("StakingListenerRegistration", false, "Failed to register");
            // Continue even if registration fails
        }
        
        emit ChargepodAddressChanged(oldAddress, chargepodAddress);
    }
    
    /**
     * @notice Get Chargepod system address - CENTRALIZED ACCESS POINT
     * @dev All facets should use this method instead of direct storage access
     * @return The current Chargepod system address
     */
    function getChargepodSystemAddress() external view returns (address) {
        return LibStakingStorage.stakingStorage().chargeSystemAddress;
    }
    
    /**
     * @notice Check if token has an active power core
     * @dev CENTRALIZED check for power core status - all facets should use this
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return isActive Whether power core is active
     */
    function isPowerCoreActive(uint256 collectionId, uint256 tokenId) external view returns (bool isActive) {
        address chargepodAddress = LibStakingStorage.stakingStorage().chargeSystemAddress;
        
        if (chargepodAddress == address(0)) {
            return false;
        }
        
        try IChargeFacet(chargepodAddress).getSpecimenData(collectionId, tokenId) returns (
            uint256, uint256 maxCharge, uint256, uint8, uint256
        ) {
            // Power core is active if it has a non-zero max charge
            return maxCharge > 0;
        } catch {
            return false;
        }
    }

    /**
     * @notice Check if a token is staked
     */
    function isSpecimenStaked(uint256 collectionId, uint256 tokenId) external view returns (bool) {
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        return LibStakingStorage.stakingStorage().stakedSpecimens[combinedId].staked;
    }

    /**
     * @notice Get the level of a staked specimen
     */
    function getSpecimenLevel(uint256 collectionId, uint256 tokenId) external view returns (uint8) {
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        return LibStakingStorage.stakingStorage().stakedSpecimens[combinedId].level;
    }

    /**
     * @notice Get the variant of a staked specimen
     */
    function getSpecimenVariant(uint256 collectionId, uint256 tokenId) external view returns (uint8) {
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        return LibStakingStorage.stakingStorage().stakedSpecimens[combinedId].variant;
    }
        
    /**
     * @notice Apply experience to token from rewards
     * @dev CENTRALIZED integration point for experience application
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param rewardAmount Amount of reward tokens claimed
     * @return success Whether experience was applied
     */
    function applyExperienceFromRewards(uint256 collectionId, uint256 tokenId, uint256 rewardAmount) external returns (bool success) {
        // Enhanced access control - allow calls from CoreFacet or admins
        if (!AccessHelper.isInternalCall() && !AccessHelper.isAuthorized()) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not authorized");
        }
        
        // Calculate experience (1 ZICO = 1 XP, capped at 100 per claim)
        uint256 xpAmount = rewardAmount / 1 ether;
        
        // Add minimum experience gain
        if (xpAmount == 0 && rewardAmount > 0) {
            xpAmount = 1;
        }
        
        // Cap at 100 XP per claim to prevent gaming the system
        if (xpAmount > 100) {
            xpAmount = 100;
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        // SpecimenCollection storage collection = ss.collections[collectionId];
        
        uint256 tokenCombinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[tokenCombinedId];
        
        // Verify token is staked
        if (!staked.staked) {
            return false;
        }

        // Apply XP through Biopod if available
        // if (collection.biopodAddress != address(0)) {
        //     try IExternalBiopod(collection.biopodAddress).applyExperienceGain(collectionId, tokenId, xpAmount) returns (bool result) {
        //         if (result) {
        //             // Update local data for consistency
        //             staked.experience += xpAmount;
        //             _updateTokenLevel(staked);
        //             return true;
        //         }
        //     } catch {
        //         // Fall back to local update on failure
        //         emit OperationResult("BiopodExperienceGain", false, "Fallback to local update");
        //     }
        // }
        
        // Local experience update
        staked.experience += xpAmount;
        _updateTokenLevel(staked);
        
        return true;
    }

    /**
     * @notice Calculate experience bonus for a token
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param baseAmount Base experience amount
     * @return bonusAmount Adjusted experience amount with bonuses
     */
    function calculateExperienceBonus(
        uint256 collectionId,
        uint256 tokenId,
        uint256 baseAmount
    ) external view returns (uint256 bonusAmount) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Begin with base amount
        bonusAmount = baseAmount;
        
        address accessoryAddress = ss.externalModules.accessoryModuleAddress;
        if (accessoryAddress == address(0)) {
            accessoryAddress = ss.chargeSystemAddress;
        }
        
        if (accessoryAddress != address(0)) {
            try IExternalAccessory(accessoryAddress).equippedAccessories(collectionId, tokenId) returns (ChargeAccessory[] memory accessories) {
                // Get token's trait packs
                SpecimenCollection storage collection = ss.collections[collectionId];
                uint8[] memory tokenTraitPacks = getTokenTraitPacks(collection.collectionAddress, tokenId);
                
                // Calculate XP multiplier
                uint256 xpMultiplier = 100; // Base 100%
                
                for (uint256 i = 0; i < accessories.length; i++) {
                    // Apply XP gain multiplier
                    if (accessories[i].xpGainMultiplier > 0) {
                        xpMultiplier += accessories[i].xpGainMultiplier - 100;
                    }
                    
                    // Additional bonus for rare accessories
                    if (accessories[i].rare) {
                        xpMultiplier += 10; // Extra 10% for rare accessories
                    }
                    
                    // Check for trait pack match
                    if (accessories[i].traitPackId > 0) {
                        for (uint256 j = 0; j < tokenTraitPacks.length; j++) {
                            if (tokenTraitPacks[j] == accessories[i].traitPackId) {
                                xpMultiplier += 15; // Extra 15% for matching trait pack
                                break;
                            }
                        }
                    }
                }
                
                // Apply multiplier
                bonusAmount = baseAmount * xpMultiplier / 100;
            } catch {
                // Use original amount if accessory retrieval fails
            }
        }
        
        return bonusAmount;
    }

    /**
     * @notice Synchronize token with Chargepod
     * @dev CENTRALIZED integration point for token data synchronization
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return success Whether synchronization was successful
     */
    function syncTokenWithChargepod(uint256 collectionId, uint256 tokenId) external returns (bool success) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Verify token is staked
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        if (!staked.staked) {
            revert TokenNotStaked();
        }
        
        // Get active Chargepod address
        address chargepodAddress = ss.chargeSystemAddress;
        if (chargepodAddress == address(0)) {
            return false;
        }
        
        bool syncSuccess = false;
        
        // 1. Sync specialization
        try ISpecializationFacet(chargepodAddress).getSpecialization(collectionId, tokenId) returns (uint8 specialization) {
            staked.specialization = specialization;
            syncSuccess = true;
        } catch {
            emit OperationResult("SpecializationSync", false, "Failed to sync specialization");
        }
        
        // 2. Sync charge level and power matrix
        address queryAddress = ss.externalModules.queryModuleAddress;
        if (queryAddress == address(0)) {
            queryAddress = chargepodAddress;
        }
        
        try IExternalChargepod(queryAddress).queryPowerMatrix(collectionId, tokenId) returns (PowerMatrix memory matrix) {
            if (matrix.lastChargeTime > 0) {
                // Calculate charge level as percentage of max
                uint8 newChargeLevel = uint8(matrix.currentCharge * 100 / matrix.maxCharge);
                staked.chargeLevel = newChargeLevel;
                
                // Update charge bonus
                LibStakingStorage.updateChargeBonus(collectionId, tokenId, newChargeLevel);
                syncSuccess = true;
            }
        } catch {
            emit OperationResult("ChargeSync", false, "Failed to sync charge data");
        }
        
        // 3. Check colony membership
        try IColonyFacet(chargepodAddress).getTokenColony(collectionId, tokenId) returns (bytes32 colonyId) {
            if (colonyId != bytes32(0) && staked.colonyId != colonyId) {
                staked.colonyId = colonyId;
                syncSuccess = true;
            }
        } catch {
            emit OperationResult("ColonySync", false, "Failed to sync colony data");
        }
        
        // Update last sync timestamp regardless of success
        staked.lastSyncTimestamp = uint32(block.timestamp);
        
        return syncSuccess;
    }

    /**
     * @notice Calculate reward multiplier incorporating Chargepod data - FIXED for Diamond accessories
     * @dev CENTRALIZED method for calculating reward multipliers with complete accessory integration
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return calcBaseMultiplier Base staking multiplier (100 = 100%)
     * @return calcTotalMultiplier Final multiplier with all bonuses
     */
    function calculateRewardMultiplier(uint256 collectionId, uint256 tokenId) external returns (uint256 calcBaseMultiplier, uint256 calcTotalMultiplier) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        uint256 tokenCombinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[tokenCombinedId];
        
        if (!staked.staked) {
            revert TokenNotStaked();
        }
        
        // Start with base multiplier (100%)
        calcBaseMultiplier = 100;
        calcTotalMultiplier = 100;
        
        // Get collection data
        SpecimenCollection storage collection = ss.collections[collectionId];
        
        // Create a temporary RewardCalcData structure to collect all multipliers
        RewardCalcData memory rewardData;
        rewardData.level = staked.level;
        rewardData.variant = staked.variant;
        rewardData.chargeLevel = staked.chargeLevel;
        rewardData.infusionLevel = staked.infusionLevel;
        rewardData.specialization = staked.specialization;
        rewardData.wearLevel = staked.wearLevel;
        
        // 1. Apply colony bonus if in a colony
        if (staked.colonyId != bytes32(0)) {
            uint256 colonyBonus = ss.colonyStakingBonuses[staked.colonyId];
            if (colonyBonus == 0) {
                // Try to get from colony structure directly
                colonyBonus = ss.colonies[staked.colonyId].stakingBonus;
            }
            rewardData.colonyBonus = colonyBonus;
            calcTotalMultiplier += colonyBonus;
        }
        
        // 2. Apply accessory staking bonuses - FIXED to include Diamond accessories with full data
        address accessoryAddress = ss.externalModules.accessoryModuleAddress;
        if (accessoryAddress == address(0)) {
            accessoryAddress = ss.chargeSystemAddress;
        }
        
        if (accessoryAddress != address(0)) {
            try IExternalAccessory(ss.externalModules.accessoryModuleAddress).equippedAccessories(collectionId, tokenId) returns (ChargeAccessory[] memory accessories) {
                // Get token's trait packs
                uint8[] memory tokenTraitPacks = getTokenTraitPacks(collection.collectionAddress, tokenId);
                
                uint256 accessoryBonus = 0;
                for (uint256 i = 0; i < accessories.length; i++) {
                    // Apply staking boost percentage
                    if (accessories[i].stakingBoostPercentage > 0) {
                        accessoryBonus += accessories[i].stakingBoostPercentage;
                    }
                    
                    // Additional bonus for rare accessories
                    if (accessories[i].rare) {
                        accessoryBonus += 5; // Additional 5% for rare accessories
                    }
                    
                    // Check for trait pack match
                    if (accessories[i].traitPackId > 0) {
                        for (uint256 j = 0; j < tokenTraitPacks.length; j++) {
                            if (tokenTraitPacks[j] == accessories[i].traitPackId) {
                                accessoryBonus += 10; // Extra 10% bonus for matching trait pack
                                break;
                            }
                        }
                    }
                }
                
                calcTotalMultiplier += accessoryBonus;
            } catch {
                emit OperationResult("AccessoryBonus", false, "Failed to get equipped accessories");
            }
        }
        
        // 3. Apply specialization bonus
        address specializationAddress = ss.externalModules.specializationModuleAddress;
        if (specializationAddress == address(0)) {
            specializationAddress = ss.chargeSystemAddress; // Fallback to Chargepod
        }
        
        if (specializationAddress != address(0)) {
            try ISpecializationFacet(specializationAddress).getSpecialization(collectionId, tokenId) returns (uint8 specialization) {
                // Apply specialization bonuses
                uint256 specializationBonus = 0;
                
                if (specialization == 1) {
                    specializationBonus = 15; // Efficiency bonus
                } else if (specialization == 2) {
                    specializationBonus = 25; // Regeneration bonus
                }
                
                // Store specialization in staking data
                rewardData.specialization = specialization;
                staked.specialization = specialization;
                
                calcTotalMultiplier += specializationBonus;
            } catch {
                emit OperationResult("SpecializationBonus", false, "Failed to get specialization");
            }
        }
        
        // 4. Apply charge level bonus
        if (staked.chargeLevel > 50) {
            // Bonus for high charge: up to 20% at 100% charge
            uint256 chargeBonus = ((staked.chargeLevel - 50) * 2) / 5;
            calcTotalMultiplier += chargeBonus;
        }
        
        // 5. Apply season multiplier if active
        if (ss.currentSeason.active) {
            rewardData.seasonMultiplier = ss.currentSeason.multiplier;
            calcTotalMultiplier = (calcTotalMultiplier * ss.currentSeason.multiplier) / 100;
        } else {
            rewardData.seasonMultiplier = 100;
        }
        
        // 6. Apply loyalty program bonus if enabled
        if (ss.loyaltyProgramEnabled) {
            LibStakingStorage.LoyaltyTierAssignment storage assignment = ss.addressTierAssignments[staked.owner];
            
            if (assignment.tierLevel != LibStakingStorage.LoyaltyTierLevel.NONE) {
                if (assignment.expiryTime == 0 || block.timestamp <= assignment.expiryTime) {
                    LibStakingStorage.LoyaltyTierConfig storage tierConfig = 
                        ss.loyaltyTierConfigs[assignment.tierLevel];
                    
                    if (tierConfig.active) {
                        rewardData.loyaltyBonus = tierConfig.bonusPercent;
                        calcTotalMultiplier += tierConfig.bonusPercent;
                    }
                }
            }
        }
        
        // 7. Apply wear penalty if applicable
        if (staked.wearLevel > 0 && staked.wearPenalty > 0) {
            calcTotalMultiplier = calcTotalMultiplier > staked.wearPenalty ? 
                calcTotalMultiplier - staked.wearPenalty : 0;
        }
        
        emit RewardMultiplierApplied(collectionId, tokenId, calcBaseMultiplier, calcTotalMultiplier);
        
        return (calcBaseMultiplier, calcTotalMultiplier);
    }

    /**
     * @notice Get token trait packs from collection contract
     * @dev Helper function to get trait packs with proper error handling
     * @param collectionAddress Collection contract address
     * @param tokenId Token ID
     * @return Array of trait pack IDs
     */
    function getTokenTraitPacks(address collectionAddress, uint256 tokenId) 
        private 
        view 
        returns (uint8[] memory) 
    {
        // Default empty array
        uint8[] memory tokenTraitPacks = new uint8[](0);
        
        // Try to get token's trait packs with proper error handling
        try IExternalCollection(collectionAddress).itemEquipments(tokenId) returns (uint8[] memory traitPacks) {
            return traitPacks;
        } catch {
            // Return empty array if trait pack retrieval fails
            return tokenTraitPacks;
        }
    }

    /**
     * @notice Update token level based on experience
     * @dev Handles level progression logic with milestone events
     * @param staked Reference to staked specimen data
     */
    function _updateTokenLevel(StakedSpecimen storage staked) internal {
        if (staked.level < 100) { // Cap at level 100
            // Get current values
            uint8 currentLevel = staked.level;
            uint256 currentExp = staked.experience;
            
            // Check if token qualifies for next level
            uint256 nextLevelExp = _calculateNextLevelExperience(currentLevel);
            
            if (currentExp >= nextLevelExp) {
                // Check if token qualifies for multiple levels at once
                uint8 newLevel = currentLevel + 1;
                
                // Iteratively check subsequent levels
                while (newLevel < 100) {
                    uint256 nextThreshold = _calculateNextLevelExperience(newLevel);
                    if (currentExp >= nextThreshold) {
                        newLevel++;
                    } else {
                        break;
                    }
                }
                
                // Store old level for event comparison
                uint8 oldLevel = staked.level;
                
                // Update level
                staked.level = newLevel;
                
                // Emit events for significant milestone levels
                if (oldLevel < 25 && newLevel >= 25) {
                    emit TokenMilestoneReached(newLevel, "Silver Milestone");
                } else if (oldLevel < 50 && newLevel >= 50) {
                    emit TokenMilestoneReached(newLevel, "Gold Milestone");
                } else if (oldLevel < 75 && newLevel >= 75) {
                    emit TokenMilestoneReached(newLevel, "Platinum Milestone");
                } else if (oldLevel < 100 && newLevel >= 100) {
                    emit TokenMilestoneReached(newLevel, "Diamond Milestone");
                }
            }
        }
    }
    
    /**
     * @notice Get staking integration data for a token
     * @dev Comprehensive integration data from multiple sources
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return tokenColony Colony ID
     * @return tokenSpecialization Specialization value
     * @return tokenChargeLevel Current charge percentage
     * @return tokenAccessoryCount Number of equipped accessories
     */
    function getIntegrationData(uint256 collectionId, uint256 tokenId) external view returns (
        bytes32 tokenColony,
        uint8 tokenSpecialization,
        uint8 tokenChargeLevel,
        uint8 tokenAccessoryCount
    ) {
        // Get token data from staking storage
        uint256 tokenCombinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = LibStakingStorage.stakingStorage().stakedSpecimens[tokenCombinedId];
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Use staking data as default values
        tokenColony = staked.colonyId;
        tokenSpecialization = staked.specialization;
        tokenChargeLevel = staked.chargeLevel;
        tokenAccessoryCount = 0;
        
        // Try to get up-to-date data from Chargepod
        address chargepod = ss.chargeSystemAddress;
        if (chargepod != address(0)) {
            // Get colony data if not already available
            if (tokenColony == bytes32(0)) {
                try IColonyFacet(chargepod).getTokenColony(collectionId, tokenId) returns (bytes32 colonyId) {
                    tokenColony = colonyId;
                } catch {}
            }
            
            // Get specialization if not already available
            address specAddress = ss.externalModules.specializationModuleAddress != address(0) ?
                ss.externalModules.specializationModuleAddress : chargepod;
                
            if (tokenSpecialization == 0) {
                try ISpecializationFacet(specAddress).getSpecialization(collectionId, tokenId) returns (uint8 spec) {
                    tokenSpecialization = spec;
                } catch {}
            }
            
            // Get accessory count
            address accessoryAddress = ss.externalModules.accessoryModuleAddress != address(0) ?
                ss.externalModules.accessoryModuleAddress : chargepod;
                
            try IExternalAccessory(accessoryAddress).equippedAccessories(collectionId, tokenId) returns (ChargeAccessory[] memory accessories) {
                tokenAccessoryCount = uint8(accessories.length);
            } catch {}
            
            // Get latest charge level
            address queryAddress = ss.externalModules.queryModuleAddress != address(0) ?
                ss.externalModules.queryModuleAddress : chargepod;
                
            try IExternalChargepod(queryAddress).queryPowerMatrix(collectionId, tokenId) returns (PowerMatrix memory matrix) {
                if (matrix.lastChargeTime > 0 && matrix.maxCharge > 0) {
                    tokenChargeLevel = uint8(matrix.currentCharge * 100 / matrix.maxCharge);
                }
            } catch {}
        }
        
        return (tokenColony, tokenSpecialization, tokenChargeLevel, tokenAccessoryCount);
    }

    /**
     * @notice Calculate experience required for next level
     * @dev Implements exponential difficulty curve for leveling
     * @param currentLevel Current token level
     * @return expRequired Experience required for next level
     */
    function _calculateNextLevelExperience(uint256 currentLevel) private pure returns (uint256 expRequired) {
        // Base formula: nextLevel = currentLevel^2 * 100
        expRequired = currentLevel * currentLevel * 100;
        
        // Additional multipliers for higher levels to increase difficulty curve
        if (currentLevel >= 50) {
            expRequired = expRequired * 12 / 10; // +20% for levels 50+
        } else if (currentLevel >= 75) {
            expRequired = expRequired * 15 / 10; // +50% for levels 75+
        } else if (currentLevel >= 90) {
            expRequired = expRequired * 20 / 10; // +100% for levels 90+
        }
        
        return expRequired;
    }
}