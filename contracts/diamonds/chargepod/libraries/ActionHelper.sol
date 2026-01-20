// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibHenomorphsStorage} from "./LibHenomorphsStorage.sol";
import {LibGamingStorage} from "./LibGamingStorage.sol";
import {PodsUtils} from "../../../libraries/PodsUtils.sol";
import {UserEngagement} from "../../../libraries/GamingModel.sol";
import {ChargeSeason, ChargeActionType} from "../../../libraries/HenomorphsModel.sol";

/**
 * @title ActionHelper - FIXED VERSION
 * @notice Centralized action validation with complete original logic restored
 * @dev Single source of truth for all validations - no duplications
 * @author rutilicus.eth (ArchXS)
 */
library ActionHelper {
    uint8 private constant COLONY_ACTION = 5;
    uint8 private constant EXPLORATION_ACTION = 3;

    // =================== EVENTS ===================
    event SpamProtectionTriggered(address indexed user, uint8 actionId, uint256 dailyActions);

    // =================== ERRORS ===================
    error UserActionCooldownActive(address user, uint8 actionId, uint256 timeRemaining);
    error SpamProtectionActive(address user, uint256 timeRemaining);
    error ColonyEventNotActive();
    error ColonyMembershipRequired();
    error DailyActionLimitReached(uint8 current, uint8 max);
    error ActionNotInTimeWindow(uint8 actionId, uint256 availableAt, uint256 expiresAt);
    error InvalidDuration();
    error TimeConflict();
    error InvalidTime();
    error TokenActionCooldownActive(
        uint256 collectionId, 
        uint256 tokenId, 
        uint8 actionId, 
        uint256 timeRemaining
    );
    
    // =================== STRUCTURES ===================
    struct TimeCheck {
        bool valid;
        uint256 adjustedStart;
        uint256 adjustedEnd;
    }
    
    // =================== MAIN VALIDATION FUNCTION ===================
    
    /**
     * @notice Unified validation with token-based smart cooldowns
     * @dev Resolves architecture issue where user cooldowns blocked all user tokens
     */
    function validateUnifiedCooldown(
        address user,
        uint256 collectionId,
        uint256 tokenId,
        uint8 actionId
    ) internal view {

        _validateTokenCooldown(collectionId, tokenId, actionId);
        _validateSmartCooldowns(user, collectionId, tokenId, actionId);
        _validateDailyLimits(user, actionId);
        _validateColonyRequirements(user, collectionId, tokenId, actionId);
        _validateTimeControl(actionId);
    }

    
    /**
     * @notice Update all tracking after successful action
     */
    function updateAfterAction(
        address user,
        uint256 collectionId,
        uint256 tokenId,
        uint8 actionId
    ) internal {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        uint32 currentTime = uint32(block.timestamp);
        uint32 currentDay = uint32(block.timestamp / 86400);
        
        // Always update token action logs
        hs.actionLogs[combinedId][actionId] = currentTime;
        
        // CONDITIONAL: Update user action logs only during colony events
        if (hs.featureFlags["colonyEvents"] && hs.colonyEventConfig.active) {
            uint256 userCombinedId = PodsUtils.combineIds(1, uint256(uint160(user)));
            hs.actionLogs[userCombinedId][actionId] = currentTime;
        }
        
        // FIXED: Centralized activity counting with proper weighting
        uint8 activityPoints = _getActionActivityPoints(actionId);
        
        // Check daily limits before adding (safety check)
        uint256 currentDailyActions = gs.userDailyActivity[user][currentDay];
        
        if (hs.featureFlags["colonyEvents"] && hs.colonyEventConfig.active) {
            if (currentDailyActions >= hs.colonyEventConfig.maxDailyActions) {
                return; // Don't count if over limit
            }
        }
        
        // SINGLE POINT: Update all activity counters here
        gs.userDailyActivity[user][currentDay] += activityPoints;    // Weighted activity points
        gs.userDailyActionCount[user][currentDay]++;                // Simple action counter
        gs.userActionCounts[user][actionId]++;                      // Per-action counter
        gs.userLastActivityTime[user] = block.timestamp;
        
        // Update session tracking
        uint256 lastActivityTime = gs.userLastActivityTime[user];
        if (lastActivityTime == 0 || block.timestamp - lastActivityTime > 1800) {
            gs.userTotalSessions[user]++;
        }
    }
            
    // =================== PRIVATE VALIDATION FUNCTIONS - RESTORED ORIGINAL LOGIC ===================

    function _getActionActivityPoints(uint8 actionId) internal view returns (uint8 activityPoints) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Use configured difficulty tier as activity points
        activityPoints = hs.actionTypes[actionId].difficultyTier;
        
        // Fallback values if not configured
        if (activityPoints == 0) {
            if (actionId == 1) activityPoints = 1;      // Training
            else if (actionId == 2) activityPoints = 2; // Maintenance  
            else if (actionId == 3) activityPoints = 3; // Exploration
            else if (actionId == 4) activityPoints = 4; // Research
            else if (actionId == 5) activityPoints = 5; // Colony
            else activityPoints = 1; // Default
        }
        
        return activityPoints;
    }

    /**
     * @dev Smart cooldowns with conditional user/token based logic
     */
    function _validateSmartCooldowns(
        address user,
        uint256 collectionId,
        uint256 tokenId,
        uint8 actionId
    ) internal view {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint32 currentDay = uint32(block.timestamp / 86400);
        uint256 totalDailyActions = gs.userDailyActivity[user][currentDay];
        
        uint32 requiredCooldown = _calculateSmartCooldown(user, actionId, totalDailyActions);
        
        if (requiredCooldown > 0) {
            uint256 tokenCombinedId = PodsUtils.combineIds(collectionId, tokenId);
            uint32 lastActionTime = hs.actionLogs[tokenCombinedId][actionId];
            
            if (lastActionTime > 0 && block.timestamp < lastActionTime + requiredCooldown) {
                uint256 timeRemaining = (lastActionTime + requiredCooldown) - block.timestamp;
                revert TokenActionCooldownActive(collectionId, tokenId, actionId, timeRemaining);
            }
        }
    }
            
    /**
     * @dev Validate token-specific cooldown (time between actions for same token)
     */
    function _validateTokenCooldown(
        uint256 collectionId,
        uint256 tokenId,
        uint8 actionId
    ) internal view {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        uint32 lastActionTime = hs.actionLogs[combinedId][actionId];
        uint256 baseCooldown = hs.actionTypes[actionId].cooldown;
        
        // Apply Unity Surge cooldown reduction for Action 5
        if (actionId == COLONY_ACTION && 
            hs.featureFlags["colonyEvents"] && 
            hs.colonyEventConfig.active) {
            baseCooldown = hs.colonyEventConfig.cooldownSeconds; // 6h instead of 12h
        }
        
        if (lastActionTime > 0 && block.timestamp < lastActionTime + baseCooldown) {
            revert LibHenomorphsStorage.ActionOnCooldown(collectionId, tokenId, actionId);
        }
    }

    function _validateTokenSmartCooldowns(
        address user,
        uint256 collectionId,
        uint256 tokenId,
        uint8 actionId
    ) internal view {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        uint32 currentDay = uint32(block.timestamp / 86400);
        uint256 totalDailyActions = gs.userDailyActivity[user][currentDay];
        
        // Calculate smart cooldown based on user total activity (anti-spam)
        uint32 requiredCooldown = _calculateSmartCooldown(user, actionId, totalDailyActions);
        
        if (requiredCooldown > 0) {
            // CRITICAL FIX: Use token-based tracking for smart cooldowns
            uint256 tokenCombinedId = PodsUtils.combineIds(collectionId, tokenId);
            LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
            uint32 lastActionTime = hs.actionLogs[tokenCombinedId][actionId];
            
            if (lastActionTime > 0 && block.timestamp < lastActionTime + requiredCooldown) {
                uint256 timeRemaining = (lastActionTime + requiredCooldown) - block.timestamp;
                
                if (totalDailyActions >= 100) {
                    // Only trigger spam protection for very high activity
                    revert SpamProtectionActive(user, timeRemaining);
                } else {
                    // Use token-specific error instead of user error
                    revert TokenActionCooldownActive(collectionId, tokenId, actionId, timeRemaining);
                }
            }
        }
    }
        
    /**
     * @dev Validate user-based smart cooldowns (anti-spam protection)
     */
    function _validateUserSmartCooldowns(address user, uint8 actionId) internal view {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        uint32 currentDay = uint32(block.timestamp / 86400);
        uint256 totalDailyActions = gs.userDailyActivity[user][currentDay];
        
        // Calculate smart cooldown based on total user activity (anti-spam)
        uint32 requiredCooldown = _calculateSmartCooldown(user, actionId, totalDailyActions);
        
        if (requiredCooldown > 0) {
            uint256 userCombinedId = PodsUtils.combineIds(1, uint256(uint160(user)));
            LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
            uint32 lastActionTime = hs.actionLogs[userCombinedId][actionId];
            
            if (lastActionTime > 0 && block.timestamp < lastActionTime + requiredCooldown) {
                uint256 timeRemaining = (lastActionTime + requiredCooldown) - block.timestamp;
                
                if (totalDailyActions >= 50) {
                    revert SpamProtectionActive(user, timeRemaining);
                } else {
                    revert UserActionCooldownActive(user, actionId, timeRemaining);
                }
            }
        }
    }
    
    /**
     * @dev Validate daily limits
     */
    function _validateDailyLimits(address user, uint8 actionId) internal view {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        uint32 currentDay = uint32(block.timestamp / 86400);

        uint32 lastActivityDay = gs.userEngagement[user].lastActivityDay;
        bool countersStale = (lastActivityDay != currentDay && lastActivityDay > 0);

        if (hs.featureFlags["colonyEvents"] && hs.colonyEventConfig.active) {
            // FIX: Use action count instead of weighted points
            uint256 totalActionsToday = gs.userDailyActionCount[user][currentDay];
            
            if (!countersStale && totalActionsToday >= hs.colonyEventConfig.maxDailyActions) {
                revert DailyActionLimitReached(uint8(totalActionsToday), hs.colonyEventConfig.maxDailyActions);
            }
        } else {
            // Existing logic unchanged
            ChargeActionType storage actionType = hs.actionTypes[actionId];
            uint256 currentLimit = _calculateUserActionLimit(user, actionType);
            
            if (currentLimit > 0) {
                uint256 thisActionCountToday = gs.userActionCounts[user][actionId];
                
                if (!countersStale && thisActionCountToday >= currentLimit) {
                    revert DailyActionLimitReached(uint8(thisActionCountToday), uint8(currentLimit));
                }
            }
        }
    }

    /**
     * @dev Calculate user's current limit for specific action
     * @notice Uses proper progression system instead of hardcoded values
     */
    function _calculateUserActionLimit(
        address user, 
        ChargeActionType storage actionType
    ) internal view returns (uint256 currentLimit) {
        currentLimit = actionType.baseDailyLimit;
        
        // Emergency defaults if not configured
        if (currentLimit == 0) {
            // Use reasonable defaults based on action type
            if (actionType.actionCategory == 1) currentLimit = 20;      // Training
            else if (actionType.actionCategory == 2) currentLimit = 15; // Maintenance  
            else if (actionType.actionCategory == 3) currentLimit = 10; // Exploration
            else if (actionType.actionCategory == 4) currentLimit = 8;  // Research
            else if (actionType.actionCategory == 5) currentLimit = 5;  // Colony
            else currentLimit = 10; // Default
        }
        
        // Apply progression bonuses if configured
        if (actionType.progressionBonus > 0 && actionType.progressionStep > 0) {
            LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
            uint32 userStreak = gs.userEngagement[user].currentStreak;
            
            uint32 progressionSteps = userStreak / actionType.progressionStep;
            uint256 bonusActions = progressionSteps * actionType.progressionBonus;
            currentLimit += bonusActions;
            
            if (actionType.maxDailyLimit > 0 && currentLimit > actionType.maxDailyLimit) {
                currentLimit = actionType.maxDailyLimit;
            }
        }
        
        return currentLimit;
    }
    
    /**
     * @dev Validate colony membership requirements
     */
    function _validateColonyRequirements(
        address,
        uint256 collectionId,
        uint256 tokenId,
        uint8 actionId
    ) internal view {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        bool tokenInColony = hs.specimenColonies[combinedId] != bytes32(0);
        
        if (hs.featureFlags["colonyEvents"] && hs.colonyEventConfig.active) {
            uint32 currentDay = LibGamingStorage.getCurrentDay();
            
            if (currentDay < hs.colonyEventConfig.startDay || currentDay > hs.colonyEventConfig.endDay) {
                revert ColonyEventNotActive();
            }
            
            // FIX: Only Action 5 requires colony membership during events
            if (actionId == COLONY_ACTION && !tokenInColony) {
                revert ColonyMembershipRequired();
            }
            // Actions 1-4 are available to everyone
        } else {
            // Normal gameplay: Only Action 5 requires colony membership
            if (actionId == COLONY_ACTION && !tokenInColony) {
                revert ColonyMembershipRequired();
            }
        }
    }
    
    /**
     * @dev Validate time control restrictions
     */
    function _validateTimeControl(uint8 actionId) internal view {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        ChargeActionType storage actionType = hs.actionTypes[actionId];
        
        if (actionType.timeControlEnabled) {
            uint256 currentTime = block.timestamp;
            
            if (currentTime < actionType.startTime) {
                revert ActionNotInTimeWindow(actionId, actionType.startTime, actionType.endTime);
            }
            
            if (actionType.endTime > 0 && currentTime > actionType.endTime) {
                revert ActionNotInTimeWindow(actionId, actionType.startTime, actionType.endTime);
            }
        }
    }
    
    /**
     * @dev Calculate smart cooldown based on user total activity (anti-spam)
     */
    function _calculateSmartCooldown(
        address user,
        uint8 actionId,
        uint256 totalDailyActions
    ) internal view returns (uint32) {
        uint32 baseCooldown = 0;
        
        // Action-specific base cooldowns
        if (actionId == COLONY_ACTION) {
            baseCooldown = 60; // 1 minute for colony actions
        }
        
        // Progressive anti-spam cooldowns based on weighted activity
        if (totalDailyActions >= 1200) {      // ~200+ actual actions
            baseCooldown = baseCooldown > 600 ? baseCooldown : 600; // 10 minutes
        } else if (totalDailyActions >= 900) { // ~150+ actual actions
            baseCooldown = baseCooldown > 300 ? baseCooldown : 300; // 5 minutes
        } else if (totalDailyActions >= 600) { // ~100+ actual actions
            baseCooldown = baseCooldown > 180 ? baseCooldown : 180; // 3 minutes
        }
        
        // Apply user bonuses (reduces cooldowns for experienced users)
        if (baseCooldown > 0) {
            baseCooldown = _applyUserBonuses(user, baseCooldown);
        }
        
        return baseCooldown;
    }
            
    /**
     * @dev Apply user bonuses to reduce smart cooldowns
     */
    function _applyUserBonuses(address user, uint32 baseCooldown) internal view returns (uint32) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (!hs.featureFlags["enableUserBonuses"]) {
            return baseCooldown;
        }
        
        uint32 reducedCooldown = baseCooldown;
        
        // Streak-based cooldown reduction
        uint32 streak = gs.userEngagement[user].currentStreak;
        if (streak >= 30) {
            reducedCooldown = reducedCooldown * 50 / 100; // 50% reduction
        } else if (streak >= 14) {
            reducedCooldown = reducedCooldown * 70 / 100; // 30% reduction
        } else if (streak >= 7) {
            reducedCooldown = reducedCooldown * 85 / 100; // 15% reduction
        }
        
        // Skill-based cooldown reduction
        uint256 skillRating = gs.userSkillRatings[user];
        if (skillRating >= 2000) {
            reducedCooldown = reducedCooldown * 80 / 100; // 20% additional reduction
        } else if (skillRating >= 1500) {
            reducedCooldown = reducedCooldown * 90 / 100; // 10% additional reduction
        }
        
        return reducedCooldown;
    }
    
    /**
    * @notice FIXED: Safe validation for view functions
    * @dev This is the core function used by all batch operations - must be 100% accurate
    */
    function checkUnifiedCooldown(
        address user,
        uint256 collectionId,
        uint256 tokenId,
        uint8 actionId
    ) internal view returns (bool isValid, string memory errorReason) {
        
        // FIX: Handle stale counters consistently
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        uint32 currentDay = uint32(block.timestamp / 86400);
        uint32 lastActivityDay = gs.userEngagement[user].lastActivityDay;
        bool countersStale = (lastActivityDay != currentDay && lastActivityDay > 0);
        
        // 1. Token cooldown check
        if (!_checkTokenCooldown(collectionId, tokenId, actionId)) {
            return (false, "Token cooldown active");
        }
        
        // 2. Smart cooldown check (token-based)
        if (!_checkSmartCooldowns(user, collectionId, tokenId, actionId)) {
            return (false, "Smart cooldown active");
        }
        
        // 3. Daily limits check (with stale counter handling)
        if (!countersStale && !_checkDailyLimits(user, actionId)) {
            return (false, "Daily limit reached");
        }
        
        // 4. Colony requirements check
        if (!_checkColonyRequirements(user, collectionId, tokenId, actionId)) {
            return (false, "Colony membership required");
        }
        
        // 5. Time control check
        if (!_checkTimeControl(actionId)) {
            return (false, "Time window restriction");
        }
        
        return (true, "");
    }
        
    // =================== SAFE CHECK FUNCTIONS (NON-REVERTING) ===================

    /**
     * @dev Smart cooldown check with conditional logic
     */
    function _checkSmartCooldowns(
        address user,
        uint256 collectionId,
        uint256 tokenId,
        uint8 actionId
    ) internal view returns (bool) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint32 currentDay = uint32(block.timestamp / 86400);
        uint256 totalDailyActions = gs.userDailyActivity[user][currentDay];
        
        uint32 requiredCooldown = _calculateSmartCooldown(user, actionId, totalDailyActions);
        
        if (requiredCooldown > 0) {
            uint256 tokenCombinedId = PodsUtils.combineIds(collectionId, tokenId);
            uint32 lastActionTime = hs.actionLogs[tokenCombinedId][actionId];
            
            if (lastActionTime > 0 && block.timestamp < lastActionTime + requiredCooldown) {
                return false;
            }
        }
        
        return true;
    }

    /**
     * @dev Token-based smart cooldown check
     * @notice Non-reverting version of token-based smart cooldowns
     */
    function _checkTokenSmartCooldowns(
        address user,
        uint256 collectionId,
        uint256 tokenId,
        uint8 actionId
    ) internal view returns (bool) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        uint32 currentDay = uint32(block.timestamp / 86400);
        uint256 totalDailyActions = gs.userDailyActivity[user][currentDay];
        
        uint32 requiredCooldown = _calculateSmartCooldown(user, actionId, totalDailyActions);
        
        if (requiredCooldown > 0) {
            // CRITICAL FIX: Use token-based tracking for smart cooldowns
            uint256 tokenCombinedId = PodsUtils.combineIds(collectionId, tokenId);
            LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
            uint32 lastActionTime = hs.actionLogs[tokenCombinedId][actionId];
            
            if (lastActionTime > 0 && block.timestamp < lastActionTime + requiredCooldown) {
                return false;
            }
        }
        
        return true;
    }
    
    function _checkTokenCooldown(
        uint256 collectionId,
        uint256 tokenId,
        uint8 actionId
    ) internal view returns (bool) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        uint32 lastActionTime = hs.actionLogs[combinedId][actionId];
        uint256 baseCooldown = hs.actionTypes[actionId].cooldown;
        
        if (actionId == COLONY_ACTION && 
            hs.featureFlags["colonyEvents"] && 
            hs.colonyEventConfig.active) {
            baseCooldown = hs.colonyEventConfig.cooldownSeconds;
        }
        
        return !(lastActionTime > 0 && block.timestamp < lastActionTime + baseCooldown);
    }
    
    function _checkUserSmartCooldowns(address user, uint8 actionId) internal view returns (bool) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        uint32 currentDay = uint32(block.timestamp / 86400);
        uint256 totalDailyActions = gs.userDailyActivity[user][currentDay];
        
        uint32 requiredCooldown = _calculateSmartCooldown(user, actionId, totalDailyActions);
        
        if (requiredCooldown > 0) {
            uint256 userCombinedId = PodsUtils.combineIds(1, uint256(uint160(user)));
            LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
            uint32 lastActionTime = hs.actionLogs[userCombinedId][actionId];
            
            if (lastActionTime > 0 && block.timestamp < lastActionTime + requiredCooldown) {
                return false;
            }
        }
        
        return true;
    }
    
    /**
    * @notice FIXED: Daily limits check with proper stale counter handling
    */
    function _checkDailyLimits(address user, uint8 actionId) internal view returns (bool) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        uint32 currentDay = uint32(block.timestamp / 86400);

        // Handle stale counters - if stale, user would get reset so limits are available
        uint32 lastActivityDay = gs.userEngagement[user].lastActivityDay;
        bool countersStale = (lastActivityDay != currentDay && lastActivityDay > 0);
        
        if (countersStale) {
            return true;
        }

        if (hs.featureFlags["colonyEvents"] && hs.colonyEventConfig.active) {
            // Colony event mode: check total weighted activity
            uint256 totalActivityToday = gs.userDailyActivity[user][currentDay];
            return !(totalActivityToday >= hs.colonyEventConfig.maxDailyActions);
        } else {
            // Normal mode: check per-action limits with progression
            ChargeActionType storage actionType = hs.actionTypes[actionId];
            uint256 currentLimit = _calculateUserActionLimit(user, actionType);
            
            if (currentLimit == 0) {
                return true; // No limit configured
            }
            
            uint256 thisActionCountToday = gs.userActionCounts[user][actionId];
            return !(thisActionCountToday >= currentLimit);
        }
    }
            
    /**
    * @notice FIXED: Colony requirements check - simplified and consistent
    */
    function _checkColonyRequirements(
        address,
        uint256 collectionId,
        uint256 tokenId,
        uint8 actionId
    ) internal view returns (bool) {
        // Only Action 5 (colony action) requires colony membership
        if (actionId != COLONY_ACTION) {
            return true;
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        bool tokenInColony = hs.specimenColonies[combinedId] != bytes32(0);
        
        // During colony events, also check if event is active
        if (hs.featureFlags["colonyEvents"] && hs.colonyEventConfig.active) {
            uint32 currentDay = LibGamingStorage.getCurrentDay();
            
            if (currentDay < hs.colonyEventConfig.startDay || currentDay > hs.colonyEventConfig.endDay) {
                return false; // Event not active
            }
        }
        
        return tokenInColony;
    }

    
    function _checkTimeControl(uint8 actionId) internal view returns (bool) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        ChargeActionType storage actionType = hs.actionTypes[actionId];
        
        if (actionType.timeControlEnabled) {
            uint256 currentTime = block.timestamp;
            
            if (currentTime < actionType.startTime) {
                return false;
            }
            
            if (actionType.endTime > 0 && currentTime > actionType.endTime) {
                return false;
            }
        }
        
        return true;
    }
    
    /**
     * @notice Validate time window for scheduling
     */
    function validateTimeWindow(
        uint256 startTime,
        uint256 endTime,
        uint256 minDuration
    ) internal view returns (TimeCheck memory result) {
        uint256 _now = block.timestamp;
        
        result.adjustedStart = startTime;
        result.adjustedEnd = endTime;
        result.valid = true;
        
        // Auto-fix recent past times (within 1 hour)
        if (startTime > 0 && startTime < _now && startTime > _now - 3600) {
            result.adjustedStart = _now;
        } else if (startTime > 0 && startTime < _now - 3600) {
            result.valid = false;
            return result;
        }
        
        // Basic end time validation
        if (endTime > 0 && endTime <= result.adjustedStart) {
            result.valid = false;
            return result;
        }
        
        // Minimum duration validation
        if (minDuration > 0 && endTime > 0) {
            uint256 duration = endTime - result.adjustedStart;
            if (duration < minDuration) {
                result.adjustedEnd = result.adjustedStart + minDuration;
            }
        }
    }
    
    /**
     * @notice Validate action schedule for conflicts
     */
    function validateActionSchedule(
        uint8 actionId,
        uint256 startTime,
        uint256 endTime
    ) internal view returns (TimeCheck memory result) {
        result = validateTimeWindow(startTime, endTime, 300); // Minimum 5 minutes
        
        if (!result.valid || actionId == 0 || actionId > 10) {
            result.valid = false;
            return result;
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Check for conflicts with existing schedule
        if (hs.actionTypes[actionId].timeControlEnabled) {
            uint256 existStart = hs.actionTypes[actionId].startTime;
            uint256 existEnd = hs.actionTypes[actionId].endTime;
            
            if (existStart > 0 && existEnd > 0) {
                if ((result.adjustedStart <= existEnd) && (result.adjustedEnd >= existStart)) {
                    result.valid = false;
                }
            }
        }
    }
    
    /**
     * @notice Validate colony event schedule
     */
    function validateColonySchedule(
        bytes32 colonyId,
        uint32 startDay,
        uint32 endDay
    ) internal view returns (bool valid, uint32 adjStart, uint32 adjEnd) {
        uint32 currentDay = LibGamingStorage.getCurrentDay();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        adjStart = startDay;
        adjEnd = endDay;
        valid = true;
        
        // Auto-fix recent past (within 2 days)
        if (startDay < currentDay && startDay > currentDay - 2) {
            adjStart = currentDay;
        } else if (startDay < currentDay - 2) {
            valid = false;
            return (valid, adjStart, adjEnd);
        }
        
        // Basic validation
        if (adjEnd <= adjStart) {
            valid = false;
            return (valid, adjStart, adjEnd);
        }
        
        // Duration limits (3-30 days)
        uint32 duration = adjEnd - adjStart;
        if (duration < 3) {
            adjEnd = adjStart + 3;
        } else if (duration > 30) {
            adjEnd = adjStart + 30;
        }
        
        // Colony exists validation
        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            valid = false;
            return (valid, adjStart, adjEnd);
        }
        
        // Overlap check with current event
        if (hs.colonyEventConfig.active) {
            if ((adjStart <= hs.colonyEventConfig.endDay) && 
                (adjEnd >= hs.colonyEventConfig.startDay)) {
                valid = false;
            }
        }
    }
    
    /**
     * @notice Check if event can execute
     */
    function canExecuteEvent(uint8 eventType) internal view returns (bool canExecute) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint32 currentTime = uint32(block.timestamp);
        
        if (eventType == 1) { // Season
            canExecute = !hs.currentSeason.active;
        } else if (eventType == 2) { // Global charge
            canExecute = (hs.chargeEventEnd <= currentTime);
        } else if (eventType == 3) { // Action schedule
            canExecute = true; // Always allowed, conflicts handled per-action
        } else if (eventType == 4) { // Colony event
            canExecute = !hs.colonyEventConfig.active;
        }
        
        return canExecute;
    }
    
    /**
     * @notice Validate season configuration
     */
    function validateSeasonConfig(
        uint32 intervalHours,
        ChargeSeason calldata seasonConfig
    ) internal pure returns (bool valid) {
        if (intervalHours == 0 || intervalHours > 8760) return false; // Max 1 year interval
        if (bytes(seasonConfig.theme).length == 0) return false;
        if (seasonConfig.endTime < 86400) return false; // Min 1 day
        if (seasonConfig.endTime > 365 days) return false; // Max 1 year
        if (seasonConfig.chargeBoostPercentage == 0 || seasonConfig.chargeBoostPercentage > 200) return false;
        if (seasonConfig.participationThreshold == 0) return false;
        if (seasonConfig.leaderboardSize == 0) return false;
        
        return true;
    }
    
    /**
     * @notice Validate colony event configuration
     */
    function validateColonyEventConfig(
        uint32 intervalHours,
        uint32 durationDays,
        LibHenomorphsStorage.ColonyEventConfig calldata config
    ) internal pure returns (bool valid) {
        if (intervalHours == 0 || intervalHours > 8760) return false;
        if (durationDays < 3 || durationDays > 30) return false;
        if (config.minDailyActions == 0 || config.minDailyActions > config.maxDailyActions) return false;
        if (config.maxDailyActions > 20) return false;
        if (config.cooldownSeconds < 300 || config.cooldownSeconds > 86400) return false; // 5min-24h
        if (config.maxBonusPercent == 0 || config.maxBonusPercent > 200) return false;
        
        // Logic check - interval must be longer than duration
        if (intervalHours * 3600 <= durationDays * 86400) return false;
        
        return true;
    }
    
    /**
     * @notice Validate global charge event configuration
     */
    function validateGlobalChargeConfig(
        uint32 intervalHours,
        uint256 duration,
        uint8 bonus
    ) internal pure returns (bool valid) {
        if (intervalHours == 0 || intervalHours > 8760) return false;
        if (duration < 3600 || duration > 7 days) return false; // 1 hour - 1 week
        if (bonus == 0 || bonus > 200) return false;
        
        // Logic check - interval must be longer than duration
        if (intervalHours * 3600 <= duration) return false;
        
        return true;
    }
    
    /**
     * @notice Validate action multiplier bounds
     */
    function validateActionMultiplier(
        uint8 actionId,
        uint256 proposedMultiplier
    ) internal pure returns (bool isReasonable) {
        uint256 maxMultiplier;
        
        if (actionId == 1 || actionId == 2) {      // Basic actions
            maxMultiplier = 300;                   // Max 3x
        } else if (actionId == 3) {                // Exploration
            maxMultiplier = 500;                   // Max 5x (higher risk)
        } else if (actionId == 4) {                // Special action
            maxMultiplier = 400;                   // Max 4x
        } else if (actionId == 5) {                // Colony action
            maxMultiplier = 200;                   // Max 2x (already has colony bonuses)
        } else {
            maxMultiplier = 200;                   // Default max 2x
        }
        
        return proposedMultiplier <= maxMultiplier;
    }

    /**
     * @dev Ensures daily counters are reset if new day started
     * @notice Must be called BEFORE any daily limit validation
     */
    function ensureDailyReset(address user) internal {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        uint32 today = uint32(block.timestamp / 86400);
        
        UserEngagement storage engagement = gs.userEngagement[user];
        
        // Handle new users (lastActivityDay=0)
        if (engagement.lastActivityDay == 0) {
            engagement.lastActivityDay = today;
            engagement.currentStreak = 1;
            engagement.streakMultiplier = 105;
            
            for (uint8 i = 1; i <= 5; i++) {
                gs.userActionCounts[user][i] = 0;
            }
            gs.userDailyActionCount[user][today] = 0;
            gs.userDailyActivity[user][today] = 0;
            return;
        }
        
        if (engagement.lastActivityDay != today) {
            for (uint8 i = 1; i <= 5; i++) {
                gs.userActionCounts[user][i] = 0;
            }
            gs.userDailyActionCount[user][today] = 0;
            gs.userDailyActivity[user][today] = 0;
            
            if (engagement.lastActivityDay == today - 1) {
                engagement.currentStreak++;
            } else if (engagement.lastActivityDay < today - 1) {
                engagement.currentStreak = 1;
            }
            
            engagement.streakMultiplier = uint128(100 + Math.min(engagement.currentStreak * 5, 100));
            
            if (engagement.currentStreak > engagement.longestStreak) {
                engagement.longestStreak = engagement.currentStreak;
            }
            
            engagement.lastActivityDay = today;
        }
        
        // Safety check: reset counters if they exceed limits (prevents stuck users)
        if (gs.userDailyActionCount[user][today] >= 255) {
            gs.userDailyActionCount[user][today] = 0;
            gs.userDailyActivity[user][today] = 0;
            
            for (uint8 i = 1; i <= 5; i++) {
                gs.userActionCounts[user][i] = 0;
            }
        }
    }

}