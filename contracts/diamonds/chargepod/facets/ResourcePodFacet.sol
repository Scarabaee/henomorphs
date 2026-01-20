// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibResourceStorage} from "../libraries/LibResourceStorage.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibFeeCollection} from "../../staking/libraries/LibFeeCollection.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {ColonyHelper} from "../../staking/libraries/ColonyHelper.sol";
import {LibAchievementTrigger} from "../libraries/LibAchievementTrigger.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {PodsUtils} from "../../../libraries/PodsUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title ResourcePodFacet
 * @notice Passive resource generation from NFT activity integration
 * @dev Integrates with Chargepod/Biopod systems for automatic resource generation
 *      Territory bonuses applied during generation
 * @custom:version 2.0.0 - Cleaned version (collaborative projects → CollaborativeCraftingFacet)
 */
contract ResourcePodFacet is AccessControlBase {
    
    // ==================== EVENTS ====================

    event ResourceGenerated(
        address indexed user,
        uint256 indexed collectionId,
        uint256 indexed tokenId,
        uint8 resourceType,
        uint256 amount
    );
    event ResourcesProcessed(address indexed user, uint8 resourceType, uint256 inputAmount, uint256 outputAmount);
    event InfrastructureBuilt(bytes32 indexed colonyId, uint8 infrastructureType, uint256 cost, address builder);
    event ResourceConfigUpdated(address indexed updater, string configType);

    // ==================== ERRORS ====================

    error InvalidConfiguration(string parameter);
    error InsufficientPermissions(address user, string action);
    error InsufficientResources(uint8 resourceType, uint256 required, uint256 available);
    error InvalidProcessingRecipe(uint8 inputType, uint8 outputType);
    error InvalidInfrastructureType(uint8 infrastructureType);
    
    // ==================== INITIALIZATION ====================
    
    /**
     * @notice Initialize resource system configuration
     * @param governanceToken Premium token address (e.g., ZICO)
     * @param utilityToken Daily operations token address (e.g., YLW)
     * @param paymentBeneficiary Treasury address for payments
     */
    function initializeResourceConfig(
        address governanceToken,
        address utilityToken,
        address paymentBeneficiary
    ) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        
        if (governanceToken == address(0) || utilityToken == address(0) || paymentBeneficiary == address(0)) {
            revert InvalidConfiguration("zero address");
        }
        
        rs.config.governanceToken = governanceToken;
        rs.config.utilityToken = utilityToken;
        rs.config.paymentBeneficiary = paymentBeneficiary;
        
        // Initialize default settings if not already set
        LibResourceStorage.initializeStorage();
        
        emit ResourceConfigUpdated(LibMeta.msgSender(), "initialization");
    }
    
    /**
     * @notice Set reward tokens for resource generation
     * @param primaryRewardToken Main reward token
     * @param secondaryRewardToken Bonus reward token (optional)
     */
    function setRewardTokens(
        address primaryRewardToken,
        address secondaryRewardToken
    ) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        
        rs.config.primaryRewardToken = primaryRewardToken;
        rs.config.secondaryRewardToken = secondaryRewardToken;
        
        emit ResourceConfigUpdated(LibMeta.msgSender(), "reward tokens");
    }

    /**
     * @notice Set reward collection address for CollaborativeCraftingFacet
     * @param rewardCollection NFT collection implementing IRewardCollection
     */
    function setRewardCollectionAddress(address rewardCollection) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        rs.config.rewardCollectionAddress = rewardCollection;
        emit ResourceConfigUpdated(LibMeta.msgSender(), "reward collection");
    }

    /**
     * @notice Configure NFT collection for resource generation
     * @param collectionId Internal collection ID
     * @param collectionAddress NFT contract address
     * @param baseResourceType Primary resource type (0-3)
     * @param generationMultiplier Production multiplier (100 = 1.0x)
     */
    function configureCollection(
        uint256 collectionId,
        address collectionAddress,
        uint8 baseResourceType,
        uint16 generationMultiplier
    ) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        
        if (collectionAddress == address(0)) revert InvalidConfiguration("collection address");
        if (baseResourceType > 3) revert InvalidConfiguration("resource type");
        
        rs.collectionConfigs[collectionId] = LibResourceStorage.CollectionConfig({
            collectionAddress: collectionAddress,
            baseResourceType: baseResourceType,
            generationMultiplier: generationMultiplier,
            enablesResourceGeneration: true,
            enablesProjectParticipation: true
        });
        
        rs.collectionAddresses[collectionId] = collectionAddress;
        
        emit ResourceConfigUpdated(LibMeta.msgSender(), "collection config");
    }
    
    /**
     * @notice Authorize external address to call resource generation
     * @param caller Address to authorize (e.g., ChargeFacet, BiopodFacet)
     * @param authorized Authorization status
     */
    function setAuthorizedCaller(address caller, bool authorized) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        rs.authorizedCallers[caller] = authorized;
        
        emit ResourceConfigUpdated(LibMeta.msgSender(), "authorized caller");
    }
    
    /**
     * @notice Set resource decay configuration
     * @param enabled Whether decay is active
     * @param decayRate Decay rate per day (basis points, 10000 = 100%)
     */
    function setResourceDecay(bool enabled, uint16 decayRate) external onlyAuthorized {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        
        if (decayRate > 10000) revert InvalidConfiguration("decay rate too high");
        
        rs.config.resourceDecayEnabled = enabled;
        rs.config.baseResourceDecayRate = decayRate;
        
        emit ResourceConfigUpdated(LibMeta.msgSender(), "resource decay");
    }
    
    // ==================== RESOURCE GENERATION ====================
    
    /**
     * @notice Generate resources based on token activity
     * @dev Called by existing action systems (ChargeFacet, BiopodFacet)
     * @param collectionId Collection ID of the token
     * @param tokenId Token ID
     * @param actionType Type of action performed (from existing systems)
     * @param baseAmount Base amount from existing calculation
     * @return resourceAmount Amount of resources generated
     */
    function generateResources(
        uint256 collectionId,
        uint256 tokenId,
        uint8 actionType,
        uint256 baseAmount
    ) external whenNotPaused returns (uint256 resourceAmount) {
        // Only allow calls from authorized system facets
        if (!_isAuthorizedSystemCall()) {
            revert InsufficientPermissions(LibMeta.msgSender(), "generateResources");
        }
        
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        
        // Get token's resource generation parameters
        uint8 resourceType = _calculateResourceType(collectionId, actionType);
        uint256 generationRate = _calculateGenerationRate(collectionId, tokenId, baseAmount);
        
        if (generationRate > 0) {
            uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
            address tokenOwner = _getTokenOwner(collectionId, tokenId);
            
            if (tokenOwner == address(0)) return 0;
            
            // Apply Territory Card bonuses
            generationRate = _applyTerritoryBonuses(tokenOwner, generationRate);

            // Apply decay before adding new resources
            LibResourceStorage.applyResourceDecay(tokenOwner);

            // Update user resources
            rs.userResources[tokenOwner][resourceType] += generationRate;
            rs.userResourcesLastUpdate[tokenOwner] = uint32(block.timestamp);
            
            // Update token generation stats
            rs.tokenResourceGeneration[combinedId][resourceType] += generationRate;
            rs.tokenLastGeneration[combinedId] = uint32(block.timestamp);
            
            // Update global stats
            unchecked {
                rs.totalResourcesGenerated += generationRate;
            }
            
            emit ResourceGenerated(tokenOwner, collectionId, tokenId, resourceType, generationRate);
            return generationRate;
        }
        
        return 0;
    }

    // ==================== RESOURCE PROCESSING ====================

    /**
     * @notice Process resources to create refined materials
     * @param resourceType Input resource type (0-3)
     * @param amount Amount to process
     * @param targetType Output resource type (0-3)
     * @return outputAmount Amount of processed resources
     */
    function processResources(
        uint8 resourceType,
        uint256 amount,
        uint8 targetType
    ) external whenNotPaused nonReentrant returns (uint256 outputAmount) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        address user = LibMeta.msgSender();

        LibResourceStorage.applyResourceDecay(user);

        if (rs.userResources[user][resourceType] < amount) {
            revert InsufficientResources(resourceType, amount, rs.userResources[user][resourceType]);
        }

        LibResourceStorage.ProcessingRecipe memory recipe = rs.processingRecipes[resourceType][targetType];
        if (recipe.outputMultiplier == 0 || !recipe.enabled) {
            revert InvalidProcessingRecipe(resourceType, targetType);
        }

        // Collect processing operation fee (configured YELLOW, burned)
        LibColonyWarsStorage.OperationFee storage processingFee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_PROCESSING);
        LibFeeCollection.processConfiguredFee(
            processingFee,
            user,
            "resource_processing"
        );

        rs.userResources[user][resourceType] -= amount;
        outputAmount = (amount * recipe.outputMultiplier) / 100;
        rs.userResources[user][targetType] += outputAmount;

        emit ResourcesProcessed(user, resourceType, amount, outputAmount);

        // Trigger resource processing achievement
        LibAchievementTrigger.triggerResourceProcessing(user);

        return outputAmount;
    }

    // ==================== INFRASTRUCTURE ====================

    /**
     * @notice Build colony infrastructure
     * @param colonyId Colony to build in
     * @param infrastructureType Type of infrastructure (0=Processing, 1=Research, 2=Defense)
     */
    function buildInfrastructure(
        bytes32 colonyId,
        uint8 infrastructureType
    ) external whenNotPaused nonReentrant {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        address user = LibMeta.msgSender();

        if (!_isAuthorizedForColony(colonyId, user)) {
            revert InsufficientPermissions(user, "build infrastructure");
        }

        LibResourceStorage.InfrastructureCost storage cost = rs.infrastructureCosts[infrastructureType];
        if (!cost.enabled) {
            revert InvalidInfrastructureType(infrastructureType);
        }

        LibResourceStorage.applyResourceDecay(user);

        // Check and consume resources
        for (uint256 i = 0; i < cost.resourceRequirements.length; i++) {
            uint8 resType = cost.resourceRequirements[i].resourceType;
            uint256 required = cost.resourceRequirements[i].amount;

            if (rs.userResources[user][resType] < required) {
                revert InsufficientResources(resType, required, rs.userResources[user][resType]);
            }
            rs.userResources[user][resType] -= required;
        }

        // Collect payment
        if (cost.paymentCost > 0 && rs.config.utilityToken != address(0)) {
            LibFeeCollection.collectFee(
                IERC20(rs.config.utilityToken),
                user,
                rs.config.paymentBeneficiary,
                cost.paymentCost,
                "buildInfrastructure"
            );
        }

        rs.colonyInfrastructure[colonyId][infrastructureType] += 1;
        rs.totalInfrastructureBuilt += 1;

        emit InfrastructureBuilt(colonyId, infrastructureType, cost.paymentCost, user);

        // Trigger infrastructure building achievement
        LibAchievementTrigger.triggerInfrastructureBuild(user);
    }

    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @notice Get user's resource balances
     * @param user Address to check
     * @return resources Array of [Basic, Energy, Bio, Rare] balances
     */
    function getUserResources(address user) external view returns (uint256[4] memory resources) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        
        for (uint8 i = 0; i < 4; i++) {
            resources[i] = rs.userResources[user][i];
        }
        
        return resources;
    }
    
    /**
     * @notice Get resource system configuration
     */
    function getResourceConfig() external view returns (
        address governanceToken,
        address utilityToken,
        address primaryRewardToken,
        address secondaryRewardToken,
        address paymentBeneficiary,
        address rewardCollectionAddress,
        uint16 baseResourceDecayRate,
        bool resourceDecayEnabled
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();

        return (
            rs.config.governanceToken,
            rs.config.utilityToken,
            rs.config.primaryRewardToken,
            rs.config.secondaryRewardToken,
            rs.config.paymentBeneficiary,
            rs.config.rewardCollectionAddress,
            rs.config.baseResourceDecayRate,
            rs.config.resourceDecayEnabled
        );
    }
    
    /**
     * @notice Get collection configuration
     */
    function getCollectionConfig(uint256 collectionId) external view returns (
        address collectionAddress,
        uint8 baseResourceType,
        uint16 generationMultiplier,
        bool enablesResourceGeneration
    ) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        LibResourceStorage.CollectionConfig memory config = rs.collectionConfigs[collectionId];
        
        return (
            config.collectionAddress,
            config.baseResourceType,
            config.generationMultiplier,
            config.enablesResourceGeneration
        );
    }
    
    /**
     * @notice Check if address is authorized caller
     */
    function isAuthorizedCaller(address caller) external view returns (bool) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        return rs.authorizedCallers[caller];
    }
    
    /**
     * @notice Get total resources generated (global stat)
     */
    function getTotalResourcesGenerated() external view returns (uint256) {
        return LibResourceStorage.resourceStorage().totalResourcesGenerated;
    }

    /**
     * @notice Get colony infrastructure levels
     * @param colonyId Colony to check
     * @return infrastructure Array of [Processing, Research, Defense] levels
     */
    function getColonyInfrastructure(bytes32 colonyId) external view returns (uint256[3] memory infrastructure) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        for (uint8 i = 0; i < 3; i++) {
            infrastructure[i] = rs.colonyInfrastructure[colonyId][i];
        }
    }

    // ==================== INTERNAL FUNCTIONS ====================
    
    /**
     * @notice Check if caller is authorized system contract
     */
    function _isAuthorizedSystemCall() internal view returns (bool) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        return rs.authorizedCallers[LibMeta.msgSender()];
    }
    
    /**
     * @notice Calculate resource type based on collection and action
     */
    function _calculateResourceType(uint256 collectionId, uint8 actionType) internal view returns (uint8) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        
        // Use collection config if available
        LibResourceStorage.CollectionConfig memory config = rs.collectionConfigs[collectionId];
        if (config.enablesResourceGeneration) {
            return config.baseResourceType;
        }
        
        // Fallback: Simple mapping based on collection ID
        return uint8(collectionId % 4);
    }
    
    /**
     * @notice Calculate resource generation rate
     */
    function _calculateGenerationRate(
        uint256 collectionId, 
        uint256, /* tokenId - unused but kept for interface compatibility */
        uint256 baseAmount
    ) internal view returns (uint256) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        
        // Use collection multiplier if configured
        LibResourceStorage.CollectionConfig memory config = rs.collectionConfigs[collectionId];
        if (config.enablesResourceGeneration && config.generationMultiplier > 0) {
            return (baseAmount * config.generationMultiplier) / 100;
        }
        
        // Default: 10% of base reward as resources
        return baseAmount / 10;
    }
    
    /**
     * @notice Get token owner (checks NFT ownership)
     */
    function _getTokenOwner(uint256 collectionId, uint256 tokenId) internal view returns (address) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        
        // Try to get collection address
        address collectionAddress = rs.collectionAddresses[collectionId];
        if (collectionAddress == address(0)) {
            return address(0);
        }
        
        // Try direct NFT ownership
        try IERC721(collectionAddress).ownerOf(tokenId) returns (address owner) {
            return owner;
        } catch {
            return address(0);
        }
    }
    
    /**
     * @notice Apply territory bonuses to resource generation
     * @dev Direct integration with LibColonyWarsStorage for territory bonuses
     */
    function _applyTerritoryBonuses(
        address user,
        uint256 baseAmount
    ) internal view returns (uint256 boostedAmount) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        // Get user's colony directly from storage
        bytes32 colonyId = cws.userToColony[user];
        if (colonyId == bytes32(0)) {
            return baseAmount;
        }
        
        // Get colony's territories directly from storage
        uint256[] memory territoryIds = cws.colonyTerritories[colonyId];
        if (territoryIds.length == 0) {
            return baseAmount;
        }
        
        // Calculate total bonus from all territories
        uint256 totalBonusPercent = 0;
        for (uint256 i = 0; i < territoryIds.length; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[territoryIds[i]];
            
            // Each territory provides production bonus based on bonusValue
            // bonusValue is in basis points (100 = 1%)
            totalBonusPercent += territory.bonusValue;
            
            // Check for equipped territory cards bonus
            LibColonyWarsStorage.TerritoryEquipment storage equipment = cws.territoryEquipment[territoryIds[i]];
            if (equipment.totalProductionBonus > 0) {
                totalBonusPercent += equipment.totalProductionBonus;
            }
        }
        
        // Apply accumulated bonus (basis points: 10000 = 100%)
        if (totalBonusPercent > 0) {
            boostedAmount = baseAmount + (baseAmount * totalBonusPercent) / 10000;
        } else {
            boostedAmount = baseAmount;
        }

        return boostedAmount;
    }

    /**
     * @notice Check if user is authorized for colony operations
     * @param colonyId Colony to check
     */
    function _isAuthorizedForColony(bytes32 colonyId, address /* user */) internal view returns (bool) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        return ColonyHelper.isColonyCreator(colonyId, hs.stakingSystemAddress);
    }
}
