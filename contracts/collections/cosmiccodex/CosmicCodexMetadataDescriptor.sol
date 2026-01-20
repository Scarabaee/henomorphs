// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {ICosmicCodexMetadataDescriptor} from "./ICosmicCodexMetadataDescriptor.sol";

/**
 * @title CosmicCodexMetadataDescriptor
 * @notice Generates on-chain JSON metadata for Henomorphs Cosmic Codex NFTs
 * @dev Uses static IPFS images with on-chain generated JSON metadata
 *      All category and difficulty names are configurable via admin functions
 * @author rutilicus.eth (ArchXS)
 */
contract CosmicCodexMetadataDescriptor is ICosmicCodexMetadataDescriptor, AccessControl {
    using Strings for uint256;
    using Strings for uint16;

    // ═══════════════════════════════════════════════════════════════════════════
    // ROLES
    // ═══════════════════════════════════════════════════════════════════════════

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ═══════════════════════════════════════════════════════════════════════════
    // STORAGE - Configurable strings
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Category names (index 0-6)
    mapping(uint8 => string) private _categoryNames;

    /// @notice Difficulty names (index 0-5)
    mapping(uint8 => string) private _difficultyNames;

    /// @notice Edition name for attributes
    string public editionName;

    /// @notice Collection name for attributes
    string public collectionAttributeName;

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event CategoryNameUpdated(uint8 indexed category, string name);
    event DifficultyNameUpdated(uint8 indexed difficulty, string name);
    event EditionNameUpdated(string name);
    event CollectionAttributeNameUpdated(string name);

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);

        // Initialize default category names
        _categoryNames[0] = "Unknown";
        _categoryNames[1] = "Cosmology";
        _categoryNames[2] = "Quantum Physics";
        _categoryNames[3] = "Astrobiology";
        _categoryNames[4] = "Dark Matter";
        _categoryNames[5] = "Multiverse";
        _categoryNames[6] = "Time & Space";

        // Initialize default difficulty names
        _difficultyNames[0] = "Unknown";
        _difficultyNames[1] = "Novice";
        _difficultyNames[2] = "Intermediate";
        _difficultyNames[3] = "Advanced";
        _difficultyNames[4] = "Expert";
        _difficultyNames[5] = "Legendary";

        // Initialize edition and collection names
        editionName = "Edition 1";
        collectionAttributeName = "Henomorphs: Cosmic Codex";
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TOKEN URI GENERATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Generate full token URI with JSON metadata
     */
    function tokenURI(
        uint256 /* tokenId */,
        TheoryData memory theory,
        CollectionConfig memory collectionConfig
    ) external view override returns (string memory) {
        string memory attributes = _generateAttributes(theory);

        string memory json = string(abi.encodePacked(
            '{"name":"Theory ',
            uint256(theory.theoryId).toString(),
            ': ',
            theory.title,
            '","description":"',
            _escapeJSON(theory.description),
            '","image":"',
            theory.imageUri,
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

    function _generateAttributes(TheoryData memory theory) internal view returns (string memory) {
        string memory part1 = string(abi.encodePacked(
            '[',
            '{"trait_type":"Theory","value":"',
            uint256(theory.theoryId).toString(),
            '"},',
            '{"trait_type":"Title","value":"',
            theory.title,
            '"},'
        ));

        string memory part2 = string(abi.encodePacked(
            '{"trait_type":"Category","value":"',
            getCategoryName(theory.category),
            '"},',
            '{"trait_type":"Difficulty","value":"',
            getDifficultyName(theory.difficulty),
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
     * @notice Get human-readable category name
     */
    function getCategoryName(uint8 category) public view override returns (string memory) {
        string memory name = _categoryNames[category];
        if (bytes(name).length == 0) {
            return _categoryNames[0]; // Return "Unknown"
        }
        return name;
    }

    /**
     * @notice Get human-readable difficulty name
     */
    function getDifficultyName(uint8 difficulty) public view override returns (string memory) {
        string memory name = _difficultyNames[difficulty];
        if (bytes(name).length == 0) {
            return _difficultyNames[0]; // Return "Unknown"
        }
        return name;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS - Configure names
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Set category name
     * @param category Category ID (0-6)
     * @param name Human-readable name
     */
    function setCategoryName(uint8 category, string calldata name) external onlyRole(ADMIN_ROLE) {
        _categoryNames[category] = name;
        emit CategoryNameUpdated(category, name);
    }

    /**
     * @notice Batch set multiple category names
     * @param categories Array of category IDs
     * @param names Array of names
     */
    function setCategoryNamesBatch(
        uint8[] calldata categories,
        string[] calldata names
    ) external onlyRole(ADMIN_ROLE) {
        require(categories.length == names.length, "Length mismatch");
        for (uint256 i = 0; i < categories.length; i++) {
            _categoryNames[categories[i]] = names[i];
            emit CategoryNameUpdated(categories[i], names[i]);
        }
    }

    /**
     * @notice Set difficulty name
     * @param difficulty Difficulty ID (0-5)
     * @param name Human-readable name
     */
    function setDifficultyName(uint8 difficulty, string calldata name) external onlyRole(ADMIN_ROLE) {
        _difficultyNames[difficulty] = name;
        emit DifficultyNameUpdated(difficulty, name);
    }

    /**
     * @notice Batch set multiple difficulty names
     * @param difficulties Array of difficulty IDs
     * @param names Array of names
     */
    function setDifficultyNamesBatch(
        uint8[] calldata difficulties,
        string[] calldata names
    ) external onlyRole(ADMIN_ROLE) {
        require(difficulties.length == names.length, "Length mismatch");
        for (uint256 i = 0; i < difficulties.length; i++) {
            _difficultyNames[difficulties[i]] = names[i];
            emit DifficultyNameUpdated(difficulties[i], names[i]);
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
