// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { LibHenomorphsStorage } from "./LibHenomorphsStorage.sol";

/**
 * @title LibColonyWarsStorage
 * @notice Dedicated storage library for Colony Wars
 * @dev Clean storage solution without mixing with LibGamingStorage
 */
library LibColonyWarsStorage {
    bytes32 constant COLONY_WARS_STORAGE_POSITION = keccak256("henomorphs.colonywars.storage.ext.v2");

    // Errors
    error ColonyWarsNotInitialized();
    error InvalidConfiguration(string parameter);
    error StorageVersionMismatch(uint256 expected, uint256 actual);
    error CollectionNotRegistered(uint256 collectionId);
    error InvalidCollectionType(uint8 collectionType);
    error CollectionAlreadyRegistered(uint256 collectionId);
    error ContractAlreadyRegistered(address contractAddress);
    error CollectionTypeMismatch(uint256 collectionId, uint8 expected, uint8 actual);

    // ============================================
    // CONSTANTS - COLLECTION TYPES
    // ============================================

    uint8 constant COLLECTION_TYPE_TERRITORY = 1;
    uint8 constant COLLECTION_TYPE_INFRASTRUCTURE = 2;
    uint8 constant COLLECTION_TYPE_RESOURCE = 3;

    // ============================================
    // CONSTANTS - OPERATION FEE KEYS (keccak256 hashes)
    // ============================================

    bytes32 constant FEE_RAID = keccak256("raid");
    bytes32 constant FEE_MAINTENANCE = keccak256("maintenance");
    bytes32 constant FEE_REPAIR = keccak256("repair");
    bytes32 constant FEE_SCOUTING = keccak256("scouting");
    bytes32 constant FEE_HEALING = keccak256("healing");
    bytes32 constant FEE_PROCESSING = keccak256("processing");
    bytes32 constant FEE_LISTING = keccak256("listing");
    bytes32 constant FEE_CRAFTING = keccak256("crafting");
    bytes32 constant FEE_CHARGE_REPAIR = keccak256("chargeRepair");
    bytes32 constant FEE_WEAR_REPAIR = keccak256("wearRepair");
    bytes32 constant FEE_CHARGE_BOOST = keccak256("chargeBoost");
    bytes32 constant FEE_ACTION = keccak256("action");
    bytes32 constant FEE_SPECIALIZATION = keccak256("specialization");
    bytes32 constant FEE_MASTERY_ACTION = keccak256("masteryAction");
    bytes32 constant FEE_INSPECTION = keccak256("inspection");

    // ============================================
    // STRUCTS - OPERATION FEES (Generic & Token-Agnostic)
    // ============================================
    
    /**
     * @notice Generic fee configuration for any operation
     * @dev Token-agnostic, burn-configurable fee structure with scaling support
     */
    struct OperationFee {
        address currency;         // Token address (treasuryCurrency or auxiliaryCurrency)
        address beneficiary;      // Destination address (usually treasury)
        uint256 baseAmount;       // Base fee amount in token's smallest unit
        uint256 multiplier;       // Scaling factor (100 = 1x, 200 = 2x, 50 = 0.5x)
        bool burnOnCollect; // If true, burn tokens after collecting to beneficiary
        bool enabled;             // If false, operation is free
    }

    // ============================================
    // STRUCTS - MULTI-COLLECTION REGISTRY
    // ============================================
    
    /**
     * @notice Registry entry for Territory/Infrastructure collections
     * @dev Separate registry from LibHenomorphsStorage (different NFT types)
     */
    struct CollectionRegistry {
        address contractAddress;     // ERC721 contract address
        uint8 collectionType;        // 1=Territory, 2=Infrastructure
        bool enabled;                // Active status
        uint32 registeredAt;         // Registration timestamp
        string name;                 // Collection name
    }
    
    /**
     * @notice Per-collection configuration for Territory Cards
     */
    struct TerritoryCollectionConfig {
        uint8 defaultTerritoryType;  // Default type for this collection (1-5)
        uint16 minBonusValue;        // Minimum bonus percentage
        uint16 maxBonusValue;        // Maximum bonus percentage
        bool requiresActivation;     // Whether cards need activation
        uint32 stakingCooldown;      // Cooldown between staking operations
    }
    
    /**
     * @notice Per-collection configuration for Infrastructure Cards
     */
    struct InfrastructureCollectionConfig {
        uint8 defaultInfraType;      // Default infrastructure type
        uint8 minEfficiencyBonus;    // Minimum efficiency bonus
        uint8 maxEfficiencyBonus;    // Maximum efficiency bonus
        uint8 minCapacityBonus;      // Minimum capacity bonus
        uint8 maxCapacityBonus;      // Maximum capacity bonus
        bool requiresEquipment;      // Whether needs to be equipped
    }

    struct TerritoryListing {
        uint256 territoryId;
        bytes32 seller;
        uint256 askPrice;
        uint32 listedTime;
        uint32 expiryTime;  // 0 = no expiry
        bool active;
    }

    struct TerritoryOffer {
        uint256 territoryId;
        bytes32 buyer;
        uint256 offerPrice;
        uint32 offerTime;
        uint32 expiryTime;
        bool active;
    }
        
    struct AllianceInvitation {
        bytes32 allianceId;
        address inviter;
        uint32 expiry;
        bool active;
    }

    // Structures
    struct ColonyWarProfile {
        uint256 defensiveStake;
        uint32 lastAttackTime;
        bool acceptingChallenges;
        uint8 reputation; // 0=honorable, 1=ruthless, 2=diplomatic, 3=mercenary
        bool registered;
        uint8 warStress;        // 0-10, increases maintenance costs
        uint32 lastStressTime;  // For stress decay calculation
        uint8 stakeIncreases;
    }
    
    struct BattleInstance {
        bytes32 attackerColony;
        bytes32 defenderColony;
        uint256 stakeAmount;
        uint256[] attackerTokens;
        uint256[] defenderTokens;
        uint32 battleStartTime;
        uint32 battleEndTime;
        uint8 battleState; // 0=preparation, 1=active, 2=completed
        bytes32 winner;
        uint256 prizePool;
        bool isBetrayalAttack;
    }
    
    struct Territory {
        bytes32 controllingColony;
        uint32 lastMaintenancePayment;
        uint8 territoryType; // 1=zico_mine, 2=trade_hub, 3=fortress, 4=observatory, 5=sanctuary
        uint16 bonusValue;
        bool active;
        string name;
        uint16 damageLevel;     // 0-100, reduces bonus effectiveness
        uint32 lastRaidTime;    // Raid cooldown timestamp
        uint16 fortificationLevel; // 0-100, increases defense effectiveness
    }
    
    struct Alliance {
        bytes32 leaderColony;
        address[] members;
        uint256 sharedTreasury;
        uint32 stabilityIndex;
        bool active;
        string name;
        uint8 betrayalCount;        
        uint32 lastBetrayalTime; 
    }
    
    struct DebtRecord {
        uint256 principalDebt;
        uint8 dailyInterestRate;
        uint32 debtStartTime;
        uint32 lastInterestCalculation;
        bool inBankruptcyProtection;
    }
    
    struct ColonyWarsConfig {
        uint8 maxBattleTokens;
        uint32 attackCooldown;
        uint256 minStakeAmount;
        uint256 maxStakeAmount;
        uint8 winnerSharePercentage;
        uint256 dailyMaintenanceCost;
        uint256 territoryCaptureCost;
        uint256 allianceFormationCost;
        uint8 maxAllianceMembers;
        uint32 betrayalCooldown;
        uint8 initialInterestRate;
        uint8 maxInterestRate;
        uint256 emergencyLoanLimit;
        uint32 seasonDuration;
        uint32 registrationPeriod;
        uint32 battleDuration;
        uint32 battlePreparationTime;
        bool initialized;
        uint8 maxTerritoriesPerColony;
        uint32 stakeIncreaseCooldown;
        uint32 stakePenaltyCooldown;
        uint8 autoDefenseTokenCount;      // Default: 3 (max tokens for auto-defense)
        uint8 autoDefensePenalty;         // Default: 30 (30% power penalty for auto-defense)
        bool enableAutoDefense;           // Default: true (enable automatic defense)
        uint32 autoDefenseTimeout;        // Default: 1800 (30 min timeout for active defense)
        uint256 maxGlobalTerritories;
    }

    struct Season {
        uint32 seasonId;
        uint32 startTime;
        uint32 registrationEnd;
        uint32 warfareEnd;
        uint32 resolutionEnd;
        bool active;
        bytes32[] registeredColonies;
        uint256 prizePool;
        bool rewarded;
    }

    struct TerritorySiege {
        uint256 territoryId;
        bytes32 attackerColony;
        bytes32 defenderColony;
        uint256 stakeAmount;
        uint256[] attackerTokens;
        uint256[] defenderTokens;
        uint32 siegeStartTime;
        uint32 siegeEndTime;
        uint8 siegeState; // 0=preparation, 1=active, 2=completed, 3=cancelled
        bytes32 winner;
        uint256 prizePool;
        bool isBetrayalAttack;
    }

    struct SiegeSnapshot {
        uint256[] attackerPowers;
        uint256[] defenderPowers;
        uint256 timestamp;
    }

    struct ForgivenessProposal {
        bytes32 betrayerColony;
        address proposer;
        uint32 voteEnd;
        uint8 yesVotes;
        uint8 totalVotes;
        bool executed;
        bool active;
    }

    // Battle snapshot to prevent manipulation between defend and resolve
    struct BattleSnapshot {
        uint256[] attackerPowers;
        uint256[] defenderPowers;
        uint256 timestamp;
    }

    struct BattleModifiers {
        uint8 winStreakBonus;        // 0-30%, bonus for consecutive wins
        uint8 debtPenalty;           // 0-40%, penalty for high debt
        uint8 territoryBonus;        // 0-15%, bonus per territory
        uint32 winStreakDecayTime;   // Time for streak to decay (seconds)
    }

    // === PHASE 6: Multi-Collection Staking ===
    
    /**
     * @notice Composite ID for multi-collection NFT tracking
     * @dev Stores both collection and token ID to prevent collisions
     */
    struct CompositeCardId {
        uint256 collectionId;  // Which collection this NFT belongs to
        uint256 tokenId;       // Token ID within that collection
    }
    
    /**
     * @notice Enhanced squad staking with multi-collection support
     * @dev FLAT structure - no nested mappings (Diamond Proxy compliance)
     * APPEND-ONLY: resourceCards added at end for storage safety
     */
    struct SquadStakePosition {
        CompositeCardId[] territoryCards;  // All staked Territory Cards with collection info
        CompositeCardId[] infraCards;      // All staked Infrastructure Cards with collection info
        uint32 stakedAt;
        uint16 totalSynergyBonus;         // 0-500 = 0-50%
        uint8 uniqueCollectionsCount;     // Number of different collections in squad
        bool active;
        CompositeCardId[] resourceCards;   // All staked Resource Cards with collection info (ADDED AT END)
    }

    // === PHASE 6: External Contracts Configuration ===
    struct ExternalContracts {
        address territoryCards;
        address infrastructureCards;
        address resourceCards;
    }

    // === PHASE 6: Territory Equipment System ===
    struct TerritoryEquipment {
        uint256[] equippedInfraIds;      // Infrastructure NFT token IDs equipped to territory (from single Infrastructure collection)
        uint16 totalProductionBonus;     // Cached total production bonus from equipment
        uint16 totalDefenseBonus;        // Cached total defense bonus from equipment
        uint8 totalTechBonus;            // Cached total tech bonus from equipment
        uint32 lastEquipmentUpdate;      // Last time equipment was changed
    }

    // === MODUŁ 6: Resource Economy ===
    enum ResourceType { BasicMaterials, EnergyCrystals, BioCompounds, RareElements }
    
    struct ResourceNode {
        uint256 territoryId;         // Territory where node exists
        ResourceType resourceType;   // Type of resource produced
        uint8 nodeLevel;             // 1-10, affects production rate
        uint256 accumulatedResources; // Unharvested resources
        uint32 lastHarvestTime;      // Last harvest timestamp
        uint32 lastMaintenancePaid;  // Last maintenance payment
        bool active;
    }

    struct ResourceBalance {
        uint256 basicMaterials;
        uint256 energyCrystals;
        uint256 bioCompounds;
        uint256 rareElements;
    }

    struct ProcessingRecipe {
        uint8 recipeId;
        ResourceType inputType;
        ResourceType outputType;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 auxCost;             // Auxiliary processing fee
        uint32 processingTime;       // Seconds required
        uint8 requiredTechLevel;     // Minimum tech level
        bool active;
    }

    struct ProcessingOrder {
        bytes32 colonyId;
        uint8 recipeId;
        uint256 inputAmount;
        uint32 startTime;
        uint32 completionTime;
        bool completed;
        bool claimed;
    }

    // === MODUŁ 6: Collaborative Crafting ===
    enum ProjectType { Infrastructure, Research, Defense }
    enum ProjectStatus { Active, Completed, Failed, Cancelled }

    struct ResourceRequirement {
        ResourceType resourceType;
        uint256 amount;
        bool fulfilled;
    }

    struct CollaborativeProject {
        uint256 projectId;
        bytes32 initiatorColony;
        address initiator;
        ProjectType projectType;
        uint8 currentStage;
        uint8 totalStages;
        ProjectStatus status;
        uint32 deadline;
        uint32 completedAt;
        uint256 totalYLWContributions;
        uint256 minYLWContribution;
        uint256 completionRewardPool;
        address[] contributors;
        bool rewardsDistributed;
    }

    struct ContributorShare {
        uint256 ylwContributed;
        uint256 resourcesContributed; // Total value in YLW equivalent
        uint32 contributionTime;
        bool rewardClaimed;
    }

        // === PHASE 5: Alliance Evolution Storage ===

    struct AllianceMission {
        bytes32 allianceId;
        uint8 missionType; // 0=Resource, 1=Battle, 2=Territory
        uint256 targetAmount;
        uint256 currentProgress;
        uint32 deadline;
        uint32 completedAt;
        bool active;
        bool completed;
        bytes32[] contributors;
    }

    struct DiplomaticTreaty {
        bytes32 alliance1;
        bytes32 alliance2;
        uint8 treatyType; // 0=NAP, 1=Trade, 2=Military
        uint32 proposedAt;
        uint32 acceptedAt;
        uint32 expiresAt;
        uint32 duration;
        bool active;
        bool broken;
    }

    // ============================================
    // TASK FORCE SYSTEM
    // ============================================

    /**
     * @notice Task Force - combat group of tokens for battles
     * @dev Tokens must belong to same colony registered in current season
     */
    struct TaskForce {
        bytes32 colonyId;           // Colony owning this task force
        uint32 seasonId;            // Season this task force belongs to
        string name;                // Task force name
        uint256[] collectionIds;    // Collection IDs of member tokens
        uint256[] tokenIds;         // Token IDs of member tokens
        uint32 createdAt;           // Creation timestamp
        bool active;                // Whether task force is active
    }

    /**
     * @notice Alliance Task Force - multi-colony combat group for coordinated attacks
     * @dev Used for coordinated attacks where multiple alliance colonies participate
     */
    struct ColonyTaskForce {
        bytes32 leaderColonyId;     // Colony leading this task force
        bytes32[] memberColonyIds;  // Member colonies participating
        uint32 seasonId;            // Season this task force belongs to
        string name;                // Task force name
        uint256[] collectionIds;    // Collection IDs of tokens from leader
        uint256[] tokenIds;         // Token IDs from leader
        uint32 createdAt;           // Creation timestamp
        bool isActive;              // Whether task force is active
    }

    // ============================================
    // COORDINATED ATTACK CONFIG
    // ============================================

    /**
     * @notice Configuration for coordinated attacks
     */
    struct CoordinatedAttackConfig {
        bool enabled;                       // Whether coordinated attacks are enabled
        uint8 minParticipants;              // Minimum colonies required (default: 2)
        uint8 maxParticipants;              // Maximum colonies allowed (default: 5)
        uint8 maxCoordinatedAttacksPerDay;  // Daily limit per alliance (default: 3)
        uint256 minStakePerParticipant;     // Minimum stake per participating colony
        uint8 bonusDamagePercent;           // Bonus damage for coordinated attacks (default: 15%)
    }

    /**
     * @notice Card mint pricing configuration
     * @dev APPEND-ONLY: Added for public card minting
     */
    struct CardMintPricing {
        uint256[6] infrastructurePrices;    // Price per infra type (0-5), in token wei
        uint256[4] resourcePrices;          // Price per resource type (0-3), in token wei
        uint256[6] territoryPrices;         // Price per territory type (1-5, index 0 unused), in token wei
        address paymentToken;               // ERC20 token for payment (address(0) = use default ZICO)
        uint16 discountBps;                 // Discount in basis points (e.g., 500 = 5%, 2000 = 20%)
        bool useNativePayment;              // true = native currency (ETH/MATIC), false = ERC20
        bool initialized;                   // Whether pricing has been configured
    }

    /**
     * @notice Detailed info about contested zone
     * @dev APPEND-ONLY: Added for zone querying in AllianceEvolutionFacet
     */
    struct ContestedZoneInfo {
        string name;                    // Zone display name
        uint8 status;                   // 0=inactive, 1=contested, 2=controlled
        bytes32 controllerAllianceId;   // Current controller (bytes32(0) if contested/unclaimed)
        uint16 productionBonus;         // Bonus for controller (basis points, e.g., 500 = 5%)
        uint256 contestProgress;        // Progress toward capture (0-10000 = 0-100%)
        uint32 contestStartTime;        // When contestation started
        bool active;                    // Is zone active in current season
    }

    struct ColonyWarsStorage {
        // Storage version for upgrades
        uint256 storageVersion;
        
        // Configuration
        ColonyWarsConfig config;
        ExternalContracts contractAddresses;
        
        // Main data
        mapping(bytes32 => ColonyWarProfile) colonyWarProfiles;
        mapping(bytes32 => BattleInstance) battles;
        mapping(uint256 => Territory) territories;
        mapping(bytes32 => Alliance) alliances;
        mapping(bytes32 => DebtRecord) colonyDebts;
        
        // Seasons
        mapping(uint32 => Season) seasons;
        uint32 currentSeason;
        
        // Season scores extracted from Season struct
        mapping(uint32 => mapping(bytes32 => uint256)) seasonScores; // seasonId => colonyId => score
        
        // Counters
        uint256 battleCounter;
        uint256 territoryCounter;
        
        // Relationships
        mapping(address => bytes32) userToColony;
        mapping(bytes32 => uint256[]) colonyTerritories;
        mapping(address => bytes32) allianceMembership;
        mapping(bytes32 => uint32) lastBetrayalTime;
        
        // Security
        mapping(address => mapping(bytes4 => uint256)) lastActionTime;
        mapping(bytes32 => bool) battleResolved;
        
        // Emergency pause per feature
        mapping(string => bool) featurePaused;

        // Tracking list dla pełnej funkcjonalności
        bytes32[] allAllianceIds;           // Lista wszystkich utworzonych federacji
        mapping(uint32 => bytes32[]) seasonBattles;      // seasonId => battleIds[]
        mapping(uint32 => bytes32[]) seasonAlliances;    // seasonId => allianceIds[] (aktywne w sezonie)
        
        // OPCJONALNIE: Tracking per kolonia
        mapping(bytes32 => bytes32[]) colonyBattleHistory; // colonyId => battleIds[]

        mapping(bytes32 => mapping(address => bool)) allianceOwnershipCheck; // allianceId => (address => isOwner)

        mapping(uint32 => mapping(address => bytes32[])) userSeasonColonies;
        mapping(address => bytes32) userPrimaryColony;

        mapping(bytes32 => TerritorySiege) territorySieges;
        mapping(bytes32 => bool) siegeResolved;
        mapping(bytes32 => SiegeSnapshot) siegeSnapshots;
        uint256 siegeCounter;

        bytes32[] activeSieges;
        mapping(uint256 => bytes32[]) territoryActiveSieges; // territoryId => siegeIds[]
        mapping(uint32 => bytes32[]) seasonSieges; // seasonId => siegeIds[]
        mapping(bytes32 => bytes32[]) colonySiegeHistory; // colonyId => siegeIds[]

        mapping(uint256 => uint32) tokenBattleEndTime;  // tokenId => battle end timestamp
        mapping(bytes32 => uint256) colonyLosses;  // colonyId => accumulated losses

        mapping(bytes32 => mapping(bytes32 => bool)) allianceBetrayals; // allianceId => colonyId => isBetrayerMarked
        mapping(bytes32 => ForgivenessProposal) forgivenessProposals;   // allianceId => proposal
        mapping(bytes32 => mapping(address => bool)) forgivenessVotes;  // allianceId => member => hasVoted

        // Storage for battle snapshots
        mapping(bytes32 => BattleSnapshot) battleSnapshots;

        BattleModifiers battleModifiers;
        mapping(bytes32 => uint8) colonyWinStreaks;
        mapping(bytes32 => uint32) lastWinTime;

        mapping(uint256 => uint256) territoryLastScout;  // observatoryId => last scout timestamp
        mapping(bytes32 => mapping(bytes32 => uint32)) scoutedTargets;      // scoutColony => targetColony => expiry
        mapping(bytes32 => mapping(uint256 => uint32)) scoutedTerritories;  // scoutColony => territoryId => expiry

        mapping(bytes32 => uint32) actionCooldowns;  // actionKey => timestamp
        
        mapping(bytes32 => AllianceInvitation) allianceInvitations; // colonyId => invitation

        mapping(uint32 => mapping(bytes32 => uint8)) seasonColonyLosses; // seasonId => colonyId => losses
        mapping(uint32 => mapping(bytes32 => uint32)) seasonLastLossTime; // seasonId => colonyId => timestamp

        // Territory Trading System
        mapping(uint256 => TerritoryListing) territoryListings;        // territoryId => listing
        mapping(bytes32 => TerritoryOffer) territoryOffers;            // offerId => offer
        mapping(uint256 => bytes32[]) territoryOfferIds;               // territoryId => offerIds[]
        uint256 offerCounter;                                           // Counter for unique offer IDs

        // PHASE 5: Alliance Evolution
        mapping(uint32 => mapping(bytes32 => uint8[])) allianceContestedZones; // season => allianceId => zoneIds[]
        mapping(uint256 => bytes32) currentTerritoryController; // territoryId => colonyId

        // PHASE 6: Territory Card Integration
        mapping(uint256 => uint256) territoryToCard;     // territoryId => cardTokenId
        mapping(uint256 => uint256) cardToTerritory;     // cardTokenId => territoryId
        
        // PHASE 6: Territory Equipment System
        mapping(uint256 => TerritoryEquipment) territoryEquipment; // territoryId => equipment
        mapping(uint256 => uint256) infraEquippedToTerritory;      // infraNFT tokenId => territoryId
        
        // MODUŁ 6: Resource Economy
        mapping(uint256 => ResourceNode) resourceNodes;            // nodeId => node
        mapping(bytes32 => ResourceBalance) colonyResources;       // colonyId => resources
        mapping(uint8 => ProcessingRecipe) processingRecipes;      // recipeId => recipe
        mapping(bytes32 => ProcessingOrder) processingOrders;      // orderId => order
        uint256 resourceNodeCounter;
        uint256 processingOrderCounter;

        mapping(bytes32 => uint256) projectContributions; // projectId => total contributions in YLW

        mapping(bytes32 => AllianceMission) allianceMissions; // missionId => mission
        mapping(bytes32 => DiplomaticTreaty) treaties; // treatyId => treaty
        mapping(bytes32 => DiplomaticTreaty) activeTreaties; // keccak(alliance1+alliance2) => treaty
        mapping(bytes32 => uint256) zoneControlBonuses; // allianceId => bonus%
        
        // ============================================
        // MULTI-COLLECTION SUPPORT
        // ============================================
        
        /**
         * @notice Collection registry for Territory and Infrastructure cards
         * @dev Maps collectionId to CollectionRegistry struct
         */
        mapping(uint256 => CollectionRegistry) collectionRegistry;
        
        /**
         * @notice Counter for registered collections
         */
        uint256 collectionCounter;
        
        /**
         * @notice Reverse lookup: contract address → collectionId
         * @dev Used for quick validation of incoming transfers
         */
        mapping(address => uint256) contractToCollectionId;
        
        /**
         * @notice Per-collection configuration for Territory Cards
         */
        mapping(uint256 => TerritoryCollectionConfig) territoryCollectionConfig;
        
        /**
         * @notice Per-collection configuration for Infrastructure Cards
         */
        mapping(uint256 => InfrastructureCollectionConfig) infraCollectionConfig;
        
        // ============================================
        // SQUAD STAKING (MULTI-COLLECTION)
        // ============================================
        
        /**
         * @notice Squad staking positions per colony
         * @dev Replaces single TeamStakePosition with collection-aware structure
         */
        mapping(bytes32 => SquadStakePosition) colonySquadStakes;
        
        /**
         * @notice Track which collection each staked Territory NFT belongs to
         * @dev Format: (collectionId, tokenId) → colonyId
         */
        mapping(uint256 => mapping(uint256 => bytes32)) stakedTerritoryOwnerByCollection;
        
        /**
         * @notice Track which collection each staked Infrastructure NFT belongs to
         * @dev Format: (collectionId, tokenId) → colonyId
         */
        mapping(uint256 => mapping(uint256 => bytes32)) stakedInfraOwnerByCollection;
        
        /**
         * @notice Quick lookup: Is NFT staked (any collection)?
         * @dev Combined ID = (collectionId << 128) | tokenId
         */
        mapping(uint256 => bool) isTokenStaked;
        
        /**
         * @notice Per-colony, per-collection Territory NFT tracking
         * @dev Format: colonyId → collectionId → tokenIds[]
         */
        mapping(bytes32 => mapping(uint256 => uint256[])) colonyTerritoryByCollection;
        
        /**
         * @notice Per-colony, per-collection Infrastructure NFT tracking
         * @dev Format: colonyId → collectionId → tokenIds[]
         */
        mapping(bytes32 => mapping(uint256 => uint256[])) colonyInfraByCollection;
        
        /**
         * @notice Track which collections each colony has used
         * @dev Format: colonyId → collectionIds[] (for uniqueCollectionsCount)
         */
        mapping(bytes32 => uint256[]) colonyActiveCollections;

        // ============================================
        // OPERATION FEES (Separate from config for flexibility)
        // ============================================

        /**
         * @notice Operation fees mapping
         * @dev Key: keccak256 hash of fee name (e.g., keccak256("raid"))
         * Use FEE_* constants for keys
         */
        mapping(bytes32 => OperationFee) operationFees;
        
        // ============================================
        // RESOURCE CARD SUPPORT (APPEND-ONLY)
        // ============================================
        
        /**
         * @notice Track which collection each staked Resource NFT belongs to
         * @dev Format: (collectionId, tokenId) → colonyId
         */
        mapping(uint256 => mapping(uint256 => bytes32)) stakedResourceOwnerByCollection;
        
        /**
         * @notice Per-colony, per-collection Resource NFT tracking
         * @dev Format: colonyId → collectionId → tokenIds[]
         */
        mapping(bytes32 => mapping(uint256 => uint256[])) colonyResourceByCollection;

        // ============================================
        // TASK FORCE SYSTEM (APPEND-ONLY)
        // ============================================

        /**
         * @notice Task force storage by ID
         * @dev taskForceId => TaskForce
         */
        mapping(bytes32 => TaskForce) taskForces;

        /**
         * @notice Task force counter for unique IDs
         */
        uint256 taskForceCounter;

        /**
         * @notice Colony's task forces for a season
         * @dev colonyId => seasonId => taskForceIds[]
         */
        mapping(bytes32 => mapping(uint32 => bytes32[])) colonyTaskForces;

        /**
         * @notice Token to task force mapping (prevents token from being in multiple task forces)
         * @dev seasonId => combinedTokenId => taskForceId (0 if not assigned)
         */
        mapping(uint32 => mapping(uint256 => bytes32)) tokenToTaskForce;

        // ============================================
        // TERRITORY CAPTURE PRIORITY (APPEND-ONLY)
        // ============================================

        /**
         * @notice Track the siege that destroyed a territory (brought damageLevel to 100)
         * @dev territoryId => siegeId (used for 1-hour capture priority window)
         * Attacker from this siege has exclusive capture rights for 1 hour after destruction
         */
        mapping(uint256 => bytes32) lastDestroyingSiegeId;

        // ============================================
        // COORDINATED ATTACK LIMITS (APPEND-ONLY)
        // ============================================

        /**
         * @notice Daily coordinated attack count per alliance
         * @dev allianceId => dayTimestamp => count
         * Used to enforce maxCoordinatedAttacksPerDay limit
         */
        mapping(bytes32 => mapping(uint256 => uint8)) allianceDailyCoordinatedAttacks;

        // ============================================
        // COORDINATED ATTACK SYSTEM (APPEND-ONLY)
        // ============================================

        /**
         * @notice Configuration for coordinated attacks
         */
        CoordinatedAttackConfig coordinatedAttackConfig;

        /**
         * @notice Alliance task forces for coordinated attacks
         * @dev taskForceId => ColonyTaskForce
         */
        mapping(bytes32 => ColonyTaskForce) allianceTaskForces;

        /**
         * @notice Counter for unique alliance task force IDs
         */
        uint256 allianceTaskForceCounter;

        // ============================================
        // CARD MINT PRICING (APPEND-ONLY)
        // ============================================

        /**
         * @notice Configurable pricing for public card minting
         * @dev Allows admins to adjust prices without contract upgrade
         */
        CardMintPricing cardMintPricing;

        // ============================================
        // ALLIANCE EVOLUTION TRACKING (APPEND-ONLY)
        // ============================================

        /**
         * @notice List of mission IDs per alliance
         * @dev allianceId => missionIds[]
         */
        mapping(bytes32 => bytes32[]) allianceMissionIds;

        /**
         * @notice List of treaty IDs per alliance (as proposer or target)
         * @dev allianceId => treatyIds[]
         */
        mapping(bytes32 => bytes32[]) allianceTreatyIds;

        /**
         * @notice Pending treaty proposals awaiting acceptance
         * @dev targetAllianceId => treatyIds[] (only pending, removed on accept/reject)
         */
        mapping(bytes32 => bytes32[]) pendingTreatyProposals;

        /**
         * @notice Contested zone detailed info
         * @dev zoneId => ContestedZoneInfo
         */
        mapping(uint256 => ContestedZoneInfo) contestedZoneInfo;

        /**
         * @notice Alliances contesting a zone (challengers)
         * @dev zoneId => allianceIds[]
         */
        mapping(uint256 => bytes32[]) zoneChallengers;

        /**
         * @notice List of all contested zone IDs per season
         * @dev season => zoneIds[]
         */
        mapping(uint32 => uint256[]) seasonContestedZones;
    }

    function colonyWarsStorage() internal pure returns (ColonyWarsStorage storage cws) {
        bytes32 position = COLONY_WARS_STORAGE_POSITION;
        assembly {
            cws.slot := position
        }
    }

    /**
     * @notice Initialize storage with default values
     */
    function initializeStorage() internal {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        
        if (cws.config.initialized) {
            return; // Already initialized
        }
        
        // Set default values
        cws.config.maxBattleTokens = 15;
        cws.config.attackCooldown = 21600; // 6 hours
        cws.config.minStakeAmount = 100 ether;
        cws.config.maxStakeAmount = 10000 ether;
        cws.config.winnerSharePercentage = 70;
        cws.config.dailyMaintenanceCost = 50 ether;
        cws.config.territoryCaptureCost = 500 ether;
        cws.config.allianceFormationCost = 1000 ether;
        cws.config.maxAllianceMembers = 6;
        cws.config.betrayalCooldown = 14 days;
        cws.config.initialInterestRate = 2;
        cws.config.maxInterestRate = 20;
        cws.config.emergencyLoanLimit = 2000 ether;
        cws.config.seasonDuration = 28 days;
        cws.config.registrationPeriod = 7 days;
        cws.config.battleDuration = 7200; // 2 hours
        cws.config.battlePreparationTime = 3600; // 1 hour
        cws.config.stakeIncreaseCooldown = 604800; // 7 days default
        cws.config.stakePenaltyCooldown = 86400; // 1 day default
        cws.config.initialized = true;
        cws.config.autoDefenseTokenCount = 3;
        cws.config.autoDefensePenalty = 80;
        cws.config.enableAutoDefense = true;
        cws.config.autoDefenseTimeout = 1800; // 30 minutes 
        cws.config.maxTerritoriesPerColony = 6;
        cws.config.maxGlobalTerritories = 50;

        cws.storageVersion = 2;
        cws.currentSeason = 2;
    }

    /**
     * @notice Initialize operation fees with treasury context
     * @dev Must be called after HenomorphsStorage is initialized
     * @param treasuryAddress Treasury wallet address
     * @param auxiliaryCurrency Auxiliary token (YELLOW) address
     */
    function initializeOperationFees(
        address treasuryAddress,
        address auxiliaryCurrency
    ) internal {
        ColonyWarsStorage storage cws = colonyWarsStorage();

        // Raid Fee - 5000 auxiliary token, burned
        cws.operationFees[FEE_RAID] = OperationFee({
            currency: auxiliaryCurrency,
            beneficiary: treasuryAddress,
            baseAmount: 5000 ether,
            multiplier: 100, // 1x
            burnOnCollect: true,
            enabled: true
        });

        // Maintenance Fee - 5000 auxiliary token, burned
        cws.operationFees[FEE_MAINTENANCE] = OperationFee({
            currency: auxiliaryCurrency,
            beneficiary: treasuryAddress,
            baseAmount: 5000 ether,
            multiplier: 100, // 1x
            burnOnCollect: true,
            enabled: true
        });

        // Repair Fee - 100 auxiliary token per damage point, burned
        cws.operationFees[FEE_REPAIR] = OperationFee({
            currency: auxiliaryCurrency,
            beneficiary: treasuryAddress,
            baseAmount: 100 ether,
            multiplier: 100, // 1x per damage point
            burnOnCollect: true,
            enabled: true
        });

        // Scouting Fee - 2000 auxiliary token, burned
        cws.operationFees[FEE_SCOUTING] = OperationFee({
            currency: auxiliaryCurrency,
            beneficiary: treasuryAddress,
            baseAmount: 2000 ether,
            multiplier: 100, // 1x
            burnOnCollect: true,
            enabled: true
        });

        // Healing Fee - 1000 auxiliary token per token, burned
        cws.operationFees[FEE_HEALING] = OperationFee({
            currency: auxiliaryCurrency,
            beneficiary: treasuryAddress,
            baseAmount: 1000 ether,
            multiplier: 100, // 1x per token healed
            burnOnCollect: true,
            enabled: true
        });

        // Resource Processing Fee - 500 auxiliary token, burned
        cws.operationFees[FEE_PROCESSING] = OperationFee({
            currency: auxiliaryCurrency,
            beneficiary: treasuryAddress,
            baseAmount: 500 ether,
            multiplier: 100, // 1x
            burnOnCollect: true,
            enabled: true
        });

        // Marketplace Listing Fee - 1000 auxiliary token, burned
        cws.operationFees[FEE_LISTING] = OperationFee({
            currency: auxiliaryCurrency,
            beneficiary: treasuryAddress,
            baseAmount: 1000 ether,
            multiplier: 100, // 1x
            burnOnCollect: true,
            enabled: true
        });

        // Crafting Fee - 500 auxiliary token, burned
        cws.operationFees[FEE_CRAFTING] = OperationFee({
            currency: auxiliaryCurrency,
            beneficiary: treasuryAddress,
            baseAmount: 500 ether,
            multiplier: 100, // 1x
            burnOnCollect: true,
            enabled: true
        });

        // === Charge/Repair/Specialization Fees ===

        // Charge Repair Fee - 10 auxiliary token per point, burned
        cws.operationFees[FEE_CHARGE_REPAIR] = OperationFee({
            currency: auxiliaryCurrency,
            beneficiary: treasuryAddress,
            baseAmount: 10 ether,
            multiplier: 100, // 1x per charge point
            burnOnCollect: true,
            enabled: true
        });

        // Wear Repair Fee - 10 auxiliary token per point, 2x multiplier, burned
        cws.operationFees[FEE_WEAR_REPAIR] = OperationFee({
            currency: auxiliaryCurrency,
            beneficiary: treasuryAddress,
            baseAmount: 10 ether,
            multiplier: 200, // 2x per wear point
            burnOnCollect: true,
            enabled: true
        });

        // Charge Boost Fee - 50 auxiliary token per hour, burned
        cws.operationFees[FEE_CHARGE_BOOST] = OperationFee({
            currency: auxiliaryCurrency,
            beneficiary: treasuryAddress,
            baseAmount: 50 ether,
            multiplier: 100, // 1x per hour
            burnOnCollect: true,
            enabled: true
        });

        // Action Fee - 5 auxiliary token per action, burned
        cws.operationFees[FEE_ACTION] = OperationFee({
            currency: auxiliaryCurrency,
            beneficiary: treasuryAddress,
            baseAmount: 5 ether,
            multiplier: 100, // 1x
            burnOnCollect: true,
            enabled: true
        });

        // Specialization Fee - 100 auxiliary token, burned
        cws.operationFees[FEE_SPECIALIZATION] = OperationFee({
            currency: auxiliaryCurrency,
            beneficiary: treasuryAddress,
            baseAmount: 100 ether,
            multiplier: 100, // 1x
            burnOnCollect: true,
            enabled: true
        });

        // Mastery Action Fee - 10 auxiliary token base, 2x multiplier, burned
        cws.operationFees[FEE_MASTERY_ACTION] = OperationFee({
            currency: auxiliaryCurrency,
            beneficiary: treasuryAddress,
            baseAmount: 10 ether,
            multiplier: 200, // 2x
            burnOnCollect: true,
            enabled: true
        });

        // Inspection Fee - 1 auxiliary token base, 1x multiplier, burned
        cws.operationFees[FEE_INSPECTION] = OperationFee({
            currency: auxiliaryCurrency,
            beneficiary: treasuryAddress,
            baseAmount: 10 ether,
            multiplier: 100, // 1x
            burnOnCollect: true,
            enabled: true
        });
    }

    // ============================================
    // OPERATION FEE HELPERS
    // ============================================

    /**
     * @notice Get operation fee by key
     * @param feeKey The fee key (use FEE_* constants or keccak256 of fee name)
     * @return fee The OperationFee struct
     */
    function getOperationFee(bytes32 feeKey) internal view returns (OperationFee storage) {
        return colonyWarsStorage().operationFees[feeKey];
    }

    /**
     * @notice Get operation fee by string name
     * @param feeName The fee name (e.g., "raid", "maintenance")
     * @return fee The OperationFee struct
     */
    function getOperationFeeByName(string memory feeName) internal view returns (OperationFee storage) {
        return colonyWarsStorage().operationFees[keccak256(bytes(feeName))];
    }

    /**
     * @notice Set operation fee by key
     * @param feeKey The fee key (use FEE_* constants or keccak256 of fee name)
     * @param fee The OperationFee configuration
     */
    function setOperationFee(bytes32 feeKey, OperationFee memory fee) internal {
        colonyWarsStorage().operationFees[feeKey] = fee;
    }

    /**
     * @notice Set operation fee by string name
     * @param feeName The fee name (e.g., "raid", "maintenance")
     * @param fee The OperationFee configuration
     */
    function setOperationFeeByName(string memory feeName, OperationFee memory fee) internal {
        colonyWarsStorage().operationFees[keccak256(bytes(feeName))] = fee;
    }

    /**
     * @notice Check if storage is initialized
     */
    function requireInitialized() internal view {
        if (!colonyWarsStorage().config.initialized) {
            revert ColonyWarsNotInitialized();
        }
    }

    /**
     * @notice Rate limiting helper
     */
    function checkRateLimit(address user, bytes4 selector, uint256 cooldown) internal returns (bool) {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        
        if (block.timestamp < cws.lastActionTime[user][selector] + cooldown) {
            return false;
        }
        
        cws.lastActionTime[user][selector] = block.timestamp;
        return true;
    }

    /**
     * @notice Check if feature is paused
     */
    function requireFeatureNotPaused(string memory featureName) internal view {
        if (colonyWarsStorage().featurePaused[featureName]) {
            revert InvalidConfiguration(string(abi.encodePacked("Feature paused: ", featureName)));
        }
    }

    /**
     * @notice Helper to get colony score for season
     */
    function getColonyScore(uint32 seasonId, bytes32 colonyId) internal view returns (uint256) {
        return colonyWarsStorage().seasonScores[seasonId][colonyId];
    }

    /**
     * @notice Helper to set colony score for season
     */
    function setColonyScore(uint32 seasonId, bytes32 colonyId, uint256 score) internal {
        colonyWarsStorage().seasonScores[seasonId][colonyId] = score;
    }

    /**
     * @notice Helper to add to colony score for season
     */
    function addColonyScore(uint32 seasonId, bytes32 colonyId, uint256 points) internal {
        colonyWarsStorage().seasonScores[seasonId][colonyId] += points;
    }

    /**
     * @notice Safely add alliance member
     */
    function addAllianceMember(bytes32 allianceId, address member) internal {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        Alliance storage alliance = cws.alliances[allianceId];
        
        if (alliance.members.length >= cws.config.maxAllianceMembers) {
            revert InvalidConfiguration("Alliance at capacity");
        }
        
        bytes32 memberColony = getUserPrimaryColony(member);
        if (memberColony == bytes32(0)) {
            revert InvalidConfiguration("User has no registered colony");
        }
        
        address colonyOwner = LibHenomorphsStorage.henomorphsStorage().colonyCreators[memberColony];
        
        if (cws.allianceOwnershipCheck[allianceId][colonyOwner]) {
            revert InvalidConfiguration("Owner already has colony in this alliance");
        }
        
        alliance.members.push(member);
        cws.allianceMembership[member] = allianceId;
        cws.allianceOwnershipCheck[allianceId][colonyOwner] = true;
    }

    /**
     * @notice Safely remove alliance member
     */
    function removeAllianceMember(bytes32 allianceId, address member) internal {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        Alliance storage alliance = cws.alliances[allianceId];
        
        bytes32 memberColony = getUserPrimaryColony(member);
        address colonyOwner = LibHenomorphsStorage.henomorphsStorage().colonyCreators[memberColony];
        
        for (uint256 i = 0; i < alliance.members.length; i++) {
            if (alliance.members[i] == member) {
                alliance.members[i] = alliance.members[alliance.members.length - 1];
                alliance.members.pop();
                break;
            }
        }
        
        delete cws.allianceMembership[member];
        delete cws.allianceOwnershipCheck[allianceId][colonyOwner];
        
        if (alliance.members.length < 2) {
            alliance.active = false;
        }
    }

    /**
     * @notice Check if colony owner already has a colony in the specified alliance
     * @param allianceId The alliance to check
     * @param colonyOwner The owner address to check
     * @return hasColony True if owner already has a colony in this alliance
     */
    function hasOwnershipInAlliance(bytes32 allianceId, address colonyOwner) internal view returns (bool hasColony) {
        return colonyWarsStorage().allianceOwnershipCheck[allianceId][colonyOwner];
    }

    /**
     * @notice Get alliance ID for user address
     */
    function getUserAllianceId(address user) internal view returns (bytes32) {
        return colonyWarsStorage().allianceMembership[user];
    }

    /**
     * @notice Check if user is in any alliance
     */
    function isUserInAlliance(address user) internal view returns (bool) {
        return colonyWarsStorage().allianceMembership[user] != bytes32(0);
    }

    /**
     * @notice Check if user is alliance leader
     */
    function isAllianceLeader(bytes32 allianceId, address user) internal view returns (bool) {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        Alliance storage alliance = cws.alliances[allianceId];
        bytes32 userColony = getUserPrimaryColony(user);
        return alliance.leaderColony == userColony && alliance.active;
    }

    /**
     * @notice Get user's colonies for specific season
     */
    function getUserSeasonColonies(uint32 seasonId, address user) internal view returns (bytes32[] memory) {
        return colonyWarsStorage().userSeasonColonies[seasonId][user];
    }

    /**
     * @notice Add colony to user's season tracking
     */
    function addUserSeasonColony(uint32 seasonId, address user, bytes32 colonyId) internal {
        colonyWarsStorage().userSeasonColonies[seasonId][user].push(colonyId);
    }

    /**
     * @notice Get user's primary colony for alliance purposes
     */
    function getUserPrimaryColony(address user) internal view returns (bytes32) {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        bytes32 primary = cws.userPrimaryColony[user];
        
        // Fallback to userToColony if no primary set (dla backward compatibility)
        if (primary == bytes32(0)) {
            primary = cws.userToColony[user];
        }
        
        return primary;
    }

    /**
     * @notice Set user's primary colony
     */
    function setUserPrimaryColony(address user, bytes32 colonyId) internal {
        colonyWarsStorage().userPrimaryColony[user] = colonyId;
    }

    /**
     * @notice Reserve tokens until battle ends
     */
    function reserveTokensForBattle(uint256[] memory tokenIds, uint32 battleEndTime) internal {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        for (uint256 i = 0; i < tokenIds.length; i++) {
            cws.tokenBattleEndTime[tokenIds[i]] = battleEndTime;
        }
    }

    /**
     * @notice Check if token is available for battle (auto-cleanup)
     */
    function isTokenAvailableForBattle(uint256 tokenId) internal view returns (bool) {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        return cws.tokenBattleEndTime[tokenId] <= uint32(block.timestamp);
    }

    /**
     * @notice Release token immediately (for resolved battles)
     */
    function releaseToken(uint256 tokenId) internal {
        colonyWarsStorage().tokenBattleEndTime[tokenId] = 0;
    }

    /**
     * @notice Internal validation and processing of alliance betrayal
     * @param attacker Address of the attacking user
     * @param attackerColony Attacking colony ID
     * @param targetColony Target colony ID (defender or territory owner)
     * @return isBetrayal True if this constitutes betrayal
     * @return allianceId Alliance ID if betrayal detected
     */
    function validateAndProcessBetrayal(
        address attacker,
        bytes32 attackerColony,
        bytes32 targetColony,
        string memory
    ) internal returns (bool isBetrayal, bytes32 allianceId) {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        
        // Get attacker's alliance
        bytes32 attackerAllianceId = getUserAllianceId(attacker);
        if (attackerAllianceId == bytes32(0)) {
            return (false, bytes32(0)); // Not in alliance, no betrayal possible
        }
        
        // Get target's alliance
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        address targetOwner = hs.colonyCreators[targetColony];
        if (targetOwner == address(0)) {
            return (false, bytes32(0)); // Invalid target
        }
        
        bytes32 targetAllianceId = getUserAllianceId(targetOwner);
        
        // Check if same alliance (betrayal condition)
        if (attackerAllianceId != targetAllianceId) {
            return (false, bytes32(0)); // Different alliances, no betrayal
        }
        
        // Additional safety checks
        if (attackerColony == targetColony) {
            return (false, bytes32(0)); // Cannot betray yourself
        }
        
        // NEW: Check if target colony has alliance protection
        // Only betrayal if target colony actually gets alliance bonuses
        bytes32 targetPrimary = getUserPrimaryColony(targetOwner);
        
        bool targetHasProtection = false;
        if (targetColony == targetPrimary) {
            // Primary colony always has protection
            targetHasProtection = true;
        } else if (isUserRegisteredColony(targetOwner, targetColony)) {
            // Additional registered colonies have partial protection
            targetHasProtection = true;
        }
        // Unregistered colonies have no protection = no betrayal
        
        if (!targetHasProtection) {
            return (false, bytes32(0)); // Target has no alliance protection = no betrayal
        }
        
        // Betrayal detected - process it
        markAllianceBetrayal(attackerAllianceId, attackerColony);
        
        // Set individual betrayal cooldown
        cws.lastBetrayalTime[attackerColony] = uint32(block.timestamp);
        
        // Auto-remove betrayer from alliance
        removeAllianceMember(attackerAllianceId, attacker);
        
        return (true, attackerAllianceId);
    }

    /**
     * @notice Mark colony as betrayer in alliance
     */
    function markAllianceBetrayal(bytes32 allianceId, bytes32 betrayerColony) internal {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        Alliance storage alliance = cws.alliances[allianceId];
        
        // Mark betrayal
        cws.allianceBetrayals[allianceId][betrayerColony] = true;
        alliance.betrayalCount++;
        alliance.lastBetrayalTime = uint32(block.timestamp);
        
        // Severe stability penalty
        if (alliance.stabilityIndex > 50) {
            alliance.stabilityIndex -= 50;
        } else {
            alliance.stabilityIndex = 0;
        }
    }

    /**
     * @notice Check if colony is marked as betrayer in alliance
     */
    function isMarkedBetrayerInAlliance(bytes32 allianceId, bytes32 colonyId) internal view returns (bool) {
        return colonyWarsStorage().allianceBetrayals[allianceId][colonyId];
    }

    /**
     * @notice Clear betrayal mark (for forgiveness)
     */
    function clearBetrayalMark(bytes32 allianceId, bytes32 colonyId) internal {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        cws.allianceBetrayals[allianceId][colonyId] = false;
        
        // Partial stability recovery
        Alliance storage alliance = cws.alliances[allianceId];
        alliance.stabilityIndex += 15;
        if (alliance.stabilityIndex > 100) alliance.stabilityIndex = 100;
    }

    /**
     * @notice Get alliance betrayal statistics
     */
    function getAllianceBetrayalStats(bytes32 allianceId) internal view returns (uint8 betrayalCount, uint32 lastBetrayalTime) {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        Alliance storage alliance = cws.alliances[allianceId];
        return (alliance.betrayalCount, alliance.lastBetrayalTime);
    }

    function getTerritoryActionKey(uint256 territoryId, string memory actionType) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("territory", territoryId, actionType));
    }

    function getWalletActionKey(address wallet, bytes4 selector) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("wallet", wallet, selector));
    }

    function checkActionCooldown(uint256 territoryId, string memory actionType, uint32 cooldownPeriod) 
        internal returns (bool) {
        ColonyWarsStorage storage cws = colonyWarsStorage();

        bytes32 actionKey = getTerritoryActionKey(territoryId, actionType);
        if (block.timestamp < cws.actionCooldowns[actionKey] + cooldownPeriod) {
            return false;
        }
        cws.actionCooldowns[actionKey] = uint32(block.timestamp);
        return true;
    }

    function checkWalletCooldown(address user, bytes4 selector, uint32 cooldownPeriod) 
        internal returns (bool) {
        ColonyWarsStorage storage cws = colonyWarsStorage();

        bytes32 actionKey = getWalletActionKey(user, selector);
        if (block.timestamp < cws.actionCooldowns[actionKey] + cooldownPeriod) {
            return false;
        }
        cws.actionCooldowns[actionKey] = uint32(block.timestamp);
        return true;
    }

    /**
     * @notice Helper function to check if colony is registered by user for current season
     * @param user User address
     * @param colonyId Colony to check
     * @return isRegistered True if colony is registered by user for current season
     */
    function isUserRegisteredColony(
        address user,
        bytes32 colonyId
    ) internal view returns (bool isRegistered) {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        // Check if colony is registered for current season
        if (!cws.colonyWarProfiles[colonyId].registered) {
            return false;
        }
        
        // Check if colony belongs to user's registered colonies for this season
        bytes32[] memory userColonies = getUserSeasonColonies(cws.currentSeason, user);
        
        for (uint256 i = 0; i < userColonies.length; i++) {
            if (userColonies[i] == colonyId) {
                return true;
            }
        }
        
        return false;
    }
    
    // ============================================
    // MULTI-COLLECTION STAKING HELPERS
    // ============================================
    
    /**
     * @notice Register a new collection for Territory or Infrastructure cards
     * @param contractAddress The ERC721 contract address
     * @param collectionType 1=Territory, 2=Infrastructure
     * @param name Collection name
     * @return collectionId The assigned collection ID
     */
    function registerCollection(
        address contractAddress,
        uint8 collectionType,
        string memory name
    ) internal returns (uint256 collectionId) {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        
        // Validate collection type
        if (collectionType != COLLECTION_TYPE_TERRITORY && 
            collectionType != COLLECTION_TYPE_INFRASTRUCTURE) {
            revert InvalidCollectionType(collectionType);
        }
        
        // Check if contract already registered
        if (cws.contractToCollectionId[contractAddress] != 0) {
            revert ContractAlreadyRegistered(contractAddress);
        }
        
        // Increment counter and assign ID
        cws.collectionCounter++;
        collectionId = cws.collectionCounter;
        
        // Store registry entry
        CollectionRegistry storage registry = cws.collectionRegistry[collectionId];
        registry.contractAddress = contractAddress;
        registry.collectionType = collectionType;
        registry.enabled = true;
        registry.registeredAt = uint32(block.timestamp);
        registry.name = name;
        
        // Store reverse lookup
        cws.contractToCollectionId[contractAddress] = collectionId;
        
        return collectionId;
    }
    
    /**
     * @notice Get collection ID for contract address
     * @param contractAddress The ERC721 contract address
     * @return collectionId The collection ID (0 if not registered)
     */
    function getCollectionId(address contractAddress) internal view returns (uint256) {
        return colonyWarsStorage().contractToCollectionId[contractAddress];
    }
    
    /**
     * @notice Verify if collection is registered and enabled
     * @param collectionId The collection ID to check
     */
    function requireCollectionEnabled(uint256 collectionId) internal view {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        CollectionRegistry storage registry = cws.collectionRegistry[collectionId];
        
        if (registry.contractAddress == address(0)) {
            revert CollectionNotRegistered(collectionId);
        }
        
        if (!registry.enabled) {
            revert InvalidConfiguration("Collection disabled");
        }
    }
    
    /**
     * @notice Get collection registry entry
     * @param collectionId The collection ID to query
     * @return registry The CollectionRegistry struct
     */
    function getCollectionRegistry(uint256 collectionId) internal view returns (CollectionRegistry memory) {
        return colonyWarsStorage().collectionRegistry[collectionId];
    }
    
    /**
     * @notice Mark NFT as staked with full multi-collection tracking
     * @param collectionId Collection ID
     * @param tokenId Token ID within collection
     * @param colonyId Colony that staked the NFT
     * @param isTerritory True for Territory, false for Infrastructure/Resource
     * @param isResource True for Resource, false for Territory/Infrastructure
     */
    function markTokenStaked(
        uint256 collectionId,
        uint256 tokenId,
        bytes32 colonyId,
        bool isTerritory,
        bool isResource
    ) internal {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        
        // 1. Mark in collection-specific ownership mapping
        if (isTerritory) {
            cws.stakedTerritoryOwnerByCollection[collectionId][tokenId] = colonyId;
            cws.colonyTerritoryByCollection[colonyId][collectionId].push(tokenId);
        } else if (isResource) {
            cws.stakedResourceOwnerByCollection[collectionId][tokenId] = colonyId;
            cws.colonyResourceByCollection[colonyId][collectionId].push(tokenId);
        } else {
            cws.stakedInfraOwnerByCollection[collectionId][tokenId] = colonyId;
            cws.colonyInfraByCollection[colonyId][collectionId].push(tokenId);
        }
        
        // 2. Mark in global lookup
        uint256 combinedId = (collectionId << 128) | tokenId;
        cws.isTokenStaked[combinedId] = true;

        // 3. Add to squad position with CompositeCardId
        addCardToSquad(colonyId, collectionId, tokenId, isTerritory, isResource);
        
        // 4. Update unique collections tracking if needed
        _addCollectionIfNew(colonyId, collectionId);
    }
    
    /**
     * @notice Mark NFT as unstaked with full multi-collection cleanup
     * @param collectionId Collection ID
     * @param tokenId Token ID within collection
     * @param colonyId Colony that owned the NFT
     * @param isTerritory True for Territory, false for Infrastructure/Resource
     * @param isResource True for Resource, false for Territory/Infrastructure
     */
    function markTokenUnstaked(
        uint256 collectionId,
        uint256 tokenId,
        bytes32 colonyId,
        bool isTerritory,
        bool isResource
    ) internal {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        
        // 1. Clear collection-specific ownership mapping
        if (isTerritory) {
            delete cws.stakedTerritoryOwnerByCollection[collectionId][tokenId];
            _removeTokenFromArray(cws.colonyTerritoryByCollection[colonyId][collectionId], tokenId);
        } else if (isResource) {
            delete cws.stakedResourceOwnerByCollection[collectionId][tokenId];
            _removeTokenFromArray(cws.colonyResourceByCollection[colonyId][collectionId], tokenId);
        } else {
            delete cws.stakedInfraOwnerByCollection[collectionId][tokenId];
            _removeTokenFromArray(cws.colonyInfraByCollection[colonyId][collectionId], tokenId);
        }
        
        // 2. Clear global lookup
        uint256 combinedId = (collectionId << 128) | tokenId;
        delete cws.isTokenStaked[combinedId];
        
        // 3. Remove from squad position
        removeCardFromSquad(colonyId, collectionId, tokenId, isTerritory, isResource);
        
        // 4. Update unique collections tracking if collection now empty
        _removeCollectionIfEmpty(colonyId, collectionId, isTerritory, isResource);
    }
    
    /**
     * @notice Check if NFT is currently staked (any colony)
     * @param collectionId Collection ID
     * @param tokenId Token ID within collection
     * @return isStaked True if NFT is currently staked
     */
    function isNFTStaked(
        uint256 collectionId,
        uint256 tokenId
    ) internal view returns (bool) {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        uint256 combinedId = (collectionId << 128) | tokenId;
        return cws.isTokenStaked[combinedId];
    }
    
    /**
     * @notice Get colony that staked specific NFT
     * @param collectionId Collection ID
     * @param tokenId Token ID within collection
     * @param isTerritory True for Territory, false for Infrastructure/Resource
     * @param isResource True for Resource, false for Territory/Infrastructure
     * @return colonyId Colony that staked this NFT (bytes32(0) if not staked)
     */
    function getTokenStakedBy(
        uint256 collectionId,
        uint256 tokenId,
        bool isTerritory,
        bool isResource
    ) internal view returns (bytes32) {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        
        if (isTerritory) {
            return cws.stakedTerritoryOwnerByCollection[collectionId][tokenId];
        } else if (isResource) {
            return cws.stakedResourceOwnerByCollection[collectionId][tokenId];
        } else {
            return cws.stakedInfraOwnerByCollection[collectionId][tokenId];
        }
    }
    
    /**
     * @notice Create combined ID for collection+token lookup
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return combinedId Combined identifier
     */
    function getCombinedId(uint256 collectionId, uint256 tokenId) internal pure returns (uint256) {
        return (collectionId << 128) | tokenId;
    }
    
    /**
     * @notice Get all staked NFTs for a colony from specific collection
     * @param colonyId Colony to query
     * @param collectionId Collection to query
     * @param isTerritory True for Territory, false for Infrastructure/Resource
     * @param isResource True for Resource, false for Territory/Infrastructure
     * @return tokenIds Array of staked token IDs
     */
    function getColonyCardsByCollection(
        bytes32 colonyId,
        uint256 collectionId,
        bool isTerritory,
        bool isResource
    ) internal view returns (uint256[] memory) {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        
        if (isTerritory) {
            return cws.colonyTerritoryByCollection[colonyId][collectionId];
        } else if (isResource) {
            return cws.colonyResourceByCollection[colonyId][collectionId];
        } else {
            return cws.colonyInfraByCollection[colonyId][collectionId];
        }
    }
    
    /**
     * @notice Get all active collections for a colony
     * @param colonyId Colony to query
     * @return collectionIds Array of collection IDs used by this colony
     */
    function getColonyActiveCollections(bytes32 colonyId) internal view returns (uint256[] memory) {
        return colonyWarsStorage().colonyActiveCollections[colonyId];
    }
    
    /**
     * @notice Add composite NFT to squad position
     * @param colonyId Colony ID
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param isTerritory True for Territory, false for Infrastructure/Resource
     * @param isResource True for Resource, false for Territory/Infrastructure
     */
    function addCardToSquad(
        bytes32 colonyId,
        uint256 collectionId,
        uint256 tokenId,
        bool isTerritory,
        bool isResource
    ) internal {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        SquadStakePosition storage squad = cws.colonySquadStakes[colonyId];
        
        CompositeCardId memory compositeId = CompositeCardId({
            collectionId: collectionId,
            tokenId: tokenId
        });
        
        if (isTerritory) {
            squad.territoryCards.push(compositeId);
        } else if (isResource) {
            squad.resourceCards.push(compositeId);
        } else {
            squad.infraCards.push(compositeId);
        }
    }
    
    /**
     * @notice Remove composite NFT from squad position
     * @param colonyId Colony ID
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param isTerritory True for Territory, false for Infrastructure/Resource
     * @param isResource True for Resource, false for Territory/Infrastructure
     */
    function removeCardFromSquad(
        bytes32 colonyId,
        uint256 collectionId,
        uint256 tokenId,
        bool isTerritory,
        bool isResource
    ) internal {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        SquadStakePosition storage squad = cws.colonySquadStakes[colonyId];

        CompositeCardId[] storage cardArray;
        if (isTerritory) {
            cardArray = squad.territoryCards;
        } else if (isResource) {
            cardArray = squad.resourceCards;
        } else {
            cardArray = squad.infraCards;
        }

        for (uint256 i = 0; i < cardArray.length; i++) {
            if (cardArray[i].collectionId == collectionId && cardArray[i].tokenId == tokenId) {
                cardArray[i] = cardArray[cardArray.length - 1];
                cardArray.pop();
                break;
            }
        }
    }
    
    /**
     * @notice Get squad stake position for colony
     * @param colonyId Colony to query
     * @return squad The SquadStakePosition struct
     */
    function getSquadStakePosition(bytes32 colonyId) internal view returns (SquadStakePosition storage) {
        return colonyWarsStorage().colonySquadStakes[colonyId];
    }
    
    // ============================================
    // INTERNAL HELPERS (PRIVATE)
    // ============================================
    
    /**
     * @notice Add collection to active list if not already present
     * @param colonyId Colony ID
     * @param collectionId Collection ID to add
     */
    function _addCollectionIfNew(bytes32 colonyId, uint256 collectionId) private {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        uint256[] storage activeCollections = cws.colonyActiveCollections[colonyId];
        
        // Check if collection already in array
        for (uint256 i = 0; i < activeCollections.length; i++) {
            if (activeCollections[i] == collectionId) {
                return; // Already exists
            }
        }
        
        // Add new collection
        activeCollections.push(collectionId);
    }
    
    /**
     * @notice Remove collection from active list if no more NFTs from it
     * @param colonyId Colony ID
     * @param collectionId Collection ID to potentially remove
     */
    function _removeCollectionIfEmpty(
        bytes32 colonyId,
        uint256 collectionId,
        bool,
        bool
    ) private {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        
        // Check if collection still has staked NFTs
        bool hasTerritory = cws.colonyTerritoryByCollection[colonyId][collectionId].length > 0;
        bool hasInfra = cws.colonyInfraByCollection[colonyId][collectionId].length > 0;
        bool hasResource = cws.colonyResourceByCollection[colonyId][collectionId].length > 0;
        
        if (hasTerritory || hasInfra || hasResource) {
            return; // Still has NFTs, don't remove
        }
        
        // Remove from active collections
        uint256[] storage activeCollections = cws.colonyActiveCollections[colonyId];
        for (uint256 i = 0; i < activeCollections.length; i++) {
            if (activeCollections[i] == collectionId) {
                activeCollections[i] = activeCollections[activeCollections.length - 1];
                activeCollections.pop();
                break;
            }
        }
    }
    
    /**
     * @notice Remove token ID from array
     * @param tokenArray Storage array to modify
     * @param tokenId Token ID to remove
     */
    function _removeTokenFromArray(uint256[] storage tokenArray, uint256 tokenId) private {
        for (uint256 i = 0; i < tokenArray.length; i++) {
            if (tokenArray[i] == tokenId) {
                tokenArray[i] = tokenArray[tokenArray.length - 1];
                tokenArray.pop();
                break;
            }
        }
    }

    // ============================================
    // COORDINATED ATTACK LIMITS
    // ============================================

    /**
     * @notice Check if alliance can initiate a coordinated attack today
     * @param allianceId Alliance identifier
     * @return canInitiate True if alliance hasn't exceeded daily limit
     * @return attacksToday Number of coordinated attacks initiated today
     */
    function canAllianceInitiateCoordinatedAttack(bytes32 allianceId) internal view returns (bool canInitiate, uint8 attacksToday) {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        uint256 dayTimestamp = block.timestamp / 1 days;
        attacksToday = cws.allianceDailyCoordinatedAttacks[allianceId][dayTimestamp];
        canInitiate = attacksToday < cws.coordinatedAttackConfig.maxCoordinatedAttacksPerDay;
    }

    /**
     * @notice Increment alliance's daily coordinated attack counter
     * @param allianceId Alliance identifier
     */
    function incrementAllianceCoordinatedAttackCount(bytes32 allianceId) internal {
        ColonyWarsStorage storage cws = colonyWarsStorage();
        uint256 dayTimestamp = block.timestamp / 1 days;
        cws.allianceDailyCoordinatedAttacks[allianceId][dayTimestamp]++;
    }
}
