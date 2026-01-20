// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

bytes1 constant SLASH = 0x2f;

/**
* @dev Structure used to define the selling phases of the series collections.
*/
enum IssuePhase {
    Locked,
    Affiliate,
    Limited,
    Presale,
    General,
    Stunt
}

/**
* @dev Structure used to mint/deposit tokens.
*/
struct Depositary {
    // The adres of target wallet
    address wallet;
    // In case of batch minting
    // The serial offset number of the wallet in the given category
    uint256 offset;
    // In case of batch minting to depositary wallet
    // The batch size to process 
    uint256 limit;
    // In case of minting tokens
    // The amount of tokens to mint
    uint256 amount;
    // In case of batch minting to different wallets
    // The pre-computed tokenID number, used if > 0
    uint256 serial;
}

/**
 * @dev Struct that keeps miniseries specific properties.
 */
struct IssueInfo {
    // Issue ID, subsequent number of the series 
    uint256 issueId;
    // Collection ID this issue belongs to
    uint256 collectionId;
    // The designation of the series eg. S1
    string designation;
    // The address the tokens or withdrowals maight be deposited
    address beneficiary;
    // The number of tiers supported by the series.
    uint256 tiersCount;
    // The base eg. hidden metadata URI
    string baseUri;
    // Whether the sessies config can be still modified
    bool isFixed;
    // When the targed uri should be revealed, the issue date
    uint256 issueTimestamp;
    // The current general issue phase of the series
    IssuePhase issuePhase;
}

/**
 * @dev Struct that keeps issue tiers item specific properties.
 */
struct ItemTier {
    // One of the tiers defined by the collection
    uint8 tier;
    // Collection ID this tier belongs to
    uint256 collectionId;
    // The base metadata URI of the given issue tier
    string tierUri;
    // Max items supply
    uint256 maxSupply;
    // The base quote token price
    uint256 price;
    // Max available mint per wallet
    uint256 maxMints;
    // Whether the thaler is mintable 
    bool isMintable;
    // Whether the thaler is swappable to stamp
    bool isSwappable;
    // Whether the thaler is swappable to stamp
    bool isBoostable;
    // When the target uri should be revealed for a given tier
    uint256 revealTimestamp;
    // The initial serial number for token ids
    uint256 offset;
    // The last serial number for token ids
    uint256 limit;
    // Wheter the ids enumeration is sequential
    bool isSequential;
    // The posible tier vatiants number
    uint256 variantsCount;
    // The specific features bitmap
    uint256 features;
}

/**
 * @dev Struct that keeps items tier variants specific properties.
 */
struct TierVariant {
   uint8 variant;
   uint8 tier;
   uint256 collectionId;
   string name;
   string description;
   string imageURI;
   uint256 maxSupply;
   uint256 currentSupply;
   uint256 mintPrice;
   bool active;
}

struct TraitPack {
    string name;
    string description;
    string baseURI;
    bool enabled;
    uint256 registrationTime;
    uint8 id;
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
}

// TraitPackEquipment is imported from HenomorphsModel.sol to avoid type conflicts
import {TraitPackEquipment} from "../../../libraries/HenomorphsModel.sol";