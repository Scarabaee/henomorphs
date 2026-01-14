// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibResourceStorage} from "../libraries/LibResourceStorage.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ResourceMarketplaceFacet
 * @notice P2P marketplace for resource trading between colonies
 * @dev Implements order book trading with utility token settlement
 */
contract ResourceMarketplaceFacet is AccessControlBase {
    using SafeERC20 for IERC20;
    
    // ==================== STRUCTS ====================
    
    struct TradeOrder {
        address seller;
        bytes32 sellerColony;
        uint8 resourceType;
        uint256 amount;
        uint256 pricePerUnit;      // In utility token (e.g., YLW)
        uint32 expiresAt;
        bool active;
    }
    
    // ==================== EVENTS ====================
    
    event OrderCreated(bytes32 indexed orderId, address indexed seller, uint8 resourceType, uint256 amount, uint256 pricePerUnit);
    event OrderCancelled(bytes32 indexed orderId, address indexed seller);
    event OrderFilled(bytes32 indexed orderId, address indexed buyer, address indexed seller, uint256 amount, uint256 totalPrice);
    event OrderPartiallyFilled(bytes32 indexed orderId, address indexed buyer, uint256 amountFilled, uint256 amountRemaining);
    event MarketFeesCollected(uint256 totalFees);
    
    // ==================== ERRORS ====================
    
    error OrderNotFound(bytes32 orderId);
    error OrderExpired(bytes32 orderId);
    error OrderInactive(bytes32 orderId);
    error InsufficientResources(uint8 resourceType, uint256 required, uint256 available);
    error InsufficientPayment(uint256 required, uint256 provided);
    error InvalidAmount(uint256 amount);
    error InvalidPrice(uint256 price);
    error UnauthorizedCancellation(address caller, address seller);
    error SelfTrade(address user);
    
    // ==================== CONSTANTS ====================
    
    uint16 constant MARKET_FEE_BPS = 200; // 2% fee
    uint32 constant MAX_ORDER_DURATION = 7 days;
    
    // ==================== STORAGE ====================
    
    bytes32 constant MARKETPLACE_STORAGE_POSITION = keccak256("henomorphs.marketplace.storage");
    
    struct MarketplaceStorage {
        mapping(bytes32 => TradeOrder) orders;
        bytes32[] activeOrderIds;
        mapping(address => bytes32[]) userOrders;
        uint256 totalFeesCollected;
    }
    
    function marketplaceStorage() internal pure returns (MarketplaceStorage storage ms) {
        bytes32 position = MARKETPLACE_STORAGE_POSITION;
        assembly {
            ms.slot := position
        }
    }
    
    // ==================== ORDER MANAGEMENT ====================
    
    /**
     * @notice Create sell order for resources
     * @param resourceType Type of resource to sell
     * @param amount Amount to sell
     * @param pricePerUnit Price per unit in utility token
     * @param duration Order duration in seconds (max 7 days)
     * @return orderId Unique order identifier
     */
    function createSellOrder(
        uint8 resourceType,
        uint256 amount,
        uint256 pricePerUnit,
        uint32 duration
    ) external whenNotPaused nonReentrant returns (bytes32 orderId) {
        if (amount == 0) revert InvalidAmount(amount);
        if (pricePerUnit == 0) revert InvalidPrice(pricePerUnit);
        if (duration > MAX_ORDER_DURATION) duration = MAX_ORDER_DURATION;
        
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        MarketplaceStorage storage ms = marketplaceStorage();
        address seller = LibMeta.msgSender();

        // Apply decay before checking/locking resources
        LibResourceStorage.applyResourceDecay(seller);

        // Verify seller has resources
        uint256 available = rs.userResources[seller][resourceType];
        if (available < amount) {
            revert InsufficientResources(resourceType, amount, available);
        }

        // Lock resources
        rs.userResources[seller][resourceType] = available - amount;
        
        // Get seller's colony
        bytes32 sellerColony = _getUserColony(seller);
        
        // Create order
        orderId = keccak256(abi.encodePacked(
            seller,
            resourceType,
            amount,
            pricePerUnit,
            block.timestamp
        ));
        
        TradeOrder storage order = ms.orders[orderId];
        order.seller = seller;
        order.sellerColony = sellerColony;
        order.resourceType = resourceType;
        order.amount = amount;
        order.pricePerUnit = pricePerUnit;
        order.expiresAt = uint32(block.timestamp) + duration;
        order.active = true;
        
        ms.activeOrderIds.push(orderId);
        ms.userOrders[seller].push(orderId);
        
        emit OrderCreated(orderId, seller, resourceType, amount, pricePerUnit);
    }
    
    /**
     * @notice Fill sell order (buy resources)
     * @param orderId Order to fill
     * @param amount Amount to buy (0 = fill entire order)
     */
    function fillOrder(
        bytes32 orderId,
        uint256 amount
    ) external whenNotPaused nonReentrant {
        MarketplaceStorage storage ms = marketplaceStorage();
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        
        TradeOrder storage order = ms.orders[orderId];
        
        // Validations
        if (order.seller == address(0)) revert OrderNotFound(orderId);
        if (!order.active) revert OrderInactive(orderId);
        if (block.timestamp > order.expiresAt) revert OrderExpired(orderId);
        
        address buyer = LibMeta.msgSender();
        if (buyer == order.seller) revert SelfTrade(buyer);
        
        // Determine fill amount
        uint256 fillAmount = amount == 0 ? order.amount : amount;
        if (fillAmount > order.amount) fillAmount = order.amount;
        if (fillAmount == 0) revert InvalidAmount(0);

        // Apply decay to buyer before awarding resources
        LibResourceStorage.applyResourceDecay(buyer);

        // Calculate payment
        uint256 totalPrice = fillAmount * order.pricePerUnit;
        uint256 fee = (totalPrice * MARKET_FEE_BPS) / 10000;
        uint256 sellerProceeds = totalPrice - fee;
        
        // Verify buyer has payment
        IERC20 utilityToken = IERC20(rs.config.utilityToken);
        if (utilityToken.balanceOf(buyer) < totalPrice) {
            revert InsufficientPayment(totalPrice, utilityToken.balanceOf(buyer));
        }
        
        // Transfer payment
        utilityToken.safeTransferFrom(buyer, order.seller, sellerProceeds);
        utilityToken.safeTransferFrom(buyer, rs.config.paymentBeneficiary, fee);
        
        // Transfer resources
        rs.userResources[buyer][order.resourceType] += fillAmount;
        
        // Update order
        order.amount -= fillAmount;
        ms.totalFeesCollected += fee;
        
        if (order.amount == 0) {
            order.active = false;
            emit OrderFilled(orderId, buyer, order.seller, fillAmount, totalPrice);
        } else {
            emit OrderPartiallyFilled(orderId, buyer, fillAmount, order.amount);
        }
    }
    
    /**
     * @notice Cancel active order and return resources
     * @param orderId Order to cancel
     */
    function cancelOrder(bytes32 orderId) external whenNotPaused nonReentrant {
        MarketplaceStorage storage ms = marketplaceStorage();
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        
        TradeOrder storage order = ms.orders[orderId];
        
        if (order.seller == address(0)) revert OrderNotFound(orderId);
        if (!order.active) revert OrderInactive(orderId);
        
        address caller = LibMeta.msgSender();
        if (caller != order.seller) revert UnauthorizedCancellation(caller, order.seller);
        
        // Return locked resources
        rs.userResources[order.seller][order.resourceType] += order.amount;
        
        // Deactivate order
        order.active = false;
        order.amount = 0;
        
        emit OrderCancelled(orderId, order.seller);
    }
    
    /**
     * @notice Batch cancel expired orders (anyone can call)
     * @param orderIds Array of order IDs to cancel
     */
    function cleanupExpiredOrders(bytes32[] calldata orderIds) external {
        MarketplaceStorage storage ms = marketplaceStorage();
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        
        uint32 currentTime = uint32(block.timestamp);
        
        for (uint256 i = 0; i < orderIds.length; i++) {
            TradeOrder storage order = ms.orders[orderIds[i]];
            
            if (order.active && currentTime > order.expiresAt) {
                // Return resources to seller
                rs.userResources[order.seller][order.resourceType] += order.amount;
                
                // Deactivate order
                order.active = false;
                order.amount = 0;
                
                emit OrderCancelled(orderIds[i], order.seller);
            }
        }
    }
    
    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @notice Get order details
     */
    function getOrder(bytes32 orderId) external view returns (
        address seller,
        bytes32 sellerColony,
        uint8 resourceType,
        uint256 amount,
        uint256 pricePerUnit,
        uint32 expiresAt,
        bool active
    ) {
        MarketplaceStorage storage ms = marketplaceStorage();
        TradeOrder storage order = ms.orders[orderId];
        
        if (order.seller == address(0)) revert OrderNotFound(orderId);
        
        return (
            order.seller,
            order.sellerColony,
            order.resourceType,
            order.amount,
            order.pricePerUnit,
            order.expiresAt,
            order.active
        );
    }
    
    /**
     * @notice Get all active orders for resource type
     */
    function getActiveOrdersByResource(uint8 resourceType) external view returns (
        bytes32[] memory orderIds,
        TradeOrder[] memory orders
    ) {
        MarketplaceStorage storage ms = marketplaceStorage();
        
        // Count matching orders
        uint256 count = 0;
        for (uint256 i = 0; i < ms.activeOrderIds.length; i++) {
            TradeOrder storage order = ms.orders[ms.activeOrderIds[i]];
            if (order.active && order.resourceType == resourceType && block.timestamp <= order.expiresAt) {
                count++;
            }
        }
        
        // Populate arrays
        orderIds = new bytes32[](count);
        orders = new TradeOrder[](count);
        
        uint256 index = 0;
        for (uint256 i = 0; i < ms.activeOrderIds.length; i++) {
            bytes32 orderId = ms.activeOrderIds[i];
            TradeOrder storage order = ms.orders[orderId];
            if (order.active && order.resourceType == resourceType && block.timestamp <= order.expiresAt) {
                orderIds[index] = orderId;
                orders[index] = order;
                index++;
            }
        }
    }
    
    /**
     * @notice Get user's active orders
     */
    function getUserOrders(address user) external view returns (
        bytes32[] memory orderIds,
        TradeOrder[] memory orders
    ) {
        MarketplaceStorage storage ms = marketplaceStorage();
        bytes32[] storage userOrderIds = ms.userOrders[user];
        
        // Count active orders
        uint256 count = 0;
        for (uint256 i = 0; i < userOrderIds.length; i++) {
            if (ms.orders[userOrderIds[i]].active) count++;
        }
        
        // Populate arrays
        orderIds = new bytes32[](count);
        orders = new TradeOrder[](count);
        
        uint256 index = 0;
        for (uint256 i = 0; i < userOrderIds.length; i++) {
            bytes32 orderId = userOrderIds[i];
            TradeOrder storage order = ms.orders[orderId];
            if (order.active) {
                orderIds[index] = orderId;
                orders[index] = order;
                index++;
            }
        }
    }
    
    /**
     * @notice Get best sell price for resource type
     */
    function getBestPrice(uint8 resourceType) external view returns (uint256 bestPrice, bytes32 bestOrderId) {
        MarketplaceStorage storage ms = marketplaceStorage();
        
        bestPrice = type(uint256).max;
        
        for (uint256 i = 0; i < ms.activeOrderIds.length; i++) {
            bytes32 orderId = ms.activeOrderIds[i];
            TradeOrder storage order = ms.orders[orderId];
            
            if (order.active && 
                order.resourceType == resourceType && 
                block.timestamp <= order.expiresAt &&
                order.pricePerUnit < bestPrice) {
                bestPrice = order.pricePerUnit;
                bestOrderId = orderId;
            }
        }
        
        if (bestPrice == type(uint256).max) bestPrice = 0;
    }
    
    /**
     * @notice Get marketplace statistics
     */
    function getMarketStats() external view returns (
        uint256 totalActiveOrders,
        uint256 totalFeesCollected,
        uint256[4] memory ordersByResourceType
    ) {
        MarketplaceStorage storage ms = marketplaceStorage();
        
        totalFeesCollected = ms.totalFeesCollected;
        
        for (uint256 i = 0; i < ms.activeOrderIds.length; i++) {
            TradeOrder storage order = ms.orders[ms.activeOrderIds[i]];
            if (order.active && block.timestamp <= order.expiresAt) {
                totalActiveOrders++;
                ordersByResourceType[order.resourceType]++;
            }
        }
    }
    
    // ==================== INTERNAL HELPERS ====================
    
    function _getUserColony(address user) internal view returns (bytes32) {
        LibResourceStorage.ResourceStorage storage rs = LibResourceStorage.resourceStorage();
        
        // Try staking system
        if (rs.config.stakingSystemAddress != address(0)) {
            try IStakingSystem(rs.config.stakingSystemAddress).getUserColony(user) returns (bytes32 colonyId) {
                if (colonyId != bytes32(0)) return colonyId;
            } catch {}
        }
        
        // Try colony facet
        if (rs.config.colonyFacetAddress != address(0)) {
            try IColonyFacet(rs.config.colonyFacetAddress).getUserPrimaryColony(user) returns (bytes32 colonyId) {
                if (colonyId != bytes32(0)) return colonyId;
            } catch {}
        }
        
        return bytes32(0);
    }
}

interface IStakingSystem {
    function getUserColony(address user) external view returns (bytes32);
}

interface IColonyFacet {
    function getUserPrimaryColony(address user) external view returns (bytes32);
}
