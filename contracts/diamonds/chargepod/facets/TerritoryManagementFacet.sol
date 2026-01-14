// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {ResourceHelper} from "../libraries/ResourceHelper.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {ColonyHelper} from "../libraries/ColonyHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {WarfareHelper} from "../libraries/WarfareHelper.sol";

/**
 * @title ITerritoryCards
 * @notice Interface for Territory Cards collection
 */
interface ITerritoryCards {
    // Struct matching ColonyTerritoryCards.TerritoryTraits
    struct TerritoryTraits {
        uint8 territoryType;    // 0-4 enum: ZicoMine, TradeHub, Fortress, Observatory, Sanctuary
        uint8 rarity;           // 0-4 enum: COMMON, UNCOMMON, RARE, EPIC, LEGENDARY
        uint8 productionBonus;
        uint8 defenseBonus;
        uint8 techLevel;
        uint16 specimenPopulation;
        uint8 colonyWarsType;   // 1-5 for Colony Wars compatibility
    }

    function mintTerritory(
        address recipient,
        uint8 territoryType,
        uint8 rarity,
        uint16 productionBonus,
        uint16 defenseBonus,
        uint8 techLevel,
        uint16 chickenPopulation
    ) external returns (uint256 tokenId);

    function assignToColony(uint256 tokenId, uint256 colonyId) external;
    function deactivateTerritory(uint256 tokenId) external;
    function reactivateTerritory(uint256 tokenId) external;
    function approveTransfer(uint256 tokenId, address to) external;
    function rejectTransfer(uint256 tokenId, address to, string calldata reason) external;
    function transferFromTreasury(uint256 tokenId, address to) external;
    function isTerritoryActive(uint256 tokenId) external view returns (bool);
    function ownerOf(uint256 tokenId) external view returns (address);

    // Get card territory type
    function getTerritoryType(uint256 tokenId) external view returns (uint8);

    // Get full card traits from ColonyTerritoryCards
    function getTerritoryTraits(uint256 tokenId) external view returns (TerritoryTraits memory);

    // Get assigned colony ID for a card
    function getAssignedColony(uint256 tokenId) external view returns (uint256);
}

/**
 * @title TerritoryManagementFacet
 * @notice Territory administration and information management for Colony Wars
 * @dev Handles territory creation, editing, deletion, maintenance, and territory-related information retrieval
 * @dev Integrates with Territory Cards collection for hybrid ownership model (Model D)
 */
