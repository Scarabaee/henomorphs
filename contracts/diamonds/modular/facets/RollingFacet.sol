// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibCollectionStorage} from "../libraries/LibCollectionStorage.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {TierVariant, ItemTier} from "../libraries/CollectionModel.sol"; 
import {AccessControlBase} from "./AccessControlBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {RecipientStatus} from "./WhitelistFacet.sol";
import {ISpecimenCollection} from "../interfaces/IExternalSystems.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PodsUtils} from "../utils/PodsUtils.sol";
import {CollectionType} from "../libraries/ModularAssetModel.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";

// ==================== INTERFACES ====================

interface IWhitelist {
    function recordUsage(uint256 collectionId, uint8 tier, address recipient, uint256 amount) external;
    function getRecipientStatus(uint256 collectionId, uint8 tier, address recipient, uint256 seed, bytes32[] calldata merkleProof) external view returns (RecipientStatus memory status);
    function getExemptedQuantity(uint256 collectionId, uint8 tier, address recipient) external view returns (uint256 exemptedAmount, uint256 usedAmount, uint256 freeAvailable);
}

interface IRepositoryFacet {
    function selectVariant(uint256 collectionId, uint8 tier, uint256 seed) external view returns (uint8);
    function updateVariantCounters(uint256 collectionId, uint8 tier, uint256 tokenId, uint8 variant) external;
    function shuffleTokenVariant(uint256 collectionId, uint8 tier, uint256 tokenId) external returns (uint8);
}

/**
 * @title RollingFacet
 * @notice Handles variant rolling system and roll management
 * @dev Rolling, assignment and roll state management for all collection types
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 * @custom:version 5.0.0 - Rolling operations only
 */
