// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/**
 * @title AchievementMetadata
 * @notice Library for generating on-chain JSON metadata for Achievement NFTs
 * @dev Separated from SVG generation for modularity and gas optimization
 * @author rutilicus.eth (ArchXS)
 */
library AchievementMetadata {
    using Strings for uint256;
    using Strings for uint8;

    // ═══════════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    struct AchievementData {
        uint256 achievementId;
        string name;
        string description;
        uint8 category;     // 1=Combat, 2=Territory, 3=Economic, 4=Collection, 5=Social, 6=Special
        uint8 tier;         // 1=Bronze, 2=Silver, 3=Gold, 4=Platinum
        uint8 maxTier;      // Maximum achievable tier
        bool soulbound;
        bool progressive;
        uint32 earnedAt;
        uint256 progress;
        uint256 progressMax;
        string externalUrl;
    }

    struct AttributeData {
        string traitType;
        string value;
        bool isNumeric;
        uint256 numericValue;
        uint256 maxValue;      // For display_type: "number" with max
        bool hasMaxValue;
        string displayType;    // "number", "date", "boost_number", "boost_percentage"
    }

    /// @notice Collection configuration for contract-level metadata
    struct CollectionConfig {
        string name;           // Collection name (e.g., "Henomorphs Achievements")
        string description;    // Collection description
        string imageUri;       // Collection logo/image URI (e.g., "ipfs://.../" ending with /)
        string baseUri;        // Base URI for individual badge images (e.g., "ipfs://.../badges/")
        string externalLink;   // External website link
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // MAIN METADATA GENERATION
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Generate complete token URI with embedded SVG
     * @param data Achievement data
     * @param svgImage Base64 encoded SVG or raw SVG string
     * @param isSvgBase64 Whether svgImage is already base64 encoded
     * @return Complete data URI with JSON metadata
     */
    function generateTokenURI(
        AchievementData memory data,
        string memory svgImage,
        bool isSvgBase64
    ) internal pure returns (string memory) {
        string memory imageUri;

        if (isSvgBase64) {
            imageUri = string.concat("data:image/svg+xml;base64,", svgImage);
        } else {
            imageUri = string.concat(
                "data:image/svg+xml;base64,",
                Base64.encode(bytes(svgImage))
            );
        }

        string memory json = _buildMetadataJSON(data, imageUri);

        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        );
    }

    /**
     * @notice Generate metadata JSON without image (for external image hosting)
     * @param data Achievement data
     * @param imageUrl External image URL
     * @return Complete data URI with JSON metadata
     */
    function generateTokenURIWithExternalImage(
        AchievementData memory data,
        string memory imageUrl
    ) internal pure returns (string memory) {
        string memory json = _buildMetadataJSON(data, imageUrl);

        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        );
    }

    /**
     * @notice Generate raw JSON metadata (not base64 encoded)
     * @param data Achievement data
     * @param imageUri Image URI (data URI or external URL)
     * @return Raw JSON string
     */
    function generateRawJSON(
        AchievementData memory data,
        string memory imageUri
    ) internal pure returns (string memory) {
        return _buildMetadataJSON(data, imageUri);
    }

    /**
     * @notice Generate contract-level metadata URI (OpenSea collection standard)
     * @param config Collection configuration
     * @return Complete data URI with JSON metadata
     * @dev imageUri should be the full path to collection logo (e.g., "ipfs://.../logo.png")
     *      baseUri is used for individual badge images, not for contract metadata
     */
    function generateContractURI(
        CollectionConfig memory config
    ) internal pure returns (string memory) {
        string memory json = string.concat(
            '{"name":"', _escapeJSON(config.name), '"',
            ',"description":"', _escapeJSON(config.description), '"',
            ',"image":"', config.imageUri, '"'
        );

        if (bytes(config.externalLink).length > 0) {
            json = string.concat(json, ',"external_link":"', config.externalLink, '"');
        }

        json = string.concat(json, '}');

        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // JSON BUILDING
    // ═══════════════════════════════════════════════════════════════════════════

    function _buildMetadataJSON(
        AchievementData memory data,
        string memory imageUri
    ) private pure returns (string memory) {
        string memory tierName = getTierName(data.tier);
        string memory categoryName = getCategoryName(data.category);

        return string.concat(
            '{',
            _buildBasicFields(data, tierName, imageUri),
            ',',
            _buildAttributes(data, tierName, categoryName),
            '}'
        );
    }

    function _buildBasicFields(
        AchievementData memory data,
        string memory tierName,
        string memory imageUri
    ) private pure returns (string memory) {
        string memory fullName = string.concat(data.name, " - ", tierName);

        string memory result = string.concat(
            '"name":"', _escapeJSON(fullName), '",',
            '"description":"', _escapeJSON(data.description), '",',
            '"image":"', imageUri, '"'
        );

        // Add external_url if provided
        if (bytes(data.externalUrl).length > 0) {
            result = string.concat(
                result,
                ',"external_url":"', data.externalUrl, '"'
            );
        }

        return result;
    }

    function _buildAttributes(
        AchievementData memory data,
        string memory tierName,
        string memory categoryName
    ) private pure returns (string memory) {
        string memory attrs = string.concat(
            '"attributes":[',
            _buildAttribute("Category", categoryName, false),
            ',',
            _buildAttribute("Tier", tierName, false),
            ',',
            _buildNumericAttribute("Achievement ID", data.achievementId),
            ',',
            _buildNumericAttribute("Category ID", uint256(data.category)),
            ',',
            _buildNumericAttribute("Tier ID", uint256(data.tier)),
            ',',
            _buildAttribute("Soulbound", data.soulbound ? "Yes" : "No", false),
            ',',
            _buildAttribute("Progressive", data.progressive ? "Yes" : "No", false),
            ',',
            _buildAttribute("Rarity", _getRarityFromTier(data.tier), false)
        );

        // Add max tier
        if (data.maxTier > 0) {
            attrs = string.concat(
                attrs,
                ',',
                _buildNumericAttribute("Max Tier", uint256(data.maxTier)),
                ',',
                _buildAttribute("Max Tier Name", getTierName(data.maxTier), false)
            );
        }

        // Add earned timestamp if available
        if (data.earnedAt > 0) {
            attrs = string.concat(
                attrs,
                ',',
                _buildDateAttribute("Date Earned", data.earnedAt)
            );
        }

        // Add progress for progressive achievements
        if (data.progressive) {
            attrs = string.concat(
                attrs,
                ',',
                _buildNumericAttribute("Progress", data.progress),
                ',',
                _buildNumericAttribute("Progress Max", data.progressMax)
            );
        }

        return string.concat(attrs, ']');
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ATTRIBUTE BUILDERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _buildAttribute(
        string memory traitType,
        string memory value,
        bool /*isNumeric*/
    ) private pure returns (string memory) {
        return string.concat(
            '{"trait_type":"', traitType, '","value":"', value, '"}'
        );
    }

    function _buildNumericAttribute(
        string memory traitType,
        uint256 value
    ) private pure returns (string memory) {
        return string.concat(
            '{"trait_type":"', traitType, '","value":', value.toString(), '}'
        );
    }

    function _buildNumericAttributeWithMax(
        string memory traitType,
        uint256 value,
        uint256 maxValue
    ) private pure returns (string memory) {
        return string.concat(
            '{"display_type":"number","trait_type":"', traitType,
            '","value":', value.toString(),
            ',"max_value":', maxValue.toString(), '}'
        );
    }

    function _buildDateAttribute(
        string memory traitType,
        uint32 timestamp
    ) private pure returns (string memory) {
        return string.concat(
            '{"display_type":"date","trait_type":"', traitType,
            '","value":', uint256(timestamp).toString(), '}'
        );
    }

    function _buildBoostAttribute(
        string memory traitType,
        uint256 value,
        bool isPercentage
    ) private pure returns (string memory) {
        string memory displayType = isPercentage ? "boost_percentage" : "boost_number";
        return string.concat(
            '{"display_type":"', displayType, '","trait_type":"', traitType,
            '","value":', value.toString(), '}'
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UTILITY FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get tier name from tier ID
     */
    function getTierName(uint8 tier) internal pure returns (string memory) {
        if (tier == 1) return "Bronze";
        if (tier == 2) return "Silver";
        if (tier == 3) return "Gold";
        if (tier == 4) return "Platinum";
        return "None";
    }

    /**
     * @notice Get category name from category ID
     */
    function getCategoryName(uint8 category) internal pure returns (string memory) {
        if (category == 1) return "Combat";
        if (category == 2) return "Territory";
        if (category == 3) return "Economic";
        if (category == 4) return "Collection";
        if (category == 5) return "Social";
        if (category == 6) return "Special";
        return "None";
    }

    /**
     * @notice Get rarity string based on tier
     */
    function _getRarityFromTier(uint8 tier) private pure returns (string memory) {
        if (tier == 1) return "Common";
        if (tier == 2) return "Uncommon";
        if (tier == 3) return "Rare";
        if (tier == 4) return "Legendary";
        return "Unknown";
    }

    /**
     * @notice Escape special characters in JSON strings
     * @dev Handles quotes, backslashes, and control characters
     */
    function _escapeJSON(string memory input) private pure returns (string memory) {
        bytes memory inputBytes = bytes(input);
        uint256 extraChars = 0;

        // Count characters that need escaping
        for (uint256 i = 0; i < inputBytes.length; i++) {
            bytes1 char = inputBytes[i];
            if (char == '"' || char == '\\' || char == '\n' || char == '\r' || char == '\t') {
                extraChars++;
            }
        }

        // If no escaping needed, return original
        if (extraChars == 0) {
            return input;
        }

        // Build escaped string
        bytes memory output = new bytes(inputBytes.length + extraChars);
        uint256 outputIndex = 0;

        for (uint256 i = 0; i < inputBytes.length; i++) {
            bytes1 char = inputBytes[i];

            if (char == '"') {
                output[outputIndex++] = '\\';
                output[outputIndex++] = '"';
            } else if (char == '\\') {
                output[outputIndex++] = '\\';
                output[outputIndex++] = '\\';
            } else if (char == '\n') {
                output[outputIndex++] = '\\';
                output[outputIndex++] = 'n';
            } else if (char == '\r') {
                output[outputIndex++] = '\\';
                output[outputIndex++] = 'r';
            } else if (char == '\t') {
                output[outputIndex++] = '\\';
                output[outputIndex++] = 't';
            } else {
                output[outputIndex++] = char;
            }
        }

        return string(output);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BATCH HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Build attributes array from custom AttributeData array
     * @param attributes Array of attribute data
     * @return JSON attributes array string
     */
    function buildCustomAttributes(
        AttributeData[] memory attributes
    ) internal pure returns (string memory) {
        if (attributes.length == 0) {
            return '"attributes":[]';
        }

        string memory result = '"attributes":[';

        for (uint256 i = 0; i < attributes.length; i++) {
            if (i > 0) {
                result = string.concat(result, ",");
            }

            AttributeData memory attr = attributes[i];

            if (bytes(attr.displayType).length > 0) {
                // Has display type (date, number, boost)
                if (attr.hasMaxValue) {
                    result = string.concat(
                        result,
                        _buildNumericAttributeWithMax(attr.traitType, attr.numericValue, attr.maxValue)
                    );
                } else if (keccak256(bytes(attr.displayType)) == keccak256(bytes("date"))) {
                    result = string.concat(
                        result,
                        _buildDateAttribute(attr.traitType, uint32(attr.numericValue))
                    );
                } else {
                    result = string.concat(
                        result,
                        '{"display_type":"', attr.displayType,
                        '","trait_type":"', attr.traitType,
                        '","value":', attr.numericValue.toString(), '}'
                    );
                }
            } else if (attr.isNumeric) {
                result = string.concat(
                    result,
                    _buildNumericAttribute(attr.traitType, attr.numericValue)
                );
            } else {
                result = string.concat(
                    result,
                    _buildAttribute(attr.traitType, attr.value, false)
                );
            }
        }

        return string.concat(result, ']');
    }
}
