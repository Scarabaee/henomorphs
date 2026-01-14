// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC721EnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {ERC2981Upgradeable} from "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IStkHenoDescriptor} from "./interfaces/IStkHenoDescriptor.sol";

/**
 * @title IStakingEarningsFacet
 * @notice Interface for fetching pending rewards from staking diamond
 */
interface IStakingEarningsFacet {
    function getPendingReward(uint256 collectionId, uint256 tokenId) external view returns (uint256 amount);
}

/**
 * @title StkHenoReceiptToken
 * @notice UUPS Upgradeable ERC721 representing staked Henomorph positions
 * @dev Liquid Staking Derivative - transferable receipt tokens for staked NFTs
 *      Transfer of stkHENO transfers ownership of the underlying staked position
 *
 *      OpenZeppelin v5 compatible - base contracts handle storage namespacing internally
 *      No __gap needed - OZ v5 uses ERC-7201 namespaced storage in base contracts
 *
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract StkHenoReceiptToken is
    Initializable,
    ERC721Upgradeable,
    ERC721EnumerableUpgradeable,
    ERC2981Upgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // ============ STRUCTS ============

    /**
     * @notice Core data for each receipt token
     * @dev Packed for gas optimization
     */
    struct ReceiptData {
        uint256 originalTokenId;      // Original staked token ID
        uint256 collectionId;         // Collection ID in staking system
        address collectionAddress;    // Address of the staked collection
        address originalStaker;       // Who first staked (receives royalties)
        uint32 stakedAt;              // Stake timestamp
        uint8 tier;                   // Token tier (1-5)
        uint8 variant;                // Token variant (0-4)
        bool hasAugment;              // Has equipped augment
        uint8 augmentVariant;         // Augment variant (1-4)
    }

    /**
     * @notice Dynamic stats that change over time
     */
    struct ReceiptStats {
        uint256 accumulatedRewards;   // Total rewards accumulated (scaled by 1e18)
        uint256 transferCount;        // Number of times token was transferred
        uint256 lastRewardUpdate;     // Timestamp of last reward update
    }

    // ============ CONSTANTS ============

    /// @notice Minimum time before unstaking allowed (flash loan protection)
    uint32 public constant MINIMUM_STAKE_DURATION = 1 hours;

    /// @notice Maximum batch size for batch operations
    uint8 public constant MAX_BATCH_SIZE = 20;

    // ============ STORAGE ============
    // OpenZeppelin v5 - no __gap needed, base contracts use ERC-7201 internally

    /// @notice Staking Diamond address - only this can mint/burn receipts
    address public stakingDiamond;

    /// @notice Collection name mapping (collectionId => name)
    mapping(uint256 => string) public collectionNames;

    /// @notice Receipt data for each token
    mapping(uint256 => ReceiptData) public receiptData;

    /// @notice Dynamic stats for each token
    mapping(uint256 => ReceiptStats) public receiptStats;

    /// @notice Royalty percentage in basis points (default 250 = 2.5%)
    uint96 public defaultRoyaltyBps;

    /// @notice Transfer cooldown between transfers (MEV/sandwich protection)
    uint32 public transferCooldown;

    /// @notice Last transfer timestamp per token (for cooldown)
    mapping(uint256 => uint32) public lastTransferTime;

    /// @notice Blocked addresses (OFAC compliance)
    mapping(address => bool) public blockedAddresses;

    /// @notice External metadata renderer contract for tokenURI/SVG generation
    IStkHenoDescriptor public metadataRenderer;

    // ============ EVENTS ============

    event ReceiptMinted(
        uint256 indexed receiptId,
        uint256 indexed originalTokenId,
        uint256 indexed collectionId,
        address staker,
        uint8 tier,
        uint8 variant
    );

    event ReceiptBurned(
        uint256 indexed receiptId,
        uint256 indexed originalTokenId,
        address burner
    );

    event StakingDiamondUpdated(address indexed oldDiamond, address indexed newDiamond);

    event CollectionNameSet(uint256 indexed collectionId, string name);

    event RewardsUpdated(uint256 indexed receiptId, uint256 newAccumulatedRewards);

    event AugmentUpdated(uint256 indexed receiptId, bool hasAugment, uint8 augmentVariant);

    event TransferCooldownUpdated(uint32 oldCooldown, uint32 newCooldown);

    event AddressBlocked(address indexed account);

    event AddressUnblocked(address indexed account);

    event BatchMinted(uint256 indexed count, address indexed caller);

    event BatchBurned(uint256 indexed count, address indexed caller);

    event MetadataRendererUpdated(address indexed oldRenderer, address indexed newRenderer);

    // ============ ERRORS ============

    error OnlyStakingSystem();
    error InvalidReceiptId();
    error FlashLoanProtection();
    error InvalidStakingSystem();
    error InvalidRoyaltyBps();
    error ZeroAddress();
    error TransferCooldownActive(uint256 tokenId, uint32 remainingTime);
    error AddressIsBlocked(address account);
    error BatchSizeExceeded(uint256 provided, uint256 maximum);
    error ArrayLengthMismatch();
    error InvalidMetadataRenderer();

    // ============ MODIFIERS ============

    modifier onlyStakingSystem() {
        if (_msgSender() != stakingDiamond && _msgSender() != owner()) revert OnlyStakingSystem();
        _;
    }

    modifier validReceipt(uint256 receiptId) {
        if (receiptData[receiptId].stakedAt == 0) revert InvalidReceiptId();
        _;
    }

    modifier noFlashLoan(uint256 receiptId) {
        if (block.timestamp < receiptData[receiptId].stakedAt + MINIMUM_STAKE_DURATION) {
            revert FlashLoanProtection();
        }
        _;
    }

    modifier onlyOwnerOrStakingSystem() {
        if (msg.sender != owner() && msg.sender != stakingDiamond) {
            revert OnlyStakingSystem();
        }
        _;
    }

    modifier notBlocked(address account) {
        if (blockedAddresses[account]) revert AddressIsBlocked(account);
        _;
    }

    // ============ INITIALIZER ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @param _stakingDiamond Address of the staking diamond contract
     * @param _metadataRenderer Address of the metadata renderer contract
     * @param _owner Address of the contract owner
     */
    function initialize(
        address _stakingDiamond,
        IStkHenoDescriptor _metadataRenderer,
        address _owner
    ) external initializer {
        if (_stakingDiamond == address(0)) revert ZeroAddress();
        if (address(_metadataRenderer) == address(0)) revert InvalidMetadataRenderer();
        if (_owner == address(0)) revert ZeroAddress();

        __ERC721_init("stkHENO", "stkHENO");
        __ERC721Enumerable_init();
        __ERC2981_init();
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        stakingDiamond = _stakingDiamond;
        metadataRenderer = _metadataRenderer;
        defaultRoyaltyBps = 250; // 2.5%
        transferCooldown = 5 minutes; // Default 5 minutes between transfers
    }

    // ============ STAKING DIAMOND FUNCTIONS ============

    /**
     * @notice Mint a new receipt token
     * @dev Only callable by staking diamond
     * @param to Recipient address
     * @param receiptId Unique receipt ID
     * @param data Receipt data
     * @return receiptId The minted receipt ID
     */
    function mint(
        address to,
        uint256 receiptId,
        ReceiptData calldata data
    ) external onlyStakingSystem whenNotPaused notBlocked(to) nonReentrant returns (uint256) {
        // Store receipt data
        receiptData[receiptId] = data;

        // Initialize stats
        receiptStats[receiptId] = ReceiptStats({
            accumulatedRewards: 0,
            transferCount: 0,
            lastRewardUpdate: block.timestamp
        });

        // Set royalty for original staker
        _setTokenRoyalty(receiptId, data.originalStaker, defaultRoyaltyBps);

        // Mint token
        _safeMint(to, receiptId);

        emit ReceiptMinted(
            receiptId,
            data.originalTokenId,
            data.collectionId,
            to,
            data.tier,
            data.variant
        );

        return receiptId;
    }

    /**
     * @notice Burn a receipt token on unstake
     * @dev Only callable by staking diamond. Enforces flash loan protection
     * @param receiptId Receipt ID to burn
     */
    function burn(uint256 receiptId)
        external
        onlyStakingSystem
        whenNotPaused
        validReceipt(receiptId)
        noFlashLoan(receiptId)
        nonReentrant
    {
        _burnReceipt(receiptId);
    }

    /**
     * @notice Internal burn logic
     */
    function _burnReceipt(uint256 receiptId) internal {
        address tokenOwner = ownerOf(receiptId);
        uint256 originalTokenId = receiptData[receiptId].originalTokenId;

        // Clear storage
        delete receiptData[receiptId];
        delete receiptStats[receiptId];
        delete lastTransferTime[receiptId];

        // Reset royalty
        _resetTokenRoyalty(receiptId);

        // Burn token
        _burn(receiptId);

        emit ReceiptBurned(receiptId, originalTokenId, tokenOwner);
    }

    /**
     * @notice Update accumulated rewards for a receipt
     * @dev Only callable by staking diamond
     * @param receiptId Receipt ID
     * @param newAccumulatedRewards New total accumulated rewards
     */
    function updateRewards(uint256 receiptId, uint256 newAccumulatedRewards)
        external
        onlyStakingSystem
        validReceipt(receiptId)
    {
        receiptStats[receiptId].accumulatedRewards = newAccumulatedRewards;
        receiptStats[receiptId].lastRewardUpdate = block.timestamp;

        emit RewardsUpdated(receiptId, newAccumulatedRewards);
    }

    /**
     * @notice Update augment status for a receipt
     * @dev Only callable by staking diamond
     * @param receiptId Receipt ID
     * @param hasAugment Whether token has augment
     * @param augmentVariant Augment variant (1-4)
     */
    function updateAugment(uint256 receiptId, bool hasAugment, uint8 augmentVariant)
        external
        onlyStakingSystem
        validReceipt(receiptId)
    {
        receiptData[receiptId].hasAugment = hasAugment;
        receiptData[receiptId].augmentVariant = augmentVariant;

        emit AugmentUpdated(receiptId, hasAugment, augmentVariant);
    }

    /**
     * @notice Notify staking diamond of ownership change
     * @dev Called internally on transfer
     * @param receiptId Receipt ID
     * @param newOwner New owner address
     */
    function _notifyOwnershipChange(uint256 receiptId, address newOwner) internal {
        // Increment transfer count
        receiptStats[receiptId].transferCount++;

        // Call staking diamond to update owner
        // Interface call - staking diamond handles the storage update
        (bool success,) = stakingDiamond.call(
            abi.encodeWithSignature(
                "onReceiptTransfer(uint256,address)",
                receiptId,
                newOwner
            )
        );

        // Silently fail if staking diamond doesn't implement callback
        // This allows for future compatibility
        if (!success) {
            // Log but don't revert - transfer should still complete
        }
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Set the staking diamond address
     * @param _stakingSystem New staking diamond address
     */
    function setStakingSystem(address _stakingSystem) external onlyOwner {
        if (_stakingSystem == address(0)) revert InvalidStakingSystem();

        address oldDiamond = stakingDiamond;
        stakingDiamond = _stakingSystem;

        emit StakingDiamondUpdated(oldDiamond, _stakingSystem);
    }

    /**
     * @notice Set the metadata renderer contract
     * @param _metadataRenderer New metadata renderer contract
     */
    function setMetadataRenderer(IStkHenoDescriptor _metadataRenderer) external onlyOwner {
        if (address(_metadataRenderer) == address(0)) revert InvalidMetadataRenderer();

        address oldRenderer = address(metadataRenderer);
        metadataRenderer = _metadataRenderer;

        emit MetadataRendererUpdated(oldRenderer, address(_metadataRenderer));
    }

    /**
     * @notice Set collection name for display
     * @dev Callable by owner or staking diamond (for auto-sync during mint)
     * @param collectionId Collection ID
     * @param name Collection name
     */
    function setCollectionName(uint256 collectionId, string calldata name) external onlyOwnerOrStakingSystem {
        collectionNames[collectionId] = name;
        emit CollectionNameSet(collectionId, name);
    }

    /**
     * @notice Set default royalty percentage
     * @param bps Basis points (100 = 1%)
     */
    function setDefaultRoyaltyBps(uint96 bps) external onlyOwner {
        if (bps > 1000) revert InvalidRoyaltyBps(); // Max 10%
        defaultRoyaltyBps = bps;
    }

    /**
     * @notice Set transfer cooldown period
     * @param cooldown New cooldown in seconds (0 to disable)
     */
    function setTransferCooldown(uint32 cooldown) external onlyOwner {
        uint32 oldCooldown = transferCooldown;
        transferCooldown = cooldown;
        emit TransferCooldownUpdated(oldCooldown, cooldown);
    }

    /**
     * @notice Block an address from receiving/sending tokens (OFAC compliance)
     * @param account Address to block
     */
    function blockAddress(address account) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        blockedAddresses[account] = true;
        emit AddressBlocked(account);
    }

    /**
     * @notice Unblock an address
     * @param account Address to unblock
     */
    function unblockAddress(address account) external onlyOwner {
        blockedAddresses[account] = false;
        emit AddressUnblocked(account);
    }

    /**
     * @notice Check if an address is blocked
     * @param account Address to check
     */
    function isBlocked(address account) external view returns (bool) {
        return blockedAddresses[account];
    }

    /**
     * @notice Pause all token transfers (emergency)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause token transfers
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ BATCH OPERATIONS ============

    /**
     * @notice Batch mint multiple receipt tokens
     * @dev Only callable by staking diamond
     * @param recipients Array of recipient addresses
     * @param receiptIds Array of receipt IDs
     * @param dataArray Array of receipt data
     */
    function batchMint(
        address[] calldata recipients,
        uint256[] calldata receiptIds,
        ReceiptData[] calldata dataArray
    ) external onlyStakingSystem whenNotPaused nonReentrant {
        uint256 length = recipients.length;
        if (length != receiptIds.length || length != dataArray.length) revert ArrayLengthMismatch();
        if (length > MAX_BATCH_SIZE) revert BatchSizeExceeded(length, MAX_BATCH_SIZE);

        for (uint256 i = 0; i < length; i++) {
            if (blockedAddresses[recipients[i]]) continue; // Skip blocked addresses

            receiptData[receiptIds[i]] = dataArray[i];
            receiptStats[receiptIds[i]] = ReceiptStats({
                accumulatedRewards: 0,
                transferCount: 0,
                lastRewardUpdate: block.timestamp
            });

            _setTokenRoyalty(receiptIds[i], dataArray[i].originalStaker, defaultRoyaltyBps);
            _safeMint(recipients[i], receiptIds[i]);

            emit ReceiptMinted(
                receiptIds[i],
                dataArray[i].originalTokenId,
                dataArray[i].collectionId,
                recipients[i],
                dataArray[i].tier,
                dataArray[i].variant
            );
        }

        emit BatchMinted(length, msg.sender);
    }

    /**
     * @notice Batch burn multiple receipt tokens
     * @dev Only callable by staking diamond
     * @param receiptIds Array of receipt IDs to burn
     */
    function batchBurn(uint256[] calldata receiptIds)
        external
        onlyStakingSystem
        whenNotPaused
        nonReentrant
    {
        uint256 length = receiptIds.length;
        if (length > MAX_BATCH_SIZE) revert BatchSizeExceeded(length, MAX_BATCH_SIZE);

        for (uint256 i = 0; i < length; i++) {
            uint256 receiptId = receiptIds[i];

            // Validate receipt exists and flash loan protection passed
            if (receiptData[receiptId].stakedAt == 0) continue;
            if (block.timestamp < receiptData[receiptId].stakedAt + MINIMUM_STAKE_DURATION) continue;

            _burnReceipt(receiptId);
        }

        emit BatchBurned(length, msg.sender);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get complete receipt information
     * @param receiptId Receipt ID
     */
    function getReceiptInfo(uint256 receiptId)
        external
        view
        validReceipt(receiptId)
        returns (
            ReceiptData memory data,
            ReceiptStats memory stats,
            address currentOwner,
            uint256 stakingDays
        )
    {
        data = receiptData[receiptId];
        stats = receiptStats[receiptId];
        currentOwner = ownerOf(receiptId);
        stakingDays = (block.timestamp - data.stakedAt) / 1 days;
    }

    /**
     * @notice Check if receipt can be unstaked (flash loan protection passed)
     * @param receiptId Receipt ID
     */
    function canUnstake(uint256 receiptId) external view returns (bool) {
        if (receiptData[receiptId].stakedAt == 0) return false;
        return block.timestamp >= receiptData[receiptId].stakedAt + MINIMUM_STAKE_DURATION;
    }

    /**
     * @notice Get staking days for a receipt
     * @param receiptId Receipt ID
     */
    function getStakingDays(uint256 receiptId) public view validReceipt(receiptId) returns (uint256) {
        return (block.timestamp - receiptData[receiptId].stakedAt) / 1 days;
    }

    /**
     * @notice Get pending rewards estimate (view only, actual from staking diamond)
     * @dev This is an estimate - actual pending rewards come from staking diamond
     * @param receiptId Receipt ID
     */
    function getAccumulatedRewards(uint256 receiptId)
        external
        view
        validReceipt(receiptId)
        returns (uint256)
    {
        return receiptStats[receiptId].accumulatedRewards;
    }

    /**
     * @notice Get collection name
     * @param collectionId Collection ID
     */
    function getCollectionName(uint256 collectionId) public view returns (string memory) {
        string memory name = collectionNames[collectionId];
        if (bytes(name).length == 0) {
            return "Henomorphs";
        }
        return name;
    }

    // ============ ERC721 OVERRIDES ============

    /**
     * @notice Returns token URI with on-chain SVG
     * @param receiptId Receipt token ID
     */
    function tokenURI(uint256 receiptId)
        public
        view
        override
        validReceipt(receiptId)
        returns (string memory)
    {
        ReceiptData memory data = receiptData[receiptId];
        ReceiptStats memory stats = receiptStats[receiptId];

        // Fetch pending rewards from staking diamond
        uint256 pendingRewards = _fetchPendingRewards(data.collectionId, data.originalTokenId);

        IStkHenoDescriptor.ReceiptMetadata memory metadata = IStkHenoDescriptor.ReceiptMetadata({
            receiptId: receiptId,
            originalTokenId: data.originalTokenId,
            collectionId: data.collectionId,
            collectionAddress: data.collectionAddress,
            collectionName: getCollectionName(data.collectionId),
            originalStaker: data.originalStaker,
            currentOwner: ownerOf(receiptId),
            tier: data.tier,
            variant: data.variant,
            stakedAt: data.stakedAt,
            stakingDays: getStakingDays(receiptId),
            accumulatedRewards: stats.accumulatedRewards,
            pendingRewards: pendingRewards,
            transferCount: stats.transferCount,
            hasAugment: data.hasAugment,
            augmentVariant: data.augmentVariant
        });

        return metadataRenderer.tokenURI(metadata);
    }

    /**
     * @notice Fetch pending rewards from staking diamond
     * @dev Safe call - returns 0 if staking diamond call fails
     * @param collectionId Collection ID
     * @param tokenId Original token ID
     * @return pendingRewards Pending rewards amount (0 if call fails)
     */
    function _fetchPendingRewards(uint256 collectionId, uint256 tokenId) internal view returns (uint256) {
        try IStakingEarningsFacet(stakingDiamond).getPendingReward(collectionId, tokenId) returns (uint256 amount) {
            return amount;
        } catch {
            return 0;
        }
    }

    /**
     * @notice Returns collection-level metadata
     */
    function contractURI() external view returns (string memory) {
        return metadataRenderer.contractURI();
    }

    /**
     * @notice Hook called before token transfer
     * @dev Enforces pausable, blocklist, cooldown and notifies staking diamond
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override(ERC721Upgradeable, ERC721EnumerableUpgradeable) returns (address) {
        address from = _ownerOf(tokenId);

        // Skip checks on mint (from == 0) and burn (to == 0)
        if (from != address(0) && to != address(0)) {
            // Pause check for transfers
            if (paused()) revert EnforcedPause();

            // Blocklist check
            if (blockedAddresses[from]) revert AddressIsBlocked(from);
            if (blockedAddresses[to]) revert AddressIsBlocked(to);

            // Transfer cooldown check
            if (transferCooldown > 0) {
                uint32 lastTransfer = lastTransferTime[tokenId];
                if (lastTransfer > 0 && block.timestamp < lastTransfer + transferCooldown) {
                    revert TransferCooldownActive(tokenId, uint32(lastTransfer + transferCooldown - block.timestamp));
                }
            }
        }

        // Call parent implementation
        address previousOwner = super._update(to, tokenId, auth);

        // Post-transfer logic (skip on mint/burn)
        if (from != address(0) && to != address(0)) {
            // Update last transfer time for cooldown
            lastTransferTime[tokenId] = uint32(block.timestamp);

            // Notify staking diamond of ownership change
            _notifyOwnershipChange(tokenId, to);
        }

        return previousOwner;
    }

    /**
     * @notice Override for ERC721Enumerable
     */
    function _increaseBalance(
        address account,
        uint128 value
    ) internal override(ERC721Upgradeable, ERC721EnumerableUpgradeable) {
        super._increaseBalance(account, value);
    }

    /**
     * @notice Check interface support
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable, ERC2981Upgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // ============ UUPS UPGRADE ============

    /**
     * @notice Authorize contract upgrade
     * @dev Only owner can upgrade
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @notice Get implementation version
     */
    function version() external pure returns (string memory) {
        return "1.2.0";
    }

    /**
     * @notice Check if a token can be transferred (cooldown check)
     * @param tokenId Token ID to check
     * @return canTransferToken True if transfer is allowed
     * @return remainingCooldown Seconds until cooldown expires (0 if can transfer)
     */
    function canTransfer(uint256 tokenId) external view returns (bool canTransferToken, uint32 remainingCooldown) {
        if (transferCooldown == 0) {
            return (true, 0);
        }

        uint32 lastTransfer = lastTransferTime[tokenId];
        if (lastTransfer == 0) {
            return (true, 0);
        }

        uint32 cooldownEnd = lastTransfer + transferCooldown;
        if (block.timestamp >= cooldownEnd) {
            return (true, 0);
        }

        return (false, uint32(cooldownEnd - block.timestamp));
    }
}
