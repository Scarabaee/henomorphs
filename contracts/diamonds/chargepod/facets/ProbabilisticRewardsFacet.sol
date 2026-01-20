// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibPremiumStorage} from "../libraries/LibPremiumStorage.sol";
import {LibResourceStorage} from "../libraries/LibResourceStorage.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibGamingStorage} from "../libraries/LibGamingStorage.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {IStakingCoreFacet} from "../../staking/interfaces/IStakingInterfaces.sol";
import {StakedSpecimen} from "../../../libraries/StakingModel.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ProbabilisticRewardsFacet
 * @notice Adds critical hits, rare drops, and streak bonuses to existing action systems
 * @dev Integrates with ChargeFacet, BiopodFacet, ResourcePodFacet without duplicating logic
 */
contract ProbabilisticRewardsFacet is AccessControlBase {
    using SafeERC20 for IERC20;
    
    // ==================== EVENTS ====================
    
    event CriticalHit(address indexed user, uint256 indexed tokenId, uint256 baseReward, uint256 bonusReward);
    event RareDrop(address indexed user, uint256 indexed tokenId, uint8 dropRarity, uint256 rewardAmount);
    event StreakBonus(address indexed user, uint32 streakDays, uint16 bonusPercent);
    event PitySystemTriggered(address indexed user, uint256 actionsSinceLegendary);
    event ProbabilisticConfigUpdated(string parameter);
    
    // ==================== ERRORS ====================
    
    error InvalidRarityTier(uint8 tier);
    error InvalidProbability(uint256 value);
    error SystemNotEnabled();
    
    // Storage moved to LibPremiumStorage - no local storage definitions
    
    // ==================== INITIALIZATION ====================
    
    /**
     * @notice Initialize probabilistic rewards system
     */
    function initializeProbabilisticRewards() external onlyAuthorized {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        
        ps.probabilisticConfig = LibPremiumStorage.ProbabilisticConfig({
            criticalHitsEnabled: true,
            rareDropsEnabled: true,
            streakBonusEnabled: true,
            baseCritChance: 500,      // 5%
            maxCritChance: 4000,      // 40%
            critMultiplier: 200,      // 2x
            pityThreshold: 100,
            legendaryPityBoost: 10    // 0.1% per action
        });
        
        // Common (40% chance)
        ps.dropRarities[0] = LibPremiumStorage.DropRarity(4000, 10 ether, 30 ether, 0);
        
        // Uncommon (30% chance)
        ps.dropRarities[1] = LibPremiumStorage.DropRarity(3000, 30 ether, 80 ether, 0);
        
        // Rare (20% chance)
        ps.dropRarities[2] = LibPremiumStorage.DropRarity(2000, 80 ether, 150 ether, 1);
        
        // Epic (8% chance)
        ps.dropRarities[3] = LibPremiumStorage.DropRarity(800, 150 ether, 300 ether, 2);
        
        // Legendary (2% base chance)
        ps.dropRarities[4] = LibPremiumStorage.DropRarity(200, 500 ether, 1000 ether, 5);
        
        emit ProbabilisticConfigUpdated("initialization");
    }
    
    // ==================== ADMIN CONFIGURATION ====================
    
    /**
     * @notice Configure critical hit parameters
     */
    function setCriticalHitConfig(
        bool enabled,
        uint16 baseChance,
        uint16 maxChance,
        uint16 multiplier
    ) external onlyAuthorized {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        
        if (baseChance > 10000 || maxChance > 10000) revert InvalidProbability(baseChance);
        if (multiplier < 100) revert InvalidProbability(multiplier);
        
        ps.probabilisticConfig.criticalHitsEnabled = enabled;
        ps.probabilisticConfig.baseCritChance = baseChance;
        ps.probabilisticConfig.maxCritChance = maxChance;
        ps.probabilisticConfig.critMultiplier = multiplier;
        
        emit ProbabilisticConfigUpdated("critical hits");
    }
    
    /**
     * @notice Configure drop rarity tier
     */
    function setDropRarity(
        uint8 tier,
        uint16 chance,
        uint256 minReward,
        uint256 maxReward,
        uint8 resourceCount
    ) external onlyAuthorized {
        if (tier > 4) revert InvalidRarityTier(tier);
        if (chance > 10000) revert InvalidProbability(chance);
        
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        ps.dropRarities[tier] = LibPremiumStorage.DropRarity(chance, minReward, maxReward, resourceCount);
        
        emit ProbabilisticConfigUpdated("drop rarity");
    }
    
    /**
     * @notice Configure pity system
     */
    function setPitySystem(uint16 threshold, uint16 boost) external onlyAuthorized {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        ps.probabilisticConfig.pityThreshold = threshold;
        ps.probabilisticConfig.legendaryPityBoost = boost;
        
        emit ProbabilisticConfigUpdated("pity system");
    }
    
    // ==================== CORE MECHANICS ====================
    
    /**
     * @notice Apply probabilistic bonuses to action reward
     * @dev Called by existing action facets (Charge, Biopod, Resource)
     * @param user User performing action
     * @param tokenId Token used for action
     * @param baseReward Base reward before bonuses
     * @return totalReward Final reward with all bonuses applied
     */
    function applyProbabilisticBonuses(
        address user,
        uint256 tokenId,
        uint256 baseReward
    ) external whenNotPaused returns (uint256 totalReward) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        totalReward = baseReward;
        
        // Update streak
        _updateStreak(user);
        
        // Apply streak bonus
        if (ps.probabilisticConfig.streakBonusEnabled) {
            uint16 streakBonus = _getStreakBonus(user);
            if (streakBonus > 0) {
                uint256 bonusAmount = (baseReward * streakBonus) / 10000;
                totalReward += bonusAmount;
                emit StreakBonus(user, ps.probabilisticUserData[user].currentStreak, streakBonus);
            }
        }
        
        // Apply critical hit
        if (ps.probabilisticConfig.criticalHitsEnabled) {
            (bool isCrit, uint256 critBonus) = _rollCriticalHit(user, tokenId, totalReward);
            if (isCrit) {
                totalReward += critBonus;
                ps.probabilisticUserData[user].totalCriticalHits++;
                unchecked { ps.totalCriticalHits++; }
                emit CriticalHit(user, tokenId, baseReward, critBonus);
            }
        }
        
        // Apply rare drop
        if (ps.probabilisticConfig.rareDropsEnabled) {
            (bool hasDrop, uint8 rarity, uint256 dropReward) = _rollRareDrop(user, tokenId);
            if (hasDrop) {
                totalReward += dropReward;
                ps.probabilisticUserData[user].totalRareDrops++;
                unchecked { ps.totalRareDrops++; }
                
                if (rarity == 4) { // Legendary
                    ps.probabilisticUserData[user].actionsSinceLegendary = 0;
                    unchecked { ps.legendaryDropCount++; }
                }
                
                emit RareDrop(user, tokenId, rarity, dropReward);
            }
        }
        
        // Increment pity counter
        ps.probabilisticUserData[user].actionsSinceLegendary++;
        
        return totalReward;
    }
    
    /**
     * @notice Calculate critical hit chance for user/token
     */
    function _rollCriticalHit(
        address user,
        uint256 tokenId,
        uint256 baseReward
    ) internal view returns (bool isCrit, uint256 bonusAmount) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        uint256 chance = ps.probabilisticConfig.baseCritChance;
        
        // Level bonus: +0.1% per level (max +20%)
        uint256 combinedId = (1 << 128) | tokenId; // Assuming collection 1
        uint8 level = hs.performedCharges[combinedId].evolutionLevel;
        uint256 levelBonus = (level * 10) > 2000 ? 2000 : (level * 10);
        
        // Staking duration bonus: +0.1% per 30 days (max +5%)
        uint256 stakingDays = _getStakingDuration(tokenId) / 1 days;
        uint256 durationBonus = (stakingDays / 30) * 10;
        if (durationBonus > 500) durationBonus = 500;
        
        // Colony specialization bonus (0-10%)
        bytes32 colonyId = hs.specimenColonies[combinedId];
        uint256 colonyBonus = _getColonySpecializationBonus(colonyId);
        
        chance += levelBonus + durationBonus + colonyBonus;
        
        // Cap at max
        if (chance > ps.probabilisticConfig.maxCritChance) {
            chance = ps.probabilisticConfig.maxCritChance;
        }
        
        // Roll
        uint256 roll = _random(user, tokenId) % 10000;
        isCrit = roll < chance;
        
        if (isCrit) {
            bonusAmount = (baseReward * (ps.probabilisticConfig.critMultiplier - 100)) / 100;
        }
    }
    
    /**
     * @notice Roll for rare drop
     */
    function _rollRareDrop(
        address user,
        uint256 tokenId
    ) internal returns (bool hasDrop, uint8 rarity, uint256 reward) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        
        // Apply pity system for legendary
        uint256 legendaryBoost = 0;
        if (ps.probabilisticUserData[user].actionsSinceLegendary >= ps.probabilisticConfig.pityThreshold) {
            legendaryBoost = (ps.probabilisticUserData[user].actionsSinceLegendary - ps.probabilisticConfig.pityThreshold) 
                           * ps.probabilisticConfig.legendaryPityBoost;
            
            if (ps.probabilisticUserData[user].actionsSinceLegendary >= ps.probabilisticConfig.pityThreshold * 2) {
                // Guaranteed epic at 2x threshold
                emit PitySystemTriggered(user, ps.probabilisticUserData[user].actionsSinceLegendary);
                return (true, 3, _calculateDropReward(3));
            }
        }
        
        // Roll for drop
        uint256 roll = _random(user, tokenId) % 10000;
        uint256 cumulativeChance = 0;
        
        // Check legendary first (with pity boost)
        cumulativeChance += ps.dropRarities[4].chance + legendaryBoost;
        if (roll < cumulativeChance) {
            reward = _calculateDropReward(4);
            _awardResources(user, ps.dropRarities[4].resourceCount);
            return (true, 4, reward);
        }
        
        // Check other rarities (descending)
        for (uint8 i = 3; i > 0; i--) {
            cumulativeChance += ps.dropRarities[i].chance;
            if (roll < cumulativeChance) {
                reward = _calculateDropReward(i);
                if (ps.dropRarities[i].resourceCount > 0) {
                    _awardResources(user, ps.dropRarities[i].resourceCount);
                }
                return (true, i, reward);
            }
        }
        
        // Common drop
        cumulativeChance += ps.dropRarities[0].chance;
        if (roll < cumulativeChance) {
            return (true, 0, _calculateDropReward(0));
        }
        
        return (false, 0, 0);
    }
    
    /**
     * @notice Calculate drop reward amount
     */
    function _calculateDropReward(uint8 rarity) internal view returns (uint256) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.DropRarity memory drop = ps.dropRarities[rarity];
        
        if (drop.minReward == drop.maxReward) return drop.minReward;
        
        uint256 range = drop.maxReward - drop.minReward;
        uint256 randomValue = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao))) % range;
        
        return drop.minReward + randomValue;
    }
    
    /**
     * @notice Award random resources to user
     */
    function _awardResources(address user, uint8 count) internal {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        // Apply decay before awarding resources
        LibResourceStorage.applyResourceDecay(user);

        for (uint8 i = 0; i < count; i++) {
            uint8 resourceType = uint8(_random(user, i) % 4);
            uint256 amount = 10 + (_random(user, i + 100) % 90); // 10-100 units
            rs.userResources[user][resourceType] += amount;
        }
    }
    
    // ==================== STREAK SYSTEM ====================
    
    /**
     * @notice Update user's daily streak
     */
    function _updateStreak(address user) internal {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        uint32 today = uint32(block.timestamp / 86400);
        
        if (ps.probabilisticUserData[user].lastActionDay == 0) {
            // First action
            ps.probabilisticUserData[user].currentStreak = 1;
            ps.probabilisticUserData[user].longestStreak = 1;
        } else if (ps.probabilisticUserData[user].lastActionDay == today - 1) {
            // Consecutive day
            ps.probabilisticUserData[user].currentStreak++;
            if (ps.probabilisticUserData[user].currentStreak > ps.probabilisticUserData[user].longestStreak) {
                ps.probabilisticUserData[user].longestStreak = ps.probabilisticUserData[user].currentStreak;
            }
        } else if (ps.probabilisticUserData[user].lastActionDay != today) {
            // Streak broken
            ps.probabilisticUserData[user].currentStreak = 1;
        }
        
        ps.probabilisticUserData[user].lastActionDay = today;
    }
    
    /**
     * @notice Get streak bonus percentage
     */
    function _getStreakBonus(address user) internal view returns (uint16) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        uint32 streak = ps.probabilisticUserData[user].currentStreak;
        
        if (streak >= 90) return 5000;  // +50% for 90+ days
        if (streak >= 30) return 2500;  // +25% for 30+ days
        if (streak >= 14) return 1500;  // +15% for 14+ days
        if (streak >= 7) return 1000;   // +10% for 7+ days
        if (streak >= 3) return 500;    // +5% for 3+ days
        
        return 0;
    }
    
    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @notice Get user probabilistic data
     */
    function getUserProbabilisticData(address user) external view returns (
        uint32 currentStreak,
        uint32 longestStreak,
        uint16 actionsSinceLegendary,
        uint256 totalCrits,
        uint256 totalDrops,
        uint16 nextStreakBonus
    ) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.UserProbabilisticData memory data = ps.probabilisticUserData[user];
        
        return (
            data.currentStreak,
            data.longestStreak,
            data.actionsSinceLegendary,
            data.totalCriticalHits,
            data.totalRareDrops,
            _getStreakBonus(user)
        );
    }
    
    /**
     * @notice Get probabilistic rewards system statistics
     */
    function getProbabilisticStats() external view returns (
        uint256 totalCrits,
        uint256 totalDrops,
        uint256 legendaryDrops
    ) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        return (ps.totalCriticalHits, ps.totalRareDrops, ps.legendaryDropCount);
    }
    
    // ==================== HELPERS ====================
    
    function _random(address user, uint256 nonce) internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            user,
            nonce
        )));
    }
    
    /**
     * @notice Get staking duration for a token from external staking diamond
     * @param tokenId Token ID to query
     * @return duration Staking duration in seconds (0 if not staked or error)
     */
    function _getStakingDuration(uint256 tokenId) internal view returns (uint256 duration) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        
        // Get staking system address
        address stakingSystem = rs.config.stakingSystemAddress;
        if (stakingSystem == address(0)) {
            return 0;
        }
        
        // Call external staking diamond (assuming collection 1)
        try IStakingCoreFacet(stakingSystem).getStakedTokenData(1, tokenId) returns (
            StakedSpecimen memory specimen
        ) {
            if (!specimen.staked || specimen.stakedSince == 0) {
                return 0;
            }
            duration = block.timestamp - specimen.stakedSince;
        } catch {
            return 0;
        }
    }
    
    /**
     * @notice Get colony specialization bonus based on territory types
     * @param colonyId Colony ID to query
     * @return bonus Bonus in basis points (0-1000 = 0-10%)
     */
    function _getColonySpecializationBonus(bytes32 colonyId) internal view returns (uint256 bonus) {
        if (colonyId == bytes32(0)) {
            return 0;
        }
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        // Get colony's territories
        uint256[] memory territoryIds = cws.colonyTerritories[colonyId];
        if (territoryIds.length == 0) {
            return 0;
        }
        
        // Count territory types for specialization detection
        uint8[6] memory typeCounts; // Index 0 unused, 1-5 for territory types
        uint256 totalTerritories = 0;
        
        for (uint256 i = 0; i < territoryIds.length; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[territoryIds[i]];
            if (territory.active && territory.territoryType > 0 && territory.territoryType <= 5) {
                typeCounts[territory.territoryType]++;
                totalTerritories++;
            }
        }
        
        if (totalTerritories == 0) {
            return 0;
        }
        
        // Find dominant territory type count
        uint8 dominantCount = 0;
        for (uint8 t = 1; t <= 5; t++) {
            if (typeCounts[t] > dominantCount) {
                dominantCount = typeCounts[t];
            }
        }
        
        // Calculate specialization percentage (how focused the colony is)
        // 100% same type = 10% bonus, 50% = 5% bonus, etc.
        uint256 specializationPercent = (dominantCount * 100) / totalTerritories;
        
        // Bonus in basis points: 0-1000 (0-10%)
        bonus = specializationPercent * 10; // Max 1000 (10%)
        
        // Cap at 1000 basis points (10%)
        if (bonus > 1000) {
            bonus = 1000;
        }
    }
}
