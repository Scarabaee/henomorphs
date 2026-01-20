
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../libraries/CollectionModel.sol";

/**
 * @dev Interface defining a collection of boostable items contracts.
 *
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
interface IBoostableCollection {
    /**
     * @notice Items boosting function for the collection tokens.
     * 
     * @param itemType The type of item to boost.
     * @param issueId The ID of the issue to boost.
     * @param tier The tier of the issue series to boost.
     * @param tokenIds The IDs of the issue tokens to upgrade.
     * @param tier The tier of the issue series to uopgrade to.
     * 
     * @return A number of token boosted.
     */
    function upgradeItems(ItemType itemType, uint256 issueId, uint8 tier, uint256[] calldata tokenIds) external returns (uint256);

    /**
     * @notice Alows to resolve the current collection's item tier.
     * 
     * @param tokenId The ID of the issue token to resolve tier.
     * 
     * @return A current tier.
     */
    function resolveTier(uint256 tokenId) external returns (uint8);

}