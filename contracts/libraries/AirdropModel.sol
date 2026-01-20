// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ItemType} from "./CollectionModel.sol";

/**
 * @notice Structs and enums module which provides an airdrop model of the PCS collections. 
 *
 * @custom:website https://nft.poczta-polska.pl
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */

/**
 * @dev Struct that keeps issue tiers item specific properties.
 */
struct ClaimItem {
    // The tier of the issue series to upgrade.
    uint8 tier;
    // The amount of items to mint.
    uint256 amount;
}

/**
 * @dev Struct that keeps airdrop tiers pricing.
 */
struct ItemPrice {
    // The regular price of mint.
    uint256 regular;
    // The discounted price of mint.
    uint256 discounted;
}

/**
 * @dev Struct that is used to definie boostoing paremeters
 */
struct AirdropInfo {
    // The type of item to upgrade.
    ItemType itemType;
     // Issue ID, subsequent number of the series 
    uint256 issueId;
    // Item's claim tier
    uint8 claimTier;
    // Max items supply
    uint256 maxSupply;
    // Max available claims per wallet
    uint256 maxClaims;
    // Max items for free
    uint256 freeClaims;
    // Boost price
    ItemPrice price;
    // Boost price
    IERC20 currency;
    // The address the tokens or withdrawals maight be deposited
    address beneficiary;
    // Whether the offer is on sale
    bool onSale;
    // Whether the airdrop is on sale
    bool isPayable;
}

/**
 * @dev Struct that is used to request a boost.
 */
struct ClaimRequest {
    // The type of item to claim.
    ItemType itemType;
    // The ID of the issue to claim.
    uint256 issueId;
    // The tier of the issue series to claim.
    ClaimItem item;
    // A merkle proof proving the claim is valid.
    bytes32[] merkleProof;
    // Claim paid value
    uint256 value;
    // A merkle proof validation number.
    uint256 seed;
}
