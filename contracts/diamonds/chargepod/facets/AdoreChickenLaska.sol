// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibAdoreChickenStorage} from "../libraries/LibAdoreChickenStorage.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {PodsUtils} from "../../libraries/PodsUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {SpecimenCollection} from "../../libraries/HenomorphsModel.sol";
import {IExternalCollection} from "../interfaces/IStakingInterfaces.sol";

/**
 * @title AdoreChickenLaska
 * @notice A whimsical facet for expressing affection towards chickens (Henomorphs)
 * @dev Allows players to kiss, hug, and declare love for their chickens with various effects
 */
contract AdoreChickenLaska is AccessControlBase {
    using LibAdoreChickenStorage for LibAdoreChickenStorage.AdoreChickenStorage;

    // Events
    event ChickenKissed(
        uint256 indexed collectionId, 
        uint256 indexed tokenId, 
        address indexed lover, 
        LibAdoreChickenStorage.ChickenMood mood, 
        string message
    );
    event ChickenHugged(
        uint256 indexed collectionId, 
        uint256 indexed tokenId, 
        address indexed lover, 
        LibAdoreChickenStorage.ChickenMood mood, 
        string message
    );
    event LoveDeclared(
        uint256 indexed collectionId, 
        uint256 indexed tokenId, 
        address indexed lover, 
        LibAdoreChickenStorage.ChickenMood mood, 
        string message
    );
    event ChickenPetted(
        uint256 indexed collectionId, 
        uint256 indexed tokenId, 
        address indexed lover, 
        LibAdoreChickenStorage.ChickenMood mood, 
        string message
    );
    event ChickenAdmired(
        uint256 indexed collectionId, 
        uint256 indexed tokenId, 
        address indexed lover, 
        LibAdoreChickenStorage.ChickenMood mood, 
        string message
    );
    event SweetWhispered(
        uint256 indexed collectionId, 
        uint256 indexed tokenId, 
        address indexed lover, 
        LibAdoreChickenStorage.ChickenMood mood, 
        string message
    );
    event ChickenHappinessChanged(
        uint256 indexed collectionId,
        uint256 indexed tokenId,
        uint16 newHappiness,
        address lover
    );
    event FavoriteLoverChanged(
        uint256 indexed collectionId,
        uint256 indexed tokenId,
        address newFavoriteLover,
        address previousLover
    );
    event AffectionStreakAchieved(
        address indexed lover,
        uint8 streakDays,
        uint256 bonusReward
    );

    // Custom errors
    error ChickenNotFound(uint256 collectionId, uint256 tokenId);
    error NotChickenOwner(uint256 collectionId, uint256 tokenId);
    error AffectionRateLimitExceeded();
    error DailyAffectionLimitExceeded();
    error ChickenDailyLimitExceeded();
    error InvalidAffectionType();
    error MessageTooLong(uint256 length, uint256 maxLength);
    error InvalidCollectionId(uint256 collectionId);
    error InsufficientPayment(uint256 required, uint256 provided);

    /**
     * @notice Kiss a chicken (most expensive affection - 10 ZICO)
     * @param collectionId Collection ID of the chicken
     * @param tokenId Token ID of the chicken
     * @param message Optional love message (max 100 chars)
     */
    function kissChicken(
        uint256 collectionId,
        uint256 tokenId,
        string calldata message
    ) external whenNotPaused nonReentrant {
        _performAffection(
            collectionId,
            tokenId,
            LibAdoreChickenStorage.AffectionType.KISS,
            message,
            msg.sig
        );
    }

    /**
     * @notice Hug a chicken (cheapest affection - 1 ZICO)
     * @param collectionId Collection ID of the chicken
     * @param tokenId Token ID of the chicken
     * @param message Optional love message (max 100 chars)
     */
    function hugChicken(
        uint256 collectionId,
        uint256 tokenId,
        string calldata message
    ) external whenNotPaused nonReentrant {
        _performAffection(
            collectionId,
            tokenId,
            LibAdoreChickenStorage.AffectionType.HUG,
            message,
            msg.sig
        );
    }

    /**
     * @notice Declare love to a chicken (2 ZICO)
     * @param collectionId Collection ID of the chicken
     * @param tokenId Token ID of the chicken
     * @param message Optional love message (max 100 chars)
     */
    function declareLove(
        uint256 collectionId,
        uint256 tokenId,
        string calldata message
    ) external whenNotPaused nonReentrant {
        _performAffection(
            collectionId,
            tokenId,
            LibAdoreChickenStorage.AffectionType.LOVE_DECLARATION,
            message,
            msg.sig
        );
    }

    /**
     * @notice Gently pet a chicken (3 ZICO)
     * @param collectionId Collection ID of the chicken
     * @param tokenId Token ID of the chicken
     * @param message Optional love message (max 100 chars)
     */
    function petChicken(
        uint256 collectionId,
        uint256 tokenId,
        string calldata message
    ) external whenNotPaused nonReentrant {
        _performAffection(
            collectionId,
            tokenId,
            LibAdoreChickenStorage.AffectionType.GENTLE_PET,
            message,
            msg.sig
        );
    }

    /**
     * @notice Admire chicken's beauty (4 ZICO)
     * @param collectionId Collection ID of the chicken
     * @param tokenId Token ID of the chicken
     * @param message Optional love message (max 100 chars)
     */
    function admireChicken(
        uint256 collectionId,
        uint256 tokenId,
        string calldata message
    ) external whenNotPaused nonReentrant {
        _performAffection(
            collectionId,
            tokenId,
            LibAdoreChickenStorage.AffectionType.ADMIRE_BEAUTY,
            message,
            msg.sig
        );
    }

    /**
     * @notice Whisper sweet things to a chicken (5 ZICO)
     * @param collectionId Collection ID of the chicken
     * @param tokenId Token ID of the chicken
     * @param message Optional love message (max 100 chars)
     */
    function whisperSweet(
        uint256 collectionId,
        uint256 tokenId,
        string calldata message
    ) external whenNotPaused nonReentrant {
        _performAffection(
            collectionId,
            tokenId,
            LibAdoreChickenStorage.AffectionType.WHISPER_SWEET,
            message,
            msg.sig
        );
    }

    /**
     * @notice Internal function to perform affection with all validations
     */
    function _performAffection(
        uint256 collectionId,
        uint256 tokenId,
        LibAdoreChickenStorage.AffectionType affectionType,
        string calldata message,
        bytes4 functionSelector 
    ) internal {
        LibAdoreChickenStorage.initializeStorage();
        LibAdoreChickenStorage.AdoreChickenStorage storage acs = LibAdoreChickenStorage.adoreChickenStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        // Validate message length
        if (bytes(message).length > acs.config.maxCustomMessageLength) {
            revert MessageTooLong(bytes(message).length, acs.config.maxCustomMessageLength);
        }

        // Rate limiting
        if (!LibAdoreChickenStorage.checkRateLimit(LibMeta.msgSender(), functionSelector)) {
            revert AffectionRateLimitExceeded();
        }

        if (!_validateToken(collectionId, tokenId)) {
            revert ChickenNotFound(collectionId, tokenId);
        }

        // Create combined ID
        uint256 combinedId = LibAdoreChickenStorage.combineIds(collectionId, tokenId);

        // Check daily limits
        (bool playerOk, bool chickenOk) = LibAdoreChickenStorage.checkDailyLimits(LibMeta.msgSender(), combinedId);
        if (!playerOk) {
            revert DailyAffectionLimitExceeded();
        }
        if (!chickenOk) {
            revert ChickenDailyLimitExceeded();
        }

        // Get affection cost and collect payment
        uint256 cost = LibAdoreChickenStorage.getAffectionCost(affectionType);
        address currency = hs.chargeTreasury.treasuryCurrency;
        
        LibFeeCollection.collectFee(
            IERC20(currency),
            LibMeta.msgSender(),
            hs.chargeTreasury.treasuryAddress,
            cost,
            "chicken_affection"
        );

        // Generate chicken's mood reaction
        LibAdoreChickenStorage.ChickenMood mood = LibAdoreChickenStorage.generateChickenMood(affectionType, combinedId);

        // Update chicken stats
        LibAdoreChickenStorage.ChickenAffectionStats storage chickenStats = acs.chickenStats[combinedId];
        _updateChickenStats(chickenStats, affectionType, mood, LibMeta.msgSender());

        // Update player stats
        LibAdoreChickenStorage.PlayerAffectionProfile storage playerProfile = acs.playerProfiles[LibMeta.msgSender()];
        _updatePlayerStats(playerProfile, affectionType, cost, collectionId, tokenId);

        // Update daily counters
        LibAdoreChickenStorage.updateDailyCounters(LibMeta.msgSender(), combinedId);

        // Update global stats
        _updateGlobalStats(acs, affectionType, cost);

        // Record affection event
        LibAdoreChickenStorage.AffectionEvent memory affectionEvent = LibAdoreChickenStorage.AffectionEvent({
            lover: LibMeta.msgSender(),
            collectionId: collectionId,
            tokenId: tokenId,
            affectionType: affectionType,
            mood: mood,
            timestamp: uint32(block.timestamp),
            customMessage: message
        });

        acs.chickenHistory[combinedId].push(affectionEvent);

        // Update rankings
        LibAdoreChickenStorage.updateRankings(LibMeta.msgSender(), combinedId);

        // Check and update favorite lover
        _checkFavoriteLover(chickenStats, LibMeta.msgSender(), combinedId, collectionId, tokenId);

        // Check love streak bonus
        _checkLoveStreak(playerProfile, LibMeta.msgSender());

        // Emit appropriate event
        _emitAffectionEvent(affectionType, collectionId, tokenId, LibMeta.msgSender(), mood, message);
    }

    /**
     * @notice Update chicken affection stats
     */
    function _updateChickenStats(
        LibAdoreChickenStorage.ChickenAffectionStats storage stats,
        LibAdoreChickenStorage.AffectionType affectionType,
        LibAdoreChickenStorage.ChickenMood mood,
        address lover
    ) internal {
        // Update type-specific counters
        if (affectionType == LibAdoreChickenStorage.AffectionType.KISS) {
            stats.totalKisses++;
        } else if (affectionType == LibAdoreChickenStorage.AffectionType.HUG) {
            stats.totalHugs++;
        } else if (affectionType == LibAdoreChickenStorage.AffectionType.LOVE_DECLARATION) {
            stats.totalLoveDeclarations++;
        }

        stats.totalAffectionEvents++;
        stats.lastAffectionTime = uint32(block.timestamp);

        // Update happiness based on mood
        uint16 happinessBoost = LibAdoreChickenStorage.getHappinessBoost(mood);
        uint16 newHappiness = stats.happinessLevel + happinessBoost;
        if (newHappiness > 100) {
            newHappiness = 100;
        }
        
        if (newHappiness != stats.happinessLevel) {
            stats.happinessLevel = newHappiness;
            emit ChickenHappinessChanged(0, 0, newHappiness, lover); // Will be filled by caller
        }

        // Update affection streak
        uint32 currentDay = uint32(block.timestamp / 86400);
        if (stats.lastAffectionDay == currentDay - 1) {
            stats.affectionStreak++;
        } else if (stats.lastAffectionDay != currentDay) {
            stats.affectionStreak = 1; // Reset streak
        }
        stats.lastAffectionDay = currentDay;
    }

    /**
     * @notice Update player affection stats
     */
    function _updatePlayerStats(
        LibAdoreChickenStorage.PlayerAffectionProfile storage profile,
        LibAdoreChickenStorage.AffectionType affectionType,
        uint256 cost,
        uint256 collectionId,
        uint256 tokenId
    ) internal {
        // Update type-specific counters
        if (affectionType == LibAdoreChickenStorage.AffectionType.KISS) {
            profile.totalKissesGiven++;
        } else if (affectionType == LibAdoreChickenStorage.AffectionType.HUG) {
            profile.totalHugsGiven++;
        }

        profile.totalAffectionGiven++;
        profile.totalZicoSpent += cost;
        profile.lastAffectionTime = uint32(block.timestamp);
        profile.favoriteChickenCollection = collectionId;
        profile.favoriteChickenToken = tokenId;

        // Update love streak
        uint32 currentDay = uint32(block.timestamp / 86400);
        if (profile.lastAffectionDay == currentDay - 1) {
            profile.loveStreak++;
        } else if (profile.lastAffectionDay != currentDay) {
            profile.loveStreak = 1; // Reset streak
        }
        profile.lastAffectionDay = currentDay;
    }

    /**
     * @notice Update global statistics
     */
    function _updateGlobalStats(
        LibAdoreChickenStorage.AdoreChickenStorage storage acs,
        LibAdoreChickenStorage.AffectionType affectionType,
        uint256 cost
    ) internal {
        acs.totalAffectionEventsGlobal++;
        acs.totalZicoSpentGlobal += cost;

        if (affectionType == LibAdoreChickenStorage.AffectionType.KISS) {
            acs.totalKissesGlobal++;
        } else if (affectionType == LibAdoreChickenStorage.AffectionType.HUG) {
            acs.totalHugsGlobal++;
        }

        // Update most loving player
        LibAdoreChickenStorage.PlayerAffectionProfile storage senderProfile = acs.playerProfiles[LibMeta.msgSender()];
        LibAdoreChickenStorage.PlayerAffectionProfile storage currentMostLoving = acs.playerProfiles[acs.mostLovingPlayer];
        
        if (senderProfile.totalAffectionGiven > currentMostLoving.totalAffectionGiven) {
            acs.mostLovingPlayer = LibMeta.msgSender();
        }
    }

    /**
     * @notice Check and update favorite lover for chicken
     */
    function _checkFavoriteLover(
        LibAdoreChickenStorage.ChickenAffectionStats storage chickenStats,
        address currentLover,
        uint256 combinedId,
        uint256 collectionId,
        uint256 tokenId
    ) internal {
        LibAdoreChickenStorage.AdoreChickenStorage storage acs = LibAdoreChickenStorage.adoreChickenStorage();
        
        uint32 currentLoverCount = acs.playerChickenAffection[currentLover][combinedId];
        uint32 favoriteLoverCount = acs.playerChickenAffection[chickenStats.favoriteLover][combinedId];
        
        acs.playerChickenAffection[currentLover][combinedId]++;
        
        if (currentLoverCount + 1 > favoriteLoverCount) {
            address previousFavorite = chickenStats.favoriteLover;
            chickenStats.favoriteLover = currentLover;
            
            emit FavoriteLoverChanged(collectionId, tokenId, currentLover, previousFavorite);
        }

        // Update most loved chicken globally
        if (chickenStats.totalAffectionEvents > acs.chickenStats[acs.mostLovedChickenCombinedId].totalAffectionEvents) {
            acs.mostLovedChickenCombinedId = combinedId;
        }
    }

    /**
     * @notice Check love streak bonus
     */
    function _checkLoveStreak(
        LibAdoreChickenStorage.PlayerAffectionProfile storage profile,
        address lover
    ) internal {
        if (profile.loveStreak > 0 && profile.loveStreak % 7 == 0) {
            uint256 bonusReward = profile.loveStreak * 1 ether;
            
            // Check if treasury has sufficient balance before attempting transfer
            LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
            IERC20 currency = IERC20(hs.chargeTreasury.treasuryCurrency);
            address treasuryAddress = hs.chargeTreasury.treasuryAddress;
            
            uint256 treasuryBalance = currency.balanceOf(treasuryAddress);
            
            // Only attempt transfer if treasury has enough funds
            if (treasuryBalance >= bonusReward) {
                LibFeeCollection.transferFromTreasury(lover, bonusReward, "love_streak_bonus");
                emit AffectionStreakAchieved(lover, profile.loveStreak, bonusReward);
            }
            // If insufficient funds, user still keeps their streak
            // Bonus will be attempted at next milestone when treasury is refilled
        }
    }

    /**
     * @notice Emit appropriate affection event
     */
    function _emitAffectionEvent(
        LibAdoreChickenStorage.AffectionType affectionType,
        uint256 collectionId,
        uint256 tokenId,
        address lover,
        LibAdoreChickenStorage.ChickenMood mood,
        string calldata message
    ) internal {
        if (affectionType == LibAdoreChickenStorage.AffectionType.KISS) {
            emit ChickenKissed(collectionId, tokenId, lover, mood, message);
        } else if (affectionType == LibAdoreChickenStorage.AffectionType.HUG) {
            emit ChickenHugged(collectionId, tokenId, lover, mood, message);
        } else if (affectionType == LibAdoreChickenStorage.AffectionType.LOVE_DECLARATION) {
            emit LoveDeclared(collectionId, tokenId, lover, mood, message);
        } else if (affectionType == LibAdoreChickenStorage.AffectionType.GENTLE_PET) {
            emit ChickenPetted(collectionId, tokenId, lover, mood, message);
        } else if (affectionType == LibAdoreChickenStorage.AffectionType.ADMIRE_BEAUTY) {
            emit ChickenAdmired(collectionId, tokenId, lover, mood, message);
        } else if (affectionType == LibAdoreChickenStorage.AffectionType.WHISPER_SWEET) {
            emit SweetWhispered(collectionId, tokenId, lover, mood, message);
        }
    }

    // View functions

    /**
     * @notice Get chicken affection statistics
     * @param collectionId Collection ID of the chicken
     * @param tokenId Token ID of the chicken
     * @return stats Complete affection statistics for the chicken
     */
    function getChickenAffectionStats(uint256 collectionId, uint256 tokenId)
        external
        view
        returns (LibAdoreChickenStorage.ChickenAffectionStats memory stats)
    {
        uint256 combinedId = LibAdoreChickenStorage.combineIds(collectionId, tokenId);
        return LibAdoreChickenStorage.adoreChickenStorage().chickenStats[combinedId];
    }

    /**
     * @notice Get player affection profile
     * @param player Player address
     * @return profile Complete affection profile for the player
     */
    function getPlayerAffectionProfile(address player)
        external
        view
        returns (LibAdoreChickenStorage.PlayerAffectionProfile memory profile)
    {
        return LibAdoreChickenStorage.adoreChickenStorage().playerProfiles[player];
    }

    /**
     * @notice Get chicken affection history
     * @param collectionId Collection ID of the chicken
     * @param tokenId Token ID of the chicken
     * @param limit Maximum number of events to return (0 = all)
     * @return events Array of affection events
     */
    function getChickenAffectionHistory(uint256 collectionId, uint256 tokenId, uint256 limit)
        external
        view
        returns (LibAdoreChickenStorage.AffectionEvent[] memory events)
    {
        uint256 combinedId = LibAdoreChickenStorage.combineIds(collectionId, tokenId);
        LibAdoreChickenStorage.AffectionEvent[] storage allEvents = LibAdoreChickenStorage.adoreChickenStorage().chickenHistory[combinedId];
        
        uint256 totalEvents = allEvents.length;
        if (limit == 0 || limit > totalEvents) {
            limit = totalEvents;
        }
        
        events = new LibAdoreChickenStorage.AffectionEvent[](limit);
        
        // Return most recent events first
        for (uint256 i = 0; i < limit; i++) {
            events[i] = allEvents[totalEvents - 1 - i];
        }
        
        return events;
    }

    /**
     * @notice Get affection cost for specific type
     * @param affectionType Type of affection
     * @return cost Cost in ZICO (with 18 decimals)
     */
    function getAffectionCost(LibAdoreChickenStorage.AffectionType affectionType)
        external
        view
        returns (uint256 cost)
    {
        return LibAdoreChickenStorage.getAffectionCost(affectionType);
    }

    /**
     * @notice Get all affection costs
     * @return hugCost Cost to hug (1 ZICO)
     * @return loveCost Cost to declare love (2 ZICO)
     * @return petCost Cost to pet (3 ZICO)
     * @return admireCost Cost to admire (4 ZICO)
     * @return whisperCost Cost to whisper (5 ZICO)
     * @return kissCost Cost to kiss (10 ZICO)
     */
    function getAllAffectionCosts()
        external
        view
        returns (
            uint256 hugCost,
            uint256 loveCost,
            uint256 petCost,
            uint256 admireCost,
            uint256 whisperCost,
            uint256 kissCost
        )
    {
        LibAdoreChickenStorage.AdoreChickenConfig storage config = LibAdoreChickenStorage.adoreChickenStorage().config;
        return (
            config.hugCost,
            config.loveDeclarationCost,
            config.gentlePetCost,
            config.admireBeautyCost,
            config.whisperSweetCost,
            config.kissCost
        );
    }

    /**
     * @notice Get global affection statistics
     * @return totalEvents Total affection events globally
     * @return totalKisses Total kisses globally
     * @return totalHugs Total hugs globally
     * @return totalSpent Total ZICO spent globally
     * @return mostLovingPlayer Address of most loving player
     * @return mostLovedChickenCollection Collection of most loved chicken
     * @return mostLovedChickenToken Token of most loved chicken
     */
    function getGlobalAffectionStats()
        external
        view
        returns (
            uint256 totalEvents,
            uint256 totalKisses,
            uint256 totalHugs,
            uint256 totalSpent,
            address mostLovingPlayer,
            uint256 mostLovedChickenCollection,
            uint256 mostLovedChickenToken
        )
    {
        LibAdoreChickenStorage.AdoreChickenStorage storage acs = LibAdoreChickenStorage.adoreChickenStorage();
        
        (uint256 collectionId, uint256 tokenId) = LibAdoreChickenStorage.splitCombinedId(acs.mostLovedChickenCombinedId);
        
        return (
            acs.totalAffectionEventsGlobal,
            acs.totalKissesGlobal,
            acs.totalHugsGlobal,
            acs.totalZicoSpentGlobal,
            acs.mostLovingPlayer,
            collectionId,
            tokenId
        );
    }

    /**
     * @notice Get top lovers leaderboard (sorted by total affection given)
     * @param limit Maximum number of players to return
     * @return players Array of top loving players (sorted by rank)
     * @return affectionCounts Array of total affection given by each player
     * @return spentAmounts Array of total ZICO spent by each player
     * @return ranks Array of rank positions (1-indexed)
     */
    function getTopLovers(uint256 limit)
        external
        view
        returns (
            address[] memory players,
            uint32[] memory affectionCounts,
            uint256[] memory spentAmounts,
            uint32[] memory ranks
        )
    {
        LibAdoreChickenStorage.AdoreChickenStorage storage acs = LibAdoreChickenStorage.adoreChickenStorage();

        uint256 totalPlayers = acs.topLovers.length;
        if (limit > totalPlayers) {
            limit = totalPlayers;
        }

        players = new address[](limit);
        affectionCounts = new uint32[](limit);
        spentAmounts = new uint256[](limit);
        ranks = new uint32[](limit);

        // List is already sorted by updateRankings
        for (uint256 i = 0; i < limit; i++) {
            address player = acs.topLovers[i];
            players[i] = player;
            affectionCounts[i] = acs.playerProfiles[player].totalAffectionGiven;
            spentAmounts[i] = acs.playerProfiles[player].totalZicoSpent;
            ranks[i] = uint32(i + 1); // 1-indexed rank
        }

        return (players, affectionCounts, spentAmounts, ranks);
    }

    /**
     * @notice Get top loved chickens leaderboard (sorted by total affection received)
     * @param limit Maximum number of chickens to return
     * @return collectionIds Array of collection IDs (sorted by rank)
     * @return tokenIds Array of token IDs
     * @return affectionCounts Array of total affection received
     * @return happinessLevels Array of current happiness levels
     * @return ranks Array of rank positions (1-indexed)
     */
    function getTopLovedChickens(uint256 limit)
        external
        view
        returns (
            uint256[] memory collectionIds,
            uint256[] memory tokenIds,
            uint32[] memory affectionCounts,
            uint16[] memory happinessLevels,
            uint32[] memory ranks
        )
    {
        LibAdoreChickenStorage.AdoreChickenStorage storage acs = LibAdoreChickenStorage.adoreChickenStorage();

        uint256 totalChickens = acs.topLovedChickens.length;
        if (limit > totalChickens) {
            limit = totalChickens;
        }

        collectionIds = new uint256[](limit);
        tokenIds = new uint256[](limit);
        affectionCounts = new uint32[](limit);
        happinessLevels = new uint16[](limit);
        ranks = new uint32[](limit);

        // List is already sorted by updateRankings
        for (uint256 i = 0; i < limit; i++) {
            uint256 combinedId = acs.topLovedChickens[i];
            (uint256 collectionId, uint256 tokenId) = LibAdoreChickenStorage.splitCombinedId(combinedId);

            collectionIds[i] = collectionId;
            tokenIds[i] = tokenId;
            affectionCounts[i] = acs.chickenStats[combinedId].totalAffectionEvents;
            happinessLevels[i] = acs.chickenStats[combinedId].happinessLevel;
            ranks[i] = uint32(i + 1); // 1-indexed rank
        }

        return (collectionIds, tokenIds, affectionCounts, happinessLevels, ranks);
    }

    /**
     * @notice Check if player can give affection (rate limiting and daily limits)
     * @param player Player address to check
     * @param collectionId Collection ID of target chicken
     * @param tokenId Token ID of target chicken
     * @return canGive Whether player can give affection
     * @return reason Reason if cannot give affection
     */
    function canGiveAffection(address player, uint256 collectionId, uint256 tokenId)
        external
        view
        returns (bool canGive, string memory reason)
    {
        LibAdoreChickenStorage.AdoreChickenStorage storage acs = LibAdoreChickenStorage.adoreChickenStorage();
        
        // Check rate limiting
        if (block.timestamp < acs.lastActionTime[player][this.kissChicken.selector] + acs.config.rateLimitCooldown) {
            return (false, "Rate limit active");
        }
        
        // Check daily limits
        uint256 combinedId = LibAdoreChickenStorage.combineIds(collectionId, tokenId);
        (bool playerOk, bool chickenOk) = LibAdoreChickenStorage.checkDailyLimits(player, combinedId);
        
        if (!playerOk) {
            return (false, "Daily player limit exceeded");
        }
        
        if (!chickenOk) {
            return (false, "Daily chicken limit exceeded");
        }
        
        return (true, "");
    }

    /**
     * @notice Get player's current rank in the leaderboard
     * @param player Player address to check
     * @return rank Player's rank (1-indexed, 0 if not ranked)
     * @return totalAffection Player's total affection given
     * @return totalSpent Player's total ZICO spent
     */
    function getChickLoverRank(address player)
        external
        view
        returns (uint32 rank, uint32 totalAffection, uint256 totalSpent)
    {
        LibAdoreChickenStorage.AdoreChickenStorage storage acs = LibAdoreChickenStorage.adoreChickenStorage();

        rank = acs.playerRankings[player];
        totalAffection = acs.playerProfiles[player].totalAffectionGiven;
        totalSpent = acs.playerProfiles[player].totalZicoSpent;

        return (rank, totalAffection, totalSpent);
    }

    /**
     * @notice Get chicken's current rank in the leaderboard
     * @param collectionId Collection ID of the chicken
     * @param tokenId Token ID of the chicken
     * @return rank Chicken's rank (1-indexed, 0 if not ranked)
     * @return totalAffection Chicken's total affection received
     * @return happiness Chicken's current happiness level
     */
    function getChickenRank(uint256 collectionId, uint256 tokenId)
        external
        view
        returns (uint32 rank, uint32 totalAffection, uint16 happiness)
    {
        LibAdoreChickenStorage.AdoreChickenStorage storage acs = LibAdoreChickenStorage.adoreChickenStorage();
        uint256 combinedId = LibAdoreChickenStorage.combineIds(collectionId, tokenId);

        rank = acs.chickenRankings[combinedId];
        totalAffection = acs.chickenStats[combinedId].totalAffectionEvents;
        happiness = acs.chickenStats[combinedId].happinessLevel;

        return (rank, totalAffection, happiness);
    }

    /**
     * @notice Get token variant from collection
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return variant Token variant (1-4)
     */
    function _getTokenVariant(uint256 collectionId, uint256 tokenId) internal view returns (uint8 variant) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Default variant if retrieval fails
        uint8 defaultVariant = 1;
        
        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            return defaultVariant;
        }
        
        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        if (collection.collectionAddress == address(0)) {
            return defaultVariant;
        }
        
        try IExternalCollection(collection.collectionAddress).itemVariant(tokenId) returns (uint8 v) {
            // Ensure variant is in valid range
            if (v >= 1 && v <= 4) {
                return v;
            }
        } catch {
            // Ignore errors
        }
        
        return defaultVariant;
    }

    /**
     * @notice Validate token exists and has variant 1-4
     * @param collectionId Collection ID to validate
     * @param tokenId Token ID to validate
     * @return valid True if token exists and has valid variant
     */
    function _validateToken(uint256 collectionId, uint256 tokenId) internal view returns (bool valid) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Validate collection exists and is enabled
        if (collectionId == 0 || collectionId > hs.collectionCounter) {
            return false;
        }

        SpecimenCollection storage collection = hs.specimenCollections[collectionId];
        if (!collection.enabled || collection.collectionAddress == address(0)) {
            return false;
        }

        // Check if token exists by trying to get its variant
        uint8 variant = _getTokenVariant(collectionId, tokenId);
        return variant >= 1 && variant <= 4;
    }

    // ============ Admin Functions ============

    /**
     * @notice Rebuild player rankings by sorting existing entries
     * @dev One-time migration function to fix unsorted legacy data
     * @dev Uses insertion sort which is gas-efficient for nearly-sorted data
     */
    function rebuildPlayerRankings() external onlyAuthorized {
        LibAdoreChickenStorage.AdoreChickenStorage storage acs = LibAdoreChickenStorage.adoreChickenStorage();
        uint256 len = acs.topLovers.length;

        // Insertion sort (stable, efficient for small arrays)
        for (uint256 i = 1; i < len; i++) {
            address current = acs.topLovers[i];
            uint32 currentScore = acs.playerProfiles[current].totalAffectionGiven;
            uint256 j = i;

            // Shift elements that are smaller than current
            while (j > 0) {
                address prev = acs.topLovers[j - 1];
                uint32 prevScore = acs.playerProfiles[prev].totalAffectionGiven;

                if (prevScore >= currentScore) {
                    break;
                }

                acs.topLovers[j] = prev;
                acs.playerRankings[prev] = uint32(j + 1);
                j--;
            }

            acs.topLovers[j] = current;
            acs.playerRankings[current] = uint32(j + 1);
        }
    }

    /**
     * @notice Rebuild chicken rankings by sorting existing entries
     * @dev One-time migration function to fix unsorted legacy data
     */
    function rebuildChickenRankings() external onlyAuthorized {
        LibAdoreChickenStorage.AdoreChickenStorage storage acs = LibAdoreChickenStorage.adoreChickenStorage();
        uint256 len = acs.topLovedChickens.length;

        // Insertion sort
        for (uint256 i = 1; i < len; i++) {
            uint256 current = acs.topLovedChickens[i];
            uint32 currentScore = acs.chickenStats[current].totalAffectionEvents;
            uint256 j = i;

            while (j > 0) {
                uint256 prev = acs.topLovedChickens[j - 1];
                uint32 prevScore = acs.chickenStats[prev].totalAffectionEvents;

                if (prevScore >= currentScore) {
                    break;
                }

                acs.topLovedChickens[j] = prev;
                acs.chickenRankings[prev] = uint32(j + 1);
                j--;
            }

            acs.topLovedChickens[j] = current;
            acs.chickenRankings[current] = uint32(j + 1);
        }
    }
}