
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @dev Interface defining an mint aware contracts.
 *
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
interface IMintableCollection {

    /**
     * @notice Items minting function for the mint available tokens.
     * 
     * @param issueId The ID of the issue to mint.
     * @param tier The tier of the issue series to mint.
     * @param value The value of items to be droped. Wheter it is amount or ID depends of implementation.
     * @param recipient If set, the destination wallet. 
     * 
     * @return A boolean value indicating whether the operation succeeded.
     */
    function mintItems(uint256 issueId, uint8 tier, uint256 value, address recipient) external returns (bool);

     /**
     * @dev Returns the value of tokens of token colllection `issueId` and its `tier` owned by `account`.
     *
     * @param account The account to be checked.
     * @param tier The ollection tier to be checked.
     */
    function collectedOf(address account, uint256 issueId, uint8 tier) external view returns (uint256);

    /**
     * issueId The ID of the issue to mint.
     * @dev Returns total amount of tokens issued within given issue and tier.
     * tier The ollection tier to be checked.
     */
    function totalItemsSupply(uint256 issueId, uint8 tier) external view returns (uint256);
}