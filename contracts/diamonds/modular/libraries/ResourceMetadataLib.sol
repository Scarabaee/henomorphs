// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import {ResourceSVGLib} from "./ResourceSVGLib.sol";

/**
 * @title ResourceMetadataLib
 * @notice Library for generating Resource Card metadata
 * @dev Generates on-chain JSON metadata for Colony Wars resources
 * @author rutilicus.eth (ArchXS)
 */
library ResourceMetadataLib {
    using Strings for uint256;

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
     */
    function generateTokenURI(
        uint256 tokenId,
        ResourceSVGLib.ResourceTraits memory traits
    ) internal pure returns (string memory) {
        string memory svg = ResourceSVGLib.generateSVG(tokenId, traits);
        string memory svgBase64 = Base64.encode(bytes(svg));
        string memory json = _generateJSON(tokenId, traits, svgBase64);

        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        );
    }

    function _generateJSON(
        uint256 tokenId,
        ResourceSVGLib.ResourceTraits memory traits,
        string memory svgBase64
    ) private pure returns (string memory) {
        return string.concat(
            '{"name":"', _getResourceName(traits.resourceType), ' #', tokenId.toString(), '",',
            '"description":"', _getResourceDescription(traits.resourceType), '",',
            '"image":"data:image/svg+xml;base64,', svgBase64, '",',
            '"attributes":[',
            _generateAttributes(traits),
            ']}'
        );
    }

    function _generateAttributes(ResourceSVGLib.ResourceTraits memory traits)
        private pure returns (string memory)
    {
        return string.concat(
            '{"trait_type":"Resource Type","value":"', _getResourceTypeName(traits.resourceType), '"},',
            '{"trait_type":"Rarity","value":"', _getRarityName(traits.rarity), '"},',
            '{"trait_type":"Yield Bonus","value":', uint256(traits.yieldBonus).toString(), '},',
            '{"trait_type":"Quality Level","value":', uint256(traits.qualityLevel).toString(), '},',
            '{"trait_type":"Stack Size","value":', uint256(traits.stackSize).toString(), '},',
            '{"trait_type":"Max Stack","value":', uint256(traits.maxStack).toString(), '}'
        );
    }

    function _getResourceName(ResourceSVGLib.ResourceType rType)
        private pure returns (string memory)
    {
        if (rType == ResourceSVGLib.ResourceType.BasicMaterials) return "Basic Materials";
        if (rType == ResourceSVGLib.ResourceType.EnergyCrystals) return "Energy Crystal";
        if (rType == ResourceSVGLib.ResourceType.BioCompounds) return "Bio Compound";
        return "Rare Element";
    }

    function _getResourceTypeName(ResourceSVGLib.ResourceType rType)
        private pure returns (string memory)
    {
        if (rType == ResourceSVGLib.ResourceType.BasicMaterials) return "Basic Materials";
        if (rType == ResourceSVGLib.ResourceType.EnergyCrystals) return "Energy Crystals";
        if (rType == ResourceSVGLib.ResourceType.BioCompounds) return "Bio Compounds";
        return "Rare Elements";
    }

    function _getResourceDescription(ResourceSVGLib.ResourceType rType)
        private pure returns (string memory)
    {
        if (rType == ResourceSVGLib.ResourceType.BasicMaterials) {
            return "Henomorphs Colony Wars Resource. Stake to squads to boost colony production rates. Essential materials for building infrastructure and expanding your territory. Higher rarity yields greater bonuses.";
        }
        if (rType == ResourceSVGLib.ResourceType.EnergyCrystals) {
            return "Henomorphs Colony Wars Resource. Stake to squads to power colony operations and fuel special abilities. Vital for charging Chargepods and activating colony defenses. Higher rarity yields greater power output.";
        }
        if (rType == ResourceSVGLib.ResourceType.BioCompounds) {
            return "Henomorphs Colony Wars Resource. Stake to squads to accelerate Henomorph evolution and unlock research upgrades. Essential for Biopod mutations. Higher rarity speeds up specimen development.";
        }
        return "Henomorphs Colony Wars Resource. Stake to squads for advanced tech bonuses and unique strategic abilities. Required for legendary upgrades and elite colony features. Extremely valuable in territory battles.";
    }

    function _getRarityName(ResourceSVGLib.Rarity rarity)
        private pure returns (string memory)
    {
        if (rarity == ResourceSVGLib.Rarity.Legendary) return "Legendary";
        if (rarity == ResourceSVGLib.Rarity.Epic) return "Epic";
        if (rarity == ResourceSVGLib.Rarity.Rare) return "Rare";
        if (rarity == ResourceSVGLib.Rarity.Uncommon) return "Uncommon";
        return "Common";
    }

    /**
     * @notice Calculate yield bonus based on type and rarity
     */
    function calculateYieldBonus(
        ResourceSVGLib.ResourceType rType,
        ResourceSVGLib.Rarity rarity
    ) internal pure returns (uint8) {
        uint8 baseYield;
        if (rType == ResourceSVGLib.ResourceType.BasicMaterials) {
            baseYield = 10;
        } else if (rType == ResourceSVGLib.ResourceType.EnergyCrystals) {
            baseYield = 15;
        } else if (rType == ResourceSVGLib.ResourceType.BioCompounds) {
            baseYield = 12;
        } else {
            baseYield = 20;
        }

        if (rarity == ResourceSVGLib.Rarity.Legendary) return baseYield + 30;
        if (rarity == ResourceSVGLib.Rarity.Epic) return baseYield + 20;
        if (rarity == ResourceSVGLib.Rarity.Rare) return baseYield + 10;
        if (rarity == ResourceSVGLib.Rarity.Uncommon) return baseYield + 5;
        return baseYield;
    }

    /**
     * @notice Calculate quality level based on rarity
     */
    function calculateQualityLevel(ResourceSVGLib.Rarity rarity)
        internal pure returns (uint8)
    {
        if (rarity == ResourceSVGLib.Rarity.Legendary) return 5;
        if (rarity == ResourceSVGLib.Rarity.Epic) return 4;
        if (rarity == ResourceSVGLib.Rarity.Rare) return 3;
        if (rarity == ResourceSVGLib.Rarity.Uncommon) return 2;
        return 1;
    }

    /**
     * @notice Get maximum stack size for resource type
     */
    function getMaxStackSize(ResourceSVGLib.ResourceType rType)
        internal pure returns (uint16)
    {
        if (rType == ResourceSVGLib.ResourceType.BasicMaterials) return 99;
        if (rType == ResourceSVGLib.ResourceType.EnergyCrystals) return 50;
        if (rType == ResourceSVGLib.ResourceType.BioCompounds) return 25;
        return 10; // RareElements - most limited
    }
}
