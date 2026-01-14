// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../common/CollectionModel.sol";
import "./libraries/HenomorphsModel.sol";
import "./interfaces/ISpecimenBiopod.sol";
import "./interfaces/ISpecimenCollection.sol";

/**
 * @notice Interface for YELLOW token burn functionality
 */
interface IYellowToken {
    function burnFrom(address account, uint256 amount, string calldata reason) external;
}

interface ICollectionRepository {
    function getItemInfo(ItemType itemType, uint256 issueId, uint8 tier) external view returns (IssueInfo memory, ItemTier memory);
    function getTierVariant(ItemType itemType, uint256 issueId, uint8 tier, uint8 variant) external view returns (TierVariant memory);
}

interface IStakingDiamond {
    function updateTokenData(uint256 collectionId, uint256 tokenId, uint8 level, uint256 experience, uint8 chargeLevel) external returns (bool);
    function isTokenStaker(uint256 collectionId, uint256 tokenId, address staker) external view returns (bool);
    function getStakedTokenData(uint256 collectionId, uint256 tokenId) external view returns (
        bool staked,
        address owner,
        uint256 stakedSince,
        uint8 variant,
        uint8 level
    );

    function getStakingVaultConfig() external view returns (
        bool useExternalVault,
        address vaultAddress,
        address actualVaultAddress
    );
}

