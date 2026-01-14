// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../libraries/HenomorphsModel.sol";

/**
 * @dev Interface for biopod contracts
 */
interface ISpecimenChargepod {
    // ==================== EVENTS ====================
    
    event ChargeUpdated(uint256 indexed collectionId, uint256 indexed tokenId, uint256 newCharge, uint256 maxCharge);
    event ActionPerformed(uint256 indexed collectionId, uint256 indexed tokenId, uint8 actionType, uint256 chargeCost, uint256 reward);
    event ChargeBoostActivated(uint256 indexed collectionId, uint256 indexed tokenId, uint256 duration, uint256 boostAmount);
    event AccessoryEquipped(uint256 indexed collectionId, uint256 indexed tokenId, uint256 accessoryId);
    event CollectionRegistered(uint256 indexed collectionId, address collectionAddress, string name);
    event CollectionUpdated(uint256 indexed collectionId, bool enabled, uint256 regenMultiplier);
    event NewSeasonStarted(uint256 seasonId, uint256 startTime, uint256 endTime, string theme);
    event SpecializationChanged(uint256 indexed collectionId, uint256 indexed tokenId, uint8 newSpecialization);
    event RepairCompleted(uint256 indexed collectionId, uint256 indexed tokenId, uint256 pointsRepaired, uint256 cost);
    event GlobalChargeEventStarted(uint256 startTime, uint256 endTime, uint256 bonusPercentage);
    event FeeConfigUpdated(ChargeFees fees);
    event ColonyFormed(bytes32 indexed colonyId, string name, address indexed creator, uint256 memberCount);
    event ColonyDissolved(bytes32 indexed colonyId, address dissolvedBy);
    event TransferNotified(uint256 indexed collectionId, uint256 indexed tokenId, address from, address to);
    event PowerCoreActivated(uint256 indexed collectionId, uint256 indexed tokenId, uint256 initialCharge, uint256 maxCharge);
    event BatchSyncCompleted(uint256 collectionId, uint256 tokenCount);
    event ActionTypeUpdated(uint8 indexed actionTypeId, ChargeActionType actionType);
    event ChargeSettingsUpdated(ChargeSettings settings);
    event OperatorApproved(address operator, bool approved);
    event Paused(address account);
    event Unpaused(address account);

    // ==================== ERRORS ====================

    error HenomorphControlForbidden(uint256 collectionId, uint256 tokenId);
    error PowerCoreAlreadyActivated(uint256 collectionId, uint256 tokenId);
    error PowerCoreNotActivated(uint256 collectionId, uint256 tokenId);
    error InvalidCallData();
    error CollectionNotEnabled(uint256 collectionId);
    error HenomorphNotEnabled(uint256 collectionId);
    error UnsupportedAction();
    error ActionOnCooldown(uint256 collectionId, uint256 tokenId, uint8 actionId);
    error HenomorphInRepairMode();
    error InsufficientCharge();
    error HenomorphNotInColony();
    error HenomorphAlreadyInColony();
    error InvalidSpecializationType();
    error SpecializationAlreadySet();
    error HenomorphFullyCharged();
    error MaxAccessoriesReached();
    error ColonyDoesNotExist(bytes32 colonyId); 
    error ForbiddenRequest();
    error BiopodNotAvailable(uint256 collectionId);
    error CollectionAlreadyRegistered(address collectionAddress);
    error FeeProcessingFailed();
    error ContractPaused();

    /**
     * @dev Gets the contract owner
     * @return Owner address
     */
    function owner() external view returns (address);
    
    /**
     * @dev Checks if an address is an operator
     * @param operator Address to check
     * @return Whether the address is an operator
     */
    function isOperator(address operator) external view returns (bool);

    /**
     * @dev Notifies processor about token transfer
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param from Previous owner
     * @param to New owner
     */
    function transferCallback(uint256 collectionId, uint256 tokenId, address from, address to) external;
    
    /**
     * @dev Synchronizes token data with biopod
     * @param collectionId Collection ID
     * @param tokenId Token ID
     */
    function syncWithBiopod(uint256 collectionId, uint256 tokenId) external;
    
    /**
     * @dev Gets collection ID from contract address
     * @param collectionAddress Collection contract address
     * @return Collection ID
     */
    function getCollectionId(address collectionAddress) external view returns (uint256);
    
    /**
     * @dev Returns collection configuration data
     * @param collectionId Collection ID
     */
    function getSpecimenCollection(uint256 collectionId) external view returns (SpecimenCollection memory);
    
    /**
     * @dev Returns PowerMatrix data for a token
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return PowerMatrix for the token
     */
    function getPowerMatrix(uint256 collectionId, uint256 tokenId) external view returns (PowerMatrix memory);
    
    /**
     * @dev Gets all accessories equipped to a henomorph
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return Array of equipped accessories
     */
    function equippedAccessories(uint256 collectionId, uint256 tokenId) external view returns (ChargeAccessory[] memory);
}