
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../libraries/CollectionModel.sol";
import "../libraries/BoostingModel.sol";

/**
 * @dev Interface defining reward claims aware contracts.
 *
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
interface ITokenBooster {
    /**
     * @notice Allows senders to upgrade their tokens
     * 
     * @param request The token upgrade parameters.
     */
    function upgradeItems(BoostRequest calldata request) external payable returns (uint256);

    /**
     * @notice Allows to check for the amount of uses that can be claimed by address.
     * 
     * @param itemType The type of item to boost.
     * @param issueId The ID of the issue to boost.
     * @param tier The tier of the issue series to boost.
     * @param recipient The address to check for a available amount.
     *  
     * @return An amount of boosts that can be boosted by address.
     */
    function availableSlots(ItemType itemType, uint256 issueId, uint8 tier, address recipient) external returns (uint256);

    /**
     * @notice Allows to check for the total amount of slots available.
     * 
     * @param itemType The type of item to boost.
     * @param issueId The ID of the issue to boost.
     * @param tier The tier of the issue series to boost.
     *  
     * @return An amount of slots available.
     */
    function slotsSupply(ItemType itemType, uint256 issueId, uint8 tier) external returns (uint256);

    /**
     * @notice Allows to check total amount of tokens issued within given issue and tier.
     * 
     * @param itemType The type of item to boost.
     * @param issueId The ID of the issue to boost.
     * @param tier The tier of the issue series to boost.
     *  
     * @return An amount of slots available.
     */
    function totalBoosted(ItemType itemType, uint256 issueId, uint8 tier) external returns (uint256);

}