// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title TerritoryMetadataLib
 * @notice Library for generating Territory Card JSON metadata
 * @dev Separated library for gas optimization and modularity
 * @author rutilicus.eth (ArchXS)
 */
library TerritoryMetadataLib {
    using Strings for uint256;

    enum TerritoryType { ZicoMine, TradeHub, Fortress, Observatory, Sanctuary }
    enum Rarity { Common, Uncommon, Rare, Epic, Legendary }

    struct TerritoryTraits {
        TerritoryType territoryType;
        Rarity rarity;
        uint8 productionBonus;
        uint8 defenseBonus;
        uint8 techLevel;
        uint16 specimenPopulation;
        uint8 colonyWarsType;
    }

    /**
     * @notice Generate complete token URI with embedded SVG
     * @param tokenId Token ID
     * @param traits Territory traits
     * @param svgData Base64-encoded SVG image data
     * @return Complete data URI with JSON metadata
     */
    function generateTokenURI(
        uint256 tokenId,
        TerritoryTraits memory traits,
        string memory svgData
    ) internal pure returns (string memory) {
        string memory json = string.concat(
            '{"name":"Colony Territory #', tokenId.toString(),
            '","description":"', _generateDescription(traits),
            '","image":"data:image/svg+xml;base64,', svgData,
            '","attributes":', _generateAttributes(traits),
            '}'
        );

        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        );
    }

    /**
     * @notice Generate OpenSea-compatible collection metadata
     * @param name Collection name
     * @param description Collection description
     * @param imageUrl Collection banner image URL (IPFS or HTTP)
     * @param externalUrl Website URL
     * @param sellerFeeBasisPoints Royalty fee (e.g., 500 = 5%)
     * @param feeRecipient Royalty recipient address
     * @return Complete data URI with collection metadata
     */
    function generateContractMetadata(
        string memory name,
        string memory description,
        string memory imageUrl,
        string memory externalUrl,
        uint256 sellerFeeBasisPoints,
        address feeRecipient
    ) internal pure returns (string memory) {
        string memory json = string.concat(
            '{"name":"', name,
            '","description":"', description,
            '","image":"', imageUrl,
            '","external_link":"', externalUrl,
            '","seller_fee_basis_points":', sellerFeeBasisPoints.toString(),
            '","fee_recipient":"', _addressToString(feeRecipient), '"}'
        );

        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        );
    }

    function _generateDescription(TerritoryTraits memory traits) private pure returns (string memory) {
        return string.concat(
            "Territory Card - ",
            _getTerritoryTypeName(traits.territoryType),
            " (Type ", uint256(traits.colonyWarsType).toString(), "). ",
            "Grants production and defense bonuses to your colony."
        );
    }

    function _generateAttributes(TerritoryTraits memory traits) private pure returns (string memory) {
        return string.concat(
            '[',
            '{"trait_type":"Territory Name","value":"', _getTerritoryTypeName(traits.territoryType), '"},',
            '{"trait_type":"Territory Type","value":', uint256(traits.colonyWarsType).toString(), '},',
            '{"trait_type":"Rarity","value":"', _getRarityName(traits.rarity), '"},',
            '{"trait_type":"Production Bonus","value":', uint256(traits.productionBonus).toString(), '},',
            '{"trait_type":"Defense Bonus","value":', uint256(traits.defenseBonus).toString(), '},',
            '{"trait_type":"Tech Level","value":', uint256(traits.techLevel).toString(), '},',
            '{"trait_type":"Specimen Population","value":', uint256(traits.specimenPopulation).toString(), '}',
            ']'
        );
    }

    function _getTerritoryTypeName(TerritoryType tType) private pure returns (string memory) {
        if (tType == TerritoryType.ZicoMine) return "ZICO Mine";
        if (tType == TerritoryType.TradeHub) return "Trade Hub";
        if (tType == TerritoryType.Fortress) return "Fortress";
        if (tType == TerritoryType.Observatory) return "Observatory";
        return "Sanctuary";
    }

    function _getRarityName(Rarity rarity) private pure returns (string memory) {
        if (rarity == Rarity.Legendary) return "Legendary";
        if (rarity == Rarity.Epic) return "Epic";
        if (rarity == Rarity.Rare) return "Rare";
        if (rarity == Rarity.Uncommon) return "Uncommon";
        return "Common";
    }

    function _addressToString(address addr) private pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes20 value = bytes20(addr);
        bytes memory str = new bytes(42);
        
        str[0] = '0';
        str[1] = 'x';
        
        for (uint256 i = 0; i < 20; i++) {
            str[2 + i * 2] = alphabet[uint8(value[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(value[i] & 0x0f)];
        }
        
        return string(str);
    }

    /**
     * @notice Helper function to calculate trait bonuses
     * @param tType Territory type
     * @param rarity Rarity level
     * @return Base bonus value
     */
    function calculateBonus(TerritoryType tType, Rarity rarity) internal pure returns (uint8) {
        uint8 baseBonus;
        
        if (tType == TerritoryType.ZicoMine) baseBonus = 15;
        else if (tType == TerritoryType.TradeHub) baseBonus = 10;
        else if (tType == TerritoryType.Fortress) baseBonus = 20;
        else if (tType == TerritoryType.Observatory) baseBonus = 12;
        else baseBonus = 8; // Sanctuary
        
        if (rarity == Rarity.Legendary) return baseBonus + 10;
        if (rarity == Rarity.Epic) return baseBonus + 6;
        if (rarity == Rarity.Rare) return baseBonus + 3;
        return baseBonus;
    }

    /**
     * @notice Helper function to calculate tech level
     * @param tType Territory type
     * @param rarity Rarity level
     * @return Tech level
     */
    function calculateTechLevel(TerritoryType tType, Rarity rarity) internal pure returns (uint8) {
        uint8 base;
        
        if (tType == TerritoryType.ZicoMine) base = 3;
        else if (tType == TerritoryType.TradeHub) base = 4;
        else if (tType == TerritoryType.Fortress) base = 5;
        else if (tType == TerritoryType.Observatory) base = 7;
        else base = 4; // Sanctuary
        
        return base + uint8(rarity) * 2;
    }

    /**
     * @notice Helper function to calculate population
     * @param tType Territory type
     * @param rarity Rarity level
     * @return Population count
     */
    function calculatePopulation(TerritoryType tType, Rarity rarity) internal pure returns (uint16) {
        uint16 base;
        
        if (tType == TerritoryType.ZicoMine) base = 200;
        else if (tType == TerritoryType.TradeHub) base = 300;
        else if (tType == TerritoryType.Fortress) base = 150;
        else if (tType == TerritoryType.Observatory) base = 50;
        else base = 100; // Sanctuary
        
        return base + uint16(rarity) * 100;
    }
}
