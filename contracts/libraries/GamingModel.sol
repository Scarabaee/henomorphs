// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// =================== CONSTANTS ===================

uint8 constant MAX_DIFFICULTY_LEVEL = 5;
uint8 constant MAX_ACHIEVEMENT_TIER = 5;
uint8 constant MAX_RANKING_TYPE = 6;
uint8 constant MAX_CHALLENGE_TYPE = 6;
uint8 constant DEFAULT_STREAK_MULTIPLIER = 100;
uint16 constant MAX_CONSISTENCY_SCORE = 1000;
uint16 constant MAX_SKILL_RATING = 10000;
uint32 constant SECONDS_PER_DAY = 86400;
uint32 constant SECONDS_PER_WEEK = 604800;

// =================== USER ENGAGEMENT STRUCTURES ===================

/**
 * @notice Comprehensive user engagement tracking
 * @param totalLifetimeActions Total actions performed across all time
 * @param currentStreak Current consecutive daily activity streak
 * @param longestStreak Longest streak ever achieved
 * @param lastActivityDay Last day user was active (in days since epoch)
 * @param streakMultiplier Current streak-based reward multiplier
 * @param lifetimeRewards Total rewards earned across all activities
 * @param favoriteAction Most frequently performed action type
 * @param totalPlayTime Total time spent in activities (estimated)
 * @param achievementsUnlocked Number of achievements unlocked
 * @param seasonalActivity Activity levels for current season
 * @param averageSessionLength Average length of user sessions
 * @param totalSessions Total number of gaming sessions
 */
struct UserEngagement {
    uint256 totalLifetimeActions;
    uint32 currentStreak;
    uint32 longestStreak;
    uint32 lastActivityDay;
    uint128 streakMultiplier;
    uint256 lifetimeRewards;
    uint8 favoriteAction;
    uint32 totalPlayTime;
    uint16 achievementsUnlocked;
    uint32 seasonalActivity;
    uint32 averageSessionLength;
    uint32 totalSessions;
}

// =================== DAILY CHALLENGES SYSTEM ===================

/**
 * @notice Individual daily challenge with comprehensive tracking
 * @param challengeType Type of challenge (1=action count, 2=streak, 3=colony, 4=score, 5=time)
 * @param targetActionId Specific action required (0 = any action)
 * @param targetValue Target value to achieve
 * @param currentProgress Current progress towards target
 * @param rewardAmount Base reward for completing challenge
 * @param bonusMultiplier Bonus multiplier if completed quickly
 * @param timeLimit Time limit for challenge completion (0 = no limit)
 * @param completed Whether challenge is completed
 * @param claimed Whether reward has been claimed
 * @param completedAt Timestamp when challenge was completed
 * @param difficulty Difficulty level of the challenge (1-5)
 * @param personalizedModifier Modifier based on user's play style
 */
struct DailyChallenge {
    uint8 challengeType;
    uint8 targetActionId;
    uint32 targetValue;
    uint32 currentProgress;
    uint256 rewardAmount;
    uint16 bonusMultiplier;
    uint32 timeLimit;
    bool completed;
    bool claimed;
    uint32 completedAt;
    uint8 difficulty;
    uint16 personalizedModifier;
}

/**
 * @notice Daily challenge set for a user with streak tracking
 * @param dayIssued Day when challenges were issued
 * @param challenges Array of 3 daily challenges
 * @param completedCount Number of completed challenges
 * @param bonusReward Bonus reward for completing all challenges
 * @param bonusClaimed Whether bonus reward has been claimed
 * @param difficultyLevel Difficulty level of challenges (1-5)
 * @param streakBonus Additional bonus for consecutive daily completions
 * @param personalizedHints Hints based on user's play style
 * @param challengeStreak Days in a row with at least one challenge completed
 * @param perfectDays Days with all challenges completed
 */
struct DailyChallengeSet {
    uint32 dayIssued;
    DailyChallenge[3] challenges;
    uint8 completedCount;
    uint256 bonusReward;
    bool bonusClaimed;
    uint8 difficultyLevel;
    uint256 streakBonus;
    string personalizedHints;
    uint16 challengeStreak;
    uint16 perfectDays;
}

// =================== GLOBAL GAME STATE ===================

/**
 * @notice Global game state with comprehensive metrics
 * @param currentDay Current day (days since epoch)
 * @param totalDailyActions Total actions performed today globally
 * @param targetDailyActions Target daily actions for surge calculation
 * @param globalMultiplier Global reward multiplier (100 = 1x)
 * @param surgeMode Whether surge mode is active
 * @param emergencyMode Whether emergency mode is active
 * @param lastUpdate Last update timestamp
 * @param playerCount Current active player count
 * @param averageSessionLength Average session length across all players
 * @param dailyNewPlayers New players today
 * @param retentionRate Player retention rate (percentage)
 * @param totalActionsAllTime Total actions performed across all time
 * @param peakConcurrentUsers Peak concurrent users today
 */
