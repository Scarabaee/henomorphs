// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title OracleIntegrationFacet
 * @notice Chainlink oracle integration for automated market resolution
 * @dev Diamond facet for managing oracle-based prediction markets
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibPremiumStorage} from "../libraries/LibPremiumStorage.sol";
import {AccessControlBase} from "./AccessControlBase.sol";


/**
 * @title IPriceOracle
 * @notice Interface for Chainlink-compatible price oracles
 * @dev Used by PredictionMarketsFacet for price-based market resolution
 */
interface IPriceOracle {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
    
    function decimals() external view returns (uint8);
}

contract OracleIntegrationFacet is AccessControlBase {
    
    // ==================== EVENTS ====================
    
    event OracleRegistered(
        bytes32 indexed oracleId,
        address indexed oracleAddress,
        string description
    );
    
    event OracleMarketCreated(
        uint256 indexed marketId,
        bytes32 indexed oracleId,
        int256 targetPrice,
        bool isAbove
    );
    
    event OracleMarketAutoResolved(
        uint256 indexed marketId,
        int256 finalPrice,
        uint8 winningOutcome
    );
    
    // ==================== ERRORS ====================
    
    error OracleNotRegistered();
    error InvalidOracleData();
    error PriceStale();
    error ResolutionNotReady();
    error MarketNotOpen();
    error MarketAlreadyResolved();
    error InvalidAddress();
    error InvalidTimeConfiguration();
    
    // ==================== ORACLE MANAGEMENT ====================
    
    /**
     * @notice Register Chainlink price feed oracle
     * @param oracleId Unique identifier for oracle
     * @param oracleAddress Chainlink aggregator address
     * @param description Human-readable description
     * @param stalePeriod Max seconds for data freshness
     */
    function registerOracle(
        bytes32 oracleId,
        address oracleAddress,
        string calldata description,
        uint32 stalePeriod
    ) external onlyAuthorized {
        if (oracleAddress == address(0)) revert InvalidAddress();
        
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        
        // Get decimals from oracle
        uint8 decimals = IPriceOracle(oracleAddress).decimals();
        
        ps.oracles[oracleId] = LibPremiumStorage.OracleConfig({
            oracleAddress: oracleAddress,
            description: description,
            stalePeriod: stalePeriod,
            active: true,
            decimals: decimals
        });
        
        ps.oracleIds.push(oracleId);
        
        emit OracleRegistered(oracleId, oracleAddress, description);
    }
    
    /**
     * @notice Create oracle-based prediction market
     * @param oracleId Registered oracle to use
     * @param questionHash IPFS hash of question
     * @param targetPrice Target price (scaled by oracle decimals)
     * @param isAbove True if betting price will be above target
     * @param lockTime When betting closes
     * @param resolutionTime When to check oracle
     * @return marketId Created market ID
     */
    function createOracleMarket(
        bytes32 oracleId,
        bytes32 questionHash,
        int256 targetPrice,
        bool isAbove,
        uint40 lockTime,
        uint40 resolutionTime
    ) external onlyAuthorized returns (uint256 marketId) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        
        if (!ps.oracles[oracleId].active) revert OracleNotRegistered();
        if (resolutionTime <= lockTime) revert InvalidTimeConfiguration();
        
        // Create binary market (outcome 0 = below/equal, outcome 1 = above)
        string[] memory outcomes = new string[](2);
        outcomes[0] = isAbove ? "Below or Equal Target" : "Above Target";
        outcomes[1] = isAbove ? "Above Target" : "Below or Equal Target";
        
        // Create market directly in storage
        
        marketId = ++ps.marketCounter;
        
        ps.markets[marketId] = LibPremiumStorage.PredictionMarket({
            marketType: LibPremiumStorage.MarketType.BINARY,
            status: LibPremiumStorage.MarketStatus.OPEN,
            questionHash: questionHash,
            outcomeCount: 2,
            openTime: uint40(block.timestamp),
            lockTime: lockTime,
            resolutionTime: resolutionTime,
            resolvedAt: 0,
            winningOutcome: 0,
            creator: LibMeta.msgSender(),
            resolver: address(this), // Oracle resolves automatically
            creatorFee: 0,
            protocolFee: ps.defaultProtocolFee,
            totalPool: 0,
            creatorBond: 0,
            minBet: 100 ether, // 100 YLW minimum
            maxBet: 0,
            linkedEntity: oracleId,
            allowDisputes: false, // Oracle resolution is final
            disputeWindow: 0
        });
        
        // Initialize outcomes
        ps.marketOutcomes[marketId][0] = LibPremiumStorage.MarketOutcome({
            description: outcomes[0],
            pool: 0,
            shares: 0,
            impliedProb: 5000
        });
        
        ps.marketOutcomes[marketId][1] = LibPremiumStorage.MarketOutcome({
            description: outcomes[1],
            pool: 0,
            shares: 0,
            impliedProb: 5000
        });
        
        // Store oracle market config
        ps.oracleMarkets[marketId] = LibPremiumStorage.OracleMarket({
            oracleId: oracleId,
            targetPrice: targetPrice,
            isAbove: isAbove,
            resolutionDeadline: resolutionTime + 1 days, // 24h grace period
            autoResolved: false
        });
        
        emit OracleMarketCreated(marketId, oracleId, targetPrice, isAbove);
        
        return marketId;
    }
    
    /**
     * @notice Auto-resolve oracle-based market
     * @param marketId Market to resolve
     */
    function resolveOracleMarket(uint256 marketId) external {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        
        LibPremiumStorage.OracleMarket storage oracleMarket = ps.oracleMarkets[marketId];
        LibPremiumStorage.PredictionMarket storage market = ps.markets[marketId];
        
        // Validations
        if (market.status != LibPremiumStorage.MarketStatus.OPEN) revert MarketNotOpen();
        if (block.timestamp < market.resolutionTime) revert ResolutionNotReady();
        if (oracleMarket.autoResolved) revert MarketAlreadyResolved();
        
        // Get oracle config
        LibPremiumStorage.OracleConfig memory oracle = ps.oracles[oracleMarket.oracleId];
        if (!oracle.active) revert OracleNotRegistered();
        
        // Query oracle
        (
            ,
            int256 price,
            ,
            uint256 updatedAt,
            
        ) = IPriceOracle(oracle.oracleAddress).latestRoundData();
        
        // Check freshness
        if (block.timestamp - updatedAt > oracle.stalePeriod) revert PriceStale();
        
        // Determine winner
        uint8 winningOutcome;
        if (oracleMarket.isAbove) {
            // Outcome 1 wins if price is above target
            winningOutcome = price > oracleMarket.targetPrice ? 1 : 0;
        } else {
            // Outcome 1 wins if price is below target
            winningOutcome = price < oracleMarket.targetPrice ? 1 : 0;
        }
        
        // Resolve market
        market.status = LibPremiumStorage.MarketStatus.RESOLVED;
        market.winningOutcome = winningOutcome;
        market.resolvedAt = uint40(block.timestamp);
        oracleMarket.autoResolved = true;
        
        emit OracleMarketAutoResolved(marketId, price, winningOutcome);
    }
    
    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @notice Get current price from oracle
     */
    function getOraclePrice(bytes32 oracleId) 
        external 
        view 
        returns (int256 price, uint256 updatedAt) 
    {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        LibPremiumStorage.OracleConfig memory oracle = ps.oracles[oracleId];
        
        if (!oracle.active) revert OracleNotRegistered();
        
        (
            ,
            int256 answer,
            ,
            uint256 timestamp,
            
        ) = IPriceOracle(oracle.oracleAddress).latestRoundData();
        
        return (answer, timestamp);
    }
    
    /**
     * @notice Get oracle configuration
     */
    function getOracleConfig(bytes32 oracleId) 
        external 
        view 
        returns (LibPremiumStorage.OracleConfig memory) 
    {
        return LibPremiumStorage.premiumStorage().oracles[oracleId];
    }
    
    /**
     * @notice Get oracle market details
     */
    function getOracleMarket(uint256 marketId) 
        external 
        view 
        returns (LibPremiumStorage.OracleMarket memory) 
    {
        return LibPremiumStorage.premiumStorage().oracleMarkets[marketId];
    }
    
    /**
     * @notice Get all registered oracle IDs
     */
    function getRegisteredOracles() external view returns (bytes32[] memory) {
        return LibPremiumStorage.premiumStorage().oracleIds;
    }
    
    /**
     * @notice Check if market can be resolved
     */
    function canResolveMarket(uint256 marketId) external view returns (bool) {
        LibPremiumStorage.PremiumStorage storage ps = LibPremiumStorage.premiumStorage();
        
        LibPremiumStorage.OracleMarket memory oracleMarket = ps.oracleMarkets[marketId];
        LibPremiumStorage.PredictionMarket memory market = ps.markets[marketId];
        
        if (market.status != LibPremiumStorage.MarketStatus.OPEN) return false;
        if (block.timestamp < market.resolutionTime) return false;
        if (oracleMarket.autoResolved) return false;
        
        // Check oracle freshness
        LibPremiumStorage.OracleConfig memory oracle = ps.oracles[oracleMarket.oracleId];
        (, , , uint256 updatedAt, ) = IPriceOracle(oracle.oracleAddress).latestRoundData();
        
        if (block.timestamp - updatedAt > oracle.stalePeriod) return false;
        
        return true;
    }
    
    // ==================== ADMIN FUNCTIONS ====================
    
    /**
     * @notice Activate/deactivate oracle
     */
    function setOracleActive(bytes32 oracleId, bool active) external onlyAuthorized {
        LibPremiumStorage.premiumStorage().oracles[oracleId].active = active;
    }
    
    /**
     * @notice Update oracle stale period
     */
    function setOracleStalePeriod(bytes32 oracleId, uint32 stalePeriod)
        external
        onlyAuthorized
    {
        LibPremiumStorage.premiumStorage().oracles[oracleId].stalePeriod = stalePeriod;
    }

    // ==================== UTILITY FUNCTIONS ====================

    /**
     * @notice Compute keccak256 hash of a string
     * @dev Utility function to generate oracle IDs from human-readable names
     * @param input String to hash (e.g., "POL_USD", "BTC_USD")
     * @return hash The keccak256 hash as bytes32
     */
    function computeOracleId(string calldata input) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(input));
    }

    /**
     * @notice Compute keccak256 hash for market question
     * @dev Utility function to generate questionHash from market description
     * @param question Market question (e.g., "Will POL be above $0.50 on Jan 15?")
     * @return hash The keccak256 hash as bytes32 for use as questionHash
     */
    function computeQuestionHash(string calldata question) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(question));
    }
}
