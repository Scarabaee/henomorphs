// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMissionStorage} from "../libraries/LibMissionStorage.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibFeeCollection} from "../../staking/libraries/LibFeeCollection.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MissionPassLendingFacet
 * @notice Lending/rental system for Mission Pass NFTs (inspired by ERC-4907 + Delegate.xyz)
 * @dev Implements collateral-free rental with auto-expiry, flat fee and revenue share modes
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 *
 * Key Features:
 * - Auto-expiry: delegateeOf() returns address(0) when delegation expires (ERC-4907 pattern)
 * - No NFT transfer: Owner keeps NFT, only usage rights are delegated (Delegate.xyz pattern)
 * - Flat fee OR revenue share modes (inspired by UnitBox GameFi)
 * - Optional collateral (inspired by ReNFT)
 * - Escrow for payments and collateral
 */
contract MissionPassLendingFacet is AccessControlBase {
    using SafeERC20 for IERC20;

    // ============================================================
    // EVENTS (ERC-4907 inspired naming)
    // ============================================================

    event PassDelegated(
        uint16 indexed collectionId,
        uint256 indexed tokenId,
        address indexed delegatee,
        uint64 expires,
        uint16 usesAllowed
    );

    event PassDelegationRevoked(
        uint16 indexed collectionId,
        uint256 indexed tokenId
    );

    event LendingOfferCreated(
        uint16 indexed collectionId,
        uint256 indexed tokenId,
        address indexed owner,
        uint96 flatFeePerUse,
        uint16 rewardShareBps
    );

    event LendingOfferCancelled(
        uint16 indexed collectionId,
        uint256 indexed tokenId
    );

    event LendingOfferAccepted(
        uint16 indexed collectionId,
        uint256 indexed tokenId,
        address indexed borrower,
        uint16 usesRented,
        uint64 expires,
        uint256 totalFee,
        uint256 collateralDeposited
    );

    event CollateralClaimed(
        uint16 indexed collectionId,
        uint256 indexed tokenId,
        address indexed claimer,
        uint256 amount
    );

    event CollateralReturned(
        uint16 indexed collectionId,
        uint256 indexed tokenId,
        address indexed borrower,
        uint256 amount
    );

    event EarningsWithdrawn(address indexed user, uint256 amount);

    // NOTE: RewardShareDistributed event moved to MissionFacet as LenderRewardShareDeposited
    // Revenue share is handled internally by MissionFacet._distributeRewardsWithRevenueShare()

    // ============================================================
    // ERRORS
    // ============================================================

    error LendingSystemPaused();
    error LendingNotEnabled();
    error NotPassOwner(uint16 collectionId, uint256 tokenId, address caller);
    error PassAlreadyDelegated(uint16 collectionId, uint256 tokenId);
    error OfferNotActive(uint16 collectionId, uint256 tokenId);
    error OfferExpired(uint16 collectionId, uint256 tokenId);
    error InvalidDuration(uint32 requested, uint32 min, uint32 max);
    error InvalidUsesCount(uint16 requested, uint16 min, uint16 max);
    error InsufficientPayment(uint256 required, uint256 provided);
    error InsufficientCollateral(uint256 required, uint256 provided);
    error DelegationNotExpired(uint16 collectionId, uint256 tokenId);
    error DelegationExpired(uint16 collectionId, uint256 tokenId);
    error NotDelegatee(uint16 collectionId, uint256 tokenId, address caller);
    error NotLender(uint16 collectionId, uint256 tokenId, address caller);
    error NoCollateralDeposited(uint16 collectionId, uint256 tokenId);
    error CollateralAlreadyReturned(uint16 collectionId, uint256 tokenId);
    error NoEarningsToWithdraw(address user);
    error CannotDelegateToSelf();
    error CannotDelegateToZero();
    error RewardShareTooHigh(uint16 requested, uint16 max);
    error ZeroUses();
    error ZeroDuration();
    error InvalidCollectionId(uint16 collectionId);

    // ============================================================
    // INPUT STRUCTS (to avoid stack too deep)
    // ============================================================

    /**
     * @notice Parameters for listing a pass for lending
     */
    struct ListPassParams {
        uint16 collectionId;
        uint256 tokenId;
        uint96 flatFeePerUse;
        uint16 rewardShareBps;
        uint32 minDuration;
        uint32 maxDuration;
        uint16 minUses;
        uint16 maxUses;
        uint64 offerExpires;
        uint96 collateralRequired;
    }

    // ============================================================
    // MODIFIERS
    // ============================================================

    modifier whenLendingActive() {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        if (ms.lendingSystemPaused) {
            revert LendingSystemPaused();
        }
        if (!ms.lendingConfig.enabled) {
            revert LendingNotEnabled();
        }
        _;
    }

    // ============================================================
    // CORE DELEGATION FUNCTIONS (ERC-4907 pattern)
    // ============================================================

    /**
     * @notice Directly delegate pass to another address (no marketplace)
     * @dev Owner can delegate without creating a listing first
     * @param collectionId Mission Pass collection ID
     * @param tokenId Token ID
     * @param delegatee Address receiving usage rights
     * @param expires Unix timestamp when delegation expires
     * @param usesAllowed Maximum uses allowed (0 = unlimited within time)
     */
    function delegateMissionPass(
        uint16 collectionId,
        uint256 tokenId,
        address delegatee,
        uint64 expires,
        uint16 usesAllowed
    ) external whenNotPaused whenLendingActive nonReentrant {
        if (delegatee == address(0)) {
            revert CannotDelegateToZero();
        }

        address caller = LibMeta.msgSender();
        if (delegatee == caller) {
            revert CannotDelegateToSelf();
        }

        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        // Validate collection
        if (collectionId == 0 || collectionId > ms.passCollectionCounter) {
            revert InvalidCollectionId(collectionId);
        }

        // Verify ownership
        address nftOwner = IERC721(ms.passCollections[collectionId].collectionAddress).ownerOf(tokenId);
        if (nftOwner != caller) {
            revert NotPassOwner(collectionId, tokenId, caller);
        }

        // Check not already delegated (active delegation)
        LibMissionStorage.PassDelegation storage delegation = ms.passDelegations[collectionId][tokenId];
        if (delegation.delegatee != address(0) && block.timestamp < delegation.expires) {
            revert PassAlreadyDelegated(collectionId, tokenId);
        }

        // Validate duration
        if (expires <= block.timestamp) {
            revert ZeroDuration();
        }

        // Create delegation
        delegation.delegatee = delegatee;
        delegation.expires = expires;
        delegation.usesAllowed = usesAllowed;
        delegation.usesConsumed = 0;
        delegation.flatFeeTotal = 0;
        delegation.rewardShareBps = 0;
        delegation.collateralAmount = 0;
        delegation.collateralReturned = false;
        delegation.lender = caller;
        delegation.autoRenewDeposit = 0;

        emit PassDelegated(collectionId, tokenId, delegatee, expires, usesAllowed);
    }

    /**
     * @notice Revoke delegation before expiry (only owner)
     * @dev Can only revoke if delegation exists and is active
     * @param collectionId Mission Pass collection ID
     * @param tokenId Token ID
     */
    function revokeMissionPassDelegation(
        uint16 collectionId,
        uint256 tokenId
    ) external whenNotPaused nonReentrant {
        address caller = LibMeta.msgSender();
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        // Verify ownership
        address nftOwner = IERC721(ms.passCollections[collectionId].collectionAddress).ownerOf(tokenId);
        if (nftOwner != caller) {
            revert NotPassOwner(collectionId, tokenId, caller);
        }

        LibMissionStorage.PassDelegation storage delegation = ms.passDelegations[collectionId][tokenId];

        // Must have active delegation
        if (delegation.delegatee == address(0) || block.timestamp >= delegation.expires) {
            revert DelegationExpired(collectionId, tokenId);
        }

        // Return collateral to borrower if any
        if (delegation.collateralAmount > 0 && !delegation.collateralReturned) {
            ms.collateralHeldBalance[delegation.delegatee] += delegation.collateralAmount;
            delegation.collateralReturned = true;
        }

        // Clear delegation
        delegation.delegatee = address(0);
        delegation.expires = 0;

        emit PassDelegationRevoked(collectionId, tokenId);
    }

    /**
     * @notice Get current delegatee (returns address(0) if expired - ERC-4907 pattern)
     * @param collectionId Mission Pass collection ID
     * @param tokenId Token ID
     * @return delegatee Current delegatee or address(0) if none/expired
     */
    function missionPassDelegateeOf(uint16 collectionId, uint256 tokenId)
        external
        view
        returns (address delegatee)
    {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.PassDelegation storage delegation = ms.passDelegations[collectionId][tokenId];

        // Auto-expiry: return 0 if expired (ERC-4907 pattern)
        if (block.timestamp >= delegation.expires) {
            return address(0);
        }

        return delegation.delegatee;
    }

    /**
     * @notice Get delegation expiry timestamp
     * @param collectionId Mission Pass collection ID
     * @param tokenId Token ID
     * @return expires Expiry timestamp (0 if no delegation)
     */
    function missionPassDelegationExpires(uint16 collectionId, uint256 tokenId)
        external
        view
        returns (uint64 expires)
    {
        return LibMissionStorage.missionStorage().passDelegations[collectionId][tokenId].expires;
    }

    // ============================================================
    // MARKETPLACE FUNCTIONS
    // ============================================================

    /**
     * @notice List Mission Pass for lending
     * @param params Listing parameters struct
     */
    function listMissionPassForLending(
        ListPassParams calldata params
    ) external whenNotPaused whenLendingActive nonReentrant {
        address caller = LibMeta.msgSender();

        // Validate and create offer
        _validateAndCreateOffer(params, caller);

        emit LendingOfferCreated(
            params.collectionId,
            params.tokenId,
            caller,
            params.flatFeePerUse,
            params.rewardShareBps
        );
    }

    /**
     * @dev Internal function to validate and create lending offer
     */
    function _validateAndCreateOffer(
        ListPassParams calldata params,
        address caller
    ) internal {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        // Validate collection
        if (params.collectionId == 0 || params.collectionId > ms.passCollectionCounter) {
            revert InvalidCollectionId(params.collectionId);
        }

        // Verify ownership
        address nftOwner = IERC721(ms.passCollections[params.collectionId].collectionAddress).ownerOf(params.tokenId);
        if (nftOwner != caller) {
            revert NotPassOwner(params.collectionId, params.tokenId, caller);
        }

        // Check not already delegated
        LibMissionStorage.PassDelegation storage delegation = ms.passDelegations[params.collectionId][params.tokenId];
        if (delegation.delegatee != address(0) && block.timestamp < delegation.expires) {
            revert PassAlreadyDelegated(params.collectionId, params.tokenId);
        }

        // Validate parameters against global config
        LibMissionStorage.LendingConfig storage config = ms.lendingConfig;

        if (params.minDuration < config.minDuration || params.maxDuration > config.maxDuration) {
            revert InvalidDuration(params.minDuration, config.minDuration, config.maxDuration);
        }
        if (params.minDuration > params.maxDuration) {
            revert InvalidDuration(params.minDuration, params.minDuration, params.maxDuration);
        }
        if (params.rewardShareBps > config.maxRewardShareBps) {
            revert RewardShareTooHigh(params.rewardShareBps, config.maxRewardShareBps);
        }
        if (params.minUses > params.maxUses || params.maxUses == 0) {
            revert InvalidUsesCount(params.minUses, params.minUses, params.maxUses);
        }

        // Create offer
        ms.passLendingOffers[params.collectionId][params.tokenId] = LibMissionStorage.PassLendingOffer({
            owner: caller,
            flatFeePerUse: params.flatFeePerUse,
            rewardShareBps: params.rewardShareBps,
            minDuration: params.minDuration,
            maxDuration: params.maxDuration,
            minUses: params.minUses,
            maxUses: params.maxUses,
            offerExpires: params.offerExpires,
            collateralRequired: params.collateralRequired,
            active: true
        });
    }

    /**
     * @notice Cancel a lending offer
     * @param collectionId Mission Pass collection ID
     * @param tokenId Token ID
     */
    function cancelPassLendingOffer(
        uint16 collectionId,
        uint256 tokenId
    ) external whenNotPaused nonReentrant {
        address caller = LibMeta.msgSender();
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        LibMissionStorage.PassLendingOffer storage offer = ms.passLendingOffers[collectionId][tokenId];

        if (offer.owner != caller) {
            revert NotPassOwner(collectionId, tokenId, caller);
        }
        if (!offer.active) {
            revert OfferNotActive(collectionId, tokenId);
        }

        offer.active = false;

        emit LendingOfferCancelled(collectionId, tokenId);
    }

    /**
     * @notice Accept a lending offer and become delegatee
     * @param collectionId Mission Pass collection ID
     * @param tokenId Token ID
     * @param usesRequested Number of uses to rent
     * @param durationSeconds Rental duration in seconds
     */
    function acceptPassLendingOffer(
        uint16 collectionId,
        uint256 tokenId,
        uint16 usesRequested,
        uint32 durationSeconds
    ) external whenNotPaused whenLendingActive nonReentrant {
        address borrower = LibMeta.msgSender();

        // Validate and get offer/delegation references
        (
            LibMissionStorage.PassLendingOffer storage offer,
            LibMissionStorage.PassDelegation storage delegation,
            LibMissionStorage.LendingConfig storage config
        ) = _validateAcceptOffer(collectionId, tokenId, borrower, usesRequested, durationSeconds);

        // Process payments and create delegation
        (uint256 totalFee, uint256 collateralDeposited, uint64 expires) = _processAcceptPayments(
            offer, delegation, config, borrower, usesRequested, durationSeconds
        );

        // Deactivate offer after acceptance
        offer.active = false;

        emit LendingOfferAccepted(
            collectionId,
            tokenId,
            borrower,
            usesRequested,
            expires,
            totalFee,
            collateralDeposited
        );

        emit PassDelegated(collectionId, tokenId, borrower, expires, usesRequested);
    }

    /**
     * @dev Validate accept offer parameters
     */
    function _validateAcceptOffer(
        uint16 collectionId,
        uint256 tokenId,
        address borrower,
        uint16 usesRequested,
        uint32 durationSeconds
    ) internal view returns (
        LibMissionStorage.PassLendingOffer storage offer,
        LibMissionStorage.PassDelegation storage delegation,
        LibMissionStorage.LendingConfig storage config
    ) {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        offer = ms.passLendingOffers[collectionId][tokenId];
        delegation = ms.passDelegations[collectionId][tokenId];
        config = ms.lendingConfig;

        // Validate offer
        if (!offer.active) {
            revert OfferNotActive(collectionId, tokenId);
        }
        if (block.timestamp >= offer.offerExpires) {
            revert OfferExpired(collectionId, tokenId);
        }
        if (borrower == offer.owner) {
            revert CannotDelegateToSelf();
        }

        // Validate parameters
        if (usesRequested < offer.minUses || usesRequested > offer.maxUses) {
            revert InvalidUsesCount(usesRequested, offer.minUses, offer.maxUses);
        }
        if (durationSeconds < offer.minDuration || durationSeconds > offer.maxDuration) {
            revert InvalidDuration(durationSeconds, offer.minDuration, offer.maxDuration);
        }

        // Check pass not already delegated
        if (delegation.delegatee != address(0) && block.timestamp < delegation.expires) {
            revert PassAlreadyDelegated(collectionId, tokenId);
        }
    }

    /**
     * @dev Process payments and create delegation for accepted offer
     */
    function _processAcceptPayments(
        LibMissionStorage.PassLendingOffer storage offer,
        LibMissionStorage.PassDelegation storage delegation,
        LibMissionStorage.LendingConfig storage config,
        address borrower,
        uint16 usesRequested,
        uint32 durationSeconds
    ) internal returns (uint256 totalFee, uint256 collateralDeposited, uint64 expires) {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        // Flat fee payment
        if (offer.flatFeePerUse > 0) {
            totalFee = uint256(offer.flatFeePerUse) * usesRequested;
            uint256 platformFee = (totalFee * config.platformFeeBps) / 10000;
            uint256 lenderFee = totalFee - platformFee;

            // Platform fee - use LibFeeCollection for consistent handling
            if (platformFee > 0) {
                if (config.burnPlatformFee) {
                    // Burn platform fee (for YLW auxiliary token)
                    LibFeeCollection.collectAndBurnFee(
                        IERC20(config.paymentToken),
                        borrower,
                        config.beneficiary,
                        platformFee,
                        "pass_lending_platform_fee"
                    );
                } else {
                    // Transfer platform fee to beneficiary
                    LibFeeCollection.collectFee(
                        IERC20(config.paymentToken),
                        borrower,
                        config.beneficiary,
                        platformFee,
                        "pass_lending_platform_fee"
                    );
                }
            }

            // Lender fee to escrow
            ms.lendingEscrowBalance[offer.owner] += lenderFee;
            IERC20(config.paymentToken).safeTransferFrom(borrower, address(this), lenderFee);
        }

        // Collateral
        if (offer.collateralRequired > 0) {
            collateralDeposited = offer.collateralRequired;
            IERC20(config.paymentToken).safeTransferFrom(borrower, address(this), collateralDeposited);
        }

        // Create delegation
        expires = uint64(block.timestamp + durationSeconds);

        delegation.delegatee = borrower;
        delegation.expires = expires;
        delegation.usesAllowed = usesRequested;
        delegation.usesConsumed = 0;
        delegation.flatFeeTotal = uint96(totalFee);
        delegation.rewardShareBps = offer.rewardShareBps;
        delegation.collateralAmount = uint96(collateralDeposited);
        delegation.collateralReturned = false;
        delegation.lender = offer.owner;
        delegation.autoRenewDeposit = 0;
    }

    // ============================================================
    // COLLATERAL FUNCTIONS
    // ============================================================

    /**
     * @notice Borrower returns pass and claims collateral before expiry
     * @param collectionId Mission Pass collection ID
     * @param tokenId Token ID
     */
    function returnPassAndClaimCollateral(
        uint16 collectionId,
        uint256 tokenId
    ) external whenNotPaused nonReentrant {
        address caller = LibMeta.msgSender();
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.PassDelegation storage delegation = ms.passDelegations[collectionId][tokenId];

        // Must be current delegatee
        if (delegation.delegatee != caller) {
            revert NotDelegatee(collectionId, tokenId, caller);
        }

        // Must not be expired
        if (block.timestamp >= delegation.expires) {
            revert DelegationExpired(collectionId, tokenId);
        }

        // Must have collateral
        if (delegation.collateralAmount == 0) {
            revert NoCollateralDeposited(collectionId, tokenId);
        }

        if (delegation.collateralReturned) {
            revert CollateralAlreadyReturned(collectionId, tokenId);
        }

        // Return collateral to borrower's balance
        uint96 collateralAmount = delegation.collateralAmount;
        delegation.collateralReturned = true;
        ms.collateralHeldBalance[caller] += collateralAmount;

        // Clear delegation (early return)
        delegation.delegatee = address(0);
        delegation.expires = 0;

        emit CollateralReturned(collectionId, tokenId, caller, collateralAmount);
        emit PassDelegationRevoked(collectionId, tokenId);
    }

    /**
     * @notice Lender claims collateral after delegation expired without return
     * @dev Only available after expiry if collateral wasn't returned
     * @param collectionId Mission Pass collection ID
     * @param tokenId Token ID
     */
    function claimPassLendingCollateral(
        uint16 collectionId,
        uint256 tokenId
    ) external whenNotPaused nonReentrant {
        address caller = LibMeta.msgSender();
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.PassDelegation storage delegation = ms.passDelegations[collectionId][tokenId];

        // Must be lender
        if (delegation.lender != caller) {
            revert NotLender(collectionId, tokenId, caller);
        }

        // Must be expired
        if (block.timestamp < delegation.expires) {
            revert DelegationNotExpired(collectionId, tokenId);
        }

        // Must have unreturned collateral
        if (delegation.collateralAmount == 0) {
            revert NoCollateralDeposited(collectionId, tokenId);
        }

        if (delegation.collateralReturned) {
            revert CollateralAlreadyReturned(collectionId, tokenId);
        }

        // Transfer collateral to lender's balance
        uint96 collateralAmount = delegation.collateralAmount;
        delegation.collateralReturned = true;
        ms.lendingEscrowBalance[caller] += collateralAmount;

        emit CollateralClaimed(collectionId, tokenId, caller, collateralAmount);
    }

    // ============================================================
    // ESCROW & WITHDRAWAL FUNCTIONS
    // ============================================================

    /**
     * @notice Withdraw accumulated earnings from pass lending escrow
     */
    function withdrawPassLendingEarnings() external whenNotPaused nonReentrant {
        address caller = LibMeta.msgSender();
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        uint256 earnings = ms.lendingEscrowBalance[caller];
        if (earnings == 0) {
            revert NoEarningsToWithdraw(caller);
        }

        ms.lendingEscrowBalance[caller] = 0;
        IERC20(ms.lendingConfig.paymentToken).safeTransfer(caller, earnings);

        emit EarningsWithdrawn(caller, earnings);
    }

    /**
     * @notice Withdraw returned collateral from pass lending
     */
    function withdrawPassLendingCollateral() external whenNotPaused nonReentrant {
        address caller = LibMeta.msgSender();
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        uint256 collateral = ms.collateralHeldBalance[caller];
        if (collateral == 0) {
            revert NoEarningsToWithdraw(caller);
        }

        ms.collateralHeldBalance[caller] = 0;
        IERC20(ms.lendingConfig.paymentToken).safeTransfer(caller, collateral);

        emit EarningsWithdrawn(caller, collateral);
    }

    /**
     * @notice Get user's pass lending escrow balance
     * @param user User address
     * @return balance Escrow balance
     */
    function getPassLendingEscrowBalance(address user) external view returns (uint256 balance) {
        return LibMissionStorage.missionStorage().lendingEscrowBalance[user];
    }

    /**
     * @notice Get user's pass lending collateral balance (available for withdrawal)
     * @param user User address
     * @return balance Collateral balance
     */
    function getPassLendingCollateralBalance(address user) external view returns (uint256 balance) {
        return LibMissionStorage.missionStorage().collateralHeldBalance[user];
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    // NOTE: Revenue share distribution is handled internally by MissionFacet._distributeRewardsWithRevenueShare()
    // No external function needed - this prevents potential manipulation of escrow balances

    /**
     * @notice Check if user can use a pass (as owner or delegatee)
     * @param collectionId Mission Pass collection ID
     * @param tokenId Token ID
     * @param user Address to check
     * @return canUse Whether user can use the pass
     * @return isDelegatee Whether user is delegatee (not owner)
     */
    function canUseMissionPass(uint16 collectionId, uint256 tokenId, address user)
        external
        view
        returns (bool canUse, bool isDelegatee)
    {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();

        if (collectionId == 0 || collectionId > ms.passCollectionCounter) {
            return (false, false);
        }

        // Check ownership
        address nftOwner = IERC721(ms.passCollections[collectionId].collectionAddress).ownerOf(tokenId);

        // Get delegation once
        LibMissionStorage.PassDelegation storage delegation = ms.passDelegations[collectionId][tokenId];

        if (nftOwner == user) {
            // Owner can use if not delegated
            if (delegation.delegatee == address(0) || block.timestamp >= delegation.expires) {
                return (true, false);
            }
            return (false, false); // Delegated to someone else
        }

        // Check delegation for non-owner
        if (delegation.delegatee == user && block.timestamp < delegation.expires) {
            // Check use limits
            if (delegation.usesAllowed > 0 && delegation.usesConsumed >= delegation.usesAllowed) {
                return (false, true);
            }
            return (true, true);
        }

        return (false, false);
    }

    /**
     * @notice Get lending offer details
     * @param collectionId Mission Pass collection ID
     * @param tokenId Token ID
     * @return offer Lending offer
     */
    function getPassLendingOffer(uint16 collectionId, uint256 tokenId)
        external
        view
        returns (LibMissionStorage.PassLendingOffer memory offer)
    {
        return LibMissionStorage.missionStorage().passLendingOffers[collectionId][tokenId];
    }

    /**
     * @notice Get delegation details
     * @param collectionId Mission Pass collection ID
     * @param tokenId Token ID
     * @return delegation Pass delegation
     */
    function getMissionPassDelegation(uint16 collectionId, uint256 tokenId)
        external
        view
        returns (LibMissionStorage.PassDelegation memory delegation)
    {
        return LibMissionStorage.missionStorage().passDelegations[collectionId][tokenId];
    }

    /**
     * @notice Check if lending offer is valid and can be accepted
     * @param collectionId Mission Pass collection ID
     * @param tokenId Token ID
     * @return isValid Whether offer can be accepted
     * @return reason Reason if not valid
     */
    function isPassLendingOfferValid(uint16 collectionId, uint256 tokenId)
        external
        view
        returns (bool isValid, string memory reason)
    {
        LibMissionStorage.MissionStorage storage ms = LibMissionStorage.missionStorage();
        LibMissionStorage.PassLendingOffer storage offer = ms.passLendingOffers[collectionId][tokenId];

        if (!offer.active) {
            return (false, "Offer not active");
        }
        if (block.timestamp >= offer.offerExpires) {
            return (false, "Offer expired");
        }

        // Check pass not delegated
        LibMissionStorage.PassDelegation storage delegation = ms.passDelegations[collectionId][tokenId];
        if (delegation.delegatee != address(0) && block.timestamp < delegation.expires) {
            return (false, "Pass already delegated");
        }

        // Verify owner still owns the pass
        address currentOwner = IERC721(ms.passCollections[collectionId].collectionAddress).ownerOf(tokenId);
        if (currentOwner != offer.owner) {
            return (false, "Owner changed");
        }

        return (true, "");
    }
}
