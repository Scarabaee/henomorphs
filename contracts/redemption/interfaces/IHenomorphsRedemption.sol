// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {RedemptionStorage} from "../storage/RedemptionStorage.sol";

/**
 * @title IHenomorphsRedemption
 * @notice Main interface for Henomorphs Redemption System
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
interface IHenomorphsRedemption {
    
    // ==================== EVENTS ====================
    
    /**
     * @notice Emitted when a tier is redeemed
     */
    event TierRedeemed(
        address indexed user,
        uint256 indexed tierId,
        uint256 timestamp,
        uint256 tokenId,
        uint256 stakedTokenCount
    );
    
    /**
     * @notice Emitted when eligibility is checked
     */
    event EligibilityChecked(
        address indexed user,
        uint256 indexed tierId,
        bool eligible,
        uint256 timestamp
    );
    
    /**
     * @notice Emitted when tier configuration is updated
     */
    event TierConfigurationUpdated(
        uint256 indexed tierId,
        string name,
        bool active
    );
    
    /**
     * @notice Emitted when a snapshot is created
     */
    event SnapshotCreated(
        bytes32 indexed snapshotHash,
        address indexed user,
        uint256 indexed tierId,
        uint256 blockNumber
    );
    
    /**
     * @notice Emitted when system is paused/unpaused
     */
    event SystemPauseChanged(bool paused);
    
    /**
     * @notice Emitted when base URI is updated
     */
    event BaseURIUpdated(string newBaseURI);
    
    // ==================== ERRORS ====================
    
    error SystemPaused();
    error TierNotActive(uint256 tierId);
    error TierNotFound(uint256 tierId);
    error NotEligible(uint256 tierId);
    error AlreadyRedeemed(uint256 tierId);
    error InCooldown(uint256 remainingTime);
    error MaxSupplyReached(uint256 tierId);
    error TierNotStarted(uint256 tierId);
    error TierEnded(uint256 tierId);
    error InvalidConfiguration();
    error UserBlacklisted(address user);
    error SnapshotRequired();
    error InvalidStakingDiamond();
    
    // ==================== STRUCTS ====================
    
    /**
     * @notice Eligibility check result
     */
    struct EligibilityResult {
        bool eligible;
        uint256 stakedTokenCount;
        uint256 averageStakingDays;
        uint256 averageLevel;
        uint8[] variantDistribution;
        uint256 infusedTokenCount;
        bool hasColonyMembership;
        bool isColonyCreator;
        bool hasLoyaltyBonus;
        uint8 loyaltyTier;
        string[] failureReasons;
    }
    
    /**
     * @notice Tier information
     */
    struct TierInfo {
        uint256 tierId;
        string name;
        string uri;
        bool active;
        uint16 minStakedTokens;
        uint32 minStakingDays;
        uint8 minAverageLevel;
        uint256 currentSupply;
        uint256 maxSupply;
        uint256 redemptionCount;
    }
    
    // ==================== REDEMPTION FUNCTIONS ====================
    
    /**
     * @notice Claim redemption for a specific tier
     * @param tierId Tier to claim
     * @return success Whether redemption was successful
     */
    function claimRedemption(uint256 tierId) external returns (bool success);
    
    /**
     * @notice Claim multiple tiers in one transaction
     * @param tierIds Array of tier IDs to claim
     * @return successes Array of success status for each tier
     */
    function batchClaimRedemption(uint256[] calldata tierIds) 
        external 
        returns (bool[] memory successes);
    
    /**
     * @notice Burn lower tier and claim higher tier
     * @param lowerTierId Tier to burn
     * @param higherTierId Tier to claim
     * @return success Whether upgrade was successful
     */
    function upgradeTier(uint256 lowerTierId, uint256 higherTierId) 
        external 
        returns (bool success);
    
    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @notice Check if user is eligible for a tier
     * @param user User address
     * @param tierId Tier ID to check
     * @return result Eligibility result with detailed information
     */
    function checkEligibility(address user, uint256 tierId) 
        external 
        view 
        returns (EligibilityResult memory result);
    
    /**
     * @notice Check eligibility for multiple tiers
     * @param user User address
     * @param tierIds Array of tier IDs
     * @return results Array of eligibility results
     */
    function batchCheckEligibility(address user, uint256[] calldata tierIds)
        external
        view
        returns (EligibilityResult[] memory results);
    
    /**
     * @notice Get tier configuration
     * @param tierId Tier ID
     * @return config Tier configuration
     */
    function getTierConfig(uint256 tierId) 
        external 
        view 
        returns (RedemptionStorage.TierConfig memory config);
    
    /**
     * @notice Get tier information
     * @param tierId Tier ID
     * @return info Tier information
     */
    function getTierInfo(uint256 tierId) 
        external 
        view 
        returns (TierInfo memory info);
    
    /**
     * @notice Get all active tiers
     * @return tierIds Array of active tier IDs
     */
    function getActiveTiers() 
        external 
        view 
        returns (uint256[] memory tierIds);
    
    /**
     * @notice Get user's redemption history
     * @param user User address
     * @return redemptions Array of user redemptions
     */
    function getUserRedemptions(address user) 
        external 
        view 
        returns (RedemptionStorage.UserRedemption[] memory redemptions);
    
    /**
     * @notice Check if user has redeemed a specific tier
     * @param user User address
     * @param tierId Tier ID
     * @return redeemed Whether user has redeemed this tier
     */
    function hasUserRedeemed(address user, uint256 tierId) 
        external 
        view 
        returns (bool redeemed);
    
    /**
     * @notice Get remaining cooldown time for user
     * @param user User address
     * @return remainingTime Remaining cooldown in seconds (0 if not in cooldown)
     */
    function getRemainingCooldown(address user) 
        external 
        view 
        returns (uint256 remainingTime);
    
    /**
     * @notice Get user's snapshot history
     * @param user User address
     * @return snapshots Array of snapshot hashes
     */
    function getUserSnapshots(address user) 
        external 
        view 
        returns (bytes32[] memory snapshots);
    
    /**
     * @notice Get snapshot details
     * @param snapshotHash Snapshot hash
     * @return snapshot Snapshot data
     */
    function getSnapshot(bytes32 snapshotHash) 
        external 
        view 
        returns (RedemptionStorage.VerificationSnapshot memory snapshot);
    
    // ==================== ADMIN FUNCTIONS ====================
    
    /**
     * @notice Create or update a tier configuration
     * @param config Tier configuration
     */
    function configureTier(RedemptionStorage.TierConfig calldata config) external;
    
    /**
     * @notice Activate/deactivate a tier
     * @param tierId Tier ID
     * @param active Active status
     */
    function setTierActive(uint256 tierId, bool active) external;
    
    /**
     * @notice Update tier URI
     * @param tierId Tier ID
     * @param uri New URI
     */
    function setTierURI(uint256 tierId, string calldata uri) external;
    
    /**
     * @notice Pause/unpause the system
     * @param paused Pause status
     */
    function setSystemPaused(bool paused) external;
    
    /**
     * @notice Update staking diamond address
     * @param stakingDiamond New staking diamond address
     */
    function setStakingDiamond(address stakingDiamond) external;
    
    /**
     * @notice Update global cooldown period
     * @param cooldownPeriod New cooldown period in seconds
     */
    function setGlobalCooldown(uint256 cooldownPeriod) external;
    
    /**
     * @notice Blacklist/unblacklist a user
     * @param user User address
     * @param blacklisted Blacklist status
     */
    function setUserBlacklisted(address user, bool blacklisted) external;
    
    /**
     * @notice Emergency withdraw tokens
     * @param token Token address (address(0) for ETH)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, address to, uint256 amount) external;
}
