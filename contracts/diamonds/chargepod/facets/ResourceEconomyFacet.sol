// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibFeeCollection} from "../../staking/libraries/LibFeeCollection.sol";
import {ResourceHelper} from "../libraries/ResourceHelper.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {ColonyHelper} from "../../staking/libraries/ColonyHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IColonyResourceCards} from "../../staking/interfaces/IColonyResourceCards.sol";

/**
 * @notice Interface for mintable reward token (YLW)
 */
interface IRewardToken is IERC20 {
    function mint(address to, uint256 amount, string calldata reason) external;
}

/**
 * @title ResourceEconomyFacet
 * @notice Manages resource nodes, harvesting, and colony resource balances
 * @dev MODUŁ 6 - Dual Token Economy Implementation
 * 
 * TOKEN ALLOCATION:
 * - ZICO (Premium): Node creation, node upgrades, strategic investments
 * - YLW (Utility): Maintenance payments, harvesting rewards, daily operations
 * 
 * ECONOMIC FLOW:
 * - Players earn YLW through harvesting resources
 * - Players spend YLW on node maintenance
 * - Players spend ZICO on node creation and upgrades (long-term investments)
 */
contract ResourceEconomyFacet is AccessControlBase {
    using LibColonyWarsStorage for LibColonyWarsStorage.ColonyWarsStorage;
    using SafeERC20 for IERC20;

    // Custom Errors
    error TerritoryNotControlled();
    error ResourceNodeNotFound();
    error NodeMaintenanceRequired();
    error HarvestCooldownActive();
    error InvalidNodeLevel();
    error NodeAlreadyExists();
    error InsufficientZICO();
    error InsufficientAuxiliaryToken();
    error AuxiliaryTokenNotConfigured();
    error ResourceCardsNotSet();
    error InvalidResourceType();
    error ResourceMaxSupplyReached();

    // Events
    event ResourceNodeCreated(
        uint256 indexed nodeId,
        uint256 indexed territoryId,
        LibColonyWarsStorage.ResourceType resourceType,
        uint8 nodeLevel,
        uint256 primaryCost
    );
    event ResourcesHarvested(
        uint256 indexed nodeId,
        bytes32 indexed colonyId,
        LibColonyWarsStorage.ResourceType resourceType,
        uint256 amount,
        uint256 tokenReward
    );
    event NodeMaintenancePaid(
        uint256 indexed nodeId, 
        bytes32 indexed colonyId, 
        uint256 auxilaryCost
    );
    event NodeUpgraded(
        uint256 indexed nodeId, 
        uint8 newLevel, 
        uint256 primaryCost
    );
    event ResourceDecay(
        bytes32 indexed colonyId,
        LibColonyWarsStorage.ResourceType resourceType,
        uint256 decayAmount
    );
    event ResourceCardMinted(uint256 indexed tokenId, address indexed recipient, uint8 resourceType, uint8 rarity);

    // Constants - Resource Economics
    uint256 constant DAILY_MAINTENANCE_COST_AUX = 10 ether; // 10 YLW per day per node
    uint32 constant HARVEST_COOLDOWN = 8 hours;
    uint256 constant BASE_PRODUCTION_RATE = 10; // Resources per hour
    uint256 constant TOKEN_HARVEST_REWARD_BASE = 5 ether; // 5 YLW base reward
    uint8 constant MAX_NODE_LEVEL = 10;
    
    // Constants - Node Costs (ZICO)
    uint256 constant NODE_CREATION_COST_PER_LEVEL = 100 ether; // 100 ZICO per level
    uint256 constant NODE_UPGRADE_COST_MULTIPLIER = 200 ether; // 200 ZICO * current level

    // ============================================================================
    // RESOURCE NODE MANAGEMENT - ZICO OPERATIONS
    // ============================================================================

    /**
     * @notice Create new resource node on territory (COSTS ZICO)
     * @param territoryId Territory where node will be placed
     * @param resourceType Type of resource to produce
     * @param nodeLevel Initial node level (1-10)
     * @dev Premium operation: Requires ZICO payment
     */
    function createResourceNode(
        uint256 territoryId,
        LibColonyWarsStorage.ResourceType resourceType,
        uint8 nodeLevel
    ) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.requireInitialized();
        
        if (nodeLevel == 0 || nodeLevel > MAX_NODE_LEVEL) revert InvalidNodeLevel();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Verify territory ownership
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        bytes32 colonyId = cws.userToColony[LibMeta.msgSender()];
        
        if (territory.controllingColony != colonyId) revert TerritoryNotControlled();
        
        // Verify colony ownership
        if (!ColonyHelper.isColonyCreator(colonyId, hs.stakingSystemAddress)) {
            revert TerritoryNotControlled();
        }
        
        // Calculate primary currency cost: 100 per node level
        uint256 creationCost = uint256(nodeLevel) * NODE_CREATION_COST_PER_LEVEL;

        // Collect primary currency fee (Premium token for strategic investments)
        LibFeeCollection.collectFee(
            IERC20(ResourceHelper.getPrimaryCurrency()),
            LibMeta.msgSender(),
            ResourceHelper.getTreasuryAddress(),
            creationCost,
            "node_creation"
        );
        
        // Create node
        uint256 nodeId = ++cws.resourceNodeCounter;
        LibColonyWarsStorage.ResourceNode storage node = cws.resourceNodes[nodeId];
        node.territoryId = territoryId;
        node.resourceType = resourceType;
        node.nodeLevel = nodeLevel;
        node.accumulatedResources = 0;
        node.lastHarvestTime = uint32(block.timestamp);
        node.lastMaintenancePaid = uint32(block.timestamp);
        node.active = true;
        
        emit ResourceNodeCreated(nodeId, territoryId, resourceType, nodeLevel, creationCost);
    }

    /**
     * @notice Upgrade resource node level (COSTS ZICO)
     * @param nodeId Node to upgrade
     * @dev Premium operation: Requires ZICO payment
     */
    function upgradeEconomyNode(uint256 nodeId) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.resourceNodes[nodeId];
        
        if (!node.active) revert ResourceNodeNotFound();
        if (node.nodeLevel >= MAX_NODE_LEVEL) revert InvalidNodeLevel();
        
        // Verify territory ownership
        LibColonyWarsStorage.Territory storage territory = cws.territories[node.territoryId];
        bytes32 colonyId = cws.userToColony[LibMeta.msgSender()];
        
        if (territory.controllingColony != colonyId) revert TerritoryNotControlled();
        
        // Verify colony ownership
        if (!ColonyHelper.isColonyCreator(colonyId, hs.stakingSystemAddress)) {
            revert TerritoryNotControlled();
        }
        
        // Calculate ZICO cost: 200 ZICO * current level
        uint256 upgradeCost = uint256(node.nodeLevel) * NODE_UPGRADE_COST_MULTIPLIER;

        // Collect primary currency fee (Premium token for upgrades)
        LibFeeCollection.collectFee(
            IERC20(ResourceHelper.getPrimaryCurrency()),
            LibMeta.msgSender(),
            ResourceHelper.getTreasuryAddress(),
            upgradeCost,
            "node_upgrade"
        );
        
        node.nodeLevel++;
        
        emit NodeUpgraded(nodeId, node.nodeLevel, upgradeCost);
    }

    // ============================================================================
    // RESOURCE HARVESTING - YLW OPERATIONS
    // ============================================================================

    /**
     * @notice Harvest accumulated resources from node (REWARDS YLW)
     * @param nodeId Node to harvest from
     * @dev Utility operation: Rewards YLW for activity
     */
    function harvestResources(uint256 nodeId) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.resourceNodes[nodeId];
        
        if (!node.active) revert ResourceNodeNotFound();
        
        // Verify territory ownership
        LibColonyWarsStorage.Territory storage territory = cws.territories[node.territoryId];
        bytes32 colonyId = cws.userToColony[LibMeta.msgSender()];
        
        if (territory.controllingColony != colonyId) revert TerritoryNotControlled();
        
        // Check harvest cooldown
        if (block.timestamp < node.lastHarvestTime + HARVEST_COOLDOWN) {
            revert HarvestCooldownActive();
        }
        
        // Check maintenance status
        uint32 daysSinceMaintenance = uint32((block.timestamp - node.lastMaintenancePaid) / 1 days);
        if (daysSinceMaintenance > 0) {
            revert NodeMaintenanceRequired();
        }
        
        // Calculate accumulated resources
        uint256 hoursSinceHarvest = (block.timestamp - node.lastHarvestTime) / 1 hours;
        uint256 production = BASE_PRODUCTION_RATE * node.nodeLevel * hoursSinceHarvest;
        
        // Apply territory equipment bonus
        LibColonyWarsStorage.TerritoryEquipment storage equipment = cws.territoryEquipment[node.territoryId];
        production = (production * (100 + equipment.totalProductionBonus)) / 100;
        
        // Add to colony balance using ResourceHelper
        node.accumulatedResources += production;
        LibColonyWarsStorage.ResourceBalance storage balance = cws.colonyResources[colonyId];
        ResourceHelper.addResources(balance, node.resourceType, production);

        node.lastHarvestTime = uint32(block.timestamp);

        // Calculate YLW reward: Base + level bonus
        uint256 tokenReward = TOKEN_HARVEST_REWARD_BASE + (uint256(node.nodeLevel) * 1 ether);

        // Reward auxiliary currency (Utility token for daily activities)
        // Uses Treasury → Mint fallback pattern for sustainable tokenomics
        address auxiliaryCurrency = ResourceHelper.getAuxiliaryCurrency();
        if (auxiliaryCurrency != address(0) && tokenReward > 0) {
            _distributeYlwReward(auxiliaryCurrency, LibMeta.msgSender(), tokenReward);
        }
        
        emit ResourcesHarvested(nodeId, colonyId, node.resourceType, production, tokenReward);
    }

    /**
     * @notice Pay maintenance for resource node (COSTS YLW)
     * @param nodeId Node to pay maintenance for
     * @dev Utility operation: Requires YLW payment for daily upkeep
     */
    function payNodeMaintenance(uint256 nodeId) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.resourceNodes[nodeId];
        
        if (!node.active) revert ResourceNodeNotFound();

        // Verify territory ownership
        LibColonyWarsStorage.Territory storage territory = cws.territories[node.territoryId];
        bytes32 colonyId = cws.userToColony[LibMeta.msgSender()];

        if (territory.controllingColony != colonyId) revert TerritoryNotControlled();

        // Calculate days of maintenance owed
        uint32 daysSinceMaintenance = uint32((block.timestamp - node.lastMaintenancePaid) / 1 days);
        if (daysSinceMaintenance == 0) return;

        // Calculate YLW cost
        uint256 maintenanceCost = DAILY_MAINTENANCE_COST_AUX * daysSinceMaintenance;

        // Collect auxiliary currency fee using LibFeeCollection
        LibFeeCollection.collectFee(
            IERC20(ResourceHelper.getAuxiliaryCurrency()),
            LibMeta.msgSender(),
            ResourceHelper.getTreasuryAddress(),
            maintenanceCost,
            "node_maintenance"
        );

        node.lastMaintenancePaid = uint32(block.timestamp);
        
        emit NodeMaintenancePaid(nodeId, colonyId, maintenanceCost);
    }

    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================

    /**
     * @notice Get resource node info
     * @param nodeId Node to query
     * @return Resource node struct
     */
    function getResourceNode(uint256 nodeId) 
        external 
        view 
        returns (LibColonyWarsStorage.ResourceNode memory) 
    {
        return LibColonyWarsStorage.colonyWarsStorage().resourceNodes[nodeId];
    }

    /**
     * @notice Get colony resource balance
     * @param colonyId Colony to query
     * @return balance Resource balance struct
     */
    function getColonyResources(bytes32 colonyId) 
        external 
        view 
        returns (LibColonyWarsStorage.ResourceBalance memory) 
    {
        return LibColonyWarsStorage.colonyWarsStorage().colonyResources[colonyId];
    }

    /**
     * @notice Calculate pending resources for node
     * @param nodeId Node to query
     * @return production Pending resources amount
     * @return tokenReward Expected YLW reward for harvesting
     */
    function getPendingResources(uint256 nodeId) 
        external 
        view 
        returns (uint256 production, uint256 tokenReward) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.resourceNodes[nodeId];
        
        if (!node.active) return (0, 0);
        
        // Calculate pending production
        uint256 hoursSinceHarvest = (block.timestamp - node.lastHarvestTime) / 1 hours;
        production = BASE_PRODUCTION_RATE * node.nodeLevel * hoursSinceHarvest;
        
        // Apply equipment bonus
        LibColonyWarsStorage.TerritoryEquipment storage equipment = cws.territoryEquipment[node.territoryId];
        production = (production * (100 + equipment.totalProductionBonus)) / 100;
        
        // Calculate YLW reward
        tokenReward = TOKEN_HARVEST_REWARD_BASE + (uint256(node.nodeLevel) * 1 ether);
        
        return (production, tokenReward);
    }

    /**
     * @notice Get maintenance cost for node
     * @param nodeId Node to query
     * @return maintanaceCost YLW cost for outstanding maintenance
     * @return daysOwed Days of maintenance owed
     */
    function getMaintenanceCost(uint256 nodeId) 
        external 
        view 
        returns (uint256 maintanaceCost, uint32 daysOwed) 
    {
        LibColonyWarsStorage.ResourceNode storage node = 
            LibColonyWarsStorage.colonyWarsStorage().resourceNodes[nodeId];
        
        if (!node.active) return (0, 0);
        
        daysOwed = uint32((block.timestamp - node.lastMaintenancePaid) / 1 days);
        maintanaceCost = DAILY_MAINTENANCE_COST_AUX * daysOwed;
        
        return (maintanaceCost, daysOwed);
    }

    /**
     * @notice Get node creation cost
     * @param nodeLevel Desired node level (1-10)
     * @return zicoCost ZICO cost for creating node
     */
    function getNodeCreationCost(uint8 nodeLevel) 
        external 
        pure 
        returns (uint256 zicoCost) 
    {
        if (nodeLevel == 0 || nodeLevel > MAX_NODE_LEVEL) return 0;
        return uint256(nodeLevel) * NODE_CREATION_COST_PER_LEVEL;
    }

    /**
     * @notice Get node upgrade cost
     * @param nodeId Node to query
     * @return zicoCost ZICO cost for upgrade
     */
    function getNodeUpgradeCost(uint256 nodeId) 
        external 
        view 
        returns (uint256 zicoCost) 
    {
        LibColonyWarsStorage.ResourceNode storage node = 
            LibColonyWarsStorage.colonyWarsStorage().resourceNodes[nodeId];
        
        if (!node.active || node.nodeLevel >= MAX_NODE_LEVEL) return 0;
        return uint256(node.nodeLevel) * NODE_UPGRADE_COST_MULTIPLIER;
    }

    // ============================================================================
    // INTERNAL HELPERS - YLW Distribution
    // ============================================================================

    /**
     * @notice Distribute YLW reward with Treasury → Mint fallback
     * @dev Priority: 1) Transfer from treasury, 2) Mint if treasury insufficient
     * @param rewardToken YLW token address
     * @param recipient User receiving the reward
     * @param amount Amount to distribute
     */
    function _distributeYlwReward(
        address rewardToken,
        address recipient,
        uint256 amount
    ) internal {
        address treasury = ResourceHelper.getTreasuryAddress();
        
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
            IRewardToken(rewardToken).mint(recipient, shortfall, "harvest_reward");
        } else {
            // Fallback: Mint new tokens
            IRewardToken(rewardToken).mint(recipient, amount, "harvest_reward");
        }
    }

    // ============================================================================
    // RESOURCE CARD MINTING - PUBLIC SALE
    // ============================================================================

    // Rarity thresholds (out of 10000)
    uint256 private constant LEGENDARY_THRESHOLD = 100;   // 1%
    uint256 private constant EPIC_THRESHOLD = 600;        // 5%
    uint256 private constant RARE_THRESHOLD = 2100;       // 15%
    uint256 private constant UNCOMMON_THRESHOLD = 5100;   // 30%

    /**
     * @notice Mint Resource Card (public sale)
     * @param resourceType Resource type (0-3)
     * @return tokenId Minted token ID
     */
    function mintResourceCard(uint8 resourceType) external payable whenNotPaused nonReentrant returns (uint256 tokenId) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        address resourceAddr = cws.contractAddresses.resourceCards;
        if (resourceAddr == address(0)) revert ResourceCardsNotSet();
        if (resourceType > 3) revert InvalidResourceType();

        IColonyResourceCards resourceContract = IColonyResourceCards(resourceAddr);

        // Check supply
        if (resourceContract.totalSupply() >= resourceContract.maxSupply()) revert ResourceMaxSupplyReached();

        // Calculate price and collect payment (supports native/ERC20 with discount)
        uint256 price = _calculateResourcePrice(resourceType);
        ResourceHelper.collectCardMintFee(LibMeta.msgSender(), price, "resource_card_mint");

        // Calculate rarity
        uint8 rarity = _calculateResourceRarity(block.timestamp, resourceType, LibMeta.msgSender());

        // Mint to user
        tokenId = resourceContract.mintResource(
            LibMeta.msgSender(),
            IColonyResourceCards.ResourceType(resourceType),
            IColonyResourceCards.Rarity(rarity)
        );

        emit ResourceCardMinted(tokenId, LibMeta.msgSender(), resourceType, rarity);
    }

    /**
     * @notice Mint Resource Card and stake to node
     * @param resourceType Resource type (0-3)
     * @param nodeId Node to stake to
     * @return tokenId Minted token ID
     */
    function mintResourceCardFor(uint8 resourceType, uint256 nodeId) external payable whenNotPaused nonReentrant returns (uint256 tokenId) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        address resourceAddr = cws.contractAddresses.resourceCards;
        if (resourceAddr == address(0)) revert ResourceCardsNotSet();
        if (resourceType > 3) revert InvalidResourceType();

        // Verify node ownership
        LibColonyWarsStorage.ResourceNode storage node = cws.resourceNodes[nodeId];
        if (!node.active) revert ResourceNodeNotFound();

        LibColonyWarsStorage.Territory storage territory = cws.territories[node.territoryId];
        bytes32 colonyId = cws.userToColony[LibMeta.msgSender()];
        if (territory.controllingColony != colonyId) revert TerritoryNotControlled();

        IColonyResourceCards resourceContract = IColonyResourceCards(resourceAddr);

        // Check supply
        if (resourceContract.totalSupply() >= resourceContract.maxSupply()) revert ResourceMaxSupplyReached();

        // Calculate price and collect payment (supports native/ERC20 with discount)
        uint256 price = _calculateResourcePrice(resourceType);
        ResourceHelper.collectCardMintFee(LibMeta.msgSender(), price, "resource_card_mint_stake");

        // Calculate rarity
        uint8 rarity = _calculateResourceRarity(block.timestamp, resourceType, LibMeta.msgSender());

        // Mint to user
        tokenId = resourceContract.mintResource(
            LibMeta.msgSender(),
            IColonyResourceCards.ResourceType(resourceType),
            IColonyResourceCards.Rarity(rarity)
        );

        emit ResourceCardMinted(tokenId, LibMeta.msgSender(), resourceType, rarity);

        // Auto-stake to node
        resourceContract.stakeToNode(tokenId, nodeId);
    }

    /**
     * @notice Calculate mint price for resource type
     * @dev Uses configured price if set, otherwise falls back to defaults
     */
    function _calculateResourcePrice(uint8 resourceType) internal view returns (uint256) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        // Use configured price if initialized
        if (cws.cardMintPricing.initialized && cws.cardMintPricing.resourcePrices[resourceType] > 0) {
            return cws.cardMintPricing.resourcePrices[resourceType];
        }

        // Fallback to defaults
        if (resourceType == 0) return 400 ether;   // BasicMaterials
        if (resourceType == 1) return 600 ether;   // EnergyCrystals
        if (resourceType == 2) return 800 ether;   // BioCompounds
        return 1200 ether;                          // RareElements
    }

    /**
     * @notice Calculate rarity based on pseudo-random seed
     */
    function _calculateResourceRarity(uint256 seed, uint8 itemType, address minter) internal view returns (uint8) {
        uint256 randomSeed = uint256(keccak256(abi.encodePacked(
            block.prevrandao,
            seed,
            minter,
            block.timestamp,
            itemType,
            block.number
        )));

        uint256 roll = randomSeed % 10000;

        if (roll < LEGENDARY_THRESHOLD) return 4;  // Legendary
        if (roll < EPIC_THRESHOLD) return 3;       // Epic
        if (roll < RARE_THRESHOLD) return 2;       // Rare
        if (roll < UNCOMMON_THRESHOLD) return 1;   // Uncommon
        return 0;                                   // Common
    }

    /**
     * @notice Get mint price for resource type
     */
    function getResourcePrice(uint8 resourceType) external view returns (uint256) {
        return _calculateResourcePrice(resourceType);
    }

    // ============================================================================
    // RESOURCE CARD COMBINING
    // ============================================================================

    // Events
    event ResourceCardsCombined(uint256[] burnedTokenIds, uint256 indexed newTokenId, address indexed owner);

    // Errors
    error InsufficientCardsForCombine();
    error CardsMustBeSameType();
    error CardNotOwned();
    error CardIsStaked();

    /**
     * @notice Combine multiple resource cards into one higher rarity card
     * @param tokenIds Array of resource card token IDs to combine (minimum 3)
     * @return newTokenId The newly minted combined card
     * @dev Burns input cards and mints one new card with higher rarity
     *      All cards must be same resource type and owned by caller
     */
    function combineResourceCards(uint256[] calldata tokenIds) external whenNotPaused nonReentrant returns (uint256 newTokenId) {
        if (tokenIds.length < 3) revert InsufficientCardsForCombine();

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        address resourceAddr = cws.contractAddresses.resourceCards;
        if (resourceAddr == address(0)) revert ResourceCardsNotSet();

        IColonyResourceCards resourceContract = IColonyResourceCards(resourceAddr);
        address caller = LibMeta.msgSender();

        // Validate all cards are owned by caller and same type
        IColonyResourceCards.ResourceTraits memory firstTraits = resourceContract.getTraits(tokenIds[0]);

        for (uint256 i = 0; i < tokenIds.length; i++) {
            // Check ownership
            if (resourceContract.ownerOf(tokenIds[i]) != caller) revert CardNotOwned();

            // Check not staked
            if (resourceContract.isStaked(tokenIds[i])) revert CardIsStaked();

            // Check same resource type
            if (i > 0) {
                IColonyResourceCards.ResourceTraits memory traits = resourceContract.getTraits(tokenIds[i]);
                if (traits.resourceType != firstTraits.resourceType) revert CardsMustBeSameType();
            }
        }

        // Call combine on NFT contract (burns old cards, mints new one)
        newTokenId = resourceContract.combineResources(tokenIds);

        emit ResourceCardsCombined(tokenIds, newTokenId, caller);
    }

    /**
     * @notice Get number of cards needed to combine for next rarity
     * @param currentRarity Current card rarity (0-4)
     * @return cardsNeeded Number of cards required to combine
     */
    function getCardsNeededForCombine(uint8 currentRarity) external pure returns (uint8 cardsNeeded) {
        // Cannot combine Legendary cards
        if (currentRarity >= 4) return 0;

        // 3 cards of same rarity combine into 1 of next rarity
        return 3;
    }

    /**
     * @notice Check if cards can be combined
     * @param tokenIds Array of token IDs to check
     * @return canCombine Whether combination is possible
     * @return reason Description if cannot combine
     */
    function canCombineCards(uint256[] calldata tokenIds) external view returns (bool canCombine, string memory reason) {
        if (tokenIds.length < 3) return (false, "Need at least 3 cards");

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        address resourceAddr = cws.contractAddresses.resourceCards;
        if (resourceAddr == address(0)) return (false, "Resource cards not configured");

        IColonyResourceCards resourceContract = IColonyResourceCards(resourceAddr);
        address caller = LibMeta.msgSender();

        IColonyResourceCards.ResourceTraits memory firstTraits = resourceContract.getTraits(tokenIds[0]);

        // Check Legendary cannot be combined
        if (uint8(firstTraits.rarity) >= 4) return (false, "Cannot combine Legendary cards");

        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (resourceContract.ownerOf(tokenIds[i]) != caller) return (false, "Card not owned");
            if (resourceContract.isStaked(tokenIds[i])) return (false, "Card is staked");

            if (i > 0) {
                IColonyResourceCards.ResourceTraits memory traits = resourceContract.getTraits(tokenIds[i]);
                if (traits.resourceType != firstTraits.resourceType) return (false, "Cards must be same type");
                if (traits.rarity != firstTraits.rarity) return (false, "Cards must be same rarity");
            }
        }

        return (true, "");
    }
}
