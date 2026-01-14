// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./CrestTypes.sol";

/**
 * @title ICrestMetadata
 * @notice Interface for Colonial Crests metadata descriptor
 * @author rutilicus.eth (ZicoDAO)
 */
interface ICrestMetadata {
    /**
     * @notice Generate token URI for a given crest
     * @param tokenId The token ID
     * @param collection Collection configuration
     * @param crest Crest data with heraldic attributes
     * @return Token URI as base64 encoded JSON
     */
    function tokenURI(
        uint256 tokenId,
        CrestTypes.Collection calldata collection,
        CrestTypes.CrestData calldata crest
    ) external view returns (string memory);

    /**
     * @notice Generate contract URI for the collection
     * @param collection Collection configuration
     * @return Contract URI as base64 encoded JSON
     */
    function contractURI(
        CrestTypes.Collection calldata collection
    ) external view returns (string memory);

    /**
     * @notice Get archetype name as string
     * @param archetype The archetype enum value
     * @return name Human-readable archetype name
     */
    function getArchetypeName(
        CrestTypes.Archetype archetype
    ) external pure returns (string memory name);
}
