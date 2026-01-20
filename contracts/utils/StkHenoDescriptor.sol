// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {IStkHenoDescriptor} from "../diamonds/staking/interfaces/IStkHenoDescriptor.sol";
import {StkHenoSVGBuilder} from "../diamonds/chargepod/libraries/StkHenoSVGBuilder.sol";

/**
 * @title StkHenoDescriptor
 * @notice Generates on-chain metadata and SVG for stkHENO receipt tokens
 * @dev External contract pattern - can be upgraded independently of main token contract
 *      Implements IStkHenoDescriptor interface
 * @author rutilicus.eth (ArchXS)
 */
contract StkHenoDescriptor is IStkHenoDescriptor {
    using Strings for uint256;
    using Strings for uint8;
    using Strings for address;

    // ============ CONSTANTS ============

    string private constant COLLECTION_NAME = "stkHENO - Staking Receipt Tokens";
    string private constant COLLECTION_DESCRIPTION =
        "Liquid Staking Derivatives for Henomorphs. Each stkHENO token represents a staked Henomorph NFT and can be freely traded. Transfer of stkHENO transfers ownership of the underlying staked position.";
    string private constant EXTERNAL_URL = "https://henomorphs.xyz";

    // ============ MAIN FUNCTIONS ============

    /**
     * @notice Generate complete tokenURI with embedded metadata and SVG
     * @param metadata Receipt token metadata
     * @return uri Data URI as data:application/json;base64,... string
     */
    function tokenURI(ReceiptMetadata memory metadata)
        external
        pure
        override
        returns (string memory uri)
    {
        string memory json = _buildJSON(metadata);
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        );
    }

    /**
     * @notice Generate SVG image for receipt token
     * @param metadata Receipt metadata
     * @return svg Complete SVG as string
     */
    function generateSVG(ReceiptMetadata memory metadata)
        external
        pure
        override
        returns (string memory svg)
    {
        uint256 totalRewards = metadata.accumulatedRewards + metadata.pendingRewards;

        StkHenoSVGBuilder.ReceiptVisualData memory visualData = StkHenoSVGBuilder.ReceiptVisualData({
            receiptId: metadata.receiptId,
            originalTokenId: metadata.originalTokenId,
            tier: metadata.tier,
            variant: metadata.variant,
            stakedAt: metadata.stakedAt,
            stakingDays: metadata.stakingDays,
            totalRewards: totalRewards,
            transferCount: metadata.transferCount,
            collectionId: metadata.collectionId,
            collectionAddress: metadata.collectionAddress,
            collectionName: metadata.collectionName,
            hasAugment: metadata.hasAugment,
            augmentVariant: metadata.augmentVariant
        });

        return StkHenoSVGBuilder.generateSVG(visualData);
    }

    /**
     * @notice Generate collection-level metadata (contractURI)
     * @return uri Data URI as data:application/json;base64,... string
     */
    function contractURI() external pure override returns (string memory uri) {
        string memory json = string.concat(
            '{"name":"', COLLECTION_NAME, '",',
            '"description":"', COLLECTION_DESCRIPTION, '",',
            '"image":"data:image/svg+xml;base64,', Base64.encode(bytes(_contractImage())), '",',
            '"external_link":"', EXTERNAL_URL, '",',
            '"seller_fee_basis_points":250,',
            '"fee_recipient":"0x0000000000000000000000000000000000000000"}'
        );

        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        );
    }

    // ============ JSON BUILDERS ============

    /**
     * @notice Build complete JSON metadata for a receipt token
     * @param m Receipt metadata
     * @return JSON string
     */
    function _buildJSON(ReceiptMetadata memory m) internal pure returns (string memory) {
        uint256 totalRewards = m.accumulatedRewards + m.pendingRewards;

        // Build SVG
        StkHenoSVGBuilder.ReceiptVisualData memory visualData = StkHenoSVGBuilder.ReceiptVisualData({
            receiptId: m.receiptId,
            originalTokenId: m.originalTokenId,
            tier: m.tier,
            variant: m.variant,
            stakedAt: m.stakedAt,
            stakingDays: m.stakingDays,
            totalRewards: totalRewards,
            transferCount: m.transferCount,
            collectionId: m.collectionId,
            collectionAddress: m.collectionAddress,
            collectionName: m.collectionName,
            hasAugment: m.hasAugment,
            augmentVariant: m.augmentVariant
        });

        string memory svg = StkHenoSVGBuilder.generateSVG(visualData);
        string memory svgBase64 = Base64.encode(bytes(svg));

        return string.concat(
            '{"name":"', _buildName(m.receiptId, m.tier, m.variant), '",',
            '"description":"', _buildDescription(m), '",',
            '"image":"data:image/svg+xml;base64,', svgBase64, '",',
            '"animation_url":"data:image/svg+xml;base64,', svgBase64, '",',
            '"external_url":"', EXTERNAL_URL, '/staking/', m.receiptId.toString(), '",',
            '"attributes":', _buildAttributes(m), '}'
        );
    }

    /**
     * @notice Build token name
     */
    function _buildName(uint256 receiptId, uint8 tier, uint8 variant) private pure returns (string memory) {
        return string.concat(
            "stkHENO #", receiptId.toString(),
            " | T", uint256(tier).toString(),
            " V", uint256(variant).toString()
        );
    }

    /**
     * @notice Build token description
     */
    function _buildDescription(ReceiptMetadata memory m) private pure returns (string memory) {
        string memory loyaltyTier = _getLoyaltyTierName(m.stakingDays);

        return string.concat(
            "Staking Receipt Token representing ", m.collectionName, " #", m.originalTokenId.toString(),
            ". This stkHENO token grants ownership of the underlying staked position. ",
            "Tier ", uint256(m.tier).toString(), " | Variant ", uint256(m.variant).toString(),
            " | ", loyaltyTier, " Status | ",
            m.stakingDays.toString(), " days staked. ",
            "Transferable - new owner receives all future staking rewards."
        );
    }

    /**
     * @notice Build attributes array for metadata
     */
    function _buildAttributes(ReceiptMetadata memory m) private pure returns (string memory) {
        string memory loyaltyTier = _getLoyaltyTierName(m.stakingDays);
        uint256 totalRewards = m.accumulatedRewards + m.pendingRewards;

        string memory attributes = string.concat(
            '[',
            _buildAttribute("Tier", uint256(m.tier).toString(), "number"),
            ',', _buildAttribute("Variant", uint256(m.variant).toString(), "number"),
            ',', _buildAttribute("Staking Days", m.stakingDays.toString(), "number"),
            ',', _buildAttribute("Loyalty Status", loyaltyTier, "string"),
            ',', _buildAttribute("Transfer Count", m.transferCount.toString(), "number"),
            ',', _buildAttribute("Original Token ID", m.originalTokenId.toString(), "number"),
            ',', _buildAttribute("Collection ID", m.collectionId.toString(), "number")
        );

        // Add rewards attributes
        attributes = string.concat(
            attributes,
            ',', _buildAttribute("Total Rewards", _formatEther(totalRewards), "number"),
            ',', _buildAttribute("Accumulated Rewards", _formatEther(m.accumulatedRewards), "number"),
            ',', _buildAttribute("Pending Rewards", _formatEther(m.pendingRewards), "number")
        );

        // Add augment if present
        if (m.hasAugment && m.augmentVariant > 0) {
            attributes = string.concat(
                attributes,
                ',', _buildAttribute("Has Augment", "true", "string"),
                ',', _buildAttribute("Augment Variant", uint256(m.augmentVariant).toString(), "number"),
                ',', _buildAttribute("Augment Type", _getAugmentName(m.augmentVariant), "string")
            );
        } else {
            attributes = string.concat(
                attributes,
                ',', _buildAttribute("Has Augment", "false", "string")
            );
        }

        // Add staker addresses
        attributes = string.concat(
            attributes,
            ',', _buildAttribute("Original Staker", Strings.toHexString(m.originalStaker), "string"),
            ',', _buildAttribute("Collection", m.collectionName, "string"),
            ',', _buildAttribute("Collection Address", Strings.toHexString(m.collectionAddress), "string"),
            ',', _buildAttribute("Staked At", uint256(m.stakedAt).toString(), "date")
        );

        return string.concat(attributes, ']');
    }

    /**
     * @notice Build single attribute object
     */
    function _buildAttribute(
        string memory traitType,
        string memory value,
        string memory displayType
    ) private pure returns (string memory) {
        if (keccak256(bytes(displayType)) == keccak256(bytes("number"))) {
            return string.concat(
                '{"trait_type":"', traitType, '","value":', value, ',"display_type":"number"}'
            );
        } else if (keccak256(bytes(displayType)) == keccak256(bytes("date"))) {
            return string.concat(
                '{"trait_type":"', traitType, '","value":', value, ',"display_type":"date"}'
            );
        } else {
            return string.concat(
                '{"trait_type":"', traitType, '","value":"', value, '"}'
            );
        }
    }

    // ============ HELPER FUNCTIONS ============

    function _getLoyaltyTierName(uint256 stakingDays) private pure returns (string memory) {
        if (stakingDays >= 365) return "Legendary";
        if (stakingDays >= 180) return "Diamond Hands";
        if (stakingDays >= 90) return "Committed";
        if (stakingDays >= 30) return "Active";
        return "New Staker";
    }

    function _getAugmentName(uint8 augmentVariant) private pure returns (string memory) {
        if (augmentVariant == 1) return "Power";
        if (augmentVariant == 2) return "Shield";
        if (augmentVariant == 3) return "Speed";
        if (augmentVariant == 4) return "Luck";
        return "Unknown";
    }

    function _formatEther(uint256 weiAmount) private pure returns (string memory) {
        uint256 whole = weiAmount / 1e18;
        uint256 fraction = (weiAmount % 1e18) / 1e16; // 2 decimal places

        if (fraction < 10) {
            return string.concat(whole.toString(), ".0", fraction.toString());
        }
        return string.concat(whole.toString(), ".", fraction.toString());
    }

    /**
     * @notice Generate simple contract-level image
     */
    function _contractImage() private pure returns (string memory) {
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400" width="400" height="400">',
            '<defs>',
            '<linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">',
            '<stop offset="0%" style="stop-color:#1a1a2e"/>',
            '<stop offset="100%" style="stop-color:#16213e"/></linearGradient>',
            '<radialGradient id="glow" cx="50%" cy="50%" r="50%">',
            '<stop offset="0%" style="stop-color:#00d9ff;stop-opacity:0.4"/>',
            '<stop offset="100%" style="stop-color:#00d9ff;stop-opacity:0"/></radialGradient>',
            '</defs>',
            '<rect width="100%" height="100%" fill="url(#bg)"/>',
            '<ellipse cx="200" cy="200" rx="150" ry="150" fill="url(#glow)"/>',
            '<circle cx="200" cy="200" r="80" fill="black" fill-opacity="0.4"/>',
            // Simplified chicken silhouette
            '<g transform="translate(200, 200)" fill="#ffeb3b">',
            '<ellipse cx="0" cy="10" rx="25" ry="30"/>',
            '<circle cx="0" cy="-20" r="22"/>',
            '<polygon points="0,-50 -5,-42 5,-42"/>',
            '<polygon points="-8,-48 -12,-40 -4,-40"/>',
            '<polygon points="8,-48 4,-40 12,-40"/>',
            '</g>',
            // Title
            '<text x="200" y="330" text-anchor="middle" font-family="monospace" font-size="28" font-weight="bold" fill="white">stkHENO</text>',
            '<text x="200" y="360" text-anchor="middle" font-family="monospace" font-size="12" fill="#00d9ff">Liquid Staking Receipts</text>',
            '</svg>'
        );
    }
}
