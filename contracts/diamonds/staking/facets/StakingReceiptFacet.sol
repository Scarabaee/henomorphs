// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibStakingStorage} from "../libraries/LibStakingStorage.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {PodsUtils} from "../../libraries/PodsUtils.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {StakedSpecimen} from "../../libraries/StakingModel.sol";
import {SpecimenCollection, ControlFee} from "../../libraries/HenomorphsModel.sol";
import {IStakingBiopodFacet, IStakingIntegrationFacet, IExternalCollection} from "../interfaces/IStakingInterfaces.sol";
import {AccessControlBase} from "./AccessControlBase.sol";

/**
 * @title IStkHenoReceiptToken
 * @notice Interface for the stkHENO receipt token contract
 */
interface IStkHenoReceiptToken {
    struct ReceiptData {
        uint256 originalTokenId;
        uint256 collectionId;
        address collectionAddress;
        address originalStaker;
        uint32 stakedAt;
        uint8 tier;
        uint8 variant;
        bool hasAugment;
        uint8 augmentVariant;
    }

    function mint(address to, uint256 receiptId, ReceiptData calldata data) external returns (uint256);
    function burn(uint256 receiptId) external;
    function updateRewards(uint256 receiptId, uint256 newAccumulatedRewards) external;
    function updateAugment(uint256 receiptId, bool hasAugment, uint8 augmentVariant) external;
    function ownerOf(uint256 tokenId) external view returns (address);
    function getReceiptInfo(uint256 receiptId) external view returns (
        ReceiptData memory data,
        IStkHenoReceiptToken.ReceiptStats memory stats,
        address currentOwner,
        uint256 stakingDays
    );
    function setCollectionName(uint256 collectionId, string calldata name) external;

    struct ReceiptStats {
        uint256 accumulatedRewards;
        uint256 transferCount;
        uint256 lastRewardUpdate;
    }
}

interface IStakingEarningsFacet {
    function processUnstakeRewards(uint256 collectionId, uint256 tokenId) external returns (uint256 amount);
    function getPendingReward(uint256 collectionId, uint256 tokenId) external view returns (uint256 amount);
    function claimRewardsFor(uint256 collectionId, uint256 tokenId, address recipient) external returns (uint256 amount);
}

interface IExternalBiopod {
    function probeCalibration(uint256 collectionId, uint256 tokenId) external view returns (Calibration memory);
}

struct Calibration {
    uint8 wear;
    uint8 chargeLevel;
    uint8 infusionLevel;
    uint8 level;
}

/**
 * @title IModularDiamond
 * @notice Interface for querying augment assignments from the modular diamond
 * @dev Uses getAssignmentById which takes collectionId instead of address
 */
interface IModularDiamond {
    struct AugmentAssignment {
        address augmentCollection;      // 1
        uint256 augmentTokenId;         // 2
        address specimenCollection;     // 3
        uint256 specimenTokenId;        // 4
        uint8 tier;                     // 5
        uint8 specimenVariant;          // 6
        uint256 assignmentTime;         // 7
        uint256 unlockTime;             // 8
        bool active;                    // 9
        uint256 totalFeePaid;           // 10
        uint8[] assignedAccessories;    // 11
        uint8 augmentVariant;           // 12 - LAST
    }

    function getAssignment(
        address specimenCollection,
        uint256 specimenTokenId
    ) external view returns (AugmentAssignment memory);

    function getAssignmentById(
        uint256 specimenCollectionId,
        uint256 specimenTokenId
    ) external view returns (AugmentAssignment memory);

    function hasActiveAugment(
        uint256 specimenCollectionId,
        uint256 specimenTokenId
    ) external view returns (bool hasActive);

    function getAugmentAttachment(
        uint256 augmentCollectionId,
        uint256 augmentTokenId
    ) external view returns (AugmentAttachment memory attachment);

