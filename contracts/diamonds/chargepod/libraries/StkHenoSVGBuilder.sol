// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/**
 * @title StkHenoSVGBuilder
 * @notice Library for generating on-chain SVG graphics for stkHENO receipt tokens
 * @dev Translates the TypeScript prototype to gas-optimized Solidity
 * @author rutilicus.eth (ArchXS)
 */
library StkHenoSVGBuilder {
    using Strings for uint256;
    using Strings for uint8;

    // ============ STRUCTS ============

    struct ReceiptVisualData {
        uint256 receiptId;
        uint256 originalTokenId;
        uint8 tier;             // 1-5
        uint8 variant;          // 0-4
        uint32 stakedAt;
        uint256 stakingDays;
        uint256 totalRewards;   // accumulated + pending (scaled by 1e18)
        uint256 transferCount;
        uint256 collectionId;
        address collectionAddress;
        string collectionName;
        bool hasAugment;
        uint8 augmentVariant;   // 1-4
    }

    struct ColorPalette {
        bytes3 primary;
        bytes3 secondary;
        bytes3 accent;
    }

    struct LoyaltyInfo {
        string emoji;
        bytes3 color;
        string name;
    }

    // ============ CONSTANTS - TIER COLORS ============

    // Tier primary colors (bytes3 = 3 bytes RGB)
    bytes3 private constant TIER1_PRIMARY = bytes3(0x1a1a2e);    // Deep Navy
    bytes3 private constant TIER2_PRIMARY = bytes3(0x0f3460);    // Royal Blue
    bytes3 private constant TIER3_PRIMARY = bytes3(0x533483);    // Deep Purple
    bytes3 private constant TIER4_PRIMARY = bytes3(0xe94560);    // Crimson
    bytes3 private constant TIER5_PRIMARY = bytes3(0xf5af19);    // Gold

    // Tier secondary colors
    bytes3 private constant TIER1_SECONDARY = bytes3(0x16213e);
    bytes3 private constant TIER2_SECONDARY = bytes3(0x1a1a2e);
    bytes3 private constant TIER3_SECONDARY = bytes3(0x0f3460);
    bytes3 private constant TIER4_SECONDARY = bytes3(0x533483);
    bytes3 private constant TIER5_SECONDARY = bytes3(0xe94560);

    // ============ CONSTANTS - VARIANT ACCENTS ============

    bytes3 private constant VARIANT0_ACCENT = bytes3(0x00d9ff);  // Cyan - Angular
    bytes3 private constant VARIANT1_ACCENT = bytes3(0x7b2cbf);  // Purple - Organic
    bytes3 private constant VARIANT2_ACCENT = bytes3(0x00ff87);  // Green - Crystalline
    bytes3 private constant VARIANT3_ACCENT = bytes3(0xff6b35);  // Orange - Energy
    bytes3 private constant VARIANT4_ACCENT = bytes3(0xff006e);  // Magenta - Hybrid

    // ============ CONSTANTS - LOYALTY ============

    bytes3 private constant LOYALTY_NEW_COLOR = bytes3(0xFFFFFF);
    bytes3 private constant LOYALTY_ACTIVE_COLOR = bytes3(0xFF4500);
    bytes3 private constant LOYALTY_COMMITTED_COLOR = bytes3(0xFFA500);
    bytes3 private constant LOYALTY_DIAMOND_COLOR = bytes3(0x00CED1);
    bytes3 private constant LOYALTY_LEGENDARY_COLOR = bytes3(0xFFD700);

    // ============ MAIN GENERATION ============

    /**
     * @notice Generate complete SVG for a receipt token
     * @param data Visual data for the receipt
     * @return svg The complete SVG string
     */
    function generateSVG(ReceiptVisualData memory data) internal pure returns (string memory) {
        ColorPalette memory colors = getColorPalette(data.tier, data.variant);
        LoyaltyInfo memory loyalty = getLoyaltyInfo(data.stakingDays);
        uint8 glowIntensity = getGlowIntensity(data.stakingDays);
        uint8 animDuration = getAnimationDuration(data.stakingDays);

        return string.concat(
            _buildSVGHeader(),
            _buildDefs(colors, glowIntensity, animDuration, data.tier, data.receiptId, data.variant),
            _buildBackground(colors, glowIntensity),
            _buildAnimatedBorderText(data.receiptId, data.tier, data.variant),
            _buildFrame(colors, data.tier),
            _buildBadges(loyalty, data.transferCount),
            _buildCentralEmblem(colors, data.variant, data.stakingDays, data.totalRewards),
            _buildInfoPanel(data, colors, loyalty),
            _buildFooter(),
            '</svg>'
        );
    }

    // ============ SVG STRUCTURE BUILDERS ============

    function _buildSVGHeader() private pure returns (string memory) {
        return '<?xml version="1.0" encoding="UTF-8"?>'
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 600" width="400" height="600">';
    }

    function _buildDefs(
        ColorPalette memory colors,
        uint8 glowIntensity,
        uint8 animDuration,
        uint8 tier,
        uint256 /*receiptId*/,
        uint8 /*variant*/
    ) private pure returns (string memory) {
        return string.concat(
            '<defs>',
            _buildGradients(colors, glowIntensity),
            _buildFilters(tier),
            _buildTextPath(),
            _buildAnimationStyles(glowIntensity, animDuration),
            '</defs>'
        );
    }

    function _buildGradients(ColorPalette memory colors, uint8 glowIntensity) private pure returns (string memory) {
        string memory primaryHex = _toHexString(colors.primary);
        string memory secondaryHex = _toHexString(colors.secondary);
        string memory accentHex = _toHexString(colors.accent);

        return string.concat(
            // Background gradient
            '<linearGradient id="bgGradient" x1="0%" y1="0%" x2="0%" y2="100%">',
            '<stop offset="0%" style="stop-color:', primaryHex, '"/>',
            '<stop offset="100%" style="stop-color:', secondaryHex, '"/></linearGradient>',
            // Glow gradient
            '<radialGradient id="glowGradient" cx="50%" cy="50%" r="50%">',
            '<stop offset="0%" style="stop-color:', accentHex, ';stop-opacity:0.', uint256(glowIntensity).toString(), '"/>',
            '<stop offset="100%" style="stop-color:', accentHex, ';stop-opacity:0"/></radialGradient>',
            // Border gradient
            '<linearGradient id="borderGradient" x1="0%" y1="0%" x2="100%" y2="100%">',
            '<stop offset="0%" style="stop-color:', accentHex, '"/>',
            '<stop offset="50%" style="stop-color:white;stop-opacity:0.5"/>',
            '<stop offset="100%" style="stop-color:', accentHex, '"/></linearGradient>',
            // Emblem gradient
            '<radialGradient id="emblemGradient" cx="50%" cy="30%" r="70%">',
            '<stop offset="0%" style="stop-color:white"/>',
            '<stop offset="100%" style="stop-color:', accentHex, ';stop-opacity:0.8"/></radialGradient>'
        );
    }

    function _buildFilters(uint8 tier) private pure returns (string memory) {
        string memory blurStd = uint256(3 + tier).toString();
        return string.concat(
            '<filter id="glow" x="-50%" y="-50%" width="200%" height="200%">',
            '<feGaussianBlur stdDeviation="', blurStd, '" result="coloredBlur"/>',
            '<feMerge><feMergeNode in="coloredBlur"/><feMergeNode in="SourceGraphic"/></feMerge></filter>',
            '<filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">',
            '<feDropShadow dx="2" dy="4" stdDeviation="3" flood-opacity="0.3"/></filter>',
            '<filter id="noise">',
            '<feTurbulence type="fractalNoise" baseFrequency="0.8" numOctaves="4" stitchTiles="stitch"/>',
            '<feColorMatrix type="saturate" values="0"/></filter>'
        );
    }

    function _buildTextPath() private pure returns (string memory) {
        return '<path id="textPath" d="M 27,20 L 373,20 Q 385,20 385,32 L 385,568 Q 385,580 373,580 L 27,580 Q 15,580 15,568 L 15,32 Q 15,20 27,20 Z"/>';
    }

    function _buildAnimationStyles(uint8 glowIntensity, uint8 animDuration) private pure returns (string memory) {
        uint8 minGlow = glowIntensity > 30 ? glowIntensity - 30 : 0;
        return string.concat(
            '<style>',
            '.pulse-glow{animation:pulse ', uint256(animDuration).toString(), 's ease-in-out infinite}',
            '@keyframes pulse{0%,100%{opacity:0.', uint256(minGlow).toString(), '}50%{opacity:0.', uint256(glowIntensity).toString(), '}}',
            '.rotate-slow{animation:rotate 60s linear infinite;transform-origin:center}',
            '@keyframes rotate{from{transform:rotate(0deg)}to{transform:rotate(360deg)}}',
            '.emblem-pulse{animation:emblem-pulse 3s ease-in-out infinite;transform-origin:center}',
            '@keyframes emblem-pulse{0%,100%{transform:scale(1);opacity:0.8}50%{transform:scale(1.05);opacity:1}}',
            '.frame-glow{animation:frame-glow 4s ease-in-out infinite}',
            '@keyframes frame-glow{0%,100%{stroke-width:2}50%{stroke-width:3}}',
            '.badge-float{animation:badge-float 3s ease-in-out infinite}',
            '@keyframes badge-float{0%,100%{transform:translateY(0)}50%{transform:translateY(-3px)}}',
            '</style>'
        );
    }

    function _buildBackground(ColorPalette memory /*colors*/, uint8 /*glowIntensity*/) private pure returns (string memory) {
        return string.concat(
            '<g id="background">',
            '<rect width="100%" height="100%" fill="url(#bgGradient)"/>',
            '<rect width="100%" height="100%" fill="url(#noise)" opacity="0.03"/>',
            '<g opacity="0.08">',
            '<pattern id="grid" width="20" height="20" patternUnits="userSpaceOnUse">',
            '<path d="M 20 0 L 0 0 0 20" fill="none" stroke="white" stroke-width="0.5"/></pattern>',
            '<rect width="100%" height="100%" fill="url(#grid)"/></g>',
            '<ellipse cx="200" cy="280" rx="180" ry="150" fill="url(#glowGradient)" class="pulse-glow"/></g>'
        );
    }

    function _buildAnimatedBorderText(uint256 receiptId, uint8 tier, uint8 variant) private pure returns (string memory) {
        string memory text = string.concat(
            unicode"• STAKED HENOMORPH • LIQUID STAKING RECEIPT • stkHENO #",
            receiptId.toString(),
            " ", unicode"• T", uint256(tier).toString(),
            " V", uint256(variant).toString(), unicode" •"
        );

        return string.concat(
            '<text text-rendering="optimizeSpeed" fill="white" opacity="0.4" font-family="monospace" font-size="9">',
            '<textPath startOffset="-100%" href="#textPath">', text,
            '<animate additive="sum" attributeName="startOffset" from="0%" to="100%" dur="35s" repeatCount="indefinite"/></textPath>',
            '<textPath startOffset="0%" href="#textPath">', text,
            '<animate additive="sum" attributeName="startOffset" from="0%" to="100%" dur="35s" repeatCount="indefinite"/></textPath></text>'
        );
    }

    function _buildFrame(ColorPalette memory colors, uint8 tier) private pure returns (string memory) {
        string memory accentHex = _toHexString(colors.accent);
        string memory tierSymbol = getTierSymbol(tier);

        return string.concat(
            '<g id="frame" filter="url(#glow)">',
            '<rect x="20" y="20" width="360" height="560" rx="20" ry="20" fill="none" stroke="url(#borderGradient)" stroke-width="2" class="frame-glow"/>',
            '<rect x="30" y="30" width="340" height="540" rx="15" ry="15" fill="none" stroke="white" stroke-width="1" opacity="0.2"/>',
            '<g fill="', accentHex, '" opacity="0.7" font-size="18">',
            '<text x="42" y="52">', tierSymbol, '</text>',
            '<text x="358" y="52" text-anchor="end">', tierSymbol, '</text>',
            '<text x="42" y="558">', tierSymbol, '</text>',
            '<text x="358" y="558" text-anchor="end">', tierSymbol, '</text></g></g>'
        );
    }

    function _buildBadges(LoyaltyInfo memory loyalty, uint256 transferCount) private pure returns (string memory) {
        string memory loyaltyColorHex = _toHexString(loyalty.color);

        return string.concat(
            // Loyalty Badge (top left)
            '<g transform="translate(55, 55)" class="badge-float">',
            '<circle r="18" fill="', loyaltyColorHex, '" fill-opacity="0.2" stroke="', loyaltyColorHex, '" stroke-width="1" opacity="0.6"/>',
            '<text x="0" y="0" text-anchor="middle" dominant-baseline="central" font-size="16">', loyalty.emoji, '</text></g>',
            // Transfer Count (below loyalty badge)
            '<g transform="translate(55, 95)">',
            '<circle r="14" fill="black" fill-opacity="0.4" stroke="white" stroke-width="1" opacity="0.5"/>',
            '<text x="0" y="0" text-anchor="middle" dominant-baseline="central" font-family="monospace" font-size="9" fill="white">',
            transferCount.toString(), 'x</text></g>'
        );
    }

    function _buildCentralEmblem(
        ColorPalette memory colors,
        uint8 variant,
        uint256 /*stakingDays*/,
        uint256 totalRewards
    ) private pure returns (string memory) {
        string memory accentHex = _toHexString(colors.accent);
        uint8 particleCount = getParticleCount(totalRewards);

        return string.concat(
            '<g id="central-emblem" transform="translate(200, 230)">',
            '<circle r="105" fill="none" stroke="white" stroke-width="1" opacity="0.2" stroke-dasharray="5 10" class="rotate-slow"/>',
            '<circle r="92" fill="none" stroke="', accentHex, '" stroke-width="2" opacity="0.4" stroke-dasharray="15 5"/>',
            '<circle r="80" fill="black" fill-opacity="0.4"/>',
            '<circle r="75" fill="url(#glowGradient)" opacity="0.3"/>',
            '<g class="emblem-pulse" style="color: #ffeb3b" transform="scale(0.85)">',
            _buildChickenSilhouette(variant, accentHex),
            '</g>',
            '<g class="rotate-slow">', _buildParticles(particleCount, accentHex), '</g>',
            '<g transform="translate(0, 95)">',
            '<rect x="-45" y="-14" width="90" height="28" rx="14" fill="black" fill-opacity="0.6" stroke="', accentHex, '" stroke-width="1"/>',
            unicode'<text x="0" y="0" text-anchor="middle" dominant-baseline="central" font-family="monospace" font-size="12" font-weight="bold" fill="white">⚡ STAKED</text></g></g>'
        );
    }

    function _buildChickenSilhouette(uint8 variant, string memory accentHex) private pure returns (string memory) {
        return string.concat(
            // Body
            '<ellipse cx="0" cy="15" rx="28" ry="32" fill="currentColor"/>',
            // Head
            '<circle cx="0" cy="-25" r="24" fill="currentColor"/>',
            // Variant-specific feathers
            _getVariantFeathers(variant),
            // Eyes
            '<ellipse cx="-8" cy="-28" rx="5" ry="7" fill="#000"/>',
            '<ellipse cx="8" cy="-28" rx="5" ry="7" fill="#000"/>',
            '<circle cx="-6" cy="-30" r="2" fill="#fff"/>',
            '<circle cx="10" cy="-30" r="2" fill="#fff"/>',
            // Beak
            '<polygon points="0,-18 -5,-10 5,-10" fill="#ff9800"/>',
            // Wings
            '<ellipse cx="-22" cy="10" rx="12" ry="8" fill="currentColor" transform="rotate(-15 -22 10)"/>',
            '<ellipse cx="22" cy="10" rx="12" ry="8" fill="currentColor" transform="rotate(15 22 10)"/>',
            // Tech goggles
            '<ellipse cx="-8" cy="-28" rx="10" ry="8" fill="none" stroke="', accentHex, '" stroke-width="2"/>',
            '<ellipse cx="8" cy="-28" rx="10" ry="8" fill="none" stroke="', accentHex, '" stroke-width="2"/>',
            '<rect x="-3" y="-30" width="6" height="3" fill="', accentHex, '"/>',
            '<ellipse cx="-8" cy="-28" rx="8" ry="6" fill="', accentHex, '" fill-opacity="0.3"/>',
            '<ellipse cx="8" cy="-28" rx="8" ry="6" fill="', accentHex, '" fill-opacity="0.3"/>',
            // Tech vest
            '<rect x="-18" y="5" width="36" height="28" rx="5" fill="#263238"/>',
            '<rect x="-14" y="10" width="8" height="4" fill="', accentHex, '"/>',
            '<rect x="6" y="10" width="8" height="4" fill="', accentHex, '"/>',
            '<rect x="-14" y="18" width="28" height="3" fill="', accentHex, '" opacity="0.7"/>',
            '<rect x="-14" y="24" width="18" height="3" fill="', accentHex, '" opacity="0.5"/>',
            '<circle cx="-6" cy="14" r="2" fill="#ff5722"/>',
            '<circle cx="6" cy="14" r="2" fill="#4caf50"/>',
            // Legs and feet
            '<rect x="-10" y="42" width="5" height="12" fill="#ff9800"/>',
            '<rect x="5" y="42" width="5" height="12" fill="#ff9800"/>',
            '<ellipse cx="-7" cy="56" rx="5" ry="3" fill="#ff9800"/>',
            '<ellipse cx="8" cy="56" rx="5" ry="3" fill="#ff9800"/>'
        );
    }

    function _getVariantFeathers(uint8 variant) private pure returns (string memory) {
        if (variant == 0) {
            // Angular - sharp spiky feathers
            return '<polygon points="0,-55 -5,-48 5,-48" fill="currentColor"/>'
                   '<polygon points="-10,-52 -15,-45 -5,-45" fill="currentColor"/>'
                   '<polygon points="10,-52 5,-45 15,-45" fill="currentColor"/>';
        } else if (variant == 1) {
            // Organic - fluffy round feathers
            return '<circle cx="-10" cy="-45" r="8" fill="currentColor"/>'
                   '<circle cx="0" cy="-50" r="10" fill="currentColor"/>'
                   '<circle cx="10" cy="-45" r="8" fill="currentColor"/>'
                   '<circle cx="-5" cy="-52" r="6" fill="currentColor" opacity="0.8"/>'
                   '<circle cx="5" cy="-52" r="6" fill="currentColor" opacity="0.8"/>';
        } else if (variant == 2) {
            // Crystalline - geometric crystal feathers
            return '<polygon points="0,-58 -8,-48 8,-48" fill="currentColor"/>'
                   '<polygon points="-12,-50 -18,-42 -6,-42" fill="currentColor"/>'
                   '<polygon points="12,-50 6,-42 18,-42" fill="currentColor"/>'
                   '<polygon points="-6,-54 -10,-46 -2,-46" fill="currentColor" opacity="0.7"/>'
                   '<polygon points="6,-54 2,-46 10,-46" fill="currentColor" opacity="0.7"/>';
        } else if (variant == 3) {
            // Energy - flame-like feathers
            return '<ellipse cx="0" cy="-52" rx="4" ry="10" fill="currentColor"/>'
                   '<ellipse cx="-8" cy="-48" rx="3" ry="8" fill="currentColor" transform="rotate(-15 -8 -48)"/>'
                   '<ellipse cx="8" cy="-48" rx="3" ry="8" fill="currentColor" transform="rotate(15 8 -48)"/>'
                   '<ellipse cx="-12" cy="-44" rx="2" ry="6" fill="currentColor" transform="rotate(-25 -12 -44)"/>'
                   '<ellipse cx="12" cy="-44" rx="2" ry="6" fill="currentColor" transform="rotate(25 12 -44)"/>';
        } else {
            // Hybrid - mixed style feathers (variant 4)
            return '<circle cx="0" cy="-52" r="8" fill="currentColor"/>'
                   '<polygon points="-10,-50 -14,-42 -6,-42" fill="currentColor"/>'
                   '<polygon points="10,-50 6,-42 14,-42" fill="currentColor"/>'
                   '<circle cx="-6" cy="-48" r="5" fill="currentColor" opacity="0.8"/>'
                   '<circle cx="6" cy="-48" r="5" fill="currentColor" opacity="0.8"/>';
        }
    }

    function _buildParticles(uint8 count, string memory accentHex) private pure returns (string memory) {
        bytes memory particles;

        for (uint8 i = 0; i < count; i++) {
            // Pre-calculated positions for gas efficiency (12 particles max)
            (int16 x, int16 y) = _getParticlePosition(i, count);
            uint8 radius = 2 + (i % 2);
            uint8 duration = 2 + (i % 2);
            uint8 delay = (i * 5) % 30; // delay in tenths of seconds

            particles = abi.encodePacked(
                particles,
                '<circle cx="', _intToString(x), '" cy="', _intToString(y),
                '" r="', uint256(radius).toString(), '" fill="', accentHex, '" opacity="0.7">',
                '<animate attributeName="opacity" values="0.3;0.9;0.3" dur="', uint256(duration).toString(),
                's" begin="0.', uint256(delay).toString(), 's" repeatCount="indefinite"/></circle>'
            );
        }

        return string(particles);
    }

    function _getParticlePosition(uint8 index, uint8 count) private pure returns (int16 x, int16 y) {
        // Pre-calculated sin/cos values for 12 positions (scaled by 100)
        int16[12] memory cosValues = [int16(100), 87, 50, 0, -50, -87, -100, -87, -50, 0, 50, 87];
        int16[12] memory sinValues = [int16(0), 50, 87, 100, 87, 50, 0, -50, -87, -100, -87, -50];

        uint8 step = count > 0 ? 12 / count : 1;
        uint8 idx = (index * step) % 12;

        int16 distance = int16(85 + int8(index % 3) * 10);

        x = (cosValues[idx] * distance) / 100;
        y = (sinValues[idx] * distance) / 100;
    }

    function _buildInfoPanel(
        ReceiptVisualData memory data,
        ColorPalette memory colors,
        LoyaltyInfo memory loyalty
    ) private pure returns (string memory) {
        string memory accentHex = _toHexString(colors.accent);
        string memory primaryHex = _toHexString(colors.primary);
        string memory loyaltyColorHex = _toHexString(loyalty.color);

        return string.concat(
            '<g id="info-panel" transform="translate(200, 390)">',
            // Receipt ID
            '<text x="0" y="0" text-anchor="middle" font-family="monospace" font-size="24" font-weight="bold" fill="white" filter="url(#shadow)">stkHENO #', data.receiptId.toString(), '</text>',
            // Original Token Reference
            '<g transform="translate(0, 28)">',
            '<text x="0" y="0" text-anchor="middle" font-family="monospace" font-size="11" fill="white" opacity="0.9">', data.collectionName, ' #', data.originalTokenId.toString(), '</text>',
            '<text x="0" y="16" text-anchor="middle" font-family="monospace" font-size="9" fill="', accentHex, '" opacity="0.7">ID: ', data.collectionId.toString(), ' | ', _shortenAddress(data.collectionAddress), '</text></g>',
            // Badges row
            _buildBadgesRow(data, primaryHex, accentHex),
            // Stats row
            _buildStatsRow(data, accentHex),
            // Loyalty status
            '<g transform="translate(0, 160)">',
            '<rect x="-70" y="-12" width="140" height="24" rx="12" fill="', loyaltyColorHex, '" fill-opacity="0.15"/>',
            '<text x="0" y="0" text-anchor="middle" dominant-baseline="central" font-family="sans-serif" font-size="11" fill="', loyaltyColorHex, '">', loyalty.emoji, ' ', loyalty.name, '</text></g>',
            '</g>'
        );
    }

    function _buildBadgesRow(
        ReceiptVisualData memory data,
        string memory primaryHex,
        string memory accentHex
    ) private pure returns (string memory) {
        string memory augmentBadge;

        if (data.hasAugment && data.augmentVariant > 0) {
            augmentBadge = string.concat(
                '<rect x="-30" y="-11" width="60" height="22" rx="11" fill="#ff9800" fill-opacity="0.25" stroke="#ff9800" stroke-width="1"/>',
                '<text x="0" y="0" text-anchor="middle" dominant-baseline="central" font-family="monospace" font-size="11" fill="#ffb74d" font-weight="bold">A', uint256(data.augmentVariant).toString(), '</text>'
            );
        } else {
            augmentBadge = '<rect x="-30" y="-11" width="60" height="22" rx="11" fill="white" fill-opacity="0.05" stroke="white" stroke-width="1" opacity="0.2"/>'
                          '<text x="0" y="0" text-anchor="middle" dominant-baseline="central" font-family="monospace" font-size="9" fill="white" opacity="0.4">NO AUG</text>';
        }

        return string.concat(
            '<g transform="translate(0, 75)">',
            // Tier Badge
            '<g transform="translate(-75, 0)">',
            '<rect x="-30" y="-11" width="60" height="22" rx="11" fill="', primaryHex, '" stroke="', accentHex, '" stroke-width="1"/>',
            '<text x="0" y="0" text-anchor="middle" dominant-baseline="central" font-family="monospace" font-size="11" fill="white" font-weight="bold">T', uint256(data.tier).toString(), '</text></g>',
            // Variant Badge
            '<g transform="translate(0, 0)">',
            '<rect x="-25" y="-11" width="50" height="22" rx="11" fill="white" fill-opacity="0.15" stroke="white" stroke-width="1" opacity="0.4"/>',
            '<text x="0" y="0" text-anchor="middle" dominant-baseline="central" font-family="monospace" font-size="11" fill="white" font-weight="bold">V', uint256(data.variant).toString(), '</text></g>',
            // Augment Badge
            '<g transform="translate(75, 0)">', augmentBadge, '</g>',
            '</g>'
        );
    }

    function _buildStatsRow(ReceiptVisualData memory data, string memory accentHex) private pure returns (string memory) {
        string memory rewardsFormatted = _formatRewards(data.totalRewards);

        return string.concat(
            '<g transform="translate(0, 115)">',
            // Staking Duration
            '<g transform="translate(-100, 0)">',
            '<text x="0" y="0" text-anchor="middle" font-family="sans-serif" font-size="8" fill="white" opacity="0.5">DAYS</text>',
            '<text x="0" y="18" text-anchor="middle" font-family="monospace" font-size="16" fill="white" font-weight="bold">', data.stakingDays.toString(), '</text></g>',
            // Rewards
            '<g transform="translate(0, 0)">',
            '<text x="0" y="0" text-anchor="middle" font-family="sans-serif" font-size="8" fill="white" opacity="0.5">REWARDS</text>',
            '<text x="0" y="18" text-anchor="middle" font-family="monospace" font-size="16" fill="', accentHex, '" font-weight="bold">', rewardsFormatted, ' YLW</text></g>',
            // Transfers
            '<g transform="translate(100, 0)">',
            '<text x="0" y="0" text-anchor="middle" font-family="sans-serif" font-size="8" fill="white" opacity="0.5">TRADES</text>',
            '<text x="0" y="18" text-anchor="middle" font-family="monospace" font-size="16" fill="white">', data.transferCount.toString(), '</text></g>',
            '</g>'
        );
    }

    function _buildFooter() private pure returns (string memory) {
        return '<line x1="80" y1="565" x2="320" y2="565" stroke="url(#borderGradient)" stroke-width="1" opacity="0.5"/>';
    }

    // ============ HELPER FUNCTIONS ============

    function getColorPalette(uint8 tier, uint8 variant) internal pure returns (ColorPalette memory) {
        bytes3 primary;
        bytes3 secondary;
        bytes3 accent;

        // Get tier colors
        if (tier == 1) {
            primary = TIER1_PRIMARY;
            secondary = TIER1_SECONDARY;
        } else if (tier == 2) {
            primary = TIER2_PRIMARY;
            secondary = TIER2_SECONDARY;
        } else if (tier == 3) {
            primary = TIER3_PRIMARY;
            secondary = TIER3_SECONDARY;
        } else if (tier == 4) {
            primary = TIER4_PRIMARY;
            secondary = TIER4_SECONDARY;
        } else {
            primary = TIER5_PRIMARY;
            secondary = TIER5_SECONDARY;
        }

        // Get variant accent
        if (variant == 0) {
            accent = VARIANT0_ACCENT;
        } else if (variant == 1) {
            accent = VARIANT1_ACCENT;
        } else if (variant == 2) {
            accent = VARIANT2_ACCENT;
        } else if (variant == 3) {
            accent = VARIANT3_ACCENT;
        } else {
            accent = VARIANT4_ACCENT;
        }

        return ColorPalette(primary, secondary, accent);
    }

    function getLoyaltyInfo(uint256 stakingDays) internal pure returns (LoyaltyInfo memory) {
        if (stakingDays >= 365) {
            return LoyaltyInfo(unicode"👑", LOYALTY_LEGENDARY_COLOR, "Legendary");
        } else if (stakingDays >= 180) {
            return LoyaltyInfo(unicode"💎", LOYALTY_DIAMOND_COLOR, "Diamond Hands");
        } else if (stakingDays >= 90) {
            return LoyaltyInfo(unicode"⭐", LOYALTY_COMMITTED_COLOR, "Committed");
        } else if (stakingDays >= 30) {
            return LoyaltyInfo(unicode"🔥", LOYALTY_ACTIVE_COLOR, "Active");
        } else {
            return LoyaltyInfo(unicode"✨", LOYALTY_NEW_COLOR, "New Staker");
        }
    }

    function getGlowIntensity(uint256 stakingDays) internal pure returns (uint8) {
        if (stakingDays >= 365) return 90;
        if (stakingDays >= 180) return 75;
        if (stakingDays >= 90) return 60;
        if (stakingDays >= 30) return 45;
        return 30;
    }

    function getAnimationDuration(uint256 stakingDays) internal pure returns (uint8) {
        if (stakingDays >= 365) return 10;
        if (stakingDays >= 180) return 8;
        if (stakingDays >= 90) return 6;
        if (stakingDays >= 30) return 4;
        return 2;
    }

    function getParticleCount(uint256 totalRewards) internal pure returns (uint8) {
        // totalRewards is in wei (1e18 scale)
        uint256 rewardsInEther = totalRewards / 1e18;
        if (rewardsInEther >= 10) return 12;
        if (rewardsInEther >= 5) return 9;
        if (rewardsInEther >= 1) return 6;
        return 3;
    }

    function getTierSymbol(uint8 tier) internal pure returns (string memory) {
        if (tier == 1) return unicode"◇";
        if (tier == 2) return unicode"◆";
        if (tier == 3) return unicode"★";
        if (tier == 4) return unicode"✦";
        return unicode"✧";
    }

    function _toHexString(bytes3 color) private pure returns (string memory) {
        bytes memory result = new bytes(7);
        result[0] = '#';

        bytes memory hexChars = "0123456789abcdef";
        for (uint8 i = 0; i < 3; i++) {
            result[1 + i * 2] = hexChars[uint8(color[i] >> 4)];
            result[2 + i * 2] = hexChars[uint8(color[i]) & 0x0f];
        }

        return string(result);
    }

    function _shortenAddress(address addr) private pure returns (string memory) {
        bytes memory addrBytes = bytes(Strings.toHexString(addr));
        bytes memory result = new bytes(13); // 0x + 4 + ... + 4

        // First 6 chars (0x + 4)
        for (uint8 i = 0; i < 6; i++) {
            result[i] = addrBytes[i];
        }
        result[6] = '.';
        result[7] = '.';
        result[8] = '.';
        // Last 4 chars
        for (uint8 i = 0; i < 4; i++) {
            result[9 + i] = addrBytes[addrBytes.length - 4 + i];
        }

        return string(result);
    }

    function _formatRewards(uint256 rewards) private pure returns (string memory) {
        // rewards in wei, format to 2 decimal places
        uint256 whole = rewards / 1e18;
        uint256 fraction = (rewards % 1e18) / 1e16; // 2 decimal places

        if (fraction < 10) {
            return string.concat(whole.toString(), ".0", fraction.toString());
        }
        return string.concat(whole.toString(), ".", fraction.toString());
    }

    function _intToString(int16 value) private pure returns (string memory) {
        if (value >= 0) {
            return uint256(uint16(value)).toString();
        } else {
            return string.concat("-", uint256(uint16(-value)).toString());
        }
    }
}
