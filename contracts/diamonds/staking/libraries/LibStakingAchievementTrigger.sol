// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibStakingStorage} from "./LibStakingStorage.sol";

/**
 * @title IAchievementRewardFacet
 * @notice Interface for achievement completion calls to Chargepod Diamond
 */
interface IAchievementRewardFacet {
    function completeAchievement(address user, uint256 achievementId, uint8 tier) external;
}

/**
 * @title LibStakingAchievementTrigger
 * @notice Library for triggering achievements from Staking Diamond facets
 * @dev Uses chargeSystemAddress for cross-diamond calls to Chargepod Diamond
 *      where AchievementRewardFacet resides
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
library LibStakingAchievementTrigger {
    // ==================== ACHIEVEMENT IDs ====================
    // Collection achievements (Category 4) - triggerowane z Staking Diamond

    uint256 constant COLLECTOR_INITIATE = 30;   // Stake first Henomorph
    uint256 constant COLLECTOR_ELITE = 31;      // Own 10/25/50/100 NFTs staked
    uint256 constant COMPLETE_GENESIS = 32;     // Own all 16 Genesis variants
    uint256 constant LONG_TERM_STAKER = 33;     // Stake for 30/90/180 days
    uint256 constant REWARD_HUNTER = 34;        // Claim 100 staking rewards

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
     * @notice Get Chargepod Diamond address from Staking storage
     * @dev Reads chargeSystemAddress from LibStakingStorage
     * @return Chargepod Diamond address
     */
    function getChargepodAddress() internal view returns (address) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        return ss.chargeSystemAddress;
    }

    /**
     * @notice Trigger achievement via cross-diamond call to Chargepod
     * @dev Uses chargeSystemAddress to call AchievementRewardFacet.completeAchievement()
     *      Silently fails if Chargepod address is not set or call fails
     * @param user User to grant achievement
     * @param achievementId Achievement ID
     * @param tier Tier level (1-4)
     */
    function triggerAchievement(address user, uint256 achievementId, uint8 tier) internal {
        address chargepod = getChargepodAddress();
        if (chargepod == address(0)) return;

        try IAchievementRewardFacet(chargepod).completeAchievement(user, achievementId, tier) {} catch {}
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

    // ==================== STAKING TRIGGERS ====================

    /**
     * @notice Trigger staking achievements when user stakes a token
     * @param user Staker address
     * @param stakedCount Total number of tokens staked by user
     */
    function triggerStake(address user, uint256 stakedCount) internal {
        // Collector Initiate - first stake
        if (stakedCount == 1) {
            triggerAchievement(user, COLLECTOR_INITIATE, 1);
        }

        // Collector Elite - progressive: 10, 25, 50, 100 staked
        triggerProgressiveAchievement(user, COLLECTOR_ELITE, stakedCount, 10, 25, 50, 100);
    }

    /**
     * @notice Trigger reward claim achievement (simple version)
     * @param user User who claimed rewards
     */
    function triggerRewardClaim(address user) internal {
        // Simple trigger - grants bronze tier for claiming rewards
        triggerAchievement(user, REWARD_HUNTER, 1);
    }

    /**
     * @notice Trigger reward claim achievement with count
     * @param user User who claimed rewards
     * @param claimCount Total number of reward claims
     */
    function triggerRewardClaimWithCount(address user, uint256 claimCount) internal {
        // Reward Hunter - 100 claims
        if (claimCount >= 100) {
            triggerAchievement(user, REWARD_HUNTER, 2);
        }
    }

    /**
     * @notice Trigger long-term staking achievement
     * @param user Long-term staker
     * @param stakingDays Total days of staking
     */
    function triggerLongTermStaking(address user, uint256 stakingDays) internal {
        // Long Term Staker - progressive: 30, 90, 180, 365 days
        triggerProgressiveAchievement(user, LONG_TERM_STAKER, stakingDays, 30, 90, 180, 365);
    }

    /**
     * @notice Trigger complete genesis collection achievement
     * @param user User who owns all genesis variants
     * @param hasAllVariants Whether user has all 16 genesis variants
     */
    function triggerCompleteGenesis(address user, bool hasAllVariants) internal {
        if (hasAllVariants) {
            triggerAchievement(user, COMPLETE_GENESIS, 4); // Platinum tier
        }
    }
}
