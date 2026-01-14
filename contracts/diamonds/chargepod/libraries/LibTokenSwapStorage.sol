// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title LibTokenSwapStorage
 * @notice Hybrid dynamic pricing storage for token swap system
 * @dev Diamond storage pattern with advanced tokenomics
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
library LibTokenSwapStorage {
    bytes32 constant TOKEN_SWAP_STORAGE_POSITION = 
        keccak256("henomorphs.tokenswap.storage.v1");

    struct SwapPair {
        // Token addresses
        address tokenA;
        address tokenB;

        // Base rate and bounds
        uint256 baseRate;          // Base conversion rate (tokenA per tokenB, scaled 1e18)
        uint256 minRate;           // Minimum allowed rate (floor)
        uint256 maxRate;           // Maximum allowed rate (ceiling)

        // Fees and limits
        uint256 feePercent;        // Fee in basis points (500 = 5%)
        uint256 dailyLimit;        // Max tokenB equivalent per user per day

        // Supply targets for dynamic adjustment
        uint256 targetSupplyA;     // Target supply for tokenA
        uint256 targetSupplyB;     // Target supply for tokenB

        // Mechanics
        bool burnTokenA;           // True = burn tokenA, False = transfer to/from treasury
        bool burnTokenB;           // True = burn tokenB, False = transfer to/from treasury

        // Mintable tokens whitelist
        bool allowMintTokenA;      // True = allow minting tokenA when treasury is insufficient
        bool allowMintTokenB;      // True = allow minting tokenB when treasury is insufficient

        // State
        bool enabled;
        bool configured;
        uint256 reverseRateMultiplier; // Multiplier for reverse rate (tokenB -> tokenA) in basis points
                                       // e.g., 10500 = 105% = worse rate for YLW->ZICO swap
                                       // Default: 10000 (100%) = symmetric rates

        // Uniswap V3 Oracle configuration
        address uniswapV3Pool;     // Uniswap V3 Pool address for price oracle
        uint32 twapInterval;       // TWAP interval in seconds (e.g., 1800 = 30 min)
        bool useOraclePrice;       // True = use Uniswap V3 TWAP, False = use baseRate
        bool oracleTokenOrder;     // True = tokenA is token0 in pool, False = tokenA is token1
    }

    struct VolumeTier {
        uint256 threshold;         // Cumulative volume threshold in tokenB
        uint256 bonusBps;          // Bonus in basis points (100 = 1% better rate)
    }

    struct ReputationTier {
        uint8 tier;                // 0=none, 1=bronze, 2=silver, 3=gold, 4=platinum
        uint256 bonusBps;          // Bonus in basis points
    }

    struct TokenSwapStorage {
        // Pair configurations
        mapping(bytes32 => SwapPair) swapPairs;

        // Volume tiers per pair (sorted by threshold ascending)
        mapping(bytes32 => VolumeTier[]) volumeTiers;

        // User reputation tiers (cross-pair)
        mapping(address => ReputationTier) userReputation;

        // Daily limits tracking
        mapping(bytes32 => mapping(address => mapping(uint256 => uint256))) userDailySwapped;
        mapping(bytes32 => mapping(address => uint256)) lastSwapDay;

        // Statistics
        mapping(bytes32 => mapping(address => uint256)) totalSwapped;      // Total per token per pair
        mapping(bytes32 => mapping(address => uint256)) userTotalVolume;   // User cumulative volume
        
        // NOTE: Treasury address is taken from LibStakingStorage.stakingStorage().settings.treasuryAddress
        // This ensures single source of truth for treasury configuration
    }

    function swapStorage() internal pure returns (TokenSwapStorage storage s) {
        bytes32 position = TOKEN_SWAP_STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }
}
