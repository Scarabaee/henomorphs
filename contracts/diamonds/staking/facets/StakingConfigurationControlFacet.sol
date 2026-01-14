// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibDiamond} from "../../shared/libraries/LibDiamond.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibStakingStorage} from "../libraries/LibStakingStorage.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {StakingFees, SeasonRewardMultiplier, SpecialEvent, Colony} from "../../libraries/StakingModel.sol";
import {ControlFee, SpecimenCollection} from "../../libraries/HenomorphsModel.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {IDiamondLoupe} from "../../shared/interfaces/IDiamondLoupe.sol";
import {IStakingIntegrationFacet} from "../interfaces/IStakingInterfaces.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";

/**
 * @title StakingConfigurationControlFacet
 * @notice Control facet for staking system configuration (excluding reward calculations)
 * @dev Contains state-modifying functions for configuring the staking system except reward parameters
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract StakingConfigurationControlFacet is AccessControlBase {
    using SafeERC20 for IERC20;
    
    // Events (excluding reward-specific ones)
    event StakingEnabled(bool enabled);
    event TreasuryAddressUpdated(address newTreasury);
    event EmergencyWithdrawal(address token, address recipient, uint256 amount);
    event SeasonUpdated(uint256 seasonId, uint256 multiplier, bool active);
    event SpecialEventConfigured(uint256 eventId, uint256 startTime, uint256 endTime, uint256 multiplier);
    event ColonyCreationFeeSet(address tokenAddress, uint256 amount, address beneficiary);
    event WearThresholdsConfigured(uint256[] thresholds, uint256[] penalties);
    event WearAutoRepairConfigured(bool enabled, uint256 threshold, uint256 amount, uint256 costPerPoint);
    event WearIncreaseRateSet(uint256 dailyIncreaseRate);
    event ColonyUpdated(bytes32 colonyId, string name, address creator, bool active);
    event BiopodSyncFailed(uint256 indexed collectionId, uint256 indexed tokenId);
    event ChargepodAddressChanged(address oldAddress, address newAddress);
    event ModulesSettingsUpdated(LibStakingStorage.InternalModules settings);
    event ExternalModulesUpdated(LibStakingStorage.ExternalModules settings);
    event ModulesVerified(bool success, uint256 timestamp);
    event ModuleRegistryInitialized();
    event ModuleAddressUpdated(string moduleType, address moduleAddress);
    event SpecimenCollectionRegistered(uint256 indexed collectionId, address indexed collectionAddress, string name);
    event SpecimenCollectionUpdated(uint256 indexed collectionId, bool enabled, uint256 regenMultiplier);
    event SpecimenCollectionRemoved(uint256 indexed collectionId, address indexed collectionAddress);
    event WearRepairFeeConfigured(address tokenAddress, uint256 costPerPoint, address beneficiary);
    event StakingFeesSet(StakingFees fees);
    event ColonyMembershipFeeConfigured(address tokenAddress, uint256 amount, address beneficiary);
    event CollectionCounterSynced(uint256 oldCounter, uint256 newCounter);
    event OperationFeeUpdated(string operation, uint256 amount, address beneficiary, address tokenAddress);
    event StakingVaultConfigured(bool useExternalVault, address vaultAddress);
    event StakingCurrencySet(address tokenAddress);
    event SystemLimitsUpdated(LibStakingStorage.SystemLimits limits);
    
    // Errors
    error InvalidParameter();
    error InvalidAddress();
    error InvalidFeeConfiguration();
    error EmergencyWithdrawalFailed();
    error MismatchedArrayLengths();
    error InvalidWearThresholds();
    error InvalidWearPenalties();
    error InvalidEventConfiguration();
    error InvalidColonyConfiguration();
    error UnsupportedModuleType();
    error InterfaceVerificationFailed(string moduleType, address moduleAddress);
    error FeeTooHigh(uint256 amount, uint256 maxAmount);
    
    // Configuration flags
    bool public skipInterfaceVerification = true;

    /**
     * @notice Set system limits - simple configuration
     * @param limits New system limits
     */
    function setSystemLimits(LibStakingStorage.SystemLimits calldata limits) external onlyAuthorized whenNotPaused {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        ss.systemLimits = limits;
        emit SystemLimitsUpdated(limits);
    }

    /**
     * @notice Get limit with fallback
     */
    function _getLimit(string memory limitType) private view returns (uint256) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        LibStakingStorage.SystemLimits storage limits = ss.systemLimits;
        
        if (keccak256(bytes(limitType)) == keccak256(bytes("maxBasicFee"))) {
            return limits.maxBasicOperationFee > 0 ? limits.maxBasicOperationFee : 10 ether;
        } else if (keccak256(bytes(limitType)) == keccak256(bytes("maxSpecialFee"))) {
            return limits.maxSpecialOperationFee > 0 ? limits.maxSpecialOperationFee : 50 ether;
        } else if (keccak256(bytes(limitType)) == keccak256(bytes("maxTieredFee"))) {
            return limits.maxTieredFeeBps > 0 ? limits.maxTieredFeeBps : 2000;
        } else if (keccak256(bytes(limitType)) == keccak256(bytes("maxWearThreshold"))) {
            return limits.maxWearThreshold > 0 ? limits.maxWearThreshold : 100;
        }
        return 100; // Default fallback
    }

    /**
     * @notice Set whether staking is enabled
     * @param enabled Whether staking is enabled
     */
    function setStakingEnabled(bool enabled) external onlyAuthorized whenNotPaused {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        ss.stakingEnabled = enabled;
        emit StakingEnabled(enabled);
    }

    /**
     * @notice Configures the vault address for staked tokens
     * @dev When useExternalVault is false, tokens are stored on the diamond contract itself
     * @param useExternalVault Whether to use an external vault instead of the diamond
     * @param vaultAddress External vault address (only used when useExternalVault is true)
        */
    function configureStakingVault(
        bool useExternalVault, 
        address vaultAddress
    ) external onlyAuthorized whenNotPaused {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Enhanced validation - prevent zero address when enabling external vault
        if (useExternalVault) {
            if (vaultAddress == address(0)) {
                revert InvalidAddress();
            }
            
            // Additional check - ensure vault address is a contract if possible
            uint256 codeSize;
            assembly {
                codeSize := extcodesize(vaultAddress)
            }
            
        }
        
        // Update configuration
        ss.vaultConfig.useExternalVault = useExternalVault;
        
        if (useExternalVault) {
            ss.vaultConfig.vaultAddress = vaultAddress;
        }
        
        emit StakingVaultConfigured(useExternalVault, vaultAddress);
    }
    
    /**
     * @notice Set whether to skip interface verification
     * @param skip Whether to skip verification
     */
    function setSkipInterfaceVerification(bool skip) external onlyAuthorized whenNotPaused {
        skipInterfaceVerification = skip;
    }
    
    /**
     * @notice Update treasury address
     * @param newTreasury New treasury address
     */
    function updateTreasuryAddress(address newTreasury) external onlyAuthorized whenNotPaused {
        if (newTreasury == address(0)) {
            revert InvalidAddress();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        ss.settings.treasuryAddress = newTreasury;
        
        emit TreasuryAddressUpdated(newTreasury);
    }

    /**
     * @notice Set the staking currency token address
     * @param tokenAddress Address of the ERC20 token contract
     */
    function setStakingCurrency(address tokenAddress) external onlyAuthorized whenNotPaused {
        if (tokenAddress == address(0)) {
            revert InvalidAddress();
        }
        
        // Verify that the address is actually a contract
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(tokenAddress)
        }
        if (codeSize == 0) {
            revert InvalidAddress();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Set the new token address
        ss.zicoToken = IERC20(tokenAddress);
        
        // Emit event with the new address
        emit StakingCurrencySet(tokenAddress);
    }
    
    /**
     * @notice Configure season
     * @param seasonId Season ID
     * @param multiplier Reward multiplier (100 = 100%)
     * @param active Whether season is active
     */
    function configureSeason(uint256 seasonId, uint256 multiplier, bool active) external onlyAuthorized whenNotPaused {
        if (seasonId == 0 || multiplier == 0) {
            revert InvalidParameter();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        ss.currentSeason = SeasonRewardMultiplier({
            seasonId: seasonId,
            multiplier: multiplier,
            active: active
        });
        
        emit SeasonUpdated(seasonId, multiplier, active);
    }
    
    /**
     * @notice Configure special event
     * @param eventId Event ID
     * @param startTime Start time
     * @param endTime End time
     * @param multiplier Reward multiplier (100 = 100%)
     */
    function configureSpecialEvent(
        uint256 eventId,
        uint256 startTime,
        uint256 endTime,
        uint256 multiplier
    ) external onlyAuthorized whenNotPaused {
        if (endTime <= startTime || multiplier == 0) {
            revert InvalidEventConfiguration();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        uint256 newEventId = eventId;
        if (eventId == 0) {
            ss.specialEventCounter++;
            newEventId = ss.specialEventCounter;
        }
        
        ss.specialEvents[newEventId] = SpecialEvent({
            startTime: startTime,
            endTime: endTime,
            multiplier: multiplier,
            active: true
        });
        
        emit SpecialEventConfigured(newEventId, startTime, endTime, multiplier);
    }
    
    /**
     * @notice Configure wear thresholds and penalties
     * @param thresholds Array of wear thresholds
     * @param penalties Array of percentage penalties
     */
    function configureWearThresholds(uint256[] calldata thresholds, uint256[] calldata penalties) external onlyAuthorized whenNotPaused {
        if (thresholds.length != penalties.length || thresholds.length == 0) {
            revert MismatchedArrayLengths();
        }
        
        // Check if thresholds are in ascending order
        for (uint256 i = 1; i < thresholds.length; i++) {
            if (thresholds[i] <= thresholds[i - 1]) {
                revert InvalidWearThresholds();
            }
        }
        
        // Check if penalties are in ascending order
        for (uint256 i = 1; i < penalties.length; i++) {
            if (penalties[i] <= penalties[i - 1]) {
                revert InvalidWearPenalties();
            }
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Clear existing thresholds
        while (ss.wearPenaltyThresholds.length > 0) {
            ss.wearPenaltyThresholds.pop();
        }
        
        // Clear existing penalties
        while (ss.wearPenaltyValues.length > 0) {
            ss.wearPenaltyValues.pop();
        }
        
        // Set new thresholds and penalties
        for (uint256 i = 0; i < thresholds.length; i++) {
            ss.wearPenaltyThresholds.push(uint8(thresholds[i]));
            ss.wearPenaltyValues.push(uint8(penalties[i]));
        }
        
        emit WearThresholdsConfigured(thresholds, penalties);
    }
    
    /**
     * @notice Configure auto repair
     * @param enabled Whether auto repair is enabled
     * @param threshold Threshold for auto repair
     * @param amount Amount of wear to repair
     * @param costPerPoint Cost per point of repair
     */
    function configureAutoRepair(
        bool enabled,
        uint256 threshold,
        uint256 amount,
        uint256 costPerPoint
    ) external onlyAuthorized whenNotPaused {
        if (threshold > _getLimit("maxWearThreshold") || amount == 0) {
            revert InvalidParameter();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        ss.wearAutoRepairEnabled = enabled;
        ss.wearAutoRepairThreshold = threshold;
        ss.wearAutoRepairAmount = amount;
        ss.wearRepairCostPerPoint = costPerPoint;
        
        emit WearAutoRepairConfigured(enabled, threshold, amount, costPerPoint);
    }
    
    /**
     * @notice Set daily wear increase rate
     * @param rate Daily wear increase rate
     */
    function setWearIncreaseRate(uint256 rate) external onlyAuthorized whenNotPaused {
        if (rate > _getLimit("maxWearThreshold")) {
            revert InvalidParameter();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        ss.wearIncreasePerDay = rate;
        
        emit WearIncreaseRateSet(rate);
    }

    /**
     * @notice Sets the complete fee configuration for staking operations
     * @param fees Complete fee structure including all fee types
     * @dev Sets each fee independently for maximum flexibility
     */
    function setStakingFees(StakingFees calldata fees) external onlyAuthorized whenNotPaused {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Set each fee independently
        ss.fees.stakeFee = fees.stakeFee;
        ss.fees.unstakeFee = fees.unstakeFee;
        ss.fees.claimFee = fees.claimFee;
        ss.fees.infusionFee = fees.infusionFee;
        ss.fees.harvestFee = fees.harvestFee;
        ss.fees.withdrawalFee = fees.withdrawalFee;
        ss.fees.reinvestFee = fees.reinvestFee;
        ss.fees.colonyCreationFee = fees.colonyCreationFee;
        ss.fees.wearRepairFee = fees.wearRepairFee;
        ss.fees.colonyMembershipFee = fees.colonyMembershipFee;
        
        // Update wear repair cost per point from the fee structure for backward compatibility
        ss.wearRepairCostPerPoint = fees.wearRepairFee.amount;
        
        // Emit main event
        emit StakingFeesSet(fees);
    }

    /**
     * @notice Configure colony membership fee separately for convenience
     * @param amount Fee amount
     * @param beneficiary Fee recipient address
     */
    function setColonyMembershipFee(uint256 amount, address beneficiary) external onlyAuthorized whenNotPaused {
        if (beneficiary == address(0)) {
            revert InvalidAddress();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        IERC20 zicoToken = ss.zicoToken;
        
        // Update only the colony membership fee
        ss.fees.colonyMembershipFee = ControlFee({
            currency: zicoToken,
            amount: amount,
            beneficiary: beneficiary,
            burnOnCollect: true
        });
        
        emit ColonyMembershipFeeConfigured(address(zicoToken), amount, beneficiary);
    }

    /**
     * @notice Configure wear repair fee separately
     * @param costPerPoint Cost per wear point repaired
     * @param beneficiary Fee beneficiary address
     */
    function configureWearRepairFee(uint256 costPerPoint, address beneficiary) external onlyAuthorized whenNotPaused {
        if (beneficiary == address(0)) {
            revert InvalidAddress();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Update wear repair cost per point
        ss.wearRepairCostPerPoint = costPerPoint;
        
        // Update beneficiary in the fee structure
        ss.fees.wearRepairFee.beneficiary = beneficiary;
        ss.fees.wearRepairFee.currency = ss.zicoToken;
        
        emit WearRepairFeeConfigured(address(ss.zicoToken), costPerPoint, beneficiary);
    }

    /**
     * @notice Simplified fee configuration function with basic limits
     * @dev Adds reasonable fee caps to prevent accidental mistakes
     * @param feeType Operation type (e.g., "stake", "claim", "harvest")
     * @param amount Fee amount
     * @param beneficiary Address receiving the fee
     * @param tokenAddress Token to collect fee in (address(0) for ZICO)
     */
    function setOperationFee(
        string memory feeType,
        uint256 amount,
        address beneficiary,
        address tokenAddress
    ) external onlyAuthorized {
        // Validate beneficiary
        if (beneficiary == address(0)) {
            revert InvalidAddress();
        }
        
        // Simple limit check based on operation type
        uint256 maxFeeAmount;
        if (_isBasicOperation(feeType)) {
            maxFeeAmount = _getLimit("maxBasicFee");
        } else {
            maxFeeAmount = _getLimit("maxSpecialFee");
        }
        
        // Apply limit
        if (amount > maxFeeAmount) {
            revert FeeTooHigh(amount, maxFeeAmount);
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Configure the fee based on type
        if (_stringEquals(feeType, "stake")) {
            ss.fees.stakeFee = ControlFee(
                tokenAddress == address(0) ? ss.zicoToken : IERC20(tokenAddress),
                amount,
                beneficiary,
                true
            );
        } else if (_stringEquals(feeType, "unstake")) {
            ss.fees.unstakeFee = ControlFee(
                tokenAddress == address(0) ? ss.zicoToken : IERC20(tokenAddress),
                amount,
                beneficiary,
                true
            );
        } else if (_stringEquals(feeType, "claim")) {
            ss.fees.claimFee = ControlFee(
                tokenAddress == address(0) ? ss.zicoToken : IERC20(tokenAddress),
                amount,
                beneficiary,
                true
            );
        } 
        // Add other fee types as needed
        
        emit OperationFeeUpdated(feeType, amount, beneficiary, tokenAddress);
    }

    /**
     * @notice Helper to check if operation is a basic type
     * @param feeType The fee type to check
     * @return isBasic Whether the operation is considered basic
     */
    function _isBasicOperation(string memory feeType) private pure returns (bool isBasic) {
        return (_stringEquals(feeType, "stake") || 
                _stringEquals(feeType, "unstake") || 
                _stringEquals(feeType, "claim") ||
                _stringEquals(feeType, "harvest"));
    }

    /**
     * @notice String comparison helper
     * @param a First string
     * @param b Second string
     * @return equal Whether strings are equal
     */
    function _stringEquals(string memory a, string memory b) private pure returns (bool equal) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /**
     * @notice Configure tiered fees for percentage-based operations
     * @dev Sets up threshold-based fee structure with improved validation
     * @param enabled Whether tiered fees are enabled
     * @param thresholds Array of thresholds for fee tiers (ascending order)
     * @param feeBps Array of fee percentages in basis points (100 = 1%)
     */
    function configureTieredFees(
        bool enabled,
        uint256[] calldata thresholds,
        uint256[] calldata feeBps
    ) external onlyAuthorized whenNotPaused {
        if (thresholds.length != feeBps.length || thresholds.length == 0) {
            revert MismatchedArrayLengths();
        }
        
        // Verify thresholds are in ascending order
        for (uint256 i = 1; i < thresholds.length; i++) {
            if (thresholds[i] <= thresholds[i - 1]) {
                revert InvalidParameter();
            }
        }
        
        // Verify percentages are reasonable (use configurable limit)
        for (uint256 i = 0; i < feeBps.length; i++) {
            if (feeBps[i] > _getLimit("maxTieredFee")) {
                revert InvalidParameter();
            }
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        LibStakingStorage.TieredFeeParams storage params = ss.settings.tieredFees;
        
        // Update tiered fee configuration
        params.enabled = enabled;
        
        // Clear existing arrays
        while (params.thresholds.length > 0) {
            params.thresholds.pop();
        }
        
        while (params.feeBps.length > 0) {
            params.feeBps.pop();
        }
        
        // Set new values
        for (uint256 i = 0; i < thresholds.length; i++) {
            params.thresholds.push(thresholds[i]);
            params.feeBps.push(feeBps[i]);
        }
        
        // Emit event for easier tracking
        emit OperationFeeUpdated("tiered_fees", 0, address(0), address(0));
    }

    /**
     * @notice Register a new collection with improved validation and error handling
     * @param collectionAddress NFT collection address
     * @param biopodAddress Associated biopod address
     * @param name Collection name
     * @param collectionType Type identifier (0=genesis, 1=matrix, etc)
     * @param regenMultiplier Regen rate multiplier (in percentage, 100 = standard)
     * @param maxChargeBonus Additional max charge bonus
     * @return collectionId Assigned collection ID
     */
    function registerCollection(
        address collectionAddress,
        address biopodAddress,
        address augmentsAddress,
        address diamondAddress,
        address repositoryAddress,
        string calldata name,
        uint8 collectionType,
        uint256 regenMultiplier,
        uint256 maxChargeBonus,
        bool isModular
    ) 
        external onlyAuthorized
        returns (uint256 collectionId) 
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Validate inputs
        if (collectionAddress == address(0)) {
            revert LibHenomorphsStorage.InvalidCallData();
        }
        
        // Check if collection already registered
        uint16 existingId = ss.collectionIndexes[collectionAddress];
        
        if (existingId != 0) {
            // Verify that the collection with this ID actually has this address
            SpecimenCollection storage existingCollection = ss.collections[existingId];
            
            if (existingCollection.collectionAddress != collectionAddress) {
                // Fix inconsistency: update the collection's address to match the index
                existingCollection.collectionAddress = collectionAddress;
            }
            
            // Update existing collection
            existingCollection.biopodAddress = biopodAddress;
            existingCollection.diamondAddress = diamondAddress;
            existingCollection.repositoryAddress = repositoryAddress;
            existingCollection.augmentsAddress = augmentsAddress;
            existingCollection.name = name;
            existingCollection.enabled = true;
            existingCollection.isModularSpecimen = isModular;
            
            // Update optional parameters if provided with non-zero values
            if (regenMultiplier > 0) {
                existingCollection.regenMultiplier = regenMultiplier;
            }
            
            if (maxChargeBonus > 0) {
                existingCollection.maxChargeBonus = maxChargeBonus;
            }
            
            emit SpecimenCollectionUpdated(existingId, existingCollection.enabled, existingCollection.regenMultiplier);
            
            return existingId;
        }

        // Safely increment the collection counter
        collectionId = ss.collectionCounter + 1;
        ss.collectionCounter = collectionId;
        
        // Set default values if not provided
        uint256 finalRegenMultiplier = regenMultiplier > 0 ? regenMultiplier : 100;
        uint256 finalMaxChargeBonus = maxChargeBonus > 0 ? maxChargeBonus : 10;
        
        // Create collection data
        ss.collections[collectionId] = SpecimenCollection({
            collectionAddress: collectionAddress,
            biopodAddress: biopodAddress,
            name: name,
            enabled: true,
            collectionType: collectionType,
            regenMultiplier: finalRegenMultiplier,
            maxChargeBonus: finalMaxChargeBonus,
            diamondAddress: diamondAddress,
            isModularSpecimen: isModular,
            augmentsAddress: augmentsAddress,
            repositoryAddress: (repositoryAddress != address(0) ? repositoryAddress : diamondAddress),
            defaultTier: 1,
            maxVariantIndex: 4
        });
        
        // Map collection address to ID
        ss.collectionIndexes[collectionAddress] = uint16(collectionId);
        
        emit SpecimenCollectionRegistered(collectionId, collectionAddress, name);
        
        return collectionId;
    }
    
    /**
     * @notice Update an existing collection with improved validation
     * @param collectionId Collection ID to update
     * @param biopodAddress New biopod address (address(0) to keep existing)
     * @param name New collection name (empty to keep existing)
     * @param enabled Whether collection should be enabled
     * @param regenMultiplier New regen multiplier (0 to keep existing)
     * @param maxChargeBonus New max charge bonus (0 to keep existing)
     * @return success Whether the update was successful
     */
    function updateCollection(
        uint256 collectionId,
        address biopodAddress,
        address augmentsAddress,
        address diamondAddress,
        address repositoryAddress,
        string calldata name,
        bool enabled,
        uint256 regenMultiplier,
        uint256 maxChargeBonus,
        bool isModular
    ) 
        external onlyAuthorized
        returns (bool success)
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Enhanced validation
        if (collectionId == 0 || collectionId > ss.collectionCounter) {
            revert LibStakingStorage.InvalidCollectionId(collectionId);
        }
        
        SpecimenCollection storage collection = ss.collections[collectionId];
        
        // Verify collection exists
        if (collection.collectionAddress == address(0)) {
            revert LibStakingStorage.CollectionNotFound(collectionId);
        }
        
        // Update parameters - we're doing explicit checks to avoid overwriting with invalid values
        
        // Update biopod address if provided
        if (biopodAddress != address(0)) {
            collection.biopodAddress = biopodAddress;
        }

        if (augmentsAddress != address(0)) {
            collection.augmentsAddress = augmentsAddress;
        }

        if (diamondAddress != address(0)) {
            collection.diamondAddress = diamondAddress;
        }

        collection.repositoryAddress = (repositoryAddress != address(0) ? repositoryAddress : diamondAddress);
        collection.isModularSpecimen = isModular;
        
        // Update name if provided
        if (bytes(name).length > 0) {
            collection.name = name;
        }
        
        // Always update enabled status (this is a direct parameter)
        collection.enabled = enabled;
        
        // Update regen multiplier if provided
        if (regenMultiplier > 0) {
            collection.regenMultiplier = regenMultiplier;
        }
        
        // Update max charge bonus if provided
        if (maxChargeBonus > 0) {
            collection.maxChargeBonus = maxChargeBonus;
        }
        
        emit SpecimenCollectionUpdated(collectionId, collection.enabled, collection.regenMultiplier);
        
        return true;
    }

    /**
     * @notice Remove a collection with safety checks
     * @param collectionId Collection ID to remove
     * @return success Whether the removal was successful
     */
    function removeCollection(uint256 collectionId) 
        external onlyAuthorized
        returns (bool success)
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Enhanced validation
        if (collectionId == 0 || collectionId > ss.collectionCounter) {
            revert LibStakingStorage.InvalidCollectionId(collectionId);
        }
        
        SpecimenCollection storage collection = ss.collections[collectionId];
        
        // Verify collection exists
        if (collection.collectionAddress == address(0)) {
            revert LibStakingStorage.CollectionNotFound(collectionId);
        }
        
        // Store the collection address for later use
        address collectionAddress = collection.collectionAddress;
        
        // Remove mapping from address to ID
        delete ss.collectionIndexes[collectionAddress];
        
        // Clear collection data
        delete ss.collections[collectionId];

        ss.collectionCounter -= 1;
        
        // Note: we do NOT decrement collectionCounter as this would disrupt the ID sequence
        // Instead we just remove the specific collection, leaving its slot empty
        
        emit SpecimenCollectionRemoved(collectionId, collectionAddress);
        
        return true;
    }

    /**
     * @notice Completely reset all collection data
     * @dev Removes all collections and resets counter, based on CollectionFacet implementation
     * @return deletedCount Number of collections removed
     */
    function clearAllCollections() 
        external onlyAuthorized whenNotPaused
        returns (uint256 deletedCount)
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Track collections removed
        deletedCount = 0;
        
        // Process all collections up to the counter
        for (uint256 i = 1; i <= ss.collectionCounter; i++) {
            address collAddr = ss.collections[i].collectionAddress;
            
            if (collAddr != address(0)) {
                // Remove from the index mapping
                delete ss.collectionIndexes[collAddr];
                
                // Clear the collection data
                delete ss.collections[i];
                
                deletedCount++;
                
                emit SpecimenCollectionRemoved(i, collAddr);
            }
        }
        
        // Reset the counter
        uint256 oldCounter = ss.collectionCounter;
        ss.collectionCounter = 0;
        
        // Use existing event for consistency with the rest of the contract
        emit CollectionCounterSynced(oldCounter, 0);
        
        return deletedCount;
    }

    /**
     * @notice Sync collection counter after batch operations
     * @dev Updates the collection counter to match the highest active collection ID
     * @return newCounter The updated counter value
     */
    function syncCollectionCounter() 
        external onlyAuthorized whenNotPaused
        returns (uint256 newCounter)
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        uint256 oldCounter = ss.collectionCounter;
        
        // Find the highest valid collection ID
        newCounter = 0;
        
        for (uint256 i = 1; i <= oldCounter; i++) {
            if (ss.collections[i].collectionAddress != address(0)) {
                newCounter = i;
            }
        }
        
        // Update the counter
        ss.collectionCounter = newCounter;
        
        // Add event for collection counter sync if missing in StakingConfigurationFacet
        emit CollectionCounterSynced(oldCounter, newCounter);
        
        return newCounter;
    }

    /**
     * @notice Sets internal modules settings with verification
     * @param settings New modules settings
     */
    function setInternalModules(LibStakingStorage.InternalModules calldata settings) 
        external 
        onlyAuthorized 
        whenNotPaused
    {
        // Validate module addresses
        if (settings.coreModuleAddress == address(0) ||
            settings.biopodModuleAddress == address(0) ||
            settings.wearModuleAddress == address(0) ||
            settings.integrationModuleAddress == address(0) ||
            settings.colonyModuleAddress == address(0)) {
            revert InvalidAddress();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Update settings with new values and track changes
        ss.internalModules = settings;
        
        // Save verification timestamp
        ss.moduleRegistry.lastVerificationTimestamp = block.timestamp;
        ss.moduleRegistry.lastVerificationResult = true; // Always set to true now
        
        emit ModulesSettingsUpdated(settings);
        emit ModulesVerified(true, block.timestamp);
    }

    /**
     * @notice Sets external modules for Chargepod integration
     * @param settings External modules settings
     */
    function setExternalModules(LibStakingStorage.ExternalModules calldata settings)
        external
        onlyAuthorized
        whenNotPaused
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Update settings with new values
        ss.externalModules = settings;
        
        emit ExternalModulesUpdated(settings);
    }

    /**
     * @notice Updates module address with verification
     * @param moduleType Module type (e.g., "core", "biopod")
     * @param moduleAddress New module address
     */
    function updateModuleAddress(string calldata moduleType, address moduleAddress)
        external
        onlyAuthorized
        whenNotPaused
    {
        if (moduleAddress == address(0)) {
            revert InvalidAddress();
        }

        // Update module address without verification if skipInterfaceVerification is true
        if (skipInterfaceVerification) {
            _setModuleAddress(moduleType, moduleAddress);
            emit ModuleAddressUpdated(moduleType, moduleAddress);
            return;
        }

        // Otherwise, use the original verification logic
        // Get original address for rollback if verification fails
        address originalAddress = _getModuleAddress(moduleType);
        
        // Update module address
        _setModuleAddress(moduleType, moduleAddress);
        
        // Verify interface
        bool valid = verifyModule(moduleType);
        
        if (!valid) {
            // Rollback to original address
            _setModuleAddress(moduleType, originalAddress);
            revert InterfaceVerificationFailed(moduleType, moduleAddress);
        }
        
        emit ModuleAddressUpdated(moduleType, moduleAddress);
    }

    /**
     * @notice Force set verification result to success
     */
    function forceSetVerificationSuccess() external onlyAuthorized whenNotPaused {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        ss.moduleRegistry.lastVerificationTimestamp = block.timestamp;
        ss.moduleRegistry.lastVerificationResult = true;
        emit ModulesVerified(true, block.timestamp);
    }

    /**
     * @notice Set the behavior of colony repair regarding inconsistent data
     * @param value Whether to override existing colony assignments when repairing inconsistent data
     */
    function setForceOverrideInconsistentColonies(bool value) external onlyAuthorized whenNotPaused {
        LibStakingStorage.stakingStorage().forceOverrideInconsistentColonies = value;
    }

    /**
     * @notice Verify module implements expected interface
     * @param moduleType Module type
     * @return valid Whether module interface is valid
     */
    function verifyModule(string memory moduleType) public view returns (bool valid) {
        // Skip verification if flag is set
        if (skipInterfaceVerification) {
            return true;
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Get expected selectors for this module type
        bytes4[] memory expectedSelectors = ss.moduleRegistry.expectedSelectors[moduleType];
        if (expectedSelectors.length == 0) {
            return false;
        }
        
        // Get module address based on type
        address moduleAddress = _getModuleAddress(moduleType);
        
        if (moduleAddress == address(0)) {
            return false;
        }
        
        // Use library function for verification
        return LibStakingStorage.verifyModuleInterface(moduleType, moduleAddress);
    }
    
    /**
     * @notice Verify all modules implement expected interfaces
     * @return allValid Whether all modules are valid
     */
    function verifyAllModules()
        external
        view
        returns (bool allValid)
    {
        // Skip verification if flag is set
        if (skipInterfaceVerification) {
            return true;
        }
        
        string[5] memory moduleTypes = [
            "core", "biopod", "wear", "integration", "colony"
        ];
        
        allValid = true;
        
        for (uint256 i = 0; i < moduleTypes.length; i++) {
            bool valid = verifyModule(moduleTypes[i]);
            if (!valid) {
                allValid = false;
                break;
            }
        }
        
        return allValid;
    }

    /**
     * @notice Get module address
     * @param moduleType Module type
     * @return Address of the module
     */
    function _getModuleAddress(string memory moduleType)
        internal
        view
        returns (address)
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        LibStakingStorage.InternalModules memory modules = ss.internalModules;
        
        bytes32 moduleTypeHash = keccak256(bytes(moduleType));
        
        if (moduleTypeHash == keccak256(bytes("core"))) {
            return modules.coreModuleAddress;
        } else if (moduleTypeHash == keccak256(bytes("biopod"))) {
            return modules.biopodModuleAddress;
        } else if (moduleTypeHash == keccak256(bytes("wear"))) {
            return modules.wearModuleAddress;
        } else if (moduleTypeHash == keccak256(bytes("integration"))) {
            return modules.integrationModuleAddress;
        } else if (moduleTypeHash == keccak256(bytes("colony"))) {
            return modules.colonyModuleAddress;
        } else {
            revert UnsupportedModuleType();
        }
    }

    /**
     * @notice Set module address
     * @param moduleType Module type
     * @param moduleAddress New module address
     */
    function _setModuleAddress(string memory moduleType, address moduleAddress)
        internal
    {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        LibStakingStorage.InternalModules storage modules = ss.internalModules;
        
        bytes32 moduleTypeHash = keccak256(bytes(moduleType));
        
        if (moduleTypeHash == keccak256(bytes("core"))) {
            modules.coreModuleAddress = moduleAddress;
        } else if (moduleTypeHash == keccak256(bytes("biopod"))) {
            modules.biopodModuleAddress = moduleAddress;
        } else if (moduleTypeHash == keccak256(bytes("wear"))) {
            modules.wearModuleAddress = moduleAddress;
        } else if (moduleTypeHash == keccak256(bytes("integration"))) {
            modules.integrationModuleAddress = moduleAddress;
        } else if (moduleTypeHash == keccak256(bytes("colony"))) {
            modules.colonyModuleAddress = moduleAddress;
        } else {
            revert UnsupportedModuleType();
        }
    }

    // View functions for accessing configuration

    /**
     * @notice Get system limits
     */
    function getSystemLimits() external view returns (LibStakingStorage.SystemLimits memory) {
        return LibStakingStorage.stakingStorage().systemLimits;
    }

    /**
     * @notice Get staking enabled status
     */
    function isStakingEnabled() external view returns (bool) {
        return LibStakingStorage.stakingStorage().stakingEnabled;
    }

    /**
     * @notice Get treasury address
     */
    function getTreasuryAddress() external view returns (address) {
        return LibStakingStorage.stakingStorage().settings.treasuryAddress;
    }

    /**
     * @notice Get staking currency
     */
    function getStakingCurrency() external view returns (address) {
        return address(LibStakingStorage.stakingStorage().zicoToken);
    }

    /**
     * @notice Get current season
     */
    function getCurrentSeason() external view returns (SeasonRewardMultiplier memory) {
        return LibStakingStorage.stakingStorage().currentSeason;
    }

    /**
     * @notice Get special event
     */
    function getSpecialEvent(uint256 eventId) external view returns (SpecialEvent memory) {
        return LibStakingStorage.stakingStorage().specialEvents[eventId];
    }

    /**
     * @notice Get vault configuration
     */
    function getVaultConfig() external view returns (LibStakingStorage.VaultConfig memory) {
        return LibStakingStorage.stakingStorage().vaultConfig;
    }

    /**
     * @notice Get wear settings
     */
    function getWearSettings() external view returns (
        uint256 increasePerDay,
        bool autoRepairEnabled,
        uint256 autoRepairThreshold,
        uint256 autoRepairAmount,
        uint256 repairCostPerPoint
    ) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        return (
            ss.wearIncreasePerDay,
            ss.wearAutoRepairEnabled,
            ss.wearAutoRepairThreshold,
            ss.wearAutoRepairAmount,
            ss.wearRepairCostPerPoint
        );
    }

    /**
     * @notice Get complete staking fees structure
     */
    function getStakingFees() external view returns (StakingFees memory) {
        return LibStakingStorage.stakingStorage().fees;
    }

    /**
     * @notice Get collection information
     */
    function getCollection(uint256 collectionId) external view returns (SpecimenCollection memory) {
        return LibStakingStorage.getCollection(collectionId);
    }

    /**
     * @notice Get collection counter
     */
    function getCollectionCounter() external view returns (uint256) {
        return LibStakingStorage.stakingStorage().collectionCounter;
    }

    /**
     * @notice Get internal modules configuration
     */
    function getInternalModules() external view returns (LibStakingStorage.InternalModules memory) {
        return LibStakingStorage.stakingStorage().internalModules;
    }

    /**
     * @notice Get external modules configuration
     */
    function getExternalModules() external view returns (LibStakingStorage.ExternalModules memory) {
        return LibStakingStorage.stakingStorage().externalModules;
    }

    /**
     * @notice Get module verification status
     */
    function getModuleVerificationStatus() external view returns (uint256 timestamp, bool result) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        return (ss.moduleRegistry.lastVerificationTimestamp, ss.moduleRegistry.lastVerificationResult);
    }
}