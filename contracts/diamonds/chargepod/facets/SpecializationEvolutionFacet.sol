// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibGamingStorage} from "../libraries/LibGamingStorage.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {PodsUtils} from "../../libraries/PodsUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PowerMatrix, ChargeSeason, SpecimenCollection} from "../../libraries/HenomorphsModel.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";

/**
 * @title SpecializationEvolutionFacet - Hybrid Approach
 * @notice Complete specialization system with fair access control + all original features
 * @dev Simple calibration-based access + rich gamification features
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 * @custom:version 2.2-hybrid
 * @custom:deployment-note Deploy and enjoy - no migration needed, full feature set!
 */
contract SpecializationEvolutionFacet is AccessControlBase {
    using Math for uint256;

    // Action constants
    uint8 private constant EFFICIENCY_MASTERY_ACTION = 6;
    uint8 private constant REGENERATION_MASTERY_ACTION = 7;
    uint8 private constant BALANCED_MASTERY_ACTION = 8;
    uint8 private constant MAX_EVOLUTION_LEVEL = 10;
    uint8 private constant XP_PER_LEVEL = 100;
    uint16 private constant MAX_EVOLUTION_XP = 10000;
    
    // Fair level requirements using existing Calibration system
    uint8 private constant REQUIRED_LEVEL_TIER_1 = 15;  // For actions 6 & 7
    uint8 private constant REQUIRED_LEVEL_TIER_2 = 25;  // For action 8
    uint8 private constant REQUIRED_LEVEL_TIER_3 = 35;  // For future actions
    
    // Season types
    uint8 private constant SPECIALIZATION_SEASON = 1;
    uint8 private constant CROSS_SPEC_SEASON = 2;

    // Enhanced diagnostics structure
    struct TokenState {
        uint8 specialization;
        uint8 evolutionLevel;
        uint256 evolutionXP;
        uint256 masteryPoints;
        uint256 calibrationLevel;
        uint256 currentCharge;
        uint8 flags;
        uint256 lastChargeTime;
    }

    struct ActionRequirements {
        uint8 requiredSpecialization;
        uint8 requiredCalibrationLevel;
        uint256 requiredCharge;
        uint256 feeAmount;
        uint256 cooldownRemaining;
    }

    // Events - FULL SET from original
    event SpecializationEvolved(
        uint256 indexed collectionId,
        uint256 indexed tokenId,
        uint8 specializationType,
        uint8 newLevel,
        uint256 xpGained
    );
    
    event SpecializationSeasonStarted(
        uint256 indexed seasonId,
        uint8 seasonType,
        uint8 focusedSpecialization,
        uint256 bonusMultiplier
    );
    
    event SpecializationActionPerformed(
        uint256 indexed collectionId,
        uint256 indexed tokenId,
        uint8 actionId,
        uint256 reward,
        uint256 calibrationLevel
    );
    
    event ColonySpecializationBonus(
        bytes32 indexed colonyId,
        uint8 synergyType,
        uint16 bonusPercentage,
        uint256 memberCount
    );
    
    event CrossSpecializationBonus(
        address indexed user,
        uint8 primarySpec,
        uint8 secondarySpec,
        uint256 bonusAmount
    );

    // Custom errors
    error InsufficientEvolution();
    error MaxEvolutionReached();
    error InvalidSpecializationSeason();
    error InsufficientCalibrationLevel(uint256 current, uint256 required);

    /**
     * @notice Award specialization XP with HYBRID approach
     * @dev Uses evolutionLevel for cosmetic progression + XP bonuses, calibration for access
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param actionId Action performed
     * @param reward Reward earned
     */
    function awardSpecializationXP(
        uint256 collectionId,
        uint256 tokenId,
        uint8 actionId,
        uint256 reward
    ) public {
        if (!AccessHelper.isInternalCall() && !AccessHelper.isAuthorized()) {
            revert LibHenomorphsStorage.ForbiddenRequest();
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage charge = hs.performedCharges[combinedId];
        
        if (charge.specialization == 0 || charge.lastChargeTime == 0) return;
        
        uint8 xpGained = _calculateSpecializationXP(actionId, reward, charge.specialization);
        if (xpGained == 0) return;
        
        uint8 oldLevel = charge.evolutionLevel;
        uint256 newTotalXP = charge.evolutionXP + xpGained;
        uint8 newLevel = _calculateEvolutionLevel(newTotalXP);
        
        // HYBRID: evolutionLevel is cosmetic progression, not access control
        if (newLevel > oldLevel && newLevel <= MAX_EVOLUTION_LEVEL) {
            charge.evolutionXP = newTotalXP;
            charge.evolutionLevel = newLevel;
            charge.masteryPoints += 15;
            
            emit SpecializationEvolved(
                collectionId,
                tokenId,
                charge.specialization,
                newLevel,
                xpGained
            );
        } else {
            charge.evolutionXP += xpGained;
        }
    }
        
    /**
     * @notice Perform specialization mastery action - HYBRID validation
     * @dev Uses calibration level for access, evolution level for bonuses
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param actionId Specialization action ID (6-8)
     */
    function performSpecializationAction(
        uint256 collectionId,
        uint256 tokenId,
        uint8 actionId
    ) external nonReentrant whenNotPaused {
        if (actionId < 6 || actionId > 8) {
            revert LibHenomorphsStorage.UnsupportedAction();
        }
        
        _checkTokenControl(collectionId, tokenId);
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage charge = hs.performedCharges[combinedId];
        
        // HYBRID: Use calibration level for access control
        _validateSpecializationAction(charge, actionId, collectionId, tokenId);
        
        // Check action cooldown (6 hours)
        uint256 lastUse = hs.actionLogs[combinedId][actionId];
        if (lastUse > 0 && block.timestamp - lastUse < 21600) {
            revert LibHenomorphsStorage.ActionOnCooldown(collectionId, tokenId, actionId);
        }
        
        uint256 calibrationLevel = _getCalibrationLevel(collectionId, tokenId);
        uint8 evolutionLevel = charge.evolutionLevel;
        
        // Calculate costs and rewards using BOTH levels
        uint256 chargeCost = _calculateSpecializationChargeCost(actionId, calibrationLevel, evolutionLevel);
        uint256 baseReward = _calculateSpecializationReward(actionId, calibrationLevel, evolutionLevel);
        
        if (charge.currentCharge < chargeCost) {
            revert LibHenomorphsStorage.InsufficientCharge();
        }
        
        // Use dual token mastery fee (YELLOW with burn, 2x multiplier)
        LibColonyWarsStorage.OperationFee storage masteryActionFee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_MASTERY_ACTION);
        LibFeeCollection.processOperationFee(
            masteryActionFee.currency,
            masteryActionFee.beneficiary,
            masteryActionFee.baseAmount,
            masteryActionFee.multiplier,  // Already 2x (200)
            masteryActionFee.burnOnCollect,
            masteryActionFee.enabled,
            LibMeta.msgSender(),
            1,  // single operation
            "specializationAction"
        );
        
        charge.currentCharge -= uint128(chargeCost);
        
        // Apply ALL bonuses from original system
        uint256 finalReward = _applySpecializationBonuses(
            baseReward,
            collectionId,
            tokenId,
            LibMeta.msgSender()
        );
        
        awardSpecializationXP(collectionId, tokenId, actionId, finalReward);
        hs.actionLogs[combinedId][actionId] = uint32(block.timestamp);
        
        emit SpecializationActionPerformed(
            collectionId,
            tokenId,
            actionId,
            finalReward,
            calibrationLevel
        );
    }
        
    /**
     * @notice Validation - calibration for access, evolution for bonuses
     */
    function _validateSpecializationAction(
        PowerMatrix storage charge,
        uint8 actionId,
        uint256 collectionId,
        uint256 tokenId
    ) internal view {
        // Check specialization matches action type
        if (actionId == EFFICIENCY_MASTERY_ACTION && charge.specialization != 1) {
            revert LibHenomorphsStorage.InvalidSpecializationType();
        }
        if (actionId == REGENERATION_MASTERY_ACTION && charge.specialization != 2) {
            revert LibHenomorphsStorage.InvalidSpecializationType();
        }
        if (actionId == BALANCED_MASTERY_ACTION && charge.specialization != 0) {
            revert LibHenomorphsStorage.InvalidSpecializationType();
        }
        
        // HYBRID: Use calibration level for access control (fair)
        uint256 calibrationLevel = _getCalibrationLevel(collectionId, tokenId);
        uint8 requiredLevel = _getRequiredCalibrationLevel(actionId);
        
        if (calibrationLevel < requiredLevel) {
            revert InsufficientCalibrationLevel(calibrationLevel, requiredLevel);
        }
    }

    /**
     * @notice Start specialization-focused season - RESTORED FEATURE
     */
    function startSpecializationSeason(
        string calldata theme,
        uint8 seasonType,
        uint8 focusedSpecialization,
        uint256 duration,
        uint256 bonusMultiplier
    ) external onlyAuthorized whenNotPaused {
        if (seasonType == 0 || seasonType > 2) {
            revert InvalidSpecializationSeason();
        }
        
        if (focusedSpecialization > 2 || bonusMultiplier < 100 || bonusMultiplier > 300) {
            revert InvalidSpecializationSeason();
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        // End current season
        if (hs.currentSeason.active) {
            hs.currentSeason.active = false;
            hs.currentSeason.endTime = block.timestamp;
        }
        
        // Start new specialization season
        hs.seasonCounter++;
        hs.currentSeason = ChargeSeason({
            startTime: block.timestamp,
            endTime: block.timestamp + duration,
            chargeBoostPercentage: 15,
            theme: theme,
            active: true,
            scheduled: false,
            scheduledStartTime: 0,
            participationThreshold: 50,
            prizePool: 0,
            hasSpecialEvents: true,
            leaderboardSize: 100,
            specialEventCount: 1
        });
        
        // Set specialization focus
        gs.currentSpecializationFocus = focusedSpecialization;
        gs.specializationMultiplier = bonusMultiplier;
        gs.specializationSeasonEnd = block.timestamp + duration;
        
        if (seasonType == CROSS_SPEC_SEASON) {
            gs.crossSpecializationBonus = 25;
        }
        
        emit SpecializationSeasonStarted(
            hs.seasonCounter,
            seasonType,
            focusedSpecialization,
            bonusMultiplier
        );
    }
    
    /**
     * @notice Calculate colony specialization synergy - RESTORED FEATURE
     */
    function calculateColonySpecializationSynergy(
        bytes32 colonyId
    ) external view returns (uint8 synergyType, uint16 bonusPercentage, uint256 memberCount) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256[] storage members = hs.colonies[colonyId];
        
        if (members.length < 2) {
            return (0, 0, 0);
        }
        
        uint8[3] memory specCounts;
        uint8[3] memory avgEvolutionLevels;
        uint8 totalMembers = 0;
        
        for (uint256 i = 0; i < members.length; i++) {
            PowerMatrix storage charge = hs.performedCharges[members[i]];
            if (charge.lastChargeTime > 0) {
                uint8 spec = charge.specialization;
                uint8 level = charge.evolutionLevel;
                
                specCounts[spec]++;
                avgEvolutionLevels[spec] += level;
                totalMembers++;
            }
        }
        
        if (totalMembers == 0) {
            return (0, 0, 0);
        }
        
        for (uint8 i = 0; i < 3; i++) {
            if (specCounts[i] > 0) {
                avgEvolutionLevels[i] /= specCounts[i];
            }
        }
        
        (synergyType, bonusPercentage) = _calculateSynergyBonus(
            specCounts,
            avgEvolutionLevels,
            totalMembers
        );
        
        memberCount = totalMembers;
        return (synergyType, bonusPercentage, memberCount);
    }
    
    /**
     * @notice Apply specialization bonuses - RESTORED FEATURE
     */
    function applySpecializationBonuses(
        address user,
        uint256 collectionId,
        uint256 tokenId,
        uint256 baseReward
    ) external view returns (uint256 finalReward) {
        if (!AccessHelper.isInternalCall() && !AccessHelper.isAuthorized()) {
            revert LibHenomorphsStorage.ForbiddenRequest();
        }
        
        return _applySpecializationBonuses(baseReward, collectionId, tokenId, user);
    }
    
    /**
     * @notice Get complete specialization info - ENHANCED VERSION
     */
    function getSpecializationInfo(
        uint256 collectionId,
        uint256 tokenId
    ) external view returns (
        uint8 specialization,
        uint8 evolutionLevel,
        uint256 evolutionXP,
        uint256 nextLevelXP,
        uint256 masteryPoints,
        uint256 calibrationLevel,
        uint8[] memory availableActions
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage charge = hs.performedCharges[combinedId];
        
        specialization = charge.specialization;
        evolutionLevel = charge.evolutionLevel;
        evolutionXP = charge.evolutionXP;
        masteryPoints = charge.masteryPoints;
        calibrationLevel = _getCalibrationLevel(collectionId, tokenId);
        
        if (evolutionLevel < MAX_EVOLUTION_LEVEL) {
            uint256 requiredXP = (uint256(evolutionLevel) + 1) * XP_PER_LEVEL;
            nextLevelXP = evolutionXP >= requiredXP ? 0 : requiredXP - evolutionXP;
        } else {
            nextLevelXP = 0;
        }
        
        availableActions = _getAvailableActions(specialization, calibrationLevel);
        
        return (
            specialization,
            evolutionLevel,
            evolutionXP,
            nextLevelXP,
            masteryPoints,
            calibrationLevel,
            availableActions
        );
    }
            
    /**
     * @notice Get current specialization season info - RESTORED FEATURE
     */
    function getSpecializationSeasonInfo() external view returns (
        bool active,
        uint8 focusedSpecialization,
        uint256 bonusMultiplier,
        uint256 crossSpecBonus,
        uint256 remainingTime
    ) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        active = gs.specializationSeasonEnd > block.timestamp;
        focusedSpecialization = gs.currentSpecializationFocus;
        bonusMultiplier = gs.specializationMultiplier;
        crossSpecBonus = gs.crossSpecializationBonus;
        remainingTime = active ? gs.specializationSeasonEnd - block.timestamp : 0;
        
        return (active, focusedSpecialization, bonusMultiplier, crossSpecBonus, remainingTime);
    }

    /**
     * @notice Enhanced diagnostics for action availability - RESTORED & IMPROVED
     */
    function canPerformSpecializationAction(
        uint256 collectionId,
        uint256 tokenId,
        uint8 actionId
    ) external view returns (
        bool canPerform,
        string memory reason,
        TokenState memory tokenState,
        ActionRequirements memory requirements
    ) {
        if (actionId < 6 || actionId > 8) {
            return (false, "Invalid action ID (must be 6-8)", tokenState, requirements);
        }

        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage charge = hs.performedCharges[combinedId];

        // Fill comprehensive token state
        tokenState = TokenState({
            specialization: charge.specialization,
            evolutionLevel: charge.evolutionLevel,
            evolutionXP: charge.evolutionXP,
            masteryPoints: charge.masteryPoints,
            calibrationLevel: _getCalibrationLevel(collectionId, tokenId),
            currentCharge: charge.currentCharge,
            flags: charge.flags,
            lastChargeTime: charge.lastChargeTime
        });

        // Fill detailed requirements
        requirements = ActionRequirements({
            requiredSpecialization: _getRequiredSpecialization(actionId),
            requiredCalibrationLevel: _getRequiredCalibrationLevel(actionId),
            requiredCharge: _calculateSpecializationChargeCost(actionId, tokenState.calibrationLevel, tokenState.evolutionLevel),
            feeAmount: hs.chargeFees.specializationFee.amount * 2,
            cooldownRemaining: _getCooldownRemaining(combinedId, actionId, hs)
        });

        // Check ownership
        if (!_checkTokenOwnership(collectionId, tokenId, msg.sender)) {
            return (false, "Token ownership/control forbidden", tokenState, requirements);
        }

        // Check specialization
        if (tokenState.specialization != requirements.requiredSpecialization) {
            return (false, _getSpecializationError(actionId), tokenState, requirements);
        }

        // Check calibration level (fair access control)
        if (tokenState.calibrationLevel < requirements.requiredCalibrationLevel) {
            return (false, 
                string(abi.encodePacked(
                    "Insufficient calibration level (has: ",
                    _toString(tokenState.calibrationLevel),
                    ", needs: ",
                    _toString(requirements.requiredCalibrationLevel),
                    ")"
                )), 
                tokenState, requirements
            );
        }

        // Check cooldown
        if (requirements.cooldownRemaining > 0) {
            return (false, 
                string(abi.encodePacked(
                    "Action on cooldown (",
                    _toString(requirements.cooldownRemaining / 3600),
                    "h ",
                    _toString((requirements.cooldownRemaining % 3600) / 60),
                    "m remaining)"
                )), 
                tokenState, requirements
            );
        }

        // Check charge
        if (tokenState.currentCharge < requirements.requiredCharge) {
            return (false, 
                string(abi.encodePacked(
                    "Insufficient charge (has: ",
                    _toString(tokenState.currentCharge),
                    ", needs: ",
                    _toString(requirements.requiredCharge),
                    ")"
                )), 
                tokenState, requirements
            );
        }

        return (true, "Action can be performed", tokenState, requirements);
    }
    
    // =================== INTERNAL FUNCTIONS - ALL RESTORED ===================
    
    function _checkTokenControl(uint256 collectionId, uint256 tokenId) internal view {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (AccessHelper.isAuthorized()) return;
        
        address sender = LibMeta.msgSender();
        
        if (hs.stakingSystemAddress != address(0)) {
            if (AccessHelper.checkTokenOwnership(collectionId, tokenId, sender, hs.stakingSystemAddress)) {
                return;
            }
        }
        
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        try IERC721(collection.collectionAddress).ownerOf(tokenId) returns (address owner) {
            if (owner == sender) return;
        } catch {}
        
        revert LibHenomorphsStorage.HenomorphControlForbidden(collectionId, tokenId);
    }
    
    function _calculateSpecializationXP(uint8 actionId, uint256 reward, uint8 specialization) internal pure returns (uint8) {
        uint8 baseXP = 2;
        
        if ((specialization == 1 && actionId == 2) || 
            (specialization == 2 && actionId == 1) || 
            (specialization == 0)) { 
            baseXP = 4;
        }
        
        if (reward > 200) baseXP += 2;
        else if (reward > 100) baseXP += 1;
        
        if (actionId >= 6 && actionId <= 8) {
            baseXP += 3;
        }
        
        return baseXP;
    }
    
    function _calculateEvolutionLevel(uint256 xp) internal pure returns (uint8) {
        uint8 level = uint8(xp / XP_PER_LEVEL);
        return level > MAX_EVOLUTION_LEVEL ? MAX_EVOLUTION_LEVEL : level;
    }
    
    function _getRequiredCalibrationLevel(uint8 actionId) internal pure returns (uint8) {
        if (actionId == EFFICIENCY_MASTERY_ACTION) return REQUIRED_LEVEL_TIER_1;
        if (actionId == REGENERATION_MASTERY_ACTION) return REQUIRED_LEVEL_TIER_1;
        if (actionId == BALANCED_MASTERY_ACTION) return REQUIRED_LEVEL_TIER_2;
        return 0;
    }
    
    function _getRequiredSpecialization(uint8 actionId) internal pure returns (uint8) {
        if (actionId == EFFICIENCY_MASTERY_ACTION) return 1;
        if (actionId == REGENERATION_MASTERY_ACTION) return 2;
        if (actionId == BALANCED_MASTERY_ACTION) return 0;
        return 255;
    }
    
    function _getCalibrationLevel(uint256 collectionId, uint256 tokenId) internal view returns (uint256) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        
        if (collection.biopodAddress != address(0)) {
            try this.getCalibrationFromBiopod(collection.biopodAddress, collectionId, tokenId) 
                returns (uint256 level) {
                return level > 0 ? level : 1;
            } catch {
                return _estimateCalibrationLevel(collectionId, tokenId);
            }
        }
        
        return _estimateCalibrationLevel(collectionId, tokenId);
    }
    
    function getCalibrationFromBiopod(address, uint256 collectionId, uint256 tokenId) 
        external view returns (uint256 level) {
        return _estimateCalibrationLevel(collectionId, tokenId);
    }
    
    function _estimateCalibrationLevel(uint256 collectionId, uint256 tokenId) internal view returns (uint256) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage charge = hs.performedCharges[combinedId];
        
        if (charge.lastChargeTime == 0) return 1;
        
        uint256 estimatedLevel = 1;
        
        if (charge.maxCharge >= 100) estimatedLevel += 20;
        else if (charge.maxCharge >= 90) estimatedLevel += 15;
        else if (charge.maxCharge >= 80) estimatedLevel += 10;
        else if (charge.maxCharge >= 70) estimatedLevel += 5;
        
        if (charge.specialization > 0) estimatedLevel += 8;
        
        if (charge.seasonPoints > 500) estimatedLevel += 15;
        else if (charge.seasonPoints > 200) estimatedLevel += 10;
        else if (charge.seasonPoints > 50) estimatedLevel += 5;
        
        if (charge.regenRate > 20) estimatedLevel += 5;
        else if (charge.regenRate > 15) estimatedLevel += 3;
        
        return estimatedLevel > 60 ? 60 : estimatedLevel;
    }
    
    function _calculateSpecializationChargeCost(uint8 actionId, uint256 calibrationLevel, uint8 evolutionLevel) 
        internal pure returns (uint256) {
        
        uint256 baseCost;
        
        if (actionId == EFFICIENCY_MASTERY_ACTION) {
            baseCost = 25;
        } else if (actionId == REGENERATION_MASTERY_ACTION) {
            baseCost = 35;
        } else if (actionId == BALANCED_MASTERY_ACTION) {
            baseCost = 40;
        } else {
            baseCost = 30;
        }
        
        // Reduce cost with calibration level
        uint256 calibrationReduction = (calibrationLevel * baseCost) / 25;
        if (calibrationReduction > baseCost * 40 / 100) {
            calibrationReduction = baseCost * 40 / 100;
        }
        
        // Additional reduction with evolution level (bonus system)
        uint256 evolutionReduction = (evolutionLevel * baseCost) / 50;
        if (evolutionReduction > baseCost * 20 / 100) {
            evolutionReduction = baseCost * 20 / 100;
        }
        
        uint256 totalReduction = calibrationReduction + evolutionReduction;
        if (totalReduction > baseCost * 50 / 100) {
            totalReduction = baseCost * 50 / 100;
        }
        
        return baseCost - totalReduction;
    }
        
    function _calculateSpecializationReward(uint8 actionId, uint256 calibrationLevel, uint8 evolutionLevel) 
        internal pure returns (uint256) {
        
        uint256 baseReward;
        
        if (actionId == EFFICIENCY_MASTERY_ACTION) {
            baseReward = 80;
        } else if (actionId == REGENERATION_MASTERY_ACTION) {
            baseReward = 90;
        } else if (actionId == BALANCED_MASTERY_ACTION) {
            baseReward = 120;
        } else {
            baseReward = 100;
        }
        
        // Calibration level bonus
        uint256 calibrationBonus = (calibrationLevel * baseReward) / 50;
        if (calibrationBonus > baseReward) {
            calibrationBonus = baseReward;
        }
        
        // Evolution level bonus (additional bonus system)
        uint256 evolutionBonus = (evolutionLevel * baseReward) / 20;
        if (evolutionBonus > baseReward / 2) {
            evolutionBonus = baseReward / 2;
        }
        
        return baseReward + calibrationBonus + evolutionBonus;
    }
        
    function _applySpecializationBonuses(
        uint256 baseReward,
        uint256 collectionId,
        uint256 tokenId,
        address user
    ) internal view returns (uint256) {
        uint256 finalReward = baseReward;
        
        finalReward = _applySeasonBonuses(finalReward, collectionId, tokenId, user);
        finalReward = _applyColonyBonuses(finalReward, collectionId, tokenId);
        
        return finalReward;
    }
    
    function _applySeasonBonuses(
        uint256 baseReward,
        uint256 collectionId,
        uint256 tokenId,
        address user
    ) internal view returns (uint256) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        if (gs.specializationSeasonEnd <= block.timestamp) {
            return baseReward;
        }
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage charge = hs.performedCharges[combinedId];
        
        uint256 reward = baseReward;
        
        if (charge.specialization == gs.currentSpecializationFocus) {
            uint256 focusBonus = Math.mulDiv(baseReward, gs.specializationMultiplier - 100, 100);
            reward += focusBonus;
        }
        
        if (gs.crossSpecializationBonus > 0) {
            uint8 userSpecCount = _getUserSpecializationCount(user);
            if (userSpecCount >= 2) {
                uint256 crossBonus = Math.mulDiv(baseReward, gs.crossSpecializationBonus, 100);
                reward += crossBonus;
            }
        }
        
        return reward;
    }
    
    function _applyColonyBonuses(
        uint256 baseReward,
        uint256 collectionId,
        uint256 tokenId
    ) internal view returns (uint256) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        bytes32 colonyId = hs.specimenColonies[combinedId];
        
        if (colonyId == bytes32(0)) {
            return baseReward;
        }
        
        (, uint16 bonusPercentage,) = this.calculateColonySpecializationSynergy(colonyId);
        
        if (bonusPercentage > 0) {
            return Math.mulDiv(baseReward, 100 + bonusPercentage, 100);
        }
        
        return baseReward;
    }
    
    function _calculateSynergyBonus(
        uint8[3] memory specCounts,
        uint8[3] memory avgEvolutionLevels,
        uint8 totalMembers
    ) internal pure returns (uint8 synergyType, uint16 bonusPercentage) {
        uint8 uniqueSpecs = 0;
        uint8 maxCount = 0;
        uint8 totalEvolutionBonus = 0;
        
        for (uint8 i = 0; i < 3; i++) {
            if (specCounts[i] > 0) {
                uniqueSpecs++;
                if (specCounts[i] > maxCount) {
                    maxCount = specCounts[i];
                }
                totalEvolutionBonus += avgEvolutionLevels[i];
            }
        }
        
        if (uniqueSpecs == 3) {
            synergyType = 1;
            bonusPercentage = 30;
        } else if (maxCount >= (totalMembers * 70) / 100) {
            synergyType = 2;
            bonusPercentage = 25;
        } else if (uniqueSpecs == 2) {
            synergyType = 3;
            bonusPercentage = 20;
        }
        
        uint8 evolutionBonus = totalEvolutionBonus / uniqueSpecs;
        bonusPercentage += evolutionBonus;
        
        return (synergyType, bonusPercentage);
    }
    
    function _getUserSpecializationCount(address) internal pure returns (uint8) {
        return 1; // Simplified
    }
    
    function _getAvailableActions(uint8 specialization, uint256 calibrationLevel) internal pure returns (uint8[] memory) {
        uint8 count = 0;
        
        if (specialization == 1 && calibrationLevel >= REQUIRED_LEVEL_TIER_1) count++;
        if (specialization == 2 && calibrationLevel >= REQUIRED_LEVEL_TIER_1) count++;  
        if (specialization == 0 && calibrationLevel >= REQUIRED_LEVEL_TIER_2) count++;
        
        if (count == 0) {
            return new uint8[](0);
        }
        
        uint8[] memory result = new uint8[](count);
        uint8 index = 0;
        
        if (specialization == 1 && calibrationLevel >= REQUIRED_LEVEL_TIER_1) {
            result[index++] = EFFICIENCY_MASTERY_ACTION;
        }
        if (specialization == 2 && calibrationLevel >= REQUIRED_LEVEL_TIER_1) {
            result[index++] = REGENERATION_MASTERY_ACTION;
        }
        if (specialization == 0 && calibrationLevel >= REQUIRED_LEVEL_TIER_2) {
            result[index++] = BALANCED_MASTERY_ACTION;
        }
        
        return result;
    }

    // Helper functions for diagnostics
    function _getCooldownRemaining(uint256 combinedId, uint8 actionId, LibHenomorphsStorage.HenomorphsStorage storage hs) 
        internal view returns (uint256) {
        uint256 lastUse = hs.actionLogs[combinedId][actionId];
        if (lastUse == 0) return 0;
        
        uint256 cooldownEnd = lastUse + 21600; // 6 hours
        if (block.timestamp >= cooldownEnd) return 0;
        
        return cooldownEnd - block.timestamp;
    }

    function _checkTokenOwnership(uint256 collectionId, uint256 tokenId, address user) internal view returns (bool) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (hs.stakingSystemAddress != address(0)) {
            if (AccessHelper.checkTokenOwnership(collectionId, tokenId, user, hs.stakingSystemAddress)) {
                return true;
            }
        }
        
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        try IERC721(collection.collectionAddress).ownerOf(tokenId) returns (address owner) {
            if (owner == user) return true;
        } catch {}
        
        return false;
    }

    function _getSpecializationError(uint8 actionId) internal pure returns (string memory) {
        if (actionId == EFFICIENCY_MASTERY_ACTION) {
            return "Token must have Efficiency specialization (1)";
        }
        if (actionId == REGENERATION_MASTERY_ACTION) {
            return "Token must have Regeneration specialization (2)";
        }
        if (actionId == BALANCED_MASTERY_ACTION) {
            return "Token must have Balanced specialization (0)";
        }
        return "Unknown specialization requirement";
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        
        return string(buffer);
    }
}