// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Specimen, Calibration, PowerMatrix, TraitPack} from "../libraries/CollectionModel.sol";
import {MetadataFallback, StakingStatus, AccessoryBonuses, CompatibilityScores} from "../libraries/MetadataFallback.sol";
import {Equipment} from "../libraries/ModularAssetModel.sol";
import {LibCollectionStorage} from "../libraries/LibCollectionStorage.sol";

// Interface for external collections
interface IExternalCollection {
    function itemVariant(uint256 tokenId) external view returns (uint8);
}

/**
 * @title MetadataHelper - FIXED Collection-Scoped Accessory Lookup
 * @notice ENHANCED: Fixed to read accessory names from collection-scoped storage
 * @dev All original functions preserved + fixed accessory name resolution
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 * @custom:version 4.1.3 - Fixed accessory name lookup
 */
library MetadataHelper {
    using Strings for uint256;
    using Strings for uint8;
    using Strings for uint64;
    
    // ==================== STRUCTS - ALL ORIGINAL PRESERVED ====================
    
    struct CoreTokenData {
        uint256 tokenId;
        uint8 tokenTier;
        uint8 tokenVariant;
        string baseUri;
        string externalUrl;
        string animationUri;
    }
    
    struct SystemData {
        Specimen specimen;
        Calibration calibration;
        PowerMatrix powerMatrix;
        StakingStatus stakingStatus;
        AccessoryBonuses accessoryBonuses;
        CompatibilityScores compatibility;
    }
    
    struct ModularData {
        uint8 activeTraitPackId;
        string traitPackName;
        string traitPackUri;
        uint64 activeAssetId;
        string assetUri;
        Equipment[] equipments;
    }

    struct ThemeData {
        bool hasTheme;
        string themeName;
        string technologyBase;
        string evolutionContext;
        string universeContext;
        string evolutionStage;
        string powerLevel;
        bool hasCustomVariantTheme;
    }
    
    struct TokenMetadataParams {
        uint256 tokenId;
        Specimen specimen;
        uint8 tokenTier;
        uint8 tokenVariant;
        Calibration calibration;
        PowerMatrix powerMatrix;
        uint8 activeTraitPackId;
        string traitPackName;
        string traitPackUri;
        uint64 activeAssetId;
        string assetUri;
        Equipment[] equipments;
        AccessoryBonuses accessoryBonuses;
        StakingStatus stakingStatus;
        CompatibilityScores compatibility;
        string baseUri;
        string externalUrl;
        string animationUri;
    }
    
    struct AugmentInfo {
        string traitPackName;
        uint8 traitPackId;
        bool hasTraitPack;
        uint8[] accessoryIds;
        uint8[] compatibleVariants;
    }
    
    // ==================== MAIN COLLECTION METADATA - ALL ORIGINAL PRESERVED ====================
    
    function generateTokenMetadata(
        TokenMetadataParams memory params
    ) external pure returns (string memory) {
        return _processTokenMetadata(params);
    }
    
    function generateTokenMetadataFromData(
        CoreTokenData memory coreData,
        SystemData memory systemData,
        ModularData memory modularData
    ) public pure returns (string memory) {
        return _processFromStructs(coreData, systemData, modularData);
    }

    function generateTokenMetadataWithTheme(
        CoreTokenData memory coreData,
        SystemData memory systemData,
        ModularData memory modularData,
        ThemeData memory themeData
    ) public pure returns (string memory) {
        return _processFromStructsWithTheme(coreData, systemData, modularData, themeData);
    }
    
    // ==================== INTERNAL PROCESSING - ALL ORIGINAL PRESERVED ====================
    
    function _processTokenMetadata(
        TokenMetadataParams memory params
    ) private pure returns (string memory) {
        string memory name = _getName(params.tokenId, params.stakingStatus.isStaked);
        string memory description = _getDescription(params.specimen, params.traitPackName, params.compatibility.traitPackCompatibility);
        
        string memory imageUri = _getMainImageUri(params);
        string memory animationUri = _getMainAnimationUri(params);
        
        string memory attributes = _getAllAttributes(params);
        
        return _assembleJSON(name, description, imageUri, animationUri, params.externalUrl, attributes);
    }
    
    function _processFromStructs(
        CoreTokenData memory coreData,
        SystemData memory systemData,
        ModularData memory modularData
    ) private pure returns (string memory) {
        
        // Build name with augment support
        string memory name = string.concat("Henomorph #", coreData.tokenId.toString());
        
        // Add augment to name if present (following HenomorphsMetadata pattern)
        if (bytes(modularData.traitPackName).length > 0 && 
            modularData.activeTraitPackId > 0 && 
            bytes(modularData.traitPackUri).length == 0) { // Augments have empty traitPackUri
            name = string.concat(name, " + ", modularData.traitPackName);
        }
        
        // Add staking indicator
        if (systemData.stakingStatus.isStaked) {
            name = string.concat(name, unicode" ⚡");
        }
        
        string memory description = _getDescriptionFromStructs(systemData.specimen, modularData.traitPackName, systemData.compatibility.traitPackCompatibility);
        string memory imageUri = _getMainImageUriFromStructs(coreData, systemData, modularData);
        string memory animationUri = _getMainAnimationUriFromStructs(coreData, systemData, modularData);
        string memory attributes = _getAllAttributesFromStructs(coreData, systemData, modularData);
        
        return _assembleJSON(name, description, imageUri, animationUri, coreData.externalUrl, attributes);
    }

    function _processFromStructsWithTheme(
        CoreTokenData memory coreData,
        SystemData memory systemData,
        ModularData memory modularData,
        ThemeData memory themeData
    ) private pure returns (string memory) {
        
        // Build name with augment support (following HenomorphsMetadata pattern)
        string memory name;
        if (themeData.hasTheme && bytes(themeData.themeName).length > 0) {
            name = string.concat(themeData.themeName, " #", coreData.tokenId.toString());
        } else {
            name = string.concat("Henomorph #", coreData.tokenId.toString());
        }
        
        // Add augment to name if present (following HenomorphsMetadata pattern)
        if (bytes(modularData.traitPackName).length > 0 && 
            modularData.activeTraitPackId > 0 && 
            bytes(modularData.traitPackUri).length == 0) { // Augments have empty traitPackUri
            name = string.concat(name, " + ", modularData.traitPackName);
        }
        
        // Add staking indicator
        if (systemData.stakingStatus.isStaked) {
            name = string.concat(name, unicode" ⚡");
        }
        
        string memory description = _getDescriptionWithTheme(systemData.specimen, modularData.traitPackName, systemData.compatibility.traitPackCompatibility, themeData);
        string memory imageUri = _getMainImageUriWithTheme(coreData, systemData, modularData, themeData);
        string memory animationUri = _getMainAnimationUriWithTheme(coreData, systemData, modularData, themeData);
        string memory attributes = _getAllAttributesWithTheme(coreData, systemData, modularData, themeData);
        
        return _assembleJSON(name, description, imageUri, animationUri, coreData.externalUrl, attributes);
    }
    
    // ==================== COMPONENT BUILDERS - ALL ORIGINAL PRESERVED ====================
    
    function _getName(uint256 tokenId, bool isStaked) private pure returns (string memory) {
        string memory baseName = string.concat("Henomorph #", tokenId.toString());
        if (isStaked) {
            return string.concat(baseName, unicode" ⚡");
        }
        return baseName;
    }

    function _getNameWithTheme(uint256 tokenId, bool isStaked, ThemeData memory themeData) private pure returns (string memory) {
        string memory baseName;
        
        if (themeData.hasTheme && bytes(themeData.themeName).length > 0) {
            baseName = string.concat(themeData.themeName, " #", tokenId.toString());
        } else {
            baseName = string.concat("Henomorph #", tokenId.toString());
        }
        
        if (isStaked) {
            return string.concat(baseName, unicode" ⚡");
        }
        return baseName;
    }
    
    function _getDescription(
        Specimen memory specimen,
        string memory traitPackName,
        uint8 compatibility
    ) private pure returns (string memory) {
        string memory desc = string.concat(
            specimen.description,
            " It utilizes ",
            _getFormTechnology(specimen.variant),
            " technology."
        );
        
        if (bytes(traitPackName).length > 0) {
            desc = string.concat(
                desc,
                " Enhanced with ",
                traitPackName,
                " providing ",
                _getCompatibilityDescription(compatibility),
                " compatibility."
            );
        }
        
        return desc;
    }
    
    function _getDescriptionFromStructs(
        Specimen memory specimen,
        string memory traitPackName,
        uint8 compatibility
    ) private pure returns (string memory) {
        return _getDescription(specimen, traitPackName, compatibility);
    }

    function _getDescriptionWithTheme(
        Specimen memory specimen,
        string memory traitPackName,
        uint8 compatibility,
        ThemeData memory themeData
    ) private pure returns (string memory) {
        string memory desc = specimen.description;
        
        if (themeData.hasTheme && bytes(themeData.technologyBase).length > 0) {
            string memory tech = themeData.technologyBase;
            
            if (bytes(themeData.evolutionContext).length > 0) {
                tech = string.concat(tech, " focused on ", themeData.evolutionContext);
            }
            
            if (bytes(themeData.universeContext).length > 0) {
                tech = string.concat(tech, " within the ", themeData.universeContext);
            }
            
            desc = string.concat(desc, " It utilizes ", tech, " technology.");
        } else {
            desc = string.concat(desc, " It utilizes ", _getFormTechnology(specimen.variant), " technology.");
        }
        
        if (themeData.hasCustomVariantTheme && bytes(themeData.evolutionStage).length > 0) {
            desc = string.concat(
                desc,
                " This ",
                specimen.formName,
                " represents the ",
                themeData.evolutionStage,
                " evolutionary stage"
            );
            
            if (bytes(themeData.powerLevel).length > 0) {
                desc = string.concat(desc, " with ", themeData.powerLevel, " power level");
            }
            
            desc = string.concat(desc, ".");
        }
        
        // ENHANCED: Add augment information (following HenomorphsMetadata pattern)
        if (bytes(traitPackName).length > 0) {
            desc = string.concat(
                desc,
                " Enhanced with ",
                traitPackName,
                " providing specialized accessories and ",
                _getCompatibilityDescription(compatibility),
                " compatibility."
            );
        }
        
        return desc;
    }
    
    // ==================== IMAGE/ANIMATION URI BUILDERS - ALL ORIGINAL PRESERVED ====================
    
    function _getMainImageUri(TokenMetadataParams memory params) private pure returns (string memory) {
        if (params.activeAssetId != 0 && bytes(params.assetUri).length > 0) {
            return params.assetUri;
        }
        
        if (params.activeTraitPackId != 0 && bytes(params.traitPackUri).length > 0) {
            return string.concat(
                params.traitPackUri,
                "A",
                params.tokenTier.toString(),
                "_s_",
                params.tokenVariant.toString(),
                ".png"
            );
        }
        
        string memory baseUri = bytes(params.specimen.baseUri).length > 0 ? 
            params.specimen.baseUri : params.baseUri;
        
        return string.concat(
            baseUri,
            "H",
            params.tokenTier.toString(),
            "_s_",
            params.tokenVariant.toString(),
            ".png"
        );
    }
    
    function _getMainImageUriFromStructs(
        CoreTokenData memory coreData,
        SystemData memory systemData,
        ModularData memory modularData
    ) private pure returns (string memory) {
        if (modularData.activeAssetId != 0 && bytes(modularData.assetUri).length > 0) {
            return modularData.assetUri;
        }
        
        // Check if this is an augmented token
        bool isAugmented = modularData.activeTraitPackId > 0 && 
                        bytes(modularData.traitPackName).length > 0 && 
                        bytes(modularData.traitPackUri).length == 0; // Augments have empty traitPackUri
        
        if (isAugmented && bytes(modularData.traitPackUri).length > 0) {
            return string.concat(
                modularData.traitPackUri,
                "A",
                coreData.tokenTier.toString(),
                "_s_",
                coreData.tokenVariant.toString(),
                ".png"
            );
        }
        
        string memory baseUri = bytes(systemData.specimen.baseUri).length > 0 ? 
            systemData.specimen.baseUri : coreData.baseUri;
        
        // Use augmented naming if augmented (following HenomorphsMetadata)
        if (isAugmented) {
            return string.concat(
                baseUri,
                "H",
                coreData.tokenTier.toString(),
                "_s_",
                coreData.tokenVariant.toString(),
                "_T",  // Trait pack marker
                modularData.activeTraitPackId.toString(),
                ".png"
            );
        }
        
        // Standard naming (unchanged)
        return string.concat(
            baseUri,
            "H",
            coreData.tokenTier.toString(),
            "_s_",
            coreData.tokenVariant.toString(),
            ".png"
        );
    }

    function _getMainImageUriWithTheme(
        CoreTokenData memory coreData,
        SystemData memory systemData,
        ModularData memory modularData,
        ThemeData memory
    ) private pure returns (string memory) {
        return _getMainImageUriFromStructs(coreData, systemData, modularData);
    }
    
    function _getMainAnimationUri(TokenMetadataParams memory params) private pure returns (string memory) {
        if (bytes(params.animationUri).length == 0) {
            return "";
        }
        
        if (params.activeAssetId != 0 && bytes(params.assetUri).length > 0) {
            return params.assetUri;
        }
        
        if (params.activeTraitPackId != 0 && bytes(params.traitPackUri).length > 0) {
            return string.concat(
                params.traitPackUri,
                "A",
                params.tokenTier.toString(),
                "_a_",
                params.tokenVariant.toString(),
                ".mp4"
            );
        }
        
        string memory baseUri = bytes(params.specimen.baseUri).length > 0 ? 
            params.specimen.baseUri : params.baseUri;
        
        return string.concat(
            baseUri,
            "H",
            params.tokenTier.toString(),
            "_a_",
            params.tokenVariant.toString(),
            ".mp4"
        );
    }
    
    function _getMainAnimationUriFromStructs(
        CoreTokenData memory coreData,
        SystemData memory systemData,
        ModularData memory modularData
    ) private pure returns (string memory) {
        if (bytes(coreData.animationUri).length == 0) {
            return "";
        }
        
        if (modularData.activeAssetId != 0 && bytes(modularData.assetUri).length > 0) {
            return _tryGetCustomAssetAnimation(modularData.assetUri);
        }
        
        // Check if this is an augmented token
        bool isAugmented = modularData.activeTraitPackId > 0 && 
                        bytes(modularData.traitPackName).length > 0 && 
                        bytes(modularData.traitPackUri).length == 0; // Augments have empty traitPackUri
        
        if (isAugmented && bytes(modularData.traitPackUri).length > 0) {
            return string.concat(
                modularData.traitPackUri,
                "A",
                coreData.tokenTier.toString(),
                "_a_",
                coreData.tokenVariant.toString(),
                ".mp4"
            );
        }
        
        string memory baseUri = bytes(systemData.specimen.baseUri).length > 0 ? 
            systemData.specimen.baseUri : coreData.baseUri;
        
        // Use augmented naming if augmented (following HenomorphsMetadata)
        if (isAugmented) {
            return string.concat(
                baseUri,
                "H",
                coreData.tokenTier.toString(),
                "_a_",
                coreData.tokenVariant.toString(),
                "_T",  // Trait pack marker
                modularData.activeTraitPackId.toString(),
                ".mp4"
            );
        }
        
        // Standard naming (unchanged)
        return string.concat(
            baseUri,
            "H",
            coreData.tokenTier.toString(),
            "_a_",
            coreData.tokenVariant.toString(),
            ".mp4"
        );
    }

    /**
     * @notice Try to get animation for custom asset - simple helper
     */
    function _tryGetCustomAssetAnimation(string memory assetUri) private pure returns (string memory) {
        bytes memory uriBytes = bytes(assetUri);
        if (uriBytes.length >= 4) {
            // Check if ends with .png
            if (uriBytes[uriBytes.length-4] == 0x2E && // '.'
                uriBytes[uriBytes.length-3] == 0x70 && // 'p'  
                uriBytes[uriBytes.length-2] == 0x6E && // 'n'
                uriBytes[uriBytes.length-1] == 0x67) { // 'g'
                
                // Create string without .png and append .mp4
                string memory baseUri = "";
                for (uint256 i = 0; i < uriBytes.length - 4; i++) {
                    baseUri = string.concat(baseUri, string(abi.encodePacked(uriBytes[i])));
                }
                return string.concat(baseUri, ".mp4");
            }
        }
        
        // Fallback: append .mp4
        return string.concat(assetUri, ".mp4");
    }

    function _getMainAnimationUriWithTheme(
        CoreTokenData memory coreData,
        SystemData memory systemData,
        ModularData memory modularData,
        ThemeData memory
    ) private pure returns (string memory) {
        return _getMainAnimationUriFromStructs(coreData, systemData, modularData);
    }
    
    // ==================== ATTRIBUTE BUILDERS - ALL ORIGINAL + THEME PRESERVED ====================
    
    function _getAllAttributes(TokenMetadataParams memory params) private pure returns (string memory) {
        string memory coreAttrs = _getCoreAttributes(params.tokenVariant, params.specimen.formName, params.specimen.generation, params.calibration.level);
        string memory powerAttrs = _getPowerAttributes(params.powerMatrix, params.calibration);
        string memory bonusAttrs = _getBonusAttributes(params.accessoryBonuses);
        string memory statusAttrs = _getStatusAttributes(params.stakingStatus, params.equipments, params.compatibility.overallScore);
        
        return string.concat(coreAttrs, powerAttrs, bonusAttrs, statusAttrs);
    }
    
    function _getAllAttributesFromStructs(
        CoreTokenData memory coreData,
        SystemData memory systemData,
        ModularData memory modularData
    ) private pure returns (string memory) {
        string memory coreAttrs = _getCoreAttributes(coreData.tokenVariant, systemData.specimen.formName, systemData.specimen.generation, systemData.calibration.level);
        string memory powerAttrs = _getPowerAttributes(systemData.powerMatrix, systemData.calibration);
        string memory bonusAttrs = _getBonusAttributes(systemData.accessoryBonuses);
        string memory statusAttrs = _getStatusAttributes(systemData.stakingStatus, modularData.equipments, systemData.compatibility.overallScore);
        
        // Add augment attributes if present (following HenomorphsMetadata pattern)
        string memory augmentAttrs = "";
        if (bytes(modularData.traitPackName).length > 0 && 
            modularData.activeTraitPackId > 0 && 
            bytes(modularData.traitPackUri).length == 0) { // Augments have empty traitPackUri
            
            augmentAttrs = string.concat(
                ',{"trait_type":"Augment Status","value":"Active"}',
                ',{"trait_type":"Augment","value":"', modularData.traitPackName, '"}',
                ',{"trait_type":"Augment Variant","value":"', modularData.activeTraitPackId.toString(), '"}',
                ',{"trait_type":"Enhanced","value":"Yes"}'
            );
        }
        
        return string.concat(coreAttrs, powerAttrs, bonusAttrs, statusAttrs, augmentAttrs);
    }

    function _getAllAttributesWithTheme(
        CoreTokenData memory coreData,
        SystemData memory systemData,
        ModularData memory modularData,
        ThemeData memory themeData
    ) private pure returns (string memory) {
        string memory coreAttrs = _getCoreAttributesWithTheme(coreData.tokenVariant, systemData.specimen.formName, systemData.specimen.generation, systemData.calibration.level, themeData);
        string memory powerAttrs = _getPowerAttributes(systemData.powerMatrix, systemData.calibration);
        string memory bonusAttrs = _getBonusAttributes(systemData.accessoryBonuses);
        string memory statusAttrs = _getStatusAttributes(systemData.stakingStatus, modularData.equipments, systemData.compatibility.overallScore);
        
        // Add augment attributes if present (following HenomorphsMetadata pattern)
        string memory augmentAttrs = "";
        if (bytes(modularData.traitPackName).length > 0 && 
            modularData.activeTraitPackId > 0 && 
            bytes(modularData.traitPackUri).length == 0) { // Augments have empty traitPackUri
            
            augmentAttrs = string.concat(
                ',{"trait_type":"Augment Status","value":"Active"}',
                ',{"trait_type":"Augment","value":"', modularData.traitPackName, '"}',
                ',{"trait_type":"Augment Variant","value":"', modularData.activeTraitPackId.toString(), '"}',
                ',{"trait_type":"Enhanced","value":"Yes"}'
            );
        }
        
        return string.concat(coreAttrs, powerAttrs, bonusAttrs, statusAttrs, augmentAttrs);
    }
    
    function _getCoreAttributes(
        uint8 tokenVariant,
        string memory formName,
        uint8 generation,
        uint256 level
    ) private pure returns (string memory) {
        return string.concat(
            '{"trait_type":"Variant","value":"', tokenVariant.toString(), '"},',
            '{"trait_type":"Form","value":"', formName, '"},',
            '{"trait_type":"Generation","value":"', uint256(generation).toString(), '"},',
            '{"trait_type":"Level","value":"', level.toString(), '"}'
        );
    }

    function _getCoreAttributesWithTheme(
        uint8 tokenVariant,
        string memory formName,
        uint8 generation,
        uint256 level,
        ThemeData memory themeData
    ) private pure returns (string memory) {
        string memory attrs = _getCoreAttributes(tokenVariant, formName, generation, level);
        
        if (themeData.hasTheme && bytes(themeData.themeName).length > 0) {
            attrs = string.concat(attrs, ',{"trait_type":"Collection Theme","value":"', themeData.themeName, '"}');
        }
        
        if (bytes(themeData.technologyBase).length > 0) {
            attrs = string.concat(attrs, ',{"trait_type":"Technology Base","value":"', themeData.technologyBase, '"}');
        }
        
        if (bytes(themeData.evolutionContext).length > 0) {
            attrs = string.concat(attrs, ',{"trait_type":"Evolution Focus","value":"', themeData.evolutionContext, '"}');
        }
        
        if (bytes(themeData.universeContext).length > 0) {
            attrs = string.concat(attrs, ',{"trait_type":"Universe","value":"', themeData.universeContext, '"}');
        }
        
        if (themeData.hasCustomVariantTheme) {
            if (bytes(themeData.evolutionStage).length > 0) {
                attrs = string.concat(attrs, ',{"trait_type":"Evolution Stage","value":"', themeData.evolutionStage, '"}');
            }
            
            if (bytes(themeData.powerLevel).length > 0) {
                attrs = string.concat(attrs, ',{"trait_type":"Power Level","value":"', themeData.powerLevel, '"}');
            }
        }
        
        return attrs;
    }
    
    function _getPowerAttributes(
        PowerMatrix memory powerMatrix,
        Calibration memory calibration
    ) private pure returns (string memory) {
        string memory attrs = string.concat(
            ',{"trait_type":"Current Charge","value":', powerMatrix.currentCharge.toString(), '}',
            ',{"trait_type":"Max Charge","value":', powerMatrix.maxCharge.toString(), '}',
            ',{"trait_type":"Charge Efficiency","value":"', powerMatrix.chargeEfficiency.toString(), '%"}',
            ',{"trait_type":"Regen Rate","value":', powerMatrix.regenRate.toString(), '}'
        );
        
        if (powerMatrix.specialization > 0) {
            attrs = string.concat(
                attrs,
                ',{"trait_type":"Specialization","value":"', _getSpecializationName(powerMatrix.specialization), '"}'
            );
        }
        
        if (calibration.calibrationCount > 0) {
            attrs = string.concat(
                attrs,
                ',{"trait_type":"Calibration Status","value":"', _getCalibrationTierName(calibration.level), '"}',
                ',{"trait_type":"Kinship","value":', calibration.kinship.toString(), '}',
                ',{"trait_type":"Experience","value":', calibration.experience.toString(), '}',
                ',{"trait_type":"Wear Level","value":', calibration.wear.toString(), '}'
            );
        }
        
        return attrs;
    }
    
    function _getBonusAttributes(AccessoryBonuses memory bonuses) private pure returns (string memory) {
        string memory attrs = "";
        
        if (bonuses.efficiencyBonus > 0) {
            attrs = string.concat(attrs, ',{"trait_type":"Efficiency Bonus","value":"', bonuses.efficiencyBonus.toString(), '%"}');
        }
        
        if (bonuses.regenBonus > 0) {
            attrs = string.concat(attrs, ',{"trait_type":"Regen Bonus","value":"', bonuses.regenBonus.toString(), '"}');
        }
        
        if (bonuses.maxChargeBonus > 0) {
            attrs = string.concat(attrs, ',{"trait_type":"Charge Bonus","value":"', bonuses.maxChargeBonus.toString(), '"}');
        }
        
        if (bonuses.kinshipBonus > 0) {
            attrs = string.concat(attrs, ',{"trait_type":"Kinship Bonus","value":"', bonuses.kinshipBonus.toString(), '"}');
        }
        
        if (bonuses.wearResistance > 0) {
            attrs = string.concat(attrs, ',{"trait_type":"Wear Resistance","value":"', bonuses.wearResistance.toString(), '%"}');
        }
        
        if (bonuses.calibrationBonus > 0) {
            attrs = string.concat(attrs, ',{"trait_type":"Calibration Bonus","value":"', bonuses.calibrationBonus.toString(), '%"}');
        }
        
        if (bonuses.stakingBonus > 0) {
            attrs = string.concat(attrs, ',{"trait_type":"Staking Bonus","value":"', bonuses.stakingBonus.toString(), '%"}');
        }
        
        if (bonuses.xpMultiplier > 100) {
            attrs = string.concat(attrs, ',{"trait_type":"XP Multiplier","value":"', bonuses.xpMultiplier.toString(), '%"}');
        }
        
        return attrs;
    }
    
    function _getStatusAttributes(
        StakingStatus memory stakingStatus,
        Equipment[] memory equipments,
        uint8 overallScore
    ) private pure returns (string memory) {
        string memory attrs = "";
        
        if (stakingStatus.isStaked) {
            attrs = string.concat(
                attrs,
                ',{"trait_type":"Staking Status","value":"Active"}',
                ',{"trait_type":"Stake Multiplier","value":"', stakingStatus.stakingMultiplier.toString(), '%"}',
                ',{"trait_type":"Stake Rewards","value":"', stakingStatus.stakingRewards.toString(), '"}'
            );
            
            if (stakingStatus.colonyId != bytes32(0)) {
                attrs = string.concat(
                    attrs,
                    ',{"trait_type":"Colony Member","value":"Yes"}',
                    ',{"trait_type":"Colony Bonus","value":"', stakingStatus.colonyBonus.toString(), '%"}'
                );
            }
        }
        
        if (equipments.length > 0) {
            attrs = string.concat(
                attrs,
                ',{"trait_type":"Equipment Count","value":"', equipments.length.toString(), '"}'
            );
            
            for (uint256 i = 0; i < equipments.length && i < 3; i++) {
                attrs = string.concat(
                    attrs,
                    ',{"trait_type":"Equipment ', i.toString(), '","value":"Asset #',
                    equipments[i].assetId.toString(), '"}'
                );
            }
        }
        
        attrs = string.concat(
            attrs,
            ',{"trait_type":"Compatibility Score","value":"', overallScore.toString(), '%"}'
        );
        
        return attrs;
    }
    
    function _assembleJSON(
        string memory name,
        string memory description,
        string memory imageUri,
        string memory animationUri,
        string memory externalUrl,
        string memory attributes
    ) private pure returns (string memory) {
        string memory json = string.concat(
            '{',
            '"name":"', name, '",',
            '"description":"', description, '",',
            '"image":"', imageUri, '"'
        );
        
        if (bytes(animationUri).length > 0) {
            json = string.concat(json, ',"animation_url":"', animationUri, '"');
        }
        
        json = string.concat(
            json,
            ',"external_url":"', externalUrl, '",',
            '"attributes":[', attributes, ']',
            '}'
        );
        
        return json;
    }
    
    // ==================== AUGMENT COLLECTION METADATA - FIXED ACCESSORY LOOKUP ====================
    
    /**
     * @notice Generate complete Augment metadata with FIXED accessory name lookup
     * @dev FIXED: Now properly reads from collection-scoped storage
     */
    function generateAugmentMetadata(
        uint256 collectionId,
        uint256 tokenId,
        uint8 tokenTier,
        uint8 tokenVariant,
        address contractAddress,
        string memory collectionName,
        string memory baseURI,
        string memory animationUri
    ) external view returns (string memory) {
        
        // Get augment information - collection-specific mapping
        AugmentInfo memory augmentInfo = _getAugmentInfo(collectionId, tokenVariant);
        
        // Build metadata components
        string memory name = _buildAugmentName(collectionName, tokenId, augmentInfo);
        string memory description = _buildAugmentDescription(augmentInfo);
        string memory imageUrl = _buildAugmentImageUrl(baseURI, tokenTier, tokenVariant, augmentInfo);
        string memory animUrl = _buildAugmentAnimationUrl(baseURI, animationUri, tokenTier, tokenVariant, augmentInfo);
        
        // FIXED: Pass collectionId to get proper accessory names
        string memory attributes = _buildAugmentAttributesFixed(contractAddress, tokenId, tokenVariant, augmentInfo, collectionId);
        
        // Assemble JSON
        string memory json = string.concat(
            '{',
            '"name":"', name, '",',
            '"description":"', description, '",',
            '"image":"', imageUrl, '"'
        );
        
        if (bytes(animUrl).length > 0) {
            json = string.concat(json, ',"animation_url":"', animUrl, '"');
        }
        
        json = string.concat(
            json,
            ',"external_url":"https://zico.network",',
            '"attributes":[', attributes, ']',
            '}'
        );
        
        return json;
    }
    
    // ==================== AUGMENT BUILDERS - ORIGINAL + FIXED ====================
    
    function _buildAugmentName(
        string memory collectionName,
        uint256 tokenId,
        AugmentInfo memory info
    ) private pure returns (string memory) {
        if (info.hasTraitPack && bytes(info.traitPackName).length > 0) {
            return string.concat(info.traitPackName, " #", tokenId.toString());
        }
        return string.concat(collectionName, " #", tokenId.toString());
    }
    
    function _buildAugmentDescription(AugmentInfo memory info) private pure returns (string memory) {
        string memory baseDescription = "Henomorphs Augment NFT that can be assigned to main collection tokens for enhancements.";
        
        if (info.hasTraitPack && bytes(info.traitPackName).length > 0) {
            return string.concat(
                baseDescription,
                " This ",
                info.traitPackName,
                " provides specialized capabilities and accessories for compatible specimens."
            );
        }
        
        return baseDescription;
    }
    
    function _buildAugmentImageUrl(
        string memory baseURI,
        uint8 tokenTier,
        uint8 tokenVariant,
        AugmentInfo memory
    ) private pure returns (string memory) {
        return string.concat(
            baseURI,
            "A",
            tokenTier.toString(),
            "_s_",
            tokenVariant.toString(),
            ".png"
        );
    }
    
    function _buildAugmentAnimationUrl(
        string memory baseURI,
        string memory animationUri,
        uint8 tokenTier,
        uint8 tokenVariant,
        AugmentInfo memory
    ) private pure returns (string memory) {
        if (bytes(animationUri).length == 0) {
            return "";
        }
        
        return string.concat(
            baseURI,
            "A",
            tokenTier.toString(),
            "_a_",
            tokenVariant.toString(),
            ".mp4"
        );
    }
    
    /**
     * @notice FIXED: Build augment attributes with proper accessory name lookup
     * @dev Now reads from collection-scoped storage first, then global fallback
     */
    function _buildAugmentAttributesFixed(
        address contractAddress,
        uint256 tokenId,
        uint8 tokenVariant,
        AugmentInfo memory info,
        uint256 collectionId
    ) private view returns (string memory) {
        // Build core attributes
        string memory coreAttrs = _buildCoreAugmentAttributes(tokenVariant, info);
        
        // FIXED: Build accessory attributes with collection context
        string memory accessoryAttrs = _buildAccessoryAttributesFixed(info, collectionId);
        
        // Build assignment attributes
        string memory assignmentAttrs = _buildAssignmentAttributes(contractAddress, tokenId);
        
        // Combine all attributes
        return string.concat(coreAttrs, accessoryAttrs, assignmentAttrs);
    }

    function _buildCoreAugmentAttributes(
        uint8 tokenVariant,
        AugmentInfo memory info
    ) private pure returns (string memory) {
        string memory attributes = string.concat(
            '{"trait_type":"Token Variant","value":"', tokenVariant.toString(), '"}',
            ',{"trait_type":"Collection Type","value":"Augment"}'
        );
        
        if (info.hasTraitPack) {
            attributes = string.concat(
                attributes,
                ',{"trait_type":"Augment Type","value":"', info.traitPackName, '"}',
                ',{"trait_type":"Trait Pack ID","value":"', info.traitPackId.toString(), '"}'
            );
            
            if (info.compatibleVariants.length > 0) {
                string memory variantList = _buildVariantList(info.compatibleVariants);
                attributes = string.concat(
                    attributes,
                    ',{"trait_type":"Compatible Variants","value":"', variantList, '"}'
                );
            }
        }
        
        return attributes;
    }

    /**
     * @notice FIXED: Build accessory attributes with collection-scoped lookup
     * @dev Reads from cs.accessoryTokens[collectionId][tokenId] first, then global fallback
     */
    function _buildAccessoryAttributesFixed(
        AugmentInfo memory info,
        uint256 collectionId
    ) private view returns (string memory) {
        if (info.accessoryIds.length == 0) {
            return "";
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        string memory attributes = string.concat(
            ',{"trait_type":"Provides Accessories","value":"', info.accessoryIds.length.toString(), '"}'
        );
        
        // Show individual accessories (limit to 3 for gas efficiency)
        uint256 limit = info.accessoryIds.length > 3 ? 3 : info.accessoryIds.length;
        
        for (uint256 i = 0; i < limit; i++) {
            uint8 accessoryId = info.accessoryIds[i];
            string memory accessoryName = _getAccessoryName(collectionId, accessoryId, cs);
            
            attributes = string.concat(
                attributes,
                ',{"trait_type":"Accessory ', (i + 1).toString(), '","value":"', accessoryName, '"}'
            );
        }
        
        return attributes;
    }
    
    /**
     * @notice FIXED: Get accessory name from collection-scoped storage - FULLY DYNAMIC
     * @dev No hardcoding - reads actual names from storage where they were defined
     */
    function _getAccessoryName(
        uint256 collectionId, 
        uint8 accessoryId, 
        LibCollectionStorage.CollectionStorage storage cs
    ) private view returns (string memory) {
        
        // PRIMARY STRATEGY: Search through all defined accessories in this collection
        // This is the most reliable approach since accessories are stored as:
        // cs.accessoryTokens[collectionId][tokenId] where tokenId is sequential (1,2,3...)
        // and each AccessoryToken has an accessoryId field
        
        for (uint256 tokenId = 1; tokenId <= 100; tokenId++) {
            LibCollectionStorage.AccessoryToken storage accessoryToken = cs.accessoryTokens[collectionId][tokenId];
            
            // Check if this tokenId has a defined accessory with matching accessoryId
            if (accessoryToken.defined && accessoryToken.accessoryId == accessoryId) {
                return accessoryToken.name; // FOUND THE ACTUAL NAME!
            }
        }
        
        // FALLBACK 1: Try direct mapping (tokenId = accessoryId)
        // In case the system uses direct ID mapping
        if (accessoryId > 0 && accessoryId <= 100) {
            LibCollectionStorage.AccessoryToken storage directAccessory = cs.accessoryTokens[collectionId][accessoryId];
            if (directAccessory.defined) {
                return directAccessory.name;
            }
        }
        
        // FALLBACK 2: Check global storage (for backward compatibility)
        if (cs.accessoryExists[accessoryId]) {
            return cs.accessoryDefinitions[accessoryId].name;
        }
        
        // FALLBACK 3: Try to infer from collection trait packs
        // If we can't find the accessory directly, see if it's referenced in trait packs
        uint8[] storage traitPackIds = cs.collectionTraitPackIds[collectionId];
        for (uint256 i = 0; i < traitPackIds.length; i++) {
            uint8 tpId = traitPackIds[i];
            if (cs.collectionTraitPackExists[collectionId][tpId]) {
                LibCollectionStorage.CollectionTraitPack storage tp = cs.collectionTraitPacks[collectionId][tpId];
                
                // Check if this trait pack contains our accessory
                for (uint256 j = 0; j < tp.accessoryIds.length; j++) {
                    if (tp.accessoryIds[j] == accessoryId) {
                        // Found the accessory in this trait pack
                        // Generate a descriptive name based on trait pack and position
                        if (tp.accessoryIds.length == 1) {
                            return string.concat(tp.name, " Accessory");
                        } else {
                            return string.concat(tp.name, " Component ", (j + 1).toString());
                        }
                    }
                }
            }
        }
        
        // SPECIAL CASE: accessoryId 0 typically means no accessories
        if (accessoryId == 0) {
            return "No Accessories";
        }
        
        // FINAL FALLBACK: Generic but informative name
        return string.concat("Collection ", collectionId.toString(), " Accessory #", accessoryId.toString());
    }
    
    function _buildAssignmentAttributes(address contractAddress, uint256 tokenId) private view returns (string memory) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        bytes32 assignmentKey = cs.augmentTokenToAssignment[contractAddress][tokenId];
        
        if (assignmentKey != bytes32(0)) {
            LibCollectionStorage.AugmentAssignment storage assignment = cs.augmentAssignments[assignmentKey];
            
            if (assignment.active) {
                string memory attributes = string.concat(
                    ',{"trait_type":"Assignment Status","value":"Assigned"}',
                    ',{"trait_type":"Assigned To Token","value":"', assignment.specimenTokenId.toString(), '"}',
                    ',{"trait_type":"Assigned To Variant","value":"', assignment.specimenVariant.toString(), '"}'
                );
                
                if (assignment.unlockTime == 0) {
                    attributes = string.concat(attributes, ',{"trait_type":"Assignment Type","value":"Permanent"}');
                } else if (block.timestamp < assignment.unlockTime) {
                    attributes = string.concat(attributes, ',{"trait_type":"Assignment Type","value":"Time Locked"}');
                } else {
                    attributes = string.concat(attributes, ',{"trait_type":"Assignment Type","value":"Unlocked"}');
                }
                
                return attributes;
            }
        }
        
        return ',{"trait_type":"Assignment Status","value":"Available"}';
    }

    function _buildVariantList(uint8[] memory variants) private pure returns (string memory) {
        if (variants.length == 0) return "";
        
        string memory variantList = variants[0].toString();
        
        uint256 limit = variants.length > 5 ? 5 : variants.length;
        
        for (uint256 i = 1; i < limit; i++) {
            variantList = string.concat(variantList, ", ", variants[i].toString());
        }
        
        if (variants.length > 5) {
            variantList = string.concat(variantList, "...");
        }
        
        return variantList;
    }
    
    // ==================== ENCODING ====================
    
    function encodeTokenURI(string memory json) external pure returns (string memory) {
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        );
    }
    
    // ==================== INTERNAL HELPERS - ALL ORIGINAL + ENHANCED ====================
    
    function _getTokenVariantFromContract(address contractAddress, uint256 tokenId) internal view returns (uint8) {
        try IExternalCollection(contractAddress).itemVariant(tokenId) returns (uint8 variant) {
            return variant;
        } catch {
            return 0;
        }
    }

    /**
     * @notice ENHANCED: Get augment info with collection-scoped trait pack support + variant 0 fix
     */
    function _getAugmentInfo(uint256 collectionId, uint8 tokenVariant) internal view returns (AugmentInfo memory info) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // PRIORITY 1: Try collection-scoped trait pack (NEW)
        uint8 scopedTraitPackId = cs.collectionVariantToTraitPack[collectionId][tokenVariant];
        if (scopedTraitPackId > 0 && cs.collectionTraitPackExists[collectionId][scopedTraitPackId]) {
            return _buildFromCollectionTraitPack(collectionId, scopedTraitPackId, cs);
        }
        
        // SPECIAL CASE: Check if variant 0 maps to trait pack 0 (SEALED POTENTIAL)
        if (tokenVariant == 0 && cs.collectionTraitPackExists[collectionId][0]) {
            return _buildFromCollectionTraitPack(collectionId, 0, cs);
        }
        
        // PRIORITY 2: Fallback to global trait pack
        uint8 globalTraitPackId = cs.variantToTraitPack[collectionId][tokenVariant];
        if (globalTraitPackId > 0 && cs.traitPackExists[globalTraitPackId]) {
            return _buildAugmentInfoFromTraitPack(globalTraitPackId, cs);
        }
        
        // PRIORITY 3: Generate from token variant
        if (cs.traitPackExists[tokenVariant]) {
            return _buildAugmentInfoFromTraitPack(tokenVariant, cs);
        }
        
        // PRIORITY 4: ENHANCED fallback with special handling for variant 0
        if (tokenVariant == 0) {
            uint8[] memory emptyAccessories = new uint8[](0);
            uint8[] memory _compatibleVariants = new uint8[](1);
            _compatibleVariants[0] = 0;
            
            return AugmentInfo({
                traitPackName: "SEALED POTENTIAL",
                traitPackId: 0,
                hasTraitPack: true,
                accessoryIds: emptyAccessories,
                compatibleVariants: _compatibleVariants
            });
        }
        
        // Regular fallback for other variants
        uint8[] memory accessoryIds = new uint8[](1);
        accessoryIds[0] = tokenVariant;
        
        uint8[] memory compatibleVariants = new uint8[](1);
        compatibleVariants[0] = tokenVariant;
        
        return AugmentInfo({
            traitPackName: string(abi.encodePacked("Augment Variant ", tokenVariant.toString())),
            traitPackId: tokenVariant,
            hasTraitPack: true,
            accessoryIds: accessoryIds,
            compatibleVariants: compatibleVariants
        });
    }

    function _buildFromCollectionTraitPack(
        uint256 collectionId,
        uint8 traitPackId, 
        LibCollectionStorage.CollectionStorage storage cs
    ) internal view returns (AugmentInfo memory info) {
        LibCollectionStorage.CollectionTraitPack storage traitPack = cs.collectionTraitPacks[collectionId][traitPackId];
        
        return AugmentInfo({
            traitPackName: traitPack.name,
            traitPackId: traitPackId,
            hasTraitPack: true,
            accessoryIds: traitPack.accessoryIds,
            compatibleVariants: traitPack.compatibleVariants
        });
    }
    
    function _buildAugmentInfoFromTraitPack(
        uint8 traitPackId, 
        LibCollectionStorage.CollectionStorage storage cs
    ) internal view returns (AugmentInfo memory info) {
        TraitPack storage traitPack = cs.traitPacks[traitPackId];
        
        return AugmentInfo({
            traitPackName: traitPack.name,
            traitPackId: traitPackId,
            hasTraitPack: true,
            accessoryIds: cs.traitPackAccessories[traitPackId],
            compatibleVariants: cs.traitPackCompatibleVariants[traitPackId]
        });
    }
    
    // ==================== UTILITY FUNCTIONS - ALL ORIGINAL PRESERVED ====================
    
    function _getFormTechnology(uint8 variant) private pure returns (string memory) {
        string[5] memory technologies = [
            "primordial data matrix",
            "basic sensory",
            "enhanced processing", 
            "sophisticated neural",
            "quantum neural"
        ];
        
        return variant <= 4 ? technologies[variant] : technologies[0];
    }
    
    function _getCompatibilityDescription(uint8 score) private pure returns (string memory) {
        if (score >= 90) return "exceptional";
        if (score >= 70) return "high";
        if (score >= 50) return "good";
        if (score >= 30) return "moderate";
        return "basic";
    }
    
    function _getCalibrationTierName(uint256 level) private pure returns (string memory) {
        string[5] memory tiers = ["Critical", "Unstable", "Nominal", "Hypertuned", "Quantum"];
        return tiers[_getTier(level)];
    }
    
    function _getSpecializationName(uint8 specialization) private pure returns (string memory) {
        if (specialization == 1) return "Efficiency";
        if (specialization == 2) return "Regeneration";
        return "Balanced";
    }
    
    function _getTier(uint256 value) private pure returns (uint8) {
        if (value < 20) return 0;
        if (value < 40) return 1;
        if (value < 70) return 2;
        if (value < 90) return 3;
        return 4;
    }
}