// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import {InfrastructureSVGLib} from "./InfrastructureSVGLib.sol";

/**
 * @title InfrastructureMetadataLib
 * @notice Library for generating Infrastructure Card metadata and bonus calculations
 * @dev Handles JSON metadata generation and trait calculations
 * @author rutilicus.eth (ArchXS)
 */
library InfrastructureMetadataLib {
    using Strings for uint256;
    using Strings for uint8;
    using InfrastructureSVGLib for InfrastructureSVGLib.InfrastructureTraits;

    /**
     * @notice Collection configuration for contract metadata and minting limits
     */
    struct CollectionConfig {
        string name;
        string description;
        string imageUrl;          // Collection logo/banner URL
        string externalUrl;       // Website URL
        uint256 maxSupply;        // Maximum total supply
        uint256 maxMintsPerWallet; // Maximum mints per wallet
    }

    /**
     * @notice Generate OpenSea-compatible collection metadata (contractURI)
     * @param config Collection configuration
     * @return Complete data URI with collection metadata
     */
    function generateContractURI(
        CollectionConfig memory config
    ) internal pure returns (string memory) {
        string memory json = string.concat(
            '{"name":"', config.name,
            '","description":"', config.description,
            '","image":"', config.imageUrl,
            '","external_link":"', config.externalUrl, '"}'
        );

        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        );
    }

    /**
     * @notice Generate complete token URI with embedded SVG
     * @param tokenId Token ID
     * @param traits Infrastructure traits
     * @return Base64-encoded data URI with complete metadata
     */
    function generateTokenURI(
        uint256 tokenId,
        InfrastructureSVGLib.InfrastructureTraits memory traits
    ) internal pure returns (string memory) {
        string memory svg = InfrastructureSVGLib.generateSVG(tokenId, traits);
        string memory json = _generateMetadataJSON(tokenId, traits, svg);
        
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        );
    }

    /**
     * @notice Calculate total efficiency bonus including rarity multiplier
     * @param baseEfficiency Base efficiency bonus from traits
     * @param rarity Rarity tier
     * @return Total efficiency percentage
     */
    function calculateTotalEfficiency(
        uint8 baseEfficiency,
        InfrastructureSVGLib.Rarity rarity
    ) internal pure returns (uint256) {
        uint256 rarityMultiplier = _getRarityMultiplier(rarity);
        return (uint256(baseEfficiency) * rarityMultiplier) / 100;
    }

    /**
     * @notice Calculate durability degradation per use
     * @param currentDurability Current durability (0-100)
     * @param rarity Rarity tier
     * @return Durability points lost per use
     */
    function calculateDegradation(
        uint8 currentDurability,
        InfrastructureSVGLib.Rarity rarity
    ) internal pure returns (uint8) {
        if (currentDurability == 0) return 0;
        
        // Legendary degrades 5x slower than Common
        if (rarity == InfrastructureSVGLib.Rarity.Legendary) return 1;
        if (rarity == InfrastructureSVGLib.Rarity.Epic) return 2;
        if (rarity == InfrastructureSVGLib.Rarity.Rare) return 3;
        if (rarity == InfrastructureSVGLib.Rarity.Uncommon) return 4;
        return 5; // Common
    }

    /**
     * @notice Calculate repair cost in ZICO
     * @param durabilityLost Durability points to restore
     * @param rarity Rarity tier
     * @return ZICO cost for repair
     */
    function calculateRepairCost(
        uint8 durabilityLost,
        InfrastructureSVGLib.Rarity rarity
    ) internal pure returns (uint256) {
        // Base: 10 ZICO per durability point
        uint256 baseCost = uint256(durabilityLost) * 10 * 1e18;
        
        // Legendary costs 3x more to repair
        if (rarity == InfrastructureSVGLib.Rarity.Legendary) return baseCost * 3;
        if (rarity == InfrastructureSVGLib.Rarity.Epic) return baseCost * 2;
        if (rarity == InfrastructureSVGLib.Rarity.Rare) return (baseCost * 15) / 10;
        if (rarity == InfrastructureSVGLib.Rarity.Uncommon) return (baseCost * 12) / 10;
        return baseCost;
    }

    // ============ INTERNAL FUNCTIONS ============

    function _generateMetadataJSON(
        uint256 tokenId,
        InfrastructureSVGLib.InfrastructureTraits memory traits,
        string memory svg
    ) private pure returns (string memory) {
        return string.concat(
            '{"name":"',
            _generateName(tokenId, traits),
            '","description":"',
            _generateDescription(traits),
            '","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)),
            '","attributes":[',
            _generateAttributes(traits),
            ']}'
        );
    }

    function _generateName(
        uint256 tokenId,
        InfrastructureSVGLib.InfrastructureTraits memory traits
    ) private pure returns (string memory) {
        string memory typeName = _getInfrastructureTypeName(traits.infraType);
        string memory rarityPrefix = _getRarityPrefix(traits.rarity);
        
        return string.concat(
            rarityPrefix,
            " ",
            typeName,
            " #",
            tokenId.toString()
        );
    }

    function _generateDescription(InfrastructureSVGLib.InfrastructureTraits memory traits)
        private pure returns (string memory)
    {
        string memory typeName = _getInfrastructureTypeName(traits.infraType);

        return string.concat(
            typeName,
            " - Henomorphs Colony Wars Infrastructure. "
            "Equip to your colony territories to boost resource production, strengthen defenses, and unlock strategic advantages. "
            "Higher rarity buildings provide greater bonuses. Durability degrades with use - repair to maintain peak efficiency."
        );
    }

    function _generateAttributes(InfrastructureSVGLib.InfrastructureTraits memory traits)
        private pure returns (string memory)
    {
        return string.concat(
            '{"trait_type":"Type","value":"',
            _getInfrastructureTypeName(traits.infraType),
            '"},',
            '{"trait_type":"Rarity","value":"',
            _getRarityName(traits.rarity),
            '"},',
            '{"trait_type":"Efficiency Bonus","value":"',
            traits.efficiencyBonus.toString(), 
            '","display_type":"boost_percentage"},',
            '{"trait_type":"Capacity Bonus","value":"',
            traits.capacityBonus.toString(),
            '"},',
            '{"trait_type":"Tech Level","value":"',
            traits.techLevel.toString(),
            '"},',
            '{"trait_type":"Durability","value":"',
            traits.durability.toString(),
            '","max_value":100}',
            _generateBonusAttributes(traits)
        );
    }

    function _generateBonusAttributes(InfrastructureSVGLib.InfrastructureTraits memory traits)
        private pure returns (string memory)
    {
        uint256 totalEfficiency = calculateTotalEfficiency(traits.efficiencyBonus, traits.rarity);
        
        return string.concat(
            ',{"trait_type":"Total Efficiency","value":"',
            totalEfficiency.toString(),
            '","display_type":"boost_percentage"}',
            ',{"trait_type":"Degradation Rate","value":"',
            calculateDegradation(100, traits.rarity).toString(),
            '","display_type":"number"}'
        );
    }

    function _getInfrastructureTypeName(InfrastructureSVGLib.InfrastructureType infraType)
        private pure returns (string memory)
    {
        if (infraType == InfrastructureSVGLib.InfrastructureType.MiningDrill) return "Mining Drill";
        if (infraType == InfrastructureSVGLib.InfrastructureType.EnergyHarvester) return "Energy Harvester";
        if (infraType == InfrastructureSVGLib.InfrastructureType.ProcessingPlant) return "Processing Plant";
        if (infraType == InfrastructureSVGLib.InfrastructureType.DefenseTurret) return "Defense Turret";
        if (infraType == InfrastructureSVGLib.InfrastructureType.ResearchLab) return "Research Lab";
        return "Storage Facility";
    }

    function _getRarityName(InfrastructureSVGLib.Rarity rarity)
        private pure returns (string memory)
    {
        if (rarity == InfrastructureSVGLib.Rarity.Legendary) return "Legendary";
        if (rarity == InfrastructureSVGLib.Rarity.Epic) return "Epic";
        if (rarity == InfrastructureSVGLib.Rarity.Rare) return "Rare";
        if (rarity == InfrastructureSVGLib.Rarity.Uncommon) return "Uncommon";
        return "Common";
    }

    function _getRarityPrefix(InfrastructureSVGLib.Rarity rarity)
        private pure returns (string memory)
    {
        if (rarity == InfrastructureSVGLib.Rarity.Legendary) return "Legendary";
        if (rarity == InfrastructureSVGLib.Rarity.Epic) return "Epic";
        if (rarity == InfrastructureSVGLib.Rarity.Rare) return "Rare";
        if (rarity == InfrastructureSVGLib.Rarity.Uncommon) return "Uncommon";
        return "";
    }

    function _getRarityMultiplier(InfrastructureSVGLib.Rarity rarity)
        private pure returns (uint256)
    {
        if (rarity == InfrastructureSVGLib.Rarity.Legendary) return 250; // +150%
        if (rarity == InfrastructureSVGLib.Rarity.Epic) return 175;      // +75%
        if (rarity == InfrastructureSVGLib.Rarity.Rare) return 130;      // +30%
        if (rarity == InfrastructureSVGLib.Rarity.Uncommon) return 115;  // +15%
        return 100; // Common - no bonus
    }
}
