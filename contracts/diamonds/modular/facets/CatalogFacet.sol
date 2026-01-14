// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {LibCollectionStorage} from "../libraries/LibCollectionStorage.sol";
import {ModularHelper} from "../libraries/ModularHelper.sol";
import {EquippablePart, PartType, ModularConfigData, CatalogAsset, TokenAsset, AssetType} from "../libraries/ModularAssetModel.sol";
import {AccessControlBase} from "./AccessControlBase.sol";

contract CatalogFacet is AccessControlBase {
    using Strings for uint256;
    using Strings for uint64;
    using Strings for uint8;
    
    struct PartCreationData {
        uint64 partId;
        string name;
        PartType partType;
        bytes4 zIndex;
        string metadataURI;
        bool fixedToParent;
    }
    
    event PartAdded(uint64 indexed partId, PartType indexed partType, string name);
    event PartUpdated(uint64 indexed partId, string name);
    event PartRemoved(uint64 indexed partId);
    event EquippableAddressSet(uint64 indexed partId, address indexed equippableAddress, bool allowed);
    event CatalogMetadataSet(string metadataURI);
    event PartBatchAdded(uint64[] partIds, PartType[] partTypes);
    event CatalogAssetAdded(uint256 indexed collectionId, uint8 indexed tier, uint256 indexed tokenId, uint64 assetId, uint64 catalogId, uint64[] selectedParts);
    event CatalogAssetUpdated(uint256 indexed collectionId, uint8 indexed tier, uint256 indexed tokenId, uint64 assetId, uint64[] selectedParts);
    event AssetContextSet(uint256 indexed collectionId, uint8 indexed tier, uint256 indexed tokenId, bytes32 context, uint64 assetId);

    error PartNotFound(uint64 partId);
    error PartAlreadyExists(uint64 partId);
    error CatalogNotFound(uint64 catalogId);
    error InvalidPartData();
    error InvalidPartType();
    error TooManyEquippableAddresses();
    error BatchDataMismatch();
    error MetadataURITooLong();
    error PartNameTooLong();
    
    uint256 private constant MAX_EQUIPPABLE_ADDRESSES = 100;
    uint256 private constant MAX_METADATA_URI_LENGTH = 2000;
    uint256 private constant MAX_PART_NAME_LENGTH = 100;
    uint256 private constant MAX_BATCH_SIZE = 50;
    uint256 private constant MAX_SELECTED_PARTS = 50;
    
    function addPart(
        uint64 partId,
        string calldata name,
        PartType partType,
        bytes4 zIndex,
        string calldata metadataURI,
        bool fixedToParent
    ) external onlyAuthorized whenNotPaused {
        
        _validatePartData(partId, name, partType, metadataURI);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (cs.partExists[partId]) {
            revert PartAlreadyExists(partId);
        }
        
        cs.parts[partId] = EquippablePart({
            id: partId,
            name: name,
            partType: partType,
            zIndex: zIndex,
            equippableAddresses: new address[](0),
            metadataURI: metadataURI,
            fixedToParent: fixedToParent
        });
        
        cs.partExists[partId] = true;
        cs.partIds.push(partId);
        
        emit PartAdded(partId, partType, name);
    }
    
    function setEquippableAddresses(
        uint64 partId,
        address[] calldata equippableAddresses
    ) external onlyAuthorized whenNotPaused {
        
        if (equippableAddresses.length > MAX_EQUIPPABLE_ADDRESSES) {
            revert TooManyEquippableAddresses();
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!cs.partExists[partId]) {
            revert PartNotFound(partId);
        }
        
        EquippablePart storage part = cs.parts[partId];
        
        if (part.partType != PartType.Slot) {
            revert InvalidPartType();
        }
        
        delete part.equippableAddresses;
        
        for (uint256 i = 0; i < equippableAddresses.length; i++) {
            if (equippableAddresses[i] == address(0)) {
                revert ModularHelper.InvalidAssetData();
            }
            part.equippableAddresses.push(equippableAddresses[i]);
            
            emit EquippableAddressSet(partId, equippableAddresses[i], true);
        }
    }
    
    function batchAddParts(
        PartCreationData[] calldata partData
    ) external onlyAuthorized whenNotPaused {
        
        if (partData.length == 0 || partData.length > MAX_BATCH_SIZE) {
            revert BatchDataMismatch();
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint64[] memory partIds = new uint64[](partData.length);
        PartType[] memory partTypes = new PartType[](partData.length);
        
        for (uint256 i = 0; i < partData.length; i++) {
            _validatePartData(partData[i].partId, partData[i].name, partData[i].partType, partData[i].metadataURI);
            
            if (cs.partExists[partData[i].partId]) {
                revert PartAlreadyExists(partData[i].partId);
            }
            
            cs.parts[partData[i].partId] = EquippablePart({
                id: partData[i].partId,
                name: partData[i].name,
                partType: partData[i].partType,
                zIndex: partData[i].zIndex,
                equippableAddresses: new address[](0),
                metadataURI: partData[i].metadataURI,
                fixedToParent: partData[i].fixedToParent
            });
            
            cs.partExists[partData[i].partId] = true;
            cs.partIds.push(partData[i].partId);
            
            partIds[i] = partData[i].partId;
            partTypes[i] = partData[i].partType;
        }
        
        emit PartBatchAdded(partIds, partTypes);
    }
    
    function addCatalogAsset(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        uint64 catalogId,
        uint64[] calldata selectedParts,
        uint64 replacesAssetId
    ) external onlyAuthorized whenNotPaused validCollection(collectionId) {
        
        if (selectedParts.length > MAX_SELECTED_PARTS) {
            revert InvalidPartData();
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        ModularHelper.validateTokenInCollectionTier(collectionId, tier, tokenId);
        
        if (!cs.partExists[catalogId]) {
            revert CatalogNotFound(catalogId);
        }
        
        for (uint256 i = 0; i < selectedParts.length; i++) {
            if (!cs.partExists[selectedParts[i]]) {
                revert PartNotFound(selectedParts[i]);
            }
        }
        
        uint64 assetId = ModularHelper.generateUniqueAssetId(block.timestamp);
        
        cs.catalogAssets[assetId] = CatalogAsset({
            id: assetId,
            catalogId: catalogId,
            selectedParts: selectedParts,
            compositionURI: "",
            assetType: AssetType.Catalog,
            pending: true,
            replaceable: true,
            registrationTime: block.timestamp,
            renderingContexts: _getDefaultContexts()
        });
        
        cs.catalogAssetExists[assetId] = true;
        
        cs.assetRegistry[assetId] = TokenAsset({
            id: assetId,
            assetUri: "",
            thumbnailUri: "",
            mediaType: "application/json",
            pending: true,
            replaceable: true,
            registrationTime: block.timestamp,
            traitPackId: 0,
            themeId: 0
        });
        cs.assetExists[assetId] = true;
        cs.assetIds.push(assetId);
        
        ModularConfigData storage config = cs.modularConfigsData[collectionId][tier][tokenId];
        if (config.lastUpdateTime == 0) {
            config.lastUpdateTime = block.timestamp;
        }
        
        config.pendingAssets.push(assetId);
        cs.modularConfigsIndices[collectionId][tier][tokenId].pendingAssetIndices[assetId] = config.pendingAssets.length;
        
        if (replacesAssetId != 0) {
            cs.assetReplacements[tokenId][assetId] = replacesAssetId;
        }
        
        string memory composedURI = _buildComposedURI(catalogId, selectedParts, collectionId, tier, tokenId);
        cs.catalogAssets[assetId].compositionURI = composedURI;
        cs.assetRegistry[assetId].assetUri = composedURI;
        
        emit CatalogAssetAdded(collectionId, tier, tokenId, assetId, catalogId, selectedParts);
    }
        
    function updateCatalogParts(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        uint64 assetId,
        uint64[] calldata selectedParts
    ) external onlyAuthorized whenNotPaused validCollection(collectionId) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        ModularHelper.validateTokenInCollectionTier(collectionId, tier, tokenId);
        
        if (!cs.catalogAssetExists[assetId]) {
            revert ModularHelper.AssetNotFound(assetId);
        }
        
        CatalogAsset storage asset = cs.catalogAssets[assetId];
        
        if (asset.assetType != AssetType.Catalog) {
            revert("Invalid asset type");
        }
        
        for (uint256 i = 0; i < selectedParts.length; i++) {
            if (!cs.partExists[selectedParts[i]]) {
                revert PartNotFound(selectedParts[i]);
            }
        }
        
        asset.selectedParts = selectedParts;
        
        string memory composedURI = _buildComposedURI(asset.catalogId, selectedParts, collectionId, tier, tokenId);
        asset.compositionURI = composedURI;
        cs.assetRegistry[assetId].assetUri = composedURI;
        
        emit CatalogAssetUpdated(collectionId, tier, tokenId, assetId, selectedParts);
    }

    function createAugmentCatalogAsset(
        uint256 specimenCollectionId,
        uint8 specimenTier,
        uint256 specimenTokenId,
        uint64 catalogId
    ) external onlyAuthorized whenNotPaused validCollection(specimenCollectionId) returns (uint64 assetId) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        ModularHelper.validateTokenInCollectionTier(specimenCollectionId, specimenTier, specimenTokenId);
        
        (address specimenCollection, , ) = LibCollectionStorage.getCollectionInfo(specimenCollectionId);
        bytes32 assignmentKey = cs.specimenToAssignment[specimenCollection][specimenTokenId];
        if (assignmentKey == bytes32(0)) {
            revert("No Augment assigned");
        }
        
        LibCollectionStorage.AugmentAssignment storage assignment = cs.augmentAssignments[assignmentKey];
        
        uint8[] memory accessories = cs.tierVariantAccessories[assignment.augmentCollection][assignment.tier][assignment.augmentVariant];
        
        uint64[] memory selectedParts = _accessoriesToParts(accessories);
        
        assetId = ModularHelper.generateUniqueAssetId(uint256(assignmentKey));
        
        cs.catalogAssets[assetId] = CatalogAsset({
            id: assetId,
            catalogId: catalogId,
            selectedParts: selectedParts,
            compositionURI: _buildComposedURI(catalogId, selectedParts, specimenCollectionId, specimenTier, specimenTokenId),
            assetType: AssetType.Catalog,
            pending: false,
            replaceable: true,
            registrationTime: block.timestamp,
            renderingContexts: _getAugmentContexts()
        });
        
        cs.catalogAssetExists[assetId] = true;
        
        cs.assetRegistry[assetId] = TokenAsset({
            id: assetId,
            assetUri: cs.catalogAssets[assetId].compositionURI,
            thumbnailUri: "",
            mediaType: "application/json",
            pending: false,
            replaceable: true,
            registrationTime: block.timestamp,
            traitPackId: 0,
            themeId: 0
        });
        cs.assetExists[assetId] = true;
        cs.assetIds.push(assetId);
        
        ModularConfigData storage config = cs.modularConfigsData[specimenCollectionId][specimenTier][specimenTokenId];
        if (config.lastUpdateTime == 0) {
            config.lastUpdateTime = block.timestamp;
        }
        
        config.acceptedAssets.push(assetId);
        
        if (config.activeAssetId == 0) {
            config.activeAssetId = assetId;
        }
        
        emit CatalogAssetAdded(specimenCollectionId, specimenTier, specimenTokenId, assetId, catalogId, selectedParts);
        
        return assetId;
    }
    
    function getComposedAssetURI(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        uint64 assetId
    ) external view validCollection(collectionId) returns (string memory) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        ModularHelper.validateTokenInCollectionTier(collectionId, tier, tokenId);
        
        if (!cs.catalogAssetExists[assetId]) {
            revert ModularHelper.AssetNotFound(assetId);
        }
        
        CatalogAsset storage asset = cs.catalogAssets[assetId];
        
        if (asset.assetType != AssetType.Catalog) {
            return "";
        }
        
        return asset.compositionURI;
    }
    
    function getPart(uint64 partId) external view returns (
        string memory name,
        PartType partType,
        bytes4 zIndex,
        string memory metadataURI,
        bool fixedToParent,
        address[] memory equippableAddresses
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!cs.partExists[partId]) {
            revert PartNotFound(partId);
        }
        
        EquippablePart storage part = cs.parts[partId];
        
        return (
            part.name,
            part.partType,
            part.zIndex,
            part.metadataURI,
            part.fixedToParent,
            part.equippableAddresses
        );
    }
    
    function getCatalogAsset(uint64 assetId) external view returns (
        uint64 catalogId,
        uint64[] memory selectedParts,
        string memory compositionURI,
        AssetType assetType,
        bool pending,
        bytes32[] memory renderingContexts
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!cs.catalogAssetExists[assetId]) {
            revert ModularHelper.AssetNotFound(assetId);
        }
        
        CatalogAsset storage asset = cs.catalogAssets[assetId];
        
        return (
            asset.catalogId,
            asset.selectedParts,
            asset.compositionURI,
            asset.assetType,
            asset.pending,
            asset.renderingContexts
        );
    }

    function getTokenCatalogAssets(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId
    ) external view validCollection(collectionId) returns (
        uint64[] memory pendingAssets,
        uint64[] memory acceptedAssets,
        uint64 activeAssetId
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        ModularHelper.validateTokenInCollectionTier(collectionId, tier, tokenId);
        
        ModularConfigData storage config = cs.modularConfigsData[collectionId][tier][tokenId];
        
        return (
            config.pendingAssets,
            config.acceptedAssets,
            config.activeAssetId
        );
    }

    function tokenExistsInCollectionTier(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId
    ) external view validCollection(collectionId) returns (bool exists) {
        ModularHelper.validateTokenInCollectionTier(collectionId, tier, tokenId);
        return true;
    }
    
    function _validatePartData(
        uint64 partId,
        string calldata name,
        PartType partType,
        string calldata metadataURI
    ) internal pure {
        if (partId == 0) revert InvalidPartData();
        if (bytes(name).length == 0 || bytes(name).length > MAX_PART_NAME_LENGTH) revert InvalidPartData();
        if (partType == PartType.None) revert InvalidPartType();
        if (bytes(metadataURI).length > MAX_METADATA_URI_LENGTH) revert MetadataURITooLong();
    }
    
    function _buildComposedURI(
        uint64 catalogId,
        uint64[] memory selectedParts,
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId
    ) internal view returns (string memory) {
        string memory baseURI = ModularHelper.getSmartBaseURI();
        
        return string.concat(
            baseURI,
            "compose/",
            collectionId.toString(),
            "/",
            tier.toString(),
            "/",
            catalogId.toString(),
            "/",
            tokenId.toString(),
            "?parts=",
            _encodePartsArray(selectedParts)
        );
    }
    
    function _encodePartsArray(uint64[] memory parts) internal pure returns (string memory) {
        if (parts.length == 0) return "";
        
        string memory result = parts[0].toString();
        for (uint256 i = 1; i < parts.length; i++) {
            result = string.concat(result, ",", parts[i].toString());
        }
        return result;
    }
    
    function _accessoriesToParts(uint8[] memory accessories) internal pure returns (uint64[] memory) {
        uint64[] memory parts = new uint64[](accessories.length);
        for (uint256 i = 0; i < accessories.length; i++) {
            parts[i] = uint64(accessories[i] + 1000);
        }
        return parts;
    }
    
    function _getDefaultContexts() internal pure returns (bytes32[] memory) {
        bytes32[] memory contexts = new bytes32[](3);
        contexts[0] = keccak256("default");
        contexts[1] = keccak256("gallery");
        contexts[2] = keccak256("marketplace");
        return contexts;
    }
    
    function _getAugmentContexts() internal pure returns (bytes32[] memory) {
        bytes32[] memory contexts = new bytes32[](4);
        contexts[0] = keccak256("default");
        contexts[1] = keccak256("game");
        contexts[2] = keccak256("battle");
        contexts[3] = keccak256("social");
        return contexts;
    }
}