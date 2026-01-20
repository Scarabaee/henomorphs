// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AchievementProgress, DailyChallengeSet, UserEngagement} from "../../../libraries/GamingModel.sol";

/**
 * @title LibAchievementStorage - SAFE Event-Based Achievement Tracking
 * @notice Dedicated storage library that WON'T conflict with existing storage
 * @dev Uses separate storage slot to avoid any conflicts with LibGamingStorage
 * @author rutilicus.eth (ArchXS)
 */
library LibAchievementStorage {
    // DEDICATED storage position - completely separate from other storage
    bytes32 constant ACHIEVEMENT_STORAGE_POSITION = keccak256("henomorphs.achievement.storage");

    /**
     * @notice Event-based achievement tracking storage
     * @dev Completely isolated from existing storage to prevent conflicts
     */
    struct AchievementStorage {
        // =================== EVENT-BASED TRACKING ===================
        
        // Achievement history (chronological order)
        mapping(address => uint256[]) userAchievementHistory;
        mapping(address => uint256) userAchievementCount;
        
        // Ready achievements cache (for quick UI display)
        mapping(address => uint256[]) userReadyAchievements;
        mapping(address => uint8) cachedReadyCount;
        
        // Cache management
        mapping(address => uint256) cacheLastUpdate;
        mapping(address => bool) cacheValid;
        uint256 cacheLifetime; // Default: 1 hour
        
        // Milestone tracking for performance optimization
        mapping(address => uint256) lastStreakMilestone;
        mapping(address => uint256) lastActionMilestone;
        mapping(address => uint256) lastSocialMilestone;
        mapping(address => uint256) lastChallengeMilestone;
        
        // System stats
        uint256 totalAchievementsTracked;
        uint256 totalCacheUpdates;
        uint256 systemVersion;
        
        // =================== ACHIEVEMENT DEFINITIONS ===================
        
        // Achievement metadata for efficient checking
        mapping(uint256 => AchievementMeta) achievementMeta;
        uint256[] allAchievementIds;
        
        // Category-based achievement grouping
        mapping(uint8 => uint256[]) achievementsByCategory;
        
        // =================== PERFORMANCE OPTIMIZATION ===================
        
        // Batch processing data
        mapping(address => uint256) lastBatchCheck;
        mapping(uint256 => uint256) achievementEarnedCount;
        
        // Hot/cold achievement separation (frequently vs rarely earned)
        uint256[] hotAchievements;    // Check these first
        uint256[] coldAchievements;   // Check these less frequently
    }

    /**
     * @notice Achievement metadata for efficient processing
     */
    struct AchievementMeta {
        uint8 category;        // 1=streak, 2=action, 3=social, 4=challenge, 5=special
        uint256 threshold;     // Required value to earn
        uint16 checkFrequency; // How often to check (in seconds)
        bool isActive;         // Whether achievement is active
        uint256 lastGlobalCheck; // Last time this achievement was checked globally
    }

    /**
     * @notice Get achievement storage reference
     */
    function achievementStorage() internal pure returns (AchievementStorage storage hhas) {
        bytes32 position = ACHIEVEMENT_STORAGE_POSITION;
        assembly {
            hhas.slot := position
        }
    }

    /**
     * @notice Initialize achievement storage system
     */
    function initializeAchievementStorage() internal {
        AchievementStorage storage has = achievementStorage();
        
        if (has.systemVersion == 0) {
            has.cacheLifetime = 3600; // 1 hour
            has.systemVersion = 1;
            
            // Initialize hot achievements (commonly earned)
            has.hotAchievements.push(1000); // 7-day streak
            has.hotAchievements.push(2000); // 100 actions
            has.hotAchievements.push(1001); // 14-day streak
            has.hotAchievements.push(2001); // 500 actions
            
            // Initialize cold achievements (rarely earned)
            has.coldAchievements.push(1002); // 30-day streak
            has.coldAchievements.push(2002); // 1000 actions
            has.coldAchievements.push(3000); // Social milestones
            has.coldAchievements.push(4000); // Challenge milestones
            
            // Set achievement metadata
            _initializeAchievementMetadata();
        }
    }

    /**
     * @notice Track achievement earned event
     */
    function trackAchievementEarned(address user, uint256 achievementId) internal {
        AchievementStorage storage has = achievementStorage();
        
        // Add to user's history
        has.userAchievementHistory[user].push(achievementId);
        has.userAchievementCount[user]++;
        
        // Update milestone tracking
        _updateMilestoneTracking(user, achievementId, has);
        
        // Invalidate cache
        has.cacheValid[user] = false;
        
        // Update global stats
        has.totalAchievementsTracked++;
        has.achievementEarnedCount[achievementId]++;
    }

    /**
     * @notice Get recent achievements (optimized)
     */
    function getRecentAchievements(address user, uint256 limit) 
        internal 
        view 
        returns (uint256[] memory recentAchievements, uint8 actualCount) 
    {
        AchievementStorage storage has = achievementStorage();
        uint256[] storage history = has.userAchievementHistory[user];
        
        if (history.length == 0) {
            return (new uint256[](0), 0);
        }
        
        // Get recent achievements (last N, up to limit)
        uint256 startIndex = history.length > limit ? history.length - limit : 0;
        actualCount = uint8(history.length - startIndex);
        
        recentAchievements = new uint256[](actualCount);
        
        // Fill array in reverse order (most recent first)
        for (uint256 i = 0; i < actualCount; i++) {
            recentAchievements[i] = history[history.length - 1 - i];
        }
    }

    /**
     * @notice Update ready achievements cache (optimized)
     */
    function updateReadyAchievementsCache(
        address user,
        UserEngagement storage engagement,
        mapping(address => mapping(uint256 => AchievementProgress)) storage userAchievements,
        uint256 socialScore,
        DailyChallengeSet storage challenges
    ) internal {
        AchievementStorage storage has = achievementStorage();
        
        // Check if cache update needed
        if (has.cacheValid[user] && 
            block.timestamp - has.cacheLastUpdate[user] < has.cacheLifetime) {
            return;
        }
        
        // Clear current ready achievements
        delete has.userReadyAchievements[user];
        uint8 readyCount = 0;
        
        // Check hot achievements first (most commonly earned)
        readyCount += _checkHotAchievements(user, engagement, userAchievements, has);
        
        // Check cold achievements less frequently
        if (block.timestamp - has.lastBatchCheck[user] > 3600) { // Every hour
            readyCount += _checkColdAchievements(user, engagement, userAchievements, socialScore, challenges, has);
            has.lastBatchCheck[user] = block.timestamp;
        }
        
        // Update cache
        has.cachedReadyCount[user] = readyCount;
        has.cacheLastUpdate[user] = block.timestamp;
        has.cacheValid[user] = true;
        has.totalCacheUpdates++;
    }

    /**
     * @notice Get cached ready achievement count
     */
    function getCachedReadyCount(address user) internal view returns (uint8) {
        AchievementStorage storage has = achievementStorage();
        
        if (has.cacheValid[user] && 
            block.timestamp - has.cacheLastUpdate[user] < has.cacheLifetime) {
            return has.cachedReadyCount[user];
        }
        
        // Return conservative estimate if cache is stale
        return 0;
    }

    /**
     * @notice Emergency cache refresh
     */
    function invalidateUserCache(address user) internal {
        AchievementStorage storage has = achievementStorage();
        has.cacheValid[user] = false;
    }

    /**
     * @notice Get system stats
     */
    function getSystemStats() internal view returns (
        uint256 totalTracked,
        uint256 totalCacheUpdates,
        uint256 version,
        uint256 hotAchievementCount,
        uint256 coldAchievementCount
    ) {
        AchievementStorage storage has = achievementStorage();
        return (
            has.totalAchievementsTracked,
            has.totalCacheUpdates,
            has.systemVersion,
            has.hotAchievements.length,
            has.coldAchievements.length
        );
    }

    // =================== INTERNAL HELPER FUNCTIONS ===================

    function _initializeAchievementMetadata() internal {
        AchievementStorage storage has = achievementStorage();
        
        // Streak achievements
        has.achievementMeta[1000] = AchievementMeta(1, 7, 300, true, 0);      // 7-day streak
        has.achievementMeta[1001] = AchievementMeta(1, 14, 300, true, 0);     // 14-day streak  
        has.achievementMeta[1002] = AchievementMeta(1, 30, 1800, true, 0);    // 30-day streak
        
        // Action achievements
        has.achievementMeta[2000] = AchievementMeta(2, 100, 600, true, 0);    // 100 actions
        has.achievementMeta[2001] = AchievementMeta(2, 500, 1800, true, 0);   // 500 actions
        has.achievementMeta[2002] = AchievementMeta(2, 1000, 3600, true, 0);  // 1000 actions
        
        // Social achievements
        has.achievementMeta[3000] = AchievementMeta(3, 50, 1800, true, 0);    // Social score 50
        has.achievementMeta[3001] = AchievementMeta(3, 100, 3600, true, 0);   // Social score 100
        
        // Challenge achievements
        has.achievementMeta[4000] = AchievementMeta(4, 7, 1800, true, 0);     // 7-day challenge streak
        has.achievementMeta[4001] = AchievementMeta(4, 3, 1800, true, 0);     // 3 perfect days
    }

    function _updateMilestoneTracking(address user, uint256 achievementId, AchievementStorage storage has) internal {
        if (achievementId >= 1000 && achievementId <= 1002) {
            has.lastStreakMilestone[user] = achievementId;
        } else if (achievementId >= 2000 && achievementId <= 2002) {
            has.lastActionMilestone[user] = achievementId;
        } else if (achievementId >= 3000 && achievementId <= 3001) {
            has.lastSocialMilestone[user] = achievementId;
        } else if (achievementId >= 4000 && achievementId <= 4001) {
            has.lastChallengeMilestone[user] = achievementId;
        }
    }

    function _checkHotAchievements(
        address user,
        UserEngagement storage engagement,
        mapping(address => mapping(uint256 => AchievementProgress)) storage userAchievements,
        AchievementStorage storage has
    ) internal returns (uint8 count) {
        count = 0;
        
        // Check streak achievements (hot)
        if (engagement.currentStreak >= 7 && !userAchievements[user][1000].hasEarned) {
            has.userReadyAchievements[user].push(1000);
            count++;
        }
        if (engagement.currentStreak >= 14 && !userAchievements[user][1001].hasEarned) {
            has.userReadyAchievements[user].push(1001);
            count++;
        }
        
        // Check action achievements (hot)
        if (engagement.totalLifetimeActions >= 100 && !userAchievements[user][2000].hasEarned) {
            has.userReadyAchievements[user].push(2000);
            count++;
        }
        if (engagement.totalLifetimeActions >= 500 && !userAchievements[user][2001].hasEarned) {
            has.userReadyAchievements[user].push(2001);
            count++;
        }
        
        return count;
    }

    function _checkColdAchievements(
        address user,
        UserEngagement storage engagement,
        mapping(address => mapping(uint256 => AchievementProgress)) storage userAchievements,
        uint256 socialScore,
        DailyChallengeSet storage challenges,
        AchievementStorage storage has
    ) internal returns (uint8 count) {
        count = 0;
        
        // Check rare streak achievements
        if (engagement.currentStreak >= 30 && !userAchievements[user][1002].hasEarned) {
            has.userReadyAchievements[user].push(1002);
            count++;
        }
        
        // Check rare action achievements
        if (engagement.totalLifetimeActions >= 1000 && !userAchievements[user][2002].hasEarned) {
            has.userReadyAchievements[user].push(2002);
            count++;
        }
        
        // Check social achievements
        if (socialScore >= 50 && !userAchievements[user][3000].hasEarned) {
            has.userReadyAchievements[user].push(3000);
            count++;
        }
        if (socialScore >= 100 && !userAchievements[user][3001].hasEarned) {
            has.userReadyAchievements[user].push(3001);
            count++;
        }
        
        // Check challenge achievements
        if (challenges.challengeStreak >= 7 && !userAchievements[user][4000].hasEarned) {
            has.userReadyAchievements[user].push(4000);
            count++;
        }
        if (challenges.perfectDays >= 3 && !userAchievements[user][4001].hasEarned) {
            has.userReadyAchievements[user].push(4001);
            count++;
        }
        
        return count;
    }
}