// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibMeta} from "../shared/libraries/LibMeta.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {LibCollectionStorage} from "../libraries/LibCollectionStorage.sol";
import {ModularConfigData, ModularConfigIndices, TokenAsset, EquippablePart, CompositionRequest, CompositionLayer, CrossCollectionPermission, LayerBlendMode} from "../libraries/ModularAssetModel.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {AccessControlBase} from "./AccessControlBase.sol";

/**
 * @title CompositionFacet
 * @notice Advanced composition engine for cross-collection RMRK 2.0 compatible NFT composition
 * @dev Enables complex multi-collection compositions with granular access control
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract CompositionFacet is AccessControlBase {
    using Strings for uint256;
    using Strings for uint64;
    
    // ==================== ENUMS & STRUCTS ====================
    
    enum CompositionType {
        Static,         // Fixed composition, immutable once created
        Dynamic,        // Can be modified by authorized parties  
        Conditional,    // Changes based on conditions (time, stats, etc.)
        Interactive     // Changes based on user interactions
    }
    
    struct CompositionMetadata {
        string name;
        string description;
        string[] attributes;
        string externalUrl;
        string animationUrl;
        bytes32[] tags;
        uint256 complexity;            // Computational complexity score
    }
    
    // ==================== EVENTS ====================
    
    event CompositionCreated(
        uint256 indexed targetCollectionId,
        uint256 indexed targetTokenId,
        bytes32 indexed compositionId,
        address requester,
        uint256 layerCount
    );
    
    event CompositionUpdated(
        bytes32 indexed compositionId,
        address indexed updater,
        uint256 layerCount,
        string changeReason
    );
    
    event CompositionRendered(
        bytes32 indexed compositionId,
        string outputFormat,
        string resultUri,
        uint256 renderTime
    );
    
    event LayerAdded(
        bytes32 indexed compositionId,
        uint256 indexed layerIndex,
        uint256 sourceCollectionId,
        uint256 sourceTokenId,
        uint64 sourceAssetId
    );
    
    event LayerRemoved(
        bytes32 indexed compositionId,
        uint256 indexed layerIndex,
        string removalReason
    );
    
    event LayerModified(
        bytes32 indexed compositionId,
        uint256 indexed layerIndex,
        address mod,
        bytes32 modificationType
    );
    
    event CrossCollectionPermissionGranted(
        address indexed authorizedCollection,
        address indexed targetCollection,
        uint256 permissionLevel,
        address indexed grantor
    );
    
    event CrossCollectionPermissionRevoked(
        address indexed authorizedCollection,
        address indexed targetCollection,
        address indexed revoker
    );
    
    event CompositionCacheUpdated(
        bytes32 indexed compositionId,
        bytes32 indexed contextHash,
        string cacheUri
    );
    
    // ==================== ERRORS ====================
    
    error CompositionNotFound(bytes32 compositionId);
    error LayerNotFound(uint256 layerIndex);
    error UnauthorizedComposition(address requester, uint256 collectionId);
    error UnauthorizedCrossCollection(address sourceCollection, address targetCollection);
    error InvalidCompositionData();
    error CompositionLocked(bytes32 compositionId);
    error MaxLayersExceeded(uint256 maxLayers);
    error InvalidLayerConfiguration(uint256 layerIndex);
    error CircularCompositionDetected(bytes32 compositionId);
    error IncompatibleCollections(uint256 sourceCollection, uint256 targetCollection);
    error CompositionComplexityExceeded(uint256 complexity, uint256 maxComplexity);
    error PermissionExpired(address collection, uint256 expirationTime);
    error InvalidOutputFormat(string format);
    error RenderingFailed(bytes32 compositionId, string reason);

    
    // ==================== CONSTANTS ====================
    
    uint256 private constant MAX_LAYERS_PER_COMPOSITION = 50;
    uint256 private constant MAX_COMPOSITION_COMPLEXITY = 1000;
    uint256 private constant CACHE_DURATION = 24 hours;
    uint256 private constant DEFAULT_PERMISSION_DURATION = 30 days;
    
    // ==================== MODIFIERS ====================
    
    /**
     * @notice Ensures caller has permission to modify compositions for specific token
     * @param collectionId Collection identifier  
     * @param tokenId Token identifier
     */
    modifier canControlToken(uint256 collectionId, uint256 tokenId) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        (address collectionAddress, , bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (!exists) {
            revert CollectionNotFound(collectionId);
        }
        
        AccessHelper.requireTokenAccess(collectionAddress, tokenId);
        _;
    }
    
    // ==================== CORE COMPOSITION FUNCTIONS ====================
    
    /**
     * @notice Create a new composition from multiple sources
     * @param request Complete composition request data
     * @return compositionId Unique identifier for the created composition
     */
    function createComposition(
        CompositionRequest calldata request
    ) external whenNotPaused nonReentrant canControlToken(request.targetCollectionId, request.targetTokenId) returns (bytes32 compositionId) {
        
        // Validate request
        _validateCompositionRequest(request);
        
        // Validate cross-collection permissions for all layers
        _validateCrossCollectionPermissions(request.layers, request.targetCollectionId);
        
        // Check composition complexity
        uint256 complexity = _calculateCompositionComplexity(request.layers);
        if (complexity > MAX_COMPOSITION_COMPLEXITY) {
            revert CompositionComplexityExceeded(complexity, MAX_COMPOSITION_COMPLEXITY);
        }
        
        // Generate unique composition ID
        compositionId = _generateCompositionId(request);
        
        // Check for circular composition dependencies
        _validateNoCircularDependencies(compositionId, request.layers);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Store composition request
        cs.storedCompositions[compositionId] = request;
        
        // Store composition layers with optimization
        CompositionLayer[] storage storedLayers = cs.compositionLayers[compositionId];
        for (uint256 i = 0; i < request.layers.length; i++) {
            storedLayers.push(request.layers[i]);
        }
        
        // Update composition tracking
        cs.tokenCompositions[request.targetCollectionId][request.targetTokenId].push(compositionId);
        cs.compositionExists[compositionId] = true;
        cs.compositionCount[request.targetCollectionId][request.targetTokenId]++;
        
        // Emit creation event
        emit CompositionCreated(
            request.targetCollectionId,
            request.targetTokenId,
            compositionId,
            request.requester,
            request.layers.length
        );
        
        return compositionId;
    }
    
    /**
     * @notice Update existing composition with new layers or modifications
     * @param compositionId Composition to update
     * @param newLayers New layer configuration
     * @param changeReason Reason for the change
     */
    function updateComposition(
        bytes32 compositionId,
        CompositionLayer[] calldata newLayers,
        string calldata changeReason
    ) external whenNotPaused nonReentrant {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!cs.compositionExists[compositionId]) {
            revert CompositionNotFound(compositionId);
        }
        
        CompositionRequest storage composition = cs.storedCompositions[compositionId];
        
        // Check authorization
        _checkCompositionAuthorization(
            composition.targetCollectionId,
            composition.targetTokenId,
            LibMeta.msgSender()
        );
        
        // Check if composition allows modifications
        if (composition.compositionType == 0) { // Static
            revert CompositionLocked(compositionId);
        }
        
        // Validate new layers
        if (newLayers.length > MAX_LAYERS_PER_COMPOSITION) {
            revert MaxLayersExceeded(MAX_LAYERS_PER_COMPOSITION);
        }
        
        // Validate cross-collection permissions for new layers
        _validateCrossCollectionPermissions(newLayers, composition.targetCollectionId);
        
        // Clear existing layers
        delete cs.compositionLayers[compositionId];
        
        // Add new layers
        CompositionLayer[] storage storedLayers = cs.compositionLayers[compositionId];
        for (uint256 i = 0; i < newLayers.length; i++) {
            storedLayers.push(newLayers[i]);
        }
        
        // Clear cache as composition has changed
        _clearCompositionCache(compositionId);
        
        emit CompositionUpdated(compositionId, LibMeta.msgSender(), newLayers.length, changeReason);
    }
    
    /**
     * @notice Add a single layer to existing composition
     * @param compositionId Target composition
     * @param layer Layer to add
     * @param insertIndex Position to insert (type(uint256).max for append)
     */
    function addLayer(
        bytes32 compositionId,
        CompositionLayer calldata layer,
        uint256 insertIndex
    ) external whenNotPaused nonReentrant {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!cs.compositionExists[compositionId]) {
            revert CompositionNotFound(compositionId);
        }
        
        CompositionRequest storage composition = cs.storedCompositions[compositionId];
        
        // Check authorization
        _checkCompositionAuthorization(
            composition.targetCollectionId,
            composition.targetTokenId,
            LibMeta.msgSender()
        );
        
        // Check if composition allows modifications
        if (composition.compositionType == 0) { // Static
            revert CompositionLocked(compositionId);
        }
        
        CompositionLayer[] storage layers = cs.compositionLayers[compositionId];
        
        // Check layer limit
        if (layers.length >= MAX_LAYERS_PER_COMPOSITION) {
            revert MaxLayersExceeded(MAX_LAYERS_PER_COMPOSITION);
        }
        
        // Validate layer
        _validateLayer(layer, composition.targetCollectionId);
        
        // Insert layer at specified position
        if (insertIndex == type(uint256).max || insertIndex >= layers.length) {
            layers.push(layer);
            insertIndex = layers.length - 1;
        } else {
            layers.push(); // Add empty slot
            // Shift elements to make space
            for (uint256 i = layers.length - 1; i > insertIndex; i--) {
                layers[i] = layers[i - 1];
            }
            layers[insertIndex] = layer;
        }
        
        // Clear cache
        _clearCompositionCache(compositionId);
        
        emit LayerAdded(
            compositionId,
            insertIndex,
            layer.sourceCollectionId,
            layer.sourceTokenId,
            layer.sourceAssetId
        );
    }
    
    /**
     * @notice Remove layer from composition
     * @param compositionId Target composition
     * @param layerIndex Index of layer to remove
     * @param removalReason Reason for removal
     */
    function removeLayer(
        bytes32 compositionId,
        uint256 layerIndex,
        string calldata removalReason
    ) external whenNotPaused nonReentrant {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!cs.compositionExists[compositionId]) {
            revert CompositionNotFound(compositionId);
        }
        
        CompositionRequest storage composition = cs.storedCompositions[compositionId];
        
        // Check authorization
        _checkCompositionAuthorization(
            composition.targetCollectionId,
            composition.targetTokenId,
            LibMeta.msgSender()
        );
        
        // Check if composition allows modifications
        if (composition.compositionType == 0) { // Static
            revert CompositionLocked(compositionId);
        }
        
        CompositionLayer[] storage layers = cs.compositionLayers[compositionId];
        
        if (layerIndex >= layers.length) {
            revert LayerNotFound(layerIndex);
        }
        
        // Remove layer by shifting elements
        for (uint256 i = layerIndex; i < layers.length - 1; i++) {
            layers[i] = layers[i + 1];
        }
        layers.pop();
        
        // Clear cache
        _clearCompositionCache(compositionId);
        
        emit LayerRemoved(compositionId, layerIndex, removalReason);
    }
    
    // ==================== CROSS-COLLECTION PERMISSION MANAGEMENT ====================
    
    /**
     * @notice Grant permission for cross-collection composition
     * @param authorizedCollection Collection that gets permission
     * @param targetCollection Collection that can be composed
     * @param permissionLevel Level of permission (1=Read, 2=Compose, 3=Modify)
     * @param duration Permission duration in seconds (0 = permanent)
     */
    function grantCrossCollectionPermission(
        address authorizedCollection,
        address targetCollection,
        uint256 permissionLevel,
        uint256 duration
    ) external onlyAuthorized whenNotPaused {
        
        if (permissionLevel > 3) {
            revert InvalidCompositionData();
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        bytes32 permissionKey = keccak256(abi.encodePacked(authorizedCollection, targetCollection));
        
        uint256 expirationTime = duration == 0 ? 0 : block.timestamp + duration;
        
        cs.crossCollectionPermissions[permissionKey] = CrossCollectionPermission({
            authorizedCollection: authorizedCollection,
            targetCollection: targetCollection,
            allowedOperations: new bytes32[](0), // Will be expanded in future versions
            permissionLevel: permissionLevel,
            expirationTime: expirationTime,
            active: true
        });
        
        emit CrossCollectionPermissionGranted(
            authorizedCollection,
            targetCollection,
            permissionLevel,
            LibMeta.msgSender()
        );
    }
    
    /**
     * @notice Revoke cross-collection permission
     * @param authorizedCollection Collection to revoke permission from
     * @param targetCollection Target collection
     */
    function revokeCrossCollectionPermission(
        address authorizedCollection,
        address targetCollection
    ) external onlyAuthorized whenNotPaused {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        bytes32 permissionKey = keccak256(abi.encodePacked(authorizedCollection, targetCollection));
        
        cs.crossCollectionPermissions[permissionKey].active = false;
        
        emit CrossCollectionPermissionRevoked(authorizedCollection, targetCollection, LibMeta.msgSender());
    }
    
    // ==================== COMPOSITION RENDERING ====================
    
    /**
     * @notice Render composition to specified format
     * @param compositionId Composition to render
     * @param outputFormat Desired output format
     * @param forceRerender Whether to bypass cache
     * @return resultUri URI of rendered composition
     */
    function renderComposition(
        bytes32 compositionId,
        string calldata outputFormat,
        bool forceRerender
    ) external view returns (string memory resultUri) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!cs.compositionExists[compositionId]) {
            revert CompositionNotFound(compositionId);
        }
        
        // Check cache first (if not forcing rerender)
        if (!forceRerender) {
            bytes32 cacheKey = keccak256(abi.encodePacked(compositionId, outputFormat));
            string memory cachedUri = cs.compositionCache[cacheKey];
            if (bytes(cachedUri).length > 0) {
                return cachedUri;
            }
        }
        
        // Validate output format
        if (!_isValidOutputFormat(outputFormat)) {
            revert InvalidOutputFormat(outputFormat);
        }
        
        CompositionRequest storage composition = cs.storedCompositions[compositionId];
        CompositionLayer[] storage layers = cs.compositionLayers[compositionId];
        
        // Build result URI based on format
        resultUri = _buildCompositionUri(composition, layers, outputFormat);
        
        return resultUri;
    }
    
    /**
     * @notice Get composition metadata with calculated attributes
     * @param compositionId Composition identifier
     * @return metadata Complete composition metadata
     */
    function getCompositionMetadata(
        bytes32 compositionId
    ) external view returns (CompositionMetadata memory metadata) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!cs.compositionExists[compositionId]) {
            revert CompositionNotFound(compositionId);
        }
        
        CompositionRequest storage composition = cs.storedCompositions[compositionId];
        CompositionLayer[] storage layers = cs.compositionLayers[compositionId];
        
        // Calculate composition complexity
        uint256 complexity = _calculateCompositionComplexity(layers);
        
        // Build metadata
        metadata = CompositionMetadata({
            name: _generateCompositionName(composition, layers),
            description: _generateCompositionDescription(composition, layers),
            attributes: _generateCompositionAttributes(composition, layers),
            externalUrl: _generateExternalUrl(compositionId),
            animationUrl: _generateAnimationUrl(compositionId),
            tags: _generateCompositionTags(layers),
            complexity: complexity
        });
        
        return metadata;
    }
    
    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @notice Get composition details
     * @param compositionId Composition identifier
     * @return request Original composition request
     * @return layers Current layer configuration
     * @return active Whether composition is currently active
     */
    function getComposition(bytes32 compositionId) external view returns (
        CompositionRequest memory request,
        CompositionLayer[] memory layers,
        bool active
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!cs.compositionExists[compositionId]) {
            revert CompositionNotFound(compositionId);
        }
        
        request = cs.storedCompositions[compositionId];
        layers = cs.compositionLayers[compositionId];
        active = cs.compositionExists[compositionId];
        
        return (request, layers, active);
    }
    
    /**
     * @notice Get all compositions for a token
     * @param collectionId Collection identifier
     * @param tokenId Token identifier
     * @return compositionIds Array of composition IDs
     */
    function getTokenCompositions(
        uint256 collectionId,
        uint256 tokenId
    ) external view returns (bytes32[] memory compositionIds) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        return cs.tokenCompositions[collectionId][tokenId];
    }
    
    /**
     * @notice Check cross-collection permission
     * @param authorizedCollection Collection requesting permission
     * @param targetCollection Target collection
     * @return hasPermission Whether permission exists
     * @return permissionLevel Level of permission
     * @return expirationTime When permission expires
     */
    function checkCrossCollectionPermission(
        address authorizedCollection,
        address targetCollection
    ) external view returns (
        bool hasPermission,
        uint256 permissionLevel,
        uint256 expirationTime
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        bytes32 permissionKey = keccak256(abi.encodePacked(authorizedCollection, targetCollection));
        CrossCollectionPermission storage permission = cs.crossCollectionPermissions[permissionKey];
        
        hasPermission = permission.active && 
                       (permission.expirationTime == 0 || block.timestamp < permission.expirationTime);
        permissionLevel = permission.permissionLevel;
        expirationTime = permission.expirationTime;
        
        return (hasPermission, permissionLevel, expirationTime);
    }
    
    // ==================== INTERNAL FUNCTIONS ====================
    
    function _validateCompositionRequest(CompositionRequest calldata request) internal view {
        if (request.targetCollectionId == 0) revert InvalidCompositionData();
        if (request.targetTokenId == 0) revert InvalidCompositionData();
        if (request.layers.length == 0) revert InvalidCompositionData();
        if (request.layers.length > MAX_LAYERS_PER_COMPOSITION) {
            revert MaxLayersExceeded(MAX_LAYERS_PER_COMPOSITION);
        }
        if (bytes(request.outputFormat).length == 0) revert InvalidCompositionData();
        
        // Validate target collection exists in unified system
        if (!LibCollectionStorage.collectionExists(request.targetCollectionId)) {
            revert CollectionNotFound(request.targetCollectionId);
        }
    }
    
    function _checkCompositionAuthorization(
        uint256 collectionId,
        uint256,
        address requester
    ) internal view {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Check if collection exists in unified system
        if (!LibCollectionStorage.collectionExists(collectionId)) {
            revert CollectionNotFound(collectionId);
        }
        
        // Check if requester has operator privileges or is contract owner
        if (requester != cs.contractOwner && !cs.operators[requester]) {
            // Additional checks for external system authorization could go here
            revert UnauthorizedComposition(requester, collectionId);
        }
    }
    
    function _validateCrossCollectionPermissions(
        CompositionLayer[] calldata layers,
        uint256 targetCollectionId
    ) internal view {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        for (uint256 i = 0; i < layers.length; i++) {
            if (layers[i].sourceCollectionId != targetCollectionId) {
                // Cross-collection layer, check permissions
                (address sourceCollection, , bool sourceExists) = LibCollectionStorage.getCollectionInfo(layers[i].sourceCollectionId);
                (address targetCollection, , bool targetExists) = LibCollectionStorage.getCollectionInfo(targetCollectionId);
                
                if (!sourceExists) {
                    revert CollectionNotFound(layers[i].sourceCollectionId);
                }
                if (!targetExists) {
                    revert CollectionNotFound(targetCollectionId);
                }
                
                bytes32 permissionKey = keccak256(abi.encodePacked(targetCollection, sourceCollection));
                CrossCollectionPermission storage permission = cs.crossCollectionPermissions[permissionKey];
                
                if (!permission.active || permission.permissionLevel < 2) {
                    revert UnauthorizedCrossCollection(sourceCollection, targetCollection);
                }
                
                if (permission.expirationTime != 0 && block.timestamp >= permission.expirationTime) {
                    revert PermissionExpired(sourceCollection, permission.expirationTime);
                }
            }
        }
    }
    
    function _validateLayer(
        CompositionLayer calldata layer,
        uint256 targetCollectionId
    ) internal view {
        if (layer.sourceCollectionId == 0) revert InvalidLayerConfiguration(0);
        
        // Validate source collection exists in unified system
        if (!LibCollectionStorage.collectionExists(layer.sourceCollectionId)) {
            revert InvalidLayerConfiguration(layer.sourceCollectionId);
        }
        
        // If cross-collection, validate permission
        if (layer.sourceCollectionId != targetCollectionId) {
            LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
            
            (address sourceCollection, , ) = LibCollectionStorage.getCollectionInfo(layer.sourceCollectionId);
            (address targetCollection, , ) = LibCollectionStorage.getCollectionInfo(targetCollectionId);
            
            bytes32 permissionKey = keccak256(abi.encodePacked(targetCollection, sourceCollection));
            CrossCollectionPermission storage permission = cs.crossCollectionPermissions[permissionKey];
            
            if (!permission.active || permission.permissionLevel < 2) {
                revert UnauthorizedCrossCollection(sourceCollection, targetCollection);
            }
        }
    }
    
    function _calculateCompositionComplexity(
        CompositionLayer[] memory layers
    ) internal pure returns (uint256 complexity) {
        complexity = layers.length * 10; // Base complexity per layer
        
        for (uint256 i = 0; i < layers.length; i++) {
            // Add complexity based on layer type and features
            if (layers[i].blendMode != LayerBlendMode.Normal) {
                complexity += 5; // Blend modes add complexity
            }
            
            if (layers[i].compositionData.length > 0) {
                complexity += layers[i].compositionData.length / 32; // Data complexity
            }
            
            if (layers[i].deactivationTime > 0) {
                complexity += 3; // Conditional layers add complexity
            }
        }
        
        return complexity;
    }
    
    function _generateCompositionId(
        CompositionRequest calldata request
    ) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(
            request.targetCollectionId,
            request.targetTokenId,
            request.requester,
            request.requestTime,
            block.timestamp,
            block.prevrandao
        ));
    }
    
    function _validateNoCircularDependencies(
        bytes32 compositionId,
        CompositionLayer[] calldata layers
    ) internal view {
        // Implementation would check for circular references in compositions
        // This is a placeholder - full implementation would traverse dependency graph
        for (uint256 i = 0; i < layers.length; i++) {
            // Basic check - a composition cannot reference itself
            LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
            bytes32[] memory existingCompositions = cs.tokenCompositions[layers[i].sourceCollectionId][layers[i].sourceTokenId];
            
            for (uint256 j = 0; j < existingCompositions.length; j++) {
                if (existingCompositions[j] == compositionId) {
                    revert CircularCompositionDetected(compositionId);
                }
            }
        }
    }
    
    function _clearCompositionCache(bytes32 compositionId) internal {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Clear all cached formats for this composition
        string[4] memory formats = ["png", "svg", "json", "metadata"];
        
        for (uint256 i = 0; i < formats.length; i++) {
            bytes32 cacheKey = keccak256(abi.encodePacked(compositionId, formats[i]));
            delete cs.compositionCache[cacheKey];
        }
    }
    
    function _isValidOutputFormat(string calldata format) internal pure returns (bool) {
        bytes32 formatHash = keccak256(bytes(format));
        return formatHash == keccak256("png") ||
               formatHash == keccak256("svg") ||
               formatHash == keccak256("json") ||
               formatHash == keccak256("metadata");
    }
    
    function _buildCompositionUri(
        CompositionRequest storage composition,
        CompositionLayer[] storage layers,
        string calldata outputFormat
    ) internal view returns (string memory) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();

        // Get base URI using unified collection system
        (, , bool exists) = LibCollectionStorage.getCollectionInfo(composition.targetCollectionId);
        if (!exists) {
            revert CollectionNotFound(composition.targetCollectionId);
        }

        string memory baseUri;
        if (LibCollectionStorage.isInternalCollection(composition.targetCollectionId)) {
            baseUri = cs.collections[composition.targetCollectionId].baseURI;
        } else {
            // For external collections, use system treasury base URI
            baseUri = cs.systemTreasury.treasuryAddress != address(0) ? 
                "https://api.zico.network/" : "https://localhost:3000/";
        }

        return string.concat(
            baseUri,
            "compose/",
            composition.targetCollectionId.toString(),
            "/",
            composition.targetTokenId.toString(),
            ".",
            outputFormat,
            "?layers=",
            layers.length.toString(),
            "&complexity=",
            _calculateCompositionComplexity(layers).toString()
        );
    }
    
    // Placeholder functions for metadata generation - would be fully implemented
    function _generateCompositionName(
        CompositionRequest storage,
        CompositionLayer[] storage layers
    ) internal view returns (string memory) {
        return string.concat("Composed NFT with ", layers.length.toString(), " layers");
    }
    
    function _generateCompositionDescription(
        CompositionRequest storage,
       CompositionLayer[] storage layers
    ) internal view returns (string memory) {
        return string.concat("A composed NFT featuring ", layers.length.toString(), " unique layers from multiple collections");
    }
    
    function _generateCompositionAttributes(
        CompositionRequest storage,
        CompositionLayer[] storage layers
    ) internal view returns (string[] memory) {
        string[] memory attributes = new string[](2);
        attributes[0] = string.concat("Layer Count: ", layers.length.toString());
        attributes[1] = string.concat("Composition Type: ", "Dynamic");
        return attributes;
    }
    
    function _generateExternalUrl(bytes32 compositionId) internal view returns (string memory) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        CompositionRequest storage request = cs.storedCompositions[compositionId];
        
        (, , bool exists) = LibCollectionStorage.getCollectionInfo(request.targetCollectionId);
        if (!exists) {
            return "";
        }
        
        string memory baseURI;
        if (LibCollectionStorage.isInternalCollection(request.targetCollectionId)) {
            baseURI = cs.collections[request.targetCollectionId].baseURI;
        } else {
            baseURI = cs.systemTreasury.treasuryAddress != address(0) ? 
                "https://api.zico.network/" : "https://localhost:3000/";
        }
        
        return string.concat(baseURI, "composition/", uint256(compositionId).toString());
    }
    
    function _generateAnimationUrl(bytes32 compositionId) internal view returns (string memory) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        CompositionRequest storage request = cs.storedCompositions[compositionId];
        
        (, , bool exists) = LibCollectionStorage.getCollectionInfo(request.targetCollectionId);
        if (!exists) {
            return "";
        }
        
        string memory baseURI;
        if (LibCollectionStorage.isInternalCollection(request.targetCollectionId)) {
            baseURI = cs.collections[request.targetCollectionId].baseURI;
        } else {
            baseURI = cs.systemTreasury.treasuryAddress != address(0) ? 
                "https://api.zico.network/" : "https://localhost:3000/";
        }
        
        return string.concat(baseURI, "animation/", uint256(compositionId).toString(), ".mp4");
    }
    
    function _generateCompositionTags(
        CompositionLayer[] storage
    ) internal pure returns (bytes32[] memory) {
        bytes32[] memory tags = new bytes32[](2);
        tags[0] = keccak256("composed");
        tags[1] = keccak256("multi-layer");
        return tags;
    }
}