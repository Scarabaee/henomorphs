// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Structs and enums module which provides data model for the Henomorphs collections. 
 *
 * @custom:website https://zicodao.io
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */

struct ControlFee {
    // The currency address.
    // If zero address, the fee is in ZICO.    
    IERC20 currency; 
    // The fee amount.
    uint256 amount; 
    // The address the tokens or withdrawals maight be deposited
    address beneficiary;
    bool burnOnCollect;
}

/**
 * @dev Struct that keeps calibration settings specific properties.
 */
struct CalibrationSettings {
    // The interval between interactions in hours.
    uint256 interactPeriod; 
    // The interval between charge in seconds.
    uint256 chargePeriod; 
    // The interval between recalibrations in seconds.
    uint256 recalPeriod; 
    // The fee for the calibration.
    ControlFee controlFee;
    // The unit of the calibration.
    uint256 tuneValue;
    // The value of the calibration.
    uint256 bonusValue;
    // The threshold for the bonus.
    uint256 bonusThreshold;

}

/**
 * @dev Struct that keeps issue tiers item specific properties.
 */
struct Calibration {
    // The ID of the Henomorphs token.
    uint256 tokenId;
    // The owner of the Henomorphs token.
    address owner;
    // Kinship level (0-100), increases with interactions, decreases over time. Default is 50.
    uint256 kinship; 
    // Last interaction timestamp
    uint256 lastInteraction; 
    // The current experience points of the Henomorphs token. Default is 0.
    uint256 experience;
    // Charge leve (0-100). Default is 0.
    uint256 charge;     
    // Last charge timestamp
    uint256 lastCharge;   
    // The current level of the Henomorph token. Default is 1.
    uint256 level;   
    // The current experience points of the Henomorph token. Default is 1.
    uint256 prowess;
    // The current wear level of the Henomorph token. Default is 0.
    uint256 wear;
    // Last recalibration timestamp
    uint256 lastRecalibration; 
    // The number of recalibrations performed on the Henomorph token. Default is 0.
    uint256 calibrationCount;
    // Locked status of the Henomorph token.
    bool locked;
    // The current level of agility of the Henomorphs token. Default is 0.
    uint256 agility;
    // The current level of intellect of the Henomorphs token. Default is 0.
    uint256 intelligence;
    // Bio-level for Biopod integration
    uint256 bioLevel;
}

/**
 * @dev Struct that keeps issue tiers item specific properties.
 */
struct Specimen {
    // The variant to which the specimen belongs to
    uint8 variant;  
    // Form type (0-4)
    uint8 form;
    // Optional form name
    string formName; 
    // Optional, general form description     
    string description;
    uint8 generation;
    uint8 augmentation;
    // The base metadata or images URI of the given specinem
    string baseUri;
}

/**
 * @dev Structure for collection configuration
 */
struct SpecimenCollection {
    address collectionAddress;  // NFT collection address
    address biopodAddress;      // Associated biopod address
    string name;                // Collection name
    bool enabled;               // Whether collection is enabled
    uint8 collectionType;       // Type identifier (0=genesis, 1=matrix, etc)
    uint256 regenMultiplier;    // Regen rate multiplier (in percentage, 100 = standard)
    uint256 maxChargeBonus;     // Additional max charge bonus
    address diamondAddress; 
    bool isModularSpecimen; 
    address augmentsAddress;      // Associated augments address
    address repositoryAddress;      // Associated repository address
    uint8 defaultTier;
    uint8 maxVariantIndex;
}

/**
 * @dev Structure for advanced charge system data
 */
