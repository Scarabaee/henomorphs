// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import {IResourceDescriptor} from "../interfaces/IResourceDescriptor.sol";
import {ResourceSVGLib} from "../../../diamonds/modular/libraries/ResourceSVGLib.sol";

/**
 * @title ResourceDescriptor
 * @notice External metadata renderer for ColonyResourceCards
 * @dev Generates on-chain SVG and JSON metadata for Resource NFTs
 *      Can be upgraded independently of the main collection contract
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract ResourceDescriptor is IResourceDescriptor, Ownable {
    using Strings for uint256;
    using Strings for uint8;
    using Strings for uint16;

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

    /// @inheritdoc IResourceDescriptor
    function tokenURI(ResourceMetadata memory metadata)
        external
        view
        override
        returns (string memory)
    {
        ResourceSVGLib.ResourceTraits memory traits = ResourceSVGLib.ResourceTraits({
            resourceType: metadata.resourceType,
            rarity: metadata.rarity,
            yieldBonus: metadata.yieldBonus,
            qualityLevel: metadata.qualityLevel,
            stackSize: metadata.stackSize,
            maxStack: metadata.maxStack
        });

        string memory svg = ResourceSVGLib.generateSVG(metadata.tokenId, traits);
        string memory json = _generateMetadataJSON(metadata, svg);

        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        );
    }

    /// @inheritdoc IResourceDescriptor
    function generateSVG(ResourceMetadata memory metadata)
        external
        pure
        override
        returns (string memory)
    {
        ResourceSVGLib.ResourceTraits memory traits = ResourceSVGLib.ResourceTraits({
            resourceType: metadata.resourceType,
            rarity: metadata.rarity,
            yieldBonus: metadata.yieldBonus,
            qualityLevel: metadata.qualityLevel,
            stackSize: metadata.stackSize,
            maxStack: metadata.maxStack
        });

        return ResourceSVGLib.generateSVG(metadata.tokenId, traits);
    }

    /// @inheritdoc IResourceDescriptor
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
        ResourceMetadata memory metadata,
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

    function _generateName(ResourceMetadata memory metadata)
        internal
        pure
        returns (string memory)
    {
        string memory typeName = _getResourceName(metadata.resourceType);
        string memory rarityPrefix = _getRarityPrefix(metadata.rarity);

        if (bytes(rarityPrefix).length > 0) {
            return string.concat(
                rarityPrefix,
                " ",
                typeName,
                " #",
                metadata.tokenId.toString()
            );
        }

        return string.concat(
            typeName,
            " #",
            metadata.tokenId.toString()
        );
    }

    function _generateDescription(ResourceMetadata memory metadata)
        internal
        pure
        returns (string memory)
    {
        if (metadata.resourceType == ResourceSVGLib.ResourceType.BasicMaterials) {
            return "Henomorphs Colony Wars Resource. Stake to squads to boost colony production rates. Essential materials for building infrastructure and expanding your territory. Higher rarity yields greater bonuses.";
        }
        if (metadata.resourceType == ResourceSVGLib.ResourceType.EnergyCrystals) {
            return "Henomorphs Colony Wars Resource. Stake to squads to power colony operations and fuel special abilities. Vital for charging Chargepods and activating colony defenses. Higher rarity yields greater power output.";
        }
        if (metadata.resourceType == ResourceSVGLib.ResourceType.BioCompounds) {
            return "Henomorphs Colony Wars Resource. Stake to squads to accelerate Henomorph evolution and unlock research upgrades. Essential for Biopod mutations. Higher rarity speeds up specimen development.";
        }
        return "Henomorphs Colony Wars Resource. Stake to squads for advanced tech bonuses and unique strategic abilities. Required for legendary upgrades and elite colony features. Extremely valuable in territory battles.";
    }

    function _generateAttributes(ResourceMetadata memory metadata)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '{"trait_type":"Resource Type","value":"',
            _getResourceTypeName(metadata.resourceType),
            '"},',
            '{"trait_type":"Rarity","value":"',
            _getRarityName(metadata.rarity),
            '"},',
            '{"trait_type":"Yield Bonus","value":',
            uint256(metadata.yieldBonus).toString(),
            '},',
            '{"trait_type":"Quality Level","value":',
            uint256(metadata.qualityLevel).toString(),
            '},',
            '{"trait_type":"Stack Size","value":',
            uint256(metadata.stackSize).toString(),
            '},',
            '{"trait_type":"Max Stack","value":',
            uint256(metadata.maxStack).toString(),
            '},',
            '{"trait_type":"Staked","value":"',
            metadata.isStaked ? "Yes" : "No",
            '"}'
        );
    }

    function _getResourceName(ResourceSVGLib.ResourceType rType)
        internal
        pure
        returns (string memory)
    {
        if (rType == ResourceSVGLib.ResourceType.BasicMaterials) return "Basic Materials";
        if (rType == ResourceSVGLib.ResourceType.EnergyCrystals) return "Energy Crystal";
        if (rType == ResourceSVGLib.ResourceType.BioCompounds) return "Bio Compound";
        return "Rare Element";
    }

    function _getResourceTypeName(ResourceSVGLib.ResourceType rType)
        internal
        pure
        returns (string memory)
    {
        if (rType == ResourceSVGLib.ResourceType.BasicMaterials) return "Basic Materials";
        if (rType == ResourceSVGLib.ResourceType.EnergyCrystals) return "Energy Crystals";
        if (rType == ResourceSVGLib.ResourceType.BioCompounds) return "Bio Compounds";
        return "Rare Elements";
    }

    function _getRarityName(ResourceSVGLib.Rarity rarity)
        internal
        pure
        returns (string memory)
    {
        if (rarity == ResourceSVGLib.Rarity.Legendary) return "Legendary";
        if (rarity == ResourceSVGLib.Rarity.Epic) return "Epic";
        if (rarity == ResourceSVGLib.Rarity.Rare) return "Rare";
        if (rarity == ResourceSVGLib.Rarity.Uncommon) return "Uncommon";
        return "Common";
    }

    function _getRarityPrefix(ResourceSVGLib.Rarity rarity)
        internal
        pure
        returns (string memory)
    {
        if (rarity == ResourceSVGLib.Rarity.Legendary) return "Legendary";
        if (rarity == ResourceSVGLib.Rarity.Epic) return "Epic";
        if (rarity == ResourceSVGLib.Rarity.Rare) return "Rare";
        if (rarity == ResourceSVGLib.Rarity.Uncommon) return "Uncommon";
        return "";
    }
}
