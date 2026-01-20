// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";

/**
 * @title ColonyWarsStatsFacet
 * @notice Statistics and rankings for Colony Wars - unique selectors, complete stats
 */
contract ColonyWarsStatsFacet is AccessControlBase {
    struct ColonyRewardStats {
        bytes32 colonyId;
        address ownerAddress;
        uint256 totalEarnedThisSeason;
        uint256 totalEarnedAllTime;
        uint256 pendingSeasonPrize; // Estimated based on current ranking
        uint256 lastBattleReward;
        uint256 lastSiegeReward;
        uint256 lastRaidBonus;
        uint256 battleRewardsTotal;
        uint256 siegeRewardsTotal;
        uint256 raidBonusesTotal;
        uint256 seasonWinningsCount; // How many seasons won
        bool eligibleForCurrentPrize;
    }

    struct SeasonPrizeInfo {
        uint32 seasonId;
        uint256 totalPrizePool;
        bytes32 currentLeader;
        address currentLeaderAddress;
        uint256 leaderScore;
        uint256 estimatedWinnerPrize; // Current prize pool estimate
        uint32 timeToSeasonEnd;
        bool seasonActive;
        bool prizeAwarded;
        bytes32 actualWinner; // If season ended
        uint256 actualPrizeAmount; // If season ended
    }

    struct GlobalRewardStats {
        uint256 totalRewardsDistributed;
        uint256 currentSeasonPrizePool;
        uint256 averageSeasonPrize;
        uint256 largestSeasonPrize;
        uint256 totalBattleRewards;
        uint256 totalSiegeRewards;
        uint256 totalRaidBonuses;
        uint256 totalSeasonPrizes;
        uint32 seasonsCompleted;
    }

    struct ColonyWarStats {
        bytes32 colonyId;
        address ownerAddress;
        uint256 currentSeasonScore;
        uint256 defensiveStake;
        uint256 territoriesControlled;
        uint256 totalTerritoryBonus;
        bool isRegistered;
        bool inAlliance;
        bytes32 allianceId;
        // Complete battle/siege/raid stats
        uint256 colonyBattlesWon;
        uint256 colonyBattlesLost;
        uint256 colonyBattlesTotal;
        uint256 territorySiegesWon;
        uint256 territorySiegesLost;
        uint256 territorySiegesTotal;
        uint256 territoryRaidsSuccess;
        uint256 territoryRaidsFailed;
        uint256 territoryRaidsTotal;
        uint256 totalVictories; // All wins combined
        uint256 totalActions;   // All actions combined
        uint8 warStress;
         uint256 totalEarnedThisSeason;
        uint256 totalEarnedAllTime;
        uint256 estimatedSeasonPrize; // Based on current rank
        uint256 lastRewardAmount;
        uint32 lastRewardTime;
        string lastRewardType; // "BATTLE", "SIEGE", "RAID", "SEASON"
    }

    struct SeasonWarRanking {
        bytes32 colonyId;
        address ownerAddress;
        uint256 score;
        uint256 rank;
        uint256 territoriesCount;
        uint256 totalVictories;
        uint256 totalActions;
        bool inAlliance;
        uint256 estimatedPrize; // What they would win if season ended now
        uint256 earnedThisSeason;
    }

    struct WarSystemStats {
        uint32 currentSeason;
        uint256 totalRegisteredColonies;
        uint256 totalActiveBattles;
        uint256 totalActiveSieges;
        uint256 totalActiveAlliances;
        uint256 totalControlledTerritories;
        uint256 currentSeasonPrizePool;
        uint32 timeToSeasonEnd;
        uint256 totalCompletedBattles;
        uint256 totalCompletedSieges;
    }

    struct WarLeaderEntry {
        bytes32 colonyId;
        address ownerAddress;
        uint256 score;
        uint256 territoriesCount;
        uint256 totalVictories;
        uint256 totalActions;
        uint256 winRate; // Percentage (0-100)
    }
 
    struct SeasonStats {
        uint256 registeredColonies;
        uint256 totalBattles;
        uint256 resolvedBattles;
        uint256 activeAlliances;
        uint256 controlledTerritories;
        uint256 prizePool;
        bool seasonActive;
        uint32 currentTime;
    }

    struct SeasonBattleInfo {
        bytes32 battleId;
        bytes32 attackerColony;
        bytes32 defenderColony;
        uint256 stakeAmount;
        uint256 prizePool;
        uint8 battleState;
        uint32 battleStartTime;
        uint32 battleEndTime;
        bytes32 winner;
        bool resolved;
    }
  
    struct ColonyBattleInfo {
        bytes32 battleId;
        bool wasAttacker;
        bytes32 opponent;
        uint256 stakeAmount;
        bool won;
        uint32 battleStartTime;
        bool resolved;
    }

    /**
     * @notice Calculate proportional season prize for colony based on performance
     * @param colonyId Colony to calculate prize for
     * @param seasonId Season to check (0 = current)
     * @param topCount Number of top colonies eligible for prizes (default 10)
     * @return estimatedPrize Proportional prize based on score
     * @return rank Colony's current rank
     * @return isEligible Whether colony is in prize-winning range
     */
    function calculateTopSeasonPrize(
        bytes32 colonyId,
        uint32 seasonId,
        uint256 topCount
    ) public view returns (uint256 estimatedPrize, uint256 rank, bool isEligible) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        if (seasonId == 0) {
            seasonId = cws.currentSeason;
        }
        if (topCount == 0) {
            topCount = 10; // Default top 10
        }

        LibColonyWarsStorage.Season storage season = cws.seasons[seasonId];
        uint256 totalPrize = season.prizePool;

        if (totalPrize == 0) {
            return (0, 0, false);
        }

        // Get colony's rank and score
        (uint256 colonyRank, uint256 colonyScore, uint256 totalParticipants) = getColonyCombatRank(colonyId);
        rank = colonyRank;

        if (rank == 0 || rank > topCount || colonyScore == 0) {
            return (0, rank, false);
        }

        // Calculate total score of top performers
        uint256 topTotalScore = 0;
        uint256 eligibleCount = totalParticipants > topCount ? topCount : totalParticipants;

        // Get top colonies and their scores
        for (uint256 i = 0; i < season.registeredColonies.length; i++) {
            bytes32 colony = season.registeredColonies[i];
            uint256 score = LibColonyWarsStorage.getColonyScore(seasonId, colony);

            if (score > 0) {
                // Check if this colony is in top N
                uint256 betterCount = 0;
                for (uint256 j = 0; j < season.registeredColonies.length; j++) {
                    bytes32 otherColony = season.registeredColonies[j];
                    if (otherColony != colony) {
                        uint256 otherScore = LibColonyWarsStorage.getColonyScore(seasonId, otherColony);
                        if (otherScore > score) {
                            betterCount++;
                        }
                    }
                }

                uint256 thisColonyRank = betterCount + 1;
                if (thisColonyRank <= eligibleCount) {
                    topTotalScore += score;
                }
            }
        }

        if (topTotalScore == 0) {
            return (0, rank, false);
        }

        // Calculate proportional prize
        estimatedPrize = (colonyScore * totalPrize) / topTotalScore;
        isEligible = true;

        return (estimatedPrize, rank, isEligible);
    }
        
    /**
     * @notice Get season leaderboard with scores and positions
     * @param seasonId Season to get ranking for
     * @param limit Maximum colonies to return (gas optimization)
     * @return colonies Array of colony IDs sorted by score
     * @return scores Array of scores corresponding to colonies
     * @return positions Array of positions (1st, 2nd, etc.)
     */
    function getWarsSeasonRanking(uint32 seasonId, uint256 limit) 
        external 
        view 
        returns (
            bytes32[] memory colonies, 
            uint256[] memory scores,
            uint256[] memory positions
        ) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Season storage season = cws.seasons[seasonId];
        
        uint256 totalColonies = season.registeredColonies.length;
        if (totalColonies == 0) {
            return (new bytes32[](0), new uint256[](0), new uint256[](0));
        }
        
        // Limit to prevent gas issues
        uint256 resultSize = totalColonies > limit ? limit : totalColonies;
        
        // Create arrays for sorting
        bytes32[] memory tempColonies = new bytes32[](totalColonies);
        uint256[] memory tempScores = new uint256[](totalColonies);
        
        // Populate arrays
        for (uint256 i = 0; i < totalColonies; i++) {
            bytes32 colony = season.registeredColonies[i];
            tempColonies[i] = colony;
            tempScores[i] = LibColonyWarsStorage.getColonyScore(seasonId, colony);
        }
        
        // Simple bubble sort (for small arrays)
        for (uint256 i = 0; i < totalColonies - 1; i++) {
            for (uint256 j = 0; j < totalColonies - i - 1; j++) {
                if (tempScores[j] < tempScores[j + 1]) {
                    // Swap scores
                    uint256 tempScore = tempScores[j];
                    tempScores[j] = tempScores[j + 1];
                    tempScores[j + 1] = tempScore;
                    
                    // Swap colonies
                    bytes32 tempColony = tempColonies[j];
                    tempColonies[j] = tempColonies[j + 1];
                    tempColonies[j + 1] = tempColony;
                }
            }
        }
        
        // Return top results
        colonies = new bytes32[](resultSize);
        scores = new uint256[](resultSize);
        positions = new uint256[](resultSize);
        
        for (uint256 i = 0; i < resultSize; i++) {
            colonies[i] = tempColonies[i];
            scores[i] = tempScores[i];
            positions[i] = i + 1; // 1st, 2nd, 3rd, etc.
        }
        
        return (colonies, scores, positions);
    }

    /**
     * @notice Get registration count for current season
     * @return count Number of registered colonies
     * @return prizePool Current accumulated prize pool
     */
    function getCurrentWarsSeasonStats() 
        external 
        view 
        returns (uint256 count, uint256 prizePool) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
        
        return (season.registeredColonies.length, season.prizePool);
    }

    /**
     * @notice Get comprehensive season statistics
     * @param seasonId Season to analyze
     * @return stats Season statistics
     */
    function getWarsSeasonStats(uint32 seasonId)
        external
        view
        returns (SeasonStats memory stats)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Season storage season = cws.seasons[seasonId];
        
        // Basic counts
        stats.registeredColonies = season.registeredColonies.length;
        stats.totalBattles = cws.seasonBattles[seasonId].length;
        stats.activeAlliances = cws.seasonAlliances[seasonId].length;
        stats.prizePool = season.prizePool;
        
        // Calculate resolved battles
        bytes32[] storage battles = cws.seasonBattles[seasonId];
        for (uint256 i = 0; i < battles.length; i++) {
            if (cws.battleResolved[battles[i]]) {
                stats.resolvedBattles++;
            }
        }
        
        // Calculate active territories
        for (uint256 i = 1; i <= cws.territoryCounter; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[i];
            if (territory.active && territory.controllingColony != bytes32(0)) {
                stats.controlledTerritories++;
            }
        }
        
        stats.seasonActive = season.active;
        stats.currentTime = uint32(block.timestamp);
    }

    /**
     * @notice Get comprehensive war stats for specific colony
     * @param colonyId Colony to analyze
     * @return stats Complete colony war statistics
     */
    function getColonyWarStats(bytes32 colonyId) 
        external 
        view 
        returns (ColonyWarStats memory stats) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
        
        // Basic info
        stats.colonyId = colonyId;
        stats.ownerAddress = hs.colonyCreators[colonyId];
        stats.currentSeasonScore = LibColonyWarsStorage.getColonyScore(cws.currentSeason, colonyId);
        stats.defensiveStake = profile.defensiveStake;
        stats.isRegistered = profile.registered;
        stats.warStress = profile.warStress;
        
        // Alliance info
        address owner = stats.ownerAddress;
        stats.inAlliance = LibColonyWarsStorage.isUserInAlliance(owner);
        if (stats.inAlliance) {
            stats.allianceId = LibColonyWarsStorage.getUserAllianceId(owner);
        }
        
        // Territory info
        uint256[] storage territories = cws.colonyTerritories[colonyId];
        uint256 activeCount = 0;
        uint256 totalBonus = 0;
        
        for (uint256 i = 0; i < territories.length; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[territories[i]];
            if (territory.active && territory.controllingColony == colonyId) {
                activeCount++;
                uint256 effectiveBonus = territory.bonusValue - (territory.bonusValue * territory.damageLevel / 100);
                totalBonus += effectiveBonus;
            }
        }
        
        stats.territoriesControlled = activeCount;
        stats.totalTerritoryBonus = totalBonus;

        // COMPLETE BATTLE/SIEGE/RAID STATISTICS
        _calculateCompleteWarStats(colonyId, cws, stats);

        // REWARD STATISTICS
        stats.totalEarnedThisSeason = _estimateSeasonEarnings(colonyId, cws);
        stats.totalEarnedAllTime = stats.totalEarnedThisSeason; // Simplified - would need historical tracking

        // Calculate estimated season prize
        (uint256 prize, , ) = calculateTopSeasonPrize(colonyId, 0, 10);
        stats.estimatedSeasonPrize = prize;

        // Note: lastRewardAmount, lastRewardTime, lastRewardType would require
        // explicit reward event tracking in storage - currently not available
    }

    /**
     * @notice Get comprehensive reward statistics for colony
     * @param colonyId Colony to analyze
     * @return rewardStats Complete reward information
     */
    function getColonyWarRewardStats(bytes32 colonyId) 
        external 
        view 
        returns (ColonyRewardStats memory rewardStats) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        rewardStats.colonyId = colonyId;
        rewardStats.ownerAddress = hs.colonyCreators[colonyId];
        
        // Calculate proportional season prize
        (uint256 proportionalPrize, , bool isEligible) = calculateTopSeasonPrize(
            colonyId, 
            0, // Current season
            10 // Top 10 eligible
        );
        
        rewardStats.pendingSeasonPrize = proportionalPrize;
        rewardStats.eligibleForCurrentPrize = isEligible;
        
        // Calculate other rewards
        uint256 estimatedBattleRewards = _estimateColonyBattleRewards(colonyId, cws);
        uint256 estimatedSiegeRewards = _estimateColonySiegeRewards(colonyId, cws);
        uint256 estimatedRaidBonuses = _estimateColonyRaidBonuses(colonyId, cws);
        
        rewardStats.battleRewardsTotal = estimatedBattleRewards;
        rewardStats.siegeRewardsTotal = estimatedSiegeRewards;
        rewardStats.raidBonusesTotal = estimatedRaidBonuses;
        rewardStats.totalEarnedThisSeason = estimatedBattleRewards + estimatedSiegeRewards + estimatedRaidBonuses;
        
        rewardStats.seasonWinningsCount = _countSeasonWins(colonyId, cws);
        
        return rewardStats;
    }

    /**
     * @notice Get current season prize information
     * @param seasonId Season to check (0 = current season)
     * @return prizeInfo Season prize details
     */
    function getSeasonWarPrizeInfo(uint32 seasonId) 
        public
        view 
        returns (SeasonPrizeInfo memory prizeInfo) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (seasonId == 0) {
            seasonId = cws.currentSeason;
        }
        
        LibColonyWarsStorage.Season storage season = cws.seasons[seasonId];
        
        prizeInfo.seasonId = seasonId;
        prizeInfo.totalPrizePool = season.prizePool;
        prizeInfo.seasonActive = season.active;
        prizeInfo.prizeAwarded = season.rewarded;
        
        if (block.timestamp < season.resolutionEnd) {
            prizeInfo.timeToSeasonEnd = season.resolutionEnd - uint32(block.timestamp);
        }
        
        // Find current leader
        bytes32 leader = _getCurrentSeasonLeader(seasonId, cws);
        if (leader != bytes32(0)) {
            prizeInfo.currentLeader = leader;
            prizeInfo.currentLeaderAddress = hs.colonyCreators[leader];
            prizeInfo.leaderScore = LibColonyWarsStorage.getColonyScore(seasonId, leader);
            
            // Leader gets proportional prize, not full pool
            (uint256 leaderPrize, , ) = calculateTopSeasonPrize(leader, seasonId, 10);
            prizeInfo.estimatedWinnerPrize = leaderPrize;
        }
        
        if (season.rewarded) {
            prizeInfo.actualWinner = leader;
            (uint256 actualPrize, , ) = calculateTopSeasonPrize(leader, seasonId, 10);
            prizeInfo.actualPrizeAmount = actualPrize;
        }
        
        return prizeInfo;
    }

    /**
     * @notice Get global reward distribution statistics
     * @return globalStats System-wide reward information
     */
    function getGlobalWarRewardStats() 
        external 
        view 
        returns (GlobalRewardStats memory globalStats) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        // Calculate totals across all seasons
        uint256 totalSeasonPrizes = 0;
        uint32 completedSeasons = 0;
        uint256 largestPrize = 0;
        
        for (uint32 i = 1; i <= cws.currentSeason; i++) {
            LibColonyWarsStorage.Season storage season = cws.seasons[i];
            if (season.rewarded) {
                totalSeasonPrizes += season.prizePool;
                completedSeasons++;
                if (season.prizePool > largestPrize) {
                    largestPrize = season.prizePool;
                }
            }
        }
        
        globalStats.currentSeasonPrizePool = cws.seasons[cws.currentSeason].prizePool;
        globalStats.totalSeasonPrizes = totalSeasonPrizes;
        globalStats.largestSeasonPrize = largestPrize;
        globalStats.seasonsCompleted = completedSeasons;
        
        if (completedSeasons > 0) {
            globalStats.averageSeasonPrize = totalSeasonPrizes / completedSeasons;
        }
        
        // Note: For battle/siege/raid rewards, you'd need to track these in storage
        // This is simplified estimation
        globalStats.totalBattleRewards = _estimateGlobalBattleRewards(cws);
        globalStats.totalSiegeRewards = _estimateGlobalSiegeRewards(cws);
        globalStats.totalRaidBonuses = _estimateGlobalRaidBonuses(cws);
        
        globalStats.totalRewardsDistributed = totalSeasonPrizes + 
            globalStats.totalBattleRewards + 
            globalStats.totalSiegeRewards + 
            globalStats.totalRaidBonuses;
    }

    /**
     * @notice Get season prize leaderboard with reward estimates
     * @param seasonId Season to check (0 = current)
     * @param limit Max entries to return
     * @return prizeRanking Rankings with prize estimates
     */
    function getSeasonWarPrizeRanking(uint32 seasonId, uint256 limit) 
        external 
        view 
        returns (SeasonWarRanking[] memory prizeRanking) 
    {
        // Get ranking with proportional prizes already calculated
        prizeRanking = getSeasonWarRanking(seasonId, limit);
        
        // The proportional prizes are already calculated in getSeasonWarRanking
        // No additional processing needed
        
        return prizeRanking;
    }

    /**
     * @notice Get reward history for past seasons
     * @param startSeason Starting season (inclusive)
     * @param endSeason Ending season (inclusive, 0 = current)
     * @return seasonPrizes Array of season prize information
     */
    function getSeasonWarRewardHistory(uint32 startSeason, uint32 endSeason) 
        external 
        view 
        returns (SeasonPrizeInfo[] memory seasonPrizes) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        if (endSeason == 0) {
            endSeason = cws.currentSeason;
        }
        
        if (startSeason > endSeason) {
            return new SeasonPrizeInfo[](0);
        }
        
        uint256 seasonCount = endSeason - startSeason + 1;
        seasonPrizes = new SeasonPrizeInfo[](seasonCount);
        
        for (uint32 i = 0; i < seasonCount; i++) {
            uint32 seasonId = startSeason + i;
            seasonPrizes[i] = getSeasonWarPrizeInfo(seasonId);
        }
    }

    /**
     * @notice Get war leaderboard for specific season
     * @param seasonId Season to rank (0 = current season)
     * @param limit Max entries to return
     * @return leaderboard Sorted ranking array
     */
    function getSeasonWarRanking(uint32 seasonId, uint256 limit)
        public
        view
        returns (SeasonWarRanking[] memory leaderboard)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        if (seasonId == 0) {
            seasonId = cws.currentSeason;
        }

        LibColonyWarsStorage.Season storage season = cws.seasons[seasonId];
        uint256 totalColonies = season.registeredColonies.length;

        if (totalColonies == 0) {
            return new SeasonWarRanking[](0);
        }

        uint256 resultSize = totalColonies > limit ? limit : totalColonies;

        // Create temp arrays for sorting
        bytes32[] memory tempColonies = new bytes32[](totalColonies);
        uint256[] memory tempScores = new uint256[](totalColonies);

        for (uint256 i = 0; i < totalColonies; i++) {
            bytes32 colony = season.registeredColonies[i];
            tempColonies[i] = colony;
            tempScores[i] = LibColonyWarsStorage.getColonyScore(seasonId, colony);
        }

        // Bubble sort (descending)
        for (uint256 i = 0; i < totalColonies - 1; i++) {
            for (uint256 j = 0; j < totalColonies - i - 1; j++) {
                if (tempScores[j] < tempScores[j + 1]) {
                    uint256 tempScore = tempScores[j];
                    tempScores[j] = tempScores[j + 1];
                    tempScores[j + 1] = tempScore;

                    bytes32 tempColony = tempColonies[j];
                    tempColonies[j] = tempColonies[j + 1];
                    tempColonies[j + 1] = tempColony;
                }
            }
        }

        // Calculate topTotalScore ONCE (sum of top 10 scores) - O(1) after sort
        uint256 topCount = 10;
        uint256 eligibleCount = totalColonies > topCount ? topCount : totalColonies;
        uint256 topTotalScore = 0;
        for (uint256 i = 0; i < eligibleCount; i++) {
            topTotalScore += tempScores[i];
        }

        uint256 totalPrize = season.prizePool;

        // Build result with proportional prizes
        leaderboard = new SeasonWarRanking[](resultSize);

        for (uint256 i = 0; i < resultSize; i++) {
            bytes32 colonyId = tempColonies[i];
            address owner = hs.colonyCreators[colonyId];

            // Get territory count
            uint256 territoryCount = cws.colonyTerritories[colonyId].length;

            // Calculate proportional prize inline (no nested loops)
            uint256 proportionalPrize = 0;
            if (i < eligibleCount && topTotalScore > 0 && totalPrize > 0) {
                proportionalPrize = (tempScores[i] * totalPrize) / topTotalScore;
            }

            // Get war stats
            (uint256 victories, uint256 actions) = _getColonyTotalWarStats(colonyId, cws);

            leaderboard[i] = SeasonWarRanking({
                colonyId: colonyId,
                ownerAddress: owner,
                score: tempScores[i],
                rank: i + 1,
                territoriesCount: territoryCount,
                totalVictories: victories,
                totalActions: actions,
                inAlliance: owner != address(0) && LibColonyWarsStorage.isUserInAlliance(owner),
                estimatedPrize: proportionalPrize,
                earnedThisSeason: (victories * 1000 ether) + (territoryCount * 500 ether)
            });
        }

        return leaderboard;
    }

    /**
     * @notice Get comprehensive war system statistics
     * @return stats Overall system war stats
     */
    function getWarSystemStats() 
        external 
        view 
        returns (WarSystemStats memory stats) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        uint32 currentSeason = cws.currentSeason;
        LibColonyWarsStorage.Season storage season = cws.seasons[currentSeason];
        
        stats.currentSeason = currentSeason;
        stats.totalRegisteredColonies = season.registeredColonies.length;
        stats.currentSeasonPrizePool = season.prizePool;
        
        // Count active battles
        bytes32[] storage seasonBattles = cws.seasonBattles[currentSeason];
        uint256 activeBattles = 0;
        uint256 completedBattles = 0;
        
        for (uint256 i = 0; i < seasonBattles.length; i++) {
            if (cws.battleResolved[seasonBattles[i]]) {
                completedBattles++;
            } else {
                activeBattles++;
            }
        }
        
        stats.totalActiveBattles = activeBattles;
        stats.totalCompletedBattles = completedBattles;
        
        // Count active and completed sieges from seasonSieges
        uint256 completedSieges = 0;
        bytes32[] storage seasonSiegeIds = cws.seasonSieges[currentSeason];
        for (uint256 i = 0; i < seasonSiegeIds.length; i++) {
            if (cws.siegeResolved[seasonSiegeIds[i]]) {
                completedSieges++;
            }
        }

        stats.totalActiveSieges = cws.activeSieges.length;
        stats.totalCompletedSieges = completedSieges;
        
        // Other stats
        stats.totalActiveAlliances = cws.seasonAlliances[currentSeason].length;
        
        // Count controlled territories
        uint256 controlledTerritories = 0;
        for (uint256 i = 1; i <= cws.territoryCounter; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[i];
            if (territory.active && territory.controllingColony != bytes32(0)) {
                controlledTerritories++;
            }
        }
        stats.totalControlledTerritories = controlledTerritories;
        
        // Time to season end
        if (block.timestamp < season.resolutionEnd) {
            stats.timeToSeasonEnd = season.resolutionEnd - uint32(block.timestamp);
        }
    }

    /**
     * @notice Get top war performers across all categories
     * @param limit Number of top colonies to return
     * @return warLeaders Ranked by combined performance
     */
    function getTopWarPerformers(uint256 limit) 
        external 
        view 
        returns (WarLeaderEntry[] memory warLeaders) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        uint32 seasonId = cws.currentSeason;
        LibColonyWarsStorage.Season storage season = cws.seasons[seasonId];
        
        uint256 totalColonies = season.registeredColonies.length;
        if (totalColonies == 0 || limit == 0) {
            return new WarLeaderEntry[](0);
        }
        
        uint256 resultSize = totalColonies > limit ? limit : totalColonies;
        warLeaders = new WarLeaderEntry[](resultSize);
        
        for (uint256 i = 0; i < resultSize; i++) {
            bytes32 colonyId = season.registeredColonies[i];
            address owner = hs.colonyCreators[colonyId];
            
            (uint256 totalVictories, uint256 totalActions) = _getColonyTotalWarStats(colonyId, cws);
            uint256 winRate = totalActions > 0 ? (totalVictories * 100) / totalActions : 0;
            
            warLeaders[i] = WarLeaderEntry({
                colonyId: colonyId,
                ownerAddress: owner,
                score: LibColonyWarsStorage.getColonyScore(seasonId, colonyId),
                territoriesCount: _countActiveColonyTerritories(colonyId, cws),
                totalVictories: totalVictories,
                totalActions: totalActions,
                winRate: winRate
            });
        }
        
        return warLeaders;
    }

    /**
     * @notice Get all colonies registered for a specific season
     * @param seasonId Season ID to check
     * @param limit Maximum number of colonies to return (gas optimization)
     */
    function getWarsSeasonParticipants(uint32 seasonId, uint256 limit) 
        external 
        view 
        returns (
            bytes32[] memory colonies,
            uint256[] memory stakes,
            uint256[] memory scores
        ) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Season storage season = cws.seasons[seasonId];
        
        uint256 totalColonies = season.registeredColonies.length;
        if (totalColonies == 0) {
            return (new bytes32[](0), new uint256[](0), new uint256[](0));
        }
        
        // Limit to prevent gas issues
        uint256 resultSize = totalColonies > limit ? limit : totalColonies;
        
        colonies = new bytes32[](resultSize);
        stakes = new uint256[](resultSize);
        scores = new uint256[](resultSize);
        
        for (uint256 i = 0; i < resultSize; i++) {
            bytes32 colonyId = season.registeredColonies[i];
            colonies[i] = colonyId;
            stakes[i] = cws.colonyWarProfiles[colonyId].defensiveStake;
            scores[i] = LibColonyWarsStorage.getColonyScore(seasonId, colonyId);
        }
        
        return (colonies, stakes, scores);
    }

    /**
     * @notice Get colony's war rank in current season
     * @param colonyId Colony to check
     * @return rank Position (1 = first place, 0 = not ranked)
     * @return score Colony's current war score
     * @return totalParticipants Total colonies in season
     */
    function getColonyCombatRank(bytes32 colonyId) 
        public
        view 
        returns (uint256 rank, uint256 score, uint256 totalParticipants) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        uint32 seasonId = cws.currentSeason;
        LibColonyWarsStorage.Season storage season = cws.seasons[seasonId];
        
        totalParticipants = season.registeredColonies.length;
        score = LibColonyWarsStorage.getColonyScore(seasonId, colonyId);
        
        if (score == 0) {
            return (0, 0, totalParticipants);
        }
        
        uint256 betterCount = 0;
        for (uint256 i = 0; i < season.registeredColonies.length; i++) {
            bytes32 otherColony = season.registeredColonies[i];
            if (otherColony != colonyId) {
                uint256 otherScore = LibColonyWarsStorage.getColonyScore(seasonId, otherColony);
                if (otherScore > score) {
                    betterCount++;
                }
            }
        }
        
        rank = betterCount + 1;
    }

    
    /**
     * @notice Get user's registered colonies for current season
     * @param user User address
     * @return colonies Array of colony IDs
     * @return stakes Array of defensive stakes
     */
    function getUserSeasonColonies(address user) 
        external 
        view 
        returns (bytes32[] memory colonies, uint256[] memory stakes) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        colonies = LibColonyWarsStorage.getUserSeasonColonies(cws.currentSeason, user);
        
        stakes = new uint256[](colonies.length);
        for (uint256 i = 0; i < colonies.length; i++) {
            stakes[i] = cws.colonyWarProfiles[colonies[i]].defensiveStake;
        }
    }

    /**
     * @notice Get user's primary colony
     * @param user User address
     * @return primaryColony Primary colony ID
     */
    function getUserPrimaryColony(address user) 
        external 
        view 
        returns (bytes32 primaryColony) 
    {
        return LibColonyWarsStorage.getUserPrimaryColony(user);
    }

    /**
     * @notice Get user's colony count for current season
     * @param user User address
     * @return count Number of colonies registered this season
     */
    function getUserColonyCount(address user) 
        external 
        view 
        returns (uint256 count) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        return LibColonyWarsStorage.getUserSeasonColonies(cws.currentSeason, user).length;
    }

    /**
     * @notice Get colony's accumulated losses
     * @param colonyId Colony to check
     * @return totalLosses Total ZICO lost in penalties
     */
    function getColonyCombatLosses(bytes32 colonyId) 
        external 
        view 
        returns (uint256 totalLosses) 
    {
        return LibColonyWarsStorage.colonyWarsStorage().colonyLosses[colonyId];
    }

    
    /**
     * @notice Get battles for specific season with pagination
     * @param seasonId Season to get battles for
     * @param includeResolved Whether to include already resolved battles
     * @param offset Starting index for pagination
     * @param limit Maximum number of battles to return (0 = all)
     * @return battles Array of battle information
     * @return total Total number of matching battles
     */
    function getSeasonBattles(uint32 seasonId, bool includeResolved, uint256 offset, uint256 limit)
        external
        view
        returns (SeasonBattleInfo[] memory battles, uint256 total)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        bytes32[] storage battleIds = cws.seasonBattles[seasonId];

        // Single pass: collect matching battles up to limit
        uint256 maxResults = limit == 0 ? battleIds.length : limit;
        SeasonBattleInfo[] memory tempBattles = new SeasonBattleInfo[](maxResults);
        uint256 found = 0;
        uint256 skipped = 0;

        for (uint256 i = 0; i < battleIds.length && found < maxResults; i++) {
            bool resolved = cws.battleResolved[battleIds[i]];
            if (includeResolved || !resolved) {
                if (skipped < offset) {
                    skipped++;
                    total++;
                    continue;
                }
                LibColonyWarsStorage.BattleInstance storage battle = cws.battles[battleIds[i]];
                tempBattles[found] = SeasonBattleInfo({
                    battleId: battleIds[i],
                    attackerColony: battle.attackerColony,
                    defenderColony: battle.defenderColony,
                    stakeAmount: battle.stakeAmount,
                    prizePool: battle.prizePool,
                    battleState: battle.battleState,
                    battleStartTime: battle.battleStartTime,
                    battleEndTime: battle.battleEndTime,
                    winner: battle.winner,
                    resolved: resolved
                });
                found++;
                total++;
            }
        }

        // Continue counting total if we hit limit early
        if (found == maxResults) {
            for (uint256 i = found + skipped; i < battleIds.length; i++) {
                bool resolved = cws.battleResolved[battleIds[i]];
                if (includeResolved || !resolved) {
                    total++;
                }
            }
        }

        // Copy to correctly sized array
        battles = new SeasonBattleInfo[](found);
        for (uint256 i = 0; i < found; i++) {
            battles[i] = tempBattles[i];
        }
    }

    /**
     * @notice Get battle history for specific colony with pagination
     * @param colonyId Colony to get battles for
     * @param seasonId Season filter (0 for all seasons)
     * @param offset Starting index for pagination
     * @param limit Maximum number of battles to return (0 = all)
     * @return battles Array of battles involving the colony
     * @return total Total number of matching battles
     */
    function getColonyBattleHistory(bytes32 colonyId, uint32 seasonId, uint256 offset, uint256 limit)
        external
        view
        returns (ColonyBattleInfo[] memory battles, uint256 total)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        bytes32[] storage battleIds = seasonId == 0
            ? cws.colonyBattleHistory[colonyId]
            : cws.seasonBattles[seasonId];

        // Single pass: collect matching battles up to limit (newest first)
        uint256 maxResults = limit == 0 ? battleIds.length : limit;
        ColonyBattleInfo[] memory tempBattles = new ColonyBattleInfo[](maxResults);
        uint256 found = 0;
        uint256 skipped = 0;
        uint256 len = battleIds.length;

        // Iterate from end to start for newest-first ordering
        for (uint256 i = len; i > 0 && found < maxResults; i--) {
            uint256 idx = i - 1;
            LibColonyWarsStorage.BattleInstance storage battle = cws.battles[battleIds[idx]];
            if (battle.attackerColony == colonyId || battle.defenderColony == colonyId) {
                if (skipped < offset) {
                    skipped++;
                    total++;
                    continue;
                }
                tempBattles[found] = ColonyBattleInfo({
                    battleId: battleIds[idx],
                    wasAttacker: (battle.attackerColony == colonyId),
                    opponent: (battle.attackerColony == colonyId) ? battle.defenderColony : battle.attackerColony,
                    stakeAmount: battle.stakeAmount,
                    won: (battle.winner == colonyId),
                    battleStartTime: battle.battleStartTime,
                    resolved: cws.battleResolved[battleIds[idx]]
                });
                found++;
                total++;
            }
        }

        // Continue counting total if we hit limit early
        if (found == maxResults) {
            for (uint256 i = len - found - skipped; i > 0; i--) {
                uint256 idx = i - 1;
                LibColonyWarsStorage.BattleInstance storage battle = cws.battles[battleIds[idx]];
                if (battle.attackerColony == colonyId || battle.defenderColony == colonyId) {
                    total++;
                }
            }
        }

        // Copy to correctly sized array
        battles = new ColonyBattleInfo[](found);
        for (uint256 i = 0; i < found; i++) {
            battles[i] = tempBattles[i];
        }
    }
         

    /**
     * @notice Get territorial dominance leaders
     * @param limit Max results to return
     * @return territoryLeaders Ranked by territory control
     */
    function getTerritoryWarLeaders(uint256 limit) 
        external 
        view 
        returns (WarLeaderEntry[] memory territoryLeaders) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
        uint256 totalColonies = season.registeredColonies.length;
        
        if (totalColonies == 0 || limit == 0) {
            return new WarLeaderEntry[](0);
        }
        
        uint256 resultSize = totalColonies > limit ? limit : totalColonies;
        
        // Sort by territory count
        bytes32[] memory tempColonies = new bytes32[](totalColonies);
        uint256[] memory tempTerritoryCounts = new uint256[](totalColonies);
        
        for (uint256 i = 0; i < totalColonies; i++) {
            bytes32 colonyId = season.registeredColonies[i];
            tempColonies[i] = colonyId;
            tempTerritoryCounts[i] = _countActiveColonyTerritories(colonyId, cws);
        }
        
        // Sort descending
        for (uint256 i = 0; i < totalColonies - 1; i++) {
            for (uint256 j = 0; j < totalColonies - i - 1; j++) {
                if (tempTerritoryCounts[j] < tempTerritoryCounts[j + 1]) {
                    uint256 tempCount = tempTerritoryCounts[j];
                    tempTerritoryCounts[j] = tempTerritoryCounts[j + 1];
                    tempTerritoryCounts[j + 1] = tempCount;
                    
                    bytes32 tempColony = tempColonies[j];
                    tempColonies[j] = tempColonies[j + 1];
                    tempColonies[j + 1] = tempColony;
                }
            }
        }
        
        territoryLeaders = new WarLeaderEntry[](resultSize);
        
        for (uint256 i = 0; i < resultSize; i++) {
            bytes32 colonyId = tempColonies[i];
            
            (uint256 totalVictories, uint256 totalActions) = _getColonyTotalWarStats(colonyId, cws);
            uint256 winRate = totalActions > 0 ? (totalVictories * 100) / totalActions : 0;
            
            territoryLeaders[i] = WarLeaderEntry({
                colonyId: colonyId,
                ownerAddress: hs.colonyCreators[colonyId],
                score: LibColonyWarsStorage.getColonyScore(cws.currentSeason, colonyId),
                territoriesCount: tempTerritoryCounts[i],
                totalVictories: totalVictories,
                totalActions: totalActions,
                winRate: winRate
            });
        }
        
        return territoryLeaders;
    }

    // Internal helper functions
    
    function _calculateCompleteWarStats(
        bytes32 colonyId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        ColonyWarStats memory stats
    ) internal view {
        // Colony battles
        bytes32[] storage battleHistory = cws.colonyBattleHistory[colonyId];
        stats.colonyBattlesTotal = battleHistory.length;

        uint256 colonyWins = 0;
        for (uint256 i = 0; i < battleHistory.length; i++) {
            LibColonyWarsStorage.BattleInstance storage battle = cws.battles[battleHistory[i]];
            if (battle.winner == colonyId && cws.battleResolved[battleHistory[i]]) {
                colonyWins++;
            }
        }
        stats.colonyBattlesWon = colonyWins;
        stats.colonyBattlesLost = stats.colonyBattlesTotal - colonyWins;

        // Territory sieges - calculate from colonySiegeHistory
        bytes32[] storage siegeHistory = cws.colonySiegeHistory[colonyId];
        uint256 siegesResolved = 0;
        uint256 siegesWon = 0;

        for (uint256 i = 0; i < siegeHistory.length; i++) {
            LibColonyWarsStorage.TerritorySiege storage siege = cws.territorySieges[siegeHistory[i]];
            if (cws.siegeResolved[siegeHistory[i]]) {
                siegesResolved++;
                if (siege.winner == colonyId) {
                    siegesWon++;
                }
            }
        }

        stats.territorySiegesTotal = siegesResolved;
        stats.territorySiegesWon = siegesWon;
        stats.territorySiegesLost = siegesResolved > siegesWon ? siegesResolved - siegesWon : 0;

        // Territory raids - estimate from controlled territories and damage events
        // Note: For accurate raid tracking, storage would need explicit raid history per colony
        // Current estimation based on territories owned and their damage patterns
        uint256[] storage colonyTerritories = cws.colonyTerritories[colonyId];
        uint256 estimatedRaidsDefended = 0;

        for (uint256 i = 0; i < colonyTerritories.length; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[colonyTerritories[i]];
            if (territory.controllingColony == colonyId && territory.damageLevel > 0) {
                // Estimate raids based on damage (each successful raid does ~8-15% damage)
                estimatedRaidsDefended += territory.damageLevel / 10;
            }
        }

        // For raids initiated, we estimate based on battle activity ratio
        // This is an approximation - for precise tracking, explicit raid history would be needed
        uint256 estimatedRaidsInitiated = battleHistory.length > 0 ? battleHistory.length / 2 : 0;
        uint256 estimatedRaidsSuccess = estimatedRaidsInitiated > 0 ? estimatedRaidsInitiated / 3 : 0;

        stats.territoryRaidsTotal = estimatedRaidsInitiated;
        stats.territoryRaidsSuccess = estimatedRaidsSuccess;
        stats.territoryRaidsFailed = estimatedRaidsInitiated > estimatedRaidsSuccess ?
            estimatedRaidsInitiated - estimatedRaidsSuccess : 0;

        // Combined totals
        stats.totalVictories = stats.colonyBattlesWon + stats.territorySiegesWon + stats.territoryRaidsSuccess;
        stats.totalActions = stats.colonyBattlesTotal + stats.territorySiegesTotal + stats.territoryRaidsTotal;
    }
    
    function _getColonyTotalWarStats(bytes32 colonyId, LibColonyWarsStorage.ColonyWarsStorage storage cws)
        internal
        view
        returns (uint256 totalVictories, uint256 totalActions)
    {
        // Colony battle wins - limit to last 500 for gas safety
        bytes32[] storage battleHistory = cws.colonyBattleHistory[colonyId];
        uint256 battleLen = battleHistory.length;
        uint256 battleStart = battleLen > 500 ? battleLen - 500 : 0;

        uint256 battleWins = 0;
        for (uint256 i = battleStart; i < battleLen; i++) {
            bytes32 battleId = battleHistory[i];
            if (cws.battleResolved[battleId]) {
                LibColonyWarsStorage.BattleInstance storage battle = cws.battles[battleId];
                if (battle.winner == colonyId) {
                    battleWins++;
                }
            }
        }

        // Siege wins - limit to last 500 for gas safety
        bytes32[] storage siegeHistory = cws.colonySiegeHistory[colonyId];
        uint256 siegeLen = siegeHistory.length;
        uint256 siegeStart = siegeLen > 500 ? siegeLen - 500 : 0;

        uint256 siegeWins = 0;
        uint256 siegesResolved = 0;
        for (uint256 i = siegeStart; i < siegeLen; i++) {
            bytes32 siegeId = siegeHistory[i];
            if (cws.siegeResolved[siegeId]) {
                siegesResolved++;
                LibColonyWarsStorage.TerritorySiege storage siege = cws.territorySieges[siegeId];
                if (siege.winner == colonyId) {
                    siegeWins++;
                }
            }
        }

        totalVictories = battleWins + siegeWins;
        totalActions = (battleLen - battleStart) + siegesResolved;
    }

    function _countActiveColonyTerritories(bytes32 colonyId, LibColonyWarsStorage.ColonyWarsStorage storage cws) 
        internal 
        view 
        returns (uint256 count) 
    {
        uint256[] storage territories = cws.colonyTerritories[colonyId];
        
        for (uint256 i = 0; i < territories.length; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[territories[i]];
            if (territory.active && territory.controllingColony == colonyId) {
                count++;
            }
        }
    }

    // Internal helper functions for reward calculations

    function _estimateColonyBattleRewards(bytes32 colonyId, LibColonyWarsStorage.ColonyWarsStorage storage cws)
        internal
        view
        returns (uint256 estimated)
    {
        // Simplified estimation without iteration - assume ~50% win rate
        uint256 battleCount = cws.colonyBattleHistory[colonyId].length;
        uint256 estimatedWins = battleCount / 2;
        // Estimate: average 1000 ZICO per battle win
        return estimatedWins * 1000 ether;
    }

    function _estimateColonySiegeRewards(bytes32 colonyId, LibColonyWarsStorage.ColonyWarsStorage storage cws) 
        internal 
        view 
        returns (uint256 estimated) 
    {
        // Simplified: estimate based on territories controlled
        uint256 territories = _countActiveColonyTerritories(colonyId, cws);
        // Estimate: 500 ZICO per territory controlled (assumes some sieges won)
        return territories * 500 ether;
    }

    function _estimateColonyRaidBonuses(bytes32 colonyId, LibColonyWarsStorage.ColonyWarsStorage storage cws) 
        internal 
        view 
        returns (uint256 estimated) 
    {
        // Simplified: small bonus estimate
        uint256 battles = cws.colonyBattleHistory[colonyId].length;
        // Estimate: 50 ZICO average raid bonus per battle (some successful raids)
        return battles * 50 ether;
    }

    function _countSeasonWins(bytes32 colonyId, LibColonyWarsStorage.ColonyWarsStorage storage cws) 
        internal 
        view 
        returns (uint256 wins) 
    {
        // Check previous seasons to see if this colony was the leader
        for (uint32 i = 1; i < cws.currentSeason; i++) {
            bytes32 winner = _getCurrentSeasonLeader(i, cws);
            if (winner == colonyId) {
                wins++;
            }
        }
    }

    function _getCurrentSeasonLeader(uint32 seasonId, LibColonyWarsStorage.ColonyWarsStorage storage cws) 
        internal 
        view 
        returns (bytes32 leader) 
    {
        LibColonyWarsStorage.Season storage season = cws.seasons[seasonId];
        uint256 maxScore = 0;
        
        for (uint256 i = 0; i < season.registeredColonies.length; i++) {
            bytes32 colony = season.registeredColonies[i];
            uint256 score = LibColonyWarsStorage.getColonyScore(seasonId, colony);
            if (score > maxScore) {
                maxScore = score;
                leader = colony;
            }
        }
    }

    function _estimateSeasonEarnings(bytes32 colonyId, LibColonyWarsStorage.ColonyWarsStorage storage cws) 
        internal 
        view 
        returns (uint256 earnings) 
    {
        return _estimateColonyBattleRewards(colonyId, cws) + 
            _estimateColonySiegeRewards(colonyId, cws) + 
            _estimateColonyRaidBonuses(colonyId, cws);
    }

    function _estimateGlobalBattleRewards(LibColonyWarsStorage.ColonyWarsStorage storage cws) 
        internal 
        view 
        returns (uint256 total) 
    {
        // Simplified global estimation
        uint256 totalBattles = 0;
        for (uint32 i = 1; i <= cws.currentSeason; i++) {
            totalBattles += cws.seasonBattles[i].length;
        }
        return totalBattles * 1500 ether; // Average per battle
    }

    function _estimateGlobalSiegeRewards(LibColonyWarsStorage.ColonyWarsStorage storage cws) 
        internal 
        view 
        returns (uint256 total) 
    {
        // Simplified: estimate based on siege counter
        return cws.siegeCounter * 800 ether; // Average per siege
    }

    function _estimateGlobalRaidBonuses(LibColonyWarsStorage.ColonyWarsStorage storage cws)
        internal
        view
        returns (uint256 total)
    {
        // Very simplified estimation
        return cws.territoryCounter * 200 ether; // Estimate based on territories
    }

}