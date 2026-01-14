// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IYellowToken
 * @notice Interface for YellowToken (YLW) utility token
 * @dev Extends standard IERC20 with minting, burning and reason tracking
 */
interface IYellowToken is IERC20 {
    /**
     * @notice Emitted when tokens are minted
     * @param to Recipient address
     * @param amount Amount minted
     * @param reason Description of why tokens were minted
     */
    event TokensMinted(address indexed to, uint256 amount, string reason);

    /**
     * @notice Emitted when tokens are burned
     * @param from Address tokens burned from
     * @param amount Amount burned
     * @param reason Description of why tokens were burned
     */
    event TokensBurned(address indexed from, uint256 amount, string reason);

    /**
     * @notice Emitted when daily mint limit is updated
     * @param oldLimit Previous limit
     * @param newLimit New limit
     */
    event DailyLimitUpdated(uint256 oldLimit, uint256 newLimit);

    /**
     * @notice Emitted when authorized pair status is updated
     * @param pair Liquidity pair address
     * @param status Authorization status
     */
    event AuthorizedPairUpdated(address indexed pair, bool status);

    /**
     * @notice Emitted when transfer restriction is toggled
     * @param enabled Restriction status
     */
    event TransferRestrictionUpdated(bool enabled);

    /**
     * @notice Emitted when authorized transfer contract status is updated
     * @param contractAddress Transfer contract address
     * @param status Authorization status
     */
    event AuthorizedTransferContractUpdated(address indexed contractAddress, bool status);

    /**
     * @notice Emitted when whitelisted recipient status is updated
     * @param recipient Recipient address
     * @param status Whitelist status
     */
    event WhitelistedRecipientUpdated(address indexed recipient, bool status);

    /**
     * @notice Emitted when NFT gating configuration is updated
     * @param nftContract Address of required NFT contract
     * @param enabled Whether gating is enabled
     */
    event NFTGatingUpdated(address indexed nftContract, bool enabled);

    /**
     * @notice Mint tokens to an address
     * @param to Recipient address
     * @param amount Amount to mint
     * @param reason Description of why tokens are minted
     * @dev Only callable by addresses with MINTER_ROLE
     */
    function mint(address to, uint256 amount, string calldata reason) external;

    /**
     * @notice Burn tokens from an address
     * @param from Address to burn from
     * @param amount Amount to burn
     * @param reason Description of why tokens are burned
     * @dev Only callable by addresses with BURNER_ROLE
     */
    function burnFrom(address from, uint256 amount, string calldata reason) external;

    /**
     * @notice Burn own tokens
     * @param amount Amount to burn
     * @param reason Description of why tokens are burned
     */
    function burn(uint256 amount, string calldata reason) external;

    /**
     * @notice Get daily mint limit per address
     * @return Daily mint limit in wei
     */
    function dailyMintLimit() external view returns (uint256);

    /**
     * @notice Get amount minted today for an address
     * @param account Address to check
     * @return Amount minted today in wei
     */
    function dailyMinted(address account) external view returns (uint256);

    /**
     * @notice Get last mint day for an address
     * @param account Address to check
     * @return Timestamp of last mint day
     */
    function lastMintDay(address account) external view returns (uint256);

    /**
     * @notice Update daily mint limit
     * @param newLimit New daily limit
     * @dev Only callable by DEFAULT_ADMIN_ROLE
     */
    function setDailyMintLimit(uint256 newLimit) external;

    /**
     * @notice Set authorized liquidity pair status
     * @param pair Address of liquidity pair
     * @param status Authorization status
     * @dev Only callable by DEFAULT_ADMIN_ROLE
     */
    function setAuthorizedPair(address pair, bool status) external;

    /**
     * @notice Enable or disable transfer restrictions
     * @param enabled Restriction status
     * @dev Only callable by DEFAULT_ADMIN_ROLE
     */
    function setTransferRestriction(bool enabled) external;

    /**
     * @notice Set authorized transfer contract status
     * @param contractAddress Address of transfer contract
     * @param status Authorization status
     * @dev Only callable by DEFAULT_ADMIN_ROLE
     */
    function setAuthorizedTransferContract(address contractAddress, bool status) external;

    /**
     * @notice Check if pair is authorized
     * @param pair Address to check
     * @return True if authorized
     */
    function authorizedPairs(address pair) external view returns (bool);

    /**
     * @notice Check if transfer restrictions are enabled
     * @return True if enabled
     */
    function transferRestrictionEnabled() external view returns (bool);

    /**
     * @notice Check if transfer contract is authorized
     * @param contractAddress Address to check
     * @return True if authorized
     */
    function authorizedTransferContracts(address contractAddress) external view returns (bool);

    /**
     * @notice Set whitelisted recipient status
     * @param recipient Address of recipient
     * @param status Whitelist status
     * @dev Only callable by DEFAULT_ADMIN_ROLE
     */
    function setWhitelistedRecipient(address recipient, bool status) external;

    /**
     * @notice Check if recipient is whitelisted
     * @param recipient Address to check
     * @return True if whitelisted
     */
    function whitelistedRecipients(address recipient) external view returns (bool);

    /**
     * @notice Configure NFT gating for transfers
     * @param nftContract Address of ERC721 contract (zero address to disable)
     * @param enabled True to enable gating, false to disable
     * @dev Only callable by DEFAULT_ADMIN_ROLE
     */
    function setNFTGating(address nftContract, bool enabled) external;

    /**
     * @notice Get the required NFT contract address
     * @return Address of required ERC721 contract
     */
    function requiredNFTContract() external view returns (address);

    /**
     * @notice Check if NFT gating is enabled
     * @return True if NFT gating is enabled
     */
    function nftGatingEnabled() external view returns (bool);

    /**
     * @notice Pause all token operations
     * @dev Only callable by PAUSER_ROLE
     */
    function pause() external;

    /**
     * @notice Unpause all token operations
     * @dev Only callable by PAUSER_ROLE
     */
    function unpause() external;
}
