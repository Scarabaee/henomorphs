// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {StakedSpecimen} from "../../libraries/StakingModel.sol";
import {Calibration, ChargeAccessory, PowerMatrix, ColonyCriteria, TraitPackEquipment, ChargeSeason} from "../../libraries/HenomorphsModel.sol";
import {RankingConfig, RankingEntry} from "../../libraries/GamingModel.sol";

/**
 * @title IStakingWearFacet
 * @notice Interface for wear management in the staking system
 */
interface IStakingWearFacet {
    /**
     * @notice Update wear data from Biopod
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return success Whether update was successful
     */
    function updateWearFromBiopod(uint256 collectionId, uint256 tokenId) external returns (bool success);
    
    /**
     * @notice Manually repair wear on a staked token
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param repairAmount Amount of wear to repair
     */
    function repairTokenWear(uint256 collectionId, uint256 tokenId, uint256 repairAmount) external;

    function getTokenWearData(uint256 collectionId, uint256 tokenId) external view returns (uint256 wearLevel, uint256 wearPenalty);
    function getWearRepairCost(uint256 wearAmount) external view returns (uint256 cost, address beneficiary);
    function checkAndPerformAutoRepair(uint256 collectionId, uint256 tokenId) external returns (bool repaired);
}

/**
 * @title IExternalBiopod
 * @notice Interface for external Biopod system
 */
interface IExternalBiopod {
    /**
     * @notice Get calibration data for a token
     * @param tokenId Token ID
     * @return calibration Calibration data
     */
    function probeCalibration(uint256 collectionId, uint256 tokenId) external view returns (Calibration memory);
    
    /**
     * @notice Apply experience gain to a token
     * @param tokenId Token ID
     * @param amount Amount of experience to add
     * @return success Whether update was successful
     */
    function applyExperienceGain(uint256 collectionId, uint256 tokenId, uint256 amount) external returns (bool);
    
    /**
     * @notice Apply fatigue to a token
     * @param tokenId Token ID
     * @param amount Amount of fatigue to add
     * @return success Whether update was successful
     */
    function applyFatigue(uint256 collectionId, uint256 tokenId, uint256 amount) external returns (bool);
    
    /**
     * @notice Update charge data for a token
     * @param tokenId Token ID
     * @param charge New charge value
     * @param timestamp Timestamp of update
     * @return success Whether update was successful
     */
    function updateChargeData(uint256 collectionId, uint256 tokenId, uint256 charge, uint256 timestamp) external returns (bool);

    /**
     * @dev Updates wear data for a token
     * @param collectionId Token collection ID
     * @param tokenId Token ID
     * @param wear New wear value
     * @return Success of operation
     */
    function updateWearData(uint256 collectionId, uint256 tokenId, uint256 wear) external returns (bool);
    
    /**
     * @dev Updates calibration status for a token
     * @param collectionId Token collection ID
     * @param tokenId Token ID
     * @param level New calibration level
     * @param wear New wear level
     * @return Success of operation
     */
    function updateCalibrationStatus(uint256 collectionId, uint256 tokenId, uint256 level, uint256 wear) external returns (bool);
    
    /**
    
    /**
     * @notice Get wear level for a token
     * @param tokenId Token ID
     * @return wearLevel Current wear level
     */
    function getWearLevel(uint256 collectionId, uint256 tokenId) external view returns (uint256);

    function applyWearRepair(uint256 collectionId, uint256 tokenId, uint256 repairAmount) external returns (bool);
}

/**
 * @title IExternalChargepod
 * @notice Interface for external Chargepod system
 */
interface IExternalChargepod {
    /**
     * @notice Get power matrix data for a token
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return matrix Power matrix data
     */
    function queryPowerMatrix(uint256 collectionId, uint256 tokenId) external view returns (PowerMatrix memory);
    
    /**
     * @notice Get collection ID from address
     * @param collectionAddress Collection contract address
     * @return collectionId Collection ID
     */
    function querySpecimenCollectionId(address collectionAddress) external view returns (uint256);
}

/**
 * @title IExternalAccessory
 * @notice Interface for accessory operations
 */
