// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {ColonyHelper} from "../../staking/libraries/ColonyHelper.sol";
import {AccessHelper} from "../../staking/libraries/AccessHelper.sol";
import {PodsUtils} from "../../../libraries/PodsUtils.sol";

/**
 * @title ColonyTaskForceFacet
 * @notice Manages combat Task Forces for Colony Wars
 * @dev Task Forces are seasonal groups of tokens for coordinated battle actions
 */
contract ColonyTaskForceFacet is AccessControlBase {

    // Events
    event TaskForceCreated(
        bytes32 indexed taskForceId,
        bytes32 indexed colonyId,
        uint32 indexed seasonId,
        string name,
        uint256 tokenCount
    );
    event TaskForceUpdated(bytes32 indexed taskForceId, uint256 newTokenCount);
    event TaskForceDisbanded(bytes32 indexed taskForceId, bytes32 indexed colonyId);
    event TokenAddedToTaskForce(bytes32 indexed taskForceId, uint256 collectionId, uint256 tokenId);
    event TokenRemovedFromTaskForce(bytes32 indexed taskForceId, uint256 collectionId, uint256 tokenId);

    // Errors
    error TaskForceNotFound();
    error TaskForceNotActive();
    error InvalidTaskForceName();
    error MinimumTwoTokensRequired();
    error TokenAlreadyInTaskForce();
    error TokenNotInTaskForce();
    error TokenNotInColony();
    error SeasonNotActive();
    error WarfareEnded();
    error ColonyNotRegistered();
    error ArrayLengthMismatch();
    error MaxTokensExceeded();
    error TokenInActiveBattle();

    // ============ MODIFIERS ============

    /**
     * @dev Verifies caller is the creator of the specified colony
     */
    modifier onlyColonyCreator(bytes32 colonyId) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        if (!ColonyHelper.isColonyCreator(colonyId, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony creator");
        }
        _;
    }

    /**
     * @dev Verifies task force creation is allowed (active season, before warfare end)
     */
    modifier duringTaskForceCreationPeriod() {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];

        if (!season.active) {
            revert SeasonNotActive();
        }
        if (block.timestamp > season.warfareEnd) {
            revert WarfareEnded();
        }
        _;
    }

    // ============ MAIN FUNCTIONS ============

    /**
     * @notice Create a new Task Force for the current season
     * @param colonyId Colony that owns this task force
     * @param name Name for the task force
     * @param collectionIds Array of collection IDs for tokens
     * @param tokenIds Array of token IDs
     * @return taskForceId The created task force ID
     */
    function createTaskForce(
        bytes32 colonyId,
        string calldata name,
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds
    )
        external
        whenNotPaused
        nonReentrant
        onlyColonyCreator(colonyId)
        duringTaskForceCreationPeriod
        returns (bytes32 taskForceId)
    {
        LibColonyWarsStorage.requireInitialized();

        // Validate inputs and get task force ID
        taskForceId = _createTaskForceInternal(colonyId, name, collectionIds, tokenIds);

        return taskForceId;
    }

    /**
     * @notice Internal task force creation logic
     */
    function _createTaskForceInternal(
        bytes32 colonyId,
        string calldata name,
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds
    ) internal returns (bytes32 taskForceId) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        // Validate colony is registered for current season
        if (!cws.colonyWarProfiles[colonyId].registered) {
            revert ColonyNotRegistered();
        }

        // Validate name
        if (bytes(name).length == 0 || bytes(name).length > 32) {
            revert InvalidTaskForceName();
        }

        // Validate arrays
        if (collectionIds.length != tokenIds.length) {
            revert ArrayLengthMismatch();
        }
        if (collectionIds.length < 2) {
            revert MinimumTwoTokensRequired();
        }
        if (collectionIds.length > cws.config.maxBattleTokens) {
            revert MaxTokensExceeded();
        }

        // Validate all tokens and create task force
        taskForceId = _validateAndCreateTaskForce(colonyId, name, collectionIds, tokenIds, cws);

        return taskForceId;
    }

    /**
     * @notice Validate tokens and create task force
     */
    function _validateAndCreateTaskForce(
        bytes32 colonyId,
        string calldata name,
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal returns (bytes32 taskForceId) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint32 currentSeason = cws.currentSeason;

        // Validate all tokens
        _validateAllTokens(colonyId, collectionIds, tokenIds, currentSeason, cws, hs);

        // Generate task force ID
        cws.taskForceCounter++;
        taskForceId = keccak256(abi.encodePacked(
            "taskforce",
            colonyId,
            currentSeason,
            cws.taskForceCounter,
            block.timestamp
        ));

        // Create and populate task force
        _populateTaskForce(taskForceId, colonyId, name, collectionIds, tokenIds, currentSeason, cws);

        emit TaskForceCreated(taskForceId, colonyId, currentSeason, name, collectionIds.length);

        return taskForceId;
    }

    /**
     * @notice Validate all tokens for task force
     */
    function _validateAllTokens(
        bytes32 colonyId,
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds,
        uint32 seasonId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) internal view {
        for (uint256 i = 0; i < collectionIds.length; i++) {
            _validateTokenForTaskForce(colonyId, collectionIds[i], tokenIds[i], seasonId, cws, hs);
        }
    }

    /**
     * @notice Populate task force with data
     */
    function _populateTaskForce(
        bytes32 taskForceId,
        bytes32 colonyId,
        string calldata name,
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds,
        uint32 currentSeason,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        LibColonyWarsStorage.TaskForce storage tf = cws.taskForces[taskForceId];
        tf.colonyId = colonyId;
        tf.seasonId = currentSeason;
        tf.name = name;
        tf.createdAt = uint32(block.timestamp);
        tf.active = true;

        // Store tokens and mark them as assigned
        for (uint256 i = 0; i < collectionIds.length; i++) {
            tf.collectionIds.push(collectionIds[i]);
            tf.tokenIds.push(tokenIds[i]);

            uint256 combinedId = PodsUtils.combineIds(collectionIds[i], tokenIds[i]);
            cws.tokenToTaskForce[currentSeason][combinedId] = taskForceId;
        }

        // Add to colony's task forces for this season
        cws.colonyTaskForces[colonyId][currentSeason].push(taskForceId);
    }

    /**
     * @notice Add tokens to an existing task force
     * @param taskForceId Task force to modify
     * @param collectionIds Array of collection IDs for new tokens
     * @param tokenIds Array of token IDs to add
     */
    function addTokensToTaskForce(
        bytes32 taskForceId,
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds
    )
        external
        whenNotPaused
        nonReentrant
        duringTaskForceCreationPeriod
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        LibColonyWarsStorage.TaskForce storage tf = cws.taskForces[taskForceId];

        if (tf.createdAt == 0) {
            revert TaskForceNotFound();
        }
        if (!tf.active) {
            revert TaskForceNotActive();
        }

        // Verify caller owns the colony
        if (!ColonyHelper.isColonyCreator(tf.colonyId, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony creator");
        }

        if (collectionIds.length != tokenIds.length) {
            revert ArrayLengthMismatch();
        }

        // Check max tokens limit
        if (tf.tokenIds.length + tokenIds.length > cws.config.maxBattleTokens) {
            revert MaxTokensExceeded();
        }

        uint32 currentSeason = cws.currentSeason;

        for (uint256 i = 0; i < collectionIds.length; i++) {
            uint256 combinedId = PodsUtils.combineIds(collectionIds[i], tokenIds[i]);

            // Check token is not in active battle/siege
            if (!LibColonyWarsStorage.isTokenAvailableForBattle(combinedId)) {
                revert TokenInActiveBattle();
            }

            _validateTokenForTaskForce(
                tf.colonyId,
                collectionIds[i],
                tokenIds[i],
                currentSeason,
                cws,
                hs
            );

            tf.collectionIds.push(collectionIds[i]);
            tf.tokenIds.push(tokenIds[i]);

            cws.tokenToTaskForce[currentSeason][combinedId] = taskForceId;

            emit TokenAddedToTaskForce(taskForceId, collectionIds[i], tokenIds[i]);
        }

        emit TaskForceUpdated(taskForceId, tf.tokenIds.length);
    }

    /**
     * @notice Remove tokens from a task force
     * @param taskForceId Task force to modify
     * @param collectionIds Array of collection IDs for tokens to remove
     * @param tokenIds Array of token IDs to remove
     */
    function removeTokensFromTaskForce(
        bytes32 taskForceId,
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds
    )
        external
        whenNotPaused
        nonReentrant
        duringTaskForceCreationPeriod
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        LibColonyWarsStorage.TaskForce storage tf = cws.taskForces[taskForceId];

        if (tf.createdAt == 0) {
            revert TaskForceNotFound();
        }
        if (!tf.active) {
            revert TaskForceNotActive();
        }

        // Verify caller owns the colony
        if (!ColonyHelper.isColonyCreator(tf.colonyId, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony creator");
        }

        if (collectionIds.length != tokenIds.length) {
            revert ArrayLengthMismatch();
        }

        uint32 currentSeason = cws.currentSeason;

        for (uint256 i = 0; i < collectionIds.length; i++) {
            uint256 combinedId = PodsUtils.combineIds(collectionIds[i], tokenIds[i]);

            // Check token is not in active battle/siege
            if (!LibColonyWarsStorage.isTokenAvailableForBattle(combinedId)) {
                revert TokenInActiveBattle();
            }

            // Verify token is in this task force
            if (cws.tokenToTaskForce[currentSeason][combinedId] != taskForceId) {
                revert TokenNotInTaskForce();
            }

            // Remove from arrays
            _removeTokenFromTaskForce(tf, collectionIds[i], tokenIds[i]);

            // Clear mapping
            delete cws.tokenToTaskForce[currentSeason][combinedId];

            emit TokenRemovedFromTaskForce(taskForceId, collectionIds[i], tokenIds[i]);
        }

        // Check minimum tokens requirement
        if (tf.tokenIds.length < 2) {
            // Check remaining tokens are not in battle before auto-disbanding
            for (uint256 i = 0; i < tf.tokenIds.length; i++) {
                uint256 remainingCombinedId = PodsUtils.combineIds(tf.collectionIds[i], tf.tokenIds[i]);
                if (!LibColonyWarsStorage.isTokenAvailableForBattle(remainingCombinedId)) {
                    revert TokenInActiveBattle();
                }
            }
            // Disband task force if less than 2 tokens remain
            _disbandTaskForce(taskForceId, tf, cws);
        } else {
            emit TaskForceUpdated(taskForceId, tf.tokenIds.length);
        }
    }

    /**
     * @notice Disband a task force completely
     * @param taskForceId Task force to disband
     */
    function disbandTaskForce(bytes32 taskForceId)
        external
        whenNotPaused
        nonReentrant
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        LibColonyWarsStorage.TaskForce storage tf = cws.taskForces[taskForceId];

        if (tf.createdAt == 0) {
            revert TaskForceNotFound();
        }
        if (!tf.active) {
            revert TaskForceNotActive();
        }

        // Verify caller owns the colony
        if (!ColonyHelper.isColonyCreator(tf.colonyId, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony creator");
        }

        // Check no tokens are in active battle/siege
        for (uint256 i = 0; i < tf.tokenIds.length; i++) {
            uint256 combinedId = PodsUtils.combineIds(tf.collectionIds[i], tf.tokenIds[i]);
            if (!LibColonyWarsStorage.isTokenAvailableForBattle(combinedId)) {
                revert TokenInActiveBattle();
            }
        }

        _disbandTaskForce(taskForceId, tf, cws);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get task force details
     * @param taskForceId Task force ID to query
     * @return colonyId Colony owning this task force
     * @return seasonId Season this task force belongs to
     * @return name Task force name
     * @return collectionIds Collection IDs of member tokens
     * @return tokenIds Token IDs of members
     * @return createdAt Creation timestamp
     * @return active Whether task force is active
     */
    function getTaskForce(bytes32 taskForceId)
        external
        view
        returns (
            bytes32 colonyId,
            uint32 seasonId,
            string memory name,
            uint256[] memory collectionIds,
            uint256[] memory tokenIds,
            uint32 createdAt,
            bool active
        )
    {
        LibColonyWarsStorage.TaskForce storage tf = LibColonyWarsStorage.colonyWarsStorage().taskForces[taskForceId];

        return (
            tf.colonyId,
            tf.seasonId,
            tf.name,
            tf.collectionIds,
            tf.tokenIds,
            tf.createdAt,
            tf.active
        );
    }

    /**
     * @notice Get all task forces for a colony in a season
     * @param colonyId Colony to query
     * @param seasonId Season to query (0 for current season)
     * @return taskForceIds Array of task force IDs
     */
    function getColonyTaskForces(bytes32 colonyId, uint32 seasonId)
        external
        view
        returns (bytes32[] memory taskForceIds)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        uint32 season = seasonId == 0 ? cws.currentSeason : seasonId;
        return cws.colonyTaskForces[colonyId][season];
    }

    /**
     * @notice Check if a token is assigned to any task force
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param seasonId Season to check (0 for current season)
     * @return taskForceId Task force ID (bytes32(0) if not assigned)
     */
    function getTokenTaskForce(uint256 collectionId, uint256 tokenId, uint32 seasonId)
        external
        view
        returns (bytes32 taskForceId)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        uint32 season = seasonId == 0 ? cws.currentSeason : seasonId;
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);

        return cws.tokenToTaskForce[season][combinedId];
    }

    /**
     * @notice Get tokens from a task force for battle use
     * @param taskForceId Task force ID
     * @return collectionIds Collection IDs of tokens
     * @return tokenIds Token IDs
     */
    function getTaskForceTokens(bytes32 taskForceId)
        external
        view
        returns (uint256[] memory collectionIds, uint256[] memory tokenIds)
    {
        LibColonyWarsStorage.TaskForce storage tf = LibColonyWarsStorage.colonyWarsStorage().taskForces[taskForceId];

        if (!tf.active) {
            revert TaskForceNotActive();
        }

        return (tf.collectionIds, tf.tokenIds);
    }

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @notice Validate token can be added to task force
     */
    function _validateTokenForTaskForce(
        bytes32 colonyId,
        uint256 collectionId,
        uint256 tokenId,
        uint32 seasonId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) internal view {
        // Check token belongs to colony
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);

        // Check if token is in colony's token array
        uint256[] storage colonyTokens = hs.colonies[colonyId];
        bool tokenInColony = false;
        for (uint256 i = 0; i < colonyTokens.length; i++) {
            if (colonyTokens[i] == combinedId) {
                tokenInColony = true;
                break;
            }
        }

        if (!tokenInColony) {
            revert TokenNotInColony();
        }

        // Check token is not already in a task force
        if (cws.tokenToTaskForce[seasonId][combinedId] != bytes32(0)) {
            revert TokenAlreadyInTaskForce();
        }
    }

    /**
     * @notice Remove token from task force arrays
     */
    function _removeTokenFromTaskForce(
        LibColonyWarsStorage.TaskForce storage tf,
        uint256 collectionId,
        uint256 tokenId
    ) internal {
        uint256 length = tf.tokenIds.length;

        for (uint256 i = 0; i < length; i++) {
            if (tf.collectionIds[i] == collectionId && tf.tokenIds[i] == tokenId) {
                // Swap with last element and pop
                tf.collectionIds[i] = tf.collectionIds[length - 1];
                tf.tokenIds[i] = tf.tokenIds[length - 1];
                tf.collectionIds.pop();
                tf.tokenIds.pop();
                return;
            }
        }

        revert TokenNotInTaskForce();
    }

    /**
     * @notice Internal function to disband task force
     */
    function _disbandTaskForce(
        bytes32 taskForceId,
        LibColonyWarsStorage.TaskForce storage tf,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        uint32 seasonId = tf.seasonId;
        bytes32 colonyId = tf.colonyId;

        // Clear all token mappings
        for (uint256 i = 0; i < tf.tokenIds.length; i++) {
            uint256 combinedId = PodsUtils.combineIds(tf.collectionIds[i], tf.tokenIds[i]);
            delete cws.tokenToTaskForce[seasonId][combinedId];
        }

        // Mark as inactive
        tf.active = false;

        // Remove from colony's task force list
        bytes32[] storage colonyTFs = cws.colonyTaskForces[colonyId][seasonId];
        for (uint256 i = 0; i < colonyTFs.length; i++) {
            if (colonyTFs[i] == taskForceId) {
                colonyTFs[i] = colonyTFs[colonyTFs.length - 1];
                colonyTFs.pop();
                break;
            }
        }

        emit TaskForceDisbanded(taskForceId, colonyId);
    }
}
