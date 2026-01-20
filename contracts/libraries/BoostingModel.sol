// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ItemType} from "./CollectionModel.sol";

/**
 * @notice Structs and enums module which provides a model of the PCS collections. 
 *
 * @custom:website https://nft.poczta-polska.pl
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */

/**
 * @dev Struct that is used to define discounts
 */
struct OnChainCoupon {
    // The discount code
    bytes32 code;
    // The discount value in percent
    uint256 discount;
    // The coupon bearer
    address bearer;
    // The coupon nonce
    string nonce;
    bytes32 r;
    bytes32 s;
    uint8 v;
}

/**
 * @dev Struct that is used to define boostoing paremeters
 */
struct BoostInfo {
    // The type of item to upgrade.
    ItemType itemType;
     // Issue ID, subsequent number of the series 
    uint256 issueId;
    // Item's base tier
    uint8 baseTier;
    // Item's tagret tier
    uint8 targetTier;
    // Max items supply
    uint256 maxSupply;
    // Max available mint per wallet
    uint256 maxSlots;
    // Boost price
    uint256 price;
    // Boost price
    IERC20 currency;
    // The address the tokens or withdrowals maight be deposited
    address beneficiary;
}

/**
 * @dev Struct that is used to request a boost.
 */
struct BoostRequest {
    // The type of item to upgrade.
    ItemType itemType;
    // The ID of the issue to upgrade.
    uint256 issueId;
    // The tier of the issue series to upgrade.
    uint8 tier;
    // The IDs of the issue tokens to upgrade.
    uint256[] tokenIds;
    // A merkle proof proving the upgrade claim is valid.
    bytes32[] merkleProof;
    // Boost price
    uint256 amount;
    // A merkle proof validation number.
    uint256 seed;
    // A discount coupon.
    OnChainCoupon coupon;
}
