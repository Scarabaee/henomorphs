// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../libraries/CollectionModel.sol";
import "../libraries/AirdropModel.sol";

/**
 * @dev Interface defining reward claims aware contracts.
 *
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
interface ICommunityClaimer {
    /**
     * @notice  Allows a sender to claim their tokens
     * 
     * @param request The token claim parameters.
     */
    function claimItems(ClaimRequest calldata request) external payable returns (uint256);

    /**
     * @notice Allows to check for the anount of tokens that can be claimed by address.
     * 
     * @param itemType The type of item to airdrop.
     * @param issueId The ID of the issue to mint.
     * @param tier The tier of the issue series to mint.
     * @param recipient The address to check for a claimable amount.
     *  
     * @return An amount of tokens that can be claimed by address.
     */
    function claimableItems(ItemType itemType, uint256 issueId, uint8 tier, address recipient) external returns (uint256);

    /**
     * @notice Allows to check for the total amount of items to claim available.
     * 
     * @param itemType The type of item to claim.
     * @param issueId The ID of the issue to claim.
     * @param tier The tier of the issue series to claim.
     *  
     * @return An amount of items available.
     */
    function claimSupply(ItemType itemType, uint256 issueId, uint8 tier) external returns (uint256);

    /**
     * @notice Returns total amount of tokens claimed within given issue and tier.
     * 
     * @param itemType The type of item to claim.
     * @param issueId The ID of the issue to claim.
     * @param tier The tier of the issue series to claim.
     *  
     * @return An amount of items already climed.
     */
    function totalItemsClaimed(ItemType itemType, uint256 issueId, uint8 tier) external returns (uint256);

    /**
     * @notice Returns total amount of tokens claimed within given issue and tier.
     * 
     * @param itemType The type of item to claim.
     * @param issueId The ID of the issue to claim.
     * @param tier The tier of the issue series to claim.
     * @param recipient The address to check for a claimed amount.
     *  
     * @return An amount of items already climed.
     */
    function collectedItems(ItemType itemType, uint256 issueId, uint8 tier, address recipient) external returns (uint256);
}