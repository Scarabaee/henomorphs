// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {PodsUtils} from "../../libraries/PodsUtils.sol";

/**
 * @title ColonyWarsConfigFacet
 * @notice Configuration and administration functions for Colony Wars system
 * @dev Handles initialization, configuration updates, and administrative functions
 */
contract ColonyWarsConfigFacet is AccessControlBase {
    using Strings for uint256;
    using Strings for uint32;
    
    // Events
    event ConfigUpdated(string parameter, uint256 oldValue, uint256 newValue);
    event ColonyProfilesCleared(uint256 count);
    event SeasonCleared(uint32 seasonId);
    event SeasonStarted(uint32 indexed seasonId, uint32 startTime);
    event AdminStakeOverride(
        bytes32 indexed colonyId, 
        uint256 oldStake, 
        uint256 newStake, 
        string reason
    );
    event AdminTokensReleased(
        uint256[] collectionIds,
        uint256[] tokenIds,
        uint256 releasedCount, 
        string reason
    );

    event SeasonUpdated(
        uint32 indexed seasonId,
        uint32 startTime,
        uint32 registrationEnd,
        uint32 warfareEnd,
        uint32 resolutionEnd,
        bool active,
        uint256 prizePool
    );

    event SeasonPrizeDistributed(
        uint32 indexed seasonId,
        bytes32 indexed colonyId,
        address recipient,
        uint256 amount,
        uint256 rank,
        uint256 score
    );

    event SeasonPrizesCompleted(
        uint32 indexed seasonId,
        uint256 totalDistributed,
        uint256 winnersCount
    );
    event SeasonEnded(uint32 indexed seasonId, uint256 endTime);
    event SeasonCounterUpdated(uint32 oldValue, uint32 newValue);
    event ColonyUnregisteredFromSeason(
        bytes32 indexed colonyId, 
        uint32 indexed seasonId, 
        uint256 refundAmount, 
        uint256 penaltyAmount
    );

    error ConfigValueOutOfRange();

    // Custom errors
    error ColonyWarsNotInitialized();
    error InvalidConfigValue(string parameter);
    error InvalidTokenCount();
    error ColonyNotRegistered();
    error ResolutionNotReady();
    
    
    /**
     * @notice Initialize Colony Wars system
     */
    function initializeColonyWars(address auxiliaryCurrency) external onlyAuthorized {
        LibColonyWarsStorage.initializeStorage();
        
        // Initialize operation fees
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        if (auxiliaryCurrency != address(0) && hs.chargeTreasury.auxiliaryCurrency == address(0)) {
            hs.chargeTreasury.auxiliaryCurrency = auxiliaryCurrency;
        }

        address operationCurrency = (hs.chargeTreasury.auxiliaryCurrency != address(0))
            ? hs.chargeTreasury.auxiliaryCurrency
            : auxiliaryCurrency;        
            
        LibColonyWarsStorage.initializeOperationFees(
            hs.chargeTreasury.treasuryAddress,
            operationCurrency
        );
    }

    /**
     * @notice Check if a specific feature is paused in the Colony Wars system
     */
    function checkColonyWarsFeatue(string calldata feature) external view returns (bool) {
       LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        return cws.featurePaused[feature];
    }

    /**
     * @notice Update configuration parameter with validation
     * @param parameter Name of parameter to update
     * @param value New value for the parameter
     */
    function updateWarsConfig(string calldata parameter, uint256 value) external onlyAuthorized {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ColonyWarsConfig storage config = cws.config;
        
        bytes32 paramHash = keccak256(bytes(parameter));
        uint256 oldValue;
        
        // Validate and update configuration parameters
        if (paramHash == keccak256("minStakeAmount")) {
            if (value == 0) revert InvalidConfigValue(parameter);
            oldValue = config.minStakeAmount;
            config.minStakeAmount = value;
        }
        else if (paramHash == keccak256("maxStakeAmount")) {
            if (value == 0 || value < config.minStakeAmount) revert InvalidConfigValue(parameter);
            oldValue = config.maxStakeAmount;
            config.maxStakeAmount = value;
        }
        else if (paramHash == keccak256("attackCooldown")) {
            if (value < 3600) revert InvalidConfigValue(parameter);
            oldValue = config.attackCooldown;
            config.attackCooldown = uint32(value);
        }
        else if (paramHash == keccak256("winnerSharePercentage")) {
            if (value == 0 || value > 90) revert InvalidConfigValue(parameter);
            oldValue = config.winnerSharePercentage;
            config.winnerSharePercentage = uint8(value);
        }
        else if (paramHash == keccak256("maxBattleTokens")) {
            if (value == 0 || value > 50) revert InvalidConfigValue(parameter);
            oldValue = config.maxBattleTokens;
            config.maxBattleTokens = uint8(value);
        } else if (paramHash == keccak256("dailyMaintenanceCost")) {
            if (value == 0) revert InvalidConfigValue(parameter);
            oldValue = config.dailyMaintenanceCost;
            config.dailyMaintenanceCost = value;
        }
        else if (paramHash == keccak256("territoryCaptureCost")) {
            if (value == 0) revert InvalidConfigValue(parameter);
            oldValue = config.territoryCaptureCost;
            config.territoryCaptureCost = value;
        }
        else if (paramHash == keccak256("allianceFormationCost")) {
            if (value == 0) revert InvalidConfigValue(parameter);
            oldValue = config.allianceFormationCost;
            config.allianceFormationCost = value;
        }
        else if (paramHash == keccak256("emergencyLoanLimit")) {
            if (value == 0) revert InvalidConfigValue(parameter);
            oldValue = config.emergencyLoanLimit;
            config.emergencyLoanLimit = value;
        }
        else if (paramHash == keccak256("maxAllianceMembers")) {
            if (value == 0 || value > 20) revert InvalidConfigValue(parameter);
            oldValue = config.maxAllianceMembers;
            config.maxAllianceMembers = uint8(value);
        }
        else if (paramHash == keccak256("maxTerritoriesPerColony")) {
            if (value == 0 || value > 18) revert InvalidConfigValue(parameter);
            oldValue = config.maxTerritoriesPerColony;
            config.maxTerritoriesPerColony = uint8(value);
        }
        else if (paramHash == keccak256("betrayalCooldown")) {
            if (value < 86400) revert InvalidConfigValue(parameter);
            oldValue = config.betrayalCooldown;
            config.betrayalCooldown = uint32(value);
        }
        else if (paramHash == keccak256("initialInterestRate")) {
            if (value == 0 || value > 50) revert InvalidConfigValue(parameter);
            oldValue = config.initialInterestRate;
            config.initialInterestRate = uint8(value);
        }
        else if (paramHash == keccak256("maxInterestRate")) {
            if (value == 0 || value > 100) revert InvalidConfigValue(parameter);
            oldValue = config.maxInterestRate;
            config.maxInterestRate = uint8(value);
        } else if (paramHash == keccak256("battleDuration")) {
            if (value < 1800) revert InvalidConfigValue(parameter); // Min 30 minutes
            oldValue = config.battleDuration;
            config.battleDuration = uint32(value);
        }
        else if (paramHash == keccak256("battlePreparationTime")) {
            if (value < 600) revert InvalidConfigValue(parameter); // Min 10 minutes
            oldValue = config.battlePreparationTime;
            config.battlePreparationTime = uint32(value);
        }
        else if (paramHash == keccak256("registrationPeriod")) {
            if (value < 86400) revert InvalidConfigValue(parameter); // Min 1 day
            oldValue = config.registrationPeriod;
            config.registrationPeriod = uint32(value);
        }
        else if (paramHash == keccak256("seasonDuration")) {
            if (value < 604800) revert InvalidConfigValue(parameter); // Min 1 week
            oldValue = config.seasonDuration;
            config.seasonDuration = uint32(value);
        }
        else if (paramHash == keccak256("stakeIncreaseCooldown")) {
            if (value < 604800) revert InvalidConfigValue(parameter); // Min 1 week
            oldValue = config.stakeIncreaseCooldown;
            config.stakeIncreaseCooldown = uint32(value);
        }
        else if (paramHash == keccak256("stakePenaltyCooldown")) {
            if (value < 1800) revert InvalidConfigValue(parameter); // Min 30 minutes
            oldValue = config.stakePenaltyCooldown;
            config.stakePenaltyCooldown = uint32(value);
        }
        else if (paramHash == keccak256("stakePenaltyCooldown")) {
            if (value < 1800) revert InvalidConfigValue(parameter); // Min 30 minutes
            oldValue = config.stakePenaltyCooldown;
            config.stakePenaltyCooldown = uint32(value);
        }
        else if (paramHash == keccak256("autoDefenseTokenCount")) {
            if (value == 0 || value > 10) revert InvalidConfigValue(parameter);
            oldValue = config.autoDefenseTokenCount;
            config.autoDefenseTokenCount = uint8(value);
        }
        else if (paramHash == keccak256("autoDefensePenalty")) {
            if (value < 10 || value > 90) revert InvalidConfigValue(parameter);
            oldValue = config.autoDefensePenalty;
            config.autoDefensePenalty = uint8(value);
        }
        else if (paramHash == keccak256("enableAutoDefense")) {
            oldValue = config.enableAutoDefense ? 1 : 0;
            config.enableAutoDefense = (value != 0);
        }
        else if (paramHash == keccak256("autoDefenseTimeout")) {
            if (value < 1800) revert InvalidConfigValue(parameter); // Min 2 hours
            oldValue = config.autoDefenseTimeout;
            config.autoDefenseTimeout = uint32(value);
        }
        else if (paramHash == keccak256("maxGlobalTerritories")) {
            if (value == 0 || value > 150) revert InvalidConfigValue(parameter);
            oldValue = config.maxGlobalTerritories;
            config.maxGlobalTerritories = uint8(value);
        }
        // === Operation Fee Configurations ===
        // raid
        else if (paramHash == keccak256("raidFeeAmount")) {
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_RAID);
            oldValue = fee.baseAmount;
            fee.baseAmount = value;
        }
        else if (paramHash == keccak256("raidFeeMultiplier")) {
            if (value == 0) revert InvalidConfigValue(parameter);
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_RAID);
            oldValue = fee.multiplier;
            fee.multiplier = value;
        }
        else if (paramHash == keccak256("raidFeeBurn")) {
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_RAID);
            oldValue = fee.burnOnCollect ? 1 : 0;
            fee.burnOnCollect = (value != 0);
        }
        else if (paramHash == keccak256("raidFeeEnabled")) {
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_RAID);
            oldValue = fee.enabled ? 1 : 0;
            fee.enabled = (value != 0);
        }
        // maintenance
        else if (paramHash == keccak256("maintenanceFeeAmount")) {
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_MAINTENANCE);
            oldValue = fee.baseAmount;
            fee.baseAmount = value;
        }
        else if (paramHash == keccak256("maintenanceFeeMultiplier")) {
            if (value == 0) revert InvalidConfigValue(parameter);
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_MAINTENANCE);
            oldValue = fee.multiplier;
            fee.multiplier = value;
        }
        else if (paramHash == keccak256("maintenanceFeeBurn")) {
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_MAINTENANCE);
            oldValue = fee.burnOnCollect ? 1 : 0;
            fee.burnOnCollect = (value != 0);
        }
        else if (paramHash == keccak256("maintenanceFeeEnabled")) {
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_MAINTENANCE);
            oldValue = fee.enabled ? 1 : 0;
            fee.enabled = (value != 0);
        }
        // repair
        else if (paramHash == keccak256("repairFeeAmount")) {
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_REPAIR);
            oldValue = fee.baseAmount;
            fee.baseAmount = value;
        }
        else if (paramHash == keccak256("repairFeeMultiplier")) {
            if (value == 0) revert InvalidConfigValue(parameter);
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_REPAIR);
            oldValue = fee.multiplier;
            fee.multiplier = value;
        }
        else if (paramHash == keccak256("repairFeeBurn")) {
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_REPAIR);
            oldValue = fee.burnOnCollect ? 1 : 0;
            fee.burnOnCollect = (value != 0);
        }
        else if (paramHash == keccak256("repairFeeEnabled")) {
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_REPAIR);
            oldValue = fee.enabled ? 1 : 0;
            fee.enabled = (value != 0);
        }
        // scouting
        else if (paramHash == keccak256("scoutingFeeAmount")) {
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_SCOUTING);
            oldValue = fee.baseAmount;
            fee.baseAmount = value;
        }
        else if (paramHash == keccak256("scoutingFeeMultiplier")) {
            if (value == 0) revert InvalidConfigValue(parameter);
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_SCOUTING);
            oldValue = fee.multiplier;
            fee.multiplier = value;
        }
        else if (paramHash == keccak256("scoutingFeeBurn")) {
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_SCOUTING);
            oldValue = fee.burnOnCollect ? 1 : 0;
            fee.burnOnCollect = (value != 0);
        }
        else if (paramHash == keccak256("scoutingFeeEnabled")) {
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_SCOUTING);
            oldValue = fee.enabled ? 1 : 0;
            fee.enabled = (value != 0);
        }
        // healing
        else if (paramHash == keccak256("healingFeeAmount")) {
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_HEALING);
            oldValue = fee.baseAmount;
            fee.baseAmount = value;
        }
        else if (paramHash == keccak256("healingFeeMultiplier")) {
            if (value == 0) revert InvalidConfigValue(parameter);
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_HEALING);
            oldValue = fee.multiplier;
            fee.multiplier = value;
        }
        else if (paramHash == keccak256("healingFeeBurn")) {
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_HEALING);
            oldValue = fee.burnOnCollect ? 1 : 0;
            fee.burnOnCollect = (value != 0);
        }
        else if (paramHash == keccak256("healingFeeEnabled")) {
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_HEALING);
            oldValue = fee.enabled ? 1 : 0;
            fee.enabled = (value != 0);
        }
        // processing
        else if (paramHash == keccak256("processingFeeAmount")) {
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_PROCESSING);
            oldValue = fee.baseAmount;
            fee.baseAmount = value;
        }
        else if (paramHash == keccak256("processingFeeMultiplier")) {
            if (value == 0) revert InvalidConfigValue(parameter);
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_PROCESSING);
            oldValue = fee.multiplier;
            fee.multiplier = value;
        }
        else if (paramHash == keccak256("processingFeeBurn")) {
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_PROCESSING);
            oldValue = fee.burnOnCollect ? 1 : 0;
            fee.burnOnCollect = (value != 0);
        }
        else if (paramHash == keccak256("processingFeeEnabled")) {
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_PROCESSING);
            oldValue = fee.enabled ? 1 : 0;
            fee.enabled = (value != 0);
        }
        // listing
        else if (paramHash == keccak256("listingFeeAmount")) {
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_LISTING);
            oldValue = fee.baseAmount;
            fee.baseAmount = value;
        }
        else if (paramHash == keccak256("listingFeeMultiplier")) {
            if (value == 0) revert InvalidConfigValue(parameter);
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_LISTING);
            oldValue = fee.multiplier;
            fee.multiplier = value;
        }
        else if (paramHash == keccak256("listingFeeBurn")) {
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_LISTING);
            oldValue = fee.burnOnCollect ? 1 : 0;
            fee.burnOnCollect = (value != 0);
        }
        else if (paramHash == keccak256("listingFeeEnabled")) {
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_LISTING);
            oldValue = fee.enabled ? 1 : 0;
            fee.enabled = (value != 0);
        }
        // crafting
        else if (paramHash == keccak256("craftingFeeAmount")) {
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_CRAFTING);
            oldValue = fee.baseAmount;
            fee.baseAmount = value;
        }
        else if (paramHash == keccak256("craftingFeeMultiplier")) {
            if (value == 0) revert InvalidConfigValue(parameter);
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_CRAFTING);
            oldValue = fee.multiplier;
            fee.multiplier = value;
        }
        else if (paramHash == keccak256("craftingFeeBurn")) {
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_CRAFTING);
            oldValue = fee.burnOnCollect ? 1 : 0;
            fee.burnOnCollect = (value != 0);
        }
        else if (paramHash == keccak256("craftingFeeEnabled")) {
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_CRAFTING);
            oldValue = fee.enabled ? 1 : 0;
            fee.enabled = (value != 0);
        }
        else {
            revert InvalidConfigValue(parameter);
        }
        
        emit ConfigUpdated(parameter, oldValue, value);
    }

    /**
     * @notice Configure operation fee (all parameters)
     * @param feeName Fee name: "raid", "maintenance", "repair", "scouting", "healing", "processing", "listing", "crafting"
     * @param currency Token address
     * @param beneficiary Beneficiary address
     * @param baseAmount Base fee amount
     * @param multiplier Fee multiplier (100 = 1x)
     * @param burnOnCollect Whether to burn tokens
     * @param enabled Whether fee is enabled
     */
    function configureOperationFee(
        string calldata feeName,
        address currency,
        address beneficiary,
        uint256 baseAmount,
        uint256 multiplier,
        bool burnOnCollect,
        bool enabled
    ) external onlyAuthorized {
        LibColonyWarsStorage.requireInitialized();

        if (currency == address(0)) revert InvalidConfigValue("currency");
        if (beneficiary == address(0)) revert InvalidConfigValue("beneficiary");
        if (multiplier == 0) revert InvalidConfigValue("multiplier");

        LibColonyWarsStorage.OperationFee memory opFee = LibColonyWarsStorage.OperationFee({
            currency: currency,
            beneficiary: beneficiary,
            baseAmount: baseAmount,
            multiplier: multiplier,
            burnOnCollect: burnOnCollect,
            enabled: enabled
        });

        LibColonyWarsStorage.setOperationFeeByName(feeName, opFee);

        emit ConfigUpdated(string.concat("operationFee_", feeName), 0, 1);
    }

    /**
     * @notice Configure battle modifiers
     * @param winStreakBonus Bonus for consecutive wins (0-30%)
     * @param debtPenalty Penalty for high debt (0-40%)
     * @param territoryBonus Bonus per territory (0-15%)
     * @param decayTime Win streak decay time (1-7 days)
     */
    function configureBattleModifiers(
        uint8 winStreakBonus,
        uint8 debtPenalty,
        uint8 territoryBonus,
        uint32 decayTime
    ) external onlyAuthorized {
        LibColonyWarsStorage.requireInitialized();
        
        if (winStreakBonus > 30) revert ConfigValueOutOfRange();
        if (debtPenalty > 40) revert ConfigValueOutOfRange();
        if (territoryBonus > 15) revert ConfigValueOutOfRange();
        if (decayTime < 86400 || decayTime > 604800) revert ConfigValueOutOfRange();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        cws.battleModifiers.winStreakBonus = winStreakBonus;
        cws.battleModifiers.debtPenalty = debtPenalty;
        cws.battleModifiers.territoryBonus = territoryBonus;
        cws.battleModifiers.winStreakDecayTime = decayTime;
        
        emit ConfigUpdated("battleModifiers", 0, 1);
    }
    
    /**
     * @notice Pause/unpause specific features for emergency control
     * @param featureName Name of feature to control
     * @param paused Whether to pause the feature
     */
    function pauseFeature(string calldata featureName, bool paused) external onlyAuthorized {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        cws.featurePaused[featureName] = paused;
    }

    /**
     * @notice Emergency reset function - clears all game data
     * @dev DESTRUCTIVE: Removes all seasons, territories, alliances, battles, and debts
     * @param value Must be 1 to confirm action
     * @param counterHash Must equal keccak256("battle") or keccak256("territory") or keccak256("season") or keccak256("RESET_ALL_DATA") to reset all counters
     */
    function emergencyCountersReset(uint256 value, bytes32 counterHash) external onlyAuthorized {
        require(counterHash == keccak256("RESET_ALL_DATA") || counterHash == keccak256("battle") || counterHash == keccak256("territory") || counterHash == keccak256("season"), "Invalid confirmation");
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        // Reset counters
        if (counterHash == keccak256("battle")) {
            cws.battleCounter = value;
        } else if (counterHash == keccak256("territory")) {
            cws.territoryCounter = value;
        } else if (counterHash == keccak256("season")) {
            cws.currentSeason = uint32(value);
        } else if (counterHash == keccak256("RESET_ALL_DATA")) {
            cws.battleCounter = value;
            cws.territoryCounter = value;
            cws.currentSeason = uint32(value);
        }
    }

    /**
     * @notice Start new warfare season with configurable parameters
     * @param startTime Season start timestamp (0 for current time)
     */
    function startNewWarsSeason(uint256 startTime) external onlyAuthorized whenNotPaused {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        uint32 newSeasonId = cws.currentSeason + 1;
        uint32 currentTime = (startTime == 0 ? uint32(block.timestamp) : uint32(startTime));

        LibColonyWarsStorage.Season storage newSeason = cws.seasons[newSeasonId];
        newSeason.seasonId = newSeasonId;
        newSeason.startTime = currentTime;
        newSeason.registrationEnd = currentTime + cws.config.registrationPeriod;
        newSeason.warfareEnd = currentTime + cws.config.registrationPeriod + (cws.config.seasonDuration - cws.config.registrationPeriod) * 2 / 3;
        newSeason.resolutionEnd = currentTime + cws.config.seasonDuration;
        newSeason.active = true;
        
        cws.currentSeason = newSeasonId;
        
        emit SeasonStarted(newSeasonId, currentTime);
    }

    function endWarsSeason(uint32 seasonId) external onlyAuthorized {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Season storage s = cws.seasons[seasonId];

        if (s.rewarded || block.timestamp <= s.warfareEnd || block.timestamp > s.resolutionEnd) {
            revert ResolutionNotReady();
        }
        
        // 1. Cleanup nierozstrzygniętych bitew i sieges
        _cleanupSeasonBattles(seasonId);
        _cleanupSeasonSieges(seasonId);
        
        // 2. Reset liczników dla nowego sezonu
        _resetSeasonCounters(seasonId);
        
        // 3. Obsłuż długi (opcjonalnie)
        // _handleSeasonDebts(seasonId);
        
        // 4. Rozdaj nagrody
        if (s.registeredColonies.length > 0 && s.prizePool > 0) {
            _distributeProportionalPrizes(seasonId, s.prizePool);
        }
        
        // 5. Zapisz podsumowanie
        // _saveSeasonSummary(seasonId);
        
        // 6. Oznacz sezon jako zakończony
        s.rewarded = true;
        s.active = false;
        
        emit SeasonEnded(seasonId, block.timestamp);
    }

    /**
     * @notice Update all season parameters
     * @param seasonId Season to update
     * @param startTime New start timestamp (0 to keep current)
     * @param registrationEnd New registration end timestamp
     * @param warfareEnd New warfare end timestamp
     * @param resolutionEnd New resolution end timestamp
     * @param active New active status
     * @param prizePool New prize pool amount (0 to keep current)
     */
    function updateWarsSeason(
        uint32 seasonId,
        uint32 startTime,
        uint32 registrationEnd,
        uint32 warfareEnd,
        uint32 resolutionEnd,
        bool active,
        uint256 prizePool
    ) external onlyAuthorized {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Season storage season = cws.seasons[seasonId];
        
        // Basic validation
        if (season.seasonId != seasonId && seasonId == 0) {
            revert InvalidConfigValue("seasonId");
        }
        
        if (season.rewarded) {
            revert InvalidConfigValue("Season already rewarded");
        }
        
        // Update startTime if provided
        if (startTime > 0) {
            season.startTime = startTime;
        }
        
        // Use existing or new startTime for validation
        uint32 effectiveStartTime = startTime > 0 ? startTime : season.startTime;
        
        // Validate timestamp order
        if (registrationEnd <= effectiveStartTime) {
            revert InvalidConfigValue("registrationEnd");
        }
        
        if (warfareEnd <= registrationEnd) {
            revert InvalidConfigValue("warfareEnd");
        }
        
        if (resolutionEnd <= warfareEnd) {
            revert InvalidConfigValue("resolutionEnd");
        }
        
        // Update all parameters
        season.seasonId = seasonId;
        season.registrationEnd = registrationEnd;
        season.warfareEnd = warfareEnd;
        season.resolutionEnd = resolutionEnd;
        season.active = active;
        
        // Update prize pool if provided
        if (prizePool > 0) {
            season.prizePool = prizePool;
        }
        
        emit SeasonUpdated(
            seasonId,
            effectiveStartTime,
            registrationEnd,
            warfareEnd,
            resolutionEnd,
            active,
            season.prizePool
        );
    }

    /**
     * @notice Clear specific season data
     * @param seasonId Season to clear
     */
    function clearWarsSeason(uint32 seasonId) external onlyAuthorized {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        // Reset season
        delete cws.seasons[seasonId];
        
        // Clear season scores (requires iteration through registered colonies)
        // This is gas-intensive for large numbers
        
        emit SeasonCleared(seasonId);
    }

    /**
     * @notice Clear colony war profiles
     * @param colonyIds Array of colony IDs to reset
     */
    function clearColonyProfiles(bytes32[] calldata colonyIds) external onlyAuthorized {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        for (uint256 i = 0; i < colonyIds.length && i < 50; i++) { // Gas limit
            delete cws.colonyWarProfiles[colonyIds[i]];
        }
        
        emit ColonyProfilesCleared(colonyIds.length);
    }

    /**
     * @notice Admin override for colony defensive stake (emergency/correction use)
     * @param colonyId Colony to modify
     * @param newStakeAmount New defensive stake amount
     * @param reason Reason for override (for transparency)
     */
    function overrideDefensiveStake(
        bytes32 colonyId,
        uint256 newStakeAmount,
        string calldata reason
    ) 
        external 
        onlyAuthorized 
        whenNotPaused 
    {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
        
        // Basic validation - must be registered colony
        if (!profile.registered) {
            revert ColonyNotRegistered();
        }
        
        // Optional: Respect min/max limits (remove if you want full override)
        if (newStakeAmount > cws.config.maxStakeAmount) {
            revert InvalidConfigValue("newStakeAmount");
        }
        
        uint256 oldStake = profile.defensiveStake;
        profile.defensiveStake = newStakeAmount;
        
        emit AdminStakeOverride(colonyId, oldStake, newStakeAmount, reason);
    }

    /**
     * @notice Admin emergency token release - unblocks tokens stuck in battles
     * @param collectionIds Array of collection IDs
     * @param tokenIds Array of token IDs
     * @param reason Reason for admin intervention (for audit trail)
     */
    function adminReleaseTokens(
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds,
        string calldata reason
    ) 
        external 
        onlyAuthorized 
    {
        LibColonyWarsStorage.requireInitialized();
        
        if (collectionIds.length != tokenIds.length) {
            revert InvalidTokenCount();
        }
        
        if (collectionIds.length == 0 || collectionIds.length > 50) {
            revert InvalidTokenCount();
        }
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        uint256 releasedCount = 0;
        
        for (uint256 i = 0; i < collectionIds.length; i++) {
            uint256 combinedId = PodsUtils.combineIds(collectionIds[i], tokenIds[i]);
            
            // Only release if token is actually blocked
            if (cws.tokenBattleEndTime[combinedId] > uint32(block.timestamp)) {
                LibColonyWarsStorage.releaseToken(combinedId);
                releasedCount++;
            }
        }
        
        emit AdminTokensReleased(collectionIds, tokenIds, releasedCount, reason);
    }

    
    /**
     * @notice Administrative unregister colony from season with full refund
     * @dev Bypasses time restrictions, battle checks, and alliance checks
     * @param colonyId Colony to unregister
     */
    function adminUnregisterFromSeason(bytes32 colonyId)
        external
        onlyAuthorized
        nonReentrant
    {
        LibColonyWarsStorage.requireInitialized();

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        uint32 currentSeason = cws.currentSeason;
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];

        // Verify colony is registered
        if (!profile.registered) {
            revert ColonyNotRegistered();
        }

        // Get colony creator for refund
        address colonyCreator = hs.colonyCreators[colonyId];

        // Full refund - no penalty for admin unregistration
        uint256 refundAmount = profile.defensiveStake;

        // Remove from season tracking
        _removeColonyFromSeason(colonyId, currentSeason, cws);

        // Reset colony profile
        profile.defensiveStake = 0;
        profile.acceptingChallenges = false;
        profile.registered = false;

        // Check if this was user's primary colony
        bytes32 userPrimary = LibColonyWarsStorage.getUserPrimaryColony(colonyCreator);
        if (userPrimary == colonyId) {
            // Set new primary from remaining colonies
            bytes32[] memory userColonies = LibColonyWarsStorage.getUserSeasonColonies(currentSeason, colonyCreator);
            bytes32 newPrimary = bytes32(0);

            for (uint256 i = 0; i < userColonies.length; i++) {
                if (userColonies[i] != colonyId && cws.colonyWarProfiles[userColonies[i]].registered) {
                    newPrimary = userColonies[i];
                    break;
                }
            }

            LibColonyWarsStorage.setUserPrimaryColony(colonyCreator, newPrimary);
            cws.userToColony[colonyCreator] = newPrimary;
        }

        // Remove from user's season colonies array
        _removeFromUserSeasonColonies(colonyId, currentSeason, colonyCreator, cws);

        // Process full refund to colony creator
        if (refundAmount > 0) {
            LibFeeCollection.transferFromTreasury(
                colonyCreator,
                refundAmount,
                "admin_colony_unregistration_refund"
            );
        }

        // No penalty - full refund goes back to user
        emit ColonyUnregisteredFromSeason(colonyId, currentSeason, refundAmount, 0);
    }

    // View functions

    /**
     * @notice Get current wars configuration
     * @return config Current configuration struct
     */
    function getColonyWarsConfig() external view returns (LibColonyWarsStorage.ColonyWarsConfig memory) {
        return LibColonyWarsStorage.colonyWarsStorage().config;
    }
    
    /**
     * @notice Get operation fee configuration
     * @param feeName Fee name: "raid", "maintenance", "repair", "scouting", "healing", "processing", "listing", "crafting"
     * @return currency Token address
     * @return beneficiary Beneficiary address
     * @return baseAmount Base fee amount
     * @return multiplier Fee multiplier (100 = 1x)
     * @return burnOnCollect Whether tokens are burned
     * @return enabled Whether fee is enabled
     */
    function getOperationFee(string calldata feeName)
        external
        view
        returns (
            address currency,
            address beneficiary,
            uint256 baseAmount,
            uint256 multiplier,
            bool burnOnCollect,
            bool enabled
        )
    {
        LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFeeByName(feeName);

        return (
            fee.currency,
            fee.beneficiary,
            fee.baseAmount,
            fee.multiplier,
            fee.burnOnCollect,
            fee.enabled
        );
    }
    
    /**
     * @notice Get all operation fees summary
     * @return feeNames Array of fee names
     * @return baseAmounts Array of base amounts
     * @return burnFlags Array of burn flags
     * @return enabledFlags Array of enabled flags
     */
    function getAllOperationFees()
        external
        view
        returns (
            string[8] memory feeNames,
            uint256[8] memory baseAmounts,
            bool[8] memory burnFlags,
            bool[8] memory enabledFlags
        )
    {
        feeNames = ["raid", "maintenance", "repair", "scouting", "healing", "processing", "listing", "crafting"];

        for (uint256 i = 0; i < 8; i++) {
            LibColonyWarsStorage.OperationFee storage fee = LibColonyWarsStorage.getOperationFeeByName(feeNames[i]);
            baseAmounts[i] = fee.baseAmount;
            burnFlags[i] = fee.burnOnCollect;
            enabledFlags[i] = fee.enabled;
        }
    }
    
    /**
     * @notice Get current season information
     * @return seasonId Current season ID
     * @return startTime Season start timestamp
     * @return registrationEnd Registration period end
     * @return warfareEnd Warfare period end
     * @return resolutionEnd Season resolution end
     */
    function getCurrentWarsSeason() external view returns (uint32 seasonId, uint32 startTime, uint32 registrationEnd, uint32 warfareEnd, uint32 resolutionEnd) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
        
        return (season.seasonId, season.startTime, season.registrationEnd, season.warfareEnd, season.resolutionEnd);
    }

    /**
     * @notice Get current season information
     * @param seasonId Current season ID
     * @return startTime Season start timestamp
     * @return registrationEnd Registration period end
     * @return warfareEnd Warfare period end
     * @return resolutionEnd Season resolution end
     */
    function getColonyWarsSeason(uint32 seasonId) external view returns (uint32 startTime, uint32 registrationEnd, uint32 warfareEnd, uint32 resolutionEnd, bool active) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Season storage season = cws.seasons[seasonId];

        return (season.startTime, season.registrationEnd, season.warfareEnd, season.resolutionEnd, season.active);
    }
    
    function getWarsSeasonCounter() external view returns (uint32) {
        return LibColonyWarsStorage.colonyWarsStorage().currentSeason;
    }

    /**
     * @notice Set the season counter to a specific value
     * @dev Administrative function to manually adjust season numbering
     * @param newSeasonCounter New value for the season counter
     */
    function setWarsSeasonCounter(uint32 newSeasonCounter) external onlyAuthorized {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        uint32 oldValue = cws.currentSeason;
        cws.currentSeason = newSeasonCounter;

        emit SeasonCounterUpdated(oldValue, newSeasonCounter);
    }

    /**
     * @notice Get season prize information
     * @param seasonId Season to check
     * @return prize Current prize pool
     * @return paid Whether prize has been paid out
     */
    function getWarsSeasonPrize(uint32 seasonId) external view returns (uint256 prize, bool paid) {
        LibColonyWarsStorage.Season storage s = LibColonyWarsStorage.colonyWarsStorage().seasons[seasonId];
        return (s.prizePool, s.rewarded);
    }

    // Internal functions

    function _distributeProportionalPrizes(uint32 seasonId, uint256 totalPrize) internal {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibColonyWarsStorage.Season storage s = cws.seasons[seasonId];
        
        uint256 topCount = 10;
        uint256 coloniesCount = s.registeredColonies.length;
        
        if (coloniesCount < topCount) {
            topCount = coloniesCount;
        }
        
        // Get sorted colonies
        bytes32[] memory sortedColonies = new bytes32[](coloniesCount);
        uint256[] memory scores = new uint256[](coloniesCount);
        
        for (uint256 i = 0; i < coloniesCount; i++) {
            sortedColonies[i] = s.registeredColonies[i];
            scores[i] = LibColonyWarsStorage.getColonyScore(seasonId, s.registeredColonies[i]);
        }
        
        // Sort
        for (uint256 i = 0; i < coloniesCount - 1; i++) {
            for (uint256 j = 0; j < coloniesCount - i - 1; j++) {
                if (scores[j] < scores[j + 1]) {
                    (scores[j], scores[j + 1]) = (scores[j + 1], scores[j]);
                    (sortedColonies[j], sortedColonies[j + 1]) = (sortedColonies[j + 1], sortedColonies[j]);
                }
            }
        }
        
        uint256 topTotalScore = 0;
        for (uint256 i = 0; i < topCount; i++) {
            topTotalScore += scores[i];
        }
        
        uint256 totalDistributed = 0;
        
        if (topTotalScore > 0) {
            for (uint256 i = 0; i < topCount; i++) {
                bytes32 colonyId = sortedColonies[i];
                uint256 colonyScore = scores[i];
                
                if (colonyScore > 0) {
                    uint256 proportionalPrize = (colonyScore * totalPrize) / topTotalScore;
                    address creator = hs.colonyCreators[colonyId];
                    
                    if (creator != address(0) && proportionalPrize > 0) {
                        LibFeeCollection.transferFromTreasury(
                            creator, 
                            proportionalPrize, 
                            string.concat("season_", seasonId.toString(), "_rank_", (i + 1).toString())
                        );
                        
                        totalDistributed += proportionalPrize;
                        
                        emit SeasonPrizeDistributed(
                            seasonId,
                            colonyId,
                            creator,
                            proportionalPrize,
                            i + 1,
                            colonyScore
                        );
                    }
                }
            }
        }
        
        emit SeasonPrizesCompleted(seasonId, totalDistributed, topCount);
    }

    function _cleanupSeasonBattles(uint32 seasonId) internal {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        bytes32[] storage battles = cws.seasonBattles[seasonId];
        
        // Release wszystkich tokenów z nierozstrzygniętych bitew
        for (uint256 i = 0; i < battles.length; i++) {
            if (!cws.battleResolved[battles[i]]) {
                LibColonyWarsStorage.BattleInstance storage battle = cws.battles[battles[i]];
                
                // Release attacker tokens
                for (uint256 j = 0; j < battle.attackerTokens.length; j++) {
                    LibColonyWarsStorage.releaseToken(battle.attackerTokens[j]);
                }
                
                // Release defender tokens
                for (uint256 j = 0; j < battle.defenderTokens.length; j++) {
                    LibColonyWarsStorage.releaseToken(battle.defenderTokens[j]);
                }
            }
        }
    }

    /**
     * @notice Remove colony from season registered colonies array
     */
    function _removeColonyFromSeason(
        bytes32 colonyId, 
        uint32 seasonId, 
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        LibColonyWarsStorage.Season storage season = cws.seasons[seasonId];
        
        // Find and remove colony from season.registeredColonies
        for (uint256 i = 0; i < season.registeredColonies.length; i++) {
            if (season.registeredColonies[i] == colonyId) {
                season.registeredColonies[i] = season.registeredColonies[season.registeredColonies.length - 1];
                season.registeredColonies.pop();
                break;
            }
        }
        
        // Reset colony score
        LibColonyWarsStorage.setColonyScore(seasonId, colonyId, 0);
    }

    /**
     * @notice Remove colony from user's season colonies array
     */
    function _removeFromUserSeasonColonies(
        bytes32 colonyId,
        uint32 seasonId,
        address user,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        bytes32[] storage userColonies = cws.userSeasonColonies[seasonId][user];
        
        // Find and remove colony from user's season colonies
        for (uint256 i = 0; i < userColonies.length; i++) {
            if (userColonies[i] == colonyId) {
                userColonies[i] = userColonies[userColonies.length - 1];
                userColonies.pop();
                break;
            }
        }
    }

    function _cleanupSeasonSieges(uint32) internal {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        // Release tokenów z aktywnych oblężeń
        for (uint256 i = 0; i < cws.activeSieges.length; i++) {
            bytes32 siegeId = cws.activeSieges[i];
            LibColonyWarsStorage.TerritorySiege storage siege = cws.territorySieges[siegeId];
            
            if (!cws.siegeResolved[siegeId]) {
                // Release tokens
                for (uint256 j = 0; j < siege.attackerTokens.length; j++) {
                    LibColonyWarsStorage.releaseToken(siege.attackerTokens[j]);
                }
                for (uint256 j = 0; j < siege.defenderTokens.length; j++) {
                    LibColonyWarsStorage.releaseToken(siege.defenderTokens[j]);
                }
            }
        }
        
        // Clear active sieges array
        delete cws.activeSieges;
    }

    function _resetSeasonCounters(uint32 seasonId) internal {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Season storage s = cws.seasons[seasonId];

        // Reset stakeIncreases dla wszystkich kolonii w sezonie
        for (uint256 i = 0; i < s.registeredColonies.length; i++) {
            bytes32 colonyId = s.registeredColonies[i];
            LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
            profile.stakeIncreases = 0; // Reset limitu zwiększeń stake
        }
    }

    // ============================================
    // CARD MINT PRICING CONFIGURATION
    // ============================================

    event CardMintPricingUpdated(string cardType, uint8 typeId, uint256 newPrice);
    event CardMintPricingInitialized();

    /**
     * @notice Set infrastructure card mint price
     * @param infraType Infrastructure type (0-5)
     * @param price Price in ZICO wei
     */
    function setInfrastructurePrice(uint8 infraType, uint256 price) external onlyAuthorized {
        if (infraType > 5) revert("Invalid infra type");
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        cws.cardMintPricing.infrastructurePrices[infraType] = price;
        cws.cardMintPricing.initialized = true;
        emit CardMintPricingUpdated("infrastructure", infraType, price);
    }

    /**
     * @notice Set resource card mint price
     * @param resourceType Resource type (0-3)
     * @param price Price in ZICO wei
     */
    function setResourcePrice(uint8 resourceType, uint256 price) external onlyAuthorized {
        if (resourceType > 3) revert("Invalid resource type");
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        cws.cardMintPricing.resourcePrices[resourceType] = price;
        cws.cardMintPricing.initialized = true;
        emit CardMintPricingUpdated("resource", resourceType, price);
    }

    /**
     * @notice Set territory card mint price
     * @param territoryType Territory type (1-5)
     * @param price Price in ZICO wei
     */
    function setTerritoryPrice(uint8 territoryType, uint256 price) external onlyAuthorized {
        if (territoryType == 0 || territoryType > 5) revert("Invalid territory type");
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        cws.cardMintPricing.territoryPrices[territoryType] = price;
        cws.cardMintPricing.initialized = true;
        emit CardMintPricingUpdated("territory", territoryType, price);
    }

    /**
     * @notice Batch set all card mint prices
     * @param infraPrices Array of 6 infrastructure prices (type 0-5)
     * @param resourcePrices Array of 4 resource prices (type 0-3)
     * @param territoryPrices Array of 6 territory prices (index 0 unused, types 1-5)
     */
    function setAllCardPrices(
        uint256[6] calldata infraPrices,
        uint256[4] calldata resourcePrices,
        uint256[6] calldata territoryPrices
    ) external onlyAuthorized {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        cws.cardMintPricing.infrastructurePrices = infraPrices;
        cws.cardMintPricing.resourcePrices = resourcePrices;
        cws.cardMintPricing.territoryPrices = territoryPrices;
        cws.cardMintPricing.initialized = true;
        emit CardMintPricingInitialized();
    }

    /**
     * @notice Get current card mint pricing configuration
     */
    function getCardMintPricing() external view returns (
        uint256[6] memory infraPrices,
        uint256[4] memory resourcePrices,
        uint256[6] memory territoryPrices,
        address paymentToken,
        uint16 discountBps,
        bool useNativePayment,
        bool initialized
    ) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        return (
            cws.cardMintPricing.infrastructurePrices,
            cws.cardMintPricing.resourcePrices,
            cws.cardMintPricing.territoryPrices,
            cws.cardMintPricing.paymentToken,
            cws.cardMintPricing.discountBps,
            cws.cardMintPricing.useNativePayment,
            cws.cardMintPricing.initialized
        );
    }

    /**
     * @notice Set payment token for card minting
     * @param token ERC20 token address (address(0) = use default ZICO from treasury)
     */
    function setCardMintPaymentToken(address token) external onlyAuthorized {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        cws.cardMintPricing.paymentToken = token;
        cws.cardMintPricing.initialized = true;
        emit ConfigUpdated("cardMintPaymentToken", 0, uint256(uint160(token)));
    }

    /**
     * @notice Set whether to use native currency (ETH/MATIC) for card minting
     * @param useNative true = native currency, false = ERC20
     */
    function setCardMintUseNative(bool useNative) external onlyAuthorized {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        cws.cardMintPricing.useNativePayment = useNative;
        cws.cardMintPricing.initialized = true;
        emit ConfigUpdated("cardMintUseNative", 0, useNative ? 1 : 0);
    }

    /**
     * @notice Set discount for card minting in basis points
     * @param discountBps Discount in basis points (e.g., 500 = 5%, 2000 = 20%, max 5000 = 50%)
     */
    function setCardMintDiscount(uint16 discountBps) external onlyAuthorized {
        if (discountBps > 5000) revert("Discount too high"); // Max 50%
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        cws.cardMintPricing.discountBps = discountBps;
        cws.cardMintPricing.initialized = true;
        emit ConfigUpdated("cardMintDiscount", 0, discountBps);
    }

    /**
     * @notice Configure full card mint payment settings in one call
     * @param token ERC20 token address (address(0) = use default ZICO)
     * @param useNative true = native currency, false = ERC20
     * @param discountBps Discount in basis points (max 5000 = 50%)
     */
    function setCardMintPaymentConfig(
        address token,
        bool useNative,
        uint16 discountBps
    ) external onlyAuthorized {
        if (discountBps > 5000) revert("Discount too high");
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        cws.cardMintPricing.paymentToken = token;
        cws.cardMintPricing.useNativePayment = useNative;
        cws.cardMintPricing.discountBps = discountBps;
        cws.cardMintPricing.initialized = true;
        emit ConfigUpdated("cardMintPaymentConfig", 0, 1);
    }

    /**
     * @notice Set resource cards contract address
     * @param resourceCardsAddress Address of ColonyResourceCards contract
     */
    function setResourceCardsAddress(address resourceCardsAddress) external onlyAuthorized {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        cws.contractAddresses.resourceCards = resourceCardsAddress;
    }

    /**
     * @notice Set infrastructure cards contract address
     * @param infrastructureCardsAddress Address of ColonyInfrastructureCards contract
     */
    function setInfrastructureCardsAddress(address infrastructureCardsAddress) external onlyAuthorized {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        cws.contractAddresses.infrastructureCards = infrastructureCardsAddress;
    }

    /**
     * @notice Get all card contract addresses
     * @return territoryCards Territory cards contract address
     * @return infrastructureCards Infrastructure cards contract address
     * @return resourceCards Resource cards contract address
     */
    function getCardContractAddresses() external view returns (
        address territoryCards,
        address infrastructureCards,
        address resourceCards
    ) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        return (
            cws.contractAddresses.territoryCards,
            cws.contractAddresses.infrastructureCards,
            cws.contractAddresses.resourceCards
        );
    }
}
