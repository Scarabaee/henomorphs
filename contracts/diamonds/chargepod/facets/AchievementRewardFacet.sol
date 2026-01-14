// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibPremiumStorage} from "../libraries/LibPremiumStorage.sol";
import {LibResourceStorage} from "../libraries/LibResourceStorage.sol";
import {LibGamingStorage} from "../libraries/LibGamingStorage.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Interface for mintable reward token (YLW)
 */
interface IRewardToken is IERC20 {
    function mint(address to, uint256 amount, string calldata reason) external;
}

/**
 * @notice Achievement NFT interface (HenomorphsAchievements compatible)
 */
interface IAchievementNFT {
    function mintAchievement(address to, uint256 achievementId, uint8 tier) external returns (uint256 tokenId);
    function upgradeAchievementTier(address user, uint256 achievementId, uint8 newTier) external;
    function updateProgress(address user, uint256 achievementId, uint256 newProgress) external;
    // Note: tier is AchievementTier enum in HenomorphsAchievements (uint8 compatible)
    function hasAchievement(address user, uint256 achievementId, uint8 tier) external view returns (bool);
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

/**
 * @title AchievementRewardFacet
 * @notice Extends existing achievement system with NFT minting and resource rewards
 * @dev Builds on LibGamingStorage achievement tracking with LibPremiumStorage rewards
 * @custom:version 2.0.0 - Refactored to use LibPremiumStorage (Diamond Pattern compliant)
 */
contract AchievementRewardFacet is AccessControlBase {
    using SafeERC20 for IERC20;
    
    // ==================== EVENTS ====================

    event AchievementAwarded(address indexed user, uint256 indexed achievementId, uint8 tier);
    event AchievementClaimed(address indexed user, uint256 indexed achievementId, uint256 tokenId, uint256 tokenReward, uint256 resourceReward);
    
    // ==================== ERRORS ====================
    
    error AchievementNotAwarded(uint256 achievementId);
    error AchievementAlreadyClaimed(uint256 achievementId);
    error InvalidAchievementTier(uint8 tier);
    error AchievementNotConfigured(uint256 achievementId);
    error InvalidResourceType(uint8 resourceType);
    error NFTMintFailed(uint256 achievementId);
    
    // Storage moved to LibPremiumStorage - no local storage definitions
    
    // ==================== INITIALIZATION ====================
    
    /**
     * @notice Initialize achievement reward system
     * @param nftContract Achievement NFT contract
     */
    function initializeAchievementRewards(address nftContract) external onlyAuthorized {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        ps.achievementNFT = nftContract;
    }
    
    // ==================== ADMIN CONFIGURATION ====================
    
    /**
     * @notice Configure rewards for achievement
     * @param achievementId Achievement identifier
     * @param tokenReward Token reward amount
     * @param resourceReward Resource amount
     * @param resourceType Resource type (0-3)
     * @param nftEnabled Whether to mint NFT
     * @param minTier Minimum tier required
     * @param maxTier Maximum tier achievable (1-5)
     */
    function configureAchievementReward(
        uint256 achievementId,
        uint256 tokenReward,
        uint256 resourceReward,
        uint8 resourceType,
        bool nftEnabled,
        uint8 minTier,
        uint8 maxTier
    ) external onlyAuthorized {
        if (resourceType > 3) revert InvalidResourceType(resourceType);
        if (minTier > 5 || minTier == 0) revert InvalidAchievementTier(minTier);
        if (maxTier > 5 || maxTier == 0 || maxTier < minTier) revert InvalidAchievementTier(maxTier);

        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();

        // Track achievement ID if not already configured
        if (!ps.isAchievementConfigured[achievementId]) {
            ps.configuredAchievementIds.push(achievementId);
            ps.isAchievementConfigured[achievementId] = true;
        }

        ps.achievementRewardConfigs[achievementId] = LibPremiumStorage.AchievementRewardConfig({
            tokenReward: tokenReward,
            resourceReward: resourceReward,
            resourceType: resourceType,
            nftMintEnabled: nftEnabled,
            minTier: minTier,
            maxTier: maxTier,
            configured: true
        });
    }
    
    /**
     * @notice Batch configure multiple achievement rewards
     */
    function batchConfigureRewards(
        uint256[] calldata achievementIds,
        LibPremiumStorage.AchievementRewardConfig[] calldata configs
    ) external onlyAuthorized {
        require(achievementIds.length == configs.length, "Length mismatch");

        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();

        for (uint256 i = 0; i < achievementIds.length; i++) {
            uint256 achievementId = achievementIds[i];

            // Track achievement ID if not already configured
            if (!ps.isAchievementConfigured[achievementId]) {
                ps.configuredAchievementIds.push(achievementId);
                ps.isAchievementConfigured[achievementId] = true;
            }

            ps.achievementRewardConfigs[achievementId] = configs[i];
        }
    }

    /**
     * @notice Remove/disable an achievement reward configuration
     * @param achievementId Achievement to remove
     */
    function removeAchievementReward(uint256 achievementId) external onlyAuthorized {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        delete ps.achievementRewardConfigs[achievementId];
    }

    /**
     * @notice Rebuild configuredAchievementIds tracking array
     * @param achievementIds List of achievement IDs to sync
     */
    function rebuildConfiguredAchievementIds(uint256[] calldata achievementIds) external onlyAuthorized {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();

        // Clear existing
        uint256 len = ps.configuredAchievementIds.length;
        for (uint256 i = 0; i < len; i++) {
            ps.isAchievementConfigured[ps.configuredAchievementIds[i]] = false;
        }
        delete ps.configuredAchievementIds;

        // Rebuild
        for (uint256 i = 0; i < achievementIds.length; i++) {
            uint256 id = achievementIds[i];
            if (ps.achievementRewardConfigs[id].configured) {
                ps.configuredAchievementIds.push(id);
                ps.isAchievementConfigured[id] = true;
            }
        }
    }

    /**
     * @notice Update NFT contract address
     * @param nftContract New achievement NFT contract address
     */
    function setAchievementNFT(address nftContract) external onlyAuthorized {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        ps.achievementNFT = nftContract;
    }

    /**
     * @notice Check if achievement rewards are initialized
     */
    function isAchievementRewardsInitialized() external view returns (bool) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        return ps.achievementNFT != address(0);
    }

