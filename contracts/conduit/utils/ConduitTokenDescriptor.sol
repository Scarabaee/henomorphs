// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "../interfaces/IConduitTokenDescriptor.sol";

/// @title ConduitTokenDescriptor
/// @notice Generates complete on-chain metadata and SVG for Henomorphs Conduit tokens
/// @dev Implements OpenSea-compatible metadata with dynamic SVG generation
contract ConduitTokenDescriptor is IConduitTokenDescriptor {
    using Strings for uint256;
    using Strings for uint8;

    string private constant COLLECTION_DESCRIPTION = 
        "Entry to the Henomorphs Ecosystem. This conduit token provides access to redeem other tokens in the ecosystem based on the number of Cores it contains. Cores can be redeemed through authorized contracts until the token expiry date.";

    string private constant COLLECTION_NAME = "Henomorphs Conduit";
    string private constant COLLECTION_SYMBOL = "HYCON";
    string private constant COLLECTION_EXTERNAL_URL = "https://henomorphs.zico.network";
    
    // Hex symbols for color generation
    bytes16 private constant HEX_SYMBOLS = "0123456789abcdef";

    /// @notice Generate complete token URI with JSON metadata and embedded SVG
    /// @param metadata Token metadata structure
    /// @return uri Data URI containing complete OpenSea-compatible metadata
    function tokenURI(TokenMetadata memory metadata) 
        external 
        view 
        override 
        returns (string memory uri) 
    {
        string memory svg = generateSVG(metadata);
        string memory json = _buildJSON(metadata, svg);
        
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        );
    }

    /// @notice Generate collection-level metadata URI (OpenSea contractURI)
    /// @return uri Data URI containing collection metadata
    function contractURI() external pure returns (string memory) {
        string memory json = string.concat(
            '{',
            '"name": "', COLLECTION_NAME, '",',
            '"description": "', COLLECTION_DESCRIPTION, '",',
            '"image": "', _getCollectionImage(), '",',
            '"external_link": "', COLLECTION_EXTERNAL_URL, '",',
            '"seller_fee_basis_points": 500,',
            '"fee_recipient": "0x8B4F045d8127E587E3083baBB31D4bC35f0065Cc"',
            '}'
        );
        
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        );
    }

    /// @notice Generate complete SVG image based on token metadata
    /// @param metadata Token metadata structure
    /// @return svg Complete SVG as string
    function generateSVG(TokenMetadata memory metadata) 
        public 
        pure 
        override 
        returns (string memory svg) 
    {
        return string.concat(
            '<svg viewBox="0 0 300 300" xmlns="http://www.w3.org/2000/svg">',
            _generateDefs(metadata.tokenId, metadata.coreCount),
            _generateBackground(),
            _generateAnimatedBorderText(),
            _generateTokenInfoBoxes(metadata),
            _generateCoresDisplay(metadata.coreCount),
            _generateChickenCharacter(metadata.tokenId, metadata.coreCount),
            _generateTechElements(metadata.tokenId, metadata.coreCount),
            _generateLegsAndFeet(),
            _generateHexagons(metadata.tokenId, metadata.coreCount),
            metadata.ownerBalance > 1 ? _generateBalanceBadge(metadata.ownerBalance) : "",
            '</svg>'
        );
    }

    /// @notice Generate SVG defs with gradients and paths based on tokenId
    /// @param tokenId Token ID for unique styling
    /// @param coreCount Core count affecting colors
    /// @return defs SVG definitions section
    function _generateDefs(uint256 tokenId, uint8 coreCount) internal pure returns (string memory) {
        (string memory bg1, string memory bg2, string memory bg3) = _generateYellowGradient(tokenId);
        string memory goggleColor = _generateGoggleColor(tokenId);
        string memory accentColor = _generateAccentColor(tokenId, coreCount);
        
        return string.concat(
            '<defs>',
            '<radialGradient id="bgGradient" cx="50%" cy="40%" r="60%">',
            '<stop offset="0%" style="stop-color:', bg1, ';stop-opacity:1" />',
            '<stop offset="50%" style="stop-color:', bg2, ';stop-opacity:1" />',
            '<stop offset="100%" style="stop-color:', bg3, ';stop-opacity:1" />',
            '</radialGradient>',
            '<radialGradient id="chickGradient" cx="50%" cy="40%" r="60%">',
            '<stop offset="0%" style="stop-color:#ffeb3b;stop-opacity:1" />',
            '<stop offset="80%" style="stop-color:#ffc107;stop-opacity:1" />',
            '<stop offset="100%" style="stop-color:#ff8f00;stop-opacity:1" />',
            '</radialGradient>',
            '<radialGradient id="glassGradient" cx="50%" cy="30%" r="70%">',
            '<stop offset="0%" style="stop-color:', goggleColor, ';stop-opacity:0.8" />',
            '<stop offset="100%" style="stop-color:', accentColor, ';stop-opacity:0.9" />',
            '</radialGradient>',
            '<path id="textPath" d="M 27,15 L 273,15 Q 285,15 285,27 L 285,273 Q 285,285 273,285 L 27,285 Q 15,285 15,273 L 15,27 Q 15,15 27,15 Z"/>',
            '</defs>'
        );
    }

    /// @notice Generate background elements
    /// @return background SVG background
    function _generateBackground() internal pure returns (string memory) {
        return string.concat(
            '<rect x="0" y="0" width="300" height="300" fill="url(#bgGradient)"/>',
            '<rect x="20" y="20" width="260" height="260" rx="15" ry="15" fill="none" stroke="#CD853F" stroke-width="4"/>',
            '<rect x="24" y="24" width="252" height="252" rx="11" ry="11" fill="url(#bgGradient)"/>'
        );
    }

    /// @notice Generate animated border text
    /// @return text Animated text elements
    function _generateAnimatedBorderText() internal pure returns (string memory) {
        return string.concat(
            '<text text-rendering="optimizeSpeed">',
            '<textPath startOffset="-100%" fill="#B8860B" font-family="Arial, sans-serif" font-size="14" font-weight="900" href="#textPath">',
            unicode'•',
            ' YELLOW CONDUIT ',
            unicode'•',
            ' ENTRY TO THE HENOMORPHS ECOSYSTEM ',
            unicode'•',
            '<animate additive="sum" attributeName="startOffset" from="0%" to="100%" begin="0s" dur="25s" repeatCount="indefinite" />',
            '</textPath>',
            '<textPath startOffset="0%" fill="#B8860B" font-family="Arial, sans-serif" font-size="14" font-weight="900" href="#textPath">',
            unicode'•',
            ' YELLOW CONDUIT ',
            unicode'•',
            ' ENTRY TO THE HENOMORPHS ECOSYSTEM ',
            unicode'•',
            '<animate additive="sum" attributeName="startOffset" from="0%" to="100%" begin="0s" dur="25s" repeatCount="indefinite" />',
            '</textPath>',
            '</text>'
        );
    }

    /// @notice Generate info boxes with token data
    /// @param metadata Token metadata
    /// @return boxes Info box elements
    function _generateTokenInfoBoxes(TokenMetadata memory metadata) internal pure returns (string memory) {
        string memory dateStr = _formatExpiryDate(metadata.expiryDate);
        string memory tokenIdStr = _padTokenId(metadata.tokenId);
        
        // Calculate background width based on token ID length
        uint256 tokenBoxWidth = 80 + (bytes(tokenIdStr).length * 8);
        uint256 coresBoxWidth = 52 + (metadata.coreCount > 12 ? 12 : metadata.coreCount) * 11;
        
        return string.concat(
            // Background boxes
            '<rect x="32" y="28" width="', tokenBoxWidth.toString(), '" height="18" rx="4" ry="4" fill="#2E2E2E" fill-opacity="0.8"/>',
            '<rect x="32" y="50" width="', coresBoxWidth.toString(), '" height="18" rx="4" ry="4" fill="#2E2E2E" fill-opacity="0.8"/>',
            '<rect x="32" y="255" width="135" height="18" rx="4" ry="4" fill="#2E2E2E" fill-opacity="0.8"/>',
            // Text content - only token number without prefix
            '<text x="36" y="40" font-family="Courier New, monospace" font-size="12" font-weight="bold" fill="#999999">Token ID: </text>',
            '<text x="102" y="40" font-family="Courier New, monospace" font-size="12" font-weight="bold" fill="#FFFFFF">#', tokenIdStr, '</text>',
            '<text x="36" y="62" font-family="Courier New, monospace" font-size="12" font-weight="bold" fill="#999999">Cores:</text>',
            '<text x="36" y="267" font-family="Courier New, monospace" font-size="12" font-weight="bold" fill="#999999">Expiry: </text>',
            '<text x="86" y="267" font-family="Courier New, monospace" font-size="12" font-weight="bold" fill="#FFFFFF">', dateStr, '</text>'
        );
    }

    /// @notice Generate cores display as yellow eggs
    /// @param coreCount Number of cores to display
    /// @return cores Visual core representation
    function _generateCoresDisplay(uint8 coreCount) internal pure returns (string memory) {
        string memory cores = "";
        uint256 maxCores = coreCount > 12 ? 12 : coreCount;
        
        for (uint256 i = 0; i < maxCores; i++) {
            uint256 x = 85 + i * 11;
            cores = string.concat(
                cores,
                '<ellipse cx="', x.toString(), '" cy="59" rx="4" ry="5" fill="#ffeb3b"/>'
            );
        }
        
        return cores;
    }

    /// @notice Generate the main chicken character with dynamic colors
    /// @param tokenId Token ID for unique styling variations
    /// @param coreCount Number of cores affecting colors
    /// @return character Complete chicken character elements
    function _generateChickenCharacter(uint256 tokenId, uint8 coreCount) internal pure returns (string memory) {
        string memory goggleColor = _generateGoggleColor(tokenId);
        
        return string.concat(
            // Body and head
            '<ellipse cx="150" cy="180" rx="45" ry="50" fill="url(#chickGradient)"/>',
            '<circle cx="150" cy="120" r="40" fill="url(#chickGradient)"/>',
            // Dynamic feathers based on core count
            _generateFeathers(coreCount),
            // Anime-style eyes
            '<ellipse cx="135" cy="115" rx="8" ry="12" fill="#000"/>',
            '<ellipse cx="165" cy="115" rx="8" ry="12" fill="#000"/>',
            // Eye reflections
            '<circle cx="137" cy="110" r="3" fill="#fff"/>',
            '<circle cx="167" cy="110" r="3" fill="#fff"/>',
            '<circle cx="133" cy="113" r="1.5" fill="#fff"/>',
            '<circle cx="163" cy="113" r="1.5" fill="#fff"/>',
            // Dynamic tech goggles
            '<circle cx="135" cy="115" rx="18" ry="15" fill="none" stroke="', goggleColor, '" stroke-width="3"/>',
            '<circle cx="165" cy="115" rx="18" ry="15" fill="none" stroke="', goggleColor, '" stroke-width="3"/>',
            '<ellipse cx="135" cy="115" rx="15" ry="12" fill="url(#glassGradient)"/>',
            '<ellipse cx="165" cy="115" rx="15" ry="12" fill="url(#glassGradient)"/>',
            '<rect x="147" y="110" width="6" height="4" fill="', goggleColor, '"/>',
            // Beak and wings
            '<polygon points="150,125 145,135 155,135" fill="#ff9800"/>',
            '<ellipse cx="115" cy="180" rx="18" ry="10" fill="url(#chickGradient)" transform="rotate(-15 115 180)"/>',
            '<ellipse cx="185" cy="180" rx="18" ry="10" fill="url(#chickGradient)" transform="rotate(15 185 180)"/>'
        );
    }

    /// @notice Generate dynamic feathers based on core count
    /// @param coreCount Number of cores affecting feather style
    /// @return feathers Feather elements
    function _generateFeathers(uint8 coreCount) internal pure returns (string memory) {
        if (coreCount >= 10) {
            // More elaborate feathers for high core count
            return string.concat(
                '<circle cx="135" cy="85" r="14" fill="#ffeb3b"/>',
                '<circle cx="150" cy="80" r="18" fill="#ffeb3b"/>',
                '<circle cx="165" cy="85" r="14" fill="#ffeb3b"/>',
                '<circle cx="142" cy="75" r="10" fill="#ffc107"/>',
                '<circle cx="158" cy="75" r="10" fill="#ffc107"/>'
            );
        } else if (coreCount >= 5) {
            // Medium feathers
            return string.concat(
                '<circle cx="140" cy="90" r="12" fill="#ffeb3b"/>',
                '<circle cx="150" cy="85" r="15" fill="#ffeb3b"/>',
                '<circle cx="160" cy="90" r="12" fill="#ffeb3b"/>'
            );
        } else {
            // Simple feathers for low core count
            return string.concat(
                '<circle cx="145" cy="95" r="8" fill="#ffeb3b"/>',
                '<circle cx="155" cy="95" r="8" fill="#ffeb3b"/>'
            );
        }
    }

    /// @notice Generate tech elements with dynamic LED colors
    /// @param tokenId Token ID for variations
    /// @param coreCount Number of cores affecting LED intensity
    /// @return tech Tech suit elements
    function _generateTechElements(uint256 tokenId, uint8 coreCount) internal pure returns (string memory) {
        string memory ledColor1 = _generateLEDColor(tokenId, 1, coreCount);
        string memory ledColor2 = _generateLEDColor(tokenId, 2, coreCount);
        string memory ledColor3 = _generateLEDColor(tokenId, 3, coreCount);
        
        string memory vestWidth = coreCount >= 8 ? "70" : "60";
        string memory vestX = coreCount >= 8 ? "115" : "120";
        
        return string.concat(
            // Tech vest (size varies with core count)
            '<rect x="', vestX, '" y="165" width="', vestWidth, '" height="50" rx="8" ry="8" fill="#263238"/>',
            // Dynamic LED displays
            '<rect x="125" y="170" width="15" height="8" fill="', ledColor1, '"/>',
            '<rect x="160" y="170" width="15" height="8" fill="', ledColor1, '"/>',
            // LED strips (more for higher core count)
            '<rect x="125" y="190" width="50" height="4" fill="', ledColor2, '"/>',
            '<rect x="125" y="200" width="30" height="4" fill="', ledColor3, '"/>',
            coreCount >= 10 ? string.concat('<rect x="125" y="210" width="40" height="4" fill="', ledColor1, '"/>') : "",
            // Status indicators
            '<circle cx="140" cy="180" r="3" fill="#ff5722"/>',
            '<circle cx="160" cy="180" r="3" fill="#ff5722"/>'
        );
    }

    /// @notice Generate legs and feet
    /// @return legs Leg and foot elements
    function _generateLegsAndFeet() internal pure returns (string memory) {
        return string.concat(
            // Legs
            '<rect x="135" y="225" width="8" height="20" fill="#ff9800"/>',
            '<rect x="157" y="225" width="8" height="20" fill="#ff9800"/>',
            // Feet
            '<ellipse cx="139" cy="248" rx="6" ry="4" fill="#ff9800"/>',
            '<ellipse cx="161" cy="248" rx="6" ry="4" fill="#ff9800"/>'
        );
    }

    /// @notice Generate decorative hexagons with safe positioning and rare fill
    /// @param tokenId Token ID for rarity calculation
    /// @param coreCount Number of cores affecting rarity and colors
    /// @return hexagons Hexagon elements with safe positioning
    function _generateHexagons(uint256 tokenId, uint8 coreCount) internal pure returns (string memory) {
        string memory rarityTrait = _getRarityTrait(tokenId, coreCount);
        bool isRare = _isRareToken(tokenId, coreCount);
        
        string memory color1;
        string memory color2; 
        string memory color3;
        string memory opacity;
        
        if (isRare) {
            // Rare tokens get vibrant colors
            bytes32 rareHash1 = keccak256(abi.encodePacked(tokenId, "rare_hex_1"));
            bytes32 rareHash2 = keccak256(abi.encodePacked(tokenId, "rare_hex_2"));
            bytes32 rareHash3 = keccak256(abi.encodePacked(tokenId, "rare_hex_3"));
            
            string[8] memory rareColors = [
                "#ff6b6b", "#4ecdc4", "#45b7d1", "#f9ca24", "#6c5ce7", "#a0e7e5", "#ffeaa7", "#fd79a8"
            ];
            
            color1 = rareColors[uint256(rareHash1) % 8];
            color2 = rareColors[uint256(rareHash2) % 8]; 
            color3 = rareColors[uint256(rareHash3) % 8];
            opacity = "0.9";
        } else {
            // Common tokens get standard variants
            bytes32 commonHash = keccak256(abi.encodePacked(tokenId, "common_hex", coreCount));
            uint256 variant = uint256(commonHash) % 3;
            
            if (variant == 0) {
                color1 = color2 = color3 = "#ffc107";
            } else if (variant == 1) {
                color1 = color2 = color3 = "#ff9800";
            } else {
                color1 = color2 = color3 = "#ffb74d";
            }
            opacity = "0.6";
        }
        
        // Safe positioning - avoiding chicken and text areas
        uint256 seed = tokenId % 1000;
        
        // Hex1: Top area - przesunięty na lewo aby uniknąć kolizji z "Cores:"
        uint256 hex1X = 220 + (seed % 15);           // 180-195 (przesunięte z 200-220)
        uint256 hex1Y = 45 + ((seed >> 8) % 15);     // 45-60 (między tekstami)
        
        // Hex2: Far right middle - away from chicken  
        uint256 hex2X = 240 + ((seed >> 16) % 30);   // 240-270 (far from chicken)
        uint256 hex2Y = 100 + ((seed >> 24) % 25);   // 100-125 (safe zone)
        
        // Hex3: Right bottom - below chicken
        uint256 hex3X = 210 + ((seed >> 32) % 25);   // 210-235 (beside chicken)
        uint256 hex3Y = 200 + ((seed >> 40) % 25);   // 200-225 (below chicken, above expiry text)
        
        // Determine which hexagons to fill based on rarity
        bool fillFirst = false;
        bool fillSecond = false;
        bool fillThird = false;
        
        // Compare strings using keccak256 hash comparison
        bytes32 legendaryHash = keccak256(bytes("Legendary"));
        bytes32 epicHash = keccak256(bytes("Epic"));
        bytes32 rareHash = keccak256(bytes("Rare"));
        bytes32 currentRarityHash = keccak256(bytes(rarityTrait));
        
        if (currentRarityHash == legendaryHash) {
            // Legendary: wszystkie 3 hexagony wypełnione
            fillFirst = true;
            fillSecond = true;
            fillThird = true;
        } else if (currentRarityHash == epicHash) {
            // Epic: 2 losowo wybrane hexagony wypełnione
            uint256 epicSeed = uint256(keccak256(abi.encodePacked(tokenId, "epic_fill"))) % 3;
            if (epicSeed == 0) {
                fillFirst = true;
                fillSecond = true;
            } else if (epicSeed == 1) {
                fillFirst = true;
                fillThird = true;
            } else {
                fillSecond = true;
                fillThird = true;
            }
        } else if (currentRarityHash == rareHash) {
            // Rare: 1 losowo wybrany hexagon wypełniony
            uint256 rareSeed = seed % 3;
            if (rareSeed == 0) {
                fillFirst = true;
            } else if (rareSeed == 1) {
                fillSecond = true;
            } else {
                fillThird = true;
            }
        }
        // Common: żaden nie wypełniony (domyślnie false)
        
        return string.concat(
            _generateSingleHexagon(hex1X, hex1Y, color1, opacity, fillFirst),
            _generateSingleHexagon(hex2X, hex2Y, color2, opacity, fillSecond),
            _generateSingleHexagon(hex3X, hex3Y, color3, opacity, fillThird)
        );
    }

    /// @notice Generate single hexagon element with optional fill
    /// @param x X position
    /// @param y Y position
    /// @param color Stroke/fill color
    /// @param opacity Opacity value
    /// @param filled Whether to fill the hexagon (for rare tokens)
    /// @return hexagon Single hexagon SVG
   function _generateSingleHexagon(
        uint256 x, 
        uint256 y, 
        string memory color, 
        string memory opacity,
        bool filled
    ) internal pure returns (string memory) {
        string memory fillAttr;
        
        if (filled) {
            // Wypełnione hexagony mają solidny kolor z większą przezroczystością
            fillAttr = string.concat('fill="', color, '" fill-opacity="0.6"');
        } else {
            fillAttr = 'fill="none"';
        }
            
        return string.concat(
            '<polygon points="',
            x.toString(), ',', y.toString(), ' ',
            (x + 10).toString(), ',', (y - 6).toString(), ' ',
            (x + 20).toString(), ',', y.toString(), ' ',
            (x + 20).toString(), ',', (y + 12).toString(), ' ',
            (x + 10).toString(), ',', (y + 18).toString(), ' ',
            x.toString(), ',', (y + 12).toString(),
            '" ', fillAttr, ' stroke="', color, '" stroke-width="2" opacity="', opacity, '"/>'
        );
    }

    /// @notice Generate balance badge with Layers icon when owner has multiple tokens
    /// @param balance Owner's total token balance
    /// @return badge Balance badge SVG element
    function _generateBalanceBadge(uint256 balance) internal pure returns (string memory) {
        // Position badge in top-right corner
        string memory badgeX = "230";
        string memory badgeY = "28";
        string memory badgeWidth = "55";
        string memory badgeHeight = "18";
        
        return string.concat(
            // Badge background with gradient
            '<defs>',
            '<linearGradient id="badgeGradient" x1="0%" y1="0%" x2="100%" y2="100%">',
            '<stop offset="0%" style="stop-color:#667eea;stop-opacity:1" />',
            '<stop offset="100%" style="stop-color:#764ba2;stop-opacity:1" />',
            '</linearGradient>',
            '</defs>',
            '<rect x="', badgeX, '" y="', badgeY, '" width="', badgeWidth, '" height="', badgeHeight, '" rx="9" ry="9" fill="url(#badgeGradient)" stroke="#FFFFFF" stroke-width="1.5"/>',
            // Layers icon (stacked rectangles)
            '<g transform="translate(235, 32)">',
            '<rect x="0" y="6" width="10" height="2" rx="1" fill="#FFFFFF" opacity="0.5"/>',
            '<rect x="0" y="3" width="10" height="2" rx="1" fill="#FFFFFF" opacity="0.7"/>',
            '<rect x="0" y="0" width="10" height="2" rx="1" fill="#FFFFFF" opacity="0.9"/>',
            '</g>',
            // Balance count text
            unicode'<text x="252" y="40" font-family="Arial, sans-serif" font-size="11" font-weight="bold" fill="#FFFFFF" text-anchor="start">×', balance.toString(), '</text>'
        );
    }

    /// @notice Generate yellow gradient colors based on tokenId
    /// @param tokenId Token ID for unique colors
    /// @return bg1 First background color
    /// @return bg2 Second background color  
    /// @return bg3 Third background color
    function _generateYellowGradient(uint256 tokenId) 
        internal 
        pure 
        returns (string memory, string memory, string memory) 
    {
        bytes32 hash = keccak256(abi.encodePacked(tokenId, "yellow"));
        
        uint256 v1 = (uint256(hash) >> 0) % 100;
        uint256 v2 = (uint256(hash) >> 8) % 100;
        uint256 v3 = (uint256(hash) >> 16) % 100;
        
        // Generate proper yellow spectrum: high red+green, low blue
        return (
            string.concat("#", _toHex(240 + (v1 % 15)), _toHex(230 + (v1 % 25)), _toHex(100 + (v1 % 50))),  // Light yellow
            string.concat("#", _toHex(255), _toHex(200 + (v2 % 55)), _toHex(50 + (v2 % 30))),                // Golden yellow  
            string.concat("#", _toHex(200 + (v3 % 55)), _toHex(170 + (v3 % 50)), _toHex(20 + (v3 % 40)))     // Deep yellow/amber
        );
    }

    /// @notice Generate accent color for tech elements
    /// @param tokenId Token ID for unique color
    /// @param coreCount Core count affecting intensity
    /// @return color Accent color hex string
    function _generateAccentColor(uint256 tokenId, uint8 coreCount) internal pure returns (string memory) {
        bytes32 hash = keccak256(abi.encodePacked(tokenId, "accent", coreCount));
        uint256 colorValue = uint256(hash) % 0x1000000;
        return string.concat("#", _toHexString(colorValue, 3));
    }

    /// @notice Generate dynamic goggle color based on token
    /// @param tokenId Token ID for base color
    /// @return color Goggle frame color
    function _generateGoggleColor(uint256 tokenId) internal pure returns (string memory) {
        bytes32 hash = keccak256(abi.encodePacked(tokenId, "goggle"));
        uint256 colorBase = uint256(hash) % 7;
        
        string[7] memory goggleColors = [
            "#1565c0", "#7b1fa2", "#d32f2f", "#388e3c", "#f57c00", "#5d4037", "#455a64"
        ];
        
        return goggleColors[colorBase];
    }

    /// @notice Generate LED colors with core count influence
    /// @param tokenId Token ID
    /// @param offset LED position offset
    /// @param coreCount Number of cores affecting intensity
    /// @return color LED color
    function _generateLEDColor(uint256 tokenId, uint256 offset, uint8 coreCount) internal pure returns (string memory) {
        bytes32 hash = keccak256(abi.encodePacked(tokenId, "led", offset, coreCount));
        uint256 variant = uint256(hash) % 6;
        
        // Higher core count gets more vibrant colors
        if (coreCount >= 10) {
            string[6] memory vibrantColors = [
                "#00ff41", "#ff0080", "#0080ff", "#ff8000", "#8000ff", "#ff4000"
            ];
            return vibrantColors[variant];
        } else if (coreCount >= 5) {
            string[6] memory mediumColors = [
                "#4caf50", "#2196f3", "#ff9800", "#9c27b0", "#00bcd4", "#ff5722"
            ];
            return mediumColors[variant];
        } else {
            string[6] memory dimColors = [
                "#388e3c", "#1976d2", "#f57c00", "#7b1fa2", "#0097a7", "#d84315"
            ];
            return dimColors[variant];
        }
    }

    /// @notice Check if token has rare traits with core count influence
    /// @param tokenId Token ID to check
    /// @param coreCount Number of cores affecting rarity
    /// @return isRare Whether token is rare
    function _isRareToken(uint256 tokenId, uint8 coreCount) internal pure returns (bool) {
        bytes32 hash = keccak256(abi.encodePacked(tokenId, "rarity", coreCount));
        
        uint256 rarity = 20; // Zwiększona bazowa szansa z 5% na 20%
        
        // Progresywny bonus za cores
        if (coreCount >= 10) {
            rarity += 40; // +40% (total 60%)
        } else if (coreCount >= 8) {
            rarity += 30; // +30% (total 50%)
        } else if (coreCount >= 5) {
            rarity += 20; // +20% (total 40%)
        } else if (coreCount >= 3) {
            rarity += 10; // +10% (total 30%)
        }
        
        return uint256(hash) % 100 < rarity;
    }

    /// @notice Build complete OpenSea-compatible JSON metadata
    /// @param metadata Token metadata
    /// @param svg Generated SVG image
    /// @return json Complete JSON metadata string
    function _buildJSON(TokenMetadata memory metadata, string memory svg) 
        internal 
        view
        returns (string memory) 
    {
        string memory encodedSVG = Base64.encode(bytes(svg));
        string memory dataURI = string.concat("data:image/svg+xml;base64,", encodedSVG);
        string memory escapedDescription = _escapeJSONString(COLLECTION_DESCRIPTION);
        
        return string.concat(
            '{"name":"Yellow Conduit #', 
            _padTokenId(metadata.tokenId), 
            '","description":"', 
            escapedDescription, 
            '","image":"', 
            dataURI,
            '","external_url":"https://henomorphs.zico.network/conduit/',
            metadata.tokenId.toString(),
            '","animation_url":"', 
            dataURI,
            '","attributes":', 
            _generateAttributes(metadata), 
            ',"properties":{"category":"Conduit","ecosystem":"Henomorphs","utility":"Core Redemption"}}'
        );
    }

    /// @notice Generate OpenSea-compatible attributes array
    /// @param metadata Token metadata
    /// @return attributes JSON attributes string
    function _generateAttributes(TokenMetadata memory metadata) 
        internal 
        view
        returns (string memory) 
    {
        bool isExpired = block.timestamp > metadata.expiryDate;
        string memory rarity = _getRarityTrait(metadata.tokenId, metadata.coreCount);
        string memory coreTier = _getCoreTier(metadata.coreCount);
        
        return string.concat(
            '[',
            '{"trait_type":"Cores","value":"', metadata.coreCount.toString(), '"},',
            '{"trait_type":"Owner Balance","value":', metadata.ownerBalance.toString(), '},',
            '{"trait_type":"Status","value":"', (metadata.isActive ? "Active" : "Burned"), '"},',
            '{"trait_type":"Expired","value":"', (isExpired ? "Yes" : "No"), '"},',
            '{"trait_type":"Expiry Date","display_type":"date","value":"', metadata.expiryDate.toString(), '"},',
            '{"trait_type":"Rarity","value":"', rarity, '"},',
            '{"trait_type":"Core Tier","value":"', coreTier, '"},',
            '{"trait_type":"Character","value":"Tech Chicken"},',
            '{"trait_type":"Accessory","value":"AR Goggles"},',
            '{"trait_type":"Background","value":"Dynamic Yellow"}',
            ']'
        );
    }

    /// @notice Escape special characters in JSON strings
    /// @param str String to escape
    /// @return escaped Escaped string safe for JSON
    function _escapeJSONString(string memory str) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(strBytes.length * 2); // Worst case: every char needs escaping
        uint256 resultIndex = 0;
        
        for (uint256 i = 0; i < strBytes.length; i++) {
            bytes1 char = strBytes[i];
            
            if (char == '"') {
                result[resultIndex++] = '\\';
                result[resultIndex++] = '"';
            } else if (char == '\\') {
                result[resultIndex++] = '\\';
                result[resultIndex++] = '\\';
            } else if (char == '\n') {
                result[resultIndex++] = '\\';
                result[resultIndex++] = 'n';
            } else if (char == '\r') {
                result[resultIndex++] = '\\';
                result[resultIndex++] = 'r';
            } else if (char == '\t') {
                result[resultIndex++] = '\\';
                result[resultIndex++] = 't';
            } else {
                result[resultIndex++] = char;
            }
        }
        
        // Trim result to actual length
        bytes memory trimmed = new bytes(resultIndex);
        for (uint256 i = 0; i < resultIndex; i++) {
            trimmed[i] = result[i];
        }
        
        return string(trimmed);
    }

    /// @notice Format expiry date as readable string  
    /// @param timestamp Expiry timestamp
    /// @return formatted Formatted date string (DD.MM.YYYY)
    function _formatExpiryDate(uint256 timestamp) internal pure returns (string memory) {
        if (timestamp == 0) return "Never";
        
        // Date conversion algorithm
        uint256 daysSinceEpoch = timestamp / 86400;
        
        uint256 year = 1970;
        uint256 _days = daysSinceEpoch;
        
        // Calculate year
        while (_days >= 365) {
            bool isLeap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
            uint256 yearDays = isLeap ? 366 : 365;
            if (_days >= yearDays) {
                _days -= yearDays;
                year++;
            } else {
                break;
            }
        }
        
        // Days in months array
        uint8[12] memory daysInMonth = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        
        // Check leap year
        bool isLeapYear = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
        if (isLeapYear) {
            daysInMonth[1] = 29; // February in leap year
        }
        
        uint256 month = 1;
        uint256 day = _days + 1;
        
        // Find correct month
        for (uint256 i = 0; i < 12; i++) {
            if (day <= daysInMonth[i]) {
                month = i + 1;
                break;
            }
            day -= daysInMonth[i];
            month = i + 2;
        }
        
        return string.concat(
            _padZero(day), ".", _padZero(month), ".", year.toString()
        );
    }

    /// @notice Get rarity trait based on token characteristics
    /// @param tokenId Token ID
    /// @param coreCount Number of cores
    /// @return rarity Rarity tier string
    function _getRarityTrait(uint256 tokenId, uint8 coreCount) internal pure returns (string memory) {
        if (_isRareToken(tokenId, coreCount)) {
            bytes32 hash = keccak256(abi.encodePacked(tokenId, "level", coreCount));
            uint256 rarityLevel = uint256(hash) % 100;
            
            // Zwiększone szanse na wyższe rzadkości z bonusem za cores
            uint256 legendaryChance = 8 + (coreCount >= 10 ? 12 : coreCount); // 8-20%
            uint256 epicChance = 25 + (coreCount >= 8 ? 15 : coreCount);      // 25-40%
            
            if (rarityLevel < legendaryChance) return "Legendary";
            if (rarityLevel < epicChance) return "Epic";
            return "Rare";
        }
        return "Common";
    }

    /// @notice Get core tier description based on count
    /// @param coreCount Number of cores
    /// @return tier Tier description
    function _getCoreTier(uint8 coreCount) internal pure returns (string memory) {
        if (coreCount >= 12) return "Maximum";
        if (coreCount >= 8) return "High";
        if (coreCount >= 5) return "Medium";
        if (coreCount >= 3) return "Low";
        return "Minimal";
    }

    /// @notice Pad token ID to 4 digits with leading zeros
    /// @param tokenId Token ID to pad
    /// @return padded Padded token ID string (max 4 digits)
    function _padTokenId(uint256 tokenId) internal pure returns (string memory) {
        if (tokenId < 10) {
            return string.concat("000", tokenId.toString());
        } else if (tokenId < 100) {
            return string.concat("00", tokenId.toString());
        } else if (tokenId < 1000) {
            return string.concat("0", tokenId.toString());
        }
        return tokenId.toString();
    }

    /// @notice Convert number to 2-digit hex
    /// @param value Value to convert (0-255)
    /// @return hex 2-digit hex string
    function _toHex(uint256 value) internal pure returns (string memory) {
        value = value % 256; // Ensure within byte range
        return string(abi.encodePacked(
            HEX_SYMBOLS[value >> 4],
            HEX_SYMBOLS[value & 0xf]
        ));
    }

    /// @notice Convert to hex string with specific length
    /// @param value Value to convert
    /// @param length Hex length in bytes
    /// @return hex Hex string
    function _toHexString(uint256 value, uint256 length) internal pure returns (string memory) {
        bytes memory buffer = new bytes(2 * length);
        for (uint256 i = 2 * length; i > 0; --i) {
            buffer[i - 1] = HEX_SYMBOLS[value & 0xf];
            value >>= 4;
        }
        return string(buffer);
    }

    /// @notice Pad single digit numbers with leading zero
    /// @param value Value to pad
    /// @return padded Padded string
    function _padZero(uint256 value) internal pure returns (string memory) {
        if (value < 10) {
            return string.concat("0", value.toString());
        }
        return value.toString();
    }

    /// @notice Get collection image for contractURI
    /// @return image Collection image URL or data URI
    function _getCollectionImage() internal pure returns (string memory) {
        // Minimal SVG representing Yellow Conduit collection
        string memory svg = string.concat(
            '<svg viewBox="0 0 200 200" xmlns="http://www.w3.org/2000/svg">',
            '<defs>',
            '<radialGradient id="bgGrad" cx="50%" cy="40%" r="60%">',
            '<stop offset="0%" style="stop-color:#fff3c4;stop-opacity:1" />',
            '<stop offset="100%" style="stop-color:#ffc107;stop-opacity:1" />',
            '</radialGradient>',
            '<radialGradient id="chickGrad" cx="50%" cy="40%" r="60%">',
            '<stop offset="0%" style="stop-color:#ffeb3b;stop-opacity:1" />',
            '<stop offset="100%" style="stop-color:#ff8f00;stop-opacity:1" />',
            '</radialGradient>',
            '</defs>',
            
            // Background
            '<rect width="200" height="200" fill="url(#bgGrad)"/>',
            '<rect x="10" y="10" width="180" height="180" rx="10" fill="none" stroke="#CD853F" stroke-width="3"/>',
            
            // Main chicken (centered)
            '<ellipse cx="100" cy="120" rx="35" ry="40" fill="url(#chickGrad)"/>',
            '<circle cx="100" cy="80" r="30" fill="url(#chickGrad)"/>',
            
            // Feathers
            '<circle cx="90" cy="60" r="8" fill="#ffeb3b"/>',
            '<circle cx="100" cy="55" r="10" fill="#ffeb3b"/>',
            '<circle cx="110" cy="60" r="8" fill="#ffeb3b"/>',
            
            // Eyes
            '<ellipse cx="90" cy="75" rx="6" ry="8" fill="#000"/>',
            '<ellipse cx="110" cy="75" rx="6" ry="8" fill="#000"/>',
            '<circle cx="92" cy="72" r="2" fill="#fff"/>',
            '<circle cx="112" cy="72" r="2" fill="#fff"/>',
            
            // Tech goggles
            '<circle cx="90" cy="75" rx="12" ry="10" fill="none" stroke="#5d4037" stroke-width="2"/>',
            '<circle cx="110" cy="75" rx="12" ry="10" fill="none" stroke="#5d4037" stroke-width="2"/>',
            '<rect x="97" y="72" width="6" height="3" fill="#5d4037"/>',
            
            // Beak
            '<polygon points="100,85 95,95 105,95" fill="#ff9800"/>',
            
            // Wings
            '<ellipse cx="70" cy="120" rx="15" ry="8" fill="url(#chickGrad)" transform="rotate(-15 70 120)"/>',
            '<ellipse cx="130" cy="120" rx="15" ry="8" fill="url(#chickGrad)" transform="rotate(15 130 120)"/>',
            
            // Tech vest (simplified)
            '<rect x="80" y="110" width="40" height="30" rx="5" fill="#263238"/>',
            '<rect x="85" y="115" width="8" height="4" fill="#4caf50"/>',
            '<rect x="107" y="115" width="8" height="4" fill="#4caf50"/>',
            
            // Legs
            '<rect x="90" y="155" width="5" height="15" fill="#ff9800"/>',
            '<rect x="105" y="155" width="5" height="15" fill="#ff9800"/>',
            
            // Feet
            '<ellipse cx="92" cy="173" rx="4" ry="3" fill="#ff9800"/>',
            '<ellipse cx="107" cy="173" rx="4" ry="3" fill="#ff9800"/>',
            
            // Cores (side elements representing collection)
            '<ellipse cx="30" cy="50" rx="3" ry="4" fill="#ffeb3b" opacity="0.8"/>',
            '<ellipse cx="45" cy="60" rx="3" ry="4" fill="#ffeb3b" opacity="0.8"/>',
            '<ellipse cx="155" cy="50" rx="3" ry="4" fill="#ffeb3b" opacity="0.8"/>',
            '<ellipse cx="170" cy="60" rx="3" ry="4" fill="#ffeb3b" opacity="0.8"/>',
            
            // Collection text
            '<text x="100" y="25" text-anchor="middle" font-family="Arial, sans-serif" font-size="14" font-weight="bold" fill="#B8860B">YELLOW CONDUIT</text>',
            '<text x="100" y="190" text-anchor="middle" font-family="Arial, sans-serif" font-size="10" fill="#8B4513">Henomorphs Ecosystem Collection</text>',
            
            '</svg>'
        );
        
        // POPRAWKA: Zwróć enkodowany SVG, nie ponownie enkoduj
        string memory encoded = Base64.encode(bytes(svg));
        return string.concat("data:image/svg+xml;base64,", encoded);
    }
}