interface IExternalAccessory {
    /**
     * @notice Get equipped accessories for a token
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return accessories Array of equipped accessories
     */
    function equippedAccessories(uint256 collectionId, uint256 tokenId) external view returns (ChargeAccessory[] memory);

    function getTokenAccessories(uint256 collectionId, uint256 tokenId) 
        external 
        view 
        returns (ChargeAccessory[] memory accessories);

    function getTokenAllAccessories(
        uint256 collectionId,
        uint256 tokenId
    ) external view returns (
        ChargeAccessory[] memory localAccessories,
        uint64[] memory crossCollectionAccessories,
        uint64[] memory totalAccessoryIds
    );

    function synchronizeWithModularAsset(uint256 collectionId, uint256 tokenId) external returns (bool success);
}

/**
 * @title IExternalCollection
 * @notice Interface for collection operations
 */
interface IExternalCollection {
    /**
     * @dev Returns the variant of a Henomorph token
     * @param tokenId Token ID
     * @return Variant number (0-4)
     */
    function itemVariant(uint256 tokenId) external view returns (uint8);

    /**
     * @notice Get equipment trait packs for a token
     * @param tokenId Token ID
     * @return traitPacks Array of trait pack IDs
     */
    function itemEquipments(uint256 tokenId) external view returns (uint8[] memory);

        /**
     * @notice Zwraca rozszerzone informacje o trait-packach przypisanych do tokenu
     * @param tokenId ID tokenu
     * @return Struktura TraitPackEquipment z danymi o trait-packach i akcesoriach
     */
    function getTokenEquipment(uint256 tokenId) external view returns (TraitPackEquipment memory);
    
    /**
     * @notice Sprawdza czy token ma przypisany trait-pack
     * @param tokenId ID tokenu
     * @return Czy token ma trait-pack
     */
    function hasTraitPack(uint256 tokenId) external view returns (bool);

    function forceUnstakeTransfer(address from, address to, uint256 tokenId) external;
}

/**
 * @title IExternalColonial
 * @notice Interface for colony operations
 */
interface IExternalColonial {
    /**
     * @notice Get colony for a token
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return colonyId Colony ID
     */
    function getTokenColony(uint256 collectionId, uint256 tokenId) external view returns (bytes32);
    
    /**
     * @notice Get staking bonus for a colony
     * @param colonyId Colony ID
     * @return bonus Staking bonus percentage
     */
    function getStakingBonus(bytes32 colonyId) external view returns (uint256);
}

/**
 * @title ISpecializationFacet
 * @notice Interface for specialization operations
 */
interface ISpecializationFacet {
    /**
     * @notice Get specialization for a token
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return specialization Specialization value
     */
    function getSpecialization(uint256 collectionId, uint256 tokenId) external view returns (uint8);
}

/**
 * @title IStakingSystem
 * @notice Unified interface for staking system integration
 */
interface IStakingSystem {
    // Authentication
    function isSpecimenStaked(uint256 collectionId, uint256 tokenId) external view returns (bool);
    function isTokenStaker(uint256 collectionId, uint256 tokenId, address staker) external view returns (bool);
    /**
     * @notice Get the address currently staking a specific token
     * @param collectionAddress The NFT collection contract address  
     * @param tokenId The token ID to query
     * @return staker The address of the account that staked this token (address(0) if not staked)
     */
    function getTokenStaker(address collectionAddress, uint256 tokenId) external view returns (address staker);
    
    // Colony integration
    function notifyColonyCreated(bytes32 colonyId, string calldata name, address creator) external;
    function notifyColonyDissolved(bytes32 colonyId) external;
    function notifySpecimenJoinedColony(uint256 collectionId, uint256 tokenId, bytes32 colonyId) external;
    function notifySpecimenLeftColony(uint256 collectionId, uint256 tokenId, bytes32 colonyId) external;
    function getStakingColonyBonus(bytes32 colonyId) external view returns (uint256);
    function setStakingBonus(bytes32 colonyId, uint256 bonusPercentage) external;
    function getSpecimenLevel(uint256 collectionId, uint256 tokenId) external view returns (uint8);
    function getSpecimenVariant(uint256 collectionId, uint256 tokenId) external view returns (uint8);
    function setColonyJoinCriteria(bytes32 colonyId, ColonyCriteria calldata joinCriteria) external;
    function syncColonyData(bytes32 colonyId) external returns (bool);
    function setChargeSystemAddress(address chargepodAddress) external;
    /**
     * @notice Unified notification for colony membership changes
     * @param colonyId Colony ID
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param isJoining Whether token is joining or leaving colony
     * @return Whether operation was successful
     */
    function notifyColonyChange(bytes32 colonyId, uint256 collectionId, uint256 tokenId, bool isJoining) external returns (bool);

