// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {ColonyHelper} from "../libraries/ColonyHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {PowerMatrix} from "../../libraries/HenomorphsModel.sol";
import {WarfareHelper} from "../libraries/WarfareHelper.sol";
import {LibAchievementTrigger} from "../libraries/LibAchievementTrigger.sol";

/**
 * @title TerritoryWarsFacet
 * @notice Warfare operations for territories - raids, scouting, healing, and repairs
 * @dev Siege operations have been moved to TerritorySiegeFacet
 */
contract TerritoryWarsFacet is AccessControlBase {

    // Events
    event TerritoryRaided(uint256 indexed territoryId, bytes32 indexed attacker, uint16 newDamageLevel);
    event TerritoryRaidFailed(uint256 indexed territoryId, bytes32 indexed attacker);
    event TerritoryRepaired(uint256 indexed territoryId, bytes32 indexed owner, uint256 cost);
    event TerritoryScouted(
        uint256 indexed territoryId,
        uint256 indexed observatoryId,
        bytes32 indexed scoutColony,
        bytes32 targetColony,
        uint256 cost,
        uint8 intelligenceLevel
    );

    // Custom errors
    error RaidCooldownActive();
    error InvalidRaidTarget();
    error InsufficientRaidStake();
    error TerritoryFullyDamaged();
    error NoRepairNeeded();
    error WarfareNotStarted();
    error WarfareEnded();
    error TerritoryNotFound();
    error RateLimitExceeded();
    error ObservatoryNotControlled();
    error NotObservatoryType();
    error SanctuaryNotControlled();
    error NotSanctuaryType();
    error SanctuaryToooDamaged();
    error TooManyTokensToHeal();
    error TokenNotInColony();
    error ObservatoryTooDamaged();
    error ActionOnCooldown();

    /**
     * @notice Raid enemy territory to reduce its effectiveness
     * @param territoryId Territory to raid
     * @param stakeAmount ZICO to stake on raid success
     */
    function raidTerritory(uint256 territoryId, uint256 stakeAmount)
        external
        whenNotPaused
        nonReentrant
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("territories");

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        // Rate limiting - one raid per hour
        if (!LibColonyWarsStorage.checkRateLimit(LibMeta.msgSender(), this.raidTerritory.selector, cws.config.attackCooldown)) {
            revert RateLimitExceeded();
        }

        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];

        if (block.timestamp < season.registrationEnd) {
            revert WarfareNotStarted();
        }
        if (block.timestamp > season.warfareEnd) {
            revert WarfareEnded();
        }

        // Validate caller and get raider colony
        bytes32 raiderColony = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());
        if (raiderColony == bytes32(0)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "No colony found");
        }

        if (!ColonyHelper.isColonyCreator(raiderColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Only colony creator can raid");
        }

        // Validate territory exists and is controlled
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        if (!territory.active) {
            revert TerritoryNotFound();
        }
        if (territory.controllingColony == bytes32(0)) {
            revert InvalidRaidTarget();
        }
        if (territory.controllingColony == raiderColony) {
            revert InvalidRaidTarget();
        }
        if (territory.damageLevel >= 100) {
            revert TerritoryFullyDamaged();
        }

        // CONFLICT CHECK: Cannot raid territory controlled by yourself
        if (ColonyHelper.isColonyCreator(territory.controllingColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Cannot raid own territory");
        }

        // Check raid cooldown - 24 hours between raids on same territory
        if (block.timestamp < territory.lastRaidTime + 86400) {
            revert RaidCooldownActive();
        }

        // Ensure both colonies are registered for current season
        if (!cws.colonyWarProfiles[raiderColony].registered) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Colony not registered for season");
        }
        if (!cws.colonyWarProfiles[territory.controllingColony].registered) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Target colony not registered for season");
        }

        // Calculate minimum stake based on territory value and bonus
        uint256 territoryBaseValue = cws.config.territoryCaptureCost; // 250 ZICO
        uint256 bonusMultiplier = 100 + territory.bonusValue; // 110-125 for 10-25% bonus
        uint256 minStake = (territoryBaseValue * bonusMultiplier) / 200; // 137-156 ZICO range

        if (stakeAmount < minStake) {
            revert InsufficientRaidStake();
        }
        if (stakeAmount > minStake * 4) {
            stakeAmount = minStake * 4; // Cap to prevent over-staking
        }

        (bool isRaidBetrayal, bytes32 raidBetrayedAllianceId) = LibColonyWarsStorage.validateAndProcessBetrayal(
            LibMeta.msgSender(),
            raiderColony,
            territory.controllingColony,
            "raid"
        );

        if (isRaidBetrayal) {
            emit WarfareHelper.BetrayalRecorded(raiderColony, raidBetrayedAllianceId);
            emit WarfareHelper.ColonyLeftAlliance(raidBetrayedAllianceId, raiderColony, "Raided alliance member territory");
            stakeAmount *= 2;
        }

        // Collect raid operation fee (YELLOW, burned)
        LibColonyWarsStorage.OperationFee storage raidFee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_RAID);
        LibFeeCollection.processConfiguredFee(
            raidFee,
            LibMeta.msgSender(),
            "territory_raid_fee"
        );

        // Transfer raid stake to treasury (ZICO, not burned - this is stake, not fee)
        address currency = hs.chargeTreasury.treasuryCurrency;
        LibFeeCollection.collectFee(
            IERC20(currency),
            LibMeta.msgSender(),
            hs.chargeTreasury.treasuryAddress,
            stakeAmount,
            "territory_raid_stake"
        );

        LibColonyWarsStorage.ColonyWarProfile storage defenderProfile =
        cws.colonyWarProfiles[territory.controllingColony];

        // Calculate success probability with diminishing returns
        uint256 validatedStake = _validateTerritoryStake(
            stakeAmount,
            defenderProfile.defensiveStake,
            true // isRaid
        );

        uint256 stakeBonus = _calculateTerritoryStakeBonus(
            validatedStake,
            defenderProfile.defensiveStake,
            true // isRaid
        );

        // Simplified success calculation
        uint256 baseChance = 25;
        uint256 successChance = baseChance + stakeBonus;
        uint8 scoutBonus = WarfareHelper.getScoutingBonus(raiderColony, territory.controllingColony, territoryId, cws);
        successChance += scoutBonus;

        if (successChance > 75) successChance = 75; // Cap at 75%

        // Defensive bonus based on territory type
        if (territory.territoryType == 3) { // Fortress
            successChance = (successChance * 80) / 100; // 20% penalty vs fortresses
        }

        // Generate controlled randomness
        uint256 randomSeed = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            raiderColony,
            territoryId,
            stakeAmount
        )));
        uint256 randomness = randomSeed % 100;

        // Update raid timestamp regardless of outcome
        territory.lastRaidTime = uint32(block.timestamp);

        if (randomness < successChance) {
            // Successful raid - calculate damage
            uint256 baseDamage = 8; // Base 8% damage
            uint256 stakeDamageBonus = (stakeAmount - minStake) / (minStake / 5); // Up to 5% extra
            if (stakeDamageBonus > 5) stakeDamageBonus = 5;

            uint256 totalDamage = baseDamage + stakeDamageBonus;
            if (totalDamage > 15) totalDamage = 15; // Cap at 15% damage per raid

            // Apply damage
            territory.damageLevel += uint16(totalDamage);
            if (territory.damageLevel > 100) territory.damageLevel = 100;

            // Partial refund for successful raid (20% of stake)
            uint256 refund = stakeAmount / 5;
            LibFeeCollection.transferFromTreasury(
                LibMeta.msgSender(),
                refund,
                "raid_success_refund"
            );

            // Remaining 80% goes to season prize pool
            season.prizePool += (stakeAmount - refund);

            // Add war stress to defender
            if (defenderProfile.warStress < 10) {
                defenderProfile.warStress++;
            }
            defenderProfile.lastStressTime = uint32(block.timestamp);

            uint256 defenderRaidPenalty = minStake / 10; // 10% of minimum stake

            if (defenderProfile.defensiveStake >= defenderRaidPenalty) {
                defenderProfile.defensiveStake -= defenderRaidPenalty;
                cws.colonyLosses[territory.controllingColony] += defenderRaidPenalty;
            }

            emit TerritoryRaided(territoryId, raiderColony, territory.damageLevel);

            // Trigger raid achievement
            address raiderOwner = hs.colonyCreators[raiderColony];
            if (raiderOwner != address(0)) {
                LibAchievementTrigger.triggerRaid(raiderOwner, cws.colonyWinStreaks[raiderColony]);
            }

        } else {
            // Failed raid - entire stake goes to season prize pool
            season.prizePool += stakeAmount;

            emit TerritoryRaidFailed(territoryId, raiderColony);
        }
    }

    /**
     * @notice Scout enemy territory using Observatory bonus
     * @param territoryId Territory to scout
     * @param observatoryId Observatory territory ID you control
     */
    function scoutTerritory(uint256 territoryId, uint256 observatoryId)
        external
        whenNotPaused
        nonReentrant
        returns (
            uint256 defensiveStake,
            uint256 estimatedTokenCount,
            uint32 lastActivityTime,
            uint8 warStress,
            uint256 totalLosses
        )
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("territories");

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        // Rate limiting - one scout per hour per observatory
        if (block.timestamp < cws.territoryLastScout[observatoryId] + 3600) {
            revert RateLimitExceeded();
        }

        LibColonyWarsStorage.Territory storage observatory = cws.territories[observatoryId];

        if (observatory.territoryType != 4) {
            revert NotObservatoryType();
        }
        if (observatory.controllingColony == bytes32(0)) {
            revert ObservatoryNotControlled();
        }
        if (observatory.damageLevel >= 75) {
            revert ObservatoryTooDamaged();
        }

        bytes32 callerColony = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());
        if (observatory.controllingColony != callerColony) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not your observatory");
        }

        if (!ColonyHelper.isColonyCreator(observatory.controllingColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Only observatory controller can scout");
        }

        LibColonyWarsStorage.Territory storage target = cws.territories[territoryId];
        if (target.controllingColony == bytes32(0)) {
            return (0, 0, 0, 0, 0);
        }

        // Collect scouting operation fee (configured YELLOW, burned)
        LibColonyWarsStorage.OperationFee storage scoutingFee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_SCOUTING);
        LibFeeCollection.processConfiguredFee(
            scoutingFee,
            LibMeta.msgSender(),
            "territory_scouting"
        );

        // Update observatory usage timestamp
        cws.territoryLastScout[observatoryId] = block.timestamp;

        // Consume observatory maintenance (small amount)
        if (observatory.lastMaintenancePayment > 0) {
            if (observatory.lastMaintenancePayment > 3600) {
                observatory.lastMaintenancePayment -= 3600;
            } else {
                observatory.lastMaintenancePayment = 0;
            }
        }

        LibColonyWarsStorage.ColonyWarProfile storage profile =
            cws.colonyWarProfiles[target.controllingColony];

        defensiveStake = profile.defensiveStake;
        warStress = profile.warStress;

        // Intelligence level based on observatory bonus value
        if (observatory.bonusValue >= 20) {
            // High-level intelligence: Full information
            uint256[] storage colonyMembers = hs.colonies[target.controllingColony];
            estimatedTokenCount = colonyMembers.length;
            lastActivityTime = profile.lastAttackTime;
            totalLosses = cws.colonyLosses[target.controllingColony];

        } else if (observatory.bonusValue >= 10) {
            // Medium intelligence: Approximate information
            uint256[] storage colonyMembers = hs.colonies[target.controllingColony];
            uint256 actualCount = colonyMembers.length;
            estimatedTokenCount = (actualCount / 5) * 5;
            lastActivityTime = profile.lastAttackTime;
            totalLosses = 0;

        } else {
            // Basic intelligence: Limited information
            estimatedTokenCount = 0;
            lastActivityTime = 0;
            totalLosses = 0;
        }

        // Add war stress to target
        if (profile.warStress < 10) {
            profile.warStress++;
            profile.lastStressTime = uint32(block.timestamp);
        }

        // STRATEGIC BONUS: Mark target as scouted for 24h attack bonus
        cws.scoutedTargets[callerColony][target.controllingColony] = uint32(block.timestamp + 86400);
        cws.scoutedTerritories[callerColony][territoryId] = uint32(block.timestamp + 86400);

        emit TerritoryScouted(
            territoryId,
            observatoryId,
            callerColony,
            target.controllingColony,
            scoutingFee.baseAmount,
            observatory.bonusValue >= 20 ? 3 : (observatory.bonusValue >= 10 ? 2 : 1)
        );

        return (defensiveStake, estimatedTokenCount, lastActivityTime, warStress, totalLosses);
    }

    /**
     * @notice Use Healing Sanctuary to reduce fatigue
     * @param sanctuaryId Healing Sanctuary territory ID
     * @param collectionIds Collection IDs of tokens
     * @param tokenIds Token IDs to heal
     */
    function recoverWarriors(
        uint256 sanctuaryId,
        uint256[] calldata collectionIds,
        uint256[] calldata tokenIds
    )
        external
        whenNotPaused
        nonReentrant
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("territories");

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        LibColonyWarsStorage.Territory storage sanctuary = cws.territories[sanctuaryId];

        if (sanctuary.territoryType != 5) {
            revert NotSanctuaryType();
        }
        if (sanctuary.controllingColony == bytes32(0)) {
            revert SanctuaryNotControlled();
        }
        if (sanctuary.damageLevel >= 50) {
            revert SanctuaryToooDamaged();
        }

        bytes32 callerColony = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());
        if (sanctuary.controllingColony != callerColony) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not your sanctuary");
        }

        if ((block.timestamp < sanctuary.lastMaintenancePayment + 21600) && !LibColonyWarsStorage.checkActionCooldown(sanctuaryId, "healing", 21600)) {
            revert ActionOnCooldown();
        }

        if (collectionIds.length != tokenIds.length || tokenIds.length > 3) {
            revert TooManyTokensToHeal();
        }

        if (!ColonyHelper.isColonyCreator(sanctuary.controllingColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Only sanctuary controller can heal");
        }

        uint256[] memory combinedIds = WarfareHelper.verifyAndConvertTokens(
            collectionIds,
            tokenIds,
            callerColony,
            hs
        );

        uint256 healingPower = sanctuary.bonusValue;

        // Collect healing operation fee
        LibColonyWarsStorage.OperationFee storage healingFee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_HEALING);
        LibFeeCollection.processConfiguredFee(
            healingFee,
            LibMeta.msgSender(),
            tokenIds.length,
            "sanctuary_healing"
        );

        for (uint256 i = 0; i < combinedIds.length; i++) {
            PowerMatrix storage charge = hs.performedCharges[combinedIds[i]];

            if (charge.lastChargeTime > 0) {
                uint256 fatigueReduction = healingPower * 2;
                if (charge.fatigueLevel > fatigueReduction) {
                    charge.fatigueLevel -= uint128(fatigueReduction);
                } else {
                    charge.fatigueLevel = 0;
                }

                uint256 chargeRestore = (charge.maxCharge * healingPower) / 100;
                charge.currentCharge = charge.currentCharge + uint128(chargeRestore) > charge.maxCharge ?
                    charge.maxCharge : charge.currentCharge + uint128(chargeRestore);
            }
        }

        sanctuary.lastMaintenancePayment = uint32(block.timestamp);

        emit WarfareHelper.TokensHealed(sanctuaryId, callerColony, combinedIds, healingPower);
    }

    /**
     * @notice Repair damaged territory to restore full bonus
     * @param territoryId Territory to repair
     */
    function repairTerritory(uint256 territoryId)
        external
        whenNotPaused
        nonReentrant
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("territories");

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        if (!LibColonyWarsStorage.checkActionCooldown(territoryId, "repair", 3600)) {
            revert ActionOnCooldown();
        }

        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        if (!territory.active) {
            revert TerritoryNotFound();
        }
        if (territory.controllingColony == bytes32(0)) {
            revert TerritoryNotFound();
        }
        if (territory.damageLevel == 0) {
            revert NoRepairNeeded();
        }

        if (!ColonyHelper.isColonyCreator(territory.controllingColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Only territory controller can repair");
        }

        // Collect repair operation fee
        LibColonyWarsStorage.OperationFee storage repairFee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_REPAIR);
        LibFeeCollection.processConfiguredFee(
            repairFee,
            LibMeta.msgSender(),
            territory.damageLevel,
            "territory_repair"
        );

        uint16 damageRepaired = territory.damageLevel;
        territory.damageLevel = 0;

        uint256 actualCost = (repairFee.baseAmount * repairFee.multiplier * damageRepaired) / 100;
        emit TerritoryRepaired(territoryId, territory.controllingColony, actualCost);
    }

    // ============ INTERNAL HELPER FUNCTIONS ============

    /**
     * @notice Validate stake amount for territory operations with caps
     * @dev Used for raids to prevent economic overwhelming
     */
    function _validateTerritoryStake(
        uint256 stakeAmount,
        uint256 defenderStake,
        bool isRaid
    ) internal pure returns (uint256 validatedStake) {
        uint256 minStake = defenderStake / 2;
        if (stakeAmount < minStake) {
            revert InsufficientRaidStake();
        }

        uint256 maxStake;
        if (isRaid) {
            maxStake = minStake * 4;
        } else {
            maxStake = defenderStake * 4;
        }

        if (stakeAmount > maxStake) {
            validatedStake = maxStake;
        } else {
            validatedStake = stakeAmount;
        }

        return validatedStake;
    }

    /**
     * @notice Calculate progressive stake bonus for territory operations
     */
    function _calculateTerritoryStakeBonus(
        uint256 stakeAmount,
        uint256 defenderStake,
        bool isRaid
    ) internal pure returns (uint256 bonusPercentage) {
        uint256 stakeRatio = (stakeAmount * 100) / defenderStake;

        if (isRaid) {
            if (stakeRatio <= 100) {
                bonusPercentage = 50 + ((stakeRatio - 50) * 50) / 50;
            } else {
                bonusPercentage = 100 + ((stakeRatio - 100) * 40) / 100;
                if (bonusPercentage > 140) bonusPercentage = 140;
            }
        } else {
            if (stakeRatio <= 100) {
                bonusPercentage = 30 + ((stakeRatio - 50) * 35) / 50;
            } else {
                bonusPercentage = 65 + ((stakeRatio - 100) * 30) / 100;
                if (bonusPercentage > 95) bonusPercentage = 95;
            }
        }

        return bonusPercentage;
    }
}
