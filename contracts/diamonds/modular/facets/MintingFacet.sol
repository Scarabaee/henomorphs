// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibCollectionStorage} from "../libraries/LibCollectionStorage.sol";
import {LibMeta} from "../shared/libraries/LibMeta.sol";
import {TierVariant, ItemTier} from "../libraries/CollectionModel.sol"; 
import {AccessControlBase} from "./AccessControlBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {RecipientStatus} from "./WhitelistFacet.sol";
import {ISpecimenCollection} from "../interfaces/IExternalSystems.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {PodsUtils} from "../utils/PodsUtils.sol";
import {CollectionType} from "../libraries/ModularAssetModel.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

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

interface IAugmentFacet {
    function altAssignAugment(
        address specimenCollection,
        uint256 specimenTokenId,
        address augmentCollection,
        uint256 augmentTokenId,
        uint256 lockDuration,
        bool createAccessories,
        bool skipFee
    ) external;
}

interface IRollingFacet {
    function rollVariant(
        uint256 collectionId,
        uint256 tokenId,
        uint256 specimenCollectionId,
        uint256 specimenTokenId,
        bytes32 previousRollHash,
        bytes calldata signature
    ) external payable returns (
        bytes32 rollHash,
        string memory messageToSign,
        uint8 variant,
        uint256 expiresAt,
        uint8 rerollsRemaining
    );
}

/**
 * @title MintingFacet
 * @notice Handles minting and payment processing for all collection types
 * @dev Main minting operations with configurable modes
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 * @custom:version 5.0.0 - Minting operations only
 */