struct PowerMatrix {
    uint256 currentCharge;    // Current charge level (0-100)
    uint256 maxCharge;        // Maximum charge capacity
    uint256 lastChargeTime;   // Timestamp of last charge update
    uint256 regenRate;        // Base regeneration speed (points per hour)
    uint256 fatigueLevel;     // Fatigue level (0-100)
    uint256 boostEndTime;     // Timestamp when active boost ends
    uint256 chargeEfficiency; // Charge utilization efficiency (%)
    uint256 consecutiveActions; // Number of consecutive actions performed
    uint8 flags;               // Bit flags
    uint8 specialization;     // Specialization type (0=balanced, 1=efficiency, 2=regeneration)
    uint256 seasonPoints;     // Points earned in current season
    // NEW: Dedicated evolution fields
    uint8 evolutionLevel;      // For evolution level (0-99)
    uint256 evolutionXP;        // For evolution XP
    uint256 masteryPoints;      // For mastery points
    // NEW: Calibration-compatible fields for full Biopod parity
    uint8 kinship;             // Kinship level (0-100), default 50
    uint8 prowess;             // Combat prowess stat
    uint8 agility;             // Agility stat
    uint8 intelligence;        // Intelligence stat
    uint32 calibrationCount;   // Number of inspections performed
    uint32 lastInteraction;    // Last inspection timestamp (separate from lastChargeTime)
}

/**
 * @dev Structure for accessories that modify charge parameters and integrate with trait packs
 * @notice Accessories provide boosts to various metrics based on trait packs and affect Biopod calibration
 */
struct ChargeAccessory {
    // Basic identification
    uint8 accessoryType;       // Type identifier (1-10 for different accessory categories)
    string accessoryName;      // Human-readable name of the accessory
    bool rare;                 // Whether accessory is rare (affects all bonuses)
    
    // Trait pack integration
    uint8 traitPackId;         // ID of the trait pack this accessory belongs to (1-3 per Henomorph)
    string traitURI;           // URI to the trait pack metadata and visuals
    
    // Charge system effects (core functionality)
    uint8 chargeBoost;         // Increases max charge capacity
    uint8 regenBoost;          // Increases charge regeneration rate
    uint8 efficiencyBoost;     // Increases charge utilization efficiency
    
    // Biopod calibration effects
    uint8 kinshipBoost;        // Increases kinship recovery or slows decay
    uint8 wearResistance;      // Reduces wear accumulation rate
    uint8 calibrationBonus;    // Improves calibration level calculations
    
    // Staking system effects
    uint8 stakingBoostPercentage;  // Additional staking rewards percentage
    uint8 xpGainMultiplier;        // Multiplier for experience gain (x100, e.g. 120 = 1.2x)
    
    // Specialization effects
    uint8 specializationType;       // Specialization this accessory enhances (0=all, 1=efficiency, 2=regen)
    uint8 specializationBoostValue; // Percentage boost to specialization effects
    
    // Special gameplay features
    bool unlocksBonusAction;        // Whether accessory unlocks bonus actions
    uint8 bonusActionType;          // Type of bonus action unlocked (0=none)
    uint8 actionBoostValue;         // Percentage boost to specific action rewards
    
    // Stats enhancement for Calibration
    uint8 prowessBoost;             // Boost to prowess stat from Calibration
    uint8 agilityBoost;             // Boost to agility stat from Calibration
    uint8 intelligenceBoost;        // Boost to intelligence stat from Calibration
}

// Add accessory type info structure
struct AccessoryTypeInfo {
    string name;                // Human-readable name
    bool defaultRare;           // Whether accessory is rare by default
    uint32 registrationTime;    // When accessory type was registered
    bool enabled;               // Whether accessory type is enabled
}

// Add trait pack system storage
struct TraitPack {
    string name;
    string description;
    string baseURI;
    bool enabled;
    uint256 registrationTime;
    uint8 id;
}

/**
 * @dev Structure for seasonal events
 */
struct ChargeSeason {
    uint256 startTime;                // EXISTING
    uint256 endTime;                  // EXISTING
    uint256 chargeBoostPercentage;    // EXISTING
    string theme;                     // EXISTING
    bool active;                      // EXISTING
    
    // NEW FIELDS - Extensions
    bool scheduled;                   // Whether season is scheduled for future
    uint256 scheduledStartTime;       // When season should activate
    uint256 participationThreshold;   // Minimum actions for season rewards
    uint256 prizePool;                // Total rewards for top performers
    bool hasSpecialEvents;            // Whether season includes special events
    uint256 leaderboardSize;          // Size of season leaderboard
    uint256 specialEventCount;        // Number of special events in season
}

/**
 * @dev Definition of action types in the charge system
 */
