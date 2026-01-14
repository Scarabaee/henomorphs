// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibStakingStorage} from "../libraries/LibStakingStorage.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {PodsUtils} from "../../libraries/PodsUtils.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StakedSpecimen, RewardCalcData, InfusionCalcData, StakeBalanceParams} from "../../libraries/StakingModel.sol";
import {SpecimenCollection, ControlFee} from "../../libraries/HenomorphsModel.sol";
import {IStakingBiopodFacet, IStakingIntegrationFacet, IStakingWearFacet, IExternalCollection, IColonyFacet} from "../interfaces/IStakingInterfaces.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {LibStakingAchievementTrigger} from "../libraries/LibStakingAchievementTrigger.sol";

interface IStakingTraitFacet {
    function applyTraitPackBonuses(uint256 collectionId, uint256 tokenId) external returns (bool);
}

interface IStakingEarningsFacet {
    function claimStakingRewards(uint256 collectionId, uint256 tokenId) external returns (uint256 amount, bool fromTreasury);
    function processUnstakeRewards(uint256 collectionId, uint256 tokenId) external returns (uint256 amount);
    function getPendingReward(uint256 collectionId, uint256 tokenId) external view returns (uint256 amount);
    function getPendingEarnings(address staker, uint256 maxCheck) external view returns (uint256 rewardTotal, uint256 count);
}

/**
 * @title StakingCoreFacet
 * @notice Core facet for handling token staking operations with overflow protection
 * @dev Implements staking, unstaking and reward calculations with safety against overflow
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */

