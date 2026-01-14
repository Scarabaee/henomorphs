// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/**
 * @title AchievementSVGBuilder
 * @notice Library for generating minimal, elegant achievement SVG overlays
 * @dev Layer 1: Premium IPFS artwork as base layer (symbolic medals)
 *      Layer 2: Subtle semi-transparent overlay - tier badge, progress, earned date
 *      Design: Minimalist approach - let the artwork shine, overlay only adds metadata
 * @author rutilicus.eth (ArchXS)
 */
library AchievementSVGBuilder {
    using Strings for uint256;
    using Strings for uint8;
    using Strings for uint32;

    // ═══════════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    struct AchievementVisualData {
        uint256 achievementId;
        string name;
        string description;
        uint8 category;     // 1=Combat, 2=Territory, 3=Economic, 4=Collection, 5=Social, 6=Special
        uint8 tier;         // 1=Bronze, 2=Silver, 3=Gold, 4=Platinum
        bool soulbound;
        bool progressive;
        uint32 earnedAt;
        uint256 progress;
        uint256 progressMax;
    }

    struct ImageConfig {
        string baseURI;
        bool useExternalImage;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS - ELEGANT COLOR PALETTE
    // ═══════════════════════════════════════════════════════════════════════════

    // Tier colors - refined metallic tones
    string private constant BRONZE_GRADIENT = "#B87333,#CD7F32,#DAA06D";
    string private constant SILVER_GRADIENT = "#A8A9AD,#C0C0C0,#E8E8E8";
    string private constant GOLD_GRADIENT = "#D4AF37,#FFD700,#F0E68C";
    string private constant PLATINUM_GRADIENT = "#E5E4E2,#B4C4D4,#A0B2C6";

    // ═══════════════════════════════════════════════════════════════════════════
    // MAIN GENERATION
    // ═══════════════════════════════════════════════════════════════════════════

    function generateHybridSVG(
        AchievementVisualData memory data,
        ImageConfig memory config
    ) internal pure returns (string memory) {
        string memory imageUrl = _buildImageUrl(data, config);

        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 400 400" width="400" height="400">',
            _buildDefs(data.tier),
            config.useExternalImage ? _buildBaseImageLayer(imageUrl) : _buildElegantFallback(data),
            _buildElegantOverlay(data),
            '</svg>'
        );
    }

    function generateOnChainSVG(AchievementVisualData memory data) internal pure returns (string memory) {
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400" width="400" height="400">',
            _buildDefs(data.tier),
            _buildElegantFallback(data),
            _buildElegantOverlay(data),
            '</svg>'
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // IMAGE URL
    // ═══════════════════════════════════════════════════════════════════════════

    function _buildImageUrl(
        AchievementVisualData memory data,
        ImageConfig memory config
    ) private pure returns (string memory) {
        if (!config.useExternalImage || bytes(config.baseURI).length == 0) {
            return "";
        }

        // Flat structure: baseUri/category_id-tier.png (e.g., "ipfs://.../combat_1-bronze.png")
        return string.concat(
            config.baseURI,
            getCategorySlug(data.category), "_",
            data.achievementId.toString(), "-",
            getTierSlug(data.tier), ".png"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEFS - ELEGANT GRADIENTS & FILTERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _buildDefs(uint8 tier) private pure returns (string memory) {
        (string memory c1, string memory c2, string memory c3) = _getTierGradientColors(tier);

        return string.concat(
            '<defs>',
            // Metallic tier gradient
            '<linearGradient id="tierMetal" x1="0%" y1="0%" x2="100%" y2="100%">',
            '<stop offset="0%" stop-color="', c1, '"/>',
            '<stop offset="50%" stop-color="', c2, '"/>',
            '<stop offset="100%" stop-color="', c3, '"/></linearGradient>',
            // Glass effect gradient
            '<linearGradient id="glass" x1="0%" y1="0%" x2="0%" y2="100%">',
            '<stop offset="0%" stop-color="white" stop-opacity="0.25"/>',
            '<stop offset="100%" stop-color="white" stop-opacity="0.05"/></linearGradient>',
            // Subtle shadow filter
            '<filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">',
            '<feDropShadow dx="0" dy="2" stdDeviation="3" flood-color="black" flood-opacity="0.6"/></filter>',
            // Top fade gradient - only top 15%
            '<linearGradient id="topFade" x1="0%" y1="100%" x2="0%" y2="0%">',
            '<stop offset="0%" stop-color="black" stop-opacity="0"/>',
            '<stop offset="85%" stop-color="black" stop-opacity="0"/>',
            '<stop offset="100%" stop-color="black" stop-opacity="0.4"/></linearGradient>',
            // Bottom fade gradient - only bottom 25%
            '<linearGradient id="bottomFade" x1="0%" y1="0%" x2="0%" y2="100%">',
            '<stop offset="0%" stop-color="black" stop-opacity="0"/>',
            '<stop offset="75%" stop-color="black" stop-opacity="0"/>',
            '<stop offset="100%" stop-color="black" stop-opacity="0.85"/></linearGradient>',
            '</defs>'
        );
    }

    function _getTierGradientColors(uint8 tier) private pure returns (string memory, string memory, string memory) {
        if (tier == 1) return ("#B87333", "#CD7F32", "#DAA06D");
        if (tier == 2) return ("#A8A9AD", "#C0C0C0", "#E8E8E8");
        if (tier == 3) return ("#D4AF37", "#FFD700", "#F0E68C");
        if (tier == 4) return ("#E5E4E2", "#B4C4D4", "#A0B2C6");
        return ("#808080", "#909090", "#A0A0A0");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BASE LAYERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _buildBaseImageLayer(string memory imageUrl) private pure returns (string memory) {
        if (bytes(imageUrl).length == 0) return "";

        return string.concat(
            '<image href="', imageUrl, '" x="0" y="0" width="400" height="400" preserveAspectRatio="xMidYMid slice"/>'
        );
    }

    function _buildElegantFallback(AchievementVisualData memory data) private pure returns (string memory) {
        (string memory c1, string memory c2, ) = _getTierGradientColors(data.tier);

        return string.concat(
            // Deep background
            '<rect width="400" height="400" fill="#0D1117"/>',
            // Subtle radial glow
            '<defs><radialGradient id="bgGlow" cx="50%" cy="40%" r="60%">',
            '<stop offset="0%" stop-color="', c2, '" stop-opacity="0.15"/>',
            '<stop offset="100%" stop-color="', c1, '" stop-opacity="0.02"/></radialGradient></defs>',
            '<rect width="400" height="400" fill="url(#bgGlow)"/>',
            // Elegant geometric pattern
            _buildGeometricPattern(c2),
            // Central emblem placeholder
            _buildCentralEmblem(data, c2)
        );
    }

    function _buildGeometricPattern(string memory color) private pure returns (string memory) {
        return string.concat(
            '<g opacity="0.08">',
            '<circle cx="200" cy="200" r="120" fill="none" stroke="', color, '" stroke-width="1"/>',
            '<circle cx="200" cy="200" r="100" fill="none" stroke="', color, '" stroke-width="0.5"/>',
            '<circle cx="200" cy="200" r="140" fill="none" stroke="', color, '" stroke-width="0.5"/>',
            '</g>'
        );
    }

    function _buildCentralEmblem(AchievementVisualData memory data, string memory color) private pure returns (string memory) {
        string memory icon = _getCategoryIcon(data.category);

        return string.concat(
            '<g transform="translate(200,180)" opacity="0.6">',
            '<circle cx="0" cy="0" r="50" fill="none" stroke="', color, '" stroke-width="2" opacity="0.3"/>',
            '<g transform="translate(-25,-25) scale(1.25)">', icon, '</g>',
            '</g>'
        );
    }

    function _getCategoryIcon(uint8 category) private pure returns (string memory) {
        // Elegant minimalist icons
        if (category == 1) { // Combat - sword
            return '<path d="M20,5 L25,40 L20,35 L15,40 Z M18,8 L22,8 L22,30 L18,30 Z" fill="currentColor" opacity="0.5"/>';
        } else if (category == 2) { // Territory - flag
            return '<path d="M15,5 L15,40 M15,5 L35,12 L15,20" fill="none" stroke="currentColor" stroke-width="2" opacity="0.5"/>';
        } else if (category == 3) { // Economic - diamond
            return '<path d="M20,8 L32,8 L40,18 L26,38 L12,18 Z" fill="none" stroke="currentColor" stroke-width="2" opacity="0.5"/>';
        } else if (category == 4) { // Collection - star
            return '<path d="M20,5 L23,15 L33,15 L25,22 L28,32 L20,26 L12,32 L15,22 L7,15 L17,15 Z" fill="currentColor" opacity="0.5"/>';
        } else if (category == 5) { // Social - people
            return '<circle cx="15" cy="15" r="6" fill="currentColor" opacity="0.5"/><circle cx="30" cy="15" r="6" fill="currentColor" opacity="0.5"/><path d="M8,35 Q15,25 22,35 M22,35 Q30,25 37,35" fill="none" stroke="currentColor" stroke-width="2" opacity="0.5"/>';
        } else if (category == 6) { // Special - crown
            return '<path d="M10,30 L15,15 L20,25 L25,10 L30,25 L35,15 L40,30 Z" fill="currentColor" opacity="0.5"/>';
        }
        return '<circle cx="20" cy="20" r="15" fill="none" stroke="currentColor" stroke-width="2" opacity="0.5"/>';
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ELEGANT OVERLAY
    // ═══════════════════════════════════════════════════════════════════════════

    function _buildElegantOverlay(AchievementVisualData memory data) private pure returns (string memory) {
        return string.concat(
            // Minimal fade gradients - only at edges (~15% coverage)
            '<rect x="0" y="0" width="400" height="400" fill="url(#topFade)"/>',
            '<rect x="0" y="0" width="400" height="400" fill="url(#bottomFade)"/>',
            // Tier badge (top right corner) - compact 64x32px
            _buildTierBadge(data.tier),
            // Soulbound lock (top left) - only if soulbound
            data.soulbound ? _buildSoulboundBadge() : "",
            // Progress ring (bottom left) - only if progressive
            data.progressive && data.progressMax > 0 ? _buildProgressRing(data.progress, data.progressMax, data.tier) : "",
            // Achievement name and date (bottom center)
            _buildNameAndDate(data.name, data.earnedAt)
        );
    }

    function _buildTierBadge(uint8 tier) private pure returns (string memory) {
        string memory tierName = getTierFullName(tier);
        // Platinum needs smaller font to fit
        string memory fontSize = tier == 4 ? "9" : "11";

        return string.concat(
            '<g transform="translate(355,40)" filter="url(#shadow)">',
            // Compact 64x32px pill badge with glass effect
            '<rect x="-32" y="-16" width="64" height="32" rx="16" fill="url(#tierMetal)"/>',
            '<rect x="-32" y="-16" width="64" height="16" rx="16" fill="url(#glass)"/>',
            // Tier text - dark for contrast
            '<text x="0" y="5" text-anchor="middle" fill="#1A1A2E" font-family="system-ui,-apple-system,sans-serif" font-size="', fontSize, '" font-weight="700" letter-spacing="0.5">', tierName, '</text>',
            '</g>'
        );
    }

    function _buildSoulboundBadge() private pure returns (string memory) {
        return string.concat(
            '<g transform="translate(40,40)" filter="url(#shadow)">',
            // Compact r=16px soulbound indicator
            '<circle r="16" fill="#1A1A2E" fill-opacity="0.9"/>',
            '<circle r="16" fill="none" stroke="#E53E3E" stroke-width="1.5"/>',
            // Lock icon - shackle and body
            '<path d="M-4,-2 L-4,-5 A4,4 0 1,1 4,-5 L4,-2" fill="none" stroke="#E53E3E" stroke-width="1.5" stroke-linecap="round"/>',
            '<rect x="-5" y="-2" width="10" height="8" rx="1.5" fill="#E53E3E"/>',
            '<circle cy="1.5" r="1.2" fill="#1A1A2E"/>',
            '</g>'
        );
    }

    function _buildNameAndDate(string memory name, uint32 earnedAt) private pure returns (string memory) {
        string memory earnedDate = earnedAt > 0 ? _formatDate(earnedAt) : "";

        return string.concat(
            // Achievement name - bottom center
            '<text x="200" y="365" text-anchor="middle" fill="white" font-family="system-ui,-apple-system,sans-serif" font-size="18" font-weight="600" letter-spacing="0.3" filter="url(#shadow)">', name, '</text>',
            // Earned date - below name, subtle
            bytes(earnedDate).length > 0
                ? string.concat('<text x="200" y="385" text-anchor="middle" fill="white" fill-opacity="0.5" font-family="system-ui,-apple-system,sans-serif" font-size="11">', earnedDate, '</text>')
                : ""
        );
    }

    function _buildProgressRing(uint256 progress, uint256 progressMax, uint8 tier) private pure returns (string memory) {
        uint256 percentage = progress >= progressMax ? 100 : (progress * 100) / progressMax;
        (,string memory c2,) = _getTierGradientColors(tier);
        // Circle circumference for r=18 is ~113, but using 85 for visual consistency with HTML preview

        return string.concat(
            '<g transform="translate(40,360)">',
            // Dark background circle r=22
            '<circle r="22" fill="#1A1A2E" fill-opacity="0.8"/>',
            // Background ring r=18
            '<circle r="18" fill="none" stroke="white" stroke-opacity="0.15" stroke-width="3"/>',
            // Progress ring r=18, dasharray=85 matches HTML preview
            '<circle r="18" fill="none" stroke="', c2, '" stroke-width="3" stroke-linecap="round" stroke-dasharray="85" stroke-dashoffset="', ((85 * (100 - percentage)) / 100).toString(), '" transform="rotate(-90)"/>',
            // Percentage text
            '<text y="4" text-anchor="middle" fill="white" font-family="system-ui,-apple-system,sans-serif" font-size="9" font-weight="600">', percentage.toString(), '%</text>',
            '</g>'
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // UTILITY FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function getTierSlug(uint8 tier) internal pure returns (string memory) {
        if (tier == 1) return "bronze";
        if (tier == 2) return "silver";
        if (tier == 3) return "gold";
        if (tier == 4) return "platinum";
        return "none";
    }

    function getCategorySlug(uint8 category) internal pure returns (string memory) {
        if (category == 1) return "combat";
        if (category == 2) return "territory";
        if (category == 3) return "economic";
        if (category == 4) return "collection";
        if (category == 5) return "social";
        if (category == 6) return "special";
        return "none";
    }

    function getTierFullName(uint8 tier) internal pure returns (string memory) {
        if (tier == 1) return "BRONZE";
        if (tier == 2) return "SILVER";
        if (tier == 3) return "GOLD";
        if (tier == 4) return "PLATINUM";
        return "---";
    }

    function _formatDate(uint32 timestamp) private pure returns (string memory) {
        if (timestamp == 0) return "";

        uint256 ts = uint256(timestamp);
        uint256 z = ts / 86400 + 719468;
        uint256 era = (z >= 0 ? z : z - 146096) / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 d = doy - (153 * mp + 2) / 5 + 1;
        uint256 m = mp < 10 ? mp + 3 : mp - 9;

        if (m <= 2) y += 1;

        string memory monthName = _getMonthName(m);

        return string.concat(
            monthName, " ", d.toString(), ", ", y.toString()
        );
    }

    function _getMonthName(uint256 month) private pure returns (string memory) {
        if (month == 1) return "Jan";
        if (month == 2) return "Feb";
        if (month == 3) return "Mar";
        if (month == 4) return "Apr";
        if (month == 5) return "May";
        if (month == 6) return "Jun";
        if (month == 7) return "Jul";
        if (month == 8) return "Aug";
        if (month == 9) return "Sep";
        if (month == 10) return "Oct";
        if (month == 11) return "Nov";
        if (month == 12) return "Dec";
        return "---";
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BASE64 ENCODING
    // ═══════════════════════════════════════════════════════════════════════════

    function generateHybridSVGBase64(
        AchievementVisualData memory data,
        ImageConfig memory config
    ) internal pure returns (string memory) {
        return Base64.encode(bytes(generateHybridSVG(data, config)));
    }

    function generateOnChainSVGBase64(AchievementVisualData memory data) internal pure returns (string memory) {
        return Base64.encode(bytes(generateOnChainSVG(data)));
    }
}
