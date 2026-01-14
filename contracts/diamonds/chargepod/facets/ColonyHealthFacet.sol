// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {ColonyHelper} from "../libraries/ColonyHelper.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";

/**
 * @title ColonyHealthFacet
 * @notice Complete colony health management system
 * @dev Focused on health management - doesn't duplicate view functionality
 */
contract ColonyHealthFacet is AccessControlBase {
    
    event ColonyHealthRestored(bytes32 indexed colonyId, address indexed restorer, uint8 newHealth);
    event ColonyHealthDecayed(bytes32 indexed colonyId, uint8 healthLevel, uint32 daysSinceActivity);
    event ColonyPenaltyApplied(bytes32 indexed colonyId, uint8 penaltySeverity, uint256 membersAffected);

    struct ColonyHealthSummary {
        bytes32 colonyId;
        string name;
        uint8 healthLevel;
        uint32 daysSinceActivity;
        bool needsAttention;
        uint256 restorationCost;
        bool canRestore;
    }

    /**
     * @notice Restore colony health with different restoration levels
     * @param colonyId Colony ID
     * @param restorationType 1=basic(+50), 2=full(+100), 3=premium(+100 + bonus)
     */
    function restoreColonyHealth(bytes32 colonyId, uint8 restorationType) external nonReentrant whenNotPaused {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            revert ColonyHelper.ColonyDoesNotExist(colonyId);
        }
        
        if (!ColonyHelper.isAuthorizedForColony(colonyId, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not authorized");
        }
        
        (uint8 currentHealth,) = ColonyHelper.calculateColonyHealth(colonyId);
        
        if (currentHealth >= 90 && restorationType != 3) {
            revert("Colony already healthy");
        }
        
        // Calculate cost and restoration amount
        uint256 baseCost = hs.chargeFees.colonyMembershipFee.amount;
        uint256 totalCost;
        uint8 healthBonus;
        
        if (restorationType == 1) {      // Basic restoration
            totalCost = baseCost;
            healthBonus = 50;
        } else if (restorationType == 2) { // Full restoration  
            totalCost = baseCost * 2;
            healthBonus = 100;
        } else if (restorationType == 3) { // Premium restoration
            totalCost = baseCost * 3;
            healthBonus = 100;
        } else {
            revert("Invalid restoration type");
        }
        
        // Collect fee
        LibFeeCollection.collectFee(
            hs.chargeFees.colonyMembershipFee.currency,
            LibMeta.msgSender(),
            hs.chargeFees.colonyMembershipFee.beneficiary,
            totalCost,
            "restoreColonyHealth"
        );
        
        // Apply restoration
        LibHenomorphsStorage.ColonyHealth storage health = hs.colonyHealth[colonyId];
        uint8 newHealth = currentHealth + healthBonus;
        if (newHealth > 100) newHealth = 100;
        
        health.healthLevel = newHealth;
        health.lastActivityDay = uint32(block.timestamp / 86400);
        
        // Premium restoration gives temporary boost
        if (restorationType == 3) {
            health.boostEndTime = uint32(block.timestamp + 7 days);
        }
        
        emit ColonyHealthRestored(colonyId, LibMeta.msgSender(), newHealth);
    }

    /**
     * @notice Get detailed colony health status
     * @param colonyId Colony ID
     */
    function getColonyHealthDetails(bytes32 colonyId) external view returns (
        uint8 healthLevel,
        uint32 daysSinceActivity,
        bool needsAttention,
        bool hasPenalties,
        uint256 restorationCost,
        uint32 boostTimeLeft,
        string memory healthDescription
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (bytes(hs.colonyNamesById[colonyId]).length == 0) {
            revert ColonyHelper.ColonyDoesNotExist(colonyId);
        }
        
        (healthLevel, daysSinceActivity) = ColonyHelper.calculateColonyHealth(colonyId);
        needsAttention = healthLevel < 50;
        hasPenalties = healthLevel < 30;
        
        // Calculate restoration cost
        if (healthLevel < 90) {
            restorationCost = hs.chargeFees.colonyMembershipFee.amount;
        }
        
        // Check boost time
        LibHenomorphsStorage.ColonyHealth storage health = hs.colonyHealth[colonyId];
        if (health.boostEndTime > block.timestamp) {
            boostTimeLeft = health.boostEndTime - uint32(block.timestamp);
        }
        
        // Health description
        if (healthLevel >= 80) {
            healthDescription = "Excellent";
        } else if (healthLevel >= 60) {
            healthDescription = "Good";
        } else if (healthLevel >= 40) {
            healthDescription = "Fair";
        } else if (healthLevel >= 20) {
            healthDescription = "Poor";
        } else {
            healthDescription = "Critical";
        }
    }

    /**
     * @notice Get unhealthy colonies for user with detailed info
     * @param user User address
     */
    function getUnhealthyUserColonies(address user) external view returns (
        ColonyHealthSummary[] memory unhealthyColonies
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        bytes32[] storage userColonies = hs.userColonies[user];
        
        // Count unhealthy colonies
        uint256 unhealthyCount = 0;
        for (uint256 i = 0; i < userColonies.length; i++) {
            (uint8 health,) = ColonyHelper.calculateColonyHealth(userColonies[i]);
            if (health < 60) { // Include "fair" health colonies
                unhealthyCount++;
            }
        }
        
        // Build detailed result
        unhealthyColonies = new ColonyHealthSummary[](unhealthyCount);
        uint256 resultIndex = 0;
        
        for (uint256 i = 0; i < userColonies.length; i++) {
            bytes32 colonyId = userColonies[i];
            (uint8 health, uint32 daysSince) = ColonyHelper.calculateColonyHealth(colonyId);
            
            if (health < 60) {
                unhealthyColonies[resultIndex] = ColonyHealthSummary({
                    colonyId: colonyId,
                    name: hs.colonyNamesById[colonyId],
                    healthLevel: health,
                    daysSinceActivity: daysSince,
                    needsAttention: health < 50,
                    restorationCost: health < 90 ? hs.chargeFees.colonyMembershipFee.amount : 0,
                    canRestore: ColonyHelper.isAuthorizedForColony(colonyId, hs.stakingSystemAddress)
                });
                resultIndex++;
            }
        }
    }

    /**
     * @notice Get health restoration options and costs
     */
    function getRestorationOptions() external view returns (
        uint256 basicCost,
        uint256 fullCost,
        uint256 premiumCost,
        string memory basicDescription,
        string memory fullDescription,
        string memory premiumDescription
    ) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        uint256 baseCost = hs.chargeFees.colonyMembershipFee.amount;
        
        basicCost = baseCost;
        fullCost = baseCost * 2;
        premiumCost = baseCost * 3;
        
        basicDescription = "Restore +50 health points";
        fullDescription = "Fully restore to 100 health";
        premiumDescription = "Full restore + 7-day boost";
    }

    /**
     * @notice Emergency reset multiple colonies (admin only)
     * @param colonyIds Array of colony IDs to reset
     */
    function emergencyBulkResetHealth(bytes32[] calldata colonyIds) external onlyAuthorized {
        for (uint256 i = 0; i < colonyIds.length && i < 20; i++) { // Limit to 20
            bytes32 colonyId = colonyIds[i];
            LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
            
            if (bytes(hs.colonyNamesById[colonyId]).length > 0) {
                LibHenomorphsStorage.ColonyHealth storage health = hs.colonyHealth[colonyId];
                health.healthLevel = 100;
                health.lastActivityDay = uint32(block.timestamp / 86400);
                health.boostEndTime = 0;
                
                emit ColonyHealthRestored(colonyId, LibMeta.msgSender(), 100);
            }
        }
    }
}