    function batchNotifyColonyChanges(
        bytes32 colonyId, 
        uint256[] calldata collectionIds, 
        uint256[] calldata tokenIds,
        bool isJoining
    ) external returns (uint256 successCount);

    /**
     * @notice Get staking bonus for a collection
     * @param collectionId Collection ID
     * @return bonus Staking bonus percentage
     */
    function getCollectionStakingBonus(uint256 collectionId) external view returns (uint256 bonus);

    /**
     * @notice Notification from Chargepod when wear level changes
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @param newWear New wear level (0-100)
     */
    function notifyWearChange(uint256 collectionId, uint256 tokenId, uint256 newWear) external;
}

/**
 * @title IStakingCoreFacet
 * @notice Standard interface for core staking functions
 * @dev Use for inter-facet calls to ensure type safety
 */
interface IStakingCoreFacet {
    function getStakedTokenData(uint256 collectionId, uint256 tokenId) external view returns (StakedSpecimen memory);
    function isTokenStaker(uint256 collectionId, uint256 tokenId, address staker) external view returns (bool);
}

/**
 * @title IStakingEarningsFacet
 * @notice Interface for reward token earnings system
 * @dev Replaces old StakingClaimFacet with new reward token system
 */
interface IStakingEarningsFacet {
    function claimStakingRewards(uint256 collectionId, uint256 tokenId) external returns (uint256 amount, bool fromTreasury);
    function processUnstakeRewards(uint256 collectionId, uint256 tokenId) external returns (uint256 amount);
    function getPendingReward(uint256 collectionId, uint256 tokenId) external view returns (uint256 amount);
    function getPendingEarnings(address staker, uint256 maxCheck) external view returns (uint256 rewardTotal, uint256 count);
}

/**
 * @title IColonyReader
 * @notice Interface for reading colony data from Chargepod
 * @dev Used by Staking system to access colony data
 */
interface IColonyFacet {
    /**
     * @notice Get colony information
     * @param colonyId Colony ID to query
     * @return name Colony name
     * @return creator Colony creator address
     * @return active Whether colony is active
     * @return stakingBonus Staking bonus percentage
     * @return memberCount Number of members
     */
    function getColonyInfo(bytes32 colonyId) external view returns (
        string memory name,
        address creator,
        bool active,
        uint256 stakingBonus,
        uint32 memberCount
    );
    
    /**
     * @notice Get colony members
     * @param colonyId Colony ID to query
     * @return collectionIds Array of collection IDs
     * @return tokenIds Array of token IDs
     */
    function getColonyMembers(bytes32 colonyId) external view returns (
        uint256[] memory collectionIds,
        uint256[] memory tokenIds
    );
    
    /**
     * @notice Get token's colony
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return Colony ID the token belongs to
     */
    function getTokenColony(uint256 collectionId, uint256 tokenId) external view returns (bytes32);
    
    /**
     * @notice Get staking bonus for a colony
     * @param colonyId Colony ID
     * @return Staking bonus percentage
     */
    function getStakingBonus(bytes32 colonyId) external view returns (uint256);

    function setStakingListener(address listener) external;

    function updateColonyBonusStorage(bytes32 colonyId, uint256 bonusPercentage) external;
    function getMaxCreatorBonusPercentage() external view returns (uint256);
}

/**
 * @title IChargeFacet
 * @notice Interface for accessing charge data in Chargepod
 * @dev Used for power core verification
 */
