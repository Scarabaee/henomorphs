// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ControlFee} from "../../../libraries/HenomorphsModel.sol";

/**
 * @title LibMissionStorage
 * @notice Storage library for Henomorphs Mission System
 * @dev Uses Diamond Storage pattern with unique slot to avoid conflicts
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
library LibMissionStorage {
    bytes32 constant MISSION_STORAGE_POSITION = keccak256("henomorphs.missions.storage");

    // ============================================================
    // CONSTANTS
    // ============================================================

    uint8 constant REVEAL_DELAY_BLOCKS = 3;
    uint16 constant REVEAL_WINDOW_BLOCKS = 256;
    uint8 constant MAX_ACTIONS_PER_BATCH = 5;
    uint8 constant MAX_PARTICIPANTS = 5;
    uint8 constant MAX_MAP_NODES = 16;
    uint8 constant MAX_OBJECTIVES = 8;

    // Charge costs per action type
    uint8 constant CHARGE_MOVE = 2;
    uint8 constant CHARGE_SCAN = 5;
    uint8 constant CHARGE_LOOT = 3;
    uint8 constant CHARGE_COMBAT_AGGRESSIVE = 15;
    uint8 constant CHARGE_COMBAT_BALANCED = 10;
    uint8 constant CHARGE_COMBAT_DEFENSIVE = 5;
    uint8 constant CHARGE_STEALTH = 8;
    uint8 constant CHARGE_HACK = 6;

    // ============================================================
    // ENUMS
    // ============================================================

    enum MissionPhase {
        NotStarted,      // 0 - Initial state
        Committed,       // 1 - Waiting for reveal block
        Active,          // 2 - Map revealed, actions possible
        EventPending,    // 3 - Event requires response
        ReadyToComplete, // 4 - All objectives met
        Completed,       // 5 - Rewards distributed
        Failed,          // 6 - Abandoned or expired
        Expired          // 7 - Deadline passed without completion
    }

    enum ObjectiveType {
        Collect,         // Collect N items of type X
        Defeat,          // Win N combats
        Discover,        // Find specific location/item
        Survive,         // Complete without losing combat
        Hack,            // Successfully hack N terminals
        Stealth,         // Complete N stealth actions
        Time             // Complete within time limit
    }

    enum MissionActionType {
        Move,            // Move to adjacent node
        Scan,            // Scan current area for items/secrets
        Loot,            // Collect items from container
        Combat,          // Engage enemy
        Stealth,         // Attempt stealth past obstacle
        Hack,            // Hack terminal/door
        Rest,            // Recover charge (limited uses)
        UseItem,         // Use consumable item
        Extract          // End mission (if objectives met)
    }

    enum NodeType {
        Empty,           // Nothing special
        Loot,            // Contains lootable items
        Combat,          // Enemy encounter
        Terminal,        // Hackable terminal
        Secret,          // Hidden discovery
        Objective,       // Mission objective location
        Exit,            // Extraction point
        Event            // Triggers random event
    }

    enum CombatStyle {
        Aggressive,      // High damage, high charge cost
        Balanced,        // Medium damage, medium cost
        Defensive,       // Low damage, low cost, damage reduction
        Retreat          // Escape attempt
    }

    enum EventType {
        Patrol,          // Enemy patrol - fight/hide/flee
        Trap,            // Trap triggered - disarm/avoid/take damage
        Ambush,          // Surprise attack - must fight
        Discovery,       // Found something valuable
        Ally,            // NPC ally offers help
        Environmental    // Weather/hazard affecting actions
    }

    enum EventResponse {
        Fight,
        Hide,
        Flee,
        Disarm,
        Accept,
        Decline,
        Negotiate
    }

    /**
     * @notice Mission Pass status - distinguishes "never used" from "exhausted"
     * @dev Solves the problem where remaining=0 could mean either first use or depleted
     */
    enum PassStatus {
        Uninitialized,  // 0 - Never used, will get full uses on first mission
        Active,         // 1 - Has remaining uses
        Exhausted       // 2 - All uses consumed, can be recharged
    }

    // ============================================================
    // PACKED STORAGE STRUCTURES (gas optimized)
    // ============================================================

    /**
     * @notice Packed mission state - 2 storage slots
     */
    struct PackedMissionState {
        // Slot 1 (256 bits)
        uint64 sessionId;           // Unique session identifier
        uint32 startBlock;          // Block when mission started
        uint32 revealBlock;         // Block for randomness reveal
        uint32 deadlineBlock;       // Hard deadline for completion
        uint16 passCollectionId;    // Mission Pass collection
        uint16 passTokenId;         // Mission Pass token (limited to 65535)
        uint8 missionVariant;       // Which mission type (1-4)
        uint8 currentNodeId;        // Current position on map
        uint8 phase;                // MissionPhase enum
        uint8 objectivesMask;       // Bit flags for completed objectives
        uint8 totalActions;         // Actions performed
        uint8 combatsWon;           // Combat victories
        uint8 combatsLost;          // Combat losses
        uint8 flags;                // Packed boolean flags

        // Slot 2 (256 bits)
        uint16 chargeUsed;          // Total charge consumed
        uint16 dataFragments;       // Collected resource type 1
        uint16 scrapMetal;          // Collected resource type 2
        uint8 rareComponents;       // Collected resource type 3
        uint8 eventsTriggered;      // Events that occurred
        uint8 eventsResolved;       // Events handled successfully
        uint8 eventsFailed;         // Events failed/ignored
        uint8 stealthSuccesses;     // Successful stealth actions
        uint8 hacksCompleted;       // Successful hacks
        uint8 secretsFound;         // Hidden areas discovered
        uint8 pendingEventId;       // Current event requiring response
        uint32 pendingEventDeadline;// Block deadline for event response
        uint32 lastActionBlock;     // Block of last action
        uint64 rewardPool;          // Accumulated reward (scaled by 1e12)
    }

    /**
     * @notice Packed participant - 1 slot per participant
     */
    struct PackedParticipant {
        uint128 combinedId;         // Collection + Token ID via PodsUtils
        uint32 initialCharge;       // Charge at mission start
        uint32 currentCharge;       // Current charge level
        uint16 damageDealt;         // Total damage dealt
        uint16 damageTaken;         // Total damage received
        uint8 xpEarned;             // XP accumulated
        uint8 actionsPerformed;     // Individual action count
        uint8 status;               // 0=active, 1=incapacitated, 2=extracted
        uint8 bonusFlags;           // Special bonuses earned
    }

    /**
     * @notice Packed map nodes - 8 nodes per 256-bit slot
     * Each node: 32 bits
     * - bits 0-3: NodeType (16 types max)
     * - bits 4-7: difficulty (0-15)
     * - bit 8: discovered
     * - bit 9: completed
     * - bit 10: hasLoot
     * - bit 11: hasEnemy
     * - bits 12-15: connected nodes mask (4 directions)
     * - bits 16-31: reserved/node-specific data
     */
    struct PackedMapNodes {
        uint256 nodes0to7;
        uint256 nodes8to15;
    }

    /**
     * @notice Packed objectives - up to 8 objectives in 1 slot
     * Each objective: 32 bits
     * - bits 0-3: ObjectiveType
     * - bits 4-11: target amount
     * - bits 12-19: current progress
     * - bit 20: isRequired (vs bonus)
     * - bit 21: isCompleted
     * - bits 22-31: bonus reward percent (0-1023)
     */
    struct PackedObjectives {
        uint256 objectives;
    }

    // ============================================================
    // RECHARGE STRUCTURES
    // ============================================================

    /**
     * @notice Configuration for Mission Pass recharge functionality
     * @dev Allows users to purchase additional uses for their Mission Pass
     */
    struct RechargeConfig {
        address paymentToken;          // Token used for payment (ERC20)
        address paymentBeneficiary;    // Recipient of recharge payments
        uint96 pricePerUse;            // Price for one use (in payment token)
        uint16 discountBps;            // Discount in basis points (0-10000, e.g., 1000 = 10% off)
        uint16 maxRechargePerTx;       // Maximum uses that can be recharged in single tx (0 = unlimited)
        uint32 cooldownSeconds;        // Cooldown between recharges (0 = no cooldown)
        bool enabled;                  // Is recharge enabled for this collection
        bool burnOnCollect;            // Burn tokens instead of transfer
    }

    /**
     * @notice Record of recharge history for a specific Mission Pass token
     */
    struct PassRechargeRecord {
        uint32 lastRechargeTime;       // Timestamp of last recharge
        uint16 totalRecharges;         // Total number of recharge transactions
        uint16 totalUsesRecharged;     // Total uses added through recharges
    }

    // ============================================================
    // LENDING STRUCTURES (ERC-4907 + Delegate.xyz inspired)
    // ============================================================

    /**
     * @notice Delegation record - inspired by ERC-4907 + Delegate.xyz
     * @dev Implements auto-expiry pattern: delegateeOf() returns address(0) when expired
     */
    struct PassDelegation {
        // Slot 1 (256 bits) - packed: 20 + 8 + 2 + 2 = 32 bytes
        address delegatee;             // Who has usage rights (20 bytes)
        uint64 expires;                // Unix timestamp of expiration - like ERC-4907 (8 bytes)
        uint16 usesAllowed;            // Use limit (0 = unlimited within time) (2 bytes)
        uint16 usesConsumed;           // Uses consumed by delegatee (2 bytes)

        // Slot 2 (256 bits) - financial terms
        uint96 flatFeeTotal;           // Total flat fee paid (12 bytes)
        uint16 rewardShareBps;         // % of rewards for delegator (0 = flat fee only) (2 bytes)
        uint96 collateralAmount;       // Deposited collateral (0 = none) (12 bytes)
        bool collateralReturned;       // Whether collateral was returned (1 byte)
        // 3 bytes padding

        // Slot 3 (256 bits) - auto-renew
        address lender;                // Original owner/lender address (20 bytes)
        uint96 autoRenewDeposit;       // Deposit for auto-renewal (12 bytes)
    }

    /**
     * @notice Listing offer for lending a Mission Pass
     * @dev Lender creates offer, borrower accepts with specified terms
     */
    struct PassLendingOffer {
        // Slot 1 (256 bits)
        address owner;                 // Pass owner (20 bytes)
        uint96 flatFeePerUse;          // Price per use (flat fee mode) (12 bytes)

        // Slot 2 (256 bits)
        uint16 rewardShareBps;         // % of rewards (revenue share mode, 0 = disabled) (2 bytes)
        uint32 minDuration;            // Minimum rental duration (seconds) (4 bytes)
        uint32 maxDuration;            // Maximum rental duration (seconds) (4 bytes)
        uint16 minUses;                // Minimum uses to rent (2 bytes)
        uint16 maxUses;                // Maximum uses to rent (2 bytes)
        uint64 offerExpires;           // When offer expires (8 bytes)
        uint96 collateralRequired;     // Required collateral (0 = none, inspired by ReNFT) (12 bytes)

        // Slot 3
        bool active;                   // Is offer active (1 byte)
        // 31 bytes padding
    }

    /**
     * @notice Global lending system configuration
     */
    struct LendingConfig {
        address paymentToken;          // Token for payments/collateral (ERC20)
        address beneficiary;           // Platform fee recipient (20 bytes)
        uint16 platformFeeBps;         // Platform fee (max 1000 = 10%) (2 bytes)
        uint32 minDuration;            // Global minimum rental duration (4 bytes)
        uint32 maxDuration;            // Global maximum rental duration (4 bytes)
        uint16 maxRewardShareBps;      // Max reward share for lender (e.g., 5000 = 50%) (2 bytes)
        bool enabled;                  // Is lending system enabled (1 byte)
        bool burnPlatformFee;          // Burn platform fee instead of transfer (for YLW tokens)
    }

    // ============================================================
    // CONFIG STRUCTURES
    // ============================================================

    /**
     * @notice Mission Pass collection configuration
     */
    struct MissionPassCollection {
        address collectionAddress;      // ERC721/ERC1155 contract
        string name;                    // Collection name
        uint8 variantCount;             // Number of mission variants
        uint16 maxUsesPerToken;         // Max uses per pass token (0 = unlimited)
        bool enabled;                   // Is collection active
        uint32 globalCooldown;          // Cooldown between missions (seconds)
        uint8 minHenomorphs;            // Min participants
        uint8 maxHenomorphs;            // Max participants
        uint8 minChargePercent;         // Min charge % to participate
        uint16[] eligibleCollections;   // Which henomorph collections can participate
        ControlFee entryFee;            // Fee to start mission
    }

    /**
     * @notice Mission variant configuration
     */
    struct MissionVariantConfig {
        string name;
        string description;

        // Timing
        uint16 minDurationBlocks;      // Minimum time to complete
        uint16 maxDurationBlocks;      // Hard deadline

        // Map
        uint8 mapSize;                 // Number of nodes (max 16)
        uint8 minCombatNodes;
        uint8 maxCombatNodes;
        uint8 lootNodeChance;          // Percent (0-100)

        // Objectives
        uint8 requiredObjectivesCount;
        uint8 bonusObjectivesCount;

        // Events
        uint8 eventFrequency;          // Average events per mission (0-10)
        uint16 eventResponseBlocks;    // Blocks to respond to event

        // Rewards
        uint256 baseReward;
        uint16 difficultyMultiplier;   // Basis points (10000 = 100%)

        // Bonuses (basis points)
        uint16 multiParticipantBonus;  // Per extra participant
        uint16 colonyBonus;            // All in same colony
        uint16 streakBonusPerDay;      // Per consecutive day
        uint16 maxStreakBonus;         // Cap on streak bonus
        uint16 weekendBonus;
        uint16 perfectCompletionBonus; // All objectives + no damage

        bool enabled;
    }

    /**
     * @notice User mission profile and statistics
     */
    struct UserMissionProfile {
        uint32 totalMissionsStarted;
        uint32 totalMissionsCompleted;
        uint32 totalMissionsFailed;
        uint32 currentStreak;          // Consecutive days with completed mission
        uint32 lastMissionDay;         // Day number of last completed mission
        uint32 longestStreak;
        uint256 totalRewardsEarned;
        uint16 perfectCompletions;
        uint16 totalCombatsWon;
        uint16 totalEventsResolved;
    }

    // ============================================================
    // EXPANDED STRUCTURES (for function parameters/returns)
    // ============================================================

    /**
     * @notice Action input from player
     */
    struct MissionAction {
        MissionActionType actionType;
        uint8 targetNodeId;         // For Move action
        uint8 participantIndex;     // Which Henomorph performs action
        CombatStyle combatStyle;    // For Combat action
    }

    /**
     * @notice Result of an action
     */
    struct ActionResult {
        bool success;
        uint8 chargeUsed;
        uint16 damageDealt;
        uint16 damageTaken;
        uint8 itemsFound;
        uint8 xpGained;
        uint8 objectiveProgress;    // Which objective advanced
        uint8 triggeredEventId;     // 0 if no event triggered
    }

    /**
     * @notice Active event details
     */
    struct MissionEvent {
        uint8 eventId;
        EventType eventType;
        uint32 triggerBlock;
        uint32 deadlineBlock;
        uint8 difficulty;
        uint16 penaltyOnIgnore;
    }

    /**
     * @notice Event resolution outcome
     */
    struct EventOutcome {
        bool success;
        uint8 chargeUsed;
        uint16 damageDealt;
        uint16 damageTaken;
        uint8 rewardBonus;
    }

    /**
     * @notice Map node details (unpacked for view functions)
     */
    struct MapNode {
        uint8 nodeId;
        NodeType nodeType;
        uint8 difficulty;
        bool discovered;
        bool completed;
        bool hasLoot;
        bool hasEnemy;
        uint8 connectedNodesMask;   // 4 bits for connections
    }

    /**
     * @notice Objective details (unpacked for view functions)
     */
    struct MissionObjective {
        uint8 objectiveId;
        ObjectiveType objectiveType;
        uint8 targetAmount;
        uint8 currentProgress;
        bool isRequired;
        bool isCompleted;
        uint16 bonusRewardPercent;
    }

    /**
     * @notice Mission completion result
     */
    struct MissionResult {
        bool success;
        uint256 totalReward;
        uint8 performanceRating;    // 0-100
        uint16 dataFragmentsEarned;
        uint16 scrapMetalEarned;
        uint8 rareComponentsEarned;
        uint8 xpEarned;
    }

    /**
     * @notice Full mission session (unpacked for view functions)
     */
    struct MissionSession {
        bytes32 sessionId;
        address initiator;
        uint16 passCollectionId;
        uint16 passTokenId;
        uint8 missionVariant;
        MissionPhase phase;
        uint8 currentNodeId;
        uint32 startBlock;
        uint32 revealBlock;
        uint32 deadlineBlock;
        uint32 lastActionBlock;
        uint8 totalActions;
        uint8 combatsWon;
        uint8 combatsLost;
        uint16 chargeUsed;
        uint8 eventsTriggered;
        uint8 eventsResolved;
        uint8 eventsFailed;
        uint8 pendingEventId;
        uint32 pendingEventDeadline;
        uint256 accumulatedReward;
    }

    // ============================================================
    // MAIN STORAGE STRUCT
    // ============================================================

    struct MissionStorage {
        // ============ CONFIGURATION ============
        // Mission Pass collections: collectionId => config
        mapping(uint16 => MissionPassCollection) passCollections;
        uint16 passCollectionCounter;

        // Variant configs: collectionId => variantId => config
        mapping(uint16 => mapping(uint8 => MissionVariantConfig)) variantConfigs;

        // Mission Pass usage tracking: passCollectionId => passTokenId => usesRemaining
        mapping(uint16 => mapping(uint256 => uint16)) passUsesRemaining;

        // ============ ACTIVE SESSIONS ============
        mapping(bytes32 => PackedMissionState) packedStates;
        mapping(bytes32 => PackedMapNodes) sessionMaps;
        mapping(bytes32 => PackedObjectives) sessionObjectives;
        mapping(bytes32 => PackedParticipant[]) sessionParticipants;
        mapping(bytes32 => bytes32) sessionEntropy;
        mapping(bytes32 => address) sessionInitiators;

        // ============ INDEX MAPPINGS ============
        mapping(address => bytes32) userActiveMission;
        mapping(uint256 => bytes32) henomorphActiveMission;
        mapping(uint256 => bool) lockedHenomorphs;

        // ============ USER PROFILES ============
        mapping(address => UserMissionProfile) userProfiles;

        // User mission cooldowns: user => lastMissionEndTime
        mapping(address => uint32) userMissionCooldowns;

        // ============ GLOBAL COUNTERS ============
        uint64 totalSessionsCreated;
        uint64 totalSessionsCompleted;
        uint64 totalSessionsFailed;

        // ============ SYSTEM STATE ============
        bool systemPaused;
        address rewardToken;
        address feeRecipient;
        uint16 feeBps;              // Fee basis points (e.g., 500 = 5%)

        // ============ RECHARGE SYSTEM (added for Mission Pass recharge) ============
        // Recharge configs: collectionId => RechargeConfig
        mapping(uint16 => RechargeConfig) passRechargeConfigs;

        // Pass status tracking: collectionId => tokenId => PassStatus
        mapping(uint16 => mapping(uint256 => PassStatus)) passStatus;

        // Recharge records: collectionId => tokenId => PassRechargeRecord
        mapping(uint16 => mapping(uint256 => PassRechargeRecord)) passRechargeRecords;

        // Recharge system pause flag
        bool rechargeSystemPaused;

        // ============ LENDING SYSTEM (ERC-4907 + Delegate.xyz inspired) ============
        // Global lending configuration
        LendingConfig lendingConfig;

        // Lending offers: collectionId => tokenId => PassLendingOffer
        mapping(uint16 => mapping(uint256 => PassLendingOffer)) passLendingOffers;

        // Active delegations: collectionId => tokenId => PassDelegation
        mapping(uint16 => mapping(uint256 => PassDelegation)) passDelegations;

        // Escrow balances for lender earnings: user => amount
        mapping(address => uint256) lendingEscrowBalance;

        // Collateral balances held: user => amount
        mapping(address => uint256) collateralHeldBalance;

        // Lending system pause flag
        bool lendingSystemPaused;
    }

    // ============================================================
    // STORAGE ACCESSOR
    // ============================================================

    function missionStorage() internal pure returns (MissionStorage storage ms) {
        bytes32 position = MISSION_STORAGE_POSITION;
        assembly {
            ms.slot := position
        }
    }

    // ============================================================
    // PACKING/UNPACKING UTILITIES
    // ============================================================

    /**
     * @notice Pack a single map node into 32 bits
     */
    function packNode(MapNode memory node) internal pure returns (uint32) {
        uint32 packed = 0;
        packed |= uint32(node.nodeType);                    // bits 0-3
        packed |= uint32(node.difficulty) << 4;             // bits 4-7
        packed |= (node.discovered ? uint32(1) : 0) << 8;   // bit 8
        packed |= (node.completed ? uint32(1) : 0) << 9;    // bit 9
        packed |= (node.hasLoot ? uint32(1) : 0) << 10;     // bit 10
        packed |= (node.hasEnemy ? uint32(1) : 0) << 11;    // bit 11
        packed |= uint32(node.connectedNodesMask) << 12;    // bits 12-15
        return packed;
    }

    /**
     * @notice Unpack a single map node from 32 bits
     */
    function unpackNode(uint32 packed, uint8 nodeId) internal pure returns (MapNode memory node) {
        node.nodeId = nodeId;
        node.nodeType = NodeType(packed & 0xF);
        node.difficulty = uint8((packed >> 4) & 0xF);
        node.discovered = ((packed >> 8) & 1) == 1;
        node.completed = ((packed >> 9) & 1) == 1;
        node.hasLoot = ((packed >> 10) & 1) == 1;
        node.hasEnemy = ((packed >> 11) & 1) == 1;
        node.connectedNodesMask = uint8((packed >> 12) & 0xF);
    }

    /**
     * @notice Get a node from packed storage
     */
    function getNode(PackedMapNodes storage nodes, uint8 nodeId) internal view returns (MapNode memory) {
        require(nodeId < MAX_MAP_NODES, "Invalid node ID");
        uint256 slot = nodeId < 8 ? nodes.nodes0to7 : nodes.nodes8to15;
        uint8 index = nodeId < 8 ? nodeId : nodeId - 8;
        uint32 packed = uint32((slot >> (index * 32)) & 0xFFFFFFFF);
        return unpackNode(packed, nodeId);
    }

    /**
     * @notice Set a node in packed storage
     */
    function setNode(PackedMapNodes storage nodes, uint8 nodeId, MapNode memory node) internal {
        require(nodeId < MAX_MAP_NODES, "Invalid node ID");
        uint32 packed = packNode(node);
        uint8 index = nodeId < 8 ? nodeId : nodeId - 8;
        uint256 mask = ~(uint256(0xFFFFFFFF) << (index * 32));

        if (nodeId < 8) {
            nodes.nodes0to7 = (nodes.nodes0to7 & mask) | (uint256(packed) << (index * 32));
        } else {
            nodes.nodes8to15 = (nodes.nodes8to15 & mask) | (uint256(packed) << (index * 32));
        }
    }

    /**
     * @notice Pack a single objective into 32 bits
     */
    function packObjective(MissionObjective memory obj) internal pure returns (uint32) {
        uint32 packed = 0;
        packed |= uint32(obj.objectiveType);                        // bits 0-3
        packed |= uint32(obj.targetAmount) << 4;                    // bits 4-11
        packed |= uint32(obj.currentProgress) << 12;                // bits 12-19
        packed |= (obj.isRequired ? uint32(1) : 0) << 20;           // bit 20
        packed |= (obj.isCompleted ? uint32(1) : 0) << 21;          // bit 21
        packed |= uint32(obj.bonusRewardPercent & 0x3FF) << 22;     // bits 22-31
        return packed;
    }

    /**
     * @notice Unpack a single objective from 32 bits
     */
    function unpackObjective(uint32 packed, uint8 objectiveId) internal pure returns (MissionObjective memory obj) {
        obj.objectiveId = objectiveId;
        obj.objectiveType = ObjectiveType(packed & 0xF);
        obj.targetAmount = uint8((packed >> 4) & 0xFF);
        obj.currentProgress = uint8((packed >> 12) & 0xFF);
        obj.isRequired = ((packed >> 20) & 1) == 1;
        obj.isCompleted = ((packed >> 21) & 1) == 1;
        obj.bonusRewardPercent = uint16((packed >> 22) & 0x3FF);
    }

    /**
     * @notice Get an objective from packed storage
     */
    function getObjective(PackedObjectives storage objectives, uint8 objectiveId) internal view returns (MissionObjective memory) {
        require(objectiveId < MAX_OBJECTIVES, "Invalid objective ID");
        uint32 packed = uint32((objectives.objectives >> (objectiveId * 32)) & 0xFFFFFFFF);
        return unpackObjective(packed, objectiveId);
    }

    /**
     * @notice Set an objective in packed storage
     */
    function setObjective(PackedObjectives storage objectives, uint8 objectiveId, MissionObjective memory obj) internal {
        require(objectiveId < MAX_OBJECTIVES, "Invalid objective ID");
        uint32 packed = packObjective(obj);
        uint256 mask = ~(uint256(0xFFFFFFFF) << (objectiveId * 32));
        objectives.objectives = (objectives.objectives & mask) | (uint256(packed) << (objectiveId * 32));
    }

    /**
     * @notice Update objective progress
     */
    function updateObjectiveProgress(PackedObjectives storage objectives, uint8 objectiveId, uint8 progressDelta) internal returns (bool completed) {
        MissionObjective memory obj = getObjective(objectives, objectiveId);
        if (obj.isCompleted) return false;

        obj.currentProgress += progressDelta;
        if (obj.currentProgress >= obj.targetAmount) {
            obj.currentProgress = obj.targetAmount;
            obj.isCompleted = true;
            completed = true;
        }
        setObjective(objectives, objectiveId, obj);
    }
}
