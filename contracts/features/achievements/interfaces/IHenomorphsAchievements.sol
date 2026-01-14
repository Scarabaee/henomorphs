// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title IHenomorphsAchievements
 * @notice Interface for HenomorphsAchievements ERC-1155 NFT Collection
 * @dev Used for integration with Diamond facets (AchievementRewardFacet)
 * @author rutilicus.eth (ArchXS)
 */
interface IHenomorphsAchievements {
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
        AchievementCategory category;
        AchievementTier maxTier;
        bool soulbound;
        bool progressive;
        bool active;
    }

    struct UserAchievementData {
        uint32 earnedAt;
        AchievementTier currentTier;
        uint256 progress;
    }

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

    // ═══════════════════════════════════════════════════════════════════════════
    // MINTING FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Mint achievement to user
     * @param to Recipient address
     * @param achievementId Achievement ID to mint
     * @param tier Tier level
     */
    function mintAchievement(
        address to,
        uint256 achievementId,
        AchievementTier tier
    ) external;

    /**
     * @notice Batch mint achievements to user
     * @param to Recipient address
     * @param achievementIds Array of achievement IDs
     * @param tiers Array of tier levels
     */
    function mintAchievementBatch(
        address to,
        uint256[] calldata achievementIds,
        AchievementTier[] calldata tiers
    ) external;

    /**
     * @notice Upgrade achievement tier for user
     * @param user User address
     * @param achievementId Achievement ID
     * @param newTier New tier level
     */
    function upgradeAchievementTier(
        address user,
        uint256 achievementId,
        AchievementTier newTier
    ) external;

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get achievement definition
     * @param achievementId Achievement ID
     * @return Achievement definition struct
     */
    function getAchievement(uint256 achievementId)
        external
        view
        returns (AchievementDefinition memory);

    /**
     * @notice Get user's achievement data
     * @param user User address
     * @param achievementId Achievement ID
     * @return User achievement data struct
     */
    function getUserAchievement(address user, uint256 achievementId)
        external
        view
        returns (UserAchievementData memory);

    /**
     * @notice Check if user has earned achievement at specific tier
     * @param user User address
     * @param achievementId Achievement ID
     * @param tier Tier level
     * @return Whether user has the achievement
     */
    function hasAchievement(address user, uint256 achievementId, AchievementTier tier)
        external
        view
        returns (bool);

    /**
     * @notice Get all registered achievement IDs
     * @return Array of achievement IDs
     */
    function getAllAchievementIds() external view returns (uint256[] memory);

    /**
     * @notice Get achievement count by category
     * @param category Achievement category
     * @return Count of achievements in category
     */
    function getAchievementCountByCategory(AchievementCategory category)
        external
        view
        returns (uint256);

    /**
     * @notice Check if token is soulbound
     * @param tokenId Token ID
     * @return Whether token is soulbound
     */
    function isSoulbound(uint256 tokenId) external view returns (bool);

    /**
     * @notice Decode token ID into achievement ID and tier
     * @param tokenId Token ID to decode
     * @return achievementId Achievement ID
     * @return tier Tier level
     */
    function decodeTokenId(uint256 tokenId)
        external
        pure
        returns (uint256 achievementId, AchievementTier tier);

    /**
     * @notice Get total achievements minted
     * @return Total count
     */
    function totalMinted() external view returns (uint256);

    /**
     * @notice Get contract version
     * @return Version string
     */
    function version() external pure returns (string memory);

    // ═══════════════════════════════════════════════════════════════════════════
    // REGISTRY FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Register a new achievement definition
     * @param id Achievement ID
     * @param name Achievement name
     * @param description Achievement description
     * @param category Achievement category
     * @param maxTier Maximum tier achievable
     * @param soulbound Whether tokens are soulbound
     * @param progressive Whether achievement has multiple tiers
     */
    function registerAchievement(
        uint256 id,
        string calldata name,
        string calldata description,
        AchievementCategory category,
        AchievementTier maxTier,
        bool soulbound,
        bool progressive
    ) external;

    /**
     * @notice Deactivate an achievement
     * @param achievementId Achievement ID to deactivate
     */
    function deactivateAchievement(uint256 achievementId) external;

    /**
     * @notice Update achievement soulbound status
     * @param achievementId Achievement ID
     * @param soulbound New soulbound status
     */
    function setAchievementSoulbound(uint256 achievementId, bool soulbound) external;
}
