
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../libraries/BoostingModel.sol";

/**
 * @dev Interface defining a coupon validation contract.
 *
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
interface ICouponValidator {
    /**
     * @notice On-chain discount coupon validation.
     *
     * @param coupon The discount coupon to validate.
     * @param signer The coupon signer.
     * 
     * @return A validatd discount value, 0 otherwise.
     */
    function validateCoupon(OnChainCoupon calldata coupon, address signer) external returns (uint256);
}