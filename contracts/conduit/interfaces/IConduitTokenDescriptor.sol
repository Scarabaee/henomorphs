// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IConduitTokenDescriptor
/// @notice Interface for token metadata and SVG generation  
interface IConduitTokenDescriptor {
    
    struct TokenMetadata {
        uint256 tokenId;        // Token ID
        uint8 coreCount;        // Current core count
        uint256 expiryDate;     // Expiry timestamp
        bool isActive;          // Whether active
        address owner;          // Token owner
        uint256 ownerBalance;   // Owner's total balance of tokens
    }

    /// @notice Generate complete token URI with metadata and SVG
    /// @param metadata Token metadata
    /// @return uri Complete token URI
    function tokenURI(TokenMetadata memory metadata) external view returns (string memory uri);
    
    /// @notice Generate SVG image for token
    /// @param metadata Token metadata  
    /// @return svg Complete SVG as string
    function generateSVG(TokenMetadata memory metadata) external view returns (string memory svg);
    
    /// @notice Generate collection metadata URI (OpenSea contractURI)
    /// @return uri Collection metadata URI
    function contractURI() external pure returns (string memory uri);
}