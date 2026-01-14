// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ControlFee} from "./HenomorphsModel.sol";

/**
 * @notice Structs and enums module which provides  . 
 *
 * @custom:website https://zicodao.io
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */

/**
 * @dev Settings for staking system
 */
struct StakingSettings {
    address treasuryAddress;               // Treasury address
    uint256[] baseRewardRates;             // Base reward rates by variant
    uint256[] levelRewardMultipliers;      // Level reward multipliers
    uint256 baseInfusionAPR;               // Base APR for infusions
    uint256 bonusInfusionAPRPerVariant;    // Bonus APR per variant
    mapping(uint8 => uint16) infusionBonuses; // Infusion bonuses by level
    uint256 minimumStakingPeriod;          // Minimum staking period
    uint256 minInfusionAmount;             // Minimum infusion amount
    uint256 earlyUnstakingFeePercentage;   // Early unstaking fee percentage
    uint256 stakingCooldown;               // Cooldown period after unstaking
    mapping(uint8 => uint256) baseMaxInfusionByVariant; // Max infusion by variant
    mapping(uint256 => uint16) loyaltyBonusThresholds; // Loyalty bonus thresholds (days => bonus %)
}

/**
 * @dev Reward rate by variant
 */
struct PodRewardRate {
    uint8 variant;          // Variant number (1-4)
    uint256 baseRate;       // Base reward rate
}

/**
 * @dev Infusion bonus
 */
struct InfusionBonus {
    uint8 infusionLevel;    // Infusion level (1-5)
    uint16 bonusPercent;    // Bonus percentage
}

/**
 * @dev Staked specimen data
 */
struct StakedSpecimen {
    address owner;              // Owner of the staked token
    address collectionAddress;  // Collection address
    uint32 stakedSince;         // Timestamp when token was staked
    uint32 lastClaimTimestamp;  // Last reward claim timestamp
    uint32 lastSyncTimestamp;   // Last sync with Biopod timestamp
    uint8 variant;              // Token variant (1-4)
    bool staked;                // Whether token is currently staked
    uint8 level;                // Token level
    uint8 infusionLevel;        // Infusion level (0-5)
    uint8 chargeLevel;          // Charge level (0-100)
    uint8 specialization;       // Specialization type
    uint256 experience;         // Accumulated experience
    uint8 wearLevel;            // Current wear level (0-100)
    uint8 wearPenalty;          // Current wear penalty percentage
    uint32 lastWearUpdateTime;  // Last wear update timestamp
    uint32 lastWearRepairTime;  // Last wear repair timestamp
    bool lockupActive;          // Whether token is locked up
    uint32 lockupEndTime;       // Lockup end timestamp
    uint16 lockupBonus;         // Lockup bonus percentage
    bytes32 colonyId;           // Colony ID if in a colony
    uint256 collectionId;
    uint256 tokenId;
    uint256 totalRewardsClaimed; // Total rewards claimed (lifetime)
}

/**
 * @dev Infused specimen data
 */
struct InfusedSpecimen {
    uint256 collectionId;       // Collection ID
    uint256 tokenId;            // Token ID
    uint256 infusedAmount;      // Amount of ZICO infused
    uint256 infusionTime;       // Initial infusion timestamp
    uint256 lastHarvestTime;    // Last harvest timestamp
    bool infused;               // Whether token is infused
}

/**
 * @dev Season reward multiplier
 */
struct SeasonRewardMultiplier {
    uint256 seasonId;           // Season ID
    uint256 multiplier;         // Reward multiplier (percentage)
    bool active;                // Whether season is active
}

/**
 * @dev Special event configuration
 */
struct SpecialEvent {
    uint256 startTime;          // Event start timestamp
    uint256 endTime;            // Event end timestamp
    uint256 multiplier;         // Reward multiplier (percentage)
    bool active;                // Whether event is active
}

/**
 * @dev Staking fees
 */
