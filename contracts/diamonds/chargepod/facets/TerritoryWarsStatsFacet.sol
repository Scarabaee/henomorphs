// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";

/**
 * @title TerritoryWarsStatsFacet
 * @notice View functions and statistics for territory warfare system
 * @dev Contains all view functions and read-only operations for territory wars
 */
contract TerritoryWarsStatsFacet is AccessControlBase {

    struct ActiveSiegeInfo {
        bytes32 siegeId;
        uint256 territoryId;
        string territoryName;
        bytes32 attackerColony;
        bytes32 defenderColony;
        uint256 stakeAmount;
        uint32 siegeStartTime;
        uint32 siegeEndTime;
        uint8 siegeState; // 0=preparation, 1=active
        bool hasDefense;
        uint32 timeRemaining;
        string status; // "PREPARATION", "ACTIVE", "READY_TO_RESOLVE"
    }

    struct TerritoryRaidInfo {
        uint256 territoryId;
        string territoryName;
        bytes32 controllingColony;
        uint16 damageLevel;
        uint32 lastRaidTime;
        bool canRaid;
        uint32 raidCooldownRemaining;
        bool hasActiveSiege;
        uint256 activeSiegesCount;
    }

    struct ScoutedTerritoryInfo {
        uint256 territoryId;
        string territoryName;
        bytes32 controllingColony;
        
        // Intel (only if scouted)
        bool hasIntel;
        uint32 intelExpiry;
        uint8 attackBonus; // 8% for territories, 5% for colonies
        
        // Key defensive info
        uint256 defenderStake;
        uint16 damageLevel;
        bool defenderInAlliance;
        bool defenderRecentlyActive;
    }

    /**
     * @notice Get siege details
     * @param siegeId Siege ID
     * @return siege Territory siege information
     */
    function getTerritorySiege(bytes32 siegeId) 
        external 
        view 
        returns (LibColonyWarsStorage.TerritorySiege memory siege) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        return cws.territorySieges[siegeId];
    }

    /**
     * @notice Get siege snapshot
     * @param siegeId Siege ID
     * @return attackerPowers Array of attacker token powers
     * @return defenderPowers Array of defender token powers
     */
    function getSiegeSnapshot(bytes32 siegeId) 
        external 
        view 
        returns (uint256[] memory attackerPowers, uint256[] memory defenderPowers) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.SiegeSnapshot storage snapshot = cws.siegeSnapshots[siegeId];
        return (snapshot.attackerPowers, snapshot.defenderPowers);
    }

    /**
     * @notice Get detailed raid information for territory
     * @param territoryId Territory to check
     * @return damageLevel Current damage (0-100)
     * @return canRaid Whether territory can be raided now
     * @return cooldownRemaining Seconds until next raid allowed
     * @return minStakeRequired Minimum ZICO needed to raid
     * @return repairCost Cost to fully repair territory
     * @return effectiveBonus Current bonus after damage reduction
     */
    function getTerritoryRaidInfo(uint256 territoryId) 
        external 
        view 
        returns (
            uint16 damageLevel,
            bool canRaid,
            uint256 cooldownRemaining,
            uint256 minStakeRequired,
            uint256 repairCost,
            uint256 effectiveBonus
        ) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        
        damageLevel = territory.damageLevel;
        
        // Calculate repair cost
        repairCost = uint256(damageLevel) * 3 ether;
        
        // Calculate effective bonus after damage
        uint256 baseBonusValue = territory.bonusValue;
        uint256 damageReduction = (baseBonusValue * damageLevel) / 100;
        effectiveBonus = baseBonusValue - damageReduction;
        
        // Check if can raid
        uint32 raidCooldownEnd = territory.lastRaidTime + 86400;
        bool cooldownPassed = block.timestamp >= raidCooldownEnd;
        bool notFullyDamaged = damageLevel < 100;
        bool hasController = territory.controllingColony != bytes32(0);
        
        canRaid = cooldownPassed && notFullyDamaged && hasController && territory.active;
        
        // Calculate cooldown remaining
        if (raidCooldownEnd > uint32(block.timestamp)) {
            cooldownRemaining = raidCooldownEnd - uint32(block.timestamp);
        } else {
            cooldownRemaining = 0;
        }
        
        // Calculate minimum stake required
        if (territory.active && hasController) {
            uint256 territoryBaseValue = cws.config.territoryCaptureCost;
            uint256 bonusMultiplier = 100 + territory.bonusValue;
            minStakeRequired = (territoryBaseValue * bonusMultiplier) / 200;
        } else {
            minStakeRequired = 0;
        }
    }
 
    /**
     * @notice Get territory raid status
     */
    function getTerritoryRaidStatus(uint256 territoryId) 
        external 
        view 
        returns (
            uint16 damageLevel,
            bool canRaid,
            uint256 cooldownRemaining,
            uint256 repairCost
        ) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        
        damageLevel = territory.damageLevel;
        repairCost = damageLevel * 2 ether;
        
        uint32 raidCooldownEnd = territory.lastRaidTime + 86400;
        if (block.timestamp >= raidCooldownEnd && damageLevel < 100) {
            canRaid = true;
            cooldownRemaining = 0;
        } else {
            canRaid = false;
            cooldownRemaining = raidCooldownEnd > uint32(block.timestamp) ? 
                raidCooldownEnd - uint32(block.timestamp) : 0;
        }
    }

    /**
     * @notice Get all active sieges across all territories
     */
    function getActiveTerritorySieges() 
        external 
        view 
        returns (ActiveSiegeInfo[] memory activesieges) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        bytes32[] storage siegeIds = cws.activeSieges;
        activesieges = new ActiveSiegeInfo[](siegeIds.length);
        
        for (uint256 i = 0; i < siegeIds.length; i++) {
            bytes32 siegeId = siegeIds[i];
            LibColonyWarsStorage.TerritorySiege storage siege = cws.territorySieges[siegeId];
            LibColonyWarsStorage.Territory storage territory = cws.territories[siege.territoryId];
            
            uint32 endTime = siege.siegeState == 0 ? 
                siege.siegeStartTime + cws.config.battlePreparationTime :
                siege.siegeEndTime;
                
            uint32 timeRemaining = 0;
            if (block.timestamp < endTime) {
                timeRemaining = endTime - uint32(block.timestamp);
            }
            
            activesieges[i] = ActiveSiegeInfo({
                siegeId: siegeId,
                territoryId: siege.territoryId,
                territoryName: territory.name,
                attackerColony: siege.attackerColony,
                defenderColony: siege.defenderColony,
                stakeAmount: siege.stakeAmount,
                siegeStartTime: siege.siegeStartTime,
                siegeEndTime: endTime,
                siegeState: siege.siegeState,
                hasDefense: siege.defenderTokens.length > 0,
                timeRemaining: timeRemaining,
                status: _getSiegeStatusString(siege.siegeState, siege.siegeStartTime, endTime)
            });
        }
        
        return activesieges;
    }

    /**
     * @notice Get active sieges for specific territory
     * @param territoryId Territory to check
     * @return territorySieges Array of sieges on this territory
     */
    function getTerritoryActiveSieges(uint256 territoryId) 
        external 
        view 
        returns (ActiveSiegeInfo[] memory territorySieges) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        bytes32[] storage siegeIds = cws.territoryActiveSieges[territoryId];
        territorySieges = new ActiveSiegeInfo[](siegeIds.length);
        
        for (uint256 i = 0; i < siegeIds.length; i++) {
            bytes32 siegeId = siegeIds[i];
            LibColonyWarsStorage.TerritorySiege storage siege = cws.territorySieges[siegeId];
            LibColonyWarsStorage.Territory storage territory = cws.territories[siege.territoryId];
            
            uint32 endTime = siege.siegeState == 0 ? 
                siege.siegeStartTime + cws.config.battlePreparationTime :
                siege.siegeEndTime;
                
            uint32 timeRemaining = 0;
            if (block.timestamp < endTime) {
                timeRemaining = endTime - uint32(block.timestamp);
            }
            
            territorySieges[i] = ActiveSiegeInfo({
                siegeId: siegeId,
                territoryId: siege.territoryId,
                territoryName: territory.name,
                attackerColony: siege.attackerColony,
                defenderColony: siege.defenderColony,
                stakeAmount: siege.stakeAmount,
                siegeStartTime: siege.siegeStartTime,
                siegeEndTime: endTime,
                siegeState: siege.siegeState,
                hasDefense: siege.defenderTokens.length > 0,
                timeRemaining: timeRemaining,
                status: _getSiegeStatusString(siege.siegeState, siege.siegeStartTime, endTime)
            });
        }
        
        return territorySieges;
    }

    /**
     * @notice Get comprehensive territory raid overview
     * @return territories Array of all territories with raid status
     */
    function getAllTerritoriesRaidStatus() 
        external 
        view 
        returns (TerritoryRaidInfo[] memory territories) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        uint256 totalTerritories = cws.territoryCounter;
        territories = new TerritoryRaidInfo[](totalTerritories);
        
        for (uint256 i = 1; i <= totalTerritories; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[i];
            
            if (!territory.active) continue;
            
            // Check raid cooldown
            uint32 raidCooldownEnd = territory.lastRaidTime + 86400;
            bool canRaid = block.timestamp >= raidCooldownEnd && 
                        territory.controllingColony != bytes32(0) &&
                        territory.damageLevel < 100;
            
            uint32 cooldownRemaining = 0;
            if (raidCooldownEnd > uint32(block.timestamp)) {
                cooldownRemaining = raidCooldownEnd - uint32(block.timestamp);
            }
            
            // Check active sieges
            uint256 activeSiegesCount = cws.territoryActiveSieges[i].length;
            
            territories[i-1] = TerritoryRaidInfo({
                territoryId: i,
                territoryName: territory.name,
                controllingColony: territory.controllingColony,
                damageLevel: territory.damageLevel,
                lastRaidTime: territory.lastRaidTime,
                canRaid: canRaid,
                raidCooldownRemaining: cooldownRemaining,
                hasActiveSiege: activeSiegesCount > 0,
                activeSiegesCount: activeSiegesCount
            });
        }
        
        return territories;
    }

    /**
     * @notice Get count of active sieges (simple counter)
     * @return count Number of active sieges
     */
    function getActiveSiegesCount() external view returns (uint256 count) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        return cws.activeSieges.length;
    }

    /**
     * @notice Get all territories available for raiding
     * @return raidableTeritories Array of territories that can be raided
     */
    function getActiveRaids()
        external
        view
        returns (TerritoryRaidInfo[] memory raidableTeritories)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        uint256 totalTerritories = cws.territoryCounter;

        // First pass: count raidable territories
        uint256 raidableCount = 0;
        for (uint256 i = 1; i <= totalTerritories; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[i];

            if (!territory.active) continue;
            if (territory.controllingColony == bytes32(0)) continue;
            if (territory.damageLevel >= 100) continue;

            uint32 raidCooldownEnd = territory.lastRaidTime + 86400;
            if (block.timestamp >= raidCooldownEnd) {
                raidableCount++;
            }
        }

        // Second pass: populate array
        raidableTeritories = new TerritoryRaidInfo[](raidableCount);
        uint256 index = 0;

        for (uint256 i = 1; i <= totalTerritories; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[i];

            if (!territory.active) continue;
            if (territory.controllingColony == bytes32(0)) continue;
            if (territory.damageLevel >= 100) continue;

            uint32 raidCooldownEnd = territory.lastRaidTime + 86400;
            if (block.timestamp < raidCooldownEnd) continue;

            // Check active sieges
            uint256 activeSiegesCount = cws.territoryActiveSieges[i].length;

            raidableTeritories[index] = TerritoryRaidInfo({
                territoryId: i,
                territoryName: territory.name,
                controllingColony: territory.controllingColony,
                damageLevel: territory.damageLevel,
                lastRaidTime: territory.lastRaidTime,
                canRaid: true,
                raidCooldownRemaining: 0,
                hasActiveSiege: activeSiegesCount > 0,
                activeSiegesCount: activeSiegesCount
            });

            index++;
        }

        return raidableTeritories;
    }

    /**
     * @notice Get scouting info for territory
     * @param territoryId Territory to check
     * @param scoutingColony Colony requesting info
     * @return info Scouted territory information
     */
    function getScoutedTerritoryInfo(uint256 territoryId, bytes32 scoutingColony)
        external
        view
        returns (ScoutedTerritoryInfo memory info)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        
        // Basic info (always visible)
        info.territoryId = territoryId;
        info.territoryName = territory.name;
        info.controllingColony = territory.controllingColony;
        
        // Check scouting status
        uint32 scoutExpiry = cws.scoutedTerritories[scoutingColony][territoryId];
        info.hasIntel = block.timestamp <= scoutExpiry;
        info.intelExpiry = scoutExpiry;
        info.attackBonus = info.hasIntel ? 8 : 0;
        
        if (!info.hasIntel || territory.controllingColony == bytes32(0)) {
            return info; // No intel or no controller
        }
        
        // Scouted intelligence
        LibColonyWarsStorage.ColonyWarProfile storage defenderProfile = 
            cws.colonyWarProfiles[territory.controllingColony];
        
        info.defenderStake = defenderProfile.defensiveStake;
        info.damageLevel = territory.damageLevel;
        
        // Check if defender is in alliance
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        address defenderOwner = hs.colonyCreators[territory.controllingColony];
        info.defenderInAlliance = LibColonyWarsStorage.isUserInAlliance(defenderOwner);
        
        // Check if defender was active recently (48h window)
        info.defenderRecentlyActive = _isRecentlyActive(defenderOwner, cws);
        
        return info;
    }

    /**
     * @notice Get scouting info for colony battle
     * @param targetColony Colony to check
     * @param scoutingColony Colony requesting info
     * @return info Basic scouted colony information
     */
    function getScoutedColonyInfo(bytes32 targetColony, bytes32 scoutingColony)
        external
        view
        returns (ScoutedTerritoryInfo memory info)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        // Basic info
        info.territoryId = 0; // Not a territory
        info.territoryName = ""; // No territory name
        info.controllingColony = targetColony;
        
        // Check scouting status
        uint32 scoutExpiry = cws.scoutedTargets[scoutingColony][targetColony];
        info.hasIntel = block.timestamp <= scoutExpiry;
        info.intelExpiry = scoutExpiry;
        info.attackBonus = info.hasIntel ? 5 : 0; // 5% for colonies
        
        if (!info.hasIntel) {
            return info; // No intel
        }
        
        // Scouted colony intelligence
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[targetColony];
        info.defenderStake = profile.defensiveStake;
        info.damageLevel = 0; // Colonies don't have damage
        
        // Check alliance and activity
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        address colonyOwner = hs.colonyCreators[targetColony];
        info.defenderInAlliance = LibColonyWarsStorage.isUserInAlliance(colonyOwner);
        info.defenderRecentlyActive = _isRecentlyActive(colonyOwner, cws);
        
        return info;
    }

    /**
     * @notice List all currently scouted targets
     * @param scoutingColony Colony to check scouts for
     * @return territoryIds Scouted territory IDs
     * @return colonyIds Scouted colony IDs
     * @return expiries Corresponding expiry times
     */
    function getActiveScouts(bytes32 scoutingColony)
        external
        view
        returns (
            uint256[] memory territoryIds,
            bytes32[] memory colonyIds,
            uint32[] memory expiries
        )
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        // Count valid scouts (simplified - check first 50 territories and colonies)
        uint256 maxCheck = 50;
        uint256 validTerritories = 0;
        uint256 validColonies = 0;
        
        // Count valid territory scouts
        uint256 totalTerritories = cws.territoryCounter > maxCheck ? maxCheck : cws.territoryCounter;
        for (uint256 i = 1; i <= totalTerritories; i++) {
            if (block.timestamp <= cws.scoutedTerritories[scoutingColony][i]) {
                validTerritories++;
            }
        }
        
        // Count valid colony scouts (simplified check)
        bytes32[] memory recentTargets = new bytes32[](maxCheck);
        // Note: This would need additional storage to track all scouted colonies
        // For now, return empty colony arrays
        
        // Populate territory results
        territoryIds = new uint256[](validTerritories);
        expiries = new uint32[](validTerritories);
        uint256 index = 0;
        
        for (uint256 i = 1; i <= totalTerritories; i++) {
            uint32 expiry = cws.scoutedTerritories[scoutingColony][i];
            if (block.timestamp <= expiry) {
                territoryIds[index] = i;
                expiries[index] = expiry;
                index++;
            }
        }
        
        // Empty colony arrays for now
        colonyIds = new bytes32[](0);
        
        return (territoryIds, colonyIds, expiries);
    }

    /**
     * @notice Check if target has valid scouting
     * @param scoutingColony Colony doing scouting
     * @param targetColony Target colony (for colony battles)
     * @param territoryId Territory ID (0 for colony battles)
     * @return hasIntel Whether intel is valid
     * @return timeRemaining Seconds until intel expires
     * @return attackBonus Percentage attack bonus
     */
    function checkScoutStatus(
        bytes32 scoutingColony,
        bytes32 targetColony,
        uint256 territoryId
    ) external view returns (bool hasIntel, uint32 timeRemaining, uint8 attackBonus) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        uint32 expiry;
        if (territoryId > 0) {
            // Territory scouting
            expiry = cws.scoutedTerritories[scoutingColony][territoryId];
            attackBonus = 8; // Territory bonus
        } else {
            // Colony scouting
            expiry = cws.scoutedTargets[scoutingColony][targetColony];
            attackBonus = 5; // Colony bonus
        }
        
        hasIntel = block.timestamp <= expiry;
        timeRemaining = hasIntel ? expiry - uint32(block.timestamp) : 0;
        
        if (!hasIntel) {
            attackBonus = 0; // No bonus without valid intel
        }
        
        return (hasIntel, timeRemaining, attackBonus);
    }

    /**
     * @notice Calculate siege status string
     */
    function _getSiegeStatusString(uint8 siegeState, uint32, uint32 endTime) 
        internal 
        view 
        returns (string memory) 
    {
        if (siegeState == 0) {
            return "PREPARATION";
        } else if (siegeState == 1) {
            if (block.timestamp < endTime) {
                return "ACTIVE";
            } else {
                return "READY_TO_RESOLVE";
            }
        } else if (siegeState == 2) {
            return "COMPLETED";
        } else {
            return "CANCELLED";
        }
    }

    /**
     * @notice Get current season territory statistics summary
     * @return seasonId Current season ID
     * @return seasonActive Whether season is active
     * @return totalTerritories Total territory count
     * @return controlledTerritories Territories with controllers
     * @return activeSieges Number of active sieges
     * @return raidableTerritories Territories available for raid
     * @return activeScouts Number of territories with active scout intel
     */
    function getSeasonTerritorySummary()
        external
        view
        returns (
            uint32 seasonId,
            bool seasonActive,
            uint256 totalTerritories,
            uint256 controlledTerritories,
            uint256 activeSieges,
            uint256 raidableTerritories,
            uint256 activeScouts
        )
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        seasonId = cws.currentSeason;
        seasonActive = cws.seasons[seasonId].active;
        totalTerritories = cws.territoryCounter;
        activeSieges = cws.activeSieges.length;

        // Get registered colonies to check their scouts
        bytes32[] storage registeredColonies = cws.seasons[seasonId].registeredColonies;

        for (uint256 i = 1; i <= totalTerritories; i++) {
            LibColonyWarsStorage.Territory storage t = cws.territories[i];
            if (!t.active) continue;

            if (t.controllingColony != bytes32(0)) {
                controlledTerritories++;

                // Check if raidable
                if (block.timestamp >= t.lastRaidTime + 86400 && t.damageLevel < 100) {
                    raidableTerritories++;
                }
            }

            // Count active scouts on this territory
            for (uint256 j = 0; j < registeredColonies.length; j++) {
                if (cws.scoutedTerritories[registeredColonies[j]][i] >= block.timestamp) {
                    activeScouts++;
                }
            }
        }
    }

    /**
     * @notice Check if user was recently active (internal helper)
     */
    function _isRecentlyActive(
        address user,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal view returns (bool active) {
        if (user == address(0)) return false;

        uint256 window = 48 hours;
        bytes4[3] memory selectors = [
            bytes4(keccak256("defendBattle(bytes32,uint256[],uint256[])")),
            bytes4(keccak256("initiateAttack(bytes32,bytes32,uint256[],uint256[],uint256)")),
            bytes4(keccak256("defendSiege(bytes32,uint256[],uint256[])"))
        ];

        for (uint256 i = 0; i < selectors.length; i++) {
            if (block.timestamp < cws.lastActionTime[user][selectors[i]] + window) {
                return true;
            }
        }

        return false;
    }

    // ============ Season Siege History ============

    struct SeasonSiegeInfo {
        bytes32 siegeId;
        uint256 territoryId;
        string territoryName;
        bytes32 attackerColony;
        bytes32 defenderColony;
        uint256 stakeAmount;
        uint256 prizePool;
        uint8 siegeState; // 0=preparation, 1=active, 2=completed, 3=cancelled
        uint32 siegeStartTime;
        uint32 siegeEndTime;
        bytes32 winner;
        bool resolved;
        bool isBetrayalAttack;
    }

    struct ColonySiegeInfo {
        bytes32 siegeId;
        uint256 territoryId;
        bool wasAttacker;
        bytes32 opponent;
        uint256 stakeAmount;
        bool won;
        uint32 siegeStartTime;
        bool resolved;
    }

    /**
     * @notice Get sieges for specific season with pagination
     * @param seasonId Season to get sieges for
     * @param includeResolved Whether to include already resolved sieges
     * @param offset Starting index for pagination
     * @param limit Maximum number of sieges to return (0 = all)
     * @return sieges Array of siege information
     * @return total Total number of matching sieges
     */
    function getSeasonSieges(uint32 seasonId, bool includeResolved, uint256 offset, uint256 limit)
        external
        view
        returns (SeasonSiegeInfo[] memory sieges, uint256 total)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        bytes32[] storage siegeIds = cws.seasonSieges[seasonId];

        // Single pass: collect matching sieges up to limit
        uint256 maxResults = limit == 0 ? siegeIds.length : limit;
        SeasonSiegeInfo[] memory tempSieges = new SeasonSiegeInfo[](maxResults);
        uint256 found = 0;
        uint256 skipped = 0;

        for (uint256 i = 0; i < siegeIds.length && found < maxResults; i++) {
            bool resolved = cws.siegeResolved[siegeIds[i]];
            if (includeResolved || !resolved) {
                if (skipped < offset) {
                    skipped++;
                    total++;
                    continue;
                }
                LibColonyWarsStorage.TerritorySiege storage siege = cws.territorySieges[siegeIds[i]];
                LibColonyWarsStorage.Territory storage territory = cws.territories[siege.territoryId];

                tempSieges[found] = SeasonSiegeInfo({
                    siegeId: siegeIds[i],
                    territoryId: siege.territoryId,
                    territoryName: territory.name,
                    attackerColony: siege.attackerColony,
                    defenderColony: siege.defenderColony,
                    stakeAmount: siege.stakeAmount,
                    prizePool: siege.prizePool,
                    siegeState: siege.siegeState,
                    siegeStartTime: siege.siegeStartTime,
                    siegeEndTime: siege.siegeEndTime,
                    winner: siege.winner,
                    resolved: resolved,
                    isBetrayalAttack: siege.isBetrayalAttack
                });
                found++;
                total++;
            }
        }

        // Continue counting total if we hit limit early
        if (found == maxResults) {
            for (uint256 i = found + skipped; i < siegeIds.length; i++) {
                bool resolved = cws.siegeResolved[siegeIds[i]];
                if (includeResolved || !resolved) {
                    total++;
                }
            }
        }

        // Copy to correctly sized array
        sieges = new SeasonSiegeInfo[](found);
        for (uint256 i = 0; i < found; i++) {
            sieges[i] = tempSieges[i];
        }
    }

    /**
     * @notice Get siege history for specific colony with pagination
     * @param colonyId Colony to get sieges for
     * @param seasonId Season filter (0 for all seasons)
     * @param offset Starting index for pagination
     * @param limit Maximum number of sieges to return (0 = all)
     * @return sieges Array of sieges involving the colony
     * @return total Total number of matching sieges
     */
    function getColonySiegeHistory(bytes32 colonyId, uint32 seasonId, uint256 offset, uint256 limit)
        external
        view
        returns (ColonySiegeInfo[] memory sieges, uint256 total)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        bytes32[] storage siegeIds = seasonId == 0
            ? cws.colonySiegeHistory[colonyId]
            : cws.seasonSieges[seasonId];

        // Single pass: collect matching sieges up to limit
        uint256 maxResults = limit == 0 ? siegeIds.length : limit;
        ColonySiegeInfo[] memory tempSieges = new ColonySiegeInfo[](maxResults);
        uint256 found = 0;
        uint256 skipped = 0;

        for (uint256 i = 0; i < siegeIds.length && found < maxResults; i++) {
            LibColonyWarsStorage.TerritorySiege storage siege = cws.territorySieges[siegeIds[i]];
            if (siege.attackerColony == colonyId || siege.defenderColony == colonyId) {
                if (skipped < offset) {
                    skipped++;
                    total++;
                    continue;
                }
                tempSieges[found] = ColonySiegeInfo({
                    siegeId: siegeIds[i],
                    territoryId: siege.territoryId,
                    wasAttacker: (siege.attackerColony == colonyId),
                    opponent: (siege.attackerColony == colonyId) ? siege.defenderColony : siege.attackerColony,
                    stakeAmount: siege.stakeAmount,
                    won: (siege.winner == colonyId),
                    siegeStartTime: siege.siegeStartTime,
                    resolved: cws.siegeResolved[siegeIds[i]]
                });
                found++;
                total++;
            }
        }

        // Continue counting total if we hit limit early
        if (found == maxResults) {
            for (uint256 i = found + skipped; i < siegeIds.length; i++) {
                LibColonyWarsStorage.TerritorySiege storage siege = cws.territorySieges[siegeIds[i]];
                if (siege.attackerColony == colonyId || siege.defenderColony == colonyId) {
                    total++;
                }
            }
        }

        // Copy to correctly sized array
        sieges = new ColonySiegeInfo[](found);
        for (uint256 i = 0; i < found; i++) {
            sieges[i] = tempSieges[i];
        }
    }

    /**
     * @notice Get siege history for specific territory with pagination
     * @param territoryId Territory to get sieges for
     * @param includeResolved Whether to include resolved sieges
     * @param offset Starting index for pagination
     * @param limit Maximum number of sieges to return (0 = all)
     * @return sieges Array of sieges on this territory
     * @return total Total number of matching sieges
     */
    function getTerritorySiegeHistory(uint256 territoryId, bool includeResolved, uint256 offset, uint256 limit)
        external
        view
        returns (SeasonSiegeInfo[] memory sieges, uint256 total)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        bytes32[] storage siegeIds = cws.territoryActiveSieges[territoryId];

        uint256 maxResults = limit == 0 ? siegeIds.length : limit;
        SeasonSiegeInfo[] memory tempSieges = new SeasonSiegeInfo[](maxResults);
        uint256 found = 0;
        uint256 skipped = 0;

        for (uint256 i = 0; i < siegeIds.length && found < maxResults; i++) {
            bool resolved = cws.siegeResolved[siegeIds[i]];
            if (includeResolved || !resolved) {
                if (skipped < offset) {
                    skipped++;
                    total++;
                    continue;
                }
                LibColonyWarsStorage.TerritorySiege storage siege = cws.territorySieges[siegeIds[i]];
                LibColonyWarsStorage.Territory storage territory = cws.territories[siege.territoryId];

                tempSieges[found] = SeasonSiegeInfo({
                    siegeId: siegeIds[i],
                    territoryId: siege.territoryId,
                    territoryName: territory.name,
                    attackerColony: siege.attackerColony,
                    defenderColony: siege.defenderColony,
                    stakeAmount: siege.stakeAmount,
                    prizePool: siege.prizePool,
                    siegeState: siege.siegeState,
                    siegeStartTime: siege.siegeStartTime,
                    siegeEndTime: siege.siegeEndTime,
                    winner: siege.winner,
                    resolved: resolved,
                    isBetrayalAttack: siege.isBetrayalAttack
                });
                found++;
                total++;
            }
        }

        if (found == maxResults) {
            for (uint256 i = found + skipped; i < siegeIds.length; i++) {
                bool resolved = cws.siegeResolved[siegeIds[i]];
                if (includeResolved || !resolved) {
                    total++;
                }
            }
        }

        sieges = new SeasonSiegeInfo[](found);
        for (uint256 i = 0; i < found; i++) {
            sieges[i] = tempSieges[i];
        }
    }

    /**
     * @notice Get count of sieges in a season
     * @param seasonId Season to check
     * @return total Total sieges in season
     * @return resolved Number of resolved sieges
     * @return active Number of active/pending sieges
     */
    function getSeasonSiegeCount(uint32 seasonId)
        external
        view
        returns (uint256 total, uint256 resolved, uint256 active)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        bytes32[] storage siegeIds = cws.seasonSieges[seasonId];

        total = siegeIds.length;
        for (uint256 i = 0; i < siegeIds.length; i++) {
            if (cws.siegeResolved[siegeIds[i]]) {
                resolved++;
            } else {
                active++;
            }
        }
    }
}