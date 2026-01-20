// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibColonyWarsStorage} from "./LibColonyWarsStorage.sol";
import {LibHenomorphsStorage} from "./LibHenomorphsStorage.sol";
import {LibFeeCollection} from "../../staking/libraries/LibFeeCollection.sol";
import {PodsUtils} from "../../../libraries/PodsUtils.sol";
import {PowerMatrix} from "../../../libraries/HenomorphsModel.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibDiamond} from "../../shared/libraries/LibDiamond.sol";
import {IStakingCoreFacet} from "../../staking/interfaces/IStakingInterfaces.sol";
import {StakedSpecimen} from "../../../libraries/StakingModel.sol";
    
// Token stats structure (identical in both facets)
struct TokenStats {
    uint8 variant;
    uint256 currentCharge;
    uint256 maxCharge;
    uint8 fatigueLevel;
    uint256 wearLevel;
    uint256 accessoryBonus;
    bool hasValidCharge;
}

// Interface for AccessoryFacet (identical in both facets)
interface IAccessoryFacet {
    function getTokenPerformanceStats(uint256[] calldata collectionIds, uint256[] calldata tokenIds) 
        external view returns (TokenStats[] memory);
}

interface IAllianceWarsFacet {
    function getAllianceDefensiveBonuses(bytes32 colonyId) 
        external 
        view 
        returns (bool hasAlliance, uint256 defensiveBonus, uint256 reinforcementTokens, uint256 sharedStakeBonus);
}

interface IDebtWarsFacet {
    function getCurrentColonyDebt(bytes32 colonyId) external view returns (uint256);
}

/**
 * @title WarfareHelper Library
 * @notice Shared functions for ColonyWarsFacet and TerritoryWarsFacet
 * @dev Simple library containing only truly duplicated functions from both facets
 */
