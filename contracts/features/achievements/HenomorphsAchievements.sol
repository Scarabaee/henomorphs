// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC1155Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {ERC1155SupplyUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155SupplyUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IAchievementMetadataDescriptor} from "./IAchievementMetadataDescriptor.sol";

/**
 * @title IRewardRedeemable
 * @notice Interface for external reward systems to mint achievement tokens
 * @dev Implements the standard reward collection interface for Colony Wars integration
 */
interface IRewardRedeemable {
    function mintReward(
        uint256 collectionId,
        uint256 tierId,
        address to,
        uint256 amount
    ) external returns (uint256 tokenId);

    function batchMintReward(
        uint256 collectionId,
        uint256[] calldata tierIds,
        address to,
        uint256[] calldata amounts
    ) external returns (uint256[] memory tokenIds);

    function canMintReward(
        uint256 collectionId,
        uint256 tierId,
        uint256 amount
    ) external view returns (bool);

    function getRemainingSupply(
        uint256 collectionId,
        uint256 tierId
    ) external view returns (uint256 remaining);
}

/**
 * @title HenomorphsAchievements
 * @notice ERC-1155 Achievement NFT Collection with UUPS upgradeability
 * @dev OpenZeppelin v5+ contracts-upgradeable
 *      Uses external metadata descriptor for SVG and JSON generation
 *      Implements IRewardRedeemable for Colony Wars reward system integration
 *
 * Storage Pattern: UUPS Proxy with storage gap for future upgrades
 * CRITICAL: Follow APPEND-ONLY principle for storage modifications
 *
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract HenomorphsAchievements is
    Initializable,
    ERC1155Upgradeable,
    ERC1155SupplyUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using Strings for uint256;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS - Roles
    // ═══════════════════════════════════════════════════════════════════════════

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant REGISTRY_ADMIN_ROLE = keccak256("REGISTRY_ADMIN_ROLE");

    // ═══════════════════════════════════════════════════════════════════════════
    // ENUMS
    // ═══════════════════════════════════════════════════════════════════════════

    enum AchievementCategory {
        None,        // 0 - Invalid
        Combat,      // 1
        Territory,   // 2
        Economic,    // 3
        Collection,  // 4
        Social,      // 5
        Special      // 6
    }

    enum AchievementTier {
        None,     // 0 - Not earned
        Bronze,   // 1
        Silver,   // 2
        Gold,     // 3
        Platinum  // 4
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    struct AchievementDefinition {
        uint16 id;
        string name;
        string description;
        string imageUri;           // IPFS or external image URI for this achievement
        AchievementCategory category;
        AchievementTier maxTier;
        uint256 progressMax;       // Max progress for progressive achievements (0 = not progressive)
        bool soulbound;
        bool active;
    }

    struct UserAchievementData {
        uint32 earnedAt;
        AchievementTier currentTier;
        uint256 progress;
    }

    /// @notice Collection configuration
    struct CollectionConfig {
        string name;
        string symbol;
        string description;
        string imageUri;             // Collection logo/image URI (full path)
        string baseUri;              // Base URI for individual badge images
        string externalLink;
        address stakingSystems;      // Staking diamond - for staking-related achievements
        address chargepodSystems;    // Chargepod diamond - for Colony Wars, Territory Wars achievements
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE - APPEND-ONLY! Never insert fields in the middle
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Achievement definitions registry
    mapping(uint256 => AchievementDefinition) private _achievements;

    /// @notice Soulbound status per token ID
    mapping(uint256 => bool) private _isSoulbound;

    /// @notice User achievement data (user => achievementId => data)
    mapping(address => mapping(uint256 => UserAchievementData)) private _userAchievements;

    /// @notice Collection configuration
    CollectionConfig public config;

    /// @notice All registered achievement IDs
    uint256[] private _allAchievementIds;

    /// @notice Achievement count per category
    mapping(AchievementCategory => uint256) private _categoryCount;

    /// @notice Total achievements minted
    uint256 public totalMinted;

    /// @notice Token owner tracking for uri() function (tokenId => owner)
    mapping(uint256 => address) private _tokenOwners;

    /// @notice External metadata descriptor contract
    IAchievementMetadataDescriptor public metadataDescriptor;

    /// @notice Max supply per achievement (achievementId => maxSupply, 0 = unlimited)
    mapping(uint256 => uint256) private _achievementMaxSupply;

    /// @notice Current minted count per achievement (achievementId => mintedCount)
    mapping(uint256 => uint256) private _achievementMintedCount;

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event AchievementUnlocked(
        address indexed user,
        uint256 indexed tokenId,
        uint256 indexed achievementId,
        AchievementTier tier
    );

    event AchievementUpgraded(
        address indexed user,
        uint256 indexed tokenId,
        AchievementTier fromTier,
        AchievementTier toTier
    );

    event AchievementRegistered(
        uint256 indexed achievementId,
        string name,
        AchievementCategory category,
        AchievementTier maxTier
    );

    event AchievementDeactivated(uint256 indexed achievementId);
    event ConfigUpdated();
    event MetadataDescriptorUpdated(address indexed newDescriptor);
    event RewardMinted(
        address indexed to,
        uint256 indexed achievementId,
        uint256 indexed tierId,
        uint256 tokenId,
        uint256 amount
    );
    event AchievementSupplyConfigured(uint256 indexed achievementId, uint256 maxSupply);

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error SoulboundTokenCannotBeTransferred(uint256 tokenId);
    error AchievementNotFound(uint256 achievementId);
    error AchievementAlreadyEarned(address user, uint256 achievementId, AchievementTier tier);
    error InvalidTierProgression(AchievementTier current, AchievementTier requested);
    error AchievementNotActive(uint256 achievementId);
    error MaxSupplyExceeded(uint256 achievementId, uint256 requested, uint256 remaining);
    error InvalidAmount();
    error ArrayLengthMismatch();
    error InvalidAchievementId(uint256 achievementId);
    error AchievementAlreadyRegistered(uint256 achievementId);
    error InvalidCategory();
    error InvalidTier();
    error ZeroAddress();
    error InvalidMetadataDescriptor();

    // ═══════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════

    modifier validAchievement(uint256 achievementId) {
        if (!_achievements[achievementId].active) {
            revert AchievementNotActive(achievementId);
        }
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZER (replaces constructor for UUPS)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract (called once via proxy)
     * @param admin Address to receive admin roles
     * @param _config Initial collection configuration
     * @param _metadataDescriptor External metadata descriptor address
     */
    function initialize(
        address admin,
        CollectionConfig calldata _config,
        address _metadataDescriptor
    ) public initializer {
        if (admin == address(0)) revert ZeroAddress();
        if (_metadataDescriptor == address(0)) revert InvalidMetadataDescriptor();

        __ERC1155_init("");
        __ERC1155Supply_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(REGISTRY_ADMIN_ROLE, admin);

        config = _config;
        metadataDescriptor = IAchievementMetadataDescriptor(_metadataDescriptor);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UUPS UPGRADE AUTHORIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}

    // ═══════════════════════════════════════════════════════════════════════════
    // SOULBOUND OVERRIDE (OZ v5+ pattern)
    // ═══════════════════════════════════════════════════════════════════════════

    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal virtual override(ERC1155Upgradeable, ERC1155SupplyUpgradeable) {
        // Check soulbound restrictions (skip mint and burn)
        if (from != address(0) && to != address(0)) {
            for (uint256 i = 0; i < ids.length; i++) {
                if (_isSoulbound[ids[i]]) {
                    revert SoulboundTokenCannotBeTransferred(ids[i]);
                }
            }
        }

        super._update(from, to, ids, values);

        // Update _tokenOwners after successful transfer
        for (uint256 i = 0; i < ids.length; i++) {
            if (to == address(0)) {
                delete _tokenOwners[ids[i]];
            } else {
                _tokenOwners[ids[i]] = to;
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MINTING
    // ═══════════════════════════════════════════════════════════════════════════

    function mintAchievement(
        address to,
        uint256 achievementId,
        uint8 tier
    ) external onlyRole(MINTER_ROLE) whenNotPaused nonReentrant validAchievement(achievementId) returns (uint256 tokenId) {
        if (to == address(0)) revert ZeroAddress();
        if (tier == 0 || tier > 4) revert InvalidTier();

        AchievementTier tierEnum = AchievementTier(tier);
        AchievementDefinition storage achievement = _achievements[achievementId];

        if (tier > uint8(achievement.maxTier)) {
            revert InvalidTierProgression(AchievementTier.None, tierEnum);
        }

        tokenId = _encodeTokenId(achievementId, tierEnum);

        if (balanceOf(to, tokenId) > 0) {
            revert AchievementAlreadyEarned(to, achievementId, tierEnum);
        }

        _userAchievements[to][achievementId] = UserAchievementData({
            earnedAt: uint32(block.timestamp),
            currentTier: tierEnum,
            progress: 0
        });

        _mint(to, tokenId, 1, "");

        totalMinted++;

        emit AchievementUnlocked(to, tokenId, achievementId, tierEnum);
    }

    function mintAchievementBatch(
        address to,
        uint256[] calldata achievementIds,
        uint8[] calldata tiers
    ) external onlyRole(MINTER_ROLE) whenNotPaused nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (achievementIds.length != tiers.length) revert("Length mismatch");

        uint256[] memory tokenIds = new uint256[](achievementIds.length);
        uint256[] memory amounts = new uint256[](achievementIds.length);

        for (uint256 i = 0; i < achievementIds.length; i++) {
            if (!_achievements[achievementIds[i]].active) {
                revert AchievementNotActive(achievementIds[i]);
            }
            if (tiers[i] == 0 || tiers[i] > 4) {
                revert InvalidTier();
            }

            AchievementTier tierEnum = AchievementTier(tiers[i]);
            tokenIds[i] = _encodeTokenId(achievementIds[i], tierEnum);
            amounts[i] = 1;

            _userAchievements[to][achievementIds[i]] = UserAchievementData({
                earnedAt: uint32(block.timestamp),
                currentTier: tierEnum,
                progress: 0
            });
        }

        _mintBatch(to, tokenIds, amounts, "");
        totalMinted += achievementIds.length;
    }

    function upgradeAchievementTier(
        address user,
        uint256 achievementId,
        uint8 newTier
    ) external onlyRole(MINTER_ROLE) whenNotPaused nonReentrant validAchievement(achievementId) {
        if (newTier == 0 || newTier > 4) revert InvalidTier();

        AchievementTier newTierEnum = AchievementTier(newTier);
        UserAchievementData storage userData = _userAchievements[user][achievementId];
        AchievementDefinition storage achievement = _achievements[achievementId];

        if (newTier <= uint8(userData.currentTier)) {
            revert InvalidTierProgression(userData.currentTier, newTierEnum);
        }
        if (newTier > uint8(achievement.maxTier)) {
            revert InvalidTierProgression(userData.currentTier, newTierEnum);
        }

        uint256 oldTokenId = _encodeTokenId(achievementId, userData.currentTier);
        if (balanceOf(user, oldTokenId) > 0) {
            _burn(user, oldTokenId, 1);
        }

        uint256 newTokenId = _encodeTokenId(achievementId, newTierEnum);
        _mint(user, newTokenId, 1, "");

        AchievementTier oldTier = userData.currentTier;
        userData.currentTier = newTierEnum;
        userData.earnedAt = uint32(block.timestamp);

        emit AchievementUpgraded(user, newTokenId, oldTier, newTierEnum);
    }

    function updateProgress(
        address user,
        uint256 achievementId,
        uint256 newProgress
    ) external onlyRole(MINTER_ROLE) validAchievement(achievementId) {
        AchievementDefinition storage achievement = _achievements[achievementId];

        if (achievement.progressMax == 0) {
            revert("Not progressive");
        }

        UserAchievementData storage userData = _userAchievements[user][achievementId];

        if (newProgress > achievement.progressMax) {
            newProgress = achievement.progressMax;
        }

        userData.progress = newProgress;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // IRewardRedeemable IMPLEMENTATION (Colony Wars Integration)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Mint reward achievement token (IRewardRedeemable interface)
     * @dev Maps collectionId to achievementId, tierId to AchievementTier
     * @param collectionId Achievement ID to mint
     * @param tierId Tier level (1=Bronze, 2=Silver, 3=Gold, 4=Platinum)
     * @param to Recipient address
     * @param amount Number of tokens to mint (typically 1 for achievements)
     * @return tokenId The encoded token ID
     */
    function mintReward(
        uint256 collectionId,
        uint256 tierId,
        address to,
        uint256 amount
    ) external onlyRole(MINTER_ROLE) whenNotPaused nonReentrant returns (uint256 tokenId) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (tierId == 0 || tierId > 4) revert InvalidTier();

        uint256 achievementId = collectionId;
        AchievementDefinition storage achievement = _achievements[achievementId];

        if (!achievement.active) revert AchievementNotActive(achievementId);
        if (tierId > uint8(achievement.maxTier)) {
            revert InvalidTierProgression(AchievementTier.None, AchievementTier(tierId));
        }

        // Check supply limits
        uint256 maxSupply = _achievementMaxSupply[achievementId];
        if (maxSupply > 0) {
            uint256 currentMinted = _achievementMintedCount[achievementId];
            if (currentMinted + amount > maxSupply) {
                revert MaxSupplyExceeded(achievementId, amount, maxSupply - currentMinted);
            }
        }

        AchievementTier tierEnum = AchievementTier(tierId);
        tokenId = _encodeTokenId(achievementId, tierEnum);

        // Update user achievement data
        _userAchievements[to][achievementId] = UserAchievementData({
            earnedAt: uint32(block.timestamp),
            currentTier: tierEnum,
            progress: 0
        });

        // Mint tokens
        _mint(to, tokenId, amount, "");

        // Update counters
        _achievementMintedCount[achievementId] += amount;
        totalMinted += amount;

        emit RewardMinted(to, achievementId, tierId, tokenId, amount);
        emit AchievementUnlocked(to, tokenId, achievementId, tierEnum);

        return tokenId;
    }

    /**
     * @notice Batch mint reward achievement tokens (IRewardRedeemable interface)
     * @param collectionId Achievement ID to mint
     * @param tierIds Array of tier levels
     * @param to Recipient address
     * @param amounts Array of amounts per tier
     * @return tokenIds Array of encoded token IDs
     */
    function batchMintReward(
        uint256 collectionId,
        uint256[] calldata tierIds,
        address to,
        uint256[] calldata amounts
    ) external onlyRole(MINTER_ROLE) whenNotPaused nonReentrant returns (uint256[] memory tokenIds) {
        if (to == address(0)) revert ZeroAddress();
        if (tierIds.length != amounts.length) revert ArrayLengthMismatch();
        if (tierIds.length == 0) revert InvalidAmount();

        uint256 achievementId = collectionId;
        AchievementDefinition storage achievement = _achievements[achievementId];

        if (!achievement.active) revert AchievementNotActive(achievementId);

        // Calculate total amount for supply check
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalAmount += amounts[i];
        }

        // Check supply limits
        uint256 maxSupply = _achievementMaxSupply[achievementId];
        if (maxSupply > 0) {
            uint256 currentMinted = _achievementMintedCount[achievementId];
            if (currentMinted + totalAmount > maxSupply) {
                revert MaxSupplyExceeded(achievementId, totalAmount, maxSupply - currentMinted);
            }
        }

        tokenIds = new uint256[](tierIds.length);
        uint256[] memory mintAmounts = new uint256[](tierIds.length);

        for (uint256 i = 0; i < tierIds.length; i++) {
            if (tierIds[i] == 0 || tierIds[i] > 4) revert InvalidTier();
            if (tierIds[i] > uint8(achievement.maxTier)) {
                revert InvalidTierProgression(AchievementTier.None, AchievementTier(tierIds[i]));
            }

            AchievementTier tierEnum = AchievementTier(tierIds[i]);
            tokenIds[i] = _encodeTokenId(achievementId, tierEnum);
            mintAmounts[i] = amounts[i];

            emit RewardMinted(to, achievementId, tierIds[i], tokenIds[i], amounts[i]);
        }

        // Batch mint
        _mintBatch(to, tokenIds, mintAmounts, "");

        // Update counters
        _achievementMintedCount[achievementId] += totalAmount;
        totalMinted += totalAmount;

        return tokenIds;
    }

    /**
     * @notice Check if reward can be minted (IRewardRedeemable interface)
     * @param collectionId Achievement ID
     * @param tierId Tier level
     * @param amount Amount to check
     * @return True if minting is possible
     */
    function canMintReward(
        uint256 collectionId,
        uint256 tierId,
        uint256 amount
    ) external view returns (bool) {
        uint256 achievementId = collectionId;
        AchievementDefinition storage achievement = _achievements[achievementId];

        // Check achievement is active
        if (!achievement.active) return false;

        // Check tier is valid
        if (tierId == 0 || tierId > 4) return false;
        if (tierId > uint8(achievement.maxTier)) return false;

        // Check supply
        uint256 maxSupply = _achievementMaxSupply[achievementId];
        if (maxSupply > 0) {
            uint256 currentMinted = _achievementMintedCount[achievementId];
            if (currentMinted + amount > maxSupply) return false;
        }

        return true;
    }

    /**
     * @notice Get remaining supply for achievement (IRewardRedeemable interface)
     * @param collectionId Achievement ID
     * @param tierId Tier level (unused, supply is per achievement not per tier)
     * @return remaining Remaining mintable tokens (type(uint256).max if unlimited)
     */
    function getRemainingSupply(
        uint256 collectionId,
        uint256 tierId
    ) external view returns (uint256 remaining) {
        // Silence unused variable warning
        tierId;

        uint256 achievementId = collectionId;
        uint256 maxSupply = _achievementMaxSupply[achievementId];

        if (maxSupply == 0) {
            return type(uint256).max; // Unlimited
        }

        uint256 currentMinted = _achievementMintedCount[achievementId];
        if (currentMinted >= maxSupply) return 0;

        return maxSupply - currentMinted;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOKEN ID ENCODING/DECODING
    // ═══════════════════════════════════════════════════════════════════════════

    function _encodeTokenId(uint256 achievementId, AchievementTier tier)
        internal
        pure
        returns (uint256)
    {
        return (achievementId << 8) | uint256(tier);
    }

    function decodeTokenId(uint256 tokenId)
        public
        pure
        returns (uint256 achievementId, AchievementTier tier)
    {
        achievementId = tokenId >> 8;
        tier = AchievementTier(tokenId & 0xFF);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // METADATA (delegated to external descriptor)
    // ═══════════════════════════════════════════════════════════════════════════

    function uri(uint256 tokenId) public view override returns (string memory) {
        (uint256 achievementId, AchievementTier tier) = decodeTokenId(tokenId);
        AchievementDefinition storage achievement = _achievements[achievementId];

        if (!achievement.active && achievement.id == 0) {
            revert AchievementNotFound(achievementId);
        }

        if (address(metadataDescriptor) == address(0)) {
            revert InvalidMetadataDescriptor();
        }

        // Simple metadata - direct IPFS image, no SVG overlay
        // Use uriForUser() for personalized SVG with overlay
        return metadataDescriptor.tokenURISimple(
            IAchievementMetadataDescriptor.AchievementData({
                achievementId: achievement.id,
                name: achievement.name,
                description: achievement.description,
                imageUri: achievement.imageUri,
                category: uint8(achievement.category),
                tier: uint8(tier),
                maxTier: uint8(achievement.maxTier),
                soulbound: achievement.soulbound,
                progressMax: achievement.progressMax,
                earnedAt: 0,
                progress: 0
            }),
            IAchievementMetadataDescriptor.CollectionConfig({
                name: config.name,
                symbol: config.symbol,
                description: config.description,
                imageUri: config.imageUri,
                baseUri: config.baseUri,
                externalLink: config.externalLink
            })
        );
    }

    function uriForUser(uint256 tokenId, address user) external view returns (string memory) {
        (uint256 achievementId, AchievementTier tier) = decodeTokenId(tokenId);
        AchievementDefinition storage achievement = _achievements[achievementId];

        if (!achievement.active && achievement.id == 0) {
            revert AchievementNotFound(achievementId);
        }

        if (address(metadataDescriptor) == address(0)) {
            revert InvalidMetadataDescriptor();
        }

        UserAchievementData memory userData = _userAchievements[user][achievementId];

        return metadataDescriptor.tokenURI(
            tokenId,
            IAchievementMetadataDescriptor.AchievementData({
                achievementId: achievement.id,
                name: achievement.name,
                description: achievement.description,
                imageUri: achievement.imageUri,
                category: uint8(achievement.category),
                tier: uint8(tier),
                maxTier: uint8(achievement.maxTier),
                soulbound: achievement.soulbound,
                progressMax: achievement.progressMax,
                earnedAt: userData.earnedAt,
                progress: userData.progress
            }),
            IAchievementMetadataDescriptor.CollectionConfig({
                name: config.name,
                symbol: config.symbol,
                description: config.description,
                imageUri: config.imageUri,
                baseUri: config.baseUri,
                externalLink: config.externalLink
            })
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // REGISTRY MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════════

    function registerAchievement(
        uint256 id,
        string calldata _name,
        string calldata description,
        string calldata imageUri,
        AchievementCategory category,
        AchievementTier maxTier,
        uint256 progressMax,
        bool soulbound
    ) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (id == 0) revert InvalidAchievementId(id);
        if (category == AchievementCategory.None) revert InvalidCategory();
        if (maxTier == AchievementTier.None) revert InvalidTier();
        if (_achievements[id].active) revert AchievementAlreadyRegistered(id);

        _achievements[id] = AchievementDefinition({
            id: uint16(id),
            name: _name,
            description: description,
            imageUri: imageUri,
            category: category,
            maxTier: maxTier,
            progressMax: progressMax,
            soulbound: soulbound,
            active: true
        });

        _allAchievementIds.push(id);
        _categoryCount[category]++;

        if (soulbound) {
            _setSoulboundForAllTiers(id, maxTier, true);
        }

        emit AchievementRegistered(id, _name, category, maxTier);
    }

    function _setSoulboundForAllTiers(uint256 achievementId, AchievementTier maxTier, bool soulbound) internal {
        for (uint8 t = 1; t <= uint8(maxTier); t++) {
            _isSoulbound[_encodeTokenId(achievementId, AchievementTier(t))] = soulbound;
        }
    }

    function deactivateAchievement(uint256 achievementId)
        external
        onlyRole(REGISTRY_ADMIN_ROLE)
    {
        if (!_achievements[achievementId].active) {
            revert AchievementNotFound(achievementId);
        }

        _achievements[achievementId].active = false;
        emit AchievementDeactivated(achievementId);
    }

    function setAchievementSoulbound(uint256 achievementId, bool soulbound)
        external
        onlyRole(REGISTRY_ADMIN_ROLE)
        validAchievement(achievementId)
    {
        AchievementDefinition storage achievement = _achievements[achievementId];
        achievement.soulbound = soulbound;
        _setSoulboundForAllTiers(achievementId, achievement.maxTier, soulbound);
    }

    /**
     * @notice Update achievement metadata (name, description, imageUri)
     */
    function updateAchievement(
        uint256 achievementId,
        string calldata _name,
        string calldata description,
        string calldata imageUri
    ) external onlyRole(REGISTRY_ADMIN_ROLE) validAchievement(achievementId) {
        AchievementDefinition storage achievement = _achievements[achievementId];
        achievement.name = _name;
        achievement.description = description;
        achievement.imageUri = imageUri;
    }

    /**
     * @notice Reactivate a deactivated achievement
     */
    function reactivateAchievement(uint256 achievementId) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (_achievements[achievementId].id == 0) revert AchievementNotFound(achievementId);
        _achievements[achievementId].active = true;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function getAchievement(uint256 achievementId)
        external
        view
        returns (AchievementDefinition memory)
    {
        return _achievements[achievementId];
    }

    function getUserAchievement(address user, uint256 achievementId)
        external
        view
        returns (UserAchievementData memory)
    {
        return _userAchievements[user][achievementId];
    }

    function hasAchievement(address user, uint256 achievementId, AchievementTier tier)
        external
        view
        returns (bool)
    {
        uint256 tokenId = _encodeTokenId(achievementId, tier);
        return balanceOf(user, tokenId) > 0;
    }

    function getAllAchievementIds() external view returns (uint256[] memory) {
        return _allAchievementIds;
    }

    function getAchievementCountByCategory(AchievementCategory category)
        external
        view
        returns (uint256)
    {
        return _categoryCount[category];
    }

    function isSoulbound(uint256 tokenId) external view returns (bool) {
        return _isSoulbound[tokenId];
    }

    /**
     * @notice Get supply information for an achievement
     * @param achievementId Achievement ID
     * @return maxSupply Maximum supply (0 = unlimited)
     * @return mintedCount Current minted count
     * @return remaining Remaining supply (type(uint256).max if unlimited)
     */
    function getAchievementSupplyInfo(uint256 achievementId)
        external
        view
        returns (uint256 maxSupply, uint256 mintedCount, uint256 remaining)
    {
        maxSupply = _achievementMaxSupply[achievementId];
        mintedCount = _achievementMintedCount[achievementId];

        if (maxSupply == 0) {
            remaining = type(uint256).max;
        } else if (mintedCount >= maxSupply) {
            remaining = 0;
        } else {
            remaining = maxSupply - mintedCount;
        }
    }

    function name() external view returns (string memory) {
        return config.name;
    }

    function symbol() external view returns (string memory) {
        return config.symbol;
    }

    function contractURI() external view returns (string memory) {
        if (address(metadataDescriptor) == address(0)) {
            revert InvalidMetadataDescriptor();
        }

        return metadataDescriptor.contractURI(
            IAchievementMetadataDescriptor.CollectionConfig({
                name: config.name,
                symbol: config.symbol,
                description: config.description,
                imageUri: config.imageUri,
                baseUri: config.baseUri,
                externalLink: config.externalLink
            })
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function setConfig(CollectionConfig calldata _config) external onlyRole(DEFAULT_ADMIN_ROLE) {
        config = _config;
        emit ConfigUpdated();
    }

    function setMetadataDescriptor(address newDescriptor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newDescriptor == address(0)) revert InvalidMetadataDescriptor();
        metadataDescriptor = IAchievementMetadataDescriptor(newDescriptor);
        emit MetadataDescriptorUpdated(newDescriptor);
    }

    /**
     * @notice Set max supply for an achievement (for reward system limits)
     * @dev Set to 0 for unlimited supply
     * @param achievementId Achievement ID
     * @param maxSupply Maximum supply (0 = unlimited)
     */
    function setAchievementMaxSupply(uint256 achievementId, uint256 maxSupply)
        external
        onlyRole(REGISTRY_ADMIN_ROLE)
    {
        if (_achievements[achievementId].id == 0) revert AchievementNotFound(achievementId);

        _achievementMaxSupply[achievementId] = maxSupply;
        emit AchievementSupplyConfigured(achievementId, maxSupply);
    }

    /**
     * @notice Batch set max supply for multiple achievements
     * @param achievementIds Array of achievement IDs
     * @param maxSupplies Array of max supplies
     */
    function batchSetAchievementMaxSupply(
        uint256[] calldata achievementIds,
        uint256[] calldata maxSupplies
    ) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (achievementIds.length != maxSupplies.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < achievementIds.length; i++) {
            if (_achievements[achievementIds[i]].id == 0) revert AchievementNotFound(achievementIds[i]);

            _achievementMaxSupply[achievementIds[i]] = maxSupplies[i];
            emit AchievementSupplyConfigured(achievementIds[i], maxSupplies[i]);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // REQUIRED OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
