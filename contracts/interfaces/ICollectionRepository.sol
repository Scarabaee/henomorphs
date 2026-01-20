// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../libraries/CollectionModel.sol";

/**
 * @dev Interface of the ERC1155 standard defining the repository for definitions of the collectible series editions.
 *
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
interface ICollectionRepository {
    /**
     * @dev Returns the issue properties for the given issue Id.
     */
    function getIssueInfo(ItemType itemType, uint256 issueId) external view returns (IssueInfo memory);

    /**
     * @dev Returns the tier definition for a given `issueId` and defined `tier`.
     */
    function getItemInfo(ItemType itemType, uint256 issueId, uint8 tier) external view returns (IssueInfo memory, ItemTier memory);

    /**
     * @dev Returns the total number of tiers definined for a given `issueId`.
     */
    function getTiersCount(ItemType itemType, uint256 issueId) external view returns (uint8);

    /**
     * @dev Returns the current derived price in native chain currency 
     *      for the given `tier` of the collectible token. 
     * @param rounds IDs of exchange rate quotation rounds, [0,0] for latest.
     */
    function getDerivedItemPrice(ItemType itemType, uint256 issueId, uint8 tier, uint80[2] calldata rounds) external view returns (uint256, uint80[2] memory);

    /**
     * @dev Returns the issue phase specific settings which can override defaults for a given `issueId` and `tier`.
     */
    function getPhaseInfo(ItemType itemType, uint256 issueId, uint8 tier, IssuePhase phase) external view returns (PhaseInfo memory);

    /**
     * @dev Returns the tier specific variant settings.
     */
    function getTierVariant(ItemType itemType, uint256 issueId, uint8 tier, uint8 variant) external view returns (TierVariant memory);

    /**
     * @dev Shuffles the variant for the given item thier ones for the given token ID.
     */
    function shuffleItemVariant(ItemType itemType, uint256 issueId, uint8 tier, uint256 tokenId) external returns (uint8);
}