contract StakingCoreFacet is AccessControlBase, IERC721Receiver {
    using Math for uint256;
    
    // Safety constants to prevent overflows
    uint256 private constant MAX_TOTAL_REWARD = 2**224;
    
    // Constants for uint8 values
    uint8 private constant MAX_VARIANT = 4;

    // Events
    event TokenStaked(uint256 indexed collectionId, uint256 indexed tokenId, address indexed staker, uint8 variant);
    event TokenUnstaked(uint256 indexed collectionId, uint256 indexed tokenId, address indexed staker);
    event OperationResult(string operation, bool success);
    event TokenIsNotStaked(uint256 indexed collectionId, uint256 indexed tokenId);
    
    // Errors
    error InvalidVariantRange();
    error InvalidCollectionId();
    error TokenAlreadyStaked();
    error TokenNotStaked();
    error NotTokenOwner();
    error StakingNotEnabled();
    error TokenInCooldown();
    error UnauthorizedCaller();
    error FeesRequired();
    error ContractPaused();
    error TransferFailed();
    error PowerCoreNotActivated(uint256 collectionId, uint256 tokenId);
    error MaxStakingLimitReached(uint256 limit);
    error InvalidFeeConfiguration();

    /**
     * @dev Mapping to track addresses authorized to transfer NFTs to this contract
     */
    mapping(address => bool) private _authorizedTransfers;

    /**
     * @notice Structure to hold detailed staked token information
     */
    struct StakedTokenInfo {
        uint256 combinedId;     // Combined token ID
        uint256 collectionId;   // Collection ID
        uint256 tokenId;        // Token ID
    }

    /**
     * @notice Implementation of IERC721Receiver
     */
    function onERC721Received(
        address,
        address from,
        uint256,
        bytes calldata
    ) external view override returns (bytes4) {
        if (_authorizedTransfers[from] || AccessHelper.isAuthorized()) {
            return IERC721Receiver.onERC721Received.selector;
        }
        
        revert UnauthorizedCaller();
    }
    
    /**
     * @notice Stake an NFT token with improved security pattern
     * @dev Updated flow: validate → update state → external calls for better reentrancy protection
     * @param collectionId Collection ID
     * @param tokenId Token ID to stake
     */
    function stakeSpecimen(uint256 collectionId, uint256 tokenId) external 
        whenNotPaused
        nonReentrant 
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        address sender = LibMeta.msgSender();
        
        // Standard validation
        if (!ss.stakingEnabled) {
            revert StakingNotEnabled();
        }
        
        if (!LibStakingStorage.isValidCollection(collectionId)) {
            revert InvalidCollectionId();
        }
        
        // Check maximum tokens per staker limit
        if (ss.settings.maxTokensPerStaker > 0 && !AccessHelper.isAuthorized()) {
            uint256 currentStakedCount = ss.stakerTokenCount[sender];
            uint256 gracePeriodEnd = ss.stakerGracePeriods[sender];
            
            if (currentStakedCount >= ss.settings.maxTokensPerStaker && 
                (gracePeriodEnd == 0 || block.timestamp > gracePeriodEnd)) {
                revert MaxStakingLimitReached(ss.settings.maxTokensPerStaker);
            }
        }
                
        // Get collection data
        SpecimenCollection storage collection = ss.collections[collectionId];
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        // Check if token is already staked
        if (ss.stakedSpecimens[combinedId].staked) {
            revert TokenAlreadyStaked();
        }
        
        // Check cooldown period
        uint32 cooldownEndTime = ss.stakingCooldowns[combinedId];
        if (cooldownEndTime > 0 && block.timestamp < cooldownEndTime) {
            revert TokenInCooldown();
        }
        
        // Check token ownership
        IERC721 nftCollection = IERC721(collection.collectionAddress);
        if (nftCollection.ownerOf(tokenId) != sender) {
            revert NotTokenOwner();
        }
        
        // Check Power Core
        if (ss.requirePowerCoreForStaking && ss.chargeSystemAddress != address(0)) {
            bool powerCoreActive = false;
            
            try IStakingIntegrationFacet(address(this)).isPowerCoreActive(collectionId, tokenId) returns (bool active) {
                powerCoreActive = active;
            } catch {
                powerCoreActive = false;
            }
            
            bool bypassCheck = ss.powerCoreBypass[combinedId] || AccessHelper.isAuthorized();
            
            if (!powerCoreActive && !bypassCheck) {
                revert PowerCoreNotActivated(collectionId, tokenId);
            }
        }
        
        // Process stake fee
        ControlFee storage stakeFee = LibFeeCollection.getOperationFee("stakeFee", ss);
        LibFeeCollection.processOperationFee(stakeFee, sender);
        
        // Get token variant
        uint8 variant = _getTokenVariant(collection.collectionAddress, tokenId);
        
        // IMPORTANT: Initialize token data in storage BEFORE external calls
        // This prevents potential reentrancy issues
        _initializeStakedToken(ss, collectionId, tokenId, variant, combinedId, collection.collectionAddress, sender);

        // Get reference to the initialized staked token to check colony membership
        StakedSpecimen storage stakedToken = ss.stakedSpecimens[combinedId];
        _updateColonyMembershipOnStake(combinedId, stakedToken);

        // Now perform the external transfer
        address tokenDestination = _getTokenVaultAddress();
        _authorizedTransfers[sender] = true;
        
        try nftCollection.safeTransferFrom(sender, tokenDestination, tokenId) {
            // Transfer succeeded - immediately revoke authorization
            _authorizedTransfers[sender] = false;
        } catch {
            // Transfer failed - revert our state changes, revoke authorization and revert
            _cleanupStakedToken(ss, combinedId, tokenId, sender);
            _authorizedTransfers[sender] = false;
            revert TransferFailed();
        }
        
        // Perform integration syncs after state changes and transfers are complete
        _performIntegrationSyncs(collectionId, tokenId);

        emit TokenStaked(collectionId, tokenId, sender, variant);

        // Trigger staking achievement (cross-diamond call to Chargepod)
        LibStakingAchievementTrigger.triggerStake(sender, ss.stakerTokens[sender].length);
    }

    /**
     * @notice Helper function to perform external integration syncs
     * @dev Separated from main logic to isolate failures and improve readability
     * @param collectionId Collection ID
     * @param tokenId Token ID
     */
    function _performIntegrationSyncs(uint256 collectionId, uint256 tokenId) private {
        // Process Biopod integration
        try IStakingBiopodFacet(address(this)).syncBiopodData(collectionId, tokenId) {
            // Successfully synced
        } catch {
            // Continue without Biopod for general errors
        }
        
        // Sync with Chargepod
        try IStakingIntegrationFacet(address(this)).syncTokenWithChargepod(collectionId, tokenId) {
            // Successfully synced
        } catch {
            // Continue without Chargepod
        }
    }

    /**
     * @notice Unstake an NFT token with enhanced security and fee handling
     * @dev Improved unstaking with standardized fee collection
     * @param collectionId Collection ID
     * @param tokenId Token ID to unstake
     */
    function unstakeSpecimen(uint256 collectionId, uint256 tokenId) external 
        whenNotPaused
        nonReentrant 
    {
        address sender = LibMeta.msgSender();
        
        // Check rate limit using AccessHelper
        if (!AccessHelper.enforceRateLimit(sender, this.unstakeSpecimen.selector, 5, 1 hours)) {
            revert AccessHelper.RateLimitExceeded(sender, this.unstakeSpecimen.selector);
        }

        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Validate collection ID
        if (collectionId == 0 || collectionId > ss.collectionCounter) {
            revert InvalidCollectionId();
        }
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        // Check if token is staked
        if (!staked.staked) {
            revert TokenNotStaked();
        }

        // Block unstaking if token has receipt - must use unstakeWithReceipt
        LibStakingStorage.requireNoReceipt(combinedId);

        // Check if caller is owner or admin using AccessHelper
        bool isOwner = staked.owner == sender;
        bool isAdmin = AccessHelper.isAuthorized();
        
        if (!isOwner && !isAdmin) {
            revert AccessHelper.Unauthorized(sender, "Not token owner or admin");
        }
        
        // Process pending rewards via StakingEarningsFacet (reward token system)
        try IStakingEarningsFacet(address(this)).processUnstakeRewards(collectionId, tokenId) {
            // Rewards processed successfully
        } catch {
            // Continue with unstaking even if reward processing fails
        }

        // Get appropriate unstake fee using standardized approach
        ControlFee storage unstakeFee = LibFeeCollection.getOperationFee("unstakeFee", ss);
        
        // Handle unstaking fee using centralized fee library
        LibFeeCollection.processOperationFee(unstakeFee, sender);
        
        // Save owner and collection address for token transfer
        address owner = staked.owner;
        address collectionAddress = staked.collectionAddress;
        
        // Remove token from all lists and mappings
        _cleanupStakedToken(ss, combinedId, tokenId, owner);
        
        // Update cooldown time
        ss.stakingCooldowns[combinedId] = uint32(block.timestamp + ss.settings.stakingCooldown);
        
        // Transfer token back to owner with safer try-catch pattern
        address tokenSource = _getTokenVaultAddress();
        // Try normal transfer first, then force transfer if needed
        try IERC721(collectionAddress).safeTransferFrom(tokenSource, owner, tokenId) {
            emit TokenUnstaked(collectionId, tokenId, owner);
        } catch {
            try IExternalCollection(collectionAddress).forceUnstakeTransfer(tokenSource, owner, tokenId) {
                emit TokenUnstaked(collectionId, tokenId, owner);
            } catch {
                _revertUnstakeState(ss, combinedId, collectionId, tokenId, owner, collectionAddress);
                revert TransferFailed(); 
            }
        }
    }

    /**
     * @notice Helper function to find unique stakers using optimized tracking
     * @param ss Storage reference
     * @return uniqueStakers Array of unique staker addresses
     * @return count Number of unique stakers found
     */
    function _findUniqueStakers(LibStakingStorage.StakingStorage storage ss) 
        private view 
        returns (address[] memory uniqueStakers, uint256 count) 
    {
        // Use optimized activeStakers array
        count = ss.activeStakers.length;
        uniqueStakers = new address[](count);
        
        // Copy addresses directly from tracked array
        for (uint256 i = 0; i < count; i++) {
            uniqueStakers[i] = ss.activeStakers[i];
        }
    }

    /**
     * @notice Get all unique addresses that have actively staked tokens
     * @dev This function may be gas-intensive with many stakers and is primarily for off-chain use
     * @return uniqueStakers Array of unique staker addresses with active stakes
     */
    function getAllUniqueStakers() public view returns (address[] memory uniqueStakers) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
    
        // Use dedicated activeStakers array
        uint256 stakerCount = ss.activeStakers.length;
        
        // Return all active stakers directly from optimized structure
        uniqueStakers = new address[](stakerCount);
        for (uint256 i = 0; i < stakerCount; i++) {
            uniqueStakers[i] = ss.activeStakers[i];
        }
        
        return uniqueStakers;
    }
    
    /**
     * @notice Set power core requirement for staking
     * @param required Whether to require power core activation for staking
     */
    function setPowerCoreRequirement(bool required) external {
        if (!AccessHelper.isAuthorized()) {
            revert UnauthorizedCaller();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        ss.requirePowerCoreForStaking = required;
        
        emit OperationResult("PowerCoreRequirementSet", true);
    }
    
    /**
     * @notice Add power core requirement bypass for specific token
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param bypass Whether to bypass power core check for this token
     */
    function setPowerCoreBypass(uint256 collectionId, uint256 tokenId, bool bypass) external {
        if (!AccessHelper.isAuthorized()) {
            revert UnauthorizedCaller();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        ss.powerCoreBypass[combinedId] = bypass;
        
        emit OperationResult("PowerCoreBypassSet", true);
    }
        
    /**
     * @notice Get staked token data
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return Staked token data
     */
    function getStakedTokenData(uint256 collectionId, uint256 tokenId) external view returns (StakedSpecimen memory) {
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        return LibStakingStorage.stakingStorage().stakedSpecimens[combinedId];
    }

    /**
     * @notice Get comprehensive staking information for a token
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return isStaked Whether the token is currently staked
     * @return stakingStartTime Timestamp when staking began (0 if not staked)
     * @return totalRewards Total rewards accumulated for this token
     * @return currentMultiplier Current reward multiplier based on various factors
     */
    function getStakingInfo(uint256 collectionId, uint256 tokenId) external view returns (
        bool isStaked,
        uint256 stakingStartTime,
        uint256 totalRewards,
        uint8 currentMultiplier
    ) {
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = LibStakingStorage.stakingStorage().stakedSpecimens[combinedId];
        
        if (!staked.staked) {
            return (false, 0, 0, 0);
        }
        
        // Get pending rewards
        uint256 pendingRewards = 0;
        try IStakingEarningsFacet(address(this)).getPendingReward(collectionId, tokenId) returns (uint256 rewards) {
            pendingRewards = rewards;
        } catch {
            // Ignore errors
        }
        
        // Simple multiplier based on charge level and wear
        uint8 multiplier = 100; // Base 100%
        if (staked.chargeLevel > 50) {
            multiplier += 10; // +10% bonus for good charge
        }
        if (staked.wearPenalty > 0) {
            multiplier = multiplier > staked.wearPenalty ? multiplier - staked.wearPenalty : 50;
        }
        
        return (
            true,
            staked.stakedSince,
            pendingRewards,
            multiplier
        );
    }
    
    /**
     * @notice Get tokens staked by an address
     * @param staker Staker address
     * @return Array of combined token IDs staked by this address
     */
    function getStakedTokensByAddress(address staker) external view returns (uint256[] memory) {
        return LibStakingStorage.stakingStorage().stakerTokens[staker];
    }

    /**
     * @notice Get detailed information about tokens staked by an address
     * @dev Returns comprehensive information including separated IDs for each staked token
     * @param staker Staker address
     * @return tokenInfo Array of token information structures
     */
    function getDetailedStakedTokensByAddress(address staker) external view returns (StakedTokenInfo[] memory tokenInfo) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256[] storage combinedIds = ss.stakerTokens[staker];
        uint256 totalTokens = combinedIds.length;
        
        if (totalTokens == 0) {
            return new StakedTokenInfo[](0);
        }
        
        // Allocate maximum possible size for the result array
        tokenInfo = new StakedTokenInfo[](totalTokens);
        uint256 validCount = 0;
        
        // Process each token
        for (uint256 i = 0; i < totalTokens; i++) {
            uint256 combinedId = combinedIds[i];
            StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
            
            // Only include tokens that are actually staked and owned by this address
            if (staked.staked && staked.owner == staker) {
                // Extract collection and token IDs
                (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);
                
                // Populate the structure
                tokenInfo[validCount].combinedId = combinedId;
                tokenInfo[validCount].collectionId = collectionId;
                tokenInfo[validCount].tokenId = tokenId;
                
                validCount++;
            }
        }
        
        // If we found fewer valid tokens than the total, create a properly sized array
        if (validCount < totalTokens) {
            // Create new array of exact size
            StakedTokenInfo[] memory result = new StakedTokenInfo[](validCount);
            
            // Copy valid entries
            for (uint256 i = 0; i < validCount; i++) {
                result[i] = tokenInfo[i];
            }
            
            return result;
        }
        
        return tokenInfo;
    }

    /**
     * @notice Force update token data (admin only)
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param level New level
     * @param experience New experience
     * @param chargeLevel New charge level
     */
    function updateTokenData(
        uint256 collectionId, 
        uint256 tokenId, 
        uint8 level, 
        uint256 experience, 
        uint8 chargeLevel
    ) external {
        if (!AccessHelper.isAuthorized()) {
            revert UnauthorizedCaller();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        if (collectionId == 0 || !ss.collections[collectionId].enabled) {
            revert InvalidCollectionId();
        }
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        // Check if the token is staked
        if (!staked.staked) {
            emit TokenIsNotStaked(collectionId, tokenId);
            return;
        }

        // Update token data
        if (level > 0) {
            staked.level = level;
        }

        staked.experience = experience;

        if (chargeLevel <= 100) {
            staked.chargeLevel = chargeLevel;
            
            // Update charge bonus
            LibStakingStorage.updateChargeBonus(collectionId, tokenId, chargeLevel);
        }

        // Update last sync timestamp
        staked.lastSyncTimestamp = uint32(block.timestamp);

        // Attempt to sync with Biopod for consistency
        try IStakingBiopodFacet(address(this)).syncBiopodData(collectionId, tokenId) {
            // Synchronization successful
        } catch {
            // Ignore errors
        }
    }

    /**
     * @notice More thorough migration that scans all token combinations
     * @dev WARNING: This function can be extremely gas intensive for large collections
     */
    function migrateActiveStakers(
        uint256 startCollectionId,
        uint256 endCollectionId,
        uint256 maxTokenId
    ) external nonReentrant {
        if (!AccessHelper.isAuthorized()) {
            revert UnauthorizedCaller();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Validate inputs
        if (endCollectionId > ss.collectionCounter) {
            endCollectionId = ss.collectionCounter;
        }
        
        // For each collection in the range
        for (uint256 collectionId = startCollectionId; collectionId <= endCollectionId; collectionId++) {
            SpecimenCollection storage collection = ss.collections[collectionId];
            
            // Skip invalid collections
            if (collection.collectionAddress == address(0) || !collection.enabled) {
                continue;
            }
            
            // Process tokens in the collection up to maxTokenId
            for (uint256 tokenId = 1; tokenId <= maxTokenId; tokenId++) {
                uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
                StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
                
                // If token is staked, add owner to active stakers
                if (staked.staked && staked.owner != address(0)) {
                    // Make sure this staker is tracked
                    if (!ss.isActiveStaker[staked.owner]) {
                        ss.activeStakers.push(staked.owner);
                        ss.isActiveStaker[staked.owner] = true;
                    }
                    
                    // Increment token count
                    ss.stakerTokenCount[staked.owner]++;
                }
            }
        }
        
        emit OperationResult("MigrateActiveStakersComprehensive", true);
    }
    
    /**
     * @notice Get staking statistics
     * @return totalStaked Total staked tokens
     * @return totalRewards Total rewards distributed
     */
    function getStakingStats() external view returns (uint256 totalStaked, uint256 totalRewards) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        return (ss.totalStakedSpecimens, ss.totalRewardsDistributed);
    }

    /**
     * @notice Get detailed staking statistics with comprehensive metrics
     * @dev This function provides a complete view of the staking ecosystem
     * @return totalStaked Total active staked tokens currently in the system
     * @return totalPendingRewards Total pending rewards across all staked tokens
     * @return totalClaimedRewards Total rewards claimed historically
     * @return totalInfusedZico Total amount of ZICO currently infused
     */
    function getDetailedStakingStats() external view returns (
        uint256 totalStaked,
        uint256 totalPendingRewards,
        uint256 totalClaimedRewards,
        uint256 totalInfusedZico
    ) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Calculate total pending rewards using internal logic to avoid external call
        (uint256 pendingRewards, ) = _calculateTotalPendingRewards();
        
        return (
            ss.totalStakedSpecimens,
            pendingRewards,
            ss.totalRewardsDistributed,
            ss.totalInfusedZico
        );
    }

    /**
     * @notice Get detailed staking information with wear level
     * @param collectionId Collection ID
     * @param tokenId Token ID
     */
    function getStakingDetailsWithWear(uint256 collectionId, uint256 tokenId) external view returns (
        address owner,
        uint8 variant,
        uint256 stakingTime,
        uint256 pendingReward,
        uint8 chargeLevel,
        uint8 wearLevel,
        uint8 wearPenalty
    ) {
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = LibStakingStorage.stakingStorage().stakedSpecimens[combinedId];
        
        if (staked.owner == address(0)) {
            return (address(0), 0, 0, 0, 0, 0, 0);
        }
        
        // Call the external view function for pending rewards
        uint256 rewards = 0;
        if (staked.staked) {
            try IStakingEarningsFacet(address(this)).getPendingReward(collectionId, tokenId) returns (uint256 amount) {
                rewards = amount;
            } catch {
                // Ignore errors
            }
            
            // Safety cap for rewards
            if (rewards > MAX_TOTAL_REWARD) {
                rewards = MAX_TOTAL_REWARD;
            }
        }
        
        return (
            staked.owner,
            staked.variant,
            block.timestamp - staked.stakedSince,
            rewards,
            staked.chargeLevel,
            staked.wearLevel,
            staked.wearPenalty
        );
    }

    /**
     * @notice Get all staked tokens for a collection owned by caller
     * @param collectionId Collection ID
     * @return tokenIds Array of staked token IDs from this collection
     */
    function getStakedTokensForCollection(uint256 collectionId) 
        external 
        view 
        returns (uint256[] memory tokenIds) 
    {
        address sender = LibMeta.msgSender();
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        if (collectionId == 0 || collectionId > ss.collectionCounter) {
            return new uint256[](0);
        }
        
        uint256[] storage allTokens = ss.stakerTokens[sender];
        if (allTokens.length == 0) {
            return new uint256[](0);
        }
        
        uint256[] memory tempTokenIds = new uint256[](allTokens.length);
        uint256 count = 0;
        
        for (uint256 i = 0; i < allTokens.length; i++) {
            uint256 combinedId = allTokens[i];
            StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
            
            if (!staked.staked || staked.owner != sender) {
                continue;
            }
            
            (uint256 tokenCollectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);
            
            if (tokenCollectionId == collectionId) {
                tempTokenIds[count] = tokenId;
                count++;
            }
        }
        
        // Resize array to actual count
        tokenIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            tokenIds[i] = tempTokenIds[i];
        }
        
        return tokenIds;
    }

    /**
     * @notice Check if an address is the staker of a token
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param staker Address to check
     * @return isStaker Whether the address is the staker
     */
    function isTokenStaker(uint256 collectionId, uint256 tokenId, address staker) external view returns (bool isStaker) {
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = LibStakingStorage.stakingStorage().stakedSpecimens[combinedId];
        
        return staked.staked && staked.owner == staker;
    }

    /**
     * @notice Get the address currently staking a specific token (Most efficient)
     * @dev Leverages the fact that we store collectionAddress in StakedSpecimen
     * @param collectionAddress The NFT collection contract address  
     * @param tokenId The token ID to query
     * @return staker The address of the account that staked this token (address(0) if not staked)
     */
    function getTokenStaker(address collectionAddress, uint256 tokenId) external view returns (address staker) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        if (ss.collectionCounter == 0) {
            return address(0);
        }
        
        for (uint256 collectionId = 1; collectionId <= ss.collectionCounter; collectionId++) {
            SpecimenCollection storage collection = ss.collections[collectionId];
            
            if (!collection.enabled || collection.collectionAddress != collectionAddress) {
                continue;
            }
            
            uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
            StakedSpecimen storage stakedToken = ss.stakedSpecimens[combinedId];
            
            if (stakedToken.staked) {
                return stakedToken.owner;
            }
            
            break;
        }
        
        return address(0);
    }

    /**
     * @notice Admin-only function to force unstake a token in case the regular unstaking fails
     * @dev This bypasses cooldown periods, fees, and other restrictions but maintains accounting
     * @param collectionId Collection ID of the token
     * @param tokenId Token ID to unstake
     * @param recipient Address that will receive the unstaked token (usually the original owner)
     * @return success Whether the emergency unstake was successful
     */
    function emergencyUnstake(
        uint256 collectionId,
        uint256 tokenId,
        address recipient
    ) external nonReentrant returns (bool success) {
        // Only authorized admins can use this function
        if (!AccessHelper.isAuthorized()) {
            revert UnauthorizedCaller();
        }
        
        // Get storage references
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Check collection validity
        if (collectionId == 0 || collectionId > ss.collectionCounter) {
            revert InvalidCollectionId();
        }
        
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        
        // Check if token is actually staked
        if (!staked.staked) {
            revert TokenNotStaked();
        }
        
        // Save token data for transfer
        address originalOwner = staked.owner;
        address collectionAddress = staked.collectionAddress;
        
        // Process pending rewards via StakingEarningsFacet (reward token system)
        try IStakingEarningsFacet(address(this)).processUnstakeRewards(collectionId, tokenId) {
            // Rewards processed successfully
        } catch {
            // Continue with emergency unstaking even if reward processing fails
        }

        // Clean up staked token data
        _cleanupStakedToken(ss, combinedId, tokenId, originalOwner);
        
        // Transfer token to recipient
        bool transferSuccessful;
        
        address tokenSource = _getTokenVaultAddress();
        try IERC721(collectionAddress).safeTransferFrom(tokenSource, recipient, tokenId) {
            transferSuccessful = true;
            emit TokenUnstaked(collectionId, tokenId, recipient);
            emit OperationResult("EmergencyUnstake", true);
        } catch {
            // Revert state if transfer fails
            _revertUnstakeState(ss, combinedId, collectionId, tokenId, originalOwner, collectionAddress);
            emit OperationResult("EmergencyUnstake", false);
            transferSuccessful = false;
        }
        
        return transferSuccessful;
    }

    /**
     * @notice Configure stake balance adjustment
     */
    function configureStakeBalance(
        bool enabled,
        uint256 decayRate,
        uint256 minMultiplier
    ) external {
        if (!AccessHelper.isAuthorized()) {
            revert UnauthorizedCaller();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Default moderate degradation configuration
        ss.settings.balanceAdjustment.enabled = enabled;
        ss.settings.balanceAdjustment.decayRate = decayRate == 0 ? 10 : decayRate;
        ss.settings.balanceAdjustment.minMultiplier = minMultiplier < 40 ? 50 : 
                                                (minMultiplier > 95 ? 95 : minMultiplier);
        
        emit OperationResult("StakeBalanceConfigured", true);
    }

    /**
     * @notice Configure time decay settings
     */
    function configureTimeDecay(
        bool enabled,
        uint256 maxBonus,
        uint256 period
    ) external {
        if (!AccessHelper.isAuthorized()) {
            revert UnauthorizedCaller();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Default moderate configuration
        ss.settings.timeDecay.enabled = enabled;
        ss.settings.timeDecay.maxBonus = maxBonus > 50 ? 30 : maxBonus;
        ss.settings.timeDecay.period = period == 0 ? 90 days : period;
        
        emit OperationResult("TimeDecayConfigured", true);
    }

    /**
     * @notice Set maximum tokens per staker
     */
    function setMaxTokensPerStaker(uint256 maxTokens) external {
        if (!AccessHelper.isAuthorized()) {
            revert UnauthorizedCaller();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        ss.settings.maxTokensPerStaker = maxTokens;
        
        emit OperationResult("MaxTokensPerStakerSet", true);
    }

    /**
     * @notice Resets reward balance settings to default values
     * @dev Uses constants defined in LibStakingStorage for consistency
     */
    function resetRewardBalanceSettings() external {
        // Verify authorization first
        if (!AccessHelper.isAuthorized()) {
            revert UnauthorizedCaller();
        }
        
        // Get reference to staking storage
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Reset balance adjustment settings (moderate decay)
        ss.settings.balanceAdjustment.enabled = true;
        ss.settings.balanceAdjustment.decayRate = LibStakingStorage.DEFAULT_DECAY_RATE;
        ss.settings.balanceAdjustment.minMultiplier = LibStakingStorage.DEFAULT_MIN_MULTIPLIER;
        ss.settings.balanceAdjustment.applyToInfusion = true;
        
        // Reset time decay settings (moderate bonus)
        ss.settings.timeDecay.enabled = true;
        ss.settings.timeDecay.maxBonus = LibStakingStorage.DEFAULT_TIME_BONUS;
        ss.settings.timeDecay.period = LibStakingStorage.DEFAULT_TIME_PERIOD;
        
        // Set max tokens per staker (0 = unlimited)
        ss.settings.maxTokensPerStaker = 0;
        
        // Enable tiered fees
        ss.settings.tieredFees.enabled = true;
        
        // Only initialize arrays if they're empty
        // This avoids potential issues with array manipulation
        if (ss.settings.tieredFees.thresholds.length == 0) {
            // Tier 1: 0-100 ZICO: 1%
            ss.settings.tieredFees.thresholds.push(100 ether);
            // Tier 2: 100-1000 ZICO: 2%
            ss.settings.tieredFees.thresholds.push(1000 ether);
            // Tier 3: >1000 ZICO: 3%
            ss.settings.tieredFees.thresholds.push(10000 ether);
        }
        
        if (ss.settings.tieredFees.feeBps.length == 0) {
            // 1% fee for first tier
            ss.settings.tieredFees.feeBps.push(100);
            // 2% fee for second tier
            ss.settings.tieredFees.feeBps.push(200);
            // 3% fee for third tier
            ss.settings.tieredFees.feeBps.push(300);
        }
        
        // Emit success event
        emit OperationResult("RewardBalanceSettingsReset", true);
    }

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
        address sender
    ) private {
        // Initialize staked token data
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        uint32 currentTime = uint32(block.timestamp);
        
        staked.staked = true;
        staked.owner = sender;
        staked.collectionId = collectionId;
        staked.tokenId = tokenId;
        staked.stakedSince = currentTime;
        
        // CRITICAL: Initialize ALL timers to current time
        staked.lastClaimTimestamp = currentTime;      // For reward calculations
        staked.lastWearUpdateTime = currentTime;      // For natural wear progression
        staked.lastWearRepairTime = currentTime;      // For repair cooldowns
        staked.lastSyncTimestamp = currentTime;       // For external sync
        
        // Token characteristics
        staked.variant = variant;
        staked.level = 1;
        staked.experience = 0;
        staked.chargeLevel = 100;
        staked.wearLevel = 0;
        staked.infusionLevel = 0;
        staked.wearPenalty = 0;
        staked.specialization = 0;
        staked.colonyId = bytes32(0);
        staked.collectionAddress = collectionAddress;
        
        // Rest of initialization...
        ss.tokenCollectionIds[tokenId] = collectionId;
        ss.stakerTokens[sender].push(combinedId);
        ss.totalStakedSpecimens++;
        
        LibStakingStorage.updateChargeBonus(collectionId, tokenId, 100);
        LibStakingStorage.addActiveStaker(sender);
    }

    /**
     * @notice Update colony membership during staking
     * @param combinedId Combined token ID
     * @param staked Reference to the staked specimen storage
     */
    function _updateColonyMembershipOnStake(uint256 combinedId, StakedSpecimen storage staked) private {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Check for pending colony assignment
        bytes32 pendingColony = ss.tokenPendingColonyAssignments[combinedId];
        if (pendingColony != bytes32(0)) {
            // Apply pending colony assignment
            staked.colonyId = pendingColony;
            staked.lastSyncTimestamp = uint32(block.timestamp);
            
            // Clear the pending assignment
            delete ss.tokenPendingColonyAssignments[combinedId];
        } else {
            // If no pending assignment, check if token is in a colony in Chargepod
            _checkColonyMembershipInChargepod(combinedId, staked);
        }
    }

    /**
     * @notice Check if token belongs to a colony in Chargepod
     * @param combinedId Combined token ID
     * @param staked Reference to the staked specimen storage
     */
    function _checkColonyMembershipInChargepod(uint256 combinedId, StakedSpecimen storage staked) private {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        address chargepodAddress = ss.chargeSystemAddress;
        
        if (chargepodAddress == address(0)) {
            return;
        }
        
        (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);
        
        try IColonyFacet(chargepodAddress).getTokenColony(collectionId, tokenId) returns (bytes32 colonyId) {
            if (colonyId != bytes32(0)) {
                // Token is in a colony according to Chargepod
                staked.colonyId = colonyId;
                staked.lastSyncTimestamp = uint32(block.timestamp);
            }
        } catch {
            // Ignore errors and continue without colony assignment
        }
    }

    /**
     * @notice Clean up staked token data during unstaking
     */
    function _cleanupStakedToken(
        LibStakingStorage.StakingStorage storage ss,
        uint256 combinedId,
        uint256 tokenId,
        address owner
    ) private {
        // Remove token from staker's list
        uint256[] storage tokens = ss.stakerTokens[owner];
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == combinedId) {
                // Swap with last element and pop
                tokens[i] = tokens[tokens.length - 1];
                tokens.pop();
                break;
            }
        }
        
        // Delete token data
        delete ss.stakedSpecimens[combinedId];
        delete ss.tokenCollectionIds[tokenId];
        
        // Decrement counter
        if (ss.totalStakedSpecimens > 0) {
            ss.totalStakedSpecimens--;
        }

        LibStakingStorage.removeActiveStakerIfEmpty(owner);
    }

    /**
     * @notice Revert state changes if the token transfer fails during unstaking
     * @dev Used for both regular unstake and emergency unstake operations
     */
    function _revertUnstakeState(
        LibStakingStorage.StakingStorage storage ss,
        uint256 combinedId,
        uint256 collectionId,
        uint256 tokenId,
        address owner,
        address collectionAddress
    ) private {
        // Re-initialize staked token data
        StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];
        staked.staked = true;
        staked.owner = owner;
        staked.collectionId = collectionId;
        staked.tokenId = tokenId;
        staked.collectionAddress = collectionAddress;
        
        // Add back to owner's tokens list
        ss.stakerTokens[owner].push(combinedId);
        
        // Restore collection mapping
        ss.tokenCollectionIds[tokenId] = collectionId;
        
        // Increment staked counter
        ss.totalStakedSpecimens++;
    }

    /**
     * @notice Returns the actual address where tokens should be stored or retrieved from
     * @dev When useExternalVault is false, returns the diamond address regardless of vaultAddress
     * @return tokenDestination The actual address to use for token operations
     */
    function _getTokenVaultAddress() internal view returns (address tokenDestination) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        if (ss.vaultConfig.useExternalVault) {
            // Critical safety check to prevent token loss
            if (ss.vaultConfig.vaultAddress == address(0)) {
                // Fall back to treasury or diamond address if vault address is zero
                return ss.settings.treasuryAddress != address(0) ? 
                    ss.settings.treasuryAddress : address(this);
            }
            return ss.vaultConfig.vaultAddress;
        } else {
            return address(this); // Diamond address is used when useExternalVault is false
        }
    }

    /**
     * @notice Get token variant from collection contract with fallbacks
     */
    function _getTokenVariant(address collectionAddress, uint256 tokenId) private view returns (uint8 variant) {
        try IExternalCollection(collectionAddress).itemVariant(tokenId) returns (uint8 v) {
            variant = v;
            if (variant < 1 || variant > MAX_VARIANT) {
                revert InvalidVariantRange();
            }
        } catch {
            // Set a default variant if retrieval fails
            variant = 1;
        }
        
        return variant;
    }

    /**
     * @dev Helper function to check if a colony exists using unified validation
     * @param ss Storage reference
     * @param colonyId Colony ID to verify
     * @return valid Whether the colony exists
     */
    function _isValidColony(LibStakingStorage.StakingStorage storage ss, bytes32 colonyId) private view returns (bool valid) {
        // Use LibStakingStorage function for consistent validation
        return LibStakingStorage.isColonyValid(ss, colonyId);
    }

    /**
     * @notice Calculate total pending rewards across all staked tokens
     * @dev Iterates through all staked tokens to calculate sum of pending rewards
     * @return pendingRewards Total pending rewards
     * @return tokenCount Count of tokens with pending rewards
     */
    function _calculateTotalPendingRewards() private view returns (uint256 pendingRewards, uint256 tokenCount) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        pendingRewards = 0;
        tokenCount = 0;
        
        // Get all unique stakers
        address[] memory stakers = getAllUniqueStakers();
        
        // Iterate through each staker
        for (uint256 i = 0; i < stakers.length; i++) {
            address staker = stakers[i];
            
            // Get all tokens staked by this address
            uint256[] memory tokens = ss.stakerTokens[staker];
            
            // Iterate through each staked token
            for (uint256 j = 0; j < tokens.length; j++) {
                uint256 combinedId = tokens[j];
                
                // Extract collection and token IDs from the combined ID
                (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);
                
                // Skip if the token is not staked (just a safety check)
                if (!ss.stakedSpecimens[combinedId].staked) {
                    continue;
                }
                
                // Calculate pending rewards for this token
                uint256 tokenRewards = 0;
                try IStakingEarningsFacet(address(this)).getPendingReward(collectionId, tokenId) returns (uint256 rewards) {
                    tokenRewards = rewards;
                } catch {
                    // Ignore errors and continue with next token
                }
                
                // Add to total
                pendingRewards += tokenRewards;
                tokenCount++;
            }
        }
        
        // Apply safety cap to avoid overflow
        if (pendingRewards > MAX_TOTAL_REWARD) {
            pendingRewards = MAX_TOTAL_REWARD;
        }
        
        return (pendingRewards, tokenCount);
    }

}