contract HenomorphsBiopod is Initializable, PausableUpgradeable, AccessControlUpgradeable, UUPSUpgradeable, ISpecimenBiopod {
    using SafeERC20 for IERC20;

    error InvalidCallData();
    error SpecimenControlForbidden(uint256 collectionId, uint256 tokenId);
    error ProcessorNotApproved(address processor);
    error RequestNotAuthorized();
    error TokenNotInitialized();
    error CalibrationNotAllowed(uint256 collectionId, uint256 tokenId);
    error CollectionNotRegistered(uint256 collectionId);
    error CollectionAlreadyRegistered(uint256 collectionId);

    event InspectionHandled(uint256 indexed collectionId, uint256 indexed tokenId, uint256 maintenance, uint256 level, uint256 experience);
    event CalibrationFinished(uint256 quantity);
    event SpecimenLevelUp(uint256 indexed collectionId, uint256 indexed tokenId, uint256 level);
    event ExperienceGained(uint256 indexed collectionId, uint256 indexed tokenId, uint256 amount, uint256 experience);
    event ProcessorApprovalChanged(address indexed processor, bool approved);
    event ChargeDataUpdated(uint256 indexed collectionId, uint256 indexed tokenId, uint256 charge, uint256 timestamp, address processor);
    event CalibrationStatusUpdated(uint256 indexed collectionId, uint256 indexed tokenId, uint256 level, uint256 wear, address processor);
    event FatigueApplied(uint256 indexed collectionId, uint256 indexed tokenId, uint256 amount, address processor);
    event WearUpdated(uint256 indexed collectionId, uint256 indexed tokenId, uint256 oldWear, uint256 newWear, address processor);
    event WearRepaired(uint256 indexed collectionId, uint256 indexed tokenId, uint256 amount, address processor);
    event StakingContractChanged(address oldAddress, address newAddress);
    event StakingSyncAttempted(uint256 indexed collectionId, uint256 indexed tokenId, bool success);
    event KinshipAdjusted(uint256 indexed collectionId, uint256 indexed tokenId, uint256 oldKinship, uint256 newKinship, address admin);
    event CollectionRegistered(uint256 indexed collectionId, address indexed collectionAddress, string name);
    event CollectionUpdated(uint256 indexed collectionId, bool enabled, uint256 regenMultiplier);
    event CollectionDeregistered(uint256 indexed collectionId);
    event CollectionEnabledChanged(uint256 indexed collectionId, bool wasEnabled, bool isEnabled);
    event FeeBurned(address indexed from, uint256 amount, string operation);

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PROCESSOR_MANAGER_ROLE = keccak256("PROCESSOR_ROLE");

    uint256 public constant RECALIBRATION_MAX = 100;
    uint256 public constant CHARGE_MAX = 100;
    uint256 public constant MAX_LEVEL = 99;

    IERC20 private constant ZICO = IERC20(0x486ebcFEe0466Def0302A944Bd6408cD2CB3E806);

    // Original storage layout - preserved
    IERC721 private collection;
    ICollectionRepository private collectionRepository;
    mapping(uint256 => Calibration) private _calibrations;
    mapping(uint256 => CalibrationSettings) private _calibrationSettings;
    mapping(address => bool) private _approvedProcessors;
    uint256 private _chargeCounter;
    address private stakingContract;

    // New storage for multi-collection support
    mapping(uint256 => SpecimenCollection) private _collections;
    mapping(uint256 => mapping(uint256 => Calibration)) private _multiCalibrations;
    mapping(uint256 => mapping(uint256 => CalibrationSettings)) private _multiSettings;
    uint256[] private _collectionIds;

    IERC20 private constant YELLOW = IERC20(0x79e60C812161eBcAfF14b1F06878c6Be451CD3Ef);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address collectionContract, address repositoryContract, address beneficiary) public initializer {
        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);

        collection = IERC721(collectionContract);
        collectionRepository = ICollectionRepository(repositoryContract);

        setCalibrationSettings(1, CalibrationSettings({
            interactPeriod: 1,
            chargePeriod: 1,
            recalPeriod: 1,
            controlFee: ControlFee(ZICO, 1000000000000000000, beneficiary, true),
            tuneValue: 1,
            bonusValue: 0,
            bonusThreshold: 0
        }));
    }

    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function migrateCalibrations(
        uint256 collectionId,
        uint256[] calldata tokenIds
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            
            // Sprawdź czy istnieje w starym storage
            if (_calibrations[tokenId].tokenId != 0) {
                // Skopiuj do nowego storage
                _multiCalibrations[collectionId][tokenId] = _calibrations[tokenId];
            }
        }
    }

    // Collection management
    function registerCollection(uint256 collectionId, SpecimenCollection memory collectionData) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_collections[collectionId].collectionAddress != address(0)) {
            revert CollectionAlreadyRegistered(collectionId);
        }
        if (collectionData.collectionAddress == address(0)) {
            revert InvalidCallData();
        }
        
        _collections[collectionId] = collectionData;
        _collectionIds.push(collectionId);
        emit CollectionRegistered(collectionId, collectionData.collectionAddress, collectionData.name);
    }

    function updateCollection(
        uint256 collectionId,
        bool enabled,
        uint256 regenMultiplier,
        uint256 maxChargeBonus,
        address repositoryAddress
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_collections[collectionId].collectionAddress == address(0)) {
            revert CollectionNotRegistered(collectionId);
        }

        _collections[collectionId].enabled = enabled;
        _collections[collectionId].regenMultiplier = regenMultiplier;
        _collections[collectionId].maxChargeBonus = maxChargeBonus;
        _collections[collectionId].repositoryAddress = repositoryAddress;

        emit CollectionUpdated(collectionId, enabled, regenMultiplier);
    }

    function deregisterCollection(uint256 collectionId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_collections[collectionId].collectionAddress == address(0)) {
            revert CollectionNotRegistered(collectionId);
        }

        delete _collections[collectionId];

        // Remove from array
        for (uint256 i = 0; i < _collectionIds.length; i++) {
            if (_collectionIds[i] == collectionId) {
                _collectionIds[i] = _collectionIds[_collectionIds.length - 1];
                _collectionIds.pop();
                break;
            }
        }

        emit CollectionDeregistered(collectionId);
    }

    /**
     * @notice Enable or disable a collection
     * @param collectionId Collection ID to modify
     * @param enabled Whether collection should be enabled
     */
    function setCollectionEnabled(uint256 collectionId, bool enabled) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (_collections[collectionId].collectionAddress == address(0)) {
            revert CollectionNotRegistered(collectionId);
        }
        
        bool wasEnabled = _collections[collectionId].enabled;
        _collections[collectionId].enabled = enabled;
        
        emit CollectionEnabledChanged(collectionId, wasEnabled, enabled);
    }

    function getCollection(uint256 collectionId) external view returns (SpecimenCollection memory) {
        return _collections[collectionId];
    }

    function getRegisteredCollections() external view returns (uint256[] memory) {
        return _collectionIds;
    }

    function isCollectionRegistered(uint256 collectionId) external view returns (bool) {
        return _collections[collectionId].collectionAddress != address(0);
    }

    function getCalibrationConfig(uint256 collectionId) external view returns (
        uint256 interactPeriod,
        uint256 chargePeriod, 
        uint256 recalPeriod,
        uint256 tuneValue,
        address currency,
        uint256 feeAmount,
        address beneficiary,
        bool hasCustomSettings
    ) {
        CalibrationSettings memory settings = _multiSettings[collectionId][1];
        hasCustomSettings = settings.interactPeriod != 0;
        
        if (!hasCustomSettings) {
            settings = _calibrationSettings[1];
        }
        
        return (
            settings.interactPeriod,
            settings.chargePeriod,
            settings.recalPeriod,
            settings.tuneValue,
            address(settings.controlFee.currency),
            settings.controlFee.amount,
            settings.controlFee.beneficiary,
            hasCustomSettings
        );
    }

    // Main inspection function
    function inspect(uint256[] memory collectionIds, uint256[] memory tokenIds) public whenNotPaused returns (uint256 count) {
        if (collectionIds.length != tokenIds.length) {
            revert InvalidCallData();
        }

        CalibrationSettings memory settings;
        bool settingsLoaded = false;
        
        for (uint256 i = 0; i < collectionIds.length; i++) {
            uint256 collectionId = collectionIds[i];
            uint256 tokenId = tokenIds[i];
            
            // Skip invalid or disabled collections
            if (!_isCollectionValid(collectionId)) continue;
            
            // Load settings only once (since all collections have same fees)
            if (!settingsLoaded) {
                settings = _getCalibrationSettings(collectionId);
                settingsLoaded = true;
            }
            
            // Validate token ownership/authorization
            (bool isValidToken, address owner) = _validateTokenAndAuth(collectionId, tokenId, _msgSender());
            if (!isValidToken) continue;
            
            // Get token variant for experience calculations
            (bool isValidVariant, uint8 variant) = _getTokenVariant(collectionId, tokenId);
            if (!isValidVariant) {
                continue;
            }
            
            // Process the inspection and update token data
            if (_processInspection(collectionId, tokenId, variant, owner, settings)) {
                count++;
            }
        }

        // Collect total fee in a single transaction
        if (count > 0 && settingsLoaded) {
            uint256 totalFee = settings.controlFee.amount * count;
            _collectFee(settings.controlFee.currency, _msgSender(), settings.controlFee.beneficiary, totalFee, settings.controlFee.burnOnCollect);
        }

        emit CalibrationFinished(count);
    }
    
    /**
     * @notice Inspect single token - simplified version for debugging
     * @param collectionId Collection ID
     * @param tokenId Token ID to inspect
     * @return success Whether inspection was successful
     */
    function inspectSingle(uint256 collectionId, uint256 tokenId) 
        external 
        whenNotPaused 
        returns (bool success) 
    {
        // Basic validation
        if (!_isCollectionValid(collectionId)) {
            return false;
        }
        
        // Get settings
        CalibrationSettings memory settings = _getCalibrationSettings(collectionId);
        
        // Validate token and auth
        (bool isValidToken, address owner) = _validateTokenAndAuth(collectionId, tokenId, _msgSender());
        if (!isValidToken) {
            return false;
        }
        
        // Get variant
        (bool isValidVariant, uint8 variant) = _getTokenVariant(collectionId, tokenId);
        if (!isValidVariant) {
            return false;
        }
        
        // Process inspection
        bool processed = _processInspection(collectionId, tokenId, variant, owner, settings);
        
        // Collect fee if processed
        if (processed) {
            _collectFee(settings.controlFee.currency, _msgSender(), settings.controlFee.beneficiary, settings.controlFee.amount, settings.controlFee.burnOnCollect);
            emit CalibrationFinished(1);
        }
        
        return processed;
    }

    /**
     * @notice Check if token can be inspected and provide reason if not
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param operator The owner of the token
     * @return canInspect Whether inspection is possible
     * @return reason Reason if inspection not possible
     */
    function canInspect(uint256 collectionId, uint256 tokenId, address operator) 
        external 
        view 
        returns (bool, string memory reason) 
    {
        // Check if contract is paused
        if (paused()) {
            return (false, "Contract is paused");
        }

        // Check if collection is valid and enabled
        if (!_isCollectionValid(collectionId)) {
            if (_collections[collectionId].collectionAddress == address(0)) {
                return (false, "Collection not registered");
            }
            return (false, "Collection is disabled");
        }

        // Check token authorization (ownership/processor/staking)
        (bool isValidToken, ) = _validateTokenAndAuth(collectionId, tokenId, operator);
        if (!isValidToken) {
            // Try to determine if token exists
            SpecimenCollection memory collectionData = _collections[collectionId];
            try IERC721(collectionData.collectionAddress).ownerOf(tokenId) returns (address) {
                return (false, "Not authorized to inspect this token");
            } catch {
                return (false, "Token does not exist");
            }
        }

        // Get calibration data using legacy fallback logic
        Calibration storage calibration = _multiCalibrations[collectionId][tokenId]; 
        
        // Check cooldown period
        CalibrationSettings memory settings = _getCalibrationSettings(collectionId);
        if (calibration.lastInteraction != 0) {
            uint256 nextAllowedTime = calibration.lastInteraction + (settings.interactPeriod * 1 hours);
            
            if (block.timestamp < nextAllowedTime) {
                return (false, "Cooldown period active");
            }
        }

        // Check if user has sufficient ZICO balance and allowance for fee
        if (settings.controlFee.amount > 0) {
            IERC20 zicoToken = settings.controlFee.currency;
            uint256 userBalance = zicoToken.balanceOf(operator);
            uint256 userAllowance = zicoToken.allowance(operator, address(this));
            
            if (userBalance < settings.controlFee.amount) {
                return (false, "Insufficient ZICO balance");
            }
            
            if (userAllowance < settings.controlFee.amount) {
                return (false, "Insufficient ZICO allowance");
            }
        }

        return (true, "Ready for inspection");
    }

    // Calibration probe - implements interface
    function probeCalibration(uint256 collectionId, uint256 tokenId) public view returns (Calibration memory) {
        if (!_isCollectionValid(collectionId)) {
            revert CollectionNotRegistered(collectionId);
        }

        SpecimenCollection memory collectionData = _collections[collectionId];
        
        try IERC721(collectionData.collectionAddress).ownerOf(tokenId) returns (address nftOwner) {
            // Get calibration with fallback
            Calibration memory calibration = _multiCalibrations[collectionId][tokenId];
            if (calibration.tokenId == 0 && collectionId < 3) {
                calibration = _calibrations[tokenId];
            }
            
            if (calibration.tokenId == 0) {
                // Return default for uninitialized tokens
                return Calibration({
                    tokenId: tokenId,
                    owner: nftOwner,
                    kinship: 50,
                    lastInteraction: 0,
                    experience: 0,
                    charge: 100,
                    lastCharge: 0,
                    level: 1,
                    prowess: 1,
                    wear: 0,
                    lastRecalibration: 0,
                    calibrationCount: 0,
                    locked: false,
                    agility: 10,
                    intelligence: 10,
                    bioLevel: 0
                });
            }
            
            // Return calibration with calculated values
            return Calibration({
                tokenId: calibration.tokenId,
                owner: calibration.owner, // Already correct from initialization
                kinship: uint8(_calculateKinship(collectionId, tokenId)),
                lastInteraction: calibration.lastInteraction,
                experience: calibration.experience,
                charge: uint8(_calculateCurrentCharge(collectionId, tokenId)),
                lastCharge: calibration.lastCharge,
                level: calibration.level,
                prowess: calibration.prowess,
                wear: uint8(_calculateCurrentWear(collectionId, tokenId)),
                lastRecalibration: calibration.lastRecalibration,
                calibrationCount: calibration.calibrationCount,
                locked: calibration.locked,
                agility: calibration.agility,
                intelligence: calibration.intelligence,
                bioLevel: uint8(_calculateCurrentBioLevel(collectionId, tokenId))
            });
        } catch {
            revert CalibrationNotAllowed(collectionId, tokenId);
        }
    }

    /**
     * @notice Update charge data for a token - fixed version
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param charge New charge level
     * @param timestamp Update timestamp
     * @return Success of operation
     */
    function updateChargeData(uint256 collectionId, uint256 tokenId, uint256 charge, uint256 timestamp) external whenNotPaused returns (bool) {
        if (!_approvedProcessors[_msgSender()]) {
            revert ProcessorNotApproved(_msgSender());
        }
        if (!_isCollectionValid(collectionId)) {
            revert CollectionNotRegistered(collectionId);
        }
        
        Calibration storage calibration = _multiCalibrations[collectionId][tokenId]; 
        
        if (calibration.tokenId == 0) {
            // Validate once and pass owner to initialization
            (, address owner) = _validateTokenAndAuth(collectionId, tokenId, _msgSender());
            if (owner == address(0)) {
                revert CalibrationNotAllowed(collectionId, tokenId);
            }
            _initializeCalibration(collectionId, tokenId, owner);
            calibration = _multiCalibrations[collectionId][tokenId];
        }
        
        SpecimenCollection memory collectionData = _collections[collectionId];
        uint256 maxCharge = CHARGE_MAX + collectionData.maxChargeBonus;
        calibration.charge = uint8(charge > maxCharge ? maxCharge : charge);
        calibration.lastCharge = timestamp;
        
        // SYNC: Keep legacy storage updated
        if (collectionId < 3) {
            _calibrations[tokenId] = calibration;
        }
        
        _chargeCounter++;
        
        emit ChargeDataUpdated(collectionId, tokenId, charge, timestamp, _msgSender());
        
        _synchronizeWithStaking(collectionId, tokenId, calibration.level, calibration.experience, charge);

        return true;
    }

    /**
     * @notice Update calibration status for a token - fixed version
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param level New calibration level
     * @param wear New wear level
     * @return Success of operation
     */
    function updateCalibrationStatus(uint256 collectionId, uint256 tokenId, uint256 level, uint256 wear) external whenNotPaused returns (bool) {
        if (!_approvedProcessors[_msgSender()]) {
            revert ProcessorNotApproved(_msgSender());
        }
        if (!_isCollectionValid(collectionId)) {
            revert CollectionNotRegistered(collectionId);
        }
        
        Calibration storage calibration = _multiCalibrations[collectionId][tokenId]; 
        
        if (calibration.tokenId == 0) {
            // Validate once and pass owner to initialization
            (, address owner) = _validateTokenAndAuth(collectionId, tokenId, _msgSender());
            if (owner == address(0)) {
                revert CalibrationNotAllowed(collectionId, tokenId);
            }
            _initializeCalibration(collectionId, tokenId, owner);
            calibration = _multiCalibrations[collectionId][tokenId];
        }
        
        uint256 oldWear = calibration.wear;
        uint256 oldLevel = calibration.level;
        
        calibration.level = uint8(level > MAX_LEVEL ? MAX_LEVEL : level);
        calibration.wear = uint8(wear > 100 ? 100 : wear);
        calibration.lastRecalibration = block.timestamp;
        
        // SYNC: Keep legacy storage updated
        if (collectionId < 3) {
            _calibrations[tokenId] = calibration;
        }
        
        emit CalibrationStatusUpdated(collectionId, tokenId, level, wear, _msgSender());
        
        if (oldWear != wear) {
            emit WearUpdated(collectionId, tokenId, oldWear, wear, _msgSender());
        }
        
        if (oldLevel < level) {
            emit SpecimenLevelUp(collectionId, tokenId, level);
        }
        
        _synchronizeWithStaking(collectionId, tokenId, level, calibration.experience, calibration.charge);
                
        return true;
    }

    function applyFatigue(uint256 collectionId, uint256 tokenId, uint256 amount) external whenNotPaused returns (bool) {
        if (!_approvedProcessors[_msgSender()]) {
            revert ProcessorNotApproved(_msgSender());
        }
        
        Calibration storage calibration = _multiCalibrations[collectionId][tokenId]; 
        if (calibration.tokenId == 0) {
            revert TokenNotInitialized();
        }
        
        uint256 oldWear = calibration.wear;
        uint256 newWear = calibration.wear + amount;
        calibration.wear = uint8(newWear > 100 ? 100 : newWear);
        
        emit FatigueApplied(collectionId, tokenId, amount, _msgSender());
        emit WearUpdated(collectionId, tokenId, oldWear, calibration.wear, _msgSender());
        
        return true;
    }

    function applyExperienceGain(uint256 collectionId, uint256 tokenId, uint256 amount) external whenNotPaused returns (bool) {
        if (!_approvedProcessors[_msgSender()]) {
            revert ProcessorNotApproved(_msgSender());
        }
        
        Calibration storage calibration = _multiCalibrations[collectionId][tokenId]; 
        if (calibration.tokenId == 0) {
            // Validate once and pass owner to initialization
            (, address owner) = _validateTokenAndAuth(collectionId, tokenId, _msgSender());
            if (owner == address(0)) {
                revert CalibrationNotAllowed(collectionId, tokenId);
            }
            _initializeCalibration(collectionId, tokenId, owner);
        }
        
        _addExperience(collectionId, tokenId, amount);
        
        if (stakingContract != address(0)) {
            calibration = _multiCalibrations[collectionId][tokenId]; // Refresh after _addExperience
            _synchronizeWithStaking(collectionId, tokenId, calibration.level, 
                                calibration.experience, calibration.charge);
        }
        
        return true;
    }

    function updateWearData(uint256 collectionId, uint256 tokenId, uint256 wear) external whenNotPaused returns (bool) {
        if (!_approvedProcessors[_msgSender()]) {
            revert ProcessorNotApproved(_msgSender());
        }
        
        Calibration storage calibration = _multiCalibrations[collectionId][tokenId]; 
        
        if (calibration.tokenId == 0) {
            // Validate once and pass owner to initialization
            (, address owner) = _validateTokenAndAuth(collectionId, tokenId, _msgSender());
            if (owner == address(0)) {
                revert CalibrationNotAllowed(collectionId, tokenId);
            }
            _initializeCalibration(collectionId, tokenId, owner);
            calibration = _multiCalibrations[collectionId][tokenId];
        }
        
        uint256 oldWear = calibration.wear;
        calibration.wear = uint8(wear > 100 ? 100 : wear);
        
        emit WearUpdated(collectionId, tokenId, oldWear, calibration.wear, _msgSender());
        
        return true;
    }

    function applyWearRepair(uint256 collectionId, uint256 tokenId, uint256 repairAmount) external whenNotPaused returns (bool) {
        if (!_approvedProcessors[_msgSender()]) {
            revert ProcessorNotApproved(_msgSender());
        }

        Calibration storage calibration = _multiCalibrations[collectionId][tokenId];

        if (calibration.tokenId == 0) {
            // Validate once and pass owner to initialization
            (, address owner) = _validateTokenAndAuth(collectionId, tokenId, _msgSender());
            if (owner == address(0)) {
                revert CalibrationNotAllowed(collectionId, tokenId);
            }
            _initializeCalibration(collectionId, tokenId, owner);
            calibration = _multiCalibrations[collectionId][tokenId];
        }

        // Calculate current wear INCLUDING time-based accumulation
        uint256 currentWear = _calculateCurrentWear(collectionId, tokenId);
        uint256 actualRepair = repairAmount > currentWear ? currentWear : repairAmount;
        uint256 newWear = currentWear - actualRepair;

        // Update stored wear and reset lastRecalibration to stop time accumulation
        calibration.wear = uint8(newWear);
        calibration.lastRecalibration = block.timestamp;

        emit WearRepaired(collectionId, tokenId, actualRepair, _msgSender());
        emit WearUpdated(collectionId, tokenId, currentWear, newWear, _msgSender());

        return true;
    }

    // Settings and approval functions
    function setCalibrationSettings(uint256 opCode, CalibrationSettings memory settings) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _calibrationSettings[opCode] = settings;
    }

    function setCollectionCalibrationSettings(uint256 collectionId, uint256 opCode, CalibrationSettings memory settings) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _multiSettings[collectionId][opCode] = settings;
    }

    function setProcessorApproval(address processor, bool approved) external override whenNotPaused {
        if (!hasRole(DEFAULT_ADMIN_ROLE, _msgSender()) && !hasRole(PROCESSOR_MANAGER_ROLE, _msgSender())) {
            revert RequestNotAuthorized();
        }
        if (processor == address(0)) {
            revert InvalidCallData();
        }
        
        _approvedProcessors[processor] = approved;
        emit ProcessorApprovalChanged(processor, approved);
    }

    function setStakingContract(address _stakingContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address _oldAddress = stakingContract;
        stakingContract = _stakingContract;
        
        if (_stakingContract != address(0) && !_approvedProcessors[_stakingContract]) {
            _approvedProcessors[_stakingContract] = true;
            emit ProcessorApprovalChanged(_stakingContract, true);
        }
        
        emit StakingContractChanged(_oldAddress, _stakingContract);
    }

    // View functions
    function requiredExperience(uint256 level) public pure returns (uint256) {
        if (level <= 1) return 0;
        if (level > MAX_LEVEL) return type(uint256).max;
        return level * level * 100;
    }

    function isProcessorApproved(address processor) external view override returns (bool) {
        return _approvedProcessors[processor];
    }

    function getStakeContract() external view returns (address) {
        return stakingContract;
    }

    function getTotalChargeUpdates() external view returns (uint256) {
        return _chargeCounter;
    }

    function hasCalibration(uint256 collectionId, uint256 tokenId) public view returns (bool) {
        if (_multiCalibrations[collectionId][tokenId].tokenId != 0) {
            return true;
        }
        
        if (collectionId == 2 && _calibrations[tokenId].tokenId != 0) {
            return true;
        }
        
        return false;
    }

    /**
     * @notice Get calibration data for multiple tokens (read-only)
     * @dev Helper function to extract current calibration state
     * @param tokenIds Array of token IDs
     * @return calibrations Array of calibration data
     */
    function getCalibrationsBatch(uint256 collectionId, uint256[] calldata tokenIds) 
        external 
        view 
        returns (Calibration[] memory calibrations) 
    {
        calibrations = new Calibration[](tokenIds.length);
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            calibrations[i] = _multiCalibrations[collectionId][tokenIds[i]];
        }
    }

    function batchHasCalibration(uint256 colletionId, uint256[] calldata tokenIds) external view returns (bool[] memory) {
        bool[] memory results = new bool[](tokenIds.length);
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            results[i] = _multiCalibrations[colletionId][tokenIds[i]].tokenId != 0;
        }
        
        return results;
    }

    // Internal helper functions
    function _isCollectionValid(uint256 collectionId) internal view returns (bool) {
        return _collections[collectionId].collectionAddress != address(0) && _collections[collectionId].enabled;
    }

    function _getCalibrationSettings(uint256 collectionId) internal view returns (CalibrationSettings memory) {
        CalibrationSettings memory settings = _multiSettings[collectionId][1];
        if (settings.interactPeriod == 0) {
            settings = _calibrationSettings[1];
        }
        return settings;
    }

    function _getRepository(uint256 collectionId) internal view returns (ICollectionRepository) {
        address repoAddress = _collections[collectionId].repositoryAddress;
        if (repoAddress != address(0)) {
            return ICollectionRepository(repoAddress);
        }
        return collectionRepository;
    }

    /**
     * @notice Initialize calibration for a token - fixed version
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param owner Token owner (already validated)
     */
    function _initializeCalibration(uint256 collectionId, uint256 tokenId, address owner) internal {
        _multiCalibrations[collectionId][tokenId] = Calibration({
            tokenId: tokenId,
            owner: owner, // Use already validated owner
            kinship: 50,
            lastInteraction: block.timestamp,
            experience: 0,
            charge: 100,
            lastCharge: 0,
            level: 1,
            prowess: 1,
            wear: 0,
            lastRecalibration: block.timestamp,
            calibrationCount: 0,
            locked: false,
            agility: 10,
            intelligence: 10,
            bioLevel: 0
        });
    }

    function _validateTokenAndAuth(uint256 collectionId, uint256 tokenId, address operator) private view returns (bool isValid, address actualOwner) {
        SpecimenCollection memory collectionData = _collections[collectionId];
        
        try IERC721(collectionData.collectionAddress).ownerOf(tokenId) returns (address tokenOwner) {
            // Direct ownership or approved processor
            if (tokenOwner == operator || _approvedProcessors[operator]) {
                return (true, tokenOwner);
            }
            
            // Staking scenarios
            if (stakingContract != address(0)) {
                // Token owned by staking contract
                if (tokenOwner == stakingContract) {
                    bool isStaker = IStakingDiamond(stakingContract).isTokenStaker(collectionId, tokenId, operator);
                    return (isStaker, isStaker ? operator : tokenOwner);
                }
                
                // Token in external vault
                (bool useExtVault, , address actualVault) = IStakingDiamond(stakingContract).getStakingVaultConfig();
                if (useExtVault && tokenOwner == actualVault) {
                    bool isStaker = IStakingDiamond(stakingContract).isTokenStaker(collectionId, tokenId, operator);
                    return (isStaker, isStaker ? operator : tokenOwner);
                }
            }
            
            return (false, tokenOwner);
        } catch {
            return (false, address(0));
        }
    }

    

    function _getTokenVariant(uint256 collectionId, uint256 tokenId) internal view returns (bool isValid, uint8 variant) {
        SpecimenCollection memory collectionData = _collections[collectionId];
        
        try ISpecimenCollection(collectionData.collectionAddress).itemVariant(tokenId) returns (uint8 result) {
            variant = result;
            isValid = (variant > 0 && variant <= 4);
        } catch {
        }
    }

    function _processInspection(
        uint256 collectionId,
        uint256 tokenId,
        uint8 variant,
        address owner,
        CalibrationSettings memory settings
    ) private returns (bool processed) {
        // Get storage reference to calibration
        Calibration storage calibration = _multiCalibrations[collectionId][tokenId];

        // Initialize if calibration doesn't exist
        if (calibration.tokenId == 0) {
            _initializeCalibration(collectionId, tokenId, owner); // Pass validated owner
            calibration = _multiCalibrations[collectionId][tokenId]; // Refresh reference
        }
        
        // Check cooldown period
        if (calibration.lastRecalibration != 0 && 
            block.timestamp < calibration.lastRecalibration + (settings.interactPeriod * 1 hours)) {
            return false;
        }

        // Process inspection
        uint256 newKinship = _calculateUpdatedKinship(collectionId, tokenId, settings);
        uint256 xpGain = _calculateExperienceGain(variant, calibration.level, 
                                                calibration.lastRecalibration, calibration.calibrationCount);
        
        calibration.kinship = uint8(newKinship);
        calibration.lastInteraction = block.timestamp;
        calibration.lastRecalibration = block.timestamp;
        calibration.calibrationCount += 1;

        // Random wear repair chance
        if (calibration.wear > 0 && _randomChance(tokenId, 33)) {
            calibration.wear -= 1;
        }
        
        _addExperience(collectionId, tokenId, xpGain);
        
        uint256 newLevel = calibration.level;
        calibration.bioLevel = uint8(_calculateCalibrationLevel(calibration, variant));
        
        emit InspectionHandled(collectionId, tokenId, newKinship, newLevel, xpGain);
        
        // Safe staking sync
        // _synchronizeWithStaking(collectionId, tokenId, newLevel, calibration.experience, calibration.charge);
        
        return true;
    }

    function _calculateUpdatedKinship(uint256 collectionId, uint256 tokenId, CalibrationSettings memory settings) private view returns (uint256) {
        uint256 tuneKinship = _calculateKinship(collectionId, tokenId);
        uint256 neglectBonus = (tuneKinship < 40) ? settings.tuneValue + 1 : 0;
        tuneKinship += settings.tuneValue + neglectBonus;
        return (tuneKinship > RECALIBRATION_MAX) ? RECALIBRATION_MAX : tuneKinship;
    }

    function _calculateKinship(uint256 collectionId, uint256 tokenId) internal view returns (uint256) {
        Calibration memory calibration = _multiCalibrations[collectionId][tokenId];
        
        // CHANGE 1: Early return for uninitialized tokens
        if (calibration.tokenId == 0) {
            return 50;  // Direct return instead of setting variable
        }
        
        // CHANGE 2: Use stored kinship for tokens without previous interaction
        if (calibration.lastInteraction == 0) {
            return calibration.kinship;  // ← FIX: Use actual stored value
        }
        
        // CHANGE 3: Use stored kinship as base for decay calculation
        CalibrationSettings memory settings = _getCalibrationSettings(collectionId);
        uint256 interval = block.timestamp - calibration.lastInteraction;
        uint256 daysPassed = interval / (settings.interactPeriod * 2 hours);
        
        return daysPassed >= calibration.kinship ? 0 : calibration.kinship - daysPassed;
    }

    function _calculateCurrentCharge(uint256 collectionId, uint256 tokenId) internal view returns (uint256) {
        Calibration memory calibration = _multiCalibrations[collectionId][tokenId];
        SpecimenCollection memory collectionData = _collections[collectionId];
        
        if (calibration.tokenId == 0 || calibration.lastCharge == 0 || calibration.charge == 0) {
            return calibration.charge;
        }
        
        uint256 timeSinceLastCharge = block.timestamp - calibration.lastCharge;
        uint256 daysElapsed = timeSinceLastCharge / (1 days);
        
        if (daysElapsed == 0) {
            return calibration.charge;
        }
        
        uint256 chargeLoss = (calibration.charge * daysElapsed * 5) / 100;
        chargeLoss = (chargeLoss * 100) / collectionData.regenMultiplier;
        
        return chargeLoss >= calibration.charge ? 0 : calibration.charge - chargeLoss;
    }

    function _calculateCurrentWear(uint256 collectionId, uint256 tokenId) internal view returns (uint256) {
        Calibration memory calibration = _multiCalibrations[collectionId][tokenId];
        
        if (calibration.lastRecalibration == 0) {
            return calibration.wear;
        }
        
        uint256 timeSinceCalibration = block.timestamp - calibration.lastRecalibration;
        uint256 weeksElapsed = timeSinceCalibration / (7 days);
        
        if (weeksElapsed == 0) {
            return calibration.wear;
        }
        
        uint256 newWear = calibration.wear + weeksElapsed;
        return newWear > 100 ? 100 : newWear;
    }

    function _calculateCurrentBioLevel(uint256 collectionId, uint256 tokenId) internal view returns (uint256) {
        Calibration memory calibration = _multiCalibrations[collectionId][tokenId];
        (, uint8 variant) = _getTokenVariant(collectionId, tokenId);
        
        Calibration memory calMemory = calibration;
        calMemory.kinship = uint8(_calculateKinship(collectionId, tokenId));
        calMemory.charge = uint8(_calculateCurrentCharge(collectionId, tokenId));
        calMemory.wear = uint8(_calculateCurrentWear(collectionId, tokenId));
        
        return _calculateCalibrationLevel(calMemory, variant);
    }

    function _synchronizeWithStaking(
        uint256 collectionId, 
        uint256 tokenId, 
        uint256 level, 
        uint256 experience, 
        uint256 charge
    ) internal {
        if (stakingContract == address(0)) {
            return;
        }
        
        try IStakingDiamond(stakingContract).updateTokenData(
            collectionId, 
            tokenId, 
            uint8(level), 
            experience, 
            uint8(charge)
        ) returns (bool success) {
            emit StakingSyncAttempted(collectionId, tokenId, success);
        } catch {
            emit StakingSyncAttempted(collectionId, tokenId, false);
        }
    }

    function _calculateExperienceGain(uint8 variant, uint256 level, uint256 timeSinceLastCalibration, uint256 calibrationCount) internal pure returns (uint256) {
        uint256 baseXP = 10 + (variant * 5);
        
        if (calibrationCount == 0) {
            return baseXP * 3;
        }
        
        uint256 daysSinceLastCalibration = timeSinceLastCalibration / 1 days;
        uint256 timeFactor = 100;
        
        if (daysSinceLastCalibration > 1) {
            if (daysSinceLastCalibration <= 7) {
                timeFactor = 100 + ((daysSinceLastCalibration - 1) * 50 / 6);
            } else {
                timeFactor = 150 + Math.sqrt((daysSinceLastCalibration - 7) * 100);
                timeFactor = timeFactor > 200 ? 200 : timeFactor;
            }
        }
        
        uint256 levelFactor = 100;
        if (level > 10) {
            if (level <= 50) {
                levelFactor = 100 - ((level - 10) * 50 / 40);
            } else {
                levelFactor = 50;
            }
        }
        
        return (baseXP * timeFactor * levelFactor) / 10000;
    }

    function _addExperience(uint256 collectionId, uint256 tokenId, uint256 amount) internal {
        Calibration storage calibration = _multiCalibrations[collectionId][tokenId];
        (bool isValidVariant, uint8 variant) = _getTokenVariant(collectionId, tokenId);
        
        if (!isValidVariant) {
            return;
        }
        
        calibration.experience += amount;
        
        // Level up logic
        uint256 currentXP = calibration.experience;
        uint256 currentLevel = calibration.level;
        uint256 newLevel = currentLevel;
        
        for (uint8 i = uint8(currentLevel + 1); i <= MAX_LEVEL; i++) {
            if (currentXP >= requiredExperience(i)) {
                newLevel = i;
            } else {
                break;
            }
        }
        
        if (newLevel > currentLevel) {
            for (uint8 i = uint8(currentLevel + 1); i <= newLevel; i++) {
                uint256 strengthGain = _variantStatGain(tokenId, variant, "prowess");
                uint256 agilityGain = _variantStatGain(tokenId, variant, "agility");
                uint256 intelligenceGain = _variantStatGain(tokenId, variant, "intelligence");
                
                calibration.agility += uint8(agilityGain);
                calibration.intelligence += uint8(intelligenceGain);
                calibration.prowess += uint8(strengthGain);
            }
            
            calibration.level = uint8(newLevel);
            emit SpecimenLevelUp(collectionId, tokenId, newLevel);
        }
        
        emit ExperienceGained(collectionId, tokenId, amount, calibration.experience);
    }

    function _calculateCalibrationLevel(Calibration memory calibration, uint8 variant) internal view returns (uint256) {
        uint8[5] memory baseCalibrationByForm = [40, 45, 50, 55, 60];
        uint256 baseCalibration = baseCalibrationByForm[variant];
        
        uint256 experienceBonus = 0;
        if (calibration.experience > 0) {
            experienceBonus = Math.sqrt(calibration.experience) / 2;
            experienceBonus = experienceBonus > 15 ? 15 : experienceBonus;
        }
        
        uint256 kinshipFactor = 0;
        if (calibration.kinship > 50) {
            kinshipFactor = (calibration.kinship - 50) / 5;
        }
        
        uint256 wearPenalty = 0;
        if (calibration.wear > 0) {
            wearPenalty = (calibration.wear * calibration.wear) / 400;
        }
        
        uint256 recalibrationPenalty = 0;
        if (calibration.lastRecalibration > 0) {
            uint256 daysSinceRecalibration = (block.timestamp - calibration.lastRecalibration) / 1 days;
            
            if (daysSinceRecalibration > 0) {
                if (daysSinceRecalibration <= 7) {
                    recalibrationPenalty = daysSinceRecalibration * 10 / 7;
                } else {
                    recalibrationPenalty = 10 + ((daysSinceRecalibration - 7) * 20 / 23);
                    recalibrationPenalty = recalibrationPenalty > 30 ? 30 : recalibrationPenalty;
                }
            }
        }
        
        int256 formModifier = 0;
        if (variant == 0) {
            formModifier = -5;
        } else if (variant == 3) {
            formModifier = 3;
        } else if (variant == 4) {
            formModifier = 5;
        }
        
        int256 calibrationValue = int256(baseCalibration) + 
                                int256(experienceBonus) + 
                                int256(kinshipFactor) - 
                                int256(wearPenalty) - 
                                int256(recalibrationPenalty) +
                                formModifier;
        
        if (calibrationValue < 0) return 0;
        if (calibrationValue > 100) return 100;
        
        return uint256(calibrationValue);
    }

    function _variantStatGain(uint256 tokenId, uint8 variant, string memory statType) internal view returns (uint256) {
        uint256 baseValue = variant == 1 ? 1 : variant == 2 ? 2 : variant == 3 ? 2 : variant == 4 ? 3 : 1;
        
        if (keccak256(abi.encodePacked(statType)) == keccak256(abi.encodePacked("prowess"))) {
            if (variant == 3 || variant == 4) baseValue += 1;
        } else if (keccak256(abi.encodePacked(statType)) == keccak256(abi.encodePacked("agility"))) {
            if (variant == 2 || variant == 4) baseValue += 1;
        } else if (keccak256(abi.encodePacked(statType)) == keccak256(abi.encodePacked("intelligence"))) {
            if (variant == 2 || variant == 4) baseValue += 1;
        }
        
        uint256 randomFactor = uint256(keccak256(abi.encodePacked(block.timestamp, tokenId, statType))) % 3;
        return randomFactor == 0 ? baseValue - 1 : (randomFactor == 1 ? baseValue : baseValue + 1);
    }

    function _randomChance(uint256 tokenId, uint256 percentage) internal view returns (bool) {
        uint256 randomValue = uint256(keccak256(abi.encodePacked(block.timestamp, tokenId, _msgSender()))) % 100;
        return randomValue < percentage;
    }

    function _collectFee(IERC20 currency, address from, address to, uint256 amount, bool burnOnCollect) internal returns (uint256) {
        if (amount > 0) {
            if (burnOnCollect) {
                // Collect to beneficiary and burn
                currency.safeTransferFrom(from, to, amount);
                IYellowToken(address(currency)).burnFrom(to, amount, "inspection");
                emit FeeBurned(to, amount, "inspection");
            } else {
                // Standard transfer
                currency.safeTransferFrom(from, to, amount);
            }
            return amount;
        }
        return 0;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}