// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { LibHenomorphsStorage } from "../libraries/LibHenomorphsStorage.sol";
import { LibColonyWarsStorage } from "../libraries/LibColonyWarsStorage.sol";
import { ColonyHelper } from "../../staking/libraries/ColonyHelper.sol";
import { AccessControlBase } from "../../common/facets/AccessControlBase.sol";
import { AccessHelper } from "../../staking/libraries/AccessHelper.sol";
import { PodsUtils } from "../../../libraries/PodsUtils.sol";
import { LibMeta } from "../../shared/libraries/LibMeta.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IColonyResourceCards } from "../../staking/interfaces/IColonyResourceCards.sol";

/**
 * @title ColonySquadStakingFacet
 * @notice Handles multi-collection NFT staking for Colony Wars battle squads
 * @dev Part of HenomorphsChargepod Diamond - integrates with Colony Wars system
 * 
 * ARCHITECTURE:
 * - Lives in Chargepod Diamond (NOT Staking Diamond)
 * - Uses LibHenomorphsStorage for colony and power core data
 * - Uses ColonyHelper for proper authorization and membership
 * - Uses standard ERC721 safe transfers (NOT Model D)
 * - Supports multiple NFT collections per squad type
 * 
 * KEY FEATURES:
 * - Standard ERC721 safeTransferFrom for custody
 * - Multi-collection support: tracks collectionId + tokenId pairs
 * - Power core validation and charge level bonuses
 * - Generic NFT semantics (Territory/Infrastructure Cards)
 * - Proper Diamond Proxy pattern compliance with LibMeta.msgSender()
 * - Full integration with ColonyHelper authorization
 * - Active power core validation before staking
 * 
 * TERMINOLOGY:
 * - Colony: Permanent structure of Henomorphs members
 * - Squad: Temporary battle formation of Territory + Infrastructure Cards
 * - Team: Legacy term (replaced by Squad for clarity)
 * 
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract ColonySquadStakingFacet is AccessControlBase {
    using LibHenomorphsStorage for LibHenomorphsStorage.HenomorphsStorage;

    // ============================================
    // ERRORS
    // ============================================
    
    error SquadAlreadyStaked();
    error NoSquadStaked();
    error InvalidCollectionContract();
    error NotAuthorizedForToken(uint256 collectionId, uint256 tokenId);
    error MaxSquadSizeExceeded();
    error NFTAlreadyStaked();
    error NFTNotInSquad();
    error ColonyNotRegistered();
    error InvalidArrayLength();
    error PowerCoreNotActive(uint256 collectionId, uint256 tokenId);
    error ChargeLevelTooLow(uint256 collectionId, uint256 tokenId, uint256 current, uint256 required);
    error CollectionNotEnabled(uint256 collectionId);
    error InvalidItemType();
    error NotColonyCreator(bytes32 colonyId);

    // ============================================
    // EVENTS
    // ============================================
    
    event SquadStaked(
        bytes32 indexed colonyId, 
        StakedToken[] territoryCards, 
        StakedToken[] infraCards,
        StakedToken[] resourceCards,
        uint16 synergyBonus
    );
    
    event SquadUnstaked(
        bytes32 indexed colonyId, 
        StakedToken[] territoryCards, 
        StakedToken[] infraCards,
        StakedToken[] resourceCards
    );
    
    event SynergyBonusUpdated(
        bytes32 indexed colonyId, 
        uint16 newBonus
    );
    
    event SquadMemberAdded(
        bytes32 indexed colonyId, 
        uint256 itemType,
        uint256 collectionId,
        uint256 tokenId
    );
    
    event SquadMemberRemoved(
        bytes32 indexed colonyId, 
        uint256 itemType,
        uint256 collectionId,
        uint256 tokenId
    );
    
    event PowerCoreLocked(
        uint256 indexed collectionId, 
        uint256 indexed tokenId, 
        bool locked
    );

    // ============================================
    // CONSTANTS
    // ============================================
    
    uint8 constant MAX_TERRITORIES_IN_SQUAD = 3;
    uint8 constant MAX_INFRASTRUCTURE_IN_SQUAD = 5;
    uint8 constant MAX_RESOURCES_IN_SQUAD = 4;
    uint256 constant MIN_CHARGE_FOR_STAKING = 50; // Minimum 50% charge required
    
    // Item Type identifiers
    uint8 constant ITEM_TYPE_TERRITORY = 1;
    uint8 constant ITEM_TYPE_INFRASTRUCTURE = 2;
    uint8 constant ITEM_TYPE_RESOURCE = 3;

    // ============================================
    // STORAGE - NOW USES LibColonyWarsStorage
    // ============================================
    // All storage moved to LibColonyWarsStorage for proper multi-collection support
    // Functions use LibColonyWarsStorage.* helpers instead of local storage
    
    // Legacy struct for backward compatibility in events/view functions
    struct StakedToken {
        uint256 collectionId;
        uint256 tokenId;
    }

    // ============================================
    // MAIN STAKING FUNCTIONS
    // ============================================

    /**
     * @notice Stake a complete squad of NFTs from multiple collections
     * @dev Uses standard ERC721 safeTransferFrom for custody
     * @param colonyId Colony to stake squad for
     * @param territoryCards Array of territory NFTs (collectionId, tokenId pairs)
     * @param infraCards Array of infrastructure NFTs (collectionId, tokenId pairs)
     * @param resourceCards Array of resource NFTs (collectionId, tokenId pairs)
     */
    function stakeSquad(
        bytes32 colonyId,
        StakedToken[] calldata territoryCards,
        StakedToken[] calldata infraCards,
        StakedToken[] calldata resourceCards
    ) external whenNotPaused nonReentrant {
        address sender = LibMeta.msgSender();
        address stakingListener = AccessHelper.getStakingAddress();
        
        // Validate colony exists and caller is authorized
        ColonyHelper.requireColonyExists(colonyId);
        if (!ColonyHelper.isColonyCreator(colonyId, stakingListener)) {
            revert NotColonyCreator(colonyId);
        }
        
        // Check if squad already staked using LibColonyWarsStorage
        LibColonyWarsStorage.SquadStakePosition storage squad = LibColonyWarsStorage.getSquadStakePosition(colonyId);
        if (squad.active) revert SquadAlreadyStaked();
        
        // Validate squad size
        if (territoryCards.length > MAX_TERRITORIES_IN_SQUAD) revert MaxSquadSizeExceeded();
        if (infraCards.length > MAX_INFRASTRUCTURE_IN_SQUAD) revert MaxSquadSizeExceeded();
        if (resourceCards.length > MAX_RESOURCES_IN_SQUAD) revert MaxSquadSizeExceeded();

        // Stake Territory NFTs using LibColonyWarsStorage
        for (uint256 i = 0; i < territoryCards.length; i++) {
            _stakeTokenToSquad(
                territoryCards[i].collectionId,
                territoryCards[i].tokenId,
                colonyId,
                ITEM_TYPE_TERRITORY,
                sender,
                stakingListener
            );
        }

        // Stake Infrastructure NFTs using LibColonyWarsStorage
        for (uint256 i = 0; i < infraCards.length; i++) {
            _stakeTokenToSquad(
                infraCards[i].collectionId,
                infraCards[i].tokenId,
                colonyId,
                ITEM_TYPE_INFRASTRUCTURE,
                sender,
                stakingListener
            );
        }

        // Stake Resource NFTs using LibColonyWarsStorage
        for (uint256 i = 0; i < resourceCards.length; i++) {
            _stakeTokenToSquad(
                resourceCards[i].collectionId,
                resourceCards[i].tokenId,
                colonyId,
                ITEM_TYPE_RESOURCE,
                sender,
                stakingListener
            );
        }

        // Calculate synergy bonus with charge level consideration (now includes resources)
        uint16 synergyBonus = _calculateSquadSynergy(
            squad.territoryCards,
            squad.infraCards,
            squad.resourceCards
        );

        // Update squad position in LibColonyWarsStorage
        squad.stakedAt = uint32(block.timestamp);
        squad.totalSynergyBonus = synergyBonus;
        squad.uniqueCollectionsCount = uint8(LibColonyWarsStorage.getColonyActiveCollections(colonyId).length);
        squad.active = true;

        emit SquadStaked(colonyId, territoryCards, infraCards, resourceCards, synergyBonus);
    }

    /**
     * @notice Unstake complete squad and return all NFTs
     * @dev Uses standard ERC721 safeTransferFrom for return
     * @param colonyId Colony to unstake from
     */
    function unstakeSquad(bytes32 colonyId) external whenNotPaused nonReentrant {
        address sender = LibMeta.msgSender();
        address stakingListener = AccessHelper.getStakingAddress();
        
        // Validate colony exists and caller is authorized
        ColonyHelper.requireColonyExists(colonyId);
        if (!ColonyHelper.isColonyCreator(colonyId, stakingListener)) {
            revert NotColonyCreator(colonyId);
        }

        LibColonyWarsStorage.SquadStakePosition storage squad = LibColonyWarsStorage.getSquadStakePosition(colonyId);
        if (!squad.active) revert NoSquadStaked();

        // Prepare output arrays for event
        StakedToken[] memory territoryCards = new StakedToken[](squad.territoryCards.length);
        StakedToken[] memory infraCards = new StakedToken[](squad.infraCards.length);
        StakedToken[] memory resourceCards = new StakedToken[](squad.resourceCards.length);

        // Unstake Territory NFTs using standard ERC721
        for (uint256 i = 0; i < squad.territoryCards.length; i++) {
            uint256 collectionId = squad.territoryCards[i].collectionId;
            uint256 tokenId = squad.territoryCards[i].tokenId;
            
            _unstakeTokenFromSquad(
                collectionId,
                tokenId,
                colonyId,
                ITEM_TYPE_TERRITORY,
                sender
            );
            territoryCards[i] = StakedToken(collectionId, tokenId);
        }

        // Unstake Infrastructure NFTs using standard ERC721
        for (uint256 i = 0; i < squad.infraCards.length; i++) {
            uint256 collectionId = squad.infraCards[i].collectionId;
            uint256 tokenId = squad.infraCards[i].tokenId;
            
            _unstakeTokenFromSquad(
                collectionId,
                tokenId,
                colonyId,
                ITEM_TYPE_INFRASTRUCTURE,
                sender
            );
            infraCards[i] = StakedToken(collectionId, tokenId);
        }

        // Unstake Resource NFTs using standard ERC721
        for (uint256 i = 0; i < squad.resourceCards.length; i++) {
            uint256 collectionId = squad.resourceCards[i].collectionId;
            uint256 tokenId = squad.resourceCards[i].tokenId;
            
            _unstakeTokenFromSquad(
                collectionId,
                tokenId,
                colonyId,
                ITEM_TYPE_RESOURCE,
                sender
            );
            resourceCards[i] = StakedToken(collectionId, tokenId);
        }

        emit SquadUnstaked(colonyId, territoryCards, infraCards, resourceCards);

        // Clear squad position using LibColonyWarsStorage
        delete squad.territoryCards;
        delete squad.infraCards;
        delete squad.resourceCards;
        squad.stakedAt = 0;
        squad.totalSynergyBonus = 0;
        squad.uniqueCollectionsCount = 0;
        squad.active = false;
    }

    /**
     * @notice Add a single NFT to existing squad
     * @param colonyId Colony to add NFT to
     * @param collectionId Collection ID of the NFT
     * @param tokenId Token ID to add
     * @param itemType Item type (1=Territory, 2=Infrastructure)
     */
    function addSquadItem(
        bytes32 colonyId,
        uint256 collectionId,
        uint256 tokenId,
        uint8 itemType
    ) external whenNotPaused nonReentrant {
        address sender = LibMeta.msgSender();
        address stakingListener = AccessHelper.getStakingAddress();
        
        // Validate colony exists and caller is authorized
        ColonyHelper.requireColonyExists(colonyId);
        if (!ColonyHelper.isColonyCreator(colonyId, stakingListener)) {
            revert NotColonyCreator(colonyId);
        }
        
        LibColonyWarsStorage.SquadStakePosition storage squad = LibColonyWarsStorage.getSquadStakePosition(colonyId);
        if (!squad.active) revert NoSquadStaked();
        
        // Validate item type
        if (itemType != ITEM_TYPE_TERRITORY && 
            itemType != ITEM_TYPE_INFRASTRUCTURE &&
            itemType != ITEM_TYPE_RESOURCE) {
            revert InvalidItemType();
        }
        
        // Validate squad size limits
        bool isTerritory = (itemType == ITEM_TYPE_TERRITORY);
        bool isResource = (itemType == ITEM_TYPE_RESOURCE);
        
        if (isTerritory && squad.territoryCards.length >= MAX_TERRITORIES_IN_SQUAD) {
            revert MaxSquadSizeExceeded();
        }
        if (isResource && squad.resourceCards.length >= MAX_RESOURCES_IN_SQUAD) {
            revert MaxSquadSizeExceeded();
        }
        if (!isTerritory && !isResource && squad.infraCards.length >= MAX_INFRASTRUCTURE_IN_SQUAD) {
            revert MaxSquadSizeExceeded();
        }

        // Stake the NFT using LibColonyWarsStorage (which adds to arrays automatically)
        _stakeTokenToSquad(collectionId, tokenId, colonyId, itemType, sender, stakingListener);

        // Recalculate synergy bonus
        squad.totalSynergyBonus = _calculateSquadSynergyFromStorage(squad);
        
        // Update unique collections count
        squad.uniqueCollectionsCount = uint8(LibColonyWarsStorage.getColonyActiveCollections(colonyId).length);

        emit SquadMemberAdded(colonyId, itemType, collectionId, tokenId);
        emit SynergyBonusUpdated(colonyId, squad.totalSynergyBonus);
    }

    /**
     * @notice Remove a single NFT from squad
     * @param colonyId Colony to remove NFT from
     * @param collectionId Collection ID of the NFT
     * @param tokenId Token ID to remove
     * @param itemType Item type (1=Territory, 2=Infrastructure)
     */
    function removeSquadItem(
        bytes32 colonyId,
        uint256 collectionId,
        uint256 tokenId,
        uint8 itemType
    ) external whenNotPaused nonReentrant {
        address sender = LibMeta.msgSender();
        address stakingListener = AccessHelper.getStakingAddress();
        
        // Validate colony exists and caller is authorized
        ColonyHelper.requireColonyExists(colonyId);
        if (!ColonyHelper.isColonyCreator(colonyId, stakingListener)) {
            revert NotColonyCreator(colonyId);
        }
        
        LibColonyWarsStorage.SquadStakePosition storage squad = LibColonyWarsStorage.getSquadStakePosition(colonyId);
        if (!squad.active) revert NoSquadStaked();

        // Validate item type
        if (itemType != ITEM_TYPE_TERRITORY && 
            itemType != ITEM_TYPE_INFRASTRUCTURE &&
            itemType != ITEM_TYPE_RESOURCE) {
            revert InvalidItemType();
        }

        bool isTerritory = (itemType == ITEM_TYPE_TERRITORY);
        bool isResource = (itemType == ITEM_TYPE_RESOURCE);
        
        // Verify NFT is in squad before unstaking
        bool found = false;
        LibColonyWarsStorage.CompositeCardId[] storage cardArray;
        if (isTerritory) {
            cardArray = squad.territoryCards;
        } else if (isResource) {
            cardArray = squad.resourceCards;
        } else {
            cardArray = squad.infraCards;
        }
        
        for (uint256 i = 0; i < cardArray.length; i++) {
            if (cardArray[i].collectionId == collectionId && cardArray[i].tokenId == tokenId) {
                found = true;
                break;
            }
        }
        
        if (!found) revert NFTNotInSquad();

        // Unstake the NFT using LibColonyWarsStorage (which removes from arrays automatically)
        _unstakeTokenFromSquad(collectionId, tokenId, colonyId, itemType, sender);

        // Recalculate synergy bonus
        squad.totalSynergyBonus = _calculateSquadSynergyFromStorage(squad);
        
        // Update unique collections count
        squad.uniqueCollectionsCount = uint8(LibColonyWarsStorage.getColonyActiveCollections(colonyId).length);

        emit SquadMemberRemoved(colonyId, itemType, collectionId, tokenId);
        emit SynergyBonusUpdated(colonyId, squad.totalSynergyBonus);
    }

    /**
     * @notice Swap one NFT for another in squad (atomic remove + add)
     * @dev Single transaction to swap items, more gas efficient and atomic
     * @param colonyId Colony to swap NFT in
     * @param removeCollectionId Collection ID of NFT to remove
     * @param removeTokenId Token ID to remove
     * @param addCollectionId Collection ID of NFT to add
     * @param addTokenId Token ID to add
     * @param itemType Item type (1=Territory, 2=Infrastructure, 3=Resource)
     */
    function swapSquadItem(
        bytes32 colonyId,
        uint256 removeCollectionId,
        uint256 removeTokenId,
        uint256 addCollectionId,
        uint256 addTokenId,
        uint8 itemType
    ) external whenNotPaused nonReentrant {
        address sender = LibMeta.msgSender();
        address stakingListener = AccessHelper.getStakingAddress();

        // Validate colony exists and caller is authorized
        ColonyHelper.requireColonyExists(colonyId);
        if (!ColonyHelper.isColonyCreator(colonyId, stakingListener)) {
            revert NotColonyCreator(colonyId);
        }

        LibColonyWarsStorage.SquadStakePosition storage squad = LibColonyWarsStorage.getSquadStakePosition(colonyId);
        if (!squad.active) revert NoSquadStaked();

        // Validate item type
        if (itemType != ITEM_TYPE_TERRITORY &&
            itemType != ITEM_TYPE_INFRASTRUCTURE &&
            itemType != ITEM_TYPE_RESOURCE) {
            revert InvalidItemType();
        }

        bool isTerritory = (itemType == ITEM_TYPE_TERRITORY);
        bool isResource = (itemType == ITEM_TYPE_RESOURCE);

        // Verify NFT to remove is in squad
        bool found = false;
        LibColonyWarsStorage.CompositeCardId[] storage cardArray;
        if (isTerritory) {
            cardArray = squad.territoryCards;
        } else if (isResource) {
            cardArray = squad.resourceCards;
        } else {
            cardArray = squad.infraCards;
        }

        for (uint256 i = 0; i < cardArray.length; i++) {
            if (cardArray[i].collectionId == removeCollectionId && cardArray[i].tokenId == removeTokenId) {
                found = true;
                break;
            }
        }

        if (!found) revert NFTNotInSquad();

        // Step 1: Unstake the old NFT
        _unstakeTokenFromSquad(removeCollectionId, removeTokenId, colonyId, itemType, sender);

        // Step 2: Stake the new NFT (no size check needed - we just removed one)
        _stakeTokenToSquad(addCollectionId, addTokenId, colonyId, itemType, sender, stakingListener);

        // Recalculate synergy bonus
        squad.totalSynergyBonus = _calculateSquadSynergyFromStorage(squad);

        // Update unique collections count
        squad.uniqueCollectionsCount = uint8(LibColonyWarsStorage.getColonyActiveCollections(colonyId).length);

        emit SquadMemberRemoved(colonyId, itemType, removeCollectionId, removeTokenId);
        emit SquadMemberAdded(colonyId, itemType, addCollectionId, addTokenId);
        emit SynergyBonusUpdated(colonyId, squad.totalSynergyBonus);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get colony's complete staked squad info
     */
    function getColonySquad(bytes32 colonyId) 
        external 
        view 
        returns (LibColonyWarsStorage.SquadStakePosition memory) 
    {
        return LibColonyWarsStorage.getSquadStakePosition(colonyId);
    }

    /**
     * @notice Get colony squad as StakedNFT arrays (with collection IDs)
     */
    function getColonySquadDetailed(bytes32 colonyId)
        external
        view
        returns (
            StakedToken[] memory territoryCards,
            StakedToken[] memory infraCards,
            StakedToken[] memory resourceCards,
            uint32 stakedAt,
            uint16 synergyBonus,
            bool active
        )
    {
        LibColonyWarsStorage.SquadStakePosition storage squad = LibColonyWarsStorage.getSquadStakePosition(colonyId);

        if (!squad.active) {
            return (new StakedToken[](0), new StakedToken[](0), new StakedToken[](0), 0, 0, false);
        }
        
        // Convert CompositeCardId to StakedNFT structs for backward compatibility
        territoryCards = new StakedToken[](squad.territoryCards.length);
        for (uint256 i = 0; i < squad.territoryCards.length; i++) {
            territoryCards[i] = StakedToken(squad.territoryCards[i].collectionId, squad.territoryCards[i].tokenId);
        }
        
        infraCards = new StakedToken[](squad.infraCards.length);
        for (uint256 i = 0; i < squad.infraCards.length; i++) {
            infraCards[i] = StakedToken(squad.infraCards[i].collectionId, squad.infraCards[i].tokenId);
        }
        
        resourceCards = new StakedToken[](squad.resourceCards.length);
        for (uint256 i = 0; i < squad.resourceCards.length; i++) {
            resourceCards[i] = StakedToken(squad.resourceCards[i].collectionId, squad.resourceCards[i].tokenId);
        }
        
        return (territoryCards, infraCards, resourceCards, squad.stakedAt, squad.totalSynergyBonus, true);
    }

    /**
     * @notice Get total squad synergy bonus for colony
     */
    function getSquadBonus(bytes32 colonyId) external view returns (uint16) {
        LibColonyWarsStorage.SquadStakePosition storage squad = LibColonyWarsStorage.getSquadStakePosition(colonyId);
        return squad.active ? squad.totalSynergyBonus : 0;
    }

    /**
     * @notice Check if NFT is staked in a squad
     */
    function isTokenStakedInSquad(uint256 collectionId, uint256 tokenId, uint8 itemType) 
        external 
        view 
        returns (bool staked, bytes32 colonyId) 
    {
        bool isTerritory = (itemType == ITEM_TYPE_TERRITORY);
        bool isResource = (itemType == ITEM_TYPE_RESOURCE);
        colonyId = LibColonyWarsStorage.getTokenStakedBy(collectionId, tokenId, isTerritory, isResource);
        staked = colonyId != bytes32(0);
    }

    /**
     * @notice Get detailed squad statistics
     */
    function getSquadStatistics(bytes32 colonyId)
        external
        view
        returns (
            uint256 territoryCount,
            uint256 infraCount,
            uint256 resourceCount,
            uint256 avgChargeLevel,
            uint256 stakeDuration
        )
    {
        LibColonyWarsStorage.SquadStakePosition storage squad = LibColonyWarsStorage.getSquadStakePosition(colonyId);

        if (!squad.active) {
            return (0, 0, 0, 0, 0);
        }

        territoryCount = squad.territoryCards.length;
        infraCount = squad.infraCards.length;
        resourceCount = squad.resourceCards.length;
        stakeDuration = block.timestamp - squad.stakedAt;

        avgChargeLevel = _getSquadAverageCharge(squad);
    }

    /**
     * @notice Get squad staking configuration constants
     * @return maxTerritories Maximum territory cards allowed
     * @return maxInfrastructure Maximum infrastructure cards allowed
     * @return maxResources Maximum resource cards allowed
     * @return minChargePercent Minimum charge percentage required (50 = 50%)
     * @return baseBonus Base synergy bonus (50 = 5%)
     * @return maxBonus Maximum possible synergy bonus (500 = 50%)
     */
    function getSquadConfig()
        external
        pure
        returns (
            uint8 maxTerritories,
            uint8 maxInfrastructure,
            uint8 maxResources,
            uint256 minChargePercent,
            uint16 baseBonus,
            uint16 maxBonus
        )
    {
        return (
            MAX_TERRITORIES_IN_SQUAD,
            MAX_INFRASTRUCTURE_IN_SQUAD,
            MAX_RESOURCES_IN_SQUAD,
            MIN_CHARGE_FOR_STAKING,
            50,  // Base bonus 5%
            500  // Max bonus 50%
        );
    }

    /**
     * @notice Check if a token can be staked in a squad
     * @param collectionId Collection ID of the NFT
     * @param tokenId Token ID to check
     * @param itemType Item type (1=Territory, 2=Infrastructure, 3=Resource)
     * @return canStake Whether the token can be staked
     * @return reason Reason code if cannot stake (0=OK, 1=already staked, 2=charge too low, 3=no power core, 4=collection not enabled)
     */
    function canStakeTokenInSquad(
        uint256 collectionId,
        uint256 tokenId,
        uint8 itemType
    )
        external
        view
        returns (bool canStake, uint8 reason)
    {
        // Check collection enabled using getCollectionRegistry
        LibColonyWarsStorage.CollectionRegistry memory registry = LibColonyWarsStorage.getCollectionRegistry(collectionId);
        if (registry.contractAddress == address(0) || !registry.enabled) {
            return (false, 4); // Collection not enabled
        }

        // Check not already staked
        if (LibColonyWarsStorage.isNFTStaked(collectionId, tokenId)) {
            return (false, 1); // Already staked
        }

        // Check power core exists and has sufficient charge
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);

        if (hs.performedCharges[combinedId].lastChargeTime == 0) {
            return (false, 3); // No power core
        }

        if (hs.performedCharges[combinedId].currentCharge < MIN_CHARGE_FOR_STAKING) {
            return (false, 2); // Charge too low
        }

        return (true, 0);
    }

    /**
     * @notice Calculate potential synergy bonus for a hypothetical squad composition
     * @dev Used for UI preview before staking
     * @param territoryCount Number of territory cards
     * @param infraCount Number of infrastructure cards
     * @param resourceCount Number of resource cards
     * @param avgChargePercent Average charge percentage (0-100)
     * @return bonus Calculated synergy bonus (in basis points, 100 = 10%)
     */
    function calculateSquadSynergyBonus(
        uint256 territoryCount,
        uint256 infraCount,
        uint256 resourceCount,
        uint256 avgChargePercent
    )
        external
        pure
        returns (uint16 bonus)
    {
        bonus = 0;

        // Base bonus: 50 (5%)
        if (territoryCount > 0 || infraCount > 0 || resourceCount > 0) {
            bonus += 50;
        }

        // Territory bonus: 30 (3%) per territory, max 90 (9%)
        uint16 territoryBonus = uint16(territoryCount * 30);
        if (territoryBonus > 90) territoryBonus = 90;
        bonus += territoryBonus;

        // Infrastructure bonus: 20 (2%) per infra, max 100 (10%)
        uint16 infraBonus = uint16(infraCount * 20);
        if (infraBonus > 100) infraBonus = 100;
        bonus += infraBonus;

        // Resource bonus: 15 (1.5%) per resource, max 60 (6%)
        uint16 resourceBonus = uint16(resourceCount * 15);
        if (resourceBonus > 60) resourceBonus = 60;
        bonus += resourceBonus;

        // Full squad bonus: +100 (10%)
        if (territoryCount == MAX_TERRITORIES_IN_SQUAD &&
            infraCount == MAX_INFRASTRUCTURE_IN_SQUAD &&
            resourceCount == MAX_RESOURCES_IN_SQUAD) {
            bonus += 100;
        }

        // Charge level bonus: +1% per 10 avg charge, max +10%
        uint16 chargeBonus = uint16((avgChargePercent / 10) * 10);
        if (chargeBonus > 100) chargeBonus = 100;
        bonus += chargeBonus;

        // Cap at 500 (50% max)
        if (bonus > 500) bonus = 500;

        return bonus;
    }

    /**
     * @notice Get all colony IDs where a user has active squads
     * @dev Iterates through user's colonies to find active squads
     * @param user Address to check
     * @return colonyIds Array of colony IDs with active squads
     */
    function getUserSquadColonies(address user)
        external
        view
        returns (bytes32[] memory colonyIds)
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        // Get user's colonies
        bytes32[] storage userColonies = hs.userColonies[user];

        // First pass: count active squads
        uint256 activeCount = 0;
        for (uint256 i = 0; i < userColonies.length; i++) {
            LibColonyWarsStorage.SquadStakePosition storage squad = LibColonyWarsStorage.getSquadStakePosition(userColonies[i]);
            if (squad.active) {
                activeCount++;
            }
        }

        // Second pass: collect colony IDs
        colonyIds = new bytes32[](activeCount);
        uint256 idx = 0;
        for (uint256 i = 0; i < userColonies.length; i++) {
            LibColonyWarsStorage.SquadStakePosition storage squad = LibColonyWarsStorage.getSquadStakePosition(userColonies[i]);
            if (squad.active) {
                colonyIds[idx] = userColonies[i];
                idx++;
            }
        }

        return colonyIds;
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Admin: Emergency unstake if needed
     */
    function emergencyUnstakeSquad(bytes32 colonyId) 
        external 
        onlyAuthorized
        nonReentrant
    {
        LibColonyWarsStorage.SquadStakePosition storage squad = LibColonyWarsStorage.getSquadStakePosition(colonyId);

        if (!squad.active) revert NoSquadStaked();
        
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        address colonyOwner = hs.colonyCreators[colonyId];
        require(colonyOwner != address(0), "Invalid colony");

        StakedToken[] memory territoryCards = new StakedToken[](squad.territoryCards.length);
        StakedToken[] memory infraCards = new StakedToken[](squad.infraCards.length);
        StakedToken[] memory resourceCards = new StakedToken[](squad.resourceCards.length);

        // Emergency return using standard ERC721 (admin bypass)
        for (uint256 i = 0; i < squad.territoryCards.length; i++) {
            uint256 collectionId = squad.territoryCards[i].collectionId;
            uint256 tokenId = squad.territoryCards[i].tokenId;
            territoryCards[i] = StakedToken(collectionId, tokenId);
            
            // CRITICAL FIX: Use LibColonyWarsStorage for contract address lookup
            LibColonyWarsStorage.CollectionRegistry memory registry = LibColonyWarsStorage.getCollectionRegistry(collectionId);
            address contractAddress = registry.contractAddress;
            
            IERC721(contractAddress).safeTransferFrom(address(this), colonyOwner, tokenId);
            
            // Cleanup using LibColonyWarsStorage
            LibColonyWarsStorage.markTokenUnstaked(collectionId, tokenId, colonyId, true, false);
            _lockPowerCore(collectionId, tokenId, false);
        }

        for (uint256 i = 0; i < squad.infraCards.length; i++) {
            uint256 collectionId = squad.infraCards[i].collectionId;
            uint256 tokenId = squad.infraCards[i].tokenId;
            infraCards[i] = StakedToken(collectionId, tokenId);
            
            // CRITICAL FIX: Use LibColonyWarsStorage for contract address lookup
            LibColonyWarsStorage.CollectionRegistry memory registry = LibColonyWarsStorage.getCollectionRegistry(collectionId);
            address contractAddress = registry.contractAddress;
            
            IERC721(contractAddress).safeTransferFrom(address(this), colonyOwner, tokenId);

            // Cleanup using LibColonyWarsStorage
            LibColonyWarsStorage.markTokenUnstaked(collectionId, tokenId, colonyId, false, false);
            _lockPowerCore(collectionId, tokenId, false);
        }

        for (uint256 i = 0; i < squad.resourceCards.length; i++) {
            uint256 collectionId = squad.resourceCards[i].collectionId;
            uint256 tokenId = squad.resourceCards[i].tokenId;
            resourceCards[i] = StakedToken(collectionId, tokenId);

            // CRITICAL FIX: Use LibColonyWarsStorage for contract address lookup
            LibColonyWarsStorage.CollectionRegistry memory registry = LibColonyWarsStorage.getCollectionRegistry(collectionId);
            address contractAddress = registry.contractAddress;

            // Unstake on NFT contract (unblocks transfers)
            IColonyResourceCards(contractAddress).unstakeFromNode(tokenId);

            IERC721(contractAddress).safeTransferFrom(address(this), colonyOwner, tokenId);

            // Cleanup using LibColonyWarsStorage
            LibColonyWarsStorage.markTokenUnstaked(collectionId, tokenId, colonyId, false, true);
            _lockPowerCore(collectionId, tokenId, false);
        }

        emit SquadUnstaked(colonyId, territoryCards, infraCards, resourceCards);
        
        // Clear squad position
        delete squad.territoryCards;
        delete squad.infraCards;
        delete squad.resourceCards;
        squad.stakedAt = 0;
        squad.totalSynergyBonus = 0;
        squad.uniqueCollectionsCount = 0;
        squad.active = false;
    }

    // ============================================
    // INTERNAL FUNCTIONS - STAKING/UNSTAKING
    // ============================================

    /**
     * @notice Internal: Stake NFT using LibColonyWarsStorage multi-collection system
     * @dev Flow: validate → collection check → safeTransferFrom → mark staked → lock power core
     * SECURITY: 12-step validation process
     * 1. Validate collection enabled in LibColonyWarsStorage
     * 2. Get collection registry from LibColonyWarsStorage (NOT LibHenomorphsStorage)
     * 3. Extract contract address from registry
     * 4. Validate collection type matches itemType
     * 5. Check not already staked
     * 6. Create ERC721 interface
     * 7. EXPLICIT ownership verification with ownerOf()
     * 8. Validate colony helper authorization
     * 9. Validate power core
     * 10. Execute safeTransferFrom
     * 11. Mark as staked in LibColonyWarsStorage
     * 12. Lock power core
     */
    function _stakeTokenToSquad(
        uint256 collectionId,
        uint256 tokenId,
        bytes32 colonyId,
        uint8 itemType,
        address sender,
        address stakingListener
    ) internal {
        // STEP 1: Validate collection is registered and enabled in LibColonyWarsStorage
        LibColonyWarsStorage.requireCollectionEnabled(collectionId);
        
        // STEP 2: Get collection registry from LibColonyWarsStorage (CRITICAL FIX)
        LibColonyWarsStorage.CollectionRegistry memory registry = LibColonyWarsStorage.getCollectionRegistry(collectionId);
        
        // STEP 3: Extract contract address from registry
        address contractAddress = registry.contractAddress;
        if (contractAddress == address(0)) revert CollectionNotEnabled(collectionId);
        
        // STEP 4: CRITICAL FIX - Validate collection type matches itemType
        bool isTerritory = (itemType == ITEM_TYPE_TERRITORY);
        bool isResource = (itemType == ITEM_TYPE_RESOURCE);
        
        uint8 expectedType;
        if (isTerritory) {
            expectedType = LibColonyWarsStorage.COLLECTION_TYPE_TERRITORY;
        } else if (isResource) {
            expectedType = LibColonyWarsStorage.COLLECTION_TYPE_RESOURCE;
        } else {
            expectedType = LibColonyWarsStorage.COLLECTION_TYPE_INFRASTRUCTURE;
        }
        
        if (registry.collectionType != expectedType) {
            revert LibColonyWarsStorage.CollectionTypeMismatch(
                collectionId,
                expectedType,
                registry.collectionType
            );
        }
        
        // STEP 5: Check not already staked using LibColonyWarsStorage
        if (LibColonyWarsStorage.isNFTStaked(collectionId, tokenId)) {
            revert NFTAlreadyStaked();
        }
        
        // STEP 6: Create ERC721 interface
        IERC721 tokenERC721 = IERC721(contractAddress);
        
        // STEP 7: CRITICAL FIX - EXPLICIT ownership verification
        address currentOwner = tokenERC721.ownerOf(tokenId);
        if (currentOwner != sender) {
            revert NotAuthorizedForToken(collectionId, tokenId);
        }
        
        // STEP 8: Validate authorization using ColonyHelper
        ColonyHelper.checkHenomorphControl(collectionId, tokenId, stakingListener);
        
        // STEP 9: Validate power core (if applicable)
        _requireActivePowerCoreWithCharge(collectionId, tokenId);

        // STEP 10: STANDARD ERC721 TRANSFER - custody the NFT
        tokenERC721.safeTransferFrom(sender, address(this), tokenId);

        // STEP 11: Mark as staked on NFT contract (blocks transfers)
        // ResourceCards require explicit stakeToNode call to set _isStaked flag
        if (isResource) {
            IColonyResourceCards(contractAddress).stakeToNode(tokenId, uint256(colonyId));
        }

        // STEP 12: Mark as staked in LibColonyWarsStorage (full multi-layer update)
        LibColonyWarsStorage.markTokenStaked(
            collectionId,
            tokenId,
            colonyId,
            isTerritory,
            isResource
        );

        // STEP 13: Lock power core
        _lockPowerCore(collectionId, tokenId, true);
    }

    /**
     * @notice Internal: Unstake NFT using LibColonyWarsStorage multi-collection system
     * @dev Flow: verify ownership → unlock power core → safeTransferFrom → mark unstaked
     */
    function _unstakeTokenFromSquad(
        uint256 collectionId,
        uint256 tokenId,
        bytes32 colonyId,
        uint8 itemType,
        address recipient
    ) internal {
        bool isTerritory = (itemType == ITEM_TYPE_TERRITORY);
        bool isResource = (itemType == ITEM_TYPE_RESOURCE);
        
        // Verify ownership in squad using LibColonyWarsStorage
        bytes32 owner = LibColonyWarsStorage.getTokenStakedBy(
            collectionId,
            tokenId,
            isTerritory,
            isResource
        );
        
        if (owner != colonyId) revert NFTNotInSquad();

        // Unlock power core
        _lockPowerCore(collectionId, tokenId, false);

        // STANDARD ERC721 RETURN: Get contract address from LibColonyWarsStorage (CRITICAL FIX)
        LibColonyWarsStorage.CollectionRegistry memory registry = LibColonyWarsStorage.getCollectionRegistry(collectionId);
        address contractAddress = registry.contractAddress;

        // Unstake on NFT contract (unblocks transfers)
        // ResourceCards require explicit unstakeFromNode call to clear _isStaked flag
        if (isResource) {
            IColonyResourceCards(contractAddress).unstakeFromNode(tokenId);
        }

        IERC721(contractAddress).safeTransferFrom(address(this), recipient, tokenId);

        // Clear staking record in LibColonyWarsStorage (full multi-layer cleanup)
        LibColonyWarsStorage.markTokenUnstaked(
            collectionId,
            tokenId,
            colonyId,
            isTerritory,
            isResource
        );
    }

    // ============================================
    // INTERNAL FUNCTIONS - CALCULATIONS
    // ============================================

    /**
     * @notice Calculate squad synergy bonus with charge level consideration
     * @dev Accepts CompositeCardId arrays from storage
     */
    function _calculateSquadSynergy(
        LibColonyWarsStorage.CompositeCardId[] memory territoryCards,
        LibColonyWarsStorage.CompositeCardId[] memory infraCards,
        LibColonyWarsStorage.CompositeCardId[] memory resourceCards
    ) internal view returns (uint16) {
        uint16 bonus = 0;

        // Base bonus: 50 (5%)
        if (territoryCards.length > 0 || infraCards.length > 0 || resourceCards.length > 0) {
            bonus += 50;
        }

        // Territory bonus: 30 (3%) per territory, max 90 (9%)
        uint16 territoryBonus = uint16(territoryCards.length * 30);
        if (territoryBonus > 90) territoryBonus = 90;
        bonus += territoryBonus;

        // Infrastructure bonus: 20 (2%) per infra, max 100 (10%)
        uint16 infraBonus = uint16(infraCards.length * 20);
        if (infraBonus > 100) infraBonus = 100;
        bonus += infraBonus;

        // Resource bonus: 15 (1.5%) per resource, max 60 (6%)
        uint16 resourceBonus = uint16(resourceCards.length * 15);
        if (resourceBonus > 60) resourceBonus = 60;
        bonus += resourceBonus;

        // Full squad bonus: +100 (10%)
        if (territoryCards.length == MAX_TERRITORIES_IN_SQUAD && 
            infraCards.length == MAX_INFRASTRUCTURE_IN_SQUAD &&
            resourceCards.length == MAX_RESOURCES_IN_SQUAD) {
            bonus += 100;
        }

        // Charge level bonus: +1% per 10 avg charge, max +10%
        uint256 avgCharge = _getAverageChargeLevel(territoryCards, infraCards, resourceCards);
        
        uint16 chargeBonus = uint16((avgCharge / 10) * 10);
        if (chargeBonus > 100) chargeBonus = 100;
        bonus += chargeBonus;

        // Cap at 500 (50% max)
        if (bonus > 500) bonus = 500;

        return bonus;
    }

    /**
     * @notice Calculate synergy from storage (for updates)
     */
    function _calculateSquadSynergyFromStorage(
        LibColonyWarsStorage.SquadStakePosition storage squad
    ) internal view returns (uint16) {
        // Convert storage arrays to memory for calculation
        LibColonyWarsStorage.CompositeCardId[] memory territoryCards = new LibColonyWarsStorage.CompositeCardId[](squad.territoryCards.length);
        for (uint256 i = 0; i < squad.territoryCards.length; i++) {
            territoryCards[i] = squad.territoryCards[i];
        }
        
        LibColonyWarsStorage.CompositeCardId[] memory infraCards = new LibColonyWarsStorage.CompositeCardId[](squad.infraCards.length);
        for (uint256 i = 0; i < squad.infraCards.length; i++) {
            infraCards[i] = squad.infraCards[i];
        }
        
        LibColonyWarsStorage.CompositeCardId[] memory resourceCards = new LibColonyWarsStorage.CompositeCardId[](squad.resourceCards.length);
        for (uint256 i = 0; i < squad.resourceCards.length; i++) {
            resourceCards[i] = squad.resourceCards[i];
        }
        
        return _calculateSquadSynergy(territoryCards, infraCards, resourceCards);
    }

    /**
     * @notice Get average charge level across all squad NFTs
     */
    function _getAverageChargeLevel(
        LibColonyWarsStorage.CompositeCardId[] memory territoryCards,
        LibColonyWarsStorage.CompositeCardId[] memory infraCards,
        LibColonyWarsStorage.CompositeCardId[] memory resourceCards
    ) internal view returns (uint256) {
        if (territoryCards.length == 0 && infraCards.length == 0 && resourceCards.length == 0) {
            return 0;
        }

        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        uint256 totalCharge = 0;
        uint256 totalCount = 0;

        // Sum territory charges
        for (uint256 i = 0; i < territoryCards.length; i++) {
            uint256 combinedId = PodsUtils.combineIds(territoryCards[i].collectionId, territoryCards[i].tokenId);
            uint256 charge = hs.performedCharges[combinedId].currentCharge;
            if (charge > 0) {
                totalCharge += charge;
                totalCount++;
            }
        }

        // Sum infrastructure charges
        for (uint256 i = 0; i < infraCards.length; i++) {
            uint256 combinedId = PodsUtils.combineIds(infraCards[i].collectionId, infraCards[i].tokenId);
            uint256 charge = hs.performedCharges[combinedId].currentCharge;
            if (charge > 0) {
                totalCharge += charge;
                totalCount++;
            }
        }

        // Sum resource charges
        for (uint256 i = 0; i < resourceCards.length; i++) {
            uint256 combinedId = PodsUtils.combineIds(resourceCards[i].collectionId, resourceCards[i].tokenId);
            uint256 charge = hs.performedCharges[combinedId].currentCharge;
            if (charge > 0) {
                totalCharge += charge;
                totalCount++;
            }
        }

        if (totalCount == 0) {
            return 0;
        }

        return totalCharge / totalCount;
    }

    /**
     * @notice Get average charge level for squad
     */
    function _getSquadAverageCharge(
        LibColonyWarsStorage.SquadStakePosition storage squad
    ) internal view returns (uint256) {
        // Convert to memory arrays
        LibColonyWarsStorage.CompositeCardId[] memory territoryCards = new LibColonyWarsStorage.CompositeCardId[](squad.territoryCards.length);
        for (uint256 i = 0; i < squad.territoryCards.length; i++) {
            territoryCards[i] = squad.territoryCards[i];
        }
        
        LibColonyWarsStorage.CompositeCardId[] memory infraCards = new LibColonyWarsStorage.CompositeCardId[](squad.infraCards.length);
        for (uint256 i = 0; i < squad.infraCards.length; i++) {
            infraCards[i] = squad.infraCards[i];
        }
        
        LibColonyWarsStorage.CompositeCardId[] memory resourceCards = new LibColonyWarsStorage.CompositeCardId[](squad.resourceCards.length);
        for (uint256 i = 0; i < squad.resourceCards.length; i++) {
            resourceCards[i] = squad.resourceCards[i];
        }
        
        return _getAverageChargeLevel(territoryCards, infraCards, resourceCards);
    }

    // ============================================
    // INTERNAL FUNCTIONS - POWER CORE
    // ============================================

    /**
     * @notice Require active power core with sufficient charge
     */
    function _requireActivePowerCoreWithCharge(
        uint256 collectionId,
        uint256 tokenId
    ) internal view {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        // Check if power core exists
        if (hs.performedCharges[combinedId].lastChargeTime == 0) {
            revert PowerCoreNotActive(collectionId, tokenId);
        }
        
        // Check minimum charge level
        uint256 currentCharge = hs.performedCharges[combinedId].currentCharge;
        if (currentCharge < MIN_CHARGE_FOR_STAKING) {
            revert ChargeLevelTooLow(collectionId, tokenId, currentCharge, MIN_CHARGE_FOR_STAKING);
        }
    }

    /**
     * @notice Lock/unlock power core for staked NFT
     * @dev Sets flag bit 0 to prevent charge actions while staked
     */
    function _lockPowerCore(
        uint256 collectionId,
        uint256 tokenId,
        bool lock
    ) internal {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 combinedId = PodsUtils.combineIds(collectionId, tokenId);
        
        // Use flags field bit 0 for lock status
        if (lock) {
            hs.performedCharges[combinedId].flags |= 1; // Set bit 0
        } else {
            hs.performedCharges[combinedId].flags &= ~uint8(1); // Clear bit 0
        }
        
        emit PowerCoreLocked(collectionId, tokenId, lock);
    }
}
