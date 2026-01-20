// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../../shared/libraries/LibMeta.sol";
import {LibTokenSwapStorage} from "../../libraries/LibTokenSwapStorage.sol";
import {LibStakingStorage} from "../../libraries/LibStakingStorage.sol";
import {AccessControlBase} from "../../../common/facets/AccessControlBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IMintableBurnable {
    function mint(address to, uint256 amount, string calldata reason) external;
    function burnFrom(address from, uint256 amount, string calldata reason) external;
    function totalSupply() external view returns (uint256);
}

/**
 * @title IUniswapV3Pool
 * @notice Minimal interface for Uniswap V3 Pool oracle functions
 */
interface IUniswapV3Pool {
    /// @notice Returns the current price and tick
    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint8 feeProtocol,
        bool unlocked
    );

    /// @notice Returns TWAP tick data for given time periods
    /// @param secondsAgos Array of seconds ago from which to get cumulative tick values
    /// @return tickCumulatives Cumulative tick values at each secondsAgo
    /// @return secondsPerLiquidityCumulativeX128s Cumulative seconds per liquidity
    function observe(uint32[] calldata secondsAgos) external view returns (
        int56[] memory tickCumulatives,
        uint160[] memory secondsPerLiquidityCumulativeX128s
    );

    /// @notice Token addresses in the pool
    function token0() external view returns (address);
    function token1() external view returns (address);

    /// @notice Pool fee tier
    function fee() external view returns (uint24);
}

