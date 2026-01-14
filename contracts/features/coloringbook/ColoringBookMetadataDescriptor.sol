// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IColoringBookMetadataDescriptor} from "./IColoringBookMetadataDescriptor.sol";

/**
 * @title ColoringBookMetadataDescriptor
 * @notice Generates on-chain JSON metadata for Henomorphs Coloring Book NFTs
 * @dev Uses static IPFS images with on-chain generated JSON metadata
 *      All territory and region names are configurable via admin functions
 * @author rutilicus.eth (ArchXS)
 */
contract ColoringBookMetadataDescriptor is IColoringBookMetadataDescriptor, AccessControl {
    using Strings for uint256;
    using Strings for uint16;

    // ═══════════════════════════════════════════════════════════════════════════
    // ROLES
    // ═══════════════════════════════════════════════════════════════════════════

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE - Configurable strings
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Territory type names (index 0-5)
    mapping(uint8 => string) private _territoryTypeNames;

    /// @notice Region names (index 0-7)
    mapping(uint8 => string) private _regionNames;

    /// @notice Edition name for attributes
    string public editionName;

    /// @notice Collection name for attributes
    string public collectionAttributeName;

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event TerritoryTypeNameUpdated(uint8 indexed territoryType, string name);
    event RegionNameUpdated(uint8 indexed region, string name);
    event EditionNameUpdated(string name);
    event CollectionAttributeNameUpdated(string name);

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);

        // Initialize default territory type names
        _territoryTypeNames[0] = "Unknown";
        _territoryTypeNames[1] = "ZICO Mine";
        _territoryTypeNames[2] = "Trade Hub";
        _territoryTypeNames[3] = "Fortress";
        _territoryTypeNames[4] = "Observatory";
        _territoryTypeNames[5] = "Sanctuary";

        // Initialize default region names (matching illustration generator)
        _regionNames[0] = "Unknown";
        _regionNames[1] = "Northern Region: The Golden Roost";
        _regionNames[2] = "Central Region: The Great Marketplace";
        _regionNames[3] = "Southern Region: The Fortress Peaks";
        _regionNames[4] = "Eastern Region: The Wild Territories";
        _regionNames[5] = "Legendary Center: The Crown Jewels";
        _regionNames[6] = "The Sacred Grounds";
        _regionNames[7] = "Tech Frontier";

        // Initialize edition and collection names
        editionName = "Edition 1";
        collectionAttributeName = "Henomorphs: The Nexus Quest";
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOKEN URI GENERATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Generate full token URI with JSON metadata
     */
    function tokenURI(
        uint256 /* tokenId */,
        ChapterData memory chapter,
        CollectionConfig memory collectionConfig
    ) external view override returns (string memory) {
        string memory attributes = _generateAttributes(chapter);

        string memory json = string(abi.encodePacked(
            '{"name":"Chapter ',
            uint256(chapter.chapterId).toString(),
            ': ',
            chapter.title,
            '","description":"',
            _escapeJSON(chapter.story),
            '","image":"',
            chapter.imageUri,
            '","external_url":"',
            collectionConfig.externalLink,
            '","attributes":',
            attributes,
            '}'
        ));

        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        ));
    }

    /**
     * @notice Generate contract-level metadata URI
     */
    function contractURI(
        CollectionConfig memory collectionConfig
    ) external pure override returns (string memory) {
        string memory json = string(abi.encodePacked(
            '{"name":"',
            collectionConfig.name,
            '","description":"',
            _escapeJSON(collectionConfig.description),
            '","image":"',
            collectionConfig.imageUri,
            '","external_link":"',
            collectionConfig.externalLink,
            '","seller_fee_basis_points":500,"fee_recipient":"0x0000000000000000000000000000000000000000"}'
        ));

        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        ));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ATTRIBUTE GENERATION
    // ═══════════════════════════════════════════════════════════════════════════

    function _generateAttributes(ChapterData memory chapter) internal view returns (string memory) {
        string memory part1 = string(abi.encodePacked(
            '[',
            '{"trait_type":"Chapter","value":"',
            uint256(chapter.chapterId).toString(),
            '"},',
            '{"trait_type":"Title","value":"',
            chapter.title,
            '"},'
        ));

        string memory part2 = string(abi.encodePacked(
            '{"trait_type":"Territory Type","value":"',
            getTerritoryTypeName(chapter.territoryType),
            '"},',
            '{"trait_type":"Region","value":"',
            getRegionName(chapter.region),
            '"},'
        ));

        string memory part3 = string(abi.encodePacked(
            '{"trait_type":"Edition","value":"', editionName, '"},',
            '{"trait_type":"Collection","value":"', collectionAttributeName, '"}',
            ']'
        ));

        return string(abi.encodePacked(part1, part2, part3));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // NAME GETTERS (from storage)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get human-readable territory type name
     */
    function getTerritoryTypeName(uint8 territoryType) public view override returns (string memory) {
        string memory name = _territoryTypeNames[territoryType];
        if (bytes(name).length == 0) {
            return _territoryTypeNames[0]; // Return "Unknown"
        }
        return name;
    }

    /**
     * @notice Get human-readable region name
     */
    function getRegionName(uint8 region) public view override returns (string memory) {
        string memory name = _regionNames[region];
        if (bytes(name).length == 0) {
            return _regionNames[0]; // Return "Unknown"
        }
        return name;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS - Configure names
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Set territory type name
     * @param territoryType Territory type ID (0-5)
     * @param name Human-readable name
     */
    function setTerritoryTypeName(uint8 territoryType, string calldata name) external onlyRole(ADMIN_ROLE) {
        _territoryTypeNames[territoryType] = name;
        emit TerritoryTypeNameUpdated(territoryType, name);
    }

    /**
     * @notice Batch set multiple territory type names
     * @param territoryTypes Array of territory type IDs
     * @param names Array of names
     */
    function setTerritoryTypeNamesBatch(
        uint8[] calldata territoryTypes,
        string[] calldata names
    ) external onlyRole(ADMIN_ROLE) {
        require(territoryTypes.length == names.length, "Length mismatch");
        for (uint256 i = 0; i < territoryTypes.length; i++) {
            _territoryTypeNames[territoryTypes[i]] = names[i];
            emit TerritoryTypeNameUpdated(territoryTypes[i], names[i]);
        }
    }

    /**
     * @notice Set region name
     * @param region Region ID (0-7)
     * @param name Human-readable name
     */
    function setRegionName(uint8 region, string calldata name) external onlyRole(ADMIN_ROLE) {
        _regionNames[region] = name;
        emit RegionNameUpdated(region, name);
    }

    /**
     * @notice Batch set multiple region names
     * @param regions Array of region IDs
     * @param names Array of names
     */
    function setRegionNamesBatch(
        uint8[] calldata regions,
        string[] calldata names
    ) external onlyRole(ADMIN_ROLE) {
        require(regions.length == names.length, "Length mismatch");
        for (uint256 i = 0; i < regions.length; i++) {
            _regionNames[regions[i]] = names[i];
            emit RegionNameUpdated(regions[i], names[i]);
        }
    }

    /**
     * @notice Set edition name for attributes
     * @param name Edition name (e.g., "Edition 1", "Season 2")
     */
    function setEditionName(string calldata name) external onlyRole(ADMIN_ROLE) {
        editionName = name;
        emit EditionNameUpdated(name);
    }

    /**
     * @notice Set collection attribute name
     * @param name Collection name for attributes
     */
    function setCollectionAttributeName(string calldata name) external onlyRole(ADMIN_ROLE) {
        collectionAttributeName = name;
        emit CollectionAttributeNameUpdated(name);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UTILITY FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Escape special characters for JSON
     */
    function _escapeJSON(string memory input) internal pure returns (string memory) {
        bytes memory inputBytes = bytes(input);
        uint256 extraChars = 0;

        // Count characters that need escaping
        for (uint256 i = 0; i < inputBytes.length; i++) {
            if (inputBytes[i] == '"' || inputBytes[i] == '\\' || inputBytes[i] == '\n' || inputBytes[i] == '\r') {
                extraChars++;
            }
        }

        if (extraChars == 0) {
            return input;
        }

        bytes memory output = new bytes(inputBytes.length + extraChars);
        uint256 j = 0;

        for (uint256 i = 0; i < inputBytes.length; i++) {
            if (inputBytes[i] == '"') {
                output[j++] = '\\';
                output[j++] = '"';
            } else if (inputBytes[i] == '\\') {
                output[j++] = '\\';
                output[j++] = '\\';
            } else if (inputBytes[i] == '\n') {
                output[j++] = '\\';
                output[j++] = 'n';
            } else if (inputBytes[i] == '\r') {
                output[j++] = '\\';
                output[j++] = 'r';
            } else {
                output[j++] = inputBytes[i];
            }
        }

        return string(output);
    }
}
