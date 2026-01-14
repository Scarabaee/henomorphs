// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IConduitRedemptionHandler  
/// @notice Interface for contracts that handle core redemptions
interface IConduitRedemptionHandler {
    /// @notice Handle core redemption from conduit token
    /// @param tokenId Token ID being redeemed from
    /// @param coresCount Number of cores being redeemed
    /// @param redeemer Address performing redemption
    /// @param data Additional data
    /// @return success Whether redemption was successful
    function onCoreRedemption(
        uint256 tokenId,
        uint8 coresCount, 
        address redeemer,
        bytes calldata data
    ) external returns (bool success);
}
