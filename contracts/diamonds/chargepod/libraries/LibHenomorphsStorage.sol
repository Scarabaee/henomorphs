// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../../libraries/HenomorphsModel.sol";
import {ModularAssetModel} from "../../../libraries/ModularAssetModel.sol";
import {GlobalGameState} from "../../../libraries/GamingModel.sol";


/**
 * @title LibHenomorphsStorage
 * @notice Storage library for HenomorphsChargepod with Ownable pattern
 * @dev Enhanced with colony management extensions
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
library LibHenomorphsStorage {
    bytes32 constant HENOMORPHS_STORAGE_POSITION = keccak256("henomorphs.chargepod.storage");

    // Charge-related constants
    uint8 constant CHARGE_BOOST_PERCENTAGE = 50;  // 50% boost
    uint8 constant REGEN_SPEC_BOOST = 30;         // 30% boost for regeneration spec
    uint8 constant EFFICIENCY_SPEC_BOOST = 30;    // 30% boost for efficiency spec
    uint8 constant MAX_FATIGUE_LEVEL = 100;       // Maximum fatigue level
    uint8 constant FATIGUE_PENALTY_THRESHOLD = 50; // Fatigue threshold for penalties

    // Global system errors
    error PowerCoreNotActivated(uint256 collectionId, uint256 tokenId);
    error PowerCoreAlreadyActivated(uint256 collectionId, uint256 tokenId);
    error InvalidCollectionId(uint256 collectionId);
    error TokenNotFound(uint256 tokenId);
    error MaxAccessoriesReached();
    error HenomorphControlForbidden(uint256 collectionId, uint256 tokenId);
    error ColonyDoesNotExist(bytes32 colonyId);
    error AccessoryAlreadyRegistered(uint8 accessoryType);
    error AccessoryDoesNotExist(uint256 accessoryIndex);
    error CollectionNotEnabled(uint256 collectionId);
    error InvalidAccessoryType();
    error SpecializationAlreadySet();
    error InvalidSpecializationType();
    error FunctionDoesNotExist(bytes4 selector);
    error FunctionNotCallableDirectly(bytes4 selector);
    error InsufficientCharge();
    error HenomorphInRepairMode();
    error ContractPaused();
    error Unauthorized(address caller, string reason);
    error InvalidCallData();
    error UnsupportedAction();
    error ForbiddenRequest();
    error ActionOnCooldown(uint256 collectionId, uint256 tokenId, uint8 actionId);
    error HenomorphNotInColony();
    error CollectionAlreadyRegistered(address collection);
    error AccessoryNotRegistered();
    error HenomorphFullyCharged();
    error SeasonNotActive();

    struct ColonyHealth {
        uint32 lastActivityDay;       // Last day of activity
        uint8 healthLevel;           // 0-100 health level
        uint32 boostEndTime;         // Premium restoration boost end time
        uint16 totalRestorations;    // Track restoration count
    }

    // Performance cache for expensive accessory operations
    struct AccessoryCache {
        ChargeAccessory[] accessories;
        uint64[] externalIds;
        uint256 timestamp;
        bool valid;
    }

    struct ColonyEventConfig {
        bool active;
        uint32 startDay;
        uint32 endDay;
        uint8 minDailyActions;     // 2
        uint8 maxDailyActions;     // 5
        uint32 cooldownSeconds;    // 21600 (6h)
        uint8 maxBonusPercent;     // 100
    }

    /**
     * @dev Essential module tracking for core facet communication
     */
    struct InternalModules {
        address chargeModuleAddress;      // Core charging functionality
        address traitsModuleAddress;      // Trait pack management
        address configModuleAddress;      // Configuration and fee collection
        address stakingModuleAddress;     // Staking system integration
    }

    /**
     * @dev Registry for module interface verification
     */
    struct ModulesRegistry {
        // Expected selectors for each module type
        mapping(string => bytes4[]) expectedSelectors;
        // Last verification timestamp
        uint256 lastVerificationTimestamp;
        // Result of last verification
        bool lastVerificationResult;
        // Module verification errors
        mapping(string => string) verificationErrors;
    }

    /**
     * @dev Treasury configuration for comprehensive fee and reward management
     */
    struct ChargeTreasury {
        // Treasury address where fees are collected and rewards are distributed from
        address treasuryAddress;
        // Currency used for treasury operations (ERC20 token address)
        address treasuryCurrency;
        // Currency used for auxiliary treasury operations (ERC20 token address)
        address auxiliaryCurrency;
    }

    struct SpecializationConfig {
        string name;                    // "Balanced", "Efficiency", "Regeneration"
        uint16 regenMultiplier;        // 100 = 100%, 80 = 80%, 130 = 130%
        uint16 efficiencyMultiplier;   // 100 = 100%, 130 = 130%, 85 = 85%
        bool enabled;                  // Whether this specialization is active
    }

    struct HenomorphsStorage {
        // Storage version for tracking upgrades
        uint256 storageVersion;
        
        // System state
        bool paused;
        
        // Operator permissions using Ownable pattern
        mapping(address => bool) operators;
        
        // Season system
        ChargeSeason currentSeason;
        uint32 seasonCounter;
        
        // Global configuration
        ChargeSettings chargeSettings;
        ChargeFees chargeFees;
        
        // Global event duration
        uint32 chargeEventEnd;
        uint8 chargeEventBonus;
        
        // Action types storage
        mapping(uint8 => ChargeActionType) actionTypes;
        
        // Collection registry
        uint16 collectionCounter;
        mapping(uint256 => SpecimenCollection) specimenCollections;
        mapping(address => uint16) collectionIndexes;
        
        // Power matrix data mapped by combined ID
        mapping(uint256 => PowerMatrix) performedCharges;
        
        // Private data storage mappings
        mapping(uint256 => mapping(uint8 => uint32)) actionLogs;
        mapping(uint256 => ChargeAccessory[]) equippedAccessories;
        
        // Operator season points tracking
        mapping(address => mapping(uint32 => uint32)) operatorSeasonPoints;
        
        // Colony system
        mapping(bytes32 => uint256[]) colonies;
        mapping(uint256 => bytes32) specimenColonies;
        mapping(bytes32 => uint256) colonyChargePools;
        mapping(bytes32 => string) colonyNames;
        
        // EXTENDED STORAGE FIELDS FOR STAKING INTEGRATION
        
        // Staking colony integration
        mapping(bytes32 => uint256) colonyStakingBonuses;  // Colony ID => staking bonus percentage
        address stakingSystemAddress;                      // Address of staking system contract
        
        // Enhanced colony features
        mapping(bytes32 => string) colonyDescriptions;     // Colony ID => description
        mapping(bytes32 => uint8) colonyLevels;            // Colony ID => level
        mapping(bytes32 => uint32) colonyExperience;       // Colony ID => experience points
        
        // Maps between staking and chargepod colonies
        mapping(bytes32 => bytes32) chargepodToStakingColonyIds; // Maps Chargepod colonies to staking colonies
        mapping(bytes32 => bytes32) stakingToChargepodColonyIds; // Maps staking colonies to Chargepod colonies

        // Trait pack system
        mapping(uint8 => TraitPack) traitPacks;            // Trait pack ID => trait pack data
        mapping(uint8 => uint8[]) traitPackAccessories;    // Trait pack ID => array of compatible accessory types
        
        // Accessory system management
        mapping(uint8 => AccessoryTypeInfo) accessoryTypes;  // Accessory type ID => accessory type info
        uint8[] allAccessoryTypes;                          // Array of all registered accessory types for enumeration
        mapping(uint8 => mapping(uint8 => bool)) rareAccessories;  // Trait pack ID => accessory type => is rare
        uint256 accessoryTypesCounter;                     // Counter for registered accessory types
        uint8[] registeredTraitPacks;  // Array of all registered trait pack IDs

        // Module configuration
        InternalModules internalModules;                   // Module address registry
        
        // Module verification
        ModulesRegistry modulesRegistry;                   // Registry for interface verification
        
        // Integrity verification
        uint256 lastIntegrityCheck;                        // Last integrity check timestamp
        bool lastIntegrityResult;                          // Result of last integrity check

        // NEW COLONY MANAGEMENT EXTENSIONS //

        // Colony join criteria
        mapping(bytes32 => ColonyCriteria) colonyCriteria;
        
        // Pending join requests (colonyId => combinedId => requester address)
        mapping(bytes32 => mapping(uint256 => address)) pendingJoinRequests;
        
        // Pending join request IDs for easy enumeration
        mapping(bytes32 => uint256[]) colonyPendingRequestIds;
        
        // Creator tracking
        mapping(bytes32 => address) colonyCreators;
        
        // User colonies
        mapping(address => bytes32[]) userColonies;
        
        // Last colony ID for randomization
        bytes32 lastColonyId;
        
        // Direct colony name lookup for optimization
        mapping(bytes32 => string) colonyNamesById;

        // Colony join restriction fields
        mapping(bytes32 => bool) colonyJoinRestrictions;  // true = require members, false = allow empty join
        bool allowEmptyColonyJoin;                        // Global setting: true = allow joining empty colonies

        // New field to control maximum bonus percentage for colony creators
        uint256 maxCreatorBonusPercentage;                // Default 0, will use 25% if not set

        // GLOBAL COLONY REGISTRY - new field added at the end to preserve storage layout
         bytes32[] allColonyIds;                           // Global registry for efficient colony enumeration

         mapping(bytes32 => mapping(uint256 => uint256)) colonyMemberIndices; // colonyId => combinedId => index+1

         // ModularAssetModel integration
        mapping(uint8 => ModularAssetModel.EnhancedTraitPack) enhancedTraitPacks;
        mapping(uint256 => ModularAssetModel.EnhancedAccessory[]) equippedEnhancedAccessories;
        mapping(uint256 => ModularAssetModel.TokenAsset[]) tokenAssets;
        mapping(uint256 => uint64) activeAssetIds;
        mapping(uint8 => mapping(uint8 => int8)) traitPackVariantBonuses; // traitPackId => variant => bonus

        // Feature flags for gradual rollout
        mapping(string => bool) featureFlags;

        // Treasury configuration for comprehensive fee management
        ChargeTreasury chargeTreasury;

        // Colony enhancement metrics
        mapping(bytes32 => uint256) colonyTotalRewards;
        mapping(bytes32 => uint32) colonyActivityScore;
        mapping(bytes32 => uint256) colonyLastActiveTime;

        // Action-specific fees (mappings moved to dedicated storage)
        mapping(uint8 => ControlFee) actionFees;        // Action ID => fee

        // Global game state integration (minimal - main data stays in LibGamingStorage)
        GlobalGameState globalGameState;
        uint256 lastEmergencyModeTime;

        ColonyEventConfig colonyEventConfig;
        
        mapping(uint8 => SpecializationConfig) specializationConfigs;

        // Performance optimization caches
        mapping(uint256 => AccessoryCache) accessoryCache;  // combinedId => cache
        mapping(uint256 => uint256) accessoryCacheTimestamps; // combinedId => timestamp
        uint256 cacheValidityPeriod; // Default 1800 seconds (30 minutes)

        mapping(bytes32 => ColonyHealth) colonyHealth;
    }

    function henomorphsStorage() internal pure returns (HenomorphsStorage storage hs) {
        bytes32 position = HENOMORPHS_STORAGE_POSITION;
        assembly {
            hs.slot := position
        }
    }
}