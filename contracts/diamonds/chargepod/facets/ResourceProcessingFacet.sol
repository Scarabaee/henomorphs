// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {ResourceHelper} from "../libraries/ResourceHelper.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ResourceProcessingFacet
 * @notice Handles resource processing and refining
 * @dev Converts basic resources into advanced materials
 */
contract ResourceProcessingFacet is AccessControlBase {
    using LibColonyWarsStorage for LibColonyWarsStorage.ColonyWarsStorage;

    // Custom Errors
    error RecipeNotFound();
    error InsufficientResources();
    error InsufficientYLW();
    error InsufficientTechLevel();
    error ProcessingNotComplete();
    error OrderAlreadyClaimed();
    error OrderNotFound();

    // Events
    event RecipeCreated(uint8 indexed recipeId, uint256 ylwCost, uint32 processingTime);
    event ProcessingStarted(
        bytes32 indexed orderId,
        bytes32 indexed colonyId,
        uint8 recipeId,
        uint256 inputAmount,
        uint32 completionTime
    );
    event ProcessingCompleted(bytes32 indexed orderId, bytes32 indexed colonyId, uint256 outputAmount);
    event ResourcesProcessed(
        bytes32 indexed colonyId,
        LibColonyWarsStorage.ResourceType inputType,
        LibColonyWarsStorage.ResourceType outputType,
        uint256 inputAmount,
        uint256 outputAmount
    );

    /**
     * @notice Start processing order
     * @param recipeId Recipe to use (0-based)
     * @param inputAmount Amount of input resources
     */
    function startProcessing(uint8 recipeId, uint256 inputAmount) external whenNotPaused nonReentrant returns (bytes32 orderId) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        address caller = LibMeta.msgSender();
        bytes32 colonyId = cws.userToColony[caller];
        require(colonyId != bytes32(0), "No colony");
        
        // Get recipe
        LibColonyWarsStorage.ProcessingRecipe storage recipe = cws.processingRecipes[recipeId];
        if (!recipe.active) revert RecipeNotFound();
        
        // Check tech level requirement
        // Tech level is managed via TerritoryEquipmentFacet.totalTechBonus
        
        // Calculate costs
        uint256 totalInputNeeded = recipe.inputAmount * (inputAmount / recipe.outputAmount);
        
        // Verify and deduct resources using ResourceHelper
        LibColonyWarsStorage.ResourceBalance storage balance = cws.colonyResources[colonyId];
        ResourceHelper.requireAndDeduct(balance, recipe.inputType, totalInputNeeded);

        // Pay configured processing fee (uses YELLOW token with burn)
        LibColonyWarsStorage.OperationFee storage processingFee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_PROCESSING);
        if (processingFee.enabled) {
            LibFeeCollection.processConfiguredFee(
                processingFee,
                LibMeta.msgSender(),
                "resource_processing"
            );
        }

        // Create processing order
        orderId = keccak256(abi.encodePacked(colonyId, recipeId, block.timestamp, ++cws.processingOrderCounter));
        LibColonyWarsStorage.ProcessingOrder storage order = cws.processingOrders[orderId];
        order.colonyId = colonyId;
        order.recipeId = recipeId;
        order.inputAmount = inputAmount;
        order.startTime = uint32(block.timestamp);
        order.completionTime = uint32(block.timestamp + recipe.processingTime);
        order.completed = false;
        order.claimed = false;
        
        emit ProcessingStarted(orderId, colonyId, recipeId, inputAmount, order.completionTime);
        
        return orderId;
    }

    /**
     * @notice Complete and claim processing order
     * @param orderId Order to complete
     */
    function completeProcessing(bytes32 orderId) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ProcessingOrder storage order = cws.processingOrders[orderId];
        
        if (order.colonyId == bytes32(0)) revert OrderNotFound();
        if (order.claimed) revert OrderAlreadyClaimed();
        
        // Verify caller is colony owner
        address caller = LibMeta.msgSender();
        bytes32 colonyId = cws.userToColony[caller];
        require(order.colonyId == colonyId, "Not your order");
        
        // Check if processing complete
        if (block.timestamp < order.completionTime) revert ProcessingNotComplete();
        
        // Get recipe
        LibColonyWarsStorage.ProcessingRecipe storage recipe = cws.processingRecipes[order.recipeId];
        
        // Calculate output
        uint256 outputAmount = (order.inputAmount / recipe.inputAmount) * recipe.outputAmount;
        
        // Add output resources to colony using ResourceHelper
        LibColonyWarsStorage.ResourceBalance storage balance = cws.colonyResources[colonyId];
        ResourceHelper.addResources(balance, recipe.outputType, outputAmount);
        
        // Mark as claimed
        order.completed = true;
        order.claimed = true;
        
        emit ProcessingCompleted(orderId, colonyId, outputAmount);
        emit ResourcesProcessed(colonyId, recipe.inputType, recipe.outputType, order.inputAmount, outputAmount);
    }

    /**
     * @notice Get processing order info
     * @param orderId Order to query
     * @return Processing order struct
     */
    function getProcessingOrder(bytes32 orderId) 
        external 
        view 
        returns (LibColonyWarsStorage.ProcessingOrder memory) 
    {
        return LibColonyWarsStorage.colonyWarsStorage().processingOrders[orderId];
    }

    /**
     * @notice Get recipe info
     * @param recipeId Recipe to query
     * @return Processing recipe struct
     */
    function getProcessingRecipe(uint8 recipeId) 
        external 
        view 
        returns (LibColonyWarsStorage.ProcessingRecipe memory) 
    {
        return LibColonyWarsStorage.colonyWarsStorage().processingRecipes[recipeId];
    }

    /**
     * @notice Admin: Create or update processing recipe
     * @param recipeId Recipe ID
     * @param inputType Input resource type
     * @param outputType Output resource type
     * @param inputAmount Input amount required
     * @param outputAmount Output amount produced
     * @param auxCost Auxiliary cost for processing
     * @param processingTime Time required in seconds
     * @param requiredTechLevel Minimum tech level
     */
    function setProcessingRecipe(
        uint8 recipeId,
        LibColonyWarsStorage.ResourceType inputType,
        LibColonyWarsStorage.ResourceType outputType,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 auxCost,
        uint32 processingTime,
        uint8 requiredTechLevel
    ) external onlyAuthorized{
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ProcessingRecipe storage recipe = cws.processingRecipes[recipeId];
        
        recipe.recipeId = recipeId;
        recipe.inputType = inputType;
        recipe.outputType = outputType;
        recipe.inputAmount = inputAmount;
        recipe.outputAmount = outputAmount;
        recipe.auxCost = auxCost;
        recipe.processingTime = processingTime;
        recipe.requiredTechLevel = requiredTechLevel;
        recipe.active = true;
        
        emit RecipeCreated(recipeId, auxCost, processingTime);
    }
}