library WarfareHelper {

    // ============ HELPER STRUCTS FOR STACK MANAGEMENT ============

    /// @dev Parameters for siege base power calculation
    struct SiegeBaseParams {
        bytes32 attackerColony;
        bytes32 defenderColony;
        uint256 territoryId;
    }

    /// @dev Results from siege base power calculation
    struct SiegeBaseResult {
        uint256 attackerPower;
        uint256 defenderPower;
        uint256 randomness;
        string weatherDesc;
    }

    /// @dev Parameters for siege attacker power calculation
    struct SiegeAttackerParams {
        bytes32 attackerColony;
        bytes32 defenderColony;
        uint256 territoryId;
        uint256 basePower;
        uint256 stakeAmount;
        uint256 defenderStake;
    }

    /// @dev Parameters for siege defender power calculation
    struct SiegeDefenderParams {
        bytes32 defenderColony;
        uint256 territoryId;
        uint256 basePower;
        uint256[] defenderPowers;
        bytes32 siegeId;
    }

    /// @dev Parameters for forfeit penalty application
    struct ForfeitParams {
        bytes32 attackerColony;
        bytes32 defenderColony;
        uint256 stakeAmount;
        uint256 defenderStake;
        uint8 forfeitType;
        uint32 seasonId;
        bool isTerritory;
    }

    // Events (identical in both facets)
    event BetrayalRecorded(bytes32 indexed colonyId, bytes32 indexed allianceId);
    event ColonyLeftAlliance(bytes32 indexed allianceId, bytes32 indexed colonyId, string reason);
    event AutoDefenseTriggered(
        bytes32 indexed battleId,
        bytes32 indexed defenderColony,
        address indexed defenderOwner,
        uint256[] autoSelectedTokens,
        uint256 defensePowerAdded,
        uint8 penaltyApplied
    );
    event TokensHealed(
        uint256 indexed sanctuaryId,
        bytes32 indexed colonyId,
        uint256[] tokenIds,
        uint256 healingPower
    );

    // Errors (identical in both facets)
    error TokensNoLongerInColony();
    error TokenInActiveBattle();
    error InvalidTokenCount();
    error ActionOnCooldown();

    /**
     * @notice Verify tokens belong to colony and convert to combined IDs
     * @dev IDENTICAL function in both facets - extracted 1:1
     * @param collectionIds Array of collection IDs
     * @param tokenIds Array of token IDs  
     * @param colonyId Colony that should own the tokens
     * @param hs Henomorphs storage reference
     * @return combinedIds Array of combined IDs for the tokens
     */
    function verifyAndConvertTokens(
        uint256[] memory collectionIds,
        uint256[] memory tokenIds,
        bytes32 colonyId,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) internal view returns (uint256[] memory combinedIds) {
        combinedIds = new uint256[](collectionIds.length);
        
        for (uint256 i = 0; i < collectionIds.length; i++) {
            uint256 collectionId = collectionIds[i];
            uint256 tokenId = tokenIds[i];
            
            // Combine IDs using utility function
            uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
            
            // Verify token belongs to the specified colony
            if (hs.specimenColonies[combinedId] != colonyId) {
                revert TokensNoLongerInColony();
            }
            
            combinedIds[i] = combinedId;
        }
        
        return combinedIds;
    }

    /**
     * @notice Calculate token power from comprehensive stats
     * @dev IDENTICAL function in both facets - extracted 1:1
     * @param stats Token stats structure with all relevant parameters
     * @return power Calculated power value for battle
     */
    function calculateTokenPower(TokenStats memory stats) internal pure returns (uint256 power) {
        // Base power per token
        power = 100;
        
        // Variant bonus (10% per variant level above 1)
        if (stats.variant > 1) {
            power += (stats.variant - 1) * 10;
        }
        
        // Charge level bonus (0-50% based on current charge vs max charge)
        if (stats.hasValidCharge && stats.maxCharge > 0) {
            uint256 chargeBonus = (stats.currentCharge * 50) / stats.maxCharge;
            power += chargeBonus;
            
            // Fatigue penalty for overworked tokens
            if (stats.fatigueLevel > LibHenomorphsStorage.FATIGUE_PENALTY_THRESHOLD) {
                uint256 fatiguePenalty = (stats.fatigueLevel - LibHenomorphsStorage.FATIGUE_PENALTY_THRESHOLD) / 2;
                power = power > fatiguePenalty ? power - fatiguePenalty : power / 2;
            }
        }
        
        // Wear penalty (0.5% penalty per wear point)
        if (stats.wearLevel > 0) {
            uint256 wearPenalty = stats.wearLevel / 2;
            power = power > wearPenalty ? power - wearPenalty : power / 2;
        }
        
        // Accessory bonus from equipped items
        power += (power * stats.accessoryBonus) / 100;
        
        return power;
    }

    /**
     * @notice Validate tokens still belong to their colony (prevent exploit)
     * @dev IDENTICAL function in both facets - extracted 1:1
     * @param tokens Array of combined token IDs
     * @param colonyId Expected colony ID
     * @param hs Henomorphs storage reference
     */
    function validateTokensStillInColony(
        uint256[] storage tokens,
        bytes32 colonyId,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) internal view returns (bool) {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (hs.specimenColonies[tokens[i]] != colonyId) {
                return false;
            }
        }
        return true;
    }

    /**
     * @notice Sum array values utility function
     * @dev IDENTICAL function in both facets - extracted 1:1
     * @param array Array to sum
     * @return sum Total sum of all elements
     */
    function sumArray(uint256[] memory array) internal pure returns (uint256 sum) {
        for (uint256 i = 0; i < array.length; i++) {
            sum += array[i];
        }
        return sum;
    }

    /**
     * @notice Apply battle effects to specific token array
     * @dev NEARLY identical - differs only in consumption parameters
     * @param tokens Array of combined token IDs
     * @param consumptionMultiplier Multiplier for consumption (10=colony, 12=territory for winners)
     * @param fatigueMultiplier Multiplier for fatigue (5=colony, 3=territory for winners)
     * @param hs Henomorphs storage reference
     */
    function applyTokenBattleEffects(
        uint256[] storage tokens,
        bool,
        uint8 consumptionMultiplier,
        uint8 fatigueMultiplier,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) internal {
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 combinedId = tokens[i];
            PowerMatrix storage charge = hs.performedCharges[combinedId];
            
            if (charge.lastChargeTime > 0) {
                // Calculate charge consumption based on multiplier
                uint256 chargeConsumption = charge.maxCharge / consumptionMultiplier;
                    
                charge.currentCharge = charge.currentCharge > chargeConsumption ?
                    charge.currentCharge - uint128(chargeConsumption) : 0;
                
                // Apply fatigue increase based on multiplier
                charge.fatigueLevel = charge.fatigueLevel + fatigueMultiplier > LibHenomorphsStorage.MAX_FATIGUE_LEVEL ?
                    LibHenomorphsStorage.MAX_FATIGUE_LEVEL : charge.fatigueLevel + fatigueMultiplier;
                    
                // Track battle experience
                charge.consecutiveActions += 1;
            }
        }
    }

    /**
     * @notice Get valid win streak for colony (with decay)
     * @dev IDENTICAL function in both facets - extracted 1:1
     * @param colonyId Colony to check win streak for
     * @param cws Colony wars storage reference
     * @return validStreak Current valid win streak (0 if expired)
     */
    function getValidWinStreak(
        bytes32 colonyId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal view returns (uint8 validStreak) {
        uint8 streak = cws.colonyWinStreaks[colonyId];
        uint32 lastWin = cws.lastWinTime[colonyId];
        
        if (streak == 0 || lastWin == 0) {
            return 0;
        }
        
        // Check if streak has expired
        uint32 timeSinceWin = uint32(block.timestamp) - lastWin;
        if (timeSinceWin > cws.battleModifiers.winStreakDecayTime) {
            return 0; // Streak expired
        }
        
        // Cap streak at 5 for balance
        return streak > 5 ? 5 : streak;
    }

    /**
     * @notice Update win streaks after battle
     * @dev IDENTICAL function in both facets - extracted 1:1
     * @param winner Winning colony
     * @param loser Losing colony
     * @param cws Colony wars storage reference
     */
    function updateWinStreaks(bytes32 winner, bytes32 loser, LibColonyWarsStorage.ColonyWarsStorage storage cws) internal {
        // Increment winner's streak
        cws.colonyWinStreaks[winner] += 1;
        cws.lastWinTime[winner] = uint32(block.timestamp);
        
        // Reset loser's streak
        cws.colonyWinStreaks[loser] = 0;
        cws.lastWinTime[loser] = 0;
    }

    /**
     * @notice Calculate additional modifiers for battle power
     * @dev IDENTICAL function in both facets - extracted 1:1
     * @param colonyId Colony to calculate modifiers for
     * @param basePower Base power before modifiers
     * @param isAttacker Whether colony is attacking (affects win streak bonus)
     * @param cws Colony wars storage reference
     * @return additionalPower Additional power from modifiers (ADD to existing power)
     */
    function calculateAdditionalBattlePower(
        bytes32 colonyId,
        uint256 basePower,
        bool isAttacker,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal view returns (uint256 additionalPower) {
        additionalPower = 0;
        
        // Win streak bonus (attackers only)
        if (isAttacker && cws.battleModifiers.winStreakBonus > 0) {
            uint8 winStreak = getValidWinStreak(colonyId, cws);
            if (winStreak > 0) {
                additionalPower += (basePower * cws.battleModifiers.winStreakBonus * winStreak) / (100 * 5);
            }
        }
        
        // Territory bonus
        if (cws.battleModifiers.territoryBonus > 0) {
            uint256 territoryCount = cws.colonyTerritories[colonyId].length;
            if (territoryCount > 0) {
                additionalPower += (basePower * cws.battleModifiers.territoryBonus * territoryCount) / (100 * 10);
            }
        }
        
        return additionalPower;
    }

    /**
     * @notice Calculate debt penalty for battle power
     * @dev IDENTICAL function in both facets - extracted 1:1
     * @param colonyId Colony to check debt for
     * @param basePower Base power before penalty
     * @param cws Colony wars storage reference
     * @return penalty Power reduction due to debt (SUBTRACT from existing power)
     */
    function calculateDebtPenalty(
        bytes32 colonyId,
        uint256 basePower,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal view returns (uint256 penalty) {
        if (cws.battleModifiers.debtPenalty == 0) {
            return 0;
        }
        
        try IDebtWarsFacet(address(this)).getCurrentColonyDebt(colonyId) returns (uint256 debt) {
            if (debt > 0) {
                LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
                if (debt > profile.defensiveStake) {
                    penalty = (basePower * cws.battleModifiers.debtPenalty) / 100;
                }
            }
        } catch {
            // DebtWarsFacet not available, no penalty
            penalty = 0;
        }
        
        return penalty;
    }

    /**
     * @notice Apply alliance bonuses to defender power
     * @dev IDENTICAL function in both facets with differentiating parameter
     * @param basePower Base defensive power before alliance bonuses
     * @param defenderColony Defending colony
     * @param isTerritory Whether this is territory siege (affects bonus scaling)
     * @return enhancedPower Power after alliance bonuses
     */
    function applyAllianceBonuses(
        uint256 basePower,
        bytes32 defenderColony,
        bool isTerritory
    ) internal view returns (uint256 enhancedPower) {
        try IAllianceWarsFacet(address(this)).getAllianceDefensiveBonuses(defenderColony) 
            returns (bool hasAlliance, uint256 defensiveBonus, uint256 reinforcementTokens, uint256 sharedStakeBonus) 
        {
            if (hasAlliance) {
                enhancedPower = basePower;
                
                // REDUCED Percentage bonus
                enhancedPower += (basePower * defensiveBonus) / 150; // Divide by 150 instead of 100 (33% reduction)
                
                // REDUCED Reinforcement tokens (absolute power)
                if (isTerritory) {
                    enhancedPower += reinforcementTokens * 60; // Reduced from 100 to 60
                } else {
                    enhancedPower += reinforcementTokens * 100; // Reduced from 150 to 100
                }
                
                // REDUCED Shared stake bonus (absolute power)
                if (isTerritory) {
                    enhancedPower += (sharedStakeBonus * 10) / 100; // Reduced from 15% to 10%
                } else {
                    enhancedPower += (sharedStakeBonus * 15) / 100; // Reduced from 20% to 15%
                }
                
                return enhancedPower;
            }
        } catch {
            // Alliance system unavailable - apply fallback bonuses (already reduced above)
        }
        
        // Fallback bonuses already applied in main functions
        return basePower; // No additional fallback here
    }

    /**
     * @notice Calculate progressive stake bonus with diminishing returns
     * @dev Used for both colony wars and territory sieges with different scaling
     * @param stakeAmount Attacker's actual stake amount
     * @param defenderStake Defender's defensive stake
     * @param isRaid Whether this is a territory raid (more aggressive scaling)
     * @return bonusPercentage Percentage bonus to apply
     */
    function calculateStakeBonus(
        uint256 stakeAmount, 
        uint256 defenderStake,
        bool isRaid
    ) internal pure returns (uint256 bonusPercentage) {
        if (defenderStake == 0) return isRaid ? 25 : 15;
        
        uint256 stakeRatio = (stakeAmount * 100) / defenderStake;
        
        if (isRaid) {
            if (stakeRatio <= 50) {
                bonusPercentage = 25;
            } else if (stakeRatio <= 100) {
                bonusPercentage = 25 + ((stakeRatio - 50) * 25) / 50;
            } else {
                bonusPercentage = 50 + ((stakeRatio - 100) * 25) / 100;
                if (bonusPercentage > 100) bonusPercentage = 100; // Cap at 100%
            }
        } else {
            if (stakeRatio <= 50) {
                bonusPercentage = 15;
            } else if (stakeRatio <= 100) {
                bonusPercentage = 15 + ((stakeRatio - 50) * 15) / 50;
            } else {
                bonusPercentage = 30 + ((stakeRatio - 100) * 15) / 100;
                if (bonusPercentage > 75) bonusPercentage = 75; 
            }
        }
        
        return bonusPercentage;
    }

    /**
     * @notice Calculate active defense bonus against high stakes
     * @dev Encourages active defense when facing wealthy attackers
     * @param attackerStake Attacker's stake amount
     * @param defenderStake Defender's defensive stake  
     * @param hasActiveDefense Whether defender committed tokens
     * @return bonusPercentage Additional percentage bonus for active defense
     */
    function calculateActiveDefenseBonus(
        uint256 attackerStake, 
        uint256 defenderStake, 
        bool hasActiveDefense
    ) internal pure returns (uint256 bonusPercentage) {
        if (!hasActiveDefense) return 0;
        
        uint256 stakeRatio = (attackerStake * 100) / defenderStake;
        
        // Zmniejsz base active defense bonus
        bonusPercentage = 6; // Zmniejszone z 10 do 6
        
        // Zmniejsz dodatkowy bonus za high-stake attacks  
        if (stakeRatio > 150) {
            bonusPercentage += (stakeRatio - 150) / 20; // Zmniejszone z /10 do /20
            if (bonusPercentage > 18) bonusPercentage = 18; // Zmniejszone z 25 do 18
        }
        
        return bonusPercentage;
    }

    /**
     * @notice Get random tokens from user's primary registered colony for automatic defense
     * @dev Uses colonies mapping to get tokens belonging to specific colony
     * @param defenderColony The colony being defended (must be primary)
     * @param defenderOwner Address of the colony owner
     * @param maxTokens Maximum number of tokens to select
     * @param cws Colony wars storage reference
     * @param hs Henomorphs storage reference
     * @return selectedTokens Array of combined token IDs for auto-defense
     */
    function getRandomDefenseTokens(
        bytes32 defenderColony, 
        address defenderOwner,
        uint256 maxTokens,
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) internal view returns (uint256[] memory selectedTokens) {
        
        // 1. Verify this is user's primary colony
        bytes32 userPrimaryColony = LibColonyWarsStorage.getUserPrimaryColony(defenderOwner);
        if (userPrimaryColony != defenderColony) {
            return new uint256[](0); // Not primary colony, no auto-defense
        }
        
        // 2. Verify colony is registered for current season
        if (!cws.colonyWarProfiles[defenderColony].registered) {
            return new uint256[](0); // Not registered, no auto-defense
        }
        
        // 3. Verify colony owner matches
        if (hs.colonyCreators[defenderColony] != defenderOwner) {
            return new uint256[](0); // Ownership mismatch
        }
        
        // 4. Get all tokens from this colony using correct mapping
        uint256[] storage colonyTokens = hs.colonies[defenderColony];
        
        if (colonyTokens.length == 0) {
            return new uint256[](0); // No tokens in colony
        }
        
        return selectRandomAvailableTokens(colonyTokens, defenderColony, maxTokens, hs);
    }

    /**
     * @notice Select random available tokens from colony's token array
     * @dev Filters for tokens available for battle and randomly selects subset
     * @param colonyTokens Array of all tokens in colony
     * @param colonyId Colony ID for validation
     * @param maxTokens Maximum tokens to select
     * @param hs Henomorphs storage reference
     * @return selectedTokens Array of selected token combined IDs
     */
    function selectRandomAvailableTokens(
        uint256[] storage colonyTokens,
        bytes32 colonyId,
        uint256 maxTokens,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) internal view returns (uint256[] memory selectedTokens) {
        
        // Filter for tokens available for battle (not already committed)
        uint256[] memory availableTokens = new uint256[](colonyTokens.length);
        uint256 availableCount = 0;
        
        for (uint256 i = 0; i < colonyTokens.length; i++) {
            uint256 combinedId = colonyTokens[i];
            
            // Double-check token still belongs to colony and is available
            if (hs.specimenColonies[combinedId] == colonyId && 
                LibColonyWarsStorage.isTokenAvailableForBattle(combinedId)) {
                availableTokens[availableCount] = combinedId;
                availableCount++;
            }
        }
        
        if (availableCount == 0) {
            return new uint256[](0);
        }
        
        // Randomly select up to maxTokens
        uint256 selectCount = maxTokens < availableCount ? maxTokens : availableCount;
        selectedTokens = new uint256[](selectCount);
        
        // Create deterministic but unpredictable seed
        uint256 seed = uint256(keccak256(abi.encodePacked(
            block.prevrandao,
            block.timestamp,
            colonyId,
            availableCount
        )));
        
        // Fisher-Yates shuffle for first N elements to avoid bias
        uint256[] memory workingArray = new uint256[](availableCount);
        for (uint256 i = 0; i < availableCount; i++) {
            workingArray[i] = availableTokens[i];
        }
        
        for (uint256 i = 0; i < selectCount; i++) {
            if (availableCount > i) {
                uint256 randomIndex = (seed + i * 7919) % (availableCount - i);
                selectedTokens[i] = workingArray[randomIndex];
                workingArray[randomIndex] = workingArray[availableCount - 1 - i];
            } else {
                break; // Zabezpieczenie przed underflow
            }
        }
        
        return selectedTokens;
    }

    /**
     * @notice Calculate power for automatically selected defense tokens
     * @dev Uses existing token stats system with penalty for auto-defense
     * @param autoTokens Array of auto-selected token combined IDs
     * @param penaltyPercentage Penalty to apply (e.g., 30 for 30% penalty)
     * @return totalPower Total defense power with penalty applied
     */
    function calculateAutoDefensePower(
        uint256[] memory autoTokens, 
        uint8 penaltyPercentage
    ) internal view returns (uint256 totalPower) {
        
        if (autoTokens.length == 0) return 0;
        
        // Convert combined IDs back to collection/token IDs for stats lookup
        uint256[] memory collectionIds = new uint256[](autoTokens.length);
        uint256[] memory tokenIds = new uint256[](autoTokens.length);
        
        for (uint256 i = 0; i < autoTokens.length; i++) {
            (collectionIds[i], tokenIds[i]) = PodsUtils.extractIds(autoTokens[i]);
        }
        
        // Get token performance stats using existing interface
        TokenStats[] memory tokenStats = IAccessoryFacet(address(this))
            .getTokenPerformanceStats(collectionIds, tokenIds);
        
        // Calculate total power using existing calculateTokenPower function
        for (uint256 i = 0; i < tokenStats.length; i++) {
            uint256 tokenPower = calculateTokenPower(tokenStats[i]);
            totalPower += tokenPower;
        }
        
        // Apply penalty for automatic (non-active) defense
        totalPower = (totalPower * (100 - penaltyPercentage)) / 100;
        
        return totalPower;
    }

    /**
     * @notice Calculate maintenance cost with debt penalty
     * @dev Territory-specific function for maintenance cost adjustment
     * @param colonyId Colony to calculate cost for
     * @param baseCost Base maintenance cost from existing calculation
     * @return adjustedCost Final cost with debt penalty applied
     */
    function calculateMaintenanceWithDebt(
        bytes32 colonyId,
        uint256 baseCost
    ) internal view returns (uint256 adjustedCost) {
        adjustedCost = baseCost;

        try IDebtWarsFacet(address(this)).getCurrentColonyDebt(colonyId) returns (uint256 debt) {
            if (debt > 0) {
                LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
                LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
                if (debt > profile.defensiveStake) {
                    // 25% higher maintenance for over-leveraged colonies
                    adjustedCost = (adjustedCost * 125) / 100;
                }
            }
        } catch {
            // DebtWarsFacet not available, use base cost
        }
        
        return adjustedCost;
    }

    /**
     * @notice Calculate additional siege power from modifiers
     * @dev Territory-specific version with extra defender bonus
     * @param colonyId Colony to calculate for
     * @param basePower Base siege power
     * @param isAttacker Whether colony is attacking territory
     * @param cws Colony wars storage reference
     * @return additionalPower Power to ADD to existing calculations
     */
    function calculateAdditionalSiegePower(
        bytes32 colonyId,
        uint256 basePower,
        bool isAttacker,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal view returns (uint256 additionalPower) {
        additionalPower = 0;
        
        // Win streak bonus (attackers only)
        if (isAttacker && cws.battleModifiers.winStreakBonus > 0) {
            uint8 winStreak = getValidWinStreak(colonyId, cws);
            if (winStreak > 0) {
                additionalPower += (basePower * cws.battleModifiers.winStreakBonus * winStreak) / (100 * 5);
            }
        }
        
        // Territory bonus
        if (cws.battleModifiers.territoryBonus > 0) {
            uint256 territoryCount = cws.colonyTerritories[colonyId].length;
            if (territoryCount > 0) {
                additionalPower += (basePower * cws.battleModifiers.territoryBonus * territoryCount) / (100 * 10);
            }
        }
        
        // Extra defender bonus for territories (home field advantage)
        if (!isAttacker) {
            additionalPower += (basePower * 20) / 100; // 20% home territory bonus
        }
        
        return additionalPower;
    }

    /**
     * @dev Check authorization with conflict of interest prevention
     * @param colonyId Colony being used for warfare
     * @param opposingColonyId Colony being attacked/defended against  
     * @param stakingListener Staking system address
     * @return isAuthorized Whether caller can use this colony for warfare
     */
    function isAuthorizedForColony(
        bytes32 colonyId,
        bytes32 opposingColonyId, 
        address stakingListener
    ) internal view returns (bool isAuthorized) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        address sender = LibMeta.msgSender();
        
        // Super-user checks (always allowed)
        if (sender == LibDiamond.contractOwner() || hs.operators[sender]) {
            return true;
        }
        
        // External systems (always allowed)
        if (stakingListener != address(0) && sender == stakingListener) {
            return true;
        }
        
        // CONFLICT CHECK: Sender cannot control opposing colony
        if (hs.colonyCreators[opposingColonyId] == sender) {
            return false; // Cannot attack/defend if you own opposing colony
        }
        
        // Sender must be creator of the colony they want to use
        return hs.colonyCreators[colonyId] == sender;
    }

    /**
     * @dev Verify tokens don't create conflict of interest
     * @param tokenCollectionIds Collection IDs of tokens to verify
     * @param tokenTokenIds Token IDs to verify  
     * @param opposingColonyId Opposing colony in warfare
     * @return hasConflict Whether any token creates conflict
     */
    function checkTokensForWarfareConflict(
        uint256[] memory tokenCollectionIds,
        uint256[] memory tokenTokenIds,
        bytes32 opposingColonyId
    ) internal view returns (bool hasConflict) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        address opposingColonyOwner = hs.colonyCreators[opposingColonyId];
        
        if (opposingColonyOwner == address(0)) {
            return false; // No opposing colony owner
        }
        
        // Check each token for ownership conflict
        for (uint256 i = 0; i < tokenCollectionIds.length; i++) {
            address tokenOwner = getTokenOwner(tokenCollectionIds[i], tokenTokenIds[i]);
            
            // If any token belongs to opposing colony owner = conflict
            if (tokenOwner == opposingColonyOwner) {
                return true;
            }
        }
        
        return false;
    }

    /**
     * @dev Retrieves the owner of a token from the collection
     */
    function getTokenOwner(uint256 collectionId, uint256 tokenId) internal view returns (address) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        address stakingListener = hs.stakingSystemAddress;
        
        // Single try-catch for staking check - if token is staked, get staker directly
        if (stakingListener != address(0)) {
            try IStakingCoreFacet(stakingListener).getStakedTokenData(collectionId, tokenId) returns (StakedSpecimen memory stakedData) {
                if (stakedData.staked && stakedData.owner != address(0)) {
                    return stakedData.owner;
                }
            } catch {
                // Fall through to NFT owner
            }
        }
        
        // Get NFT owner
        try IERC721(hs.specimenCollections[collectionId].collectionAddress).ownerOf(tokenId) returns (address nftOwner) {
            return nftOwner;
        } catch {
            return address(0);
        }
    }

    /**
     * @notice Check if user was recently active (for auto-defense eligibility)
     */
    function isUserRecentlyActive(
        address user,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal view returns (bool isActive) {
        uint256 activityWindow = 48 * 3600; // 48 hours
        
        bytes4[7] memory selectors = [
            bytes4(keccak256("raidTerritory(uint256,uint256)")),
            bytes4(keccak256("siegeTerritory(uint256,bytes32,uint256[],uint256[],uint256)")),
            bytes4(keccak256("defendSiege(bytes32,uint256[],uint256[])")),
            bytes4(keccak256("registerForSeason(bytes32,uint256)")),
            bytes4(keccak256("initiateAttack(bytes32,bytes32,uint256[],uint256[],uint256)")),
            bytes4(keccak256("defendBattle(bytes32,uint256[],uint256[])")),
            bytes4(keccak256("increaseDefensiveStake(bytes32,uint256)"))
        ];
        
        for (uint256 i = 0; i < selectors.length; i++) {
            if (block.timestamp < cws.lastActionTime[user][selectors[i]] + activityWindow) {
                return true;
            }
        }
        
        return false;
    }

    /**
     * @notice Get valid consecutive losses for colony in current season
     */
    function getValidConsecutiveLosses(
        bytes32 colonyId, 
        uint32 seasonId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal view returns (uint8) {
        uint8 losses = cws.seasonColonyLosses[seasonId][colonyId];
        uint32 lastLoss = cws.seasonLastLossTime[seasonId][colonyId];
        
        // Reset after 48h without battles in this season
        if (block.timestamp > lastLoss + 48 hours) {
            return 0;
        }
        
        return losses > 5 ? 5 : losses; // Cap at 5 consecutive losses
    }

    /**
     * @notice Update consecutive losses tracking for season
     */
    function updateSeasonConsecutiveLosses(
        bytes32 winner, 
        bytes32 loser, 
        uint32 seasonId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        // Winner - reset losses in this season
        cws.seasonColonyLosses[seasonId][winner] = 0;
        
        // Loser - increment losses in this season
        cws.seasonColonyLosses[seasonId][loser] += 1;
        cws.seasonLastLossTime[seasonId][loser] = uint32(block.timestamp);
    }

    /**
     * @notice Get scouting bonus for attacks
     */
    function getScoutingBonus(
        bytes32 attackerColony, 
        bytes32 targetColony, 
        uint256 territoryId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal view returns (uint8 bonus) {
        // Territory-specific scouting (preferred)
        if (territoryId > 0 && block.timestamp <= cws.scoutedTerritories[attackerColony][territoryId]) {
            return 8; // 8% bonus for territory raids/sieges
        }
        
        // Colony-wide scouting (fallback)  
        if (block.timestamp <= cws.scoutedTargets[attackerColony][targetColony]) {
            return territoryId > 0 ? 5 : 5; // 5% bonus for any attack on scouted colony
        }
        
        return 0;
    }

    /**
     * @notice Apply forfeit penalty (unified for both facets)
     */
    function applyForfeitPenalty(
        ForfeitParams memory params,
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) internal {
        LibColonyWarsStorage.Season storage season = cws.seasons[params.seasonId];

        if (params.forfeitType == 1) {
            _applyAttackerForfeit(params, cws, hs, season);
        } else if (params.forfeitType == 2) {
            _applyDefenderForfeit(params, cws, hs);
        } else if (params.forfeitType == 3) {
            _applyMutualForfeit(params, cws, hs, season);
        }
    }

    function _applyAttackerForfeit(
        ForfeitParams memory params,
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        LibHenomorphsStorage.HenomorphsStorage storage hs,
        LibColonyWarsStorage.Season storage season
    ) private {
        uint256 forfeitPenalty = params.isTerritory ? params.stakeAmount : params.stakeAmount / 2;
        cws.colonyLosses[params.attackerColony] += params.stakeAmount + forfeitPenalty;

        // Defender compensation
        address defenderCreator = hs.colonyCreators[params.defenderColony];
        if (defenderCreator != address(0)) {
            uint256 compensation = params.isTerritory ? params.stakeAmount : params.stakeAmount / 2;
            LibFeeCollection.transferFromTreasury(defenderCreator, compensation, "forfeit_compensation");
        }
        season.prizePool += forfeitPenalty;

        // Reputation & points
        LibColonyWarsStorage.ColonyWarProfile storage attackerProfile = cws.colonyWarProfiles[params.attackerColony];
        if (attackerProfile.reputation < 5) attackerProfile.reputation = 5;
        LibColonyWarsStorage.addColonyScore(params.seasonId, params.defenderColony, params.isTerritory ? 40 : 75);
        LibColonyWarsStorage.addColonyScore(params.seasonId, params.attackerColony, 0);
    }

    function _applyDefenderForfeit(
        ForfeitParams memory params,
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) private {
        LibColonyWarsStorage.ColonyWarProfile storage defenderProfile = cws.colonyWarProfiles[params.defenderColony];
        uint256 stakePenalty = params.isTerritory ? defenderProfile.defensiveStake / 3 : defenderProfile.defensiveStake / 4;

        if (defenderProfile.defensiveStake >= stakePenalty) {
            defenderProfile.defensiveStake -= stakePenalty;
            cws.colonyLosses[params.defenderColony] += stakePenalty;
        }

        // Attacker reward
        address attackerCreator = hs.colonyCreators[params.attackerColony];
        if (attackerCreator != address(0)) {
            LibFeeCollection.transferFromTreasury(attackerCreator, params.stakeAmount + stakePenalty, "forfeit_victory");
        }

        // Reputation & points
        if (defenderProfile.reputation < 4) defenderProfile.reputation = 4;
        LibColonyWarsStorage.addColonyScore(params.seasonId, params.attackerColony, params.isTerritory ? 50 : 100);
        LibColonyWarsStorage.addColonyScore(params.seasonId, params.defenderColony, 0);
    }

    function _applyMutualForfeit(
        ForfeitParams memory params,
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        LibHenomorphsStorage.HenomorphsStorage storage hs,
        LibColonyWarsStorage.Season storage season
    ) private {
        hs; // silence unused warning
        season.prizePool += params.stakeAmount + params.defenderStake;
        cws.colonyLosses[params.attackerColony] += params.stakeAmount;

        LibColonyWarsStorage.ColonyWarProfile storage defenderProfile = cws.colonyWarProfiles[params.defenderColony];
        uint256 defenderPenalty = params.isTerritory ? defenderProfile.defensiveStake / 3 : defenderProfile.defensiveStake / 4;
        if (defenderProfile.defensiveStake >= defenderPenalty) {
            defenderProfile.defensiveStake -= defenderPenalty;
            cws.colonyLosses[params.defenderColony] += defenderPenalty;
        }

        // Reputation penalties for both
        LibColonyWarsStorage.ColonyWarProfile storage attackerProfile = cws.colonyWarProfiles[params.attackerColony];
        if (attackerProfile.reputation < 5) attackerProfile.reputation = 5;
        if (defenderProfile.reputation < 4) defenderProfile.reputation = 4;

        // Points
        LibColonyWarsStorage.addColonyScore(params.seasonId, params.defenderColony, params.isTerritory ? 15 : 25);
        LibColonyWarsStorage.addColonyScore(params.seasonId, params.attackerColony, params.isTerritory ? 5 : 10);
    }

    /**
     * @notice Apply team synergy bonus to total power
     * @dev Integrates Multi-Collection Staking bonuses into battle calculations
     * @param colonyId Colony to check for team staking
     * @param basePower Base power before synergy bonus
     * @param cws Colony Wars storage reference
     * @return Enhanced power with synergy bonus applied
     */
    function applyTeamSynergyBonus(
        bytes32 colonyId,
        uint256 basePower,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal view returns (uint256) {
        LibColonyWarsStorage.SquadStakePosition storage squad = cws.colonySquadStakes[colonyId];
        
        // No bonus if squad not active or no synergy
        if (!squad.active || squad.totalSynergyBonus == 0) {
            return basePower;
        }
        
        // Apply synergy bonus (synergy is 0-500 = 0-50%)
        // Dividing by 1000 because 500 = 50% = 0.5x bonus
        uint256 bonusPower = (basePower * squad.totalSynergyBonus) / 1000;
        return basePower + bonusPower;
    }

    // ============ TERRITORY SIEGE FUNCTIONS ============

    /**
     * @notice Validate and adjust territory stake amount
     * @param stakeAmount Proposed stake amount
     * @param defenderStake Defender's defensive stake
     * @param isRaid Whether this is a raid (vs siege)
     * @return validatedStake Validated stake amount
     */
    function validateTerritoryStake(
        uint256 stakeAmount,
        uint256 defenderStake,
        bool isRaid
    ) internal pure returns (uint256 validatedStake) {
        uint256 minStake = isRaid ? defenderStake / 4 : defenderStake / 2;
        uint256 maxStake = defenderStake * 3;

        if (stakeAmount < minStake) {
            return minStake;
        }
        if (stakeAmount > maxStake) {
            return maxStake;
        }
        return stakeAmount;
    }

    /**
     * @notice Award defensive bonus points for territory defense
     * @param defenderColony Defending colony
     * @param defenseTokenCount Number of defense tokens committed
     * @param attackTokenCount Number of attacker tokens
     * @param seasonId Current season ID
     */
    function awardTerritoryDefensiveBonus(
        bytes32 defenderColony,
        uint256 defenseTokenCount,
        uint256 attackTokenCount,
        uint32 seasonId
    ) internal {
        uint256 basePoints = 10;
        if (defenseTokenCount >= attackTokenCount) {
            basePoints += 5;
        }
        LibColonyWarsStorage.addColonyScore(seasonId, defenderColony, basePoints);
    }

    /**
     * @notice Calculate territory damage from siege
     * @param attackerPowers Array of attacker token powers
     * @param defenderPowers Array of defender token powers
     * @param stakeAmount Stake amount in the siege
     * @return damage Damage dealt to territory (0-100 scale)
     */
    function calculateTerritoryDamage(
        uint256[] memory attackerPowers,
        uint256[] memory defenderPowers,
        uint256 stakeAmount
    ) internal pure returns (uint16 damage) {
        uint256 totalAttack = sumArray(attackerPowers);
        uint256 totalDefense = sumArray(defenderPowers);

        uint256 baseDamage;
        if (totalAttack > totalDefense) {
            baseDamage = ((totalAttack - totalDefense) * 100) / (totalAttack + 1);
        } else {
            baseDamage = 5;
        }

        uint256 stakeBonus = stakeAmount / 1e18;
        if (stakeBonus > 20) stakeBonus = 20;

        damage = uint16(baseDamage + stakeBonus);
        if (damage > 50) damage = 50;

        return damage;
    }

    /**
     * @notice Calculate defensive stake loss after siege defeat
     * @param hasDefended Whether defender committed tokens
     * @param attackerPower Total attacker power (unused)
     * @param defenderPower Total defender power (unused)
     * @param defenderStake Current defensive stake
     * @return stakeLoss Amount of stake lost
     */
    function calculateSiegeStakeLoss(
        bool hasDefended,
        uint256 attackerPower,
        uint256 defenderPower,
        uint256 defenderStake
    ) internal pure returns (uint256 stakeLoss) {
        attackerPower;
        defenderPower;

        if (hasDefended) {
            stakeLoss = (defenderStake * 15) / 100;
        } else {
            stakeLoss = (defenderStake * 25) / 100;
        }
        return stakeLoss;
    }

    /**
     * @notice Calculate base powers for siege with weather effects
     */
    function calculateSiegeBasePowers(
        SiegeBaseParams memory params,
        uint256[] memory attackerPowers,
        uint256[] memory defenderPowers,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal view returns (SiegeBaseResult memory result) {
        result.attackerPower = sumArray(attackerPowers);
        result.defenderPower = sumArray(defenderPowers);

        result.attackerPower = applyTeamSynergyBonus(params.attackerColony, result.attackerPower, cws);
        result.defenderPower = applyTeamSynergyBonus(params.defenderColony, result.defenderPower, cws);

        result.randomness = uint256(keccak256(abi.encodePacked(
            block.prevrandao,
            block.timestamp,
            params.attackerColony,
            params.defenderColony,
            params.territoryId
        )));

        result.weatherDesc = _getWeatherDescription(uint8(result.randomness % 10));
    }

    function _getWeatherDescription(uint8 weatherType) private pure returns (string memory) {
        if (weatherType < 2) return "Stormy conditions";
        if (weatherType < 4) return "Foggy battlefield";
        if (weatherType < 6) return "Harsh winds";
        return "Clear skies";
    }

    /**
     * @notice Calculate attacker power with all bonuses
     */
    function calculateSiegeAttackerPower(
        SiegeAttackerParams memory params,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal view returns (uint256 attackerPower) {
        attackerPower = params.basePower;

        {
            uint256 stakeBonus = calculateStakeBonus(params.stakeAmount, params.defenderStake, true);
            attackerPower += (params.basePower * stakeBonus) / 100;
        }

        attackerPower += calculateAdditionalSiegePower(params.attackerColony, params.basePower, true, cws);

        {
            uint8 scoutBonus = getScoutingBonus(params.attackerColony, params.defenderColony, params.territoryId, cws);
            if (scoutBonus > 0) {
                attackerPower += (params.basePower * scoutBonus) / 100;
            }
        }

        {
            uint256 debtPenalty = calculateDebtPenalty(params.attackerColony, params.basePower, cws);
            if (debtPenalty > 0 && attackerPower > debtPenalty) {
                attackerPower -= debtPenalty;
            }
        }

        return attackerPower;
    }

    /**
     * @notice Calculate defender power with all bonuses
     */
    function calculateSiegeDefenderPower(
        SiegeDefenderParams memory params,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal view returns (uint256 defenderPower) {
        defenderPower = params.basePower;

        {
            LibColonyWarsStorage.Territory storage territory = cws.territories[params.territoryId];
            if (territory.fortificationLevel > 0) {
                defenderPower += (params.basePower * territory.fortificationLevel * 5) / 100;
            }
        }

        defenderPower += calculateAdditionalSiegePower(params.defenderColony, params.basePower, false, cws);
        defenderPower = applyAllianceBonuses(defenderPower, params.defenderColony, true);

        if (params.defenderPowers.length > 0) {
            defenderPower += (params.basePower * 10) / 100;
        }

        return defenderPower;
    }

    /**
     * @notice Apply randomness effects to siege powers
     */
    function applySiegeRandomnessEffects(
        uint256 attackerPower,
        uint256 defenderPower,
        uint256 randomness
    ) internal pure returns (uint256 finalAttacker, uint256 finalDefender) {
        uint256 attackerVariance = (randomness % 21);
        uint256 defenderVariance = ((randomness >> 8) % 21);

        if (attackerVariance >= 10) {
            finalAttacker = attackerPower + (attackerPower * (attackerVariance - 10)) / 100;
        } else {
            finalAttacker = attackerPower - (attackerPower * (10 - attackerVariance)) / 100;
        }

        if (defenderVariance >= 10) {
            finalDefender = defenderPower + (defenderPower * (defenderVariance - 10)) / 100;
        } else {
            finalDefender = defenderPower - (defenderPower * (10 - defenderVariance)) / 100;
        }

        return (finalAttacker, finalDefender);
    }

    /**
     * @notice Update season points after siege resolution
     */
    function updateSiegeSeasonPoints(
        bytes32 attackerColony,
        bytes32 defenderColony,
        bytes32 winner,
        uint256 stakeAmount,
        uint256 defenderStake,
        bool hasActiveDefense,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        uint32 seasonId = cws.currentSeason;

        uint256 winnerPoints = 50;
        uint256 loserPoints = 10;

        if (defenderStake > 0) {
            uint256 stakeRatio = (stakeAmount * 100) / defenderStake;
            if (stakeRatio > 150) {
                winnerPoints += 20;
            } else if (stakeRatio > 100) {
                winnerPoints += 10;
            }
        }

        if (hasActiveDefense) {
            if (winner == defenderColony) {
                winnerPoints += 15;
            } else {
                loserPoints += 5;
            }
        }

        if (winner == attackerColony) {
            LibColonyWarsStorage.addColonyScore(seasonId, attackerColony, winnerPoints);
            LibColonyWarsStorage.addColonyScore(seasonId, defenderColony, loserPoints);
        } else {
            LibColonyWarsStorage.addColonyScore(seasonId, defenderColony, winnerPoints);
            LibColonyWarsStorage.addColonyScore(seasonId, attackerColony, loserPoints);
        }
    }

    /**
     * @notice Remove siege from active sieges arrays
     */
    function removeFromActiveSieges(
        bytes32 siegeId,
        uint256 territoryId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        bytes32[] storage activeSieges = cws.activeSieges;
        for (uint256 i = 0; i < activeSieges.length; i++) {
            if (activeSieges[i] == siegeId) {
                activeSieges[i] = activeSieges[activeSieges.length - 1];
                activeSieges.pop();
                break;
            }
        }

        bytes32[] storage territoryActiveSieges = cws.territoryActiveSieges[territoryId];
        for (uint256 i = 0; i < territoryActiveSieges.length; i++) {
            if (territoryActiveSieges[i] == siegeId) {
                territoryActiveSieges[i] = territoryActiveSieges[territoryActiveSieges.length - 1];
                territoryActiveSieges.pop();
                break;
            }
        }
    }
}