    /**
     * @notice Get the achievement NFT contract address
     */
    function getAchievementNFTAddress() external view returns (address) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        return ps.achievementNFT;
    }
    
    // ==================== ACHIEVEMENT AWARDING ====================

    /**
     * @notice Award achievement to a single user (user must claim NFT and rewards)
     * @param user User who earned the achievement
     * @param achievementId Achievement identifier
     * @param tier Tier achieved (1-5)
     */
    function completeAchievement(
        address user,
        uint256 achievementId,
        uint8 tier
    ) external whenNotPaused onlyTrusted {
        _award(user, achievementId, tier, false);
    }
    
    /**
     * @notice Award achievement to multiple users
     * @param users Array of user addresses
     * @param achievementId Achievement identifier
     * @param tier Tier to award (1-5)
     * @param autoMint If true, mint NFT immediately; if false, user must claim
     */
    function awardAchievement(
        address[] calldata users,
        uint256 achievementId,
        uint8 tier,
        bool autoMint
    ) external whenNotPaused onlyTrusted {
        for (uint256 i = 0; i < users.length; i++) {
            _award(users[i], achievementId, tier, autoMint);
        }
    }

    /**
     * @notice Internal: award achievement to user
     */
    function _award(address user, uint256 achievementId, uint8 tier, bool autoMint) internal {
        if (tier > 5 || tier == 0) revert InvalidAchievementTier(tier);

        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();

        if (!ps.achievementRewardConfigs[achievementId].configured) {
            revert AchievementNotConfigured(achievementId);
        }

        // Skip if already earned
        if (gs.userAchievements[user][achievementId].hasEarned) return;

        // Mark as earned
        gs.userAchievements[user][achievementId].hasEarned = true;
        gs.userAchievements[user][achievementId].earnedAt = uint32(block.timestamp);
        gs.userAchievementHistory[user].push(achievementId);

        // Track reward data
        LibPremiumStorage.UserAchievementReward storage reward = ps.userAchievementRewards[user][achievementId];
        reward.completionTime = uint32(block.timestamp);
        reward.tierAchieved = tier;

        unchecked {
            ps.totalAchievementsCompleted++;
            gs.achievementEarnCount[achievementId]++;
        }

        emit AchievementAwarded(user, achievementId, tier);

        // Auto-mint NFT if requested
        if (autoMint && ps.achievementRewardConfigs[achievementId].nftMintEnabled) {
            _mintNFT(user, achievementId, tier);
        }
    }

    /**
     * @notice Admin: mint badges for users who earned achievement but badge wasn't minted
     * @param users Array of user addresses
     * @param achievementId Achievement ID
     */
    function mintPendingBadges(
        address[] calldata users,
        uint256 achievementId
    ) external whenNotPaused onlyTrusted {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();

        if (!ps.achievementRewardConfigs[achievementId].nftMintEnabled) return;

        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            LibPremiumStorage.UserAchievementReward storage reward = ps.userAchievementRewards[user][achievementId];

            // Skip if not earned or already minted
            if (!gs.userAchievements[user][achievementId].hasEarned) continue;
            if (reward.nftMinted) continue;

            _mintNFT(user, achievementId, reward.tierAchieved);
        }
    }

    /**
     * @notice Internal: mint NFT for achievement
     */
    function _mintNFT(address user, uint256 achievementId, uint8 tier) internal returns (uint256 tokenId) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        if (ps.achievementNFT == address(0)) revert NFTMintFailed(achievementId);

        tokenId = IAchievementNFT(ps.achievementNFT).mintAchievement(user, achievementId, tier);
        ps.userAchievementRewards[user][achievementId].nftMinted = true;
        unchecked { ps.totalNFTsMinted++; }
    }

    /**
     * @notice Internal: check if user already has achievement NFT (minted externally)
     */
    function _userHasAchievementNFT(address user, uint256 achievementId, uint8 tier) internal view returns (bool) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        if (ps.achievementNFT == address(0)) return false;

        // Check on-chain if user has this achievement NFT
        try IAchievementNFT(ps.achievementNFT).hasAchievement(user, achievementId, tier) returns (bool has) {
            return has;
        } catch {
            return false;
        }
    }

    // ==================== CLAIMING ====================

    /**
     * @notice Claim achievement NFT badge and rewards (tokens + resources)
     * @param achievementId Achievement to claim
     */
    function claimAchievement(uint256 achievementId) external whenNotPaused nonReentrant {
        address user = LibMeta.msgSender();
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();

        // Must have earned the achievement
        if (!gs.userAchievements[user][achievementId].hasEarned) {
            revert AchievementNotAwarded(achievementId);
        }

        LibPremiumStorage.UserAchievementReward storage reward = ps.userAchievementRewards[user][achievementId];
        if (reward.rewardClaimed) revert AchievementAlreadyClaimed(achievementId);

        LibPremiumStorage.AchievementRewardConfig storage config = ps.achievementRewardConfigs[achievementId];

        // Check tier requirement
        if (reward.tierAchieved < config.minTier) {
            revert InvalidAchievementTier(reward.tierAchieved);
        }

        reward.rewardClaimed = true;

        // 1. Mint NFT if enabled and not already minted (check on-chain ownership too)
        uint256 tokenId = 0;
        if (config.nftMintEnabled && !reward.nftMinted) {
            // Check if user already has this NFT (minted externally)
            bool alreadyHasNFT = _userHasAchievementNFT(user, achievementId, reward.tierAchieved);
            if (!alreadyHasNFT) {
                tokenId = _mintNFT(user, achievementId, reward.tierAchieved);
            } else {
                // Mark as minted since user already has it
                reward.nftMinted = true;
            }
        }

        // 2. Award token rewards
        uint256 totalTokens = 0;
        if (config.tokenReward > 0) {
            LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
            uint256 tierMultiplier = 100 + (reward.tierAchieved - 1) * 25; // 100%-200%
            totalTokens = (config.tokenReward * tierMultiplier) / 100;
            _distributeYlwReward(rs.config.utilityToken, rs.config.paymentBeneficiary, user, totalTokens);
            unchecked { ps.totalTokensDistributed += totalTokens; }
        }

        // 3. Award resource rewards
        uint256 totalResources = 0;
        if (config.resourceReward > 0) {
            LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
            // Apply decay before modifying resources
            LibResourceStorage.applyResourceDecay(user);
            uint256 tierMultiplier = 100 + (reward.tierAchieved - 1) * 25;
            totalResources = (config.resourceReward * tierMultiplier) / 100;
            rs.userResources[user][config.resourceType] += totalResources;
            unchecked { ps.totalResourcesDistributed += totalResources; }
        }

        emit AchievementClaimed(user, achievementId, tokenId, totalTokens, totalResources);
    }
    
    /**
     * @notice Batch claim multiple achievement rewards (NFT + tokens + resources for each)
     * @param achievementIds Array of achievement IDs to claim rewards for
     */
    function claimAchievementRewards(uint256[] calldata achievementIds) external whenNotPaused nonReentrant {
        address user = LibMeta.msgSender();
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();

        for (uint256 i = 0; i < achievementIds.length; i++) {
            uint256 achievementId = achievementIds[i];

            // Skip if not earned or already claimed
            if (!gs.userAchievements[user][achievementId].hasEarned) continue;
            if (ps.userAchievementRewards[user][achievementId].rewardClaimed) continue;

            LibPremiumStorage.UserAchievementReward storage reward = ps.userAchievementRewards[user][achievementId];
            LibPremiumStorage.AchievementRewardConfig storage config = ps.achievementRewardConfigs[achievementId];

            // Skip if tier requirement not met
            if (reward.tierAchieved < config.minTier) continue;

            reward.rewardClaimed = true;

            // 1. Mint NFT if enabled (check on-chain ownership too)
            uint256 tokenId = 0;
            if (config.nftMintEnabled && !reward.nftMinted) {
                bool alreadyHasNFT = _userHasAchievementNFT(user, achievementId, reward.tierAchieved);
                if (!alreadyHasNFT) {
                    tokenId = _mintNFT(user, achievementId, reward.tierAchieved);
                } else {
                    reward.nftMinted = true;
                }
            }

            // 2. Token rewards
            uint256 totalTokens = 0;
            if (config.tokenReward > 0) {
                LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
                uint256 tierMultiplier = 100 + (reward.tierAchieved - 1) * 25;
                totalTokens = (config.tokenReward * tierMultiplier) / 100;
                _distributeYlwReward(rs.config.utilityToken, rs.config.paymentBeneficiary, user, totalTokens);
                unchecked { ps.totalTokensDistributed += totalTokens; }
            }

            // 3. Resource rewards
            uint256 totalResources = 0;
            if (config.resourceReward > 0) {
                LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
                // Apply decay before modifying resources
                LibResourceStorage.applyResourceDecay(user);
                uint256 tierMultiplier = 100 + (reward.tierAchieved - 1) * 25;
                totalResources = (config.resourceReward * tierMultiplier) / 100;
                rs.userResources[user][config.resourceType] += totalResources;
                unchecked { ps.totalResourcesDistributed += totalResources; }
            }

            emit AchievementClaimed(user, achievementId, tokenId, totalTokens, totalResources);
        }
    }
    
    // ==================== VIEW FUNCTIONS ====================

    /**
     * @notice Get user's pending achievements (earned but not claimed)
     * @return ids Achievement IDs
     * @return tiers Tiers achieved
     * @return nftPending Whether NFT is pending (not minted)
     * @return tokenRewards Token reward amounts
     * @return resourceRewards Resource reward amounts
     */
    function getPendingAchievements(address user) external view returns (
        uint256[] memory ids,
        uint8[] memory tiers,
        bool[] memory nftPending,
        uint256[] memory tokenRewards,
        uint256[] memory resourceRewards
    ) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();

        uint256[] memory history = gs.userAchievementHistory[user];
        uint256 count = 0;

        // Count pending
        for (uint256 i = 0; i < history.length; i++) {
            if (gs.userAchievements[user][history[i]].hasEarned &&
                !ps.userAchievementRewards[user][history[i]].rewardClaimed) {
                count++;
            }
        }

        ids = new uint256[](count);
        tiers = new uint8[](count);
        nftPending = new bool[](count);
        tokenRewards = new uint256[](count);
        resourceRewards = new uint256[](count);

        uint256 idx = 0;
        for (uint256 i = 0; i < history.length; i++) {
            uint256 achId = history[i];
            LibPremiumStorage.UserAchievementReward storage reward = ps.userAchievementRewards[user][achId];

            if (gs.userAchievements[user][achId].hasEarned && !reward.rewardClaimed) {
                ids[idx] = achId;
                tiers[idx] = reward.tierAchieved;

                LibPremiumStorage.AchievementRewardConfig storage config = ps.achievementRewardConfigs[achId];
                nftPending[idx] = config.nftMintEnabled && !reward.nftMinted;

                uint256 multiplier = 100 + (reward.tierAchieved - 1) * 25;
                tokenRewards[idx] = (config.tokenReward * multiplier) / 100;
                resourceRewards[idx] = (config.resourceReward * multiplier) / 100;

                idx++;
            }
        }
    }
    
    /**
     * @notice Get achievement reward configuration
     */
    function getAchievementRewardConfig(uint256 achievementId) external view returns (
        uint256 tokenReward,
        uint256 resourceReward,
        uint8 resourceType,
        bool nftEnabled,
        uint8 minTier,
        uint8 maxTier,
        bool configured
    ) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.AchievementRewardConfig storage config = ps.achievementRewardConfigs[achievementId];

        return (
            config.tokenReward,
            config.resourceReward,
            config.resourceType,
            config.nftMintEnabled,
            config.minTier,
            config.maxTier,
            config.configured
        );
    }

    /**
     * @notice Get all configured achievement reward configurations
     * @return ids Array of achievement IDs
     * @return configs Array of achievement reward configurations
     */
    function getAllAchievementConfigs() external view returns (
        uint256[] memory ids,
        LibPremiumStorage.AchievementRewardConfig[] memory configs
    ) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();

        uint256 count = ps.configuredAchievementIds.length;
        ids = new uint256[](count);
        configs = new LibPremiumStorage.AchievementRewardConfig[](count);

        for (uint256 i = 0; i < count; i++) {
            uint256 achievementId = ps.configuredAchievementIds[i];
            ids[i] = achievementId;
            configs[i] = ps.achievementRewardConfigs[achievementId];
        }
    }

    /**
     * @notice Get count of configured achievements
     */
    function getConfiguredAchievementCount() external view returns (uint256) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        return ps.configuredAchievementIds.length;
    }

    /**
     * @notice Check user's achievement status
     * @return earned Whether achievement was earned
     * @return tier Tier achieved
     * @return claimed Whether rewards were claimed
     * @return nftMinted Whether NFT was minted
     */
    function getAchievementStatus(address user, uint256 achievementId) external view returns (
        bool earned,
        uint8 tier,
        bool claimed,
        bool nftMinted
    ) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.UserAchievementReward storage reward = ps.userAchievementRewards[user][achievementId];

        return (
            gs.userAchievements[user][achievementId].hasEarned,
            reward.tierAchieved,
            reward.rewardClaimed,
            reward.nftMinted
        );
    }

    /**
     * @notice Check if user has completed achievement (legacy alias)
     */
    function hasCompletedAchievement(address user, uint256 achievementId) external view returns (bool completed, uint8 tier) {
        LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        return (
            gs.userAchievements[user][achievementId].hasEarned,
            ps.userAchievementRewards[user][achievementId].tierAchieved
        );
    }
    
    /**
     * @notice Get achievement rewards system statistics
     */
    function getAchievementStats() external view returns (
        uint256 totalCompleted,
        uint256 totalNFTs,
        uint256 totalTokens,
        uint256 totalResources
    ) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        return (
            ps.totalAchievementsCompleted,
            ps.totalNFTsMinted,
            ps.totalTokensDistributed,
            ps.totalResourcesDistributed
        );
    }
    
    // ==================== INTERNAL HELPERS ====================
    
    /**
     * @notice Distribute YLW reward with Treasury → Mint fallback
     * @dev Priority: 1) Transfer from treasury, 2) Mint if treasury insufficient
     * @param rewardToken YLW token address
     * @param treasury Treasury address
     * @param recipient User receiving the reward
     * @param amount Amount to distribute
     */
    function _distributeYlwReward(
        address rewardToken,
        address treasury,
        address recipient,
        uint256 amount
    ) internal {
        // Check treasury balance and allowance
        uint256 treasuryBalance = IERC20(rewardToken).balanceOf(treasury);
        uint256 allowance = IERC20(rewardToken).allowance(treasury, address(this));
        
        if (treasuryBalance >= amount && allowance >= amount) {
            // Pay from treasury (preferred - sustainable)
            IERC20(rewardToken).safeTransferFrom(treasury, recipient, amount);
        } else if (treasuryBalance > 0 && allowance > 0) {
            // Partial from treasury, rest from mint
            uint256 fromTreasury = treasuryBalance < allowance ? treasuryBalance : allowance;
            IERC20(rewardToken).safeTransferFrom(treasury, recipient, fromTreasury);
            
            uint256 shortfall = amount - fromTreasury;
            IRewardToken(rewardToken).mint(recipient, shortfall, "achievement_reward");
        } else {
            // Fallback: Mint new tokens
            IRewardToken(rewardToken).mint(recipient, amount, "achievement_reward");
        }
    }
}
