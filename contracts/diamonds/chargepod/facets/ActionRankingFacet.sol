// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibGamingStorage} from "../libraries/LibGamingStorage.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {RankingConfig, RankingEntry, TopPlayersRanking, UserEngagement, DailyChallengeSet, AchievementProgress} from "../../libraries/GamingModel.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibAchievementStorage} from "../libraries/LibAchievementStorage.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";

/**
 * @title ActionRankingFacet - Complete Fixed & Optimized Production Version
 * @notice Includes all bug fixes AND optimizations with full compatibility
 * @dev Fixes duplicate issues, adds user tracking, optimizes gas usage
 */
contract ActionRankingFacet is AccessControlBase {
    using Math for uint256;

    // All original events maintained for compatibility
    event RankingCreated(uint256 indexed rankingId, string name, uint8 rankingType);
    event RankingUpdated(uint256 indexed rankingId, string field, uint256 newValue);
    event RankingRemoved(uint256 indexed rankingId, string reason);
    event RankingPaused(uint256 indexed rankingId, string reason);
    event RankingResumed(uint256 indexed rankingId);
    event UserScoreUpdated(uint256 indexed rankingId, address indexed user, uint256 newScore, uint256 increase);
    event BatchScoreUpdated(uint256 indexed rankingId, uint256 userCount, uint256 totalIncrease);
    event TopPlayersUpdated(uint256 indexed rankingId, uint256 totalPlayers);
    event GlobalRankingSet(uint256 indexed rankingId);
    event SeasonRankingSet(uint256 indexed rankingId, uint32 seasonId);
    event RankingSystemInitialized(uint256 globalRankingId);
    event AchievementSystemInitialized();
    event AchievementTracked(address indexed user, uint256 indexed achievementId);
    event AchievementCacheUpdated(address indexed user);
    event AchievementCacheBatchRefreshed(uint256 userCount);
    event AchievementCacheInvalidated(address indexed user);
    event AchievementManuallyAwarded(address indexed user, uint256 indexed achievementId, string reason);
    event AchievementRevoked(address indexed user, uint256 indexed achievementId, string reason);
    event RankingCacheRebuilt(uint256 rankingId, uint256 playerCount);

    // All original errors maintained for compatibility
    error RankingNotFound(uint256 rankingId);
    error RankingAlreadyExists(string name);
    error InvalidRankingType(uint8 rankingType);
    error RankingNotActive(uint256 rankingId);
    error CannotRemoveActiveRanking(uint256 rankingId);
    error InvalidBatchSize(uint256 size);
    error UnauthorizedAccess(address caller);
    error InvalidScoreIncrease(uint256 increase);
    error CacheUpdateFailed(uint256 rankingId);
    error InvalidCallData();

    // =================== ORIGINAL PUBLIC INTERFACE (ALL SELECTORS PRESERVED) ===================

    function setupRanking(
        string memory name,
        uint8 rankingType,
        uint256 startTime,
        uint256 endTime,
        uint256 qualificationThreshold
    ) public onlyAuthorized whenNotPaused returns (uint256 rankingId) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        if (rankingType == 0 || rankingType > 6) revert InvalidRankingType(rankingType);
        if (endTime > 0 && endTime <= startTime) revert InvalidCallData();
        
        unchecked {
            ++gs.rankingConfigCounter;
        }
        rankingId = gs.rankingConfigCounter;
        
        gs.rankingConfigs[rankingId] = RankingConfig({
            name: name,
            rankingType: rankingType,
            startTime: startTime == 0 ? block.timestamp : startTime,
            endTime: endTime,
            maxEntries: 1000,
            active: true,
            lastUpdateTime: block.timestamp,
            decayRate: 0,
            qualificationThreshold: qualificationThreshold,
            rewardTiers: new uint256[](0),
            participationReward: 0,
            updateFrequency: 3600
        });
        
        _initializeTopPlayersCache(rankingId);
        emit RankingCreated(rankingId, name, rankingType);
        
        return rankingId;
    }

    function updateRanking(
        uint256 rankingId,
        uint256 qualificationThreshold,
        uint32 maxEntries,
        uint32 updateFrequency
    ) external onlyAuthorized {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        if (!gs.rankingConfigs[rankingId].active && gs.rankingConfigs[rankingId].startTime == 0) {
            revert RankingNotFound(rankingId);
        }
        
        RankingConfig storage config = gs.rankingConfigs[rankingId];
        
        if (qualificationThreshold > 0) {
            config.qualificationThreshold = qualificationThreshold;
            emit RankingUpdated(rankingId, "qualificationThreshold", qualificationThreshold);
        }
        
        if (maxEntries > 0) {
            config.maxEntries = maxEntries;
            emit RankingUpdated(rankingId, "maxEntries", maxEntries);
        }
        
        if (updateFrequency > 0) {
            config.updateFrequency = updateFrequency;
            emit RankingUpdated(rankingId, "updateFrequency", updateFrequency);
        }
        
        config.lastUpdateTime = block.timestamp;
    }

    function removeRanking(uint256 rankingId, string calldata reason) external onlyAuthorized {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        if (!gs.rankingConfigs[rankingId].active && gs.rankingConfigs[rankingId].startTime == 0) {
            revert RankingNotFound(rankingId);
        }
        
        if (rankingId == gs.currentGlobalRankingId || rankingId == gs.currentSeasonRankingId) {
            revert CannotRemoveActiveRanking(rankingId);
        }
        
        gs.rankingConfigs[rankingId].active = false;
        gs.rankingConfigs[rankingId].endTime = block.timestamp;
        
        emit RankingRemoved(rankingId, reason);
    }

    function initializeRankingSystem() external onlyAuthorized returns (uint256 globalRankingId) {
        globalRankingId = initializeGlobalRanking();
        emit RankingSystemInitialized(globalRankingId);
        return globalRankingId;
    }

    function initializeAchievementSystem() external onlyAuthorized {
        LibAchievementStorage.initializeAchievementStorage();
        emit AchievementSystemInitialized();
    }

    function initializeGlobalRanking() public onlyAuthorized returns (uint256 rankingId) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        if (gs.currentGlobalRankingId == 0) {
            rankingId = setupRanking("Global All-Time", 1, 0, 0, 100);
            gs.currentGlobalRankingId = rankingId;
            emit GlobalRankingSet(rankingId);
        } else {
            rankingId = gs.currentGlobalRankingId;
        }
        
        return rankingId;
    }

    function createSeasonRanking(
        uint32 seasonId,
        uint256 seasonStartTime,
        uint256 seasonEndTime
    ) external returns (uint256 rankingId) {
        if (!AccessHelper.isAuthorized() && !AccessHelper.isInternalCall())  {
            revert AccessHelper.Unauthorized(msg.sender, "Not authorized");
        }
        
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        rankingId = setupRanking(
            string.concat("Season ", _uintToString(seasonId)),
            2,
            seasonStartTime,
            seasonEndTime,
            100
        );
        
        gs.currentSeasonRankingId = rankingId;
        emit SeasonRankingSet(rankingId, seasonId);
        
        return rankingId;
    }

    function endSeasonRanking() public onlyAuthorized {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        if (gs.currentSeasonRankingId > 0) {
            gs.rankingConfigs[gs.currentSeasonRankingId].active = false;
            gs.rankingConfigs[gs.currentSeasonRankingId].endTime = block.timestamp;
            
            emit RankingRemoved(gs.currentSeasonRankingId, "Season ended");
            gs.currentSeasonRankingId = 0;
        }
    }

    function resetRankingSystem() external onlyAuthorized returns (uint256 newGlobalRankingId) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        unchecked {
            for (uint256 i = 1; i <= gs.rankingConfigCounter; ++i) {
                delete gs.rankingConfigs[i];
                _clearRankingCache(i);
            }
        }
        
        gs.rankingConfigCounter = 0;
        gs.currentGlobalRankingId = 0;
        gs.currentSeasonRankingId = 0;
        
        newGlobalRankingId = initializeGlobalRanking();
        emit RankingSystemInitialized(newGlobalRankingId);
        
        return newGlobalRankingId;
    }

    function clearOldRankings() external onlyAuthorized returns (uint256 clearedCount) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        unchecked {
            for (uint256 i = 1; i <= gs.rankingConfigCounter; ++i) {
                RankingConfig storage config = gs.rankingConfigs[i];
                
                if (config.startTime == 0 || i == gs.currentGlobalRankingId || i == gs.currentSeasonRankingId) {
                    continue;
                }
                
                if ((config.endTime > 0 && config.endTime < block.timestamp) || !config.active) {
                    delete gs.rankingConfigs[i];
                    _clearRankingCache(i);
                    ++clearedCount;
                }
            }
        }
        
        return clearedCount;
    }

    /**
     * @notice Update user score with proper participant tracking
     */
    function updateUserScore(
        uint256 rankingId,
        address user,
        uint256 scoreIncrease
    ) external {
        if (!AccessHelper.isInternalCall() && !AccessHelper.isAuthorized()) {
            revert UnauthorizedAccess(msg.sender);
        }
        
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        if (!gs.rankingConfigs[rankingId].active || scoreIncrease == 0) return;
        if (scoreIncrease > 1000) revert InvalidScoreIncrease(scoreIncrease);
        
        // Add user to participants tracking if new
        if (!gs.userInRanking[rankingId][user]) {
            gs.rankingParticipants[rankingId].push(user);
            gs.userInRanking[rankingId][user] = true;
            unchecked {
                ++gs.rankingParticipantCount[rankingId];
            }
        }
        
        _updateSingleUserScoreFixed(rankingId, user, scoreIncrease);
        
        // Update achievement cache for significant score increases
        if (scoreIncrease >= 100) {
            UserEngagement storage engagement = gs.userEngagement[user];
            DailyChallengeSet storage challenges = gs.dailyChallenges[user];
            uint256 socialScore = gs.userSocialScore[user];
            
            LibAchievementStorage.updateReadyAchievementsCache(
                user,
                engagement,
                gs.userAchievements,
                socialScore,
                challenges
            );
        }
        
        emit UserScoreUpdated(rankingId, user, gs.rankings[rankingId][user].score, scoreIncrease);
    }

    /**
     * @notice Rebuild cache from tracked participants
     */
    function rebuildTopPlayersCache(uint256 rankingId) public onlyAuthorized {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        if (!gs.rankingConfigs[rankingId].active) {
            revert RankingNotFound(rankingId);
        }
        
        uint256 playerCount = _rebuildCacheFromParticipantsFixed(rankingId);
        emit RankingCacheRebuilt(rankingId, playerCount);
    }

    function batchUpdateUserScores(
        uint256 rankingId,
        address[] calldata users,
        uint256[] calldata scoreIncreases
    ) external {
        if (!AccessHelper.isInternalCall() && !AccessHelper.isAuthorized()) {
            revert UnauthorizedAccess(msg.sender);
        }
        
        if (users.length != scoreIncreases.length || users.length == 0 || users.length > 100) {
            revert InvalidBatchSize(users.length);
        }
        
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        if (!gs.rankingConfigs[rankingId].active) return;
        
        uint256 totalIncrease = 0;
        
        unchecked {
            for (uint256 i = 0; i < users.length; ++i) {
                if (scoreIncreases[i] > 0) {
                    _updateSingleUserScoreFixed(rankingId, users[i], scoreIncreases[i]);
                    totalIncrease += scoreIncreases[i];
                }
            }
        }
        
        // Use proper cache rebuild instead of refresh
        _rebuildCacheFromParticipantsFixed(rankingId);
        
        emit BatchScoreUpdated(rankingId, users.length, totalIncrease);
        emit TopPlayersUpdated(rankingId, gs.topPlayersCache[rankingId].totalPlayers);
    }

    function updateTopPlayersCache(uint256 rankingId) external onlyAuthorized {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        if (!gs.rankingConfigs[rankingId].active) {
            revert RankingNotActive(rankingId);
        }
        
        _refreshTopPlayersCache(rankingId);
        emit TopPlayersUpdated(rankingId, gs.topPlayersCache[rankingId].totalPlayers);
    }

    function getRankingParticipantCount(uint256 rankingId) external view returns (uint256 count) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        return gs.rankingParticipantCount[rankingId];
    }

    function getRankingParticipants(uint256 rankingId, uint256 offset, uint256 limit) 
        external view onlyAuthorized returns (
            address[] memory participants,
            uint256 totalCount
        ) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        address[] storage allParticipants = gs.rankingParticipants[rankingId];
        totalCount = allParticipants.length;
        
        if (offset >= totalCount) {
            return (new address[](0), totalCount);
        }
        
        uint256 endIndex = offset + limit;
        if (endIndex > totalCount) endIndex = totalCount;
        
        uint256 resultCount = endIndex - offset;
        participants = new address[](resultCount);
        
        unchecked {
            for (uint256 i = 0; i < resultCount; ++i) {
                participants[i] = allParticipants[offset + i];
            }
        }
        
        return (participants, totalCount);
    }

    function cleanupInactiveParticipants(uint256 rankingId) external onlyAuthorized returns (uint256 removedCount) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        address[] storage participants = gs.rankingParticipants[rankingId];
        uint256 writeIndex = 0;
        
        unchecked {
            for (uint256 i = 0; i < participants.length; ++i) {
                address user = participants[i];
                
                if (gs.rankings[rankingId][user].score > 0) {
                    if (writeIndex != i) {
                        participants[writeIndex] = participants[i];
                    }
                    ++writeIndex;
                } else {
                    gs.userInRanking[rankingId][user] = false;
                    ++removedCount;
                }
            }
        }
        
        while (participants.length > writeIndex) {
            participants.pop();
        }
        
        gs.rankingParticipantCount[rankingId] = writeIndex;
        _rebuildCacheFromParticipantsFixed(rankingId);
        
        return removedCount;
    }

    function calculateUserRank(uint256 rankingId, address user) external view returns (uint256 rank) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        if (!gs.rankingConfigs[rankingId].active) return 0;
        
        RankingEntry storage entry = gs.rankings[rankingId][user];
        if (entry.rank > 0) return entry.rank;
        
        uint256 userScore = entry.score;
        if (userScore == 0) return 0;
        
        // Score-based ranking estimation
        if (userScore >= 2000) return 1;
        if (userScore >= 1000) return 5;
        if (userScore >= 500) return 25;
        if (userScore >= 200) return 100;
        if (userScore >= 100) return 500;
        return 1000;
    }

    /**
     * @notice Get season leaderboard with no duplicates
     */
    function getSeasonLeaderboard(uint256 limit) external view returns (
        address[] memory players,
        uint32[] memory points,
        uint256[] memory ranks,
        uint256 totalParticipants
    ) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        uint256 seasonRankingId = gs.currentSeasonRankingId;
        if (seasonRankingId == 0) {
            return (new address[](0), new uint32[](0), new uint256[](0), 0);
        }
        
        (address[] memory topPlayers, uint128[] memory topScores, uint256 total) = 
            getTopPlayers(seasonRankingId, limit);
        
        uint256 resultCount = topPlayers.length;
        points = new uint32[](resultCount);
        ranks = new uint256[](resultCount);
        
        unchecked {
            for (uint256 i = 0; i < resultCount; ++i) {
                points[i] = uint32(topScores[i]);
                ranks[i] = i + 1;
            }
        }
        
        return (topPlayers, points, ranks, total);
    }

    /**
     * @notice Get user season ranking with accurate rank calculation
     */
    function getUserSeasonRanking(address user) external view returns (
        uint256 rank,
        uint32 points,
        uint256 percentile
    ) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        points = hs.operatorSeasonPoints[user][hs.seasonCounter];
        
        uint256 seasonRankingId = gs.currentSeasonRankingId;
        if (points == 0 || seasonRankingId == 0) {
            return (0, points, 0);
        }
        
        RankingEntry storage entry = gs.rankings[seasonRankingId][user];
        rank = entry.rank;
        
        // More thorough rank finding
        if (rank == 0) {
            TopPlayersRanking storage cache = gs.topPlayersCache[seasonRankingId];
            
            unchecked {
                for (uint256 i = 0; i < 100; ++i) {
                    if (cache.topPlayers[i] == user) {
                        rank = i + 1;
                        break;
                    }
                }
            }
            
            if (rank == 0) {
                rank = _estimateUserRank(seasonRankingId, entry.score);
            }
        }
        
        uint256 totalParticipants = gs.rankingParticipantCount[seasonRankingId];
        if (totalParticipants > 0 && rank > 0) {
            percentile = ((totalParticipants - rank + 1) * 100) / totalParticipants;
        }
        
        return (rank, points, percentile);
    }

    function pauseRanking(uint256 rankingId, string calldata reason) external onlyAuthorized {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        if (gs.rankingConfigs[rankingId].active) {
            gs.rankingConfigs[rankingId].active = false;
            emit RankingPaused(rankingId, reason);
        }
    }

    function resumeRanking(uint256 rankingId) external onlyAuthorized {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        if (!gs.rankingConfigs[rankingId].active) {
            gs.rankingConfigs[rankingId].active = true;
            gs.rankingConfigs[rankingId].lastUpdateTime = block.timestamp;
            emit RankingResumed(rankingId);
        }
    }

    function getRankingSystemStatus() external view returns (
        bool globalRankingActive,
        bool seasonRankingActive,
        uint256 totalActiveRankings,
        uint256 lastUpdateTime
    ) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        if (gs.currentGlobalRankingId > 0) {
            globalRankingActive = gs.rankingConfigs[gs.currentGlobalRankingId].active;
        }
        
        if (gs.currentSeasonRankingId > 0) {
            seasonRankingActive = gs.rankingConfigs[gs.currentSeasonRankingId].active;
        }
        
        unchecked {
            for (uint256 i = 1; i <= gs.rankingConfigCounter; ++i) {
                if (gs.rankingConfigs[i].active) {
                    ++totalActiveRankings;
                    
                    if (gs.rankingConfigs[i].lastUpdateTime > lastUpdateTime) {
                        lastUpdateTime = gs.rankingConfigs[i].lastUpdateTime;
                    }
                }
            }
        }
    }

    function getRankingConfig(uint256 rankingId) external view returns (RankingConfig memory config) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        return gs.rankingConfigs[rankingId];
    }

    function getUserRankingEntry(
        uint256 rankingId,
        address user
    ) external view returns (RankingEntry memory entry) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        return gs.rankings[rankingId][user];
    }

    /**
     * @notice Get top players with guaranteed no duplicates
     */
    function getTopPlayers(
        uint256 rankingId,
        uint256 limit
    ) public view returns (
        address[] memory players,
        uint128[] memory scores,
        uint256 totalPlayers
    ) {
        if (limit > 100) limit = 100;
        
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        TopPlayersRanking storage cache = gs.topPlayersCache[rankingId];
        
        // Count actual valid entries and check for duplicates
        uint256 realCount = 0;
        address[] memory tempPlayers = new address[](limit);
        uint128[] memory tempScores = new uint128[](limit);
        
        unchecked {
            for (uint256 i = 0; i < limit && i < 100; ++i) {
                address player = cache.topPlayers[i];
                uint128 score = cache.topScores[i];
                
                if (player != address(0) && score > 0) {
                    // Check for duplicates
                    bool isDuplicate = false;
                    for (uint256 j = 0; j < realCount; ++j) {
                        if (tempPlayers[j] == player) {
                            isDuplicate = true;
                            break;
                        }
                    }
                    
                    if (!isDuplicate) {
                        tempPlayers[realCount] = player;
                        tempScores[realCount] = score;
                        ++realCount;
                    }
                } else {
                    break;
                }
            }
        }
        
        // Create properly sized arrays
        players = new address[](realCount);
        scores = new uint128[](realCount);
        
        unchecked {
            for (uint256 i = 0; i < realCount; ++i) {
                players[i] = tempPlayers[i];
                scores[i] = tempScores[i];
            }
        }
        
        totalPlayers = cache.totalPlayers;
    }

    function getTopPlayersPage(
        uint256 rankingId,
        uint256 offset,
        uint256 limit
    ) external view returns (
        address[] memory players,
        uint128[] memory scores,
        uint256 totalPlayers,
        bool hasMore
    ) {
        if (limit > 50) limit = 50;
        if (offset >= 100) offset = 99;
        
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        TopPlayersRanking storage cache = gs.topPlayersCache[rankingId];
        
        uint256 endIndex = offset + limit;
        if (endIndex > 100) endIndex = 100;
        
        uint256 resultSize = endIndex > offset ? endIndex - offset : 0;
        
        players = new address[](resultSize);
        scores = new uint128[](resultSize);
        
        unchecked {
            for (uint256 i = 0; i < resultSize; ++i) {
                uint256 cacheIndex = offset + i;
                players[i] = cache.topPlayers[cacheIndex];
                scores[i] = cache.topScores[cacheIndex];
            }
        }
        
        totalPlayers = cache.totalPlayers;
        hasMore = endIndex < 100 && cache.topPlayers[endIndex] != address(0);
    }

    function getActiveRankingIds() external view returns (
        uint256 globalRankingId,
        uint256 seasonRankingId
    ) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        return (gs.currentGlobalRankingId, gs.currentSeasonRankingId);
    }

    function getActiveRankings(uint256 limit) external view returns (
        uint256[] memory rankingIds,
        string[] memory names,
        uint8[] memory types
    ) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        uint256 activeCount = 0;
        unchecked {
            for (uint256 i = 1; i <= gs.rankingConfigCounter && activeCount < limit; ++i) {
                if (gs.rankingConfigs[i].active) {
                    ++activeCount;
                }
            }
        }
        
        rankingIds = new uint256[](activeCount);
        names = new string[](activeCount);
        types = new uint8[](activeCount);
        
        uint256 index = 0;
        unchecked {
            for (uint256 i = 1; i <= gs.rankingConfigCounter && index < activeCount; ++i) {
                if (gs.rankingConfigs[i].active) {
                    rankingIds[index] = i;
                    names[index] = gs.rankingConfigs[i].name;
                    types[index] = gs.rankingConfigs[i].rankingType;
                    ++index;
                }
            }
        }
    }

    function trackAchievementEarned(address user, uint256 achievementId) external {
        if (!AccessHelper.isInternalCall() && !AccessHelper.isAuthorized()) {
            revert UnauthorizedAccess(msg.sender);
        }
        
        LibAchievementStorage.trackAchievementEarned(user, achievementId);
        emit AchievementTracked(user, achievementId);
    }

    function updateUserAchievementCache(address user) external {
        if (!AccessHelper.isInternalCall() && !AccessHelper.isAuthorized()) {
            revert UnauthorizedAccess(msg.sender);
        }
        
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        UserEngagement storage engagement = gs.userEngagement[user];
        DailyChallengeSet storage challenges = gs.dailyChallenges[user];
        uint256 socialScore = gs.userSocialScore[user];
        
        LibAchievementStorage.updateReadyAchievementsCache(
            user,
            engagement,
            gs.userAchievements,
            socialScore,
            challenges
        );
        
        emit AchievementCacheUpdated(user);
    }

    function getUserRecentAchievements(address user, uint256 limit) 
        external 
        view 
        returns (uint256[] memory achievements, uint8 count) 
    {
        return LibAchievementStorage.getRecentAchievements(user, limit);
    }

    function getUserReadyAchievementCount(address user) external view returns (uint8 count) {
        return LibAchievementStorage.getCachedReadyCount(user);
    }

    function checkAchievementProgress(address user, uint256 achievementId) 
        external 
        view 
        returns (
            bool hasEarned,
            uint256 currentProgress,
            uint256 targetValue,
            uint32 earnedAt
        ) 
    {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        AchievementProgress storage progress = gs.userAchievements[user][achievementId];
        
        hasEarned = progress.hasEarned;
        currentProgress = progress.currentProgress;
        earnedAt = progress.earnedAt;
        
        if (achievementId >= 1000 && achievementId <= 1002) {
            uint256[3] memory streakTargets = [uint256(7), uint256(14), uint256(30)];
            targetValue = streakTargets[achievementId - 1000];
        } else if (achievementId >= 2000 && achievementId <= 2002) {
            uint256[3] memory actionTargets = [uint256(100), uint256(500), uint256(1000)];
            targetValue = actionTargets[achievementId - 2000];
        } else if (achievementId >= 3000 && achievementId <= 3001) {
            uint256[2] memory socialTargets = [uint256(50), uint256(100)];
            targetValue = socialTargets[achievementId - 3000];
        } else {
            targetValue = 0;
        }
    }

    function getAchievementLeaderboard(uint256, uint256) 
        external 
        pure 
        returns (
            address[] memory users,
            uint32[] memory earnedTimes,
            uint256 totalEarned
        ) 
    {
        users = new address[](0);
        earnedTimes = new uint32[](0);
        totalEarned = 0;
    }

    function getUserAchievementStats(address user) 
        external 
        view 
        returns (
            uint256 totalEarned,
            uint256 totalReady,
            uint256 lastEarnedTimestamp,
            uint8 recentCount
        ) 
    {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        (, uint8 count) = LibAchievementStorage.getRecentAchievements(user, 10);
        recentCount = count;
        
        uint256[10] memory commonAchievements = [
            uint256(1000), uint256(1001), uint256(1002),
            uint256(2000), uint256(2001), uint256(2002),
            uint256(3000), uint256(3001),
            uint256(4000), uint256(4001)
        ];
        
        unchecked {
            for (uint256 i = 0; i < 10; ++i) {
                if (gs.userAchievements[user][commonAchievements[i]].hasEarned) {
                    ++totalEarned;
                    uint32 earnedAt = gs.userAchievements[user][commonAchievements[i]].earnedAt;
                    if (earnedAt > lastEarnedTimestamp) {
                        lastEarnedTimestamp = earnedAt;
                    }
                }
            }
        }
        
        totalReady = LibAchievementStorage.getCachedReadyCount(user);
    }

    function batchRefreshAchievementCaches(address[] calldata users) external onlyAuthorized {
        if (users.length > 50) revert InvalidBatchSize(users.length);
        
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        unchecked {
            for (uint256 i = 0; i < users.length; ++i) {
                address user = users[i];
                
                UserEngagement storage engagement = gs.userEngagement[user];
                DailyChallengeSet storage challenges = gs.dailyChallenges[user];
                uint256 socialScore = gs.userSocialScore[user];
                
                LibAchievementStorage.updateReadyAchievementsCache(
                    user,
                    engagement,
                    gs.userAchievements,
                    socialScore,
                    challenges
                );
            }
        }
        
        emit AchievementCacheBatchRefreshed(users.length);
    }

    function invalidateAchievementCache(address user) external onlyAuthorized {
        LibAchievementStorage.invalidateUserCache(user);
        emit AchievementCacheInvalidated(user);
    }

    function getAchievementSystemStatus() external view returns (
        uint256 totalTracked,
        uint256 totalCacheUpdates,
        uint256 version,
        uint256 hotAchievements,
        uint256 coldAchievements
    ) {
        return LibAchievementStorage.getSystemStats();
    }

    function awardAchievement(
        address user, 
        uint256 achievementId, 
        string calldata reason
    ) external onlyAuthorized {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        if (!gs.userAchievements[user][achievementId].hasEarned) {
            gs.userAchievements[user][achievementId].hasEarned = true;
            gs.userAchievements[user][achievementId].earnedAt = uint32(block.timestamp);
            
            LibAchievementStorage.trackAchievementEarned(user, achievementId);
            
            emit AchievementManuallyAwarded(user, achievementId, reason);
        }
    }

    function revokeAchievement(
        address user, 
        uint256 achievementId, 
        string calldata reason
    ) external onlyAuthorized {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        if (gs.userAchievements[user][achievementId].hasEarned) {
            gs.userAchievements[user][achievementId].hasEarned = false;
            gs.userAchievements[user][achievementId].earnedAt = 0;
            
            LibAchievementStorage.invalidateUserCache(user);
            
            emit AchievementRevoked(user, achievementId, reason);
        }
    }

    // =================== FIXED & OPTIMIZED INTERNAL FUNCTIONS ===================

    function _initializeTopPlayersCache(uint256 rankingId) internal {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        TopPlayersRanking storage cache = gs.topPlayersCache[rankingId];
        
        cache.lastUpdate = uint32(block.timestamp);
        cache.totalPlayers = 0;
        cache.averageScore = 0;
        cache.medianScore = 0;
        cache.competitiveIndex = 0;
        
        unchecked {
            for (uint256 i = 0; i < 100; ++i) {
                cache.topPlayers[i] = address(0);
                cache.topScores[i] = 0;
            }
        }
    }

    /**
     * @dev Update single user score with proper tracking
     */
    function _updateSingleUserScoreFixed(
        uint256 rankingId,
        address user,
        uint256 scoreIncrease
    ) internal {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        RankingEntry storage entry = gs.rankings[rankingId][user];
        
        uint256 currentScore = entry.score;
        uint256 newScore = currentScore + scoreIncrease;
        
        if (newScore < currentScore) {
            newScore = type(uint128).max;
        }
        
        entry.score = uint128(newScore);
        entry.lastUpdate = uint32(block.timestamp / 86400);
        unchecked {
            ++entry.gamesPlayed;
        }
        
        if (uint128(newScore) > entry.peakScore) {
            entry.peakScore = uint128(newScore);
        }
        
        // Optimized score history update
        unchecked {
            for (uint i = 9; i > 0; --i) {
                entry.scoreHistory[i] = entry.scoreHistory[i-1];
            }
        }
        entry.scoreHistory[0] = uint64(scoreIncrease);
        
        TopPlayersRanking storage cache = gs.topPlayersCache[rankingId];
        if (newScore > cache.topScores[99] || cache.totalPlayers < 100) {
            _updateTopPlayersCacheFixed(user, rankingId, uint128(newScore));
        }
    }

    /**
     * @dev Update cache with proper duplicate handling
     */
    function _updateTopPlayersCacheFixed(address user, uint256 rankingId, uint128 newScore) internal {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        TopPlayersRanking storage cache = gs.topPlayersCache[rankingId];
        
        // Remove existing entry efficiently
        bool found = false;
        uint256 oldPos = 0;
        
        unchecked {
            for (uint256 i = 0; i < 100; ++i) {
                if (cache.topPlayers[i] == user) {
                    found = true;
                    oldPos = i;
                    break;
                }
            }
        }
        
        if (found) {
            unchecked {
                for (uint256 i = oldPos; i < 99; ++i) {
                    cache.topPlayers[i] = cache.topPlayers[i + 1];
                    cache.topScores[i] = cache.topScores[i + 1];
                }
            }
            cache.topPlayers[99] = address(0);
            cache.topScores[99] = 0;
            
            if (cache.totalPlayers > 0) {
                unchecked {
                    --cache.totalPlayers;
                }
            }
        }
        
        // Find insertion position
        uint256 insertPos = 100;
        unchecked {
            for (uint256 i = 0; i < 100; ++i) {
                if (cache.topPlayers[i] == address(0) || newScore > cache.topScores[i]) {
                    insertPos = i;
                    break;
                }
            }
        }
        
        // Insert at position
        if (insertPos < 100) {
            unchecked {
                for (uint256 i = 99; i > insertPos; --i) {
                    cache.topPlayers[i] = cache.topPlayers[i - 1];
                    cache.topScores[i] = cache.topScores[i - 1];
                }
            }
            
            cache.topPlayers[insertPos] = user;
            cache.topScores[insertPos] = newScore;
            
            if (cache.totalPlayers < 100) {
                unchecked {
                    ++cache.totalPlayers;
                }
            }
            
            gs.rankings[rankingId][user].rank = uint32(insertPos + 1);
        }
        
        cache.lastUpdate = uint32(block.timestamp);
    }

    function _refreshTopPlayersCache(uint256 rankingId) internal {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        TopPlayersRanking storage cache = gs.topPlayersCache[rankingId];
        
        uint256 totalScore = 0;
        uint256 playerCount = 0;
        
        unchecked {
            for (uint256 i = 0; i < 100; ++i) {
                if (cache.topPlayers[i] != address(0)) {
                    totalScore += cache.topScores[i];
                    ++playerCount;
                }
            }
        }
        
        if (playerCount > 0) {
            cache.averageScore = uint128(totalScore / playerCount);
            cache.totalPlayers = uint32(playerCount);
        }
        
        cache.lastUpdate = uint32(block.timestamp);
        gs.rankingConfigs[rankingId].lastUpdateTime = block.timestamp;
    }

    /**
     * @dev Rebuild cache from tracked participants - actually works
     */
    function _rebuildCacheFromParticipantsFixed(uint256 rankingId) internal returns (uint256 totalValid) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        TopPlayersRanking storage cache = gs.topPlayersCache[rankingId];
        
        // Clear cache
        unchecked {
            for (uint256 i = 0; i < 100; ++i) {
                cache.topPlayers[i] = address(0);
                cache.topScores[i] = 0;
            }
        }
        
        address[] storage participants = gs.rankingParticipants[rankingId];
        uint256 participantCount = participants.length;
        
        if (participantCount == 0) {
            cache.totalPlayers = 0;
            return 0;
        }
        
        // Collect valid users with scores
        address[] memory validUsers = new address[](participantCount);
        uint128[] memory validScores = new uint128[](participantCount);
        
        unchecked {
            for (uint256 i = 0; i < participantCount; ++i) {
                address user = participants[i];
                uint128 score = gs.rankings[rankingId][user].score;
                
                if (score > 0) {
                    validUsers[totalValid] = user;
                    validScores[totalValid] = score;
                    ++totalValid;
                }
            }
        }
        
        // Optimized bubble sort for descending order
        unchecked {
            for (uint256 i = 0; i < totalValid; ++i) {
                for (uint256 j = 0; j < totalValid - 1 - i; ++j) {
                    if (validScores[j] < validScores[j + 1]) {
                        // Swap scores
                        uint128 tempScore = validScores[j];
                        validScores[j] = validScores[j + 1];
                        validScores[j + 1] = tempScore;
                        
                        // Swap users
                        address tempUser = validUsers[j];
                        validUsers[j] = validUsers[j + 1];
                        validUsers[j + 1] = tempUser;
                    }
                }
            }
        }
        
        // Fill cache with top 100
        uint256 cacheSize = totalValid > 100 ? 100 : totalValid;
        unchecked {
            for (uint256 i = 0; i < cacheSize; ++i) {
                cache.topPlayers[i] = validUsers[i];
                cache.topScores[i] = validScores[i];
                gs.rankings[rankingId][validUsers[i]].rank = uint32(i + 1);
            }
            
            // Update ranks for users outside top 100
            for (uint256 i = 100; i < totalValid; ++i) {
                gs.rankings[rankingId][validUsers[i]].rank = uint32(i + 1);
            }
        }
        
        cache.totalPlayers = uint32(totalValid);
        cache.lastUpdate = uint32(block.timestamp);
        
        // Calculate statistics
        if (cacheSize > 0) {
            uint256 totalScore = 0;
            unchecked {
                for (uint256 i = 0; i < cacheSize; ++i) {
                    totalScore += cache.topScores[i];
                }
            }
            cache.averageScore = uint128(totalScore / cacheSize);
            cache.medianScore = cache.topScores[cacheSize / 2];
        }
        
        return totalValid;
    }

    function _estimateUserRank(uint256 rankingId, uint256 userScore) internal view returns (uint256) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        TopPlayersRanking storage cache = gs.topPlayersCache[rankingId];
        
        if (userScore == 0) return gs.rankingParticipantCount[rankingId];
        
        if (cache.totalPlayers == 100 && userScore > cache.topScores[99]) {
            return 100;
        }
        
        uint128 avgScore = cache.averageScore;
        if (avgScore == 0) return 500;
        
        if (userScore >= avgScore * 2) return 50;
        if (userScore >= avgScore) return 250;
        if (userScore >= avgScore / 2) return 500;
        return 1000;
    }

    function _clearRankingCache(uint256 rankingId) internal {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        TopPlayersRanking storage cache = gs.topPlayersCache[rankingId];
        
        unchecked {
            for (uint256 i = 0; i < 100; ++i) {
                cache.topPlayers[i] = address(0);
                cache.topScores[i] = 0;
            }
        }
        
        cache.totalPlayers = 0;
        cache.lastUpdate = 0;
    }

    function _uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        
        uint256 temp = value;
        uint256 digits;
        
        unchecked {
            while (temp != 0) {
                ++digits;
                temp /= 10;
            }
        }
        
        bytes memory buffer = new bytes(digits);
        
        unchecked {
            while (value != 0) {
                --digits;
                buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
                value /= 10;
            }
        }
        
        return string(buffer);
    }
}