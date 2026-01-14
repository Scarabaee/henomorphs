// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title IAchievementRewardFacet
 * @notice Interface for achievement completion calls
 */
interface IAchievementRewardFacet {
    function completeAchievement(address user, uint256 achievementId, uint8 tier) external;
}

/**
 * @title LibAchievementTrigger
 * @notice Central library for triggering achievements from Chargepod Diamond facets
 * @dev Uses address(this) for inter-facet calls within the same diamond
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
library LibAchievementTrigger {
    // ==================== ACHIEVEMENT IDs ====================

    // Combat (Category 1)
    uint256 constant FIRST_BLOOD = 1;           // Win first battle
    uint256 constant BATTLE_VETERAN = 2;        // Win 10/50/100/500 battles
    uint256 constant UNDEFEATED = 3;            // 10 wins in a row
    uint256 constant BATTLE_MASTER = 4;         // Win 50 battles with >80% health
    uint256 constant SIEGE_BREAKER = 5;         // Break 10 sieges
    uint256 constant WAR_HERO = 6;              // Win season championship

    // Territory (Category 2)
    uint256 constant TERRITORY_DEFENDER = 10;   // Defend territory 5x
    uint256 constant RAIDER = 11;               // 10/50/100 successful raids
    uint256 constant CONQUEROR = 12;            // Capture 5/20/50 territories
    uint256 constant SCOUT_MASTER = 13;         // Scout 50 territories
    uint256 constant SIEGE_MASTER = 14;         // Win 10/30/50 sieges

    // Economic (Category 3)
    uint256 constant RESOURCE_MOGUL = 20;       // Collect 10k/50k/100k resources
    uint256 constant MASTER_CRAFTER = 21;       // Complete 10/50/100 projects
    uint256 constant TRADER = 22;               // Complete 50 trades
    uint256 constant PROCESSOR = 23;            // Process 1k/5k/10k resources
    uint256 constant ECONOMY_KING = 24;         // Earn 100k tokens

    // Collection (Category 4) - triggerowane z Staking Diamond
    uint256 constant COLLECTOR_INITIATE = 30;   // Stake first Henomorph
    uint256 constant COLLECTOR_ELITE = 31;      // Own 10/25/50/100 NFTs staked
    uint256 constant COMPLETE_GENESIS = 32;     // Own all 16 Genesis variants
    uint256 constant LONG_TERM_STAKER = 33;     // Stake for 30/90/180 days
    uint256 constant REWARD_HUNTER = 34;        // Claim 100 staking rewards

    // Social (Category 5)
    uint256 constant ALLIANCE_BUILDER = 40;     // Create alliance mission
    uint256 constant TEAM_PLAYER = 41;          // Complete 10 alliance missions
    uint256 constant CONTRIBUTOR = 42;          // Contribute to 20 projects
    uint256 constant LEADER = 43;               // Lead 5 successful missions
    uint256 constant DIPLOMAT = 44;             // Form 3 treaties

    // Special (Category 6)
    uint256 constant GENESIS_PIONEER = 50;      // Among first 1000 players
    uint256 constant SPECIALIST = 51;           // Change specialization
    uint256 constant EVOLUTION_MASTER = 52;     // Evolve 5 henomorphs
    uint256 constant LEGENDARY_STATUS = 54;     // Max level in all categories

    // ==================== HELPER FUNCTIONS ====================

    /**
     * @notice Calculate tier based on progressive thresholds
     * @param current Current value
     * @param bronze Bronze threshold
     * @param silver Silver threshold
     * @param gold Gold threshold
     * @param platinum Platinum threshold
     * @return tier 0 if below bronze, 1-4 for Bronze/Silver/Gold/Platinum
     */
    function calculateProgressiveTier(
        uint256 current,
        uint256 bronze,
        uint256 silver,
        uint256 gold,
        uint256 platinum
    ) internal pure returns (uint8) {
        if (current >= platinum) return 4;
        if (current >= gold) return 3;
        if (current >= silver) return 2;
        if (current >= bronze) return 1;
        return 0;
    }

    /**
     * @notice Trigger achievement via inter-facet call (Chargepod Diamond)
     * @dev Uses address(this) since AchievementRewardFacet is in the same diamond
     * @param user User to grant achievement
     * @param achievementId Achievement ID
     * @param tier Tier level (1-4)
     */
    function triggerAchievement(address user, uint256 achievementId, uint8 tier) internal {
        try IAchievementRewardFacet(address(this)).completeAchievement(user, achievementId, tier) {} catch {}
    }

    /**
     * @notice Trigger progressive achievement based on current value
     * @param user User to grant achievement
     * @param achievementId Achievement ID
     * @param currentValue Current progress value
     * @param bronze Bronze threshold
     * @param silver Silver threshold
     * @param gold Gold threshold
     * @param platinum Platinum threshold
     */
    function triggerProgressiveAchievement(
        address user,
        uint256 achievementId,
        uint256 currentValue,
        uint256 bronze,
        uint256 silver,
        uint256 gold,
        uint256 platinum
    ) internal {
        uint8 tier = calculateProgressiveTier(currentValue, bronze, silver, gold, platinum);
        if (tier > 0) {
            triggerAchievement(user, achievementId, tier);
        }
    }

    // ==================== COMBAT TRIGGERS ====================

    /**
     * @notice Trigger battle-related achievements
     * @param user Winner of the battle
     * @param totalWins Total number of wins
     * @param currentStreak Current win streak
     */
    function triggerBattleWin(address user, uint256 totalWins, uint256 currentStreak) internal {
        // First Blood - first battle won
        if (totalWins == 1) {
            triggerAchievement(user, FIRST_BLOOD, 1);
        }

        // Battle Veteran - progressive: 10, 50, 100, 500 wins
        triggerProgressiveAchievement(user, BATTLE_VETERAN, totalWins, 10, 50, 100, 500);

        // Undefeated - 10 wins in a row
        if (currentStreak >= 10) {
            triggerAchievement(user, UNDEFEATED, 2);
        }
    }

    /**
     * @notice Trigger siege break achievement
     * @param user Player who broke the siege
     * @param siegesBroken Total sieges broken
     */
    function triggerSiegeBreak(address user, uint256 siegesBroken) internal {
        if (siegesBroken >= 10) {
            triggerAchievement(user, SIEGE_BREAKER, 2);
        }
    }

    // ==================== TERRITORY TRIGGERS ====================

    /**
     * @notice Trigger territory defense achievement
     * @param user Defender
     * @param defenseCount Total successful defenses
     */
    function triggerDefense(address user, uint256 defenseCount) internal {
        if (defenseCount >= 5) {
            triggerAchievement(user, TERRITORY_DEFENDER, 1);
        }
    }

    /**
     * @notice Trigger raid achievement
     * @param user Raider
     * @param raidCount Total successful raids
     */
    function triggerRaid(address user, uint256 raidCount) internal {
        triggerProgressiveAchievement(user, RAIDER, raidCount, 10, 50, 100, 200);
    }

    /**
     * @notice Trigger siege win achievement
     * @param user Siege winner
     * @param siegeWins Total siege victories
     */
    function triggerSiegeWin(address user, uint256 siegeWins) internal {
        triggerProgressiveAchievement(user, SIEGE_MASTER, siegeWins, 10, 30, 50, 100);
    }

    /**
     * @notice Trigger territory capture achievement
     * @param user Conqueror
     * @param captureCount Total territories captured
     */
    function triggerTerritoryCapture(address user, uint256 captureCount) internal {
        triggerProgressiveAchievement(user, CONQUEROR, captureCount, 5, 20, 50, 100);
    }

    /**
     * @notice Trigger scout achievement
     * @param user Scout
     * @param scoutCount Total territories scouted
     */
    function triggerScout(address user, uint256 scoutCount) internal {
        if (scoutCount >= 50) {
            triggerAchievement(user, SCOUT_MASTER, 2);
        }
    }

    // ==================== ECONOMIC TRIGGERS ====================

    /**
     * @notice Trigger resource collection achievement
     * @param user Collector
     * @param totalResources Total resources collected
     */
    function triggerResourceCollection(address user, uint256 totalResources) internal {
        triggerProgressiveAchievement(user, RESOURCE_MOGUL, totalResources, 10000, 50000, 100000, 500000);
    }

    /**
     * @notice Trigger resource processing achievement (simple version)
     * @param user Processor
     */
    function triggerResourceProcessing(address user) internal {
        // Simple trigger - grants bronze tier for first processing
        triggerAchievement(user, PROCESSOR, 1);
    }

    /**
     * @notice Trigger resource processing achievement with count
     * @param user Processor
     * @param processedAmount Total resources processed
     */
    function triggerResourceProcessingWithCount(address user, uint256 processedAmount) internal {
        triggerProgressiveAchievement(user, PROCESSOR, processedAmount, 1000, 5000, 10000, 50000);
    }

    /**
     * @notice Trigger trade completion achievement
     * @param user Trader
     * @param tradeCount Total trades completed
     */
    function triggerTrade(address user, uint256 tradeCount) internal {
        if (tradeCount >= 50) {
            triggerAchievement(user, TRADER, 2);
        }
    }

    /**
     * @notice Trigger infrastructure building achievement
     * @param user Builder
     */
    function triggerInfrastructureBuild(address user) internal {
        // Grants achievement for infrastructure building (Economic category)
        triggerAchievement(user, ECONOMY_KING, 1);
    }

    // ==================== CRAFTING TRIGGERS ====================

    /**
     * @notice Trigger project completion achievement
     * @param user Crafter
     * @param completedProjects Total projects completed
     */
    function triggerProjectCompletion(address user, uint256 completedProjects) internal {
        triggerProgressiveAchievement(user, MASTER_CRAFTER, completedProjects, 10, 50, 100, 200);
    }

    /**
     * @notice Trigger project contribution achievement
     * @param user Contributor
     * @param contributions Total contributions made
     */
    function triggerProjectContribution(address user, uint256 contributions) internal {
        if (contributions >= 20) {
            triggerAchievement(user, CONTRIBUTOR, 2);
        }
    }

    /**
     * @notice Trigger collaborative project creation achievement
     * @param user Project creator
     */
    function triggerCollaborativeProject(address user) internal {
        triggerAchievement(user, MASTER_CRAFTER, 1);
    }

    /**
     * @notice Trigger contribution achievement (simple version)
     * @param user Contributor
     */
    function triggerContribution(address user) internal {
        triggerAchievement(user, CONTRIBUTOR, 1);
    }

    // ==================== SOCIAL TRIGGERS ====================

    /**
     * @notice Trigger alliance mission creation achievement
     * @param user Mission creator
     * @param missionsCreated Total missions created
     */
    function triggerAllianceMissionCreation(address user, uint256 missionsCreated) internal {
        // First mission created
        if (missionsCreated == 1) {
            triggerAchievement(user, ALLIANCE_BUILDER, 1);
        }
        // Leader - 5 missions led
        if (missionsCreated >= 5) {
            triggerAchievement(user, LEADER, 2);
        }
    }

    /**
     * @notice Trigger alliance mission completion achievement
     * @param user Mission participant
     * @param missionsCompleted Total missions completed
     */
    function triggerAllianceMissionCompletion(address user, uint256 missionsCompleted) internal {
        if (missionsCompleted >= 10) {
            triggerAchievement(user, TEAM_PLAYER, 2);
        }
    }

    /**
     * @notice Trigger treaty formation achievement
     * @param user Diplomat
     * @param treatiesFormed Total treaties formed
     */
    function triggerTreatyFormation(address user, uint256 treatiesFormed) internal {
        if (treatiesFormed >= 3) {
            triggerAchievement(user, DIPLOMAT, 2);
        }
    }

    /**
     * @notice Trigger territory conquest achievement
     * @param user Conqueror
     */
    function triggerTerritoryConquest(address user) internal {
        triggerAchievement(user, CONQUEROR, 1);
    }

    /**
     * @notice Trigger diplomacy achievement (treaty accepted)
     * @param user Diplomat
     */
    function triggerDiplomacy(address user) internal {
        triggerAchievement(user, DIPLOMAT, 1);
    }

    /**
     * @notice Trigger mission completion achievement
     * @param user Mission contributor
     */
    function triggerMissionComplete(address user) internal {
        triggerAchievement(user, TEAM_PLAYER, 1);
    }

    /**
     * @notice Trigger coordinated attack achievement
     * @param user Attack coordinator
     */
    function triggerCoordinatedAttack(address user) internal {
        triggerAchievement(user, WAR_HERO, 1);
    }

    // ==================== SPECIAL TRIGGERS ====================

    /**
     * @notice Trigger specialization change achievement
     * @param user Player who changed specialization
     */
    function triggerSpecializationChange(address user) internal {
        triggerAchievement(user, SPECIALIST, 1);
    }

    /**
     * @notice Trigger evolution achievement
     * @param user Player who evolved henomorphs
     * @param evolutionCount Total evolutions
     */
    function triggerEvolution(address user, uint256 evolutionCount) internal {
        if (evolutionCount >= 5) {
            triggerAchievement(user, EVOLUTION_MASTER, 2);
        }
    }
}
