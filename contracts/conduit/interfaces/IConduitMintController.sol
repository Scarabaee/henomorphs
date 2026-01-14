// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IConduitMintController
/// @notice Interface for mint controller that manages phases and whitelist verification
interface IConduitMintController {
    
    struct MintPhase {
        bytes32 merkleRoot;
        uint256 startTime;
        uint256 endTime;
        uint256 maxPerAddress;
        uint256 basePrice;
        bool isActive;
        string phaseName;
        bool allowZicoPayment;
    }

    struct PublicMintConfig {
        uint256 maxPerAddress;
        uint256 basePrice;
        bool isActive;
        uint256 startTime;
    }

    /// @notice Verify mint eligibility and calculate progressive price
    /// @param to Address attempting to mint
    /// @param quantity Number of tokens to mint
    /// @param merkleProof Merkle proof for verification
    /// @param useZico Whether user wants to pay with alternative token
    /// @param isPublic Whether this is public mint (false = whitelist)
    /// @return totalPrice Total price to pay
    /// @return allowZico Whether alternative token payment is allowed
    function verifyMint(
        address to,
        uint256 quantity,
        uint8 coreCount,
        bytes32[] calldata merkleProof,
        bool useZico,
        bool isPublic
    ) external returns (uint256 totalPrice, bool allowZico);
    
    /// @notice Get current phase information
    /// @return phase Current mint phase details
    function getCurrentPhase() external view returns (MintPhase memory phase);

    /// @notice Get public mint configuration
    /// @return config Public mint configuration
    function getPublicConfig() external view returns (PublicMintConfig memory config);

    /// @notice Check if address is whitelisted for current phase
    /// @param account Address to check
    /// @param merkleProof Merkle proof for verification
    /// @return isWhitelisted Whether address can mint
    function isWhitelisted(address account, bytes32[] calldata merkleProof) external view returns (bool);

    /// @notice Calculate progressive price for quantity
    /// @param basePrice Base price per token
    /// @param coreCount Number of cores
    /// @param quantity Number of tokens
    /// @return totalPrice Total progressive price
    function calculatePrice(uint256 basePrice, uint8 coreCount, uint256 quantity) external view returns (uint256 totalPrice);
}