contract TerritoryManagementFacet is AccessControlBase {

    uint256 constant DEFAULT_MAX_TERRITORY_PER_COLONY = 6; // Default max territories per colony if not set

    enum TerritoryStatus {
        INACTIVE,              // Nieaktywne
        FREE,                  // Wolne do przejęcia
        CONTROLLED_CURRENT,    // Kontrolowane, opłaty aktualne
        CONTROLLED_DUE,        // Kontrolowane, opłaty należne dziś
        CONTROLLED_OVERDUE,    // Kontrolowane, opłaty zaległe (1-2 dni)
        ABANDONED              // Porzucone (3+ dni zaległości)
    }

    // Rarity tier enum (matching ColonyTerritoryCards)
    enum Rarity {
        COMMON,      // 0: 49%
        UNCOMMON,    // 1: 30%
        RARE,        // 2: 15%
        EPIC,        // 3: 5%
        LEGENDARY    // 4: 1%
    }
    
    // Cumulative probability breakpoints (out of 10000 for precision)
    uint256 private constant LEGENDARY_THRESHOLD = 100;      // 0-99 = 1%
    uint256 private constant EPIC_THRESHOLD = 600;           // 100-599 = 5%
    uint256 private constant RARE_THRESHOLD = 2100;          // 600-2099 = 15%
    uint256 private constant UNCOMMON_THRESHOLD = 5100;      // 2100-5099 = 30%

    struct TerritoryStatusInfo {
        uint256 territoryId;
        string name;
        uint8 territoryType;
        uint16 bonusValue;
        bytes32 controllingColony;
        uint32 lastMaintenancePayment;
        uint32 daysSincePayment;
        TerritoryStatus status;
        bool canCapture;
        uint256 maintenanceCost;
    }

    // Response struct for batch card data retrieval
    struct CardDataResponse {
        uint256 cardTokenId;
        bool exists;
        address owner;
        bool isActive;
        uint256 assignedColonyId;
        uint8 territoryType;
        uint8 rarity;
        uint8 productionBonus;
        uint8 defenseBonus;
        uint8 techLevel;
        uint16 specimenPopulation;
        uint8 colonyWarsType;
    }

    // Events
    event TerritoryCreated(uint256 indexed territoryId, uint8 territoryType, string name, uint16 bonusValue);
    event TerritoryUpdated(uint256 indexed territoryId, uint8 territoryType, string name, uint16 bonusValue);
    event TerritoryDeleted(uint256 indexed territoryId, string name);
    event TerritoryCaptured(uint256 indexed territoryId, bytes32 indexed colony, uint256 cost);
    event TerritoryLost(uint256 indexed territoryId, bytes32 indexed previousOwner, string reason);
    event MaintenancePaid(uint256 indexed territoryId, bytes32 indexed colony, uint256 amount);
    event TerritoriesCleared(uint256 count);
    event TerritoryCounterReset(uint256 oldValue, uint256 newValue);
    event TerritoryRepaired(uint256 indexed territoryId, bytes32 indexed owner, uint256 cost);
    event TerritoryFortified(uint256 indexed territoryId, bytes32 indexed colony, uint256 amount);

    event TerritoryCardMinted(uint256 indexed territoryId, uint256 indexed cardTokenId, address indexed recipient);
    event TerritoryCardActivated(uint256 indexed territoryId, uint256 indexed cardTokenId, bytes32 indexed colony);
    event TerritoryCardDeactivated(uint256 indexed territoryId, uint256 indexed cardTokenId);
    event TerritoryCardTransferApproved(uint256 indexed territoryId, uint256 indexed cardTokenId, address indexed approvedAddress);
    event TerritoryCardTransferRejected(uint256 indexed territoryId, uint256 indexed cardTokenId, address indexed rejectedAddress, string reason);
    event TerritoryCardClaimed(uint256 indexed territoryId, uint256 indexed cardTokenId, bytes32 indexed colony, address recipient);
    event UnboundCardMinted(uint256 indexed cardTokenId, uint8 territoryType, address indexed recipient);
        event CardBoundToTerritory(
        uint256 indexed cardTokenId,
        uint256 indexed territoryId,
        bytes32 indexed colonyId
    );

    
    // Custom errors
    error TerritoryNotFound();
    error TerritoryNotAvailable();
    error MaintenanceNotDue();
    error InvalidTerritoryType();
    error InvalidBonusValue();
    error TerritoryNameTooLong();
    error RateLimitExceeded();
    error TerritoryLimitExceeded();
    error NoRepairNeeded();
    error TerritoryHasActiveSieges();
    error CaptureNotYetAllowed();
    error InvalidFortificationAmount();
    error FortificationLimitExceeded();
    error TerritoryNotOwned();

    error TerritoryCardsNotConfigured();
    error CardOwnerMismatch();
    error CardNotActive();
    error TransferAlreadyApproved();
    error CardAlreadyClaimed();
    error CardNotInTreasury();
    error TerritoryLimitReached();
    error TerritoryHasCardAssigned(uint256 territoryId, uint256 existingCardId);
    error CardTypeMismatch(uint8 cardType, uint8 territoryType);


    /**
     * @notice Create new territory (admin only)
     * @dev Also mints corresponding Territory Card if contract is configured
     */
    function createTerritory(
        uint8 territoryType,
        uint16 bonusValue,
        string calldata name,
        bool withCard
    ) external onlyAuthorized whenNotPaused returns (uint256 territoryId) {
        LibColonyWarsStorage.requireInitialized();
        
        if (territoryType == 0 || territoryType > 5) {
            revert InvalidTerritoryType();
        }
        if (bonusValue == 0 || bonusValue > 100) {
            revert InvalidBonusValue();
        }
        if (bytes(name).length == 0 || bytes(name).length > 50) {
            revert TerritoryNameTooLong();
        }
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        // CHECK: Global territory limit
        uint256 maxGlobal = cws.config.maxGlobalTerritories;
        if (maxGlobal == 0) {
            maxGlobal = 50;
        }

        if (cws.territoryCounter >= maxGlobal) {
            revert TerritoryLimitReached();
        }
        
        cws.territoryCounter++;
        territoryId = cws.territoryCounter;
        
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        territory.territoryType = territoryType;
        territory.bonusValue = bonusValue;
        territory.active = true;
        territory.name = name;
        
        // Mint Territory Card if contract is configured
        if (cws.contractAddresses.territoryCards != address(0) && withCard) {
            uint256 cardTokenId = _mintTerritoryCard(
                territoryId, 
                territoryType, 
                bonusValue, 
                ResourceHelper.getTreasuryAddress(), 
                cws
            );
            emit TerritoryCardMinted(territoryId, cardTokenId, ResourceHelper.getTreasuryAddress());
        }

        emit TerritoryCreated(territoryId, territoryType, name, bonusValue);
        
        return territoryId;
    }

    /**
     * @notice Update existing territory (admin only)
     * @param territoryId Territory ID to update
     * @param territoryType New territory type (1-3)
     * @param bonusValue New bonus value (1-100)
     * @param name New territory name
     */
    function updateTerritory(
        uint256 territoryId,
        uint8 territoryType,
        uint16 bonusValue,
        string calldata name
    ) external onlyAuthorized whenNotPaused {
        LibColonyWarsStorage.requireInitialized();
        
        if (territoryType == 0 || territoryType > 5) {
            revert InvalidTerritoryType();
        }
        if (bonusValue == 0 || bonusValue > 100) {
            revert InvalidBonusValue();
        }
        if (bytes(name).length == 0 || bytes(name).length > 50) {
            revert TerritoryNameTooLong();
        }
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        
        if (!territory.active) {
            revert TerritoryNotFound();
        }
        
        territory.territoryType = territoryType;
        territory.bonusValue = bonusValue;
        territory.name = name;
        
        emit TerritoryUpdated(territoryId, territoryType, name, bonusValue);
    }

    /**
     * @notice Delete territory (admin only)
     * @param territoryId Territory ID to delete
     * @param forceDelete Whether to force deletion even with active sieges
     */
    function deleteTerritory(
        uint256 territoryId,
        bool forceDelete
    ) external onlyAuthorized whenNotPaused {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        
        if (!territory.active) {
            revert TerritoryNotFound();
        }
        
        // Check for active sieges unless force delete
        if (!forceDelete && cws.territoryActiveSieges[territoryId].length > 0) {
            revert TerritoryHasActiveSieges();
        }
        
        string memory territoryName = territory.name;
        
        // Unbind card if present
        uint256 cardTokenId = cws.territoryToCard[territoryId];
        if (cardTokenId > 0 && cws.contractAddresses.territoryCards != address(0)) {
            _deactivateTerritoryCard(territoryId, cardTokenId, cws);
            delete cws.territoryToCard[territoryId];
            delete cws.cardToTerritory[cardTokenId];
            emit TerritoryCardDeactivated(territoryId, cardTokenId);
        }
        
        // Remove from controlling colony if any
        if (territory.controllingColony != bytes32(0)) {
            _removeTerritoryFromColony(territoryId, territory.controllingColony, cws);
            emit TerritoryLost(territoryId, territory.controllingColony, "Territory deleted by admin");
        }
        
        // If force delete, cancel all active sieges
        if (forceDelete) {
            _cancelAllTerritorySieges(territoryId, cws);
        }
        
        // Clear territory data
        delete cws.territories[territoryId];
        delete cws.territoryActiveSieges[territoryId];
        
        // Decrement global counter
        unchecked {
            cws.territoryCounter--;
        }

        emit TerritoryDeleted(territoryId, territoryName);
    }


    /**
     * @notice Administratively assign territory to colony (admin only)
     * @dev Bypasses all checks - use for setup, corrections, or special events
     * @param territoryId Territory ID to assign
     * @param colonyId Colony to assign to (use bytes32(0) to unassign)
     * @param skipLimits Whether to skip per-colony territory limit checks
     */
    function adminAssignTerritory(
        uint256 territoryId,
        bytes32 colonyId,
        bool skipLimits,
        bool skipCardActivation
    ) external onlyAuthorized whenNotPaused {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        
        // Validate territory exists
        if (!territory.active) {
            revert TerritoryNotFound();
        }
        
        // If assigning to a colony (not unassigning)
        if (colonyId != bytes32(0)) {
            // Check territory limit unless explicitly skipped
            if (!skipLimits) {
                uint256 currentTerritories = _countActiveColonyTerritories(colonyId, cws);
                uint256 maxTerritories = cws.config.maxTerritoriesPerColony;
                if (maxTerritories == 0) {
                    maxTerritories = DEFAULT_MAX_TERRITORY_PER_COLONY;
                }
                
                if (currentTerritories >= maxTerritories) {
                    revert TerritoryLimitExceeded();
                }
            }
        }
        
        bytes32 previousColony = territory.controllingColony;
        
        // Remove from previous colony if was assigned
        if (previousColony != bytes32(0)) {
            _removeTerritoryFromColony(territoryId, previousColony, cws);
            
            // Deactivate card if present
            if (cws.contractAddresses.territoryCards != address(0) && !skipCardActivation) {
                uint256 cardTokenId = cws.territoryToCard[territoryId];
                if (cardTokenId > 0) {
                    _deactivateTerritoryCard(territoryId, cardTokenId, cws);
                    emit TerritoryCardDeactivated(territoryId, cardTokenId);
                }
            }
            
            emit TerritoryLost(territoryId, previousColony, "Admin reassignment");
        }
        
        // Assign to new colony (or unassign if colonyId is 0)
        territory.controllingColony = colonyId;
        
        if (colonyId != bytes32(0)) {
            // Update maintenance timestamp
            territory.lastMaintenancePayment = uint32(block.timestamp);
            
            // Add to colony's territory list
            cws.colonyTerritories[colonyId].push(territoryId);
            
            // Activate Territory Card if present
            if (cws.contractAddresses.territoryCards != address(0) && !skipCardActivation) {
                uint256 cardTokenId = cws.territoryToCard[territoryId];
                if (cardTokenId > 0) {
                    _activateTerritoryCard(territoryId, cardTokenId, colonyId, cws);
                    emit TerritoryCardActivated(territoryId, cardTokenId, colonyId);
                }
            }
            
            emit TerritoryCaptured(territoryId, colonyId, 0); // 0 cost for admin action
        } else {
            // Unassigning - reset maintenance
            territory.lastMaintenancePayment = 0;
        }
    }

    /**
     * @notice Capture a territory
     */
    function captureTerritory(uint256 territoryId, bytes32 colonyId) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("territories");

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Rate limiting
        if (!LibColonyWarsStorage.checkRateLimit(LibMeta.msgSender(), this.captureTerritory.selector, 3600)) {
            revert RateLimitExceeded();
        }
        
        if (!ColonyHelper.isColonyCreator(colonyId, hs.stakingSystemAddress) && !AccessHelper.isAuthorized()) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony controller");
        }
        
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        if (!territory.active) {
            revert TerritoryNotFound();
        }

        uint32 currentSeason = cws.currentSeason;
        LibColonyWarsStorage.Season storage season = cws.seasons[currentSeason];
        
        // Determine season phase
        bool isSeasonActive = season.active;
        bool isOffSeason = !isSeasonActive || block.timestamp > season.resolutionEnd;
        
        // Validate registration - required both in-season and off-season
        if (!cws.colonyWarProfiles[colonyId].registered) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Colony not registered for season");
        }
        
        // Check availability - territory can be captured if:
        // 1. Uncontrolled (no owner)
        // 2. Fully damaged from siege (damageLevel >= 100)
        // 3. Abandoned (3+ days without maintenance)
        if (territory.controllingColony != bytes32(0)) {
            bool isFullyDamaged = territory.damageLevel >= 100;
            uint32 daysSincePayment = (uint32(block.timestamp) - territory.lastMaintenancePayment) / 86400;
            bool isAbandoned = daysSincePayment >= 3;

            if (!isFullyDamaged && !isAbandoned) {
                revert TerritoryNotAvailable();
            }

            // If fully damaged, check destroyer priority (1 hour exclusive capture window)
            if (isFullyDamaged) {
                bytes32 destroyingSiegeId = cws.lastDestroyingSiegeId[territoryId];
                if (destroyingSiegeId != bytes32(0)) {
                    LibColonyWarsStorage.TerritorySiege storage destroyingSiege = cws.territorySieges[destroyingSiegeId];
                    // siegeEndTime is when the siege was resolved (damage applied)
                    uint32 timeSinceDestruction = uint32(block.timestamp) - destroyingSiege.siegeEndTime;
                    // Within 1 hour, only the destroyer colony can capture
                    if (timeSinceDestruction < 3600 && colonyId != destroyingSiege.attackerColony) {
                        revert CaptureNotYetAllowed();
                    }
                }
            }
        }

        // Check territory limit
        uint256 currentTerritories = _countActiveColonyTerritories(colonyId, cws);
        uint256 maxTerritories = cws.config.maxTerritoriesPerColony;
        if (maxTerritories == 0) {
            maxTerritories = DEFAULT_MAX_TERRITORY_PER_COLONY;
        }

        if (currentTerritories >= maxTerritories) {
            revert TerritoryLimitExceeded();
        }
        
        // Calculate cost with off-season penalty
        uint256 captureCost = cws.config.territoryCaptureCost;
        if (isOffSeason) {
            captureCost = (captureCost * 150) / 100; // +50% off-season penalty
        }
        
        // Transfer capture cost
        if (!AccessHelper.isAuthorized()) {
            ResourceHelper.collectPrimaryFee(
                LibMeta.msgSender(),
                captureCost,
                "territory_capture"
            );
        }
        
        // Remove from previous owner
        if (territory.controllingColony != bytes32(0)) {
            _removeTerritoryFromColony(territoryId, territory.controllingColony, cws);
            emit TerritoryLost(territoryId, territory.controllingColony, "Captured");
        }
        
        // Assign to new colony
        territory.controllingColony = colonyId;
        territory.lastMaintenancePayment = uint32(block.timestamp);

        // Reset damage and capture priority after capture
        if (territory.damageLevel > 0) {
            territory.damageLevel = 0;
        }
        // Clear the destroying siege reference
        if (cws.lastDestroyingSiegeId[territoryId] != bytes32(0)) {
            delete cws.lastDestroyingSiegeId[territoryId];
        }

        // Add to colony's territory list
        cws.colonyTerritories[colonyId].push(territoryId);
        
        // PHASE 6 INTEGRATION: Activate Territory Card
        if (cws.contractAddresses.territoryCards != address(0)) {
            uint256 cardTokenId = cws.territoryToCard[territoryId];
            if (cardTokenId > 0) {
                _activateTerritoryCard(territoryId, cardTokenId, colonyId, cws);
                emit TerritoryCardActivated(territoryId, cardTokenId, colonyId);
            }
        }
        
        emit TerritoryCaptured(territoryId, colonyId, captureCost);
    }

    // ============================================================================
    // NOTE: repairTerritory() is implemented in TerritoryWarsFacet.sol
    // 
    // That implementation correctly uses:
    //   LibFeeCollection.processConfiguredFee(cws.config.repairFee, ...)
    // which uses YELLOW token with burn mechanism.
    // 
    // Do NOT duplicate this function here - it causes Diamond selector conflicts.
    // ============================================================================

    /**
     * @notice Pay maintenance for controlled territory
     * @dev Uses configured YELLOW maintenance fee with burn mechanism
     */
    function maintainTerritory(uint256 territoryId) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("territories");
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        if (!territory.active || territory.controllingColony == bytes32(0)) {
            revert TerritoryNotFound();
        }
        
        if (!ColonyHelper.isColonyCreator(territory.controllingColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not territory controller");
        }
        
        uint32 daysSincePayment = (uint32(block.timestamp) - territory.lastMaintenancePayment) / 86400;
        if (daysSincePayment == 0) {
            revert MaintenanceNotDue();
        }

        // Calculate dynamic maintenance cost multiplier
        // Base: daysSincePayment (pay for each overdue day)
        // Modifier 1: War stress (0-10) adds 5% per level
        // Modifier 2: Debt penalty adds 20% if colony has debt
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[territory.controllingColony];

        uint256 stressMultiplier = 100 + (uint256(profile.warStress) * 5); // 100-150%
        uint256 debtMultiplier = 100;

        // Check if colony has unpaid debt
        if (cws.colonyDebts[territory.controllingColony].principalDebt > 0) {
            debtMultiplier = 120; // +20% penalty for indebted colonies
        }

        // Final quantity = days * (stressMultiplier/100) * (debtMultiplier/100)
        // To avoid precision loss: (days * stressMultiplier * debtMultiplier) / 10000
        uint256 adjustedQuantity = (uint256(daysSincePayment) * stressMultiplier * debtMultiplier) / 10000;
        if (adjustedQuantity == 0) adjustedQuantity = 1; // Minimum 1 day

        // Use configured maintenance fee (YELLOW token with burn)
        // processConfiguredFee calculates: baseAmount * multiplier * quantity / 100
        LibColonyWarsStorage.OperationFee storage maintenanceFee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_MAINTENANCE);
        LibFeeCollection.processConfiguredFee(
            maintenanceFee,
            LibMeta.msgSender(),
            adjustedQuantity,
            "territory_maintenance"
        );

        territory.lastMaintenancePayment = uint32(block.timestamp);

        // Decay stress over time (profile already declared above)
        if (block.timestamp > profile.lastStressTime + 86400 && profile.warStress > 0) {
            profile.warStress--;
            profile.lastStressTime = uint32(block.timestamp);
        }

        // Emit with actual cost paid (baseAmount * multiplier * adjustedQuantity / 100)
        uint256 actualCost = (maintenanceFee.baseAmount * maintenanceFee.multiplier * adjustedQuantity) / 100;
        emit MaintenancePaid(territoryId, territory.controllingColony, actualCost);
    }

    /**
     * @notice Fortify territory with ZICO investment
     * @param territoryId Territory to fortify
     * @param fortificationAmount ZICO amount (must be multiple of 100)
     */
    function fortifyTerritory(uint256 territoryId, uint256 fortificationAmount) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Rate limiting - 7 days
        if (!LibColonyWarsStorage.checkActionCooldown(territoryId, "fortify", 604800)) { // 7 days
            revert RateLimitExceeded();
        }

        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        if (!territory.active || territory.controllingColony == bytes32(0)) {
            revert TerritoryNotFound();
        }
        
        if (!ColonyHelper.isColonyCreator(territory.controllingColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not territory controller");
        }
        
        if (fortificationAmount % 100 ether != 0 || fortificationAmount == 0) {
            revert InvalidFortificationAmount();
        }
        
        // Check defense stake limit and cap fortification
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[territory.controllingColony];
        uint256 maxFortificationAllowed = profile.defensiveStake;
        uint256 currentFortificationValue = uint256(territory.fortificationLevel) * 100 ether;
        
        // Cap fortification amount to not exceed defensive stake
        uint256 remainingCapacity = maxFortificationAllowed > currentFortificationValue 
            ? maxFortificationAllowed - currentFortificationValue 
            : 0;
        
        if (remainingCapacity == 0) {
            revert FortificationLimitExceeded();
        }
        
        // Limit fortification to available capacity
        if (fortificationAmount > remainingCapacity) {
            fortificationAmount = remainingCapacity;
            // Round down to nearest 100 ZICO
            fortificationAmount = (fortificationAmount / 100 ether) * 100 ether;
            
            if (fortificationAmount == 0) {
                revert FortificationLimitExceeded();
            }
        }
        
        uint16 levelsToAdd = uint16(fortificationAmount / 100 ether);

        // Transfer ZICO
        ResourceHelper.collectPrimaryFee(
            LibMeta.msgSender(),
            fortificationAmount,
            "territory_fortification"
        );

        // Update territory and award points
        territory.fortificationLevel += levelsToAdd;
        LibColonyWarsStorage.addColonyScore(cws.currentSeason, territory.controllingColony, levelsToAdd * 10);
        
        emit TerritoryFortified(territoryId, territory.controllingColony, fortificationAmount);
    }

    /**
     * @notice Abandon territory
     */
    function abandonTerritory(uint256 territoryId) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        if (!territory.active || territory.controllingColony == bytes32(0)) {
            revert TerritoryNotFound();
        }
        
        if (!ColonyHelper.isColonyCreator(territory.controllingColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony controller");
        }
        
        bytes32 previousOwner = territory.controllingColony;
        
        _removeTerritoryFromColony(territoryId, territory.controllingColony, cws);
        
        territory.controllingColony = bytes32(0);
        territory.lastMaintenancePayment = 0;
        
        // PHASE 6 INTEGRATION: Deactivate Territory Card
        if (cws.contractAddresses.territoryCards != address(0)) {
            uint256 cardTokenId = cws.territoryToCard[territoryId];
            if (cardTokenId > 0) {
                _deactivateTerritoryCard(territoryId, cardTokenId, cws);
                emit TerritoryCardDeactivated(territoryId, cardTokenId);
            }
        }
        
        emit TerritoryLost(territoryId, previousOwner, "Abandoned");
    }

    /**
     * @notice Bulk territory cleanup
     * @param territoryIds Array of territory IDs to delete
     */
    function clearTerritories(uint256[] calldata territoryIds) external onlyAuthorized {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        for (uint256 i = 0; i < territoryIds.length && i < 50; i++) { // Gas limit
            delete cws.territories[territoryIds[i]];
        }

        emit TerritoriesCleared(territoryIds.length);
    }

    /**
     * @notice Administrative reset of territory counter
     * @dev Use with caution - only reset when all territories have been cleared
     * @param newValue New value for territory counter (0 to fully reset, or specific value)
     */
    function resetTerritoryCounter(uint256 newValue) external onlyAuthorized {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        uint256 oldValue = cws.territoryCounter;
        cws.territoryCounter = newValue;

        emit TerritoryCounterReset(oldValue, newValue);
    }

    /**
     * @notice Force clean corrupted territory slot without reading data
     * @dev Emergency function for corrupted storage slots
     * @param territoryId Territory ID to force clean
     */
    function forceCleanTerritory(uint256 territoryId) external onlyAuthorized {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        // Direct delete without reading any data
        delete cws.territories[territoryId];
        delete cws.territoryActiveSieges[territoryId];
        delete cws.territoryToCard[territoryId];

        emit TerritoryDeleted(territoryId, "Force cleaned");
    }

    // ============================================================================
    // TERRITORY CARDS INTEGRATION - ADMIN FUNCTIONS
    // ============================================================================

    /**
     * @notice Set Territory Cards contract address
     * @param cardContract Address of ColonyTerritoryCards contract
     */
    function setTerritoryCardsContract(address cardContract) external onlyAuthorized {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        cws.contractAddresses.territoryCards = cardContract;
    }

    /**
     * @notice Get Territory Cards contract address
     */
    function getTerritoryCardsContract() external view returns (address) {
        return LibColonyWarsStorage.colonyWarsStorage().contractAddresses.territoryCards;
    }

    // ============================================================================
    // TERRITORY CARDS INTEGRATION - MISSING VIEW FUNCTIONS FROM OLD FACET
    // ============================================================================

    /**
     * @notice Get territory ID for a card token
     * @param nftTokenId Card token ID
     * @return territoryId Associated territory ID (0 if not mapped)
     */
    function getCardTerritoryId(uint256 nftTokenId) external view returns (uint256) {
        return LibColonyWarsStorage.colonyWarsStorage().cardToTerritory[nftTokenId];
    }

    /**
     * @notice Get card token ID for a territory
     * @param territoryId Territory ID
     * @return cardTokenId Associated card token ID (0 if not mapped)
     */
    function getTerritoryCardId(uint256 territoryId) external view returns (uint256) {
        return LibColonyWarsStorage.colonyWarsStorage().territoryToCard[territoryId];
    }

    /**
     * @notice Check if territory has associated card
     * @param territoryId Territory ID
     * @return hasCard Whether territory has card assigned
     */
    function hasTerritoryCard(uint256 territoryId) external view returns (bool) {
        return LibColonyWarsStorage.colonyWarsStorage().territoryToCard[territoryId] != 0;
    }

    /**
     * @notice Get comprehensive territory card information
     * @param territoryId Territory ID
     * @return exists Whether territory card mapping exists
     * @return nftTokenId Card token ID
     * @return owner Current owner of the card
     * @return isActive Whether card is active
     * @return assignedColony Colony the territory is assigned to (as uint256)
     */
    function getTerritoryCardInfo(uint256 territoryId) 
        external 
        view 
        returns (
            bool exists,
            uint256 nftTokenId,
            address owner,
            bool isActive,
            uint256 assignedColony
        ) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        nftTokenId = cws.territoryToCard[territoryId];
        exists = (nftTokenId != 0 && cws.contractAddresses.territoryCards != address(0));
        
        if (!exists) {
            return (false, 0, address(0), false, 0);
        }
        
        ITerritoryCards cardContract = ITerritoryCards(cws.contractAddresses.territoryCards);
        
        // Get card owner
        owner = cardContract.ownerOf(nftTokenId);
        
        // Get card active status
        isActive = cardContract.isTerritoryActive(nftTokenId);
        
        // Get territory assignment
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        assignedColony = uint256(territory.controllingColony);
        
        return (exists, nftTokenId, owner, isActive, assignedColony);
    }

    // ============================================================================
    // TERRITORY CARDS INTEGRATION - RESOURCE BONUS MECHANICS
    // ============================================================================

    /**
     * @notice Apply Territory Card bonuses to resource production
     * @dev Called by ResourcePodFacet during harvest calculations
     * @param territoryId Territory ID to get bonuses from
     * @param baseAmount Base resource amount before bonuses
     * @return boostedAmount Amount after applying territory card bonuses
     */
    function applyTerritoryCardBonus(
        uint256 territoryId,
        uint256 baseAmount
    ) external view returns (uint256 boostedAmount) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        // Check if territory has associated card
        uint256 cardTokenId = cws.territoryToCard[territoryId];
        if (cardTokenId == 0 || cws.contractAddresses.territoryCards == address(0)) {
            return baseAmount; // No card, no bonus
        }
        
        // Check if card is active
        ITerritoryCards cardContract = ITerritoryCards(cws.contractAddresses.territoryCards);
        if (!cardContract.isTerritoryActive(cardTokenId)) {
            return baseAmount; // Inactive card, no bonus
        }
        
        // Get territory info for production bonus
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        
        // Calculate bonus: use bonusValue as percentage (1-100%)
        // Apply damage reduction to bonus
        uint256 effectiveBonus = territory.bonusValue;
        if (territory.damageLevel > 0) {
            uint256 damageReduction = (effectiveBonus * territory.damageLevel) / 100;
            effectiveBonus = effectiveBonus - damageReduction;
        }
        
        // Apply bonus to base amount
        boostedAmount = baseAmount + (baseAmount * effectiveBonus) / 100;
        
        return boostedAmount;
    }

    /**
     * @notice Get comprehensive territory card bonuses
     * @param territoryId Territory ID to query
     * @return hasCard Whether territory has associated NFT card
     * @return isActive Whether card is currently active
     * @return productionBonus Production bonus percentage (0-100)
     * @return defenseBonus Defense bonus percentage (0-100)
     * @return effectiveProductionBonus Production bonus after damage reduction
     */
    function getTerritoryCardBonuses(uint256 territoryId)
        external
        view
        returns (
            bool hasCard,
            bool isActive,
            uint16 productionBonus,
            uint16 defenseBonus,
            uint16 effectiveProductionBonus
        )
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        uint256 cardTokenId = cws.territoryToCard[territoryId];
        hasCard = (cardTokenId > 0 && cws.contractAddresses.territoryCards != address(0));
        
        if (!hasCard) {
            return (false, false, 0, 0, 0);
        }
        
        ITerritoryCards cardContract = ITerritoryCards(cws.contractAddresses.territoryCards);
        isActive = cardContract.isTerritoryActive(cardTokenId);
        
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        productionBonus = territory.bonusValue;
        
        // Defense bonus from fortifications
        defenseBonus = territory.fortificationLevel * 5;
        
        // Calculate effective production bonus (after damage)
        if (territory.damageLevel > 0) {
            uint256 damageReduction = (uint256(productionBonus) * territory.damageLevel) / 100;
            effectiveProductionBonus = productionBonus - uint16(damageReduction);
        } else {
            effectiveProductionBonus = productionBonus;
        }
        
        return (hasCard, isActive, productionBonus, defenseBonus, effectiveProductionBonus);
    }

    /**
     * @notice Sync territory state with NFT card
     * @dev Updates card metadata when territory is damaged/repaired/fortified
     * @param territoryId Territory to sync
     */
    function syncTerritoryWithCard(uint256 territoryId) external whenNotPaused {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        // Verify territory exists
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        if (!territory.active) {
            revert TerritoryNotFound();
        }
        
        // Verify card exists
        uint256 cardTokenId = cws.territoryToCard[territoryId];
        if (cardTokenId == 0 || cws.contractAddresses.territoryCards == address(0)) {
            revert TerritoryCardsNotConfigured();
        }
        
        // Card contract will update its internal metadata based on current territory state
        // This is a placeholder - actual implementation depends on ColonyTerritoryCards interface
        // For now, just emit event to signal sync occurred
        emit TerritoryCardActivated(territoryId, cardTokenId, territory.controllingColony);
    }

    /**
     * @notice Batch apply territory bonuses to multiple resource amounts
     * @dev Optimized for ResourcePodFacet batch harvest operations
     * @param territoryIds Array of territory IDs
     * @param baseAmounts Array of base resource amounts
     * @return boostedAmounts Array of amounts after bonuses
     */
    function applyTerritoryBonuses(
        uint256[] calldata territoryIds,
        uint256[] calldata baseAmounts
    ) external view returns (uint256[] memory boostedAmounts) {
        require(territoryIds.length == baseAmounts.length, "Array length mismatch");
        
        boostedAmounts = new uint256[](territoryIds.length);
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        for (uint256 i = 0; i < territoryIds.length; i++) {
            uint256 territoryId = territoryIds[i];
            uint256 baseAmount = baseAmounts[i];
            
            // Check if territory has active card
            uint256 cardTokenId = cws.territoryToCard[territoryId];
            if (cardTokenId == 0 || cws.contractAddresses.territoryCards == address(0)) {
                boostedAmounts[i] = baseAmount;
                continue;
            }

            ITerritoryCards cardContract = ITerritoryCards(cws.contractAddresses.territoryCards);
            if (!cardContract.isTerritoryActive(cardTokenId)) {
                boostedAmounts[i] = baseAmount;
                continue;
            }
            
            // Apply bonus
            LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
            uint256 effectiveBonus = territory.bonusValue;
            
            if (territory.damageLevel > 0) {
                uint256 damageReduction = (effectiveBonus * territory.damageLevel) / 100;
                effectiveBonus = effectiveBonus - damageReduction;
            }
            
            boostedAmounts[i] = baseAmount + (baseAmount * effectiveBonus) / 100;
        }
        
        return boostedAmounts;
    }

    // ============================================================================
    // TERRITORY CARDS INTEGRATION - USER ACQUISITION & ASSIGNMENT
    // ============================================================================

    /**
     * @notice Mint unbound Territory Card (no territory slot required)
     * @dev 20% cheaper than mintTerritoryCard, card is tradeable until bound
     * @param territoryType Type of territory card (1-5)
     * @return cardTokenId Minted card token ID
     */
    function mintUnboundCard(uint8 territoryType)
        external
        payable
        whenNotPaused
        nonReentrant
        returns (uint256 cardTokenId)
    {
        LibColonyWarsStorage.requireInitialized();

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        if (cws.contractAddresses.territoryCards == address(0)) {
            revert TerritoryCardsNotConfigured();
        }

        // Validate territory type
        if (territoryType == 0 || territoryType > 5) {
            revert InvalidTerritoryType();
        }

        // Calculate unbound price: 80% discount (no territory slot included)
        uint256 basePrice = _calculateMintPrice(territoryType);
        uint256 unboundPrice = (basePrice * 20) / 100;

        // Transfer payment
        ResourceHelper.collectPrimaryFee(
            LibMeta.msgSender(),
            unboundPrice,
            "unbound_card_mint"
        );

        // Generate card stats (no territory created yet)
        (uint8 rarity, uint16 bonusValue) = _calculateRarityWithBonus(
            block.timestamp,
            territoryType,
            LibMeta.msgSender()
        );
        
        uint16 productionBonus = _calculateProductionBonus(territoryType, bonusValue);
        uint16 defenseBonus = _calculateDefenseBonus(territoryType, bonusValue);
        uint8 techLevel = _calculateTechLevel(territoryType, rarity);
        uint16 chickenPopulation = _calculateChickenPopulation(territoryType, bonusValue);
        
        // Mint card to user (unbound - no territory)
        cardTokenId = ITerritoryCards(cws.contractAddresses.territoryCards).mintTerritory(
            LibMeta.msgSender(),
            territoryType,
            rarity,
            productionBonus,
            defenseBonus,
            techLevel,
            chickenPopulation
        );
        
        // NO territory created - card is unbound
        // NO territory mapping - card can be bound later
        // NO global counter increment - only when bound to territory

        emit UnboundCardMinted(cardTokenId, territoryType, LibMeta.msgSender());

        return cardTokenId;
    }

    /**
     * @notice Mint Territory Card directly from treasury (User pays ZICO)
     * @dev Creates territory + mints card + auto-assigns to colony
     * @param territoryType Type of territory (1-5)
     * @param colonyId Colony to assign card to
     * @return cardTokenId Minted card token ID
     */
    function mintTerritoryCard(
        uint8 territoryType,
        bytes32 colonyId
    ) external payable whenNotPaused nonReentrant returns (uint256 cardTokenId) {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (cws.contractAddresses.territoryCards == address(0)) {
            revert TerritoryCardsNotConfigured();
        }
        
        // Validate colony ownership
        if (!ColonyHelper.isColonyCreator(colonyId, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony controller");
        }
        
        // Validate territory type
        if (territoryType == 0 || territoryType > 5) {
            revert InvalidTerritoryType();
        }
        
        // CHECK 1: Global territory limit
        uint256 maxGlobal = cws.config.maxGlobalTerritories;
        if (maxGlobal == 0) {
            maxGlobal = 50; // Fallback default
        }
        
        if (cws.territoryCounter >= maxGlobal ) {
            revert TerritoryLimitReached();
        }
        
        // CHECK 2: Per-colony soft limit (optional)
        uint256 colonyTerritories = _countActiveColonyTerritories(colonyId, cws);
        uint256 maxPerColony = cws.config.maxTerritoriesPerColony;
        if (maxPerColony > 0 && colonyTerritories >= maxPerColony) {
            revert TerritoryLimitExceeded();
        }
        
        // Calculate mint price
        uint256 mintPrice = _calculateMintPrice(territoryType);

        // Transfer ZICO payment
        ResourceHelper.collectPrimaryFee(LibMeta.msgSender(), mintPrice, "territory_card_mint");

        // Create game territory first
        cws.territoryCounter++;
        uint256 territoryId = cws.territoryCounter;
        
        // Generate random bonus and rarity
        (, uint16 bonusValue) = _calculateRarityWithBonus(
            territoryId,
            territoryType,
            LibMeta.msgSender()
        );
        
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        territory.territoryType = territoryType;
        territory.bonusValue = bonusValue;
        territory.active = true;
        territory.name = _generateTerritoryName(territoryType, territoryId);
        territory.controllingColony = colonyId;
        territory.lastMaintenancePayment = uint32(block.timestamp);
        
        // Mint card to user (not treasury)
        cardTokenId = _mintTerritoryCard(
            territoryId,
            territoryType,
            bonusValue,
            LibMeta.msgSender(), // User gets card
            cws
        );
        
        // Auto-assign to colony
        _activateTerritoryCard(territoryId, cardTokenId, colonyId, cws);
        
        // Add to colony territories
        cws.colonyTerritories[colonyId].push(territoryId);
   
        emit TerritoryCardMinted(territoryId, cardTokenId, LibMeta.msgSender());
        emit TerritoryCaptured(territoryId, colonyId, mintPrice);
        
        return cardTokenId;
    }

    /**
     * @notice Assign a free Territory Card to an existing colony territory
     * @dev User must own the card, control the colony, and pay assignment fee
     * @param colonyId Colony identifier
     * @param cardTokenId Territory Card token ID to assign
     * @param territoryId Existing territory ID (must be controlled by colony)
     */
    function assignCardToColony(
        bytes32 colonyId,
        uint256 cardTokenId,
        uint256 territoryId
    ) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // 0. Validate Territory Cards contract is configured
        if (cws.contractAddresses.territoryCards == address(0)) {
            revert TerritoryCardsNotConfigured();
        }
        
        ITerritoryCards cardContract = ITerritoryCards(cws.contractAddresses.territoryCards);
        
        // 1. Validate territory exists and is active
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        if (!territory.active) {
            revert TerritoryNotFound();
        }
        
        // 2. Validate territory belongs to specified colony
        if (territory.controllingColony != colonyId) {
            revert TerritoryNotOwned();
        }
        
        // 3. Validate caller controls the colony
        if (!ColonyHelper.isColonyCreator(colonyId, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony controller");
        }
        
        // 4. Validate caller owns the card NFT
        address cardOwner = cardContract.ownerOf(cardTokenId);
        if (cardOwner != LibMeta.msgSender()) {
            revert CardOwnerMismatch();
        }
        
        // 5. Validate territory doesn't already have a card assigned
        uint256 existingCard = cws.territoryToCard[territoryId];
        if (existingCard != 0) {
            revert TerritoryHasCardAssigned(territoryId, existingCard);
        }
        
        // 6. Validate card is not already assigned to another territory
        uint256 existingTerritory = cws.cardToTerritory[cardTokenId];
        if (existingTerritory != 0) {
            revert CardAlreadyClaimed();
        }
        
        // 7. Validate card is currently inactive (not bound to any territory)
        if (cardContract.isTerritoryActive(cardTokenId)) {
            revert CardNotActive();
        }
        
        // 8. Get card type and validate it matches territory type
        // NOTE: Requires getTerritoryType(uint256 tokenId) in ITerritoryCards interface
        uint8 cardType = _getCardType(cardTokenId, cardContract);
        if (cardType != territory.territoryType) {
            revert CardTypeMismatch(cardType, territory.territoryType);
        }
        
        // 9. Charge assignment fee (500 ZICO - reasonable for binding valuable NFT)
        uint256 assignmentFee = 500 ether;
        ResourceHelper.collectPrimaryFee(LibMeta.msgSender(), assignmentFee, "card_assignment");

        // 10. Create bidirectional mapping in storage
        cws.territoryToCard[territoryId] = cardTokenId;
        cws.cardToTerritory[cardTokenId] = territoryId;
        
        // 11. Activate card on the NFT contract (marks as bound)
        _activateTerritoryCard(territoryId, cardTokenId, colonyId, cws);
        
        emit CardBoundToTerritory(cardTokenId, territoryId, colonyId);
    }

    /**
     * @notice Unbind card from territory without replacement
     * @dev Card becomes unbound and can be freely traded
     * @param territoryId Territory to unbind card from
     */
    function unbindTerritoryCard(uint256 territoryId) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (cws.contractAddresses.territoryCards == address(0)) {
            revert TerritoryCardsNotConfigured();
        }
        
        // Validate territory exists and is controlled
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        if (!territory.active || territory.controllingColony == bytes32(0)) {
            revert TerritoryNotFound();
        }
        
        // Validate colony ownership
        if (!ColonyHelper.isColonyCreator(territory.controllingColony, hs.stakingSystemAddress)) {
            revert TerritoryNotOwned();
        }
        
        // Get card token ID
        uint256 cardTokenId = cws.territoryToCard[territoryId];
        if (cardTokenId == 0) {
            revert TerritoryNotFound();
        }
        
        // Deactivate and unbind card
        _deactivateTerritoryCard(territoryId, cardTokenId, cws);
        delete cws.territoryToCard[territoryId];
        delete cws.cardToTerritory[cardTokenId];
        
        emit TerritoryCardDeactivated(territoryId, cardTokenId);
    }

    /**
     * @notice Replace existing territory card with different card of matching type
     * @dev Old card is unbound and returned to owner, new card is bound
     * @param territoryId Territory slot to update
     * @param oldCardId Current card (must be assigned to this territory)
     * @param newCardId New card (must be owned, unassigned, and matching type)
     */
    function replaceTerritoryCard(
        uint256 territoryId,
        uint256 oldCardId,
        uint256 newCardId
    ) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (cws.contractAddresses.territoryCards == address(0)) {
            revert TerritoryCardsNotConfigured();
        }
        
        ITerritoryCards cardContract = ITerritoryCards(cws.contractAddresses.territoryCards);
        
        // 1. Validate territory exists and is controlled
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        if (!territory.active || territory.controllingColony == bytes32(0)) {
            revert TerritoryNotFound();
        }
        
        // 2. Validate colony ownership
        if (!ColonyHelper.isColonyCreator(territory.controllingColony, hs.stakingSystemAddress)) {
            revert TerritoryNotOwned();
        }
        
        // 3. Validate old card is currently assigned to this territory
        if (cws.territoryToCard[territoryId] != oldCardId) {
            revert CardOwnerMismatch();
        }
        if (!cardContract.isTerritoryActive(oldCardId)) {
            revert CardNotActive();
        }
        
        // 4. Validate caller owns the new card
        if (cardContract.ownerOf(newCardId) != LibMeta.msgSender()) {
            revert CardOwnerMismatch();
        }
        
        // 5. Validate new card is not already assigned
        if (cws.cardToTerritory[newCardId] != 0) {
            revert CardAlreadyClaimed();
        }
        if (cardContract.isTerritoryActive(newCardId)) {
            revert CardNotActive();
        }
        
        // 6. Validate new card type matches territory type
        uint8 newCardType = _getCardType(newCardId, cardContract);
        
        if (newCardType != territory.territoryType) {
            revert CardTypeMismatch(newCardType, territory.territoryType);
        }
        
        // 7. Charge replacement fee (250 ZICO - 50% discount vs new assignment)
        uint256 replacementFee = 250 ether;
        ResourceHelper.collectPrimaryFee(LibMeta.msgSender(), replacementFee, "card_replacement");

        // 8. Deactivate old card
        _deactivateTerritoryCard(territoryId, oldCardId, cws);
        delete cws.cardToTerritory[oldCardId];
        
        // 9. Update mappings with new card
        cws.territoryToCard[territoryId] = newCardId;
        cws.cardToTerritory[newCardId] = territoryId;
        
        // 10. Activate new card
        _activateTerritoryCard(territoryId, newCardId, territory.controllingColony, cws);
        
        emit TerritoryCardDeactivated(territoryId, oldCardId);
        emit CardBoundToTerritory(newCardId, territoryId, territory.controllingColony);
    }

    // ============================================================================
    // TERRITORY CARDS INTEGRATION - TRANSFER APPROVAL
    // ============================================================================

    /**
     * @notice Approve Territory Card transfer (called by card owner via requestTransfer)
     * @dev Only callable by territory controller through Colony Wars validation
     * @param territoryId Territory ID
     * @param newOwner Address to approve transfer to
     */
    function approveCardTransfer(
        uint256 territoryId,
        address newOwner
    ) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (cws.contractAddresses.territoryCards == address(0)) {
            revert TerritoryCardsNotConfigured();
        }
        
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        if (!territory.active || territory.controllingColony == bytes32(0)) {
            revert TerritoryNotFound();
        }
        
        // Only territory controller can approve
        if (!ColonyHelper.isColonyCreator(territory.controllingColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not territory controller");
        }
        
        uint256 cardTokenId = cws.territoryToCard[territoryId];
        if (cardTokenId == 0) {
            revert TerritoryNotFound();
        }
        
        // Validate with Colony Wars rules:
        // 1. No active sieges
        if (cws.territoryActiveSieges[territoryId].length > 0) {
            revert TerritoryHasActiveSieges();
        }
        
        // 2. Maintenance paid (no overdue)
        uint32 daysSincePayment = (uint32(block.timestamp) - territory.lastMaintenancePayment) / 86400;
        if (daysSincePayment > 1) {
            revert MaintenanceNotDue();
        }
        
        // 3. Rate limiting (7 days between transfers)
        if (!LibColonyWarsStorage.checkActionCooldown(territoryId, "card_transfer", 604800)) {
            revert RateLimitExceeded();
        }
        
        // Approve transfer on card contract
        ITerritoryCards(cws.contractAddresses.territoryCards).approveTransfer(cardTokenId, newOwner);
        
        emit TerritoryCardTransferApproved(territoryId, cardTokenId, newOwner);
    }

    /**
     * @notice Claim Territory Card from treasury
     * @dev Allows colony controller to claim NFT ownership after capturing territory
     * @param territoryId Territory ID to claim card for
     */
    function claimTerritoryCard(uint256 territoryId) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (cws.contractAddresses.territoryCards == address(0)) {
            revert TerritoryCardsNotConfigured();
        }
        
        // Validate territory exists and is controlled
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        if (!territory.active || territory.controllingColony == bytes32(0)) {
            revert TerritoryNotFound();
        }
        
        // Validate caller controls the colony that owns this territory
        if (!ColonyHelper.isColonyCreator(territory.controllingColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not territory controller");
        }
        
        // Get card token ID
        uint256 cardTokenId = cws.territoryToCard[territoryId];
        if (cardTokenId == 0) {
            revert TerritoryNotFound();
        }
        
        // Check current card owner
        ITerritoryCards cardContract = ITerritoryCards(cws.contractAddresses.territoryCards);
        address currentOwner = cardContract.ownerOf(cardTokenId);
        
        // Verify card is still in treasury
        if (currentOwner != ResourceHelper.getTreasuryAddress()) {
            revert CardNotInTreasury();
        }
        
        // Transfer card from treasury to colony controller
        address recipient = LibMeta.msgSender();
        
        // Execute transfer from treasury via special function
        // This requires ColonyTerritoryCards to have transferFromTreasury() with COLONY_WARS_ROLE
        cardContract.transferFromTreasury(cardTokenId, recipient);
        
        emit TerritoryCardClaimed(territoryId, cardTokenId, territory.controllingColony, recipient);
    }

    /**
     * @notice Reject Territory Card transfer request
     * @param territoryId Territory ID
     * @param rejectedAddress Address to reject
     * @param reason Rejection reason
     */
    function rejectCardTransfer(
        uint256 territoryId,
        address rejectedAddress,
        string calldata reason
    ) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (cws.contractAddresses.territoryCards == address(0)) {
            revert TerritoryCardsNotConfigured();
        }
        
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        if (!territory.active || territory.controllingColony == bytes32(0)) {
            revert TerritoryNotFound();
        }
        
        // Only territory controller can reject
        if (!ColonyHelper.isColonyCreator(territory.controllingColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not territory controller");
        }
        
        uint256 cardTokenId = cws.territoryToCard[territoryId];
        if (cardTokenId == 0) {
            revert TerritoryNotFound();
        }
        
        // Reject transfer on card contract
        ITerritoryCards(cws.contractAddresses.territoryCards).rejectTransfer(cardTokenId, rejectedAddress, reason);
        
        emit TerritoryCardTransferRejected(territoryId, cardTokenId, rejectedAddress, reason);
    }

    /**
     * @notice Check and forfeit territories with overdue maintenance
     */
    function checkMaintenanceForfeiture(uint256[] calldata territoryIds) external {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        for (uint256 i = 0; i < territoryIds.length && i < 50; i++) { // Limit batch size
            LibColonyWarsStorage.Territory storage territory = cws.territories[territoryIds[i]];
            
            if (territory.active && territory.controllingColony != bytes32(0)) {
                uint32 daysSincePayment = (uint32(block.timestamp) - territory.lastMaintenancePayment) / 86400;
                
                if (daysSincePayment >= 3) {
                    bytes32 previousOwner = territory.controllingColony;
                    
                    _removeTerritoryFromColony(territoryIds[i], territory.controllingColony, cws);
                    
                    territory.controllingColony = bytes32(0);
                    territory.lastMaintenancePayment = 0;
                    
                    emit TerritoryLost(territoryIds[i], previousOwner, "Maintenance overdue");
                }
            }
        }
    }

    /**
    * @notice Clean up season data and reset for new season
    * @param seasonId Season to clean up
    * @param resetTerritories Whether to reset all territory control
    * @param handleAllianceTreasuries How to handle alliance funds
    */
    function endWarsSeasonCleanup(
        uint32 seasonId, 
        bool resetTerritories,
        uint8 handleAllianceTreasuries // 0=leave, 1=return to leaders, 2=transfer to next season
    ) external onlyAuthorized {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Reset territories if requested
        if (resetTerritories) {
            for (uint256 i = 1; i <= cws.territoryCounter; i++) {
                LibColonyWarsStorage.Territory storage territory = cws.territories[i];
                if (territory.controllingColony != bytes32(0)) {
                    _removeTerritoryFromColony(i, territory.controllingColony, cws);
                    territory.controllingColony = bytes32(0);
                    territory.lastMaintenancePayment = 0;
                }
            }
        }
        
        // Handle alliance treasuries
        bytes32[] storage allianceIds = cws.seasonAlliances[seasonId];
        for (uint256 i = 0; i < allianceIds.length; i++) {
            LibColonyWarsStorage.Alliance storage alliance = cws.alliances[allianceIds[i]];
            
            if (alliance.sharedTreasury > 0) {
                if (handleAllianceTreasuries == 1) {
                    // Return to leader
                    address leaderAddress = hs.colonyCreators[alliance.leaderColony];
                    if (leaderAddress != address(0)) {
                        LibFeeCollection.transferFromTreasury(leaderAddress, alliance.sharedTreasury, "season_cleanup");
                    }
                    alliance.sharedTreasury = 0;
                } else if (handleAllianceTreasuries == 2) {
                    // Transfer to next season prize pool
                    uint32 nextSeason = seasonId + 1;
                    cws.seasons[nextSeason].prizePool += alliance.sharedTreasury;
                    alliance.sharedTreasury = 0;
                }
            }
            
            // Deactivate alliance
            alliance.active = false;
        }
        
        // Reset colony war profiles
        LibColonyWarsStorage.Season storage season = cws.seasons[seasonId];
        for (uint256 i = 0; i < season.registeredColonies.length; i++) {
            bytes32 colonyId = season.registeredColonies[i];
            delete cws.colonyWarProfiles[colonyId];
        }
    }













    // View functions for territory management and information

    /**
     * @notice Get territory bonus for colony
     */
    function getColonyTerritorialBonus(bytes32 colonyId) external view returns (uint256 totalBonus) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        uint256[] storage territories = cws.colonyTerritories[colonyId];
        totalBonus = 0;
        
        for (uint256 i = 0; i < territories.length; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[territories[i]];
            if (territory.active && territory.controllingColony == colonyId) {
                // Apply damage reduction
                uint256 baseBonus = territory.bonusValue;
                uint256 damageReduction = (baseBonus * territory.damageLevel) / 100;
                uint256 effectiveBonus = baseBonus - damageReduction;
                totalBonus += effectiveBonus;
            }
        }
        
        return totalBonus;
    }
    
    function getTerritoryInfo(uint256 territoryId) external view returns (LibColonyWarsStorage.Territory memory) {
        return LibColonyWarsStorage.colonyWarsStorage().territories[territoryId];
    }

    /**
     * @notice Get maintenance cost and time remaining for a territory
     * @param territoryId Territory to check
     * @return maintenanceCost Current maintenance cost in YELLOW tokens (with dynamic multipliers)
     * @return daysSincePayment Number of days since last maintenance payment
     * @return secondsUntilOverdue Seconds remaining until territory becomes capturable (0 if already overdue)
     * @return isOverdue Whether the territory is overdue for maintenance (can be captured)
     * @return baseFeePerDay Base maintenance fee per day (before multipliers)
     * @return stressMultiplier War stress multiplier (100 = 1x, 150 = 1.5x)
     * @return debtMultiplier Debt penalty multiplier (100 = 1x, 120 = 1.2x)
     */
    function getTerritoryMaintenanceInfo(uint256 territoryId)
        external
        view
        returns (
            uint256 maintenanceCost,
            uint32 daysSincePayment,
            uint256 secondsUntilOverdue,
            bool isOverdue,
            uint256 baseFeePerDay,
            uint256 stressMultiplier,
            uint256 debtMultiplier
        )
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];

        // Return zeros if territory doesn't exist or has no controller
        if (!territory.active || territory.controllingColony == bytes32(0)) {
            return (0, 0, 0, false, 0, 100, 100);
        }

        // Calculate days since last payment
        uint32 timeSincePayment = uint32(block.timestamp) - territory.lastMaintenancePayment;
        daysSincePayment = timeSincePayment / 86400;

        // Calculate seconds until overdue (maintenance due after 1 day, capturable after 2 days)
        // Territory becomes capturable when daysSincePayment > 1
        if (timeSincePayment < 2 days) {
            secondsUntilOverdue = 2 days - timeSincePayment;
            isOverdue = false;
        } else {
            secondsUntilOverdue = 0;
            isOverdue = true;
        }

        // Get fee configuration
        LibColonyWarsStorage.OperationFee storage maintenanceFee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_MAINTENANCE);
        baseFeePerDay = (maintenanceFee.baseAmount * maintenanceFee.multiplier) / 100;

        // Calculate dynamic multipliers
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[territory.controllingColony];
        stressMultiplier = 100 + (uint256(profile.warStress) * 5); // 100-150%
        debtMultiplier = 100;

        // Check if colony has unpaid debt
        if (cws.colonyDebts[territory.controllingColony].principalDebt > 0) {
            debtMultiplier = 120; // +20% penalty
        }

        // Calculate total maintenance cost if payment is due
        if (daysSincePayment > 0) {
            // Same formula as maintainTerritory: (days * stressMultiplier * debtMultiplier) / 10000
            uint256 adjustedQuantity = (uint256(daysSincePayment) * stressMultiplier * debtMultiplier) / 10000;
            if (adjustedQuantity == 0) adjustedQuantity = 1;

            // Final cost: (baseAmount * multiplier * adjustedQuantity) / 100
            maintenanceCost = (maintenanceFee.baseAmount * maintenanceFee.multiplier * adjustedQuantity) / 100;
        } else {
            maintenanceCost = 0;
        }
    }

    function getColonyTerritories(bytes32 colonyId) external view returns (uint256[] memory) {
        return LibColonyWarsStorage.colonyWarsStorage().colonyTerritories[colonyId];
    }

    /**
     * @notice Get all territories with current status
     * @return territoryIds Array of territory IDs
     * @return controllers Array of controlling colonies (bytes32(0) if unclaimed)
     * @return types Array of territory types
     * @return bonuses Array of bonus values
     * @return available Array indicating if territory is available for capture
     */
    function getAllTerritoryStates()
        external
        view
        returns (
            uint256[] memory territoryIds,
            bytes32[] memory controllers,
            uint8[] memory types,
            uint16[] memory bonuses,
            bool[] memory available
        )
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        uint256 totalTerritories = cws.territoryCounter;
        
        territoryIds = new uint256[](totalTerritories);
        controllers = new bytes32[](totalTerritories);
        types = new uint8[](totalTerritories);
        bonuses = new uint16[](totalTerritories);
        available = new bool[](totalTerritories);
        
        for (uint256 i = 1; i <= totalTerritories; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[i];
            
            territoryIds[i-1] = i;
            controllers[i-1] = territory.controllingColony;
            types[i-1] = territory.territoryType;
            bonuses[i-1] = territory.bonusValue;
            
            // Check if available (unclaimed or maintenance overdue)
            if (territory.controllingColony == bytes32(0)) {
                available[i-1] = true;
            } else {
                uint32 daysSincePayment = (uint32(block.timestamp) - territory.lastMaintenancePayment) / 86400;
                available[i-1] = daysSincePayment > 1;
            }
        }
    }

    /**
     * @notice Get comprehensive territory status overview
     * @return territories Array of all territory information with status
     */
    function getTerritoryStatuses()
        external
        view
        returns (TerritoryStatusInfo[] memory territories)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        uint256 totalTerritories = cws.territoryCounter;
        territories = new TerritoryStatusInfo[](totalTerritories);
        
        for (uint256 i = 1; i <= totalTerritories; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[i];
            
            // Determine territory status
            TerritoryStatus status;
            uint32 daysSincePayment = 0;
            
            if (!territory.active) {
                status = TerritoryStatus.INACTIVE;
            } else if (territory.controllingColony == bytes32(0)) {
                status = TerritoryStatus.FREE;
            } else {
                daysSincePayment = (uint32(block.timestamp) - territory.lastMaintenancePayment) / 86400;
                
                if (daysSincePayment == 0) {
                    status = TerritoryStatus.CONTROLLED_CURRENT;
                } else if (daysSincePayment == 1) {
                    status = TerritoryStatus.CONTROLLED_DUE;
                } else if (daysSincePayment == 2) {
                    status = TerritoryStatus.CONTROLLED_OVERDUE;
                } else {
                    status = TerritoryStatus.ABANDONED;
                }
            }
            
            territories[i-1] = TerritoryStatusInfo({
                territoryId: i,
                name: territory.name,
                territoryType: territory.territoryType,
                bonusValue: territory.bonusValue,
                controllingColony: territory.controllingColony,
                lastMaintenancePayment: territory.lastMaintenancePayment,
                daysSincePayment: daysSincePayment,
                status: status,
                canCapture: (status == TerritoryStatus.FREE || status == TerritoryStatus.ABANDONED),
                maintenanceCost: _calculateMaintenanceCost(daysSincePayment, cws)
            });
        }
    }

    /**
     * @notice Get only free territories
     * @return freeIds Array of free territory IDs
     * @return freeNames Array of free territory names
     */
    function getAvailableTerritories() 
        external 
        view 
        returns (uint256[] memory freeIds, string[] memory freeNames) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        uint256 maxTerritories = cws.territoryCounter;
        
        // Bardziej restrykcyjna walidacja
        if (maxTerritories == 0) {
            return (new uint256[](0), new string[](0));
        }
        
        // Jeśli wartość jest podejrzanie duża, sprawdź pierwszych kilka terytoriów
        if (maxTerritories > 100) {
            // Spróbuj znaleźć rzeczywistą liczbę przez sprawdzenie aktywności
            uint256 realCount = 0;
            for (uint256 i = 1; i <= 100; i++) {
                if (cws.territories[i].active) {
                    realCount = i;
                } else if (realCount > 0) {
                    break; // Znaleźliśmy koniec aktywnych terytoriów
                }
            }
            maxTerritories = realCount;
        }
        
        // Reszta kodu...
        uint256 freeCount = 0;
        for (uint256 i = 1; i <= maxTerritories; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[i];
            if (territory.active && _isTerritoryAvailable(territory)) {
                freeCount++;
            }
        }
        
        freeIds = new uint256[](freeCount);
        freeNames = new string[](freeCount);
        uint256 index = 0;
        
        for (uint256 i = 1; i <= maxTerritories; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[i];
            if (territory.active && _isTerritoryAvailable(territory)) {
                freeIds[index] = i;
                freeNames[index] = territory.name;
                index++;
            }
        }
    }

    function getTerritoryCounter() external view returns (uint256) {
        return LibColonyWarsStorage.colonyWarsStorage().territoryCounter;
    }

    /**
     * @notice Get territories controlled by specific colony
     * @param colonyId Colony to check
     * @return controlledIds Array of controlled territory IDs
     * @return totalBonus Sum of all bonuses from controlled territories
     */
    function getControlledTerritories(bytes32 colonyId)
        external
        view
        returns (uint256[] memory controlledIds, uint256 totalBonus)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        uint256[] storage territories = cws.colonyTerritories[colonyId];
        
        // Filter active controlled territories
        uint256 activeCount = 0;
        for (uint256 i = 0; i < territories.length; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[territories[i]];
            if (territory.active && territory.controllingColony == colonyId) {
                activeCount++;
                totalBonus += territory.bonusValue;
            }
        }
        
        controlledIds = new uint256[](activeCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < territories.length; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[territories[i]];
            if (territory.active && territory.controllingColony == colonyId) {
                controlledIds[index] = territories[i];
                index++;
            }
        }
    }

    /**
     * @notice Get territories at risk of abandonment
     * @return riskIds Array of territory IDs at risk
     * @return controllers Array of controlling colonies
     * @return daysOverdue Array of days since payment
     */
    function getTerritoriesAtRisk()
        external
        view
        returns (
            uint256[] memory riskIds,
            bytes32[] memory controllers,
            uint32[] memory daysOverdue
        )
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        // Count at-risk territories
        uint256 riskCount = 0;
        for (uint256 i = 1; i <= cws.territoryCounter; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[i];
            if (territory.active && territory.controllingColony != bytes32(0)) {
                uint32 daysSincePayment = (uint32(block.timestamp) - territory.lastMaintenancePayment) / 86400;
                if (daysSincePayment >= 1) {
                    riskCount++;
                }
            }
        }
        
        // Populate arrays
        riskIds = new uint256[](riskCount);
        controllers = new bytes32[](riskCount);
        daysOverdue = new uint32[](riskCount);
        uint256 index = 0;
        
        for (uint256 i = 1; i <= cws.territoryCounter; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[i];
            if (territory.active && territory.controllingColony != bytes32(0)) {
                uint32 daysSincePayment = (uint32(block.timestamp) - territory.lastMaintenancePayment) / 86400;
                if (daysSincePayment >= 1) {
                    riskIds[index] = i;
                    controllers[index] = territory.controllingColony;
                    daysOverdue[index] = daysSincePayment;
                    index++;
                }
            }
        }
    }

    /**
     * @notice Get territory defense bonus from fortifications
     */
    function getTerritoryDefenseBonus(uint256 territoryId) external view returns (uint16) {
        LibColonyWarsStorage.Territory storage territory = LibColonyWarsStorage.colonyWarsStorage().territories[territoryId];
        return territory.fortificationLevel * 5; // 5% per level
    }

    /**
     * @notice Get territory fortification status
     * @param territoryId Territory to check
     * @return fortificationLevel Current fortification level
     * @return zicoInvested Total ZICO invested in fortifications
     * @return defenseBonus Defense bonus percentage
     * @return maxPossible Maximum fortification possible (based on colony defense stake)
     */
    function getFortificationStatus(uint256 territoryId) 
        external 
        view 
        returns (
            uint16 fortificationLevel,
            uint256 zicoInvested,
            uint16 defenseBonus,
            uint256 maxPossible
        )
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        
        fortificationLevel = territory.fortificationLevel;
        zicoInvested = uint256(fortificationLevel) * 100 ether;
        defenseBonus = fortificationLevel * 5;
        
        if (territory.controllingColony != bytes32(0)) {
            LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[territory.controllingColony];
            maxPossible = profile.defensiveStake;
        } else {
            maxPossible = 0;
        }
    }

    /**
     * @notice Get expected rarity probabilities (view helper)
     * @return probabilities Array of probabilities in basis points [10000 = 100%]
     */
    function getRarityProbabilities() external pure returns (uint256[5] memory probabilities) {
        probabilities[uint8(Rarity.COMMON)] = 4900;      // 49%
        probabilities[uint8(Rarity.UNCOMMON)] = 3000;    // 30%
        probabilities[uint8(Rarity.RARE)] = 1500;        // 15%
        probabilities[uint8(Rarity.EPIC)] = 500;         // 5%
        probabilities[uint8(Rarity.LEGENDARY)] = 100;    // 1%
        return probabilities;
    }

    // ============================================================================
    // TERRITORY CARDS - DATA RETRIEVAL FROM COLLECTION CONTRACT
    // ============================================================================

    /**
     * @notice Get comprehensive card data from ColonyTerritoryCards collection
     * @dev Fetches all card traits directly from the NFT collection contract
     * @param cardTokenId Territory Card token ID
     * @return exists Whether the card exists
     * @return owner Current owner of the card
     * @return isActive Whether card is currently active (bound to territory)
     * @return assignedColonyId Colony ID the card is assigned to (0 if not assigned)
     * @return territoryType Territory type (0-4: ZicoMine, TradeHub, Fortress, Observatory, Sanctuary)
     * @return rarity Rarity level (0-4: Common, Uncommon, Rare, Epic, Legendary)
     * @return productionBonus Production bonus percentage
     * @return defenseBonus Defense bonus percentage
     * @return techLevel Technology level
     * @return specimenPopulation Specimen/chicken population
     * @return colonyWarsType Colony Wars compatible type (1-5)
     */
    function getTerritoryCardData(uint256 cardTokenId)
        external
        view
        returns (
            bool exists,
            address owner,
            bool isActive,
            uint256 assignedColonyId,
            uint8 territoryType,
            uint8 rarity,
            uint8 productionBonus,
            uint8 defenseBonus,
            uint8 techLevel,
            uint16 specimenPopulation,
            uint8 colonyWarsType
        )
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        // Check if Territory Cards contract is configured
        if (cws.contractAddresses.territoryCards == address(0)) {
            return (false, address(0), false, 0, 0, 0, 0, 0, 0, 0, 0);
        }

        ITerritoryCards cardContract = ITerritoryCards(cws.contractAddresses.territoryCards);

        // Try to get owner - if this fails, card doesn't exist
        try cardContract.ownerOf(cardTokenId) returns (address cardOwner) {
            exists = true;
            owner = cardOwner;
        } catch {
            return (false, address(0), false, 0, 0, 0, 0, 0, 0, 0, 0);
        }

        // Get card active status
        isActive = cardContract.isTerritoryActive(cardTokenId);

        // Get assigned colony ID from card contract
        assignedColonyId = cardContract.getAssignedColony(cardTokenId);

        // Get full card traits from ColonyTerritoryCards
        ITerritoryCards.TerritoryTraits memory traits = cardContract.getTerritoryTraits(cardTokenId);

        territoryType = traits.territoryType;
        rarity = traits.rarity;
        productionBonus = traits.productionBonus;
        defenseBonus = traits.defenseBonus;
        techLevel = traits.techLevel;
        specimenPopulation = traits.specimenPopulation;
        colonyWarsType = traits.colonyWarsType;
    }

    /**
     * @notice Get card data by territory ID (reverse lookup)
     * @dev Finds card associated with territory and returns its data
     * @param territoryId Territory ID
     * @return cardTokenId Associated card token ID (0 if none)
     * @return exists Whether the card exists
     * @return owner Current owner of the card
     * @return traits Card traits from collection contract
     */
    function getCardDataByTerritoryId(uint256 territoryId)
        external
        view
        returns (
            uint256 cardTokenId,
            bool exists,
            address owner,
            ITerritoryCards.TerritoryTraits memory traits
        )
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        cardTokenId = cws.territoryToCard[territoryId];

        if (cardTokenId == 0 || cws.contractAddresses.territoryCards == address(0)) {
            return (0, false, address(0), traits);
        }

        ITerritoryCards cardContract = ITerritoryCards(cws.contractAddresses.territoryCards);

        try cardContract.ownerOf(cardTokenId) returns (address cardOwner) {
            exists = true;
            owner = cardOwner;
            traits = cardContract.getTerritoryTraits(cardTokenId);
        } catch {
            exists = false;
        }
    }

    // Internal functions

    function _calculateMaintenanceCost(uint32 period, LibColonyWarsStorage.ColonyWarsStorage storage cws) 
        internal 
        view 
        returns (uint256) 
    {
        if (period == 0) return 0;
        return cws.config.dailyMaintenanceCost * period;
    }
    
    function _isTerritoryAvailable(LibColonyWarsStorage.Territory storage territory) internal view returns (bool) {
        if (territory.controllingColony == bytes32(0)) {
            return true; // Unclaimed
        }
        
        uint32 daysSincePayment = (uint32(block.timestamp) - territory.lastMaintenancePayment) / 86400;
        return daysSincePayment >= 3; // Zmień z > 1 na >= 3
    }

    /**
     * @notice Count active territories controlled by a colony
     * @param colonyId Colony to count territories for
     * @param cws Colony wars storage reference
     * @return count Number of active territories
     */
    function _countActiveColonyTerritories(
        bytes32 colonyId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal view returns (uint256 count) {
        uint256[] storage territoryIds = cws.colonyTerritories[colonyId];
        count = 0;
        
        for (uint256 i = 0; i < territoryIds.length; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[territoryIds[i]];
            if (territory.active && territory.controllingColony == colonyId) {
                count++;
            }
        }
        
        return count;
    }

    /**
     * @notice Remove territory from colony's territory list
     * @param territoryId Territory to remove
     * @param colonyId Colony to remove from
     * @param cws Colony wars storage reference
     */
    function _removeTerritoryFromColony(
        uint256 territoryId,
        bytes32 colonyId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        uint256[] storage territoryIds = cws.colonyTerritories[colonyId];
        
        for (uint256 i = 0; i < territoryIds.length; i++) {
            if (territoryIds[i] == territoryId) {
                // Move last element to current position and remove last
                territoryIds[i] = territoryIds[territoryIds.length - 1];
                territoryIds.pop();
                break;
            }
        }
    }

    /**
     * @notice Cancel all active sieges for a territory (force delete helper)
     * @param territoryId Territory to cancel sieges for
     * @param cws Colony wars storage reference
     */
    function _cancelAllTerritorySieges(
        uint256 territoryId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        bytes32[] storage siegeIds = cws.territoryActiveSieges[territoryId];
        
        for (uint256 i = 0; i < siegeIds.length; i++) {
            bytes32 siegeId = siegeIds[i];
            LibColonyWarsStorage.TerritorySiege storage siege = cws.territorySieges[siegeId];
            
            // Mark siege as cancelled and resolved
            siege.siegeState = 3; // CANCELLED
            siege.winner = bytes32(0);
            cws.siegeResolved[siegeId] = true;
            
            // Release tokens
            for (uint256 j = 0; j < siege.attackerTokens.length; j++) {
                LibColonyWarsStorage.releaseToken(siege.attackerTokens[j]);
            }
            if (siege.defenderTokens.length > 0) {
                for (uint256 j = 0; j < siege.defenderTokens.length; j++) {
                    LibColonyWarsStorage.releaseToken(siege.defenderTokens[j]);
                }
            }
            
            // Remove from global active sieges
            bytes32[] storage activeSieges = cws.activeSieges;
            for (uint256 j = 0; j < activeSieges.length; j++) {
                if (activeSieges[j] == siegeId) {
                    activeSieges[j] = activeSieges[activeSieges.length - 1];
                    activeSieges.pop();
                    break;
                }
            }
        }
        
        // Clear territory's siege list
        delete cws.territoryActiveSieges[territoryId];
    }



    // ============================================================================
    // INTERNAL HELPERS - TERRITORY CARDS INTEGRATION
    // ============================================================================

    /**
     * @notice Mint Territory Card
     * @param territoryId Game territory ID
     * @param territoryType Type of territory (1-5)
     * @param bonusValue Bonus value (1-100)
     * @param recipient Initial recipient (treasury)
     * @param cws Storage reference
     * @return cardTokenId Minted card token ID
     */
    function _mintTerritoryCard(
        uint256 territoryId,
        uint8 territoryType,
        uint16 bonusValue,
        address recipient,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal returns (uint256 cardTokenId) {
        // Calculate rarity based on bonus value
        // Calculate rarity AND bonus together
        (uint8 rarity, uint16 actualBonus) = _calculateRarityWithBonus(
            territoryId,
            territoryType,
            recipient
        );
        
        // Use actualBonus instead of passed bonusValue
        bonusValue = actualBonus;
        
        // Calculate card stats
        uint16 productionBonus = _calculateProductionBonus(territoryType, bonusValue);
        uint16 defenseBonus = _calculateDefenseBonus(territoryType, bonusValue);
        uint8 techLevel = _calculateTechLevel(territoryType, rarity);
        uint16 chickenPopulation = _calculateChickenPopulation(territoryType, bonusValue);
        
        // Mint card
        cardTokenId = ITerritoryCards(cws.contractAddresses.territoryCards).mintTerritory(
            recipient,
            territoryType,
            rarity,
            productionBonus,
            defenseBonus,
            techLevel,
            chickenPopulation
        );
        
        // Store mapping
        cws.territoryToCard[territoryId] = cardTokenId;
        cws.cardToTerritory[cardTokenId] = territoryId;
        
        return cardTokenId;
    }

    /**
     * @notice Activate Territory Card (assign to colony)
     * @param cardTokenId Card token ID
     * @param colonyId Colony ID to assign to
     * @param cws Storage reference
     */
    function _activateTerritoryCard(
        uint256,
        uint256 cardTokenId,
        bytes32 colonyId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        // Convert colonyId to uint256 for card contract
        uint256 colonyIdUint = uint256(colonyId);
        
        // Activate card
        ITerritoryCards(cws.contractAddresses.territoryCards).assignToColony(cardTokenId, colonyIdUint);
    }

    /**
     * @notice Deactivate Territory Card
     * @param cardTokenId Card token ID
     * @param cws Storage reference
     */
    function _deactivateTerritoryCard(
        uint256,
        uint256 cardTokenId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        ITerritoryCards(cws.contractAddresses.territoryCards).deactivateTerritory(cardTokenId);
    }

    // ============================================================================
    // INTERNAL HELPERS - CARD STATS CALCULATION
    // ============================================================================

    /**
     * @notice Calculate rarity using weighted pseudo-random algorithm
     * @dev CRITICAL: This function MUST produce identical results in both contracts
     * 
     * ENTROPY SOURCES (in order of importance):
     * 1. block.prevrandao - Primary entropy (beacon chain randomness)
     * 2. territoryId - Ensures different territories get different rarities
     * 3. minter address - Prevents front-running by making user-specific
     * 4. block.timestamp - Additional entropy layer
     * 5. territoryType - Influences seed diversification
     * 
     * @param territoryId Unique territory identifier
     * @param territoryType Type of territory (1-5)
     * @param minter Address minting the territory
     * @return rarity Calculated rarity tier (0-4)
     */
    function _calculateRarity(
        uint256 territoryId,
        uint8 territoryType,
        address minter
    ) internal view returns (uint8 rarity) {
        // Step 1: Generate pseudo-random seed
        // Using multiple entropy sources makes manipulation extremely difficult
        uint256 randomSeed = uint256(
            keccak256(
                abi.encodePacked(
                    block.prevrandao,      // Primary entropy (replaces difficulty)
                    territoryId,           // Unique per territory
                    minter,                // User-specific
                    block.timestamp,       // Time-based entropy
                    territoryType,         // Type-based variation
                    block.number           // Additional block data
                )
            )
        );
        
        // Step 2: Normalize to 0-9999 range
        uint256 roll = randomSeed % 10000;
        
        // Step 3: Map to rarity tier using weighted thresholds
        if (roll < LEGENDARY_THRESHOLD) {
            return uint8(Rarity.LEGENDARY);  // 1%
        } else if (roll < EPIC_THRESHOLD) {
            return uint8(Rarity.EPIC);       // 5%
        } else if (roll < RARE_THRESHOLD) {
            return uint8(Rarity.RARE);       // 15%
        } else if (roll < UNCOMMON_THRESHOLD) {
            return uint8(Rarity.UNCOMMON);   // 30%
        } else {
            return uint8(Rarity.COMMON);     // 49%
        }
    }

    /**
     * @notice Calculate rarity with bonus percentage based on rarity tier
     * @dev Each rarity tier gets a range of possible bonus values
     * 
     * BONUS RANGES (inspired by Axie Infinity stat ranges):
     * - LEGENDARY: 76-100 (top 25% of bonus spectrum)
     * - EPIC: 51-75 (upper mid range)
     * - RARE: 26-50 (mid range)
     * - UNCOMMON: 11-25 (lower mid range)  
     * - COMMON: 1-10 (base range)
     * 
     * @param territoryId Unique territory identifier
     * @param territoryType Type of territory (1-5)
     * @param minter Address minting the territory
     * @return rarity Rarity tier (0-4)
     * @return bonusValue Bonus percentage (1-100)
     */
    function _calculateRarityWithBonus(
        uint256 territoryId,
        uint8 territoryType,
        address minter
    ) internal view returns (uint8 rarity, uint16 bonusValue) {
        // Calculate rarity tier
        rarity = _calculateRarity(territoryId, territoryType, minter);
        
        // Generate bonus value seed (different from rarity seed)
        uint256 bonusSeed = uint256(
            keccak256(
                abi.encodePacked(
                    block.prevrandao,
                    territoryId,
                    minter,
                    "BONUS",  // Different namespace
                    block.timestamp
                )
            )
        );
        
        // Map rarity to bonus range
        if (rarity == uint8(Rarity.LEGENDARY)) {
            bonusValue = uint16(38 + (bonusSeed % 13));  // 38-50
        } else if (rarity == uint8(Rarity.EPIC)) {
            bonusValue = uint16(26 + (bonusSeed % 13));  // 26-38
        } else if (rarity == uint8(Rarity.RARE)) {
            bonusValue = uint16(13 + (bonusSeed % 13));  // 13-25
        } else if (rarity == uint8(Rarity.UNCOMMON)) {
            bonusValue = uint16(6 + (bonusSeed % 8));    // 6-13
        } else { // COMMON
            bonusValue = uint16(1 + (bonusSeed % 5));    // 1-5
        }
        
        return (rarity, bonusValue);
    }
    
    /**
     * @notice Get rarity name string (view helper)
     * @param rarity Rarity tier (0-4)
     * @return name Human-readable rarity name
     */
    function _getRarityName(uint8 rarity) internal pure returns (string memory) {
        if (rarity == uint8(Rarity.LEGENDARY)) return "Legendary";
        if (rarity == uint8(Rarity.EPIC)) return "Epic";
        if (rarity == uint8(Rarity.RARE)) return "Rare";
        if (rarity == uint8(Rarity.UNCOMMON)) return "Uncommon";
        return "Common";
    }

    /**
     * @notice Calculate production bonus based on territory type and base bonus
     */
    function _calculateProductionBonus(uint8 territoryType, uint16 bonusValue) internal pure returns (uint16) {
        // Type 1 (ZICO Mine) gets full production bonus
        if (territoryType == 1) return bonusValue;
        // Type 2 (Trade Hub) gets 75% production bonus
        if (territoryType == 2) return (bonusValue * 75) / 100;
        // Others get base bonus
        return bonusValue / 2;
    }

    /**
     * @notice Calculate defense bonus based on territory type and base bonus
     */
    function _calculateDefenseBonus(uint8 territoryType, uint16 bonusValue) internal pure returns (uint16) {
        // Type 3 (Fortress) gets full defense bonus
        if (territoryType == 3) return bonusValue;
        // Type 5 (Sanctuary) gets 75% defense bonus
        if (territoryType == 5) return (bonusValue * 75) / 100;
        // Others get base bonus
        return bonusValue / 2;
    }

    /**
     * @notice Calculate tech level based on territory type and rarity
     */
    function _calculateTechLevel(uint8 territoryType, uint8 rarity) internal pure returns (uint8) {
        // Type 4 (Observatory) gets bonus tech level
        if (territoryType == 4) {
            return uint8(1 + rarity); // 1-4
        }
        // Others based on rarity
        return rarity; // 0-3
    }

    /**
     * @notice Calculate chicken population based on territory type and bonus
     */
    function _calculateChickenPopulation(uint8 territoryType, uint16 bonusValue) internal pure returns (uint16) {
        // Type 5 (Sanctuary) gets highest population
        if (territoryType == 5) {
            return bonusValue * 10; // 10-1000
        }
        // Type 2 (Trade Hub) gets medium population
        if (territoryType == 2) {
            return bonusValue * 5; // 5-500
        }
        // Others get base population
        return bonusValue * 2; // 2-200
    }

    // ============================================================================
    // INTERNAL HELPERS - USER MINTING
    // ============================================================================

    /**
     * @notice Calculate mint price for territory card
     * @dev Base price varies by type, influenced by pseudo-rarity
     */
    function _calculateMintPrice(uint8 territoryType) internal pure returns (uint256) {
        // Base prices by type (in ZICO)
        uint256 basePrice;
        
        if (territoryType == 1) {
            basePrice = 5000 ether; // ZICO Mine
        } else if (territoryType == 2) {
            basePrice = 6000 ether; // Trade Hub
        } else if (territoryType == 3) {
            basePrice = 7000 ether; // Fortress
        } else if (territoryType == 4) {
            basePrice = 8000 ether; // Observatory
        } else if (territoryType == 5) {
            basePrice = 9000 ether; // Sanctuary
        } else {
            basePrice = 5000 ether;
        }
        
        return basePrice;
    }

    /**
     * @notice Generate pseudo-random bonus value
     * @dev Simple on-chain randomness - use Chainlink VRF for production
     */
    function _generateRandomBonus(
        uint256 territoryId,
        uint8 territoryType  
    ) internal view returns (uint16) {
        (, uint16 bonusValue) = _calculateRarityWithBonus(
            territoryId,
            territoryType,
            LibMeta.msgSender()
        );
        return bonusValue;
    }
 
    /**
     * @notice Generate territory name based on type and ID
     */
    function _generateTerritoryName(
        uint8 territoryType,
        uint256 territoryId
    ) internal pure returns (string memory) {
        string memory prefix;
        
        if (territoryType == 1) {
            prefix = "ZICO Mine";
        } else if (territoryType == 2) {
            prefix = "Trade Hub";
        } else if (territoryType == 3) {
            prefix = "Fortress";
        } else if (territoryType == 4) {
            prefix = "Observatory";
        } else if (territoryType == 5) {
            prefix = "Sanctuary";
        } else {
            prefix = "Territory";
        }
        
        return string(abi.encodePacked(prefix, " #", _toString(territoryId)));
    }

    /**
     * @notice Convert uint to string
     */
    function _toString(uint256 value) internal pure returns (string memory) {
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

    /**
     * @notice Get territory type from card NFT
     * @dev Requires getTerritoryType() function in ITerritoryCards interface
     * @param cardTokenId Card token ID
     * @param cardContract Territory Cards contract reference
     * @return territoryType Type of territory (1-5)
     */
    function _getCardType(
        uint256 cardTokenId,
        ITerritoryCards cardContract
    ) internal view returns (uint8) {
        // This requires adding getTerritoryType(uint256) to ITerritoryCards interface
        // For now, we'll need to add this to the interface at top of contract
        return cardContract.getTerritoryType(cardTokenId);
    }
}