struct GlobalGameState {
    uint32 currentDay;
    uint256 totalDailyActions;
    uint256 targetDailyActions;
    uint16 globalMultiplier;
    bool surgeMode;
    bool emergencyMode;
    uint256 lastUpdate;
    uint32 playerCount;
    uint32 averageSessionLength;
    uint32 dailyNewPlayers;
    uint16 retentionRate;
    uint256 totalActionsAllTime;
    uint32 peakConcurrentUsers;
}

// =================== FLASH EVENTS SYSTEM ===================

/**
 * @notice Flash event with comprehensive configuration
 * @param eventName Name of the flash event
 * @param startTime Event start timestamp
 * @param endTime Event end timestamp
 * @param targetActionId Target action for the event (0 = any)
 * @param bonusMultiplier Reward multiplier during event
 * @param maxParticipants Maximum number of participants
 * @param currentParticipants Current number of participants
 * @param totalRewardPool Total reward pool for the event
 * @param active Whether event is currently active
 * @param eventType Type of flash event (1=speed, 2=endurance, 3=skill, 4=social)
 * @param difficultyModifier Difficulty modifier for the event
 * @param specialRequirements Special requirements for participation
 * @param minimumLevel Minimum user level required
 * @param entryFee Entry fee required to participate
 */
struct FlashEvent {
    string eventName;
    uint256 startTime;
    uint256 endTime;
    uint8 targetActionId;
    uint16 bonusMultiplier;
    uint16 maxParticipants;
    uint16 currentParticipants;
    uint256 totalRewardPool;
    bool active;
    uint8 eventType;
    uint16 difficultyModifier;
    uint32 specialRequirements;
    uint8 minimumLevel;
    uint256 entryFee;
}

/**
 * @notice User participation in flash event with detailed tracking
 * @param actionsPerformed Number of actions performed during event
 * @param rewardsEarned Total rewards earned from event
 * @param participationTime When user started participating
 * @param qualified Whether user qualified for rewards
 * @param rewardsClaimed Whether user has claimed rewards
 * @param bestPerformance Best single action performance during event
 * @param consistency Consistency score across all actions
 * @param bonusEligible Whether user is eligible for bonus rewards
 * @param rank Final rank in the event
 * @param percentileRank Percentile rank among participants
 */
struct FlashParticipation {
    uint16 actionsPerformed;
    uint256 rewardsEarned;
    uint32 participationTime;
    bool qualified;
    bool rewardsClaimed;
    uint32 bestPerformance;
    uint16 consistency;
    bool bonusEligible;
    uint16 rank;
    uint8 percentileRank;
}

// =================== ACHIEVEMENTS SYSTEM ===================

/**
 * @notice Achievement definition with comprehensive configuration
 * @param name Achievement name
 * @param description Achievement description
 * @param category Achievement category (1=activity, 2=social, 3=skill, 4=collection, 5=special)
 * @param tier Achievement tier (1=bronze, 2=silver, 3=gold, 4=platinum, 5=legendary)
 * @param targetValue Target value to achieve
 * @param rewardAmount Reward for achieving
 * @param repeatable Whether achievement can be repeated
 * @param cooldownPeriod Cooldown between repeats (if repeatable)
 * @param active Whether achievement is active
 * @param hidden Whether achievement is hidden until unlocked
 * @param prerequisites Array of prerequisite achievement IDs
 * @param seasonalAvailability Season when achievement is available (0 = always)
 * @param difficultyRating Difficulty rating (1-10)
 * @param estimatedTime Estimated time to complete (in hours)
 */
struct Achievement {
    string name;
    string description;
    uint8 category;
    uint8 tier;
    uint256 targetValue;
    uint256 rewardAmount;
    bool repeatable;
    uint256 cooldownPeriod;
    bool active;
    bool hidden;
    uint256[] prerequisites;
    uint32 seasonalAvailability;
    uint8 difficultyRating;
    uint16 estimatedTime;
}

/**
 * @notice User's progress on an achievement with detailed tracking
 * @param currentProgress Current progress towards achievement
 * @param hasEarned Whether user has earned the achievement
 * @param earnedAt Timestamp when achievement was earned
 * @param claimedAt Timestamp when reward was claimed
 * @param claimCount Number of times claimed (for repeatable achievements)
 * @param bestAttempt Best single attempt towards achievement
 * @param firstAttempt Timestamp of first attempt
 * @param progressMilestones Array of milestone timestamps
 * @param timeSpent Total time spent working on this achievement
 * @param attempts Number of attempts made
 */