    struct AugmentAttachment {
        bool isAttached;
        address specimenCollection;
        uint256 specimenTokenId;
        uint8 tier;
        uint8 augmentVariant;
        uint8 specimenVariant;
        uint256 assignmentTime;
        uint256 unlockTime;
        bool isPermanent;
        uint256 totalFeePaid;
        uint8[] assignedAccessories;
    }
}

/**
 * @title StakingReceiptFacet
 * @notice Diamond facet for integrating stkHENO receipt tokens with the staking system
 * @dev Provides stake-with-receipt, generate-receipt-for-staked, and unstake-via-receipt functionality
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract StakingReceiptFacet is AccessControlBase {

    // ============ EVENTS ============

    event StakedWithReceipt(
        uint256 indexed collectionId,
        uint256 indexed tokenId,
        uint256 indexed receiptId,
        address staker
    );

    event ReceiptGenerated(
        uint256 indexed collectionId,
        uint256 indexed tokenId,
        uint256 indexed receiptId,
        address owner
    );

    event UnstakedWithReceipt(
        uint256 indexed receiptId,
        uint256 indexed collectionId,
        uint256 indexed tokenId,
        address unstaker
    );

    event ReceiptOwnershipChanged(
        uint256 indexed receiptId,
        address indexed previousOwner,
        address indexed newOwner
    );

    event ReceiptTokenContractSet(address indexed receiptTokenContract);

    // ============ ERRORS ============

    error ReceiptTokenNotConfigured();
    error TokenAlreadyHasReceipt();
    error TokenDoesNotHaveReceipt();
    error InvalidReceiptId();
    error NotReceiptOwner();
    error TokenNotStaked();
    error TokenAlreadyStaked();
    error NotTokenOwner();
    error StakingNotEnabled();
    error InvalidCollectionId();
    error TransferFailed();
    error UnauthorizedCaller();

    // ============ MODIFIERS ============

    modifier receiptTokenConfigured() {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        if (ss.receiptTokenContract == address(0)) revert ReceiptTokenNotConfigured();
        _;
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Set the stkHENO receipt token contract address
     * @param _receiptTokenContract Address of the deployed StkHenoReceiptToken
     */
    function setReceiptTokenContract(address _receiptTokenContract) external {
        if (!AccessHelper.isAuthorized()) revert UnauthorizedCaller();

        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        ss.receiptTokenContract = _receiptTokenContract;

        emit ReceiptTokenContractSet(_receiptTokenContract);
    }

    /**
     * @notice Get the receipt token contract address
     */
    function getReceiptTokenContract() external view returns (address) {
        return LibStakingStorage.stakingStorage().receiptTokenContract;
    }

    // ============ STAKE WITH RECEIPT ============

    /**
     * @notice Stake a token and mint a receipt token in one transaction
     * @param collectionId Collection ID
     * @param tokenId Token ID to stake
     * @return receiptId The minted receipt token ID
     */
    function stakeWithReceipt(uint256 collectionId, uint256 tokenId)
        external
        whenNotPaused
        nonReentrant
        receiptTokenConfigured
        returns (uint256 receiptId)
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        address sender = LibMeta.msgSender();

        // Validate
        if (!ss.stakingEnabled) revert StakingNotEnabled();
        if (!LibStakingStorage.isValidCollection(collectionId)) revert InvalidCollectionId();

        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        if (ss.stakedSpecimens[combinedId].staked) revert TokenAlreadyStaked();

        SpecimenCollection storage collection = ss.collections[collectionId];
        IERC721 nftCollection = IERC721(collection.collectionAddress);
        if (nftCollection.ownerOf(tokenId) != sender) revert NotTokenOwner();

        // Get token variant and tier
        uint8 variant = _getTokenVariant(collection.collectionAddress, tokenId);
        uint8 tier = _getTokenTier(collectionId, tokenId, variant);

        // Process stake fee
        ControlFee storage stakeFee = LibFeeCollection.getOperationFee("stakeFee", ss);
        LibFeeCollection.processOperationFee(stakeFee, sender);

        // Initialize staked token
        _initializeStakedToken(ss, collectionId, tokenId, variant, combinedId, collection.collectionAddress, sender);

        // Transfer token to vault
        address tokenDestination = _getTokenVaultAddress();
        nftCollection.safeTransferFrom(sender, tokenDestination, tokenId);

        // Generate receipt ID
        ss.receiptTokenCounter++;
        receiptId = ss.receiptTokenCounter;

        // Mint receipt token
        IStkHenoReceiptToken.ReceiptData memory receiptData = IStkHenoReceiptToken.ReceiptData({
            originalTokenId: tokenId,
            collectionId: collectionId,
            collectionAddress: collection.collectionAddress,
            originalStaker: sender,
            stakedAt: uint32(block.timestamp),
            tier: tier,
            variant: variant,
            hasAugment: false,
            augmentVariant: 0
        });

        IStkHenoReceiptToken receiptToken = IStkHenoReceiptToken(ss.receiptTokenContract);
        receiptToken.mint(sender, receiptId, receiptData);

        // Auto-sync collection name from staking configuration
        _syncCollectionName(receiptToken, collectionId, collection.name);

        // Store mappings
        ss.combinedIdToReceiptId[combinedId] = receiptId;
        ss.receiptIdToCombinedId[receiptId] = combinedId;
        ss.hasReceiptToken[combinedId] = true;

        // Perform integration syncs
        _performIntegrationSyncs(collectionId, tokenId);

        emit StakedWithReceipt(collectionId, tokenId, receiptId, sender);
    }

    // ============ GENERATE RECEIPT FOR STAKED TOKEN ============

    /**
     * @notice Generate a receipt token for an already staked token
     * @dev Only the current owner of the staked token can generate a receipt
     * @param collectionId Collection ID
     * @param tokenId Token ID that is already staked
     * @return receiptId The minted receipt token ID
     */
    function issueReceiptForStaked(uint256 collectionId, uint256 tokenId)
        external
        whenNotPaused
        nonReentrant
        receiptTokenConfigured
        returns (uint256 receiptId)
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        address sender = LibMeta.msgSender();

        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];

        // Validate
        if (!staked.staked) revert TokenNotStaked();
        if (staked.owner != sender && !AccessHelper.isAuthorized()) revert NotTokenOwner();
        if (ss.hasReceiptToken[combinedId]) revert TokenAlreadyHasReceipt();

        // Get tier
        uint8 tier = _getTokenTier(collectionId, tokenId, staked.variant);

        // Generate receipt ID
        ss.receiptTokenCounter++;
        receiptId = ss.receiptTokenCounter;

        // Determine augment status
        (bool hasAugment, uint8 augmentVariant) = _getAugmentStatus(collectionId, tokenId);

        // Mint receipt token
        IStkHenoReceiptToken.ReceiptData memory receiptData = IStkHenoReceiptToken.ReceiptData({
            originalTokenId: tokenId,
            collectionId: collectionId,
            collectionAddress: staked.collectionAddress,
            originalStaker: staked.owner, // Current owner becomes original staker for royalties
            stakedAt: staked.stakedSince,
            tier: tier,
            variant: staked.variant,
            hasAugment: hasAugment,
            augmentVariant: augmentVariant
        });

        IStkHenoReceiptToken receiptToken = IStkHenoReceiptToken(ss.receiptTokenContract);
        receiptToken.mint(sender, receiptId, receiptData);

        // Auto-sync collection name from staking configuration
        SpecimenCollection storage collection = ss.collections[collectionId];
        _syncCollectionName(receiptToken, collectionId, collection.name);

        // Store mappings
        ss.combinedIdToReceiptId[combinedId] = receiptId;
        ss.receiptIdToCombinedId[receiptId] = combinedId;
        ss.hasReceiptToken[combinedId] = true;

        emit ReceiptGenerated(collectionId, tokenId, receiptId, sender);
    }

    // ============ UNSTAKE VIA RECEIPT ============

    /**
     * @notice Unstake a token using the receipt token
     * @dev Burns the receipt and returns the staked NFT to the receipt owner
     * @param receiptId Receipt token ID
     */
    function unstakeWithReceipt(uint256 receiptId)
        external
        whenNotPaused
        nonReentrant
        receiptTokenConfigured
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        address sender = LibMeta.msgSender();

        // Validate receipt exists and caller owns it
        uint256 combinedId = ss.receiptIdToCombinedId[receiptId];
        if (combinedId == 0) revert InvalidReceiptId();

        IStkHenoReceiptToken receiptToken = IStkHenoReceiptToken(ss.receiptTokenContract);
        if (receiptToken.ownerOf(receiptId) != sender && !AccessHelper.isAuthorized()) {
            revert NotReceiptOwner();
        }

        (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];

        if (!staked.staked) revert TokenNotStaked();

        // Process pending rewards
        try IStakingEarningsFacet(address(this)).processUnstakeRewards(collectionId, tokenId) {
            // Rewards processed
        } catch {
            // Continue anyway
        }

        // Process unstake fee
        ControlFee storage unstakeFee = LibFeeCollection.getOperationFee("unstakeFee", ss);
        LibFeeCollection.processOperationFee(unstakeFee, sender);

        // Save data before cleanup
        address collectionAddress = staked.collectionAddress;

        // Cleanup staked token
        _cleanupStakedToken(ss, combinedId, tokenId, staked.owner);

        // Clear receipt mappings
        delete ss.combinedIdToReceiptId[combinedId];
        delete ss.receiptIdToCombinedId[receiptId];
        ss.hasReceiptToken[combinedId] = false;

        // Update cooldown
        ss.stakingCooldowns[combinedId] = uint32(block.timestamp + ss.settings.stakingCooldown);

        // Burn receipt token
        receiptToken.burn(receiptId);

        // Transfer NFT back to sender (receipt owner)
        address tokenSource = _getTokenVaultAddress();
        try IERC721(collectionAddress).safeTransferFrom(tokenSource, sender, tokenId) {
            // Success
        } catch {
            try IExternalCollection(collectionAddress).forceUnstakeTransfer(tokenSource, sender, tokenId) {
                // Success via force transfer
            } catch {
                revert TransferFailed();
            }
        }

        emit UnstakedWithReceipt(receiptId, collectionId, tokenId, sender);
    }

    // ============ CLAIM VIA RECEIPT ============

    /**
     * @notice Claim staking rewards using a receipt token
     * @dev Only the receipt owner can claim. Rewards are sent to receipt owner.
     * @param receiptId Receipt token ID
     * @return amount Amount of rewards claimed
     */
    function claimWithReceipt(uint256 receiptId)
        external
        whenNotPaused
        nonReentrant
        receiptTokenConfigured
        returns (uint256 amount)
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        address sender = LibMeta.msgSender();

        // Validate receipt exists and caller owns it
        uint256 combinedId = ss.receiptIdToCombinedId[receiptId];
        if (combinedId == 0) revert InvalidReceiptId();

        IStkHenoReceiptToken receiptToken = IStkHenoReceiptToken(ss.receiptTokenContract);
        if (receiptToken.ownerOf(receiptId) != sender) {
            revert NotReceiptOwner();
        }

        (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];

        if (!staked.staked) revert TokenNotStaked();

        // Process claim fee
        ControlFee storage claimFee = LibFeeCollection.getOperationFee("claimFee", ss);
        LibFeeCollection.processOperationFee(claimFee, sender);

        // Claim rewards - uses internal function that bypasses receipt check
        try IStakingEarningsFacet(address(this)).claimRewardsFor(collectionId, tokenId, sender) returns (uint256 claimedAmount) {
            amount = claimedAmount;
        } catch {
            // Try getting pending reward and process manually if internal call fails
            amount = IStakingEarningsFacet(address(this)).getPendingReward(collectionId, tokenId);
            if (amount > 0) {
                staked.lastClaimTimestamp = uint32(block.timestamp);
                staked.totalRewardsClaimed += amount;
            }
        }

        // Update accumulated rewards in receipt token
        if (amount > 0) {
            try receiptToken.updateRewards(receiptId, staked.totalRewardsClaimed) {
                // Updated
            } catch {
                // Continue even if update fails
            }
        }

        emit RewardClaimedWithReceipt(receiptId, collectionId, tokenId, sender, amount);
    }

    event RewardClaimedWithReceipt(
        uint256 indexed receiptId,
        uint256 indexed collectionId,
        uint256 indexed tokenId,
        address claimer,
        uint256 amount
    );

    // ============ RECEIPT TRANSFER CALLBACK ============

    /**
     * @notice Callback from stkHENO contract when receipt is transferred
     * @dev Updates the staked token owner in storage
     * @param receiptId Receipt token ID
     * @param newOwner New owner address
     */
    function onReceiptTransfer(uint256 receiptId, address newOwner) external {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        // Only receipt token contract can call this
        if (msg.sender != ss.receiptTokenContract) revert UnauthorizedCaller();

        uint256 combinedId = ss.receiptIdToCombinedId[receiptId];
        if (combinedId == 0) return; // Silent return if receipt not found

        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        if (!staked.staked) return; // Silent return if not staked

        address previousOwner = staked.owner;

        // Update owner in staking storage
        staked.owner = newOwner;

        // Update stakerTokens mapping
        _updateStakerTokensOnTransfer(ss, combinedId, previousOwner, newOwner);

        emit ReceiptOwnershipChanged(receiptId, previousOwner, newOwner);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get receipt ID for a staked token
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return receiptId Receipt token ID (0 if no receipt)
     */
    function getStakingReceiptId(uint256 collectionId, uint256 tokenId) external view returns (uint256) {
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        return LibStakingStorage.stakingStorage().combinedIdToReceiptId[combinedId];
    }

    /**
     * @notice Get staked token IDs from receipt ID
     * @param receiptId Receipt token ID
     * @return collectionId Collection ID
     * @return tokenId Token ID
     */
    function getStakedTokenFromReceipt(uint256 receiptId)
        external
        view
        returns (uint256 collectionId, uint256 tokenId)
    {
        uint256 combinedId = LibStakingStorage.stakingStorage().receiptIdToCombinedId[receiptId];
        if (combinedId == 0) revert InvalidReceiptId();
        return PodsUtils.extractIds(combinedId);
    }

    /**
     * @notice Check if a staked token has a receipt
     * @param collectionId Collection ID
     * @param tokenId Token ID
     */
    function hasStakingReceipt(uint256 collectionId, uint256 tokenId) external view returns (bool) {
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        return LibStakingStorage.stakingStorage().hasReceiptToken[combinedId];
    }

    /**
     * @notice Get total receipt tokens minted
     */
    function getTotalReceiptsMinted() external view returns (uint256) {
        return LibStakingStorage.stakingStorage().receiptTokenCounter;
    }

    /**
     * @notice Diagnose augment status for a specific receipt
     * @param receiptId Receipt ID to diagnose
     * @return combinedId The combined ID for the receipt
     * @return collectionId Extracted collection ID
     * @return tokenId Extracted token ID
     * @return diamondAddress Modular diamond address for the collection
     * @return collectionAddress The NFT collection address
     * @return hasAugment Whether the token has an active augment
     * @return augmentVariant The augment variant
     */
    function diagnoseReceipt(uint256 receiptId) external view returns (
        uint256 combinedId,
        uint256 collectionId,
        uint256 tokenId,
        address diamondAddress,
        address collectionAddress,
        bool hasAugment,
        uint8 augmentVariant
    ) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        combinedId = ss.receiptIdToCombinedId[receiptId];
        if (combinedId == 0) {
            return (0, 0, 0, address(0), address(0), false, 0);
        }

        (collectionId, tokenId) = PodsUtils.extractIds(combinedId);

        SpecimenCollection storage collection = ss.collections[collectionId];
        diamondAddress = collection.diamondAddress;
        collectionAddress = collection.collectionAddress;

        (hasAugment, augmentVariant) = _getAugmentStatus(collectionId, tokenId);
    }

    // ============ AUGMENT SYNC ============

    /**
     * @notice Sync augment status to staking receipt token
     * @dev Called by AugmentFacet when augment is assigned or removed
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param hasAugment Whether token has augment
     * @param augmentVariant Augment variant (0 if no augment)
     */
    function syncAugmentToReceipt(
        uint256 collectionId,
        uint256 tokenId,
        bool hasAugment,
        uint8 augmentVariant
    ) external {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        // Allow calls from modular diamond or authorized callers
        SpecimenCollection storage collection = ss.collections[collectionId];
        if (msg.sender != collection.diamondAddress && !AccessHelper.isAuthorized()) {
            revert UnauthorizedCaller();
        }

        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);

        // Check if token has a receipt
        if (!ss.hasReceiptToken[combinedId]) {
            return;
        }

        uint256 receiptId = ss.combinedIdToReceiptId[combinedId];
        if (receiptId == 0) {
            return;
        }

        // Update receipt token augment status
        if (ss.receiptTokenContract != address(0)) {
            try IStkHenoReceiptToken(ss.receiptTokenContract).updateAugment(
                receiptId,
                hasAugment,
                augmentVariant
            ) {} catch {}
        }
    }

    /**
     * @notice Batch refresh augment status for existing receipt tokens
     * @param collectionId Collection ID
     * @param tokenIds Array of token IDs to refresh
     */
    function refreshAugments(uint256 collectionId, uint256[] calldata tokenIds) external onlyAuthorized {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        if (ss.receiptTokenContract == address(0)) revert ReceiptTokenNotConfigured();

        IStkHenoReceiptToken receiptToken = IStkHenoReceiptToken(ss.receiptTokenContract);

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);

            if (!ss.hasReceiptToken[combinedId]) continue;

            uint256 receiptId = ss.combinedIdToReceiptId[combinedId];
            if (receiptId == 0) continue;

            (bool hasAugment, uint8 augmentVariant) = _getAugmentStatus(collectionId, tokenId);

            try receiptToken.updateAugment(receiptId, hasAugment, augmentVariant) {} catch {}
        }
    }

    /**
     * @notice Refresh augments for receipt tokens by range (all collections)
     * @param startReceiptId Starting receipt ID (inclusive)
     * @param endReceiptId Ending receipt ID (inclusive)
     */
    function refreshAugmentsByRange(uint256 startReceiptId, uint256 endReceiptId) external onlyAuthorized {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        if (ss.receiptTokenContract == address(0)) revert ReceiptTokenNotConfigured();

        IStkHenoReceiptToken receiptToken = IStkHenoReceiptToken(ss.receiptTokenContract);

        for (uint256 receiptId = startReceiptId; receiptId <= endReceiptId; receiptId++) {
            uint256 combinedId = ss.receiptIdToCombinedId[receiptId];
            if (combinedId == 0) continue;

            (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);

            (bool hasAugment, uint8 augmentVariant) = _getAugmentStatus(collectionId, tokenId);

            try receiptToken.updateAugment(receiptId, hasAugment, augmentVariant) {} catch {}
        }
    }

    /**
     * @notice Test function to refresh single receipt without authorization
     * @dev For debugging - remove after testing
     */
    function testRefreshSingleReceipt(uint256 receiptId) external onlyAuthorized returns (
        bool success,
        uint256 combinedId,
        uint256 collectionId,
        uint256 tokenId,
        bool hasAugment,
        uint8 augmentVariant,
        string memory errorMsg
    ) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        if (ss.receiptTokenContract == address(0)) {
            return (false, 0, 0, 0, false, 0, "Receipt token not configured");
        }

        combinedId = ss.receiptIdToCombinedId[receiptId];
        if (combinedId == 0) {
            return (false, 0, 0, 0, false, 0, "Receipt not found in mapping");
        }

        (collectionId, tokenId) = PodsUtils.extractIds(combinedId);
        (hasAugment, augmentVariant) = _getAugmentStatus(collectionId, tokenId);

        IStkHenoReceiptToken receiptToken = IStkHenoReceiptToken(ss.receiptTokenContract);

        try receiptToken.updateAugment(receiptId, hasAugment, augmentVariant) {
            success = true;
            errorMsg = "OK";
        } catch Error(string memory reason) {
            success = false;
            errorMsg = reason;
        } catch {
            success = false;
            errorMsg = "Unknown error";
        }
    }

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @notice Initialize staked token data
     */
    function _initializeStakedToken(
        LibStakingStorage.StakingStorage storage ss,
        uint256 collectionId,
        uint256 tokenId,
        uint8 variant,
        uint256 combinedId,
        address collectionAddress,
        address staker
    ) internal {
        ss.stakedSpecimens[combinedId] = StakedSpecimen({
            owner: staker,
            collectionAddress: collectionAddress,
            stakedSince: uint32(block.timestamp),
            lastClaimTimestamp: uint32(block.timestamp),
            lastSyncTimestamp: uint32(block.timestamp),
            variant: variant,
            staked: true,
            level: 1,
            infusionLevel: 0,
            chargeLevel: 0,
            specialization: 0,
            experience: 0,
            wearLevel: 0,
            wearPenalty: 0,
            lastWearUpdateTime: uint32(block.timestamp),
            lastWearRepairTime: 0,
            lockupActive: false,
            lockupEndTime: 0,
            lockupBonus: 0,
            colonyId: bytes32(0),
            collectionId: collectionId,
            tokenId: tokenId,
            totalRewardsClaimed: 0
        });

        ss.tokenCollectionIds[combinedId] = collectionId;
        ss.stakerTokens[staker].push(combinedId);
        ss.totalStakedSpecimens++;

        LibStakingStorage.addActiveStaker(staker);
    }

    /**
     * @notice Cleanup staked token on unstake
     */
    function _cleanupStakedToken(
        LibStakingStorage.StakingStorage storage ss,
        uint256 combinedId,
        uint256 tokenId,
        address owner
    ) internal {
        // Remove from stakerTokens array
        uint256[] storage tokens = ss.stakerTokens[owner];
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == combinedId) {
                tokens[i] = tokens[tokens.length - 1];
                tokens.pop();
                break;
            }
        }

        // Handle colony membership cleanup
        bytes32 colonyId = ss.stakedSpecimens[combinedId].colonyId;
        if (colonyId != bytes32(0)) {
            _removeFromColony(ss, combinedId, colonyId);
        }

        // Clear staked data
        delete ss.stakedSpecimens[combinedId];
        delete ss.tokenCollectionIds[combinedId];
        ss.totalStakedSpecimens--;

        LibStakingStorage.removeActiveStakerIfEmpty(owner);
    }

    /**
     * @notice Update stakerTokens mapping on receipt transfer
     */
    function _updateStakerTokensOnTransfer(
        LibStakingStorage.StakingStorage storage ss,
        uint256 combinedId,
        address previousOwner,
        address newOwner
    ) internal {
        // Remove from previous owner
        uint256[] storage prevTokens = ss.stakerTokens[previousOwner];
        for (uint256 i = 0; i < prevTokens.length; i++) {
            if (prevTokens[i] == combinedId) {
                prevTokens[i] = prevTokens[prevTokens.length - 1];
                prevTokens.pop();
                break;
            }
        }

        // Add to new owner
        ss.stakerTokens[newOwner].push(combinedId);

        // Update active staker tracking
        LibStakingStorage.removeActiveStakerIfEmpty(previousOwner);
        LibStakingStorage.addActiveStaker(newOwner);
    }

    /**
     * @notice Remove token from colony
     */
    function _removeFromColony(
        LibStakingStorage.StakingStorage storage ss,
        uint256 combinedId,
        bytes32 colonyId
    ) internal {
        uint256[] storage members = ss.colonyMembers[colonyId];
        for (uint256 i = 0; i < members.length; i++) {
            if (members[i] == combinedId) {
                members[i] = members[members.length - 1];
                members.pop();
                break;
            }
        }

        if (ss.colonyStats[colonyId].memberCount > 0) {
            ss.colonyStats[colonyId].memberCount--;
        }
    }

    /**
     * @notice Get token variant from collection
     */
    function _getTokenVariant(address collectionAddress, uint256 tokenId) internal view returns (uint8) {
        try IExternalCollection(collectionAddress).itemVariant(tokenId) returns (uint8 variant) {
            return variant > 0 && variant <= 4 ? variant : 1;
        } catch {
            return 1;
        }
    }

    /**
     * @notice Get token tier from collection configuration
     * @dev Retrieves the default tier from the SpecimenCollection config
     *      Falls back to tier 1 if not configured
     * @param collectionId Collection ID in staking system
     * @param tokenId Token ID (unused, kept for interface compatibility)
     * @param variant Token variant (unused, kept for interface compatibility)
     * @return tier Token tier (1-5)
     */
    function _getTokenTier(uint256 collectionId, uint256 tokenId, uint8 variant) internal view returns (uint8) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        SpecimenCollection storage collection = ss.collections[collectionId];

        // Use collection's default tier if configured
        if (collection.defaultTier > 0 && collection.defaultTier <= 5) {
            return collection.defaultTier;
        }

        // Fallback: if no tier configured, return tier 1
        return 1;
    }

    /**
     * @notice Get augment status for a staked token
     * @dev Queries the modular diamond for augment assignment info
     *      Uses getAssignment with collection address
     * @param collectionId Collection ID in staking system
     * @param tokenId Token ID to check
     * @return hasAugment Whether the token has an active augment assignment
     * @return augmentVariant The augment variant (1-4), 0 if no augment
     */
    function _getAugmentStatus(uint256 collectionId, uint256 tokenId)
        internal
        view
        returns (bool hasAugment, uint8 augmentVariant)
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        // Get collection data to find the modular diamond address
        SpecimenCollection storage collection = ss.collections[collectionId];

        // Check if collection has a modular diamond configured
        if (collection.diamondAddress == address(0)) {
            return (false, 0);
        }

        // Query the modular diamond for augment assignment using collection address
        try IModularDiamond(collection.diamondAddress).getAssignment(
            collection.collectionAddress,
            tokenId
        ) returns (IModularDiamond.AugmentAssignment memory assignment) {
            if (assignment.active && assignment.augmentVariant > 0) {
                return (true, assignment.augmentVariant);
            }
        } catch {
            // Query failed - return no augment
        }

        return (false, 0);
    }

    /**
     * @notice Get token vault address
     */
    function _getTokenVaultAddress() internal view returns (address) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        if (ss.vaultConfig.useExternalVault && ss.vaultConfig.vaultAddress != address(0)) {
            return ss.vaultConfig.vaultAddress;
        }

        return address(this);
    }

    /**
     * @notice Sync collection name to receipt token contract
     * @dev Only syncs if the name is not empty
     */
    function _syncCollectionName(
        IStkHenoReceiptToken receiptToken,
        uint256 collectionId,
        string storage collectionName
    ) internal {
        if (bytes(collectionName).length > 0) {
            try receiptToken.setCollectionName(collectionId, collectionName) {
                // Name synced successfully
            } catch {
                // Continue even if sync fails - not critical
            }
        }
    }

    /**
     * @notice Perform integration syncs
     */
    function _performIntegrationSyncs(uint256 collectionId, uint256 tokenId) internal {
        try IStakingBiopodFacet(address(this)).syncBiopodData(collectionId, tokenId) {
            // Synced
        } catch {
            // Continue
        }

        try IStakingIntegrationFacet(address(this)).syncTokenWithChargepod(collectionId, tokenId) {
            // Synced
        } catch {
            // Continue
        }
    }
}
