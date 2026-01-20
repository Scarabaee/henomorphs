// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ItemType} from "./CollectionModel.sol";

/**
 * @notice Structs and enums module which provides an minting model of the PCS collections. 
 *
 * @custom:website https://nft.poczta-polska.pl
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */

/**
 * @dev Struct that keeps issue tiers item specific properties.
 */
struct MintItem {
    // The tier of the issue series to upgrade.
    uint8 tier;
    // The amount of items to mint.
    uint256 amount;
}

/**
 * @dev Struct that keeps mint tiers pricing.
 */
struct ItemPrice {
    // The regular price of mint.
    uint256 regular;
    // The discounted price of mint.
    uint256 discounted;
    // Currency is a native token.
    bool chargeNative;
    // Mint price
    IERC20 currency;
    // The address the tokens or withdrawals maight be deposited
    address beneficiary;
}

/**
 * @dev Struct that is used to definie mint paremeters
 */
struct MintInfo {
    // The type of item to upgrade.
    ItemType itemType;
     // Issue ID, subsequent number of the series 
    uint256 issueId;
    // Item's claim tier
    uint8 mintTier;
    // Max items supply
    uint256 maxSupply;
    // Max available mints per wallet
    uint256 maxMints;
    // Max items for free
    uint256 freeMints;
    // Item pricing
    ItemPrice price;
    // Whether the offer is on sale
    bool onSale;
    // Whether the mint is to purchase
    bool isPayable;
    // Whether the mint is active
    bool isActive;
}

/**
 * @dev Struct that is used to request a mint.
 */
struct MintRequest {
    // The type of item to claim.
    ItemType itemType;
    // The ID of the issue to claim.
    uint256 issueId;
    // The tier of the issue series to claim.
    MintItem item;
    // Mint paid value
    uint256 value;
    //  IDs of exchange rate quotation rounds, [0,0] for latest.
    uint80[2] rounds;
    // `true` to agree to the Terms
    bool consentApproved;
    // A merkle proof validation number.
    uint256 seed;
    // A merkle proof proving the claim is valid.
    bytes32[] merkleProof;
    // To whom to send tokens
    address recipient; 
}
