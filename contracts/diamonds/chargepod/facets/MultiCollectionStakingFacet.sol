// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { LibColonyWarsStorage } from "../libraries/LibColonyWarsStorage.sol";
import { LibHenomorphsStorage } from "../libraries/LibHenomorphsStorage.sol";
import { LibMeta } from "../../shared/libraries/LibMeta.sol";
import { AccessControlBase } from "./AccessControlBase.sol";
import { AccessHelper } from "../libraries/AccessHelper.sol";
import { PodsUtils } from "../../libraries/PodsUtils.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

// ============================================
// INTERFACES FOR MODEL D
// ============================================

/**
 * @notice Interface for Territory/Infrastructure Cards (Model D)
 * @dev These contracts implement conditional transfer requiring approval
 */
interface IConditionalTransferToken {
    function requestTransfer(uint256 tokenId, address to) external;
    function approveTransfer(uint256 tokenId, address to) external;
    function completeTransfer(address from, address to, uint256 tokenId) external;
    function rejectTransfer(uint256 tokenId, string calldata reason) external;
    function isTerritoryActive(uint256 tokenId) external view returns (bool);
    function getApprovedTransferTarget(uint256 tokenId) external view returns (address);
}

/**
 * @title MultiCollectionStakingFacet
 * @notice Handles multi-collection token staking for Colony Wars team synergies
 * @dev Part of HenomorphsChargepod Diamond - integrates with Colony Wars system
 * 
 * ARCHITECTURE:
 * - Lives in Chargepod Diamond (NOT Staking Diamond)
 * - Uses LibColonyWarsStorage for team staking data
 * - Uses LibHenomorphsStorage for power core integration
 * - Implements Model D Conditional Transfer for Territory/Infrastructure Cards
 * - Supports multiple collections per item type (Territory/Infrastructure)
 * 
 * KEY FEATURES:
 * - Model D: requestTransfer → approveTransfer → completeTransfer flow
 * - Multi-collection support: tracks collectionId + tokenId pairs
 * - Power core validation and charge level bonuses
 * - Generic token semantics (not hardcoded "NFT")
 * - Proper Diamond Proxy pattern compliance
 * - Active territory validation before staking
 * 
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract MultiCollectionStakingFacet is AccessControlBase, IERC721Receiver {
    using LibColonyWarsStorage for LibColonyWarsStorage.ColonyWarsStorage;

    // ============================================
    // STRUCTS
    // ============================================
    
    /**
     * @notice Represents a staked token with collection tracking
     */
    struct StakedToken {
        uint256 collectionId;
        uint256 tokenId;
    }

    // ============================================
    // ERRORS
    // ============================================
    
    error TeamAlreadyStaked();
    error NoTeamStaked();
    error InvalidCollectionContract();
    error NotTokenOwner();
    error MaxTeamSizeExceeded();
    error TokenAlreadyStaked();
    error TokenNotInTeamStake();
    error ColonyNotRegistered();
    error InvalidArrayLength();
    error PowerCoreNotActive(uint256 collectionId, uint256 tokenId);
    error ChargeLevelTooLow(uint256 collectionId, uint256 tokenId, uint256 current, uint256 required);
    error TerritoryNotActive(uint256 tokenId);
    error TransferNotApproved(uint256 tokenId);
    error ModelDTransferFailed(uint256 tokenId, string reason);
    error CollectionNotRegistered(uint256 collectionId);
    error InvalidItemType();

    // ============================================
    // EVENTS
    // ============================================
    
    event TeamStaked(
        bytes32 indexed colonyId, 
        StakedToken[] territoryTokens, 
        StakedToken[] infraTokens, 
        uint16 synergyBonus
    );
    
    event TeamUnstaked(
        bytes32 indexed colonyId, 
        StakedToken[] territoryTokens, 
        StakedToken[] infraTokens
    );
    
    event SynergyBonusUpdated(
        bytes32 indexed colonyId, 
        uint16 newBonus
    );
    
    event TeamMemberAdded(
        bytes32 indexed colonyId, 
        uint256 itemType,
        uint256 collectionId,
        uint256 tokenId
    );
    
    event TeamMemberRemoved(
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
    
    event ModelDTransferInitiated(
        uint256 indexed collectionId,
        uint256 indexed tokenId,
        address indexed from,
        address to
    );
    
    event ModelDTransferCompleted(
        uint256 indexed collectionId,
        uint256 indexed tokenId,
        address indexed from,
        address to
    );
    
    event CollectionRegistered(
        uint256 indexed collectionId,
        address indexed contractAddress,
        uint8 itemType
    );

    // ============================================
    // CONSTANTS
    // ============================================
    
    uint8 constant MAX_TERRITORIES_IN_TEAM = 3;
    uint8 constant MAX_INFRASTRUCTURE_IN_TEAM = 5;
    uint256 constant MIN_CHARGE_FOR_STAKING = 50; // Minimum 50% charge required
    
    // Item Type identifiers
    uint8 constant ITEM_TYPE_TERRITORY = 1;
    uint8 constant ITEM_TYPE_INFRASTRUCTURE = 2;

    // ============================================
    // IERC721RECEIVER IMPLEMENTATION
    // ============================================

    /**
     * @notice Implementation of IERC721Receiver for safe transfers
     * @dev Only accepts transfers from authorized addresses or during team staking
     */
    function onERC721Received(
        address,
        address from,
        uint256,
        bytes calldata
    ) external view override returns (bytes4) {
        // Accept from authorized addresses or internal calls
        if (AccessHelper.isAuthorized() || AccessHelper.isInternalCall()) {
            return IERC721Receiver.onERC721Received.selector;
        }
        
        // Accept if from is this contract (for internal operations)
        if (from == address(this)) {
            return IERC721Receiver.onERC721Received.selector;
        }
        
        revert AccessHelper.Unauthorized(from, "Unauthorized token transfer");
    }

    // ============================================
    // MAIN STAKING FUNCTIONS
    // ============================================

    /**
     * @notice Stake a complete team of tokens from multiple collections
     * @dev Uses Model D: validates → requests → approves → completes transfer
     * @param colonyId Colony to stake for
     * @param territoryTokens Array of territory tokens (collectionId, tokenId pairs)
     * @param infraTokens Array of infrastructure tokens (collectionId, tokenId pairs)
     */
    function stakeTeam(
        bytes32 colonyId,
        StakedToken[] calldata territoryTokens,
        StakedToken[] calldata infraTokens
    ) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        // Validate colony ownership
        address caller = LibMeta.msgSender();
        require(cws.userToColony[caller] == colonyId, "Not colony owner");
        
        // Validate colony is registered for current season
        if (!cws.colonyWarProfiles[colonyId].registered) {
            revert ColonyNotRegistered();
        }
        
        // Check if team already staked
        LibColonyWarsStorage.SquadStakePosition storage squad = cws.colonySquadStakes[colonyId];
        if (squad.active) revert TeamAlreadyStaked();
        
        // Validate team size
        if (territoryTokens.length > MAX_TERRITORIES_IN_TEAM) revert MaxTeamSizeExceeded();
        if (infraTokens.length > MAX_INFRASTRUCTURE_IN_TEAM) revert MaxTeamSizeExceeded();

        // Stake Territory tokens using Model D
        for (uint256 i = 0; i < territoryTokens.length; i++) {
            _stakeToken(
                cws,
                territoryTokens[i].collectionId,
                territoryTokens[i].tokenId,
                colonyId,
                ITEM_TYPE_TERRITORY
            );
        }

        // Stake Infrastructure tokens using Model D
        for (uint256 i = 0; i < infraTokens.length; i++) {
            _stakeToken(
                cws,
                infraTokens[i].collectionId,
                infraTokens[i].tokenId,
                colonyId,
                ITEM_TYPE_INFRASTRUCTURE
            );
        }

        // Calculate synergy bonus with charge level consideration
        uint16 synergyBonus = _calculateTeamSynergy(
            territoryTokens,
            infraTokens
        );

        // Update squad position
        squad.stakedAt = uint32(block.timestamp);
        squad.totalSynergyBonus = synergyBonus;
        squad.uniqueCollectionsCount = uint8(cws.colonyActiveCollections[colonyId].length);
        squad.active = true;

        emit TeamStaked(colonyId, territoryTokens, infraTokens, synergyBonus);
    }

    /**
     * @notice Unstake complete team and return all tokens
     * @dev Uses Model D reverse flow for safe return
     * @param colonyId Colony to unstake from
     */
    function unstakeTeam(bytes32 colonyId) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        // Validate colony ownership
        address caller = LibMeta.msgSender();
        require(cws.userToColony[caller] == colonyId, "Not colony owner");
        
        LibColonyWarsStorage.SquadStakePosition storage squad = cws.colonySquadStakes[colonyId];
        if (!squad.active) revert NoTeamStaked();

        // Prepare output arrays for event
        StakedToken[] memory territoryTokens = new StakedToken[](squad.territoryCards.length);
        StakedToken[] memory infraTokens = new StakedToken[](squad.infraCards.length);

        // Unstake Territory tokens using Model D
        for (uint256 i = 0; i < squad.territoryCards.length; i++) {
            uint256 collectionId = squad.territoryCards[i].collectionId;
            uint256 tokenId = squad.territoryCards[i].tokenId;
            _unstakeToken(
                cws,
                collectionId,
                tokenId,
                colonyId,
                ITEM_TYPE_TERRITORY
            );
            territoryTokens[i] = StakedToken(collectionId, tokenId);
        }

        // Unstake Infrastructure tokens using Model D
        for (uint256 i = 0; i < squad.infraCards.length; i++) {
            uint256 collectionId = squad.infraCards[i].collectionId;
            uint256 tokenId = squad.infraCards[i].tokenId;
            _unstakeToken(
                cws,
                collectionId,
                tokenId,
                colonyId,
                ITEM_TYPE_INFRASTRUCTURE
            );
            infraTokens[i] = StakedToken(collectionId, tokenId);
        }

        emit TeamUnstaked(colonyId, territoryTokens, infraTokens);

        // Clear squad position
        delete cws.colonySquadStakes[colonyId];
    }

    /**
     * @notice Add a single token to existing team
     * @param colonyId Colony to add token to
     * @param collectionId Collection ID of the token
     * @param tokenId Token ID to add
     * @param itemType Item type (1=Territory, 2=Infrastructure)
     */
    function addTeamMember(
        bytes32 colonyId,
        uint256 collectionId,
        uint256 tokenId,
        uint8 itemType
    ) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        // Validate colony ownership
        address caller = LibMeta.msgSender();
        require(cws.userToColony[caller] == colonyId, "Not colony owner");
        
        LibColonyWarsStorage.SquadStakePosition storage squad = cws.colonySquadStakes[colonyId];
        if (!squad.active) revert NoTeamStaked();
        
        // Validate item type
        if (itemType != ITEM_TYPE_TERRITORY && itemType != ITEM_TYPE_INFRASTRUCTURE) {
            revert InvalidItemType();
        }
        
        // Validate team size limits
        bool isTerritory = (itemType == ITEM_TYPE_TERRITORY);
        if (isTerritory && squad.territoryCards.length >= MAX_TERRITORIES_IN_TEAM) {
            revert MaxTeamSizeExceeded();
        }
        if (!isTerritory && squad.infraCards.length >= MAX_INFRASTRUCTURE_IN_TEAM) {
            revert MaxTeamSizeExceeded();
        }

        // Stake the token using Model D
        _stakeToken(cws, collectionId, tokenId, colonyId, itemType);

        // Recalculate synergy bonus
        squad.totalSynergyBonus = _calcSquadSynergy(squad);
        squad.uniqueCollectionsCount = uint8(cws.colonyActiveCollections[colonyId].length);

        emit TeamMemberAdded(colonyId, itemType, collectionId, tokenId);
        emit SynergyBonusUpdated(colonyId, squad.totalSynergyBonus);
    }

    /**
     * @notice Remove a single token from team
     * @param colonyId Colony to remove token from
     * @param collectionId Collection ID of the token
     * @param tokenId Token ID to remove
     * @param itemType Item type (1=Territory, 2=Infrastructure)
     */
    function removeTeamMember(
        bytes32 colonyId,
        uint256 collectionId,
        uint256 tokenId,
        uint8 itemType
    ) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        // Validate colony ownership
        address caller = LibMeta.msgSender();
        require(cws.userToColony[caller] == colonyId, "Not colony owner");
        
        LibColonyWarsStorage.SquadStakePosition storage squad = cws.colonySquadStakes[colonyId];
        if (!squad.active) revert NoTeamStaked();

        // Validate item type
        if (itemType != ITEM_TYPE_TERRITORY && itemType != ITEM_TYPE_INFRASTRUCTURE) {
            revert InvalidItemType();
        }

        // Verify token is in squad and find its index
        bool found = false;
        bool isTerritory = (itemType == ITEM_TYPE_TERRITORY);
        
        if (isTerritory) {
            for (uint256 i = 0; i < squad.territoryCards.length; i++) {
                if (squad.territoryCards[i].collectionId == collectionId && 
                    squad.territoryCards[i].tokenId == tokenId) {
                    found = true;
                    break;
                }
            }
        } else {
            for (uint256 i = 0; i < squad.infraCards.length; i++) {
                if (squad.infraCards[i].collectionId == collectionId && 
                    squad.infraCards[i].tokenId == tokenId) {
                    found = true;
                    break;
                }
            }
        }

        if (!found) revert TokenNotInTeamStake();

        // Unstake the token using Model D (this also removes from squad arrays via storage helper)
        _unstakeToken(cws, collectionId, tokenId, colonyId, itemType);

        // Recalculate synergy bonus
        squad.totalSynergyBonus = _calcSquadSynergy(squad);
        squad.uniqueCollectionsCount = uint8(cws.colonyActiveCollections[colonyId].length);

        emit TeamMemberRemoved(colonyId, itemType, collectionId, tokenId);
        emit SynergyBonusUpdated(colonyId, squad.totalSynergyBonus);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get colony's complete staked team info
     */
    function getColonyTeam(bytes32 colonyId) 
        external 
        view 
        returns (LibColonyWarsStorage.SquadStakePosition memory) 
    {
        return LibColonyWarsStorage.colonyWarsStorage().colonySquadStakes[colonyId];
    }

    /**
     * @notice Get colony team as StakedToken arrays (with collection IDs)
     */
    function getColonyTeamDetailed(bytes32 colonyId)
        external
        view
        returns (
            StakedToken[] memory territoryTokens,
            StakedToken[] memory infraTokens,
            uint32 stakedAt,
            uint16 synergyBonus,
            bool active
        )
    {
        LibColonyWarsStorage.SquadStakePosition storage squad = 
            LibColonyWarsStorage.colonyWarsStorage().colonySquadStakes[colonyId];
        
        if (!squad.active) {
            return (new StakedToken[](0), new StakedToken[](0), 0, 0, false);
        }
        
        // Convert CompositeCardId to StakedToken structs
        territoryTokens = new StakedToken[](squad.territoryCards.length);
        for (uint256 i = 0; i < squad.territoryCards.length; i++) {
            territoryTokens[i] = StakedToken(
                squad.territoryCards[i].collectionId,
                squad.territoryCards[i].tokenId
            );
        }
        
        infraTokens = new StakedToken[](squad.infraCards.length);
        for (uint256 i = 0; i < squad.infraCards.length; i++) {
            infraTokens[i] = StakedToken(
                squad.infraCards[i].collectionId,
                squad.infraCards[i].tokenId
            );
        }
        
        return (territoryTokens, infraTokens, squad.stakedAt, squad.totalSynergyBonus, true);
    }

    /**
     * @notice Get total team synergy bonus for colony
     */
    function getTeamBonus(bytes32 colonyId) external view returns (uint16) {
        LibColonyWarsStorage.SquadStakePosition storage squad = 
            LibColonyWarsStorage.colonyWarsStorage().colonySquadStakes[colonyId];
        return squad.active ? squad.totalSynergyBonus : 0;
    }

    /**
     * @notice Check if token is staked in a team
     */
    function isTokenStakedInTeam(uint256 collectionId, uint256 tokenId, uint8 itemType) 
        external 
        view 
        returns (bool staked, bytes32 colonyId) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        if (itemType == ITEM_TYPE_TERRITORY) {
            colonyId = cws.stakedTerritoryOwnerByCollection[collectionId][tokenId];
        } else if (itemType == ITEM_TYPE_INFRASTRUCTURE) {
            colonyId = cws.stakedInfraOwnerByCollection[collectionId][tokenId];
        }
        
        staked = colonyId != bytes32(0);
    }

    /**
     * @notice Get detailed team statistics
     */
    function getTeamStatistics(bytes32 colonyId) 
        external 
        view 
        returns (
            uint256 territoryCount,
            uint256 infraCount,
            uint256 avgChargeLevel,
            uint256 stakeDuration
        ) 
    {
        LibColonyWarsStorage.SquadStakePosition storage squad = 
            LibColonyWarsStorage.colonyWarsStorage().colonySquadStakes[colonyId];
        
        if (!squad.active) {
            return (0, 0, 0, 0);
        }
        
        territoryCount = squad.territoryCards.length;
        infraCount = squad.infraCards.length;
        stakeDuration = block.timestamp - squad.stakedAt;
        
        avgChargeLevel = _getSquadCharge(squad);
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Admin: Emergency unstake if needed
     */
    function emergencyUnstakeTeam(bytes32 colonyId) 
        external 
        onlyAuthorized
        nonReentrant
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.SquadStakePosition storage squad = cws.colonySquadStakes[colonyId];
        
        if (!squad.active) revert NoTeamStaked();
        
        address colonyOwner = LibHenomorphsStorage.henomorphsStorage().colonyCreators[colonyId];
        require(colonyOwner != address(0), "Invalid colony");

        StakedToken[] memory territoryTokens = new StakedToken[](squad.territoryCards.length);
        StakedToken[] memory infraTokens = new StakedToken[](squad.infraCards.length);

        // Emergency return using Model D (admin bypass)
        for (uint256 i = 0; i < squad.territoryCards.length; i++) {
            uint256 collectionId = squad.territoryCards[i].collectionId;
            uint256 tokenId = squad.territoryCards[i].tokenId;
            territoryTokens[i] = StakedToken(collectionId, tokenId);
            
            LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
            address contractAddress = hs.specimenCollections[collectionId].collectionAddress;
            
            IConditionalTransferToken token = IConditionalTransferToken(contractAddress);
            token.approveTransfer(tokenId, colonyOwner);
            token.completeTransfer(address(this), colonyOwner, tokenId);
            
            // Clear staking records using storage helper
            LibColonyWarsStorage.markTokenUnstaked(collectionId, tokenId, colonyId, true, false);
            _lockPowerCore(collectionId, tokenId, false);
        }

        for (uint256 i = 0; i < squad.infraCards.length; i++) {
            uint256 collectionId = squad.infraCards[i].collectionId;
            uint256 tokenId = squad.infraCards[i].tokenId;
            infraTokens[i] = StakedToken(collectionId, tokenId);
            
            LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
            address contractAddress = hs.specimenCollections[collectionId].collectionAddress;
            
            IConditionalTransferToken token = IConditionalTransferToken(contractAddress);
            token.approveTransfer(tokenId, colonyOwner);
            token.completeTransfer(address(this), colonyOwner, tokenId);
            
            // Clear staking records using storage helper
            LibColonyWarsStorage.markTokenUnstaked(collectionId, tokenId, colonyId, false, false);
            _lockPowerCore(collectionId, tokenId, false);
        }

        emit TeamUnstaked(colonyId, territoryTokens, infraTokens);
        delete cws.colonySquadStakes[colonyId];
    }

    // ============================================
    // INTERNAL FUNCTIONS - MODEL D IMPLEMENTATION
    // ============================================

    /**
     * @notice Internal: Stake token using Model D conditional transfer
     * @dev Flow: validate → approve → complete transfer → lock power core
     */
    function _stakeToken(
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        uint256 collectionId,
        uint256 tokenId,
        bytes32 colonyId,
        uint8 itemType
    ) internal {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Get collection contract address
        address contractAddress = hs.specimenCollections[collectionId].collectionAddress;
        if (contractAddress == address(0)) revert CollectionNotRegistered(collectionId);
        
        IConditionalTransferToken token = IConditionalTransferToken(contractAddress);
        IERC721 tokenERC721 = IERC721(contractAddress);
        
        // Validate ownership using meta-transaction sender
        address caller = LibMeta.msgSender();
        if (tokenERC721.ownerOf(tokenId) != caller) revert NotTokenOwner();
        
        // Check not already staked in team (using multi-collection storage)
        bytes32 existingOwner;
        bool isTerritory = (itemType == ITEM_TYPE_TERRITORY);
        
        if (isTerritory) {
            existingOwner = cws.stakedTerritoryOwnerByCollection[collectionId][tokenId];
        } else {
            existingOwner = cws.stakedInfraOwnerByCollection[collectionId][tokenId];
        }
        
        if (existingOwner != bytes32(0)) revert TokenAlreadyStaked();

        // Validate territory is active (only for territories)
        if (itemType == ITEM_TYPE_TERRITORY) {
            bool active = token.isTerritoryActive(tokenId);
            if (!active) revert TerritoryNotActive(tokenId);
        }

        // Validate power core (if applicable)
        _requireActivePowerCoreWithCharge(collectionId, tokenId);

        // MODEL D FLOW:
        // Step 1: This contract (COLONY_WARS_ROLE) approves the transfer
        token.approveTransfer(tokenId, address(this));
        
        emit ModelDTransferInitiated(collectionId, tokenId, caller, address(this));
        
        // Step 2: Complete the transfer
        token.completeTransfer(caller, address(this), tokenId);
        
        emit ModelDTransferCompleted(collectionId, tokenId, caller, address(this));
        
        // Mark as staked in team using storage helpers
        LibColonyWarsStorage.markTokenStaked(collectionId, tokenId, colonyId, isTerritory, false);
        LibColonyWarsStorage.addCardToSquad(colonyId, collectionId, tokenId, isTerritory, false);

        // Lock power core
        _lockPowerCore(collectionId, tokenId, true);
    }

    /**
     * @notice Internal: Unstake token using Model D reverse flow
     */
    function _unstakeToken(
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        uint256 collectionId,
        uint256 tokenId,
        bytes32 colonyId,
        uint8 itemType
    ) internal {
        // Verify ownership in team (using multi-collection storage)
        bool isTerritory = (itemType == ITEM_TYPE_TERRITORY);
        bytes32 owner;
        
        if (isTerritory) {
            owner = cws.stakedTerritoryOwnerByCollection[collectionId][tokenId];
        } else {
            owner = cws.stakedInfraOwnerByCollection[collectionId][tokenId];
        }
        
        if (owner != colonyId) revert TokenNotInTeamStake();

        // Unlock power core
        _lockPowerCore(collectionId, tokenId, false);

        // MODEL D FLOW for return:
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        address contractAddress = hs.specimenCollections[collectionId].collectionAddress;
        
        IConditionalTransferToken token = IConditionalTransferToken(contractAddress);
        address caller = LibMeta.msgSender();
        
        // Step 1: Approve return to original owner
        token.approveTransfer(tokenId, caller);
        
        emit ModelDTransferInitiated(collectionId, tokenId, address(this), caller);
        
        // Step 2: Complete transfer back
        token.completeTransfer(address(this), caller, tokenId);
        
        emit ModelDTransferCompleted(collectionId, tokenId, address(this), caller);
        
        // Clear staking record using storage helpers
        LibColonyWarsStorage.markTokenUnstaked(collectionId, tokenId, colonyId, isTerritory, false);
        LibColonyWarsStorage.removeCardFromSquad(colonyId, collectionId, tokenId, isTerritory, false);
    }

    // ============================================
    // INTERNAL FUNCTIONS - CALCULATIONS
    // ============================================

    /**
     * @notice Calculate team synergy bonus with charge level consideration
     */
    function _calculateTeamSynergy(
        StakedToken[] memory territoryTokens,
        StakedToken[] memory infraTokens
    ) internal view returns (uint16) {
        uint16 bonus = 0;

        // Base bonus: 50 (5%)
        if (territoryTokens.length > 0 || infraTokens.length > 0) {
            bonus += 50;
        }

        // Territory bonus: 30 (3%) per territory, max 90 (9%)
        uint16 territoryBonus = uint16(territoryTokens.length * 30);
        if (territoryBonus > 90) territoryBonus = 90;
        bonus += territoryBonus;

        // Infrastructure bonus: 20 (2%) per infra, max 100 (10%)
        uint16 infraBonus = uint16(infraTokens.length * 20);
        if (infraBonus > 100) infraBonus = 100;
        bonus += infraBonus;

        // Full team bonus: +100 (10%)
        if (territoryTokens.length == MAX_TERRITORIES_IN_TEAM && 
            infraTokens.length == MAX_INFRASTRUCTURE_IN_TEAM) {
            bonus += 100;
        }

        // Charge level bonus: +1% per 10 avg charge, max +10%
        uint256 avgCharge = _getAverageChargeLevel(territoryTokens, infraTokens);
        
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
    function _calcSquadSynergy(
        LibColonyWarsStorage.SquadStakePosition storage squad
    ) internal view returns (uint16) {
        // Convert storage CompositeCardId arrays to StakedToken arrays
        StakedToken[] memory territoryTokens = new StakedToken[](squad.territoryCards.length);
        for (uint256 i = 0; i < squad.territoryCards.length; i++) {
            territoryTokens[i] = StakedToken(
                squad.territoryCards[i].collectionId,
                squad.territoryCards[i].tokenId
            );
        }
        
        StakedToken[] memory infraTokens = new StakedToken[](squad.infraCards.length);
        for (uint256 i = 0; i < squad.infraCards.length; i++) {
            infraTokens[i] = StakedToken(
                squad.infraCards[i].collectionId,
                squad.infraCards[i].tokenId
            );
        }
        
        return _calculateTeamSynergy(territoryTokens, infraTokens);
    }

    /**
     * @notice Get average charge level across all team tokens
     */
    function _getAverageChargeLevel(
        StakedToken[] memory territoryTokens,
        StakedToken[] memory infraTokens
    ) internal view returns (uint256) {
        if (territoryTokens.length == 0 && infraTokens.length == 0) {
            return 0;
        }

        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        uint256 totalCharge = 0;
        uint256 totalCount = 0;

        // Sum territory charges
        for (uint256 i = 0; i < territoryTokens.length; i++) {
            uint256 combinedId = PodsUtils.combineIds(territoryTokens[i].collectionId, territoryTokens[i].tokenId);
            uint256 charge = hs.performedCharges[combinedId].currentCharge;
            if (charge > 0) {
                totalCharge += charge;
                totalCount++;
            }
        }

        // Sum infrastructure charges
        for (uint256 i = 0; i < infraTokens.length; i++) {
            uint256 combinedId = PodsUtils.combineIds(infraTokens[i].collectionId, infraTokens[i].tokenId);
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
     * @notice Get average charge level from storage
     */
    function _getSquadCharge(
        LibColonyWarsStorage.SquadStakePosition storage squad
    ) internal view returns (uint256) {
        // Convert to StakedToken arrays
        StakedToken[] memory territoryTokens = new StakedToken[](squad.territoryCards.length);
        for (uint256 i = 0; i < squad.territoryCards.length; i++) {
            territoryTokens[i] = StakedToken(
                squad.territoryCards[i].collectionId,
                squad.territoryCards[i].tokenId
            );
        }
        
        StakedToken[] memory infraTokens = new StakedToken[](squad.infraCards.length);
        for (uint256 i = 0; i < squad.infraCards.length; i++) {
            infraTokens[i] = StakedToken(
                squad.infraCards[i].collectionId,
                squad.infraCards[i].tokenId
            );
        }
        
        return _getAverageChargeLevel(territoryTokens, infraTokens);
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
     * @notice Lock/unlock power core for staked token
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