struct StakingFees {
    ControlFee unstakeFee;       // Fee for unstaking
    ControlFee infusionFee;      // Fee for infusing
    ControlFee claimFee;         // Fee for claiming rewards
    ControlFee colonyCreationFee; // Fee for creating a colony
    ControlFee wearRepairFee;
    ControlFee colonyMembershipFee;      // Added to match Chargepod - Fee for joining or leaving a colony
    // Add these new fee types
    ControlFee stakeFee;     // Fee for staking a token
    ControlFee harvestFee;     // Fee for harvesting infusion rewards
    ControlFee withdrawalFee;  // Fee for withdrawing infused tokens
    ControlFee reinvestFee;    // Fee for reinvesting harvested rewards
}

/**
 * @dev Colony statistics
 * @notice Optimized for compatibility with Chargepod system
 */
struct ColonyStats {
    uint256 memberCount;        // Number of members - using uint256 to match Chargepod
    uint32 totalActiveMembers;  // Number of actively staking members
    uint256 totalStakedAmount;  // Total amount of tokens staked
    bool priorityStatus;        // Whether colony has priority status
    uint32 ageInDays;           // Age of the colony in days (added for reward calculations)
    uint16 totalPower;          // Total power (moved from Colony for consolidation)
}

/**
 * @dev Colony data
 */
struct Colony {
    string name;
    address creator;
    bool active;
    uint32 creationTime;
    uint32 memberLimit;
    uint16 totalPower;
    uint32 memberCount;
    uint256 stakingBonus;
    string description;
    // Stats as a composition rather than duplication
    ColonyStats stats;          // Colony statistics
}

/**
 * @notice Enhanced rate limit structure with proper configuration parameters
 * @dev Used to prevent DoS attacks and excessive operations
 */
struct RateLimits {
    uint256 maxOperations;     // Maximum operations allowed within window
    uint256 windowDuration;    // Time window duration in seconds
    uint256 windowStart;       // Start timestamp of current window
    uint256 operationCount;    // Counter for operations in current window
}

/**
 * @dev Pending join request structure
 */
struct PendingJoinRequest {
    uint256 collectionId;     // Collection ID
    uint256 tokenId;          // Token ID
    address requester;        // Address requesting to join
    uint256 requestTime;      // When request was submitted
    bool approved;            // Whether request is approved
    bool processed;           // Whether request has been processed
}

/**
 * @dev Unified data structure for staking reward calculations
 * @notice Prevents stack too deep errors by grouping all parameters into a single structure
 */
struct RewardCalcData {
    uint256 baseReward;        // Base reward amount
    uint8 level;               // Token level
    uint8 variant;             // Token variant
    uint8 chargeLevel;         // Current charge level
    uint8 infusionLevel;       // Current infusion level
    uint8 specialization;      // Specialization type
    uint256 colonyBonus;       // Colony bonus percentage
    uint256 seasonMultiplier;  // Season multiplier
    uint8 wearLevel;           // Current wear level
    uint256 loyaltyBonus;      // Loyalty program bonus
    uint256 baseMultiplier;    // Base multiplier percentage (100 = 100%)
    uint256 totalMultiplier;   // Final multiplier with all bonuses applied 
    uint256 accessoryBonus;   // Accessory-based bonus
    uint8 wearPenalty; 
}
    

/**
 * @dev Unified data structure for infusion reward calculations
 * @notice Prevents stack too deep errors by grouping all parameters into a single structure
 */
struct InfusionCalcData {
    uint256 infusedAmount;     // Amount of ZICO infused
    uint256 apr;               // Annual percentage rate
    uint256 timeElapsed;       // Time elapsed since last harvest
    uint8 intelligence;        // Intelligence value for bonus
    uint8 wearLevel;           // Wear level for penalty
}

struct StakeBalanceParams {
    uint256 userStakedCount;    // Number of tokens staked by the user
    uint256 totalStakedCount;   // Total number of tokens staked in the system
    uint256 stakingDuration;    // Duration the token has been staked (in seconds)
    bool balanceEnabled;        // Whether balance adjustment is enabled
    uint256 decayRate;          // Rate at which rewards decay as user's stake increases
    uint256 minMultiplier;      // Minimum multiplier allowed (floor)
    bool timeEnabled;           // Whether time-based bonus is enabled
    uint256 maxTimeBonus;       // Maximum time-based bonus percentage
    uint256 timePeriod;         // Time period required for maximum bonus
}