struct AchievementProgress {
    uint256 currentProgress;
    bool hasEarned;
    uint32 earnedAt;
    uint32 claimedAt;
    uint16 claimCount;
    uint256 bestAttempt;
    uint32 firstAttempt;
    uint32[] progressMilestones;
    uint32 timeSpent;
    uint16 attempts;
}

// =================== RANKING SYSTEM ===================

/**
 * @notice Ranking configuration with comprehensive settings
 * @param name Ranking name
 * @param rankingType Type of ranking (1=global, 2=season, 3=weekly, 4=daily, 5=monthly)
 * @param startTime Ranking period start time
 * @param endTime Ranking period end time (0 = permanent)
 * @param maxEntries Maximum entries to track
 * @param active Whether ranking is active
 * @param lastUpdateTime Last update timestamp
 * @param decayRate Score decay rate (for time-based rankings)
 * @param qualificationThreshold Minimum score to qualify
 * @param rewardTiers Array of reward tiers
 * @param participationReward Reward for participation
 * @param updateFrequency How often rankings are updated (in seconds)
 */
struct RankingConfig {
    string name;
    uint8 rankingType;
    uint256 startTime;
    uint256 endTime;
    uint32 maxEntries;
    bool active;
    uint256 lastUpdateTime;
    uint16 decayRate;
    uint256 qualificationThreshold;
    uint256[] rewardTiers;
    uint256 participationReward;
    uint32 updateFrequency;
}

/**
 * @notice Individual ranking entry with comprehensive tracking
 * @param score Current score
 * @param rank Current rank (1-based)
 * @param lastUpdate Last update day
 * @param peakScore Highest score achieved
 * @param peakRank Best rank achieved
 * @param rewardClaimed Whether ranking reward has been claimed
 * @param gamesPlayed Number of games/actions contributing to score
 * @param winRate Win rate or success rate (percentage)
 * @param averageScore Average score per game
 * @param scoreHistory Array of recent scores for trend analysis
 */
struct RankingEntry {
    uint128 score;
    uint32 rank;
    uint32 lastUpdate;
    uint128 peakScore;
    uint32 peakRank;
    bool rewardClaimed;
    uint32 gamesPlayed;
    uint16 winRate;
    uint64 averageScore;
    uint64[10] scoreHistory; // Last 10 scores for trend analysis
}

/**
 * @notice Top players ranking cache with comprehensive data
 * @param topPlayers Array of top 100 player addresses
 * @param topScores Array of corresponding scores
 * @param lastUpdate Last cache update timestamp
 * @param totalPlayers Total number of players in ranking
 * @param averageScore Average score across all players
 * @param medianScore Median score across all players
 * @param scoreDistribution Score distribution buckets for analytics
 * @param competitiveIndex Index of how competitive the ranking is
 */
struct TopPlayersRanking {
    address[100] topPlayers;
    uint128[100] topScores;
    uint32 lastUpdate;
    uint32 totalPlayers;
    uint128 averageScore;
    uint128 medianScore;
    uint32[10] scoreDistribution; // 10 buckets for score distribution
    uint16 competitiveIndex; // How competitive the ranking is (0-1000)
}

// =================== SCHEDULED EVENTS ===================

/**
 * @notice Scheduled event with comprehensive configuration
 * @param startTime When event should start
 * @param duration Event duration in seconds
 * @param bonusPercentage Bonus percentage for the event
 * @param scheduled Whether event is scheduled
 * @param eventType Type of scheduled event (1=seasonal, 2=flash, 3=maintenance, 4=special)
 * @param requirements Special requirements for participation
 * @param maxParticipants Maximum participants (0 = unlimited)
 * @param rewardPool Total reward pool for event
 * @param recurringInterval How often event repeats (0 = one-time)
 * @param autoStart Whether event starts automatically
 * @param notificationSent Whether participants have been notified
 * @param preparationTime Time before event for preparation/notification
 */
struct ScheduledEvent {
    uint256 startTime;
    uint256 duration;
    uint8 bonusPercentage;
    bool scheduled;
    uint8 eventType;
    uint32 requirements;
    uint32 maxParticipants;
    uint256 rewardPool;
    uint256 recurringInterval;
    bool autoStart;
    bool notificationSent;
    uint256 preparationTime;
}

// =================== SOCIAL AND TEAM FEATURES ===================

