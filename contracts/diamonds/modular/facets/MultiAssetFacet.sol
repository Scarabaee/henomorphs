// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {LibCollectionStorage} from "../libraries/LibCollectionStorage.sol";
import {ModularHelper} from "../libraries/ModularHelper.sol";
import {ModularConfigData, ModularConfigIndices, TokenAsset, AssetCombination} from "../libraries/ModularAssetModel.sol";
import {AccessControlBase} from "./AccessControlBase.sol";

contract MultiAssetFacet is AccessControlBase {
    using Strings for uint256;
    using Strings for uint64;
    using Strings for uint8;

    event AssetSet(uint64 indexed assetId, string metadataURI, string mediaType);
    event AssetAddedToTokens(uint256 indexed collectionId, uint8 indexed tier, uint64 indexed assetId, uint256[] tokenIds, uint64 replacesAssetId);
    event AssetAccepted(uint256 indexed collectionId, uint8 indexed tier, uint256 indexed tokenId, uint64 assetId, uint64 replacedAssetId);
    event AssetRejected(uint256 indexed collectionId, uint8 indexed tier, uint256 indexed tokenId, uint64 assetId);
    event AssetPrioritySet(uint256 indexed collectionId, uint8 indexed tier, uint256 indexed tokenId, uint64[] priorities);
    event ActiveAssetChanged(uint256 indexed collectionId, uint8 indexed tier, uint256 indexed tokenId, uint64 oldAssetId, uint64 newAssetId);
    event AssetUpdated(uint64 indexed assetId, string newMetadataURI);
    event AssetRemoved(uint64 indexed assetId);
    event TokenAssetDataUpdated(uint256 indexed collectionId, uint8 indexed tier, uint256 indexed tokenId, uint64 assetId);
    event AssetsCombined(uint256 indexed collectionId, uint8 indexed tier, uint256 indexed tokenId, uint64 combinedAssetId, uint64[] sourceAssetIds, uint8 combinationType);
    event CombinationSeparated(uint256 indexed collectionId, uint8 indexed tier, uint256 indexed tokenId, uint64 combinedAssetId);
    event AssetContextSet(uint256 indexed collectionId, uint8 indexed tier, uint256 indexed tokenId, uint64 assetId, bytes32 context);
    
    error AssetAlreadyExists(uint64 assetId);
    error AssetNotPending(uint256 tokenId, uint64 assetId);
    error AssetNotAccepted(uint256 tokenId, uint64 assetId);
    error AssetLimitExceeded(uint256 tokenId, uint256 limit);
    error CombinationNotFound(uint64 combinedAssetId);
    error TooManyAssetsForCombination(uint256 maxAssets);
    error InvalidCombinationType(uint8 combinationType);
    
    uint256 private constant MAX_ASSETS_PER_COMBINATION = 5;
    uint8 private constant MAX_COMBINATION_TYPE = 2;
    uint256 private constant MAX_BATCH_SIZE = 50;
    
    function addAsset(
        uint64 assetId,
        string calldata metadataURI,
        string calldata mediaType
    ) external onlyAuthorized whenNotPaused {
        
        if (assetId == 0) revert ModularHelper.InvalidAssetData();
        if (bytes(metadataURI).length == 0) revert ModularHelper.InvalidAssetData();
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (cs.assetExists[assetId]) {
            revert AssetAlreadyExists(assetId);
        }
        
        cs.assetRegistry[assetId] = TokenAsset({
            id: assetId,
            assetUri: metadataURI,
            thumbnailUri: "",
            mediaType: mediaType,
            pending: false,
            replaceable: true,
            registrationTime: block.timestamp,
            traitPackId: 0,
            themeId: 0
        });
        
        cs.assetExists[assetId] = true;
        cs.assetIds.push(assetId);
        
        emit AssetSet(assetId, metadataURI, mediaType);
    }
    
    function addAssetToTokens(
        uint256 collectionId,
        uint8 tier,
        uint256[] calldata tokenIds,
        uint64 assetId,
        uint64 replacesAssetId
    ) external onlyAuthorized whenNotPaused validCollection(collectionId) {
        
        if (tokenIds.length == 0 || tokenIds.length > MAX_BATCH_SIZE) {
            revert ModularHelper.InvalidAssetData();
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        _validateMultiAssetCapability(collectionId);
        
        if (!cs.assetExists[assetId]) {
            revert ModularHelper.AssetNotFound(assetId);
        }
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            
            ModularHelper.validateTokenInCollectionTier(collectionId, tier, tokenId);
            
            uint16 maxAssetsPerToken = _getMaxAssetsPerToken(collectionId);
            ModularConfigData storage config = cs.modularConfigsData[collectionId][tier][tokenId];
            uint256 totalAssets = config.pendingAssets.length + config.acceptedAssets.length;
            if (totalAssets >= maxAssetsPerToken) {
                revert AssetLimitExceeded(tokenId, maxAssetsPerToken);
            }
            
            if (config.lastUpdateTime == 0) {
                config.lastUpdateTime = block.timestamp;
            }
            
            config.pendingAssets.push(assetId);
            cs.modularConfigsIndices[collectionId][tier][tokenId].pendingAssetIndices[assetId] = config.pendingAssets.length;
            
            if (replacesAssetId != 0) {
                cs.assetReplacements[tokenId][assetId] = replacesAssetId;
            }
            
            config.lastUpdateTime = block.timestamp;
        }
        
        emit AssetAddedToTokens(collectionId, tier, assetId, tokenIds, replacesAssetId);
    }
    
    function acceptAsset(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        uint64 assetId
    ) external whenNotPaused validCollection(collectionId) {
        
        ModularHelper.validateTokenInCollectionTier(collectionId, tier, tokenId);
        ModularHelper.validateTokenController(collectionId, tokenId, msg.sender);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!_isAssetPending(collectionId, tier, tokenId, assetId)) {
            revert AssetNotPending(tokenId, assetId);
        }
        
        ModularConfigData storage config = cs.modularConfigsData[collectionId][tier][tokenId];
        uint64 oldActiveAssetId = config.activeAssetId;
        
        _removeFromPendingAssets(collectionId, tier, tokenId, assetId);
        
        uint64 replacedAssetId = cs.assetReplacements[tokenId][assetId];
        if (replacedAssetId != 0) {
            _removeFromAcceptedAssets(collectionId, tier, tokenId, replacedAssetId);
            delete cs.assetReplacements[tokenId][assetId];
        }
        
        _addToAcceptedAssets(collectionId, tier, tokenId, assetId);
        
        bool activeAssetChanged = false;
        if (config.activeAssetId == 0 || config.activeAssetId == replacedAssetId) {
            config.activeAssetId = assetId;
            activeAssetChanged = true;
        }
        
        config.lastUpdateTime = block.timestamp;
        
        emit AssetAccepted(collectionId, tier, tokenId, assetId, replacedAssetId);
        
        if (activeAssetChanged) {
            emit ActiveAssetChanged(collectionId, tier, tokenId, oldActiveAssetId, assetId);
        }
    }
    
    function rejectAsset(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        uint64 assetId
    ) external whenNotPaused validCollection(collectionId) {
        
        ModularHelper.validateTokenInCollectionTier(collectionId, tier, tokenId);
        ModularHelper.validateTokenController(collectionId, tokenId, msg.sender);
        
        if (!_isAssetPending(collectionId, tier, tokenId, assetId)) {
            revert AssetNotPending(tokenId, assetId);
        }
        
        _removeFromPendingAssets(collectionId, tier, tokenId, assetId);
        _cleanupAssetReplacement(tokenId, assetId);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        cs.modularConfigsData[collectionId][tier][tokenId].lastUpdateTime = block.timestamp;
        
        emit AssetRejected(collectionId, tier, tokenId, assetId);
    }
    
    function setActiveAsset(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        uint64 assetId
    ) external whenNotPaused validCollection(collectionId) {
        
        ModularHelper.validateTokenInCollectionTier(collectionId, tier, tokenId);
        ModularHelper.validateTokenController(collectionId, tokenId, msg.sender);
        
        if (!_isAssetAccepted(collectionId, tier, tokenId, assetId)) {
            revert AssetNotAccepted(tokenId, assetId);
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        ModularConfigData storage config = cs.modularConfigsData[collectionId][tier][tokenId];
        
        uint64 oldActiveAssetId = config.activeAssetId;
        config.activeAssetId = assetId;
        config.lastUpdateTime = block.timestamp;
        
        emit ActiveAssetChanged(collectionId, tier, tokenId, oldActiveAssetId, assetId);
        emit TokenAssetDataUpdated(collectionId, tier, tokenId, assetId);
    }
    
    function setPriority(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        uint64[] calldata priorities
    ) external whenNotPaused validCollection(collectionId) {
        
        if (priorities.length == 0) revert ModularHelper.InvalidAssetData();
        
        ModularHelper.validateTokenInCollectionTier(collectionId, tier, tokenId);
        ModularHelper.validateTokenController(collectionId, tokenId, msg.sender);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        ModularConfigIndices storage indices = cs.modularConfigsIndices[collectionId][tier][tokenId];
        for (uint256 i = 0; i < priorities.length; i++) {
            if (indices.acceptedAssetIndices[priorities[i]] == 0) {
                revert AssetNotAccepted(tokenId, priorities[i]);
            }
        }
        
        _updateAssetPriorities(collectionId, tier, tokenId, priorities);
        
        cs.modularConfigsData[collectionId][tier][tokenId].lastUpdateTime = block.timestamp;
        
        emit AssetPrioritySet(collectionId, tier, tokenId, priorities);
    }
    
    function updateAsset(
        uint64 assetId,
        string calldata metadataURI,
        string calldata mediaType
    ) external onlyAuthorized whenNotPaused {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!cs.assetExists[assetId]) {
            revert ModularHelper.AssetNotFound(assetId);
        }
        
        TokenAsset storage asset = cs.assetRegistry[assetId];
        
        if (bytes(metadataURI).length > 0) {
            asset.assetUri = metadataURI;
        }
        
        if (bytes(mediaType).length > 0) {
            asset.mediaType = mediaType;
        }
        
        emit AssetUpdated(assetId, metadataURI);
    }
    
    function combineAssets(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        uint64[] calldata sourceAssetIds,
        uint8 combinationType
    ) external whenNotPaused validCollection(collectionId) returns (uint64 combinedAssetId) {
        
        if (sourceAssetIds.length < 2 || sourceAssetIds.length > MAX_ASSETS_PER_COMBINATION) {
            revert TooManyAssetsForCombination(MAX_ASSETS_PER_COMBINATION);
        }
        
        if (combinationType > MAX_COMBINATION_TYPE) {
            revert InvalidCombinationType(combinationType);
        }
        
        ModularHelper.validateTokenInCollectionTier(collectionId, tier, tokenId);
        ModularHelper.validateTokenController(collectionId, tokenId, msg.sender);
        
        _validateAcceptedAssets(collectionId, tier, tokenId, sourceAssetIds);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        combinedAssetId = ModularHelper.generateUniqueAssetId(uint256(keccak256(abi.encodePacked(sourceAssetIds))));
        
        string memory combinedURI = _buildCombinedURI(collectionId, tier, tokenId, sourceAssetIds, combinationType);
        
        cs.assetCombinations[combinedAssetId] = AssetCombination({
            combinedAssetId: combinedAssetId,
            sourceAssetIds: sourceAssetIds,
            combinedURI: combinedURI,
            combinationType: combinationType,
            creationTime: block.timestamp,
            replaceable: true
        });
        
        cs.assetRegistry[combinedAssetId] = TokenAsset({
            id: combinedAssetId,
            assetUri: combinedURI,
            thumbnailUri: string.concat(combinedURI, "&thumbnail=true"),
            mediaType: "application/json",
            pending: true,
            replaceable: true,
            registrationTime: block.timestamp,
            traitPackId: 0,
            themeId: 0
        });
        
        cs.assetExists[combinedAssetId] = true;
        cs.assetIds.push(combinedAssetId);
        
        ModularConfigData storage config = cs.modularConfigsData[collectionId][tier][tokenId];
        config.pendingAssets.push(combinedAssetId);
        cs.modularConfigsIndices[collectionId][tier][tokenId].pendingAssetIndices[combinedAssetId] = config.pendingAssets.length;
        config.lastUpdateTime = block.timestamp;
        
        emit AssetsCombined(collectionId, tier, tokenId, combinedAssetId, sourceAssetIds, combinationType);
        
        return combinedAssetId;
    }
    
    function separateCombination(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        uint64 combinedAssetId
    ) external whenNotPaused validCollection(collectionId) {
        
        ModularHelper.validateTokenInCollectionTier(collectionId, tier, tokenId);
        ModularHelper.validateTokenController(collectionId, tokenId, msg.sender);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!_isCombinedAsset(combinedAssetId)) {
            revert CombinationNotFound(combinedAssetId);
        }
        
        if (_isAssetPending(collectionId, tier, tokenId, combinedAssetId)) {
            _removeFromPendingAssets(collectionId, tier, tokenId, combinedAssetId);
        }
        if (_isAssetAccepted(collectionId, tier, tokenId, combinedAssetId)) {
            _removeFromAcceptedAssets(collectionId, tier, tokenId, combinedAssetId);
        }
        
        delete cs.assetCombinations[combinedAssetId];
        delete cs.assetRegistry[combinedAssetId];
        delete cs.assetExists[combinedAssetId];
        
        _removeFromAssetIds(combinedAssetId);
        
        cs.modularConfigsData[collectionId][tier][tokenId].lastUpdateTime = block.timestamp;
        
        emit CombinationSeparated(collectionId, tier, tokenId, combinedAssetId);
    }
    
    function setAssetContext(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        uint64 assetId,
        bytes32 context
    ) external whenNotPaused validCollection(collectionId) {
        
        ModularHelper.validateTokenInCollectionTier(collectionId, tier, tokenId);
        ModularHelper.validateTokenController(collectionId, tokenId, msg.sender);
        
        if (!_isAssetAccepted(collectionId, tier, tokenId, assetId)) {
            revert AssetNotAccepted(tokenId, assetId);
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        cs.contextAssetMapping[tokenId][context] = assetId;
        
        bool contextExists = false;
        bytes32[] storage contexts = cs.tokenRenderingContexts[tokenId];
        
        for (uint256 i = 0; i < contexts.length; i++) {
            if (contexts[i] == context) {
                contextExists = true;
                break;
            }
        }
        
        if (!contextExists) {
            contexts.push(context);
        }
        
        cs.modularConfigsData[collectionId][tier][tokenId].lastUpdateTime = block.timestamp;
        
        emit AssetContextSet(collectionId, tier, tokenId, assetId, context);
    }

    function batchAcceptAssets(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        uint64[] calldata assetIds
    ) external whenNotPaused validCollection(collectionId) {
        
        if (assetIds.length == 0 || assetIds.length > 20) {
            revert ModularHelper.InvalidAssetData();
        }
        
        for (uint256 i = 0; i < assetIds.length; i++) {
            this.acceptAsset(collectionId, tier, tokenId, assetIds[i]);
        }
    }

    function batchRejectAssets(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        uint64[] calldata assetIds
    ) external whenNotPaused validCollection(collectionId) {
        
        if (assetIds.length == 0 || assetIds.length > 20) {
            revert ModularHelper.InvalidAssetData();
        }
        
        for (uint256 i = 0; i < assetIds.length; i++) {
            this.rejectAsset(collectionId, tier, tokenId, assetIds[i]);
        }
    }
    
    function getAssetMetadata(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        uint64 assetId
    ) external view validCollection(collectionId) returns (string memory) {
        ModularHelper.validateTokenInCollectionTier(collectionId, tier, tokenId);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!cs.assetExists[assetId]) {
            revert ModularHelper.AssetNotFound(assetId);
        }
        
        return cs.assetRegistry[assetId].assetUri;
    }
    
    function getAcceptedAssets(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId
    ) external view validCollection(collectionId) returns (uint64[] memory) {
        ModularHelper.validateTokenInCollectionTier(collectionId, tier, tokenId);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        return cs.modularConfigsData[collectionId][tier][tokenId].acceptedAssets;
    }
    
    function getPendingAssets(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId
    ) external view validCollection(collectionId) returns (uint64[] memory) {
        ModularHelper.validateTokenInCollectionTier(collectionId, tier, tokenId);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        return cs.modularConfigsData[collectionId][tier][tokenId].pendingAssets;
    }
    
    function getActiveAsset(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId
    ) external view validCollection(collectionId) returns (uint64) {
        ModularHelper.validateTokenInCollectionTier(collectionId, tier, tokenId);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        return cs.modularConfigsData[collectionId][tier][tokenId].activeAssetId;
    }

    function getAssetSummary(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId
    ) external view validCollection(collectionId) returns (
        uint64[] memory pendingAssets,
        uint64[] memory acceptedAssets,
        uint64 activeAssetId,
        uint256 lastUpdateTime,
        uint256 maxAssetsLimit
    ) {
        ModularHelper.validateTokenInCollectionTier(collectionId, tier, tokenId);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        ModularConfigData storage config = cs.modularConfigsData[collectionId][tier][tokenId];
        
        return (
            config.pendingAssets,
            config.acceptedAssets,
            config.activeAssetId,
            config.lastUpdateTime,
            _getMaxAssetsPerToken(collectionId)
        );
    }
    
    function getAssetForContext(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        bytes32 context
    ) external view validCollection(collectionId) returns (uint64) {
        ModularHelper.validateTokenInCollectionTier(collectionId, tier, tokenId);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint64 contextAsset = cs.contextAssetMapping[tokenId][context];
        if (contextAsset != 0) {
            return contextAsset;
        }
        
        return cs.modularConfigsData[collectionId][tier][tokenId].activeAssetId;
    }
    
    function getTokenContexts(uint256 tokenId) external view returns (bytes32[] memory) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        return cs.tokenRenderingContexts[tokenId];
    }
    
    function getCombinedAsset(uint64 combinedAssetId) external view returns (AssetCombination memory combination) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!_isCombinedAsset(combinedAssetId)) {
            revert CombinationNotFound(combinedAssetId);
        }
        
        return cs.assetCombinations[combinedAssetId];
    }
    
    function getAssetReplacements(uint256 tokenId, uint64 assetId) external view returns (uint64) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        return cs.assetReplacements[tokenId][assetId];
    }
    
    function getAllAssets() external view returns (uint64[] memory) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        return cs.assetIds;
    }
    
    function getAsset(uint64 assetId) external view returns (
        string memory assetUri,
        string memory mediaType,
        bool replaceable,
        uint256 registrationTime
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!cs.assetExists[assetId]) {
            revert ModularHelper.AssetNotFound(assetId);
        }
        
        TokenAsset storage asset = cs.assetRegistry[assetId];
        return (asset.assetUri, asset.mediaType, asset.replaceable, asset.registrationTime);
    }
    
    function isMultiAssetEnabled(uint256 collectionId) external view returns (bool) {
        if (!LibCollectionStorage.collectionExists(collectionId)) {
            return false;
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (LibCollectionStorage.isInternalCollection(collectionId)) {
            return cs.collections[collectionId].enabled && cs.collections[collectionId].multiAssetEnabled;
        } else {
            return cs.externalCollections[collectionId].enabled;
        }
    }

    function _validateMultiAssetCapability(uint256 collectionId) internal view {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (LibCollectionStorage.isInternalCollection(collectionId)) {
            if (!cs.collections[collectionId].multiAssetEnabled) {
                revert ModularHelper.MultiAssetNotEnabled(collectionId);
            }
        } else if (LibCollectionStorage.isExternalCollection(collectionId)) {
            if (!cs.externalCollections[collectionId].enabled) {
                revert ModularHelper.MultiAssetNotEnabled(collectionId);
            }
        } else {
            revert ModularHelper.CollectionNotFound(collectionId);
        }
    }

    function _getMaxAssetsPerToken(uint256 collectionId) internal view returns (uint16) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (LibCollectionStorage.isInternalCollection(collectionId)) {
            return cs.collections[collectionId].maxAssetsPerToken;
        } else {
            return 50;
        }
    }

    function _validateAcceptedAssets(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        uint64[] calldata assetIds
    ) internal view {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        ModularConfigIndices storage indices = cs.modularConfigsIndices[collectionId][tier][tokenId];
        
        for (uint256 i = 0; i < assetIds.length; i++) {
            if (!cs.assetExists[assetIds[i]]) {
                revert ModularHelper.AssetNotFound(assetIds[i]);
            }
            
            if (indices.acceptedAssetIndices[assetIds[i]] == 0) {
                revert("Asset not accepted for token");
            }
        }
    }

    function _addToAcceptedAssets(uint256 collectionId, uint8 tier, uint256 tokenId, uint64 assetId) internal {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        ModularConfigData storage config = cs.modularConfigsData[collectionId][tier][tokenId];
        ModularConfigIndices storage indices = cs.modularConfigsIndices[collectionId][tier][tokenId];
        
        config.acceptedAssets.push(assetId);
        indices.acceptedAssetIndices[assetId] = config.acceptedAssets.length;
    }

    function _removeFromPendingAssets(uint256 collectionId, uint8 tier, uint256 tokenId, uint64 assetId) internal {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        ModularConfigData storage config = cs.modularConfigsData[collectionId][tier][tokenId];
        ModularConfigIndices storage indices = cs.modularConfigsIndices[collectionId][tier][tokenId];
        
        uint256 index = indices.pendingAssetIndices[assetId];
        if (index == 0) return;
        
        index -= 1;
        uint256 lastIndex = config.pendingAssets.length - 1;
        
        if (index < lastIndex) {
            uint64 lastAssetId = config.pendingAssets[lastIndex];
            config.pendingAssets[index] = lastAssetId;
            indices.pendingAssetIndices[lastAssetId] = index + 1;
        }
        
        config.pendingAssets.pop();
        delete indices.pendingAssetIndices[assetId];
    }

    function _removeFromAcceptedAssets(uint256 collectionId, uint8 tier, uint256 tokenId, uint64 assetId) internal {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        ModularConfigData storage config = cs.modularConfigsData[collectionId][tier][tokenId];
        ModularConfigIndices storage indices = cs.modularConfigsIndices[collectionId][tier][tokenId];
        
        uint256 index = indices.acceptedAssetIndices[assetId];
        if (index == 0) return;
        
        index -= 1;
        uint256 lastIndex = config.acceptedAssets.length - 1;
        
        if (index < lastIndex) {
            uint64 lastAssetId = config.acceptedAssets[lastIndex];
            config.acceptedAssets[index] = lastAssetId;
            indices.acceptedAssetIndices[lastAssetId] = index + 1;
        }
        
        config.acceptedAssets.pop();
        delete indices.acceptedAssetIndices[assetId];
    }

    function _updateAssetPriorities(uint256 collectionId, uint8 tier, uint256 tokenId, uint64[] calldata priorities) internal {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        ModularConfigData storage config = cs.modularConfigsData[collectionId][tier][tokenId];
        ModularConfigIndices storage indices = cs.modularConfigsIndices[collectionId][tier][tokenId];
        
        delete config.acceptedAssets;
        
        for (uint256 i = 0; i < priorities.length; i++) {
            config.acceptedAssets.push(priorities[i]);
            indices.acceptedAssetIndices[priorities[i]] = i + 1;
        }
    }

    function _cleanupAssetReplacement(uint256 tokenId, uint64 assetId) internal {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        delete cs.assetReplacements[tokenId][assetId];
    }

    function _removeFromAssetIds(uint64 assetId) internal {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint64[] storage assetIds = cs.assetIds;
        for (uint256 i = 0; i < assetIds.length; i++) {
            if (assetIds[i] == assetId) {
                assetIds[i] = assetIds[assetIds.length - 1];
                assetIds.pop();
                break;
            }
        }
    }

    function _isAssetPending(uint256 collectionId, uint8 tier, uint256 tokenId, uint64 assetId) internal view returns (bool) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        ModularConfigIndices storage indices = cs.modularConfigsIndices[collectionId][tier][tokenId];
        return indices.pendingAssetIndices[assetId] != 0;
    }

    function _isAssetAccepted(uint256 collectionId, uint8 tier, uint256 tokenId, uint64 assetId) internal view returns (bool) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        ModularConfigIndices storage indices = cs.modularConfigsIndices[collectionId][tier][tokenId];
        return indices.acceptedAssetIndices[assetId] != 0;
    }

    function _isCombinedAsset(uint64 assetId) internal view returns (bool) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        return cs.assetCombinations[assetId].combinedAssetId != 0;
    }

    function _buildCombinedURI(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        uint64[] calldata sourceAssetIds,
        uint8 combinationType
    ) internal view returns (string memory) {
        string memory baseURI = ModularHelper.getSmartBaseURI();
        
        return string.concat(
            baseURI,
            "combine/",
            collectionId.toString(),
            "/",
            tier.toString(),
            "/",
            tokenId.toString(),
            "?assets=",
            _encodeAssetIds(sourceAssetIds),
            "&type=",
            uint256(combinationType).toString()
        );
    }

    function _encodeAssetIds(uint64[] calldata assetIds) internal pure returns (string memory) {
        if (assetIds.length == 0) return "";
        
        string memory result = assetIds[0].toString();
        for (uint256 i = 1; i < assetIds.length; i++) {
            result = string.concat(result, ",", assetIds[i].toString());
        }
        return result;
    }
}