// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ControlFee} from "../../../libraries/HenomorphsModel.sol";

/**
 * @title LibResourceStorage
 * @notice Storage library for ResourcePod system
 * @dev Uses Diamond storage pattern for isolation
 */
library LibResourceStorage {
    bytes32 constant RESOURCE_STORAGE_POSITION = keccak256("henomorphs.resource.storage");
    
    // Resource types enumeration
    uint8 constant BASIC_MATERIALS = 0;      // Stone, wood, basic components
    uint8 constant ENERGY_CRYSTALS = 1;      // Energy-based resources
    uint8 constant BIO_COMPOUNDS = 2;        // Biological materials
    uint8 constant RARE_ELEMENTS = 3;        // Rare/special materials
    
    // Infrastructure types
    uint8 constant PROCESSING_FACILITY = 0;  // Improves resource processing
    uint8 constant RESEARCH_LAB = 1;         // Enables advanced projects
    uint8 constant DEFENSE_STRUCTURE = 2;    // Colony protection
    
    // Project types
    uint8 constant INFRASTRUCTURE_PROJECT = 1;
    uint8 constant RESEARCH_PROJECT = 2;
    uint8 constant DEFENSE_PROJECT = 3;
    
    enum ProjectStatus {
        Active,
        Completed,
        Failed,
        Cancelled
    }
    
    struct ResourceConfig {
        address governanceToken;          // Premium token for major operations (e.g., ZICO)
        address utilityToken;             // Daily operations token (e.g., YLW)
        address primaryRewardToken;       // Main reward token distribution
        address secondaryRewardToken;     // Bonus reward token (optional)
        address paymentBeneficiary;       // Where payment fees go (treasury)
        address rewardCollectionAddress;  // NFT collection for project rewards
        address chargeFacetAddress;       // Existing ChargeFacet for integration
        address biopodFacetAddress;       // Existing BiopodFacet for integration
        address stakingSystemAddress;     // Existing staking system
        address colonyFacetAddress;       // Existing colony management
        uint32 defaultProjectDuration;    // Default project duration in seconds
        uint16 baseResourceDecayRate;     // Base decay rate per day (out of 10000)
        bool resourceDecayEnabled;        // Whether resources decay over time
    }
    
    struct ResourceRequirement {
        uint8 resourceType;
        uint256 amount;
    }
    
    struct ProcessingRecipe {
        uint8 inputType;
        uint8 outputType;
        uint16 outputMultiplier;          // Output amount as % of input (e.g., 150 = 1.5x)
        uint256 paymentCostPerUnit;       // Payment token cost per unit processed
        uint32 processingTime;            // Time required in seconds
        bool enabled;
    }
    
    struct CollaborativeProject {
        bytes32 colonyId;
        uint8 projectType;
        address initiator;
        uint32 deadline;
        uint256 paymentRequirement;      // Payment token cost for participation
        ProjectStatus status;
        ResourceRequirement[] resourceRequirements;
        address[] contributors;
        uint256[4] totalContributions;   // Resources contributed by type
    }
    
    struct InfrastructureCost {
        ResourceRequirement[] resourceRequirements;
        uint256 paymentCost;             // Payment token cost
        uint32 buildTime;
        bool enabled;
    }

    struct ResourceEvent {
        bytes32 eventId;                 // Unique event identifier
        string name;                     // Event name
        string description;              // Event description
        uint40 startTime;                // When event starts
        uint40 endTime;                  // When event ends
        uint16 productionMultiplier;     // Production bonus in basis points (150 = +50%)
        uint16 processingDiscount;       // Processing cost discount in bps (1000 = 10% off)
        bool active;                     // Is event currently active
        address creator;                 // Who created the event
        bool globalEvent;                // True = all colonies, false = eligible only
        uint8 eventType;                 // 1=Rush, 2=Frenzy, 3=Festival
        uint256 minContribution;         // Min resources to participate
        uint256 rewardPool;              // Total rewards for distribution
    }
    
    struct EventParticipant {
        uint256 contribution;            // Total resources contributed
        uint256 actionsCompleted;        // Actions during event
        bool rewardClaimed;
        uint32 participationTime;
    }
    
    struct EventLeaderboard {
        address[] topParticipants;       // Top 10 participants
        uint256 minScoreRequired;        // Min score to enter top 10
    }
    
    struct CollectionConfig {
        address collectionAddress;
        uint8 baseResourceType;          // Primary resource type this collection generates
        uint16 generationMultiplier;     // Multiplier for resource generation
        bool enablesResourceGeneration;
        bool enablesProjectParticipation;
    }
    
    struct ResourceStorage {
        // Configuration
        ResourceConfig config;
        mapping(address => bool) authorizedCallers; // Addresses that can call generation functions
        
        // Collection configuration for resource generation
        mapping(uint256 => CollectionConfig) collectionConfigs;
        mapping(uint256 => address) collectionAddresses;
        uint16 collectionCounter;
        
        // Resource balances per user
        mapping(address => mapping(uint8 => uint256)) userResources;
        mapping(address => uint32) userResourcesLastUpdate;
        
        // Resource generation tracking per token
        mapping(uint256 => mapping(uint8 => uint256)) tokenResourceGeneration;
        mapping(uint256 => uint32) tokenLastGeneration;
        
        // Processing recipes
        mapping(uint8 => mapping(uint8 => ProcessingRecipe)) processingRecipes;
        
        // Infrastructure costs
        mapping(uint8 => InfrastructureCost) infrastructureCosts;
        
        // Colony infrastructure levels
        mapping(bytes32 => mapping(uint8 => uint256)) colonyInfrastructure;
        mapping(bytes32 => mapping(uint8 => uint256)) colonyResources;
        mapping(bytes32 => mapping(uint8 => uint256)) colonyProductionRates;

        // Collaborative projects
        mapping(bytes32 => CollaborativeProject) collaborativeProjects;
        mapping(bytes32 => mapping(address => mapping(uint8 => uint256))) projectContributions;
        bytes32[] activeProjects;
        
        // Resource decay tracking
        mapping(address => uint32) lastDecayUpdate;
        
        // === RESOURCE EVENTS ===
        // Events tracking
        mapping(bytes32 => ResourceEvent) resourceEvents;
        bytes32 activeResourceEvent;     // Currently active event ID
        bytes32[] eventHistory;          // Past and current events
        string[] activeEventIds;         // Currently active event IDs (string format for compatibility)
        
        // Event eligibility (flattened - was inside ResourceEvent struct)
        mapping(bytes32 => mapping(bytes32 => bool)) eventEligibleColonies; // eventId => colonyId => eligible
        
        // Event participation tracking
        mapping(string => mapping(address => EventParticipant)) eventParticipants;
        mapping(string => EventLeaderboard) eventLeaderboards;
        mapping(string => mapping(address => uint256)) eventLeaderboardScores; // FLATTENED: eventId => user => score
        mapping(string => uint256) totalEventParticipants;
        mapping(string => uint256) totalEventContributions;
        
        // Event statistics
        uint256 totalEventsHosted;
        uint256 totalRewardsDistributed;
        
        // Statistics
        uint256 totalResourcesGenerated;
        uint256 totalProjectsCompleted;
        uint256 totalInfrastructureBuilt;
        
        // Version for future upgrades
        uint256 storageVersion;
    }
    
    /**
     * @notice Get resource storage reference
     */
    function resourceStorage() internal pure returns (ResourceStorage storage rs) {
        bytes32 position = RESOURCE_STORAGE_POSITION;
        assembly {
            rs.slot := position
        }
    }
    
    /**
     * @notice Apply resource decay to user's resources
     * @param user User address
     */
    function applyResourceDecay(address user) internal {
        ResourceStorage storage rs = resourceStorage();
        
        if (!rs.config.resourceDecayEnabled || rs.config.baseResourceDecayRate == 0) {
            return;
        }
        
        uint32 currentTime = uint32(block.timestamp);
        uint32 lastUpdate = rs.lastDecayUpdate[user];
        
        if (lastUpdate == 0) {
            rs.lastDecayUpdate[user] = currentTime;
            return;
        }
        
        uint32 timePassed = currentTime - lastUpdate;
        if (timePassed < 86400) return; // Skip if less than 1 day
        
        uint32 daysPassed = timePassed / 86400;
        
        // Apply decay to each resource type
        for (uint8 i = 0; i < 4; i++) {
            uint256 currentAmount = rs.userResources[user][i];
            if (currentAmount > 0) {
                uint256 decayAmount = (currentAmount * rs.config.baseResourceDecayRate * daysPassed) / 10000;
                if (decayAmount > currentAmount) {
                    rs.userResources[user][i] = 0;
                } else {
                    rs.userResources[user][i] = currentAmount - decayAmount;
                }
            }
        }
        
        rs.lastDecayUpdate[user] = currentTime;
    }
    
    /**
     * @notice Get infrastructure bonus for colony
     * @param colonyId Colony ID
     * @param bonusType Type of bonus to calculate
     * @return bonus Bonus percentage (100 = no bonus, 150 = 50% bonus)
     */
    function getInfrastructureBonus(bytes32 colonyId, uint8 bonusType) internal view returns (uint16 bonus) {
        ResourceStorage storage rs = resourceStorage();
        
        bonus = 100; // Base 100% (no bonus)
        
        if (bonusType == 0) { // Processing bonus
            bonus += uint16(rs.colonyInfrastructure[colonyId][PROCESSING_FACILITY] * 10); // 10% per facility
        } else if (bonusType == 1) { // Research bonus
            bonus += uint16(rs.colonyInfrastructure[colonyId][RESEARCH_LAB] * 15); // 15% per lab
        } else if (bonusType == 2) { // Defense bonus
            bonus += uint16(rs.colonyInfrastructure[colonyId][DEFENSE_STRUCTURE] * 5); // 5% per structure
        }
        
        // Cap bonuses at reasonable levels
        if (bonus > 300) bonus = 300; // Max 200% bonus
        
        return bonus;
    }
    
    /**
     * @notice Check if user has sufficient resources for requirements
     * @param user User address
     * @param requirements Array of resource requirements
     * @return sufficient Whether user has enough resources
     */
    function checkResourceRequirements(address user, ResourceRequirement[] memory requirements) internal view returns (bool sufficient) {
        ResourceStorage storage rs = resourceStorage();
        
        for (uint256 i = 0; i < requirements.length; i++) {
            if (rs.userResources[user][requirements[i].resourceType] < requirements[i].amount) {
                return false;
            }
        }
        
        return true;
    }
    
    /**
     * @notice Initialize storage with default configurations
     */
    function initializeStorage() internal {
        ResourceStorage storage rs = resourceStorage();
        
        if (rs.storageVersion > 0) return; // Already initialized
        
        // Set default processing recipes
        _setDefaultProcessingRecipes();
        
        // Set default infrastructure costs
        _setDefaultInfrastructureCosts();
        
        // Set default configuration
        rs.config.defaultProjectDuration = 7 days;
        rs.config.baseResourceDecayRate = 50; // 0.5% per day
        rs.config.resourceDecayEnabled = true;
        
        rs.storageVersion = 1;
    }
    
    function _setDefaultProcessingRecipes() private {
        ResourceStorage storage rs = resourceStorage();
        
        // Basic -> Energy conversion
        rs.processingRecipes[BASIC_MATERIALS][ENERGY_CRYSTALS] = ProcessingRecipe({
            inputType: BASIC_MATERIALS,
            outputType: ENERGY_CRYSTALS,
            outputMultiplier: 80, // 80% conversion rate
            paymentCostPerUnit: 1e18, // 1 payment token per unit
            processingTime: 3600, // 1 hour
            enabled: true
        });
        
        // Energy -> Bio conversion  
        rs.processingRecipes[ENERGY_CRYSTALS][BIO_COMPOUNDS] = ProcessingRecipe({
            inputType: ENERGY_CRYSTALS,
            outputType: BIO_COMPOUNDS,
            outputMultiplier: 60, // 60% conversion rate
            paymentCostPerUnit: 2e18, // 2 payment tokens per unit
            processingTime: 7200, // 2 hours
            enabled: true
        });
        
        // Any -> Rare conversion (expensive)
        for (uint8 i = 0; i < 3; i++) {
            rs.processingRecipes[i][RARE_ELEMENTS] = ProcessingRecipe({
                inputType: i,
                outputType: RARE_ELEMENTS,
                outputMultiplier: 20, // 20% conversion rate
                paymentCostPerUnit: 10e18, // 10 payment tokens per unit
                processingTime: 14400, // 4 hours
                enabled: true
            });
        }
    }
    
    function _setDefaultInfrastructureCosts() private {
        ResourceStorage storage rs = resourceStorage();
        
        // Processing Facility
        InfrastructureCost storage processingCost = rs.infrastructureCosts[PROCESSING_FACILITY];
        processingCost.paymentCost = 100e18; // 100 payment tokens
        processingCost.buildTime = 86400; // 1 day
        processingCost.enabled = true;
        processingCost.resourceRequirements.push(ResourceRequirement(BASIC_MATERIALS, 1000));
        processingCost.resourceRequirements.push(ResourceRequirement(ENERGY_CRYSTALS, 500));
        
        // Research Lab
        InfrastructureCost storage researchCost = rs.infrastructureCosts[RESEARCH_LAB];
        researchCost.paymentCost = 200e18; // 200 payment tokens
        researchCost.buildTime = 172800; // 2 days
        researchCost.enabled = true;
        researchCost.resourceRequirements.push(ResourceRequirement(BASIC_MATERIALS, 500));
        researchCost.resourceRequirements.push(ResourceRequirement(BIO_COMPOUNDS, 300));
        researchCost.resourceRequirements.push(ResourceRequirement(RARE_ELEMENTS, 100));
        
        // Defense Structure
        InfrastructureCost storage defenseCost = rs.infrastructureCosts[DEFENSE_STRUCTURE];
        defenseCost.paymentCost = 300e18; // 300 payment tokens
        defenseCost.buildTime = 259200; // 3 days
        defenseCost.enabled = true;
        defenseCost.resourceRequirements.push(ResourceRequirement(BASIC_MATERIALS, 2000));
        defenseCost.resourceRequirements.push(ResourceRequirement(ENERGY_CRYSTALS, 1000));
        defenseCost.resourceRequirements.push(ResourceRequirement(RARE_ELEMENTS, 200));
    }
}