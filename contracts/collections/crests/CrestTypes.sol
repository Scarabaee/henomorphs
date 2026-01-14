// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title CrestTypes
 * @notice Shared type definitions for Henomorphs Colonial Crests collection
 * @dev Heraldic attributes for cyberpunk coat of arms NFTs
 * @author rutilicus.eth (ZicoDAO)
 */
library CrestTypes {

    // ============ ENUMS ============

    /// @notice Colony archetype - determines overall style and symbolism
    enum Archetype {
        Newborn,      // Default - new colonies (cyan, potential)
        Aggressive,   // High battle activity (crimson, warriors)
        Defensive,    // High defensive stake (steel blue, fortified)
        Wealthy,      // High earnings (gold, prosperity)
        Territorial,  // Many territories (green, expansion)
        Alliance,     // Alliance member (purple, unity)
        Veteran,      // Battle history (silver, experience)
        Elite         // Top performers (multi-spectrum, supreme)
    }

    /// @notice Shield shape - heraldic escutcheon type
    enum ShieldType {
        Heater,       // Classic medieval pointed shield
        Kite,         // Long Norman-style shield
        Round,        // Circular shield (buckler)
        Pavise,       // Large rectangular infantry shield
        Lozenge       // Diamond-shaped (traditionally feminine)
    }

    /// @notice Crown type above the shield
    enum Crown {
        None,         // No crown
        Coronet,      // Simple noble crown
        Laurel,       // Victory laurel wreath
        Imperial,     // Grand imperial crown
        Cyber         // Cybernetic halo/crown
    }

    /// @notice Beast pose - heraldic attitude of the cyber chick
    enum BeastPose {
        Rampant,      // Standing on hind legs, aggressive
        Guardian,     // Alert, watching, protective stance
        Vigilant,     // Head raised, watchful
        Combatant,    // Fighting pose, weapons ready
        Triumphant    // Victorious pose, wings spread
    }

    // ============ STRUCTS ============

    /// @notice Collection configuration
    struct Collection {
        uint256 id;
        string name;
        string description;
        string baseImageUri;
        string contractImageUrl;
        bool isMintable;
        bool isFixed;
    }

    /// @notice Heraldic attributes for a crest (immutable after mint)
    struct Heraldry {
        ShieldType shield;
        Crown crown;
        BeastPose pose;
    }

    /// @notice Individual crest token data (immutable after mint)
    struct CrestData {
        uint256 tokenId;
        bytes32 colonyId;
        string colonyName;
        address originalMinter;
        uint256 mintTimestamp;
        Archetype archetype;
        Heraldry heraldry;
    }

    /// @notice Colony stats snapshot used internally for attribute determination
    /// @dev Not stored - only used during mint to calculate attributes
    struct ColonySnapshot {
        bytes32 colonyId;
        string name;
        address creator;
        uint32 memberCount;
        uint256 score;
        uint256 territoriesControlled;
        uint256 battlesWon;
        uint256 battlesLost;
        uint256 defensiveStake;
        uint256 totalEarned;
        bool inAlliance;
        uint256 rank;
    }
}
