// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibGamingStorage} from "../libraries/LibGamingStorage.sol";
import {LibAchievementStorage} from "../libraries/LibAchievementStorage.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DailyChallengeSet, DailyChallenge, AchievementProgress, FlashEvent, FlashParticipation, RankingConfig, RankingEntry} from "../../libraries/GamingModel.sol";
import {ChargeSeason} from "../../libraries/HenomorphsModel.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {IExternalCollection, IRankingFacet} from "../interfaces/IStakingInterfaces.sol";

/**
 * @title ChargeClaimFacet - FIXED VERSION
 * @notice Facet for handling reward claiming operations - synchronized with system
 * @dev Fixed integration issues with achievement system and ranking rewards
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract ChargeClaimFacet is AccessControlBase {
    using Math for uint256;

    // Base achievement reward in ZICO
    uint256 private constant BASE_ACHIEVEMENT_ZICO = 1e18;
    
    // Events
    event DailyChallengeRewardClaimed(address indexed user, uint256 challengeIndex, uint256 reward);
    event BonusRewardClaimed(address indexed user, uint256 bonusReward);
    event AchievementRewardClaimed(address indexed user, uint256 indexed achievementId, uint256 reward);
    event FlashEventRewardClaimed(address indexed user, uint256 eventId, uint256 reward);
    event RankingRewardClaimed(address indexed user, uint256 indexed rankingId, uint256 rank, uint256 reward);
    event SeasonRewardClaimed(address indexed user, uint256 indexed seasonId, uint256 reward);
    event BatchRewardsClaimed(address indexed user, uint256 totalAmount, uint256 rewardsCount);

    // Errors
    error InvalidCallData();
    error ChallengeNotCompleted(uint8 challengeIndex);
    error RewardAlreadyClaimed();
    error AchievementNotFound(uint256 achievementId);
    error AchievementNotEarned(uint256 achievementId);
    error AchievementOnCooldown(uint256 achievementId, uint256 cooldownEnd);
    error FlashEventNotActive();
    error FlashEventNotParticipated();
    error InsufficientTreasuryBalance();
    error NotQualifiedForReward();
    error SeasonNotActive();
    error RankingNotFound(uint256 rankingId);
    error TreasuryTransferFailed();

    // =================== DAILY CHALLENGE REWARD FUNCTIONS ===================

    /**
     * @notice Claims daily challenge rewards with enhanced calculation
     * @param challengeIndex Index of challenge to claim (0-2, or 3 for bonus)
     */
    function claimDailyChallengeReward(uint8 challengeIndex) external nonReentrant whenNotPaused {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        address user = LibMeta.msgSender();
        DailyChallengeSet storage challengeSet = gs.dailyChallenges[user];
        
        uint32 today = uint32(block.timestamp / 86400);
        if (challengeSet.dayIssued != today) {
            revert InvalidCallData();
        }
        
        if (challengeIndex < 3) {
            // Claim individual challenge
            DailyChallenge storage challenge = challengeSet.challenges[challengeIndex];
            if (!challenge.completed) {
                revert ChallengeNotCompleted(challengeIndex);
            }
            
            if (challenge.claimed) {
                revert RewardAlreadyClaimed();
            }
            
            challenge.claimed = true;
            
            // Enhanced reward calculation using existing user data
            uint256 finalReward = _calculateEnhancedReward(
                user, 
                challenge.rewardAmount, 
                challenge.difficulty
            );
            
            // Process daily challenge fee
            LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
            LibFeeCollection.processOperationFee(hs.chargeFees.claimRewardsFee, user);
            
            // Transfer reward from treasury
            _transferRewardFromTreasury(user, finalReward, "daily_challenge");
            
            emit DailyChallengeRewardClaimed(user, challengeIndex, finalReward);
            
        } else if (challengeIndex == 3) {
            // Claim bonus reward for completing all challenges
            if (challengeSet.completedCount != 3) {
                revert InvalidCallData();
            }
            
            // Check if all individual rewards claimed
            bool allClaimed = true;
            for (uint i = 0; i < 3; i++) {
                if (!challengeSet.challenges[i].claimed) {
                    allClaimed = false;
                    break;
                }
            }
            
            if (!allClaimed) {
                revert InvalidCallData();
            }
            
            if (challengeSet.bonusClaimed) {
                revert RewardAlreadyClaimed();
            }
            
            challengeSet.bonusClaimed = true;
            
            // Calculate final bonus with streak multiplier and enhancements
            uint256 baseBonus = challengeSet.bonusReward + challengeSet.streakBonus;
            uint256 finalBonus = _calculateEnhancedReward(
                user, 
                baseBonus, 
                challengeSet.difficultyLevel
            );
            
            // Transfer bonus reward
            _transferRewardFromTreasury(user, finalBonus, "daily_challenge_bonus");
            
            emit BonusRewardClaimed(user, finalBonus);
        } else {
            revert InvalidCallData();
        }
    }

    /**
     * @notice Claims all daily challenge rewards in one transaction
     * @return totalClaimed Total amount claimed
     * @return rewardsClaimed Number of individual rewards claimed
     */
    function claimAllDailyChallengeRewards() external nonReentrant whenNotPaused returns (uint256 totalClaimed, uint256 rewardsClaimed) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        address user = LibMeta.msgSender();
        DailyChallengeSet storage challengeSet = gs.dailyChallenges[user];
        
        uint32 today = uint32(block.timestamp / 86400);
        if (challengeSet.dayIssued != today) {
            return (0, 0);
        }
        
        totalClaimed = 0;
        rewardsClaimed = 0;
        
        // Claim individual challenges
        for (uint8 i = 0; i < 3; i++) {
            DailyChallenge storage challenge = challengeSet.challenges[i];
            if (challenge.completed && !challenge.claimed) {
                challenge.claimed = true;
                
                uint256 enhancedReward = _calculateEnhancedReward(
                    user, 
                    challenge.rewardAmount, 
                    challenge.difficulty
                );
                
                totalClaimed += enhancedReward;
                rewardsClaimed++;
                
                _transferRewardFromTreasury(user, enhancedReward, "daily_challenge_batch");
                emit DailyChallengeRewardClaimed(user, i, enhancedReward);
            }
        }
        
        // Check if can claim bonus
        if (challengeSet.completedCount == 3 && !challengeSet.bonusClaimed) {
            bool allClaimed = true;
            for (uint i = 0; i < 3; i++) {
                if (!challengeSet.challenges[i].claimed) {
                    allClaimed = false;
                    break;
                }
            }
            
            if (allClaimed) {
                challengeSet.bonusClaimed = true;
                uint256 baseBonus = challengeSet.bonusReward + challengeSet.streakBonus;
                uint256 enhancedBonus = _calculateEnhancedReward(
                    user, 
                    baseBonus, 
                    challengeSet.difficultyLevel
                );
                
                totalClaimed += enhancedBonus;
                rewardsClaimed++;
                
                _transferRewardFromTreasury(user, enhancedBonus, "daily_challenge_bonus_batch");
                emit BonusRewardClaimed(user, enhancedBonus);
            }
        }
        
        if (rewardsClaimed > 0) {
            // Process single fee for batch operation
            LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
            LibFeeCollection.processOperationFee(hs.chargeFees.claimRewardsFee, user);
            emit BatchRewardsClaimed(user, totalClaimed, rewardsClaimed);
        }
        
        return (totalClaimed, rewardsClaimed);
    }

    // =================== ACHIEVEMENT REWARD FUNCTIONS - FIXED ===================

    /**
     * @notice Claims achievement reward - FIXED to use proper achievement system
     * @param achievementId Achievement ID to claim
     */
    function claimAchievementReward(uint256 achievementId) external nonReentrant whenNotPaused {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        address user = LibMeta.msgSender();
        
        // Check if user has earned the achievement
        AchievementProgress storage progress = gs.userAchievements[user][achievementId];
        if (!progress.hasEarned) {
            revert AchievementNotEarned(achievementId);
        }
        
        // Check if already claimed
        if (progress.claimedAt > 0) {
            revert RewardAlreadyClaimed();
        }
        
        // Mark as claimed
        progress.claimedAt = uint32(block.timestamp);
        progress.claimCount++;
        
        // Process achievement claim fee
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibFeeCollection.processOperationFee(hs.chargeFees.claimRewardsFee, user);
        
        // Calculate reward based on achievement type - FIXED
        uint256 baseReward = _getAchievementBaseReward(achievementId);
        uint256 finalReward = _calculateEnhancedReward(
            user, 
            baseReward, 
            _getAchievementDifficulty(achievementId)
        );
        
        // Transfer reward from treasury
        _transferRewardFromTreasury(user, finalReward, "achievement");
        
        emit AchievementRewardClaimed(user, achievementId, finalReward);
    }

    /**
     * @notice Claims multiple achievement rewards in batch - FIXED
     * @param achievementIds Array of achievement IDs to claim
     * @return totalClaimed Total amount claimed
     * @return successfulClaims Number of successful claims
     */
    function claimMultipleAchievementRewards(uint256[] calldata achievementIds) 
        external 
        nonReentrant 
        whenNotPaused 
        returns (uint256 totalClaimed, uint256 successfulClaims) 
    {
        if (achievementIds.length == 0 || achievementIds.length > 10) {
            revert InvalidCallData();
        }
        
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        address user = LibMeta.msgSender();
        
        totalClaimed = 0;
        successfulClaims = 0;
        
        for (uint i = 0; i < achievementIds.length; i++) {
            uint256 achievementId = achievementIds[i];
            
            // Check if user has earned it and not claimed
            AchievementProgress storage progress = gs.userAchievements[user][achievementId];
            if (!progress.hasEarned || progress.claimedAt > 0) {
                continue;
            }
            
            // Claim the achievement
            progress.claimedAt = uint32(block.timestamp);
            progress.claimCount++;
            
            uint256 baseReward = _getAchievementBaseReward(achievementId);
            uint256 finalReward = _calculateEnhancedReward(
                user, 
                baseReward, 
                _getAchievementDifficulty(achievementId)
            );
            
            totalClaimed += finalReward;
            successfulClaims++;
            
            _transferRewardFromTreasury(user, finalReward, "achievement_batch");
            emit AchievementRewardClaimed(user, achievementId, finalReward);
        }
        
        if (successfulClaims > 0) {
            // Process single fee for batch operation
            LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
            LibFeeCollection.processOperationFee(hs.chargeFees.claimRewardsFee, user);
            emit BatchRewardsClaimed(user, totalClaimed, successfulClaims);
        }
        
        return (totalClaimed, successfulClaims);
    }

    // =================== FLASH EVENT REWARD FUNCTIONS ===================

    /**
     * @notice Claims flash event reward with enhanced calculation
     * @param eventId Flash event ID (use 0 for current event)
     */
    function claimFlashEventReward(uint256 eventId) external nonReentrant whenNotPaused {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        address user = LibMeta.msgSender();
        
        // Use current event if eventId is 0
        if (eventId == 0) {
            eventId = gs.flashEventCounter;
        }
        
        // Check if flash event was active
        FlashEvent storage flashEvent = gs.currentFlashEvent;
        if (eventId == gs.flashEventCounter && !flashEvent.active && flashEvent.endTime == 0) {
            revert FlashEventNotActive();
        }
        
        // Check user participation
        FlashParticipation storage participation = gs.flashParticipations[user];
        if (participation.actionsPerformed == 0) {
            revert FlashEventNotParticipated();
        }
        
        if (!participation.qualified) {
            revert NotQualifiedForReward();
        }
        
        if (participation.rewardsClaimed) {
            revert RewardAlreadyClaimed();
        }
        
        // Mark as claimed
        participation.rewardsClaimed = true;
        
        uint256 baseReward = participation.rewardsEarned;
        
        // Apply performance bonus based on rank if available
        if (participation.rank > 0 && participation.rank <= 10) {
            uint256 rankBonus = baseReward * (11 - participation.rank) / 10;
            baseReward += rankBonus;
        }
        
        // Enhanced reward calculation
        uint256 finalReward = _calculateEnhancedReward(
            user, 
            baseReward, 
            uint8(flashEvent.difficultyModifier / 20)
        );

        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibFeeCollection.processOperationFee(hs.chargeFees.claimRewardsFee, user);
        
        // Transfer reward from treasury
        _transferRewardFromTreasury(user, finalReward, "flash_event");
        
        emit FlashEventRewardClaimed(user, eventId, finalReward);
    }

    // =================== RANKING REWARD FUNCTIONS - FIXED ===================

    /**
     * @notice Claims ranking reward - FIXED to use ActionRankingFacet
     * @param rankingId Ranking ID
     */
    function claimRankingReward(uint256 rankingId) external nonReentrant whenNotPaused {
        address user = LibMeta.msgSender();
        
        // Get ranking data from ActionRankingFacet
        IRankingFacet rankingFacet = IRankingFacet(address(this));
        
        try rankingFacet.getRankingConfig(rankingId) returns (RankingConfig memory config) {
            // Check if ranking has ended
            if (config.endTime > block.timestamp && config.endTime > 0) {
                revert InvalidCallData();
            }
            
            // Get user's ranking entry
            RankingEntry memory entry = rankingFacet.getUserRankingEntry(rankingId, user);
            
            if (entry.rank == 0 || entry.score == 0) {
                revert NotQualifiedForReward();
            }
            
            // Check if already claimed
            if (entry.rewardClaimed) {
                revert RewardAlreadyClaimed();
            }
            
            // Calculate reward using config data
            uint256 baseReward = _calculateRankingRewardFromConfig(entry.rank, config);
            
            if (baseReward == 0) {
                revert NotQualifiedForReward();
            }
            
            // Enhanced reward calculation
            uint256 finalReward = _calculateEnhancedReward(
                user, 
                baseReward, 
                5 // High difficulty for rankings
            );
            
            // Mark as claimed in gaming storage
            LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
            gs.rankings[rankingId][user].rewardClaimed = true;

            LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
            LibFeeCollection.processOperationFee(hs.chargeFees.claimRewardsFee, user);
            
            // Transfer reward from treasury
            _transferRewardFromTreasury(user, finalReward, "ranking");
            
            emit RankingRewardClaimed(user, rankingId, entry.rank, finalReward);
            
        } catch {
            revert RankingNotFound(rankingId);
        }
    }

    // =================== SEASON REWARD FUNCTIONS ===================

    /**
     * @notice Claims season participation reward
     * @param seasonId Season ID (use 0 for current season)
     */
    function claimSeasonReward(uint256 seasonId) external nonReentrant whenNotPaused {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        address user = LibMeta.msgSender();
        
        // Use current season if seasonId is 0
        if (seasonId == 0) {
            seasonId = hs.seasonCounter;
        }
        
        // Check if season has ended
        if (seasonId == hs.seasonCounter && hs.currentSeason.active) {
            if (hs.currentSeason.endTime > block.timestamp) {
                revert SeasonNotActive();
            }
        }
        
        // Check user participation
        uint32 userSeasonPoints = hs.operatorSeasonPoints[user][uint32(seasonId)];
        
        if (userSeasonPoints == 0) {
            revert NotQualifiedForReward();
        }
        
        // Check if reward already claimed
        if (gs.userSeasonRewardsClaimed[user][uint32(seasonId)]) {
            revert RewardAlreadyClaimed();
        }
        
        // Calculate base reward based on participation
        uint256 baseReward = _calculateSeasonReward(userSeasonPoints, seasonId);
        
        if (baseReward == 0) {
            revert NotQualifiedForReward();
        }
        
        // Enhanced reward calculation
        uint256 finalReward = _calculateEnhancedReward(
            user, 
            baseReward, 
            4 // Medium-high difficulty for seasons
        );
        
        // Mark as claimed
        gs.userSeasonRewardsClaimed[user][uint32(seasonId)] = true;
        
        // Process season reward fee
        LibFeeCollection.processOperationFee(hs.chargeFees.claimRewardsFee, user);
        
        // Transfer reward from treasury
        _transferRewardFromTreasury(user, finalReward, "season");
        
        emit SeasonRewardClaimed(user, seasonId, finalReward);
    }

    // =================== VIEW FUNCTIONS - FIXED ===================

    /**
     * @notice Gets claimable achievement rewards for a user - FIXED
     * @param user User address
     * @return achievementIds Array of claimable achievement IDs
     * @return rewardAmounts Array of corresponding reward amounts
     */
    function getClaimableAchievementRewards(address user) 
        external 
        view 
        returns (uint256[] memory achievementIds, uint256[] memory rewardAmounts) 
    {
        // Get recent achievements from ActionRankingFacet
        IRankingFacet rankingFacet = IRankingFacet(address(this));
        
        try rankingFacet.getUserRecentAchievements(user, 20) returns (uint256[] memory recent, uint8 count) {
            // Count claimable from recent achievements
            uint256 claimableCount = 0;
            for (uint8 i = 0; i < count; i++) {
                uint256 achievementId = recent[i];
                if (_isAchievementClaimable(user, achievementId)) {
                    claimableCount++;
                }
            }
            
            achievementIds = new uint256[](claimableCount);
            rewardAmounts = new uint256[](claimableCount);
            
            uint256 index = 0;
            for (uint8 i = 0; i < count; i++) {
                uint256 achievementId = recent[i];
                if (_isAchievementClaimable(user, achievementId)) {
                    achievementIds[index] = achievementId;
                    
                    uint256 baseReward = _getAchievementBaseReward(achievementId);
                    rewardAmounts[index] = _calculateEnhancedReward(
                        user, 
                        baseReward, 
                        _getAchievementDifficulty(achievementId)
                    );
                    index++;
                }
            }
        } catch {
            // Fallback to empty arrays
            achievementIds = new uint256[](0);
            rewardAmounts = new uint256[](0);
        }
    }

    // =================== INTERNAL HELPER FUNCTIONS - FIXED ===================

    /**
     * @dev Get achievement base reward based on ID - FIXED
     */
    function _getAchievementBaseReward(uint256 achievementId) internal pure returns (uint256) {
        if (achievementId >= 1000 && achievementId <= 1002) {
            // Streak achievements: 2, 5, 10 ZICO
            if (achievementId == 1000) return BASE_ACHIEVEMENT_ZICO * 2;      // 2 ZICO
            if (achievementId == 1001) return BASE_ACHIEVEMENT_ZICO * 5;      // 5 ZICO
            if (achievementId == 1002) return BASE_ACHIEVEMENT_ZICO * 10;     // 10 ZICO
        } else if (achievementId >= 2000 && achievementId <= 2002) {
            // Action achievements: 3, 7, 15 ZICO
            if (achievementId == 2000) return BASE_ACHIEVEMENT_ZICO * 3;      // 3 ZICO
            if (achievementId == 2001) return BASE_ACHIEVEMENT_ZICO * 7;      // 7 ZICO
            if (achievementId == 2002) return BASE_ACHIEVEMENT_ZICO * 15;     // 15 ZICO
        } else if (achievementId >= 3000 && achievementId <= 3001) {
            // Social achievements: 5, 10 ZICO
            if (achievementId == 3000) return BASE_ACHIEVEMENT_ZICO * 5;      // 5 ZICO
            if (achievementId == 3001) return BASE_ACHIEVEMENT_ZICO * 10;     // 10 ZICO
        } else if (achievementId >= 4000 && achievementId <= 4001) {
            // Challenge achievements: 10, 20 ZICO
            if (achievementId == 4000) return BASE_ACHIEVEMENT_ZICO * 10;     // 10 ZICO
            if (achievementId == 4001) return BASE_ACHIEVEMENT_ZICO * 20;     // 20 ZICO
        }
        
        return BASE_ACHIEVEMENT_ZICO; // Default: 1 ZICO
    }

    /**
     * @dev Get achievement difficulty based on ID - FIXED
     */
    function _getAchievementDifficulty(uint256 achievementId) internal pure returns (uint8) {
        if (achievementId >= 1000 && achievementId <= 1002) {
            // Streak achievements: 3, 4, 5
            return uint8(3 + (achievementId - 1000));
        } else if (achievementId >= 2000 && achievementId <= 2002) {
            // Action achievements: 2, 3, 4
            return uint8(2 + (achievementId - 2000));
        } else if (achievementId >= 3000 && achievementId <= 3001) {
            // Social achievements: 3, 4
            return uint8(3 + (achievementId - 3000));
        } else if (achievementId >= 4000 && achievementId <= 4001) {
            // Challenge achievements: 4, 5
            return uint8(4 + (achievementId - 4000));
        } else {
            return 3; // Default difficulty
        }
    }

    /**
     * @dev Calculate ranking reward from config - FIXED
     */
    function _calculateRankingRewardFromConfig(uint256 rank, RankingConfig memory config) internal pure returns (uint256) {
        // Use rewardTiers from config if available
        if (config.rewardTiers.length > 0) {
            uint256 tierIndex = rank > config.rewardTiers.length ? config.rewardTiers.length - 1 : rank - 1;
            return config.rewardTiers[tierIndex];
        }
        
        // Fallback to calculated reward
        return _calculateRankingReward(rank, config.rankingType);
    }

    /**
     * @dev Enhanced reward calculation using existing user data
     */
    function _calculateEnhancedReward(
        address user,
        uint256 baseReward,
        uint8 difficulty
    ) internal view returns (uint256 enhancedReward) {
        if (baseReward == 0) return 0;
        
        try this._safeCalculateEnhancedReward(user, baseReward, difficulty) returns (uint256 result) {
            return result;
        } catch {
            return baseReward;
        }
    }

    /**
     * @dev Safe wrapper for enhanced reward calculation
     */
    function _safeCalculateEnhancedReward(
        address user,
        uint256 baseReward,
        uint8 difficulty
    ) external view returns (uint256) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        uint256 enhancedReward = baseReward;
        
        // Apply current season bonus if active
        if (hs.currentSeason.active) {
            enhancedReward = enhancedReward * (100 + hs.currentSeason.chargeBoostPercentage) / 100;
        }
        
        // Apply global multiplier
        if (gs.globalGameState.globalMultiplier > 100) {
            enhancedReward = enhancedReward * gs.globalGameState.globalMultiplier / 100;
        }
        
        // Apply streak multiplier from user engagement
        if (gs.userEngagement[user].currentStreak > 7) {
            uint256 streakBonus = Math.min(gs.userEngagement[user].currentStreak / 7, 5);
            enhancedReward = enhancedReward * (100 + streakBonus * 10) / 100;
        }
        
        // Simple difficulty bonus
        if (difficulty > 3) {
            enhancedReward = enhancedReward * (100 + (difficulty - 3) * 10) / 100;
        }
        
        return enhancedReward;
    }

    /**
     * @dev Transfers reward from treasury to user
     */
    function _transferRewardFromTreasury(address user, uint256 amount, string memory reason) internal {
        if (amount == 0) return;
        
        // Check treasury balance
        if (!LibFeeCollection.checkTreasuryBalance(amount)) {
            revert InsufficientTreasuryBalance();
        }
        
        // Transfer from treasury to user
        LibFeeCollection.transferFromTreasury(user, amount, reason);
    }

    /**
     * @dev Checks if achievement is claimable by user - FIXED
     */
    function _isAchievementClaimable(address user, uint256 achievementId) internal view returns (bool) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        AchievementProgress storage progress = gs.userAchievements[user][achievementId];
        
        // Must be earned and not claimed
        return progress.hasEarned && progress.claimedAt == 0;
    }

    /**
     * @dev Calculates ranking reward based on position - kept for compatibility
     */
    function _calculateRankingReward(uint256 rank, uint8 rankingType) internal pure returns (uint256) {
        uint256 baseReward;
        
        // Set base rewards in ZICO based on ranking type
        if (rankingType == 1) {          // Global ranking
            baseReward = 10e18;          // 10 ZICO base
        } else if (rankingType == 2) {   // Season ranking
            baseReward = 5e18;           // 5 ZICO base
        } else if (rankingType == 3) {   // Weekly ranking
            baseReward = 2e18;           // 2 ZICO base
        } else {                         // Daily ranking
            baseReward = 1e18;           // 1 ZICO base
        }
        
        // Apply rank multipliers
        if (rank == 1) {
            return baseReward * 10;      // 1st place: 10x multiplier
        } else if (rank <= 3) {
            return baseReward * 5;       // 2nd-3rd place: 5x multiplier
        } else if (rank <= 10) {
            return baseReward * 3;       // 4th-10th place: 3x multiplier
        } else if (rank <= 50) {
            return baseReward * 2;       // 11th-50th place: 2x multiplier
        } else if (rank <= 100) {
            return baseReward;           // 51st-100th place: 1x multiplier
        } else {
            return 0;                    // No reward below rank 100
        }
    }
    
    /**
     * @dev Calculates season reward based on participation
     */
    function _calculateSeasonReward(uint32 seasonPoints, uint256) internal pure returns (uint256) {
        uint256 baseReward = 1e18; // 1 ZICO base
        
        if (seasonPoints >= 2000) {
            return baseReward * 50;      // 50 ZICO for top performers
        } else if (seasonPoints >= 1000) {
            return baseReward * 25;      // 25 ZICO for high performers
        } else if (seasonPoints >= 500) {
            return baseReward * 10;      // 10 ZICO for regular performers
        } else if (seasonPoints >= 200) {
            return baseReward * 5;       // 5 ZICO for active users
        } else if (seasonPoints >= 100) {
            return baseReward * 2;       // 2 ZICO for participants
        } else if (seasonPoints >= 50) {
            return baseReward;           // 1 ZICO for basic participation
        } else {
            return 0;                    // No reward for minimal participation
        }
    }

    // =================== REMAINING VIEW FUNCTIONS ===================

    /**
     * @notice Gets claimable daily challenge rewards for a user
     */
    function getClaimableDailyChallengeRewards(address user) 
        external 
        view 
        returns (uint256[4] memory claimableRewards, uint256 totalClaimable) 
    {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        DailyChallengeSet storage challengeSet = gs.dailyChallenges[user];
        
        uint32 today = uint32(block.timestamp / 86400);
        
        if (challengeSet.dayIssued == today) {
            // Check individual challenges
            for (uint i = 0; i < 3; i++) {
                if (challengeSet.challenges[i].completed && !challengeSet.challenges[i].claimed) {
                    claimableRewards[i] = _calculateEnhancedReward(
                        user, 
                        challengeSet.challenges[i].rewardAmount, 
                        challengeSet.challenges[i].difficulty
                    );
                    totalClaimable += claimableRewards[i];
                }
            }
            
            // Check bonus reward (only if all individual challenges are completed)
            if (challengeSet.completedCount == 3 && !challengeSet.bonusClaimed) {
                uint256 baseBonus = challengeSet.bonusReward + challengeSet.streakBonus;
                claimableRewards[3] = _calculateEnhancedReward(
                    user, 
                    baseBonus, 
                    challengeSet.difficultyLevel
                );
                totalClaimable += claimableRewards[3];
            }
        }
    }

    /**
     * @notice Gets user's flash event participation and claimable status
     */
    function getFlashEventRewardStatus(address user) 
        external 
        view 
        returns (bool participated, bool qualified, uint256 rewardAmount, bool alreadyClaimed) 
    {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        
        participated = gs.flashParticipations[user].actionsPerformed > 0;
        qualified = gs.flashParticipations[user].qualified;
        alreadyClaimed = gs.flashParticipations[user].rewardsClaimed;
        
        if (qualified && !alreadyClaimed) {
            uint256 baseReward = gs.flashParticipations[user].rewardsEarned;
            
            // Calculate potential rank bonus
            if (gs.flashParticipations[user].rank > 0 && gs.flashParticipations[user].rank <= 10) {
                uint256 rankBonus = baseReward * (11 - gs.flashParticipations[user].rank) / 10;
                baseReward += rankBonus;
            }
            
            rewardAmount = _calculateEnhancedReward(
                user, 
                baseReward, 
                uint8(gs.currentFlashEvent.difficultyModifier / 20)
            );
        }
    }

    /**
     * @notice Gets treasury balance for rewards
     */
    function getTreasuryBalance() external view returns (uint256 balance) {
        return LibFeeCollection.getTreasuryBalance();
    }

    /**
     * @notice Gets comprehensive claimable rewards summary for user
     */
    function getClaimableRewardsSummary(address user) 
        external 
        view 
        returns (
            uint256 dailyChallengeAmount,
            uint256 achievementAmount,
            uint256 flashEventAmount,
            uint256 seasonAmount,
            uint256 totalAmount
        ) 
    {
        // Get daily challenge rewards
        (, uint256 dailyTotal) = this.getClaimableDailyChallengeRewards(user);
        dailyChallengeAmount = dailyTotal;
        
        // Get achievement rewards
        (, uint256[] memory achievementRewards) = this.getClaimableAchievementRewards(user);
        for (uint i = 0; i < achievementRewards.length; i++) {
            achievementAmount += achievementRewards[i];
        }
        
        // Get flash event rewards
        (, bool qualified, uint256 flashReward, bool flashClaimed) = this.getFlashEventRewardStatus(user);
        if (qualified && !flashClaimed) {
            flashEventAmount = flashReward;
        }
        
        // Calculate season rewards
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        uint32 userSeasonPoints = hs.operatorSeasonPoints[user][hs.seasonCounter];
        if (userSeasonPoints > 0 && !gs.userSeasonRewardsClaimed[user][hs.seasonCounter]) {
            uint256 baseSeasonReward = _calculateSeasonReward(userSeasonPoints, hs.seasonCounter);
            seasonAmount = _calculateEnhancedReward(user, baseSeasonReward, 4);
        }
        
        totalAmount = dailyChallengeAmount + achievementAmount + flashEventAmount + seasonAmount;
    }
}