// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibGamingStorage} from "../libraries/LibGamingStorage.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {PodsUtils} from "../../libraries/PodsUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ChargeSeason, SpecimenCollection} from "../../libraries/HenomorphsModel.sol";
import {ScheduledEvent, UserEngagement} from "../../libraries/GamingModel.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {IRankingFacet} from "../interfaces/IStakingInterfaces.sol";

/**
* @title SeasonFacet
* @notice Unified season management across all game systems
* @dev Manages seasons for Actions, Augments, and Colony Events
* @author rutilicus.eth (ArchXS)
* @custom:security-contact contact@archxs.com
*/
contract SeasonFacet is AccessControlBase {
   using Math for uint256;

   struct UnifiedSeasonConfig {
       string theme;
       uint256 endTime;
       uint256 chargeBoostPercentage;
       uint256 participationThreshold;
       uint256 prizePool;
       bool hasSpecialEvents;
       bool autoStartColonyEvent;
       ColonyEventConfig colonyEvent;
   }

   struct CrossSystemBonuses {
       uint8 biopodBonus;
       uint8 chargepodBonus;
       uint8 stakingBonus;
       uint8 wearReduction;
       bool enabled;
   }

   struct ColonyEventConfig {
       bool enabled;
       uint8 minDailyActions;
       uint8 maxDailyActions;
       uint32 cooldownSeconds;
       uint8 maxBonusPercent;
   }

   struct ExtendedSeasonData {
       uint256 skillRating;
       uint256 consistencyScore;
       uint8 difficultyLevel;
       uint256 weeklyPerformance;
       uint256 socialScore;
   }

   struct UserProgressData {
       bool participating;
       uint8 currentTier;
       uint32 streak;
       uint32 totalPoints;
       uint8 todayActions;
       uint16 currentBonus;
   }

   event UnifiedSeasonStarted(uint256 indexed seasonId, string theme, uint256 startTime, uint256 endTime);
   event NewSeasonStarted(uint256 indexed seasonId, uint256 startTime, uint256 endTime, string theme);
   event SeasonEnded(uint256 indexed seasonId, uint256 endTime);
   event GlobalChargeEventStarted(uint256 startTime, uint256 endTime, uint256 bonusPercentage);
   event GlobalChargeEventEnded(uint256 timestamp);
   event ChargeEventBonusUpdated(uint8 bonusPercentage);
   event SeasonCounterUpdated(uint32 oldCounter, uint32 finalCounter, string reason);
   event ColonyEventStarted(string indexed theme, uint32 startDay, uint32 endDay);
   event ColonyEventEnded(uint256 timestamp);

   error EndTimeInPast(uint256 endTime, uint256 currentTime);
   error EndTimeBeforeStart(uint256 endTime, uint256 startTime);
   error SeasonNotActive();
   error InvalidBonusPercentage(uint256 provided, uint256 maximum);
   error ColonyEventNotActive();
   error NoActiveSeason();
   error NoActiveColonyEvent();
   error InvalidTheme();
   error InvalidParticipationThreshold(uint256 threshold);
   error BoostPercentageTooHigh(uint256 provided, uint256 maximum);
   error LeaderboardSizeTooSmall(uint256 provided, uint256 minimum);
   error SeasonCounterOverflow();
   error InvalidColonyEventDuration(uint256 duration);
   error GlobalEventDurationTooLong(uint256 duration, uint256 maximum);
       
   function startUnifiedSeason(UnifiedSeasonConfig memory config) 
       external 
       onlyAuthorized 
       whenNotPaused 
   {
       LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
       
       if (hs.currentSeason.active) {
           _endCurrentSeasonInternal();
       }
       
       if (config.endTime <= block.timestamp) {
           revert EndTimeInPast(config.endTime, block.timestamp);
       }
       
       hs.seasonCounter++;
       hs.currentSeason = ChargeSeason({
           startTime: block.timestamp,
           endTime: config.endTime,
           chargeBoostPercentage: config.chargeBoostPercentage,
           theme: config.theme,
           active: true,
           scheduled: false,
           scheduledStartTime: 0,
           participationThreshold: config.participationThreshold,
           prizePool: config.prizePool,
           hasSpecialEvents: config.hasSpecialEvents,
           leaderboardSize: 100,
           specialEventCount: config.autoStartColonyEvent ? 1 : 0
       });
       
       try IRankingFacet(address(this)).createSeasonRanking(
           hs.seasonCounter, 
           hs.currentSeason.startTime, 
           hs.currentSeason.endTime
       ) {
           // Season ranking created successfully
       } catch {
           // Continue without ranking - not critical
       }
       
       emit UnifiedSeasonStarted(hs.seasonCounter, config.theme, block.timestamp, config.endTime);
       
       if (config.autoStartColonyEvent && config.colonyEvent.enabled) {
           uint256 duration = config.endTime - block.timestamp;
           _startColonyEventInternal(config.theme, duration, config.colonyEvent);
       }
   }

   function startNewSeason(ChargeSeason memory seasonConfig, bool forceOverride) public onlyAuthorized whenNotPaused {
       LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
       
       if (hs.currentSeason.active) {
           if (forceOverride) {
               hs.currentSeason.active = false;
               hs.currentSeason.endTime = block.timestamp;
               
               try IRankingFacet(address(this)).endSeasonRanking() {
                   // Ranking ended successfully
               } catch {
                   // Continue without ranking - not critical for season override
               }
               
               emit SeasonEnded(hs.seasonCounter, block.timestamp);
           } else {
               // Fix: Don't let _endCurrentSeasonInternal failure block new season
               try this.endCurrentSeason() {
                   // Normal ending succeeded
               } catch {
                   // If ending fails, force end it
                   hs.currentSeason.active = false;
                   hs.currentSeason.endTime = block.timestamp;
                   emit SeasonEnded(hs.seasonCounter, block.timestamp);
               }
           }
       }
       
       // Fix: Set defaults instead of reverting
       if (bytes(seasonConfig.theme).length == 0) {
           seasonConfig.theme = "Default Season";
       }
       
       if (seasonConfig.endTime == 0) {
           seasonConfig.endTime = block.timestamp + 35 days;
       }
       
       if (seasonConfig.chargeBoostPercentage == 0) {
           seasonConfig.chargeBoostPercentage = 10;
       }
       
       if (seasonConfig.participationThreshold == 0) {
           seasonConfig.participationThreshold = 50;
       }
       
       if (seasonConfig.leaderboardSize == 0) {
           seasonConfig.leaderboardSize = 100;
       }
       
       if (seasonConfig.chargeBoostPercentage > 500) {
           revert BoostPercentageTooHigh(seasonConfig.chargeBoostPercentage, 500);
       }
       
       if (seasonConfig.endTime > 0 && seasonConfig.endTime <= block.timestamp) {
           revert EndTimeInPast(seasonConfig.endTime, block.timestamp);
       }
       
       hs.seasonCounter++;
       hs.currentSeason = ChargeSeason({
           startTime: block.timestamp,
           endTime: seasonConfig.endTime,
           chargeBoostPercentage: seasonConfig.chargeBoostPercentage,
           theme: seasonConfig.theme,
           active: true,
           scheduled: seasonConfig.scheduled,
           scheduledStartTime: seasonConfig.scheduledStartTime,
           participationThreshold: seasonConfig.participationThreshold,
           prizePool: seasonConfig.prizePool,
           hasSpecialEvents: seasonConfig.hasSpecialEvents,
           leaderboardSize: seasonConfig.leaderboardSize,
           specialEventCount: seasonConfig.specialEventCount
       });
       
       try IRankingFacet(address(this)).createSeasonRanking(
           hs.seasonCounter, 
           hs.currentSeason.startTime, 
           hs.currentSeason.endTime
       ) {
           // Season ranking created successfully
       } catch {
           // Continue without ranking - not critical
       }
       
       emit NewSeasonStarted(hs.seasonCounter, block.timestamp, seasonConfig.endTime, seasonConfig.theme);
   }

   function startNewSeason(ChargeSeason memory seasonConfig) public onlyAuthorized whenNotPaused {
       startNewSeason(seasonConfig, false);
   }

   function updateSeason(ChargeSeason calldata seasonConfig) external onlyAuthorized {
       LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
       
       // Fix: Remove NoActiveSeason check - allow updating inactive seasons
       
       if (seasonConfig.endTime > 0) {
           if (seasonConfig.endTime <= block.timestamp) {
               revert EndTimeInPast(seasonConfig.endTime, block.timestamp);
           }
           if (seasonConfig.endTime <= hs.currentSeason.startTime) {
               revert EndTimeBeforeStart(seasonConfig.endTime, hs.currentSeason.startTime);
           }
           hs.currentSeason.endTime = seasonConfig.endTime;
       }
       
       if (bytes(seasonConfig.theme).length > 0) {
           hs.currentSeason.theme = seasonConfig.theme;
       }
       
       if (seasonConfig.chargeBoostPercentage > 0) {
           if (seasonConfig.chargeBoostPercentage > 500) {
               revert BoostPercentageTooHigh(seasonConfig.chargeBoostPercentage, 500);
           }
           hs.currentSeason.chargeBoostPercentage = seasonConfig.chargeBoostPercentage;
       }
       
       if (seasonConfig.participationThreshold > 0) {
           hs.currentSeason.participationThreshold = seasonConfig.participationThreshold;
       }
       
       if (seasonConfig.leaderboardSize > 0) {
           hs.currentSeason.leaderboardSize = seasonConfig.leaderboardSize;
       }
       
       // Fix: Allow activating season through update
       hs.currentSeason.active = seasonConfig.active;
       
       hs.currentSeason.prizePool = seasonConfig.prizePool;
       hs.currentSeason.hasSpecialEvents = seasonConfig.hasSpecialEvents;
       hs.currentSeason.specialEventCount = seasonConfig.specialEventCount;
   }

   function endCurrentSeason() public onlyAuthorized {
       _endCurrentSeasonInternal();
   }

   function startColonyEvent(
       string calldata theme,
       uint256 durationDays,
       LibHenomorphsStorage.ColonyEventConfig calldata eventConfig,
       bool createSeason,
       bool createGlobalEvent,
       uint8 globalEventBonus
   ) external onlyAuthorized whenNotPaused {
       LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
       uint32 currentDay = LibGamingStorage.getCurrentDay();
       
       hs.featureFlags["colonyEvents"] = true;
       hs.colonyEventConfig = LibHenomorphsStorage.ColonyEventConfig({
           active: true,
           startDay: currentDay,
           endDay: currentDay + uint32(durationDays),
           minDailyActions: eventConfig.minDailyActions,
           maxDailyActions: eventConfig.maxDailyActions,
           cooldownSeconds: eventConfig.cooldownSeconds,
           maxBonusPercent: eventConfig.maxBonusPercent
       });
       
       if (createSeason) {
           uint256 endTime = block.timestamp + (durationDays * 86400);
           
           ChargeSeason memory defaultSeason = ChargeSeason({
               startTime: 0,
               endTime: endTime,
               chargeBoostPercentage: 10,
               theme: theme,
               active: false,
               scheduled: false,
               scheduledStartTime: 0,
               participationThreshold: 100,
               prizePool: 0,
               hasSpecialEvents: true,
               leaderboardSize: 100,
               specialEventCount: 0
           });
           startNewSeason(defaultSeason);
       }
       
       if (createGlobalEvent) {
           startGlobalChargeEvent(durationDays * 86400, globalEventBonus);
       }
       
       emit ColonyEventStarted(theme, currentDay, currentDay + uint32(durationDays));
   }

   function updateColonyEvent(LibHenomorphsStorage.ColonyEventConfig calldata eventConfig) external onlyAuthorized {
       LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
       
       if (!hs.colonyEventConfig.active) {
           revert NoActiveColonyEvent();
       }
       
       hs.colonyEventConfig.minDailyActions = eventConfig.minDailyActions;
       hs.colonyEventConfig.maxDailyActions = eventConfig.maxDailyActions;
       hs.colonyEventConfig.cooldownSeconds = eventConfig.cooldownSeconds;
       hs.colonyEventConfig.maxBonusPercent = eventConfig.maxBonusPercent;
   }

   function endColonyEvent() external onlyAuthorized {
       LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
       
       if (!hs.colonyEventConfig.active) {
           revert NoActiveColonyEvent();
       }
       
       hs.colonyEventConfig.active = false;
       hs.featureFlags["colonyEvents"] = false;
       
       emit ColonyEventEnded(block.timestamp);
   }

   function setChargeEventBonus(uint8 bonusPercentage) external onlyAuthorized whenNotPaused {
       if (bonusPercentage > 200) {
           revert InvalidBonusPercentage(bonusPercentage, 200);
       }
       
       LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
       hs.chargeEventBonus = bonusPercentage;
       
       emit ChargeEventBonusUpdated(bonusPercentage);
   }

   function startGlobalChargeEvent(uint256 duration, uint8 bonusPercentage) 
       public 
       onlyAuthorized 
       whenNotPaused 
   {
       if (bonusPercentage > 200) {
           revert InvalidBonusPercentage(bonusPercentage, 200);
       }
       
       LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
       
       hs.chargeEventEnd = uint32(block.timestamp + duration);
       hs.chargeEventBonus = bonusPercentage;
       
       emit GlobalChargeEventStarted(block.timestamp, block.timestamp + duration, bonusPercentage);
   }

   function endGlobalChargeEvent() public onlyAuthorized {
       LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
       
       hs.chargeEventEnd = uint32(block.timestamp);
       
       emit GlobalChargeEventEnded(block.timestamp);
   }

   function resetSeasonCounter(uint32 newCounter, string calldata reason) 
       external 
       onlyAuthorized 
       whenNotPaused 
   {
       LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
       uint32 oldCounter = hs.seasonCounter;
       uint32 finalCounter;
       
       if (newCounter == 0) {
           finalCounter = _findHighestSeasonWithData();
           if (finalCounter == 0) finalCounter = 1;
       } else {
           finalCounter = newCounter;
       }
       
       hs.seasonCounter = finalCounter;
       
       emit SeasonCounterUpdated(oldCounter, finalCounter, reason);
   }

   function _startColonyEventInternal(
       string memory theme,
       uint256 duration,
       ColonyEventConfig memory config
   ) internal {
       LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
       uint32 currentDay = LibGamingStorage.getCurrentDay();
       uint32 durationDays = uint32(duration / 86400);
       
       hs.featureFlags["colonyEvents"] = true;
       hs.colonyEventConfig = LibHenomorphsStorage.ColonyEventConfig({
           active: true,
           startDay: currentDay,
           endDay: currentDay + durationDays,
           minDailyActions: config.minDailyActions,
           maxDailyActions: config.maxDailyActions,
           cooldownSeconds: config.cooldownSeconds,
           maxBonusPercent: config.maxBonusPercent
       });
       
       emit ColonyEventStarted(theme, currentDay, currentDay + durationDays);
   }

   function _endCurrentSeasonInternal() internal {
       LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
       
       if (hs.currentSeason.active) {
           hs.currentSeason.active = false;
           hs.currentSeason.endTime = block.timestamp;
           
           try IRankingFacet(address(this)).endSeasonRanking() {
               // Season ranking ended successfully
           } catch {
               // Continue without ranking - not critical for season end
           }
           
           emit SeasonEnded(hs.seasonCounter, block.timestamp);
       }
   }

   function _findHighestSeasonWithData() internal view returns (uint32) {
       LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
       
       if (hs.currentSeason.active && _isSeasonProperlyConfigured(hs.currentSeason)) {
           return hs.seasonCounter;
       }
       
       if (hs.seasonCounter > 1) {
           return hs.seasonCounter - 1;
       }
       
       return 0;
   }

   function _isSeasonProperlyConfigured(ChargeSeason storage season) internal view returns (bool) {
       if (season.startTime == 0) return false;
       if (season.endTime == 0) return false;
       if (season.endTime <= season.startTime) return false;
       if (bytes(season.theme).length == 0) return false;
       if (season.chargeBoostPercentage == 0) return false;
       if (season.participationThreshold == 0) return false;
       if (season.leaderboardSize == 0) return false;
       
       uint256 duration = season.endTime - season.startTime;
       if (duration < 86400) return false;
       if (duration > 31536000) return false;
       
       return true;
   }

   function getCurrentSeason() external view returns (ChargeSeason memory) {
       return LibHenomorphsStorage.henomorphsStorage().currentSeason;
   }
   
   function getSeasonCount() external view returns (uint32) {
       return LibHenomorphsStorage.henomorphsStorage().seasonCounter;
   }
   
   function getCurrentSeasonPoints(address operator) external view returns (uint32) {
       LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
       return hs.operatorSeasonPoints[operator][hs.seasonCounter];
   }
   
   function getOperatorSeasonPoints(address operator, uint32 seasonId) external view returns (uint32) {
       return LibHenomorphsStorage.henomorphsStorage().operatorSeasonPoints[operator][seasonId];
   }
   
   function getChargeEventStatus() 
       external 
       view 
       returns (bool active, uint256 remainingTime, uint8 bonusPercentage) 
   {
       LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
       
       if (hs.chargeEventEnd > block.timestamp) {
           return (true, hs.chargeEventEnd - block.timestamp, hs.chargeEventBonus);
       } else {
           return (false, 0, 0);
       }
   }

   function getColonyEventStatus() external view returns (
       bool active,
       bool featureEnabled,
       uint32 startDay,
       uint32 endDay,
       uint32 currentDay,
       uint32 daysRemaining
   ) {
       LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
       
       featureEnabled = hs.featureFlags["colonyEvents"];
       active = featureEnabled && hs.colonyEventConfig.active;
       startDay = hs.colonyEventConfig.startDay;
       endDay = hs.colonyEventConfig.endDay;
       currentDay = LibGamingStorage.getCurrentDay();
       daysRemaining = active && currentDay <= endDay ? endDay - currentDay : 0;
   }

   function getUserColonyEventProgress(
       address user,
       uint256 collectionId,
       uint256 tokenId
   ) external view returns (UserProgressData memory progress) {
       LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
       
       if (!hs.colonyEventConfig.active) {
           return progress;
       }
       
       uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
       if (hs.specimenColonies[combinedId] == bytes32(0)) {
           return progress;
       }
       
       LibGamingStorage.GamingStorage storage gs = LibGamingStorage.gamingStorage();
       uint32 currentDay = LibGamingStorage.getCurrentDay();
       
       progress.participating = true;
       progress.streak = gs.userEngagement[user].currentStreak;
       progress.totalPoints = hs.operatorSeasonPoints[user][hs.seasonCounter];
       progress.todayActions = uint8(gs.userDailyActivity[user][currentDay]);
       
       uint8 qualifiedDays = 0;
       for (uint32 day = hs.colonyEventConfig.startDay; day <= currentDay; day++) {
           if (gs.userDailyActivity[user][day] >= hs.colonyEventConfig.minDailyActions) {
               qualifiedDays++;
           }
       }
       
       if (qualifiedDays >= 13) progress.currentTier = 5;
       else if (qualifiedDays >= 10) progress.currentTier = 4;
       else if (qualifiedDays >= 7) progress.currentTier = 3;
       else if (qualifiedDays >= 4) progress.currentTier = 2;
       else progress.currentTier = 1;
       
       progress.currentBonus = 0;
   }

   function _uintToString(uint256 value) internal pure returns (string memory) {
       if (value == 0) {
           return "0";
       }
       
       uint256 temp = value;
       uint256 digits;
       
       while (temp != 0) {
           digits++;
           temp /= 10;
       }
       
       bytes memory buffer = new bytes(digits);
       
       while (value != 0) {
           digits -= 1;
           buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
           value /= 10;
       }
       
       return string(buffer);
   }
}