interface IChargeFacet {
    function getSpecimenData(uint256 collectionId, uint256 tokenId) external view returns (
        uint256 currentCharge, 
        uint256 maxCharge, 
        uint256 regenRate, 
        uint8 specialization, 
        uint256 level
    );

    function recalibrateCore(uint256 collectionId, uint256 tokenId) external returns (uint256);
}

interface IStakingBiopodFacet {
    function syncBiopodData(uint256 collectionId, uint256 tokenId) external returns (bool success);
    function getBiopodCalibrationData(uint256 collectionId, uint256 tokenId) external view returns (bool exists, Calibration memory calibration);
    function addExperienceToBiopod(uint256 collectionId, uint256 tokenId, uint256 amount) external returns (bool success);
    function applyFatigueToBiopod(uint256 collectionId, uint256 tokenId, uint256 amount) external returns (bool success);
    function updateBiopodChargeLevel(uint256 collectionId, uint256 tokenId, uint256 charge) external returns (bool success);
}

interface IStakingIntegrationFacet {
    function isPowerCoreActive(uint256 collectionId, uint256 tokenId) external view returns (bool);
    function syncTokenWithChargepod(uint256 collectionId, uint256 tokenId) external returns (bool);
    function calculateRewardMultiplier(uint256 collectionId, uint256 tokenId) external returns (uint256 calcBaseMultiplier, uint256 calcTotalMultiplier);
    function applyExperienceFromRewards(uint256 collectionId, uint256 tokenId, uint256 amount) external returns (bool);
    function calculateExperienceBonus(uint256 collectionId, uint256 tokenId, uint256 baseAmount) external view returns (uint256 bonusAmount);
    function getChargepodSystemAddress() external view returns (address);
    function setChargepodSystemAddress(address chargepodAddress) external;
}

interface ISeasonFacet {
    function startNewSeason(ChargeSeason memory seasonConfig) external;
    function startGlobalChargeEvent(uint256 duration, uint256 bonusPercentage) external;
    function endCurrentSeason() external;
    function startColonyEvent(
        string calldata theme,
        uint256 durationDays,
        LibHenomorphsStorage.ColonyEventConfig calldata eventConfig,
        bool createSeason,
        bool createGlobalEvent,
        uint8 globalEventBonus
    ) external;
}

interface IRankingFacet {
    // Fixed signature to match ActionRankingFacet implementation
    function createSeasonRanking(
        uint32 seasonId,
        uint256 seasonStartTime,
        uint256 seasonEndTime
    ) external returns (uint256 rankingId); // Added missing return value

    function calculateUserRank(uint256 rankingId, address user) external view returns (uint256 rank);
    function getRankingParticipantCount(uint256 rankingId) external view returns (uint256 count);
    function endSeasonRanking() external; // Signature matches implementation
    function getActiveRankingIds() external view returns (
        uint256 globalRankingId,
        uint256 seasonRankingId
    );
    
    function updateUserScore(
        uint256 rankingId,
        address user,
        uint256 scoreIncrease
    ) external;

    function trackAchievementEarned(address user, uint256 achievementId) external;
    function updateUserAchievementCache(address user) external;
    function getUserReadyAchievementCount(address user) external view returns (uint8);
    function getUserRecentAchievements(address user, uint256 limit) external view returns (uint256[] memory, uint8);
    function getRankingConfig(uint256 rankingId) external view returns (RankingConfig memory config);
    function getUserRankingEntry(
        uint256 rankingId,
        address user
    ) external view returns (RankingEntry memory entry);
}

/**
* @title ISpecializationEvolution
* @notice Interface for inter-facet communication with specialization system
* @dev Minimal interface containing only methods needed for facet integration
*/
interface ISpecializationEvolution {
   
   /**
    * @notice Award specialization XP for performing actions
    * @dev Called by ChargeFacet after successful action execution
    * @param collectionId Collection ID
    * @param tokenId Token ID
    * @param actionId Action performed (1-8)
    * @param reward Reward earned from action
    */
   function awardSpecializationXP(
       uint256 collectionId,
       uint256 tokenId,
       uint8 actionId,
       uint256 reward
   ) external;

}