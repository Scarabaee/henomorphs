// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title ResourceSVGLib
 * @notice Library for generating Resource Card SVG graphics - Hendom Visual Style
 * @dev Based on TerritorySVGLib and StkHenoSVGBuilder visual patterns
 * @author rutilicus.eth (ArchXS)
 * @custom:version 2.0.0
 * @custom:changelog Complete rewrite with animated elements, particle effects, and cyborg chickens
 */
library ResourceSVGLib {
    using Strings for uint256;

    enum ResourceType {
        BasicMaterials,     // 0 - Stone, Wood, Metal
        EnergyCrystals,     // 1 - Power sources
        BioCompounds,       // 2 - Organic materials
        RareElements        // 3 - Exotic materials
    }

    enum Rarity { Common, Uncommon, Rare, Epic, Legendary }

    struct ResourceTraits {
        ResourceType resourceType;
        Rarity rarity;
        uint8 yieldBonus;         // Production bonus (0-100%)
        uint8 qualityLevel;       // Quality tier (1-5)
        uint16 stackSize;         // Current stack (1-99)
        uint16 maxStack;          // Maximum stack size
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
     * @notice Generate complete SVG for resource card
     */
    function generateSVG(uint256 tokenId, ResourceTraits memory traits)
        internal pure returns (string memory)
    {
        string memory typeColors = _getTypeColorScheme(traits.resourceType);
        (string memory rPrimary, string memory rSecondary, string memory rGlow) = _getRarityColors(traits.rarity);

        return string.concat(
            '<svg viewBox="0 0 300 400" xmlns="http://www.w3.org/2000/svg">',
            '<defs>', _generateDefs(typeColors, rPrimary, rSecondary, rGlow, traits.rarity, tokenId), '</defs>',
            _generateBackground(typeColors, tokenId),
            _generateRarityFrame(traits.rarity, rPrimary, rGlow, tokenId),
            _generateGrid(typeColors, traits.rarity, rPrimary),
            _generateResourceIcon(traits, rPrimary, rSecondary),
            _generateParticles(traits.rarity, rPrimary, tokenId),
            _generateCyborgChickenCarrier(traits, rPrimary),
            _generateRaritySymbol(traits.rarity, rPrimary),
            _generateStackIndicator(traits.stackSize, traits.maxStack, rSecondary),
            _generateQualityStars(traits.qualityLevel, rPrimary),
            _generateStatsBadges(traits, rPrimary, rSecondary),
            _generateTypeBadge(traits.resourceType, typeColors),
            '</svg>'
        );
    }

    // ============ COLOR SCHEMES ============

    function _getTypeColorScheme(ResourceType rType) private pure returns (string memory) {
        if (rType == ResourceType.BasicMaterials) {
            return "#8B4513,#A0522D,#D2691E"; // Browns (earth materials)
        }
        if (rType == ResourceType.EnergyCrystals) {
            return "#00BFFF,#1E90FF,#00CED1"; // Blue-Cyan (energy)
        }
        if (rType == ResourceType.BioCompounds) {
            return "#32CD32,#228B22,#00FF88"; // Greens (organic)
        }
        return "#9370DB,#8A2BE2,#DA70D6"; // Purples (rare)
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
            '<stop offset="0%" stop-color="', c1, '" stop-opacity="0.4"/>',
            '<stop offset="100%" stop-color="', c2, '" stop-opacity="0.15"/>',
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
                '.rotate{animation:rotate 15s linear infinite;transform-origin:center}'
                '@keyframes rotate{from{transform:rotate(0)}to{transform:rotate(360deg)}}'
                '.float{animation:float 3s ease-in-out infinite}'
                '@keyframes float{0%,100%{transform:translateY(0)}50%{transform:translateY(-8px)}}'
                '.shimmer{animation:shimmer 2s linear infinite}'
                '@keyframes shimmer{0%{opacity:0.3}50%{opacity:1}100%{opacity:0.3}}'
                '</style>';
        }
        if (rarity == Rarity.Epic) {
            return '<style>'
                '.pulse{animation:pulse 3s ease-in-out infinite}'
                '@keyframes pulse{0%,100%{opacity:0.5}50%{opacity:0.9}}'
                '.rotate{animation:rotate 25s linear infinite;transform-origin:center}'
                '@keyframes rotate{from{transform:rotate(0)}to{transform:rotate(360deg)}}'
                '.float{animation:float 4s ease-in-out infinite}'
                '@keyframes float{0%,100%{transform:translateY(0)}50%{transform:translateY(-5px)}}'
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

        // Corner gems for Legendary
        if (rarity == Rarity.Legendary) {
            frame = string.concat(
                frame,
                '<polygon points="20,12 25,20 20,28 15,20" fill="', rPrimary, '" class="shimmer"/>',
                '<polygon points="280,12 285,20 280,28 275,20" fill="', rPrimary, '" class="shimmer"/>',
                '<polygon points="20,372 25,380 20,388 15,380" fill="', rPrimary, '" class="shimmer"/>',
                '<polygon points="280,372 285,380 280,388 275,380" fill="', rPrimary, '" class="shimmer"/>'
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
                'stroke="', gridColor, '" stroke-width="0.4" opacity="0.12"/>',
                '<line x1="0" y1="', (i * 4 / 3).toString(), '" x2="300" y2="', (i * 4 / 3).toString(), '" ',
                'stroke="', gridColor, '" stroke-width="0.4" opacity="0.12"/>'
            );
        }

        return string.concat('<g>', lines, '</g>');
    }

    function _generateResourceIcon(
        ResourceTraits memory traits,
        string memory rPrimary,
        string memory rSecondary
    ) private pure returns (string memory) {
        if (traits.resourceType == ResourceType.BasicMaterials) {
            return _generateBasicMaterialsIcon(traits.rarity, rPrimary, rSecondary);
        }
        if (traits.resourceType == ResourceType.EnergyCrystals) {
            return _generateEnergyCrystalsIcon(traits.rarity, rPrimary, rSecondary);
        }
        if (traits.resourceType == ResourceType.BioCompounds) {
            return _generateBioCompoundsIcon(traits.rarity, rPrimary, rSecondary);
        }
        return _generateRareElementsIcon(traits.rarity, rPrimary, rSecondary);
    }

    function _generateBasicMaterialsIcon(Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';
        string memory floatClass = rarity == Rarity.Legendary ? ' class="float"' : '';

        return string.concat(
            '<g transform="translate(150, 170)">',
            // Mountain/Rock formation
            '<path d="M-60,60 L-40,-20 L-10,30 L20,-40 L50,20 L60,60 Z" fill="#696969" stroke="', rPrimary, '" stroke-width="2"/>',
            '<path d="M-55,55 L-38,-15 L-12,25 L18,-35 L48,18 L55,55 Z" fill="#808080"/>',
            // Crystal deposits
            '<polygon points="-30,20 -25,0 -20,20 -25,35" fill="', rSecondary, '"', floatClass, '/>',
            '<polygon points="5,15 12,-10 19,15 12,30" fill="', rPrimary, '"', floatClass, '/>',
            '<polygon points="30,25 35,10 40,25 35,40" fill="', rSecondary, '"', floatClass, '/>',
            // Gold veins
            '<path d="M-40,10 Q-20,5 0,15 Q20,25 35,20" stroke="', rPrimary, '" stroke-width="3" fill="none" opacity="0.8"', animClass, '/>',
            '<path d="M-35,35 Q-10,30 10,40 Q30,50 45,45" stroke="', rSecondary, '" stroke-width="2" fill="none" opacity="0.6"/>',
            // Sparkling points
            '<circle cx="-25" cy="8" r="4" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="12" cy="3" r="5" fill="', rSecondary, '"', animClass, '/>',
            '<circle cx="35" cy="15" r="3" fill="', rPrimary, '"', animClass, '/>',
            // Mining pick (decorative)
            '<path d="M-50,-40 L-35,-25" stroke="#A0522D" stroke-width="4"/>',
            '<path d="M-50,-40 L-55,-35 L-45,-30" fill="#696969"/>',
            '</g>'
        );
    }

    function _generateEnergyCrystalsIcon(Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';
        string memory floatClass = rarity == Rarity.Legendary ? ' class="float"' : '';

        return string.concat(
            '<g transform="translate(150, 170)">',
            // Main crystal
            '<polygon points="0,-70 -25,-20 -20,50 20,50 25,-20" fill="#00BFFF" stroke="', rPrimary, '" stroke-width="2" opacity="0.9"', floatClass, '/>',
            '<polygon points="0,-65 -20,-18 -16,45 16,45 20,-18" fill="#1E90FF"/>',
            '<polygon points="0,-55 -12,-10 -10,35 10,35 12,-10" fill="', rSecondary, '" opacity="0.8"/>',
            // Inner glow
            '<line x1="0" y1="-60" x2="0" y2="40" stroke="#FFF" stroke-width="3" opacity="0.5"/>',
            // Side crystals
            '<polygon points="-45,-25 -55,0 -45,35 -35,0" fill="#00CED1" opacity="0.8"', floatClass, '/>',
            '<polygon points="45,-25 55,0 45,35 35,0" fill="#00CED1" opacity="0.8"', floatClass, '/>',
            // Energy rings
            '<ellipse cx="0" cy="10" rx="50" ry="15" fill="none" stroke="', rPrimary, '" stroke-width="2" opacity="0.4"',
            rarity == Rarity.Legendary ? ' class="rotate"' : '', '/>',
            '<ellipse cx="0" cy="10" rx="60" ry="20" fill="none" stroke="', rSecondary, '" stroke-width="1" opacity="0.3"',
            rarity == Rarity.Legendary ? ' class="rotate"' : '', '/>',
            // Energy sparks
            '<circle cx="-30" cy="-10" r="6" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="30" cy="-10" r="6" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="0" cy="-75" r="8" fill="', rSecondary, '"', animClass, '/>',
            // Lightning bolts
            '<path d="M-35,-50 L-25,-40 L-35,-30" stroke="', rPrimary, '" stroke-width="2" fill="none"', animClass, '/>',
            '<path d="M35,-50 L25,-40 L35,-30" stroke="', rPrimary, '" stroke-width="2" fill="none"', animClass, '/>',
            '</g>'
        );
    }

    function _generateBioCompoundsIcon(Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';
        string memory floatClass = rarity == Rarity.Legendary ? ' class="float"' : '';

        return string.concat(
            '<g transform="translate(150, 170)">',
            // Central cell
            '<ellipse cx="0" cy="0" rx="50" ry="40" fill="#228B22" opacity="0.8" stroke="', rPrimary, '" stroke-width="2"/>',
            '<ellipse cx="0" cy="0" rx="40" ry="30" fill="#32CD32" opacity="0.9"/>',
            // Nucleus
            '<circle cx="0" cy="0" r="20" fill="', rSecondary, '" opacity="0.7"', floatClass, '/>',
            '<circle cx="0" cy="0" r="12" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="0" cy="0" r="6" fill="#FFF" opacity="0.6"/>',
            // DNA strands
            '<path d="M-35,-50 Q-20,-35 -35,-20 Q-20,-5 -35,10 Q-20,25 -35,40" stroke="', rSecondary, '" stroke-width="3" fill="none" opacity="0.7"', animClass, '/>',
            '<path d="M-30,-50 Q-15,-35 -30,-20 Q-15,-5 -30,10 Q-15,25 -30,40" stroke="', rPrimary, '" stroke-width="2" fill="none" opacity="0.5"/>',
            '<path d="M35,-50 Q20,-35 35,-20 Q20,-5 35,10 Q20,25 35,40" stroke="', rSecondary, '" stroke-width="3" fill="none" opacity="0.7"', animClass, '/>',
            '<path d="M30,-50 Q15,-35 30,-20 Q15,-5 30,10 Q15,25 30,40" stroke="', rPrimary, '" stroke-width="2" fill="none" opacity="0.5"/>',
            // Floating organelles
            '<circle cx="-30" cy="-25" r="8" fill="', rPrimary, '" opacity="0.6"', floatClass, '/>',
            '<circle cx="30" cy="-25" r="8" fill="', rPrimary, '" opacity="0.6"', floatClass, '/>',
            '<circle cx="-30" cy="25" r="8" fill="', rSecondary, '" opacity="0.6"', floatClass, '/>',
            '<circle cx="30" cy="25" r="8" fill="', rSecondary, '" opacity="0.6"', floatClass, '/>',
            // Mitochondria (small shapes)
            '<ellipse cx="-15" cy="-15" rx="6" ry="4" fill="', rPrimary, '" transform="rotate(-30 -15 -15)"', animClass, '/>',
            '<ellipse cx="15" cy="15" rx="6" ry="4" fill="', rPrimary, '" transform="rotate(30 15 15)"', animClass, '/>',
            '</g>'
        );
    }

    function _generateRareElementsIcon(Rarity rarity, string memory rPrimary, string memory rSecondary)
        private pure returns (string memory)
    {
        string memory animClass = rarity >= Rarity.Epic ? ' class="pulse"' : '';
        string memory rotateClass = rarity == Rarity.Legendary ? ' class="rotate"' : '';

        return string.concat(
            '<g transform="translate(150, 170)">',
            // Main hexagonal gem
            '<polygon points="0,-55 40,-28 40,28 0,55 -40,28 -40,-28" fill="#8A2BE2" stroke="', rPrimary, '" stroke-width="3" opacity="0.9"/>',
            '<polygon points="0,-45 32,-22 32,22 0,45 -32,22 -32,-22" fill="#9370DB"/>',
            '<polygon points="0,-30 20,-15 20,15 0,30 -20,15 -20,-15" fill="', rSecondary, '" opacity="0.8"/>',
            // Inner star
            '<polygon points="0,-20 5,-7 18,-7 8,2 12,15 0,8 -12,15 -8,2 -18,-7 -5,-7" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="0" cy="0" r="8" fill="#FFF" opacity="0.6"/>',
            // Orbiting particles
            '<g', rotateClass, '>',
            '<circle cx="50" cy="0" r="6" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="-50" cy="0" r="6" fill="', rSecondary, '"', animClass, '/>',
            '<circle cx="0" cy="50" r="5" fill="', rPrimary, '"', animClass, '/>',
            '<circle cx="0" cy="-50" r="5" fill="', rSecondary, '"', animClass, '/>',
            '</g>',
            // Smaller floating gems
            '<polygon points="-55,-35 -50,-45 -45,-35 -50,-25" fill="', rSecondary, '" opacity="0.7"', animClass, '/>',
            '<polygon points="55,-35 50,-45 45,-35 50,-25" fill="', rSecondary, '" opacity="0.7"', animClass, '/>',
            '<polygon points="-55,35 -50,45 -45,35 -50,25" fill="', rPrimary, '" opacity="0.7"', animClass, '/>',
            '<polygon points="55,35 50,45 45,35 50,25" fill="', rPrimary, '" opacity="0.7"', animClass, '/>',
            // Energy lines
            '<line x1="-40" y1="-28" x2="-55" y2="-40" stroke="', rPrimary, '" stroke-width="2" opacity="0.5"', animClass, '/>',
            '<line x1="40" y1="-28" x2="55" y2="-40" stroke="', rPrimary, '" stroke-width="2" opacity="0.5"', animClass, '/>',
            '</g>'
        );
    }

    function _generateParticles(Rarity rarity, string memory rPrimary, uint256 tokenId)
        private pure returns (string memory)
    {
        if (rarity < Rarity.Rare) return '';

        uint8 count = rarity == Rarity.Legendary ? 10 : rarity == Rarity.Epic ? 6 : 4;
        string memory particles = '';

        // Better distributed positions - no overlapping, within safe bounds
        uint16[10] memory xPositions = [uint16(25), 275, 20, 280, 22, 278, 25, 275, 30, 270];
        uint16[10] memory yPositions = [uint16(70), 75, 140, 145, 200, 195, 250, 255, 110, 180];
        uint8[10] memory sizes = [uint8(3), 3, 2, 2, 3, 2, 2, 3, 2, 2];

        for (uint8 i = 0; i < count; i++) {
            particles = string.concat(
                particles,
                '<circle cx="', uint256(xPositions[i]).toString(),
                '" cy="', uint256(yPositions[i]).toString(),
                '" r="', uint256(sizes[i]).toString(),
                '" fill="', rPrimary, '" opacity="0.4" class="pulse"/>'
            );
        }

        return string.concat('<g>', particles, '</g>');
    }

    function _generateCyborgChickenCarrier(ResourceTraits memory traits, string memory rPrimary)
        private pure returns (string memory)
    {
        (string memory c1, string memory c2, ) = _splitColors(_getTypeColorScheme(traits.resourceType));
        string memory chickenBorder = traits.rarity >= Rarity.Epic ? rPrimary : c1;

        return string.concat(
            // Left chicken carrier (scaled down, positioned better)
            '<g transform="translate(45, 355) scale(0.8)">',
            '<ellipse cx="0" cy="0" rx="14" ry="16" fill="', c2, '" stroke="', chickenBorder, '" stroke-width="1"/>',
            '<circle cx="0" cy="-18" r="10" fill="', c1, '" stroke="', chickenBorder, '" stroke-width="1"/>',
            '<circle cx="-3" cy="-19" r="3" fill="#000"/>',
            '<circle cx="-2" cy="-20" r="1" fill="#F00"/>',
            '<circle cx="3" cy="-19" r="3" fill="#000"/>',
            '<circle cx="4" cy="-20" r="1" fill="#F00"/>',
            '<polygon points="8,-18 12,-15 8,-12" fill="#FF9800"/>',
            '<rect x="-16" y="-8" width="32" height="20" fill="#2c3e50" rx="4" stroke="', rPrimary, '" stroke-width="1"/>',
            '<rect x="-12" y="-4" width="24" height="12" fill="', c1, '" rx="2" opacity="0.6"/>',
            '<path d="M-8,-26 Q0,-32 8,-26" fill="', rPrimary, '"/>',
            '</g>',
            // Right chicken carrier
            '<g transform="translate(255, 355) scale(0.8)">',
            '<ellipse cx="0" cy="0" rx="14" ry="16" fill="', c1, '" stroke="', chickenBorder, '" stroke-width="1"/>',
            '<circle cx="0" cy="-18" r="10" fill="', c2, '" stroke="', chickenBorder, '" stroke-width="1"/>',
            '<circle cx="-3" cy="-19" r="3" fill="#000"/>',
            '<circle cx="-2" cy="-20" r="1" fill="#0F0"/>',
            '<circle cx="3" cy="-19" r="3" fill="#000"/>',
            '<circle cx="4" cy="-20" r="1" fill="#0F0"/>',
            '<polygon points="-8,-18 -12,-15 -8,-12" fill="#FF9800"/>',
            '<rect x="-16" y="-8" width="32" height="20" fill="#2c3e50" rx="4" stroke="', rPrimary, '" stroke-width="1"/>',
            '<rect x="-12" y="-4" width="24" height="12" fill="', c2, '" rx="2" opacity="0.6"/>',
            '<path d="M-8,-26 Q0,-32 8,-26" fill="', rPrimary, '"/>',
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
            rarity == Rarity.Legendary ? ' class="shimmer"' : '',
            '>', symbol, '</text>'
        );
    }

    function _generateStackIndicator(uint16 stackSize, uint16 maxStack, string memory color)
        private pure returns (string memory)
    {
        if (stackSize <= 1) return '';

        string memory stackText = string.concat(
            uint256(stackSize).toString(), '/', uint256(maxStack).toString()
        );

        return string.concat(
            '<g transform="translate(250, 35)">',
            '<rect x="-30" y="-15" width="60" height="28" fill="rgba(0,0,0,0.7)" rx="8" stroke="', color, '" stroke-width="1"/>',
            '<text x="0" y="5" text-anchor="middle" fill="', color, '" font-size="14" font-weight="bold">', stackText, '</text>',
            '</g>'
        );
    }

    function _generateQualityStars(uint8 qualityLevel, string memory color)
        private pure returns (string memory)
    {
        string memory stars = '';
        uint8 level = qualityLevel > 5 ? 5 : qualityLevel;

        for (uint8 i = 0; i < level; i++) {
            stars = string.concat(
                stars,
                '<text x="', uint256(70 + i * 18).toString(),
                '" y="55" fill="', color, '" font-size="14">', unicode'★', '</text>'
            );
        }

        // Empty stars
        for (uint8 i = level; i < 5; i++) {
            stars = string.concat(
                stars,
                '<text x="', uint256(70 + i * 18).toString(),
                '" y="55" fill="#444" font-size="14">', unicode'☆', '</text>'
            );
        }

        return string.concat(
            '<text x="25" y="55" fill="#888" font-size="10">QUALITY</text>',
            stars
        );
    }

    function _generateStatsBadges(ResourceTraits memory traits, string memory rPrimary, string memory)
        private pure returns (string memory)
    {
        return string.concat(
            // Yield bonus badge (top right, semi-transparent, wider)
            '<g transform="translate(185, 25)">',
            '<rect x="0" y="0" width="95" height="24" fill="rgba(10,10,20,0.6)" rx="12" stroke="', rPrimary, '" stroke-width="1" stroke-opacity="0.7"/>',
            '<text x="48" y="16" text-anchor="middle" fill="', rPrimary, '" font-size="10" font-weight="bold">+',
            uint256(traits.yieldBonus).toString(), '% YIELD</text>',
            '</g>'
        );
    }

    function _generateTypeBadge(ResourceType rType, string memory typeColors)
        private pure returns (string memory)
    {
        (string memory c1, , ) = _splitColors(typeColors);
        string memory typeName = _getTypeName(rType);

        return string.concat(
            '<g transform="translate(150, 285)">',
            '<rect x="-60" y="-12" width="120" height="24" rx="12" fill="rgba(0,0,0,0.7)" stroke="', c1, '" stroke-width="1"/>',
            '<text x="0" y="5" text-anchor="middle" fill="', c1, '" font-size="11" font-weight="bold">', typeName, '</text>',
            '</g>',
            // HENOMORPHS branding at bottom
            '<text x="150" y="388" text-anchor="middle" fill="#444" font-size="9" letter-spacing="8" font-weight="300">HENOMORPHS</text>'
        );
    }

    function _getTypeName(ResourceType rType) private pure returns (string memory) {
        if (rType == ResourceType.BasicMaterials) return "BASIC MATERIALS";
        if (rType == ResourceType.EnergyCrystals) return "ENERGY CRYSTALS";
        if (rType == ResourceType.BioCompounds) return "BIO COMPOUNDS";
        return "RARE ELEMENTS";
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