contract RollingFacet is AccessControlBase {
    using SafeERC20 for IERC20;
    using Strings for uint256;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    using PodsUtils for uint256;

    uint256 private constant DEFAULT_VARIANT_COUNT = 4;

    // ==================== STRUCTS ====================
    
    struct RollRequest {
        uint256 collectionId;           
        uint256 tokenId;                
        uint256 specimenCollectionId;   
        uint256 specimenTokenId;        
        bytes32 previousRollHash;       
        bytes signature;                
    }
    
    struct AssignRequest {
        uint256 collectionId;           
        bytes32 rollHash;               
        bytes signature;                
    }
    
    // Internal struct to reduce stack depth
    struct RollContext {
        address user;
        uint256 currentNonce;
        uint8 variant;
        bytes32 rollHash;
        uint256 expiresAt;
        uint8 rerollsRemaining;
        string messageToSign;
        uint256 issueId;
    }
    
    // ==================== EVENTS ====================
    
    event VariantRolled(address indexed user, bytes32 indexed rollHash, uint256 indexed tokenId, string messageToSign, uint256 collectionId, uint8 variant, uint256 expiresAt, uint256 paidAmount);
    event VariantRerollChanged(address indexed user, bytes32 indexed newHash, string messageToSign, bytes32 oldHash, uint8 newVariant, uint256 paidAmount);
    event VariantAssigned(address indexed user, bytes32 indexed rollHash, uint256 indexed tokenId, uint8 variant, address targetCollection);
    event VariantRollExpired(bytes32 indexed rollHash, uint8 variant);
    event PaymentProcessed(address indexed user, uint256 amount, bool isNative, bool usedExchange, uint80[2] exchangeRounds, address beneficiary);
    event AssignmentPaymentProcessed(address indexed user, uint256 amount, bool isNative, address beneficiary);
    event SpecimenUsed(uint256 indexed specimenCollectionId, uint256 indexed specimenTokenId, address indexed user, uint256 rollsUsed);
    event SpecimenResetOnExpiry(uint256 indexed specimenCollectionId, uint256 indexed specimenTokenId, bytes32 rollHash);
    event SpecimensBatchReset(address indexed admin, uint256 totalReset);
    event CouponUsageReset(uint256 indexed collectionId, uint256 indexed tokenId, address indexed admin);
    event TokenUnlocked(uint256 indexed collectionId, uint256 indexed tokenId);
    event TokenLocked(uint256 indexed collectionId, uint256 indexed tokenId);
    event CouponReset(uint256 indexed collectionId, uint256 indexed tokenId);
    event RollingPolicyUpdated(uint256 indexed collectionId, bool allowReRolling);
    
    // ==================== CUSTOM ERRORS ====================
    
    error RollingNotSupported();
    error RollingNotActive();
    error RollNotFound();
    error RollExpired();
    error InvalidSignature();
    error MaxRerollsExceeded();
    error InvalidRerollAttempt();
    error RollAlreadyAssigned();
    error InvalidAssignRequest();
    error SpecimenNotAccessible();
    error SpecimenExhausted(uint256 used, uint256 max);
    error RateLimited(uint256 timeRemaining);
    error AssignmentNotActive(); 
    error BatchTooLarge(uint256 requested, uint256 maxAllowed);
    error MaxActiveRollsExceeded(uint256 current, uint256 max);
    error TokenAlreadyHasVariant(uint256 tokenId, uint8 variant);
    error InsufficientVariantsAvailable();
    error TargetCollectionError();
    error InsufficientPayment(uint256 required, uint256 provided);
    error InvalidConfiguration();
    error InvalidCollectionType();
    
    // ==================== MAIN FUNCTIONS ====================
    
    /**
     * @notice Roll variant using specimen token as coupon (generic interface)
     * @dev Universal specimen-based rolling for any collection type
     */
    function rollWithCoupon(
        uint256 collectionId,     // Collection to roll variant for
        uint256 specimenCollectionId,   // Specimen collection (coupon)
        uint256 specimenTokenId,        // Specimen token (coupon)
        bytes32 previousRollHash,
        bytes calldata signature
    ) external payable whenNotPaused nonReentrant returns (
        bytes32 rollHash,
        string memory messageToSign,
        uint8 variant,
        uint256 expiresAt,
        uint8 rerollsRemaining
    ) {
        CollectionType collectionType = _getCollectionType(collectionId);
        
        if (collectionType == CollectionType.Main) {
            return _rollMainVariant(collectionId, 0, previousRollHash, signature);
        } else {
            return _rollAugmentVariant(collectionId, 0, specimenCollectionId, specimenTokenId, previousRollHash, signature);
        }
    }
    
    /**
     * @notice Roll variant for any collection that supports it
     * @param collectionId Collection ID
     * @param tokenId Token ID  
     * @param specimenCollectionId Specimen collection ID (0 for Main collections)
     * @param specimenTokenId Specimen token ID (0 for Main collections)
     * @param previousRollHash Previous roll hash (bytes32(0) for first roll)
     * @param signature User signature
     * @return rollHash Unique identifier for this roll
     * @return messageToSign Message user must sign to assign this roll
     * @return variant The rolled variant number
     * @return expiresAt Timestamp when this roll expires
     * @return rerollsRemaining Number of rerolls left for this user
     */
    function rollVariant(
        uint256 collectionId,
        uint256 tokenId,
        uint256 specimenCollectionId,
        uint256 specimenTokenId,
        bytes32 previousRollHash,
        bytes calldata signature
    ) public payable whenNotPaused nonReentrant returns (
        bytes32 rollHash,
        string memory messageToSign,
        uint8 variant,
        uint256 expiresAt,
        uint8 rerollsRemaining
    ) {
        CollectionType collectionType = _getCollectionType(collectionId);
        
        if (collectionType == CollectionType.Main) {
            return _rollMainVariant(collectionId, tokenId, previousRollHash, signature);
        } else {
            return _rollAugmentVariant(collectionId, tokenId, specimenCollectionId, specimenTokenId, previousRollHash, signature);
        }
    }
    
    /**
     * @notice Assign variant from roll
     * @param collectionId Collection ID
     * @param rollHash Roll hash to assign
     * @param signature User signature
     * @return tokenId Token ID that received the variant
     * @return variant Assigned variant
     */
    function assignVariant(
        uint256 collectionId,
        bytes32 rollHash,
        bytes calldata signature
    ) public payable whenNotPaused nonReentrant returns (uint256 tokenId, uint8 variant) {
        AssignRequest memory request = AssignRequest({
            collectionId: collectionId,
            rollHash: rollHash,
            signature: signature
        });

        return _assignVariant(request);
    }

    function assignRolled(
        uint256 collectionId,
        uint8,
        bytes32 rollHash,
        bytes calldata signature
    ) external payable whenNotPaused nonReentrant returns (
        uint256[] memory tokenIds,
        uint8 variant,
        uint256 totalPaid
    ) {
        // Get specimen info from roll
        LibCollectionStorage.VariantRoll storage roll = _getVariantRoll(rollHash);
        if (!roll.exists) {
            revert RollNotFound();
        }
        
        CollectionType collectionType = _getCollectionType(collectionId);
        
        if (collectionType == CollectionType.Main) {
            // Main collections: assign to existing token
            (uint256 tokenId, uint8 assignedVariant) = assignVariant(collectionId, rollHash, signature);
            tokenIds = new uint256[](1);
            tokenIds[0] = tokenId;
            return (tokenIds, assignedVariant, 0);
            
        } else if (collectionType == CollectionType.Augment || collectionType == CollectionType.Accessory) {
            // For augment collections, this would need to call back to MintingFacet
            // This is a simplified implementation - in practice you'd need cross-facet communication
            revert("Use MintingFacet.mintRolled() for augment collections");
        } else {
            revert UnsupportedCollectionType(collectionId, "mintRolled not supported");
        }
    }
    
    // ==================== ROLLING IMPLEMENTATIONS ====================
    
    /**
     * @notice Roll main variant (FIXED: Add collectionId parameter to payment processing)
     */
    function _rollMainVariant(
        uint256 collectionId,
        uint256 tokenId,
        bytes32 previousRollHash,
        bytes calldata signature
    ) internal returns (
        bytes32 rollHash,
        string memory messageToSign,
        uint8 variant,
        uint256 expiresAt,
        uint8 rerollsRemaining
    ) {
        address user = LibMeta.msgSender();
        
        (, uint8 tier, bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (!exists) {
            revert CollectionNotFound(collectionId);
        }

        _validateSelfRollingToken(collectionId, tier, tokenId, user);
        
        if (!_getRollingPricing(collectionId, tier).isActive) {
            revert RollingNotActive();
        }
        
        _cleanupExpiredRolls(collectionId, tier);
        
        if (previousRollHash == bytes32(0)) {
            uint256 paidAmount = _processMainRollingPayment(user, collectionId, tier);
            (rollHash, messageToSign, variant, expiresAt, rerollsRemaining) = _performMainFirstRoll(user, collectionId, tokenId, tier);
            LibCollectionStorage.VariantRoll storage roll = _getVariantRoll(rollHash);
            roll.totalPaid = paidAmount;
        } else {
            uint256 paidAmount = _processMainRollingPayment(user, collectionId, tier);
            uint256 previousTotalPaid;
            (rollHash, messageToSign, variant, expiresAt, rerollsRemaining, previousTotalPaid) = _performMainReroll(user, previousRollHash, signature);
            LibCollectionStorage.VariantRoll storage roll = _getVariantRoll(rollHash);
            roll.totalPaid = previousTotalPaid + paidAmount;
        }
        
        return (rollHash, messageToSign, variant, expiresAt, rerollsRemaining);
    }
        
    function _rollAugmentVariant(
        uint256 collectionId,
        uint256 tokenId,
        uint256 specimenCollectionId,
        uint256 specimenTokenId,
        bytes32 previousRollHash,
        bytes calldata signature
    ) internal returns (
        bytes32 rollHash,
        string memory messageToSign,
        uint8 variant,
        uint256 expiresAt,
        uint8 rerollsRemaining
    ) {
        RollRequest memory request = RollRequest({
            collectionId: collectionId,
            tokenId: tokenId,
            specimenCollectionId: specimenCollectionId,
            specimenTokenId: specimenTokenId,
            previousRollHash: previousRollHash,
            signature: signature
        });

        address user = LibMeta.msgSender();
        
        (, uint8 tier, bool exists) = LibCollectionStorage.getCollectionInfo(request.collectionId);
        if (!exists) {
            revert CollectionNotFound(request.collectionId);
        }

        _validateCouponToken(request.specimenCollectionId, tier, request.specimenTokenId, user);
        _validateTokenState(request.collectionId, request.tokenId, tier);
        
        if (!_getRollingPricing(request.specimenCollectionId, tier).isActive) {
            revert RollingNotActive();
        }

        if (request.previousRollHash == bytes32(0)) {
            LibCollectionStorage.CouponConfiguration storage specimenConfig = _getCouponConfig();
            uint256 activeCount = _countActiveRolls(request.specimenCollectionId, request.specimenTokenId);
            
            if (activeCount >= specimenConfig.maxRollsPerCoupon) {
                revert MaxActiveRollsExceeded(activeCount, specimenConfig.maxRollsPerCoupon);
            }
        }
        
        _cleanupExpiredRolls(request.collectionId, tier);
        
        if (request.previousRollHash == bytes32(0)) {
            uint256 paidAmount = _processRollingPayment(request.specimenCollectionId, request.specimenTokenId, user, tier);
            (rollHash, messageToSign, variant, expiresAt, rerollsRemaining) = _performAugmentFirstRoll(user, request.collectionId, request.tokenId, request.specimenCollectionId, request.specimenTokenId);
            LibCollectionStorage.VariantRoll storage roll = _getVariantRoll(rollHash);
            roll.totalPaid = paidAmount;
        } else {
            uint256 paidAmount = _processRollingPayment(request.specimenCollectionId, request.specimenTokenId, user, tier);
            uint256 previousTotalPaid;
            (rollHash, messageToSign, variant, expiresAt, rerollsRemaining, previousTotalPaid) = _performAugmentReroll(user, request.previousRollHash, request.signature);
            LibCollectionStorage.VariantRoll storage roll = _getVariantRoll(rollHash);
            roll.totalPaid = previousTotalPaid + paidAmount;
        }
        
        return (rollHash, messageToSign, variant, expiresAt, rerollsRemaining);
    }
    
    function _assignVariant(
        AssignRequest memory request
    ) internal returns (uint256 tokenId, uint8 variant) {
        address user = LibMeta.msgSender();
        
        LibCollectionStorage.VariantRoll storage roll = _getVariantRoll(request.rollHash);
        
        if (!roll.exists) {
            revert RollNotFound();
        }
        if (roll.user != user) {
            revert InvalidAssignRequest();
        }
        if (block.timestamp > roll.expiresAt) {
            revert RollExpired();
        }
        if (_isRollConsumed(request.rollHash)) {
            revert RollAlreadyAssigned();
        }

        if (!_getAssignmentPricing(request.collectionId, roll.tier).isActive) {
            revert AssignmentNotActive();
        }

        _verifyRollSignature(user, request.rollHash, request.signature);
        
        _processAssignmentPayment(user, request.collectionId, roll.tier);
        
        _setRollConsumed(request.rollHash, true);
        
        tokenId = roll.couponTokenId;
        variant = roll.variant;
        
        _releaseTempReservation(roll.issueId, roll.tier, roll.variant, request.rollHash);
        
        (address targetCollection,, bool exists) = LibCollectionStorage.getCollectionInfo(request.collectionId);
        if (!exists || targetCollection == address(0)) {
            revert TargetCollectionError();
        }
        
        try ISpecimenCollection(targetCollection).assignVariant(
            roll.issueId,
            roll.tier,
            tokenId,
            variant
        ) returns (uint8 assignedVariant) {
            if (assignedVariant != variant) {
                revert InvalidAssignRequest();
            }
            
            IRepositoryFacet(address(this)).updateVariantCounters(
                request.collectionId,
                roll.tier,
                tokenId,
                variant
            );
            
        } catch {
            revert TargetCollectionError();
        }
        
        _storeMintedTokenInfo(request.rollHash, tokenId, variant, user, roll.couponCollectionId, roll.couponTokenId);
        
        _clearVariantRoll(request.rollHash);
        _setTokenRollHash(roll.couponCollectionId, roll.tier, tokenId, bytes32(0));

        _removeRollFromTracking(roll.couponCollectionId, roll.couponTokenId, request.rollHash);
        
        emit VariantAssigned(user, request.rollHash, tokenId, variant, targetCollection);
        
        return (tokenId, variant);
    }

    // ==================== ROLLING CORE FUNCTIONS ====================
    
    function _performMainFirstRoll(
        address user,
        uint256 collectionId,
        uint256 tokenId,
        uint8 tier
    ) internal returns (
        bytes32 rollHash,
        string memory messageToSign,
        uint8 variant,
        uint256 expiresAt,
        uint8 rerollsRemaining
    ) {
        // Create a context to reduce stack depth
        RollContext memory ctx;
        ctx.user = user;
        ctx.currentNonce = LibCollectionStorage.getCurrentNonce(user);
        ctx.variant = _selectVariantForRoll(collectionId, tier, user, tokenId);
        ctx.rollHash = _generateRollHash(user, collectionId, tokenId, tier);
        ctx.expiresAt = _calculateExpirationTime();
        ctx.issueId = _getIssueIdForRoll(collectionId);
        
        LibCollectionStorage.RollingConfiguration storage config = _getRollingConfig();
        ctx.rerollsRemaining = config.maxRerollsPerUser;
        
        _storeMainRollData(ctx.rollHash, ctx.user, ctx.variant, ctx.expiresAt, collectionId, tier, tokenId, ctx.currentNonce);
        _createTempReservation(ctx.issueId, tier, ctx.variant, ctx.rollHash, ctx.expiresAt);
        
        ctx.messageToSign = string(abi.encodePacked(
            "Apply variant roll: ",
            Strings.toHexString(uint256(ctx.rollHash)),
            " with nonce: ",
            Strings.toString(ctx.currentNonce)
        ));
        
        emit VariantRolled(ctx.user, ctx.rollHash, tokenId, ctx.messageToSign, collectionId, ctx.variant, ctx.expiresAt, 0);
        
        return (ctx.rollHash, ctx.messageToSign, ctx.variant, ctx.expiresAt, ctx.rerollsRemaining);
    }
    
    function _performAugmentFirstRoll(
        address user,
        uint256 collectionId,
        uint256 tokenId,
        uint256 specimenCollectionId,
        uint256 specimenTokenId
    ) internal returns (
        bytes32 rollHash,
        string memory messageToSign,
        uint8 variant,
        uint256 expiresAt,
        uint8 rerollsRemaining
    ) {
        (, uint8 tier, bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (!exists) {
            revert CollectionNotFound(collectionId);
        }

        // Create a context to reduce stack depth
        RollContext memory ctx;
        ctx.user = user;
        ctx.currentNonce = LibCollectionStorage.getCurrentNonce(user);
        ctx.variant = _selectVariantForRoll(collectionId, tier, user, tokenId);
        ctx.rollHash = _generateRollHash(user, collectionId, tokenId, tier);
        ctx.expiresAt = _calculateExpirationTime();
        ctx.issueId = _getIssueIdForRoll(collectionId);
        
        LibCollectionStorage.RollingConfiguration storage config = _getRollingConfig();
        ctx.rerollsRemaining = config.maxRerollsPerUser;
        
        _storeAugmentRollData(ctx.rollHash, ctx.user, ctx.variant, ctx.expiresAt, collectionId, tier, tokenId, specimenCollectionId, specimenTokenId, ctx.currentNonce);
        _createTempReservation(ctx.issueId, tier, ctx.variant, ctx.rollHash, ctx.expiresAt);
        
        ctx.messageToSign = string(abi.encodePacked(
            "Apply variant roll: ",
            Strings.toHexString(uint256(ctx.rollHash)),
            " with nonce: ",
            Strings.toString(ctx.currentNonce)
        ));

        _addRollToTracking(specimenCollectionId, specimenTokenId, ctx.rollHash);
        
        emit VariantRolled(ctx.user, ctx.rollHash, tokenId, ctx.messageToSign, collectionId, ctx.variant, ctx.expiresAt, 0);
        
        return (ctx.rollHash, ctx.messageToSign, ctx.variant, ctx.expiresAt, ctx.rerollsRemaining);
    }
    
    function _performMainReroll(
        address user,
        bytes32 previousRollHash,
        bytes memory signature
    ) internal returns (
        bytes32 rollHash,
        string memory messageToSign,
        uint8 variant,
        uint256 expiresAt,
        uint8 rerollsRemaining,
        uint256 previousTotalPaid
    ) {
        LibCollectionStorage.VariantRoll storage previousRoll = _getVariantRoll(previousRollHash);
        
        if (!previousRoll.exists) revert RollNotFound();
        if (previousRoll.user != user) revert InvalidRerollAttempt();
        if (block.timestamp > previousRoll.expiresAt) revert RollExpired();
        
        LibCollectionStorage.RollingConfiguration storage config = _getRollingConfig();
        if (previousRoll.rerollsUsed >= config.maxRerollsPerUser) {
            revert MaxRerollsExceeded();
        }

        if (_isRollConsumed(previousRollHash)) {
            revert RollAlreadyAssigned();
        }
        
        _verifyRollSignature(user, previousRollHash, signature);
        
        LibCollectionStorage.VariantRoll memory savedRoll = previousRoll;
        uint256 updatedNonce = LibCollectionStorage.getCurrentNonce(user);
        
        variant = _selectVariantForRoll(savedRoll.couponCollectionId, savedRoll.tier, user, savedRoll.couponTokenId);
        
        rollHash = keccak256(abi.encodePacked(
            user,
            variant,
            block.timestamp,
            updatedNonce,
            savedRoll.couponCollectionId,
            savedRoll.couponTokenId
        ));
        
        expiresAt = block.timestamp + config.reservationTimeSeconds;
        
        _createTempReservation(savedRoll.issueId, savedRoll.tier, variant, rollHash, expiresAt);
        _releaseTempReservation(savedRoll.issueId, savedRoll.tier, savedRoll.variant, previousRollHash);
        _clearVariantRoll(previousRollHash);
        
        uint8 newRerollsUsed = savedRoll.rerollsUsed + 1;
        rerollsRemaining = config.maxRerollsPerUser - newRerollsUsed;
        
        LibCollectionStorage.VariantRoll storage newVariantRoll = _getVariantRoll(rollHash);
        newVariantRoll.user = user;
        newVariantRoll.variant = variant;
        newVariantRoll.expiresAt = expiresAt;
        newVariantRoll.rerollsUsed = newRerollsUsed;
        newVariantRoll.exists = true;
        newVariantRoll.issueId = savedRoll.issueId;
        newVariantRoll.tier = savedRoll.tier;
        newVariantRoll.couponCollectionId = savedRoll.couponCollectionId;
        newVariantRoll.couponTokenId = savedRoll.couponTokenId;
        newVariantRoll.totalPaid = savedRoll.totalPaid;
        newVariantRoll.nonce = updatedNonce;
        
        messageToSign = string(abi.encodePacked(
            "Apply variant roll: ",
            Strings.toHexString(uint256(rollHash)),
            " with nonce: ",
            Strings.toString(updatedNonce)
        ));
        
        previousTotalPaid = savedRoll.totalPaid;
        
        emit VariantRerollChanged(user, rollHash, messageToSign, previousRollHash, variant, 0);
        
        return (rollHash, messageToSign, variant, expiresAt, rerollsRemaining, previousTotalPaid);
    }
    
    function _performAugmentReroll(
        address user,
        bytes32 previousRollHash,
        bytes memory signature
    ) internal returns (
        bytes32 rollHash,
        string memory messageToSign,
        uint8 variant,
        uint256 expiresAt,
        uint8 rerollsRemaining,
        uint256 previousTotalPaid
    ) {
        LibCollectionStorage.VariantRoll storage previousRoll = _getVariantRoll(previousRollHash);
        
        if (!previousRoll.exists) revert RollNotFound();
        if (previousRoll.user != user) revert InvalidRerollAttempt();
        if (block.timestamp > previousRoll.expiresAt) revert RollExpired();
        
        LibCollectionStorage.RollingConfiguration storage config = _getRollingConfig();
        if (previousRoll.rerollsUsed >= config.maxRerollsPerUser) {
            revert MaxRerollsExceeded();
        }

        if (_isRollConsumed(previousRollHash)) {
            revert RollAlreadyAssigned();
        }
        
        _verifyRollSignature(user, previousRollHash, signature);
        
        LibCollectionStorage.VariantRoll memory savedRoll = previousRoll;
        uint256 updatedNonce = LibCollectionStorage.getCurrentNonce(user);
        
        variant = _selectVariantForRoll(savedRoll.couponCollectionId, savedRoll.tier, user, savedRoll.couponTokenId);
        
        rollHash = keccak256(abi.encodePacked(
            user,
            variant,
            block.timestamp,
            updatedNonce,
            savedRoll.couponCollectionId,
            savedRoll.couponTokenId
        ));
        
        expiresAt = block.timestamp + config.reservationTimeSeconds;
        
        _createTempReservation(savedRoll.issueId, savedRoll.tier, variant, rollHash, expiresAt);
        _releaseTempReservation(savedRoll.issueId, savedRoll.tier, savedRoll.variant, previousRollHash);
        _clearVariantRoll(previousRollHash);
        
        uint8 newRerollsUsed = savedRoll.rerollsUsed + 1;
        rerollsRemaining = config.maxRerollsPerUser - newRerollsUsed;
        
        LibCollectionStorage.VariantRoll storage newVariantRoll = _getVariantRoll(rollHash);
        newVariantRoll.user = user;
        newVariantRoll.variant = variant;
        newVariantRoll.expiresAt = expiresAt;
        newVariantRoll.rerollsUsed = newRerollsUsed;
        newVariantRoll.exists = true;
        newVariantRoll.issueId = savedRoll.issueId;
        newVariantRoll.tier = savedRoll.tier;
        newVariantRoll.couponCollectionId = savedRoll.couponCollectionId;
        newVariantRoll.couponTokenId = savedRoll.couponTokenId;
        newVariantRoll.totalPaid = savedRoll.totalPaid;
        newVariantRoll.nonce = updatedNonce;
        
        messageToSign = string(abi.encodePacked(
            "Apply variant roll: ",
            Strings.toHexString(uint256(rollHash)),
            " with nonce: ",
            Strings.toString(updatedNonce)
        ));
        
        previousTotalPaid = savedRoll.totalPaid;

        _removeRollFromTracking(savedRoll.couponCollectionId, savedRoll.couponTokenId, previousRollHash);
        _addRollToTracking(savedRoll.couponCollectionId, savedRoll.couponTokenId, rollHash);
        
        emit VariantRerollChanged(user, rollHash, messageToSign, previousRollHash, variant, 0);
        
        return (rollHash, messageToSign, variant, expiresAt, rerollsRemaining, previousTotalPaid);
    }
    
    // ==================== PAYMENT PROCESSING ====================
    
    /**
     * @notice Process rolling payment for Main collections (FIXED: Use actual collectionId)
     * @dev FIXED: Pass collectionId parameter instead of hardcoded value
     */
    function _processMainRollingPayment(address user, uint256 collectionId, uint8 tier) internal returns (uint256 paidAmount) {
        // FIXED: Use passed collectionId instead of hardcoded 1
        LibCollectionStorage.RollingPricing storage pricing = _getRollingPricing(collectionId, tier);
        
        if (!pricing.isActive) {
            return 0;
        }
        
        uint256 requiredPayment = pricing.onSale ? pricing.discounted : pricing.regular;
        
        if (requiredPayment == 0) {
            if (msg.value > 0) {
                Address.sendValue(payable(user), msg.value);
            }
            return 0;
        }
        
        if (pricing.chargeNative) {
            if (msg.value < requiredPayment) {
                revert InsufficientPayment(requiredPayment, msg.value);
            }
            
            Address.sendValue(payable(pricing.beneficiary), requiredPayment);
            
            if (msg.value > requiredPayment) {
                Address.sendValue(payable(user), msg.value - requiredPayment);
            }
        } else {
            pricing.currency.safeTransferFrom(user, pricing.beneficiary, requiredPayment);
        }
        
        bool usedExchange = pricing.useExchangeRate && pricing.chargeNative;
        emit PaymentProcessed(user, requiredPayment, pricing.chargeNative, usedExchange, [uint80(0), uint80(0)], pricing.beneficiary);
        
        return requiredPayment;
    }
        
    function _processRollingPayment(
        uint256 specimenCollectionId,
        uint256 specimenTokenId,
        address user,
        uint8 tier
    ) internal returns (uint256 paidAmount) {
        uint256 combinedId = PodsUtils.combineIds(specimenCollectionId, specimenTokenId);
        LibCollectionStorage.RollCoupon storage specimen = _getRollCoupon(combinedId);
        LibCollectionStorage.CouponConfiguration storage specimenConfig = _getCouponConfig();
        
        if (!specimen.active) {
            specimen.collectionId = specimenCollectionId;
            specimen.tokenId = specimenTokenId;
            specimen.active = true;
        }
        
        (uint256 requiredPayment, IERC20 currency) = _calculateRollingPayment(specimenCollectionId, specimenTokenId, tier);
        
        paidAmount = 0;
        
        if (requiredPayment > 0) {
            LibCollectionStorage.RollingPricing storage pricing = _getRollingPricing(specimenCollectionId, tier);
            currency.safeTransferFrom(user, pricing.beneficiary, requiredPayment);
            paidAmount = requiredPayment;
        } else {
            if (specimen.freeRollsUsed < specimenConfig.freeRollsPerCoupon) {
                specimen.freeRollsUsed++;
            }
        }
        
        if (msg.value > 0) {
            Address.sendValue(payable(user), msg.value);
        }
        
        if (specimenConfig.rateLimitingEnabled && specimen.lastRollTime > 0) {
            uint256 timeSinceLastRoll = block.timestamp - specimen.lastRollTime;
            if (timeSinceLastRoll < specimenConfig.cooldownBetweenRolls) {
                revert RateLimited(specimenConfig.cooldownBetweenRolls - timeSinceLastRoll);
            }
        }
        
        specimen.totalRollsEver++;
        specimen.usedRolls++;
        specimen.lastRollTime = block.timestamp;
        
        emit SpecimenUsed(specimenCollectionId, specimenTokenId, user, specimen.usedRolls);
        
        return paidAmount;
    }
    
    function _processAssignmentPayment(address user, uint256 collectionId, uint8 tier) internal returns (uint256 paidAmount) {
        (uint256 requiredPayment, IERC20 currency) = _calculateAssignmentPayment(user, collectionId, tier);
        
        if (requiredPayment == 0) {
            IWhitelist(address(this)).recordUsage(collectionId, tier, user, 1);
            
            if (msg.value > 0) {
                Address.sendValue(payable(user), msg.value);
            }
            return 0;
        }
        
        LibCollectionStorage.AssignmentPricing storage pricing = _getAssignmentPricing(collectionId, tier);
        
        currency.safeTransferFrom(user, pricing.beneficiary, requiredPayment);
        paidAmount = requiredPayment;
        
        if (msg.value > 0) {
            Address.sendValue(payable(user), msg.value);
        }
        
        emit AssignmentPaymentProcessed(user, paidAmount, false, pricing.beneficiary);
        
        return paidAmount;
    }
    
    // ==================== PAYMENT CALCULATIONS ====================
    
    function _calculateRollingPayment(
        uint256 specimenCollectionId,
        uint256 specimenTokenId,
        uint8 tier
    ) internal view returns (uint256 requiredPayment, IERC20 currency) {
        LibCollectionStorage.RollingPricing storage pricing = _getRollingPricing(specimenCollectionId, tier);
        currency = pricing.currency;
        
        bool onlyBasicLeft = _checkOnlyBasicVariantsRemaining(specimenCollectionId, tier);
        
        if (onlyBasicLeft) {
            return (0, currency);
        }
        
        uint256 combinedId = PodsUtils.combineIds(specimenCollectionId, specimenTokenId);
        LibCollectionStorage.RollCoupon storage specimen = _getRollCoupon(combinedId);
        LibCollectionStorage.CouponConfiguration storage specimenConfig = _getCouponConfig();
        
        if (specimen.freeRollsUsed < specimenConfig.freeRollsPerCoupon) {
            requiredPayment = 0;
        } else {
            uint256 basePrice = pricing.onSale ? pricing.discounted : pricing.regular;
            requiredPayment = basePrice * specimen.totalRollsEver;
        }
        
        return (requiredPayment, currency);
    }
    
    function _calculateAssignmentPayment(address, uint256 collectionId, uint8 tier) internal view returns (uint256 requiredPayment, IERC20 currency) {
        LibCollectionStorage.AssignmentPricing storage pricing = _getAssignmentPricing(collectionId, tier);
        currency = pricing.currency;

        if (!pricing.isActive || address(currency) == address(0) || _isAuthorized()) {
            requiredPayment = 0;
        } else {
            requiredPayment = pricing.onSale ? pricing.discounted : pricing.regular;
        }
        
        return (requiredPayment, currency);
    }
    
    // ==================== VALIDATION FUNCTIONS ====================
    
    /**
     * @notice Validate token access for rolling (FIXED: Main vs Augment collections)
     * @dev Main collections validate direct ownership, Augment collections use specimen validation
     */
    function _validateCouponToken(uint256 collectionId, uint8, uint256 tokenId, address user) internal view {
        // This function already correctly calls _validateAccess() which we enhanced
        (bool isValid,) = _validateAccess(collectionId, tokenId, user);
        if (!isValid) {
            revert SpecimenNotAccessible();
        }
    }

    function _validateSelfRollingToken(uint256 collectionId, uint8 tier, uint256 tokenId, address user) internal view {
        (address contractAddress,, bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (!exists || contractAddress == address(0)) {
            revert CollectionNotFound(collectionId);
        }
        
        // Verify token actually exists
        try IERC721(contractAddress).ownerOf(tokenId) returns (address tokenOwner) {
            if (tokenOwner == address(0)) {
                revert SpecimenNotAccessible(); // Token is burned
            }
        } catch {
            revert SpecimenNotAccessible(); // Token doesn't exist
        }
        
        if (!AccessHelper.hasTokenAccess(contractAddress, tokenId, user)) {
            revert SpecimenNotAccessible();
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        uint8 currentVariant = cs.itemsVariants[collectionId][tier][tokenId];
        
        // Self-rolling validation logic
        if (currentVariant == 0) {
            // Fresh token - always allowed to roll
            return;
        }
        
        if (cs.tokenRollingUnlocked[collectionId][tokenId]) {
            // Token explicitly unlocked for re-rolling
            return;
        }
        
        // Token has variant and not unlocked - cannot roll
        revert TokenAlreadyHasVariant(tokenId, currentVariant);
    }

    /**
     * @dev This validates tokens being used as coupons for augment minting
     */
    function _validateAccess(uint256 collectionId, uint256 tokenId, address user) internal view returns (bool isValid, string memory reason) {
    
        CollectionType collectionType = _getCollectionType(collectionId);
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();

        if (collectionType == CollectionType.Main) {
            // Main collection validation with self-rolling support
            (address contractAddress,, bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
            if (!exists) {
                return (false, "Collection not found");
            }
            
            if (!AccessHelper.hasTokenAccess(contractAddress, tokenId, user)) {
                return (false, "No token access");
            }
            
            (, uint8 tier,) = LibCollectionStorage.getCollectionInfo(collectionId);
            uint8 currentVariant = cs.itemsVariants[collectionId][tier][tokenId];
            
            // NEW: Check coupon configuration for self-rolling support
            LibCollectionStorage.CouponCollection storage coupon = cs.couponCollections[collectionId];
            
            if (coupon.allowSelfRolling) {
                // SELF-ROLLING MODE: variant 0 OK, variant > 0 needs unlock
                if (currentVariant == 0) {
                    return (true, "Fresh token can be self-rolled");
                }
                
                if (cs.tokenRollingUnlocked[collectionId][tokenId]) {
                    return (true, "Token unlocked for re-rolling");
                }
                
                return (false, "Token already has variant assigned and rolling not unlocked");
                
            } else {
                // COUPON MODE: requires variant > 0
                if (currentVariant == 0) {
                    return (false, "Main collection coupon must have assigned variant (variant > 0)");
                }
                
                // Check if coupon already used
                if (cs.collectionCouponUsed[collectionId][tokenId]) {
                    return (false, "Coupon already used for minting");
                }
                
                // Check existing augment assignment
                bytes32 existingAssignment = cs.specimenToAssignment[contractAddress][tokenId];
                if (existingAssignment != bytes32(0) && cs.augmentAssignments[existingAssignment].active) {
                    return (false, "Coupon already has active augment assignment");
                }
                
                return (true, "Main collection coupon valid");
            }
            
        } else {
            // Non-Main collections - EXISTING LOGIC UNCHANGED
            LibCollectionStorage.CouponCollection storage collection = cs.couponCollections[collectionId];
            
            if (!collection.active) {
                return (false, "Collection not active");
            }
            
            if (!AccessHelper.hasTokenAccess(collection.collectionAddress, tokenId, user)) {
                return (false, "No token access (ownership or staking required)");
            }

            (, uint8 tier,) = LibCollectionStorage.getCollectionInfo(collectionId);
            uint8 currentVariant = cs.itemsVariants[collectionId][tier][tokenId];
            
            bool tokenWasEverVarianted = cs.collectionItemsVarianted[collectionId][tokenId] != 0;
            bool wasReset = cs.tokenSelfResetUsed[collectionId][tokenId];
            bool rollingUnlocked = cs.tokenRollingUnlocked[collectionId][tokenId];
            
            if (wasReset && !rollingUnlocked) {
                return (false, "Token was reset without unlocking rolling capability");
            }
            
            if (currentVariant != 0 && !rollingUnlocked) {
                return (false, "Token already has variant assigned and rolling not unlocked");
            }
            
            if (tokenWasEverVarianted && currentVariant == 0 && !rollingUnlocked && !wasReset) {
                return (false, "Token was previously varianted and rolling not unlocked");
            }
            
            uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
            LibCollectionStorage.RollCoupon storage coupon = cs.rollCouponsByTokenId[combinedId];
            LibCollectionStorage.CouponConfiguration storage config = cs.couponConfiguration;
            
            if (config.rateLimitingEnabled && coupon.active && coupon.lastRollTime > 0) {
                if (block.timestamp < coupon.lastRollTime + config.cooldownBetweenRolls) {
                    return (false, "Rate limited");
                }
            }
            
            return (true, "Access granted");
        }
    }

    function _validateTokenState(uint256 collectionId, uint256 tokenId, uint8 tier) internal view {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        (bool hasVariant, uint8 variant) = _checkTokenHasVariant(collectionId, tokenId, tier);
        if (hasVariant) {
            bool rollingUnlocked = cs.tokenRollingUnlocked[collectionId][tokenId];
            if (!rollingUnlocked) {
                revert TokenAlreadyHasVariant(tokenId, variant);
            }
        }
    }

    function _checkTokenHasVariant(uint256 collectionId, uint256 tokenId, uint8 tier) internal view returns (bool hasVariant, uint8 variant) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        variant = cs.itemsVariants[collectionId][tier][tokenId];
        
        if (variant > 0) {
            return (true, variant);
        }
        
        return (false, 0);
    }
    
    // ==================== UTILITY FUNCTIONS ====================
    
    function _selectVariantForRoll(
        uint256 collectionId,
        uint8 tier,
        address user,
        uint256 tokenId
    ) internal view returns (uint8) {
        uint256 issueId = _getIssueIdForRoll(collectionId);
        uint256 currentNonce = LibCollectionStorage.getCurrentNonce(user);
        
        uint256 seed = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            user,
            currentNonce,
            collectionId,
            tokenId
        )));
        
        uint8 selectedVariant = IRepositoryFacet(address(this)).selectVariant(issueId, tier, seed);
        
        if (selectedVariant == 0) {
            return 1;
        }
        
        return selectedVariant;
    }

    function _getIssueIdForRoll(uint256 collectionId) internal view returns (uint256) {
        if (LibCollectionStorage.isInternalCollection(collectionId)) {
            return LibCollectionStorage.collectionStorage().collections[collectionId].defaultIssueId;
        }
        return 1;
    }

    function _calculateExpirationTime() internal view returns (uint256) {
        return block.timestamp + _getRollingConfig().reservationTimeSeconds;
    }

    function _getCouponCollection(uint256 collectionId) internal view returns (LibCollectionStorage.CouponCollection storage) {
        return LibCollectionStorage.collectionStorage().couponCollections[collectionId];
    }

    function _generateRollHash(
        address user,
        uint256 collectionId,
        uint256 tokenId,
        uint8 tier
    ) internal view returns (bytes32) {
        uint256 currentNonce = LibCollectionStorage.getCurrentNonce(user);
        
        return keccak256(abi.encodePacked(
            user,
            block.timestamp,
            currentNonce,
            collectionId,
            tokenId,
            tier
        ));
    }

    function _storeMainRollData(
        bytes32 rollHash,
        address user,
        uint8 variant,
        uint256 expiresAt,
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        uint256 nonce
    ) internal {
        uint256 issueId = _getIssueIdForRoll(collectionId);
        
        LibCollectionStorage.VariantRoll storage variantRoll = _getVariantRoll(rollHash);
        variantRoll.user = user;
        variantRoll.variant = variant;
        variantRoll.expiresAt = expiresAt;
        variantRoll.rerollsUsed = 0;
        variantRoll.exists = true;
        variantRoll.issueId = issueId;
        variantRoll.tier = tier;
        variantRoll.couponCollectionId = collectionId; // Self-rolling for Main
        variantRoll.couponTokenId = tokenId;
        variantRoll.totalPaid = 0;
        variantRoll.nonce = nonce;
    }

    function _storeAugmentRollData(
        bytes32 rollHash,
        address user,
        uint8 variant,
        uint256 expiresAt,
        uint256 collectionId,
        uint8 tier,
        uint256,
        uint256 specimenCollectionId,
        uint256 specimenTokenId,
        uint256 nonce
    ) internal {
        uint256 issueId = _getIssueIdForRoll(collectionId);
        
        LibCollectionStorage.VariantRoll storage variantRoll = _getVariantRoll(rollHash);
        variantRoll.user = user;
        variantRoll.variant = variant;
        variantRoll.expiresAt = expiresAt;
        variantRoll.rerollsUsed = 0;
        variantRoll.exists = true;
        variantRoll.issueId = issueId;
        variantRoll.tier = tier;
        variantRoll.couponCollectionId = specimenCollectionId;
        variantRoll.couponTokenId = specimenTokenId;
        variantRoll.totalPaid = 0;
        variantRoll.nonce = nonce;
    }

    function _createTempReservation(uint256 issueId, uint8 tier, uint8 variant, bytes32 rollHash, uint256 expiresAt) internal {
        LibCollectionStorage.TempReservation[] storage reservations = _getTempReservations(issueId, tier, variant);
        
        LibCollectionStorage.TempReservation memory newReservation;
        newReservation.rollHash = rollHash;
        newReservation.expiresAt = expiresAt;
        newReservation.active = true;
        
        reservations.push(newReservation);
        _setRollToReservationIndex(rollHash, reservations.length - 1);
    }

    function _releaseTempReservation(
        uint256 issueId, 
        uint8 tier, 
        uint8 variant, 
        bytes32 rollHash
    ) internal {
        uint256 index = _getRollToReservationIndex(rollHash);
        LibCollectionStorage.TempReservation[] storage reservations = _getTempReservations(issueId, tier, variant);
        
        if (index < reservations.length && reservations[index].rollHash == rollHash) {
            reservations[index].active = false;
        }
        
        _deleteRollToReservationIndex(rollHash);
    }

    function _verifyRollSignature(address user, bytes32 rollHash, bytes memory signature) internal {
        LibCollectionStorage.VariantRoll storage roll = _getVariantRoll(rollHash);
        uint256 savedNonce = roll.nonce;

        LibCollectionStorage.getAndIncrementNonce(user);
        
        string memory humanMessage = string(abi.encodePacked(
            "Apply variant roll: ",
            Strings.toHexString(uint256(rollHash)),
            " with nonce: ",
            Strings.toString(savedNonce)
        ));
        
        bytes32 messageHash = _createEthSignedMessageHash(humanMessage);
        address recovered = messageHash.recover(signature);
        
        if (recovered == user) {
            return;
        }
        
        bytes32 rawHash = keccak256(bytes(humanMessage));
        recovered = rawHash.recover(signature);
        
        if (recovered == user) {
            return;
        }
        
        revert InvalidSignature();
    }

    function _createEthSignedMessageHash(string memory message) internal pure returns (bytes32) {
        bytes memory messageBytes = bytes(message);
        bytes memory prefix = "\x19Ethereum Signed Message:\n";
        bytes memory lengthBytes = bytes(Strings.toString(messageBytes.length));
        
        return keccak256(abi.encodePacked(prefix, lengthBytes, messageBytes));
    }

    function _storeMintedTokenInfo(
        bytes32 rollHash,
        uint256 tokenId,
        uint8 variant,
        address user,
        uint256 specimenCollectionId,
        uint256 specimenTokenId
    ) internal {
        LibCollectionStorage.MintedToken storage mintedToken = _getMintedToken(rollHash);
        mintedToken.tokenId = tokenId;
        mintedToken.variant = variant;
        mintedToken.recipient = user;
        mintedToken.mintTime = block.timestamp;
        mintedToken.couponCollectionId = specimenCollectionId;
        mintedToken.couponTokenId = specimenTokenId;
    }
    
    function _clearVariantRoll(bytes32 rollHash) internal {
        delete LibCollectionStorage.collectionStorage().variantRollsByHash[rollHash];
    }

    function _countActiveRolls(uint256 specimenCollectionId, uint256 tokenId) internal view returns (uint256) {
        uint256 combinedId = PodsUtils.combineIds(specimenCollectionId, tokenId);
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        bytes32[] storage activeRolls = cs.couponActiveRolls[combinedId];
        
        uint256 activeCount = 0;
        for (uint256 i = 0; i < activeRolls.length; i++) {
            LibCollectionStorage.VariantRoll storage roll = _getVariantRoll(activeRolls[i]);
            if (roll.exists && 
                block.timestamp <= roll.expiresAt && 
                !_isRollConsumed(activeRolls[i])) {
                activeCount++;
            }
        }
        return activeCount;
    }

    function _addRollToTracking(uint256 specimenCollectionId, uint256 tokenId, bytes32 rollHash) internal {
        uint256 combinedId = PodsUtils.combineIds(specimenCollectionId, tokenId);
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        cs.couponActiveRolls[combinedId].push(rollHash);
    }

    function _removeRollFromTracking(uint256 specimenCollectionId, uint256 tokenId, bytes32 rollHash) internal {
        uint256 combinedId = PodsUtils.combineIds(specimenCollectionId, tokenId);
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        bytes32[] storage activeRolls = cs.couponActiveRolls[combinedId];
        
        for (uint256 i = 0; i < activeRolls.length; i++) {
            if (activeRolls[i] == rollHash) {
                activeRolls[i] = activeRolls[activeRolls.length - 1];
                activeRolls.pop();
                break;
            }
        }
    }

    /**
     * @notice Clean up expired rolls for Main collections (FIXED: Add missing cleanup)
     * @dev Identical to augment cleanup but for Main collection reservations
     */
    function _cleanupExpiredRolls(uint256 collectionId, uint8 tier) internal {
        // Only cleanup every 5 blocks to reduce gas costs
        if (block.number % 5 == 0) {
            // Rotate through variants to spread cleanup load
            uint8 variant = uint8((block.number % 4) + 1);
            _cleanupVariantReservations(collectionId, tier, variant, 3);
        }
    }

    function _cleanupVariantReservations(uint256 collectionId, uint8 tier, uint8 variant, uint256 maxCleanups) internal {
        LibCollectionStorage.TempReservation[] storage reservations = _getTempReservations(collectionId, tier, variant);
        uint256 cleaned = 0;
        uint256 reservationsLength = reservations.length;
        
        for (uint256 i = 0; i < reservationsLength && cleaned < maxCleanups; i++) {
            if (i >= reservations.length) break;
            
            LibCollectionStorage.TempReservation storage reservation = reservations[i];
            
            if (reservation.active && block.timestamp > reservation.expiresAt) {
                bytes32 rollHash = reservation.rollHash;
                
                LibCollectionStorage.VariantRoll storage roll = _getVariantRoll(rollHash);
                
                if (!roll.exists || block.timestamp > roll.expiresAt + 300) {
                    reservation.active = false;
                    
                    if (!_isRollConsumed(rollHash)) {
                        _resetSpecimenOnExpiry(rollHash);
                    }
                    
                    emit VariantRollExpired(rollHash, variant);
                    _deleteRollToReservationIndex(rollHash);
                    cleaned++;
                }
            }
        }
    }

    function _resetSpecimenOnExpiry(bytes32 rollHash) internal {
        LibCollectionStorage.VariantRoll storage roll = _getVariantRoll(rollHash);
        
        if (roll.exists && roll.couponCollectionId > 0) {
            _removeRollFromTracking(roll.couponCollectionId, roll.couponTokenId, rollHash);
            _clearVariantRoll(rollHash);
            
            emit SpecimenResetOnExpiry(roll.couponCollectionId, roll.couponTokenId, rollHash);
        }
    }

    function _checkOnlyBasicVariantsRemaining(uint256 collectionId, uint8 tier) internal view returns (bool) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        ItemTier storage itemTier = cs.itemTiers[collectionId][tier];
        uint256 maxVariants = itemTier.variantsCount;
        
        if (maxVariants <= 1) {
            return true;
        }
        
        for (uint8 variant = 2; variant <= maxVariants; variant++) {
            if (_getAvailableVariantCount(collectionId, tier, variant) > 0) {
                return false;
            }
        }
        
        return true;
    }

    function _getAvailableVariantCount(uint256 collectionId, uint8 tier, uint8 variant) internal view returns (uint256 available) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        TierVariant storage tierVariant = cs.tierVariants[collectionId][tier][variant];
        if (tierVariant.maxSupply == 0) {
            return 0;
        }
        
        uint256 permanentCount = cs.hitVariantsCounters[collectionId][tier][variant];
        uint256 tempCount = _countActiveTempReservations(collectionId, tier, variant);
        
        uint256 totalUsed = permanentCount + tempCount;
        if (totalUsed >= tierVariant.maxSupply) {
            return 0;
        }
        
        return tierVariant.maxSupply - totalUsed;
    }
    
    function _countActiveTempReservations(uint256 collectionId, uint8 tier, uint8 variant) internal view returns (uint256 count) {
        LibCollectionStorage.TempReservation[] storage reservations = _getTempReservations(collectionId, tier, variant);
        uint256 reservationsLength = reservations.length;
        
        for (uint256 i = 0; i < reservationsLength; i++) {
            if (i >= reservations.length) break;
            
            if (reservations[i].active && block.timestamp <= reservations[i].expiresAt) {
                count++;
            }
        }
        
        return count;
    }

    function _getCollectionType(uint256 collectionId) internal view returns (CollectionType) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (LibCollectionStorage.isInternalCollection(collectionId)) {
            return cs.collections[collectionId].collectionType;
        } else if (LibCollectionStorage.isExternalCollection(collectionId)) {
            return cs.externalCollections[collectionId].collectionType;
        } else {
            revert CollectionNotFound(collectionId);
        }
    }
    
    // ==================== STORAGE ACCESS ====================
    
    function _getRollingPricing(uint256 collectionId, uint8 tier) internal view returns (LibCollectionStorage.RollingPricing storage) {
        return LibCollectionStorage.collectionStorage().rollingPricingByTier[collectionId][tier];
    }
    
    function _getAssignmentPricing(uint256 collectionId, uint8 tier) internal view returns (LibCollectionStorage.AssignmentPricing storage) {
        return LibCollectionStorage.collectionStorage().assignmentPricingByTier[collectionId][tier];
    }
    
    function _getCouponConfig() internal view returns (LibCollectionStorage.CouponConfiguration storage) {
        return LibCollectionStorage.collectionStorage().couponConfiguration;
    }
    
    function _getRollingConfig() internal view returns (LibCollectionStorage.RollingConfiguration storage) {
        return LibCollectionStorage.collectionStorage().rollingConfiguration;
    }
    
    function _getSpecimenCollection(uint256 collectionId) internal view returns (LibCollectionStorage.CouponCollection storage) {
        return LibCollectionStorage.collectionStorage().couponCollections[collectionId];
    }
    
    function _getRollCoupon(uint256 combinedId) internal view returns (LibCollectionStorage.RollCoupon storage) {
        return LibCollectionStorage.collectionStorage().rollCouponsByTokenId[combinedId];
    }
    
    function _getVariantRoll(bytes32 rollHash) internal view returns (LibCollectionStorage.VariantRoll storage) {
        return LibCollectionStorage.collectionStorage().variantRollsByHash[rollHash];
    }
    
    function _setTokenRollHash(uint256 collectionId, uint8 tier, uint256 tokenId, bytes32 rollHash) internal {
        LibCollectionStorage.collectionStorage().tokenToRollHash[collectionId][tier][tokenId] = rollHash;
    }
    
    function _getTokenRollHash(uint256 collectionId, uint8 tier, uint256 tokenId) internal view returns (bytes32) {
        return LibCollectionStorage.collectionStorage().tokenToRollHash[collectionId][tier][tokenId];
    }
    
    function _isRollConsumed(bytes32 rollHash) internal view returns (bool) {
        return LibCollectionStorage.collectionStorage().assignedRollsByHash[rollHash];
    }
    
    function _setRollConsumed(bytes32 rollHash, bool assigned) internal {
        LibCollectionStorage.collectionStorage().assignedRollsByHash[rollHash] = assigned;
    }
    
    function _getMintedToken(bytes32 rollHash) internal view returns (LibCollectionStorage.MintedToken storage) {
        return LibCollectionStorage.collectionStorage().mintedTokensByHash[rollHash];
    }
    
    function _getTempReservations(uint256 collectionId, uint8 tier, uint8 variant) internal view returns (LibCollectionStorage.TempReservation[] storage) {
        return LibCollectionStorage.collectionStorage().tempReservationsByVariant[collectionId][tier][variant];
    }
    
    function _getRollToReservationIndex(bytes32 rollHash) internal view returns (uint256) {
        return LibCollectionStorage.collectionStorage().rollToReservationIndexByHash[rollHash];
    }
    
    function _setRollToReservationIndex(bytes32 rollHash, uint256 index) internal {
        LibCollectionStorage.collectionStorage().rollToReservationIndexByHash[rollHash] = index;
    }
    
    function _deleteRollToReservationIndex(bytes32 rollHash) internal {
        delete LibCollectionStorage.collectionStorage().rollToReservationIndexByHash[rollHash];
    }
 
    // ==================== VIEW FUNCTIONS ====================
    
    function supportsRolling(uint256 collectionId) public view validCollection(collectionId) returns (bool supported) {
        LibCollectionStorage.RollingPricing storage rollingPricing = _getRollingPricing(collectionId, 1);
        return rollingPricing.isActive && address(rollingPricing.currency) != address(0);
    }

    function getMintingOptions(uint256 collectionId) external view validCollection(collectionId) returns (
        bool traditionalMinting,
        bool rollingMinting
    ) {
        CollectionType collectionType = _getCollectionType(collectionId);
        
        if (collectionType == CollectionType.Main) {
            LibCollectionStorage.MintingConfig storage config = LibCollectionStorage.collectionStorage().mintingConfigs[collectionId][1];
            traditionalMinting = config.isActive;
            rollingMinting = config.allowRolling && supportsRolling(collectionId);
        } else if (collectionType == CollectionType.Augment || collectionType == CollectionType.Accessory) {
            traditionalMinting = true;
            rollingMinting = supportsRolling(collectionId);
        } else {
            traditionalMinting = false;
            rollingMinting = false;
        }
        
        return (traditionalMinting, rollingMinting);
    }
    
    function getAvailableVariants(uint256 collectionId, uint8 tier, uint8 variant) external view returns (uint256 available) {
        return _getAvailableVariantCount(collectionId, tier, variant);
    }

    function getVariantAvailability(
        uint256 collectionId, 
        uint8 tier, 
        uint8 variant
    ) external view returns (
        uint256 maxSupply,
        uint256 assignedTokens,
        uint256 activeReservations,
        uint256 availableForRolling
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        TierVariant storage tierVariant = cs.tierVariants[collectionId][tier][variant];
        maxSupply = tierVariant.maxSupply;
        
        assignedTokens = cs.hitVariantsCounters[collectionId][tier][variant];
        
        activeReservations = _countActiveTempReservations(collectionId, tier, variant);
        
        uint256 totalUsed = assignedTokens + activeReservations;
        availableForRolling = (totalUsed >= maxSupply) ? 0 : (maxSupply - totalUsed);
        
        return (maxSupply, assignedTokens, activeReservations, availableForRolling);
    }

    function getTierVariantStatus(
        uint256 collectionId,
        uint8 tier
    ) external view returns (
        uint8[] memory variants,
        uint256[] memory maxSupplies,
        uint256[] memory assignedCounts,
        uint256[] memory reservedCounts,
        uint256[] memory availableCounts
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        ItemTier storage itemTier = cs.itemTiers[collectionId][tier];
        uint256 tierVariants = itemTier.variantsCount > 0 ? itemTier.variantsCount : DEFAULT_VARIANT_COUNT;

        uint256 variantCount = 0;
        for (uint8 v = 0; v <= tierVariants; v++) {
            if (v == 0) {
                if (cs.tierVariants[collectionId][tier][0].maxSupply > 0) variantCount++;
            } else {
                if (cs.tierVariants[collectionId][tier][v].variant != 0) variantCount++;
            }
        }
        
        variants = new uint8[](variantCount);
        maxSupplies = new uint256[](variantCount);
        assignedCounts = new uint256[](variantCount);
        reservedCounts = new uint256[](variantCount);
        availableCounts = new uint256[](variantCount);
        
        uint256 index = 0;
        for (uint8 v = 0; v <= tierVariants; v++) {
            bool exists = false;
            if (v == 0) {
                exists = (cs.tierVariants[collectionId][tier][0].maxSupply > 0);
            } else {
                exists = (cs.tierVariants[collectionId][tier][v].variant != 0);
            }
            
            if (exists) {
                variants[index] = v;
                maxSupplies[index] = cs.tierVariants[collectionId][tier][v].maxSupply;
                assignedCounts[index] = cs.hitVariantsCounters[collectionId][tier][v];
                reservedCounts[index] = _countActiveTempReservations(collectionId, tier, v);
                
                uint256 totalUsed = assignedCounts[index] + reservedCounts[index];
                availableCounts[index] = (totalUsed >= maxSupplies[index]) ? 0 : (maxSupplies[index] - totalUsed);
                
                index++;
            }
        }
        
        return (variants, maxSupplies, assignedCounts, reservedCounts, availableCounts);
    }
    
    function getSpecimenUsageStats(uint256 specimenCollectionId, uint256 tokenId) external view returns (
        uint256 currentUsage,
        uint256 freeRollsUsed,
        uint256 totalRollsEver,
        uint256 freeRollsRemaining,
        uint256 maxUsage,
        uint256 nextRollPayment,
        bool isExhausted
    ) {
        uint256 combinedId = PodsUtils.combineIds(specimenCollectionId, tokenId);
        LibCollectionStorage.RollCoupon storage specimen = LibCollectionStorage.collectionStorage().rollCouponsByTokenId[combinedId];
        
        currentUsage = specimen.usedRolls;
        freeRollsUsed = specimen.freeRollsUsed;
        totalRollsEver = specimen.totalRollsEver;
        
        LibCollectionStorage.CouponConfiguration storage specimenConfig = LibCollectionStorage.collectionStorage().couponConfiguration;
        maxUsage = specimenConfig.maxRollsPerCoupon;
        
        if (freeRollsUsed >= specimenConfig.freeRollsPerCoupon) {
            freeRollsRemaining = 0;
        } else {
            freeRollsRemaining = specimenConfig.freeRollsPerCoupon - freeRollsUsed;
        }
        
        (, uint8 tier,) = LibCollectionStorage.getCollectionInfo(specimenCollectionId);
        (nextRollPayment,) = _calculateRollingPayment(specimenCollectionId, tokenId, tier);
        
        isExhausted = (maxUsage > 0) && (currentUsage >= maxUsage);
        
        return (currentUsage, freeRollsUsed, totalRollsEver, freeRollsRemaining, maxUsage, nextRollPayment, isExhausted);
    }
    
    function canUseCoupon(uint256 specimenCollectionId, uint256 tokenId, address user) external view returns (bool canUse, string memory reason, uint256 rollsRemaining) {
    
        // This function already calls _validateAccess() which now has the proper logic
        (bool isValid, string memory validationReason) = _validateAccess(specimenCollectionId, tokenId, user);
        
        if (!isValid) {
            return (false, validationReason, 0);
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        (, uint8 tier,) = LibCollectionStorage.getCollectionInfo(specimenCollectionId);
        
        // Check if token already has variant for non-Main collections
        CollectionType collectionType = _getCollectionType(specimenCollectionId);
        if (collectionType != CollectionType.Main) {
            if (cs.itemsVariants[specimenCollectionId][tier][tokenId] != 0) {
                if (!cs.tokenRollingUnlocked[specimenCollectionId][tokenId]) {
                    return (false, "Token already has assigned variant", 0);
                }
            }
            
            // Check rolling limits for non-Main collections
            LibCollectionStorage.CouponConfiguration storage specimenConfig = _getCouponConfig();
            uint256 activeCount = _countActiveRolls(specimenCollectionId, tokenId);
            
            if (activeCount >= specimenConfig.maxRollsPerCoupon) {
                return (false, "Max active rolls exceeded", 0);
            }
            
            rollsRemaining = specimenConfig.maxRollsPerCoupon - activeCount;
        } else {
            // Main collections don't have rolling limits
            rollsRemaining = 0;
        }
        
        return (true, validationReason, rollsRemaining);
    }

    function getTokenRoll(uint256 collectionId, uint8 tier, uint256 tokenId) external view returns (LibCollectionStorage.VariantRoll memory roll) {
        bytes32 rollHash = _getTokenRollHash(collectionId, tier, tokenId);
        if (rollHash != bytes32(0)) {
            return _getVariantRoll(rollHash);
        }
        return roll;
    }
        
    function getRoll(bytes32 rollHash) external view returns (LibCollectionStorage.VariantRoll memory roll) {
        return _getVariantRoll(rollHash);
    }
    
    function checkRoll(bytes32 rollHash) external view returns (bool valid, uint8 variant, uint256 timeRemaining) {
        LibCollectionStorage.VariantRoll storage roll = _getVariantRoll(rollHash);
        
        if (!roll.exists) {
            return (false, 0, 0);
        }
        
        bool isValid = block.timestamp <= roll.expiresAt && !_isRollConsumed(rollHash);
        uint256 remaining = isValid ? roll.expiresAt - block.timestamp : 0;
        
        return (isValid, roll.variant, remaining);
    }
    
    function getMessageToSign(bytes32 rollHash) external view returns (string memory messageToSign) {
        LibCollectionStorage.VariantRoll storage roll = _getVariantRoll(rollHash);
        
        if (!roll.exists) {
            revert RollNotFound();
        }
        
        return string(abi.encodePacked(
            "Apply variant roll: ",
            Strings.toHexString(uint256(rollHash)),
            " with nonce: ",
            Strings.toString(roll.nonce)
        ));
    }

    /**
     * @notice Check if Main collection coupon was used
     */
    function isCouponUsed(uint256 collectionId, uint256 tokenId) external view returns (bool) {
        return LibCollectionStorage.collectionStorage().collectionCouponUsed[collectionId][tokenId];
    }

    /**
     * @notice Check multiple coupon statuses
     * @param collectionId Collection ID
     * @param tokenIds Token IDs to check
     * @return used Array of usage statuses
     */
    function checkCoupons(
        uint256 collectionId,
        uint256[] calldata tokenIds
    ) external view validInternalCollection(collectionId) returns (bool[] memory used) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        used = new bool[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            used[i] = cs.collectionCouponUsed[collectionId][tokenIds[i]];
        }
    }

    /**
     * @notice Get comprehensive token status
     * @param collectionId Collection ID
     * @param tokenId Token ID
     */
    function getRollingTokenStatus(
        uint256 collectionId,
        uint256 tokenId
    ) external view validInternalCollection(collectionId) returns (
        uint8 variant,
        bool couponUsed,
        bool rollingUnlocked,
        bool hasAugment
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        (, uint8 tier,) = LibCollectionStorage.getCollectionInfo(collectionId);
        variant = cs.itemsVariants[collectionId][tier][tokenId];
        couponUsed = cs.collectionCouponUsed[collectionId][tokenId];
        rollingUnlocked = cs.tokenRollingUnlocked[collectionId][tokenId];
        
        (address contractAddress,,) = LibCollectionStorage.getCollectionInfo(collectionId);
        bytes32 assignment = cs.specimenToAssignment[contractAddress][tokenId];
        hasAugment = assignment != bytes32(0) && cs.augmentAssignments[assignment].active;
    }

    function calculateRollingPayment(uint256 specimenCollectionId, uint256 tokenId, uint8 tier) external view returns (uint256 requiredPayment, IERC20 currency) {
        return _calculateRollingPayment(specimenCollectionId, tokenId, tier);
    }
    
    function calculateAssignmentPayment(address user, uint256 collectionId, uint8 tier) external view returns (uint256 requiredPayment, IERC20 currency) {
        return _calculateAssignmentPayment(user, collectionId, tier);
    }
    
    function canRollToken(uint256 collectionId, uint8, uint256 tokenId, address user) external view returns (bool canRoll, string memory reason) {
        // This function already calls _validateAccess() which now has the proper logic
        return _validateAccess(collectionId, tokenId, user);
    }
        
    function getMintedToken(bytes32 rollHash) external view returns (LibCollectionStorage.MintedToken memory token) {
        return _getMintedToken(rollHash);
    }
    
    function isRollConsumed(bytes32 rollHash) external view returns (bool assigned) {
        return _isRollConsumed(rollHash);
    }

    function isTokenRollingUnlocked(
        uint256 collectionId,
        uint256 tokenId
    ) external view returns (bool unlocked) {
        return LibCollectionStorage.collectionStorage().tokenRollingUnlocked[collectionId][tokenId];
    }
    
    // ==================== ADMIN FUNCTIONS ====================

    /**
     * @notice ADMIN: Reset coupon usage status (emergency recovery)
     */
    function resetCouponUsage(
        uint256 collectionId, 
        uint256 tokenId
    ) external onlyAuthorized {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        cs.collectionCouponUsed[collectionId][tokenId] = false;
        
        emit CouponUsageReset(collectionId, tokenId, LibMeta.msgSender());
    }

    function cleanupExpiredReservations(
        uint256 collectionId,
        uint8 tier,
        uint8 variant,
        uint256 maxCleanups
    ) external onlyAuthorized whenNotPaused returns (uint256 cleaned) {
        LibCollectionStorage.TempReservation[] storage reservations = _getTempReservations(collectionId, tier, variant);
        uint256 reservationsLength = reservations.length;
        
        for (uint256 i = 0; i < reservationsLength && cleaned < maxCleanups; i++) {
            if (i >= reservations.length) break;
            
            LibCollectionStorage.TempReservation storage reservation = reservations[i];
            
            if (reservation.active && block.timestamp > reservation.expiresAt) {
                bytes32 rollHash = reservation.rollHash;
                
                reservation.active = false;
                
                if (!_isRollConsumed(rollHash)) {
                    _resetSpecimenOnExpiry(rollHash);
                }
                
                _deleteRollToReservationIndex(rollHash);
                
                emit VariantRollExpired(rollHash, variant);
                
                cleaned++;
            }
        }
        
        return cleaned;
    }

    function checkMaintenanceNeeded(
        uint256 collectionId,
        uint8 tier
    ) external view returns (bool needsCleanup, uint256 expiredCount) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        for (uint8 variant = 1; variant <= 4; variant++) {
            if (cs.tierVariants[collectionId][tier][variant].variant != 0) {
                LibCollectionStorage.TempReservation[] storage reservations = _getTempReservations(collectionId, tier, variant);
                
                for (uint256 i = 0; i < reservations.length; i++) {
                    if (reservations[i].active && block.timestamp > reservations[i].expiresAt) {
                        expiredCount++;
                    }
                }
            }
        }
        
        needsCleanup = (expiredCount > 0);
        return (needsCleanup, expiredCount);
    }

    function batchResetCoupons(
        uint256 specimenCollectionId,
        uint256[] calldata tokenIds
    ) external onlyAuthorized whenNotPaused {
        uint256 length = tokenIds.length;
        
        if (length > 100) revert BatchTooLarge(length, 100);
        
        for (uint256 i = 0; i < length; i++) {
            uint256 combinedId = PodsUtils.combineIds(specimenCollectionId, tokenIds[i]);
            LibCollectionStorage.RollCoupon storage specimen = _getRollCoupon(combinedId);
            
            specimen.usedRolls = 0;
            specimen.freeRollsUsed = 0;
            specimen.totalRollsEver = 0;
            specimen.lastRollTime = 0;
            specimen.active = true;
        }
        
        emit SpecimensBatchReset(LibMeta.msgSender(), length);
    }

    function resetCoupon(
        uint256 specimenCollectionId,
        uint256 tokenId
    ) external onlyAuthorized whenNotPaused {
        uint256 combinedId = PodsUtils.combineIds(specimenCollectionId, tokenId);
        LibCollectionStorage.RollCoupon storage specimen = _getRollCoupon(combinedId);
        
        specimen.usedRolls = 0;
        specimen.freeRollsUsed = 0;
        specimen.totalRollsEver = 0;
        specimen.lastRollTime = 0;
        specimen.active = false;
    }

    /**
     * @notice Enable token re-rolling
     * @param collectionId Collection ID
     * @param tokenIds Token IDs to unlock
     */
    function unlockTokens(
        uint256 collectionId,
        uint256[] calldata tokenIds
    ) external onlyAuthorized whenNotPaused validInternalCollection(collectionId) {
        if (tokenIds.length == 0 || tokenIds.length > 100) {
            revert InvalidConfiguration();
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            cs.tokenRollingUnlocked[collectionId][tokenIds[i]] = true;
            emit TokenUnlocked(collectionId, tokenIds[i]);
        }
    }

    /**
     * @notice Disable token re-rolling
     * @param collectionId Collection ID
     * @param tokenIds Token IDs to lock
     */
    function lockTokens(
        uint256 collectionId,
        uint256[] calldata tokenIds
    ) external onlyAuthorized whenNotPaused validInternalCollection(collectionId) {
        if (tokenIds.length == 0 || tokenIds.length > 100) {
            revert InvalidConfiguration();
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            cs.tokenRollingUnlocked[collectionId][tokenIds[i]] = false;
            emit TokenLocked(collectionId, tokenIds[i]);
        }
    }

    /**
     * @notice Reset coupon usage (emergency recovery)
     * @param collectionId Collection ID
     * @param tokenIds Token IDs to reset
     */
    function resetCoupons(
        uint256 collectionId,
        uint256[] calldata tokenIds
    ) external onlyAuthorized whenNotPaused validInternalCollection(collectionId) {
        if (tokenIds.length == 0 || tokenIds.length > 50) {
            revert InvalidConfiguration();
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (cs.collections[collectionId].collectionType != CollectionType.Main) {
            revert InvalidCollectionType();
        }
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            cs.collectionCouponUsed[collectionId][tokenIds[i]] = false;
            emit CouponReset(collectionId, tokenIds[i]);
        }
    }

    /**
     * @notice Configure collection rolling policy
     * @param collectionId Collection ID
     * @param allowReRolling Whether re-rolling is allowed
     */
    function setRollingPolicy(
        uint256 collectionId,
        bool allowReRolling
    ) external onlyAuthorized whenNotPaused validInternalCollection(collectionId) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        cs.couponCollections[collectionId].allowSelfRolling = allowReRolling;
        
        emit RollingPolicyUpdated(collectionId, allowReRolling);
    }

}