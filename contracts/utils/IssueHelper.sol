// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@prb/math/src/Common.sol";

/**
 * @notice Utility library of the crypto stamp related contracts.
 *
 * @custom:website https://nft.poczta-polska.pl
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
library IssueHelper {

    /**
     * @dev Combining two given numbers into unique one.
     * Used for deriving the final token ID basing on its category in the collection.
     */
    function combineTokenId(uint256 baseId, uint256 tokenId) internal pure returns (uint256 combinedId) {
        combinedId = mulDiv((baseId + tokenId), (baseId + tokenId + 1), 2) + tokenId;
    }

    /**
     * @dev Extracting two initial numbers form the combined one.
     * Used for deriving the collection and category IDs from the given token ID.
     */
    function extractTokenIds(uint256 combinedId) internal pure returns (uint256 baseId, uint256 tokenId) {
        uint256 _result = mulDiv((sqrt((combinedId * 8) + 1) - 1), 1, 2);

        baseId = mulDiv((_result + 3), _result, 2) - combinedId;
        tokenId = combinedId - mulDiv(_result, (_result + 1), 2);
    }

}