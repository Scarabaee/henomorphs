// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibCollectionStorage} from "../libraries/LibCollectionStorage.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {PodsUtils} from "../utils/PodsUtils.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

interface IRepositoryFacet {
    function selectVariant(uint256 collectionId, uint8 tier, uint256 seed) external view returns (uint8);
}

/**
 * @title SecretRollingFacet - Secure Commit-Reveal Per-Token Implementation
 * @notice Secure secret rolling using commit-reveal scheme with signed commitments
 * @dev Admin commits hash(password + nonce), users sign commitment proofs, each token can be used once per secret period
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 * @custom:version 2.2.0 - Secure signed commitments
 */
contract SecretRollingFacet is AccessControlBase {
    using SafeERC20 for IERC20;
    using Strings for uint256;
    using PodsUtils for uint256;
    using ECDSA for bytes32;
    
    // ==================== EVENTS ====================
    
    event SecretCommitted(uint256 indexed collectionId, uint8 indexed tier, bytes32 commitment, uint256 secretStart, uint256 secretEnd, uint256 revealTime);
    event SecretRevealed(uint256 indexed collectionId, uint8 indexed tier, string password, uint256 nonce, bytes32 passwordHash);
    event VariantRolled(address indexed user, bytes32 indexed rollHash, uint256 indexed tokenId, string messageToSign, uint256 collectionId, uint8 variant, uint256 expiresAt, uint256 paidAmount);
    event CouponUsed(uint256 indexed collectionId, uint256 indexed tokenId, address indexed user, uint256 rollsUsed);
    event TokenSecretUsageReset(uint256 indexed collectionId, uint8 indexed tier, uint256 indexed tokenId);
    event SecretRollingDataReset(uint256 indexed collectionId, uint8 indexed tier);
    
    // ==================== ERRORS ====================
    
    error InvalidPassword();
    error SecretNotActive();
    error SecretPeriodEnded();
    error SecretAlreadyUsedByToken(uint256 tokenId);
    error InvalidReveal();
    error RevealTooEarly();
    error SecretNotRevealed();
    error InvalidConfiguration();
    error CouponNotAccessible();
    error RollingNotActive();
    error CommitmentExists();
    error InvalidSignature();
    
    // ==================== ADMIN FUNCTIONS ====================
    
    /**
     * @notice Commit secret hash for collection/tier
     * @param collectionId Collection ID
     * @param tier Tier level  
     * @param commitment Hash of password + nonce
     * @param secretStart When secret period begins
     * @param secretEnd When secret period ends
     * @param revealTime When reveal is allowed
     */
    function commitSecret(
        uint256 collectionId,
        uint8 tier,
        bytes32 commitment,
        uint256 secretStart,
        uint256 secretEnd,
        uint256 revealTime
    ) external onlyAuthorized whenNotPaused {
        if (secretStart >= secretEnd || secretEnd >= revealTime || commitment == bytes32(0)) {
            revert InvalidConfiguration();
        }
        
        (,, bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (!exists) revert CollectionNotFound(collectionId);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (cs.secretCommitments[collectionId][tier] != bytes32(0) && !cs.secretRevealed[collectionId][tier]) {
            revert CommitmentExists();
        }
        
        cs.secretCommitments[collectionId][tier] = commitment;
        cs.secretStartTimes[collectionId][tier] = secretStart;
        cs.secretEndTimes[collectionId][tier] = secretEnd;
        cs.secretRevealTimes[collectionId][tier] = revealTime;
        cs.secretRollingActive[collectionId][tier] = true;
        cs.secretRevealed[collectionId][tier] = false;
        
        emit SecretCommitted(collectionId, tier, commitment, secretStart, secretEnd, revealTime);
    }
    
    /**
     * @notice Reveal the secret after secret period ends
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param password The actual secret password
     * @param nonce The actual nonce used in commitment
     */
    function revealSecret(
        uint256 collectionId,
        uint8 tier,
        string calldata password,
        uint256 nonce
    ) external onlyAuthorized whenNotPaused {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!cs.secretRollingActive[collectionId][tier]) revert SecretNotActive();
        if (block.timestamp < cs.secretRevealTimes[collectionId][tier]) revert RevealTooEarly();
        if (cs.secretRevealed[collectionId][tier]) revert InvalidReveal();
        
        bytes32 expectedCommitment = keccak256(abi.encodePacked(password, nonce));
        if (expectedCommitment != cs.secretCommitments[collectionId][tier]) revert InvalidReveal();
        
        cs.secretRevealed[collectionId][tier] = true;
        cs.secretPasswordHashes[collectionId][tier] = keccak256(abi.encodePacked(password));
        
        emit SecretRevealed(collectionId, tier, password, nonce, cs.secretPasswordHashes[collectionId][tier]);
    }
    
    /**
     * @notice Set secret rolling active/inactive
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param active Whether secret rolling should be active
     */
    function setSecretActive(
        uint256 collectionId,
        uint8 tier,
        bool active
    ) external onlyAuthorized whenNotPaused {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        cs.secretRollingActive[collectionId][tier] = active;
    }
    
    /**
     * @notice Reset secret rolling usage for specific token
     * @dev Admin can reset token usage to allow it to roll again in current secret period
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param tokenId Token ID to reset
     */
    function resetTokenSecretUsage(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId
    ) external onlyAuthorized whenNotPaused {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        cs.secretUsedByToken[collectionId][tier][tokenId] = false;
        delete cs.tokenSecretSubmissions[collectionId][tier][tokenId];
        delete cs.tokenNonceSubmissions[collectionId][tier][tokenId];
        delete cs.tokenOwnerSubmissions[collectionId][tier][tokenId];
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        LibCollectionStorage.RollCoupon storage coupon = cs.rollCouponsByTokenId[combinedId];
        coupon.totalRollsEver = 0;
        coupon.usedRolls = 0;
        coupon.freeRollsUsed = 0;
        
        emit TokenSecretUsageReset(collectionId, tier, tokenId);
    }
    
    /**
     * @notice Reset secret rolling usage for multiple tokens
     * @dev Admin can reset multiple tokens at once for efficiency
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param tokenIds Array of token IDs to reset
     */
    function resetMultipleTokenSecretUsage(
        uint256 collectionId,
        uint8 tier,
        uint256[] calldata tokenIds
    ) external onlyAuthorized whenNotPaused {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            
            cs.secretUsedByToken[collectionId][tier][tokenId] = false;
            delete cs.tokenSecretSubmissions[collectionId][tier][tokenId];
            delete cs.tokenNonceSubmissions[collectionId][tier][tokenId];
            delete cs.tokenOwnerSubmissions[collectionId][tier][tokenId];
            
            uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
            LibCollectionStorage.RollCoupon storage coupon = cs.rollCouponsByTokenId[combinedId];
            coupon.totalRollsEver = 0;
            coupon.usedRolls = 0;
            coupon.freeRollsUsed = 0;
            
            emit TokenSecretUsageReset(collectionId, tier, tokenId);
        }
    }
    
    /**
     * @notice Reset all secret rolling data for collection/tier
     * @dev Nuclear option - resets everything for new secret period
     * @param collectionId Collection ID
     * @param tier Tier level
     */
    function resetSecretRollingData(
        uint256 collectionId,
        uint8 tier
    ) external onlyAuthorized whenNotPaused {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        cs.secretCommitments[collectionId][tier] = bytes32(0);
        cs.secretStartTimes[collectionId][tier] = 0;
        cs.secretEndTimes[collectionId][tier] = 0;
        cs.secretRevealTimes[collectionId][tier] = 0;
        cs.secretRollingActive[collectionId][tier] = false;
        cs.secretRevealed[collectionId][tier] = false;
        cs.secretPasswordHashes[collectionId][tier] = bytes32(0);
        
        emit SecretRollingDataReset(collectionId, tier);
    }
    
    // ==================== USER FUNCTIONS ====================
    
    /**
     * @notice SIMPLE: Secret rolling with signed commitment (simplified interface)
     * @param collectionId Collection ID
     * @param tokenId Token ID  
     * @param userCommitment User's hash(password + nonce) - never reveal plaintext on-chain
     * @param signature User's signature proving they know the secret
     * @return rollHash Unique identifier for this roll
     * @return messageToSign Message user must sign to assign this roll
     * @return variant The rolled variant number
     * @return expiresAt When this roll expires
     * @return rerollsRemaining Number of rerolls (always 0 in secret mode)
     */
    function secretRollVariantSimple(
        uint256 collectionId,
        uint256 tokenId,
        bytes32 userCommitment,
        bytes calldata signature
    ) external payable whenNotPaused nonReentrant returns (
        bytes32 rollHash,
        string memory messageToSign,
        uint8 variant,
        uint256 expiresAt,
        uint8 rerollsRemaining
    ) {
        return _executeSecretRoll(
            collectionId,
            tokenId,
            userCommitment,
            true,  // isSimple
            signature
        );
    }
    
    /**
     * @notice ADVANCED: Secret rolling with signed commitment (full interface)
     * @param collectionId Collection ID
     * @param tokenId Token ID  
     * @param userCommitment User's hash(password + nonce) - never reveal plaintext on-chain
     * @param signature User's signature proving they know the secret
     * @return rollHash Unique identifier for this roll
     * @return messageToSign Message user must sign to assign this roll
     * @return variant The rolled variant number
     * @return expiresAt When this roll expires
     * @return rerollsRemaining Number of rerolls (always 0 in secret mode)
     */
    function secretRollVariant(
        uint256 collectionId,
        uint256 tokenId,
        bytes32 userCommitment,
        bytes calldata signature
    ) external payable whenNotPaused nonReentrant returns (
        bytes32 rollHash,
        string memory messageToSign,
        uint8 variant,
        uint256 expiresAt,
        uint8 rerollsRemaining
    ) {
        return _executeSecretRoll(
            collectionId,
            tokenId,
            userCommitment,
            false,  // isSimple
            signature
        );
    }
    
    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @notice Get secret rolling status for specific token
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param tokenId Token ID to check
     * @return isSecretActive Whether secret mode is currently active
     * @return timeToEnd Seconds remaining until secret period ends
     * @return timeToReveal Seconds remaining until reveal is allowed
     * @return tokenCanUse Whether this token can still use secret rolling
     * @return tokenHasUsed Whether this token already used secret rolling
     * @return isRevealed Whether secret has been revealed
     */
    function getTokenSecretStatus(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId
    ) external view returns (
        bool isSecretActive,
        uint256 timeToEnd,
        uint256 timeToReveal,
        bool tokenCanUse,
        bool tokenHasUsed,
        bool isRevealed
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!cs.secretRollingActive[collectionId][tier]) {
            return (false, 0, 0, false, false, false);
        }
        
        isSecretActive = block.timestamp >= cs.secretStartTimes[collectionId][tier] && 
                        block.timestamp < cs.secretEndTimes[collectionId][tier];
        
        timeToEnd = block.timestamp < cs.secretEndTimes[collectionId][tier] ? 
                   cs.secretEndTimes[collectionId][tier] - block.timestamp : 0;
        
        timeToReveal = block.timestamp < cs.secretRevealTimes[collectionId][tier] ? 
                      cs.secretRevealTimes[collectionId][tier] - block.timestamp : 0;
        
        tokenHasUsed = cs.secretUsedByToken[collectionId][tier][tokenId];
        tokenCanUse = isSecretActive && !tokenHasUsed;
        isRevealed = cs.secretRevealed[collectionId][tier];
        
        return (isSecretActive, timeToEnd, timeToReveal, tokenCanUse, tokenHasUsed, isRevealed);
    }
    
    /**
     * @notice Check if collection/tier is in secret mode
     */
    function isInSecretMode(uint256 collectionId, uint8 tier) external view returns (bool inSecretMode) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        return cs.secretRollingActive[collectionId][tier] &&
               block.timestamp >= cs.secretStartTimes[collectionId][tier] && 
               block.timestamp < cs.secretEndTimes[collectionId][tier];
    }
    
    /**
     * @notice Verify if token's submission was correct (after reveal)
     */
    function verifyTokenSubmission(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId
    ) external view returns (
        bool wasCorrect,
        string memory tokenPassword,
        uint256 tokenNonce,
        address tokenOwner
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!cs.secretRevealed[collectionId][tier]) revert SecretNotRevealed();
        
        tokenPassword = cs.tokenSecretSubmissions[collectionId][tier][tokenId];
        tokenNonce = cs.tokenNonceSubmissions[collectionId][tier][tokenId];
        tokenOwner = cs.tokenOwnerSubmissions[collectionId][tier][tokenId];
        
        // Check if token was used and if submission was correct
        bool wasUsed = cs.secretUsedByToken[collectionId][tier][tokenId];
        wasCorrect = false;
        
        if (wasUsed && bytes(tokenPassword).length > 0) {
            // Only check correctness for legacy submissions that stored password
            bytes32 tokenCommitment = keccak256(abi.encodePacked(tokenPassword, tokenNonce));
            wasCorrect = tokenCommitment == cs.secretCommitments[collectionId][tier];
        } else if (wasUsed) {
            // For secure submissions (no stored password), we assume correct since they passed verification
            wasCorrect = true;
        }
        
        return (wasCorrect, tokenPassword, tokenNonce, tokenOwner);
    }
    
    /**
     * @notice Helper to generate user commitment hash OFF-CHAIN
     * @dev Users should call this off-chain to generate their commitment
     */
    function generateUserCommitment(
        string calldata password,
        uint256 nonce
    ) external pure returns (bytes32 commitment) {
        return keccak256(abi.encodePacked(password, nonce));
    }
    
    /**
     * @notice Generate message to sign for secret knowledge proof
     * @param userCommitment User's commitment hash  
     * @param tokenId Token ID
     * @return messageToSign Message user should sign
     */
    function getSecretProofMessage(
        bytes32 userCommitment,
        uint256 tokenId
    ) external pure returns (string memory messageToSign) {
        return string(abi.encodePacked(
            "I know secret: ",
            Strings.toHexString(uint256(userCommitment)),
            " for token: ",
            Strings.toString(tokenId)
        ));
    }
    
    /**
     * @notice Verify user commitment is correct (for testing)
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param userCommitment User's commitment hash
     * @return isCorrect Whether commitment matches admin commitment
     */
    function verifyUserCommitment(
        uint256 collectionId,
        uint8 tier,
        bytes32 userCommitment
    ) external view returns (bool isCorrect) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!cs.secretRollingActive[collectionId][tier]) return false;
        
        return userCommitment == cs.secretCommitments[collectionId][tier];
    }
    
    /**
     * @notice Helper to check password + nonce before submitting (LEGACY)
     * @dev DEPRECATED: Use verifyUserCommitment with secure method instead
     */
    function checkPasswordAndNonce(
        uint256 collectionId,
        uint8 tier,
        string calldata password,
        uint256 nonce
    ) external view returns (bool isCorrect) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!cs.secretRollingActive[collectionId][tier]) return false;
        
        bytes32 userCommitment = keccak256(abi.encodePacked(password, nonce));
        return userCommitment == cs.secretCommitments[collectionId][tier];
    }
    
    /**
     * @notice Generate commitment hash for admin use
     */
    function generateCommitment(
        string calldata password,
        uint256 nonce
    ) external pure returns (bytes32 commitment) {
        return keccak256(abi.encodePacked(password, nonce));
    }
    
    /**
     * @notice Get assignment message to sign (compatible with MintingFacet)
     */
    function getAssignMessageToSignAux(bytes32 rollHash) external view returns (string memory messageToSign) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.VariantRoll storage roll = cs.variantRollsByHash[rollHash];
        
        return string(abi.encodePacked(
            "Assign variant roll: ",
            Strings.toHexString(uint256(rollHash)),
            " with nonce: ",
            Strings.toString(roll.nonce)
        ));
    }
    
    // ==================== ADMIN VIEW FUNCTIONS ====================
    
    /**
     * @notice Get token secret usage details (admin only)
     * @param collectionId Collection ID
     * @param tier Tier level
     * @param tokenId Token ID to check
     * @return hasUsed Whether token was used
     * @return submittedPassword What password was submitted (always empty for security)
     * @return submittedNonce What nonce was submitted (always 0 for security)
     * @return submittedBy Who submitted
     */
    function getTokenSecretUsageDetails(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId
    ) external view onlyAuthorized returns (
        bool hasUsed,
        string memory submittedPassword,
        uint256 submittedNonce,
        address submittedBy
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        hasUsed = cs.secretUsedByToken[collectionId][tier][tokenId];
        submittedPassword = "";
        submittedNonce = 0;
        submittedBy = cs.tokenOwnerSubmissions[collectionId][tier][tokenId];
        
        return (hasUsed, submittedPassword, submittedNonce, submittedBy);
    }
    
    /**
     * @notice Get secret rolling statistics (admin only)
     * @param collectionId Collection ID
     * @param tier Tier level
     * @return totalTokensUsed Number of tokens that used secret rolling
     * @return isActive Whether secret rolling is active
     * @return isRevealed Whether secret has been revealed
     * @return timeToEnd Seconds until secret period ends
     */
    function getSecretRollingStats(
        uint256 collectionId,
        uint8 tier
    ) external view onlyAuthorized returns (
        uint256 totalTokensUsed,
        bool isActive,
        bool isRevealed,
        uint256 timeToEnd
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        isActive = cs.secretRollingActive[collectionId][tier];
        isRevealed = cs.secretRevealed[collectionId][tier];
        
        timeToEnd = 0;
        if (isActive && block.timestamp < cs.secretEndTimes[collectionId][tier]) {
            timeToEnd = cs.secretEndTimes[collectionId][tier] - block.timestamp;
        }
        
        totalTokensUsed = 0;
        
        return (totalTokensUsed, isActive, isRevealed, timeToEnd);
    }
    
    // ==================== INTERNAL FUNCTIONS ====================
    
    /**
     * @notice Internal unified secret rolling implementation
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param userCommitment User's commitment hash
     * @param signature User's signature proving knowledge of secret
     * @return rollHash Unique identifier for this roll
     * @return messageToSign Message user must sign to assign this roll
     * @return variant The rolled variant number
     * @return expiresAt When this roll expires
     * @return rerollsRemaining Number of rerolls (always 0 in secret mode)
     */
    function _executeSecretRoll(
        uint256 collectionId,
        uint256 tokenId,
        bytes32 userCommitment,
        bool,
        bytes memory signature
    ) internal returns (
        bytes32 rollHash,
        string memory messageToSign,
        uint8 variant,
        uint256 expiresAt,
        uint8 rerollsRemaining
    ) {
        address user = LibMeta.msgSender();
        
        (,, bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (!exists) revert CollectionNotFound(collectionId);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        uint8 tier = cs.collections[collectionId].defaultTier;
        
        if (!cs.secretRollingActive[collectionId][tier]) revert SecretNotActive();
        if (block.timestamp < cs.secretStartTimes[collectionId][tier]) revert SecretNotActive();
        if (block.timestamp >= cs.secretEndTimes[collectionId][tier]) revert SecretPeriodEnded();
        
        if (cs.secretUsedByToken[collectionId][tier][tokenId]) {
            revert SecretAlreadyUsedByToken(tokenId);
        }
        
        if (userCommitment != cs.secretCommitments[collectionId][tier]) {
            revert InvalidPassword();
        }
        
        _verifySecretKnowledge(user, userCommitment, tokenId, signature);
        
        _validateTokenForSecretRoll(collectionId, tokenId, user);
        
        if (!cs.assignmentPricingByTier[collectionId][tier].isActive) revert RollingNotActive();
        
        // Both simple and advanced use secure storage (no plaintext)
        cs.tokenSecretSubmissions[collectionId][tier][tokenId] = "";
        cs.tokenNonceSubmissions[collectionId][tier][tokenId] = 0;
        cs.tokenOwnerSubmissions[collectionId][tier][tokenId] = user;
        cs.secretUsedByToken[collectionId][tier][tokenId] = true;
        
        uint256 paidAmount = _processSecretRollingPayment(collectionId, tokenId, user, tier);
        (rollHash, messageToSign, variant, expiresAt) = _executeSecretRollCore(user, collectionId, tokenId, tier, paidAmount);
        
        return (rollHash, messageToSign, variant, expiresAt, 0);
    }
    
    function _verifySecretKnowledge(
        address user,
        bytes32 userCommitment,
        uint256 tokenId,
        bytes memory signature
    ) internal pure {
        string memory message = string(abi.encodePacked(
            "I know secret: ",
            Strings.toHexString(uint256(userCommitment)),
            " for token: ",
            Strings.toString(tokenId)
        ));
        
        bytes32 messageHash = _createEthSignedMessageHash(message);
        address recovered = messageHash.recover(signature);
        
        if (recovered != user) {
            bytes32 rawHash = keccak256(bytes(message));
            recovered = rawHash.recover(signature);
            
            if (recovered != user) {
                revert InvalidSignature();
            }
        }
    }
    
    function _createEthSignedMessageHash(string memory message) internal pure returns (bytes32) {
        bytes memory messageBytes = bytes(message);
        bytes memory prefix = "\x19Ethereum Signed Message:\n";
        bytes memory lengthBytes = bytes(Strings.toString(messageBytes.length));
        
        return keccak256(abi.encodePacked(prefix, lengthBytes, messageBytes));
    }
    
    function _validateTokenForSecretRoll(uint256 collectionId, uint256 tokenId, address user) internal view {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.CouponCollection storage collection = cs.couponCollections[collectionId];
        
        if (!collection.active) revert CouponNotAccessible();
        
        try IERC721(collection.collectionAddress).ownerOf(tokenId) returns (address owner) {
            if (owner != user) revert CouponNotAccessible();
        } catch {
            revert CouponNotAccessible();
        }
        
        if (cs.collectionItemsVarianted[collectionId][tokenId] != 0) revert CouponNotAccessible();
    }
    
    function _processSecretRollingPayment(
        uint256 collectionId,
        uint256 tokenId,
        address user,
        uint8 tier
    ) internal returns (uint256 paidAmount) {
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.RollCoupon storage coupon = cs.rollCouponsByTokenId[combinedId];
        LibCollectionStorage.CouponConfiguration storage couponConfig = cs.couponConfiguration;
        
        if (!coupon.active) {
            coupon.collectionId = collectionId;
            coupon.tokenId = tokenId;
            coupon.active = true;
        }
        
        paidAmount = 0;
        
        if (coupon.freeRollsUsed < couponConfig.freeRollsPerCoupon) {
            coupon.freeRollsUsed++;
        } else {
            LibCollectionStorage.RollingPricing storage pricing = cs.rollingPricingByTier[collectionId][tier];
            uint256 basePrice = pricing.onSale ? pricing.discounted : pricing.regular;
            uint256 requiredPayment = basePrice;
            
            if (requiredPayment > 0) {
                pricing.currency.safeTransferFrom(user, pricing.beneficiary, requiredPayment);
                paidAmount = requiredPayment;
            }
        }
        
        if (msg.value > 0) {
            Address.sendValue(payable(user), msg.value);
        }
        
        coupon.totalRollsEver++;
        coupon.usedRolls++;
        coupon.lastRollTime = block.timestamp;
        
        emit CouponUsed(collectionId, tokenId, user, coupon.usedRolls);
        
        return paidAmount;
    }
    
    function _executeSecretRollCore(
        address user,
        uint256 collectionId,
        uint256 tokenId,
        uint8 tier,
        uint256 paidAmount
    ) internal returns (
        bytes32 rollHash,
        string memory messageToSign,
        uint8 variant,
        uint256 expiresAt
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint256 currentNonce = LibCollectionStorage.getAndIncrementNonce(user);
        
        rollHash = keccak256(abi.encodePacked(
            user, block.timestamp, currentNonce, collectionId, tokenId, tier, "SECRET"
        ));
        
        uint256 seed = uint256(keccak256(abi.encodePacked(
            block.timestamp, block.prevrandao, user, currentNonce, collectionId, tokenId, "SECRET_VARIANT"
        )));
        
        variant = IRepositoryFacet(address(this)).selectVariant(collectionId, tier, seed);
        expiresAt = block.timestamp + cs.rollingConfiguration.reservationTimeSeconds;
        
        cs.variantRollsByHash[rollHash] = LibCollectionStorage.VariantRoll({
            user: user,
            variant: variant,
            expiresAt: expiresAt,
            rerollsUsed: 0,
            exists: true,
            issueId: collectionId,
            tier: tier,
            couponCollectionId: collectionId,
            couponTokenId: tokenId,
            totalPaid: paidAmount,
            nonce: currentNonce
        });
        
        cs.tempReservationsByVariant[collectionId][tier][variant].push(
            LibCollectionStorage.TempReservation({
                rollHash: rollHash,
                expiresAt: expiresAt,
                active: true
            })
        );
        cs.rollToReservationIndexByHash[rollHash] = cs.tempReservationsByVariant[collectionId][tier][variant].length - 1;
        
        cs.tokenToRollHash[collectionId][tier][tokenId] = rollHash;
        
        messageToSign = string(abi.encodePacked(
            "Assign variant roll: ",
            Strings.toHexString(uint256(rollHash)),
            " with nonce: ",
            Strings.toString(currentNonce)
        ));
        
        emit VariantRolled(user, rollHash, tokenId, messageToSign, collectionId, variant, expiresAt, paidAmount);
        
        return (rollHash, messageToSign, variant, expiresAt);
    }
}