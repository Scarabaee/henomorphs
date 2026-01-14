// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title ITransferCallback
 * @notice Interface for game contracts that want to react to YLW transfers
 * @dev Rekomendacja 9: Transfer hooks for game contracts integration
 */
interface ITransferCallback {
    /**
     * @notice Called when YLW tokens are received
     * @param from Address tokens came from
     * @param amount Amount received
     */
    function onYLWReceived(address from, uint256 amount) external;

    /**
     * @notice Called when YLW tokens are spent/sent
     * @param to Address tokens were sent to
     * @param amount Amount sent
     */
    function onYLWSpent(address to, uint256 amount) external;
}

/**
 * @title YellowToken (YLW)
 * @notice UUPS upgradeable utility token for Colony Wars daily operations
 * @dev Unlimited supply token earned through gameplay, used for repairs, processing, crafting
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract YellowToken is 
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PausableUpgradeable,
    ERC20PermitUpgradeable,
    ERC20VotesUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // Custom errors
    error InvalidAmount();
    error InvalidRecipient();
    error DailyLimitExceeded();
    error EmptyReason();
    error TransferNotAuthorized();
    error UnauthorizedTransferContract();
    error AddressBlacklisted(address account);
    error FlashMintDetected();
    error CannotWithdrawYLW();

    // Events for transparency and tracking
    event TokensMinted(address indexed to, uint256 amount, string reason);
    event TokensBurned(address indexed from, uint256 amount, string reason);
    event DailyLimitUpdated(uint256 oldLimit, uint256 newLimit);
    event AuthorizedPairUpdated(address indexed pair, bool status);
    event TransferRestrictionUpdated(bool enabled);
    event AuthorizedTransferContractUpdated(address indexed contractAddress, bool status);
    event BlacklistUpdated(address indexed account, bool status);
    event TransferCallbackUpdated(address indexed callback, bool status);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);
    event WhitelistedRecipientUpdated(address indexed recipient, bool status);
    event NFTGatingUpdated(address indexed nftContract, bool enabled);
    event LimitExemptMinterUpdated(address indexed minter, bool status);

    // Daily minting limits per address (anti-abuse)
    mapping(address => uint256) public dailyMinted;
    mapping(address => uint256) public lastMintDay;
    uint256 public dailyMintLimit;

    // Option 1: Whitelist authorized liquidity pairs (e.g., official Uniswap/QuickSwap pools)
    mapping(address => bool) public authorizedPairs;
    bool public transferRestrictionEnabled;

    // Option 2: Whitelist authorized transfer contracts (e.g., official swap contract)
    mapping(address => bool) public authorizedTransferContracts;

    // Rekomendacja 4: Blacklist (security measure)
    mapping(address => bool) public blacklisted;

    // Rekomendacja 6: Flash mint prevention
    mapping(address => uint256) private lastMintBlock;

    // Rekomendacja 9: Transfer hooks for game contracts
    mapping(address => bool) public registeredCallbacks;

    // Whitelist dozwolonych odbiorców transferu
    mapping(address => bool) public whitelistedRecipients;

    // ERC721 gating: adres tokena NFT wymaganego do otrzymywania YLW
    address public requiredNFTContract;
    bool public nftGatingEnabled;

    // Minters exempt from daily recipient limits (have their own limit mechanisms)
    mapping(address => bool) public limitExemptMinters;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the YellowToken contract
     * @param defaultAdmin Address that will have DEFAULT_ADMIN_ROLE
     */
    function initialize(address defaultAdmin) public initializer {
        if (defaultAdmin == address(0)) revert InvalidRecipient();

        __ERC20_init("Yellow Token", "YLW");
        __ERC20Burnable_init();
        __ERC20Pausable_init();
        __ERC20Permit_init("Yellow Token"); // Rekomendacja 3: EIP-2612 Permit
        __ERC20Votes_init(); // Rekomendacja 8: Snapshot dla airdrops/rewards
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(UPGRADER_ROLE, defaultAdmin);

        // Set default daily limit to 10,000 YLW per address
        dailyMintLimit = 10_000 * 10**18;
    }

    /**
     * @notice Mint tokens to an address with reason tracking
     * @param to Recipient address
     * @param amount Amount to mint (in wei)
     * @param reason Description of why tokens are minted
     * @dev Only MINTER_ROLE can call. Respects daily limits per address.
     */
    function mint(
        address to, 
        uint256 amount, 
        string calldata reason
    ) external onlyRole(MINTER_ROLE) whenNotPaused {
        if (to == address(0)) revert InvalidRecipient();
        if (amount == 0) revert InvalidAmount();
        if (bytes(reason).length == 0) revert EmptyReason();
        
        // Rekomendacja 4: Sprawdzenie blacklist
        if (blacklisted[to]) revert AddressBlacklisted(to);
        
        // Rekomendacja 6: Flash mint prevention
        if (lastMintBlock[to] == block.number) revert FlashMintDetected();
        lastMintBlock[to] = block.number;

        // Check daily limit (skip for exempt minters - they have own limits)
        if (!limitExemptMinters[msg.sender]) {
            uint256 currentDay = block.timestamp / 1 days;
            if (lastMintDay[to] < currentDay) {
                dailyMinted[to] = 0;
                lastMintDay[to] = currentDay;
            }

            if (dailyMinted[to] + amount > dailyMintLimit) {
                revert DailyLimitExceeded();
            }

            dailyMinted[to] += amount;
        }

        _mint(to, amount);

        emit TokensMinted(to, amount, reason);
    }

    /**
     * @notice Administrative mint that bypasses daily limits
     * @param to Recipient address
     * @param amount Amount to mint (in wei)
     * @param reason Description of why tokens are minted
     * @dev Only DEFAULT_ADMIN_ROLE can call. Use for initial liquidity, airdrops, etc.
     */
    function adminMint(
        address to,
        uint256 amount,
        string calldata reason
    ) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (to == address(0)) revert InvalidRecipient();
        if (amount == 0) revert InvalidAmount();
        if (bytes(reason).length == 0) revert EmptyReason();

        if (blacklisted[to]) revert AddressBlacklisted(to);

        _mint(to, amount);

        emit TokensMinted(to, amount, reason);
    }

    /**
     * @notice Burn tokens from an address with reason tracking
     * @param from Address to burn from
     * @param amount Amount to burn (in wei)
     * @param reason Description of why tokens are burned
     * @dev Only BURNER_ROLE can call
     */
    function burnFrom(
        address from,
        uint256 amount,
        string calldata reason
    ) public onlyRole(BURNER_ROLE) {
        if (from == address(0)) revert InvalidRecipient();
        if (amount == 0) revert InvalidAmount();
        if (bytes(reason).length == 0) revert EmptyReason();

        _burn(from, amount);

        emit TokensBurned(from, amount, reason);
    }

    /**
     * @notice Burn own tokens with reason
     * @param amount Amount to burn
     * @param reason Description of why tokens are burned
     */
    function burn(uint256 amount, string calldata reason) public {
        if (amount == 0) revert InvalidAmount();
        if (bytes(reason).length == 0) revert EmptyReason();

        _burn(_msgSender(), amount);

        emit TokensBurned(_msgSender(), amount, reason);
    }

    /**
     * @notice Update daily mint limit per address
     * @param newLimit New daily limit (in wei)
     * @dev Only DEFAULT_ADMIN_ROLE can call
     */
    function setDailyMintLimit(uint256 newLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldLimit = dailyMintLimit;
        dailyMintLimit = newLimit;
        
        emit DailyLimitUpdated(oldLimit, newLimit);
    }

    /**
     * @notice Set authorized liquidity pair status (Option 1)
     * @param pair Address of liquidity pair contract
     * @param status True to authorize, false to revoke
     * @dev Only DEFAULT_ADMIN_ROLE can call. Use for official DEX pools.
     */
    function setAuthorizedPair(address pair, bool status) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (pair == address(0)) revert InvalidRecipient();
        authorizedPairs[pair] = status;
        emit AuthorizedPairUpdated(pair, status);
    }

    /**
     * @notice Enable or disable transfer restrictions (Option 1)
     * @param enabled True to enable restrictions, false to disable
     * @dev Only DEFAULT_ADMIN_ROLE can call
     */
    function setTransferRestriction(bool enabled) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        transferRestrictionEnabled = enabled;
        emit TransferRestrictionUpdated(enabled);
    }

    /**
     * @notice Set authorized transfer contract status (Option 2)
     * @param contractAddress Address of transfer contract
     * @param status True to authorize, false to revoke
     * @dev Only DEFAULT_ADMIN_ROLE can call. Use for official swap contracts.
     */
    function setAuthorizedTransferContract(address contractAddress, bool status) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (contractAddress == address(0)) revert InvalidRecipient();
        authorizedTransferContracts[contractAddress] = status;
        emit AuthorizedTransferContractUpdated(contractAddress, status);
    }

    /**
     * @notice Rekomendacja 4: Add or remove address from blacklist
     * @param account Address to blacklist/unblacklist
     * @param status True to blacklist, false to remove from blacklist
     * @dev Only DEFAULT_ADMIN_ROLE can call. Use for security in case of exploits.
     */
    function setBlacklist(address account, bool status) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (account == address(0)) revert InvalidRecipient();
        blacklisted[account] = status;
        emit BlacklistUpdated(account, status);
    }

    /**
     * @notice Rekomendacja 9: Register/unregister transfer callback contract
     * @param callback Address of callback contract
     * @param status True to register, false to unregister
     * @dev Only DEFAULT_ADMIN_ROLE can call. Allows game contracts to react to YLW transfers.
     */
    function setTransferCallback(address callback, bool status) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (callback == address(0)) revert InvalidRecipient();
        registeredCallbacks[callback] = status;
        emit TransferCallbackUpdated(callback, status);
    }

    /**
     * @notice Dodaj lub usuń adres z whitelisty dozwolonych odbiorców
     * @param recipient Adres do dodania/usunięcia z whitelisty
     * @param status True aby dodać, false aby usunąć
     * @dev Tylko DEFAULT_ADMIN_ROLE może wywołać. Używane do autoryzacji adresów które mogą otrzymywać YLW.
     */
    function setWhitelistedRecipient(address recipient, bool status) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (recipient == address(0)) revert InvalidRecipient();
        whitelistedRecipients[recipient] = status;
        emit WhitelistedRecipientUpdated(recipient, status);
    }

    /**
     * @notice Skonfiguruj NFT gating dla transferów
     * @param nftContract Adres kontraktu ERC721 (zero address aby wyłączyć)
     * @param enabled True aby włączyć gating, false aby wyłączyć
     * @dev Tylko DEFAULT_ADMIN_ROLE może wywołać. Gdy włączone, tylko posiadacze NFT mogą otrzymywać YLW.
     */
    function setNFTGating(address nftContract, bool enabled) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        requiredNFTContract = nftContract;
        nftGatingEnabled = enabled;
        emit NFTGatingUpdated(nftContract, enabled);
    }

    /**
     * @notice Set minter as exempt from daily recipient limits
     * @param minter Address of minter contract (e.g., staking diamond)
     * @param status True to exempt, false to enforce limits
     * @dev Use for contracts that have their own limit enforcement
     */
    function setLimitExemptMinter(address minter, bool status)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (minter == address(0)) revert InvalidRecipient();
        limitExemptMinters[minter] = status;
        emit LimitExemptMinterUpdated(minter, status);
    }

    /**
     * @notice Rekomendacja 7: Emergency withdraw of accidentally sent tokens
     * @param token Address of token to withdraw (cannot be YLW)
     * @param to Address to send tokens to
     * @param amount Amount to withdraw
     * @dev Only DEFAULT_ADMIN_ROLE can call. Protection against accidental token sends.
     */
    function emergencyWithdraw(
        address token, 
        address to, 
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(this)) revert CannotWithdrawYLW();
        if (to == address(0)) revert InvalidRecipient();
        
        IERC20(token).transfer(to, amount);
        emit EmergencyWithdraw(token, to, amount);
    }

    /**
     * @notice Pause all token transfers
     * @dev Only PAUSER_ROLE can call
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause all token transfers
     * @dev Only PAUSER_ROLE can call
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Authorize contract upgrade
     * @param newImplementation Address of new implementation
     * @dev Only UPGRADER_ROLE can upgrade
     */
    function _authorizeUpgrade(address newImplementation) 
        internal 
        onlyRole(UPGRADER_ROLE) 
        override 
    {}

    /**
     * @notice Hook that is called before any token transfer
     * @dev Implements Option 1 (authorized pairs), Option 2 (authorized contracts), 
     *      blacklist check, and transfer hooks
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20Upgradeable, ERC20PausableUpgradeable, ERC20VotesUpgradeable) {
        // Rekomendacja 4: Blacklist check (except minting/burning)
        if (from != address(0) && blacklisted[from]) revert AddressBlacklisted(from);
        if (to != address(0) && blacklisted[to]) revert AddressBlacklisted(to);

        // Allow minting and burning
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        // Option 2: Check if transfer is through authorized contract (checked first to allow bypass)
        // msg.sender is the contract calling transfer/transferFrom
        bool isAuthorizedContractTransfer = false;
        if (msg.sender != from) {
            // This is a transferFrom call (contract is moving tokens)
            if (!authorizedTransferContracts[msg.sender] && 
                !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
                revert UnauthorizedTransferContract();
            }
            isAuthorizedContractTransfer = authorizedTransferContracts[msg.sender];
        }

        // Option 1: Check if transfer restrictions are enabled
        // Authorized contracts can bypass these restrictions
        if (transferRestrictionEnabled && !isAuthorizedContractTransfer) {
            // Allow transfers if either from or to is an authorized pair
            // OR if sender has admin role (for emergency operations)
            // OR if recipient is whitelisted
            // OR if NFT gating is enabled and recipient owns required NFT
            bool isAuthorizedPairTransfer = authorizedPairs[from] || authorizedPairs[to];
            bool isAdminTransfer = hasRole(DEFAULT_ADMIN_ROLE, from) || hasRole(DEFAULT_ADMIN_ROLE, to);
            bool isWhitelistedRecipient = whitelistedRecipients[to];
            bool hasRequiredNFT = false;
            
            // Check NFT ownership if gating is enabled
            if (nftGatingEnabled && requiredNFTContract != address(0)) {
                try IERC721(requiredNFTContract).balanceOf(to) returns (uint256 balance) {
                    hasRequiredNFT = balance > 0;
                } catch {
                    hasRequiredNFT = false;
                }
            }
            
            if (!isAuthorizedPairTransfer && !isAdminTransfer && !isWhitelistedRecipient && !hasRequiredNFT) {
                revert TransferNotAuthorized();
            }
        }

        super._update(from, to, value);

        // Rekomendacja 9: Transfer hooks - notify registered callbacks
        if (registeredCallbacks[to]) {
            try ITransferCallback(to).onYLWReceived(from, value) {} catch {}
        }
        if (registeredCallbacks[from]) {
            try ITransferCallback(from).onYLWSpent(to, value) {} catch {}
        }
    }

    /**
     * @notice Required override for ERC20Votes
     */
    function nonces(address owner)
        public
        view
        override(ERC20PermitUpgradeable, NoncesUpgradeable)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}
