// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title LibNoteStorage
 * @notice Storage library for NoteRewardFacet - Diamond proxy integration
 * @dev Manages note reward configuration and claims tracking for Colony Wars
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
library LibNoteStorage {
    bytes32 constant NOTE_STORAGE_POSITION = keccak256("henomorphs.note.reward.storage.v1");

    // ============================================
    // ERRORS
    // ============================================

    error NoteRewardsNotInitialized();
    error NoteRewardsDisabled();
    error NoteContractNotSet();
    error InvalidDenomination(uint8 denominationId);
    error SeasonLimitReached(uint8 denominationId, uint32 seasonId);
    error AlreadyClaimed(bytes32 colonyId, uint8 denominationId, uint32 seasonId);
    error NotEligible(bytes32 colonyId, uint8 denominationId);
    error NotInResolutionPeriod(uint32 seasonId);
    error NotColonyOwner(bytes32 colonyId, address sender);

    // ============================================
    // STRUCTS
    // ============================================

    /**
     * @notice Configuration for a single denomination reward
     */
    struct DenominationRewardConfig {
        uint32 seasonLimit;       // Max notes of this denomination per season (0 = unlimited)
        uint256 minScore;         // Minimum Colony Wars score required
        uint8 minRank;            // Minimum rank required (0 = no rank requirement, 1 = top 1, etc.)
        bool enabled;             // Whether this denomination is enabled for rewards
    }

    /**
     * @notice Main note reward configuration
     */
    struct NoteRewardConfig {
        address noteContract;     // ColonyReserveNotes contract address
        bool enabled;             // Global enable/disable for note rewards
        bytes1 currentSeries;     // Current series to mint notes from
        bool initialized;         // Whether config has been initialized
    }

    /**
     * @notice Main storage struct for note rewards
     */
    struct NoteStorage {
        // Core configuration
        NoteRewardConfig config;

        // Per-denomination reward configuration
        // denominationId => DenominationRewardConfig
        mapping(uint8 => DenominationRewardConfig) denominationConfigs;

        // List of configured denomination IDs
        uint8[] configuredDenominations;

        // Claims tracking: seasonId => colonyId => denominationId => claimed
        mapping(uint32 => mapping(bytes32 => mapping(uint8 => bool))) claims;

        // Season mint counts: seasonId => denominationId => count
        mapping(uint32 => mapping(uint8 => uint32)) seasonMintCounts;

        // Reserved for future upgrades
        uint256[50] __gap;
    }

    // ============================================
    // STORAGE ACCESS
    // ============================================

    /**
     * @notice Get note storage
     */
    function noteStorage() internal pure returns (NoteStorage storage ns) {
        bytes32 position = NOTE_STORAGE_POSITION;
        assembly {
            ns.slot := position
        }
    }

    // ============================================
    // VALIDATION HELPERS
    // ============================================

    /**
     * @notice Require note rewards to be initialized and enabled
     */
    function requireEnabled() internal view {
        NoteStorage storage ns = noteStorage();
        if (!ns.config.initialized) revert NoteRewardsNotInitialized();
        if (!ns.config.enabled) revert NoteRewardsDisabled();
        if (ns.config.noteContract == address(0)) revert NoteContractNotSet();
    }

    /**
     * @notice Check if denomination is configured
     */
    function isDenominationConfigured(uint8 denominationId) internal view returns (bool) {
        return noteStorage().denominationConfigs[denominationId].enabled;
    }

    /**
     * @notice Check if colony has already claimed a denomination in a season
     */
    function hasClaimed(
        uint32 seasonId,
        bytes32 colonyId,
        uint8 denominationId
    ) internal view returns (bool) {
        return noteStorage().claims[seasonId][colonyId][denominationId];
    }

    /**
     * @notice Check if season limit is reached for a denomination
     */
    function isSeasonLimitReached(
        uint32 seasonId,
        uint8 denominationId
    ) internal view returns (bool) {
        NoteStorage storage ns = noteStorage();
        uint32 limit = ns.denominationConfigs[denominationId].seasonLimit;
        if (limit == 0) return false; // Unlimited
        return ns.seasonMintCounts[seasonId][denominationId] >= limit;
    }

    /**
     * @notice Get remaining season allocation for a denomination
     */
    function getRemainingSeasonAllocation(
        uint32 seasonId,
        uint8 denominationId
    ) internal view returns (uint32) {
        NoteStorage storage ns = noteStorage();
        uint32 limit = ns.denominationConfigs[denominationId].seasonLimit;
        if (limit == 0) return type(uint32).max; // Unlimited
        uint32 minted = ns.seasonMintCounts[seasonId][denominationId];
        return minted >= limit ? 0 : limit - minted;
    }

    // ============================================
    // STATE MODIFIERS
    // ============================================

    /**
     * @notice Record a claim
     */
    function recordClaim(
        uint32 seasonId,
        bytes32 colonyId,
        uint8 denominationId
    ) internal {
        NoteStorage storage ns = noteStorage();
        ns.claims[seasonId][colonyId][denominationId] = true;
        ns.seasonMintCounts[seasonId][denominationId]++;
    }

    /**
     * @notice Initialize note rewards configuration
     */
    function initialize(
        address noteContract,
        bytes1 series
    ) internal {
        NoteStorage storage ns = noteStorage();
        ns.config.noteContract = noteContract;
        ns.config.currentSeries = series;
        ns.config.enabled = true;
        ns.config.initialized = true;
    }

    /**
     * @notice Configure a denomination for rewards
     */
    function configureDenomination(
        uint8 denominationId,
        uint32 seasonLimit,
        uint256 minScore,
        uint8 minRank,
        bool enabled
    ) internal {
        NoteStorage storage ns = noteStorage();

        // Track new denomination
        bool exists = false;
        for (uint256 i = 0; i < ns.configuredDenominations.length; i++) {
            if (ns.configuredDenominations[i] == denominationId) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            ns.configuredDenominations.push(denominationId);
        }

        ns.denominationConfigs[denominationId] = DenominationRewardConfig({
            seasonLimit: seasonLimit,
            minScore: minScore,
            minRank: minRank,
            enabled: enabled
        });
    }

    /**
     * @notice Get all configured denomination IDs
     */
    function getConfiguredDenominations() internal view returns (uint8[] memory) {
        return noteStorage().configuredDenominations;
    }

    /**
     * @notice Get denomination reward config
     */
    function getDenominationConfig(uint8 denominationId)
        internal
        view
        returns (DenominationRewardConfig memory)
    {
        return noteStorage().denominationConfigs[denominationId];
    }
}
