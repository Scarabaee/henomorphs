// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibGamingStorage} from "../libraries/LibGamingStorage.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {ActionHelper} from "../libraries/ActionHelper.sol";
import {PodsUtils} from "../../libraries/PodsUtils.sol";
import {ChargeActionType, PowerMatrix, ControlFee} from "../../libraries/HenomorphsModel.sol";
import {UserEngagement, FlashParticipation, DailyChallengeSet, AchievementProgress} from "../../libraries/GamingModel.sol";
import {AccessControlBase} from "./AccessControlBase.sol";

/**
 * @title ActionCheckerFacet
 * @notice Essential view functions, admin tools, and core gamification features
 * @dev Complements ChargeFacet with all missing view/admin functionality
 * @author rutilicus.eth (ArchXS)
 */
contract ActionCheckerFacet is AccessControlBase {

    // =================== EVENTS & ERRORS ===================
    
    event UserStateReset(address indexed admin, address indexed user, uint8 indexed resetType, string reason);
    event ActionCooldownReset(address indexed admin, address indexed user, uint8 actionId);
    event StreakUpdated(address indexed user, uint32 currentStreak, uint128 streakMultiplier);
    event AchievementEarned(address indexed user, uint256 indexed achievementId, uint256 reward);
    event DailyChallengeCompleted(address indexed user, uint256 challengeIndex, uint256 reward);
    event ActionLimitsUpdated(
        uint8 indexed actionId,
        uint8 baseDailyLimit,
        uint8 maxDailyLimit,
        uint8 progressionBonus,
        uint8 progressionStep,
        uint8 minChargePercent
    );
    
    error InvalidAction(uint8 actionId);
    error InvalidInput(string reason);

    // Reset type constants
    uint8 constant RESET_COOLDOWNS = 1;
    uint8 constant RESET_DAILY_ACTIVITY = 2;
    uint8 constant RESET_ENGAGEMENT = 3;
    uint8 constant RESET_GAMIFICATION = 4;

    // Action system constants
    uint8 constant MAX_PUBLIC_ACTIONS = 10;    // Actions exposed to UI (1-5)
    uint8 constant MAX_SYSTEM_ACTIONS = 11;    // Internal system actions (includes special action 6)

    // =================== CORE STRUCTURES ===================

    struct LastActionInfo {
        uint8 actionId;              // Which action (1-6)
        uint32 timestamp;            // When performed
        uint32 cooldownEnd;          // When cooldown ends
        string actionName;           // Human readable name
    }

    struct TokenInfo {
        uint256 currentCharge;       // Current charge level
        uint256 maxCharge;          // Max charge capacity
        uint8 fatigueLevel;         // Current fatigue (0-100)
        uint32 totalActions;        // Total actions performed
        uint32 lastActivity;        // Last activity timestamp
        bool isActive;              // Whether token has been used
    }

    struct UserDailyStats {
        uint32 currentDay;          // Current day number
        uint256 actionsToday;       // Actions performed today
        uint256 rewardsToday;       // Rewards earned today
        uint32 currentStreak;       // Current daily streak
        uint256 nextActionAvailable; // When next action is available
    }

    struct ActionStatus {
        uint8 actionId;
        bool available;
        uint256 dailyLimit;           // 0 = unlimited
        uint256 performedToday;
        uint256 cooldownEnd;          // 0 = no cooldown
        string blockReason;           // Empty if available
    }

    struct DailySummary {
        uint32 currentDay;
        uint256 totalActionsToday;
        uint32 currentStreak;
        uint8 availableActionsCount;
        ActionStatus[5] actionStatuses;
        EventStatus events;
        GameStatus gamification;
    }

    struct EventStatus {
        bool colonyEventActive;
        bool globalEventActive;
        uint8 colonyTier;             // 0 if not participating
        uint8 globalBonusPercent;     // 0 if no global event
        uint32 colonyDaysLeft;
    }

    struct GameStatus {
        uint8 challengesCompleted;    // Today's completed challenges (0-3)
        uint16 challengeStreak;       // Consecutive days with challenges
        bool flashEventActive;        // Whether user is in flash event
        uint16 flashEventActions;     // Actions performed in flash event
        uint8 availableAchievements;  // Ready to claim achievements
    }

    struct UserGameState {
        // Engagement
        uint256 totalLifetimeActions;
        uint32 currentStreak;
        uint32 longestStreak;
        uint256 lifetimeRewards;
        
        // Recent activity (last 7 days)
        uint256[] recentDailyActivity;
        
        // Current challenges
        bool hasDailyChallenges;
        uint8 challengesCompleted;
        uint16 challengeStreak;
        
        // Flash event participation
        bool inFlashEvent;
        uint16 flashEventActions;
        uint256 flashEventRewards;
        
        // Achievement status
        uint256[] recentAchievements; // Last 5 earned achievements
    }

    // =================== MAIN VIEW FUNCTIONS ===================

    /**
     * @notice Update action limits and charge requirements
     */
    function updateActionLimits(
        uint8 actionId,
        uint8 baseDailyLimit,
        uint8 maxDailyLimit,
        uint8 progressionBonus,
        uint8 progressionStep,
        uint8 minChargePercent
    ) external onlyAuthorized {
        if (actionId == 0 || actionId > MAX_SYSTEM_ACTIONS) revert InvalidAction(actionId);
        if (maxDailyLimit < baseDailyLimit) revert InvalidInput("Max below base");
        if (minChargePercent > 100) revert InvalidInput("Invalid charge percent");
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        ChargeActionType storage actionType = hs.actionTypes[actionId];
        
        actionType.baseDailyLimit = baseDailyLimit;
        actionType.maxDailyLimit = maxDailyLimit;
        actionType.progressionBonus = progressionBonus;
        actionType.progressionStep = progressionStep;
        actionType.minChargePercent = minChargePercent;
        
        emit ActionLimitsUpdated(actionId, baseDailyLimit, maxDailyLimit, progressionBonus, progressionStep, minChargePercent);
    }

    /**
     * @notice VIEW: Get current action limits configuration
     * @dev Shows how daily limits are configured for each action
     */
    function getActionLimitsConfiguration() 
        external 
        view 
        returns (
            uint8[MAX_PUBLIC_ACTIONS] memory baseLimits,
            uint8[MAX_PUBLIC_ACTIONS] memory maxLimits,
            uint8[MAX_PUBLIC_ACTIONS] memory progressionBonuses,
            uint8[MAX_PUBLIC_ACTIONS] memory progressionSteps
        ) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        for (uint8 i = 0; i < MAX_PUBLIC_ACTIONS; i++) {
            uint8 actionId = i + 1;
            ChargeActionType storage actionType = hs.actionTypes[actionId];
            
            baseLimits[i] = actionType.baseDailyLimit;
            maxLimits[i] = actionType.maxDailyLimit;
            progressionBonuses[i] = actionType.progressionBonus;
            progressionSteps[i] = actionType.progressionStep;
        }
    }

    /**
     * @notice Get user's current and potential limits
     */
    function getUserActionLimits(address user, uint8 actionId) 
        external 
        view 
        returns (
            uint256 currentLimit,
            uint256 nextMilestoneLimit,
            uint32 daysToNextMilestone
        ) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        currentLimit = _calculateHybridLimit(user, actionId);
        
        ChargeActionType storage actionType = hs.actionTypes[actionId];
        
        if (actionType.progressionStep > 0) {
            uint32 currentStreak = gs.userEngagement[user].currentStreak;
            uint32 nextMilestone = ((currentStreak / actionType.progressionStep) + 1) * actionType.progressionStep;
            daysToNextMilestone = nextMilestone - currentStreak;
            
            uint8 nextBonus = uint8(nextMilestone / actionType.progressionStep) * actionType.progressionBonus;
            nextMilestoneLimit = actionType.baseDailyLimit + nextBonus;
            
            if (nextMilestoneLimit > actionType.maxDailyLimit) {
                nextMilestoneLimit = actionType.maxDailyLimit;
            }
        } else {
            nextMilestoneLimit = currentLimit;
            daysToNextMilestone = 0;
        }
    }

    /**
     * @notice Get action status with token-based validation
     * @dev Primary function for checking action availability with proper token context
     */
    function getActionStatus(
        address user, 
        uint256 collectionId,
        uint256 tokenId,
        uint8 actionId
    ) external view returns (ActionStatus memory status) {
        if (actionId == 0 || actionId > MAX_PUBLIC_ACTIONS) revert InvalidAction(actionId);
        
        status.actionId = actionId;
        uint32 currentDay = uint32(block.timestamp / 86400);
        
        (bool available, string memory blockReason) = ActionHelper.checkUnifiedCooldown(
            user, collectionId, tokenId, actionId
        );
        
        status.available = available;
        status.blockReason = blockReason;
        
        (status.performedToday, status.cooldownEnd, status.dailyLimit) = 
            _getCoreTokenActionData(user, collectionId, tokenId, actionId, currentDay);
    }

    /**
     * @notice Get complete daily summary with gamification  
     * @dev Requires token info for accurate action status
     */
    function getDailySummary(
        address user, 
        uint256 collectionId, 
        uint256 tokenId
    ) external view returns (DailySummary memory summary) {
        uint32 currentDay = uint32(block.timestamp / 86400);
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        summary.currentDay = currentDay;
        summary.totalActionsToday = gs.userDailyActivity[user][currentDay];
        summary.currentStreak = gs.userEngagement[user].currentStreak;
        
        // Get all action statuses with consistent validation
        uint8 availableCount = 0;
        for (uint8 i = 1; i <= MAX_PUBLIC_ACTIONS; i++) {
            summary.actionStatuses[i-1] = _getActionStatusInternal(user, collectionId, tokenId, i, currentDay);
            if (summary.actionStatuses[i-1].available) availableCount++;
        }
        summary.availableActionsCount = availableCount;
        
        summary.events = _getEventsStatus(user, currentDay);
        summary.gamification = _getGameStatus(user, currentDay);
    }

    /**
     * @notice Get user's today activity breakdown by action type
     * @param user User address 
     */
    function getUserTodayActivityBreakdown(address user) 
        external 
        view 
        returns (
            uint256 totalActivityPoints,
            uint256 totalActionCount,
            uint256[10] memory actionCounts,
            uint256[10] memory actionPoints
        ) 
    {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        uint32 today = uint32(block.timestamp / 86400);
        
        totalActivityPoints = gs.userDailyActivity[user][today];
        totalActionCount = gs.userDailyActionCount[user][today]; // NEW: show simple counter
        
        for (uint8 i = 1; i <= MAX_PUBLIC_ACTIONS; i++) {
            actionCounts[i-1] = gs.userActionCounts[user][i];
            actionPoints[i-1] = actionCounts[i-1] * _getActionActivityPoints(i);
        }
    }

    /**
     * @notice Get user activity history with weighted scoring
     * @param user User address
     * @param periodInDays Number of days to look back (1-30)
     * @return dailyActivityPoints Array of daily activity points
     * @return averageDailyPoints Average points per day
     * @return activeDays Number of days with activity
     */
    function getUserActivityHistory(address user, uint8 periodInDays) 
        external 
        view 
        returns (
            uint256[] memory dailyActivityPoints,
            uint256 averageDailyPoints,
            uint8 activeDays
        ) 
    {
        if (periodInDays == 0 || periodInDays > 30) revert InvalidInput("Days must be 1-30");
        
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        uint32 currentDay = uint32(block.timestamp / 86400);
        
        dailyActivityPoints = new uint256[](periodInDays);
        uint256 totalPoints = 0;
        activeDays = 0;
        
        for (uint8 i = 0; i < periodInDays; i++) {
            uint32 checkDay = currentDay - i;
            uint256 dayPoints = gs.userDailyActivity[user][checkDay];
            dailyActivityPoints[i] = dayPoints;
            totalPoints += dayPoints;
            if (dayPoints > 0) activeDays++;
        }
        
        averageDailyPoints = periodInDays > 0 ? totalPoints / periodInDays : 0;
    }

    /**
     * @notice Get action performance stats for user with weighted scoring
     * @param user User address
     * @return actionCounts How many times each action was performed [action1, action2, ..., action5]
     * @return actionPoints Total points from each action type [action1_points, action2_points, ...]
     * @return favoriteAction Most performed action ID
     * @return totalActions Total action count across all types
     * @return totalPoints Total activity points across all actions
     */
    function getUserActionStatsWeighted(address user)
        external
        view
        returns (
            uint256[10] memory actionCounts,
            uint256[10] memory actionPoints,
            uint8 favoriteAction,
            uint256 totalActions,
            uint256 totalPoints
        )
    {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        uint256 maxCount = 0;
        favoriteAction = 1;
        
        for (uint8 i = 0; i < MAX_PUBLIC_ACTIONS; i++) {
            uint8 actionId = i + 1; // 1, 2, 3, 4, 5
            actionCounts[i] = gs.userActionCounts[user][actionId];
            actionPoints[i] = actionCounts[i] * _getActionActivityPoints(actionId);
            
            totalActions += actionCounts[i];
            totalPoints += actionPoints[i];
            
            if (actionCounts[i] > maxCount) {
                maxCount = actionCounts[i];
                favoriteAction = actionId;
            }
        }
    }

    /**
     * @notice Get colony event status with weighted activity requirements
     * @param user User address
     * @return active Whether colony event is active
     * @return tier User's tier in colony event
     * @return daysLeft Days remaining in event
     * @return todayQualified Whether user met today's point requirement
     * @return minDailyPoints Minimum points required per day
     * @return maxDailyPoints Maximum points that count per day
     */
    function getColonyEventStatusWeighted(address user) 
        external 
        view 
        returns (
            bool active, 
            uint8 tier, 
            uint32 daysLeft, 
            bool todayQualified, 
            uint16 minDailyPoints, 
            uint16 maxDailyPoints
        ) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        active = hs.colonyEventConfig.active;
        if (!active) return (false, 0, 0, false, 0, 0);
        
        uint32 currentDay = uint32(block.timestamp / 86400);
        
        // Safe subtraction to prevent underflow
        if (hs.colonyEventConfig.endDay > currentDay) {
            daysLeft = hs.colonyEventConfig.endDay - currentDay;
        } else {
            daysLeft = 0;  // Event already ended
        }
        
        // Convert action-based requirements to point-based requirements
        minDailyPoints = uint16(hs.colonyEventConfig.minDailyActions * 3);
        maxDailyPoints = uint16(hs.colonyEventConfig.maxDailyActions * 3);
        
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        uint256 todayPoints = gs.userDailyActivity[user][currentDay];
        todayQualified = todayPoints >= minDailyPoints;
        
        tier = _calculateUserTierWeighted(user, currentDay);
    }


    /**
     * @notice Quick check multiple actions
     */
    function batchCheckActions(
        address user, 
        uint256 collectionId,
        uint256 tokenId,
        uint8[] calldata actionIds
    ) external view returns (bool[] memory available, uint256[] memory waitTimes) {
        uint256 length = actionIds.length;
        if (length == 0 || length > MAX_PUBLIC_ACTIONS) revert InvalidInput("Invalid array length");
        
        available = new bool[](length);
        waitTimes = new uint256[](length);
        
        for (uint256 i = 0; i < length; i++) {
            uint8 actionId = actionIds[i];
            if (actionId == 0 || actionId > MAX_PUBLIC_ACTIONS) {
                available[i] = false;
                waitTimes[i] = 0;
                continue;
            }
            
            // FIX: Use ActionHelper directly - same as action execution
            (available[i], ) = ActionHelper.checkUnifiedCooldown(user, collectionId, tokenId, actionId);
            
            if (!available[i]) {
                waitTimes[i] = _calculateActionWaitTime(user, collectionId, tokenId, actionId);
            }
        }
    }

    /**
     * @notice Check if user can perform action right now with wait time
     */
    function canPerformActionNow(address user, uint8 actionId) 
        external 
        view 
        returns (bool canPerform, uint256 waitTime, string memory reason) 
    {
        if (actionId == 0 || actionId > MAX_PUBLIC_ACTIONS) return (false, 0, "Invalid action");
        
        uint32 currentDay = uint32(block.timestamp / 86400);
        canPerform = _checkUserLevelAvailability(user, actionId, currentDay);
        reason = canPerform ? "" : "User-level restriction active";
        
        if (!canPerform) {
            waitTime = _calculateUserWaitTime(user, actionId, currentDay);
        }
    }

    /**
     * @notice Get user action history (last N days)
     */
    function getActionHistory(address user, uint8 period) 
        external 
        view 
        returns (uint256[] memory dailyActions, uint256 averageDaily, uint8 activeDays) 
    {
        if (period == 0 || period > 14) revert InvalidInput("Days must be 1-14");
        
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        uint32 currentDay = uint32(block.timestamp / 86400);
        
        dailyActions = new uint256[](period);
        uint256 total = 0;
        activeDays = 0;
        
        for (uint8 i = 0; i < period; i++) {
            uint32 checkDay = currentDay - i;
            uint256 dayActions = gs.userDailyActivity[user][checkDay];
            dailyActions[i] = dayActions;
            total += dayActions;
            if (dayActions > 0) activeDays++;
        }
        
        averageDaily = period > 0 ? total / period : 0;
    }

    /**
     * @notice Get colony event status
     */
    function getColonyEventStatus(address user) 
        external 
        view 
        returns (bool active, uint8 tier, uint32 daysLeft, bool todayQualified, uint8 minDaily, uint8 maxDaily) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        active = hs.colonyEventConfig.active;
        if (!active) return (false, 0, 0, false, 0, 0);
        
        uint32 currentDay = uint32(block.timestamp / 86400);
        daysLeft = currentDay <= hs.colonyEventConfig.endDay ? 
            hs.colonyEventConfig.endDay - currentDay : 0;
        
        minDaily = hs.colonyEventConfig.minDailyActions;
        maxDaily = hs.colonyEventConfig.maxDailyActions;
        
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        uint256 todayActions = gs.userDailyActivity[user][currentDay];
        todayQualified = todayActions >= minDaily;
        
        tier = _calculateUserTier(user, currentDay);
    }

    /**
     * @notice Get user's complete gamification state
     */
    function getUserGameState(address user) 
        external 
        view 
        returns (UserGameState memory state) 
    {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        uint32 currentDay = uint32(block.timestamp / 86400);
        
        UserEngagement storage engagement = gs.userEngagement[user];
        state.totalLifetimeActions = engagement.totalLifetimeActions;
        state.currentStreak = engagement.currentStreak;
        state.longestStreak = engagement.longestStreak;
        state.lifetimeRewards = engagement.lifetimeRewards;
        
        // Recent daily activity (last 7 days)
        state.recentDailyActivity = new uint256[](7);
        for (uint8 i = 0; i < 7; i++) {
            state.recentDailyActivity[i] = gs.userDailyActivity[user][currentDay - i];
        }
        
        // Daily challenges
        DailyChallengeSet storage challenges = gs.dailyChallenges[user];
        state.hasDailyChallenges = challenges.dayIssued == currentDay;
        state.challengesCompleted = challenges.completedCount;
        state.challengeStreak = challenges.challengeStreak;
        
        // Flash event
        FlashParticipation storage flash = gs.flashParticipations[user];
        state.inFlashEvent = flash.qualified;
        state.flashEventActions = flash.actionsPerformed;
        state.flashEventRewards = flash.rewardsEarned;
        
        // Recent achievements (simplified - would need more complex logic for real implementation)
        state.recentAchievements = new uint256[](0);
    }

    /**
     * @notice Get last action information for a token
     * @param collectionId Collection ID
     * @param tokenId Token ID  
     * @return lastAction Last action details
     */
    function getLastTokenAction(uint256 collectionId, uint256 tokenId) 
        public 
        view 
        returns (LastActionInfo memory lastAction) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        // Find most recent action
        uint32 mostRecentTime = 0;
        uint8 mostRecentActionId = 0;
        
        // Check all system actions including special ones
        for (uint8 actionId = 1; actionId <= MAX_SYSTEM_ACTIONS; actionId++) {
            uint32 actionTime = hs.actionLogs[combinedId][actionId];
            if (actionTime > mostRecentTime) {
                mostRecentTime = actionTime;
                mostRecentActionId = actionId;
            }
        }
        
        if (mostRecentActionId == 0) {
            return LastActionInfo({
                actionId: 0,
                timestamp: 0,
                cooldownEnd: 0,
                actionName: "No actions yet"
            });
        }
        
        // Calculate cooldown end
        uint256 cooldownDuration = hs.actionTypes[mostRecentActionId].cooldown;
        
        // Handle colony event cooldown override
        if (mostRecentActionId == 5 && hs.featureFlags["colonyEvents"] && hs.colonyEventConfig.active) {
            cooldownDuration = hs.colonyEventConfig.cooldownSeconds;
        }
        
        uint32 cooldownEnd = mostRecentTime + uint32(cooldownDuration);
        
        lastAction = LastActionInfo({
            actionId: mostRecentActionId,
            timestamp: mostRecentTime,
            cooldownEnd: cooldownEnd,
            actionName: _getActionName(mostRecentActionId)
        });
    }

    /**
     * @notice Get comprehensive token information
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return info Complete token status
     */
    function getSubjectedTokenInfo(uint256 collectionId, uint256 tokenId)
        external
        view
        returns (TokenInfo memory info)
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage charge = hs.performedCharges[combinedId];
        
        // Count total actions and find last activity
        uint32 totalActions = 0;
        uint32 lastActivity = 0;
        
        // Count all system actions for complete tracking
        for (uint8 actionId = 1; actionId <= MAX_SYSTEM_ACTIONS; actionId++) {
            uint32 actionTime = hs.actionLogs[combinedId][actionId];
            if (actionTime > 0) {
                totalActions++;
                if (actionTime > lastActivity) {
                    lastActivity = actionTime;
                }
            }
        }
        
        info = TokenInfo({
            currentCharge: charge.currentCharge,
            maxCharge: charge.maxCharge,
            fatigueLevel: uint8(charge.fatigueLevel),
            totalActions: totalActions,
            lastActivity: lastActivity,
            isActive: charge.lastChargeTime > 0
        });
    }

    /**
     * @notice Get time until next action is available
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return secondsUntilNext Seconds until any action is available (0 = available now)
     * @return nextActionId Which action will be available first
     */
    function getNextAvailableAction(uint256 collectionId, uint256 tokenId)
        external
        view
        returns (uint256 secondsUntilNext, uint8 nextActionId)
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        uint256 earliestAvailable = type(uint256).max;
        uint8 earliestActionId = 0;
        
        // Check all system actions to find earliest available
        for (uint8 actionId = 1; actionId <= MAX_SYSTEM_ACTIONS; actionId++) {
            uint32 lastAction = hs.actionLogs[combinedId][actionId];
            
            if (lastAction == 0) {
                // Never performed - available now
                return (0, actionId);
            }
            
            uint256 cooldownDuration = hs.actionTypes[actionId].cooldown;
            
            // Handle colony event cooldown override
            if (actionId == 5 && hs.featureFlags["colonyEvents"] && hs.colonyEventConfig.active) {
                cooldownDuration = hs.colonyEventConfig.cooldownSeconds;
            }
            
            uint256 availableAt = lastAction + cooldownDuration;
            
            if (availableAt < earliestAvailable) {
                earliestAvailable = availableAt;
                earliestActionId = actionId;
            }
        }
        
        if (earliestAvailable <= block.timestamp) {
            return (0, earliestActionId); // Available now
        }
        
        return (earliestAvailable - block.timestamp, earliestActionId);
    }

    /**
     * @notice Check if specific action is available
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param actionId Action to check (1-6)
     * @return available Whether action is available now
     * @return secondsUntilAvailable Seconds until available (0 if available now)
     */
    function checkActionAvailability(uint256 collectionId, uint256 tokenId, uint8 actionId)
        external
        view
        returns (bool available, uint256 secondsUntilAvailable)
    {
        if (actionId == 0 || actionId > MAX_SYSTEM_ACTIONS) {
            return (false, 0);
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        uint32 lastAction = hs.actionLogs[combinedId][actionId];
        
        if (lastAction == 0) {
            return (true, 0); // Never performed - available
        }
        
        uint256 cooldownDuration = hs.actionTypes[actionId].cooldown;
        
        // Handle colony event cooldown override
        if (actionId == 5 && hs.featureFlags["colonyEvents"] && hs.colonyEventConfig.active) {
            cooldownDuration = hs.colonyEventConfig.cooldownSeconds;
        }
        
        uint256 availableAt = lastAction + cooldownDuration;
        
        if (availableAt <= block.timestamp) {
            return (true, 0); // Available now
        }
        
        return (false, availableAt - block.timestamp);
    }

    /**
     * @notice Get user's daily activity summary
     * @param user User address
     * @return stats Daily activity statistics
     */
    function getUserDailyStats(address user)
        external
        view
        returns (UserDailyStats memory stats)
    {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        uint32 currentDay = uint32(block.timestamp / 86400);
        
        stats = UserDailyStats({
            currentDay: currentDay,
            actionsToday: gs.userDailyActivity[user][currentDay],
            rewardsToday: _estimateTodayRewards(user, currentDay),
            currentStreak: gs.userEngagement[user].currentStreak,
            nextActionAvailable: _findNextAvailableActionTime(user)
        });
    }

    /**
     * @notice Get action performance stats for user
     * @param user User address
     * @return actionCounts How many times each action was performed [action1, action2, ..., action5]
     * @return favoriteAction Most performed action ID
     * @return totalActions Total actions across all action types
     */
    function getUserActionStats(address user)
        external
        view
        returns (uint256[10] memory actionCounts, uint8 favoriteAction, uint256 totalActions)
    {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        uint256 maxCount = 0;
        favoriteAction = 1;
        
        for (uint8 i = 0; i < MAX_PUBLIC_ACTIONS; i++) {
            uint8 actionId = i + 1; // 1, 2, 3, 4, 5
            actionCounts[i] = gs.userActionCounts[user][actionId];
            totalActions += actionCounts[i];
            
            if (actionCounts[i] > maxCount) {
                maxCount = actionCounts[i];
                favoriteAction = actionId;
            }
        }
    }

    /**
     * @notice Get multiple tokens' last actions (batch function)
     * @param collectionIds Array of collection IDs
     * @param tokenIds Array of token IDs
     * @return lastActions Array of last action info for each token
     */
    function getBatchLastActions(
        uint256[] calldata collectionIds, 
        uint256[] calldata tokenIds
    ) external view returns (LastActionInfo[] memory lastActions) {
        if (collectionIds.length != tokenIds.length || collectionIds.length > 20) {
            revert InvalidInput("Invalid batch size");
        }
        
        lastActions = new LastActionInfo[](collectionIds.length);
        
        for (uint256 i = 0; i < collectionIds.length; i++) {
            lastActions[i] = getLastTokenAction(collectionIds[i], tokenIds[i]);
        }
    }

    // =================== ESSENTIAL ADMIN FUNCTIONS ===================

    /**
     * @notice Reset user's action cooldowns
     */
    function resetActionCooldowns(address user, uint8[] calldata actionIds, string calldata reason) 
        external 
        onlyAuthorized 
        whenNotPaused 
    {
        if (user == address(0)) revert InvalidInput("Invalid user address");
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 userCombinedId = PodsUtils.combineIds(1, uint256(uint160(user)));
        
        uint8[] memory actionsToReset;
        if (actionIds.length == 0) {
            actionsToReset = new uint8[](MAX_PUBLIC_ACTIONS);
            for (uint8 i = 0; i < MAX_PUBLIC_ACTIONS; i++) {
                actionsToReset[i] = i + 1;
            }
        } else {
            for (uint256 i = 0; i < actionIds.length; i++) {
                if (actionIds[i] == 0 || actionIds[i] > MAX_PUBLIC_ACTIONS) {
                    revert InvalidAction(actionIds[i]);
                }
            }
            actionsToReset = actionIds;
        }
        
        for (uint256 i = 0; i < actionsToReset.length; i++) {
            uint8 actionId = actionsToReset[i];
            hs.actionLogs[userCombinedId][actionId] = 0;
            emit ActionCooldownReset(msg.sender, user, actionId);
        }
        
        emit UserStateReset(msg.sender, user, RESET_COOLDOWNS, reason);
    }

    /**
     * @notice Reset user's daily activity counters
     */
    function resetDailyActivity(address user, uint8 resetDays, string calldata reason) 
        external 
        onlyAuthorized 
        whenNotPaused 
    {
        if (user == address(0)) revert InvalidInput("Invalid user address");
        if (resetDays > 30) revert InvalidInput("Cannot reset more than 30 days");
        
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        uint32 currentDay = uint32(block.timestamp / 86400);
        
        uint8 daysToReset = resetDays == 0 ? 1 : resetDays;
        
        for (uint8 i = 0; i < daysToReset; i++) {
            uint32 dayToReset = currentDay - i;
            gs.userDailyActivity[user][dayToReset] = 0;
        }
        
        emit UserStateReset(msg.sender, user, RESET_DAILY_ACTIVITY, reason);
    }

    /**
     * @notice Reset user's engagement metrics
     */
    function resetUserEngagement(
        address user, 
        bool resetStreak, 
        bool resetLifetime, 
        bool resetRewards,
        string calldata reason
    ) external onlyAuthorized whenNotPaused {
        if (user == address(0)) revert InvalidInput("Invalid user address");
        if (!resetStreak && !resetLifetime && !resetRewards) revert InvalidInput("No reset fields specified");
        
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        UserEngagement storage engagement = gs.userEngagement[user];
        
        if (resetStreak) {
            engagement.currentStreak = 0;
            engagement.longestStreak = 0;
            engagement.streakMultiplier = 100;
            engagement.lastActivityDay = 0;
        }
        
        if (resetLifetime) {
            engagement.totalLifetimeActions = 0;
            engagement.totalPlayTime = 0;
            engagement.totalSessions = 0;
        }
        
        if (resetRewards) {
            engagement.lifetimeRewards = 0;
        }
        
        emit UserStateReset(msg.sender, user, RESET_ENGAGEMENT, reason);
    }

    /**
     * @notice Reset gamification data (challenges, flash events, achievements)
     */
    function resetGamificationData(address user, string calldata reason) 
        external 
        onlyAuthorized 
        whenNotPaused 
    {
        if (user == address(0)) revert InvalidInput("Invalid user address");
        
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        // Reset daily challenges
        DailyChallengeSet storage challengeSet = gs.dailyChallenges[user];
        challengeSet.dayIssued = 0;
        challengeSet.completedCount = 0;
        challengeSet.bonusClaimed = false;
        challengeSet.challengeStreak = 0;
        
        // Reset flash event participation
        FlashParticipation storage participation = gs.flashParticipations[user];
        participation.actionsPerformed = 0;
        participation.rewardsEarned = 0;
        participation.participationTime = 0;
        participation.qualified = false;
        
        // Reset common achievements
        uint256[6] memory commonAchievements = [
            uint256(1000), uint256(1001), uint256(1002), // Streak achievements
            uint256(2000), uint256(2001), uint256(2002)  // Action achievements
        ];
        
        for (uint256 i = 0; i < 6; i++) {
            AchievementProgress storage progress = gs.userAchievements[user][commonAchievements[i]];
            progress.hasEarned = false;
            progress.earnedAt = 0;
            progress.currentProgress = 0;
        }
        
        emit UserStateReset(msg.sender, user, RESET_GAMIFICATION, reason);
    }

    /**
     * @notice Debug action status with detailed info
     */
    function checkActionStatus(address user, uint8 actionId) 
        external 
        view 
        returns (bool canPerform, string memory details) 
    {
        if (actionId == 0 || actionId > MAX_PUBLIC_ACTIONS) return (false, "Invalid action ID");
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        uint32 currentDay = uint32(block.timestamp / 86400);

        ChargeActionType storage actionType = hs.actionTypes[actionId];
        
        // Check daily limits without reverting
        if (hs.featureFlags["colonyEvents"] && hs.colonyEventConfig.active) {
            uint256 totalActionsToday = gs.userDailyActivity[user][currentDay];
            if (totalActionsToday >= hs.colonyEventConfig.maxDailyActions) {
                return (false, "Daily limit reached in colony event");
            }
        } else {
            
            uint256 currentLimit = _calculateHybridLimit(user, actionId);
            if (currentLimit > 0) {
                uint256 thisActionCount = gs.userActionCounts[user][actionId];
                if (thisActionCount >= currentLimit) {
                    return (false, "Action daily limit reached");
                }
            }
        }
        
        // Check colony membership requirement
        if (actionId == 5) {
            bytes32[] storage userColonies = hs.userColonies[user];
            if (userColonies.length == 0) {
                return (false, "Colony membership required");
            }
        }
        
        // Check time control restrictions
        if (actionType.timeControlEnabled) {
            uint256 currentTime = block.timestamp;
            
            if (currentTime < actionType.startTime) {
                return (false, "Action not yet available");
            }
            
            if (actionType.endTime > 0 && currentTime > actionType.endTime) {
                return (false, "Action time window expired");
            }
        }
        
        return (true, "Available");
    }

    /**
     * @notice Simple debug for fee collection
     * @dev Admin only - debug Transfer forbidden issue
     */
    function checkFeeCollection(address user, uint8 actionId) external view returns (
        address currency,
        uint256 amount,
        address beneficiary,
        uint256 userBalance,
        uint256 userAllowance,
        bool balanceOK,
        bool allowanceOK
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Get fee exactly like performAction does
        ControlFee memory actionFee = hs.actionFees[actionId];
        if (actionFee.beneficiary == address(0)) {
            actionFee = hs.actionTypes[actionId].baseCost;
        }
        
        currency = address(actionFee.currency);
        amount = actionFee.amount;
        beneficiary = actionFee.beneficiary;
        
        if (amount == 0) {
            return (currency, 0, beneficiary, 0, 0, true, true);
        }
        
        // Check exactly like LibFeeCollection does
        IERC20 token = IERC20(currency);
        userBalance = token.balanceOf(user);
        userAllowance = token.allowance(user, address(this));
        
        balanceOK = userBalance >= amount;
        allowanceOK = userAllowance >= amount;
        
        return (currency, amount, beneficiary, userBalance, userAllowance, balanceOK, allowanceOK);
    }
    

    // =================== ESSENTIAL GAMIFICATION FUNCTIONS ===================

    /**
     * @notice Manual streak update (emergency admin function)
     */
    function updateUserStreak(address user, uint32 newStreak, string calldata reason) 
        external 
        onlyAuthorized 
        whenNotPaused 
    {
        if (user == address(0)) revert InvalidInput("Invalid user address");
        
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        UserEngagement storage engagement = gs.userEngagement[user];
        
        engagement.currentStreak = newStreak;
        engagement.streakMultiplier = uint128(100 + (newStreak * 5 > 100 ? 100 : newStreak * 5));
        
        if (newStreak > engagement.longestStreak) {
            engagement.longestStreak = newStreak;
        }
        
        emit StreakUpdated(user, newStreak, engagement.streakMultiplier);
        emit UserStateReset(msg.sender, user, RESET_ENGAGEMENT, reason);
    }

    /**
     * @notice Check and potentially award achievements
     */
    function checkUserAchievements(address user) 
        external 
        view 
        returns (uint256[] memory readyAchievements) 
    {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        UserEngagement storage engagement = gs.userEngagement[user];
        
        uint256[] memory tempAchievements = new uint256[](6);
        uint256 count = 0;
        
        // Check streak achievements
        uint256[3] memory streakMilestones = [uint256(7), uint256(14), uint256(30)];
        for (uint256 i = 0; i < 3; i++) {
            uint256 achievementId = 1000 + i;
            if (engagement.currentStreak >= streakMilestones[i] && 
                !gs.userAchievements[user][achievementId].hasEarned) {
                tempAchievements[count++] = achievementId;
            }
        }
        
        // Check action achievements
        uint256[3] memory actionMilestones = [uint256(100), uint256(500), uint256(1000)];
        for (uint256 i = 0; i < 3; i++) {
            uint256 achievementId = 2000 + i;
            if (engagement.totalLifetimeActions >= actionMilestones[i] && 
                !gs.userAchievements[user][achievementId].hasEarned) {
                tempAchievements[count++] = achievementId;
            }
        }
        
        // Return only the achievements that are ready
        readyAchievements = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            readyAchievements[i] = tempAchievements[i];
        }
    }

    function getChargeRequirementStatus(
        uint256 collectionId, 
        uint256 tokenId,
        uint8 actionId
    ) external view returns (
        bool sufficient,
        uint256 requiredCharge,
        uint256 currentCharge,
        uint256 maxCharge,
        uint8 requiredPercent
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        PowerMatrix storage _charge = hs.performedCharges[combinedId];
        ChargeActionType storage actionType = hs.actionTypes[actionId];
        
        currentCharge = _charge.currentCharge;
        maxCharge = _charge.maxCharge;
        requiredPercent = actionType.minChargePercent;
        
        if (actionType.minChargePercent > 0) {
            requiredCharge = (_charge.maxCharge * actionType.minChargePercent) / 100;
            sufficient = _charge.currentCharge >= requiredCharge;
        } else {
            requiredCharge = 0;
            sufficient = true;
        }
    }

    /**
     * @notice NEW: Get detailed action limit information for user
     * @dev Provides transparency into how limits are calculated
     */
    function getUserActionLimitDetails(address user, uint8 actionId) 
        external 
        view 
        returns (
            uint256 baseLimit,
            uint256 currentLimit,
            uint256 maxLimit,
            uint32 userStreak,
            uint32 progressionSteps,
            uint256 bonusActions,
            uint256 performedToday,
            uint256 remaining
        ) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        ChargeActionType storage actionType = hs.actionTypes[actionId];
        
        baseLimit = actionType.baseDailyLimit;
        maxLimit = actionType.maxDailyLimit;
        userStreak = gs.userEngagement[user].currentStreak;
        
        // Calculate progression
        if (actionType.progressionStep > 0) {
            progressionSteps = userStreak / actionType.progressionStep;
            bonusActions = progressionSteps * actionType.progressionBonus;
        }
        
        // Calculate current limit
        currentLimit = baseLimit + bonusActions;
        if (maxLimit > 0 && currentLimit > maxLimit) {
            currentLimit = maxLimit;
        }
        
        // Get usage
        performedToday = gs.userActionCounts[user][actionId];
        
        remaining = currentLimit > performedToday ? currentLimit - performedToday : 0;
    }

    /**
     * @notice Reset action counts for specific users (ADMIN ONLY)
     * @param users Array of user addresses to reset
     */
    function resetUserActionCounts(address[] calldata users) external onlyAuthorized {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        for (uint256 i = 0; i < users.length; i++) {
            for (uint8 actionId = 1; actionId <= MAX_PUBLIC_ACTIONS; actionId++) {
                gs.userActionCounts[users[i]][actionId] = 0;
            }
        }
    }

    function resetUserCounters(
        address[] calldata users,
        uint32 targetDay
    ) external onlyAuthorized {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        uint32 dayToReset = targetDay == 0 ? uint32(block.timestamp / 86400) : targetDay;
        
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            
            // Reset wszystkie liczniki
            gs.userDailyActionCount[user][dayToReset] = 0;
            gs.userDailyActivity[user][dayToReset] = 0;
            
            for (uint8 actionId = 1; actionId <= 5; actionId++) {
                gs.userActionCounts[user][actionId] = 0;
            }
            
            gs.userEngagement[user].lastActivityDay = dayToReset;
        }
    }

    /**
     * @notice Get user's current action counts
     * @param user User address
     * @return counts Array of action counts [action1, action2, action3, action4, action5]
     */
    function getUserActionCounts(address user) external view returns (uint256[] memory counts) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        counts = new uint256[](MAX_PUBLIC_ACTIONS);
        for (uint8 i = 1; i <= MAX_PUBLIC_ACTIONS; i++) {
            counts[i-1] = gs.userActionCounts[user][i];
        }
    }

    // =================== INTERNAL FUNCTIONS ===================
    
    /**
    * @notice Calculate wait time for user-level restrictions only
    */
    function _calculateUserWaitTime(address user, uint8 actionId, uint32 currentDay) 
        internal 
        view 
        returns (uint256) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        uint32 lastActivityDay = gs.userEngagement[user].lastActivityDay;
        bool countersStale = (lastActivityDay != currentDay && lastActivityDay > 0);
        
        if (!countersStale) {
            bool hitLimit = false;
            
            if (hs.featureFlags["colonyEvents"] && hs.colonyEventConfig.active) {
                uint256 totalActionsToday = gs.userDailyActivity[user][currentDay];
                hitLimit = (totalActionsToday >= hs.colonyEventConfig.maxDailyActions);
            } else {
                uint256 currentLimit = _calculateHybridLimit(user, actionId);
                if (currentLimit > 0) {
                    uint256 thisActionCount = gs.userActionCounts[user][actionId];
                    hitLimit = (thisActionCount >= currentLimit);
                }
            }
            
            if (hitLimit) {
                return ((currentDay + 1) * 86400) - block.timestamp;
            }
        }
        
        return 0;
    }

    /**
    * @notice Check user-level availability (without token-specific checks)
    * @dev Used by canPerformActionNow which lacks token context
    */
    function _checkUserLevelAvailability(address user, uint8 actionId, uint32 currentDay) 
        internal 
        view 
        returns (bool) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        // Check daily limits with stale counter handling
        uint32 lastActivityDay = gs.userEngagement[user].lastActivityDay;
        bool countersStale = (lastActivityDay != currentDay && lastActivityDay > 0);
        
        if (!countersStale) {
            if (hs.featureFlags["colonyEvents"] && hs.colonyEventConfig.active) {
                uint256 totalActionsToday = gs.userDailyActivity[user][currentDay];
                if (totalActionsToday >= hs.colonyEventConfig.maxDailyActions) {
                    return false;
                }
                
                // Check event time window
                if (currentDay < hs.colonyEventConfig.startDay || currentDay > hs.colonyEventConfig.endDay) {
                    return false;
                }
            } else {
                uint256 currentLimit = _calculateHybridLimit(user, actionId);
                if (currentLimit > 0) {
                    uint256 thisActionCount = gs.userActionCounts[user][actionId];
                    if (thisActionCount >= currentLimit) {
                        return false;
                    }
                }
            }
        }
        
        // Check colony membership for action 5 (user level - can't check specific token)
        if (actionId == 5 && !_hasColonyMembership(user)) {
            return false;
        }
        
        // Check time control restrictions
        ChargeActionType storage actionType = hs.actionTypes[actionId];
        if (actionType.timeControlEnabled) {
            if (block.timestamp < actionType.startTime) return false;
            if (actionType.endTime > 0 && block.timestamp > actionType.endTime) return false;
        }
        
        return true;
    }

    /**
    * @notice FIXED: Calculate wait time based on actual blocking conditions
    * @dev Comprehensive wait time calculation matching all validation checks
    */
    function _calculateActionWaitTime(
        address user,
        uint256 collectionId, 
        uint256 tokenId,
        uint8 actionId
    ) internal view returns (uint256) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        uint32 currentDay = uint32(block.timestamp / 86400);
        uint256 maxWaitTime = 0;
        
        // 1. Check token cooldown
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        uint32 lastAction = hs.actionLogs[combinedId][actionId];
        uint256 baseCooldown = hs.actionTypes[actionId].cooldown;
        
        // Handle colony event cooldown override
        if (actionId == 5 && hs.featureFlags["colonyEvents"] && hs.colonyEventConfig.active) {
            baseCooldown = hs.colonyEventConfig.cooldownSeconds;
        }
        
        if (lastAction > 0 && block.timestamp < lastAction + baseCooldown) {
            uint256 tokenWait = (lastAction + baseCooldown) - block.timestamp;
            if (tokenWait > maxWaitTime) maxWaitTime = tokenWait;
        }
        
        // 2. Check smart cooldown (anti-spam)
        uint256 totalDailyActions = gs.userDailyActivity[user][currentDay];
        uint32 smartCooldown = _calculateSmartCooldown(user, actionId, totalDailyActions);
        
        if (smartCooldown > 0 && lastAction > 0) {
            uint256 smartWaitEnd = lastAction + smartCooldown;
            if (block.timestamp < smartWaitEnd) {
                uint256 smartWait = smartWaitEnd - block.timestamp;
                if (smartWait > maxWaitTime) maxWaitTime = smartWait;
            }
        }
        
        // 3. Check daily limits (only if counters not stale)
        uint32 lastActivityDay = gs.userEngagement[user].lastActivityDay;
        bool countersStale = (lastActivityDay != currentDay && lastActivityDay > 0);
        
        if (!countersStale) {
            bool hitLimit = false;
            
            if (hs.featureFlags["colonyEvents"] && hs.colonyEventConfig.active) {
                hitLimit = (totalDailyActions >= hs.colonyEventConfig.maxDailyActions);
            } else {
                uint256 currentLimit = _calculateHybridLimit(user, actionId);
                if (currentLimit > 0) {
                    uint256 thisActionCount = gs.userActionCounts[user][actionId];
                    hitLimit = (thisActionCount >= currentLimit);
                }
            }
            
            if (hitLimit) {
                uint256 dailyWait = ((currentDay + 1) * 86400) - block.timestamp;
                if (dailyWait > maxWaitTime) maxWaitTime = dailyWait;
            }
        }
        
        return maxWaitTime;
    }

    /**
     * @notice Internal helper to get action status with consistent validation
     * @dev Uses MAX_PUBLIC_ACTIONS for UI-related status checks
     */
    function _getActionStatusInternal(
        address user, 
        uint256 collectionId, 
        uint256 tokenId, 
        uint8 actionId, 
        uint32 currentDay
    ) internal view returns (ActionStatus memory status) {
        status.actionId = actionId;
        
        (status.performedToday, status.cooldownEnd, status.dailyLimit) = 
            _getCoreActionData(user, actionId, currentDay);
        
        (status.available, status.blockReason) = ActionHelper.checkUnifiedCooldown(
            user, collectionId, tokenId, actionId
        );
    }

    /**
     * @notice Get core action data for internal use
     */
    function _getCoreActionData(address user, uint8 actionId, uint32 currentDay) 
        internal 
        view 
        returns (uint256 userActivity, uint256 cooldownEnd, uint256 dailyLimit) 
    {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        userActivity = gs.userDailyActivity[user][currentDay];
        
        if (hs.featureFlags["colonyEvents"] && hs.colonyEventConfig.active) {
            uint256 userCombinedId = PodsUtils.combineIds(1, uint256(uint160(user)));
            uint32 lastAction = hs.actionLogs[userCombinedId][actionId];
            uint256 cooldown = hs.actionTypes[actionId].cooldown;
            
            if (actionId == 5 && hs.colonyEventConfig.cooldownSeconds > 0) {
                cooldown = hs.colonyEventConfig.cooldownSeconds;
            }
            
            cooldownEnd = lastAction > 0 ? lastAction + cooldown : 0;
            dailyLimit = hs.colonyEventConfig.maxDailyActions;
        } else {
            cooldownEnd = 0;
            dailyLimit = _calculateHybridLimit(user, actionId);
        }
    }

    function _getCoreTokenActionData(
        address user, 
        uint256 collectionId, 
        uint256 tokenId, 
        uint8 actionId, 
        uint32 currentDay
    ) internal view returns (uint256 userActivity, uint256 cooldownEnd, uint256 dailyLimit) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // User daily activity (unchanged)
        userActivity = gs.userDailyActivity[user][currentDay];
        
        // FIXED: Use token-based cooldown calculation
        uint256 tokenCombinedId = PodsUtils.combineIds(collectionId, tokenId);
        uint32 lastAction = hs.actionLogs[tokenCombinedId][actionId];
        
        // Calculate effective cooldown (includes both token and smart cooldowns)
        uint256 baseCooldown = hs.actionTypes[actionId].cooldown;
        
        // Handle colony event cooldown override
        if (actionId == 5 && hs.featureFlags["colonyEvents"] && hs.colonyEventConfig.active) {
            baseCooldown = hs.colonyEventConfig.cooldownSeconds;
        }
        
        // Calculate smart cooldown
        uint256 totalDailyActions = gs.userDailyActivity[user][currentDay];
        uint32 smartCooldown = _calculateSmartCooldown(user, actionId, totalDailyActions);
        
        // Use the longer of the two cooldowns
        uint256 effectiveCooldown = baseCooldown > smartCooldown ? baseCooldown : smartCooldown;
        
        cooldownEnd = lastAction > 0 ? lastAction + effectiveCooldown : 0;
        
        // FIXED: Use configurable daily limit calculation
        dailyLimit = _calculateHybridLimit(user, actionId);
    }

    /**
     * @notice Calculate hybrid limit for action
     */
    function _calculateHybridLimit(address user, uint8 actionId) 
        internal 
        view 
        returns (uint256 limit) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        ChargeActionType storage actionType = hs.actionTypes[actionId];
        
        // Start with configured base limit (NOT hardcoded)
        limit = actionType.baseDailyLimit;
        
        // Add progression bonus if configured
        if (actionType.progressionBonus > 0 && actionType.progressionStep > 0) {
            uint32 userStreak = gs.userEngagement[user].currentStreak;
            uint32 progressionSteps = userStreak / actionType.progressionStep;
            uint256 bonusActions = progressionSteps * actionType.progressionBonus;
            limit += bonusActions;
            
            // Apply cap
            if (actionType.maxDailyLimit > 0 && limit > actionType.maxDailyLimit) {
                limit = actionType.maxDailyLimit;
            }
        }
        
        return limit;
    }

    function _calculateUnifiedWaitTime(
        address user,
        uint256 collectionId,
        uint256 tokenId,
        uint8 actionId
    ) internal view returns (uint256 waitTime) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        uint256 tokenCombinedId = PodsUtils.combineIds(collectionId, tokenId);
        uint32 lastTokenAction = hs.actionLogs[tokenCombinedId][actionId];
        uint256 baseCooldown = hs.actionTypes[actionId].cooldown;
        
        if (actionId == 5 && hs.featureFlags["colonyEvents"] && hs.colonyEventConfig.active) {
            baseCooldown = hs.colonyEventConfig.cooldownSeconds;
        }
        
        uint256 tokenCooldownEnd = lastTokenAction > 0 ? lastTokenAction + baseCooldown : 0;
        
        uint32 currentDay = uint32(block.timestamp / 86400);
        uint256 totalDailyActions = gs.userDailyActivity[user][currentDay];
        uint32 smartCooldown = _calculateSmartCooldown(user, actionId, totalDailyActions);
        
        uint256 smartCooldownEnd = 0;
        if (smartCooldown > 0) {
            smartCooldownEnd = lastTokenAction > 0 ? lastTokenAction + smartCooldown : 0;
        }
        
        uint256 effectiveCooldownEnd = tokenCooldownEnd > smartCooldownEnd ? tokenCooldownEnd : smartCooldownEnd;
        
        if (effectiveCooldownEnd > block.timestamp) {
            waitTime = effectiveCooldownEnd - block.timestamp;
        } else {
            waitTime = _calculateDailyLimitWaitTime(user, actionId, currentDay);
        }
        
        return waitTime;
    }

    /**
     * @notice Calculate daily limit wait time
     */
    function _calculateDailyLimitWaitTime(
        address user,
        uint8 actionId,
        uint32 currentDay
    ) internal view returns (uint256) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        if (hs.featureFlags["colonyEvents"] && hs.colonyEventConfig.active) {
            // Colony events: Check total user actions
            uint256 totalUserActionsToday = gs.userDailyActivity[user][currentDay];
            if (totalUserActionsToday >= hs.colonyEventConfig.maxDailyActions) {
                return ((currentDay + 1) * 86400) - block.timestamp; // Until next day
            }
        } else {
            // Normal gameplay: Check action-specific limits
            uint256 currentLimit = _calculateHybridLimit(user, actionId);
            
            if (currentLimit > 0) {
                uint256 thisActionCount = gs.userActionCounts[user][actionId];
                if (thisActionCount >= currentLimit) {
                    return ((currentDay + 1) * 86400) - block.timestamp; // Until next day
                }
            }
        }
        
        return 0; // No daily limit restriction
    }

    /**
     * @notice Helper: Calculate smart cooldown for display purposes
     * @dev Simplified version of ActionHelper's smart cooldown calculation
     */
    function _calculateSmartCooldown(
        address user,
        uint8 actionId,
        uint256 totalDailyActions
    ) internal view returns (uint32) {
        uint32 baseCooldown = 0;
        
        // FIXED: Much more reasonable action-specific cooldowns
        if (actionId == 5) { // Colony action
            baseCooldown = 60; // 1 minute instead of 3 minutes
        }
        
        // FIXED: Much more reasonable anti-spam cooldowns
        if (totalDailyActions >= 200) {        // Extreme spam (was 100)
            baseCooldown = baseCooldown > 300 ? baseCooldown : 300; // 5 min (was 10 min)
        } else if (totalDailyActions >= 100) { // Heavy use (was 50)
            baseCooldown = baseCooldown > 180 ? baseCooldown : 180; // 3 min (was 5 min)
        } else if (totalDailyActions >= 50) {  // Moderate use (was 30)
            baseCooldown = baseCooldown > 60 ? baseCooldown : 60;   // 1 min (was 1 min)
        }
        // Below 50 actions = no smart cooldown (was 30)
        
        // Apply user bonuses (unchanged - reduces cooldowns)
        if (baseCooldown > 0) {
            baseCooldown = ActionHelper._applyUserBonuses(user, baseCooldown);
        }
        
        return baseCooldown;
    }

    /**
     * @notice Calculate activity points for action based on difficulty
     * @param actionId Action ID (1-5)
     * @return activityPoints Activity points awarded for this action
     */
    function _getActionActivityPoints(uint8 actionId) internal view returns (uint8 activityPoints) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Use action difficulty as activity points
        activityPoints = hs.actionTypes[actionId].difficultyTier;
        
        // Fallback if difficulty not set
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
     * @notice Calculate user's colony tier based on weighted activity points
     */
    function _calculateUserTierWeighted(address user, uint32 currentDay) internal view returns (uint8 tier) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        uint16 minDailyPoints = uint16(hs.colonyEventConfig.minDailyActions * 3);
        uint8 qualifiedDays = 0;
        
        uint32 eventStart = hs.colonyEventConfig.startDay;
        uint32 eventEnd = hs.colonyEventConfig.endDay;
        
        // Prevent infinite loops by limiting range
        if (eventStart == 0 || eventEnd == 0 || eventEnd < eventStart) {
            return 1;
        }
        
        // Limit range to prevent gas issues
        uint32 maxRange = 90;
        if (eventEnd - eventStart > maxRange) {
            eventStart = eventEnd - maxRange;
        }
        
        // Add iteration counter for safety
        uint32 iterations = 0;
        for (uint32 day = eventStart; day <= eventEnd && day <= currentDay; day++) {
            iterations++;
            if (iterations > maxRange) break;
            if (gasleft() < 10000) break;
            
            if (gs.userDailyActivity[user][day] >= minDailyPoints) {
                qualifiedDays++;
                if (qualifiedDays >= 13) break;
            }
        }
        
        if (qualifiedDays >= 13) return 5;
        if (qualifiedDays >= 10) return 4;
        if (qualifiedDays >= 7) return 3;
        if (qualifiedDays >= 4) return 2;
        return 1;
    }

    function _checkActionAvailability(address user, uint8 actionId, uint32 currentDay) 
        internal 
        view 
        returns (bool available, string memory reason) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        // CONDITIONAL: Check user-based cooldowns only during colony events
        if (hs.featureFlags["colonyEvents"] && hs.colonyEventConfig.active) {
            uint256 userCombinedId = PodsUtils.combineIds(1, uint256(uint160(user)));
            uint32 lastAction = hs.actionLogs[userCombinedId][actionId];
            uint256 cooldown = hs.actionTypes[actionId].cooldown;
            
            if (actionId == 5 && hs.colonyEventConfig.cooldownSeconds > 0) {
                cooldown = hs.colonyEventConfig.cooldownSeconds;
            }
            
            if (lastAction > 0 && block.timestamp < lastAction + cooldown) {
                return (false, "Cooldown");
            }
        }
        
        uint256 todayActions = gs.userDailyActivity[user][currentDay];
        
        if (hs.featureFlags["colonyEvents"] && hs.colonyEventConfig.active) {
            if (todayActions >= hs.colonyEventConfig.maxDailyActions) {
                return (false, "Daily limit");
            }
            
            if (currentDay < hs.colonyEventConfig.startDay || currentDay > hs.colonyEventConfig.endDay) {
                return (false, "Event not active");
            }
            
            if (!_hasColonyMembership(user)) {
                return (false, "Need colony");
            }
        } else {
            // Use configurable limits instead of hardcoded values
            ChargeActionType storage _actionType = hs.actionTypes[actionId];
            uint256 currentLimit = _actionType.baseDailyLimit;
            
            // Apply progression bonuses
            if (_actionType.progressionBonus > 0 && _actionType.progressionStep > 0) {
                uint32 userStreak = gs.userEngagement[user].currentStreak;
                uint32 progressionSteps = userStreak / _actionType.progressionStep;
                currentLimit += progressionSteps * _actionType.progressionBonus;

                if (_actionType.maxDailyLimit > 0 && currentLimit > _actionType.maxDailyLimit) {
                    currentLimit = _actionType.maxDailyLimit;
                }
            }
            
            if (currentLimit > 0) {
                uint256 thisActionCount = gs.userActionCounts[user][actionId];
                if (thisActionCount >= currentLimit) {
                    return (false, "Action limit");
                }
            }
            
            if (actionId == 5 && !_hasColonyMembership(user)) {
                return (false, "Need colony");
            }
        }
        
        // Check time control restrictions
        ChargeActionType storage actionType = hs.actionTypes[actionId];
        if (actionType.timeControlEnabled) {
            if (block.timestamp < actionType.startTime) {
                return (false, "Not started");
            }
            if (actionType.endTime > 0 && block.timestamp > actionType.endTime) {
                return (false, "Expired");
            }
        }
        
        return (true, "");
    }

    /**
     * @dev Calculate wait time based on validation failure reason
     */
    function _calculateWaitTime(address user, uint8 actionId, uint32 currentDay) 
        internal 
        view 
        returns (uint256 waitTime) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        if (hs.featureFlags["colonyEvents"] && hs.colonyEventConfig.active) {
            // During colony events: Calculate user-based wait time
            uint256 userCombinedId = PodsUtils.combineIds(1, uint256(uint160(user)));
            uint32 lastAction = hs.actionLogs[userCombinedId][actionId];
            uint256 cooldown = hs.actionTypes[actionId].cooldown;
            
            if (actionId == 5 && hs.colonyEventConfig.cooldownSeconds > 0) {
                cooldown = hs.colonyEventConfig.cooldownSeconds;
            }
            
            if (lastAction > 0 && block.timestamp < lastAction + cooldown) {
                return (lastAction + cooldown) - block.timestamp;
            }
            
            uint256 todayActions = gs.userDailyActivity[user][currentDay];
            if (todayActions >= hs.colonyEventConfig.maxDailyActions) {
                return ((currentDay + 1) * 86400) - block.timestamp;
            }
        } else {
            // During normal gameplay: Check configurable daily limits only
            ChargeActionType storage actionType = hs.actionTypes[actionId];
            uint256 currentLimit = actionType.baseDailyLimit;
            
            if (actionType.progressionBonus > 0 && actionType.progressionStep > 0) {
                uint32 userStreak = gs.userEngagement[user].currentStreak;
                uint32 progressionSteps = userStreak / actionType.progressionStep;
                currentLimit += progressionSteps * actionType.progressionBonus;
                
                if (actionType.maxDailyLimit > 0 && currentLimit > actionType.maxDailyLimit) {
                    currentLimit = actionType.maxDailyLimit;
                }
            }
            
            if (currentLimit > 0) {
                uint256 thisActionCount = gs.userActionCounts[user][actionId];
                if (thisActionCount >= currentLimit) {
                    return ((currentDay + 1) * 86400) - block.timestamp;
                }
            }
        }
        
        return 0;
    }

    function _getEventsStatus(address user, uint32 currentDay) 
        internal 
        view 
        returns (EventStatus memory status) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        status.colonyEventActive = hs.colonyEventConfig.active;
        status.globalEventActive = hs.chargeEventEnd > block.timestamp;
        
        if (status.colonyEventActive) {
            status.colonyTier = _calculateUserTier(user, currentDay);
            status.colonyDaysLeft = currentDay <= hs.colonyEventConfig.endDay ? 
                hs.colonyEventConfig.endDay - currentDay : 0;
        }
        
        if (status.globalEventActive) {
            status.globalBonusPercent = hs.chargeEventBonus;
        }
    }

    function _getGameStatus(address user, uint32 currentDay) 
        internal 
        view 
        returns (GameStatus memory status) 
    {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        // Daily challenges
        DailyChallengeSet storage challenges = gs.dailyChallenges[user];
        if (challenges.dayIssued == currentDay) {
            status.challengesCompleted = challenges.completedCount;
        }
        status.challengeStreak = challenges.challengeStreak;
        
        // Flash event
        FlashParticipation storage flash = gs.flashParticipations[user];
        status.flashEventActive = flash.qualified;
        status.flashEventActions = flash.actionsPerformed;
        
        // Available achievements (simplified count)
        status.availableAchievements = 0; // Would need complex logic to count ready achievements
    }

    function _calculateUserTier(address user, uint32 currentDay) 
        internal 
        view 
        returns (uint8 tier) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        uint8 qualifiedDays = 0;
        
        uint32 eventStart = hs.colonyEventConfig.startDay;
        uint32 eventEnd = hs.colonyEventConfig.endDay;
        
        // Prevent infinite loops
        if (eventStart == 0 || eventEnd == 0 || eventEnd < eventStart) {
            return 1;
        }
        
        // Limit iteration range
        uint32 maxRange = 90;
        if (eventEnd - eventStart > maxRange) {
            eventStart = eventEnd - maxRange;
        }
        
        uint32 iterations = 0;
        for (uint32 day = eventStart; day <= currentDay && day <= eventEnd; day++) {
            iterations++;
            if (iterations > maxRange) break;
            
            if (gs.userDailyActivity[user][day] >= hs.colonyEventConfig.minDailyActions) {
                qualifiedDays++;
                if (qualifiedDays >= 13) break;
            }
        }
        
        if (qualifiedDays >= 13) return 5;
        if (qualifiedDays >= 10) return 4;
        if (qualifiedDays >= 7) return 3;
        if (qualifiedDays >= 4) return 2;
        return 1;
    }

    function _hasColonyMembership(address user) internal view returns (bool) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        return hs.userColonies[user].length > 0;
    }

    function _getActionName(uint8 actionId) internal pure returns (string memory) {
        if (actionId == 1) return "Training";
        if (actionId == 2) return "Maintenance"; 
        if (actionId == 3) return "Exploration";
        if (actionId == 4) return "Research";
        if (actionId == 5) return "Colony Action";
        if (actionId == 6) return "Special Action"; // System-only action
        return "Unknown Action";
    }

    function _estimateTodayRewards(address user, uint32 currentDay) internal view returns (uint256) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        // Estimate based on actions today and average reward per action
        uint256 actionsToday = gs.userDailyActivity[user][currentDay];
        uint256 averageRewardPerAction = 75; // Reasonable estimate
        
        return actionsToday * averageRewardPerAction;
    }

    function _findNextAvailableActionTime(address user) internal view returns (uint256) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Find user's tokens through colonies (simplified)
        bytes32[] storage userColonies = hs.userColonies[user];
        uint256 earliestAvailable = type(uint256).max;
        
        for (uint256 i = 0; i < userColonies.length && i < 5; i++) {
            uint256[] storage colonyMembers = hs.colonies[userColonies[i]];
            
            for (uint256 j = 0; j < colonyMembers.length && j < 3; j++) {
                uint256 combinedId = colonyMembers[j];
                (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);
                
                try this.getNextAvailableAction(collectionId, tokenId) returns (uint256 period, uint8) {
                    uint256 availableAt = block.timestamp + period;
                    if (availableAt < earliestAvailable) {
                        earliestAvailable = availableAt;
                    }
                } catch {
                    continue;
                }
            }
        }
        
        return earliestAvailable == type(uint256).max ? block.timestamp : earliestAvailable;
    }
}