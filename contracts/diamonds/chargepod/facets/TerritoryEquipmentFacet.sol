// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import { LibColonyWarsStorage } from "../libraries/LibColonyWarsStorage.sol";
import { AccessControlBase } from "./AccessControlBase.sol";
import { IColonyInfrastructureCards } from "../interfaces/IColonyInfrastructureCards.sol";
import { ResourceHelper } from "../libraries/ResourceHelper.sol";

/**
 * @title TerritoryEquipmentFacet
 * @notice Manages Infrastructure NFT equipment on territories
 * @dev Equips Infrastructure Cards to territories for production/defense bonuses
 */
contract TerritoryEquipmentFacet is AccessControlBase {
    using LibColonyWarsStorage for LibColonyWarsStorage.ColonyWarsStorage;

    // Custom Errors
    error TerritoryNotOwned();
    error InfrastructureNotOwned();
    error InfrastructureAlreadyEquipped();
    error InfrastructureNotEquipped();
    error MaxEquipmentSlotsReached();
    error InvalidInfrastructureType();
    error InsufficientTechLevel();
    error TerritoryNotActive();
    error InfraContractNotSet();
    error InfraMaxSupplyReached();

    // Events
    event InfraCardMinted(uint256 indexed tokenId, address indexed recipient, uint8 infraType, uint8 rarity);
    event InfrastructureEquipped(
        uint256 indexed territoryId,
        uint256 indexed infraTokenId,
        uint8 infraType,
        uint16 productionBonus,
        uint16 defenseBonus
    );
    event InfrastructureUnequipped(uint256 indexed territoryId, uint256 indexed infraTokenId);
    event TerritoryBonusesRecalculated(
        uint256 indexed territoryId,
        uint16 totalProduction,
        uint16 totalDefense,
        uint8 totalTech
    );

    // Constants
    uint8 constant MAX_EQUIPMENT_SLOTS = 4;
    uint8 constant TYPE_RESEARCH_LAB = 4;

    // Internal struct to reduce stack variables
    struct EquipmentParams {
        uint8 infraType;
        uint8 territoryType;
        uint16 productionBonus;
        uint16 defenseBonus;
    }

    // Rarity thresholds (out of 10000)
    uint256 private constant LEGENDARY_THRESHOLD = 100;   // 1%
    uint256 private constant EPIC_THRESHOLD = 600;        // 5%
    uint256 private constant RARE_THRESHOLD = 2100;       // 15%
    uint256 private constant UNCOMMON_THRESHOLD = 5100;   // 30%

    // ==================== PUBLIC MINT FUNCTIONS ====================

    /**
     * @notice Mint Infrastructure Card (public sale)
     * @param infraType Infrastructure type (0-5)
     * @return tokenId Minted token ID
     */
    function mintInfraCard(uint8 infraType) external payable whenNotPaused nonReentrant returns (uint256 tokenId) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        address infraAddr = cws.contractAddresses.infrastructureCards;
        if (infraAddr == address(0)) revert InfraContractNotSet();
        if (infraType > 5) revert InvalidInfrastructureType();

        IColonyInfrastructureCards infraContract = IColonyInfrastructureCards(infraAddr);

        // Check supply
        if (infraContract.totalSupply() >= infraContract.maxSupply()) revert InfraMaxSupplyReached();

        // Calculate price and collect payment (supports native/ERC20 with discount)
        uint256 price = _calculateInfraPrice(infraType);
        ResourceHelper.collectCardMintFee(LibMeta.msgSender(), price, "infra_card_mint");

        // Calculate rarity
        uint8 rarity = _calculateRarity(block.timestamp, infraType, LibMeta.msgSender());

        // Mint to user
        tokenId = infraContract.mintInfrastructure(
            LibMeta.msgSender(),
            IColonyInfrastructureCards.InfrastructureType(infraType),
            IColonyInfrastructureCards.Rarity(rarity)
        );

        emit InfraCardMinted(tokenId, LibMeta.msgSender(), infraType, rarity);
    }

    /**
     * @notice Mint Infrastructure Card and auto-equip to territory
     * @param infraType Infrastructure type (0-5)
     * @param territoryId Territory to equip to
     * @return tokenId Minted token ID
     */
    function mintInfraCardFor(uint8 infraType, uint256 territoryId) external payable whenNotPaused nonReentrant returns (uint256 tokenId) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        address infraAddr = cws.contractAddresses.infrastructureCards;
        if (infraAddr == address(0)) revert InfraContractNotSet();
        if (infraType > 5) revert InvalidInfrastructureType();

        // Verify territory ownership
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        if (!territory.active) revert TerritoryNotActive();

        bytes32 colonyId = cws.userToColony[LibMeta.msgSender()];
        if (territory.controllingColony != colonyId) revert TerritoryNotOwned();

        // Check equipment slots
        if (cws.territoryEquipment[territoryId].equippedInfraIds.length >= MAX_EQUIPMENT_SLOTS) {
            revert MaxEquipmentSlotsReached();
        }

        IColonyInfrastructureCards infraContract = IColonyInfrastructureCards(infraAddr);

        // Check supply
        if (infraContract.totalSupply() >= infraContract.maxSupply()) revert InfraMaxSupplyReached();

        // Calculate price and collect payment (supports native/ERC20 with discount)
        uint256 price = _calculateInfraPrice(infraType);
        ResourceHelper.collectCardMintFee(LibMeta.msgSender(), price, "infra_card_mint_equip");

        // Calculate rarity
        uint8 rarity = _calculateRarity(block.timestamp, infraType, LibMeta.msgSender());

        // Mint to user
        tokenId = infraContract.mintInfrastructure(
            LibMeta.msgSender(),
            IColonyInfrastructureCards.InfrastructureType(infraType),
            IColonyInfrastructureCards.Rarity(rarity)
        );

        emit InfraCardMinted(tokenId, LibMeta.msgSender(), infraType, rarity);

        // Auto-equip
        EquipmentParams memory params = _validateAndGetEquipParams(territoryId, tokenId);
        _applyEquipment(territoryId, tokenId, params);
    }

    // ==================== EQUIPMENT FUNCTIONS ====================

    /**
     * @notice Equip infrastructure to territory
     * @param territoryId Territory to equip
     * @param infraTokenId Infrastructure NFT token ID
     */
    function equipInfrastructure(uint256 territoryId, uint256 infraTokenId) external whenNotPaused nonReentrant {
        // Validate and get params (reduces stack depth)
        EquipmentParams memory params = _validateAndGetEquipParams(territoryId, infraTokenId);
        
        // Apply equipment
        _applyEquipment(territoryId, infraTokenId, params);
    }

    /**
     * @notice Internal: Validate equip request and return params
     */
    function _validateAndGetEquipParams(
        uint256 territoryId, 
        uint256 infraTokenId
    ) internal view returns (EquipmentParams memory params) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        // Get infrastructure contract
        address infraAddr = cws.contractAddresses.infrastructureCards;
        if (infraAddr == address(0)) revert InfraContractNotSet();
        IColonyInfrastructureCards infraContract = IColonyInfrastructureCards(infraAddr);
        
        // Verify territory
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        if (!territory.active) revert TerritoryNotActive();
        
        bytes32 colonyId = cws.userToColony[LibMeta.msgSender()];
        if (territory.controllingColony != colonyId) revert TerritoryNotOwned();
        
        // Verify infrastructure ownership
        if (infraContract.ownerOf(infraTokenId) != LibMeta.msgSender()) revert InfrastructureNotOwned();
        
        // Check not already equipped
        if (cws.infraEquippedToTerritory[infraTokenId] != 0) revert InfrastructureAlreadyEquipped();
        
        // Check slots
        if (cws.territoryEquipment[territoryId].equippedInfraIds.length >= MAX_EQUIPMENT_SLOTS) {
            revert MaxEquipmentSlotsReached();
        }
        
        // Get traits and calculate bonuses
        IColonyInfrastructureCards.InfrastructureTraits memory traits = infraContract.getTraits(infraTokenId);
        
        // Tech level check
        if (territory.territoryType > 0 && traits.techLevel > 8) revert InsufficientTechLevel();
        
        params.infraType = uint8(traits.infraType);
        params.territoryType = territory.territoryType;
        
        (params.productionBonus, params.defenseBonus) = _calculateInfrastructureBonuses(
            params.infraType,
            uint8(traits.rarity),
            traits.efficiencyBonus,
            params.territoryType
        );
    }

    /**
     * @notice Internal: Apply equipment after validation
     */
    function _applyEquipment(
        uint256 territoryId,
        uint256 infraTokenId,
        EquipmentParams memory params
    ) internal {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.TerritoryEquipment storage equipment = cws.territoryEquipment[territoryId];
        IColonyInfrastructureCards infraContract = IColonyInfrastructureCards(cws.contractAddresses.infrastructureCards);

        // Mark infrastructure as equipped on NFT contract (blocks transfers)
        infraContract.equipToColony(infraTokenId, territoryId);

        // Update equipment tracking in Diamond storage
        equipment.equippedInfraIds.push(infraTokenId);
        equipment.totalProductionBonus += params.productionBonus;
        equipment.totalDefenseBonus += params.defenseBonus;
        if (params.infraType == TYPE_RESEARCH_LAB) {
            equipment.totalTechBonus += 1;
        }
        equipment.lastEquipmentUpdate = uint32(block.timestamp);

        cws.infraEquippedToTerritory[infraTokenId] = territoryId;

        emit InfrastructureEquipped(territoryId, infraTokenId, params.infraType, params.productionBonus, params.defenseBonus);
    }

    /**
     * @notice Unequip infrastructure from territory
     * @param territoryId Territory to unequip from
     * @param infraTokenId Infrastructure NFT token ID
     */
    function unequipInfrastructure(uint256 territoryId, uint256 infraTokenId) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        // Verify ownership
        bytes32 colonyId = cws.userToColony[LibMeta.msgSender()];
        if (cws.territories[territoryId].controllingColony != colonyId) revert TerritoryNotOwned();

        // Verify equipped
        if (cws.infraEquippedToTerritory[infraTokenId] != territoryId) revert InfrastructureNotEquipped();

        IColonyInfrastructureCards infraContract = IColonyInfrastructureCards(cws.contractAddresses.infrastructureCards);

        // Unequip from colony on NFT contract (unblocks transfers)
        infraContract.unequipFromColony(infraTokenId);

        // Remove from Diamond storage tracking
        _removeFromEquippedList(territoryId, infraTokenId);
        _recalculateTerritoryBonuses(territoryId);
        delete cws.infraEquippedToTerritory[infraTokenId];

        emit InfrastructureUnequipped(territoryId, infraTokenId);
    }

    /**
     * @notice Internal: Remove token from equipped list
     */
    function _removeFromEquippedList(uint256 territoryId, uint256 infraTokenId) internal {
        LibColonyWarsStorage.TerritoryEquipment storage equipment = 
            LibColonyWarsStorage.colonyWarsStorage().territoryEquipment[territoryId];
        
        uint256 length = equipment.equippedInfraIds.length;
        for (uint256 i = 0; i < length; i++) {
            if (equipment.equippedInfraIds[i] == infraTokenId) {
                equipment.equippedInfraIds[i] = equipment.equippedInfraIds[length - 1];
                equipment.equippedInfraIds.pop();
                break;
            }
        }
    }

    /**
     * @notice Get territory equipment info
     */
    function getTerritoryEquipment(uint256 territoryId) 
        external 
        view 
        returns (LibColonyWarsStorage.TerritoryEquipment memory) 
    {
        return LibColonyWarsStorage.colonyWarsStorage().territoryEquipment[territoryId];
    }

    /**
     * @notice Get enhanced territory bonuses (base + equipment)
     */
    function getTerritoryEnhancedBonuses(uint256 territoryId) 
        external 
        view 
        returns (uint16 productionBonus, uint16 defenseBonus, uint8 techBonus) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        LibColonyWarsStorage.TerritoryEquipment storage equipment = cws.territoryEquipment[territoryId];
        
        productionBonus = territory.bonusValue + equipment.totalProductionBonus;
        defenseBonus = territory.fortificationLevel + equipment.totalDefenseBonus;
        techBonus = equipment.totalTechBonus;
    }

    /**
     * @notice Recalculate territory bonuses after equipment change
     */
    function _recalculateTerritoryBonuses(uint256 territoryId) internal {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.TerritoryEquipment storage equipment = cws.territoryEquipment[territoryId];
        uint8 territoryType = cws.territories[territoryId].territoryType;
        
        // Reset
        equipment.totalProductionBonus = 0;
        equipment.totalDefenseBonus = 0;
        equipment.totalTechBonus = 0;
        
        // Recalculate
        IColonyInfrastructureCards infraContract = IColonyInfrastructureCards(cws.contractAddresses.infrastructureCards);
        
        for (uint256 i = 0; i < equipment.equippedInfraIds.length; i++) {
            _addInfraBonuses(equipment, infraContract, equipment.equippedInfraIds[i], territoryType);
        }
        
        equipment.lastEquipmentUpdate = uint32(block.timestamp);
        
        emit TerritoryBonusesRecalculated(
            territoryId,
            equipment.totalProductionBonus,
            equipment.totalDefenseBonus,
            equipment.totalTechBonus
        );
    }

    /**
     * @notice Internal: Add bonuses from single infrastructure
     */
    function _addInfraBonuses(
        LibColonyWarsStorage.TerritoryEquipment storage equipment,
        IColonyInfrastructureCards infraContract,
        uint256 infraTokenId,
        uint8 territoryType
    ) internal {
        IColonyInfrastructureCards.InfrastructureTraits memory traits = infraContract.getTraits(infraTokenId);
        
        (uint16 prodBonus, uint16 defBonus) = _calculateInfrastructureBonuses(
            uint8(traits.infraType),
            uint8(traits.rarity),
            traits.efficiencyBonus,
            territoryType
        );
        
        equipment.totalProductionBonus += prodBonus;
        equipment.totalDefenseBonus += defBonus;
        if (uint8(traits.infraType) == TYPE_RESEARCH_LAB) {
            equipment.totalTechBonus += 1;
        }
    }

    /**
     * @notice Calculate bonuses from infrastructure
     */
    function _calculateInfrastructureBonuses(
        uint8 infraType,
        uint8 rarity,
        uint8 efficiency,
        uint8 territoryType
    ) internal pure returns (uint16 productionBonus, uint16 defenseBonus) {
        // Base bonus from efficiency (0-25%)
        uint16 baseBonus = uint16(efficiency) / 4;
        
        // Rarity multiplier
        baseBonus = (baseBonus * (100 + rarity * 50)) / 100;
        
        // Type-specific bonuses
        if (infraType <= 2) {
            // Production types (0-2)
            productionBonus = baseBonus;
            // Synergy bonus for matching territory
            if ((infraType == 0 && territoryType == 1) || // Mining on mines
                (infraType == 2 && territoryType == 2)) { // Processing on trade hubs
                productionBonus = (productionBonus * 150) / 100;
            }
        } else if (infraType == 3) {
            // Defense turret
            defenseBonus = baseBonus;
            if (territoryType == 3) defenseBonus = (defenseBonus * 150) / 100;
        } else if (infraType == 4) {
            // Research lab
            productionBonus = territoryType == 4 ? baseBonus : baseBonus / 2;
        } else {
            // Storage
            productionBonus = baseBonus / 4;
            defenseBonus = baseBonus / 4;
        }
    }

    // ==================== PRICING & RARITY ====================

    /**
     * @notice Calculate mint price for infrastructure type
     * @dev Uses configured price if set, otherwise falls back to defaults
     */
    function _calculateInfraPrice(uint8 infraType) internal view returns (uint256) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        // Use configured price if initialized
        if (cws.cardMintPricing.initialized && cws.cardMintPricing.infrastructurePrices[infraType] > 0) {
            return cws.cardMintPricing.infrastructurePrices[infraType];
        }

        // Fallback to defaults
        if (infraType == 0) return 800 ether;   // MiningDrill
        if (infraType == 1) return 1000 ether;  // EnergyHarvester
        if (infraType == 2) return 1200 ether;  // ProcessingPlant
        if (infraType == 3) return 1500 ether;  // DefenseTurret
        if (infraType == 4) return 2000 ether;  // ResearchLab
        return 600 ether;                        // StorageFacility
    }

    /**
     * @notice Calculate rarity based on pseudo-random seed
     */
    function _calculateRarity(uint256 seed, uint8 itemType, address minter) internal view returns (uint8) {
        uint256 randomSeed = uint256(keccak256(abi.encodePacked(
            block.prevrandao,
            seed,
            minter,
            block.timestamp,
            itemType,
            block.number
        )));

        uint256 roll = randomSeed % 10000;

        if (roll < LEGENDARY_THRESHOLD) return 4;  // Legendary
        if (roll < EPIC_THRESHOLD) return 3;       // Epic
        if (roll < RARE_THRESHOLD) return 2;       // Rare
        if (roll < UNCOMMON_THRESHOLD) return 1;   // Uncommon
        return 0;                                   // Common
    }

    /**
     * @notice Get mint price for infrastructure type
     */
    function getInfraPrice(uint8 infraType) external view returns (uint256) {
        return _calculateInfraPrice(infraType);
    }

    // ==================== INFRASTRUCTURE USAGE ====================

    // Events for infrastructure usage
    event InfrastructureUsed(uint256 indexed territoryId, uint256 indexed infraTokenId, uint8 infraType);
    event InfrastructureRepaired(uint256 indexed territoryId, uint256 indexed infraTokenId, uint8 durabilityRestored, uint256 costPaid);

    // Errors for infrastructure usage
    error InfrastructureDepleted();
    error InvalidDurabilityAmount();

    /**
     * @notice Use infrastructure for production/defense action
     * @param territoryId Territory where infrastructure is equipped
     * @param infraTokenId Infrastructure NFT token ID
     * @dev Reduces durability, returns false if depleted
     */
    function useInfrastructure(uint256 territoryId, uint256 infraTokenId) external whenNotPaused nonReentrant returns (bool success) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        // Verify territory ownership
        bytes32 colonyId = cws.userToColony[LibMeta.msgSender()];
        if (cws.territories[territoryId].controllingColony != colonyId) revert TerritoryNotOwned();

        // Verify infrastructure is equipped to this territory
        if (cws.infraEquippedToTerritory[infraTokenId] != territoryId) revert InfrastructureNotEquipped();

        // Get infrastructure contract and call useInfrastructure
        address infraAddr = cws.contractAddresses.infrastructureCards;
        if (infraAddr == address(0)) revert InfraContractNotSet();

        IColonyInfrastructureCards infraContract = IColonyInfrastructureCards(infraAddr);

        // Check durability before use
        IColonyInfrastructureCards.InfrastructureTraits memory traits = infraContract.getTraits(infraTokenId);
        if (traits.durability == 0) revert InfrastructureDepleted();

        // Use infrastructure (reduces durability in NFT contract)
        success = infraContract.useInfrastructure(infraTokenId);

        if (success) {
            emit InfrastructureUsed(territoryId, infraTokenId, uint8(traits.infraType));
        }
    }

    /**
     * @notice Repair infrastructure durability
     * @param territoryId Territory where infrastructure is equipped
     * @param infraTokenId Infrastructure NFT token ID
     * @param durabilityToRestore Amount of durability to restore (1-100)
     * @return cost Amount paid for repair
     * @dev Cost is calculated by NFT contract based on rarity and amount
     */
    function repairInfrastructure(
        uint256 territoryId,
        uint256 infraTokenId,
        uint8 durabilityToRestore
    ) external payable whenNotPaused nonReentrant returns (uint256 cost) {
        if (durabilityToRestore == 0 || durabilityToRestore > 100) revert InvalidDurabilityAmount();

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        // Verify territory ownership
        bytes32 colonyId = cws.userToColony[LibMeta.msgSender()];
        if (cws.territories[territoryId].controllingColony != colonyId) revert TerritoryNotOwned();

        // Verify infrastructure is equipped to this territory
        if (cws.infraEquippedToTerritory[infraTokenId] != territoryId) revert InfrastructureNotEquipped();

        // Get infrastructure contract
        address infraAddr = cws.contractAddresses.infrastructureCards;
        if (infraAddr == address(0)) revert InfraContractNotSet();

        IColonyInfrastructureCards infraContract = IColonyInfrastructureCards(infraAddr);

        // Call repair on NFT contract (it calculates and collects cost)
        cost = infraContract.repairInfrastructure(infraTokenId, durabilityToRestore);

        // Collect payment using card mint fee helper (supports native/ERC20)
        if (cost > 0) {
            ResourceHelper.collectCardMintFee(LibMeta.msgSender(), cost, "infra_repair");
        }

        emit InfrastructureRepaired(territoryId, infraTokenId, durabilityToRestore, cost);
    }

    /**
     * @notice Get infrastructure durability status
     * @param infraTokenId Infrastructure NFT token ID
     * @return durability Current durability (0-100)
     * @return maxDurability Maximum durability (always 100)
     * @return isDepleted Whether infrastructure is depleted
     */
    function getInfraDurability(uint256 infraTokenId) external view returns (
        uint8 durability,
        uint8 maxDurability,
        bool isDepleted
    ) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        address infraAddr = cws.contractAddresses.infrastructureCards;
        if (infraAddr == address(0)) return (0, 100, true);

        IColonyInfrastructureCards infraContract = IColonyInfrastructureCards(infraAddr);
        IColonyInfrastructureCards.InfrastructureTraits memory traits = infraContract.getTraits(infraTokenId);

        return (traits.durability, 100, traits.durability == 0);
    }
}
