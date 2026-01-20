// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibPremiumStorage} from "../../chargepod/libraries/LibPremiumStorage.sol";
import {LibStakingStorage} from "../libraries/LibStakingStorage.sol";
import {ResourceHelper} from "../../chargepod/libraries/ResourceHelper.sol";
import {PodsUtils} from "../../../libraries/PodsUtils.sol";
import {IExternalBiopod} from "../interfaces/IStakingInterfaces.sol";
import {Calibration, SpecimenCollection} from "../../../libraries/HenomorphsModel.sol";
import {StakedSpecimen} from "../../../libraries/StakingModel.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title PremiumActionsFacet
 * @notice Premium actions system with ZICO/YLW dual pricing and staking discounts
 * @dev Diamond facet implementing premium features inspired by Aavegotchi and Axie Infinity
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract PremiumActionsFacet is AccessControlBase {
    using SafeERC20 for IERC20;
    using LibPremiumStorage for LibPremiumStorage.PremiumStorage;

    // ==================== EVENTS ====================

    event PremiumActionPurchased(
        address indexed user,
        LibPremiumStorage.ActionType indexed actionType,
        address paymentToken,
        uint256 amount,
        uint256 discountApplied,
        uint40 expiresAt
    );

    event PremiumActionActivated(
        address indexed user,
        LibPremiumStorage.ActionType indexed actionType,
        uint40 activatedAt,
        uint40 expiresAt
    );

    event PremiumActionUsed(
        address indexed user,
        LibPremiumStorage.ActionType indexed actionType,
        uint16 usesRemaining
    );

    event PremiumActionExpired(
        address indexed user,
        LibPremiumStorage.ActionType indexed actionType
    );

    event ActionConfigUpdated(
        LibPremiumStorage.ActionType indexed actionType,
        uint256 priceZICO,
        uint256 priceYLW,
        uint32 duration
    );

    event DiscountTierSet(
        uint8 indexed tier,
        uint8 minLevel,
        uint16 discountBps,
        uint32 minStakingDays
    );

    event PremiumRevenueClaimed(
        address indexed token,
        address indexed treasury,
        uint256 amount
    );

    // ==================== ERRORS ====================

    error PremiumDisabled();
    error ActionNotEnabled(LibPremiumStorage.ActionType actionType);
    error ActionAlreadyActive();
    error ActionNotActive();
    error ActionExpired();
    error NoUsesRemaining();
    error InvalidPaymentToken();
    error InsufficientPayment(uint256 required, uint256 provided);
    error InvalidDuration();
    error InvalidTier();
    error TreasuryNotSet();
    error InvalidAddress();

    // ==================== INITIALIZATION ====================

    /**
     * @notice Initialize premium actions system
     * @dev Configuration now uses centralized treasury from LibHenomorphsStorage
     */
    function initializePremiumActions(
        address /* _ylwToken */,
        address /* _zicoToken */,
        address /* _treasury */
    ) external onlyAuthorized {
        // NOTE: These parameters are now ignored - treasury configuration comes from LibHenomorphsStorage
        // Keeping function signature for compatibility but using ResourceHelper centralized config
        
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        ps.premiumEnabled = true;

        // Initialize default action configs
        _initializeActionConfigs(ps);
        
        // Initialize discount tiers
        _initializeDiscountTiers(ps);
    }

    function _initializeActionConfigs(LibPremiumStorage.PremiumStorage storage ps) private {
        // INSTANT_PROCESS - Skip cooldowns
        ps.actionConfigs[LibPremiumStorage.ActionType.INSTANT_PROCESS] = LibPremiumStorage.ActionConfig({
            priceZICO: 50 ether,
            priceYLW: 1000 ether,
            duration: 0,          // Instant use
            uses: 1,              // Single use
            effectStrength: 10000, // 100% (instant)
            enabled: true,
            stackable: false
        });

        // DOUBLE_REWARDS - 2x rewards
        ps.actionConfigs[LibPremiumStorage.ActionType.DOUBLE_REWARDS] = LibPremiumStorage.ActionConfig({
            priceZICO: 100 ether,
            priceYLW: 2000 ether,
            duration: 7 days,
            uses: 0,              // Unlimited during duration
            effectStrength: 200,  // 2x multiplier
            enabled: true,
            stackable: false
        });

        // FREE_REPAIRS
        ps.actionConfigs[LibPremiumStorage.ActionType.FREE_REPAIRS] = LibPremiumStorage.ActionConfig({
            priceZICO: 75 ether,
            priceYLW: 1500 ether,
            duration: 14 days,
            uses: 0,
            effectStrength: 100,  // 100% discount
            enabled: true,
            stackable: true
        });

        // BOOST_PRODUCTION - 1.5x resource production
        ps.actionConfigs[LibPremiumStorage.ActionType.BOOST_PRODUCTION] = LibPremiumStorage.ActionConfig({
            priceZICO: 150 ether,
            priceYLW: 3000 ether,
            duration: 30 days,
            uses: 0,
            effectStrength: 150,  // 1.5x multiplier
            enabled: true,
            stackable: false
        });

        // GUARANTEED_CRIT
        ps.actionConfigs[LibPremiumStorage.ActionType.GUARANTEED_CRIT] = LibPremiumStorage.ActionConfig({
            priceZICO: 80 ether,
            priceYLW: 1600 ether,
            duration: 0,
            uses: 10,             // 10 guaranteed crits
            effectStrength: 10000, // 100% crit chance
            enabled: true,
            stackable: false
        });

        // SKIP_BATTLE_COOLDOWN
        ps.actionConfigs[LibPremiumStorage.ActionType.SKIP_BATTLE_COOLDOWN] = LibPremiumStorage.ActionConfig({
            priceZICO: 60 ether,
            priceYLW: 1200 ether,
            duration: 0,
            uses: 3,
            effectStrength: 10000,
            enabled: true,
            stackable: false
        });

        // ENHANCED_DROPS - Better rare drop chances
        ps.actionConfigs[LibPremiumStorage.ActionType.ENHANCED_DROPS] = LibPremiumStorage.ActionConfig({
            priceZICO: 120 ether,
            priceYLW: 2400 ether,
            duration: 7 days,
            uses: 0,
            effectStrength: 200,  // 2x drop rates
            enabled: true,
            stackable: false
        });

        // TERRITORY_SHIELD - Territory protection
        ps.actionConfigs[LibPremiumStorage.ActionType.TERRITORY_SHIELD] = LibPremiumStorage.ActionConfig({
            priceZICO: 200 ether,
            priceYLW: 4000 ether,
            duration: 3 days,
            uses: 0,
            effectStrength: 100,  // 100% protection
            enabled: true,
            stackable: false
        });
    }

    function _initializeDiscountTiers(LibPremiumStorage.PremiumStorage storage ps) private {
        // Tier 0: Level 1-10, 0% discount
        ps.discountTiers[0] = LibPremiumStorage.DiscountTier({
            minLevel: 1,
            discountBps: 0,
            minStakingDays: 0
        });

        // Tier 1: Level 11-20, 5% discount, 7+ days staked
        ps.discountTiers[1] = LibPremiumStorage.DiscountTier({
            minLevel: 11,
            discountBps: 500,  // 5%
            minStakingDays: 7
        });

        // Tier 2: Level 21-30, 10% discount, 30+ days staked
        ps.discountTiers[2] = LibPremiumStorage.DiscountTier({
            minLevel: 21,
            discountBps: 1000, // 10%
            minStakingDays: 30
        });

        // Tier 3: Level 31-40, 15% discount, 90+ days staked
        ps.discountTiers[3] = LibPremiumStorage.DiscountTier({
            minLevel: 31,
            discountBps: 1500, // 15%
            minStakingDays: 90
        });

        // Tier 4: Level 41+, 20% discount, 180+ days staked
        ps.discountTiers[4] = LibPremiumStorage.DiscountTier({
            minLevel: 41,
            discountBps: 2000, // 20%
            minStakingDays: 180
        });

        ps.maxDiscountTier = 4;
    }

    // ==================== CORE FUNCTIONS ====================

    /**
     * @notice Purchase premium action with primary or auxiliary currency
     * @param actionType Type of premium action
     * @param payWithPrimary True to pay with primary currency, false for auxiliary
     * @return finalPrice Final price after discount
     */
    function purchasePremiumAction(
        LibPremiumStorage.ActionType actionType,
        bool payWithPrimary
    ) external nonReentrant whenNotPaused returns (uint256 finalPrice) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        
        if (!ps.premiumEnabled) revert PremiumDisabled();
        
        LibPremiumStorage.ActionConfig memory config = ps.actionConfigs[actionType];
        if (!config.enabled) revert ActionNotEnabled(actionType);

        address user = LibMeta.msgSender();
        
        // Check if action is already active (for duration-based or use-based actions)
        LibPremiumStorage.PremiumAction storage existing = ps.userActions[user][actionType];
        if (existing.active && (existing.expiresAt == 0 || existing.expiresAt > block.timestamp)) {
            if (existing.usesRemaining > 0 || config.duration > 0) {
                revert ActionAlreadyActive();
            }
        }

        // Calculate price with discount
        (uint256 basePrice, uint16 discountBps) = _calculatePrice(user, config, payWithPrimary);
        finalPrice = basePrice - (basePrice * discountBps / 10000);

        // Process payment using ResourceHelper centralized treasury
        if (payWithPrimary) {
            ResourceHelper.collectPrimaryFee(user, finalPrice, "premium_action_purchase");
        } else {
            ResourceHelper.collectAuxiliaryFee(user, finalPrice, "premium_action_purchase");
        }

        // Create premium action
        uint40 expiresAt = config.duration > 0 
            ? uint40(block.timestamp + config.duration)
            : uint40(block.timestamp);

        ps.userActions[user][actionType] = LibPremiumStorage.PremiumAction({
            actionType: actionType,
            purchasedAt: uint40(block.timestamp),
            activatedAt: config.duration > 0 ? uint40(block.timestamp) : 0,
            expiresAt: expiresAt,
            usesRemaining: config.uses,
            totalUses: config.uses,
            active: config.duration > 0, // Auto-activate duration-based actions
            amountPaid: finalPrice
        });

        // Update statistics
        ps.actionsPurchased[actionType]++;
        ps.userPremiumSpent[user] += finalPrice;
        ps.totalPremiumRevenue += finalPrice;

        // Track active action (if duration-based or use-based and active)
        if (config.duration > 0 || config.uses > 0) {
            _addActiveAction(ps, user, actionType);
        }

        emit PremiumActionPurchased(
            user,
            actionType,
            payWithPrimary ? ResourceHelper.getPrimaryCurrency() : ResourceHelper.getAuxiliaryCurrency(),
            finalPrice,
            discountBps,
            expiresAt
        );

        if (config.duration > 0) {
            emit PremiumActionActivated(user, actionType, uint40(block.timestamp), expiresAt);
        }

        return finalPrice;
    }

    /**
     * @notice Activate purchased premium action (for use-based actions)
     * @param actionType Type of action to activate
     */
    function activatePremiumAction(LibPremiumStorage.ActionType actionType) external whenNotPaused {
        address user = LibMeta.msgSender();
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        
        LibPremiumStorage.PremiumAction storage action = ps.userActions[user][actionType];
        
        if (action.purchasedAt == 0) revert ActionNotActive();
        if (action.active) revert ActionAlreadyActive();
        if (action.usesRemaining == 0) revert NoUsesRemaining();

        action.active = true;
        action.activatedAt = uint40(block.timestamp);

        // Track active action
        _addActiveAction(ps, user, actionType);

        emit PremiumActionActivated(user, actionType, uint40(block.timestamp), action.expiresAt);
    }

    /**
     * @notice Use one charge of premium action (called by other facets)
     * @param user User address
     * @param actionType Type of action being used
     * @return effectStrength Strength of the effect
     */
    function usePremiumAction(
        address user,
        LibPremiumStorage.ActionType actionType
    ) external onlyAuthorized returns (uint16 effectStrength) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.PremiumAction storage action = ps.userActions[user][actionType];

        if (!action.active) revert ActionNotActive();
        if (action.expiresAt != 0 && action.expiresAt < block.timestamp) revert ActionExpired();

        // Decrement uses if applicable
        if (action.usesRemaining > 0) {
            action.usesRemaining--;
            
            // Deactivate if no uses left
            if (action.usesRemaining == 0) {
                action.active = false;
                _removeActiveAction(ps, user, actionType);
                emit PremiumActionExpired(user, actionType);
            }
            
            emit PremiumActionUsed(user, actionType, action.usesRemaining);
        }

        ps.actionsRedeemed[actionType]++;

        return ps.actionConfigs[actionType].effectStrength;
    }

    // ==================== VIEW FUNCTIONS ====================

    /**
     * @notice Check if user has active premium action
     * @param user User address
     * @param actionType Type of action
     * @return active Is action active
     * @return effectStrength Effect strength if active
     */
    function hasActivePremiumAction(
        address user,
        LibPremiumStorage.ActionType actionType
    ) external view returns (bool active, uint16 effectStrength) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.PremiumAction storage action = ps.userActions[user][actionType];

        if (!action.active) return (false, 0);
        if (action.expiresAt != 0 && action.expiresAt < block.timestamp) return (false, 0);
        
        return (true, ps.actionConfigs[actionType].effectStrength);
    }

    /**
     * @notice Get user's premium action details
     */
    function getUserPremiumAction(
        address user,
        LibPremiumStorage.ActionType actionType
    ) external view returns (
        bool active,
        uint40 purchasedAt,
        uint40 activatedAt,
        uint40 expiresAt,
        uint16 usesRemaining,
        uint16 totalUses,
        uint256 amountPaid
    ) {
        LibPremiumStorage.PremiumAction storage action = 
            LibPremiumStorage.premiumStorage().userActions[user][actionType];
        
        return (
            action.active && (action.expiresAt == 0 || action.expiresAt > block.timestamp),
            action.purchasedAt,
            action.activatedAt,
            action.expiresAt,
            action.usesRemaining,
            action.totalUses,
            action.amountPaid
        );
    }

    /**
     * @notice Get action configuration
     */
    function getActionConfig(LibPremiumStorage.ActionType actionType) 
        external 
        view 
        returns (LibPremiumStorage.ActionConfig memory) 
    {
        return LibPremiumStorage.premiumStorage().actionConfigs[actionType];
    }

    /**
     * @notice Get user's discount tier and applicable discount
     * @param user User address
     * @return tier Discount tier
     * @return discountBps Discount in basis points
     */
    function getUserDiscountTier(address user) 
        external 
        view 
        returns (uint8 tier, uint16 discountBps) 
    {
        return _getUserDiscountTier(user);
    }

    /**
     * @notice Get list of user's active premium actions
     * @param user User address
     * @return actionTypes Array of active action types
     */
    function getUserActiveActions(address user) 
        external 
        view 
        returns (LibPremiumStorage.ActionType[] memory actionTypes) 
    {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        return ps.userActiveActionTypes[user];
    }

    /**
     * @notice Get detailed info about all user's active actions
     * @param user User address
     * @return actions Array of active premium actions with full details
     */
    function getUserActiveActionsDetailed(address user) 
        external 
        view 
        returns (LibPremiumStorage.PremiumAction[] memory actions) 
    {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.ActionType[] memory activeTypes = ps.userActiveActionTypes[user];
        
        actions = new LibPremiumStorage.PremiumAction[](activeTypes.length);
        
        for (uint256 i = 0; i < activeTypes.length; i++) {
            actions[i] = ps.userActions[user][activeTypes[i]];
        }
        
        return actions;
    }

    /**
     * @notice Calculate price with discount for user
     * @param user User address
     * @param actionType Type of action
     * @param payWithPrimary True for primary currency, false for auxiliary
     * @return basePrice Base price before discount
     * @return finalPrice Final price after discount
     * @return discountBps Discount applied in basis points
     */
    function calculatePriceForUser(
        address user,
        LibPremiumStorage.ActionType actionType,
        bool payWithPrimary
    ) external view returns (uint256 basePrice, uint256 finalPrice, uint16 discountBps) {
        LibPremiumStorage.ActionConfig memory config =
            LibPremiumStorage.premiumStorage().actionConfigs[actionType];

        (basePrice, discountBps) = _calculatePrice(user, config, payWithPrimary);
        finalPrice = basePrice - (basePrice * discountBps / 10000);
    }

    // ==================== ADMIN FUNCTIONS ====================

    /**
     * @notice Update action configuration
     */
    function setActionConfig(
        LibPremiumStorage.ActionType actionType,
        uint256 priceZICO,
        uint256 priceYLW,
        uint32 duration,
        uint16 uses,
        uint16 effectStrength,
        bool enabled,
        bool stackable
    ) external onlyAuthorized {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        
        ps.actionConfigs[actionType] = LibPremiumStorage.ActionConfig({
            priceZICO: priceZICO,
            priceYLW: priceYLW,
            duration: duration,
            uses: uses,
            effectStrength: effectStrength,
            enabled: enabled,
            stackable: stackable
        });

        emit ActionConfigUpdated(actionType, priceZICO, priceYLW, duration);
    }

    /**
     * @notice Set discount tier
     */
    function setDiscountTier(
        uint8 tier,
        uint8 minLevel,
        uint16 discountBps,
        uint32 minStakingDays
    ) external onlyAuthorized {
        if (tier > 10) revert InvalidTier();
        if (discountBps > 5000) revert InvalidTier(); // Max 50% discount

        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        
        ps.discountTiers[tier] = LibPremiumStorage.DiscountTier({
            minLevel: minLevel,
            discountBps: discountBps,
            minStakingDays: minStakingDays
        });

        if (tier > ps.maxDiscountTier) {
            ps.maxDiscountTier = tier;
        }

        emit DiscountTierSet(tier, minLevel, discountBps, minStakingDays);
    }

    /**
     * @notice Enable/disable premium system
     */
    function setPremiumEnabled(bool enabled) external onlyAuthorized {
        LibPremiumStorage.premiumStorage().premiumEnabled = enabled;
    }

    // NOTE: Treasury configuration now centralized in LibHenomorphsStorage.chargeTreasury
    // Use ChargeConfigurationControlFacet to update treasury settings

    /**
     * @notice Clean up expired actions from user's active list
     * @dev Can be called by user or admin to maintain clean state
     * @param user User address to clean up
     * @return removedCount Number of expired actions removed
     */
    function cleanupExpiredActions(address user) external returns (uint256 removedCount) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.ActionType[] storage activeActions = ps.userActiveActionTypes[user];
        
        uint256 i = 0;
        while (i < activeActions.length) {
            LibPremiumStorage.ActionType actionType = activeActions[i];
            LibPremiumStorage.PremiumAction storage action = ps.userActions[user][actionType];
            
            // Check if action is expired or inactive
            bool shouldRemove = false;
            
            if (!action.active) {
                shouldRemove = true;
            } else if (action.expiresAt != 0 && action.expiresAt < block.timestamp) {
                // Mark as inactive and remove
                action.active = false;
                shouldRemove = true;
                emit PremiumActionExpired(user, actionType);
            } else if (action.usesRemaining == 0) {
                // No uses left and should be removed
                action.active = false;
                shouldRemove = true;
                emit PremiumActionExpired(user, actionType);
            }
            
            if (shouldRemove) {
                // Remove from array (swap with last and pop)
                activeActions[i] = activeActions[activeActions.length - 1];
                activeActions.pop();
                removedCount++;
                // Don't increment i, check same position again
            } else {
                i++;
            }
        }
        
        return removedCount;
    }

    // ==================== INTERNAL HELPERS ====================

    function _calculatePrice(
        address user,
        LibPremiumStorage.ActionConfig memory config,
        bool payWithPrimary
    ) internal view returns (uint256 basePrice, uint16 discountBps) {
        basePrice = payWithPrimary ? config.priceZICO : config.priceYLW;
        (, discountBps) = _getUserDiscountTier(user);
    }

    function _getUserDiscountTier(address user) 
        internal 
        view 
        returns (uint8 tier, uint16 discountBps) 
    {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        // Get user's staked tokens (correct mapping: stakerTokens)
        uint256[] memory combinedIds = ss.stakerTokens[user];
        
        if (combinedIds.length == 0) {
            return (0, 0); // No staked tokens = no discount
        }

        // Track highest level and longest staking duration across ALL tokens
        uint8 maxLevel = 0;
        uint32 maxStakingDays = 0;

        for (uint256 i = 0; i < combinedIds.length; i++) {
            uint256 combinedId = combinedIds[i];
            StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
            
            if (!staked.staked) continue; // Skip if not actually staked
            
            // Get staking duration in days
            uint32 stakingDays = uint32((block.timestamp - staked.stakedSince) / 1 days);
            if (stakingDays > maxStakingDays) {
                maxStakingDays = stakingDays;
            }
            
            // Extract collectionId and tokenId from combinedId
            (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);
            
            // Try to get token level from Biopod
            SpecimenCollection storage collection = ss.collections[collectionId];
            if (collection.biopodAddress != address(0)) {
                try IExternalBiopod(collection.biopodAddress).probeCalibration(collectionId, tokenId) returns (Calibration memory cal) {
                    if (cal.level > maxLevel) {
                        maxLevel = uint8(cal.level);
                    }
                } catch {
                    // If Biopod fails, continue to next token
                }
            }
        }

        // Find highest discount tier user qualifies for
        for (uint8 i = ps.maxDiscountTier + 1; i > 0; i--) {
            uint8 tierIndex = i - 1;
            LibPremiumStorage.DiscountTier memory tierData = ps.discountTiers[tierIndex];
            if (maxLevel >= tierData.minLevel && maxStakingDays >= tierData.minStakingDays) {
                return (tierIndex, tierData.discountBps);
            }
        }

        return (0, 0);
    }

    /**
     * @notice Add action type to user's active actions list
     * @dev Internal helper to maintain userActiveActionTypes array
     * @param ps Premium storage reference
     * @param user User address
     * @param actionType Action type to add
     */
    function _addActiveAction(
        LibPremiumStorage.PremiumStorage storage ps,
        address user,
        LibPremiumStorage.ActionType actionType
    ) internal {
        // Check if action type already exists in array
        LibPremiumStorage.ActionType[] storage activeActions = ps.userActiveActionTypes[user];
        
        for (uint256 i = 0; i < activeActions.length; i++) {
            if (activeActions[i] == actionType) {
                return; // Already tracked, no need to add
            }
        }
        
        // Add new action type to array
        activeActions.push(actionType);
    }

    /**
     * @notice Remove action type from user's active actions list
     * @dev Internal helper to maintain userActiveActionTypes array
     * @param ps Premium storage reference
     * @param user User address
     * @param actionType Action type to remove
     */
    function _removeActiveAction(
        LibPremiumStorage.PremiumStorage storage ps,
        address user,
        LibPremiumStorage.ActionType actionType
    ) internal {
        LibPremiumStorage.ActionType[] storage activeActions = ps.userActiveActionTypes[user];
        
        // Find and remove action type from array
        for (uint256 i = 0; i < activeActions.length; i++) {
            if (activeActions[i] == actionType) {
                // Move last element to this position and pop
                activeActions[i] = activeActions[activeActions.length - 1];
                activeActions.pop();
                return;
            }
        }
    }
}
