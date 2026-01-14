// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title LibAdoreChickenStorage
 * @notice Dedicated storage library for AdoreChickenLaska facet
 * @dev Centralized storage following Diamond Proxy pattern
 */
library LibAdoreChickenStorage {
    bytes32 constant ADORE_CHICKEN_STORAGE_POSITION = keccak256("henomorphs.adorechicken.storage.v1");

    // Affection types with different costs
    enum AffectionType {
        HUG,               // 1 ZICO - Warm embrace
        LOVE_DECLARATION,  // 2 ZICO - Verbal expression of love
        GENTLE_PET,        // 3 ZICO - Soft petting
        ADMIRE_BEAUTY,     // 4 ZICO - Admiring the chicken's beauty
        WHISPER_SWEET,     // 5 ZICO - Sweet whispers
        KISS               // 10 ZICO - Most expensive, gentle kiss
    }

    // Chicken reaction to affection
    enum ChickenMood {
        ECSTATIC,      // Over the moon
        HAPPY,         // Very pleased
        CONTENT,       // Satisfied
        BASHFUL,       // Shy but pleased
        CONFUSED,      // Not sure what happened
        INDIFFERENT    // Couldn't care less
    }

    struct AffectionEvent {
        address lover;              // Who gave the affection
        uint256 collectionId;       // Collection ID of the chicken
        uint256 tokenId;            // Token ID of the chicken
        AffectionType affectionType; // Type of affection
        ChickenMood mood;           // Chicken's reaction
        uint32 timestamp;           // When it happened
        string customMessage;       // Optional love message
    }

    struct ChickenAffectionStats {
        uint32 totalKisses;           // Total kisses received
        uint32 totalHugs;             // Total hugs received
        uint32 totalLoveDeclarations; // Total love declarations
        uint32 totalAffectionEvents;  // Total affection events
        uint32 lastAffectionTime;     // Last time affection was given
        address favoriteLover;         // Who loves this chicken most
        uint16 happinessLevel;         // Current happiness (0-100)
        uint8 affectionStreak;         // Days of consecutive affection
        uint32 dailyAffectionReceived; // Affection received today
        uint32 lastAffectionDay;       // Last day affection was received
    }

    struct PlayerAffectionProfile {
        uint32 totalAffectionGiven;   // Total affections given by player
        uint32 totalKissesGiven;      // Total kisses given
        uint32 totalHugsGiven;        // Total hugs given
        uint256 totalZicoSpent;       // Total ZICO spent on affection
        uint256 favoriteChickenCollection; // Player's most loved chicken collection
        uint256 favoriteChickenToken;      // Player's most loved chicken token
        uint32 lastAffectionTime;     // Last time player gave affection
        uint8 loveStreak;             // Consecutive days of loving
        uint32 dailyAffectionGiven;   // Affection given today
        uint32 lastAffectionDay;      // Last day affection was given
    }

    struct AdoreChickenConfig {
        uint256 hugCost;              // 1 ZICO
        uint256 loveDeclarationCost;  // 2 ZICO
        uint256 gentlePetCost;        // 3 ZICO
        uint256 admireBeautyCost;     // 4 ZICO
        uint256 whisperSweetCost;     // 5 ZICO
        uint256 kissCost;             // 10 ZICO
        uint32 maxAffectionPerDay;    // 10 per day limit per player
        uint32 maxAffectionPerChickenPerDay; // 20 per chicken per day
        uint32 happinessDecayTime;    // 24 hours
        uint32 maxCustomMessageLength; // 100 characters
        uint32 rateLimitCooldown;     // 60 seconds between actions
        bool initialized;
    }

    struct PlayerRanking {
        address player;
        uint32 totalKisses;
        uint32 totalHugs;
        uint256 totalSpent;
        uint32 rank;
    }

    struct ChickenRanking {
        uint256 collectionId;
        uint256 tokenId;
        uint32 totalAffectionReceived;
        uint16 happinessLevel;
        uint32 rank;
    }

    struct AdoreChickenStorage {
        // Configuration
        AdoreChickenConfig config;
        
        // Chicken affection data (using combined ID from collection + token)
        mapping(uint256 => ChickenAffectionStats) chickenStats; // combinedId => stats
        mapping(uint256 => AffectionEvent[]) chickenHistory;     // combinedId => events
        
        // Player data
        mapping(address => PlayerAffectionProfile) playerProfiles;
        mapping(address => mapping(uint256 => uint32)) playerChickenAffection; // player => combinedId => count
        
        // Global statistics
        uint256 totalAffectionEventsGlobal;
        uint256 totalKissesGlobal;
        uint256 totalHugsGlobal;
        uint256 totalZicoSpentGlobal;
        address mostLovingPlayer;
        uint256 mostLovedChickenCombinedId;
        
        // Rate limiting
        mapping(address => mapping(bytes4 => uint256)) lastActionTime;
        
        // Rankings
        address[] topLovers;                    // Top 50 lovers by total affection
        uint256[] topLovedChickens;            // Top 50 most loved chickens (combined IDs)
        mapping(address => uint32) playerRankings;    // player => rank position
        mapping(uint256 => uint32) chickenRankings;   // combinedId => rank position
        
        // Daily tracking for rate limiting
        mapping(address => uint32) playerDailyCount;
        mapping(address => uint32) playerLastAffectionDay;
        mapping(uint256 => uint32) chickenDailyCount;  // combinedId => daily count
        mapping(uint256 => uint32) chickenLastAffectionDay; // combinedId => last day
        
        // Storage version
        uint256 storageVersion;
    }

    function adoreChickenStorage() internal pure returns (AdoreChickenStorage storage acs) {
        bytes32 position = ADORE_CHICKEN_STORAGE_POSITION;
        assembly {
            acs.slot := position
        }
    }

    /**
     * @notice Initialize storage with default values
     */
    function initializeStorage() internal {
        AdoreChickenStorage storage acs = adoreChickenStorage();
        
        if (acs.config.initialized) {
            return; // Already initialized
        }
        
        // Set affection costs (in wei, 18 decimals)
        acs.config.hugCost = 1 ether;              // 1 ZICO
        acs.config.loveDeclarationCost = 2 ether;  // 2 ZICO
        acs.config.gentlePetCost = 3 ether;        // 3 ZICO
        acs.config.admireBeautyCost = 4 ether;     // 4 ZICO
        acs.config.whisperSweetCost = 5 ether;     // 5 ZICO
        acs.config.kissCost = 10 ether;            // 10 ZICO - Most expensive!
        
        // Set limits
        acs.config.maxAffectionPerDay = 10;        // Per player per day
        acs.config.maxAffectionPerChickenPerDay = 20; // Per chicken per day
        acs.config.happinessDecayTime = 86400;     // 24 hours
        acs.config.maxCustomMessageLength = 100;   // 100 characters
        acs.config.rateLimitCooldown = 60;         // 60 seconds between actions
        
        acs.config.initialized = true;
        acs.storageVersion = 1;
    }

    /**
     * @notice Get affection cost for specific type
     */
    function getAffectionCost(AffectionType affectionType) internal view returns (uint256) {
        AdoreChickenStorage storage acs = adoreChickenStorage();
        
        if (affectionType == AffectionType.HUG) return acs.config.hugCost;
        if (affectionType == AffectionType.LOVE_DECLARATION) return acs.config.loveDeclarationCost;
        if (affectionType == AffectionType.GENTLE_PET) return acs.config.gentlePetCost;
        if (affectionType == AffectionType.ADMIRE_BEAUTY) return acs.config.admireBeautyCost;
        if (affectionType == AffectionType.WHISPER_SWEET) return acs.config.whisperSweetCost;
        if (affectionType == AffectionType.KISS) return acs.config.kissCost;
        
        return 0;
    }

    /**
     * @notice Check rate limiting for user
     */
    function checkRateLimit(address user, bytes4 selector) internal returns (bool) {
        AdoreChickenStorage storage acs = adoreChickenStorage();
        
        if (block.timestamp < acs.lastActionTime[user][selector] + acs.config.rateLimitCooldown) {
            return false;
        }
        
        acs.lastActionTime[user][selector] = block.timestamp;
        return true;
    }

    /**
     * @notice Check daily affection limits
     */
    function checkDailyLimits(address user, uint256 combinedId) internal view returns (bool playerOk, bool chickenOk) {
        AdoreChickenStorage storage acs = adoreChickenStorage();
        uint32 currentDay = uint32(block.timestamp / 86400);
        
        // Check player daily limit
        if (acs.playerLastAffectionDay[user] == currentDay) {
            playerOk = acs.playerDailyCount[user] < acs.config.maxAffectionPerDay;
        } else {
            playerOk = true; // New day, reset
        }
        
        // Check chicken daily limit
        if (acs.chickenLastAffectionDay[combinedId] == currentDay) {
            chickenOk = acs.chickenDailyCount[combinedId] < acs.config.maxAffectionPerChickenPerDay;
        } else {
            chickenOk = true; // New day, reset
        }
        
        return (playerOk, chickenOk);
    }

    /**
     * @notice Update daily counters
     */
    function updateDailyCounters(address user, uint256 combinedId) internal {
        AdoreChickenStorage storage acs = adoreChickenStorage();
        uint32 currentDay = uint32(block.timestamp / 86400);
        
        // Update player counter
        if (acs.playerLastAffectionDay[user] != currentDay) {
            acs.playerDailyCount[user] = 1;
            acs.playerLastAffectionDay[user] = currentDay;
        } else {
            acs.playerDailyCount[user]++;
        }
        
        // Update chicken counter
        if (acs.chickenLastAffectionDay[combinedId] != currentDay) {
            acs.chickenDailyCount[combinedId] = 1;
            acs.chickenLastAffectionDay[combinedId] = currentDay;
        } else {
            acs.chickenDailyCount[combinedId]++;
        }
    }

    /**
     * @notice Generate chicken mood based on affection type and randomness
     */
    function generateChickenMood(AffectionType affectionType, uint256 combinedId) internal view returns (ChickenMood) {
        // Create pseudo-random number based on block data and chicken ID
        uint256 randomness = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            combinedId,
            uint8(affectionType)
        ))) % 100;
        
        // More expensive affection = better mood probability
        if (affectionType == AffectionType.KISS) {
            // Kiss: 60% ecstatic, 30% happy, 10% bashful
            if (randomness < 60) return ChickenMood.ECSTATIC;
            if (randomness < 90) return ChickenMood.HAPPY;
            return ChickenMood.BASHFUL;
        } else if (affectionType == AffectionType.WHISPER_SWEET) {
            // Whisper: 40% ecstatic, 40% happy, 15% bashful, 5% content
            if (randomness < 40) return ChickenMood.ECSTATIC;
            if (randomness < 80) return ChickenMood.HAPPY;
            if (randomness < 95) return ChickenMood.BASHFUL;
            return ChickenMood.CONTENT;
        } else if (affectionType == AffectionType.ADMIRE_BEAUTY) {
            // Admire: 30% ecstatic, 40% happy, 20% bashful, 10% content
            if (randomness < 30) return ChickenMood.ECSTATIC;
            if (randomness < 70) return ChickenMood.HAPPY;
            if (randomness < 90) return ChickenMood.BASHFUL;
            return ChickenMood.CONTENT;
        } else if (affectionType == AffectionType.GENTLE_PET) {
            // Pet: 20% ecstatic, 40% happy, 25% content, 10% bashful, 5% confused
            if (randomness < 20) return ChickenMood.ECSTATIC;
            if (randomness < 60) return ChickenMood.HAPPY;
            if (randomness < 85) return ChickenMood.CONTENT;
            if (randomness < 95) return ChickenMood.BASHFUL;
            return ChickenMood.CONFUSED;
        } else if (affectionType == AffectionType.LOVE_DECLARATION) {
            // Love: 25% ecstatic, 35% happy, 20% bashful, 15% content, 5% confused
            if (randomness < 25) return ChickenMood.ECSTATIC;
            if (randomness < 60) return ChickenMood.HAPPY;
            if (randomness < 80) return ChickenMood.BASHFUL;
            if (randomness < 95) return ChickenMood.CONTENT;
            return ChickenMood.CONFUSED;
        } else { // HUG
            // Hug: 15% ecstatic, 35% happy, 30% content, 15% bashful, 5% indifferent
            if (randomness < 15) return ChickenMood.ECSTATIC;
            if (randomness < 50) return ChickenMood.HAPPY;
            if (randomness < 80) return ChickenMood.CONTENT;
            if (randomness < 95) return ChickenMood.BASHFUL;
            return ChickenMood.INDIFFERENT;
        }
    }

    /**
     * @notice Calculate happiness boost from mood
     */
    function getHappinessBoost(ChickenMood mood) internal pure returns (uint16) {
        if (mood == ChickenMood.ECSTATIC) return 20;
        if (mood == ChickenMood.HAPPY) return 15;
        if (mood == ChickenMood.CONTENT) return 10;
        if (mood == ChickenMood.BASHFUL) return 8;
        if (mood == ChickenMood.CONFUSED) return 3;
        return 1; // INDIFFERENT
    }

    /**
     * @notice Combine collection and token ID into single identifier
     */
    function combineIds(uint256 collectionId, uint256 tokenId) internal pure returns (uint256) {
        return (collectionId << 128) | tokenId;
    }

    /**
     * @notice Split combined ID back into collection and token ID
     */
    function splitCombinedId(uint256 combinedId) internal pure returns (uint256 collectionId, uint256 tokenId) {
        collectionId = combinedId >> 128;
        tokenId = combinedId & ((1 << 128) - 1);
    }

    /**
     * @notice Update global rankings (called after affection events)
     * @dev Maintains sorted rankings by inserting/moving entries to correct position
     */
    function updateRankings(address player, uint256 combinedId) internal {
        AdoreChickenStorage storage acs = adoreChickenStorage();

        _updatePlayerRanking(acs, player);
        _updateChickenRanking(acs, combinedId);
    }

    /**
     * @notice Update player ranking with proper sorting
     */
    function _updatePlayerRanking(AdoreChickenStorage storage acs, address player) private {
        uint32 playerScore = acs.playerProfiles[player].totalAffectionGiven;
        uint256 currentIndex = type(uint256).max;

        // Find current position of player
        for (uint256 i = 0; i < acs.topLovers.length; i++) {
            if (acs.topLovers[i] == player) {
                currentIndex = i;
                break;
            }
        }

        // If player not in list, try to add them
        if (currentIndex == type(uint256).max) {
            if (acs.topLovers.length < 50) {
                // List not full, add player
                acs.topLovers.push(player);
                currentIndex = acs.topLovers.length - 1;
            } else {
                // List full, check if player beats last entry
                address lastPlayer = acs.topLovers[49];
                if (playerScore > acs.playerProfiles[lastPlayer].totalAffectionGiven) {
                    acs.topLovers[49] = player;
                    acs.playerRankings[lastPlayer] = 0; // Remove old player's rank
                    currentIndex = 49;
                } else {
                    return; // Player doesn't make it into top 50
                }
            }
        }

        // Bubble up to correct position (higher score = lower index)
        while (currentIndex > 0) {
            address abovePlayer = acs.topLovers[currentIndex - 1];
            uint32 aboveScore = acs.playerProfiles[abovePlayer].totalAffectionGiven;

            if (playerScore > aboveScore) {
                // Swap positions
                acs.topLovers[currentIndex] = abovePlayer;
                acs.topLovers[currentIndex - 1] = player;
                acs.playerRankings[abovePlayer] = uint32(currentIndex + 1);
                currentIndex--;
            } else {
                break;
            }
        }

        // Update player's rank (1-indexed)
        acs.playerRankings[player] = uint32(currentIndex + 1);
    }

    /**
     * @notice Update chicken ranking with proper sorting
     */
    function _updateChickenRanking(AdoreChickenStorage storage acs, uint256 combinedId) private {
        uint32 chickenScore = acs.chickenStats[combinedId].totalAffectionEvents;
        uint256 currentIndex = type(uint256).max;

        // Find current position of chicken
        for (uint256 i = 0; i < acs.topLovedChickens.length; i++) {
            if (acs.topLovedChickens[i] == combinedId) {
                currentIndex = i;
                break;
            }
        }

        // If chicken not in list, try to add them
        if (currentIndex == type(uint256).max) {
            if (acs.topLovedChickens.length < 50) {
                // List not full, add chicken
                acs.topLovedChickens.push(combinedId);
                currentIndex = acs.topLovedChickens.length - 1;
            } else {
                // List full, check if chicken beats last entry
                uint256 lastChicken = acs.topLovedChickens[49];
                if (chickenScore > acs.chickenStats[lastChicken].totalAffectionEvents) {
                    acs.topLovedChickens[49] = combinedId;
                    acs.chickenRankings[lastChicken] = 0; // Remove old chicken's rank
                    currentIndex = 49;
                } else {
                    return; // Chicken doesn't make it into top 50
                }
            }
        }

        // Bubble up to correct position (higher score = lower index)
        while (currentIndex > 0) {
            uint256 aboveChicken = acs.topLovedChickens[currentIndex - 1];
            uint32 aboveScore = acs.chickenStats[aboveChicken].totalAffectionEvents;

            if (chickenScore > aboveScore) {
                // Swap positions
                acs.topLovedChickens[currentIndex] = aboveChicken;
                acs.topLovedChickens[currentIndex - 1] = combinedId;
                acs.chickenRankings[aboveChicken] = uint32(currentIndex + 1);
                currentIndex--;
            } else {
                break;
            }
        }

        // Update chicken's rank (1-indexed)
        acs.chickenRankings[combinedId] = uint32(currentIndex + 1);
    }
}