/**
 * @notice Team/Guild information
 * @param name Team name
 * @param leader Team leader address
 * @param members Array of member addresses
 * @param totalScore Combined team score
 * @param averageLevel Average level of team members
 * @param createdAt When team was created
 * @param maxMembers Maximum team size
 * @param inviteOnly Whether team is invite-only
 * @param teamType Type of team (1=casual, 2=competitive, 3=educational)
 */
struct TeamInfo {
    string name;
    address leader;
    address[] members;
    uint256 totalScore;
    uint8 averageLevel;
    uint32 createdAt;
    uint8 maxMembers;
    bool inviteOnly;
    uint8 teamType;
}

/**
 * @notice Social connection between users
 * @param friendAddress Address of the friend
 * @param connectionType Type of connection (1=friend, 2=rival, 3=mentor, 4=student)
 * @param connectedAt When connection was established
 * @param interactionCount Number of interactions
 * @param lastInteraction Last interaction timestamp
 * @param mutualConnection Whether connection is mutual
 */
struct SocialConnection {
    address friendAddress;
    uint8 connectionType;
    uint32 connectedAt;
    uint32 interactionCount;
    uint32 lastInteraction;
    bool mutualConnection;
}

// =================== PERFORMANCE ANALYTICS ===================

/**
 * @notice User performance analytics
 * @param skillRating Overall skill rating (ELO-style)
 * @param consistencyScore How consistent user's performance is
 * @param improvementRate Rate of improvement over time
 * @param peakPerformanceTime When user performs best
 * @param strongestAction Action type user performs best at
 * @param weakestAction Action type user struggles with
 * @param learningCurve How quickly user learns and improves
 * @param adaptabilityScore How well user adapts to new challenges
 */
struct PerformanceAnalytics {
    uint256 skillRating;
    uint16 consistencyScore;
    uint16 improvementRate;
    uint8 peakPerformanceTime; // Hour of day (0-23)
    uint8 strongestAction;
    uint8 weakestAction;
    uint16 learningCurve;
    uint16 adaptabilityScore;
}

// =================== REWARD ECONOMICS ===================

/**
 * @notice Reward pool configuration
 * @param poolName Name of the reward pool
 * @param totalAllocated Total amount allocated to pool
 * @param currentBalance Current balance in pool
 * @param distributionRate Rate at which rewards are distributed
 * @param replenishmentRate Rate at which pool is replenished
 * @param minimumBalance Minimum balance to maintain
 * @param poolType Type of pool (1=daily, 2=weekly, 3=seasonal, 4=special)
 * @param autoReplenish Whether pool auto-replenishes
 */
struct RewardPool {
    string poolName;
    uint256 totalAllocated;
    uint256 currentBalance;
    uint256 distributionRate;
    uint256 replenishmentRate;
    uint256 minimumBalance;
    uint8 poolType;
    bool autoReplenish;
}

// =================== ENUMS FOR TYPE SAFETY ===================

/**
 * @notice Challenge types enumeration
 */
enum ChallengeType {
    ACTION_COUNT,    // 0 - Perform X actions
    STREAK,          // 1 - Maintain X day streak
    COLONY,          // 2 - Colony-related challenge
    SCORE,           // 3 - Achieve X score
    TIME,            // 4 - Complete within time limit
    SOCIAL,          // 5 - Social interaction challenge
    SKILL            // 6 - Skill-based challenge
}

/**
 * @notice Achievement categories enumeration
 */
enum AchievementCategory {
    ACTIVITY,        // 0 - Activity-based achievements
    SOCIAL,          // 1 - Social achievements
    SKILL,           // 2 - Skill-based achievements
    COLLECTION,      // 3 - Collection achievements
    SPECIAL,         // 4 - Special event achievements
    PROGRESSION,     // 5 - Long-term progression achievements
    DISCOVERY        // 6 - Discovery and exploration achievements
}

/**
 * @notice Event types enumeration
 */
enum EventType {
    SEASONAL,        // 0 - Seasonal events
    FLASH,           // 1 - Flash events
    MAINTENANCE,     // 2 - Maintenance events
    SPECIAL,         // 3 - Special commemorative events
    COMMUNITY,       // 4 - Community-driven events
    COMPETITIVE,     // 5 - Competitive tournaments
    EDUCATIONAL      // 6 - Educational events
}

/**
 * @notice Ranking types enumeration
 */
enum RankingType {
    GLOBAL,          // 0 - Global all-time ranking
    SEASONAL,        // 1 - Season-based ranking
    WEEKLY,          // 2 - Weekly ranking
    DAILY,           // 3 - Daily ranking
    MONTHLY,         // 4 - Monthly ranking
    SPECIALIZED,     // 5 - Specialized skill ranking
    TEAM             // 6 - Team-based ranking
}
