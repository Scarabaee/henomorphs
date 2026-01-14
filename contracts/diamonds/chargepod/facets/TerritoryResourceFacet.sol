// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibResourceStorage} from "../libraries/LibResourceStorage.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";

/**
 * @title TerritoryResourceFacet
 * @notice Integrates resource system with territory control
 * @dev Uses LibColonyWarsStorage.resourceNodes mapping for safe Diamond storage
 */
contract TerritoryResourceFacet is AccessControlBase {

    // ==================== EVENTS ====================

    event ResourceNodePlaced(uint256 indexed territoryId, bytes32 indexed colonyId, uint8 resourceType, uint8 nodeLevel);
    event ResourceNodeUpgraded(uint256 indexed territoryId, uint8 oldLevel, uint8 newLevel);
    event ResourceNodeHarvested(uint256 indexed territoryId, bytes32 indexed colonyId, uint8 resourceType, uint256 amount);

    // ==================== ERRORS ====================

    error TerritoryNotControlled(uint256 territoryId, bytes32 colonyId);
    error ResourceNodeAlreadyExists(uint256 territoryId);
    error ResourceNodeNotFound(uint256 territoryId);
    error InvalidNodeLevel(uint8 level);
    error InsufficientResourcesForUpgrade(uint8 resourceType, uint256 required, uint256 available);
    error HarvestCooldownActive(uint256 territoryId, uint32 remainingTime);
    error InvalidTerritoryForResourceType(uint256 territoryId, uint8 resourceType);
    error InsufficientPermissions(address user);
    
    // ==================== RESOURCE NODE MANAGEMENT ====================

    /**
     * @notice Place resource node on controlled territory
     * @param territoryId Territory to place node on
     * @param resourceType Type of resource node (0-3)
     */
    function placeResourceNode(
        uint256 territoryId,
        uint8 resourceType
    ) external whenNotPaused {
        bytes32 colonyId = _getCallerColonyId();
        _requireTerritoryControl(territoryId, colonyId);

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        // Check if node already exists (use territoryId as nodeId)
        if (cws.resourceNodes[territoryId].active) {
            revert ResourceNodeAlreadyExists(territoryId);
        }

        // Validate resource type matches territory type
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        if (!_isValidResourceTypeForTerritory(territory.territoryType, resourceType)) {
            revert InvalidTerritoryForResourceType(territoryId, resourceType);
        }

        // Cost: governance token + resources
        uint256 placementCost = _calculateNodePlacementCost(1);
        _chargeGovernanceToken(placementCost);

        // Consume resources for placement
        address sender = LibMeta.msgSender();
        _consumeResources(sender, resourceType, 100);

        // Create node using LibColonyWarsStorage.ResourceNode
        cws.resourceNodes[territoryId] = LibColonyWarsStorage.ResourceNode({
            territoryId: territoryId,
            resourceType: LibColonyWarsStorage.ResourceType(resourceType),
            nodeLevel: 1,
            accumulatedResources: 0,
            lastHarvestTime: uint32(block.timestamp),
            lastMaintenancePaid: uint32(block.timestamp),
            active: true
        });

        emit ResourceNodePlaced(territoryId, colonyId, resourceType, 1);
    }

    /**
     * @notice Upgrade existing resource node
     * @param territoryId Territory with node to upgrade
     */
    function upgradeResourceNode(uint256 territoryId) external whenNotPaused {
        bytes32 colonyId = _getCallerColonyId();
        _requireTerritoryControl(territoryId, colonyId);

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.resourceNodes[territoryId];

        if (!node.active) revert ResourceNodeNotFound(territoryId);
        if (node.nodeLevel >= 10) revert InvalidNodeLevel(node.nodeLevel);

        uint8 newLevel = node.nodeLevel + 1;
        uint256 upgradeCost = _calculateNodePlacementCost(newLevel);
        uint256 resourceCost = 100 * newLevel;

        _chargeGovernanceToken(upgradeCost);
        address sender = LibMeta.msgSender();
        _consumeResources(sender, uint8(node.resourceType), resourceCost);

        uint8 oldLevel = node.nodeLevel;
        node.nodeLevel = newLevel;

        emit ResourceNodeUpgraded(territoryId, oldLevel, newLevel);
    }

    /**
     * @notice Harvest resources from territory node
     * @param territoryId Territory to harvest from
     */
    function harvestResourceNode(uint256 territoryId) external whenNotPaused returns (uint256 harvestedAmount) {
        bytes32 colonyId = _getCallerColonyId();
        _requireTerritoryControl(territoryId, colonyId);

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.resourceNodes[territoryId];

        if (!node.active) revert ResourceNodeNotFound(territoryId);

        // Check cooldown (24h)
        uint32 currentTime = uint32(block.timestamp);
        uint32 cooldown = 86400; // 24 hours
        if (currentTime < node.lastHarvestTime + cooldown) {
            uint32 remaining = (node.lastHarvestTime + cooldown) - currentTime;
            revert HarvestCooldownActive(territoryId, remaining);
        }

        // Calculate production with bonuses
        harvestedAmount = _calculateHarvestAmount(colonyId, node);

        // Update harvest timestamp
        node.lastHarvestTime = currentTime;

        // Award resources to harvester
        address sender = LibMeta.msgSender();
        _awardResources(sender, uint8(node.resourceType), harvestedAmount);

        emit ResourceNodeHarvested(territoryId, colonyId, uint8(node.resourceType), harvestedAmount);
    }
    
    // ==================== VIEW FUNCTIONS ====================

    /**
     * @notice Get production bonus from controlled territories
     * @param colonyId Colony ID
     * @param resourceType Resource type
     * @return bonusPercent Bonus percentage (100 = no bonus, 150 = 50% bonus)
     */
    function getTerritoryProductionBonus(
        bytes32 colonyId,
        uint8 resourceType
    ) external view returns (uint16 bonusPercent) {
        return _calculateTerritoryBonus(colonyId, resourceType);
    }

    /**
     * @notice Get all resource nodes for colony's territories
     * @param colonyId Colony ID
     * @return territoryIds Array of territory IDs with nodes
     * @return nodes Array of resource node data
     */
    function getColonyResourceNodes(bytes32 colonyId) external view returns (
        uint256[] memory territoryIds,
        LibColonyWarsStorage.ResourceNode[] memory nodes
    ) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        uint256[] memory controlled = cws.colonyTerritories[colonyId];

        uint256 count = 0;
        for (uint256 i = 0; i < controlled.length; i++) {
            if (cws.resourceNodes[controlled[i]].active) count++;
        }

        territoryIds = new uint256[](count);
        nodes = new LibColonyWarsStorage.ResourceNode[](count);

        uint256 index = 0;
        for (uint256 i = 0; i < controlled.length; i++) {
            if (cws.resourceNodes[controlled[i]].active) {
                territoryIds[index] = controlled[i];
                nodes[index] = cws.resourceNodes[controlled[i]];
                index++;
            }
        }
    }

    /**
     * @notice Get resource node info for specific territory
     * @param territoryId Territory ID
     */
    function getResourceNodeInfo(uint256 territoryId) external view returns (
        bool exists,
        uint8 resourceType,
        uint8 nodeLevel,
        uint32 lastHarvest,
        uint32 nextHarvestTime,
        uint256 estimatedProduction
    ) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ResourceNode storage node = cws.resourceNodes[territoryId];

        exists = node.active;

        if (exists) {
            resourceType = uint8(node.resourceType);
            nodeLevel = node.nodeLevel;
            lastHarvest = node.lastHarvestTime;
            nextHarvestTime = node.lastHarvestTime + 86400; // 24h cooldown
            estimatedProduction = _calculateBaseProduction(node.nodeLevel);
        }
    }

    // ==================== INTERNAL HELPERS ====================

    function _calculateBaseProduction(uint8 level) private pure returns (uint256) {
        return 100 * level; // Linear scaling
    }

    function _calculateNodePlacementCost(uint8 level) private pure returns (uint256) {
        return 50 ether * level; // governance token cost
    }

    function _calculateHarvestAmount(
        bytes32 colonyId,
        LibColonyWarsStorage.ResourceNode storage node
    ) private view returns (uint256) {
        uint256 baseAmount = _calculateBaseProduction(node.nodeLevel);

        // Apply territory bonus
        uint16 territoryBonus = _calculateTerritoryBonus(colonyId, uint8(node.resourceType));
        uint256 bonusAmount = (baseAmount * territoryBonus) / 100;

        // Apply infrastructure bonus
        uint16 infraBonus = LibResourceStorage.getInfrastructureBonus(colonyId, 0);
        uint256 finalAmount = (bonusAmount * infraBonus) / 100;

        return finalAmount;
    }

    function _calculateTerritoryBonus(
        bytes32 colonyId,
        uint8 resourceType
    ) private view returns (uint16 bonusPercent) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        uint256[] memory territories = cws.colonyTerritories[colonyId];

        bonusPercent = 100; // Base 100% (no bonus)

        for (uint256 i = 0; i < territories.length; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[territories[i]];

            if (_isValidResourceTypeForTerritory(territory.territoryType, resourceType)) {
                bonusPercent += territory.bonusValue / 10;
            }
        }
    }

    function _isValidResourceTypeForTerritory(
        uint8 territoryType,
        uint8 resourceType
    ) private pure returns (bool) {
        // Territory type 1 (Mining) -> Basic Materials (0)
        // Territory type 2 (Energy) -> Energy Crystals (1)
        // Territory type 3 (Research) -> Bio Compounds (2)
        // Territory type 4 (Production) -> Rare Elements (3)
        // Territory type 5 (Strategic) -> All types
        if (territoryType == 5) return true;
        return territoryType == resourceType + 1;
    }

    function _requireTerritoryControl(uint256 territoryId, bytes32 colonyId) private view {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        if (cws.territories[territoryId].controllingColony != colonyId) {
            revert TerritoryNotControlled(territoryId, colonyId);
        }
    }

    function _getCallerColonyId() private view returns (bytes32) {
        // Use LibColonyWarsStorage directly - simpler approach
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        address user = LibMeta.msgSender();

        bytes32 colonyId = cws.userToColony[user];
        if (colonyId == bytes32(0)) {
            colonyId = cws.userPrimaryColony[user];
        }
        if (colonyId == bytes32(0)) {
            revert InsufficientPermissions(user);
        }
        return colonyId;
    }

    function _chargeGovernanceToken(uint256 amount) private {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        LibFeeCollection.collectFee(
            IERC20(rs.config.governanceToken),
            LibMeta.msgSender(),
            rs.config.paymentBeneficiary,
            amount,
            "territory_resource"
        );
    }

    function _consumeResources(address user, uint8 resourceType, uint256 amount) private {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        // Apply decay before consuming resources
        LibResourceStorage.applyResourceDecay(user);

        uint256 available = rs.userResources[user][resourceType];
        if (available < amount) {
            revert InsufficientResourcesForUpgrade(resourceType, amount, available);
        }
        rs.userResources[user][resourceType] = available - amount;
    }

    function _awardResources(address user, uint8 resourceType, uint256 amount) private {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        // Apply decay before awarding resources
        LibResourceStorage.applyResourceDecay(user);
        rs.userResources[user][resourceType] += amount;
    }
}
