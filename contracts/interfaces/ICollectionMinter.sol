
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../libraries/MintingModel.sol";

/**
 * @dev Interface defining colletion minting contracts.
 *
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
interface ICollectionMinter {
    /**
     * @dev Emitted when `contract` dispatches minted tokens of specific series indicated by `issueId`.
     */
    event ItemsMinted(uint256 issueId, uint8 tier, uint256 value, ItemType itemType, address indexed recipient);

    /**
     * @dev Emitted when log is necessary.
     */
    event LogEvent(uint256 intValue, string strValue);

    /**
     * Invalid item
     */
    error InvalidItemTier(uint8 tier);

    /**
     * @dev Invalid collection contract.
     */
    error InvalidCollectionContract();

    /**
     * @dev The start should be in the future.
     */
    error InvalidStartTimestamp();

    /**
     * @dev The Start should be before end.
     */
    error InvalidEndTimestamp();
    
    /**
     * @dev Mint not started yet.
     */
    error MintNotStarted();

    /**
     * @dev Mint not started yet.
     */
    error MintNotActive();

    /**
     * @dev Mint has already ended.
     */
    error MintAlreadyEnded();

    /**
     * @dev Limit has already been minted.
     */
    error LimitAlreadyMinted();

    /**
     * @dev Invalid call data.
     */
    error InvalidCallData();

    /**
     * @dev Invalid issue data.
     */
    error InvalidIssueData();

    /**
     * @dev Forbidden claim.
     */
    error UnauthorizedClaim();

    /**
     * @dev Token disptach has failed.
     */
    error DispatchFailed();

    /**
     * Mint failed.
     */
    error ItemMintFailure(MintRequest request, string message);

    /**
     * @dev The tier max mints has been exceeded.
     */
    error MintSupplyExceeded();

    /**
     * @dev Clai of tokens to the given recipient is not allowed.
     */
    error MintNotAllowed(address recipient);

    /**
     * @dev Item cannot be minted.
     */
    error ItemNotMintable(uint8 tier);

    /**
     * @dev Value sent is to low.
     */
    error InsufficientValueSent(uint256 value);

    /**
     * @notice  Allows a sender to mint their tokens
     * 
     * @param request The token mint parameters.
     */
    function mintItems(MintRequest calldata request) external payable returns (uint256);

    /**
     * @notice Allows to check for the anount of tokens that can be minted by address.
     * 
     * @param itemType The type of item to airdrop.
     * @param issueId The ID of the issue to mint.
     * @param tier The tier of the issue series to mint.
     * @param recipient The address to check for a mintable amount.
     *  
     * @return An amount of tokens that can be minted by address.
     */
    function availability(ItemType itemType, uint256 issueId, uint8 tier, address recipient) external returns (uint256);

    /**
     * @notice Allows to check for the total amount of items to mint available.
     * 
     * @param itemType The type of item to mint.
     * @param issueId The ID of the issue to mint.
     * @param tier The tier of the issue series to mint.
     *  
     * @return An amount of items available.
     */
    function mintSupply(ItemType itemType, uint256 issueId, uint8 tier) external returns (uint256);

    /**
     * @notice Returns total amount of tokens minted within given issue and tier.
     * 
     * @param itemType The type of item to mint.
     * @param issueId The ID of the issue to mint.
     * @param tier The tier of the issue series to mint.
     *  
     * @return An amount of items already minted.
     */
    function totalMinted(ItemType itemType, uint256 issueId, uint8 tier) external returns (uint256);

    /**
     * @notice Returns total amount of tokens minted within given issue and tier.
     * 
     * @param itemType The type of item to mint.
     * @param issueId The ID of the issue to mint.
     * @param tier The tier of the issue series to mint.
     * @param recipient The address to check for a minted amount.
     *  
     * @return An amount of items already minted.
     */
    function mintedOf(ItemType itemType, uint256 issueId, uint8 tier, address recipient) external returns (uint256);

    /**
     * @dev Returns the current derived price in native chain currency 
     *      for the given `tier` of the collectible token. 
     * @param rounds IDs of exchange rate quotation rounds, [0,0] for latest.
     */
    function derivePrice(ItemType itemType, uint256 issueId, uint8 tier, uint80[2] calldata rounds) external view returns (uint256, uint80[2] memory);

    /**
     * @dev Returns the mint definition for a given `issueId` and defined `tier`.
     */
    function getMintInfo(ItemType itemType, uint256 issueId, uint8 tier) external view returns (MintInfo memory);
}