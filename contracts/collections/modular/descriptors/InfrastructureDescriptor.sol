// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import {IInfrastructureDescriptor} from "../interfaces/IInfrastructureDescriptor.sol";
import {InfrastructureSVGLib} from "../../libraries/InfrastructureSVGLib.sol";

/**
 * @title InfrastructureDescriptor
 * @notice External metadata renderer for ColonyInfrastructureCards
 * @dev Generates on-chain SVG and JSON metadata for Infrastructure NFTs
 *      Can be upgraded independently of the main collection contract
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract InfrastructureDescriptor is IInfrastructureDescriptor, Ownable {
    using Strings for uint256;
    using Strings for uint8;

    // Collection metadata
    string public collectionName;
    string public collectionDescription;
    string public collectionImageUrl;
    string public collectionExternalUrl;

    event CollectionMetadataUpdated(
        string name,
        string description,
        string imageUrl,
        string externalUrl
    );

    constructor(
        string memory _name,
        string memory _description,
        string memory _imageUrl,
        string memory _externalUrl,
        address _owner
    ) Ownable(_owner) {
        collectionName = _name;
        collectionDescription = _description;
        collectionImageUrl = _imageUrl;
        collectionExternalUrl = _externalUrl;
    }

    // ============ EXTERNAL VIEW FUNCTIONS ============

    /// @inheritdoc IInfrastructureDescriptor
    function tokenURI(InfrastructureMetadata memory metadata)
        external
        view
        override
        returns (string memory)
    {
        InfrastructureSVGLib.InfrastructureTraits memory traits = InfrastructureSVGLib.InfrastructureTraits({
            infraType: metadata.infraType,
            rarity: metadata.rarity,
            efficiencyBonus: metadata.efficiencyBonus,
            capacityBonus: metadata.capacityBonus,
            techLevel: metadata.techLevel,
            durability: metadata.durability
        });

        string memory svg = InfrastructureSVGLib.generateSVG(metadata.tokenId, traits);
        string memory json = _generateMetadataJSON(metadata, svg);

        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        );
    }

    /// @inheritdoc IInfrastructureDescriptor
    function generateSVG(InfrastructureMetadata memory metadata)
        external
        pure
        override
        returns (string memory)
    {
        InfrastructureSVGLib.InfrastructureTraits memory traits = InfrastructureSVGLib.InfrastructureTraits({
            infraType: metadata.infraType,
            rarity: metadata.rarity,
            efficiencyBonus: metadata.efficiencyBonus,
            capacityBonus: metadata.capacityBonus,
            techLevel: metadata.techLevel,
            durability: metadata.durability
        });

        return InfrastructureSVGLib.generateSVG(metadata.tokenId, traits);
    }

    /// @inheritdoc IInfrastructureDescriptor
    function contractURI() external view override returns (string memory) {
        string memory json = string.concat(
            '{"name":"', collectionName,
            '","description":"', collectionDescription,
            '","image":"', collectionImageUrl,
            '","external_link":"', collectionExternalUrl, '"}'
        );

        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        );
    }

    // ============ ADMIN FUNCTIONS ============

    function setCollectionMetadata(
        string memory _name,
        string memory _description,
        string memory _imageUrl,
        string memory _externalUrl
    ) external onlyOwner {
        collectionName = _name;
        collectionDescription = _description;
        collectionImageUrl = _imageUrl;
        collectionExternalUrl = _externalUrl;

        emit CollectionMetadataUpdated(_name, _description, _imageUrl, _externalUrl);
    }

    function setCollectionName(string memory _name) external onlyOwner {
        collectionName = _name;
    }

    function setCollectionDescription(string memory _description) external onlyOwner {
        collectionDescription = _description;
    }

    function setCollectionImageUrl(string memory _imageUrl) external onlyOwner {
        collectionImageUrl = _imageUrl;
    }

    function setCollectionExternalUrl(string memory _externalUrl) external onlyOwner {
        collectionExternalUrl = _externalUrl;
    }

    // ============ INTERNAL FUNCTIONS ============

    function _generateMetadataJSON(
        InfrastructureMetadata memory metadata,
        string memory svg
    ) internal pure returns (string memory) {
        return string.concat(
            '{"name":"',
            _generateName(metadata),
            '","description":"',
            _generateDescription(metadata),
            '","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)),
            '","attributes":[',
            _generateAttributes(metadata),
            ']}'
        );
    }

    function _generateName(InfrastructureMetadata memory metadata)
        internal
        pure
        returns (string memory)
    {
        string memory typeName = _getInfrastructureTypeName(metadata.infraType);
        string memory rarityPrefix = _getRarityPrefix(metadata.rarity);

        return string.concat(
            rarityPrefix,
            " ",
            typeName,
            " #",
            metadata.tokenId.toString()
        );
    }

    function _generateDescription(InfrastructureMetadata memory metadata)
        internal
        pure
        returns (string memory)
    {
        string memory typeName = _getInfrastructureTypeName(metadata.infraType);

        return string.concat(
            typeName,
            " - Henomorphs Colony Wars Infrastructure. "
            "Equip to your colony territories to boost resource production, strengthen defenses, and unlock strategic advantages. "
            "Higher rarity buildings provide greater bonuses. Durability degrades with use - repair to maintain peak efficiency."
        );
    }

    function _generateAttributes(InfrastructureMetadata memory metadata)
        internal
        pure
        returns (string memory)
    {
        uint256 totalEfficiency = _calculateTotalEfficiency(metadata.efficiencyBonus, metadata.rarity);

        return string.concat(
            '{"trait_type":"Type","value":"',
            _getInfrastructureTypeName(metadata.infraType),
            '"},',
            '{"trait_type":"Rarity","value":"',
            _getRarityName(metadata.rarity),
            '"},',
            '{"trait_type":"Efficiency Bonus","value":"',
            metadata.efficiencyBonus.toString(),
            '","display_type":"boost_percentage"},',
            '{"trait_type":"Capacity Bonus","value":"',
            metadata.capacityBonus.toString(),
            '"},',
            '{"trait_type":"Tech Level","value":"',
            metadata.techLevel.toString(),
            '"},',
            '{"trait_type":"Durability","value":"',
            metadata.durability.toString(),
            '","max_value":100},',
            '{"trait_type":"Total Efficiency","value":"',
            totalEfficiency.toString(),
            '","display_type":"boost_percentage"},',
            '{"trait_type":"Equipped","value":"',
            metadata.isEquipped ? "Yes" : "No",
            '"}'
        );
    }

    function _calculateTotalEfficiency(
        uint8 baseEfficiency,
        InfrastructureSVGLib.Rarity rarity
    ) internal pure returns (uint256) {
        uint256 rarityMultiplier = _getRarityMultiplier(rarity);
        return (uint256(baseEfficiency) * rarityMultiplier) / 100;
    }

    function _getRarityMultiplier(InfrastructureSVGLib.Rarity rarity)
        internal
        pure
        returns (uint256)
    {
        if (rarity == InfrastructureSVGLib.Rarity.Legendary) return 250;
        if (rarity == InfrastructureSVGLib.Rarity.Epic) return 175;
        if (rarity == InfrastructureSVGLib.Rarity.Rare) return 130;
        if (rarity == InfrastructureSVGLib.Rarity.Uncommon) return 115;
        return 100;
    }

    function _getInfrastructureTypeName(InfrastructureSVGLib.InfrastructureType infraType)
        internal
        pure
        returns (string memory)
    {
        if (infraType == InfrastructureSVGLib.InfrastructureType.MiningDrill) return "Mining Drill";
        if (infraType == InfrastructureSVGLib.InfrastructureType.EnergyHarvester) return "Energy Harvester";
        if (infraType == InfrastructureSVGLib.InfrastructureType.ProcessingPlant) return "Processing Plant";
        if (infraType == InfrastructureSVGLib.InfrastructureType.DefenseTurret) return "Defense Turret";
        if (infraType == InfrastructureSVGLib.InfrastructureType.ResearchLab) return "Research Lab";
        return "Storage Facility";
    }

    function _getRarityName(InfrastructureSVGLib.Rarity rarity)
        internal
        pure
        returns (string memory)
    {
        if (rarity == InfrastructureSVGLib.Rarity.Legendary) return "Legendary";
        if (rarity == InfrastructureSVGLib.Rarity.Epic) return "Epic";
        if (rarity == InfrastructureSVGLib.Rarity.Rare) return "Rare";
        if (rarity == InfrastructureSVGLib.Rarity.Uncommon) return "Uncommon";
        return "Common";
    }

    function _getRarityPrefix(InfrastructureSVGLib.Rarity rarity)
        internal
        pure
        returns (string memory)
    {
        if (rarity == InfrastructureSVGLib.Rarity.Legendary) return "Legendary";
        if (rarity == InfrastructureSVGLib.Rarity.Epic) return "Epic";
        if (rarity == InfrastructureSVGLib.Rarity.Rare) return "Rare";
        if (rarity == InfrastructureSVGLib.Rarity.Uncommon) return "Uncommon";
        return "";
    }
}
