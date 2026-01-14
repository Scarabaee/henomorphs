// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";

import "./HenomorphsModel.sol";

/**
 * @notice Structs and enums module which provides metadata library for the Henomorphs collections. 
 *
 * @custom:website https://zicodao.io
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */

library HenomorphsMetadata {
    using Strings for uint256;
    using Strings for uint8;

    struct TokenURIParams {
        uint256 tokenId;
        uint8 tier;
        Specimen specimen;
        string externalUrl;
        Calibration calibration;
        TraitPackEquipment traitPackData;
    }

    // Specimen stats structure
    struct SpecimenStats {
        uint16 strengthBonus;
        uint16 agilityBonus;
        uint16 intelligenceBonus;
        uint16 xpBonus;
    }

    // Constants for tier calculation
    uint8 internal constant TIER_THRESHOLD_1 = 20;
    uint8 internal constant TIER_THRESHOLD_2 = 40;
    uint8 internal constant TIER_THRESHOLD_3 = 70;
    uint8 internal constant TIER_THRESHOLD_4 = 90;
    
    /**
     * @notice Generates complete tokenURI for a Henomorph
     */
    function generateTokenURI(
        TokenURIParams memory params
    ) public view returns (string memory) {
        // Generate image URL for standard token (no trait pack)
        string memory imageUrl = _generateImageURL(params.tokenId, params.tier, params.specimen, false, 0);
        
        // Generate metadata
        string memory json = _generateMetadataJSON(
            params.tokenId,
            params.specimen,
            params.calibration,
            _calculateCalibrationLevel(params.specimen, params.calibration),
            imageUrl,
            params.externalUrl
        );
        
        // Encode JSON to Base64
        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        ));
    }

    /**
     * @notice Generates complete tokenURI for an augmented Henomorph
     */
    function generateAugmentedTokenURI(
        TokenURIParams memory params
    ) public view returns (string memory) {
        // Generate image URL for augmented token with trait pack variant
        bool hasTraitPack = params.traitPackData.traitPackCollection != address(0);
        string memory imageUrl = _generateImageURL(
            params.tokenId, 
            params.tier, 
            params.specimen, 
            hasTraitPack, 
            params.traitPackData.variant
        );
        
        string memory json = _generateAugmentedMetadataJSON(
            params.tokenId,
            params.specimen,
            params.calibration,
            params.traitPackData,
            _calculateCalibrationLevel(params.specimen, params.calibration),
            imageUrl,
            params.externalUrl
        );
        
        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        ));
    }

    function getTraitPackName(uint8 variant) public pure returns (string memory) {
        if (variant == 1) return "Voight-Kampff Set";
        if (variant == 2) return "Spinner Escape Pack";
        if (variant == 3) return "Nexus Dreamer";
        if (variant == 4) return "Baseline Override";
        return "Unknown Augment";
    }

    /**
     * @notice Calculates a calibration level based on various Calibration struct data
     */
    function _calculateCalibrationLevel(Specimen memory specimen, Calibration memory calibration) internal view returns (uint256) {
        // Base calibration values differ based on form type
        uint8[5] memory baseCalibrationByForm = [40, 45, 50, 55, 60];
        uint256 variant = specimen.variant;
        uint256 baseCalibration = baseCalibrationByForm[variant];
        
        // Experience scaling
        uint256 experienceBonus = 0;
        if (calibration.experience > 0) {
            experienceBonus = Math.sqrt(calibration.experience) / 2;
            experienceBonus = experienceBonus > 15 ? 15 : experienceBonus;
        }
        
        // Kinship affects calibration positively
        uint256 kinshipFactor = 0;
        if (calibration.kinship > 50) {
            kinshipFactor = (calibration.kinship - 50) / 5;
        }
        
        // Wear affects calibration negatively
        uint256 wearPenalty = 0;
        if (calibration.wear > 0) {
            wearPenalty = (calibration.wear * calibration.wear) / 400;
        }
        
        // Time since last recalibration affects calibration negatively
        uint256 recalibrationPenalty = 0;
        if (calibration.lastRecalibration > 0) {
            uint256 daysSinceRecalibration = (block.timestamp - calibration.lastRecalibration) / 1 days;
            
            if (daysSinceRecalibration > 0) {
                if (daysSinceRecalibration <= 7) {
                    recalibrationPenalty = daysSinceRecalibration * 10 / 7;
                } else {
                    recalibrationPenalty = 10 + ((daysSinceRecalibration - 7) * 20 / 23);
                    recalibrationPenalty = recalibrationPenalty > 30 ? 30 : recalibrationPenalty;
                }
            }
        }
        
        // Form-specific calibration modifiers
        int256 formModifier = 0;
        if (variant == 0) {
            formModifier = -5;
        } else if (variant == 3) {
            formModifier = 3;
        } else if (variant == 4) {
            formModifier = 5;
        }
        
        // Calculate final calibration value
        int256 calibrationValue = int256(baseCalibration) + 
                                int256(experienceBonus) + 
                                int256(kinshipFactor) - 
                                int256(wearPenalty) - 
                                int256(recalibrationPenalty) +
                                formModifier;
        
        // Ensure result is within bounds (0-100)
        if (calibrationValue < 0) return 0;
        if (calibrationValue > 100) return 100;
        
        return uint256(calibrationValue);
    }

    /**
     * @notice Generates image URL based on parameters
     * @param hasTraitPack Whether token has assigned trait pack
     * @param augmentVariant Variant of the assigned trait pack
     */
    function _generateImageURL(
        uint256,
        uint8 tier,
        Specimen memory specimen,
        bool hasTraitPack,
        uint8 augmentVariant
    ) internal pure returns (string memory) {
        string memory _imageUri = string.concat(
            specimen.baseUri,
            "H",
            tier.toString(),
            "_",
            specimen.variant.toString()
        );

        // Add trait pack variant if token has augment assigned
        if (hasTraitPack) {
            _imageUri = string.concat(
                _imageUri,
                "_T",
                augmentVariant.toString()
            );
        } else if (specimen.form > 0) {
            // Add form only if no trait pack is assigned
            _imageUri = string.concat(
                _imageUri, 
                "_",
                specimen.form.toString()
            );
        }

        _imageUri = string.concat(
            _imageUri, 
            ".png"
        );

        return _imageUri;
    }

    /**
     * @notice Generates metadata JSON for standard token
     */
    function _generateMetadataJSON(
        uint256 tokenId,
        Specimen memory specimen,
        Calibration memory calibration,
        uint256 level,
        string memory imageUrl,
        string memory externalUrl
    ) internal view returns (string memory) {
        string memory description = _generateDescription(specimen, calibration, level);
        string memory baseAttributes = _generateBaseAttributes(specimen, level);
        
        // Always generate operational attributes for calibration data
        string memory operationalAttributes = _generateOperationalAttributes(calibration, level);

        return _assembleMetadataJSON(
            tokenId,
            description,
            imageUrl,
            externalUrl,
            baseAttributes,
            operationalAttributes
        );
    }

    /**
     * @notice Generates metadata JSON for augmented token
     */
    function _generateAugmentedMetadataJSON(
        uint256 tokenId,
        Specimen memory specimen,
        Calibration memory calibration,
        TraitPackEquipment memory traitPackData,
        uint256 level,
        string memory imageUrl,
        string memory externalUrl
    ) internal view returns (string memory) {
        
        bool hasTraitPack = traitPackData.traitPackCollection != address(0);
        
        string memory enhancedName = string(abi.encodePacked(
            "Henomorph #", 
            tokenId.toString(),
            hasTraitPack ? string(abi.encodePacked(" + ", getTraitPackName(traitPackData.variant))) : ""
        ));
        
        string memory enhancedDescription = hasTraitPack 
            ? string(abi.encodePacked(
                specimen.description,
                " Enhanced with ",
                getTraitPackName(traitPackData.variant),
                " providing specialized accessories and bonuses."
            ))
            : _generateDescription(specimen, calibration, level);
        
        string memory baseAttributes = _generateBaseAttributes(specimen, level);
        
        // Always generate operational attributes for calibration data
        string memory operationalAttributes = _generateOperationalAttributes(calibration, level);
        
        string memory traitPackAttributes = "";
        if (hasTraitPack) {
            traitPackAttributes = _generateTraitPackAttributes(traitPackData);
        }
        
        return _assembleAugmentedMetadataJSON(
            enhancedName,
            enhancedDescription,
            imageUrl,
            externalUrl,
            baseAttributes,
            operationalAttributes,
            traitPackAttributes
        );
    }

    function _generateTraitPackAttributes(TraitPackEquipment memory traitPackData) internal pure returns (string memory) {
        return string(abi.encodePacked(
            '{"trait_type":"Trait Pack","value":"', getTraitPackName(traitPackData.variant), '"},',
            '{"trait_type":"Trait Pack ID","value":"', traitPackData.traitPackTokenId.toString(), '"},',
            '{"trait_type":"Trait Pack Variant","value":', traitPackData.variant.toString(), '},',
            '{"trait_type":"Accessories Count","value":', traitPackData.accessoryIds.length.toString(), '},',
            '{"trait_type":"Enhanced","value":"Yes"}'
        ));
    }

    function _assembleAugmentedMetadataJSON(
        string memory name,
        string memory description,
        string memory imageUrl,
        string memory externalURL,
        string memory baseAttributes,
        string memory operationalAttributes,
        string memory traitPackAttributes
    ) internal pure returns (string memory) {
        
        string memory json = string(abi.encodePacked(
            '{"name":"', name, '",',
            '"symbol":"HMS",',
            '"description":"', description, '",',
            '"image":"', imageUrl, '",',
            '"external_url":"', externalURL, '",',
            '"animation_url":"",',
            '"attributes":[', baseAttributes
        ));
        
        if (bytes(operationalAttributes).length > 0) {
            json = string(abi.encodePacked(json, ',', operationalAttributes));
        }
        
        if (bytes(traitPackAttributes).length > 0) {
            json = string(abi.encodePacked(json, ',', traitPackAttributes));
        }
        
        json = string(abi.encodePacked(json, ']}'));
        
        return json;
    }

    /**
     * @notice Generates the description part of metadata
     */
    function _generateDescription(
        Specimen memory specimen,
        Calibration memory calibration,
        uint256 level
    ) internal view returns (string memory) {
        string memory description = specimen.description;

        description = string.concat(
            description, 
            " It utilizes ", 
            _getFormDescriptor(specimen.variant), 
            " technology."
        );

        if (calibration.calibrationCount > 0) {
            description = _appendDynamicStatus(description, calibration, level);
        }
        
        return description;
    }

    /**
     * @notice Generates base attributes that are always present
     */
    function _generateBaseAttributes(
        Specimen memory specimen,
        uint256 level
    ) internal pure returns (string memory) {
        return string.concat(
            '{"trait_type":"Form","value":"',
            specimen.formName,
            '"},',
            '{"trait_type":"Level","value":"',
            level.toString(),
            '"},',
            '{"trait_type":"Generation","value":"',
            uint256(specimen.generation).toString(),
            '"},',
            '{"trait_type":"Augmentation","value":"',
            uint256(specimen.augmentation).toString(),
            '"}'
        );
    }

    /**
     * @notice Generates attributes for operational metrics
     */
    function _generateOperationalAttributes(
        Calibration memory calibration,
        uint256 level
    ) internal pure returns (string memory) {
        return string.concat(
            '{"trait_type":"Calibration","value":"',
            _getCalibrationTierName(level),
            '"},'
            '{"trait_type":"Maintenance","value":',
            calibration.kinship.toString(),
            '},'
            '{"trait_type":"Experience","value":',
            calibration.experience.toString(),
            '},',
            '{"trait_type":"Calibrations","value":',
            calibration.calibrationCount.toString(),
            '},',
            '{"trait_type":"Last Recalibration","value":',
            calibration.lastRecalibration.toString(),
            ',"display_type":"date"}'
        );
    }

    /**
     * @notice Assembles the final metadata JSON
     */
    function _assembleMetadataJSON(
        uint256 tokenId,
        string memory description,
        string memory imageUrl,
        string memory externalURL,
        string memory baseAttributes,
        string memory operationalAttributes
    ) internal pure returns (string memory) {
        string memory json = string.concat(
            '{"name":"Henomorph #',
            tokenId.toString(),
            '","symbol":"HMS",',
            '"description":"',
            description,
            '","image":"',
            imageUrl,
            '","external_url":"',
            externalURL,
            '","animation_url":"",',
            '"attributes":['
        );
        
        json = string.concat(json, baseAttributes);
        
        // Add operational attributes (always present)
        if (bytes(operationalAttributes).length > 0) {
            json = string.concat(json, ',', operationalAttributes);
        }
 
        json = string.concat(json, ']}');
        
        return json;
    }

    /**
     * @notice Appends dynamic status to the standard description
     */
    function _appendDynamicStatus(
        string memory baseDescription,
        Calibration memory calibration,
        uint256 level
    ) internal view returns (string memory) {
        string memory calibrationStatus = _getCalibrationTierName(level);
        string memory chargeStatus = _getChargeTierName(calibration.charge);
        
        uint256 timeSinceLastInteraction = block.timestamp - calibration.lastRecalibration;
        string memory maintenanceStatus;
        
        if (timeSinceLastInteraction < 1 days) {
            maintenanceStatus = "recently maintained";
        } else if (timeSinceLastInteraction < 3 days) {
            maintenanceStatus = "needs attention soon";
        } else {
            maintenanceStatus = "requires immediate calibration";
        }
        
        string memory bondStatus;
        if (calibration.kinship >= 80) {
            bondStatus = "optimized";
        } else if (calibration.kinship >= 50) {
            bondStatus = "maintained";
        } else if (calibration.kinship >= 20) {
            bondStatus = "irregular";
        } else {
            bondStatus = "neglected";
        }
        
        string memory wearStatus;
        if (calibration.wear >= 80) {
            wearStatus = "heavily worn";
        } else if (calibration.wear >= 50) {
            wearStatus = "showing signs of wear";
        } else if (calibration.wear >= 20) {
            wearStatus = "lightly worn";
        } else {
            wearStatus = "pristine";
        }
        
        return string.concat(
            baseDescription,
            " Status: ", 
            calibrationStatus, 
            " calibration, ",
            chargeStatus,
            " charge. Unit is ",
            wearStatus,
            " and ",
            bondStatus,
            ". Maintenance status: ",
            maintenanceStatus,
            "."
        );
    }

    function _getFormDescriptor(uint8 form) internal pure returns (string memory) {
        string[5] memory descriptors = [
            "primordial data matrix",
            "basic sensory",
            "enhanced processing",
            "sophisticated neural",
            "quantum neural"
        ];
        
        if (form >= 1 && form <= 4) {
            return descriptors[form];
        } else {
            return descriptors[0];
        }
    }

    /**
     * @notice Converts percentage level to tier
     */
    function _getTraitTier(uint256 value) internal pure returns (uint8) {
        if (value < TIER_THRESHOLD_1) return 0;
        if (value < TIER_THRESHOLD_2) return 1;
        if (value < TIER_THRESHOLD_3) return 2;
        if (value < TIER_THRESHOLD_4) return 3;
        return 4;
    }
    
    /**
     * @notice Get calibration tier name based on value
     */
    function _getCalibrationTierName(uint256 calibration) internal pure returns (string memory) {
        string[5] memory calibrationTiers = [
            "Critical",
            "Unstable",
            "Nominal",
            "Hypertuned",
            "Quantum"
        ];
        return calibrationTiers[_getTraitTier(calibration)];
    }
    
    /**
     * @notice Get charge tier name based on value
     */
    function _getChargeTierName(uint256 charge) internal pure returns (string memory) {
        string[5] memory chargeTiers = [
            "Depleted",
            "Low",
            "Medium",
            "High",
            "Full"
        ];
        return chargeTiers[_getTraitTier(charge)];
    }

}