contract MintingFacet is AccessControlBase {
    using SafeERC20 for IERC20;
    using Strings for uint256;
    using PodsUtils for uint256;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    uint256 private constant DEFAULT_VARIANT_COUNT = 4;
    
    // ==================== STRUCTS ====================
    
    struct MintRequest {
        uint256 quantity;               
        uint256 seed;                   
        bytes32[] merkleProof;          
        uint80[2] exchangeRounds;       
        bool useSpecimenRolling;        
        uint256 specimenCollectionId;   
        uint256 specimenTokenId;        
        bytes32 previousRollHash;       
        bytes rollSignature;   
        bool isPreRolledMint;         
    }

    /**
     * @notice Add this function to MintingFacet.sol
     * @dev Minimal collection control function without over-engineering
     */

    struct CollectionInfo {
        bool exists;
        address contractAddress;
        bool mintingActive;
        uint256 currentMints;
        uint256 maxMints;
        uint256 price;
        address currency;
        string status;
    }
        
    // ==================== EVENTS ====================
    
    event TokensMinted(address indexed user, uint256 indexed collectionId, uint8 indexed tier, uint256 quantity, uint8 variant, uint256 totalPaid, uint256[] tokenIds);
    event PaymentProcessed(address indexed user, uint256 amount, bool isNative, bool usedExchange, uint80[2] exchangeRounds, address beneficiary);
    event SpecimenUsed(uint256 indexed specimenCollectionId, uint256 indexed specimenTokenId, address indexed user, uint256 rollsUsed);
    event AutoAssignmentRequested(uint256 indexed augmentTokenId, address indexed specimenCollection, uint256 indexed specimenTokenId);
    event AutoAssignmentCompleted(uint256 indexed augmentTokenId, address indexed specimenCollection, uint256 indexed specimenTokenId);
    event AssignmentPaymentProcessed(address indexed user, uint256 amount, bool isNative, address beneficiary);
    event VariantAssigned(address indexed user, bytes32 indexed rollHash, uint256 indexed tokenId, uint8 variant, address targetCollection);
    event SpecimenDataOverridden(
        uint256 provided,
        uint256 actual,
        string reason
    );

    event AutoAssignmentFailed(uint256 indexed augmentTokenId, address indexed specimenCollection, uint256 indexed specimenTokenId, string reason);
    
    // ==================== CUSTOM ERRORS ====================
    
    error MintingNotActive();
    error MintingNotStarted(uint256 startTime);
    error MintingEnded(uint256 endTime);
    error InvalidQuantity();
    error MaxMintsExceeded(uint256 available, uint256 requested);
    error MaxUserMintsExceeded(uint256 available, uint256 requested);
    error InsufficientPayment(uint256 required, uint256 provided);
    error WhitelistVerificationFailed();
    error TargetCollectionError();
    error ExchangeRateUnavailable();
    error MintCapExceeded(uint256 current, uint256 max);
    error SpecimenNotAccessible();
    error AssignmentNotActive(); 
    error TokenAlreadyHasVariant(uint256 tokenId, uint8 variant);
    error InsufficientVariantsAvailable();
    error CollectionNotCompatible(uint256 collectionId, address augmentCollection);
    error InvalidAssignRequest();
    error RollNotFound();
    error RollExpired();
    error RollAlreadyAssigned();
    error RateLimited(uint256 timeRemaining);
    error CollectionMismatch(uint256 provided, uint256 expected);
    error CouponAlreadyUsed(uint256 collectionId, uint256 tokenId);
    error InvalidSignature();
    error MaxWalletMintsExceeded(uint256 limit, uint256 attempted);
    error InvalidCollectionType();
    
    // ==================== MAIN FUNCTIONS ====================
    
    /**
     * @notice Main mint function with collection-type-specific logic
     * @param collectionId Collection ID for minting
     * @param tier Tier level
     * @param request Mint request with optional rolling parameters
     * @return tokenIds Array of minted token IDs
     * @return variant The variant of minted tokens
     * @return totalPaid Total amount paid
     */
    function mint(
        uint256 collectionId,
        uint8 tier,
        MintRequest memory request
    ) public payable whenNotPaused nonReentrant returns (
        uint256[] memory tokenIds,
        uint8 variant,
        uint256 totalPaid
    ) { 
        return _mint(collectionId, tier, request);
    }

    /**
     * @notice Mint with roll or auto-variant if no roll provided
     * @dev Handles both pre-rolled variants and auto-variant selection
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param rollHash Roll hash (bytes32(0) for auto-variant)
     * @param signature Signature (empty for auto-variant)
     * @return tokenIds Minted token IDs
     * @return variant Selected variant
     * @return totalPaid Total amount paid
     */
    function mintWithRoll(
        uint256 collectionId,
        uint8 tier,
        bytes32 rollHash,
        bytes calldata signature
    ) external payable whenNotPaused nonReentrant returns (
        uint256[] memory tokenIds,
        uint8 variant,
        uint256 totalPaid
    ) {
        address user = LibMeta.msgSender();
        
        // CASE 1: Auto-variant mint (no rollHash)
        if (rollHash == bytes32(0)) {
            // Basic validation
            _validateMinting(collectionId, tier, user, 1);
            
            // Select best available variant
            variant = _selectBestAvailableVariant(collectionId, tier);
            if (variant == 0) {
                revert InsufficientVariantsAvailable();
            }
            
            // Validate whitelist
            _validateWhitelist(collectionId, user, tier, 0, new bytes32[](0));
            
            // Process payment with whitelist discounts
            totalPaid = _processMintPayment(user, collectionId, tier, 1, [uint80(0), uint80(0)]);
            
            // Execute minting with selected variant
            tokenIds = _executeMinting(user, collectionId, tier, variant, 1, rollHash);
            
            // Update counters and whitelist usage
            _updateCounters(user, collectionId, tier, 1);
            IWhitelist(address(this)).recordUsage(collectionId, tier, user, 1);
            
            emit TokensMinted(user, collectionId, tier, 1, variant, totalPaid, tokenIds);
            
            return (tokenIds, variant, totalPaid);
        }
        
        // CASE 2: Pre-rolled variant mint (with rollHash)
        LibCollectionStorage.VariantRoll storage roll = _getVariantRoll(rollHash);
        
        // Validate roll exists and belongs to user
        if (!roll.exists) revert RollNotFound();
        if (roll.user != user) revert InvalidAssignRequest();
        if (block.timestamp > roll.expiresAt) revert RollExpired();
        
        // Basic validation
        _validateMinting(collectionId, tier, user, 1);
        
        // Create internal MintRequest using data from roll
        MintRequest memory request = MintRequest({
            quantity: 1,
            seed: 0,
            merkleProof: new bytes32[](0),
            exchangeRounds: [uint80(0), uint80(0)],
            useSpecimenRolling: true,
            specimenCollectionId: roll.couponCollectionId,
            specimenTokenId: roll.couponTokenId,
            previousRollHash: rollHash,
            rollSignature: signature,
            isPreRolledMint: true
        });
        
        // Delegate to existing mint logic
        return _mint(collectionId, tier, request);
    }

    /**
     * @notice Mint with auto-selected variant (best available or random)
     * @dev Enhanced function supporting both best-available and random variant selection
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param quantity Quantity to mint
     * @param random If true, selects random variant and charges rolling fee
     * @return tokenIds Minted token IDs
     * @return variant Selected variant
     * @return totalPaid Total amount paid (including rolling fee if applicable)
     */
    function mintAutoVariant(
        uint256 collectionId,
        uint8 tier,
        uint256 quantity,
        bool random
    ) external payable whenNotPaused nonReentrant returns (
        uint256[] memory tokenIds,
        uint8 variant,
        uint256 totalPaid
    ) {
        address user = LibMeta.msgSender();
        
        // Basic validation
        _validateMinting(collectionId, tier, user, quantity);
        
        if (random) {
            // RANDOM MODE: Each token gets individually minted with random variant
            
            // Validate whitelist once
            _validateWhitelist(collectionId, user, tier, 0, new bytes32[](0));
            
            // Process payments upfront
            totalPaid = _processMintPayment(user, collectionId, tier, quantity, [uint80(0), uint80(0)]);
            uint256 rollingFee = _processRandomVariantFee(user, collectionId, tier, quantity);
            totalPaid += rollingFee;
            
            // Mint each token individually with random variant
            tokenIds = new uint256[](quantity);
            
            for (uint256 i = 0; i < quantity; i++) {
                // Generate unique seed for each token
                uint256 seed = uint256(keccak256(abi.encodePacked(
                    block.timestamp,
                    block.prevrandao,
                    user,
                    collectionId,
                    tier,
                    i, // Unique index for each token
                    gasleft()
                )));
                
                // Select random variant for this specific token
                uint8 tokenVariant = IRepositoryFacet(address(this)).selectVariant(collectionId, tier, seed);
                if (tokenVariant == 0) {
                    revert InsufficientVariantsAvailable();
                }
                
                // Mint single token with this variant
                uint256[] memory singleTokenId = _executeMinting(user, collectionId, tier, tokenVariant, 1, bytes32(0));
                tokenIds[i] = singleTokenId[0];
                
                // Track last variant for return value
                variant = tokenVariant;
            }
            
            // Update counters and whitelist usage once
            _updateCounters(user, collectionId, tier, quantity);
            IWhitelist(address(this)).recordUsage(collectionId, tier, user, quantity);
            
            emit TokensMinted(user, collectionId, tier, quantity, variant, totalPaid, tokenIds);
            
        } else {
            // BEST AVAILABLE MODE: All tokens get same best variant (original logic)
            
            variant = _selectBestAvailableVariant(collectionId, tier);
            if (variant == 0) {
                revert InsufficientVariantsAvailable();
            }
            
            // Validate whitelist
            _validateWhitelist(collectionId, user, tier, 0, new bytes32[](0));
            
            // Process mint payment
            totalPaid = _processMintPayment(user, collectionId, tier, quantity, [uint80(0), uint80(0)]);
            
            // Execute minting with selected variant
            tokenIds = _executeMinting(user, collectionId, tier, variant, quantity, bytes32(0));
            
            // Update counters and whitelist usage
            _updateCounters(user, collectionId, tier, quantity);
            IWhitelist(address(this)).recordUsage(collectionId, tier, user, quantity);
            
            emit TokensMinted(user, collectionId, tier, quantity, variant, totalPaid, tokenIds);
        }
        
        return (tokenIds, variant, totalPaid);
    }

    /**
     * @notice Simple mint with quantity
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param quantity Quantity to mint
     * @return tokenIds Minted token IDs
     */
    function mintDefaultVariant(
        uint256 collectionId,
        uint8 tier,
        uint256 quantity
    ) external payable whenNotPaused nonReentrant returns (uint256[] memory tokenIds) {
        
        // Check collection configuration for default mint allowance
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        bool allowDefaultMint = false;
        
        if (LibCollectionStorage.isInternalCollection(collectionId)) {
            allowDefaultMint = cs.collections[collectionId].allowDefaultMint;
        }
        
        // Enforce collection type restriction only if default mint not allowed
        if (!allowDefaultMint) {
            CollectionType collectionType = _getCollectionType(collectionId);
            if (collectionType != CollectionType.Main) {
                revert InvalidCollectionType();
            }
        }
        
        MintRequest memory request = MintRequest({
            quantity: quantity,
            seed: 0,
            merkleProof: new bytes32[](0),
            exchangeRounds: [uint80(0), uint80(0)],
            useSpecimenRolling: false,
            specimenCollectionId: 0,
            specimenTokenId: 0,
            previousRollHash: bytes32(0),
            rollSignature: "",
            isPreRolledMint: false
        });

        (tokenIds,,) = _mint(collectionId, tier, request);
        return tokenIds;
    }
        
    /**
     * @notice Auto-assign variant without rolling (best available or random)
     * @dev Enhanced function supporting both best-available and random variant assignment
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param random If true, selects random variant and charges rolling fee
     * @return variant Assigned variant
     */
    function assignAutoVariant(
        uint256 collectionId,
        uint256 tokenId,
        bool random
    ) external payable whenNotPaused nonReentrant returns (uint8 variant) {
        address user = LibMeta.msgSender();
        
        (, uint8 tier, bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (!exists) {
            revert CollectionNotFound(collectionId);
        }
        
        _validateTokenForAssignment(user, collectionId, tier, tokenId);
        
        // Select variant based on mode
        if (random) {
            // Use existing RepositoryFacet random selection with entropy
            uint256 seed = uint256(keccak256(abi.encodePacked(
                block.timestamp,
                block.prevrandao,
                user,
                collectionId,
                tier,
                tokenId,
                gasleft()
            )));
            
            variant = IRepositoryFacet(address(this)).selectVariant(collectionId, tier, seed);
            if (variant == 0) {
                revert InsufficientVariantsAvailable();
            }
        } else {
            variant = _selectBestAvailableVariant(collectionId, tier);
            if (variant == 0) {
                revert InsufficientVariantsAvailable();
            }
        }
        
        if (!_getAssignmentPricing(collectionId, tier).isActive) {
            revert AssignmentNotActive();
        }
        
        // Process assignment payment
        _processAssignmentPayment(user, collectionId, tier);
        
        // Add rolling fee for random variant selection
        if (random) {
            _processRandomVariantFee(user, collectionId, tier, 1);
            // Note: rollingFee is processed but not tracked in return value
            // since this function only returns variant, not total paid
        }
        
        _executeDirectAssignment(collectionId, tier, tokenId, variant);
        
        emit VariantAssigned(user, bytes32(0), tokenId, variant, address(0));
        
        return variant;
    }
        
    // ==================== MAIN COLLECTION IMPLEMENTATIONS ====================

    function _mint(
        uint256 collectionId,
        uint8 tier,
        MintRequest memory request
    ) internal returns (
        uint256[] memory tokenIds,
        uint8 variant,
        uint256 totalPaid
    ) { 
        CollectionType collectionType = _getCollectionType(collectionId);
        LibCollectionStorage.MintingConfig storage config = _getMintingConfig(collectionId, tier);
        
        if (collectionType == CollectionType.Main) {
            if (config.allowRolling && request.useSpecimenRolling && _supportsRolling(collectionId)) {
                return _mintMainWithRolling(collectionId, tier, request);
            } else {
                return _mintMain(collectionId, tier, request);
            }
        } else if (collectionType == CollectionType.Augment || collectionType == CollectionType.Accessory) {
            if (request.useSpecimenRolling && _supportsRolling(collectionId)) {
                return _mintAugmentWithRolling(collectionId, tier, request);
            } else {
                return _mintAugment(collectionId, tier, request);
            }
        } else {
            revert UnsupportedCollectionType(collectionId, "");
        }
    }

    function _mintMain(
        uint256 collectionId,
        uint8 tier,
        MintRequest memory request
    ) internal returns (
        uint256[] memory tokenIds,
        uint8 variant,
        uint256 totalPaid
    ) {
        address user = LibMeta.msgSender();
        
        _validateMinting(collectionId, tier, user, request.quantity);
        _validateWhitelist(collectionId, user, tier, request.seed, request.merkleProof);
        
        LibCollectionStorage.MintingConfig storage config = _getMintingConfig(collectionId, tier);
        variant = config.defaultVariant;
        
        totalPaid = _processMintPayment(user, collectionId, tier, request.quantity, request.exchangeRounds);
        tokenIds = _executeMinting(user, collectionId, tier, variant, request.quantity, request.previousRollHash);
        _updateCounters(user, collectionId, tier, request.quantity);
        
        IWhitelist(address(this)).recordUsage(collectionId, tier, user, request.quantity);
        
        emit TokensMinted(user, collectionId, tier, request.quantity, variant, totalPaid, tokenIds);
        
        return (tokenIds, variant, totalPaid);
    }
    
    function _mintMainWithRolling(
        uint256 collectionId,
        uint8 tier,
        MintRequest memory request
    ) internal returns (
        uint256[] memory tokenIds,
        uint8 variant,
        uint256 totalPaid
    ) {
        require(request.quantity == 1, "Rolling mode supports quantity=1 only");
        
        address user = LibMeta.msgSender();
        
        _validateMinting(collectionId, tier, user, 1);
        _validateWhitelist(collectionId, user, tier, request.seed, request.merkleProof);
        _verifyMintSignature(user, request.previousRollHash, request.rollSignature);
        
        if (request.previousRollHash != bytes32(0)) {
            // Delegate to RollingFacet for reroll
            (,, uint8 rolledVariant,,) = 
                IRollingFacet(address(this)).rollVariant(
                    collectionId,
                    0, // tokenId not used for new mints
                    0,  // specimenCollectionId not used for main
                    0,  // specimenTokenId not used for main
                    request.previousRollHash,
                    request.rollSignature
                );
            
            tokenIds = new uint256[](0);
            totalPaid = 0;
            return (tokenIds, rolledVariant, totalPaid);
        }
        
        variant = _rollMainVariantForMinting(collectionId, tier, user);
        
        totalPaid = _processMintPayment(user, collectionId, tier, 1, request.exchangeRounds);
        tokenIds = _executeMinting(user, collectionId, tier, variant, 1, request.previousRollHash);
        _updateCounters(user, collectionId, tier, 1);
        
        IWhitelist(address(this)).recordUsage(collectionId, tier, user, 1);
        
        emit TokensMinted(user, collectionId, tier, 1, variant, totalPaid, tokenIds);
        
        return (tokenIds, variant, totalPaid);
    }
    
    // ==================== AUGMENT COLLECTION IMPLEMENTATIONS ====================
    
    function _mintAugment(
        uint256 collectionId,
        uint8 tier,
        MintRequest memory request
    ) internal returns (
        uint256[] memory tokenIds,
        uint8 variant,
        uint256 totalPaid
    ) {
        address user = LibMeta.msgSender();
        
        _validateMinting(collectionId, tier, user, request.quantity);
        _validateWhitelist(collectionId, user, tier, request.seed, request.merkleProof);
        
        LibCollectionStorage.MintingConfig storage config = _getMintingConfig(collectionId, tier);
        if (config.randomMint) {
            variant = _selectBestAvailableVariant(collectionId, tier);
        } else {
            variant = config.defaultVariant; // Usually 0 for later rolling
        }
        
        totalPaid = _processMintPayment(user, collectionId, tier, request.quantity, request.exchangeRounds);
        tokenIds = _executeMinting(user, collectionId, tier, variant, request.quantity, request.previousRollHash);
        _updateCounters(user, collectionId, tier, request.quantity);
        
        IWhitelist(address(this)).recordUsage(collectionId, tier, user, request.quantity);
        
        emit TokensMinted(user, collectionId, tier, request.quantity, variant, totalPaid, tokenIds);
        
        return (tokenIds, variant, totalPaid);
    }
    
    /**
     * @notice Validate token access for augment minting
     * @dev Checks ownership, variant, and coupon usage status
     */
    function _validateForMinting(
        uint256 collectionId, 
        uint256 tokenId, 
        address user
    ) internal view returns (bool isValid, string memory reason) {
        
        CollectionType collectionType = _getCollectionType(collectionId);
        
        if (collectionType == CollectionType.Main) {
            (address contractAddress,, bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
            if (!exists) return (false, "Collection not found");
            
            if (!AccessHelper.hasTokenAccess(contractAddress, tokenId, user)) {
                return (false, "No token access");
            }
            
            LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
            (, uint8 tier,) = LibCollectionStorage.getCollectionInfo(collectionId);
            uint8 currentVariant = cs.itemsVariants[collectionId][tier][tokenId];
            
            if (currentVariant == 0) {
                return (false, "Main collection coupon must have assigned variant (variant > 0)");
            }
            
            // FIXED: Check if coupon was already used
            if (cs.collectionCouponUsed[collectionId][tokenId]) {
                return (false, "Coupon already used");
            }
            
            // Check if coupon already has active augment assignment
            bytes32 existingAssignment = cs.specimenToAssignment[contractAddress][tokenId];
            if (existingAssignment != bytes32(0) && cs.augmentAssignments[existingAssignment].active) {
                return (false, "Coupon already has active augment assignment");
            }
            
            return (true, "Valid coupon");
            
        } else {
            return _validateSpecimenAccess(collectionId, tokenId, user);
        }
    }

    /**
     * @notice Mint augment with rolling (FIXED: Use proper specimen validation)
     */
    function _mintAugmentWithRolling(
        uint256 collectionId,
        uint8 tier,
        MintRequest memory request
    ) internal returns (
        uint256[] memory tokenIds,
        uint8 variant,
        uint256 totalPaid
    ) {
        address user = LibMeta.msgSender();
        
        _validateMinting(collectionId, tier, user, request.quantity);
        _validateWhitelist(collectionId, user, tier, request.seed, request.merkleProof);
        _verifyMintSignature(user, request.previousRollHash, request.rollSignature);
        _setRollConsumed(request.previousRollHash, true);
        
        if (request.useSpecimenRolling && request.previousRollHash != bytes32(0)) {
            
            if (request.isPreRolledMint) {
                // PRE-ROLLED MINT
                LibCollectionStorage.VariantRoll storage roll = _getVariantRoll(request.previousRollHash);
                
                if (!roll.exists) revert RollNotFound();
                if (roll.user != user) revert InvalidAssignRequest();
                if (block.timestamp > roll.expiresAt) revert RollExpired();
                
                // Claim coupon atomically
                _claimCoupon(roll.couponCollectionId, roll.couponTokenId, user);
                
                variant = roll.variant;
                totalPaid = _processMintPayment(user, collectionId, tier, request.quantity, request.exchangeRounds);
                tokenIds = _executeMinting(user, collectionId, tier, variant, request.quantity, request.previousRollHash);
                
                if (tokenIds.length > 0) {
                    _tryAutoAssignAugment(roll.couponCollectionId, roll.couponTokenId, collectionId, tokenIds[0]);
                }
                
            } else {
                // REROLL LOGIC
                _claimCoupon(request.specimenCollectionId, request.specimenTokenId, user);
                
                (,, uint8 rolledVariant,,) = IRollingFacet(address(this)).rollVariant(
                    collectionId,
                    0,
                    request.specimenCollectionId,
                    request.specimenTokenId,
                    request.previousRollHash,
                    request.rollSignature
                );
                
                return (new uint256[](0), rolledVariant, 0);
            }
            
        } else if (request.useSpecimenRolling) {
            // FRESH ROLL + MINT
            _claimCoupon(request.specimenCollectionId, request.specimenTokenId, user);
            
            // Get correct tier for specimen collection
            (, uint8 specimenTier,) = LibCollectionStorage.getCollectionInfo(request.specimenCollectionId);
            
            uint256 rollingPayment = _processSpecimenPayment(
                request.specimenCollectionId, 
                request.specimenTokenId, 
                user, 
                specimenTier  // FIXED: Use specimen tier
            );
            
            variant = _rollRandomVariant(
                collectionId, tier, user, request.specimenCollectionId, request.specimenTokenId
            );
            
            totalPaid = _processMintPayment(user, collectionId, tier, request.quantity, request.exchangeRounds);
            totalPaid += rollingPayment;

            tokenIds = _executeMinting(user, collectionId, tier, variant, request.quantity, request.previousRollHash);

            if (tokenIds.length > 0) {
                _tryAutoAssignAugment(request.specimenCollectionId, request.specimenTokenId, collectionId, tokenIds[0]);
            }
            
        } else {
            // STANDARD MINT
            variant = 0;
            totalPaid = _processMintPayment(user, collectionId, tier, request.quantity, request.exchangeRounds);
            tokenIds = _executeMinting(user, collectionId, tier, variant, request.quantity, request.previousRollHash);
        }
        
        _updateCounters(user, collectionId, tier, request.quantity);
        IWhitelist(address(this)).recordUsage(collectionId, tier, user, request.quantity);
        emit TokensMinted(user, collectionId, tier, request.quantity, variant, totalPaid, tokenIds);
        
        return (tokenIds, variant, totalPaid);
    }

    /**
     * @notice Atomically validate and mark coupon as used
     * @dev Prevents double-spending of Main collection coupons
     */
    function _claimCoupon(uint256 collectionId, uint256 tokenId, address user) internal {
        (bool isValid,) = _validateForMinting(collectionId, tokenId, user);
        if (!isValid) revert SpecimenNotAccessible();
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        cs.collectionCouponUsed[collectionId][tokenId] = true;
    }
    
    // ==================== PAYMENT PROCESSING ====================

    /**
     * @notice Process rolling fee for random variant selection
     * @dev Charges rolling fee in ZICO currency proportional to quantity
     * @param user User address
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param quantity Number of tokens being minted
     * @return paidAmount Amount paid for rolling fee
     */
    function _processRandomVariantFee(address user, uint256 collectionId, uint8 tier, uint256 quantity) internal returns (uint256 paidAmount) {
        LibCollectionStorage.RollingPricing storage pricing = _getRollingPricing(collectionId, tier);
        
        // Skip fee if rolling not configured or authorized user
        if (!pricing.isActive || address(pricing.currency) == address(0) || _isAuthorized()) {
            return 0;
        }
        
        uint256 unitRollingFee = pricing.onSale ? pricing.discounted : pricing.regular;
        
        if (unitRollingFee == 0) {
            return 0;
        }
        
        // Calculate total rolling fee based on quantity
        uint256 totalRollingFee = unitRollingFee * quantity;
        
        // Charge rolling fee in ZICO
        pricing.currency.safeTransferFrom(user, pricing.beneficiary, totalRollingFee);
        
        return totalRollingFee;
    }
    
    function _processMintPayment(
        address user,
        uint256 collectionId,
        uint8 tier,
        uint256 quantity,
        uint80[2] memory exchangeRounds
    ) internal returns (uint256 totalPaid) {
        (uint256 requiredPayment, IERC20 currency, bool isNative) = _calculateMintPayment(
            user, collectionId, tier, quantity, exchangeRounds
        );
        
        if (requiredPayment == 0) {
            if (msg.value > 0) {
                Address.sendValue(payable(user), msg.value);
            }
            return 0;
        }
        
        LibCollectionStorage.MintPricing storage pricing = _getMintingPricing(collectionId, tier);
        
        if (isNative) {
            if (msg.value < requiredPayment) {
                revert InsufficientPayment(requiredPayment, msg.value);
            }
            
            Address.sendValue(payable(pricing.beneficiary), requiredPayment);
            
            if (msg.value > requiredPayment) {
                Address.sendValue(payable(user), msg.value - requiredPayment);
            }
        } else {
            currency.safeTransferFrom(user, pricing.beneficiary, requiredPayment);
        }
        
        bool usedExchange = pricing.useExchangeRate && isNative;
        emit PaymentProcessed(user, requiredPayment, isNative, usedExchange, exchangeRounds, pricing.beneficiary);
        
        return requiredPayment;
    }
    
    function _processSpecimenPayment(
        uint256 specimenCollectionId,
        uint256 specimenTokenId,
        address user,
        uint8 tier
    ) internal returns (uint256 paidAmount) {
        uint256 combinedId = PodsUtils.combineIds(specimenCollectionId, specimenTokenId);
        LibCollectionStorage.RollCoupon storage specimen = _getRollCoupon(combinedId);
        LibCollectionStorage.CouponConfiguration storage specimenConfig = _getSpecimenConfig();
        
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
    
    function _calculateMintPayment(
        address user,
        uint256 collectionId,
        uint8 tier,
        uint256 quantity,
        uint80[2] memory exchangeRounds
    ) internal view returns (uint256 requiredPayment, IERC20 currency, bool isNative) {
        LibCollectionStorage.MintPricing storage pricing = _getMintingPricing(collectionId, tier);
        currency = pricing.currency;
        isNative = pricing.chargeNative || address(currency) == address(0);
        
        (, , uint256 freeAvailable) = IWhitelist(address(this)).getExemptedQuantity(collectionId, tier, user);
        
        uint256 freeQuantity = (quantity <= freeAvailable) ? quantity : freeAvailable;
        uint256 paidQuantity = quantity - freeQuantity;
        
        if (paidQuantity == 0) {
            return (0, currency, isNative);
        }
        
        if (freeQuantity < quantity) {
            RecipientStatus memory status = IWhitelist(address(this)).getRecipientStatus(collectionId, tier, user, 0, new bytes32[](0));
            uint256 userMints = _getUserMintCount(user, collectionId, tier);
            uint256 whitelistCount = LibCollectionStorage.getEligibleRecipientsCount(collectionId, tier);
            
            if (userMints + freeQuantity < pricing.freeMints) {
                if (whitelistCount == 0 || !status.isEligible) {
                    uint256 additionalFree = pricing.freeMints - userMints - freeQuantity;
                    uint256 totalFree = freeQuantity + additionalFree;
                    
                    if (totalFree >= quantity) {
                        return (0, currency, isNative);
                    }
                    
                    paidQuantity = quantity - totalFree;
                }
            }
        }
        
        uint256 unitPrice = pricing.onSale ? pricing.discounted : pricing.regular;
        requiredPayment = unitPrice * paidQuantity;
        
        if (pricing.useExchangeRate && isNative) {
            requiredPayment = _deriveNativePrice(requiredPayment, exchangeRounds);
        }
        
        return (requiredPayment, currency, isNative);
    }
    
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
        LibCollectionStorage.CouponConfiguration storage specimenConfig = _getSpecimenConfig();
        
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
    
    // ==================== MINTING EXECUTION ====================
    
    function _executeMinting(
        address user,
        uint256 collectionId,
        uint8 tier,
        uint8 variant,
        uint256 quantity,
        bytes32 rollHash
    ) internal returns (uint256[] memory tokenIds) {
        (address targetCollection,, bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (!exists || targetCollection == address(0)) {
            revert TargetCollectionError();
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();

        LibCollectionStorage.VariantRoll storage roll = _getVariantRoll(rollHash);
        LibCollectionStorage.CouponCollection storage specimen = _getCouponCollection(roll.couponCollectionId);
        
        uint256 issueId;
        if (LibCollectionStorage.isInternalCollection(collectionId)) {
            issueId = cs.collections[collectionId].defaultIssueId;
        } else {
            issueId = collectionId;
        }

        address collectionAddress = address(0);
        uint256 tokenId = 0;

        if (specimen.collectionAddress != address(0) && roll.couponTokenId > 0) {
            collectionAddress = specimen.collectionAddress;
            tokenId = roll.couponTokenId;
        }
        
        try ISpecimenCollection(targetCollection).mintWithVariantAssignment(
            issueId,
            tier,
            variant,
            user,
            quantity,
            collectionAddress,
            tokenId
        ) returns (uint256[] memory _tokenIds, uint8[] memory) {
            if (_tokenIds.length == 0) {
                revert TargetCollectionError();
            }
            return _tokenIds;
            
        } catch {
            try ISpecimenCollection(targetCollection).mintVariant(
                issueId,
                tier,
                variant,
                user,
                quantity
            ) returns (uint256[] memory _tokenIds) {
                if (_tokenIds.length == 0) {
                    revert TargetCollectionError();
                }
                return _tokenIds;
                
            } catch {
                revert TargetCollectionError();
            }
        }
    }
    
    function _updateCounters(address user, uint256 collectionId, uint8 tier, uint256 quantity) internal {
        uint256 currentCount = _getUserMintCount(user, collectionId, tier);
        _setUserMintCount(user, collectionId, tier, currentCount + quantity);
        
        LibCollectionStorage.MintingConfig storage config = _getMintingConfig(collectionId, tier);
        config.currentMints += quantity;
    }
    
    function _rollMainVariantForMinting(
        uint256 collectionId,
        uint8 tier,
        address user
    ) internal view returns (uint8) {
        uint256 seed = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            user,
            collectionId,
            tier,
            gasleft()
        )));
        
        try IRepositoryFacet(address(this)).selectVariant(collectionId, tier, seed) returns (uint8 selectedVariant) {
            if (selectedVariant == 0) {
                return 1;
            }
            return selectedVariant;
        } catch {
            return 1;
        }
    }
    
    function _rollRandomVariant(
        uint256 collectionId,
        uint8 tier,
        address user,
        uint256 specimenCollectionId,
        uint256 specimenTokenId
    ) internal view returns (uint8) {
        uint256 seed = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            user,
            collectionId,
            tier,
            specimenCollectionId,
            specimenTokenId,
            gasleft()
        )));
        
        try IRepositoryFacet(address(this)).selectVariant(collectionId, tier, seed) returns (uint8 selectedVariant) {
            if (selectedVariant == 0) {
                return 1;
            }
            return selectedVariant;
        } catch {
            return 1;
        }
    }
    
    // ==================== AUTO ASSIGNMENT ====================
    
    function _tryAutoAssignAugment(
        uint256 specimenCollectionId,
        uint256 specimenTokenId,
        uint256 augmentCollectionId,
        uint256 augmentTokenId
    ) internal {
        (address specimenCollection, , bool specimenExists) = LibCollectionStorage.getCollectionInfo(specimenCollectionId);
        if (!specimenExists) {
            emit AutoAssignmentRequested(augmentTokenId, specimenCollection, specimenTokenId);
            return;
        }

        (address augmentCollection, , bool augmentExists) = LibCollectionStorage.getCollectionInfo(augmentCollectionId);
        if (!augmentExists) {
            emit AutoAssignmentRequested(augmentTokenId, specimenCollection, specimenTokenId);
            return;
        }

        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        if (cs.augmentRestrictions[specimenCollectionId] && 
            !cs.allowedAugments[specimenCollectionId][augmentCollection]) {
            emit AutoAssignmentRequested(augmentTokenId, specimenCollection, specimenTokenId);
            return;
        }

        try IAugmentFacet(address(this)).altAssignAugment(
            specimenCollection,
            specimenTokenId,
            augmentCollection,
            augmentTokenId,
            2592000, // 30 days
            false,   // don't create accessories
            true     // skip fee for auto-assignment
        ) {
            emit AutoAssignmentCompleted(augmentTokenId, specimenCollection, specimenTokenId);
        } catch Error(string memory reason) {
            emit AutoAssignmentFailed(augmentTokenId, specimenCollection, specimenTokenId, reason);
        } catch {
            emit AutoAssignmentFailed(augmentTokenId, specimenCollection, specimenTokenId, "Unknown error");
        }
    }
    
    // ==================== VALIDATION FUNCTIONS ====================
    
    function _validateMinting(uint256 collectionId, uint8 tier, address user, uint256 quantity) internal view {
        _validateCollection(collectionId);
        _validateMintingActive(collectionId, tier);
        _validateMintingTime(collectionId, tier);
        _validateQuantity(quantity);
        _validateMintLimits(collectionId, tier, user, quantity);
    }

    /**
     * @notice Validate collection exists and is properly configured
     * @dev Simple helper to avoid repetitive collection validation
     * @param collectionId Collection ID to validate
     */
    function _validateCollection(uint256 collectionId) internal view {
        (address contractAddress, , bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (!exists) revert CollectionNotFound(collectionId);
        if (contractAddress == address(0)) revert TargetCollectionError();
    }
    
    function _validateMintingActive(uint256 collectionId, uint8 tier) internal view {
        LibCollectionStorage.MintingConfig storage config = _getMintingConfig(collectionId, tier);
        if (!config.isActive) revert MintingNotActive();
    }
    
    function _validateMintingTime(uint256 collectionId, uint8 tier) internal view {
        LibCollectionStorage.MintingConfig storage config = _getMintingConfig(collectionId, tier);
        
        if (block.timestamp < config.startTime) {
            revert MintingNotStarted(config.startTime);
        }
        
        if (block.timestamp > config.endTime) {
            revert MintingEnded(config.endTime);
        }
    }
    
    function _validateQuantity(uint256 quantity) internal pure {
        if (quantity == 0) revert InvalidQuantity();
    }
    
    function _validateMintLimits(uint256 collectionId, uint8 tier, address user, uint256 quantity) internal view {
        LibCollectionStorage.MintingConfig storage config = _getMintingConfig(collectionId, tier);
        
        if (config.currentMints + quantity > config.maxMints) {
            revert MintCapExceeded(config.currentMints, config.maxMints);
        }
        
        uint256 userAvailable = _availability(collectionId, tier, user);
        if (quantity > userAvailable) {
            revert MaxUserMintsExceeded(userAvailable, quantity);
        }

        // NEW: Simple wallet limit check (4 lines only!)
        LibCollectionStorage.MintPricing storage pricing = _getMintingPricing(collectionId, tier);
        if (pricing.maxMintsPerWallet > 0) {
            uint256 totalMints = LibCollectionStorage.getTotalWalletMints(collectionId, user);
            if (totalMints + quantity > pricing.maxMintsPerWallet) {
                revert MaxWalletMintsExceeded(pricing.maxMintsPerWallet, totalMints + quantity);
            }
        }
    }
    
    function _validateWhitelist(uint256 collectionId, address user, uint8 tier, uint256, bytes32[] memory) internal view {
        uint256 totalAvailable = _availability(collectionId, tier, user);
        
        if (totalAvailable == 0) {
            revert WhitelistVerificationFailed();
        }
    }

    function _validateSpecimenAccess(uint256 specimenCollectionId, uint256 tokenId, address user) internal view returns (bool isValid, string memory reason) {
        LibCollectionStorage.CouponCollection storage collection = _getSpecimenCollection(specimenCollectionId);
        
        if (!collection.active) {
            return (false, "Collection not active");
        }
        
        // Use comprehensive access validation including staking
        if (!AccessHelper.hasTokenAccess(collection.collectionAddress, tokenId, user)) {
            return (false, "No token access (ownership or staking required)");
        }
        
        // Continue with existing rolling-specific validations
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        (, uint8 tier,) = LibCollectionStorage.getCollectionInfo(specimenCollectionId);
        
        uint8 currentVariant = cs.itemsVariants[specimenCollectionId][tier][tokenId];
        bool tokenWasEverVarianted = cs.collectionItemsVarianted[specimenCollectionId][tokenId] != 0;
        bool wasReset = cs.tokenSelfResetUsed[specimenCollectionId][tokenId];
        bool rollingUnlocked = cs.tokenRollingUnlocked[specimenCollectionId][tokenId];
        
        if (wasReset && !rollingUnlocked) {
            return (false, "Token was reset without unlocking rolling capability");
        }
        
        if (currentVariant != 0 && !rollingUnlocked) {
            return (false, "Token already has variant assigned and rolling not unlocked");
        }
        
        if (tokenWasEverVarianted && currentVariant == 0 && !rollingUnlocked && !wasReset) {
            return (false, "Token was previously varianted and rolling not unlocked");
        }
        
        uint256 combinedId = PodsUtils.combineIds(specimenCollectionId, tokenId);
        LibCollectionStorage.RollCoupon storage specimen = _getRollCoupon(combinedId);
        LibCollectionStorage.CouponConfiguration storage specimenConfig = _getSpecimenConfig();
        
        if (specimenConfig.rateLimitingEnabled && specimen.active && specimen.lastRollTime > 0) {
            if (block.timestamp < specimen.lastRollTime + specimenConfig.cooldownBetweenRolls) {
                return (false, "Rate limited");
            }
        }
        
        return (true, "Access granted");
    }

    function _validateTokenForAssignment(
        address user,
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId
    ) internal view {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint8 currentVariant = cs.itemsVariants[collectionId][tier][tokenId];
        if (currentVariant != 0) {
            revert TokenAlreadyHasVariant(tokenId, currentVariant);
        }
        
        (address collectionAddress,, bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (exists && collectionAddress != address(0)) {
            try IERC721(collectionAddress).ownerOf(tokenId) returns (address owner) {
                if (owner != user && (owner != address(0) && !_isAuthorized())) {
                    revert InvalidAssignRequest();
                }
            } catch {
                revert InvalidAssignRequest();
            }
        }
    }
    
    function _executeDirectAssignment(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        uint8 variant
    ) internal {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (cs.hitVariantsCounters[collectionId][tier][0] > 0) {
            cs.hitVariantsCounters[collectionId][tier][0]--;
        }
        cs.hitVariantsCounters[collectionId][tier][variant]++;
        cs.itemsVariants[collectionId][tier][tokenId] = variant;
        
        (address targetCollection,, bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (exists && targetCollection != address(0)) {
            uint256 issueId = LibCollectionStorage.isInternalCollection(collectionId) ? 
                cs.collections[collectionId].defaultIssueId : 1;
                
            try ISpecimenCollection(targetCollection).assignVariant(issueId, tier, tokenId, variant) returns (uint8 assignedVariant) {
                if (assignedVariant != variant) {
                    cs.hitVariantsCounters[collectionId][tier][variant]--;
                    cs.hitVariantsCounters[collectionId][tier][0]++;
                    cs.itemsVariants[collectionId][tier][tokenId] = 0;
                    revert InvalidAssignRequest();
                }
            } catch {
                cs.hitVariantsCounters[collectionId][tier][variant]--;
                cs.hitVariantsCounters[collectionId][tier][0]++;
                cs.itemsVariants[collectionId][tier][tokenId] = 0;
                revert TargetCollectionError();
            }
        }
    }
    
    // ==================== UTILITY FUNCTIONS ====================
    
    function _availability(uint256 collectionId, uint8 tier, address recipient) internal view returns (uint256) {
        uint256 whitelistCount = LibCollectionStorage.getEligibleRecipientsCount(collectionId, tier);
        
        if (whitelistCount > 0) {
            RecipientStatus memory status = IWhitelist(address(this)).getRecipientStatus(collectionId, tier, recipient, 0, new bytes32[](0));
            return (status.isEligible && status.availableAmount > 0) ? status.availableAmount : 0;
        }
        
        uint256 userMints = _getUserMintCount(recipient, collectionId, tier);
        LibCollectionStorage.MintPricing storage pricing = _getMintingPricing(collectionId, tier);
        
        return (userMints < pricing.maxMints) ? (pricing.maxMints - userMints) : 0;
    }
    
    function _getUserMintCount(address user, uint256 collectionId, uint8 tier) internal view returns (uint256) {
        return LibCollectionStorage.collectionStorage().userMintCounters[user][collectionId][tier];
    }

    function _getCouponCollection(uint256 collectionId) internal view returns (LibCollectionStorage.CouponCollection storage) {
        return LibCollectionStorage.collectionStorage().couponCollections[collectionId];
    }
    
    function _setUserMintCount(address user, uint256 collectionId, uint8 tier, uint256 count) internal {
        LibCollectionStorage.collectionStorage().userMintCounters[user][collectionId][tier] = count;
    }
    
    function _selectBestAvailableVariant(uint256 collectionId, uint8 tier) internal view returns (uint8 bestVariant) {
        uint256 maxAvailable = 0;
        
        for (uint8 variant = 1; variant <= 4; variant++) {
            uint256 available = _getAvailableVariantCount(collectionId, tier, variant);
            if (available > maxAvailable) {
                maxAvailable = available;
                bestVariant = variant;
            }
        }
        
        return bestVariant;
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
    
    function _getTempReservations(uint256 collectionId, uint8 tier, uint8 variant) internal view returns (LibCollectionStorage.TempReservation[] storage) {
        return LibCollectionStorage.collectionStorage().tempReservationsByVariant[collectionId][tier][variant];
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
    
    function _deriveNativePrice(uint256 listPrice, uint80[2] memory exchangeRounds) internal view returns (uint256 derivedPrice) {
        (uint256 price,) = LibCollectionStorage.derivePriceFromExchange(listPrice, exchangeRounds);
        
        if (price == 0) {
            revert ExchangeRateUnavailable();
        }
        
        return price;
    }

    function _supportsRolling(uint256 collectionId) internal view returns (bool supported) {
        LibCollectionStorage.RollingPricing storage rollingPricing = _getRollingPricing(collectionId, 1);
        return rollingPricing.isActive && address(rollingPricing.currency) != address(0);
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
    
    function _getMintingConfig(uint256 collectionId, uint8 tier) internal view returns (LibCollectionStorage.MintingConfig storage) {
        return LibCollectionStorage.collectionStorage().mintingConfigs[collectionId][tier];
    }
    
    function _getRollingPricing(uint256 collectionId, uint8 tier) internal view returns (LibCollectionStorage.RollingPricing storage) {
        return LibCollectionStorage.collectionStorage().rollingPricingByTier[collectionId][tier];
    }
    
    function _getAssignmentPricing(uint256 collectionId, uint8 tier) internal view returns (LibCollectionStorage.AssignmentPricing storage) {
        return LibCollectionStorage.collectionStorage().assignmentPricingByTier[collectionId][tier];
    }
    
    function _getMintingPricing(uint256 collectionId, uint8 tier) internal view returns (LibCollectionStorage.MintPricing storage) {
        return LibCollectionStorage.collectionStorage().mintPricingByTier[collectionId][tier];
    }
    
    function _getSpecimenConfig() internal view returns (LibCollectionStorage.CouponConfiguration storage) {
        return LibCollectionStorage.collectionStorage().couponConfiguration;
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
    function _getRollConsumed(bytes32 rollHash) internal view returns (LibCollectionStorage.VariantRoll storage) {
        return LibCollectionStorage.collectionStorage().variantRollsByHash[rollHash];
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

    
    /**
     * @notice Mark Main collection coupon as used
     * @dev Prevents double-spending of the same coupon
     */
    function _markCollectionCouponUsed(uint256 collectionId, uint256 tokenId) internal {
        if (_getCollectionType(collectionId) == CollectionType.Main) {
            LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
            cs.collectionCouponUsed[collectionId][tokenId] = true;
        }
    }
    
    /**
     * @notice Verify mint signature
     * @dev Validates user signature for mint authorization
     */
    function _verifyMintSignature(address user, bytes32 rollHash, bytes memory signature) internal {
        LibCollectionStorage.VariantRoll storage roll = _getVariantRoll(rollHash);
        uint256 savedNonce = roll.nonce;
        
        // Increment nonce for next operation
        LibCollectionStorage.getAndIncrementNonce(user);
        
        string memory humanMessage = string.concat(
            "Apply variant roll: ",
            Strings.toHexString(uint256(rollHash)),
            " with nonce: ",
            Strings.toString(savedNonce)
        );
        
        // Try EIP-191 format first
        bytes32 messageHash = _createEthSignedMessageHash(humanMessage);
        address recovered = messageHash.recover(signature);
        
        if (recovered == user) {
            return;
        }
        
        // Try raw hash as fallback
        bytes32 rawHash = keccak256(bytes(humanMessage));
        recovered = rawHash.recover(signature);
        
        if (recovered == user) {
            return;
        }
        
        revert InvalidSignature();
    }

    /**
     * @notice Create EIP-191 signed message hash
     * @dev Creates properly formatted message hash for signature verification
     */
    function _createEthSignedMessageHash(string memory message) internal pure returns (bytes32) {
        bytes memory messageBytes = bytes(message);
        bytes memory prefix = "\x19Ethereum Signed Message:\n";
        bytes memory lengthBytes = bytes(Strings.toString(messageBytes.length));
        
        return keccak256(abi.encodePacked(prefix, lengthBytes, messageBytes));
    }
    
    // ==================== VIEW FUNCTIONS ====================
    
    function calculateMintPayment(
        address user,
        uint256 collectionId,
        uint8 tier,
        uint256 quantity,
        uint80[2] calldata exchangeRounds
    ) external view returns (uint256 requiredPayment, IERC20 currency, bool isNative) {
        return _calculateMintPayment(user, collectionId, tier, quantity, exchangeRounds);
    }
    
    function getUserMintStats(address user, uint256 collectionId, uint8 tier) external view returns (
        uint256 mintCount,
        uint256 available,
        uint256 nextPayment
    ) {
        mintCount = _getUserMintCount(user, collectionId, tier);
        available = _availability(collectionId, tier, user);
        (nextPayment,,) = _calculateMintPayment(user, collectionId, tier, 1, [uint80(0), uint80(0)]);
        
        return (mintCount, available, nextPayment);
    }
    
    function getMintingSupply(uint256 collectionId, uint8 tier) external view returns (
        uint256 currentMints,
        uint256 maxMints,
        uint256 remaining
    ) {
        LibCollectionStorage.MintingConfig storage config = _getMintingConfig(collectionId, tier);
        
        currentMints = config.currentMints;
        maxMints = config.maxMints;
        remaining = (currentMints >= maxMints) ? 0 : (maxMints - currentMints);
        
        return (currentMints, maxMints, remaining);
    }

    function getMintingEligibility(uint256 collectionId, uint8 tier, address user) external view returns (
        bool hasAccess,
        uint256 totalAvailable,
        uint256 freeAllocation,
        bool hasWhitelistAccess,
        bool hasExemptedAccess, 
        bool hasFallbackAccess,
        uint256 whitelistRemaining,
        uint256 exemptedRemaining,
        uint256 fallbackRemaining,
        string memory primaryAccessType
    ) {
        RecipientStatus memory status = IWhitelist(address(this)).getRecipientStatus(collectionId, tier, user, 0, new bytes32[](0));
        uint256 userMints = _getUserMintCount(user, collectionId, tier);
        LibCollectionStorage.MintPricing storage pricing = _getMintingPricing(collectionId, tier);
        uint256 whitelistCount = LibCollectionStorage.getEligibleRecipientsCount(collectionId, tier);
        
        hasWhitelistAccess = status.isEligible && status.availableAmount > 0;
        whitelistRemaining = hasWhitelistAccess ? status.availableAmount : 0;
        
        hasExemptedAccess = status.freeAvailable > 0;
        exemptedRemaining = status.freeAvailable;
        
        hasFallbackAccess = false;
        fallbackRemaining = 0;
        
        if (whitelistCount == 0 || !status.isEligible) {
            if (userMints < pricing.freeMints) {
                hasFallbackAccess = true;
                fallbackRemaining = pricing.freeMints - userMints;
            }
        }
        
        totalAvailable = whitelistRemaining;
        if (!hasWhitelistAccess && hasFallbackAccess) {
            totalAvailable = fallbackRemaining;
        }
        
        freeAllocation = exemptedRemaining;
        if (!hasExemptedAccess && hasFallbackAccess) {
            freeAllocation = fallbackRemaining;
        }
        
        hasAccess = totalAvailable > 0;
        
        if (hasWhitelistAccess) {
            primaryAccessType = "whitelist";
        } else if (hasFallbackAccess) {
            primaryAccessType = "fallback";
        } else {
            primaryAccessType = "none";
        }
        
        return (
            hasAccess,
            totalAvailable,
            freeAllocation,
            hasWhitelistAccess,
            hasExemptedAccess,
            hasFallbackAccess,
            whitelistRemaining,
            exemptedRemaining,
            fallbackRemaining,
            primaryAccessType
        );
    }

    /**
     * @notice Get basic collection and minting info
     * @param collectionId Collection ID
     * @param tier Tier (default 1)
     * @return info Basic collection information
     */
    function getCollectionMintingInfo(
        uint256 collectionId,
        uint8 tier
    ) external view returns (CollectionInfo memory info) {
        
        // Check if collection exists
        (address contractAddress, , bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        
        if (!exists) {
            return CollectionInfo({
                exists: false,
                contractAddress: address(0),
                mintingActive: false,
                currentMints: 0,
                maxMints: 0,
                price: 0,
                currency: address(0),
                status: "NOT_FOUND"
            });
        }
        
        // Get minting config
        LibCollectionStorage.MintingConfig storage mintConfig = _getMintingConfig(collectionId, tier);
        LibCollectionStorage.MintPricing storage pricing = _getMintingPricing(collectionId, tier);
        
        // Determine status
        string memory status;
        if (!mintConfig.isActive) {
            status = "INACTIVE";
        } else if (block.timestamp < mintConfig.startTime) {
            status = "NOT_STARTED";
        } else if (block.timestamp > mintConfig.endTime) {
            status = "ENDED";
        } else if (mintConfig.currentMints >= mintConfig.maxMints) {
            status = "SOLD_OUT";
        } else {
            status = "ACTIVE";
        }
        
        return CollectionInfo({
            exists: true,
            contractAddress: contractAddress,
            mintingActive: mintConfig.isActive,
            currentMints: mintConfig.currentMints,
            maxMints: mintConfig.maxMints,
            price: pricing.onSale ? pricing.discounted : pricing.regular,
            currency: address(pricing.currency),
            status: status
        });
    }

    /**
     * @notice Check if user can mint
     * @param collectionId Collection ID
     * @param tier Tier
     * @param user User address
     * @return canMint Can user mint
     * @return reason Reason if cannot mint
     */
    function canMint(
        uint256 collectionId,
        uint8 tier,
        address user
    ) external view returns (bool, string memory) {
        
        LibCollectionStorage.MintingConfig storage config = _getMintingConfig(collectionId, tier);
        
        if (!config.isActive) return (false, "INACTIVE");
        if (block.timestamp < config.startTime) return (false, "NOT_STARTED");
        if (block.timestamp > config.endTime) return (false, "ENDED");
        if (config.currentMints >= config.maxMints) return (false, "SOLD_OUT");
        if (_availability(collectionId, tier, user) == 0) return (false, "NO_ALLOCATION");
        
        return (true, "OK");
    }

}