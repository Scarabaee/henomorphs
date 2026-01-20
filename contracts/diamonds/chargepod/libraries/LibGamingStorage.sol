// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27; 

import {UserEngagement, DailyChallengeSet, GlobalGameState, FlashEvent, FlashParticipation, Achievement, AchievementProgress, ScheduledEvent, RankingConfig, RankingEntry, TopPlayersRanking} from "../../../libraries/GamingModel.sol";

/**
 * @title LibGamingStorage - Optimized Gaming Storage System
 * @notice Gaming storage for core gaming features without dead code
 * @dev Provides essential gaming functionality with optimized storage structure
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
library LibGamingStorage {
    bytes32 constant GAMING_STORAGE_POSITION = keccak256("henomorphs.gaming.storage.v2");

    // Gaming-specific errors
    error FeatureNotEnabled(string featureName);
    error InvalidDifficultyTier(uint8 tier);
    error FlashEventNotActive();
    error ChallengeNotCompleted(uint8 challengeIndex);
    error AchievementNotFound(uint256 achievementId);
    error RewardAlreadyClaimed();
    error ActionNotAvailable(uint8 actionId);
    error InvalidRankingConfiguration();
    error RankingNotFound(uint256 rankingId);
    error InsufficientScore(uint256 required, uint256 actual);
    error EventCapacityReached();
    error EventNotStarted();
    error EventEnded();
    error UnauthorizedParticipation();

    /**
     * @notice Gaming storage structure - optimized core gaming features only
     * @dev Contains only actively used gaming functionality
     */
    struct GamingStorage {
        // =================== CORE GAMING FEATURES ===================
        
        // User engagement tracking
        mapping(address => UserEngagement) userEngagement;
        mapping(address => DailyChallengeSet) dailyChallenges;
        GlobalGameState globalGameState;
        
        // Flash events system
        FlashEvent currentFlashEvent;
        mapping(address => FlashParticipation) flashParticipations;
        uint256 flashEventCounter;
        
        // Achievement system
        mapping(uint256 => Achievement) achievements;
        mapping(address => mapping(uint256 => AchievementProgress)) userAchievements;
        uint256 achievementCounter;
        
        // Scheduled events system (core only)
        ScheduledEvent scheduledEvent;
        uint256 lastScheduleCheck;
        
        // Enhanced ranking system
        mapping(uint256 => RankingConfig) rankingConfigs;
        mapping(uint256 => mapping(address => RankingEntry)) rankings;
        mapping(uint256 => TopPlayersRanking) topPlayersCache;
        uint256 rankingConfigCounter;
        uint256 currentGlobalRankingId;
        uint256 currentSeasonRankingId;
        
        // Emergency and surge mode tracking
        uint256 lastEmergencyModeTime;
        uint256 emergencyModeDuration;
        
        // Season reward claims tracking
        mapping(address => mapping(uint32 => bool)) userSeasonRewardsClaimed;
        
        // Basic user activity metrics
        mapping(address => uint256) userLastActivityTime;
        mapping(address => uint32) userTotalSessions;
        mapping(address => uint256) userTotalPlayTime;
        
        // =================== EXTENDED GAMING FEATURES (ACTIVE) ===================
        
        // Advanced user engagement metrics
        mapping(address => mapping(uint32 => uint256)) userDailyActivity; // user => day => activity score
        mapping(address => mapping(uint8 => uint32)) userActionCounts; // user => actionType => count
        mapping(address => uint256) userSkillRatings; // user => skill rating (read-only)
        
        // Enhanced daily challenges
        mapping(address => mapping(uint32 => uint8)) userChallengeStreak; // user => day => streak
        mapping(uint32 => DailyChallengeSet) globalDailyChallenges; // day => global challenges
        
        // Flash event management
        mapping(uint256 => FlashEvent) flashEventHistory; // eventId => event data
        mapping(uint256 => mapping(address => FlashParticipation)) eventParticipations; // eventId => user => participation
        mapping(address => uint256[]) userFlashEventHistory; // user => eventIds participated
        
        // Achievement categories and progression
        mapping(uint8 => uint256[]) achievementsByCategory; // category => achievementIds
        mapping(address => uint256[]) userAchievementHistory; // user => earned achievementIds
        mapping(uint256 => uint256) achievementEarnCount; // achievementId => times earned globally
        
        // Advanced ranking system
        mapping(uint256 => mapping(uint32 => TopPlayersRanking)) historicalRankings; // rankingId => day => snapshot
        mapping(address => mapping(uint256 => uint256[])) userRankingHistory; // user => rankingId => historical ranks
        mapping(uint256 => uint256) rankingTotalRewards; // rankingId => total rewards distributed
        
        // Seasonal competitions
        mapping(uint32 => mapping(uint8 => uint256)) seasonalCompetitions; // seasonId => competitionType => competitionId
        mapping(uint256 => mapping(address => uint256)) competitionScores; // competitionId => user => score
        mapping(uint256 => address[]) competitionParticipants; // competitionId => participants
        
        // =================== OPTIONAL SOCIAL FEATURES ===================
        
        // Social features (used in SeasonFacet if socialFeatures enabled)
        mapping(address => address[]) userFriends;
        mapping(address => mapping(address => bool)) friendRequestsSent;
        mapping(address => uint256) userSocialScore;
        
        // Guild/Team features (used in SeasonFacet if guilds enabled)
        mapping(bytes32 => address[]) guildMembers; // guildId => members
        mapping(address => bytes32) userGuild; // user => guildId
        mapping(bytes32 => uint256) guildTotalScore;
        mapping(bytes32 => string) guildNames;
        
        // =================== PERFORMANCE ANALYTICS ===================
        
        // Performance analytics (used for reward calculations)
        mapping(address => mapping(uint8 => uint256)) userActionEfficiency; // user => actionType => efficiency score
        mapping(address => uint256) userConsistencyScore; // used in ChargeCalculator
        mapping(address => mapping(uint32 => uint256)) userWeeklyPerformance; // user => week => performance score
        
        // =================== REWARD ECONOMICS ===================
        
        // Reward pools and economics
        mapping(string => uint256) rewardPools; // poolType => available amount
        mapping(address => mapping(string => uint256)) userRewardBalances; // user => tokenType => balance
        mapping(string => uint256) globalRewardDistributed; // tokenType => total distributed
        
        // =================== TIME-BASED BONUSES ===================
        
        // Time-based bonuses (used in SeasonFacet)
        mapping(uint32 => uint16) dailyGlobalMultiplier; // day => multiplier
        mapping(uint32 => uint16) weeklyGlobalMultiplier; // week => multiplier
        mapping(address => mapping(uint32 => uint16)) userDailyMultiplier; // user => day => personal multiplier

        mapping(uint256 => address[]) rankingParticipants;
        mapping(uint256 => mapping(address => bool)) userInRanking;
        mapping(uint256 => uint256) rankingParticipantCount;

        mapping(address => mapping(uint32 => uint256)) userDailyActionCount; // user => day => count

        mapping(address => uint32) lastDailyResetDay;              // Track daily resets
        mapping(address => mapping(uint8 => uint256)) userDailyActionCounts;  // Per-action daily counters
        mapping(address => mapping(uint8 => uint256)) userActionProgression;  // Track progression milestones

        uint8 currentSpecializationFocus;        // Currently focused specialization
        uint256 specializationMultiplier;        // Bonus multiplier for focused spec
        uint256 specializationSeasonEnd;         // When specialization season ends
        uint256 crossSpecializationBonus;       // Cross-spec bonus percentage
    }
    
    /**
     * @notice Get gaming storage reference
     * @return gs Gaming storage reference
     */
    function gamingStorage() internal pure returns (GamingStorage storage gs) {
        bytes32 position = GAMING_STORAGE_POSITION;
        assembly {
            gs.slot := position
        }
    }

    /**
     * @notice Update user's skill rating based on performance (ELO-style algorithm)
     * @param user User address
     * @param performanceScore Recent performance score
     * @param difficulty Difficulty level of the activity (1-5)
     * @dev This is a complete ELO implementation but currently not called anywhere
     */
    function updateUserSkillRating(address user, uint256 performanceScore, uint8 difficulty) internal {
        GamingStorage storage gs = gamingStorage();
        
        uint256 currentRating = gs.userSkillRatings[user];
        if (currentRating == 0) currentRating = 1000; // Default rating
        
        // Calculate rating change based on performance and difficulty
        uint256 expectedScore = 1000; // Expected average performance
        int256 ratingChange;
        
        if (performanceScore > expectedScore) {
            // Good performance increases rating
            ratingChange = int256((performanceScore - expectedScore) * difficulty / 2);
        } else {
            // Poor performance decreases rating
            ratingChange = -int256((expectedScore - performanceScore) * difficulty / 3);
        }
        
        // Apply rating change with bounds
        if (ratingChange > 0) {
            gs.userSkillRatings[user] = currentRating + uint256(ratingChange);
        } else if (uint256(-ratingChange) < currentRating) {
            gs.userSkillRatings[user] = currentRating - uint256(-ratingChange);
        } else {
            gs.userSkillRatings[user] = 100; // Minimum rating
        }
        
        // Cap maximum rating
        if (gs.userSkillRatings[user] > 10000) {
            gs.userSkillRatings[user] = 10000;
        }
    }

    /**
     * @notice Get current week number since epoch
     * @return week Current week number
     */
    function getCurrentWeek() internal view returns (uint32 week) {
        return uint32(block.timestamp / (7 * 86400));
    }

    /**
     * @notice Get current day number since epoch
     * @return day Current day number
     */
    function getCurrentDay() internal view returns (uint32 day) {
        return uint32(block.timestamp / 86400);
    }
}