// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibNoteStorage} from "../libraries/LibNoteStorage.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {IColonyReserveNotes} from "../../../collections/banknotes/IColonyReserveNotes.sol";

/**
 * @title NoteRewardFacet
 * @notice Diamond facet for Colony Reserve Notes integration with Colony Wars
 * @dev Allows colonies to claim banknote NFTs as rewards based on season performance
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract NoteRewardFacet is AccessControlBase {
    // ============================================
    // EVENTS
    // ============================================

    event NoteRewardsClaimed(
        bytes32 indexed colonyId,
        address indexed claimer,
        uint8 denominationId,
        uint256 tokenId,
        uint32 seasonId
    );

    event NoteRewardsConfigured(
        address indexed noteContract,
        bytes1 series,
        bool enabled
    );

    event DenominationRewardConfigured(
        uint8 indexed denominationId,
        uint32 seasonLimit,
        uint256 minScore,
        uint8 minRank
    );

    // ============================================
    // ERRORS
    // ============================================

    error ArrayLengthMismatch();
    error InvalidSeriesId();
    error MintFailed();

    // ============================================
    // ADMIN: INITIALIZATION
    // ============================================

    /**
     * @notice Initialize note rewards system
     * @param noteContract Address of ColonyReserveNotes contract
     * @param series Initial series ID ('A', 'B', etc.)
     */
    function initializeNoteRewards(
        address noteContract,
        bytes1 series
    ) external onlyAuthorized {
        if (noteContract == address(0)) revert LibNoteStorage.NoteContractNotSet();
        if (series == 0) revert InvalidSeriesId();

        LibNoteStorage.initialize(noteContract, series);

        emit NoteRewardsConfigured(noteContract, series, true);
    }

    /**
     * @notice Set note rewards enabled/disabled
     */
    function setNoteRewardsEnabled(bool enabled) external onlyAuthorized {
        LibNoteStorage.NoteStorage storage ns = LibNoteStorage.noteStorage();
        ns.config.enabled = enabled;

        emit NoteRewardsConfigured(ns.config.noteContract, ns.config.currentSeries, enabled);
    }

    /**
     * @notice Update note contract address
     */
    function setNoteContract(address noteContract) external onlyAuthorized {
        if (noteContract == address(0)) revert LibNoteStorage.NoteContractNotSet();

        LibNoteStorage.NoteStorage storage ns = LibNoteStorage.noteStorage();
        ns.config.noteContract = noteContract;

        emit NoteRewardsConfigured(noteContract, ns.config.currentSeries, ns.config.enabled);
    }

    /**
     * @notice Update current series for minting
     */
    function setCurrentNoteSeries(bytes1 series) external onlyAuthorized {
        if (series == 0) revert InvalidSeriesId();

        LibNoteStorage.NoteStorage storage ns = LibNoteStorage.noteStorage();
        ns.config.currentSeries = series;

        emit NoteRewardsConfigured(ns.config.noteContract, series, ns.config.enabled);
    }

    // ============================================
    // ADMIN: DENOMINATION CONFIGURATION
    // ============================================

    /**
     * @notice Configure a denomination for rewards
     * @param denominationId Denomination ID (must match ColonyReserveNotes config)
     * @param seasonLimit Max notes per season (0 = unlimited)
     * @param minScore Minimum Colony Wars score required
     * @param minRank Minimum rank required (0 = no rank requirement, 1 = top 1, etc.)
     * @param enabled Whether this denomination is enabled
     */
    function configureDenominationReward(
        uint8 denominationId,
        uint32 seasonLimit,
        uint256 minScore,
        uint8 minRank,
        bool enabled
    ) external onlyAuthorized {
        LibNoteStorage.configureDenomination(
            denominationId,
            seasonLimit,
            minScore,
            minRank,
            enabled
        );

        emit DenominationRewardConfigured(denominationId, seasonLimit, minScore, minRank);
    }

    /**
     * @notice Batch configure denominations
     * @param denominationIds Array of denomination IDs
     * @param seasonLimits Array of season limits
     * @param minScores Array of minimum scores
     * @param minRanks Array of minimum ranks
     * @param enabledFlags Array of enabled flags
     */
    function configureDenominationRewardsBatch(
        uint8[] calldata denominationIds,
        uint32[] calldata seasonLimits,
        uint256[] calldata minScores,
        uint8[] calldata minRanks,
        bool[] calldata enabledFlags
    ) external onlyAuthorized {
        if (
            denominationIds.length != seasonLimits.length ||
            denominationIds.length != minScores.length ||
            denominationIds.length != minRanks.length ||
            denominationIds.length != enabledFlags.length
        ) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i = 0; i < denominationIds.length; i++) {
            LibNoteStorage.configureDenomination(
                denominationIds[i],
                seasonLimits[i],
                minScores[i],
                minRanks[i],
                enabledFlags[i]
            );

            emit DenominationRewardConfigured(
                denominationIds[i],
                seasonLimits[i],
                minScores[i],
                minRanks[i]
            );
        }
    }

    /**
     * @notice Set season limit for a denomination
     */
    function setNoteSeasonLimit(uint8 denominationId, uint32 limit) external onlyAuthorized {
        LibNoteStorage.NoteStorage storage ns = LibNoteStorage.noteStorage();
        ns.denominationConfigs[denominationId].seasonLimit = limit;
    }

    /**
     * @notice Set minimum score for a denomination
     */
    function setNoteMinScore(uint8 denominationId, uint256 minScore) external onlyAuthorized {
        LibNoteStorage.NoteStorage storage ns = LibNoteStorage.noteStorage();
        ns.denominationConfigs[denominationId].minScore = minScore;
    }

    /**
     * @notice Set minimum rank for a denomination
     */
    function setNoteMinRank(uint8 denominationId, uint8 minRank) external onlyAuthorized {
        LibNoteStorage.NoteStorage storage ns = LibNoteStorage.noteStorage();
        ns.denominationConfigs[denominationId].minRank = minRank;
    }

    // ============================================
    // USER: CLAIM NOTE REWARDS
    // ============================================

    /**
     * @notice Claim a note reward for a colony
     * @param colonyId Colony ID that earned the reward
     * @param denominationId Denomination to claim
     */
    function claimNoteReward(
        bytes32 colonyId,
        uint8 denominationId
    ) external whenNotPaused nonReentrant {
        address sender = LibMeta.msgSender();

        // Get current season
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        uint32 seasonId = cws.currentSeason;

        // Validate claim
        _validateClaim(sender, colonyId, denominationId, seasonId, cws);

        // Mint note
        uint256 tokenId = _mintNoteReward(sender, denominationId, seasonId, colonyId);

        emit NoteRewardsClaimed(colonyId, sender, denominationId, tokenId, seasonId);
    }

    /**
     * @notice Claim multiple note rewards at once
     * @param colonyId Colony ID that earned the rewards
     * @param denominationIds Array of denominations to claim
     */
    function claimNoteRewardsBatch(
        bytes32 colonyId,
        uint8[] calldata denominationIds
    ) external whenNotPaused nonReentrant {
        address sender = LibMeta.msgSender();

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        uint32 seasonId = cws.currentSeason;

        for (uint256 i = 0; i < denominationIds.length; i++) {
            uint8 denomId = denominationIds[i];

            _validateClaim(sender, colonyId, denomId, seasonId, cws);
            uint256 tokenId = _mintNoteReward(sender, denomId, seasonId, colonyId);

            emit NoteRewardsClaimed(colonyId, sender, denomId, tokenId, seasonId);
        }
    }

    // ============================================
    // VIEW: ELIGIBILITY
    // ============================================

    /**
     * @notice Check eligibility for all configured denominations
     * @param colonyId Colony to check
     * @return eligibleDenominations Array of denomination IDs the colony is eligible for
     * @return claimedDenominations Array of denomination IDs already claimed
     * @return seasonId Current season ID
     */
    function checkNoteEligibility(bytes32 colonyId) external view returns (
        uint8[] memory eligibleDenominations,
        uint8[] memory claimedDenominations,
        uint32 seasonId
    ) {
        LibNoteStorage.NoteStorage storage ns = LibNoteStorage.noteStorage();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        seasonId = cws.currentSeason;
        uint8[] memory configured = LibNoteStorage.getConfiguredDenominations();

        // Count eligible and claimed
        uint256 eligibleCount = 0;
        uint256 claimedCount = 0;

        for (uint256 i = 0; i < configured.length; i++) {
            uint8 denomId = configured[i];

            if (LibNoteStorage.hasClaimed(seasonId, colonyId, denomId)) {
                claimedCount++;
            } else if (_isEligibleForDenomination(colonyId, denomId, seasonId, cws, ns)) {
                eligibleCount++;
            }
        }

        // Build arrays
        eligibleDenominations = new uint8[](eligibleCount);
        claimedDenominations = new uint8[](claimedCount);

        uint256 eligibleIdx = 0;
        uint256 claimedIdx = 0;

        for (uint256 i = 0; i < configured.length; i++) {
            uint8 denomId = configured[i];

            if (LibNoteStorage.hasClaimed(seasonId, colonyId, denomId)) {
                claimedDenominations[claimedIdx++] = denomId;
            } else if (_isEligibleForDenomination(colonyId, denomId, seasonId, cws, ns)) {
                eligibleDenominations[eligibleIdx++] = denomId;
            }
        }
    }

    /**
     * @notice Check if colony is eligible for a specific denomination
     * @param colonyId Colony to check
     * @param denominationId Denomination to check
     * @return eligible Whether the colony is eligible
     * @return reason Reason if not eligible
     */
    function checkDenominationEligibility(
        bytes32 colonyId,
        uint8 denominationId
    ) external view returns (bool eligible, string memory reason) {
        LibNoteStorage.NoteStorage storage ns = LibNoteStorage.noteStorage();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        uint32 seasonId = cws.currentSeason;

        if (!ns.config.initialized) return (false, "Note rewards not initialized");
        if (!ns.config.enabled) return (false, "Note rewards disabled");
        if (!ns.denominationConfigs[denominationId].enabled) return (false, "Denomination not enabled");

        if (LibNoteStorage.hasClaimed(seasonId, colonyId, denominationId)) {
            return (false, "Already claimed");
        }

        if (LibNoteStorage.isSeasonLimitReached(seasonId, denominationId)) {
            return (false, "Season limit reached");
        }

        // Check resolution period
        if (!_isInResolutionPeriod(cws)) {
            return (false, "Not in resolution period");
        }

        // Check score
        LibNoteStorage.DenominationRewardConfig memory config = ns.denominationConfigs[denominationId];
        uint256 colonyScore = cws.seasonScores[seasonId][colonyId];

        if (colonyScore < config.minScore) {
            return (false, "Score too low");
        }

        // Check rank if required
        if (config.minRank > 0) {
            uint256 rank = _getColonyRank(colonyId, seasonId, cws);
            if (rank == 0 || rank > config.minRank) {
                return (false, "Rank too low");
            }
        }

        return (true, "");
    }

    // ============================================
    // VIEW: CONFIGURATION
    // ============================================

    /**
     * @notice Get note rewards configuration
     */
    function getNoteRewardsConfig() external view returns (
        address noteContract,
        bool enabled,
        bytes1 currentSeries,
        bool initialized
    ) {
        LibNoteStorage.NoteStorage storage ns = LibNoteStorage.noteStorage();
        return (
            ns.config.noteContract,
            ns.config.enabled,
            ns.config.currentSeries,
            ns.config.initialized
        );
    }

    /**
     * @notice Get denomination reward configuration
     */
    function getDenominationRewardConfig(uint8 denominationId) external view returns (
        uint32 seasonLimit,
        uint256 minScore,
        uint8 minRank,
        bool enabled
    ) {
        LibNoteStorage.DenominationRewardConfig memory config =
            LibNoteStorage.getDenominationConfig(denominationId);

        return (config.seasonLimit, config.minScore, config.minRank, config.enabled);
    }

    /**
     * @notice Get all configured denomination IDs
     */
    function getConfiguredDenominations() external view returns (uint8[] memory) {
        return LibNoteStorage.getConfiguredDenominations();
    }

    /**
     * @notice Get remaining season allocation for a denomination
     */
    function getRemainingSeasonAllocation(uint8 denominationId) external view returns (uint32) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        uint32 seasonId = cws.currentSeason;
        return LibNoteStorage.getRemainingSeasonAllocation(seasonId, denominationId);
    }

    /**
     * @notice Get season mint count for a denomination
     */
    function getSeasonMintCount(uint32 seasonId, uint8 denominationId) external view returns (uint32) {
        return LibNoteStorage.noteStorage().seasonMintCounts[seasonId][denominationId];
    }

    // ============================================
    // INTERNAL
    // ============================================

    function _validateClaim(
        address sender,
        bytes32 colonyId,
        uint8 denominationId,
        uint32 seasonId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal view {
        LibNoteStorage.requireEnabled();

        // Verify colony ownership
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        if (hs.colonyCreators[colonyId] != sender) {
            revert LibNoteStorage.NotColonyOwner(colonyId, sender);
        }

        // Check resolution period
        if (!_isInResolutionPeriod(cws)) {
            revert LibNoteStorage.NotInResolutionPeriod(seasonId);
        }

        // Check denomination is configured
        if (!LibNoteStorage.isDenominationConfigured(denominationId)) {
            revert LibNoteStorage.InvalidDenomination(denominationId);
        }

        // Check not already claimed
        if (LibNoteStorage.hasClaimed(seasonId, colonyId, denominationId)) {
            revert LibNoteStorage.AlreadyClaimed(colonyId, denominationId, seasonId);
        }

        // Check season limit
        if (LibNoteStorage.isSeasonLimitReached(seasonId, denominationId)) {
            revert LibNoteStorage.SeasonLimitReached(denominationId, seasonId);
        }

        // Check eligibility
        LibNoteStorage.NoteStorage storage ns = LibNoteStorage.noteStorage();
        if (!_isEligibleForDenomination(colonyId, denominationId, seasonId, cws, ns)) {
            revert LibNoteStorage.NotEligible(colonyId, denominationId);
        }
    }

    function _isEligibleForDenomination(
        bytes32 colonyId,
        uint8 denominationId,
        uint32 seasonId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        LibNoteStorage.NoteStorage storage ns
    ) internal view returns (bool) {
        LibNoteStorage.DenominationRewardConfig memory config = ns.denominationConfigs[denominationId];

        if (!config.enabled) return false;

        // Check score
        uint256 colonyScore = cws.seasonScores[seasonId][colonyId];
        if (colonyScore < config.minScore) return false;

        // Check rank if required
        if (config.minRank > 0) {
            uint256 rank = _getColonyRank(colonyId, seasonId, cws);
            if (rank == 0 || rank > config.minRank) return false;
        }

        return true;
    }

    function _isInResolutionPeriod(
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal view returns (bool) {
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];

        // Resolution period: after warfareEnd, before resolutionEnd
        return block.timestamp >= season.warfareEnd &&
               block.timestamp <= season.resolutionEnd &&
               season.active;
    }

    function _getColonyRank(
        bytes32 colonyId,
        uint32 seasonId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal view returns (uint256) {
        // Get colony score
        uint256 colonyScore = cws.seasonScores[seasonId][colonyId];
        if (colonyScore == 0) return 0;

        // Count colonies with higher score
        bytes32[] storage registeredColonies = cws.seasons[seasonId].registeredColonies;
        uint256 rank = 1;

        for (uint256 i = 0; i < registeredColonies.length; i++) {
            bytes32 otherId = registeredColonies[i];
            if (otherId != colonyId) {
                uint256 otherScore = cws.seasonScores[seasonId][otherId];
                if (otherScore > colonyScore) {
                    rank++;
                }
            }
        }

        return rank;
    }

    function _mintNoteReward(
        address recipient,
        uint8 denominationId,
        uint32 seasonId,
        bytes32 colonyId
    ) internal returns (uint256 tokenId) {
        LibNoteStorage.NoteStorage storage ns = LibNoteStorage.noteStorage();

        // Record claim first (reentrancy protection)
        LibNoteStorage.recordClaim(seasonId, colonyId, denominationId);

        // Mint note via external contract
        try IColonyReserveNotes(ns.config.noteContract).mintNote(
            recipient,
            denominationId,
            ns.config.currentSeries
        ) returns (uint256 mintedTokenId) {
            return mintedTokenId;
        } catch {
            // Revert claim on failure - this will revert the entire tx
            revert MintFailed();
        }
    }
}
