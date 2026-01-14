// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibMeta} from "../shared/libraries/LibMeta.sol";
import {LibCollectionStorage} from "./LibCollectionStorage.sol";

/**
 * @title ModularHelper
 * @notice Common validation and utilities for modular facets
 * @dev Only centralizes actual duplicated code
 */
library ModularHelper {

    error CollectionNotFound(uint256 collectionId);
    error TokenNotExists(uint256 tokenId);
    error TokenNotInCollectionTier(uint256 tokenId, uint256 collectionId, uint8 tier);
    error InvalidCollectionTierContext();
    error UnauthorizedTokenOperation(address caller, uint256 tokenId);
    error AssetNotFound(uint64 assetId);
    error InvalidAssetData();
    error MultiAssetNotEnabled(uint256 collectionId);

    /**
     * @notice Validate token exists in collection-tier context
     * @dev This was duplicated across 3 facets, hence centralized
     */
    function validateTokenInCollectionTier(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId
    ) internal view {
        LibCollectionStorage.TokenContext memory context = LibCollectionStorage.getTokenContext(collectionId, tokenId);
        if (context.exists) {
            if (context.collectionId == collectionId && context.tier == tier) {
                return;
            } else {
                revert TokenNotInCollectionTier(tokenId, collectionId, tier);
            }
        }
        
        (address contractAddress, , bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (!exists) {
            revert InvalidCollectionTierContext();
        }
        
        try IERC721(contractAddress).ownerOf(tokenId) returns (address) {
            return;
        } catch {
            revert TokenNotExists(tokenId);
        }
    }

    /**
     * @notice Validate caller has token control permissions
     * @dev This was duplicated across facets with slight variations
     */
    function validateTokenController(uint256 collectionId, uint256 tokenId, address caller) internal view {
        (address contractAddress, , bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (!exists) {
            revert InvalidCollectionTierContext();
        }
        
        try IERC721(contractAddress).ownerOf(tokenId) returns (address owner) {
            if (caller == owner) return;
            
            try IERC721(contractAddress).getApproved(tokenId) returns (address approved) {
                if (caller == approved) return;
            } catch {}
            
            try IERC721(contractAddress).isApprovedForAll(owner, caller) returns (bool approvedForAll) {
                if (approvedForAll) return;
            } catch {}
            
            revert UnauthorizedTokenOperation(caller, tokenId);
        } catch {
            revert TokenNotExists(tokenId);
        }
    }

    /**
     * @notice Generate unique asset ID with collision protection
     * @dev This exact pattern was used in multiple places
     */
    function generateUniqueAssetId(uint256 seed) internal view returns (uint64) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint64 assetId;
        uint256 attempts = 0;
        
        do {
            assetId = uint64(uint256(keccak256(abi.encodePacked(
                block.timestamp,
                block.prevrandao,
                LibMeta.msgSender(),
                attempts,
                seed
            ))) % type(uint64).max);
            
            attempts++;
            if (attempts > 1000) revert("Cannot generate unique asset ID");
            
        } while (cs.assetExists[assetId] || cs.catalogAssetExists[assetId] || assetId == 0);
        
        return assetId;
    }

    /**
     * @notice Get smart base URI for the system
     * @dev This logic was repeated in multiple URI builders
     */
    function getSmartBaseURI() internal view returns (string memory) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        return cs.systemTreasury.treasuryAddress != address(0) ? 
            "https://api.zico.network/" : "https://localhost:3000/";
    }
}