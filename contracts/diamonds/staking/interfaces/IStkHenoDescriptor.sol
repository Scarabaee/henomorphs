// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IStkHenoDescriptor
/// @notice Interface for stkHENO token metadata and SVG generation
/// @dev External contract pattern - descriptor can be upgraded independently
interface IStkHenoDescriptor {

    /// @notice Metadata structure for stkHENO receipt tokens
    struct ReceiptMetadata {
        uint256 receiptId;            // Receipt token ID
        uint256 originalTokenId;      // Original staked NFT token ID
        uint256 collectionId;         // Collection ID in staking system
        address collectionAddress;    // Address of the staked collection
        string collectionName;        // Display name of collection
        address originalStaker;       // Who first staked (receives royalties)
        address currentOwner;         // Current receipt holder
        uint8 tier;                   // Token tier (1-5)
        uint8 variant;                // Token variant (0-4)
        uint32 stakedAt;              // Stake timestamp
        uint256 stakingDays;          // Days staked
        uint256 accumulatedRewards;   // Total rewards accumulated
        uint256 pendingRewards;       // Pending unclaimed rewards
        uint256 transferCount;        // Number of ownership transfers
        bool hasAugment;              // Has equipped augment
        uint8 augmentVariant;         // Augment variant (1-4)
    }

    /// @notice Generate complete token URI with metadata and SVG
    /// @param metadata Receipt metadata
    /// @return uri Complete data URI with JSON and embedded SVG
    function tokenURI(ReceiptMetadata memory metadata) external view returns (string memory uri);

    /// @notice Generate SVG image for receipt token
    /// @param metadata Receipt metadata
    /// @return svg Complete SVG as string
    function generateSVG(ReceiptMetadata memory metadata) external view returns (string memory svg);

    /// @notice Generate collection metadata URI (OpenSea contractURI)
    /// @return uri Collection metadata data URI
    function contractURI() external pure returns (string memory uri);
}
