// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title TerritorySVGLib
 * @notice Library for generating Territory Card SVG graphics - Hendom Visual Style
 * @dev Based on HTML artifact "Hendom - Kompletny System Terytoriów NFT"
 * @author rutilicus.eth (ArchXS)
 * @custom:version 6.2.0
 * @custom:changelog Added rarity-based color schemes for borders, frames, and visual elements
 */
library TerritorySVGLib {
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
     * @notice Generate complete SVG for territory card
     */
    function generateSVG(uint256 tokenId, TerritoryTraits memory traits) 
        public pure returns (string memory) 
    {
        string memory colorScheme = _getColorScheme(traits.territoryType);
        string memory rarityColors = _getRarityColorScheme(traits.rarity);
        
        return string.concat(
            '<svg viewBox="0 0 300 300" xmlns="http://www.w3.org/2000/svg">',
            '<defs>', _generateGradients(colorScheme, rarityColors, tokenId), '</defs>',
            // Background with radial gradient
            '<rect width="300" height="300" fill="url(#grad-', tokenId.toString(), ')" rx="10"/>',
            // Rarity border frame
            _generateRarityFrame(traits.rarity, rarityColors),
            // Grid overlay
            _generateGrid(traits, rarityColors),
            // Main territory structure
            _generateTerritoryStructure(traits, rarityColors),
            // Cyborgiczne kurczaki w rogach
            _generateCyborgChickens(traits, rarityColors),
            // Rarity symbol (top-left corner)
            _generateRaritySymbol(traits.rarity, rarityColors),
            // Stats bars in corners
            _generateStatsBars(traits, rarityColors),
            '</svg>'
        );
    }

    function _getColorScheme(TerritoryType tType) private pure returns (string memory) {
        if (tType == TerritoryType.ZicoMine) return "#ffd700,#ff6b35,#00ff88";
        if (tType == TerritoryType.TradeHub) return "#3498db,#9b59b6,#00ff88";
        if (tType == TerritoryType.Fortress) return "#e74c3c,#7f8c8d,#ff6b35";
        if (tType == TerritoryType.Observatory) return "#9b59b6,#3498db,#00ff88";
        return "#27ae60,#2ecc71,#00ff88"; // Sanctuary
    }

    /**
     * @notice Get rarity-specific color scheme for accents and borders
     * @dev Returns: border color, accent color, glow color
     */
    function _getRarityColorScheme(Rarity rarity) private pure returns (string memory) {
        if (rarity == Rarity.Legendary) return "#f1c40f,#ffed4e,#ffd700"; // Gold
        if (rarity == Rarity.Epic) return "#9b59b6,#c39bd3,#8e44ad"; // Purple
        if (rarity == Rarity.Rare) return "#3498db,#5dade2,#2980b9"; // Blue
        if (rarity == Rarity.Uncommon) return "#2ecc71,#58d68d,#27ae60"; // Green
        return "#95a5a6,#bdc3c7,#7f8c8d"; // Gray (Common)
    }

    function _generateGradients(string memory colors, string memory rarityColors, uint256 tokenId) 
        private pure returns (string memory) 
    {
        (string memory c1, string memory c2, ) = _splitColors(colors);
        (string memory rBorder, string memory rAccent, string memory rGlow) = _splitColors(rarityColors);
        
        return string.concat(
            // Główny gradient tła
            '<radialGradient id="grad-', tokenId.toString(), '" cx="50%" cy="30%">',
            '<stop offset="0%" stop-color="', c1, '" stop-opacity="0.3"/>',
            '<stop offset="100%" stop-color="', c2, '" stop-opacity="0.1"/>',
            '</radialGradient>',
            // Gradient dla ramki rarity
            '<linearGradient id="rarity-grad-', tokenId.toString(), '" x1="0%" y1="0%" x2="100%" y2="100%">',
            '<stop offset="0%" stop-color="', rBorder, '"/>',
            '<stop offset="50%" stop-color="', rAccent, '"/>',
            '<stop offset="100%" stop-color="', rGlow, '"/>',
            '</linearGradient>',
            // Filtr świecenia dla rarity
            '<filter id="glow-', tokenId.toString(), '">',
            '<feGaussianBlur stdDeviation="4" result="coloredBlur"/>',
            '<feMerge><feMergeNode in="coloredBlur"/><feMergeNode in="SourceGraphic"/></feMerge>',
            '</filter>'
        );
    }

    /**
     * @notice Generate decorative border frame based on rarity
     */
    function _generateRarityFrame(Rarity rarity, string memory rarityColors) 
        private pure returns (string memory) 
    {
        (string memory rBorder, , string memory rGlow) = _splitColors(rarityColors);
        
        // Grubość i styl ramki zależny od rarity
        string memory strokeWidth;
        string memory opacity;
        
        if (rarity == Rarity.Legendary) {
            strokeWidth = "4";
            opacity = "1.0";
        } else if (rarity == Rarity.Epic) {
            strokeWidth = "3";
            opacity = "0.9";
        } else if (rarity == Rarity.Rare) {
            strokeWidth = "2.5";
            opacity = "0.8";
        } else if (rarity == Rarity.Uncommon) {
            strokeWidth = "2";
            opacity = "0.7";
        } else {
            strokeWidth = "1.5";
            opacity = "0.6";
        }
        
        return string.concat(
            '<rect x="5" y="5" width="290" height="290" rx="10" fill="none" ',
            'stroke="', rBorder, '" stroke-width="', strokeWidth, '" opacity="', opacity, '"/>',
            // Dodatkowa wewnętrzna ramka dla Legendary i Epic
            rarity == Rarity.Legendary || rarity == Rarity.Epic ? 
                string.concat(
                    '<rect x="8" y="8" width="284" height="284" rx="8" fill="none" ',
                    'stroke="', rGlow, '" stroke-width="1" opacity="0.5"/>'
                ) : ''
        );
    }

    function _generateGrid(TerritoryTraits memory traits, string memory rarityColors) 
        private pure returns (string memory) 
    {
        (, , string memory gridColor) = _splitColors(_getColorScheme(traits.territoryType));
        (string memory rBorder, , ) = _splitColors(rarityColors);
        
        // Dla wyższych rarity używamy koloru ramki w gridzie
        string memory finalGridColor = traits.rarity == Rarity.Legendary || traits.rarity == Rarity.Epic ? 
            rBorder : gridColor;
        
        string memory lines = '';
        for (uint256 i = 0; i <= 300; i += 20) {
            lines = string.concat(
                lines,
                '<line x1="', i.toString(), '" y1="0" x2="', i.toString(), '" y2="300" ',
                'stroke="', finalGridColor, '" stroke-width="0.5" opacity="0.2"/>',
                '<line x1="0" y1="', i.toString(), '" x2="300" y2="', i.toString(), '" ',
                'stroke="', finalGridColor, '" stroke-width="0.5" opacity="0.2"/>'
            );
        }
        
        return string.concat('<g>', lines, '</g>');
    }

    function _generateTerritoryStructure(TerritoryTraits memory traits, string memory rarityColors) 
        private pure returns (string memory) 
    {
        if (traits.territoryType == TerritoryType.ZicoMine) return _generateMineStructure(traits, rarityColors);
        if (traits.territoryType == TerritoryType.TradeHub) return _generateTradeHubStructure(traits, rarityColors);
        if (traits.territoryType == TerritoryType.Fortress) return _generateFortressStructure(traits, rarityColors);
        if (traits.territoryType == TerritoryType.Observatory) return _generateObservatoryStructure(traits, rarityColors);
        return _generateSanctuaryStructure(traits, rarityColors);
    }

    /**
     * @notice Mine: Mountain with 3 mining towers and crystals
     */
    function _generateMineStructure(TerritoryTraits memory traits, string memory rarityColors) 
        private pure returns (string memory) 
    {
        (string memory c1, , string memory c3) = _splitColors(_getColorScheme(traits.territoryType));
        (string memory rBorder, string memory rAccent, ) = _splitColors(rarityColors);
        
        // Dla wyższych rarity dodajemy akcenty kolorem rarity
        string memory accentColor = traits.rarity >= Rarity.Rare ? rAccent : c3;
        string memory borderAccent = traits.rarity >= Rarity.Epic ? rBorder : c3;
        
        return string.concat(
            '<g>',
            // Mountain base z ramką rarity
            '<path d="M80 220 Q150 120 220 220 Z" fill="#2c3e50" stroke="', borderAccent, '" stroke-width="2"/>',
            // Mining towers (3 vertical structures)
            '<rect x="120" y="100" width="4" height="60" fill="', c1, '"/>',
            '<rect x="150" y="100" width="4" height="60" fill="', c1, '"/>',
            '<rect x="180" y="100" width="4" height="60" fill="', c1, '"/>',
            // Energy cores on towers - kolor rarity
            '<circle cx="122" cy="95" r="3" fill="', accentColor, '"/>',
            '<circle cx="152" cy="95" r="3" fill="', accentColor, '"/>',
            '<circle cx="182" cy="95" r="3" fill="', accentColor, '"/>',
            // Crystals at base - tylko kolor się zmienia, kształt ten sam
            '<polygon points="130,200 134,192 138,200 134,208" fill="', traits.rarity >= Rarity.Epic ? rAccent : c1, '"/>',
            '<polygon points="145,200 149,192 153,200 149,208" fill="', traits.rarity >= Rarity.Epic ? rAccent : c1, '"/>',
            '<polygon points="160,200 164,192 168,200 164,208" fill="', traits.rarity >= Rarity.Epic ? rAccent : c1, '"/>',
            '<polygon points="175,200 179,192 183,200 179,208" fill="', traits.rarity >= Rarity.Epic ? rAccent : c1, '"/>',
            '</g>'
        );
    }

    /**
     * @notice Trade Hub: Central building with 4 bio-tech domes
     */
    function _generateTradeHubStructure(TerritoryTraits memory traits, string memory rarityColors) 
        private pure returns (string memory) 
    {
        (string memory c1, string memory c2, string memory c3) = _splitColors(_getColorScheme(traits.territoryType));
        (string memory rBorder, string memory rAccent, ) = _splitColors(rarityColors);
        
        string memory connectionColor = traits.rarity >= Rarity.Rare ? rAccent : c3;
        string memory borderColor = traits.rarity >= Rarity.Epic ? rBorder : c3;
        
        return string.concat(
            '<g>',
            // Central building
            '<rect x="120" y="120" width="60" height="60" rx="5" fill="', c1, '" stroke="', borderColor, '" stroke-width="2"/>',
            // 4 Bio-tech domes with connections
            // Top
            '<line x1="150" y1="150" x2="150" y2="100" stroke="', connectionColor, '" stroke-width="2" opacity="0.6"/>',
            '<circle cx="150" cy="100" r="12" fill="', c2, '" stroke="', connectionColor, '"/>',
            // Right  
            '<line x1="150" y1="150" x2="200" y2="150" stroke="', connectionColor, '" stroke-width="2" opacity="0.6"/>',
            '<circle cx="200" cy="150" r="12" fill="', c2, '" stroke="', connectionColor, '"/>',
            // Bottom
            '<line x1="150" y1="150" x2="150" y2="200" stroke="', connectionColor, '" stroke-width="2" opacity="0.6"/>',
            '<circle cx="150" cy="200" r="12" fill="', c2, '" stroke="', connectionColor, '"/>',
            // Left
            '<line x1="150" y1="150" x2="100" y2="150" stroke="', connectionColor, '" stroke-width="2" opacity="0.6"/>',
            '<circle cx="100" cy="150" r="12" fill="', c2, '" stroke="', connectionColor, '"/>',
            '</g>'
        );
    }

    /**
     * @notice Fortress: Main structure with 3 defense towers
     */
    function _generateFortressStructure(TerritoryTraits memory traits, string memory rarityColors) 
        private pure returns (string memory) 
    {
        (string memory c1, string memory c2, string memory c3) = _splitColors(_getColorScheme(traits.territoryType));
        (string memory rBorder, string memory rAccent, ) = _splitColors(rarityColors);
        
        string memory towerColor = traits.rarity >= Rarity.Rare ? rAccent : c1;
        string memory borderColor = traits.rarity >= Rarity.Epic ? rBorder : c1;
        
        return string.concat(
            '<g>',
            // Main fortress body
            '<rect x="120" y="140" width="60" height="50" fill="', c3, '" stroke="', borderColor, '" stroke-width="2"/>',
            // Tower 1 (left)
            '<rect x="110" y="130" width="12" height="30" fill="', c2, '" stroke="', borderColor, '"/>',
            '<circle cx="116" cy="127" r="4" fill="', towerColor, '"/>',
            // Tower 2 (center)
            '<rect x="150" y="120" width="12" height="30" fill="', c2, '" stroke="', borderColor, '"/>',
            '<circle cx="156" cy="117" r="4" fill="', towerColor, '"/>',
            // Tower 3 (right)
            '<rect x="190" y="130" width="12" height="30" fill="', c2, '" stroke="', borderColor, '"/>',
            '<circle cx="196" cy="127" r="4" fill="', towerColor, '"/>',
            '</g>'
        );
    }

    /**
     * @notice Observatory: Dome structure with telescope and star field
     */
    function _generateObservatoryStructure(TerritoryTraits memory traits, string memory rarityColors) 
        private pure returns (string memory) 
    {
        (string memory c1, string memory c2, string memory c3) = _splitColors(_getColorScheme(traits.territoryType));
        (string memory rBorder, string memory rAccent, ) = _splitColors(rarityColors);
        
        string memory accentColor = traits.rarity >= Rarity.Rare ? rAccent : c2;
        string memory borderColor = traits.rarity >= Rarity.Epic ? rBorder : c3;
        
        return string.concat(
            '<g>',
            // Base platform
            '<rect x="90" y="180" width="120" height="15" rx="5" fill="', c1, '" stroke="', borderColor, '" stroke-width="2"/>',
            // Main dome
            '<ellipse cx="150" cy="160" rx="50" ry="55" fill="', c1, '" stroke="', borderColor, '" stroke-width="2"/>',
            '<ellipse cx="150" cy="160" rx="45" ry="50" fill="', c2, '" opacity="0.9"/>',
            // Viewing slit
            '<rect x="145" y="120" width="10" height="50" rx="5" fill="', borderColor, '"/>',
            // Top antenna
            '<line x1="150" y1="105" x2="150" y2="75" stroke="', accentColor, '" stroke-width="4"/>',
            '<circle cx="150" cy="75" r="8" fill="', accentColor, '"/>',
            '<circle cx="150" cy="75" r="5" fill="#FFF"/>',
            // Star field
            '<circle cx="80" cy="110" r="2" fill="white" opacity="0.9"/>',
            '<circle cx="225" cy="120" r="2" fill="white" opacity="0.8"/>',
            '<circle cx="90" cy="210" r="2" fill="white" opacity="0.7"/>',
            '<circle cx="220" cy="200" r="2" fill="white" opacity="0.9"/>',
            '</g>'
        );
    }

    /**
     * @notice Sanctuary: Organic healing structure with growth tendrils
     */
    function _generateSanctuaryStructure(TerritoryTraits memory traits, string memory rarityColors) 
        private pure returns (string memory) 
    {
        (string memory c1, string memory c2, string memory c3) = _splitColors(_getColorScheme(traits.territoryType));
        (string memory rBorder, string memory rAccent, ) = _splitColors(rarityColors);
        
        string memory coreColor = traits.rarity >= Rarity.Rare ? rAccent : c3;
        string memory borderColor = traits.rarity >= Rarity.Epic ? rBorder : c3;
        
        return string.concat(
            '<g>',
            // Base platform
            '<ellipse cx="150" cy="200" rx="70" ry="15" fill="', c1, '" stroke="', borderColor, '" stroke-width="2"/>',
            // Main organic structure
            '<path d="M110 130 Q110 90 150 100 Q190 90 190 130 Q190 170 150 190 Q110 170 110 130 Z" ',
            'fill="', c1, '" stroke="', borderColor, '" stroke-width="2"/>',
            '<path d="M115 130 Q115 95 150 105 Q185 95 185 130 Q185 165 150 185 Q115 165 115 130 Z" ',
            'fill="', c2, '" opacity="0.9"/>',
            // Healing core
            '<circle cx="150" cy="150" r="25" fill="', c2, '" opacity="0.7"/>',
            '<circle cx="150" cy="150" r="15" fill="', coreColor, '" opacity="0.8"/>',
            '<circle cx="150" cy="150" r="8" fill="#FFF"/>',
            // Growth tendrils
            '<path d="M120 135 Q100 120 90 130" stroke="', c2, '" stroke-width="4" fill="none" opacity="0.8"/>',
            '<path d="M180 135 Q200 120 210 130" stroke="', c2, '" stroke-width="4" fill="none" opacity="0.8"/>',
            '<path d="M125 165 Q105 185 100 200" stroke="', c2, '" stroke-width="4" fill="none" opacity="0.8"/>',
            '<path d="M175 165 Q195 185 200 200" stroke="', c2, '" stroke-width="4" fill="none" opacity="0.8"/>',
            // Leaf nodes - dla wysokiego rarity świecące
            '<circle cx="90" cy="130" r="8" fill="', coreColor, '" opacity="0.9"/>',
            '<circle cx="210" cy="130" r="8" fill="', coreColor, '" opacity="0.9"/>',
            '<circle cx="100" cy="200" r="8" fill="', coreColor, '" opacity="0.9"/>',
            '<circle cx="200" cy="200" r="8" fill="', coreColor, '" opacity="0.9"/>',
            '</g>'
        );
    }

    /**
     * @notice Generate 4 small cyborg chickens in corners
     */
    function _generateCyborgChickens(TerritoryTraits memory traits, string memory rarityColors) 
        private pure returns (string memory) 
    {
        (string memory c1, string memory c2, string memory c3) = _splitColors(_getColorScheme(traits.territoryType));
        (string memory rBorder, , ) = _splitColors(rarityColors);
        
        string memory chickenBorder = traits.rarity >= Rarity.Epic ? rBorder : c3;
        
        return string.concat(
            '<g>',
            // Bottom-left chicken
            '<ellipse cx="70" cy="240" rx="6" ry="8" fill="', c1, '" stroke="', chickenBorder, '" stroke-width="0.5"/>',
            '<circle cx="70" cy="230" r="4" fill="', c2, '" stroke="', chickenBorder, '" stroke-width="0.5"/>',
            '<circle cx="71" cy="229" r="1" fill="#ff0000"/>',
            // Bottom-right chicken
            '<ellipse cx="230" cy="240" rx="6" ry="8" fill="', c2, '" stroke="', chickenBorder, '" stroke-width="0.5"/>',
            '<circle cx="230" cy="230" r="4" fill="', c1, '" stroke="', chickenBorder, '" stroke-width="0.5"/>',
            '<circle cx="231" cy="229" r="1" fill="#ff0000"/>',
            '</g>'
        );
    }

    function _generateRaritySymbol(Rarity rarity, string memory rarityColors) 
        private pure returns (string memory) 
    {
        string memory symbol;
        (string memory color, , ) = _splitColors(rarityColors);
        
        if (rarity == Rarity.Legendary) {
            symbol = unicode"♦";
        } else if (rarity == Rarity.Epic) {
            symbol = unicode"★";
        } else if (rarity == Rarity.Rare) {
            symbol = unicode"■";
        } else if (rarity == Rarity.Uncommon) {
            symbol = unicode"▲";
        } else {
            symbol = unicode"●";
        }
        
        return string.concat(
            '<text x="25" y="35" text-anchor="middle" fill="', color, 
            '" font-size="20" font-weight="900">', symbol, '</text>'
        );
    }

    /**
     * @notice Generate 4 stat bars in corners with icons and values
     */
    function _generateStatsBars(TerritoryTraits memory traits, string memory rarityColors) 
        private pure returns (string memory) 
    {
        (string memory rBorder, , ) = _splitColors(rarityColors);
        
        // Calculate defense and strategic values
        uint256 defenseNumeric = traits.rarity == Rarity.Legendary ? 75 : 
                                 traits.rarity == Rarity.Epic ? 50 : 25;
        uint256 strategicNumeric = traits.productionBonus > 20 ? 80 : 
                                  traits.productionBonus > 15 ? 60 : 40;
        
        return string.concat(
            // Top-left: Production bonus (💰)
            _generateStatBar(50, 40, 60, uint256(traits.productionBonus) * 3, 
                            '#ffd700', unicode'💰', string.concat('+', uint256(traits.productionBonus).toString(), '%')),
            // Top-right: Maintenance cost (⚡)
            _generateStatBar(190, 40, 60, uint256(traits.defenseBonus) * 2, 
                            '#e74c3c', unicode'⚡', uint256(traits.defenseBonus).toString()),
            // Bottom-left: Defense (🛡️) - kolor rarity dla wysokich wartości
            _generateStatBar(50, 260, 60, defenseNumeric, 
                            traits.rarity >= Rarity.Rare ? rBorder : '#3498db', unicode'🛡️', 'D'),
            // Bottom-right: Strategic value (⭐)
            _generateStatBar(190, 260, 60, strategicNumeric, 
                            '#9b59b6', unicode'⭐', 'W')
        );
    }

    function _generateStatBar(
        uint256 x, 
        uint256 y, 
        uint256 width, 
        uint256 value,
        string memory color,
        string memory icon,
        string memory text
    ) private pure returns (string memory) {
        uint256 filledWidth = (width * value) / 100;
        if (filledWidth > width) filledWidth = width;
        
        return string.concat(
            // Background bar
            '<rect x="', x.toString(), '" y="', y.toString(), '" width="', width.toString(), 
            '" height="4" rx="2" fill="rgba(0,0,0,0.6)" stroke="rgba(255,255,255,0.3)" stroke-width="0.5"/>',
            // Filled bar
            '<rect x="', x.toString(), '" y="', y.toString(), '" width="', filledWidth.toString(), 
            '" height="4" rx="2" fill="', color, '"/>',
            // Icon
            '<text x="', (x - 12).toString(), '" y="', (y + 3).toString(), '" font-size="8">', icon, '</text>',
            // Value text
            '<text x="', (x + width + 5).toString(), '" y="', (y + 3).toString(), 
            '" fill="', color, '" font-size="8" font-weight="700">', text, '</text>'
        );
    }

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
}
