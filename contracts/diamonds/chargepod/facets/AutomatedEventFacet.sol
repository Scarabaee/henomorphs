// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibGamingStorage} from "../libraries/LibGamingStorage.sol";
import {ActionHelper} from "../libraries/ActionHelper.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {ChargeConfigurationControlFacet} from "./ChargeConfigurationControlFacet.sol";
import {ISeasonFacet} from "../interfaces/IStakingInterfaces.sol";
import {ChargeSeason} from "../../libraries/HenomorphsModel.sol";


/**
 * @title ComplementaryAutomatedEventFacet
 * @notice Extends SeasonFacet with automation - full compatibility and configuration
 * @dev Uses complete SeasonFacet functionality, adds only scheduling layer
 * @author rutilicus.eth (ArchXS)
 */
contract AutomatedEventFacet is AccessControlBase {

    // =================== STORAGE - EXTENDS, NOT REPLACES ===================
    
    struct AutomationConfig {
        bool enabled;
        uint32 lastProcessed;
        uint32 processingInterval;
        uint16 maxEventsPerRun;
    }
    
    struct RecurringEventConfig {
        // Event scheduling
        uint32 intervalSeconds;
        uint32 nextExecution;
        uint16 executionCount;
        uint16 maxExecutions;
        bool enabled;
        
        // Event type and target
        uint8 eventType; // 1=season, 2=global_charge, 3=action_schedule, 4=colony_event
        uint8 targetActionId; // For action schedules
        
        // FULL configuration - not hardcoded defaults
        ChargeSeason seasonConfig; // Complete season configuration
        LibHenomorphsStorage.ColonyEventConfig colonyConfig; // Complete colony configuration
        
        // Global charge event config
        uint256 chargeDuration;
        uint8 chargeBonus;
        
        // Action schedule config  
        uint256 actionDuration;
        uint256 actionMultiplier;
    }

    AutomationConfig public automation;
    mapping(uint256 => RecurringEventConfig) public recurringEvents;
    uint256 public recurringEventCounter;

    // =================== MINIMAL EVENTS ===================
    
    event AutomationExecuted(uint32 processed);
    event RecurringEventExecuted(uint256 indexed eventId, uint8 eventType);

    // =================== MINIMAL ERRORS ===================
    
    error AutomationDisabled();
    error InvalidEventConfig();
    error ExecutionFailed();

    // =================== CORE AUTOMATION ===================

    /**
     * @notice Execute automation with full SeasonFacet integration
     */
    function executeAutomation() external {
        if (!automation.enabled) revert AutomationDisabled();
        
        uint32 currentTime = uint32(block.timestamp);
        uint32 processed = 0;
        uint16 maxEvents = automation.maxEventsPerRun > 0 ? automation.maxEventsPerRun : 10;
        
        // Process existing SeasonFacet logic first
        processed += _processExistingSeasonLogic(currentTime);
        
        // Process recurring events with full configuration
        for (uint256 i = 1; i <= recurringEventCounter && processed < maxEvents; i++) {
            if (_processRecurringEvent(i, currentTime)) {
                processed++;
            }
        }
        
        automation.lastProcessed = currentTime;
        emit AutomationExecuted(processed);
    }

    /**
     * @notice Process existing SeasonFacet automation logic
     */
    function _processExistingSeasonLogic(uint32 currentTime) internal returns (uint32 processed) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Use existing SeasonFacet logic for season expiration
        if (hs.currentSeason.active && hs.currentSeason.endTime <= currentTime) {
            try ISeasonFacet(address(this)).endCurrentSeason() {
                processed++;
            } catch {}
        }
        
        // Use existing SeasonFacet logic for scheduled season start
        if (hs.currentSeason.scheduled && hs.currentSeason.scheduledStartTime <= currentTime) {
            // Validate using ActionHelper
            ActionHelper.TimeCheck memory validation = ActionHelper.validateTimeWindow(
                currentTime,
                hs.currentSeason.endTime,
                86400 // Min 1 day
            );
            
            if (validation.valid) {
                try this.startScheduledSeason() {
                    processed++;
                } catch {}
            }
        }
        
        // Process action schedules using existing logic
        for (uint8 actionId = 1; actionId <= 5; actionId++) {
            if (hs.actionTypes[actionId].timeControlEnabled && 
                hs.actionTypes[actionId].endTime <= currentTime) {
                try ChargeConfigurationControlFacet(address(this)).removeActionSchedule(actionId) {
                    processed++;
                } catch {}
            }
        }
    }

    /**
     * @notice Execute recurring event with pre-execution validation
     */
    function _processRecurringEvent(uint256 eventId, uint32 currentTime) internal returns (bool success) {
        RecurringEventConfig storage config = recurringEvents[eventId];
        
        if (!config.enabled || config.nextExecution > currentTime) {
            return false;
        }
        
        // Check execution limits
        if (config.maxExecutions > 0 && config.executionCount >= config.maxExecutions) {
            config.enabled = false;
            return false;
        }
        
        // Pre-execution validation via ActionHelper
        if (!ActionHelper.canExecuteEvent(config.eventType)) {
            return false;
        }
        
        // Execute with full configuration based on type
        if (config.eventType == 1) {
            success = _executeRecurringSeason(config);
        } else if (config.eventType == 2) {
            success = _executeRecurringGlobalCharge(config);
        } else if (config.eventType == 3) {
            success = _executeRecurringActionSchedule(config, currentTime);
        } else if (config.eventType == 4) {
            success = _executeRecurringColonyEvent(config);
        }
        
        if (success) {
            config.nextExecution = currentTime + config.intervalSeconds;
            config.executionCount++;
            emit RecurringEventExecuted(eventId, config.eventType);
        }
        
        return success;
    }

    // =================== EVENT EXECUTORS WITH FULL CONFIG ===================

    /**
     * @notice Execute recurring season with FULL SeasonFacet configuration
     */
    function _executeRecurringSeason(RecurringEventConfig storage config) internal returns (bool) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Don't start if season already active
        if (hs.currentSeason.active) return false;
        
        // Use FULL season configuration from storage
        try ISeasonFacet(address(this)).startNewSeason(config.seasonConfig) {
            return true;
        } catch {
            return false;
        }
    }

    /**
     * @notice Execute recurring global charge event with full configuration
     */
    function _executeRecurringGlobalCharge(RecurringEventConfig storage config) internal returns (bool) {
        try ISeasonFacet(address(this)).startGlobalChargeEvent(
            config.chargeDuration,
            config.chargeBonus
        ) {
            return true;
        } catch {
            return false;
        }
    }

    /**
     * @notice Execute recurring action schedule with full configuration
     */
    function _executeRecurringActionSchedule(
        RecurringEventConfig storage config, 
        uint32 currentTime
    ) internal returns (bool) {
        if (config.targetActionId == 0 || config.targetActionId > 5) return false;
        
        uint256 endTime = currentTime + config.actionDuration;
        
        // Validate using ActionHelper
        ActionHelper.TimeCheck memory validation = ActionHelper.validateActionSchedule(
            config.targetActionId,
            currentTime,
            endTime
        );
        
        if (!validation.valid) return false;
        
        try ChargeConfigurationControlFacet(address(this)).setActionSchedule(
            config.targetActionId,
            validation.adjustedStart,
            validation.adjustedEnd,
            config.actionMultiplier,
            true
        ) {
            return true;
        } catch {
            return false;
        }
    }

    /**
     * @notice Execute recurring colony event with FULL SeasonFacet configuration
     */
    function _executeRecurringColonyEvent(RecurringEventConfig storage config) internal returns (bool) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Don't start if colony event already active
        if (hs.colonyEventConfig.active) return false;
        
        uint32 currentDay = LibGamingStorage.getCurrentDay();
        uint32 eventDuration = config.colonyConfig.endDay - config.colonyConfig.startDay;
        
        // Validate using ActionHelper
        (bool valid, uint32 adjStart, uint32 adjEnd) = ActionHelper.validateColonySchedule(
            bytes32("RECURRING_COLONY"),
            currentDay,
            currentDay + eventDuration
        );
        
        if (!valid) return false;
        
        // Update config with validated times
        LibHenomorphsStorage.ColonyEventConfig memory adjustedConfig = config.colonyConfig;
        adjustedConfig.startDay = adjStart;
        adjustedConfig.endDay = adjEnd;
        
        // Use FULL SeasonFacet colony event functionality
        try ISeasonFacet(address(this)).startColonyEvent(
            "Recurring Colony Event",
            eventDuration,
            adjustedConfig,
            false, // Don't auto-create season
            true,  // Create global event
            config.colonyConfig.maxBonusPercent
        ) {
            return true;
        } catch {
            return false;
        }
    }

    // =================== CONFIGURATION - FULL FEATURE PARITY ===================

    /**
     * @notice Create recurring season with validation via ActionHelper
     */
    function createRecurringSeason(
        uint32 intervalHours,
        ChargeSeason calldata seasonConfig,
        uint16 maxExecutions
    ) external onlyAuthorized whenNotPaused {
        if (!ActionHelper.validateSeasonConfig(intervalHours, seasonConfig)) {
            revert InvalidEventConfig();
        } 
        
        recurringEventCounter++;
        
        RecurringEventConfig storage config = recurringEvents[recurringEventCounter];
        config.intervalSeconds = intervalHours * 3600;
        config.nextExecution = uint32(block.timestamp + intervalHours * 3600);
        config.executionCount = 0;
        config.maxExecutions = maxExecutions;
        config.enabled = true;
        config.eventType = 1;
        config.seasonConfig = seasonConfig;
    }

    /**
     * @notice Create recurring global charge event with validation
     */
    function createRecurringGlobalCharge(
        uint32 intervalHours,
        uint256 chargeDuration,
        uint8 chargeBonus,
        uint16 maxExecutions
    ) external onlyAuthorized whenNotPaused {
        if (!ActionHelper.validateGlobalChargeConfig(intervalHours, chargeDuration, chargeBonus)) {
            revert InvalidEventConfig();
        }
        
        recurringEventCounter++;
        
        RecurringEventConfig storage config = recurringEvents[recurringEventCounter];
        config.intervalSeconds = intervalHours * 3600;
        config.nextExecution = uint32(block.timestamp + intervalHours * 3600);
        config.executionCount = 0;
        config.maxExecutions = maxExecutions;
        config.enabled = true;
        config.eventType = 2;
        config.chargeDuration = chargeDuration;
        config.chargeBonus = chargeBonus;
    }

    /**
     * @notice Create recurring action schedule with enhanced validation
     */
    function createRecurringActionSchedule(
        uint32 intervalHours,
        uint8 targetActionId,
        uint256 actionDuration,
        uint256 actionMultiplier,
        uint16 maxExecutions
    ) external onlyAuthorized whenNotPaused {
        if (intervalHours == 0 || targetActionId == 0 || targetActionId > 5 || 
            actionDuration == 0 || actionMultiplier == 0) {
            revert InvalidEventConfig();
        }
        
        // Enhanced validation - check multiplier bounds
        if (!ActionHelper.validateActionMultiplier(targetActionId, actionMultiplier)) {
            revert InvalidEventConfig();
        }
        
        // Additional validation via ActionHelper
        ActionHelper.TimeCheck memory validation = ActionHelper.validateActionSchedule(
            targetActionId,
            block.timestamp + intervalHours * 3600,
            block.timestamp + intervalHours * 3600 + actionDuration
        );
        
        if (!validation.valid) {
            revert InvalidEventConfig();
        }
        
        recurringEventCounter++;
        
        RecurringEventConfig storage config = recurringEvents[recurringEventCounter];
        config.intervalSeconds = intervalHours * 3600;
        config.nextExecution = uint32(block.timestamp + intervalHours * 3600);
        config.executionCount = 0;
        config.maxExecutions = maxExecutions;
        config.enabled = true;
        config.eventType = 3;
        config.targetActionId = targetActionId;
        config.actionDuration = actionDuration;
        config.actionMultiplier = actionMultiplier;
    }

    /**
     * @notice Create recurring colony event with validation
     */
    function createRecurringColonyEvent(
        uint32 intervalHours,
        uint32 eventDurationDays,
        LibHenomorphsStorage.ColonyEventConfig calldata colonyConfig,
        uint16 maxExecutions
    ) external onlyAuthorized whenNotPaused {
        if (!ActionHelper.validateColonyEventConfig(intervalHours, eventDurationDays, colonyConfig)) {
            revert InvalidEventConfig();
        }
        
        recurringEventCounter++;
        
        RecurringEventConfig storage config = recurringEvents[recurringEventCounter];
        config.intervalSeconds = intervalHours * 3600;
        config.nextExecution = uint32(block.timestamp + intervalHours * 3600);
        config.executionCount = 0;
        config.maxExecutions = maxExecutions;
        config.enabled = true;
        config.eventType = 4;
        config.colonyConfig = colonyConfig;
        config.colonyConfig.endDay = config.colonyConfig.startDay + eventDurationDays;
    }

    /**
     * @notice Schedule one-time season using FULL SeasonFacet functionality
     */
    function scheduleSeasonStart(
        uint256 startTime,
        ChargeSeason calldata seasonConfig
    ) external onlyAuthorized whenNotPaused {
        // Validate using ActionHelper
        ActionHelper.TimeCheck memory validation = ActionHelper.validateTimeWindow(
            startTime,
            startTime + seasonConfig.endTime,
            86400 // Min 1 day
        );
        
        if (!validation.valid) revert InvalidEventConfig();
        
        // Use existing SeasonFacet scheduling logic
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        hs.currentSeason = seasonConfig;
        hs.currentSeason.scheduled = true;
        hs.currentSeason.scheduledStartTime = validation.adjustedStart;
        hs.currentSeason.endTime = validation.adjustedEnd;
    }

    /**
     * @notice Schedule one-time colony event using FULL SeasonFacet functionality
     */
    function scheduleColonyEvent(
        bytes32 colonyId,
        uint32 startDay,
        uint32 durationDays,
        LibHenomorphsStorage.ColonyEventConfig calldata colonyConfig
    ) external onlyAuthorized whenNotPaused {
        // Validate using ActionHelper
        (bool valid, uint32 adjStart, uint32 adjEnd) = ActionHelper.validateColonySchedule(
            colonyId,
            startDay,
            startDay + durationDays
        );
        
        if (!valid) revert InvalidEventConfig();
        
        // Create adjusted config
        LibHenomorphsStorage.ColonyEventConfig memory adjustedConfig = colonyConfig;
        adjustedConfig.startDay = adjStart;
        adjustedConfig.endDay = adjEnd;
        
        // Use FULL SeasonFacet functionality
        ISeasonFacet(address(this)).startColonyEvent(
            "Scheduled Colony Event",
            adjEnd - adjStart,
            adjustedConfig,
            true,  // Create season if requested
            true,  // Create global event
            colonyConfig.maxBonusPercent
        );
    }

    function startScheduledSeason() external onlyAuthorized {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (hs.currentSeason.scheduled) {
            // Use existing scheduled season logic
            ISeasonFacet(address(this)).startNewSeason(hs.currentSeason);
            hs.currentSeason.scheduled = false;
        }
    }

    function setAutomationConfig(
        bool enabled,
        uint32 processingInterval,
        uint16 maxEventsPerRun
    ) external onlyAuthorized {
        automation.enabled = enabled;
        automation.processingInterval = processingInterval;
        automation.maxEventsPerRun = maxEventsPerRun;
    }

    function toggleRecurringEvent(uint256 eventId, bool enabled) external onlyAuthorized {
        if (eventId > 0 && eventId <= recurringEventCounter) {
            recurringEvents[eventId].enabled = enabled;
        }
    }

    function updateRecurringEventInterval(uint256 eventId, uint32 intervalHours) external onlyAuthorized {
        if (eventId > 0 && eventId <= recurringEventCounter && intervalHours > 0) {
            RecurringEventConfig storage config = recurringEvents[eventId];
            config.intervalSeconds = intervalHours * 3600;
            // Recalculate next execution
            config.nextExecution = uint32(block.timestamp + config.intervalSeconds);
        }
    }

    // =================== VIEW FUNCTIONS ===================

    function getAutomationStatus() external view returns (
        bool enabled,
        uint32 lastProcessed,
        uint256 activeRecurringEvents
    ) {
        enabled = automation.enabled;
        lastProcessed = automation.lastProcessed;
        
        for (uint256 i = 1; i <= recurringEventCounter; i++) {
            if (recurringEvents[i].enabled) {
                activeRecurringEvents++;
            }
        }
    }

    function getRecurringEvent(uint256 eventId) external view returns (
        RecurringEventConfig memory config,
        uint256 timeUntilNext
    ) {
        if (eventId > 0 && eventId <= recurringEventCounter) {
            config = recurringEvents[eventId];
            if (config.enabled && config.nextExecution > block.timestamp) {
                timeUntilNext = config.nextExecution - block.timestamp;
            }
        }
    }

    function getRecurringEventsByType(uint8 eventType) external view returns (uint256[] memory eventIds) {
        uint256 count = 0;
        
        // Count matching events
        for (uint256 i = 1; i <= recurringEventCounter; i++) {
            if (recurringEvents[i].eventType == eventType && recurringEvents[i].enabled) {
                count++;
            }
        }
        
        // Populate result
        eventIds = new uint256[](count);
        uint256 index = 0;
        
        for (uint256 i = 1; i <= recurringEventCounter; i++) {
            if (recurringEvents[i].eventType == eventType && recurringEvents[i].enabled) {
                eventIds[index] = i;
                index++;
            }
        }
    }
}