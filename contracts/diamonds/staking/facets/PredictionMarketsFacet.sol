// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibPremiumStorage} from "../../chargepod/libraries/LibPremiumStorage.sol";
import {LibStakingStorage} from "../libraries/LibStakingStorage.sol";
import {LibHenomorphsStorage} from "../../chargepod/libraries/LibHenomorphsStorage.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {ResourceHelper} from "../../chargepod/libraries/ResourceHelper.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {PodsUtils} from "../../../libraries/PodsUtils.sol";
import {IExternalBiopod} from "../interfaces/IStakingInterfaces.sol";
import {Calibration, SpecimenCollection} from "../../../libraries/HenomorphsModel.sol";
import {StakedSpecimen} from "../../../libraries/StakingModel.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IExternalStaking
 * @notice Interface for external Staking Diamond calls
 */
interface IExternalStaking {
    function getStakedTokensByAddress(address staker) external view returns (uint256[] memory);
    function getStakedTokenData(uint256 collectionId, uint256 tokenId) external view returns (StakedSpecimen memory);
}

/**
 * @title PredictionMarketsFacet
 * @notice Prediction markets with AMM pricing inspired by Polymarket and Augur
 * @dev Diamond facet implementing decentralized prediction markets with staking bonuses
 * @dev V3.0.0 - Full implementation with AMM liquidity, disputes, refunds
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 * @custom:version 3.0.0 - Complete mechanics implementation
 */
