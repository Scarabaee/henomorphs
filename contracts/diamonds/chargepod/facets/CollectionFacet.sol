// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibDiamond} from "../../shared/libraries/LibDiamond.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {PodsUtils} from "../../libraries/PodsUtils.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "../../libraries/HenomorphsModel.sol"; 
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {AccessControlBase} from "./AccessControlBase.sol";


/**
 * @title CollectionFacet
 * @notice Alternative facet for collection management with improved functionality and integrity
 * @dev Optimized to avoid "stack too deep" errors by using parameter grouping
 */
contract CollectionFacet is AccessControlBase {
    // Events
    event SpecimenCollectionRegistered(uint256 indexed collectionId, address indexed collectionAddress, string name);
    event SpecimenCollectionUpdated(uint256 indexed collectionId, bool enabled, uint256 regenMultiplier);
    event SpecimenCollectionRemoved(uint256 indexed collectionId, address indexed collectionAddress);
    event TransferNotified(uint256 indexed collectionId, uint256 indexed tokenId, address indexed from, address to);
    event CollectionCounterSynced(uint256 oldCounter, uint256 newCounter);
    
    /**
     * @dev Structure to group collection parameters and avoid stack too deep errors
     */
    struct CollectionParams {
        address collectionAddress;
        address biopodAddress;
        string name;
        uint8 collectionType;
        uint256 regenMultiplier;
        uint256 maxChargeBonus;
        bool enabled;
        address augmentsAddress;
        address diamondAddress; 
        bool isModularSpecimen; 
        address repositoryAddress;
    }

    /**
     * @notice Register a new collection with enhanced validation
     * @param params All collection parameters in a single struct
     * @return collectionId Assigned collection ID
     */
    function registerCollection(CollectionParams calldata params) 
        external onlyAuthorized
        returns (uint256 collectionId) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Validate inputs
        if (params.collectionAddress == address(0) || params.biopodAddress == address(0)) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        // Check if collection already registered and return its ID if it exists
        uint16 existingId = hs.collectionIndexes[params.collectionAddress];
        if (existingId != 0) {
            // Verify bidirectional mapping is correct
            address storedAddress = hs.specimenCollections[existingId].collectionAddress;
            
            if (storedAddress == params.collectionAddress) {
                // Update existing collection
                SpecimenCollection storage existingCollection = hs.specimenCollections[existingId];
                existingCollection.biopodAddress = params.biopodAddress;
                existingCollection.name = params.name;
                existingCollection.enabled = true;
                existingCollection.augmentsAddress = params.augmentsAddress;
                existingCollection.diamondAddress = params.diamondAddress;
                existingCollection.isModularSpecimen = params.isModularSpecimen;
                existingCollection.repositoryAddress = params.repositoryAddress;
                
                // Update optional parameters if provided with non-zero values
                if (params.regenMultiplier > 0) {
                    existingCollection.regenMultiplier = params.regenMultiplier;
                }
                
                if (params.maxChargeBonus > 0) {
                    existingCollection.maxChargeBonus = params.maxChargeBonus;
                }
                
                emit SpecimenCollectionUpdated(existingId, existingCollection.enabled, existingCollection.regenMultiplier);
                
                return existingId;
            } else {
                // Fix corrupted index - clear the invalid mapping
                delete hs.collectionIndexes[params.collectionAddress];
            }
        }

        // Increment collection counter
        hs.collectionCounter++;
        collectionId = hs.collectionCounter;
        
        // Set default values if not provided
        uint256 regenMultiplier = params.regenMultiplier == 0 ? 100 : params.regenMultiplier;
        uint256 maxChargeBonus = params.maxChargeBonus == 0 ? 10 : params.maxChargeBonus;
        
        // Create collection data
        hs.specimenCollections[collectionId].collectionAddress = params.collectionAddress;
        hs.specimenCollections[collectionId].biopodAddress = params.biopodAddress;
        hs.specimenCollections[collectionId].name = params.name;
        hs.specimenCollections[collectionId].enabled = true;
        hs.specimenCollections[collectionId].collectionType = params.collectionType;
        hs.specimenCollections[collectionId].regenMultiplier = regenMultiplier;
        hs.specimenCollections[collectionId].maxChargeBonus = maxChargeBonus;
        hs.specimenCollections[collectionId].diamondAddress = params.diamondAddress;
        hs.specimenCollections[collectionId].isModularSpecimen = params.isModularSpecimen;
        hs.specimenCollections[collectionId].repositoryAddress = params.repositoryAddress;
        
        // Map collection address to ID
        hs.collectionIndexes[params.collectionAddress] = uint16(collectionId);
        
        emit SpecimenCollectionRegistered(collectionId, params.collectionAddress, params.name);
        
        return collectionId;
    }
    
    /**
     * @notice Update an existing collection
     * @param collectionId Collection ID to update
     * @param params Collection parameters to update
     */
    function updateCollection(
        uint256 collectionId,
        CollectionParams calldata params
    ) 
        external onlyAuthorized
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        address oldCollectionAddress = collection.collectionAddress;
        
        // Verify collection exists
        if (oldCollectionAddress == address(0)) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        // Handle collection address change if requested
        if (params.collectionAddress != address(0) && params.collectionAddress != oldCollectionAddress) {
            // Check if the new address is already registered
            uint16 existingId = hs.collectionIndexes[params.collectionAddress];
            if (existingId != 0) {
                revert LibHenomorphsStorage.CollectionAlreadyRegistered(params.collectionAddress);
            }
            
            // Remove old index mapping
            delete hs.collectionIndexes[oldCollectionAddress];
            
            // Update collection address
            collection.collectionAddress = params.collectionAddress;
            
            // Create new index mapping
            hs.collectionIndexes[params.collectionAddress] = uint16(collectionId);
        }
        
        // Update other parameters
        collection.enabled = params.enabled;
        
        if (params.biopodAddress != address(0)) {
            collection.biopodAddress = params.biopodAddress;
        }

        if (params.augmentsAddress != address(0)) {
            collection.augmentsAddress = params.augmentsAddress;
        }

        if (params.diamondAddress != address(0)) {
            collection.diamondAddress = params.diamondAddress;
        }

        if (params.repositoryAddress != address(0)) {
            collection.repositoryAddress = params.repositoryAddress;
        }

        if (bytes(params.name).length > 0) {
            collection.name = params.name;
        }
        
        if (params.regenMultiplier > 0) {
            collection.regenMultiplier = params.regenMultiplier;
        }
        
        if (params.maxChargeBonus > 0) {
            collection.maxChargeBonus = params.maxChargeBonus;
        }

        collection.collectionType = params.collectionType; 
        collection.isModularSpecimen = params.isModularSpecimen;
        
        emit SpecimenCollectionUpdated(collectionId, collection.enabled, collection.regenMultiplier);
    }
        
    /**
     * @notice Remove a collection with enhanced integrity validation
     * @param collectionId Collection ID to remove
     */
    function removeCollection(uint256 collectionId) 
        external onlyAuthorized
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        address collectionAddress = hs.specimenCollections[collectionId].collectionAddress;
        
        if (collectionAddress == address(0)) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        // Remove mapping from address to ID
        delete hs.collectionIndexes[collectionAddress];
        
        // Clear collection data
        delete hs.specimenCollections[collectionId];
        
        // Note: We don't adjust the counter here for gas efficiency
        // Use syncCollectionCounter() separately if needed after batch operations
        
        emit SpecimenCollectionRemoved(collectionId, collectionAddress);
    }
    
    /**
     * @notice Process transfer notification from collections
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param from Previous owner
     * @param to New owner
     */
    function notifyTransfer(uint256 collectionId, uint256 tokenId, address from, address to) 
        external 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            revert LibHenomorphsStorage.InvalidCallData();
        }

        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        if (LibMeta.msgSender() != collection.collectionAddress) {
            revert LibHenomorphsStorage.ForbiddenRequest();
        }

        // Handle the transfer notification
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        // If the token has a PowerMatrix, update it
        if (hs.performedCharges[combinedId].lastChargeTime > 0) {
            // Update timestamp to refresh data
            hs.performedCharges[combinedId].lastChargeTime = uint32(block.timestamp);
            
            // Reset fatigue on transfer
            hs.performedCharges[combinedId].fatigueLevel = 0;
            hs.performedCharges[combinedId].consecutiveActions = 0;
        }
        
        emit TransferNotified(collectionId, tokenId, from, to);
    }
    
    /**
     * @notice Get collection details
     * @param collectionId Collection ID
     * @return collection SpecimenCollection configuration
     */
    function getCollection(uint256 collectionId) 
        external 
        view 
        returns (SpecimenCollection memory collection) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        return hs.specimenCollections[collectionId];
    }
    
    /**
     * @notice Get collection ID from address with improved validation
     * @param collectionAddress Collection address
     * @return collectionId Collection ID (0 if not registered or invalid)
     */
    function specimenCollectionId(address collectionAddress) 
        external 
        view 
        returns (uint256 collectionId) 
    {
        if (collectionAddress == address(0)) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        collectionId = hs.collectionIndexes[collectionAddress];
        
        // Verify bidirectional consistency
        if (collectionId != 0) {
            address storedAddress = hs.specimenCollections[collectionId].collectionAddress;
            if (storedAddress != collectionAddress) {
                // Index is corrupted, return 0
                return 0;
            }
        }
        
        return collectionId;
    }
    
    /**
     * @notice Get collection counter
     * @return Current collection counter
     */
    function specimenCollectionCount() 
        external 
        view 
        returns (uint256) 
    {
        return LibHenomorphsStorage.henomorphsStorage().collectionCounter;
    }
    
    /**
     * @notice Check if a collection exists with enhanced validation
     * @param collectionAddress Collection address to check
     * @return exists Whether collection exists and is valid
     * @return collectionId ID of the collection if exists
     */
    function checkCollection(address collectionAddress)
        external
        view
        returns (bool exists, uint256 collectionId)
    {
        if (collectionAddress == address(0)) {
            return (false, 0);
        }
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Get ID from the address mapping
        collectionId = hs.collectionIndexes[collectionAddress];
        
        // Verify bidirectional consistency
        if (collectionId != 0 && collectionId <= hs.collectionCounter) {
            address storedAddress = hs.specimenCollections[collectionId].collectionAddress;
            exists = (storedAddress == collectionAddress);
        } else {
            exists = false;
            collectionId = 0;
        }
        
        return (exists, collectionId);
    }
    
    /**
     * @notice Completely reset all collection data
     * @dev Removes all collections and resets counter
     * @return deletedCount Number of collections removed
     */
    function clearAllCollections() 
        external onlyAuthorized
        returns (uint256 deletedCount)
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Track collections removed
        deletedCount = 0;
        
        // Process all collections up to the counter
        for (uint256 i = 1; i <= hs.collectionCounter; i++) {
            address collAddr = hs.specimenCollections[i].collectionAddress;
            
            if (collAddr != address(0)) {
                // Remove from the index mapping
                delete hs.collectionIndexes[collAddr];
                
                // Clear the collection data
                delete hs.specimenCollections[i];
                
                deletedCount++;
                
                emit SpecimenCollectionRemoved(i, collAddr);
            }
        }
        
        // Reset the counter
        uint256 oldCounter = hs.collectionCounter;
        hs.collectionCounter = 0;
        
        emit CollectionCounterSynced(oldCounter, 0);
        
        return deletedCount;
    }
    
    /**
     * @notice Replace an entire collection's data
     * @param collectionId ID of the collection to replace
     * @param params All collection parameters in a single struct
     */
    function replaceCollection(
        uint256 collectionId,
        CollectionParams calldata params
    ) 
        external onlyAuthorized
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Validate inputs
        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        if (params.collectionAddress == address(0) || params.biopodAddress == address(0)) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        // Check if the new collection address is already registered elsewhere
        uint16 existingId = hs.collectionIndexes[params.collectionAddress];
        if (existingId != 0 && existingId != collectionId) {
            revert LibHenomorphsStorage.CollectionAlreadyRegistered(params.collectionAddress);
        }
        
        // Get the old collection address before replacing data
        address oldCollectionAddress = hs.specimenCollections[collectionId].collectionAddress;
        
        // If the collection address is changing, update the index mapping
        if (oldCollectionAddress != params.collectionAddress) {
            // Remove old mapping if it exists
            if (oldCollectionAddress != address(0)) {
                delete hs.collectionIndexes[oldCollectionAddress];
            }
            
            // Add new mapping
            hs.collectionIndexes[params.collectionAddress] = uint16(collectionId);
        }
        
        // Set default values if not provided
        uint256 regenMultiplier = params.regenMultiplier == 0 ? 100 : params.regenMultiplier;
        uint256 maxChargeBonus = params.maxChargeBonus == 0 ? 10 : params.maxChargeBonus;
        
        // Replace all collection data
        hs.specimenCollections[collectionId].collectionAddress = params.collectionAddress;
        hs.specimenCollections[collectionId].biopodAddress = params.biopodAddress;
        hs.specimenCollections[collectionId].name = params.name;
        hs.specimenCollections[collectionId].collectionType = params.collectionType;
        hs.specimenCollections[collectionId].regenMultiplier = regenMultiplier;
        hs.specimenCollections[collectionId].maxChargeBonus = maxChargeBonus;
        hs.specimenCollections[collectionId].enabled = params.enabled;
        
        // Emit appropriate event
        emit SpecimenCollectionUpdated(collectionId, params.enabled, regenMultiplier);
    }
    
    /**
     * @notice Synchronize collection counter to match actual collections
     * @dev Should be called after batch removals to update the counter
     * @return newCounter The updated counter value
     */
    function syncCollectionCounter() 
        external onlyAuthorized
        returns (uint256 newCounter)
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        uint256 oldCounter = hs.collectionCounter;
        
        // Find the highest valid collection ID
        newCounter = 0;
        
        for (uint256 i = 1; i <= oldCounter; i++) {
            if (hs.specimenCollections[i].collectionAddress != address(0)) {
                newCounter = i;
            }
        }
        
        // Update the counter
        hs.collectionCounter = uint16(newCounter);
        
        emit CollectionCounterSynced(oldCounter, newCounter);
        
        return newCounter;
    }

    /**
     * @notice Reset collection counter to a specific value (DANGEROUS - Admin only)
     * @dev This allows setting the counter to any specific value
     * @dev Use with extreme caution - can break collection ID consistency
     * @param newCounter The new counter value to set
     * @return oldCounter The previous counter value before reset
     */
    function resetCollectionCounter(uint256 newCounter) 
        external onlyAuthorized
        returns (uint256 oldCounter)
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        oldCounter = hs.collectionCounter;
        
        // Set the counter to the specified value
        hs.collectionCounter = uint16(newCounter);
        
        emit CollectionCounterSynced(oldCounter, newCounter);
        
        return oldCounter;
    }

    /**
     * @notice Get detailed collection counter information
     * @dev Provides comprehensive information about the collection counter state
     * @return currentCounter Current counter value
     * @return totalRegistered Number of actually registered collections
     * @return gaps Number of gaps in collection IDs
     * @return isConsistent Whether counter matches highest registered collection
     */
    function checkCollectionRegistryState() 
        external 
        view 
        returns (
            uint256 currentCounter,
            uint256 totalRegistered,
            uint256 gaps,
            bool isConsistent
        )
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        currentCounter = hs.collectionCounter;
        totalRegistered = 0;
        gaps = 0;
        uint256 highestRegistered = 0;
        
        // Count registered collections and find gaps
        for (uint256 i = 1; i <= currentCounter; i++) {
            if (hs.specimenCollections[i].collectionAddress != address(0)) {
                totalRegistered++;
                highestRegistered = i;
            } else {
                gaps++;
            }
        }
        
        // Check if counter is consistent with highest registered collection
        isConsistent = (currentCounter == highestRegistered);
        
        return (currentCounter, totalRegistered, gaps, isConsistent);
    }
        
    /**
     * @notice Repair collection index mappings
     * @dev Ensures all collection indexes point to the correct collections
     * @return repairedCount Number of index mappings repaired
     */
    function repairCollectionIndexes() 
        external onlyAuthorized
        returns (uint256 repairedCount)
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        repairedCount = 0;
        
        // First clear all incorrect index mappings
        for (uint256 i = 1; i <= hs.collectionCounter; i++) {
            address collAddr = hs.specimenCollections[i].collectionAddress;
            
            if (collAddr != address(0)) {
                // Check if index is correct
                uint16 currentIndex = hs.collectionIndexes[collAddr];
                if (currentIndex != i) {
                    // Clear the incorrect mapping
                    delete hs.collectionIndexes[collAddr];
                    repairedCount++;
                }
            }
        }
        
        // Then rebuild all index mappings
        for (uint256 i = 1; i <= hs.collectionCounter; i++) {
            address collAddr = hs.specimenCollections[i].collectionAddress;
            
            if (collAddr != address(0) && hs.collectionIndexes[collAddr] == 0) {
                // Set the correct mapping
                hs.collectionIndexes[collAddr] = uint16(i);
            }
        }
        
        return repairedCount;
    }
}