struct ChargeActionType {
    ControlFee baseCost;              // EXISTING
    uint8 actionCategory;             // EXISTING
    uint256 cooldown;                 // EXISTING
    uint256 rewardMultiplier;         // EXISTING
    bool special;                     // EXISTING
    
    // Time control extensions
    bool timeControlEnabled;          // Whether time control is active
    uint256 startTime;                // Start time (0 = always available)
    uint256 endTime;                  // End time (0 = no end)
    uint256 temporaryMultiplier;      // Override multiplier during time window
    
    // Gamification extensions
    uint256 streakBonusMultiplier;    // Additional multiplier for streak users
    bool eligibleForSpecialEvents;    // Can participate in special events
    uint8 difficultyTier;             // Difficulty tier (1-5) for rewards scaling

    uint8 baseDailyLimit;      // Replace difficulty-based calculation
    uint8 maxDailyLimit;       // Cap for progression bonuses
    uint8 progressionBonus;    // Bonus actions per milestone (0 = no progression)
    uint8 progressionStep;     // Milestone frequency (e.g., every 7 days)
    uint8 minChargePercent;    // Minimum charge required (0-100, 0 = no requirement)
}

/**
 * @dev Structure for system configuration parameters
 */
struct ChargeSettings {
    uint256 baseRegenRate;            // Base charge regeneration points per hour
    uint256 maxConsecutiveActions;    // Maximum number of actions before fatigue penalty
    uint256 fatigueIncreaseRate;      // Fatigue increase per action
    uint256 fatigueRecoveryRate;      // Fatigue decrease per hour
    uint256 chargeEventBonus;         // Percentage bonus during global events
}

/**
 * @dev Structure for fee configuration
 */
struct ChargeFees {
    ControlFee repairFee;             // Fee per charge point repair
    ControlFee boostFee;              // Fee per hour of boost
    ControlFee specializationFee;     // Fee to change specialization
    ControlFee colonyFormationFee;    // Fee to form a new colony
    ControlFee accessoryBaseFee;      // Fee for regular accessories
    ControlFee accessoryRareFee;      // Fee for rare accessories
    ControlFee colonyMembershipFee;   // Fee for joining/leaving a colony

    // Gaming system fees - essential only
    ControlFee claimRewardsFee;         // Fee for claiming general rewards
    ControlFee eventFee;         // Fee for performing events
    ControlFee evolutionFee;
}


/**
 * @dev Structure for colony join criteria
 */
struct ColonyCriteria {
    uint8 minLevel;                // Minimum level required to join (0 means no restriction)
    uint8 minVariant;              // Minimum variant required to join (0 means no restriction)
    uint8 requiredSpecialization;  // Required specialization (0 means any)
    bool requiresApproval;         // Whether joining requires creator approval
    bool allowEmptyJoin;           // Whether joining empty colony is allowed (default: true)
}

/**
 * @dev Structure for colony info
 */
struct SpecimenColony {
    string name;                // Colony name
    string description;         // Colony description
    uint256 memberCount;        // Number of members
    uint256 chargePoolAmount;   // Amount of charge in pool
    uint256 stakingBonus;       // Staking bonus percentage
    address creator;            // Colony creator
}

/**
 * @dev Structure for colony list item
 */
struct ColonyRegistryItem {
    bytes32 colonyId;           // Colony ID
    string name;                // Colony name
    address creator;            // Colony creator
    uint256 memberCount;        // Number of members
    bool requiresApproval;      // Whether joining requires approval
}

/**
 * @notice Structure for comprehensive equipment data transfer
 * @dev Contains all necessary information about trait packs and accessories
 */
struct TraitPackEquipment {
    address traitPackCollection; // Address of the trait pack collection
    uint256 traitPackTokenId;    // Token ID of the active trait pack (0 if none)
    uint64[] accessoryIds;       // List of accessory asset IDs
    uint8 tier;
    uint8 variant;
    uint256 assignmentTime;
    uint256 unlockTime;
    bool locked;
}

struct AugmentedTokenData {
    uint8 tier;
    uint8 specimenVariant;
    Specimen specimen;
    Calibration calibration;
    bool hasCalibration;
    TraitPackEquipment traitPackData;
}