contract PredictionMarketsFacet is AccessControlBase {

    // ==================== CONSTANTS ====================

    uint256 constant MIN_LIQUIDITY = 1000 ether;      // Minimum liquidity for AMM
    uint256 constant LP_FEE_BPS = 30;                  // 0.3% LP fee
    uint256 constant DISPUTE_QUORUM_BPS = 1000;        // 10% of total pool for quorum
    uint256 constant DISPUTE_MAJORITY_BPS = 6000;      // 60% majority to overturn

    // Time-Weighted Shares: early bettors get more shares for same amount
    uint256 constant TIME_BONUS_MAX_BPS = 5000;       // 50% max bonus at market open
    uint256 constant TIME_BONUS_MIN_BPS = 5000;       // 50% penalty at lock time (multiplier = 50%)

    // Stake Balance: prevent extreme imbalance on single outcome
    uint256 constant MAX_OUTCOME_SHARE_BPS = 9000;    // Max 90% of pool on single outcome

    // ==================== STRUCTS FOR PARAMETER GROUPING ====================

    struct MarketParams {
        LibPremiumStorage.MarketType marketType;
        bytes32 questionHash;
        uint40 lockTime;
        uint40 resolutionTime;
        address resolver;
        uint256 minBet;
        uint256 maxBet;
        uint256 creatorFee;
        bytes32 linkedEntity;
    }

    // ==================== EVENTS ====================

    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        LibPremiumStorage.MarketType marketType,
        bytes32 questionHash,
        uint8 outcomeCount,
        uint40 lockTime,
        uint40 resolutionTime
    );

    event BetPlaced(
        uint256 indexed marketId,
        address indexed user,
        uint8 outcome,
        uint256 ylwAmount,
        uint256 shares,
        uint256 stakingBonus
    );

    event MarketResolved(
        uint256 indexed marketId,
        uint8 winningOutcome,
        address indexed resolver,
        uint256 totalPool
    );

    event WinningsClaimed(
        uint256 indexed marketId,
        address indexed user,
        uint256 payout,
        uint256 profitAmount
    );

    event RefundClaimed(
        uint256 indexed marketId,
        address indexed user,
        uint256 refundAmount
    );

    event MarketDisputed(
        uint256 indexed marketId,
        address indexed disputer,
        uint8 proposedOutcome,
        uint256 bondAmount
    );

    event DisputeVoteCast(
        uint256 indexed marketId,
        uint256 indexed disputeIndex,
        address indexed voter,
        bool votedFor,
        uint256 voteWeight
    );

    event DisputeResolved(
        uint256 indexed marketId,
        uint256 disputeIndex,
        bool upheld,
        uint8 newOutcome
    );

    event LiquidityAdded(
        uint256 indexed marketId,
        address indexed provider,
        uint256 amount,
        uint256 lpShares
    );

    event LiquidityRemoved(
        uint256 indexed marketId,
        address indexed provider,
        uint256 lpShares,
        uint256 amountReturned
    );

    event SharesSwapped(
        uint256 indexed marketId,
        address indexed user,
        uint8 fromOutcome,
        uint8 toOutcome,
        uint256 amountIn,
        uint256 amountOut
    );

    event MarketCancelled(
        uint256 indexed marketId,
        string reason
    );

    event MarketStatusChanged(
        uint256 indexed marketId,
        LibPremiumStorage.MarketStatus oldStatus,
        LibPremiumStorage.MarketStatus newStatus
    );

    event PredictionMarketsReset(
        uint256 indexed timestamp,
        uint256 newMinCreatorBond,
        uint16 newDefaultProtocolFee
    );

    event MarketLockTimeUpdated(
        uint256 indexed marketId,
        uint40 oldLockTime,
        uint40 newLockTime
    );

    // ==================== ERRORS ====================

    error MarketsDisabled();
    error MarketNotFound();
    error MarketNotOpen();
    error MarketLocked();
    error MarketNotLocked();
    error MarketAlreadyResolved();
    error MarketNotResolved();
    error MarketNotCancelled();
    error MarketNotDisputed();
    error InvalidOutcome();
    error InvalidMarketType();
    error BelowMinBet();
    error AboveMaxBet();
    error InsufficientBond();
    error NotMarketCreator();
    error NotResolver();
    error DisputeWindowClosed();
    error DisputeNotFound();
    error AlreadyVoted();
    error AlreadyClaimed();
    error AlreadyRefunded();
    error NoWinnings();
    error NoStake();
    error InvalidTimeConfiguration();
    error UnauthorizedCreator();
    error InvalidAddress();
    error InvalidCreatorFee();
    error InsufficientLiquidity();
    error NoLpShares();
    error AMMNotInitialized();
    error SameOutcome();
    error InsufficientShares();
    error DisputeAlreadyResolved();
    error QuorumNotReached();
    error ArrayLengthMismatch();
    error StakeImbalanceTooHigh();

    // ==================== INITIALIZATION ====================

    /**
     * @notice Initialize prediction markets
     * @dev Treasury configuration comes from LibHenomorphsStorage.chargeTreasury
     */
    function initializePredictionMarkets(
        address /* _ylwToken */,     // Ignored - uses central treasury config
        address /* _zicoToken */,    // Ignored - uses central treasury config
        address /* _treasury */,     // Ignored - uses central treasury config
        uint256 _minCreatorBond,
        uint16 _defaultProtocolFee
    ) external onlyAuthorized {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        
        ps.minCreatorBond = _minCreatorBond;
        ps.defaultProtocolFee = _defaultProtocolFee;
        ps.maxCreatorFee = 1000;           // Max 10%
        ps.stakingBonusBps = 20;           // 0.2% per staking level
        ps.defaultDisputeWindow = 3 days;
        ps.marketsEnabled = true;
    }

    // ==================== MARKET CREATION ====================

    /**
     * @notice Create new prediction market
     */
    function createMarket(
        LibPremiumStorage.MarketType marketType,
        bytes32 questionHash,
        string[] calldata outcomes,
        uint40 lockTime,
        uint40 resolutionTime,
        address resolver,
        uint256 minBet,
        uint256 maxBet,
        uint256 creatorFee,
        bytes32 linkedEntity
    ) external nonReentrant whenNotPaused returns (uint256 marketId) {
        MarketParams memory params = MarketParams({
            marketType: marketType,
            questionHash: questionHash,
            lockTime: lockTime,
            resolutionTime: resolutionTime,
            resolver: resolver,
            minBet: minBet,
            maxBet: maxBet,
            creatorFee: creatorFee,
            linkedEntity: linkedEntity
        });

        marketId = _validateAndCreateMarket(params, outcomes);
        _initializeMarketOutcomes(marketId, outcomes);
        _finalizeMarketCreation(marketId, params);

        return marketId;
    }

    function _validateAndCreateMarket(
        MarketParams memory params,
        string[] calldata outcomes
    ) internal returns (uint256 marketId) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        
        if (!ps.marketsEnabled) revert MarketsDisabled();
        
        address creator = LibMeta.msgSender();
        
        if (!ps.authorizedCreators[creator] && !AccessHelper.isAuthorized()) {
            revert UnauthorizedCreator();
        }

        if (outcomes.length < 2 || outcomes.length > 10) revert InvalidOutcome();
        if (params.lockTime <= block.timestamp || params.lockTime >= params.resolutionTime) {
            revert InvalidTimeConfiguration();
        }
        if (params.creatorFee > ps.maxCreatorFee) revert InvalidCreatorFee();
        
        address finalResolver = params.resolver;
        if (finalResolver == address(0)) {
            finalResolver = creator;
        }

        // Collect creator bond if required
        uint256 bondAmount = ps.minCreatorBond;
        if (bondAmount > 0) {
            ResourceHelper.collectAuxiliaryFee(creator, bondAmount, "market_creator_bond");
        }

        // Create market
        marketId = ++ps.marketCounter;
        
        ps.markets[marketId] = LibPremiumStorage.PredictionMarket({
            marketType: params.marketType,
            status: LibPremiumStorage.MarketStatus.OPEN,
            questionHash: params.questionHash,
            outcomeCount: uint8(outcomes.length),
            openTime: uint40(block.timestamp),
            lockTime: params.lockTime,
            resolutionTime: params.resolutionTime,
            resolvedAt: 0,
            winningOutcome: 0,
            creator: creator,
            resolver: finalResolver,
            creatorFee: params.creatorFee,
            protocolFee: ps.defaultProtocolFee,
            totalPool: 0,
            creatorBond: bondAmount,
            minBet: params.minBet,
            maxBet: params.maxBet,
            linkedEntity: params.linkedEntity,
            allowDisputes: true,
            disputeWindow: ps.defaultDisputeWindow
        });

        return marketId;
    }

    function _initializeMarketOutcomes(
        uint256 marketId,
        string[] calldata outcomes
    ) internal {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        
        uint256 outcomeCount = outcomes.length;
        uint256 equalProb = 10000 / outcomeCount;

        for (uint8 i = 0; i < outcomeCount; i++) {
            ps.marketOutcomes[marketId][i] = LibPremiumStorage.MarketOutcome({
                description: outcomes[i],
                pool: 0,
                shares: 0,
                impliedProb: equalProb
            });
        }
    }

    function _finalizeMarketCreation(
        uint256 marketId,
        MarketParams memory params
    ) internal {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.PredictionMarket memory market = ps.markets[marketId];

        // Add to status tracking
        ps.marketsByStatus[LibPremiumStorage.MarketStatus.OPEN].push(marketId);
        
        // Add to entity tracking if linked
        if (params.linkedEntity != bytes32(0)) {
            ps.marketsByEntity[params.linkedEntity].push(marketId);
        }

        emit MarketCreated(
            marketId,
            market.creator,
            params.marketType,
            params.questionHash,
            market.outcomeCount,
            params.lockTime,
            params.resolutionTime
        );
    }

    // ==================== BETTING ====================

    /**
     * @notice Place bet on outcome
     */
    function placeBet(
        uint256 marketId,
        uint8 outcome,
        uint256 ylwAmount
    ) external nonReentrant whenNotPaused returns (uint256 shares) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.PredictionMarket storage market = ps.markets[marketId];

        _validateBet(market, outcome, ylwAmount);

        address user = LibMeta.msgSender();

        // Calculate staking bonus
        uint256 stakingBonus = _calculateStakingBonus(user, ylwAmount);
        uint256 effectiveAmount = ylwAmount + stakingBonus;

        // Transfer tokens
        ResourceHelper.collectAuxiliaryFee(user, ylwAmount, "market_bet");

        // Calculate and update shares
        shares = _updateMarketPools(marketId, outcome, ylwAmount, effectiveAmount);

        // Update user position
        _updateUserPosition(marketId, user, outcome, ylwAmount, shares, stakingBonus);

        // Update probabilities
        _updateImpliedProbabilities(marketId);

        emit BetPlaced(marketId, user, outcome, ylwAmount, shares, stakingBonus);

        return shares;
    }

    function _validateBet(
        LibPremiumStorage.PredictionMarket storage market,
        uint8 outcome,
        uint256 ylwAmount
    ) internal view {
        if (market.openTime == 0) revert MarketNotFound();
        if (market.status != LibPremiumStorage.MarketStatus.OPEN) revert MarketNotOpen();
        if (block.timestamp >= market.lockTime) revert MarketLocked();
        if (outcome >= market.outcomeCount) revert InvalidOutcome();
        if (ylwAmount < market.minBet) revert BelowMinBet();
        if (market.maxBet > 0 && ylwAmount > market.maxBet) revert AboveMaxBet();
    }

    function _updateMarketPools(
        uint256 marketId,
        uint8 outcome,
        uint256 ylwAmount,
        uint256 effectiveAmount
    ) internal returns (uint256 shares) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.PredictionMarket storage market = ps.markets[marketId];
        LibPremiumStorage.MarketOutcome storage outcomeData = ps.marketOutcomes[marketId][outcome];

        // Apply time-weighted multiplier (early bettors get more shares)
        uint256 timeWeightedAmount = _applyTimeMultiplier(effectiveAmount, market.openTime, market.lockTime);

        if (outcomeData.pool == 0) {
            shares = timeWeightedAmount;
        } else {
            shares = (timeWeightedAmount * outcomeData.shares) / outcomeData.pool;
        }

        // Check stake balance before updating pools
        _checkStakeBalance(marketId, outcome, ylwAmount, market);

        outcomeData.pool += ylwAmount;
        outcomeData.shares += shares;
        market.totalPool += ylwAmount;

        return shares;
    }

    /**
     * @notice Calculate time-weighted multiplier for shares
     * @dev Early bettors get up to 50% more shares, late bettors get 50% less
     * @param amount Base amount
     * @param openTime Market open time
     * @param lockTime Market lock time
     * @return Adjusted amount with time multiplier applied
     */
    function _applyTimeMultiplier(
        uint256 amount,
        uint40 openTime,
        uint40 lockTime
    ) internal view returns (uint256) {
        if (block.timestamp <= openTime) {
            // At or before open: max bonus (150%)
            return (amount * (10000 + TIME_BONUS_MAX_BPS)) / 10000;
        }

        if (block.timestamp >= lockTime) {
            // At or after lock: min multiplier (50%)
            return (amount * TIME_BONUS_MIN_BPS) / 10000;
        }

        // Linear interpolation between open and lock
        // At open: multiplier = 15000 (150%)
        // At lock: multiplier = 5000 (50%)
        uint256 totalWindow = lockTime - openTime;
        uint256 elapsed = block.timestamp - openTime;
        uint256 percentElapsed = (elapsed * 10000) / totalWindow;

        // Multiplier decreases from 15000 to 5000 as time progresses
        uint256 multiplier = 10000 + TIME_BONUS_MAX_BPS - (percentElapsed * (TIME_BONUS_MAX_BPS + (10000 - TIME_BONUS_MIN_BPS))) / 10000;

        return (amount * multiplier) / 10000;
    }

    /**
     * @notice Check if bet would create excessive imbalance on single outcome
     * @dev Prevents one outcome from having more than 90% of pool
     * @param marketId Market ID
     * @param outcome Outcome being bet on
     * @param newAmount Amount being added
     * @param market Market storage reference
     */
    function _checkStakeBalance(
        uint256 marketId,
        uint8 outcome,
        uint256 newAmount,
        LibPremiumStorage.PredictionMarket storage market
    ) internal view {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();

        // Calculate total on all other outcomes (BEFORE this bet)
        uint256 otherOutcomesTotal = 0;
        for (uint8 i = 0; i < market.outcomeCount; i++) {
            if (i != outcome) {
                otherOutcomesTotal += ps.marketOutcomes[marketId][i].pool;
            }
        }

        // If no bets on other outcomes yet, allow any bet (market needs to start somehow)
        if (otherOutcomesTotal == 0) return;

        // Calculate total on this outcome after bet
        uint256 thisOutcomeTotal = ps.marketOutcomes[marketId][outcome].pool + newAmount;

        // Check if this outcome would exceed MAX_OUTCOME_SHARE_BPS (90%)
        uint256 totalPool = thisOutcomeTotal + otherOutcomesTotal;
        uint256 thisOutcomePercent = (thisOutcomeTotal * 10000) / totalPool;
        if (thisOutcomePercent > MAX_OUTCOME_SHARE_BPS) {
            revert StakeImbalanceTooHigh();
        }
    }

    function _updateUserPosition(
        uint256 marketId,
        address user,
        uint8 outcome,
        uint256 ylwAmount,
        uint256 shares,
        uint256 stakingBonus
    ) internal {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();

        ps.positionOutcomeStakes[marketId][user][outcome] += ylwAmount;
        ps.positionOutcomeShares[marketId][user][outcome] += shares;
        
        uint256 prevTotalStaked = ps.positionTotalStaked[marketId][user];
        ps.positionTotalStaked[marketId][user] += ylwAmount;
        ps.positionStakingBonus[marketId][user] += stakingBonus;
        ps.positionLastBetTime[marketId][user] = uint40(block.timestamp);

        ps.userProfiles[user].totalWagered += ylwAmount;
        ps.userProfiles[user].marketsParticipated++;

        if (prevTotalStaked == 0) {
            ps.userMarkets[user].push(marketId);
        }
    }

    /**
     * @notice Calculate staking bonus for user based on staked NFT levels
     * @dev Checks external Staking Diamond for staked tokens and uses highest level for bonus
     * @dev Also checks local Chargepod staking (MultiCollectionStakingFacet, ColonySquadStakingFacet)
     */
    function _calculateStakingBonus(address user, uint256 amount)
        internal
        view
        returns (uint256 bonus)
    {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();

        uint8 maxLevel = 0;

        // 1. Check EXTERNAL Staking Diamond (main staking)
        address stakingSystem = hs.stakingSystemAddress;
        if (stakingSystem != address(0)) {
            try IExternalStaking(stakingSystem).getStakedTokensByAddress(user) returns (uint256[] memory externalTokens) {
                for (uint256 i = 0; i < externalTokens.length; i++) {
                    uint256 combinedId = externalTokens[i];
                    (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);

                    // Get level from Biopod (which is this Chargepod diamond)
                    SpecimenCollection storage collection = ss.collections[collectionId];
                    if (collection.biopodAddress != address(0)) {
                        try IExternalBiopod(collection.biopodAddress).probeCalibration(collectionId, tokenId) returns (Calibration memory cal) {
                            if (cal.level > maxLevel) {
                                maxLevel = uint8(cal.level);
                            }
                        } catch {}
                    }
                }
            } catch {}
        }

        // 2. Check LOCAL Chargepod staking (MultiCollectionStakingFacet, ColonySquadStakingFacet)
        uint256[] memory localTokens = ss.stakerTokens[user];
        for (uint256 i = 0; i < localTokens.length; i++) {
            uint256 combinedId = localTokens[i];
            StakedSpecimen storage staked = ss.stakedSpecimens[combinedId];

            if (!staked.staked) continue;

            (uint256 collectionId, uint256 tokenId) = PodsUtils.extractIds(combinedId);

            SpecimenCollection storage collection = ss.collections[collectionId];
            if (collection.biopodAddress != address(0)) {
                try IExternalBiopod(collection.biopodAddress).probeCalibration(collectionId, tokenId) returns (Calibration memory cal) {
                    if (cal.level > maxLevel) {
                        maxLevel = uint8(cal.level);
                    }
                } catch {}
            }
        }

        // No staked tokens found
        if (maxLevel == 0) return 0;

        // Calculate bonus: level * stakingBonusBps, max 20% (2000 bps)
        uint256 bonusBps = uint256(maxLevel) * ps.stakingBonusBps;
        if (bonusBps > 2000) bonusBps = 2000;

        return (amount * bonusBps) / 10000;
    }

    // ==================== RESOLUTION ====================

    /**
     * @notice Resolve market with winning outcome
     */
    function resolveMarket(
        uint256 marketId,
        uint8 winningOutcome
    ) external nonReentrant whenNotPaused {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.PredictionMarket storage market = ps.markets[marketId];

        address resolver = LibMeta.msgSender();
        if (resolver != market.resolver && !AccessHelper.isAuthorized()) {
            revert NotResolver();
        }

        if (market.status != LibPremiumStorage.MarketStatus.OPEN && 
            market.status != LibPremiumStorage.MarketStatus.LOCKED) {
            revert MarketNotOpen();
        }
        if (block.timestamp < market.lockTime) revert MarketNotLocked();
        if (winningOutcome >= market.outcomeCount) revert InvalidOutcome();

        // Update status
        LibPremiumStorage.MarketStatus oldStatus = market.status;
        market.winningOutcome = winningOutcome;
        market.resolvedAt = uint40(block.timestamp);
        market.status = LibPremiumStorage.MarketStatus.RESOLVED;

        // Update status tracking
        _updateMarketStatusTracking(ps, marketId, oldStatus, LibPremiumStorage.MarketStatus.RESOLVED);

        // Update resolver stats
        ps.resolvers[resolver].marketsResolved++;
        ps.resolvers[resolver].totalVolume += market.totalPool;
        ps.resolvers[resolver].lastActiveTime = uint40(block.timestamp);

        // Return creator bond
        if (market.creatorBond > 0) {
            LibFeeCollection.transferFromTreasury(market.creator, market.creatorBond, "creator_bond_return");
        }

        emit MarketResolved(marketId, winningOutcome, resolver, market.totalPool);
        emit MarketStatusChanged(marketId, oldStatus, LibPremiumStorage.MarketStatus.RESOLVED);
    }

    /**
     * @notice Claim winnings from resolved market
     */
    function claimWinnings(uint256 marketId) 
        external 
        nonReentrant 
        whenNotPaused 
        returns (uint256 payout) 
    {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.PredictionMarket storage market = ps.markets[marketId];
        
        if (market.status != LibPremiumStorage.MarketStatus.RESOLVED) revert MarketNotResolved();

        address user = LibMeta.msgSender();
        
        if (ps.positionClaimed[marketId][user]) revert AlreadyClaimed();
        
        uint256 userTotalStaked = ps.positionTotalStaked[marketId][user];
        if (userTotalStaked == 0) revert NoStake();

        // Calculate payout
        payout = _calculateWinningPayout(marketId, user, market);
        
        // Mark as claimed
        ps.positionClaimed[marketId][user] = true;
        
        if (payout == 0) {
            ps.userProfiles[user].totalLost += userTotalStaked;
            return 0;
        }

        // Distribute fees and payout
        uint256 netPayout = _distributeFees(market, payout, ps);

        // Transfer winnings
        LibFeeCollection.transferFromTreasury(user, netPayout, "market_winnings");

        // Update user stats
        _updateUserWinnings(user, userTotalStaked, netPayout, ps);

        emit WinningsClaimed(marketId, user, netPayout, netPayout > userTotalStaked ? netPayout - userTotalStaked : 0);

        return netPayout;
    }

    /**
     * @notice Claim refund from cancelled market
     */
    function claimRefund(uint256 marketId) 
        external 
        nonReentrant 
        whenNotPaused 
        returns (uint256 refundAmount) 
    {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.PredictionMarket storage market = ps.markets[marketId];
        
        if (market.status != LibPremiumStorage.MarketStatus.CANCELLED) revert MarketNotCancelled();

        address user = LibMeta.msgSender();
        
        if (ps.refundClaimed[marketId][user]) revert AlreadyRefunded();
        
        refundAmount = ps.positionTotalStaked[marketId][user];
        if (refundAmount == 0) revert NoStake();

        // Mark as refunded
        ps.refundClaimed[marketId][user] = true;

        // Transfer refund
        LibFeeCollection.transferFromTreasury(user, refundAmount, "market_refund");

        emit RefundClaimed(marketId, user, refundAmount);

        return refundAmount;
    }

    function _calculateWinningPayout(
        uint256 marketId,
        address user,
        LibPremiumStorage.PredictionMarket storage market
    ) internal view returns (uint256 payout) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        
        uint8 winningOutcome = market.winningOutcome;
        uint256 userShares = ps.positionOutcomeShares[marketId][user][winningOutcome];

        if (userShares == 0) return 0;

        LibPremiumStorage.MarketOutcome storage outcome = ps.marketOutcomes[marketId][winningOutcome];
        return (userShares * market.totalPool) / outcome.shares;
    }

    function _distributeFees(
        LibPremiumStorage.PredictionMarket storage market,
        uint256 payout,
        LibPremiumStorage.PremiumStorage storage ps
    ) internal returns (uint256 netPayout) {
        uint256 protocolFee = (payout * market.protocolFee) / 10000;
        uint256 creatorFee = (payout * market.creatorFee) / 10000;
        netPayout = payout - protocolFee - creatorFee;

        // Protocol fee stays in treasury
        ps.protocolFeesCollected += protocolFee;
        
        // Creator fee goes to creator
        if (creatorFee > 0) {
            LibFeeCollection.transferFromTreasury(market.creator, creatorFee, "market_creator_fee");
            ps.creatorFeesCollected += creatorFee;
        }

        return netPayout;
    }

    function _updateUserWinnings(
        address user,
        uint256 userTotalStaked,
        uint256 netPayout,
        LibPremiumStorage.PremiumStorage storage ps
    ) internal {
        uint256 profit = netPayout > userTotalStaked ? netPayout - userTotalStaked : 0;
        
        ps.userProfiles[user].totalWon += netPayout;
        ps.userProfiles[user].marketsWon++;
        
        if (profit > 0) {
            ps.userProfiles[user].streakCurrent++;
            if (ps.userProfiles[user].streakCurrent > ps.userProfiles[user].streakBest) {
                ps.userProfiles[user].streakBest = ps.userProfiles[user].streakCurrent;
            }
        } else {
            ps.userProfiles[user].streakCurrent = 0;
        }

        ps.userProfiles[user].winRate = uint16(
            (ps.userProfiles[user].marketsWon * 10000) / ps.userProfiles[user].marketsParticipated
        );
    }

    // ==================== DISPUTES ====================

    /**
     * @notice Dispute market resolution
     */
    function disputeResolution(
        uint256 marketId,
        uint8 proposedOutcome
    ) external nonReentrant whenNotPaused {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.PredictionMarket storage market = ps.markets[marketId];

        if (market.status != LibPremiumStorage.MarketStatus.RESOLVED) revert MarketNotResolved();
        if (!market.allowDisputes) revert DisputeWindowClosed();
        if (block.timestamp > market.resolvedAt + market.disputeWindow) revert DisputeWindowClosed();
        if (proposedOutcome >= market.outcomeCount) revert InvalidOutcome();

        address disputer = LibMeta.msgSender();
        uint256 bondAmount = market.totalPool / 100; // 1% of pool as bond

        // Collect dispute bond
        ResourceHelper.collectAuxiliaryFee(disputer, bondAmount, "dispute_bond");

        ps.disputes[marketId].push(LibPremiumStorage.MarketDispute({
            disputer: disputer,
            proposedOutcome: proposedOutcome,
            bondAmount: bondAmount,
            timestamp: uint40(block.timestamp),
            votesFor: 0,
            votesAgainst: 0,
            resolved: false
        }));

        // Update status
        LibPremiumStorage.MarketStatus oldStatus = market.status;
        market.status = LibPremiumStorage.MarketStatus.DISPUTED;
        _updateMarketStatusTracking(ps, marketId, oldStatus, LibPremiumStorage.MarketStatus.DISPUTED);

        emit MarketDisputed(marketId, disputer, proposedOutcome, bondAmount);
        emit MarketStatusChanged(marketId, oldStatus, LibPremiumStorage.MarketStatus.DISPUTED);
    }

    /**
     * @notice Vote on a dispute
     * @param marketId Market ID
     * @param disputeIndex Index of dispute in disputes array
     * @param voteFor True to support the dispute, false to oppose
     */
    function voteOnDispute(
        uint256 marketId,
        uint256 disputeIndex,
        bool voteFor
    ) external nonReentrant whenNotPaused {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.PredictionMarket storage market = ps.markets[marketId];
        
        if (market.status != LibPremiumStorage.MarketStatus.DISPUTED) revert MarketNotDisputed();
        if (disputeIndex >= ps.disputes[marketId].length) revert DisputeNotFound();
        
        LibPremiumStorage.MarketDispute storage dispute = ps.disputes[marketId][disputeIndex];
        if (dispute.resolved) revert DisputeAlreadyResolved();

        address voter = LibMeta.msgSender();
        
        // Check if already voted
        if (ps.disputeVotes[marketId][disputeIndex][voter]) revert AlreadyVoted();
        
        // Vote weight = user's total stake in market
        uint256 voteWeight = ps.positionTotalStaked[marketId][voter];
        if (voteWeight == 0) revert NoStake();
        
        // Record vote
        ps.disputeVotes[marketId][disputeIndex][voter] = true;
        ps.disputeVoteDirection[marketId][disputeIndex][voter] = voteFor;
        
        if (voteFor) {
            dispute.votesFor += voteWeight;
        } else {
            dispute.votesAgainst += voteWeight;
        }

        emit DisputeVoteCast(marketId, disputeIndex, voter, voteFor, voteWeight);
    }

    /**
     * @notice Resolve a dispute after voting period
     * @param marketId Market ID
     * @param disputeIndex Index of dispute
     */
    function resolveDispute(
        uint256 marketId,
        uint256 disputeIndex
    ) external nonReentrant whenNotPaused {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.PredictionMarket storage market = ps.markets[marketId];
        
        if (market.status != LibPremiumStorage.MarketStatus.DISPUTED) revert MarketNotDisputed();
        if (disputeIndex >= ps.disputes[marketId].length) revert DisputeNotFound();
        
        LibPremiumStorage.MarketDispute storage dispute = ps.disputes[marketId][disputeIndex];
        if (dispute.resolved) revert DisputeAlreadyResolved();
        
        // Check if voting period ended (dispute window from dispute timestamp)
        if (block.timestamp < dispute.timestamp + market.disputeWindow) {
            // Can still resolve early if quorum reached
            uint256 totalVotes = dispute.votesFor + dispute.votesAgainst;
            uint256 quorum = (market.totalPool * DISPUTE_QUORUM_BPS) / 10000;
            if (totalVotes < quorum) revert QuorumNotReached();
        }
        
        // Determine outcome
        uint256 totalVotes = dispute.votesFor + dispute.votesAgainst;
        bool upheld = false;
        
        if (totalVotes > 0) {
            // Dispute upheld if votesFor >= DISPUTE_MAJORITY_BPS of total votes
            upheld = (dispute.votesFor * 10000) / totalVotes >= DISPUTE_MAJORITY_BPS;
        }
        
        dispute.resolved = true;
        
        if (upheld) {
            // Change winning outcome
            uint8 oldOutcome = market.winningOutcome;
            market.winningOutcome = dispute.proposedOutcome;
            
            // Return bond to disputer + bonus from resolver
            uint256 bonus = dispute.bondAmount / 2;
            LibFeeCollection.transferFromTreasury(dispute.disputer, dispute.bondAmount + bonus, "dispute_won");
            
            // Penalize resolver
            ps.resolvers[market.resolver].disputesLost++;
            ps.resolvers[market.resolver].reputationScore = 
                ps.resolvers[market.resolver].reputationScore > 1000 
                    ? ps.resolvers[market.resolver].reputationScore - 1000 
                    : 0;
        } else {
            // Bond goes to resolver as compensation
            LibFeeCollection.transferFromTreasury(market.resolver, dispute.bondAmount, "dispute_rejected");
            
            // Boost resolver reputation
            ps.resolvers[market.resolver].correctResolutions++;
            if (ps.resolvers[market.resolver].reputationScore < 9500) {
                ps.resolvers[market.resolver].reputationScore += 500;
            }
        }
        
        // Return to RESOLVED status
        market.status = LibPremiumStorage.MarketStatus.RESOLVED;
        _updateMarketStatusTracking(ps, marketId, LibPremiumStorage.MarketStatus.DISPUTED, LibPremiumStorage.MarketStatus.RESOLVED);

        emit DisputeResolved(marketId, disputeIndex, upheld, market.winningOutcome);
        emit MarketStatusChanged(marketId, LibPremiumStorage.MarketStatus.DISPUTED, LibPremiumStorage.MarketStatus.RESOLVED);
    }

    // ==================== AMM LIQUIDITY ====================

    /**
     * @notice Add liquidity to market's AMM pool
     * @param marketId Market ID
     * @param amount Amount of YLW to add as liquidity
     */
    function addLiquidity(
        uint256 marketId,
        uint256 amount
    ) external nonReentrant whenNotPaused returns (uint256 lpSharesIssued) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.PredictionMarket storage market = ps.markets[marketId];
        
        if (market.status != LibPremiumStorage.MarketStatus.OPEN) revert MarketNotOpen();
        if (amount < MIN_LIQUIDITY / 10) revert InsufficientLiquidity();
        
        address provider = LibMeta.msgSender();
        
        // Collect liquidity
        ResourceHelper.collectAuxiliaryFee(provider, amount, "amm_liquidity");
        
        LibPremiumStorage.AMMPool storage pool = ps.ammPools[marketId];
        
        // Calculate LP shares
        if (ps.totalLpShares[marketId] == 0) {
            // First LP - initialize pool
            lpSharesIssued = amount;
            
            // Distribute equally across outcomes
            uint256 perOutcome = amount / market.outcomeCount;
            for (uint8 i = 0; i < market.outcomeCount; i++) {
                pool.reserves[i] = perOutcome;
            }
            
            // Calculate constant product k
            pool.k = _calculateK(pool, market.outcomeCount);
            pool.swapFeeBps = uint16(LP_FEE_BPS);
        } else {
            // Proportional LP shares
            lpSharesIssued = (amount * ps.totalLpShares[marketId]) / pool.liquidity;
            
            // Add proportionally to each outcome
            for (uint8 i = 0; i < market.outcomeCount; i++) {
                pool.reserves[i] += (amount * pool.reserves[i]) / pool.liquidity;
            }
            
            // Recalculate k
            pool.k = _calculateK(pool, market.outcomeCount);
        }
        
        pool.liquidity += amount;
        
        // Update LP tracking
        ps.lpShares[marketId][provider] += lpSharesIssued;
        ps.totalLpShares[marketId] += lpSharesIssued;
        
        if (!ps.isLpProvider[marketId][provider]) {
            ps.isLpProvider[marketId][provider] = true;
            ps.lpProviders[marketId].push(provider);
        }
        
        emit LiquidityAdded(marketId, provider, amount, lpSharesIssued);
        
        return lpSharesIssued;
    }

    /**
     * @notice Remove liquidity from market's AMM pool
     * @param marketId Market ID
     * @param lpSharesToRemove Amount of LP shares to burn
     */
    function removeLiquidity(
        uint256 marketId,
        uint256 lpSharesToRemove
    ) external nonReentrant whenNotPaused returns (uint256 amountReturned) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.PredictionMarket storage market = ps.markets[marketId];
        
        // Can remove liquidity when OPEN or after RESOLVED/CANCELLED
        if (market.status == LibPremiumStorage.MarketStatus.LOCKED || 
            market.status == LibPremiumStorage.MarketStatus.DISPUTED) {
            revert MarketLocked();
        }
        
        address provider = LibMeta.msgSender();
        
        uint256 userShares = ps.lpShares[marketId][provider];
        if (userShares == 0 || lpSharesToRemove > userShares) revert NoLpShares();
        
        LibPremiumStorage.AMMPool storage pool = ps.ammPools[marketId];
        if (pool.liquidity == 0) revert AMMNotInitialized();
        
        // Calculate proportional return
        amountReturned = (lpSharesToRemove * pool.liquidity) / ps.totalLpShares[marketId];
        
        // Update reserves proportionally
        for (uint8 i = 0; i < market.outcomeCount; i++) {
            pool.reserves[i] -= (lpSharesToRemove * pool.reserves[i]) / ps.totalLpShares[marketId];
        }
        
        pool.liquidity -= amountReturned;
        pool.k = _calculateK(pool, market.outcomeCount);
        
        // Update LP tracking
        ps.lpShares[marketId][provider] -= lpSharesToRemove;
        ps.totalLpShares[marketId] -= lpSharesToRemove;

        // Transfer back YLW (same currency used in addLiquidity)
        ResourceHelper.transferAuxiliaryFromTreasury(provider, amountReturned, "lp_withdrawal");
        
        emit LiquidityRemoved(marketId, provider, lpSharesToRemove, amountReturned);
        
        return amountReturned;
    }

    /**
     * @notice Swap shares between outcomes using AMM
     * @param marketId Market ID
     * @param fromOutcome Outcome to sell shares of
     * @param toOutcome Outcome to buy shares of
     * @param amountIn Amount of shares to sell
     */
    function swapShares(
        uint256 marketId,
        uint8 fromOutcome,
        uint8 toOutcome,
        uint256 amountIn
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.PredictionMarket storage market = ps.markets[marketId];
        
        if (market.status != LibPremiumStorage.MarketStatus.OPEN) revert MarketNotOpen();
        if (fromOutcome == toOutcome) revert SameOutcome();
        if (fromOutcome >= market.outcomeCount || toOutcome >= market.outcomeCount) revert InvalidOutcome();
        
        address user = LibMeta.msgSender();
        
        // Check user has enough shares
        uint256 userShares = ps.positionOutcomeShares[marketId][user][fromOutcome];
        if (userShares < amountIn) revert InsufficientShares();
        
        LibPremiumStorage.AMMPool storage pool = ps.ammPools[marketId];
        if (pool.liquidity == 0) revert AMMNotInitialized();
        
        // Calculate output using constant product formula
        // (reserveFrom + amountIn) * (reserveTo - amountOut) = k
        uint256 amountInWithFee = amountIn * (10000 - pool.swapFeeBps) / 10000;
        amountOut = (pool.reserves[toOutcome] * amountInWithFee) / (pool.reserves[fromOutcome] + amountInWithFee);
        
        // Update reserves
        pool.reserves[fromOutcome] += amountIn;
        pool.reserves[toOutcome] -= amountOut;
        
        // Update user positions
        ps.positionOutcomeShares[marketId][user][fromOutcome] -= amountIn;
        ps.positionOutcomeShares[marketId][user][toOutcome] += amountOut;
        
        // Update market outcomes
        ps.marketOutcomes[marketId][fromOutcome].shares -= amountIn;
        ps.marketOutcomes[marketId][toOutcome].shares += amountOut;
        
        // Update probabilities
        _updateImpliedProbabilities(marketId);
        
        emit SharesSwapped(marketId, user, fromOutcome, toOutcome, amountIn, amountOut);
        
        return amountOut;
    }

    /**
     * @notice Calculate constant product k for AMM
     * @dev For markets with many outcomes, we use geometric mean approach to avoid overflow
     * @dev Instead of k = r0 * r1 * ... * rn (which overflows), we store k as scaled value
     * @dev For 2 outcomes: k = r0 * r1 (fits in uint256)
     * @dev For 3+ outcomes: We use sum of reserves as simplified invariant (CSMM-like)
     * @dev This avoids overflow while maintaining AMM functionality
     */
    function _calculateK(
        LibPremiumStorage.AMMPool storage pool,
        uint8 outcomeCount
    ) internal view returns (uint256 k) {
        if (outcomeCount == 0) return 0;
        if (outcomeCount == 1) return pool.reserves[0];

        // For 2 outcomes, simple multiplication works (standard CPMM)
        if (outcomeCount == 2) {
            return pool.reserves[0] * pool.reserves[1];
        }

        // For 3+ outcomes, use sum-based invariant to completely avoid overflow
        // This is a simplified approach similar to Constant Sum Market Maker (CSMM)
        // k = sum of all reserves * scaling factor
        // The swap function uses ratio-based pricing which doesn't depend on k directly
        k = 0;
        for (uint8 i = 0; i < outcomeCount; i++) {
            k += pool.reserves[i];
        }

        // Scale by outcome count to differentiate from simple sum
        k = k * outcomeCount;

        return k;
    }

    // ==================== VIEW FUNCTIONS ====================

    function getMarket(uint256 marketId) 
        external 
        view 
        returns (LibPremiumStorage.PredictionMarket memory) 
    {
        return LibPremiumStorage.premiumStorage().markets[marketId];
    }

    function getMarketOutcome(uint256 marketId, uint8 outcome)
        external
        view
        returns (LibPremiumStorage.MarketOutcome memory)
    {
        return LibPremiumStorage.premiumStorage().marketOutcomes[marketId][outcome];
    }

    function getUserPosition(uint256 marketId, address user)
        external
        view
        returns (
            uint256 totalStaked,
            uint256 stakingBonus,
            bool claimed,
            bool refunded,
            uint40 lastBetTime,
            uint256[] memory outcomeStakes,
            uint256[] memory outcomeShares
        )
    {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.PredictionMarket memory market = ps.markets[marketId];

        totalStaked = ps.positionTotalStaked[marketId][user];
        stakingBonus = ps.positionStakingBonus[marketId][user];
        claimed = ps.positionClaimed[marketId][user];
        refunded = ps.refundClaimed[marketId][user];
        lastBetTime = ps.positionLastBetTime[marketId][user];

        outcomeStakes = new uint256[](market.outcomeCount);
        outcomeShares = new uint256[](market.outcomeCount);
        
        for (uint8 i = 0; i < market.outcomeCount; i++) {
            outcomeStakes[i] = ps.positionOutcomeStakes[marketId][user][i];
            outcomeShares[i] = ps.positionOutcomeShares[marketId][user][i];
        }

        return (totalStaked, stakingBonus, claimed, refunded, lastBetTime, outcomeStakes, outcomeShares);
    }

    function getUserOutcomeShares(uint256 marketId, address user, uint8 outcome)
        external
        view
        returns (uint256 shares, uint256 staked)
    {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        return (
            ps.positionOutcomeShares[marketId][user][outcome],
            ps.positionOutcomeStakes[marketId][user][outcome]
        );
    }

    function getUserMarketProfile(address user)
        external
        view
        returns (LibPremiumStorage.UserMarketProfile memory)
    {
        return LibPremiumStorage.premiumStorage().userProfiles[user];
    }

    /**
     * @notice Get all markets where user has a position
     * @param user User address
     * @return marketIds Array of market IDs where user participated
     */
    function getUserMarkets(address user)
        external
        view
        returns (uint256[] memory)
    {
        return LibPremiumStorage.premiumStorage().userMarkets[user];
    }

    function getMarketsByStatus(LibPremiumStorage.MarketStatus status)
        external
        view
        returns (uint256[] memory)
    {
        return LibPremiumStorage.premiumStorage().marketsByStatus[status];
    }

    function getMarketsByEntity(bytes32 entityId)
        external
        view
        returns (uint256[] memory)
    {
        return LibPremiumStorage.premiumStorage().marketsByEntity[entityId];
    }

    function getDisputes(uint256 marketId)
        external
        view
        returns (LibPremiumStorage.MarketDispute[] memory)
    {
        return LibPremiumStorage.premiumStorage().disputes[marketId];
    }

    function getAMMPool(uint256 marketId)
        external
        view
        returns (LibPremiumStorage.AMMPool memory)
    {
        return LibPremiumStorage.premiumStorage().ammPools[marketId];
    }

    function getUserLpShares(uint256 marketId, address user)
        external
        view
        returns (uint256)
    {
        return LibPremiumStorage.premiumStorage().lpShares[marketId][user];
    }

    function calculatePotentialPayout(
        uint256 marketId,
        uint8 outcome,
        uint256 ylwAmount
    ) external view returns (uint256 estimatedPayout, uint256 shares) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.PredictionMarket memory market = ps.markets[marketId];
        LibPremiumStorage.MarketOutcome memory outcomeData = ps.marketOutcomes[marketId][outcome];

        if (outcomeData.pool == 0) {
            shares = ylwAmount;
        } else {
            shares = (ylwAmount * outcomeData.shares) / outcomeData.pool;
        }

        uint256 newTotalPool = market.totalPool + ylwAmount;
        uint256 newOutcomeShares = outcomeData.shares + shares;
        
        estimatedPayout = (shares * newTotalPool) / newOutcomeShares;

        uint256 totalFees = market.protocolFee + market.creatorFee;
        estimatedPayout = estimatedPayout - (estimatedPayout * totalFees / 10000);

        return (estimatedPayout, shares);
    }

    function calculateSwapOutput(
        uint256 marketId,
        uint8 fromOutcome,
        uint8 toOutcome,
        uint256 amountIn
    ) external view returns (uint256 amountOut) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.AMMPool storage pool = ps.ammPools[marketId];
        
        if (pool.liquidity == 0) return 0;
        
        uint256 amountInWithFee = amountIn * (10000 - pool.swapFeeBps) / 10000;
        amountOut = (pool.reserves[toOutcome] * amountInWithFee) / (pool.reserves[fromOutcome] + amountInWithFee);
        
        return amountOut;
    }

    // ==================== ADMIN FUNCTIONS ====================

    function cancelMarket(uint256 marketId, string calldata reason) 
        external 
        onlyAuthorized 
    {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.PredictionMarket storage market = ps.markets[marketId];

        if (market.status == LibPremiumStorage.MarketStatus.RESOLVED) {
            revert MarketAlreadyResolved();
        }

        LibPremiumStorage.MarketStatus oldStatus = market.status;
        market.status = LibPremiumStorage.MarketStatus.CANCELLED;
        
        _updateMarketStatusTracking(ps, marketId, oldStatus, LibPremiumStorage.MarketStatus.CANCELLED);

        // Return creator bond
        if (market.creatorBond > 0) {
            LibFeeCollection.transferFromTreasury(market.creator, market.creatorBond, "cancelled_bond_return");
        }

        emit MarketCancelled(marketId, reason);
        emit MarketStatusChanged(marketId, oldStatus, LibPremiumStorage.MarketStatus.CANCELLED);
    }

    function lockMarket(uint256 marketId) external onlyAuthorized {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.PredictionMarket storage market = ps.markets[marketId];
        
        if (market.status != LibPremiumStorage.MarketStatus.OPEN) revert MarketNotOpen();
        
        LibPremiumStorage.MarketStatus oldStatus = market.status;
        market.status = LibPremiumStorage.MarketStatus.LOCKED;
        
        _updateMarketStatusTracking(ps, marketId, oldStatus, LibPremiumStorage.MarketStatus.LOCKED);
        
        emit MarketStatusChanged(marketId, oldStatus, LibPremiumStorage.MarketStatus.LOCKED);
    }

    function setAuthorizedCreator(address creator, bool authorized) external onlyAuthorized {
        LibPremiumStorage.premiumStorage().authorizedCreators[creator] = authorized;
    }

    function setTrustedResolver(address resolver, bool trusted) external onlyAuthorized {
        LibPremiumStorage.premiumStorage().trustedResolvers[resolver] = trusted;
        LibPremiumStorage.premiumStorage().resolvers[resolver].trusted = trusted;
    }

    function setMarketsEnabled(bool enabled) external onlyAuthorized {
        LibPremiumStorage.premiumStorage().marketsEnabled = enabled;
    }

    function updateMarketResolver(uint256 marketId, address newResolver) external onlyAuthorized {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.PredictionMarket storage market = ps.markets[marketId];
        
        if (market.status != LibPremiumStorage.MarketStatus.OPEN) revert MarketNotOpen();
        if (newResolver == address(0)) revert InvalidAddress();
        
        market.resolver = newResolver;
    }

    function extendMarketLockTime(uint256 marketId, uint40 newLockTime) external onlyAuthorized {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.PredictionMarket storage market = ps.markets[marketId];

        if (market.status != LibPremiumStorage.MarketStatus.OPEN) revert MarketNotOpen();
        if (newLockTime <= market.lockTime || newLockTime >= market.resolutionTime) {
            revert InvalidTimeConfiguration();
        }

        market.lockTime = newLockTime;
    }

    /**
     * @notice Set market lock time (can shorten or extend)
     * @dev Allows admin to adjust lock time to implement early-lock strategy
     * @param marketId Market ID
     * @param newLockTime New lock time (must be > now and < resolutionTime)
     */
    function setMarketLockTime(uint256 marketId, uint40 newLockTime) external onlyAuthorized {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.PredictionMarket storage market = ps.markets[marketId];

        if (market.status != LibPremiumStorage.MarketStatus.OPEN) revert MarketNotOpen();
        if (newLockTime <= uint40(block.timestamp)) revert InvalidTimeConfiguration();
        if (newLockTime >= market.resolutionTime) revert InvalidTimeConfiguration();

        emit MarketLockTimeUpdated(marketId, market.lockTime, newLockTime);
        market.lockTime = newLockTime;
    }

    /**
     * @notice Batch update lock times for multiple markets
     * @dev Useful for applying early-lock configuration to all open markets
     * @param marketIds Array of market IDs
     * @param newLockTimes Array of new lock times (matching indices)
     */
    function batchSetMarketLockTimes(
        uint256[] calldata marketIds,
        uint40[] calldata newLockTimes
    ) external onlyAuthorized {
        if (marketIds.length != newLockTimes.length) revert ArrayLengthMismatch();

        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();

        for (uint256 i = 0; i < marketIds.length; i++) {
            LibPremiumStorage.PredictionMarket storage market = ps.markets[marketIds[i]];

            if (market.status != LibPremiumStorage.MarketStatus.OPEN) continue; // Skip non-open
            if (newLockTimes[i] <= uint40(block.timestamp)) continue; // Skip invalid
            if (newLockTimes[i] >= market.resolutionTime) continue; // Skip invalid

            emit MarketLockTimeUpdated(marketIds[i], market.lockTime, newLockTimes[i]);
            market.lockTime = newLockTimes[i];
        }
    }

    /**
     * @notice Full reset of prediction markets system
     * @dev Resets market counter, clears status arrays, and reinitializes config
     * @dev WARNING: This is a destructive operation! All market data references become orphaned.
     * @dev Use only when you need a complete fresh start of the system.
     * @param _minCreatorBond New minimum creator bond
     * @param _defaultProtocolFee New default protocol fee (basis points)
     */
    function resetPredictionMarkets(
        uint256 _minCreatorBond,
        uint16 _defaultProtocolFee
    ) external onlyAuthorized {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();

        // Reset market counter to 0
        ps.marketCounter = 0;

        // Clear status arrays (old market IDs become orphaned)
        delete ps.marketsByStatus[LibPremiumStorage.MarketStatus.PENDING];
        delete ps.marketsByStatus[LibPremiumStorage.MarketStatus.OPEN];
        delete ps.marketsByStatus[LibPremiumStorage.MarketStatus.LOCKED];
        delete ps.marketsByStatus[LibPremiumStorage.MarketStatus.RESOLVED];
        delete ps.marketsByStatus[LibPremiumStorage.MarketStatus.DISPUTED];
        delete ps.marketsByStatus[LibPremiumStorage.MarketStatus.CANCELLED];

        // Reset configuration
        ps.minCreatorBond = _minCreatorBond;
        ps.defaultProtocolFee = _defaultProtocolFee;
        ps.maxCreatorFee = 1000;           // Max 10%
        ps.stakingBonusBps = 20;           // 0.2% per staking level
        ps.defaultDisputeWindow = 3 days;
        ps.marketsEnabled = true;

        // Reset fee counters
        ps.protocolFeesCollected = 0;
        ps.creatorFeesCollected = 0;

        emit PredictionMarketsReset(block.timestamp, _minCreatorBond, _defaultProtocolFee);
    }

    /**
     * @notice Batch cancel multiple markets
     * @dev Useful for cleaning up before reset or removing invalid markets
     * @param marketIds Array of market IDs to cancel
     * @param reason Cancellation reason
     */
    function batchCancelMarkets(
        uint256[] calldata marketIds,
        string calldata reason
    ) external onlyAuthorized {
        for (uint256 i = 0; i < marketIds.length; i++) {
            _cancelMarketInternal(marketIds[i], reason);
        }
    }

    /**
     * @notice Internal cancel market helper
     */
    function _cancelMarketInternal(uint256 marketId, string calldata reason) internal {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.PredictionMarket storage market = ps.markets[marketId];

        // Skip if market doesn't exist or already resolved/cancelled
        if (market.openTime == 0) return;
        if (market.status == LibPremiumStorage.MarketStatus.RESOLVED) return;
        if (market.status == LibPremiumStorage.MarketStatus.CANCELLED) return;

        LibPremiumStorage.MarketStatus oldStatus = market.status;
        market.status = LibPremiumStorage.MarketStatus.CANCELLED;

        _updateMarketStatusTracking(ps, marketId, oldStatus, LibPremiumStorage.MarketStatus.CANCELLED);

        // Return creator bond if any
        if (market.creatorBond > 0) {
            LibFeeCollection.transferFromTreasury(market.creator, market.creatorBond, "cancelled_bond_return");
        }

        emit MarketCancelled(marketId, reason);
        emit MarketStatusChanged(marketId, oldStatus, LibPremiumStorage.MarketStatus.CANCELLED);
    }

    /**
     * @notice Get current market counter
     * @return Current market ID counter
     */
    function getMarketCounter() external view returns (uint256) {
        return LibPremiumStorage.premiumStorage().marketCounter;
    }

    /**
     * @notice Clear entity mapping for specific entity hash
     * @dev Useful for cleaning up linkedEntity references
     */
    function clearEntityMarkets(bytes32 entityId) external onlyAuthorized {
        delete LibPremiumStorage.premiumStorage().marketsByEntity[entityId];
    }

    /**
     * @notice Clear multiple entity mappings at once
     * @dev Use after reset to clean up all known entity references
     * @param entityIds Array of entity hashes to clear
     */
    function batchClearEntityMarkets(bytes32[] calldata entityIds) external onlyAuthorized {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        for (uint256 i = 0; i < entityIds.length; i++) {
            delete ps.marketsByEntity[entityIds[i]];
        }
    }

    /**
     * @notice Clear AMM pool data for a market
     * @dev Use to reset corrupted pool state
     */
    function clearAMMPool(uint256 marketId) external onlyAuthorized {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        delete ps.ammPools[marketId];
        delete ps.totalLpShares[marketId];
    }

    /**
     * @notice Batch clear AMM pools
     * @dev Use after reset to clean up old pool data
     */
    function batchClearAMMPools(uint256[] calldata marketIds) external onlyAuthorized {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        for (uint256 i = 0; i < marketIds.length; i++) {
            delete ps.ammPools[marketIds[i]];
            delete ps.totalLpShares[marketIds[i]];
        }
    }

    /**
     * @notice Admin function to create market without requiring creator bond
     * @dev Skips bond collection - use for protocol-created markets
     */
    function adminCreateMarket(
        LibPremiumStorage.MarketType marketType,
        bytes32 questionHash,
        string[] calldata outcomes,
        uint40 lockTime,
        uint40 resolutionTime,
        address resolver,
        uint256 minBet,
        uint256 maxBet,
        uint256 creatorFee,
        bytes32 linkedEntity
    ) external onlyAuthorized nonReentrant returns (uint256 marketId) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();

        if (!ps.marketsEnabled) revert MarketsDisabled();
        if (outcomes.length < 2 || outcomes.length > 10) revert InvalidOutcome();
        if (lockTime <= block.timestamp || lockTime >= resolutionTime) {
            revert InvalidTimeConfiguration();
        }
        if (creatorFee > ps.maxCreatorFee) revert InvalidCreatorFee();

        address finalResolver = resolver;
        if (finalResolver == address(0)) {
            finalResolver = LibMeta.msgSender();
        }

        // Admin creates market - NO BOND REQUIRED
        marketId = ++ps.marketCounter;

        ps.markets[marketId] = LibPremiumStorage.PredictionMarket({
            marketType: marketType,
            status: LibPremiumStorage.MarketStatus.OPEN,
            questionHash: questionHash,
            outcomeCount: uint8(outcomes.length),
            openTime: uint40(block.timestamp),
            lockTime: lockTime,
            resolutionTime: resolutionTime,
            resolvedAt: 0,
            winningOutcome: 0,
            creator: LibMeta.msgSender(),
            resolver: finalResolver,
            creatorFee: creatorFee,
            protocolFee: ps.defaultProtocolFee,
            totalPool: 0,
            creatorBond: 0,  // No bond for admin-created markets
            minBet: minBet,
            maxBet: maxBet,
            linkedEntity: linkedEntity,
            allowDisputes: true,
            disputeWindow: ps.defaultDisputeWindow
        });

        // Initialize outcomes
        uint256 outcomeCount = outcomes.length;
        uint256 equalProb = 10000 / outcomeCount;
        for (uint8 i = 0; i < outcomeCount; i++) {
            ps.marketOutcomes[marketId][i] = LibPremiumStorage.MarketOutcome({
                description: outcomes[i],
                pool: 0,
                shares: 0,
                impliedProb: equalProb
            });
        }

        // Add to status tracking
        ps.marketsByStatus[LibPremiumStorage.MarketStatus.OPEN].push(marketId);

        emit MarketCreated(
            marketId,
            LibMeta.msgSender(),
            marketType,
            questionHash,
            uint8(outcomes.length),
            lockTime,
            resolutionTime
        );

        return marketId;
    }

    /**
     * @notice Admin function to seed market liquidity from treasury
     * @dev Uses treasury funds instead of requiring admin to have YLW balance
     * @param marketId Market to add liquidity to
     * @param amount Amount of YLW to seed from treasury
     */
    function adminSeedLiquidity(
        uint256 marketId,
        uint256 amount
    ) external onlyAuthorized nonReentrant returns (uint256 lpSharesIssued) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.PredictionMarket storage market = ps.markets[marketId];

        if (market.status != LibPremiumStorage.MarketStatus.OPEN) revert MarketNotOpen();
        if (amount < MIN_LIQUIDITY / 10) revert InsufficientLiquidity();

        // Note: Treasury funds are used as internal accounting, no actual transfer needed
        // The AMM pool tracks virtual liquidity

        LibPremiumStorage.AMMPool storage pool = ps.ammPools[marketId];

        if (ps.totalLpShares[marketId] == 0) {
            // First LP - initialize pool
            lpSharesIssued = amount;

            // Distribute equally across outcomes
            uint256 perOutcome = amount / market.outcomeCount;
            for (uint8 i = 0; i < market.outcomeCount; i++) {
                pool.reserves[i] = perOutcome;
            }

            // Calculate constant product k
            pool.k = _calculateK(pool, market.outcomeCount);
            pool.swapFeeBps = uint16(LP_FEE_BPS);
        } else {
            // Proportional LP shares
            lpSharesIssued = (amount * ps.totalLpShares[marketId]) / pool.liquidity;

            // Add proportionally to each outcome
            for (uint8 i = 0; i < market.outcomeCount; i++) {
                pool.reserves[i] += (amount * pool.reserves[i]) / pool.liquidity;
            }

            // Recalculate k
            pool.k = _calculateK(pool, market.outcomeCount);
        }

        // Update totals - treasury is the LP provider
        address treasury = ResourceHelper.getTreasuryAddress();
        pool.liquidity += amount;
        ps.totalLpShares[marketId] += lpSharesIssued;
        ps.lpShares[marketId][treasury] += lpSharesIssued;

        if (!ps.isLpProvider[marketId][treasury]) {
            ps.isLpProvider[marketId][treasury] = true;
            ps.lpProviders[marketId].push(treasury);
        }

        emit LiquidityAdded(marketId, treasury, amount, lpSharesIssued);

        return lpSharesIssued;
    }

    // ==================== INTERNAL HELPERS ====================

    function _updateImpliedProbabilities(uint256 marketId) internal {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.PredictionMarket storage market = ps.markets[marketId];

        uint256 totalShares = 0;
        for (uint8 i = 0; i < market.outcomeCount; i++) {
            totalShares += ps.marketOutcomes[marketId][i].shares;
        }

        if (totalShares > 0) {
            for (uint8 i = 0; i < market.outcomeCount; i++) {
                ps.marketOutcomes[marketId][i].impliedProb = uint256(
                    (ps.marketOutcomes[marketId][i].shares * 10000) / totalShares
                );
            }
        }
    }

    /**
     * @notice Update market status tracking arrays
     * @dev Removes from old status array, adds to new status array
     */
    function _updateMarketStatusTracking(
        LibPremiumStorage.PremiumStorage storage ps,
        uint256 marketId,
        LibPremiumStorage.MarketStatus oldStatus,
        LibPremiumStorage.MarketStatus newStatus
    ) internal {
        // Remove from old status array
        uint256[] storage oldArray = ps.marketsByStatus[oldStatus];
        for (uint256 i = 0; i < oldArray.length; i++) {
            if (oldArray[i] == marketId) {
                oldArray[i] = oldArray[oldArray.length - 1];
                oldArray.pop();
                break;
            }
        }
        
        // Add to new status array
        ps.marketsByStatus[newStatus].push(marketId);
    }
}
