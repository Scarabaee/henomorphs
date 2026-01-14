// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title PodsUtils
 * @notice Utility library for Henomorphs Pods
 * @dev Contains ID combining/extraction and other utility functions
 */
library PodsUtils {
    /**
     * @notice Combine collection ID and token ID into a single ID
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return combinedId Combined ID
     */
    function combineIds(uint256 collectionId, uint256 tokenId) internal pure returns (uint256 combinedId) {
        return (collectionId << 128) | tokenId;
    }

    /**
     * @notice Extract collection ID and token ID from a combined ID
     * @param combinedId Combined ID
     * @return collectionId Collection ID
     * @return tokenId Token ID
     */
    function extractIds(uint256 combinedId) internal pure returns (uint256 collectionId, uint256 tokenId) {
        collectionId = combinedId >> 128;
        tokenId = combinedId & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    }
    
    /**
     * @notice Extract collection ID from a combined ID
     * @param combinedId Combined ID
     * @return collectionId Collection ID
     */
    function extractCollectionId(uint256 combinedId) internal pure returns (uint256 collectionId) {
        return combinedId >> 128;
    }
    
    /**
     * @notice Extract token ID from a combined ID
     * @param combinedId Combined ID
     * @return tokenId Token ID
     */
    function extractTokenId(uint256 combinedId) internal pure returns (uint256 tokenId) {
        return combinedId & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    }
    
    /**
     * @notice Check if a combined ID is valid
     * @param combinedId Combined ID
     * @return isValid Whether the ID is valid
     */
    function isValidCombinedId(uint256 combinedId) internal pure returns (bool isValid) {
        // A valid combined ID should have a non-zero collection ID
        uint256 collectionId = combinedId >> 128;
        return collectionId > 0;
    }
}