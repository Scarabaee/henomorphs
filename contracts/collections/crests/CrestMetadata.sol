// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./ICrestMetadata.sol";
import "./CrestTypes.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";

/**
 * @title CrestMetadata
 * @notice On-chain metadata generator for Henomorphs Colonial Crests
 * @dev Generates heraldic attributes for cyberpunk coat of arms NFTs
 * @author rutilicus.eth (ZicoDAO)
 */
contract CrestMetadata is ICrestMetadata {
    using Strings for uint256;

    /**
     * @notice Generate contract URI for the collection
     */
    function contractURI(
        CrestTypes.Collection calldata collection
    ) external pure override returns (string memory) {
        string memory json = string(
            abi.encodePacked(
                '{"name": "',
                collection.name,
                '", "description": "',
                collection.description,
                '", "image": "',
                collection.contractImageUrl,
                '", "external_link": "https://zico.network"}'
            )
        );

        return string(
            abi.encodePacked(
                "data:application/json;base64,",
                Base64.encode(bytes(json))
            )
        );
    }

    /**
     * @notice Generate token URI for a crest
     */
    function tokenURI(
        uint256,
        CrestTypes.Collection calldata collection,
        CrestTypes.CrestData calldata crest
    ) external pure override returns (string memory) {
        string memory attributes = _buildAttributes(crest);
        string memory imageUrl = _buildImageUrl(collection.baseImageUri, crest.colonyId);

        string memory json = string(
            abi.encodePacked(
                '{"name": "',
                crest.colonyName,
                ' Colonial Crest", "description": "Heraldic emblem of the ',
                crest.colonyName,
                ' colony in the Henomorphs ecosystem. A cyberpunk coat of arms featuring Henomorphs cyber chicks as noble beasts, forged as permanent on-chain testament to the colony legacy.',
                '", "image": "',
                imageUrl,
                '"'
            )
        );

        json = string(
            abi.encodePacked(
                json,
                ', "attributes": [',
                attributes,
                ']}'
            )
        );

        return string(
            abi.encodePacked(
                "data:application/json;base64,",
                Base64.encode(bytes(json))
            )
        );
    }

    /**
     * @notice Build image URL from colony ID
     */
    function _buildImageUrl(
        string memory baseUri,
        bytes32 colonyId
    ) internal pure returns (string memory) {
        uint256 colonyIdInt = uint256(colonyId);
        return string(
            abi.encodePacked(
                baseUri,
                colonyIdInt.toString(),
                ".png"
            )
        );
    }

    /**
     * @notice Build attributes JSON array with heraldic traits
     */
    function _buildAttributes(
        CrestTypes.CrestData calldata crest
    ) internal pure returns (string memory) {
        string memory attrs = "";

        // Colony Name
        attrs = string(abi.encodePacked(attrs, _trait("Colony", crest.colonyName)));

        // Archetype/Style - determines overall aesthetic
        attrs = string(abi.encodePacked(attrs, ',', _trait("Style", _getArchetypeName(crest.archetype))));

        // Heraldic Shield Type
        attrs = string(abi.encodePacked(attrs, ',', _trait("Shield", _getShieldName(crest.heraldry.shield))));

        // Crown Type
        attrs = string(abi.encodePacked(attrs, ',', _trait("Crown", _getCrownName(crest.heraldry.crown))));

        // Beast Pose
        attrs = string(abi.encodePacked(attrs, ',', _trait("Beast Pose", _getPoseName(crest.heraldry.pose))));

        // Mint Order (token ID = sequential number)
        attrs = string(abi.encodePacked(attrs, ',', _traitNumber("Mint Order", crest.tokenId)));

        return attrs;
    }

    /**
     * @notice Helper to format a string trait
     */
    function _trait(
        string memory traitType,
        string memory value
    ) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '{"trait_type": "',
                traitType,
                '", "value": "',
                value,
                '"}'
            )
        );
    }

    /**
     * @notice Helper to format a numeric trait
     */
    function _traitNumber(
        string memory traitType,
        uint256 value
    ) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '{"trait_type": "',
                traitType,
                '", "value": ',
                value.toString(),
                '}'
            )
        );
    }

    // ============ NAME LOOKUPS ============

    function _getArchetypeName(CrestTypes.Archetype archetype) internal pure returns (string memory) {
        if (archetype == CrestTypes.Archetype.Aggressive) return "Aggressive";
        if (archetype == CrestTypes.Archetype.Defensive) return "Defensive";
        if (archetype == CrestTypes.Archetype.Wealthy) return "Wealthy";
        if (archetype == CrestTypes.Archetype.Territorial) return "Territorial";
        if (archetype == CrestTypes.Archetype.Alliance) return "Alliance";
        if (archetype == CrestTypes.Archetype.Veteran) return "Veteran";
        if (archetype == CrestTypes.Archetype.Elite) return "Elite";
        return "Newborn";
    }

    function _getShieldName(CrestTypes.ShieldType shield) internal pure returns (string memory) {
        if (shield == CrestTypes.ShieldType.Heater) return "Heater";
        if (shield == CrestTypes.ShieldType.Kite) return "Kite";
        if (shield == CrestTypes.ShieldType.Round) return "Round";
        if (shield == CrestTypes.ShieldType.Pavise) return "Pavise";
        if (shield == CrestTypes.ShieldType.Lozenge) return "Lozenge";
        return "Heater";
    }

    function _getCrownName(CrestTypes.Crown crown) internal pure returns (string memory) {
        if (crown == CrestTypes.Crown.None) return "None";
        if (crown == CrestTypes.Crown.Coronet) return "Coronet";
        if (crown == CrestTypes.Crown.Laurel) return "Laurel";
        if (crown == CrestTypes.Crown.Imperial) return "Imperial";
        if (crown == CrestTypes.Crown.Cyber) return "Cyber";
        return "None";
    }

    function _getPoseName(CrestTypes.BeastPose pose) internal pure returns (string memory) {
        if (pose == CrestTypes.BeastPose.Rampant) return "Rampant";
        if (pose == CrestTypes.BeastPose.Guardian) return "Guardian";
        if (pose == CrestTypes.BeastPose.Vigilant) return "Vigilant";
        if (pose == CrestTypes.BeastPose.Combatant) return "Combatant";
        if (pose == CrestTypes.BeastPose.Triumphant) return "Triumphant";
        return "Guardian";
    }

    // ============ EXTERNAL GETTERS (for interface compatibility) ============

    function getArchetypeName(
        CrestTypes.Archetype archetype
    ) external pure override returns (string memory) {
        return _getArchetypeName(archetype);
    }
}