/**
 * @title TokenSwapFacet
 * @notice Hybrid dynamic token swap with supply-based rates, volume bonuses, and reputation tiers
 * @dev Diamond facet implementing advanced tokenomics from DeFi protocols
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract TokenSwapFacet is AccessControlBase {
    using SafeERC20 for IERC20;

    // Constants for rate calculation
    uint256 private constant RATE_PRECISION = 1e18;
    uint256 private constant BASIS_POINTS = 10000;

    struct SwapPairConfig {
        address tokenA;
        address tokenB;
        uint256 baseRate;
        uint256 feePercent;
        uint256 dailyLimit;
        uint256 targetSupplyA;
        uint256 targetSupplyB;
        uint256 minRate;
        uint256 maxRate;
        bool burnTokenA;
        bool burnTokenB;
        bool allowMintTokenA;
        bool allowMintTokenB;
        uint256 reverseRateMultiplier; 
    }

    struct SwapStats {
        uint256 effectiveRateForward;      // Rate for tokenA -> tokenB
        uint256 effectiveRateReverse;      // Rate for tokenB -> tokenA
        uint256 remainingDailyLimit;       // Remaining daily swap limit
        uint256 userTotalVolume;           // User's total cumulative volume
        uint8 reputationTier;              // User's reputation tier (0-4)
        uint256 volumeBonus;               // Volume bonus in basis points
        uint256 reputationBonus;           // Reputation bonus in basis points
        address tokenA;                    // Address of tokenA
        address tokenB;                    // Address of tokenB
        uint256 baseRate;                  // Base conversion rate
        uint256 feePercent;                // Fee percentage in basis points
        uint256 dailyLimit;                // Daily limit per user
        bool enabled;                      // Whether swaps are enabled
    }

    struct SwapResult {
        uint256 effectiveRate;
        uint256 rawOut;
        uint256 feeAmount;
        uint256 amountOut;
        address tokenOut;
    }

    struct SwapMechanicsParams {
        address tokenIn;
        address tokenOut;
        address user;
        uint256 amountIn;
        uint256 amountOut;
        bytes32 pairId;
    }

    // Events
    event SwapPairConfigured(
        bytes32 indexed pairId,
        address tokenA,
        address tokenB,
        uint256 baseRate,
        uint256 feePercent
    );
    event SwapExecuted(
        bytes32 indexed pairId,
        address indexed user,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 effectiveRate,
        uint256 feeAmount
    );
    event RateAdjusted(
        bytes32 indexed pairId,
        uint256 baseRate,
        uint256 supplyMultiplier,
        uint256 effectiveRate
    );
    event VolumeTierAdded(bytes32 indexed pairId, uint256 threshold, uint256 bonusBps);
    event ReputationTierSet(address indexed user, uint8 tier, uint256 bonusBps);
    event SupplyTargetUpdated(bytes32 indexed pairId, uint256 oldTarget, uint256 newTarget);
    event RateBoundsUpdated(bytes32 indexed pairId, uint256 minRate, uint256 maxRate);
    event SwapEnabled(bytes32 indexed pairId, bool enabled);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);
    event TokenMinted(bytes32 indexed pairId, address indexed token, uint256 amount, string reason);
    event OracleConfigured(bytes32 indexed pairId, address pool, uint32 twapInterval, bool tokenOrder);
    event OracleEnabled(bytes32 indexed pairId, bool enabled);
    event OraclePriceUsed(bytes32 indexed pairId, uint256 twapPrice, uint256 finalRate);

    // Errors
    error SwapDisabled();
    error InvalidAmount();
    error InvalidPairId();
    error InvalidTokenForPair();
    error DailyLimitExceeded(uint256 requested, uint256 available);
    error InsufficientBalance(uint256 required, uint256 available);
    error InsufficientAllowance(uint256 required, uint256 available);
    error InvalidConversionRate();
    error InvalidAddress();
    error PairNotConfigured();
    error InvalidVolumeTier();
    error InvalidReputationTier();
    error TreasuryNotConfigured();
    error MintNotAllowed();
    error AlreadyInitialized();
    error OracleNotConfigured();
    error OracleCallFailed();
    error InvalidTwapInterval();
    error PoolTokenMismatch();

    /**
     * @notice Swap tokens with hybrid dynamic pricing
     * @param pairId Unique identifier for token pair
     * @param tokenIn Address of input token
     * @param amountIn Amount of input token
     * @return tokenOut Address of output token
     * @return amountOut Amount of output token received after fees
     */
    function swapTokens(
        bytes32 pairId,
        address tokenIn,
        uint256 amountIn
    ) external returns (address tokenOut, uint256 amountOut) {
        LibTokenSwapStorage.SwapPair storage pair = LibTokenSwapStorage.swapStorage().swapPairs[pairId];

        // Validations
        if (!pair.enabled) revert SwapDisabled();
        if (!pair.configured) revert PairNotConfigured();
        if (amountIn == 0) revert InvalidAmount();

        address user = LibMeta.msgSender();
        bool isForward = tokenIn == pair.tokenA;

        // Validate token direction
        if (!isForward && tokenIn != pair.tokenB) revert InvalidTokenForPair();

        // Check and update daily limit
        _checkAndUpdateDailyLimit(pairId, user);

        // Calculate and execute swap
        return _executeSwap(pairId, tokenIn, amountIn, isForward, user);
    }

    /**
     * @notice Internal swap execution with optimized stack depth
     */
    function _executeSwap(
        bytes32 pairId,
        address tokenIn,
        uint256 amountIn,
        bool isForward,
        address user
    ) internal returns (address tokenOut, uint256 amountOut) {
        LibTokenSwapStorage.TokenSwapStorage storage s = LibTokenSwapStorage.swapStorage();
        LibTokenSwapStorage.SwapPair storage pair = s.swapPairs[pairId];
        
        // Calculate swap amounts
        SwapResult memory result = _calculateSwapAmounts(pair, pairId, user, amountIn, isForward);
        tokenOut = result.tokenOut;
        amountOut = result.amountOut;

        // Validate and update daily limits
        _validateAndUpdateLimits(s, pair, pairId, user, amountIn, result.rawOut, isForward);

        // Check shared daily limit before executing swap
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        uint256 ylwAmount = tokenOut == pair.tokenB ? amountOut : 0; // Only count if receiving YLW
        if (ylwAmount > 0) {
            uint256 availableLimit = LibStakingStorage.getAvailableYlwLimit(ss, user);
            if (ylwAmount > availableLimit) {
                revert DailyLimitExceeded(ylwAmount, availableLimit);
            }
        }

        // Execute swap mechanics
        _executeSwapMechanics(pair, tokenIn, tokenOut, user, amountIn, amountOut, pairId);

        // ✅ NEW: Consume from shared daily limit after successful swap
        if (ylwAmount > 0) {
            (bool limitOk, ) = LibStakingStorage.checkAndConsumeYlwLimit(ss, user, ylwAmount);
            if (!limitOk) revert DailyLimitExceeded(ylwAmount, 0); // Should not happen, but safety check
        }

        // Update stats and emit event
        _updateStatsAndEmit(s, pairId, tokenIn, tokenOut, user, amountIn, amountOut, result);
    }

    function _calculateSwapAmounts(
        LibTokenSwapStorage.SwapPair storage pair,
        bytes32 pairId,
        address user,
        uint256 amountIn,
        bool isForward
    ) private view returns (SwapResult memory result) {
        result.effectiveRate = _calculateHybridRate(pairId, user, amountIn, isForward);

        // Calculate output token and raw amount
        if (isForward) {
            result.tokenOut = pair.tokenB;
            result.rawOut = (amountIn * result.effectiveRate) / RATE_PRECISION; 
        } else {
            result.tokenOut = pair.tokenA;
            result.rawOut = (amountIn * RATE_PRECISION) / result.effectiveRate; 
        }

        if (result.rawOut == 0) revert InvalidAmount();

        result.feeAmount = (result.rawOut * pair.feePercent) / BASIS_POINTS;
        result.amountOut = result.rawOut - result.feeAmount;
    }

    function _validateAndUpdateLimits(
        LibTokenSwapStorage.TokenSwapStorage storage s,
        LibTokenSwapStorage.SwapPair storage pair,
        bytes32 pairId,
        address user,
        uint256 amountIn,
        uint256 rawOut,
        bool isForward
    ) private {
        uint256 currentDay = _getCurrentDay();
        uint256 tokenBEq = isForward ? rawOut : amountIn;
        uint256 dailyUsed = s.userDailySwapped[pairId][user][currentDay];

        if (tokenBEq > pair.dailyLimit - dailyUsed) {
            revert DailyLimitExceeded(tokenBEq, pair.dailyLimit - dailyUsed);
        }

        s.userDailySwapped[pairId][user][currentDay] = dailyUsed + tokenBEq;
        s.userTotalVolume[pairId][user] += tokenBEq;
    }

    function _updateStatsAndEmit(
        LibTokenSwapStorage.TokenSwapStorage storage s,
        bytes32 pairId,
        address tokenIn,
        address tokenOut,
        address user,
        uint256 amountIn,
        uint256 amountOut,
        SwapResult memory result
    ) private {
        s.totalSwapped[pairId][tokenIn] += amountIn;
        s.totalSwapped[pairId][tokenOut] += amountOut;

        emit SwapExecuted(
            pairId, 
            user, 
            tokenIn, 
            tokenOut, 
            amountIn, 
            amountOut, 
            result.effectiveRate, 
            result.feeAmount
        );
    }

    /**
     * @notice Initialize TokenSwap system (one-time admin setup)
     * @dev Should be called once during diamond setup, before any swaps
     * @param tokenA Address of ZICO token (tokenA)
     * @param tokenB Address of YELLOW token (tokenB)
     */
    function initializeTokenSwap(
        address tokenA,
        address tokenB,
        bool forceReinitialize
    ) external onlyAuthorized {
        LibTokenSwapStorage.TokenSwapStorage storage s = LibTokenSwapStorage.swapStorage();
        
        // Prevent re-initialization
        bytes32 mainPairId = keccak256("ZICO_YELLOW_MAIN");
        if (s.swapPairs[mainPairId].configured && !forceReinitialize) revert AlreadyInitialized();
        
        if (tokenA == address(0) || tokenB == address(0)) revert InvalidAddress();
        
        // Configure main ZICO <-> YELLOW pair with hybrid pricing
        // Base rate: 1 ZICO = 100 YELLOW (scaled to 1e18)
        uint256 baseRate = 100 * RATE_PRECISION;
        
        LibTokenSwapStorage.SwapPair storage pair = s.swapPairs[mainPairId];
        
        pair.tokenA = tokenA;           // ZICO (input)
        pair.tokenB = tokenB;         // YELLOW (output)
        pair.baseRate = baseRate;          // 1 ZICO = 100 YELLOW
        pair.reverseRateMultiplier = 10500; // 105% = symmetric rates
        pair.feePercent = 200;             // 2% fee (200 basis points)
        pair.dailyLimit = 10000 ether;     // 10,000 YELLOW daily limit per user
        
        // Target supplies for dynamic adjustment (set to realistic values)
        pair.targetSupplyA = 13_000_000 ether;  // Target 1M ZICO in circulation
        pair.targetSupplyB = 100_000_000 ether; // Target 100M YELLOW in circulation
        
        // Rate bounds: ±20% from base rate
        pair.minRate = (baseRate * 80) / 100;   // 80 YELLOW per ZICO (floor)
        pair.maxRate = (baseRate * 120) / 100;  // 120 YELLOW per ZICO (ceiling)
        
        // Mechanics: Transfer ZICO to treasury, Burn YELLOW
        pair.burnTokenA = false;           // Transfer incoming ZICO to treasury (NEVER burn - fixed supply!)
        pair.burnTokenB = true;            // Burn incoming YELLOW (deflationary mechanism)
        
        // Mintable tokens configuration (YELLOW can be minted if treasury insufficient)
        pair.allowMintTokenA = false;      // ZICO cannot be minted
        pair.allowMintTokenB = true;       // YELLOW can be minted as fallback
        
        // Enable the pair
        pair.enabled = true;
        pair.configured = true;
        
        // Initialize volume tiers (bulk discounts)
        // Tier 1: 1,000+ YELLOW → 1% bonus
        s.volumeTiers[mainPairId].push(
            LibTokenSwapStorage.VolumeTier({
                threshold: 1000 ether,
                bonusBps: 100  // 1% better rate
            })
        );
        
        // Tier 2: 10,000+ YELLOW → 2% bonus
        s.volumeTiers[mainPairId].push(
            LibTokenSwapStorage.VolumeTier({
                threshold: 10000 ether,
                bonusBps: 200  // 2% better rate
            })
        );
        
        // Tier 3: 50,000+ YELLOW → 3% bonus
        s.volumeTiers[mainPairId].push(
            LibTokenSwapStorage.VolumeTier({
                threshold: 50000 ether,
                bonusBps: 300  // 3% better rate
            })
        );
        
        // Tier 4: 100,000+ YELLOW → 5% bonus
        s.volumeTiers[mainPairId].push(
            LibTokenSwapStorage.VolumeTier({
                threshold: 100000 ether,
                bonusBps: 500  // 5% better rate
            })
        );
        
        emit SwapPairConfigured(mainPairId, tokenA, tokenB, baseRate, 100);
    }

    /**
     * @notice Configure a token swap pair with hybrid pricing
     */
    function configureSwapPair(
        bytes32 pairId,
        SwapPairConfig calldata config
    ) external onlyAuthorized {
        if (pairId == bytes32(0)) revert InvalidPairId();
        if (config.tokenA == address(0) || config.tokenB == address(0)) revert InvalidAddress();
        if (config.baseRate == 0) revert InvalidConversionRate();
        require(config.feePercent <= 2000, "Fee too high");
        require(config.minRate <= config.baseRate && config.baseRate <= config.maxRate, "Invalid rate bounds");

        LibTokenSwapStorage.SwapPair storage pair = 
            LibTokenSwapStorage.swapStorage().swapPairs[pairId];

        pair.tokenA = config.tokenA;
        pair.tokenB = config.tokenB;
        pair.baseRate = config.baseRate;
        pair.reverseRateMultiplier = config.reverseRateMultiplier;
        pair.feePercent = config.feePercent;
        pair.dailyLimit = config.dailyLimit;
        pair.targetSupplyA = config.targetSupplyA;
        pair.targetSupplyB = config.targetSupplyB;
        pair.minRate = config.minRate;
        pair.maxRate = config.maxRate;
        pair.burnTokenA = config.burnTokenA;
        pair.burnTokenB = config.burnTokenB;
        pair.allowMintTokenA = config.allowMintTokenA;
        pair.allowMintTokenB = config.allowMintTokenB;
        pair.configured = true;

        emit SwapPairConfigured(pairId, config.tokenA, config.tokenB, config.baseRate, config.feePercent);
    }

    /**
     * @notice Add volume tier bonus (bulk discount)
     * @param pairId Pair identifier
     * @param threshold Cumulative volume threshold in tokenB
     * @param bonusBps Bonus in basis points (100 = 1% better rate)
     */
    function addBonusVolumeTier(
        bytes32 pairId,
        uint256 threshold,
        uint256 bonusBps
    ) external onlyAuthorized {
        require(bonusBps <= 2000, "Bonus too high"); // Max 20%

        LibTokenSwapStorage.TokenSwapStorage storage s = LibTokenSwapStorage.swapStorage();
        
        s.volumeTiers[pairId].push(
            LibTokenSwapStorage.VolumeTier({
                threshold: threshold,
                bonusBps: bonusBps
            })
        );

        emit VolumeTierAdded(pairId, threshold, bonusBps);
    }

    /**
     * @notice Set user reputation tier
     * @param user User address
     * @param tier Reputation tier (0=none, 1=bronze, 2=silver, 3=gold, 4=platinum)
     * @param bonusBps Bonus in basis points (100 = 1% better rate)
     */
    function setUserReputationTier(
        address user,
        uint8 tier,
        uint256 bonusBps
    ) external onlyAuthorized {
        require(tier <= 4, "Invalid tier");
        require(bonusBps <= 1000, "Bonus too high"); // Max 10%

        LibTokenSwapStorage.TokenSwapStorage storage s = LibTokenSwapStorage.swapStorage();
        
        s.userReputation[user] = LibTokenSwapStorage.ReputationTier({
            tier: tier,
            bonusBps: bonusBps
        });

        emit ReputationTierSet(user, tier, bonusBps);
    }

    /**
     * @notice Update target supplies for dynamic rate adjustment
     */
    function setPairTargetSupplies(
        bytes32 pairId,
        uint256 targetSupplyA,
        uint256 targetSupplyB
    ) external onlyAuthorized {
        LibTokenSwapStorage.SwapPair storage pair = 
            LibTokenSwapStorage.swapStorage().swapPairs[pairId];
        
        if (!pair.configured) revert PairNotConfigured();

        pair.targetSupplyA = targetSupplyA;
        pair.targetSupplyB = targetSupplyB;

        emit SupplyTargetUpdated(pairId, targetSupplyA, targetSupplyB);
    }

    /**
     * @notice Update rate bounds (min/max)
     */
    function setPairRateBounds(
        bytes32 pairId,
        uint256 minRate,
        uint256 maxRate
    ) external onlyAuthorized {
        LibTokenSwapStorage.SwapPair storage pair = 
            LibTokenSwapStorage.swapStorage().swapPairs[pairId];
        
        if (!pair.configured) revert PairNotConfigured();
        require(minRate <= pair.baseRate && pair.baseRate <= maxRate, "Invalid bounds");

        pair.minRate = minRate;
        pair.maxRate = maxRate;

        emit RateBoundsUpdated(pairId, minRate, maxRate);
    }

    /**
     * @notice Update base rate
     */
    function setPairBaseRate(bytes32 pairId, uint256 rate)
        external
        onlyAuthorized
    {
        if (rate == 0) revert InvalidConversionRate();

        LibTokenSwapStorage.SwapPair storage pair = 
            LibTokenSwapStorage.swapStorage().swapPairs[pairId];
        
        if (!pair.configured) revert PairNotConfigured();

        pair.baseRate = rate;
    }

    /**
     * @notice Update fee
     */
    function setPairSwapFee(bytes32 pairId, uint256 feePercent)
        external
        onlyAuthorized
    {
        require(feePercent <= 2000, "Fee too high");

        LibTokenSwapStorage.SwapPair storage pair = 
            LibTokenSwapStorage.swapStorage().swapPairs[pairId];
        
        if (!pair.configured) revert PairNotConfigured();

        pair.feePercent = feePercent;
    }

    /**
     * @notice Update daily limit
     */
    function setPairDailyLimit(bytes32 pairId, uint256 limit)
        external
        onlyAuthorized
    {
        LibTokenSwapStorage.SwapPair storage pair = 
            LibTokenSwapStorage.swapStorage().swapPairs[pairId];
        
        if (!pair.configured) revert PairNotConfigured();

        pair.dailyLimit = limit;
    }

    /**
     * @notice Enable/disable swaps
     */
    function setPairSwapEnabled(bytes32 pairId, bool enabled)
        external
        onlyAuthorized
    {
        LibTokenSwapStorage.SwapPair storage pair =
            LibTokenSwapStorage.swapStorage().swapPairs[pairId];

        if (!pair.configured) revert PairNotConfigured();

        pair.enabled = enabled;

        emit SwapEnabled(pairId, enabled);
    }

    /**
     * @notice Set reverse rate multiplier for tokenB -> tokenA swaps
     * @param pairId Pair identifier
     * @param multiplier Multiplier in basis points (10000 = 100%, 12000 = 120%, 15000 = 150%)
     * @dev Higher multiplier = worse rate for reverse swaps (anti-arbitrage)
     */
    function setPairReverseRateMultiplier(bytes32 pairId, uint256 multiplier)
        external
        onlyAuthorized
    {
        require(multiplier >= 10000 && multiplier <= 20000, "Multiplier must be 100-200%");

        LibTokenSwapStorage.SwapPair storage pair =
            LibTokenSwapStorage.swapStorage().swapPairs[pairId];

        if (!pair.configured) revert PairNotConfigured();

        pair.reverseRateMultiplier = multiplier;
    }

    /**
     * @notice Emergency withdraw from treasury (admin only)
     */
    function emergencySwapWithdraw(address token, address to, uint256 amount)
        external
        onlyAuthorized
    {
        if (to == address(0)) revert InvalidAddress();
        
        address treasury = _getTreasuryAddress();
        if (treasury == address(0)) revert TreasuryNotConfigured();
        
        IERC20(token).safeTransferFrom(treasury, to, amount);
        emit EmergencyWithdraw(token, to, amount);
    }

    // View functions

    /**
     * @notice Get current effective rate for a user
     * @dev Returns the same rate regardless of swap direction (prevents arbitrage)
     * @return Rate in format: tokenB per tokenA (e.g., 100e18 = 1 tokenA = 100 tokenB)
     */
    function getPairEffectiveRate(
        bytes32 pairId,
        address user,
        uint256 amount,
        bool isForward
    ) external view returns (uint256) {
        return _calculateHybridRate(pairId, user, amount, isForward);
    }

    /**
     * @notice Preview swap output
     */
    function previewSwap(
        bytes32 pairId,
        address tokenIn,
        uint256 amountIn
    ) external view returns (address tokenOut, uint256 amountOut, uint256 feeAmount) {
        LibTokenSwapStorage.SwapPair storage pair = 
            LibTokenSwapStorage.swapStorage().swapPairs[pairId];

        bool isForward = tokenIn == pair.tokenA;
        if (!isForward && tokenIn != pair.tokenB) revert InvalidTokenForPair();

        address user = LibMeta.msgSender();
        uint256 effectiveRate = _calculateHybridRate(pairId, user, amountIn, isForward);

        uint256 rawAmountOut;
        if (isForward) {
            // tokenA → tokenB: multiply by rate
            rawAmountOut = (amountIn * effectiveRate) / RATE_PRECISION;  // ✅ NAPRAWIONE
            tokenOut = pair.tokenB;
        } else {
            // tokenB → tokenA: divide by rate
            rawAmountOut = (amountIn * RATE_PRECISION) / effectiveRate;  // ✅ NAPRAWIONE
            tokenOut = pair.tokenA;
        }

        feeAmount = (rawAmountOut * pair.feePercent) / BASIS_POINTS;
        amountOut = rawAmountOut - feeAmount;

        return (tokenOut, amountOut, feeAmount);
    }

    /**
     * @notice Calculate required input amount to receive desired output
     * @dev Reverse calculation: given desired output, calculate needed input (including fees)
     * @param pairId Swap pair identifier
     * @param tokenOut Desired output token address
     * @param amountOut Desired output amount (net, after fees)
     * @return tokenIn Required input token address
     * @return amountIn Required input amount
     * @return feeAmount Fee that will be charged
     * @return effectiveRate Rate that will be used
     */
    function calculateRequiredInput(
        bytes32 pairId,
        address tokenOut,
        uint256 amountOut
    ) external view returns (
        address tokenIn,
        uint256 amountIn,
        uint256 feeAmount,
        uint256 effectiveRate
    ) {
        LibTokenSwapStorage.SwapPair storage pair = LibTokenSwapStorage.swapStorage().swapPairs[pairId];
        
        if (!pair.configured) revert PairNotConfigured();
        if (amountOut == 0) revert InvalidAmount();
        
        address user = LibMeta.msgSender();
        
        // Determine direction: if tokenOut is tokenB, then we're doing forward swap (tokenA -> tokenB)
        bool isForward = tokenOut == pair.tokenB;
        
        if (!isForward && tokenOut != pair.tokenA) revert InvalidTokenForPair();
        
        // Set input token based on direction
        tokenIn = isForward ? pair.tokenA : pair.tokenB;
        
        // NOTE: We need to iterate because rate depends on amountIn
        // Start with approximation, then refine
        uint256 estimatedAmountIn;
        
        // Step 1: Calculate rawOut needed (before fee deduction)
        // amountOut = rawOut - fee
        // amountOut = rawOut - (rawOut * feePercent / BASIS_POINTS)
        // amountOut = rawOut * (1 - feePercent/BASIS_POINTS)
        // rawOut = amountOut / (1 - feePercent/BASIS_POINTS)
        // rawOut = amountOut * BASIS_POINTS / (BASIS_POINTS - feePercent)
        
        uint256 rawOut = (amountOut * BASIS_POINTS) / (BASIS_POINTS - pair.feePercent);
        feeAmount = rawOut - amountOut;
        
        // Step 2: Use rawOut to estimate initial amountIn for rate calculation
        if (isForward) {
            // tokenA → tokenB: amountIn * rate / PRECISION = rawOut
            // Estimate with baseRate for initial calculation
            estimatedAmountIn = (rawOut * RATE_PRECISION) / pair.baseRate;
        } else {
            // tokenB → tokenA: amountIn * PRECISION / rate = rawOut
            // Estimate with baseRate
            estimatedAmountIn = (rawOut * pair.baseRate) / RATE_PRECISION;
        }
        
        // Step 3: Calculate actual effective rate with estimated input
        effectiveRate = _calculateHybridRate(pairId, user, estimatedAmountIn, isForward);
        
        // Step 4: Calculate precise amountIn with actual effective rate
        if (isForward) {
            // tokenA → tokenB: amountIn * effectiveRate / PRECISION = rawOut
            // amountIn = rawOut * PRECISION / effectiveRate
            amountIn = (rawOut * RATE_PRECISION) / effectiveRate;
        } else {
            // tokenB → tokenA: amountIn * PRECISION / effectiveRate = rawOut
            // amountIn = rawOut * effectiveRate / PRECISION
            amountIn = (rawOut * effectiveRate) / RATE_PRECISION;
        }
        
        // Add 0.1% buffer for rounding errors and rate fluctuations
        amountIn = (amountIn * 10010) / 10000;
    }

    function getSwapPairInfo(bytes32 pairId) 
        external 
        view 
        returns (
            address tokenA,
            address tokenB,
            uint256 baseRate,
            uint256 feePercent,
            uint256 dailyLimit,
            bool enabled,
            bool configured
        ) 
    {
        LibTokenSwapStorage.SwapPair storage pair = 
            LibTokenSwapStorage.swapStorage().swapPairs[pairId];
        
        return (
            pair.tokenA,
            pair.tokenB,
            pair.baseRate,
            pair.feePercent,
            pair.dailyLimit,
            pair.enabled,
            pair.configured
        );
    }

    function getRemainingDailyLimit(bytes32 pairId, address user) 
        external 
        view 
        returns (uint256) 
    {
        LibTokenSwapStorage.TokenSwapStorage storage s = LibTokenSwapStorage.swapStorage();
        LibTokenSwapStorage.SwapPair storage pair = s.swapPairs[pairId];

        uint256 currentDay = _getCurrentDay();
        uint256 swapped = s.userDailySwapped[pairId][user][currentDay];

        if (swapped >= pair.dailyLimit) return 0;
        return pair.dailyLimit - swapped;
    }

    function getUserReputationTier(address user) 
        external 
        view 
        returns (uint8 tier, uint256 bonusBps) 
    {
        LibTokenSwapStorage.ReputationTier storage rep = 
            LibTokenSwapStorage.swapStorage().userReputation[user];
        return (rep.tier, rep.bonusBps);
    }

    function getUserTotalVolume(bytes32 pairId, address user) 
        external 
        view 
        returns (uint256) 
    {
        return LibTokenSwapStorage.swapStorage().userTotalVolume[pairId][user];
    }

    function getTotalSwapped(bytes32 pairId, address token) 
        external 
        view 
        returns (uint256) 
    {
        return LibTokenSwapStorage.swapStorage().totalSwapped[pairId][token];
    }

    /**
     * @notice Get the main ZICO/YELLOW pair ID
     * @return Main pair identifier for ZICO <-> YELLOW swaps
     */
    function getMainPairId() external pure returns (bytes32) {
        return keccak256("ZICO_YELLOW_MAIN");
    }

    /**
     * @notice Get pair ID for given token addresses if pair is defined
     * @dev Checks all configured pairs and returns the pair ID if tokens match
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return pairId The pair identifier (0 if not found)
     * @return found Whether a pair was found for the given tokens
     */
    function getPairIdForTokens(address tokenA, address tokenB) 
        external 
        view 
        returns (bytes32 pairId, bool found) 
    {
        LibTokenSwapStorage.TokenSwapStorage storage s = LibTokenSwapStorage.swapStorage();
        
        // Check main pair first (most common case)
        bytes32 mainPairId = keccak256("ZICO_YELLOW_MAIN");
        LibTokenSwapStorage.SwapPair storage mainPair = s.swapPairs[mainPairId];
        
        if (mainPair.configured) {
            // Check both directions (tokenA <-> tokenB)
            if ((mainPair.tokenA == tokenA && mainPair.tokenB == tokenB) ||
                (mainPair.tokenA == tokenB && mainPair.tokenB == tokenA)) {
                return (mainPairId, true);
            }
        }
        
        // If not main pair, would need to iterate through all pairs
        // For now, only main pair is supported
        // Future: Could add a mapping tokenHash => pairId for O(1) lookup
        
        return (bytes32(0), false);
    }

    /**
     * @notice Get aggregated swap statistics for UI dashboard
     * @param pairId Token pair identifier
     * @param user User address
     * @return stats Struct with all relevant swap data
     */
    function getUserSwapStats(bytes32 pairId, address user) 
        external 
        view 
        returns (SwapStats memory stats) 
    {
        LibTokenSwapStorage.TokenSwapStorage storage s = LibTokenSwapStorage.swapStorage();
        LibTokenSwapStorage.SwapPair storage pair = s.swapPairs[pairId];

        // Calculate effective rates for both directions
        stats.effectiveRateForward = _calculateHybridRate(pairId, user, 0, true);
        stats.effectiveRateReverse = _calculateHybridRate(pairId, user, 0, false);

        // Get remaining daily limit
        uint256 currentDay = _getCurrentDay();
        uint256 swapped = s.userDailySwapped[pairId][user][currentDay];
        stats.remainingDailyLimit = swapped >= pair.dailyLimit ? 0 : pair.dailyLimit - swapped;

        // Get user volume and reputation data
        stats.userTotalVolume = s.userTotalVolume[pairId][user];
        stats.reputationTier = s.userReputation[user].tier;
        stats.volumeBonus = _calculateVolumeBonus(pairId, user);
        stats.reputationBonus = s.userReputation[user].bonusBps;

        // Get pair configuration
        stats.tokenA = pair.tokenA;
        stats.tokenB = pair.tokenB;
        stats.baseRate = pair.baseRate;
        stats.feePercent = pair.feePercent;
        stats.dailyLimit = pair.dailyLimit;
        stats.enabled = pair.enabled;

        return stats;
    }

    // Internal functions

    /**
     * @notice Calculate hybrid dynamic rate
     * Components:
     * 1. Base rate (fixed)
     * 2. Supply multiplier (elastic based on token supply vs target)
     * 3. Volume bonus (bulk discount tiers)
     * 4. Reputation bonus (loyalty rewards)
     * 
     * IMPORTANT: Rate is calculated the SAME for both directions to prevent arbitrage!
     * The rate always represents: tokenB per tokenA (e.g., 100e18 = 1 ZICO = 100 YELLOW)
     */
    function _calculateHybridRate(
        bytes32 pairId,
        address user,
        uint256,
        bool isForward
    ) internal view returns (uint256) {
        LibTokenSwapStorage.TokenSwapStorage storage s = LibTokenSwapStorage.swapStorage();
        LibTokenSwapStorage.SwapPair storage pair = s.swapPairs[pairId];

        // Get base rate - from oracle (with fallback) or static config
        uint256 baseRate;
        if (pair.useOraclePrice && pair.uniswapV3Pool != address(0)) {
            // Try to get price from Uniswap V3 oracle with fallback chain
            baseRate = _getOraclePriceWithFallback(pair);
        } else {
            baseRate = pair.baseRate;
        }

        if (!isForward) {
            // Apply reverse rate multiplier for tokenB -> tokenA swaps
            // If multiplier = 10500 (105%), effective rate increases by 5%
            uint256 multiplier = pair.reverseRateMultiplier;
            if (multiplier == 0) multiplier = BASIS_POINTS; // Default to 100% if not set
            baseRate = (baseRate * multiplier) / BASIS_POINTS;
        }

        // Calculate supply-based multiplier (optional, can be disabled if using oracle)
        uint256 supplyMultiplier = _calculateSupplyMultiplier(pair);

        // Calculate volume and reputation bonuses
        uint256 volumeBonus = _calculateVolumeBonus(pairId, user);
        uint256 reputationBonus = s.userReputation[user].bonusBps;

        // Apply multipliers: rate * (supply) * (1 + volumeBonus) * (1 + repBonus)
        uint256 adjustedRate = baseRate;
        adjustedRate = (adjustedRate * supplyMultiplier) / RATE_PRECISION;
        adjustedRate = (adjustedRate * (BASIS_POINTS + volumeBonus)) / BASIS_POINTS;
        adjustedRate = (adjustedRate * (BASIS_POINTS + reputationBonus)) / BASIS_POINTS;

        // Clamp to min/max bounds
        if (adjustedRate < pair.minRate) adjustedRate = pair.minRate;
        if (adjustedRate > pair.maxRate) adjustedRate = pair.maxRate;

        return adjustedRate;
    }

    /**
     * @notice Calculate supply-based multiplier
     * ALWAYS uses tokenA (ZICO) supply to ensure consistent rate in both directions
     * If tokenA supply > target: rate decreases (cheaper to buy tokenB)
     * If tokenA supply < target: rate increases (more expensive to buy tokenB)
     */
    function _calculateSupplyMultiplier(
        LibTokenSwapStorage.SwapPair storage pair
    ) internal view returns (uint256) {
        uint256 targetSupply = pair.targetSupplyA;
        
        if (targetSupply == 0) return RATE_PRECISION; // No adjustment if target not set

        address token = pair.tokenA;  // Always use tokenA for consistency
        uint256 currentSupply = IMintableBurnable(token).totalSupply();

        if (currentSupply == 0) return RATE_PRECISION;

        // Calculate ratio: (target / current)^0.5 for smooth adjustment
        // If current > target: ratio < 1 (rate decreases - more tokenB per tokenA)
        // If current < target: ratio > 1 (rate increases - less tokenB per tokenA)
        uint256 ratio = (targetSupply * RATE_PRECISION) / currentSupply;
        
        // Square root for gentler curve
        uint256 multiplier = _sqrt(ratio * RATE_PRECISION);

        // Clamp to ±20% adjustment
        uint256 minMultiplier = (RATE_PRECISION * 80) / 100;
        uint256 maxMultiplier = (RATE_PRECISION * 120) / 100;

        if (multiplier < minMultiplier) multiplier = minMultiplier;
        if (multiplier > maxMultiplier) multiplier = maxMultiplier;

        return multiplier;
    }

    /**
     * @notice Calculate volume tier bonus
     */
    function _calculateVolumeBonus(bytes32 pairId, address user) 
        internal 
        view 
        returns (uint256) 
    {
        LibTokenSwapStorage.TokenSwapStorage storage s = LibTokenSwapStorage.swapStorage();
        uint256 userVolume = s.userTotalVolume[pairId][user];

        LibTokenSwapStorage.VolumeTier[] storage tiers = s.volumeTiers[pairId];
        
        uint256 bonusBps = 0;
        for (uint256 i = 0; i < tiers.length; i++) {
            if (userVolume >= tiers[i].threshold) {
                bonusBps = tiers[i].bonusBps;
            } else {
                break;
            }
        }

        return bonusBps;
    }

    /**
     * @notice Execute swap mechanics with treasury integration and hybrid mint logic
     * @dev Priority: 1) Transfer from treasury, 2) Mint if allowed and treasury insufficient
     */
    function _executeSwapMechanics(
        LibTokenSwapStorage.SwapPair storage pair,
        address tokenIn,
        address tokenOut,
        address user,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 pairId
    ) internal {
        address treasury = _getTreasuryAddress();
        if (treasury == address(0)) revert TreasuryNotConfigured();

        bool isForward = tokenIn == pair.tokenA;

        // Handle input token (burn or transfer to treasury)
        _handleInputToken(pair, tokenIn, user, amountIn, treasury, isForward);

        // Handle output token (from treasury or mint)
        _handleOutputToken(pair, tokenOut, user, amountOut, treasury, isForward, pairId);
    }

    function _handleInputToken(
        LibTokenSwapStorage.SwapPair storage pair,
        address tokenIn,
        address user,
        uint256 amountIn,
        address treasury,
        bool isForward
    ) private {
        if (isForward) {
            // Processing tokenA input
            if (pair.burnTokenA) {
                IMintableBurnable(tokenIn).burnFrom(user, amountIn, "token_swap");
            } else {
                IERC20(tokenIn).safeTransferFrom(user, treasury, amountIn);
            }
        } else {
            // Processing tokenB input
            if (pair.burnTokenB) {
                IMintableBurnable(tokenIn).burnFrom(user, amountIn, "token_swap");
            } else {
                IERC20(tokenIn).safeTransferFrom(user, treasury, amountIn);
            }
        }
    }

    function _handleOutputToken(
        LibTokenSwapStorage.SwapPair storage pair,
        address tokenOut,
        address user,
        uint256 amountOut,
        address treasury,
        bool isForward,
        bytes32 pairId
    ) private {
        bool allowMint = isForward ? pair.allowMintTokenB : pair.allowMintTokenA;
        
        _sendTokenWithFallback(
            tokenOut,
            treasury,
            user,
            amountOut,
            allowMint,
            pairId
        );
    }

    /**
     * @notice Send token with fallback to minting if treasury insufficient
     * @dev 1. Try transfer from treasury, 2. If insufficient and mint allowed -> mint difference
     */
    function _sendTokenWithFallback(
        address token,
        address treasury,
        address recipient,
        uint256 amount,
        bool allowMint,
        bytes32 pairId
    ) internal {
        uint256 treasuryBalance = IERC20(token).balanceOf(treasury);
        
        if (treasuryBalance >= amount) {
            // Treasury has enough - just transfer
            IERC20(token).safeTransferFrom(treasury, recipient, amount);
        } else {
            // Treasury insufficient
            if (treasuryBalance > 0) {
                // Transfer what's available from treasury
                IERC20(token).safeTransferFrom(treasury, recipient, treasuryBalance);
            }
            
            uint256 shortfall = amount - treasuryBalance;
            
            if (allowMint) {
                // Mint the difference if allowed
                IMintableBurnable(token).mint(recipient, shortfall, "token_swap_mint");
                emit TokenMinted(pairId, token, shortfall, "treasury_insufficient");
            } else {
                // Mint not allowed - revert
                revert InsufficientBalance(amount, treasuryBalance);
            }
        }
    }

    /**
     * @notice Get treasury address from LibStakingStorage
     */
    function _getTreasuryAddress() internal view returns (address) {
        return LibStakingStorage.stakingStorage().settings.treasuryAddress;
    }

    function _checkAndUpdateDailyLimit(bytes32 pairId, address user) internal {
        LibTokenSwapStorage.TokenSwapStorage storage s = LibTokenSwapStorage.swapStorage();

        uint256 currentDay = _getCurrentDay();

        if (s.lastSwapDay[pairId][user] < currentDay) {
            s.userDailySwapped[pairId][user][currentDay] = 0;
            s.lastSwapDay[pairId][user] = currentDay;
        }
    }

    function _getCurrentDay() internal view returns (uint256) {
        return block.timestamp / 1 days;
    }

    // ============================================
    // UNISWAP V3 ORACLE FUNCTIONS
    // ============================================

    /**
     * @notice Get oracle price with fallback chain:
     *         1. TWAP (observe) -> 2. Spot (slot0) -> 3. baseRate
     * @param pair The swap pair configuration
     * @return price Price in RATE_PRECISION (tokenB per tokenA)
     */
    function _getOraclePriceWithFallback(
        LibTokenSwapStorage.SwapPair storage pair
    ) internal view returns (uint256 price) {
        address pool = pair.uniswapV3Pool;
        uint32 twapInterval = pair.twapInterval;

        // Fallback 1: Try TWAP first (most manipulation-resistant)
        if (twapInterval > 0) {
            (bool success, uint256 twapPrice) = _tryGetTWAP(pool, twapInterval, pair.oracleTokenOrder);
            if (success && twapPrice > 0) {
                return twapPrice;
            }
        }

        // Fallback 2: Try spot price from slot0
        (bool spotSuccess, uint256 spotPrice) = _tryGetSpotPrice(pool, pair.oracleTokenOrder);
        if (spotSuccess && spotPrice > 0) {
            return spotPrice;
        }

        // Fallback 3: Return static baseRate
        return pair.baseRate;
    }

    /**
     * @notice Try to get TWAP price from Uniswap V3 pool
     * @param pool Pool address
     * @param twapInterval Seconds for TWAP calculation
     * @param tokenAIsToken0 True if tokenA is token0 in pool
     * @return success Whether the call succeeded
     * @return price TWAP price in RATE_PRECISION
     */
    function _tryGetTWAP(
        address pool,
        uint32 twapInterval,
        bool tokenAIsToken0
    ) internal view returns (bool success, uint256 price) {
        // Build secondsAgos array: [twapInterval, 0] for time-weighted average
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapInterval;
        secondsAgos[1] = 0;

        try IUniswapV3Pool(pool).observe(secondsAgos) returns (
            int56[] memory tickCumulatives,
            uint160[] memory
        ) {
            // Calculate average tick over the interval
            int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
            int24 averageTick = int24(tickCumulativesDelta / int56(uint56(twapInterval)));

            // Convert tick to price
            price = _tickToPrice(averageTick, tokenAIsToken0);
            success = true;
        } catch {
            success = false;
            price = 0;
        }
    }

    /**
     * @notice Try to get spot price from slot0
     * @param pool Pool address
     * @param tokenAIsToken0 True if tokenA is token0 in pool
     * @return success Whether the call succeeded
     * @return price Spot price in RATE_PRECISION
     */
    function _tryGetSpotPrice(
        address pool,
        bool tokenAIsToken0
    ) internal view returns (bool success, uint256 price) {
        try IUniswapV3Pool(pool).slot0() returns (
            uint160 sqrtPriceX96,
            int24,
            uint16,
            uint16,
            uint16,
            uint8,
            bool
        ) {
            price = _sqrtPriceX96ToPrice(sqrtPriceX96, tokenAIsToken0);
            success = true;
        } catch {
            success = false;
            price = 0;
        }
    }

    /**
     * @notice Convert Uniswap V3 tick to price
     * @dev tick = log1.0001(price), so price = 1.0001^tick
     * @param tick The tick value
     * @param tokenAIsToken0 True if tokenA is token0 (affects price direction)
     * @return price Price in RATE_PRECISION (tokenB per tokenA)
     */
    function _tickToPrice(int24 tick, bool tokenAIsToken0) internal pure returns (uint256 price) {
        // Calculate 1.0001^tick using the formula from Uniswap V3
        // For efficiency, we use sqrt(1.0001)^(2*tick) = 1.0001^tick
        uint256 absTick = tick < 0 ? uint256(uint24(-tick)) : uint256(uint24(tick));

        // Start with Q128 representation
        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        // Convert from Q128 to price with RATE_PRECISION
        // price = ratio >> 128, but we need to scale to RATE_PRECISION
        uint256 priceX128 = ratio;

        // If tokenA is token0, price = token1/token0 (what we want for tokenB per tokenA)
        // If tokenA is token1, price = token0/token1, so we need to invert
        if (tokenAIsToken0) {
            // price already represents tokenB/tokenA (token1/token0)
            // To avoid overflow: (priceX128 >> 64) * RATE_PRECISION >> 64
            price = ((priceX128 >> 64) * RATE_PRECISION) >> 64;
        } else {
            // Need to invert: tokenB/tokenA = 1 / (token1/token0) = token0/token1
            // price = RATE_PRECISION^2 / priceX128 (scaled)
            if (priceX128 == 0) return 0;
            // To avoid overflow: (2^64 * RATE_PRECISION) / (priceX128 >> 64)
            uint256 shifted = priceX128 >> 64;
            if (shifted == 0) return type(uint256).max; // Very small price = very large inverse
            price = ((uint256(1) << 64) * RATE_PRECISION) / shifted;
        }
    }

    /**
     * @notice Convert sqrtPriceX96 to price
     * @dev sqrtPriceX96 = sqrt(token1/token0) * 2^96
     * @param sqrtPriceX96 The sqrt price from slot0
     * @param tokenAIsToken0 True if tokenA is token0
     * @return price Price in RATE_PRECISION (tokenB per tokenA)
     */
    function _sqrtPriceX96ToPrice(
        uint160 sqrtPriceX96,
        bool tokenAIsToken0
    ) internal pure returns (uint256 price) {
        // price = (sqrtPriceX96 / 2^96)^2 = sqrtPriceX96^2 / 2^192
        // We want to scale to RATE_PRECISION (1e18)

        uint256 sqrtPrice = uint256(sqrtPriceX96);

        if (tokenAIsToken0) {
            // price = token1/token0 (tokenB per tokenA) - this is what we want
            // price = sqrtPriceX96^2 * RATE_PRECISION / 2^192
            // To avoid overflow, we divide first then multiply
            // Split: (sqrtPrice^2 >> 64) * RATE_PRECISION >> 128
            uint256 sqrtPriceSquared = sqrtPrice * sqrtPrice;
            price = (sqrtPriceSquared >> 64) * RATE_PRECISION >> 128;
        } else {
            // price = token0/token1, but we want tokenB/tokenA = token0/token1
            // So we need: price = 2^192 * RATE_PRECISION / sqrtPriceX96^2
            // To avoid overflow: (2^128 * RATE_PRECISION) / (sqrtPrice^2 >> 64)
            uint256 sqrtPriceSquared = sqrtPrice * sqrtPrice;
            if (sqrtPriceSquared == 0) return 0;
            price = ((uint256(1) << 128) * RATE_PRECISION) / (sqrtPriceSquared >> 64);
        }
    }

    // ============================================
    // ORACLE CONFIGURATION FUNCTIONS
    // ============================================

    /**
     * @notice Configure Uniswap V3 oracle for a swap pair
     * @param pairId Pair identifier
     * @param pool Uniswap V3 pool address
     * @param twapInterval TWAP interval in seconds (recommended: 1800 = 30 min)
     * @param tokenAIsToken0 True if pair.tokenA is token0 in the Uniswap pool
     */
    function configureOracle(
        bytes32 pairId,
        address pool,
        uint32 twapInterval,
        bool tokenAIsToken0
    ) external onlyAuthorized {
        if (pool == address(0)) revert InvalidAddress();
        if (twapInterval > 0 && twapInterval < 60) revert InvalidTwapInterval(); // Min 1 minute

        LibTokenSwapStorage.SwapPair storage pair =
            LibTokenSwapStorage.swapStorage().swapPairs[pairId];

        if (!pair.configured) revert PairNotConfigured();

        pair.uniswapV3Pool = pool;
        pair.twapInterval = twapInterval;
        pair.oracleTokenOrder = tokenAIsToken0;

        emit OracleConfigured(pairId, pool, twapInterval, tokenAIsToken0);
    }

    /**
     * @notice Configure Uniswap V3 oracle with automatic token order detection
     * @dev Queries the pool to determine if tokenA is token0 or token1
     * @param pairId Pair identifier
     * @param pool Uniswap V3 pool address
     * @param twapInterval TWAP interval in seconds (recommended: 1800 = 30 min)
     */
    function configureOracleAuto(
        bytes32 pairId,
        address pool,
        uint32 twapInterval
    ) external onlyAuthorized {
        if (pool == address(0)) revert InvalidAddress();
        if (twapInterval > 0 && twapInterval < 60) revert InvalidTwapInterval();

        LibTokenSwapStorage.SwapPair storage pair =
            LibTokenSwapStorage.swapStorage().swapPairs[pairId];

        if (!pair.configured) revert PairNotConfigured();

        // Query pool for token addresses
        address poolToken0 = IUniswapV3Pool(pool).token0();
        address poolToken1 = IUniswapV3Pool(pool).token1();

        // Determine token order
        bool tokenAIsToken0;
        if (pair.tokenA == poolToken0 && pair.tokenB == poolToken1) {
            tokenAIsToken0 = true;
        } else if (pair.tokenA == poolToken1 && pair.tokenB == poolToken0) {
            tokenAIsToken0 = false;
        } else {
            revert PoolTokenMismatch();
        }

        pair.uniswapV3Pool = pool;
        pair.twapInterval = twapInterval;
        pair.oracleTokenOrder = tokenAIsToken0;

        emit OracleConfigured(pairId, pool, twapInterval, tokenAIsToken0);
    }

    /**
     * @notice Enable or disable oracle price for a pair
     * @param pairId Pair identifier
     * @param enabled True to use oracle price, false to use static baseRate
     */
    function setOraclePriceEnabled(bytes32 pairId, bool enabled) external onlyAuthorized {
        LibTokenSwapStorage.SwapPair storage pair =
            LibTokenSwapStorage.swapStorage().swapPairs[pairId];

        if (!pair.configured) revert PairNotConfigured();
        if (enabled && pair.uniswapV3Pool == address(0)) revert OracleNotConfigured();

        pair.useOraclePrice = enabled;

        emit OracleEnabled(pairId, enabled);
    }

    /**
     * @notice Update TWAP interval
     * @param pairId Pair identifier
     * @param twapInterval New TWAP interval in seconds (0 = use spot price only)
     */
    function setOracleTwapInterval(bytes32 pairId, uint32 twapInterval) external onlyAuthorized {
        if (twapInterval > 0 && twapInterval < 60) revert InvalidTwapInterval();

        LibTokenSwapStorage.SwapPair storage pair =
            LibTokenSwapStorage.swapStorage().swapPairs[pairId];

        if (!pair.configured) revert PairNotConfigured();

        pair.twapInterval = twapInterval;
    }

    // ============================================
    // ORACLE VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get current oracle price for a pair
     * @param pairId Pair identifier
     * @return twapPrice TWAP price (0 if failed)
     * @return spotPrice Spot price (0 if failed)
     * @return baseRate Static base rate
     * @return activePrice Currently active price (based on config)
     */
    function getOraclePrice(bytes32 pairId) external view returns (
        uint256 twapPrice,
        uint256 spotPrice,
        uint256 baseRate,
        uint256 activePrice
    ) {
        LibTokenSwapStorage.SwapPair storage pair =
            LibTokenSwapStorage.swapStorage().swapPairs[pairId];

        baseRate = pair.baseRate;

        if (pair.uniswapV3Pool != address(0)) {
            // Try TWAP
            if (pair.twapInterval > 0) {
                (bool twapSuccess, uint256 twap) = _tryGetTWAP(
                    pair.uniswapV3Pool,
                    pair.twapInterval,
                    pair.oracleTokenOrder
                );
                if (twapSuccess) twapPrice = twap;
            }

            // Try spot
            (bool spotSuccess, uint256 spot) = _tryGetSpotPrice(
                pair.uniswapV3Pool,
                pair.oracleTokenOrder
            );
            if (spotSuccess) spotPrice = spot;
        }

        // Determine active price
        if (pair.useOraclePrice && pair.uniswapV3Pool != address(0)) {
            activePrice = _getOraclePriceWithFallback(pair);
        } else {
            activePrice = baseRate;
        }
    }

    /**
     * @notice Get oracle configuration for a pair
     * @param pairId Pair identifier
     * @return pool Uniswap V3 pool address
     * @return twapInterval TWAP interval in seconds
     * @return useOracle Whether oracle is enabled
     * @return tokenAIsToken0 Token order in pool
     */
    function getOracleConfig(bytes32 pairId) external view returns (
        address pool,
        uint32 twapInterval,
        bool useOracle,
        bool tokenAIsToken0
    ) {
        LibTokenSwapStorage.SwapPair storage pair =
            LibTokenSwapStorage.swapStorage().swapPairs[pairId];

        return (
            pair.uniswapV3Pool,
            pair.twapInterval,
            pair.useOraclePrice,
            pair.oracleTokenOrder
        );
    }

    /**
     * @notice Babylonian method for square root
     */
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
}
