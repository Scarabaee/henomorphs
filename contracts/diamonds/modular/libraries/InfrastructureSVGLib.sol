// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title InfrastructureSVGLib
 * @notice Library for generating Infrastructure Card SVG graphics - Hendom Visual Style
 * @dev Based on TerritorySVGLib and StkHenoSVGBuilder visual patterns
 * @author rutilicus.eth (ArchXS)
 * @custom:version 2.0.0
 * @custom:changelog Complete rewrite with animated elements, rarity effects, and cyborg chickens
 */
library InfrastructureSVGLib {
    using Strings for uint256;

    enum InfrastructureType {
        MiningDrill,        // 0 - Resource extraction
        EnergyHarvester,    // 1 - Power generation
        ProcessingPlant,    // 2 - Resource refinement
        DefenseTurret,      // 3 - Territory defense
        ResearchLab,        // 4 - Tech advancement
        StorageFacility     // 5 - Resource capacity
    }

    enum Rarity { Common, Uncommon, Rare, Epic, Legendary }

    struct InfrastructureTraits {
        InfrastructureType infraType;
        Rarity rarity;
        uint8 efficiencyBonus;    // Production/processing bonus
        uint8 capacityBonus;      // Storage/defense bonus
        uint8 techLevel;          // Required tech level
        uint8 durability;         // Degradation resistance (0-100)
    }

    // ============ RARITY COLOR CONSTANTS ============

    bytes3 private constant LEGENDARY_PRIMARY = bytes3(0xFFD700);   // Gold
    bytes3 private constant LEGENDARY_SECONDARY = bytes3(0xFFED4E);
    bytes3 private constant LEGENDARY_GLOW = bytes3(0xFFAA00);

    bytes3 private constant EPIC_PRIMARY = bytes3(0x9B59B6);        // Purple
    bytes3 private constant EPIC_SECONDARY = bytes3(0xC39BD3);
    bytes3 private constant EPIC_GLOW = bytes3(0x8E44AD);

    bytes3 private constant RARE_PRIMARY = bytes3(0x3498DB);        // Blue
    bytes3 private constant RARE_SECONDARY = bytes3(0x5DADE2);
    bytes3 private constant RARE_GLOW = bytes3(0x2980B9);

    bytes3 private constant UNCOMMON_PRIMARY = bytes3(0x2ECC71);    // Green
    bytes3 private constant UNCOMMON_SECONDARY = bytes3(0x58D68D);
    bytes3 private constant UNCOMMON_GLOW = bytes3(0x27AE60);

    bytes3 private constant COMMON_PRIMARY = bytes3(0x95A5A6);      // Gray
    bytes3 private constant COMMON_SECONDARY = bytes3(0xBDC3C7);
    bytes3 private constant COMMON_GLOW = bytes3(0x7F8C8D);

    /**
     * @notice Generate complete SVG for infrastructure card
     */
    function generateSVG(uint256 tokenId, InfrastructureTraits memory traits)
        internal pure returns (string memory)
    {
        string memory typeColors = _getTypeColorScheme(traits.infraType);
        (string memory rPrimary, string memory rSecondary, string memory rGlow) = _getRarityColors(traits.rarity);

        return string.concat(
            '<svg viewBox="0 0 300 400" xmlns="http://www.w3.org/2000/svg">',
            '<defs>', _generateDefs(typeColors, rPrimary, rSecondary, rGlow, traits.rarity, tokenId), '</defs>',
            _generateBackground(typeColors, tokenId),
            _generateRarityFrame(traits.rarity, rPrimary, rGlow, tokenId),
            _generateGrid(typeColors, traits.rarity, rPrimary),
            _generateInfrastructureIcon(traits, rPrimary, rSecondary),
            _generateCyborgChickenWorker(traits, rPrimary),
            _generateRaritySymbol(traits.rarity, rPrimary),
            _generateStatsBars(traits, rPrimary, rSecondary),
            _generateTechLevel(traits.techLevel, rPrimary),
            _generateTypeBadge(traits.infraType, typeColors),
            '</svg>'
        );
    }

    // ============ COLOR SCHEMES ============

    function _getTypeColorScheme(InfrastructureType infraType)
        private pure returns (string memory)
    {
        if (infraType == InfrastructureType.MiningDrill) {
            return "#FF6B35,#F7931E,#8B4513"; // Orange-Brown (mining)
        }
        if (infraType == InfrastructureType.EnergyHarvester) {
            return "#FFD700,#00CED1,#1E90FF"; // Gold-Cyan (energy)
        }
        if (infraType == InfrastructureType.ProcessingPlant) {
            return "#00FF88,#32CD32,#228B22"; // Green (processing)
        }
        if (infraType == InfrastructureType.DefenseTurret) {
            return "#DC143C,#FF4500,#8B0000"; // Red (defense)
        }
        if (infraType == InfrastructureType.ResearchLab) {
            return "#9370DB,#4169E1,#6A5ACD"; // Purple-Blue (research)
        }
        return "#708090,#4682B4,#2F4F4F"; // Steel Gray (storage)
    }

    function _getRarityColors(Rarity rarity)
        private pure returns (string memory primary, string memory secondary, string memory glow)
    {
        if (rarity == Rarity.Legendary) {
            return ("#FFD700", "#FFED4E", "#FFAA00");
        }
        if (rarity == Rarity.Epic) {
            return ("#9B59B6", "#C39BD3", "#8E44AD");
        }
        if (rarity == Rarity.Rare) {
            return ("#3498DB", "#5DADE2", "#2980B9");
        }
        if (rarity == Rarity.Uncommon) {
            return ("#2ECC71", "#58D68D", "#27AE60");
        }
        return ("#95A5A6", "#BDC3C7", "#7F8C8D");
    }

    // ============ SVG GENERATION ============

    function _generateDefs(
        string memory typeColors,
        string memory rPrimary,
        string memory rSecondary,
        string memory rGlow,
        Rarity rarity,
        uint256 tokenId
    ) private pure returns (string memory) {
        (string memory c1, string memory c2, ) = _splitColors(typeColors);
        string memory id = tokenId.toString();

        return string.concat(
            // Background gradient
            '<radialGradient id="bg-', id, '" cx="50%" cy="30%">',
            '<stop offset="0%" stop-color="', c1, '" stop-opacity="0.35"/>',
            '<stop offset="100%" stop-color="', c2, '" stop-opacity="0.12"/>',
            '</radialGradient>',
            // Rarity frame gradient
            '<linearGradient id="frame-', id, '" x1="0%" y1="0%" x2="100%" y2="100%">',
            '<stop offset="0%" stop-color="', rPrimary, '"/>',
            '<stop offset="50%" stop-color="', rSecondary, '"/>',
            '<stop offset="100%" stop-color="', rGlow, '"/>',
            '</linearGradient>',
            // Glow filter
            '<filter id="glow-', id, '">',
            '<feGaussianBlur stdDeviation="', rarity == Rarity.Legendary ? "5" : rarity == Rarity.Epic ? "4" : "3", '" result="blur"/>',
            '<feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge>',
            '</filter>',
            // Animation styles
            _generateAnimationStyles(rarity)
        );
    }

    function _generateAnimationStyles(Rarity rarity) private pure returns (string memory) {
        if (rarity == Rarity.Legendary) {
            return '<style>'
                '.pulse{animation:pulse 2s ease-in-out infinite}'
                '@keyframes pulse{0%,100%{opacity:0.6}50%{opacity:1}}'
                '.rotate{animation:rotate 20s linear infinite;transform-origin:center}'
                '@keyframes rotate{from{transform:rotate(0)}to{transform:rotate(360deg)}}'
                '.float{animation:float 3s ease-in-out infinite}'
                '@keyframes float{0%,100%{transform:translateY(0)}50%{transform:translateY(-5px)}}'
                '</style>';
        }
        if (rarity == Rarity.Epic) {
            return '<style>'
                '.pulse{animation:pulse 3s ease-in-out infinite}'
                '@keyframes pulse{0%,100%{opacity:0.5}50%{opacity:0.9}}'
                '.rotate{animation:rotate 30s linear infinite;transform-origin:center}'
                '@keyframes rotate{from{transform:rotate(0)}to{transform:rotate(360deg)}}'
                '</style>';
        }
        return '<style>.pulse{animation:pulse 4s ease-in-out infinite}@keyframes pulse{0%,100%{opacity:0.4}50%{opacity:0.7}}</style>';
    }

    function _generateBackground(string memory typeColors, uint256 tokenId)
        private pure returns (string memory)
    {
        string memory id = tokenId.toString();
        return string.concat(
            '<rect width="300" height="400" fill="#0a0a14" rx="12"/>',
            '<rect width="300" height="400" fill="url(#bg-', id, ')" rx="12"/>'
        );
    }

    function _generateRarityFrame(
        Rarity rarity,
        string memory rPrimary,
        string memory rGlow,
        uint256 tokenId
    ) private pure returns (string memory) {
        string memory id = tokenId.toString();
        uint8 strokeWidth = rarity == Rarity.Legendary ? 4 :
                           rarity == Rarity.Epic ? 3 :
                           rarity == Rarity.Rare ? 2 : 1;

        string memory frame = string.concat(
            '<rect x="5" y="5" width="290" height="390" rx="10" fill="none" ',
            'stroke="url(#frame-', id, ')" stroke-width="', _uint8ToString(strokeWidth), '"',
            rarity == Rarity.Legendary ? ' filter="url(#glow-' : '',
            rarity == Rarity.Legendary ? string.concat(id, ')"') : '',
            '/>'
        );

        // Double frame for Legendary/Epic
        if (rarity == Rarity.Legendary || rarity == Rarity.Epic) {
            frame = string.concat(
                frame,
                '<rect x="8" y="8" width="284" height="384" rx="8" fill="none" ',
                'stroke="', rGlow, '" stroke-width="1" opacity="0.5"/>'
            );
        }

        // Corner accents for Legendary
        if (rarity == Rarity.Legendary) {
            frame = string.concat(
                frame,
                '<circle cx="20" cy="20" r="5" fill="', rPrimary, '" class="pulse"/>',
                '<circle cx="280" cy="20" r="5" fill="', rPrimary, '" class="pulse"/>',
                '<circle cx="20" cy="380" r="5" fill="', rPrimary, '" class="pulse"/>',
                '<circle cx="280" cy="380" r="5" fill="', rPrimary, '" class="pulse"/>'
            );
        }

        return frame;
    }

    function _generateGrid(string memory typeColors, Rarity rarity, string memory rPrimary)
        private pure returns (string memory)
    {
        (string memory c1, , ) = _splitColors(typeColors);
        string memory gridColor = rarity >= Rarity.Epic ? rPrimary : c1;

        string memory lines = '';
        for (uint256 i = 0; i <= 300; i += 25) {
            lines = string.concat(
                lines,
                '<line x1="', i.toString(), '" y1="0" x2="', i.toString(), '" y2="400" ',
                'stroke="', gridColor, '" stroke-width="0.4" opacity="0.15"/>',
                '<line x1="0" y1="', (i * 4 / 3).toString(), '" x2="300" y2="', (i * 4 / 3).toString(), '" ',
                'stroke="', gridColor, '" stroke-width="0.4" opacity="0.15"/>'
            );
        }

        return string.concat('<g>', lines, '</g>');
    }

    function _generateInfrastructureIcon(
        InfrastructureTraits memory traits,
        string memory rPrimary,
        string memory rSecondary
    ) private pure returns (string memory) {
        if (traits.infraType == InfrastructureType.MiningDrill) {
            return _generateMiningDrillIcon(traits.rarity, rPrimary, rSecondary);
        }
        if (traits.infraType == InfrastructureType.EnergyHarvester) {
            return _generateEnergyHarvesterIcon(traits.rarity, rPrimary, rSecondary);
        }
        if (traits.infraType == InfrastructureType.ProcessingPlant) {
            return _generateProcessingPlantIcon(traits.rarity, rPrimary, rSecondary);
        }
        if (traits.infraType == InfrastructureType.DefenseTurret) {
            return _generateDefenseTurretIcon(traits.rarity, rPrimary, rSecondary);
        }
        if (traits.infraType == InfrastructureType.ResearchLab) {
            return _generateResearchLabIcon(traits.rarity, rPrimary, rSecondary);
        }
        return _generateStorageFacilityIcon(traits.rarity, rPrimary, rSecondary);
    }

    function _generateMiningDrillIcon(Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';

        return string.concat(
            '<g transform="translate(150, 175)">',
            // Base platform
            '<ellipse cx="0" cy="70" rx="60" ry="15" fill="#2c3e50" stroke="', rPrimary, '" stroke-width="2"/>',
            // Drill tower
            '<rect x="-12" y="-80" width="24" height="150" fill="#8B4513" rx="3"/>',
            '<rect x="-8" y="-75" width="16" height="140" fill="#A0522D"/>',
            // Cross beams
            '<line x1="-30" y1="-60" x2="30" y2="-20" stroke="#696969" stroke-width="4"/>',
            '<line x1="30" y1="-60" x2="-30" y2="-20" stroke="#696969" stroke-width="4"/>',
            // Drill head
            '<polygon points="0,75 -20,55 20,55" fill="#FF6B35" stroke="', rPrimary, '" stroke-width="1"', animClass, '/>',
            '<polygon points="0,90 -15,70 15,70" fill="', rPrimary, '"', animClass, '/>',
            // Rotating gear
            '<circle cx="0" cy="0" r="25" fill="none" stroke="', rSecondary, '" stroke-width="4" stroke-dasharray="10 5"',
            rarity == Rarity.Legendary ? ' class="rotate"' : '', '/>',
            // Energy cores
            '<circle cx="-25" cy="-50" r="8" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="25" cy="-50" r="8" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="0" cy="-85" r="10" fill="', rSecondary, '"', animClass, '/>',
            // Sparks (Legendary/Epic)
            rarity >= Rarity.Epic ? _generateSparks(rPrimary) : '',
            '</g>'
        );
    }

    function _generateEnergyHarvesterIcon(Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';

        return string.concat(
            '<g transform="translate(150, 175)">',
            // Central pillar
            '<rect x="-15" y="-60" width="30" height="120" fill="#1E90FF" rx="5"/>',
            // Solar panels (left)
            '<rect x="-70" y="-30" width="50" height="25" fill="#00CED1" stroke="', rPrimary, '" stroke-width="1" rx="3" transform="rotate(-15 -45 -17)"/>',
            '<rect x="-70" y="5" width="50" height="25" fill="#00CED1" stroke="', rPrimary, '" stroke-width="1" rx="3" transform="rotate(-10 -45 17)"/>',
            // Solar panels (right)
            '<rect x="20" y="-30" width="50" height="25" fill="#00CED1" stroke="', rPrimary, '" stroke-width="1" rx="3" transform="rotate(15 45 -17)"/>',
            '<rect x="20" y="5" width="50" height="25" fill="#00CED1" stroke="', rPrimary, '" stroke-width="1" rx="3" transform="rotate(10 45 17)"/>',
            // Energy orb
            '<circle cx="0" cy="0" r="20" fill="', rSecondary, '" opacity="0.8"', animClass, '/>',
            '<circle cx="0" cy="0" r="12" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="0" cy="0" r="6" fill="#FFF"/>',
            // Lightning bolts
            '<path d="M-5,-65 L5,-55 L-3,-55 L5,-45" stroke="', rPrimary, '" stroke-width="3" fill="none"', animClass, '/>',
            '<path d="M-5,45 L5,55 L-3,55 L5,65" stroke="', rPrimary, '" stroke-width="3" fill="none"', animClass, '/>',
            // Energy rings
            '<circle cx="0" cy="0" r="35" fill="none" stroke="', rSecondary, '" stroke-width="2" opacity="0.5"',
            rarity == Rarity.Legendary ? ' class="pulse"' : '', '/>',
            '<circle cx="0" cy="0" r="45" fill="none" stroke="', rPrimary, '" stroke-width="1" opacity="0.3"',
            rarity == Rarity.Legendary ? ' class="pulse"' : '', '/>',
            '</g>'
        );
    }

    function _generateProcessingPlantIcon(Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';

        return string.concat(
            '<g transform="translate(150, 175)">',
            // Main building
            '<rect x="-50" y="-40" width="100" height="90" fill="#228B22" rx="8" stroke="', rPrimary, '" stroke-width="2"/>',
            '<rect x="-45" y="-35" width="90" height="80" fill="#2E8B57" rx="5"/>',
            // Chimneys
            '<rect x="-35" y="-70" width="15" height="35" fill="#32CD32"/>',
            '<rect x="20" y="-80" width="15" height="45" fill="#32CD32"/>',
            // Smoke (animated for legendary)
            '<ellipse cx="-27" cy="-80" rx="10" ry="6" fill="#00FF88" opacity="0.5"', animClass, '/>',
            '<ellipse cx="27" cy="-90" rx="12" ry="8" fill="#00FF88" opacity="0.5"', animClass, '/>',
            // Processing windows
            '<rect x="-35" y="-20" width="25" height="20" fill="', rSecondary, '" rx="3"/>',
            '<rect x="10" y="-20" width="25" height="20" fill="', rSecondary, '" rx="3"/>',
            // Conveyor belt
            '<rect x="-60" y="35" width="120" height="15" fill="#696969" rx="5"/>',
            '<circle cx="-50" cy="42" r="8" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="0" cy="42" r="8" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="50" cy="42" r="8" fill="', rPrimary, '"', animClass, '/>',
            // Central core
            '<circle cx="0" cy="10" r="18" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="0" cy="10" r="10" fill="#FFF" opacity="0.5"/>',
            '</g>'
        );
    }

    function _generateDefenseTurretIcon(Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';

        return string.concat(
            '<g transform="translate(150, 175)">',
            // Base
            '<ellipse cx="0" cy="60" rx="55" ry="20" fill="#2c3e50" stroke="', rPrimary, '" stroke-width="2"/>',
            // Turret body
            '<rect x="-35" y="0" width="70" height="60" fill="#8B0000" rx="10" stroke="', rPrimary, '" stroke-width="2"/>',
            '<rect x="-30" y="5" width="60" height="50" fill="#DC143C" rx="8"/>',
            // Rotating dome
            '<ellipse cx="0" cy="0" rx="40" ry="25" fill="#FF4500" stroke="', rSecondary, '" stroke-width="2"',
            rarity == Rarity.Legendary ? ' class="rotate"' : '', '/>',
            // Cannons
            '<rect x="-45" y="-15" width="35" height="10" fill="#8B0000" rx="3"/>',
            '<rect x="10" y="-15" width="35" height="10" fill="#8B0000" rx="3"/>',
            '<circle cx="-50" cy="-10" r="6" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="50" cy="-10" r="6" fill="', rPrimary, '"', animClass, '/>',
            // Targeting system
            '<circle cx="0" cy="-35" r="15" fill="#1a1a2e" stroke="', rSecondary, '" stroke-width="2"/>',
            '<circle cx="0" cy="-35" r="8" fill="', rPrimary, '"', animClass, '/>',
            '<line x1="0" y1="-50" x2="0" y2="-20" stroke="', rPrimary, '" stroke-width="1" opacity="0.5"/>',
            '<line x1="-15" y1="-35" x2="15" y2="-35" stroke="', rPrimary, '" stroke-width="1" opacity="0.5"/>',
            // Warning lights
            '<circle cx="-25" cy="25" r="5" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="25" cy="25" r="5" fill="', rPrimary, '"', animClass, '/>',
            '</g>'
        );
    }

    function _generateResearchLabIcon(Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';

        return string.concat(
            '<g transform="translate(150, 175)">',
            // Main dome
            '<ellipse cx="0" cy="20" rx="55" ry="50" fill="#4169E1" stroke="', rPrimary, '" stroke-width="2"/>',
            '<ellipse cx="0" cy="20" rx="50" ry="45" fill="#6A5ACD" opacity="0.9"/>',
            // Glass panels
            '<path d="M-40,10 Q0,-30 40,10" fill="none" stroke="', rSecondary, '" stroke-width="3"/>',
            '<path d="M-30,25 Q0,0 30,25" fill="none" stroke="', rSecondary, '" stroke-width="2"/>',
            // Antenna array
            '<rect x="-5" y="-70" width="10" height="50" fill="#9370DB"/>',
            '<circle cx="0" cy="-75" r="12" fill="', rSecondary, '"', animClass, '/>',
            '<circle cx="0" cy="-75" r="6" fill="', rPrimary, '"', animClass, '/>',
            // Satellite dishes
            '<ellipse cx="-45" cy="-20" rx="15" ry="10" fill="#8A2BE2" transform="rotate(-30 -45 -20)"/>',
            '<ellipse cx="45" cy="-20" rx="15" ry="10" fill="#8A2BE2" transform="rotate(30 45 -20)"/>',
            // Data streams
            '<line x1="-40" y1="-15" x2="-5" y2="-60" stroke="', rPrimary, '" stroke-width="2" stroke-dasharray="5 3"', animClass, '/>',
            '<line x1="40" y1="-15" x2="5" y2="-60" stroke="', rPrimary, '" stroke-width="2" stroke-dasharray="5 3"', animClass, '/>',
            // Base platform
            '<rect x="-60" y="55" width="120" height="15" fill="#2c3e50" rx="5" stroke="', rPrimary, '" stroke-width="1"/>',
            // Floating data orbs
            '<circle cx="-25" cy="30" r="8" fill="', rPrimary, '" opacity="0.6"', rarity == Rarity.Legendary ? ' class="float"' : '', '/>',
            '<circle cx="25" cy="30" r="8" fill="', rPrimary, '" opacity="0.6"', rarity == Rarity.Legendary ? ' class="float"' : '', '/>',
            '</g>'
        );
    }

    function _generateStorageFacilityIcon(Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';

        return string.concat(
            '<g transform="translate(150, 175)">',
            // Main container
            '<rect x="-55" y="-50" width="110" height="100" fill="#4682B4" rx="10" stroke="', rPrimary, '" stroke-width="2"/>',
            '<rect x="-50" y="-45" width="100" height="90" fill="#5F9EA0" rx="8"/>',
            // Storage compartments
            '<rect x="-45" y="-40" width="40" height="35" fill="#708090" rx="5" stroke="', rSecondary, '" stroke-width="1"/>',
            '<rect x="5" y="-40" width="40" height="35" fill="#708090" rx="5" stroke="', rSecondary, '" stroke-width="1"/>',
            '<rect x="-45" y="5" width="40" height="35" fill="#708090" rx="5" stroke="', rSecondary, '" stroke-width="1"/>',
            '<rect x="5" y="5" width="40" height="35" fill="#708090" rx="5" stroke="', rSecondary, '" stroke-width="1"/>',
            // Status indicators
            '<circle cx="-25" cy="-22" r="6" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="25" cy="-22" r="6" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="-25" cy="22" r="6" fill="', rSecondary, '"', animClass, '/>',
            '<circle cx="25" cy="22" r="6" fill="', rSecondary, '"', animClass, '/>',
            // Capacity bars
            '<rect x="-45" y="50" width="90" height="8" fill="#2c3e50" rx="4"/>',
            '<rect x="-43" y="52" width="60" height="4" fill="', rPrimary, '" rx="2"', animClass, '/>',
            // Lock mechanism
            '<circle cx="0" cy="-55" r="10" fill="#2c3e50" stroke="', rSecondary, '" stroke-width="2"/>',
            '<rect x="-3" y="-58" width="6" height="8" fill="', rPrimary, '"/>',
            '</g>'
        );
    }

    function _generateSparks(string memory color) private pure returns (string memory) {
        return string.concat(
            '<circle cx="-40" cy="60" r="3" fill="', color, '" class="pulse"/>',
            '<circle cx="40" cy="60" r="3" fill="', color, '" class="pulse"/>',
            '<circle cx="-35" cy="70" r="2" fill="', color, '" class="pulse"/>',
            '<circle cx="35" cy="70" r="2" fill="', color, '" class="pulse"/>'
        );
    }

    function _generateCyborgChickenWorker(InfrastructureTraits memory traits, string memory rPrimary)
        private pure returns (string memory)
    {
        (string memory c1, string memory c2, ) = _splitColors(_getTypeColorScheme(traits.infraType));
        string memory chickenBorder = traits.rarity >= Rarity.Epic ? rPrimary : c1;

        return string.concat(
            // Left chicken (scaled 0.8, repositioned)
            '<g transform="translate(45, 355) scale(0.8)">',
            '<ellipse cx="0" cy="0" rx="12" ry="15" fill="', c2, '" stroke="', chickenBorder, '" stroke-width="1"/>',
            '<circle cx="0" cy="-18" r="10" fill="', c1, '" stroke="', chickenBorder, '" stroke-width="1"/>',
            '<circle cx="3" cy="-19" r="3" fill="#000"/>',
            '<circle cx="4" cy="-20" r="1" fill="#FFF"/>',
            '<polygon points="8,-18 12,-15 8,-12" fill="#FF9800"/>',
            '<ellipse cx="0" cy="-25" rx="10" ry="4" fill="', rPrimary, '"/>',
            '<rect x="-8" y="-27" width="16" height="4" fill="', rPrimary, '"/>',
            '</g>',
            // Right chicken (scaled 0.8)
            '<g transform="translate(255, 355) scale(0.8)">',
            '<ellipse cx="0" cy="0" rx="12" ry="15" fill="', c1, '" stroke="', chickenBorder, '" stroke-width="1"/>',
            '<circle cx="0" cy="-18" r="10" fill="', c2, '" stroke="', chickenBorder, '" stroke-width="1"/>',
            '<circle cx="-3" cy="-19" r="3" fill="#000"/>',
            '<circle cx="-2" cy="-20" r="1" fill="#FFF"/>',
            '<polygon points="-8,-18 -12,-15 -8,-12" fill="#FF9800"/>',
            '<ellipse cx="0" cy="-25" rx="10" ry="4" fill="', rPrimary, '"/>',
            '<rect x="-8" y="-27" width="16" height="4" fill="', rPrimary, '"/>',
            '</g>'
        );
    }

    function _generateRaritySymbol(Rarity rarity, string memory color)
        private pure returns (string memory)
    {
        string memory symbol;

        if (rarity == Rarity.Legendary) {
            symbol = unicode"♦";
        } else if (rarity == Rarity.Epic) {
            symbol = unicode"★";
        } else if (rarity == Rarity.Rare) {
            symbol = unicode"◆";
        } else if (rarity == Rarity.Uncommon) {
            symbol = unicode"▲";
        } else {
            symbol = unicode"●";
        }

        return string.concat(
            '<text x="25" y="35" text-anchor="middle" fill="', color,
            '" font-size="22" font-weight="900"',
            rarity == Rarity.Legendary ? ' class="pulse"' : '',
            '>', symbol, '</text>'
        );
    }

    function _generateStatsBars(
        InfrastructureTraits memory traits,
        string memory rPrimary,
        string memory rSecondary
    ) private pure returns (string memory) {
        uint256 effValue = uint256(traits.efficiencyBonus) > 100 ? 100 : uint256(traits.efficiencyBonus);
        uint256 capValue = uint256(traits.capacityBonus) > 100 ? 100 : uint256(traits.capacityBonus);

        return string.concat(
            // Stats badge (top-right, semi-transparent like ResourceCards)
            '<g transform="translate(175, 35)">',
            '<rect x="0" y="0" width="105" height="38" fill="rgba(10,10,20,0.6)" rx="8" stroke="', rPrimary, '" stroke-width="1" stroke-opacity="0.7"/>',
            // Efficiency row
            '<text x="8" y="14" fill="#AAA" font-size="8">EFF</text>',
            '<rect x="28" y="8" width="50" height="5" rx="2" fill="rgba(0,0,0,0.5)"/>',
            '<rect x="28" y="8" width="', (effValue * 50 / 100).toString(), '" height="5" rx="2" fill="', rPrimary, '"/>',
            '<text x="82" y="14" fill="', rPrimary, '" font-size="8" font-weight="700">+', uint256(traits.efficiencyBonus).toString(), '%</text>',
            // Capacity row
            '<text x="8" y="30" fill="#AAA" font-size="8">CAP</text>',
            '<rect x="28" y="24" width="50" height="5" rx="2" fill="rgba(0,0,0,0.5)"/>',
            '<rect x="28" y="24" width="', (capValue * 50 / 100).toString(), '" height="5" rx="2" fill="', rSecondary, '"/>',
            '<text x="82" y="30" fill="', rSecondary, '" font-size="8" font-weight="700">+', uint256(traits.capacityBonus).toString(), '</text>',
            '</g>'
        );
    }

    function _generateTechLevel(uint8 techLevel, string memory color)
        private pure returns (string memory)
    {
        string memory dots = '';
        // Tech level dots at y=318 (above chickens, below type badge)
        // Dots start at x=50 to not overlap with TECH label
        for (uint8 i = 0; i < techLevel && i < 5; i++) {
            dots = string.concat(
                dots,
                '<circle cx="', uint256(50 + i * 12).toString(), '" cy="318" r="3" fill="', color, '"/>'
            );
        }
        // Empty dots
        for (uint8 i = techLevel; i < 5; i++) {
            dots = string.concat(
                dots,
                '<circle cx="', uint256(50 + i * 12).toString(), '" cy="318" r="3" fill="#333" stroke="', color, '" stroke-width="0.5"/>'
            );
        }

        return string.concat(
            '<text x="18" y="321" fill="#888" font-size="8">TECH</text>',
            dots
        );
    }

    function _generateTypeBadge(InfrastructureType infraType, string memory typeColors)
        private pure returns (string memory)
    {
        (string memory c1, , ) = _splitColors(typeColors);
        string memory typeName = _getTypeName(infraType);

        return string.concat(
            '<g transform="translate(150, 285)">',
            '<rect x="-60" y="-12" width="120" height="24" rx="12" fill="rgba(0,0,0,0.7)" stroke="', c1, '" stroke-width="1"/>',
            '<text x="0" y="5" text-anchor="middle" fill="', c1, '" font-size="10" font-weight="bold">', typeName, '</text>',
            '</g>',
            // HENOMORPHS branding at bottom
            '<text x="150" y="388" text-anchor="middle" fill="#444" font-size="9" letter-spacing="8" font-weight="300">HENOMORPHS</text>'
        );
    }

    function _getTypeName(InfrastructureType infraType) private pure returns (string memory) {
        if (infraType == InfrastructureType.MiningDrill) return "MINING DRILL";
        if (infraType == InfrastructureType.EnergyHarvester) return "ENERGY HARVESTER";
        if (infraType == InfrastructureType.ProcessingPlant) return "PROCESSING PLANT";
        if (infraType == InfrastructureType.DefenseTurret) return "DEFENSE TURRET";
        if (infraType == InfrastructureType.ResearchLab) return "RESEARCH LAB";
        return "STORAGE FACILITY";
    }

    // ============ UTILITY FUNCTIONS ============

    function _splitColors(string memory colors)
        private pure returns (string memory c1, string memory c2, string memory c3)
    {
        bytes memory b = bytes(colors);
        uint256 firstComma = 0;
        uint256 secondComma = 0;

        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ",") {
                if (firstComma == 0) {
                    firstComma = i;
                } else {
                    secondComma = i;
                    break;
                }
            }
        }

        bytes memory color1 = new bytes(firstComma);
        bytes memory color2 = new bytes(secondComma - firstComma - 1);
        bytes memory color3 = new bytes(b.length - secondComma - 1);

        for (uint256 i = 0; i < firstComma; i++) {
            color1[i] = b[i];
        }
        for (uint256 i = 0; i < color2.length; i++) {
            color2[i] = b[firstComma + 1 + i];
        }
        for (uint256 i = 0; i < color3.length; i++) {
            color3[i] = b[secondComma + 1 + i];
        }

        return (string(color1), string(color2), string(color3));
    }

    function _uint8ToString(uint8 value) private pure returns (string memory) {
        return Strings.toString(uint256(value));
    }
}
