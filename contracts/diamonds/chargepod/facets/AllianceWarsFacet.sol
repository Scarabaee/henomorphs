// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {ColonyHelper} from "../libraries/ColonyHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";

interface IDebtWarsFacet {
    function getCurrentColonyDebt(bytes32 colonyId) external view returns (uint256);
}


/**
 * @title AllianceWarsFacet
 * @notice Complete secure alliance management for Colony Wars
 */
contract AllianceWarsFacet is AccessControlBase {

    struct AllianceInfo {
        bytes32 allianceId;
        string name;
        bytes32 leaderColony;
        uint256 memberCount;
        uint256 sharedTreasury;
        uint32 stabilityIndex;
        bool active;
    }
    
    // Events
    event AllianceCreated(bytes32 indexed allianceId, string name, bytes32 indexed leaderColony);
    event ColonyJoinedAlliance(bytes32 indexed allianceId, bytes32 indexed colony);
    event ColonyLeftAlliance(bytes32 indexed allianceId, bytes32 indexed colony, string reason);
    event EmergencyAidSent(bytes32 indexed fromAlliance, bytes32 indexed toColony, uint256 amount);
    event BetrayalRecorded(bytes32 indexed betrayerColony, bytes32 indexed victimAlliance);
    event AllianceContribution(bytes32 indexed allianceId, bytes32 indexed colony, uint256 amount);
    event AllianceDisbanded(bytes32 indexed allianceId, string reason);
    event LeadershipTransferred(bytes32 indexed allianceId, bytes32 indexed oldLeader, bytes32 indexed newLeader);
    event AlliancesCleared(uint256 count);
    event ForgivenessProposed(bytes32 indexed allianceId, bytes32 indexed betrayerColony, address indexed proposer);
    event ForgivenessVoteCast(bytes32 indexed allianceId, address indexed voter, bool vote);
    event BetrayalForgiven(bytes32 indexed allianceId, bytes32 indexed betrayerColony);
    event ForgivenessRejected(bytes32 indexed allianceId, bytes32 indexed betrayerColony);
    event PrimaryColonyChanged(address indexed owner, bytes32 indexed oldPrimaryColony, bytes32 indexed newPrimaryColony);
    event AdminPrimaryColonyChanged(address indexed targetUser, bytes32 indexed oldPrimaryColony, bytes32 indexed newPrimaryColony, address admin);
    event InvitationSent(bytes32 indexed allianceId, address indexed targetUser, address indexed inviter);
    event InvitationAccepted(bytes32 indexed allianceId, address indexed accepter);
    event InvitationDeclined(bytes32 indexed allianceId, address indexed decliner);
    
    // Custom errors
    error AllianceNotFound();
    error ColonyNotInAlliance();
    error AllianceAtCapacity();
    error AllianceAlreadyExists();
    error BetrayalCooldownActive();
    error InsufficientSharedFunds();
    error InvalidAllianceName();
    error NotAllianceLeader();
    error TargetNotInAlliance();
    error RateLimitExceeded();
    error CannotLeaveAsLeader();
    error AllianceNotEmpty();
    error InvalidEmergencyAmount();
    error ColonyNotRegistered();
    error SameColony();
    error ColonyDebtTooHigh();
    error FormationNotYetAllowed();
    error InvitationNotFound();
    error InvitationExpired();
    error CannotInviteSelf();
    error NoPrimaryColony();
    
    
    /**
     * @notice Create new alliance - simplified and more reliable implementation
     * @param name Alliance name
     * @param leaderColony Colony ID that will lead the alliance (optional - uses primary if not provided)
     */
    function createAlliance(string calldata name, bytes32 leaderColony) 
        external 
        whenNotPaused 
        nonReentrant 
        returns (bytes32 allianceId) 
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("alliances");
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        address user = LibMeta.msgSender();
        
        // 1. BASIC VALIDATIONS (fail fast)
        if (bytes(name).length == 0 || bytes(name).length > 50) {
            revert InvalidAllianceName();
        }
        
        if (LibColonyWarsStorage.isUserInAlliance(user)) {
            revert AllianceAlreadyExists();
        }
        
        // 2. DETERMINE LEADER COLONY
        if (leaderColony == bytes32(0)) {
            leaderColony = LibColonyWarsStorage.getUserPrimaryColony(user);
            if (leaderColony == bytes32(0)) {
                revert AccessHelper.Unauthorized(user, "No colony specified and no primary colony set");
            }
        }
        
        // 3. VALIDATE COLONY OWNERSHIP
        if (!ColonyHelper.isColonyCreator(leaderColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(user, "Not colony controller");
        }
        
        // 4. VALIDATE COLONY STATUS
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[leaderColony];
        if (!profile.registered) {
            revert ColonyNotRegistered();
        }
        
        // 5. CHECK BETRAYAL COOLDOWN
        if (_hasActiveBetrayalCooldown(leaderColony)) {
            revert BetrayalCooldownActive();
        }
        
        // 6. RATE LIMITING (simplified - only for this function)
        if (!LibColonyWarsStorage.checkRateLimit(user, this.createAlliance.selector, 86400)) {
            revert RateLimitExceeded();
        }
        
        // 7. SEASON VALIDATION (simplified)
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
        if (!season.active && (block.timestamp > season.startTime)) {
            revert FormationNotYetAllowed();
        }

        // 8. COLLECT FORMATION FEE
        address currency = hs.chargeTreasury.treasuryCurrency;
        LibFeeCollection.collectFee(
            IERC20(currency),
            user,
            hs.chargeTreasury.treasuryAddress,
            cws.config.allianceFormationCost,
            "alliance_formation"
        );
        
        // 9. CREATE ALLIANCE (simplified)
        allianceId = keccak256(abi.encodePacked(
            "alliance", 
            block.timestamp,
            user,
            leaderColony
        ));
        
        LibColonyWarsStorage.Alliance storage alliance = cws.alliances[allianceId];
        alliance.leaderColony = leaderColony;
        alliance.sharedTreasury = cws.config.allianceFormationCost;
        alliance.stabilityIndex = 100;
        alliance.active = true;
        alliance.name = name;
        
        // 10. ADD LEADER AS FIRST MEMBER USING CONSISTENT LOGIC
        // This handles all validation and mapping updates consistently
        LibColonyWarsStorage.addAllianceMember(allianceId, user);
        
        // Set as primary colony if user doesn't have one
        if (LibColonyWarsStorage.getUserPrimaryColony(user) == bytes32(0) && leaderColony != bytes32(0)) {
            LibColonyWarsStorage.setUserPrimaryColony(user, leaderColony);
        }
        
        // Update legacy mapping for compatibility
        cws.userToColony[user] = leaderColony;
        
        // 11. UPDATE TRACKING ARRAYS
        cws.allAllianceIds.push(allianceId);
        cws.seasonAlliances[cws.currentSeason].push(allianceId);
        
        emit AllianceCreated(allianceId, name, leaderColony);
        
        return allianceId;
    }
    
    /**
     * @notice Join existing alliance - improved implementation using addAllianceMember
     * @param allianceId Alliance to join
     * @param joiningColony Colony ID that will join (optional - uses primary if not provided)
     */
    function joinAlliance(bytes32 allianceId, bytes32 joiningColony) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("alliances");
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        address user = LibMeta.msgSender();
        
        // 1. VALIDATE ALLIANCE EXISTS AND IS ACTIVE
        LibColonyWarsStorage.Alliance storage alliance = cws.alliances[allianceId];
        if (!alliance.active) {
            revert AllianceNotFound();
        }
        
        // 2. DETERMINE JOINING COLONY
        if (joiningColony == bytes32(0)) {
            joiningColony = LibColonyWarsStorage.getUserPrimaryColony(user);
            if (joiningColony == bytes32(0)) {
                revert AccessHelper.Unauthorized(user, "No colony specified and no primary colony set");
            }
        }
        
        // 3. VALIDATE COLONY OWNERSHIP AND CONTROL
        if (!ColonyHelper.isColonyCreator(joiningColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(user, "Not colony controller");
        }
        
        // 4. VALIDATE COLONY STATUS
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[joiningColony];
        if (!profile.registered) {
            revert ColonyNotRegistered();
        }
        
        // 5. CHECK BETRAYAL COOLDOWN
        if (_hasActiveBetrayalCooldown(joiningColony)) {
            revert BetrayalCooldownActive();
        }
        
        // 6. VALIDATE NOT SAME AS LEADER
        if (joiningColony == alliance.leaderColony) {
            revert SameColony();
        }
        
        // 7. VALIDATE DEBT ELIGIBILITY (if DebtWarsFacet available)
        if (!_validateDebtEligibility(joiningColony)) {
            revert ColonyDebtTooHigh();
        }
        
        // 8. VALIDATE SEASON IS ACTIVE (optional check)
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
        if (!season.active && (block.timestamp > season.startTime)) {
            revert FormationNotYetAllowed();
        }
        
        // 9. USE addAllianceMember FOR CONSISTENT VALIDATION AND ADDING
        // This function handles:
        // - Capacity check
        // - Primary colony validation
        // - Ownership uniqueness check
        // - All mappings updates
        LibColonyWarsStorage.addAllianceMember(allianceId, user);
        
        // 10. SET PRIMARY COLONY IF NEEDED
        if (LibColonyWarsStorage.getUserPrimaryColony(user) == bytes32(0) && joiningColony != bytes32(0)) {
            LibColonyWarsStorage.setUserPrimaryColony(user, joiningColony);
        }
        
        // 11. UPDATE LEGACY MAPPING FOR COMPATIBILITY
        cws.userToColony[user] = joiningColony;
        
        emit ColonyJoinedAlliance(allianceId, joiningColony);
    }
    
    /**
     * @notice Leave current alliance
     */
    function leaveAlliance(string calldata reason) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        bytes32 leavingColony = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());
        if (leavingColony == bytes32(0)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "No colony found");
        }
        if (!ColonyHelper.isColonyCreator(leavingColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony controller");
        }
        
        // FIXED: Get alliance ID using corrected mapping
        bytes32 allianceId = LibColonyWarsStorage.getUserAllianceId(LibMeta.msgSender());
        if (allianceId == bytes32(0)) {
            revert ColonyNotInAlliance();
        }
        
        LibColonyWarsStorage.Alliance storage alliance = cws.alliances[allianceId];
        
        // Leader cannot leave unless transferring leadership or disbanding
        if (leavingColony == alliance.leaderColony && alliance.members.length > 1) {
            revert CannotLeaveAsLeader();
        }
        
        // Remove from alliance using helper function
        LibColonyWarsStorage.removeAllianceMember(allianceId, LibMeta.msgSender());
        
        // Reduce stability for voluntary departures
        if (alliance.active && alliance.stabilityIndex > 10) {
            alliance.stabilityIndex -= 10;
        } else {
            alliance.stabilityIndex = 0;
        }
        
        emit ColonyLeftAlliance(allianceId, leavingColony, reason);
        
        // If alliance becomes empty, mark as disbanded
        if (alliance.members.length == 0) {
            alliance.active = false;
            emit AllianceDisbanded(allianceId, "No members remaining");
        }
    }
    
    /**
     * @notice Contribute ZICO to alliance treasury
     */
    function contributeToTreasury(uint256 amount) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("alliances");
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();

        bytes32 contributingColony = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());
        if (contributingColony == bytes32(0)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "No colony found");
        }
        if (!ColonyHelper.isColonyCreator(contributingColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony controller");
        }
        
        // FIXED: Get alliance ID using corrected mapping
        bytes32 allianceId = LibColonyWarsStorage.getUserAllianceId(LibMeta.msgSender());
        if (allianceId == bytes32(0)) {
            revert ColonyNotInAlliance();
        }
        if (amount == 0) {
            revert InvalidEmergencyAmount();
        }
        
        LibColonyWarsStorage.Alliance storage alliance = cws.alliances[allianceId];
        if (!alliance.active) {
            revert AllianceNotFound();
        }
        
        // Transfer ZICO to contract (alliance treasury)
        address currency = hs.chargeTreasury.treasuryCurrency;
        LibFeeCollection.collectFee(
            IERC20(currency),
            LibMeta.msgSender(),
            hs.chargeTreasury.treasuryAddress,
            amount,
            "alliance_contribution"
        );
        
        // Update alliance treasury
        alliance.sharedTreasury += amount;
        
        emit AllianceContribution(allianceId, contributingColony, amount);
    }
    
    /**
     * @notice Send emergency aid from alliance treasury to member colony
     */
    function sendEmergencyAid(bytes32 targetColony, uint256 amount) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("alliances");
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        bytes32 senderColony = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());
        if (senderColony == bytes32(0)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "No colony found");
        }
        
        // FIXED: Get alliance ID using corrected mapping
        bytes32 allianceId = LibColonyWarsStorage.getUserAllianceId(LibMeta.msgSender());
        if (allianceId == bytes32(0)) {
            revert ColonyNotInAlliance();
        }
        
        LibColonyWarsStorage.Alliance storage alliance = cws.alliances[allianceId];
        if (!alliance.active) {
            revert AllianceNotFound();
        }
        
        // Only leader can send emergency aid
        if (senderColony != alliance.leaderColony) {
            revert NotAllianceLeader();
        }
        
        // Validate amount
        if (amount == 0 || amount > cws.config.emergencyLoanLimit) {
            revert InvalidEmergencyAmount();
        }
        if (alliance.sharedTreasury < amount) {
            revert InsufficientSharedFunds();
        }
        
        // Check if target colony exists and is in same alliance
        address targetCreator = hs.colonyCreators[targetColony];
        if (targetCreator == address(0)) {
            revert TargetNotInAlliance();
        }
        // FIXED: Check alliance membership using corrected mapping
        if (LibColonyWarsStorage.getUserAllianceId(targetCreator) != allianceId) {
            revert TargetNotInAlliance();
        }
        
        // Cannot send aid to self
        if (targetColony == senderColony) {
            revert SameColony();
        }
        
        // Deduct from alliance treasury
        alliance.sharedTreasury -= amount;
        
        // Transfer aid directly to target colony creator
        LibFeeCollection.transferFromTreasury(targetCreator, amount, "emergency_aid");
        
        emit EmergencyAidSent(allianceId, targetColony, amount);
    }
    
    /**
     * @notice Record betrayal by alliance member
     */
    function recordBetrayal(bytes32 betrayerColony, string calldata) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        bytes32 reportingColony = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());
        if (reportingColony == bytes32(0)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "No colony found");
        }
        if (!ColonyHelper.isColonyCreator(reportingColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony controller");
        }
        
        // FIXED: Get alliance ID using corrected mapping
        bytes32 allianceId = LibColonyWarsStorage.getUserAllianceId(LibMeta.msgSender());
        if (allianceId == bytes32(0)) {
            revert ColonyNotInAlliance();
        }
        
        // Check if betrayer is/was in same alliance
        address betrayerAddress = hs.colonyCreators[betrayerColony];
        if (betrayerAddress == address(0)) {
            revert TargetNotInAlliance();
        }
        // FIXED: Check alliance membership using corrected mapping
        bytes32 betrayerAllianceId = LibColonyWarsStorage.getUserAllianceId(betrayerAddress);
        
        // Must be same alliance or betrayer must have recently left
        if (betrayerAllianceId != allianceId && 
            block.timestamp > cws.lastBetrayalTime[betrayerColony] + 86400) { // 24h grace period
            revert TargetNotInAlliance();
        }
        
        // Cannot report betrayal against self
        if (betrayerColony == reportingColony) {
            revert SameColony();
        }
        
        LibColonyWarsStorage.Alliance storage alliance = cws.alliances[allianceId];
        if (!alliance.active) {
            revert AllianceNotFound();
        }
        
        // Record betrayal timestamp
        cws.lastBetrayalTime[betrayerColony] = uint32(block.timestamp);
        
        // Severely reduce alliance stability
        if (alliance.stabilityIndex > 30) {
            alliance.stabilityIndex -= 30;
        } else {
            alliance.stabilityIndex = 0;
        }
        
        // Remove betrayer from alliance if still a member
        if (betrayerAllianceId == allianceId) {
            LibColonyWarsStorage.removeAllianceMember(allianceId, betrayerAddress);
            emit ColonyLeftAlliance(allianceId, betrayerColony, "Betrayal");
        }
        
        emit BetrayalRecorded(betrayerColony, allianceId);
    }
    
    /**
     * @notice Transfer alliance leadership to another member
     */
    function transferLeadership(bytes32 newLeaderColony) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        bytes32 currentLeaderColony = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());
        if (currentLeaderColony == bytes32(0)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "No colony found");
        }
        if (!ColonyHelper.isColonyCreator(currentLeaderColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony controller");
        }
        
        // FIXED: Get alliance ID using corrected mapping
        bytes32 allianceId = LibColonyWarsStorage.getUserAllianceId(LibMeta.msgSender());
        if (allianceId == bytes32(0)) {
            revert ColonyNotInAlliance();
        }
        
        LibColonyWarsStorage.Alliance storage alliance = cws.alliances[allianceId];
        if (!alliance.active) {
            revert AllianceNotFound();
        }
        
        // Only current leader can transfer leadership
        if (currentLeaderColony != alliance.leaderColony) {
            revert NotAllianceLeader();
        }
        
        // Cannot transfer to self
        if (newLeaderColony == currentLeaderColony) {
            revert SameColony();
        }
        
        // Check if new leader is in the alliance
        address newLeaderAddress = hs.colonyCreators[newLeaderColony];
        if (newLeaderAddress == address(0)) {
            revert TargetNotInAlliance();
        }
        // FIXED: Check alliance membership using corrected mapping
        if (LibColonyWarsStorage.getUserAllianceId(newLeaderAddress) != allianceId) {
            revert TargetNotInAlliance();
        }
        
        // Transfer leadership
        bytes32 oldLeader = alliance.leaderColony;
        alliance.leaderColony = newLeaderColony;
        
        emit LeadershipTransferred(allianceId, oldLeader, newLeaderColony);
    }
    
    /**
     * @notice Disband alliance (leader only, must be empty except for leader)
     */
    function disbandAlliance() 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        bytes32 leaderColony = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());
        if (leaderColony == bytes32(0)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "No colony found");
        }
        if (!ColonyHelper.isColonyCreator(leaderColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony controller");
        }
        
        // FIXED: Get alliance ID using corrected mapping
        bytes32 allianceId = LibColonyWarsStorage.getUserAllianceId(LibMeta.msgSender());
        if (allianceId == bytes32(0)) {
            revert ColonyNotInAlliance();
        }
        
        LibColonyWarsStorage.Alliance storage alliance = cws.alliances[allianceId];
        if (!alliance.active) {
            revert AllianceNotFound();
        }
        
        // Only leader can disband
        if (leaderColony != alliance.leaderColony) {
            revert NotAllianceLeader();
        }
        
        // Can only disband if leader is the only member
        if (alliance.members.length > 1) {
            revert AllianceNotEmpty();
        }
        
        // Return remaining treasury to leader
        if (alliance.sharedTreasury > 0) {
            LibFeeCollection.transferFromTreasury(LibMeta.msgSender(), alliance.sharedTreasury, "alliance_disbandment");
        }
        
        // Remove leader from alliance and deactivate
        LibColonyWarsStorage.removeAllianceMember(allianceId, LibMeta.msgSender());
        alliance.active = false;
        alliance.sharedTreasury = 0;
        
        emit AllianceDisbanded(allianceId, "Disbanded by leader");
    }

    /**
     * @notice Propose forgiveness for a marked betrayer
     * @param betrayerColony Colony that committed betrayal
     */
    function proposeForgivenessVote(bytes32 betrayerColony) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        bytes32 proposerColony = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());
        if (proposerColony == bytes32(0)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "No colony found");
        }
        if (!ColonyHelper.isColonyCreator(proposerColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony controller");
        }
        
        // Get proposer's alliance
        bytes32 allianceId = LibColonyWarsStorage.getUserAllianceId(LibMeta.msgSender());
        if (allianceId == bytes32(0)) {
            revert ColonyNotInAlliance();
        }
        
        // Check if betrayer is marked in this alliance
        if (!LibColonyWarsStorage.isMarkedBetrayerInAlliance(allianceId, betrayerColony)) {
            revert InvalidEmergencyAmount(); // Reuse error for "not marked betrayer"
        }
        
        // Check if proposal already exists and is active
        LibColonyWarsStorage.ForgivenessProposal storage existing = cws.forgivenessProposals[allianceId];
        if (existing.active) {
            revert RateLimitExceeded(); // Reuse error for "proposal already active"
        }
        
        // Create new proposal
        LibColonyWarsStorage.ForgivenessProposal storage proposal = cws.forgivenessProposals[allianceId];
        proposal.betrayerColony = betrayerColony;
        proposal.proposer = LibMeta.msgSender();
        proposal.voteEnd = uint32(block.timestamp + 2 days);
        proposal.yesVotes = 0;
        proposal.totalVotes = 0;
        proposal.executed = false;
        proposal.active = true;
        
        emit ForgivenessProposed(allianceId, betrayerColony, LibMeta.msgSender());
    }

    /**
     * @notice Vote on active forgiveness proposal
     * @param forgive True to forgive, false to reject
     */
    function voteOnForgiveness(bool forgive) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        bytes32 voterColony = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());
        if (voterColony == bytes32(0)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "No colony found");
        }
        if (!ColonyHelper.isColonyCreator(voterColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony controller");
        }
        
        // Get voter's alliance
        bytes32 allianceId = LibColonyWarsStorage.getUserAllianceId(LibMeta.msgSender());
        if (allianceId == bytes32(0)) {
            revert ColonyNotInAlliance();
        }
        
        LibColonyWarsStorage.ForgivenessProposal storage proposal = cws.forgivenessProposals[allianceId];
        if (!proposal.active) {
            revert InvalidEmergencyAmount(); // Reuse error for "no active proposal"
        }
        if (block.timestamp > proposal.voteEnd) {
            revert InvalidEmergencyAmount(); // Reuse error for "voting ended"
        }
        if (cws.forgivenessVotes[allianceId][LibMeta.msgSender()]) {
            revert RateLimitExceeded(); // Reuse error for "already voted"
        }
        
        // Record vote
        cws.forgivenessVotes[allianceId][LibMeta.msgSender()] = true;
        proposal.totalVotes++;
        if (forgive) {
            proposal.yesVotes++;
        }
        
        emit ForgivenessVoteCast(allianceId, LibMeta.msgSender(), forgive);
        
        // Check if we can execute immediately (75% threshold)
        LibColonyWarsStorage.Alliance storage alliance = cws.alliances[allianceId];
        uint256 requiredVotes = (alliance.members.length * 75) / 100; // 75% of members
        
        if (proposal.yesVotes >= requiredVotes) {
            _executeForgiveness(allianceId, proposal.betrayerColony, cws);
        } else if (proposal.totalVotes == alliance.members.length) {
            // All voted, but not enough yes votes
            proposal.active = false;
            proposal.executed = true;
            emit ForgivenessRejected(allianceId, proposal.betrayerColony);
        }
    }

    /**
     * @notice Send invitation to user to join alliance with their primary colony
     * @param targetUser User address to invite
     */
    function sendAllianceInvitation(address targetUser) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("alliances");
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Get sender's colony and alliance
        bytes32 senderColony = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());
        if (senderColony == bytes32(0)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "No colony found");
        }
        
        bytes32 allianceId = LibColonyWarsStorage.getUserAllianceId(LibMeta.msgSender());
        if (allianceId == bytes32(0)) {
            revert ColonyNotInAlliance();
        }
        
        LibColonyWarsStorage.Alliance storage alliance = cws.alliances[allianceId];
        if (!alliance.active) {
            revert AllianceNotFound();
        }
        
        // Only leader can send invitations
        if (senderColony != alliance.leaderColony) {
            revert NotAllianceLeader();
        }
        
        // Cannot invite self
        if (targetUser == LibMeta.msgSender()) {
            revert CannotInviteSelf();
        }
        
        // Get target user's primary colony
        bytes32 targetColony = LibColonyWarsStorage.getUserPrimaryColony(targetUser);
        if (targetColony == bytes32(0)) {
            revert NoPrimaryColony();
        }
        
        // Validate target controls their primary colony
        if (!ColonyHelper.isColonyCreator(targetColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(targetUser, "Target not colony controller");
        }
        
        // Check if target can join alliance
        (bool canJoin,) = canColonyJoinAlliance(targetUser, allianceId, targetColony);
        if (!canJoin) {
            revert AllianceAtCapacity(); // Reuse error for "cannot join"
        }
        
        // Store invitation (expires in 7 days)
        cws.allianceInvitations[targetColony] = LibColonyWarsStorage.AllianceInvitation({
            allianceId: allianceId,
            inviter: LibMeta.msgSender(),
            expiry: uint32(block.timestamp + 7 days),
            active: true
        });
        
        emit InvitationSent(allianceId, targetUser, LibMeta.msgSender());
    }

    /**
     * @notice Accept alliance invitation with your primary colony
     * @param allianceId Alliance to join
     */
    function acceptAllianceInvitation(bytes32 allianceId) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("alliances");
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Get user's primary colony
        bytes32 primaryColony = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());
        if (primaryColony == bytes32(0)) {
            revert NoPrimaryColony();
        }
        
        // Validate user controls their primary colony
        if (!ColonyHelper.isColonyCreator(primaryColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony controller");
        }
        
        // Check if user already in alliance
        if (LibColonyWarsStorage.isUserInAlliance(LibMeta.msgSender())) {
            revert AllianceAlreadyExists();
        }
        
        // Get and validate invitation
        LibColonyWarsStorage.AllianceInvitation storage invitation = cws.allianceInvitations[primaryColony];
        if (!invitation.active) {
            revert InvitationNotFound();
        }
        if (invitation.allianceId != allianceId) {
            revert InvitationNotFound(); // Wrong alliance ID
        }
        if (block.timestamp > invitation.expiry) {
            revert InvitationExpired();
        }
        
        // Final validation that colony can still join
        (bool canJoin,) = canColonyJoinAlliance(LibMeta.msgSender(), allianceId, primaryColony);
        if (!canJoin) {
            revert AllianceAtCapacity();
        }
        
        // Add to alliance
        LibColonyWarsStorage.addAllianceMember(allianceId, LibMeta.msgSender());
        
        // Set colony mapping (should already be set but ensure consistency)
        // cws.userToColony[LibMeta.msgSender()] = primaryColony;
        
        // Clear invitation
        delete cws.allianceInvitations[primaryColony];
        
        emit InvitationAccepted(allianceId, LibMeta.msgSender());
        emit ColonyJoinedAlliance(allianceId, primaryColony);
    }

    /**
     * @notice Decline alliance invitation
     * @param allianceId Alliance invitation to decline
     */
    function declineAllianceInvitation(bytes32 allianceId) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        // Get and validate invitation
        bytes32 primaryColony = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());
        LibColonyWarsStorage.AllianceInvitation storage invitation = cws.allianceInvitations[primaryColony];
        if (!invitation.active) {
            revert InvitationNotFound();
        }
        if (invitation.allianceId != allianceId) {
            revert InvitationNotFound(); // Wrong alliance ID
        }
        
        // Clear invitation
        delete cws.allianceInvitations[primaryColony];
        
        emit InvitationDeclined(allianceId, LibMeta.msgSender());
    }

    /**
     * @notice Clear all alliances
     * @param allianceIds Array of alliance IDs to delete
     */
    function clearAlliances(bytes32[] calldata allianceIds) external onlyAuthorized {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        for (uint256 i = 0; i < allianceIds.length && i < 50; i++) { // Gas limit
            delete cws.alliances[allianceIds[i]];
        }
        
        emit AlliancesCleared(allianceIds.length);
    }

    
    // View Functions

    /**
     * @notice Get pending invitation for user
     * @param user User address to check
     * @return hasInvitation Whether user has pending invitation
     * @return allianceId Alliance that sent invitation
     * @return allianceName Name of the alliance
     * @return inviter Address that sent invitation
     * @return expiry When invitation expires
     */
    function getAllianceInvitation(address user) 
        external 
        view 
        returns (
            bool hasInvitation,
            bytes32 allianceId,
            string memory allianceName,
            address inviter,
            uint32 expiry
        ) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        // Get user's primary colony
        bytes32 primaryColony = LibColonyWarsStorage.getUserPrimaryColony(user);
        if (primaryColony == bytes32(0)) {
            return (false, bytes32(0), "", address(0), 0);
        }
        
        LibColonyWarsStorage.AllianceInvitation storage invitation = cws.allianceInvitations[primaryColony];
        
        if (invitation.active && block.timestamp <= invitation.expiry) {
            LibColonyWarsStorage.Alliance storage alliance = cws.alliances[invitation.allianceId];
            return (
                true, 
                invitation.allianceId, 
                alliance.name,
                invitation.inviter, 
                invitation.expiry
            );
        }
        
        return (false, bytes32(0), "", address(0), 0);
    }

    /**
     * @notice Check if user can be recruited to alliance
     * @param user User to check
     * @param allianceId Alliance to potentially join
     * @return canRecruit Whether user can be recruited
     * @return reason Human-readable reason if cannot recruit
     */
    function canRecruitAlly(address user, bytes32 allianceId) 
        external 
        view 
        returns (bool canRecruit, string memory reason) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        // Get user's primary colony
        bytes32 primaryColony = LibColonyWarsStorage.getUserPrimaryColony(user);
        if (primaryColony == bytes32(0)) {
            return (false, "User has no primary colony");
        }
        
        // Check if user has pending invitation
        if (cws.allianceInvitations[primaryColony].active) {
            return (false, "User already has pending invitation");
        }
        
        // Check if user already in alliance
        if (LibColonyWarsStorage.isUserInAlliance(user)) {
            return (false, "User already in alliance");
        }
        
        // Use existing canColonyJoinAlliance logic
        return canColonyJoinAlliance(user, allianceId, primaryColony);
    }

    /**
     * @notice Check if a colony owner can join a specific alliance
     * @param allianceId The alliance to check
     * @param potentialMember The address that wants to join
     * @return canJoin True if the owner can join this alliance
     * @return reason Human-readable reason if cannot join
     */
    function canOwnerJoinAlliance(bytes32 allianceId, address potentialMember) 
        external 
        view 
        returns (bool canJoin, string memory reason) 
    {
        // Get user's primary colony
        bytes32 primaryColony = LibColonyWarsStorage.getUserPrimaryColony(potentialMember);
        if (primaryColony == bytes32(0)) {
            return (false, "No primary colony set");
        }
        
        // Delegate to new comprehensive method
        return canColonyJoinAlliance(potentialMember, allianceId, primaryColony);
    }

    /**
     * @notice Check if specific colony can join alliances (betrayal cooldown only)
     * @dev Simplified version for backwards compatibility
     */
    function getColonyBetrayalStatus(bytes32 colonyId) 
        external 
        view 
        returns (bool canJoinAlliances, uint32 cooldownRemaining) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        uint32 lastBetrayal = cws.lastBetrayalTime[colonyId];
        
        // No betrayal history = can join
        if (lastBetrayal == 0) {
            return (true, 0);
        }
        
        // Check actual cooldown
        uint32 cooldownEnd = lastBetrayal + cws.config.betrayalCooldown;
        canJoinAlliances = block.timestamp >= cooldownEnd;
        cooldownRemaining = cooldownEnd > uint32(block.timestamp) ? 
            cooldownEnd - uint32(block.timestamp) : 0;
    }
        
    /**
     * @notice Get comprehensive alliance information
     */
    function getAllianceInfo(bytes32 allianceId) external view returns (
        string memory name,
        bytes32 leader,
        address[] memory members,
        uint256 treasury,
        uint32 stability,
        bool active
    ) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Alliance storage alliance = cws.alliances[allianceId];
        
        return (
            alliance.name,
            alliance.leaderColony,
            alliance.members,
            alliance.sharedTreasury,
            alliance.stabilityIndex,
            alliance.active
        );
    }
    /**
     * @notice Get alliance member count and capacity
     */
    function getAllianceCapacity(bytes32 allianceId) external view returns (
        uint256 currentMembers,
        uint256 maxMembers,
        bool canJoin
    ) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Alliance storage alliance = cws.alliances[allianceId];
        
        currentMembers = alliance.members.length;
        maxMembers = cws.config.maxAllianceMembers;
        canJoin = alliance.active && currentMembers < maxMembers;
        
        return (currentMembers, maxMembers, canJoin);
    }

    /**
     * @notice Get active alliances with member counts
     * @param allianceIds Array of known alliance IDs to check
     * @return activeAlliances Array of active alliance IDs
     * @return names Array of alliance names
     * @return memberCounts Array of member counts
     * @return treasuries Array of treasury balances
     */
    function getActiveAlliances(bytes32[] calldata allianceIds)
        external
        view
        returns (
            bytes32[] memory activeAlliances,
            string[] memory names,
            uint256[] memory memberCounts,
            uint256[] memory treasuries
        )
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        // Count active alliances first
        uint256 activeCount = 0;
        for (uint256 i = 0; i < allianceIds.length; i++) {
            if (cws.alliances[allianceIds[i]].active) {
                activeCount++;
            }
        }
        
        // Initialize arrays
        activeAlliances = new bytes32[](activeCount);
        names = new string[](activeCount);
        memberCounts = new uint256[](activeCount);
        treasuries = new uint256[](activeCount);
        
        // Populate arrays
        uint256 index = 0;
        for (uint256 i = 0; i < allianceIds.length; i++) {
            LibColonyWarsStorage.Alliance storage alliance = cws.alliances[allianceIds[i]];
            if (alliance.active) {
                activeAlliances[index] = allianceIds[i];
                names[index] = alliance.name;
                memberCounts[index] = alliance.members.length;
                treasuries[index] = alliance.sharedTreasury;
                index++;
            }
        }
    }

    /**
     * @notice Get all alliances (active and inactive)
     * @param activeOnly Whether to return only active alliances
     * @return alliances Array of alliance information
     */
    function getAllAlliances(bool activeOnly)
        external
        view
        returns (AllianceInfo[] memory alliances)
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        bytes32[] storage allianceIds = cws.allAllianceIds;
        
        // Count qualifying alliances
        uint256 count = 0;
        for (uint256 i = 0; i < allianceIds.length; i++) {
            bool active = cws.alliances[allianceIds[i]].active;
            if (!activeOnly || active) {
                count++;
            }
        }
        
        // Populate result
        alliances = new AllianceInfo[](count);
        uint256 index = 0;
        
        for (uint256 i = 0; i < allianceIds.length; i++) {
            LibColonyWarsStorage.Alliance storage alliance = cws.alliances[allianceIds[i]];
            bool active = alliance.active;
            
            if (!activeOnly || active) {
                alliances[index] = AllianceInfo({
                    allianceId: allianceIds[i],
                    name: alliance.name,
                    leaderColony: alliance.leaderColony,
                    memberCount: alliance.members.length,
                    sharedTreasury: alliance.sharedTreasury,
                    stabilityIndex: alliance.stabilityIndex,
                    active: active
                });
                index++;
            }
        }
    }
    
    /**
     * @notice Check if user can join alliance with specific colony
     * @param user User address to check
     * @param allianceId Alliance to potentially join
     * @param colonyId Colony that would join
     * @return canJoin Whether can join with this colony
     * @return reason Human-readable reason if cannot join
     */
    function canColonyJoinAlliance(address user, bytes32 allianceId, bytes32 colonyId) 
        public
        view 
        returns (bool canJoin, string memory reason) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Check if alliance exists and is active
        LibColonyWarsStorage.Alliance storage alliance = cws.alliances[allianceId];
        if (!alliance.active) {
            return (false, "Alliance not active");
        }
        
        // Check alliance capacity
        if (alliance.members.length >= cws.config.maxAllianceMembers) {
            return (false, "Alliance at capacity");
        }
        
        // Check if user already in alliance
        if (LibColonyWarsStorage.isUserInAlliance(user)) {
            return (false, "Already in alliance");
        }
        
        // Check if user controls the colony
        if (!ColonyHelper.isColonyCreator(colonyId, hs.stakingSystemAddress)) {
            return (false, "Not colony controller");
        }
        
        // Check if colony is registered
        if (!cws.colonyWarProfiles[colonyId].registered) {
            return (false, "Colony not registered for season");
        }
        
        // Check betrayal cooldown
        if (block.timestamp < cws.lastBetrayalTime[colonyId] + cws.config.betrayalCooldown) {
            return (false, "Colony has betrayal cooldown");
        }
        
        // Check if same as leader colony
        if (colonyId == alliance.leaderColony) {
            return (false, "Cannot join with leader colony");
        }
        
        // Check colony ownership uniqueness
        address colonyOwner = hs.colonyCreators[colonyId];
        if (LibColonyWarsStorage.hasOwnershipInAlliance(allianceId, colonyOwner)) {
            return (false, "Owner already has colony in this alliance");
        }

        if (!_validateDebtEligibility(colonyId)) {
            return (false, "Colony has too high debt");
        }
        
        return (true, "Can join alliance");
    }

    /**
     * @notice Get user's colonies eligible to join specific alliance
     * @param user User address to check
     * @param allianceId Alliance to potentially join
     * @return eligibleColonies Array of colony IDs that can join
     * @return reasons Array of status reasons for each colony
     */
    function getEligibleJoinColonies(address user, bytes32 allianceId) 
        external 
        view 
        returns (
            bytes32[] memory eligibleColonies,
            string[] memory reasons
        ) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        // Get user's registered colonies for current season
        bytes32[] memory userColonies = LibColonyWarsStorage.getUserSeasonColonies(cws.currentSeason, user);
        
        // Count eligible colonies
        uint256 eligibleCount = 0;
        for (uint256 i = 0; i < userColonies.length; i++) {
            bytes32 colonyId = userColonies[i];
            
            (bool canJoin,) = canColonyJoinAlliance(user, allianceId, colonyId);
            if (canJoin) eligibleCount++;
        }
        
        // Populate results
        eligibleColonies = new bytes32[](eligibleCount);
        reasons = new string[](eligibleCount);
        
        uint256 index = 0;
        for (uint256 i = 0; i < userColonies.length; i++) {
            bytes32 colonyId = userColonies[i];
            
            (bool canJoin, string memory reason) = canColonyJoinAlliance(user, allianceId, colonyId);
            if (canJoin) {
                eligibleColonies[index] = colonyId;
                reasons[index] = reason;
                index++;
            }
        }
        
        return (eligibleColonies, reasons);
    }
    
    /**
     * @notice Get count of all active alliances
     * @dev Iterates through all alliance IDs to count active ones
     * @return currentSeason Current game season
     * @return count Number of currently active alliances
     */
    function getActiveAlliancesCount() external view returns (uint256 currentSeason, uint256 count) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        bytes32[] storage allianceIds = cws.allAllianceIds;
        
        for (uint256 i = 0; i < allianceIds.length; i++) {
            if (cws.alliances[allianceIds[i]].active) {
                count++;
            }
        }

        return (cws.currentSeason, count);
    }

    /**
     * @notice Check if address is in alliance - ADDED HELPER FUNCTION
     */
    function isAddressInAlliance(address user) external view returns (bool, bytes32) {
        bytes32 allianceId = LibColonyWarsStorage.getUserAllianceId(user);
        return (allianceId != bytes32(0), allianceId);
    }

    /**
     * @notice Calculate alliance defensive bonuses for colony
     * @param colonyId Colony to check
     * @return hasAlliance Whether colony is in alliance
     * @return defensiveBonus Percentage defensive bonus (0-50)
     * @return reinforcementTokens Number of reinforcement tokens available
     * @return sharedStakeBonus Bonus from alliance shared treasury
     */
    function getAllianceDefensiveBonuses(bytes32 colonyId) 
        external 
        view 
        returns (
            bool hasAlliance,
            uint256 defensiveBonus,
            uint256 reinforcementTokens,
            uint256 sharedStakeBonus
        ) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        address colonyOwner = hs.colonyCreators[colonyId];
        if (colonyOwner == address(0)) {
            return (false, 0, 0, 0);
        }
        
        // Check if colony owner is in alliance
        bytes32 allianceId = LibColonyWarsStorage.getUserAllianceId(colonyOwner);
        if (allianceId == bytes32(0)) {
            return (false, 0, 0, 0);
        }
        
        LibColonyWarsStorage.Alliance storage alliance = cws.alliances[allianceId];
        if (!alliance.active) {
            return (false, 0, 0, 0);
        }
        
        hasAlliance = true;
        
        // NEW: Determine bonus scaling based on colony status
        bytes32 primaryColony = LibColonyWarsStorage.getUserPrimaryColony(colonyOwner);
        uint256 bonusMultiplier = 100; // Default 100% for primary colony
        
        if (primaryColony != colonyId) {
            // Additional registered colonies get reduced bonuses
            if (LibColonyWarsStorage.isUserRegisteredColony(colonyOwner, colonyId)) {
                bonusMultiplier = 35; // 35% bonuses for additional registered colonies
            } else {
                return (false, 0, 0, 0); // Unregistered colonies get no bonuses
            }
        }
        
        // Calculate base bonuses (existing logic)
        uint256 memberCount = alliance.members.length;
        uint256 stabilityIndex = alliance.stabilityIndex;
        
        defensiveBonus = memberCount * 5;
        if (defensiveBonus > 25) defensiveBonus = 25;
        
        if (stabilityIndex >= 80) {
            defensiveBonus += 25;
        } else if (stabilityIndex >= 60) {
            defensiveBonus += 15;
        } else if (stabilityIndex >= 40) {
            defensiveBonus += 10;
        }
        
        uint256 betrayalPenalty = alliance.betrayalCount * 5;
        if (betrayalPenalty > 25) betrayalPenalty = 25;
        
        if (defensiveBonus > betrayalPenalty) {
            defensiveBonus -= betrayalPenalty;
        } else {
            defensiveBonus = 0;
        }
        
        if (alliance.stabilityIndex < 30) {
            defensiveBonus /= 2;
            reinforcementTokens = memberCount > 1 ? (memberCount - 1) / 2 : 0;
            sharedStakeBonus = alliance.sharedTreasury / 20;
        } else {
            reinforcementTokens = memberCount > 1 ? memberCount - 1 : 0;
            sharedStakeBonus = alliance.sharedTreasury / 10;
        }
        
        if (defensiveBonus > 50) defensiveBonus = 50;
        
        // NEW: Apply scaling to all bonuses
        defensiveBonus = (defensiveBonus * bonusMultiplier) / 100;
        reinforcementTokens = (reinforcementTokens * bonusMultiplier) / 100;
        sharedStakeBonus = (sharedStakeBonus * bonusMultiplier) / 100;
        
        return (hasAlliance, defensiveBonus, reinforcementTokens, sharedStakeBonus);
    }

    /**
     * @notice Check if specific colony has alliance protection
     */
    function isColonyProtectedByAlliance(bytes32 colonyId) 
        external 
        view 
        returns (bool protected, bytes32 allianceId, string memory status) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        address colonyOwner = hs.colonyCreators[colonyId];
        if (colonyOwner == address(0)) {
            return (false, bytes32(0), "Colony does not exist");
        }
        
        bytes32 primaryColony = LibColonyWarsStorage.getUserPrimaryColony(colonyOwner);
        if (primaryColony == bytes32(0)) {
            return (false, bytes32(0), "Owner has no primary colony set");
        }
        
        if (primaryColony != colonyId) {
            return (false, bytes32(0), "Not owner's primary colony");
        }
        
        allianceId = LibColonyWarsStorage.getUserAllianceId(colonyOwner);
        protected = allianceId != bytes32(0);
        
        if (protected) {
            status = "Protected by alliance";
        } else {
            status = "Primary colony but no alliance";
        }
        
        return (protected, allianceId, status);
    }

    /**
     * @notice Get comprehensive defensive capabilities including alliance bonuses
     * @param colonyId Colony to analyze  
     * @return baseDefense Base defensive power from stake
     * @return allianceBonus Total alliance defensive bonus
     * @return totalDefense Combined defensive capability
     * @return breakdown Detailed breakdown of bonuses
     */
    function getDefensiveCapabilities(bytes32 colonyId) 
        external 
        view 
        returns (
            uint256 baseDefense,
            uint256 allianceBonus, 
            uint256 totalDefense,
            string memory breakdown
        ) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
        
        // Base defense from stake
        baseDefense = profile.defensiveStake;
        
        // Get alliance bonuses
        (bool hasAlliance, uint256 defensiveBonus, uint256 reinforcementTokens, uint256 sharedStakeBonus) = 
            this.getAllianceDefensiveBonuses(colonyId);
        
        if (hasAlliance) {
            // Calculate alliance bonus value
            uint256 percentageBonus = (baseDefense * defensiveBonus) / 100;
            uint256 reinforcementBonus = reinforcementTokens * 150;
            uint256 treasuryBonus = (sharedStakeBonus * 20) / 100;
            
            allianceBonus = percentageBonus + reinforcementBonus + treasuryBonus;
            breakdown = "Alliance bonuses active";
        } else {
            allianceBonus = (baseDefense * 25) / 100; // Traditional home advantage
            breakdown = "Solo: +25% home advantage";
        }
        
        totalDefense = baseDefense + allianceBonus;
        
        return (baseDefense, allianceBonus, totalDefense, breakdown);
    }

   /**
    * @notice Get active forgiveness proposal for alliance
    */
    function getForgivenessProposal(bytes32 allianceId) 
        external 
        view 
        returns (
            bytes32 betrayerColony,
            address proposer,
            uint32 voteEnd,
            uint8 yesVotes,
            uint8 totalVotes,
            bool active
        ) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.ForgivenessProposal storage proposal = cws.forgivenessProposals[allianceId];
        
        return (
            proposal.betrayerColony,
            proposal.proposer,
            proposal.voteEnd,
            proposal.yesVotes,
            proposal.totalVotes,
            proposal.active
        );
    }

    /**
     * @notice Change user's primary colony
     * @param newPrimaryColony Colony ID to set as new primary
     */
    function changePrimaryColony(bytes32 newPrimaryColony) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Validate user controls the colony
        if (!ColonyHelper.isColonyCreator(newPrimaryColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony controller");
        }
        
        bytes32 currentPrimary = LibColonyWarsStorage.getUserPrimaryColony(LibMeta.msgSender());
        
        // Cannot set same colony as primary
        if (currentPrimary == newPrimaryColony) {
            revert SameColony();
        }
        
        // Cannot change while in alliance (prevents manipulation)
        if (LibColonyWarsStorage.isUserInAlliance(LibMeta.msgSender())) {
            revert AllianceAlreadyExists(); // Reuse error for "leave alliance first"
        }
        
        // Update primary colony
        LibColonyWarsStorage.setUserPrimaryColony(LibMeta.msgSender(), newPrimaryColony);
        cws.userToColony[LibMeta.msgSender()] = newPrimaryColony;
        
        emit PrimaryColonyChanged(LibMeta.msgSender(), currentPrimary, newPrimaryColony);
    }

    /**
     * @notice Get user's primary colony status and change eligibility
     * @param user User address to check
     * @return currentPrimary Current primary colony ID
     * @return canChange Whether user can change primary colony
     * @return isInAlliance Whether user is currently in alliance
     * @return reason Human-readable reason if cannot change
     */
    function getPrimaryColonyStatus(address user) 
        external 
        view 
        returns (
            bytes32 currentPrimary,
            bool canChange,
            bool isInAlliance,
            string memory reason
        ) 
    {
        currentPrimary = LibColonyWarsStorage.getUserPrimaryColony(user);
        isInAlliance = LibColonyWarsStorage.isUserInAlliance(user);
        
        if (isInAlliance) {
            canChange = false;
            reason = "Must leave alliance first";
        } else {
            canChange = true;
            reason = "Can change primary colony";
        }
        
        return (currentPrimary, canChange, isInAlliance, reason);
    }

    /**
     * @notice Enhanced pre-join validation with detailed feedback
     * @param user User address
     * @param allianceId Alliance to check
     * @param colonyId Colony to join with (optional)
     * @return canJoin Whether can join
     * @return reason Detailed reason if cannot join
     * @return suggestedColony Alternative colony if current not suitable
     */
    function validateJoinRequest(address user, bytes32 allianceId, bytes32 colonyId) 
        external 
        view 
        returns (
            bool canJoin, 
            string memory reason, 
            bytes32 suggestedColony
        ) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Check if alliance exists and is active
        LibColonyWarsStorage.Alliance storage alliance = cws.alliances[allianceId];
        if (!alliance.active) {
            return (false, "Alliance not active", bytes32(0));
        }
        
        if (alliance.members.length >= cws.config.maxAllianceMembers) {
            return (false, "Alliance at capacity", bytes32(0));
        }
        
        // Check if user already in alliance
        if (LibColonyWarsStorage.isUserInAlliance(user)) {
            return (false, "Already in alliance", bytes32(0));
        }
        
        // Determine colony to check
        bytes32 checkColony = colonyId;
        if (checkColony == bytes32(0)) {
            checkColony = LibColonyWarsStorage.getUserPrimaryColony(user);
            if (checkColony == bytes32(0)) {
                return (false, "No colony specified", bytes32(0));
            }
        }
        
        // Validate colony ownership
        if (!ColonyHelper.isColonyCreator(checkColony, hs.stakingSystemAddress)) {
            // Try to find alternative colony for this user
            bytes32[] memory userColonies = LibColonyWarsStorage.getUserSeasonColonies(cws.currentSeason, user);
            for (uint256 i = 0; i < userColonies.length; i++) {
                if (ColonyHelper.isColonyCreator(userColonies[i], hs.stakingSystemAddress)) {
                    return (false, "Not colony controller", userColonies[i]);
                }
            }
            return (false, "Not colony controller", bytes32(0));
        }
        
        // Check colony registration
        if (!cws.colonyWarProfiles[checkColony].registered) {
            return (false, "Colony not registered", bytes32(0));
        }
        
        // Check betrayal cooldown
        if (_hasActiveBetrayalCooldown(checkColony)) {
            uint32 lastBetrayal = cws.lastBetrayalTime[checkColony];
            uint32 cooldownEnd = lastBetrayal + cws.config.betrayalCooldown;
            uint32 remaining = cooldownEnd - uint32(block.timestamp);
            return (false, string(abi.encodePacked("Betrayal cooldown: ", _uintToString(remaining), " seconds")), bytes32(0));
        }
        
        // Check not same as leader
        if (checkColony == alliance.leaderColony) {
            return (false, "Cannot join with leader colony", bytes32(0));
        }
        
        // Check ownership uniqueness (simulate addAllianceMember check)
        address colonyOwner = hs.colonyCreators[checkColony];
        if (cws.allianceOwnershipCheck[allianceId][colonyOwner]) {
            return (false, "Owner already has colony in this alliance", bytes32(0));
        }
        
        // Check debt eligibility
        if (!_validateDebtEligibility(checkColony)) {
            return (false, "Colony debt too high", bytes32(0));
        }
        
        // Check season status
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
        if (!season.active) {
            return (false, "Season not active", bytes32(0));
        }
        
        return (true, "Eligible to join", checkColony);
    }

    /**
     * @notice Check if user has voted on current proposal
     */
    function hasVotedOnForgiveness(address user) external view returns (bool) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        bytes32 allianceId = LibColonyWarsStorage.getUserAllianceId(user);
        if (allianceId == bytes32(0)) return false;
        
        return cws.forgivenessVotes[allianceId][user];
    }

    /**
     * @notice Get alliance betrayal statistics
     */
    function getAllianceBetrayalInfo(bytes32 allianceId) 
        external 
        view 
        returns (
            uint8 betrayalCount,
            uint32 lastBetrayalTime,
            uint256 stabilityPenalty
        ) 
    {
        (betrayalCount, lastBetrayalTime) = LibColonyWarsStorage.getAllianceBetrayalStats(allianceId);
        
        // Calculate current penalty
        stabilityPenalty = betrayalCount * 5; // 5% per betrayal
        if (stabilityPenalty > 25) stabilityPenalty = 25;
        
        return (betrayalCount, lastBetrayalTime, stabilityPenalty);
    }

    /**
     * @notice Get alliance health summary with actionable insights
     * @param allianceId Alliance to analyze
     * @return currentSeason Current game season
     * @return healthScore Overall health score (0-100)
     * @return status Current alliance status ("Stable", "Warning", "Critical")
     * @return recommendations Array of actionable recommendations
     * @return metrics Key metrics for dashboard display
     */
    function getAllianceHealthCheck(bytes32 allianceId) 
        external 
        view 
        returns (
            uint256 currentSeason,
            uint8 healthScore,
            string memory status,
            string[] memory recommendations,
            uint256[4] memory metrics // [memberCount, stabilityIndex, treasuryBalance, daysActiveCooldowns]
        ) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Alliance storage alliance = cws.alliances[allianceId];
        
        if (!alliance.active) {
            return (cws.currentSeason, uint8(0), "Inactive", new string[](0), [uint256(0), uint256(0), uint256(0), uint256(0)]);
        }

        // Calculate health components
        uint8 membershipScore = _calculateMembershipHealth(alliance);
        uint32 stabilityScore = alliance.stabilityIndex;
        uint32 treasuryScore = _calculateTreasuryHealth(alliance, cws);
        uint32 activityScore = _calculateActivityHealth(allianceId, alliance, cws);
        
        // Weighted average (membership 30%, stability 30%, treasury 25%, activity 15%)
        healthScore = uint8(
            (uint256(membershipScore) * 30 + 
            uint256(stabilityScore) * 30 + 
            uint256(treasuryScore) * 25 + 
            uint256(activityScore) * 15) / 100
        );
        
        // Simple status determination
        if (healthScore >= 80) {
            status = "Stable";
        } else if (healthScore >= 60) {
            status = "Warning";
        } else {
            status = "Critical";
        }
        
        // Count active cooldowns for context
        uint256 activeCooldowns = _countActiveBetrayalCooldowns(alliance, cws);
        
        // No recommendations - just raw data
        string[] memory finalRecs = new string[](0);
        
        metrics = [
            alliance.members.length,
            alliance.stabilityIndex,
            alliance.sharedTreasury,
            activeCooldowns
        ];
        
        return (cws.currentSeason, healthScore, status, finalRecs, metrics);
    }

    /**
     * @notice Get colony alliance status with bonus percentage
     */
    function getColonyAllianceStatus(bytes32 colonyId) 
        external 
        view 
        returns (
            bool hasProtection,
            uint256 bonusPercentage,
            string memory status,
            bytes32 allianceId
        ) 
    {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        address colonyOwner = hs.colonyCreators[colonyId];
        if (colonyOwner == address(0)) {
            return (false, 0, "Colony does not exist", bytes32(0));
        }
        
        allianceId = LibColonyWarsStorage.getUserAllianceId(colonyOwner);
        if (allianceId == bytes32(0)) {
            return (false, 0, "Owner not in alliance", bytes32(0));
        }
        
        bytes32 primaryColony = LibColonyWarsStorage.getUserPrimaryColony(colonyOwner);
        
        if (primaryColony == colonyId) {
            return (true, 100, "Primary colony - full protection", allianceId);
        } else if (LibColonyWarsStorage.isUserRegisteredColony(colonyOwner, colonyId)) {
            return (true, 35, "Additional colony - partial protection", allianceId);
        } else {
            return (false, 0, "Unregistered colony - no protection", allianceId);
        }
    }

    /**
     * @notice Execute forgiveness after successful vote
     */
    function _executeForgiveness(
        bytes32 allianceId, 
        bytes32 betrayerColony,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        LibColonyWarsStorage.ForgivenessProposal storage proposal = cws.forgivenessProposals[allianceId];
        
        // Clear betrayal mark
        LibColonyWarsStorage.clearBetrayalMark(allianceId, betrayerColony);
        
        // Reset individual cooldown (allow rejoining alliances)
        cws.lastBetrayalTime[betrayerColony] = 0;
        
        // Mark proposal as executed
        proposal.active = false;
        proposal.executed = true;
        
        emit BetrayalForgiven(allianceId, betrayerColony);
    }

    /**
     * @notice Check if colony can join alliance based on debt status
     * @param colonyId Colony to validate
     * @return eligible Whether colony is eligible for alliance membership
     */
    function _validateDebtEligibility(bytes32 colonyId) internal view returns (bool eligible) {
        try IDebtWarsFacet(address(this)).getCurrentColonyDebt(colonyId) returns (uint256 debt) {
            if (debt == 0) {
                return true; // No debt, eligible
            }
            
            LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
            LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
            
            // Allow alliance membership if debt is less than 50% of defensive stake
            return debt < (profile.defensiveStake / 2);
        } catch {
            return true; // DebtWarsFacet not available, allow membership
        }
    }

    /**
     * @notice Check if colony has active betrayal cooldown
     */
    function _hasActiveBetrayalCooldown(bytes32 colonyId) internal view returns (bool) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        uint32 lastBetrayal = cws.lastBetrayalTime[colonyId];
        
        // No betrayal = no cooldown
        if (lastBetrayal == 0) return false;
        
        // Check if cooldown still active
        return block.timestamp < lastBetrayal + cws.config.betrayalCooldown;
    }

    /**
     * @notice Calculate membership health score
     */
    function _calculateMembershipHealth(LibColonyWarsStorage.Alliance storage alliance) 
        internal 
        view 
        returns (uint8 score) 
    {
        uint256 memberCount = alliance.members.length;
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        uint256 maxMembers = cws.config.maxAllianceMembers;
        
        if (memberCount == 0) return 0;
        if (memberCount == 1) return 20; // Solo alliance
        if (memberCount <= maxMembers / 4) return 40; // Quarter capacity
        if (memberCount <= maxMembers / 2) return 70; // Half capacity
        if (memberCount <= maxMembers * 3 / 4) return 90; // Three quarters
        return 100; // Near or at capacity
    }

    /**
     * @notice Calculate treasury health score
     */
    function _calculateTreasuryHealth(
        LibColonyWarsStorage.Alliance storage alliance,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal view returns (uint8 score) {
        uint256 treasury = alliance.sharedTreasury;
        uint256 emergencyLimit = cws.config.emergencyLoanLimit;
        uint256 memberCount = alliance.members.length;
        
        // Target: 2x emergency limit per member
        uint256 targetTreasury = emergencyLimit * memberCount * 2;
        
        if (treasury == 0) return 0;
        if (treasury < emergencyLimit) return 20; // Can't even do one emergency aid
        if (treasury < targetTreasury / 4) return 40;
        if (treasury < targetTreasury / 2) return 60;
        if (treasury < targetTreasury) return 80;
        return 100; // Well funded
    }

    /**
     * @notice Calculate activity/trust health score
     */
    function _calculateActivityHealth(
        bytes32 allianceId,
        LibColonyWarsStorage.Alliance storage alliance,
        LibColonyWarsStorage.ColonyWarsStorage storage
    ) internal view returns (uint32 score) {
        (uint8 betrayalCount,) = LibColonyWarsStorage.getAllianceBetrayalStats(allianceId);
        
        // Base score from stability
        score = alliance.stabilityIndex;
        
        // Penalize for betrayal history
        uint8 betrayalPenalty = betrayalCount * 15; // -15 points per betrayal
        if (score > betrayalPenalty) {
            score -= betrayalPenalty;
        } else {
            score = 0;
        }
        
        return score;
    }

    /**
     * @notice Count members with active betrayal cooldowns
     */
    function _countActiveBetrayalCooldowns(
        LibColonyWarsStorage.Alliance storage alliance,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal view returns (uint256 count) {
        for (uint256 i = 0; i < alliance.members.length; i++) {
            address member = alliance.members[i];
            bytes32 colonyId = cws.userToColony[member];
            
            if (_hasActiveBetrayalCooldown(colonyId)) {
                count++;
            }
        }
        return count;
    }
    /**
     * @notice Helper function to convert uint to string
     */
    function _uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Administrative function to change a user's primary colony
     * @dev Only authorized operators can call this function
     * @param targetUser Address of user whose primary colony will be changed
     * @param newPrimaryColony Colony ID to set as new primary
     */
    function adminChangePrimaryColony(address targetUser, bytes32 newPrimaryColony)
        external
        onlyAuthorized
        nonReentrant
    {
        LibColonyWarsStorage.requireInitialized();

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();

        // Validate target user address
        if (targetUser == address(0)) {
            revert AccessHelper.Unauthorized(targetUser, "Invalid target user");
        }

        // Validate colony exists
        if (!ColonyHelper.colonyExists(newPrimaryColony)) {
            revert ColonyNotRegistered();
        }

        bytes32 currentPrimary = LibColonyWarsStorage.getUserPrimaryColony(targetUser);

        // Cannot set same colony as primary
        if (currentPrimary == newPrimaryColony) {
            revert SameColony();
        }

        // Update primary colony (admin can bypass alliance check)
        LibColonyWarsStorage.setUserPrimaryColony(targetUser, newPrimaryColony);
        cws.userToColony[targetUser] = newPrimaryColony;

        emit AdminPrimaryColonyChanged(targetUser, currentPrimary, newPrimaryColony, LibMeta.msgSender());
    }

}