
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IConduit
/// @notice Interface for conduit token contracts
interface IConduit {
    
    struct TokenConfig {
        uint8 coreCount;        // Number of cores in this token
        uint256 expiryDate;     // When token expires
        bool isActive;          // Whether token is active (not burned)
    }
    
    struct CorePricing {
        uint256 nativePrice;    // Price in native token
        uint256 tokenPrice;     // Price in alternative payable token
    }

    // Events
    event CoresMinted(uint256 indexed tokenId, address indexed to, uint8 coreCount, uint256 expiryDate);
    event CoresRedeemed(uint256 indexed tokenId, address indexed redeemer, uint8 coresRedeemed, uint8 coresRemaining);
    event TokenBurned(uint256 indexed tokenId);
    event RedemptionHandlerSet(address indexed handler);
    event TokenDescriptorSet(address indexed descriptor);
    event CorePriceUpdated(uint8 indexed coreCount, uint256 nativePrice, uint256 tokenPrice);
    event PayableTokenSet(address indexed token);

    // Custom errors
    error ZeroAddress();
    error InvalidCoreCount();
    error ConfigDisabled();
    error TokenNotActive();
    error TokenExpired();
    error InsufficientCores();
    error RedemptionFailed();
    error Unauthorized();
    error InvalidConfiguration();
    error InsufficientPayment();
    error MintLimitExceeded();

    /// @notice Mint tokens with specified cores (admin function)
    /// @param to Address to mint to
    /// @param coreCount Number of cores per token
    /// @param quantity Number of tokens to mint
    function adminMint(address to, uint8 coreCount, uint256 quantity) external;

    /// @notice Redeem cores from a token
    /// @param tokenId Token to redeem from
    /// @param coresCount Number of cores to redeem
    /// @param data Additional data for redemption handler
    function redeemCores(uint256 tokenId, uint8 coresCount, bytes calldata data) external;
    
    /// @notice Get token configuration
    /// @param tokenId Token ID to query
    /// @return config Token configuration
    function getTokenConfig(uint256 tokenId) external view returns (TokenConfig memory config);
}
