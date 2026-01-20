// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibStakingStorage} from "../libraries/LibStakingStorage.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";

/**
 * @title StakingLoyaltyProgramFacet
 * @notice Facet for managing the VIP Loyalty Program for staking addresses
 * @dev Allows creating tier configurations and assigning addresses to tiers
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract StakingLoyaltyProgramFacet is AccessControlBase {
    // Uproszczone eventy
    event TierConfigured(uint8 indexed tierLevel, uint256 bonusPercent);
    event TierDeactivated(uint8 indexed tierLevel);
    event AddressAssignedToTier(address indexed account, uint8 tierLevel);
    event AddressRemovedFromProgram(address indexed account);
    event ProgramToggled(bool enabled);
    event AutoUpgradesToggled(bool enabled);
    event TierUpgraded(address indexed account, uint8 newTierLevel);
    
    // Errors
    error InvalidTierParameters();
    error TierNotFound();
    error TierAlreadyExists();
    error AddressNotInProgram();
    error UnauthorizedCaller();
    error TierExpired();
    error InvalidExpiryTime();
    
    /**
     * @notice Initialize the loyalty program with default tiers
     * @dev Should be called once after facet deployment
     */
    function initializeLoyaltyProgram() external onlyAuthorized whenNotPaused {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
    
        // Skip if already initialized (check if any tier exists)
        if (bytes(ss.loyaltyTierConfigs[LibStakingStorage.LoyaltyTierLevel.BASIC].name).length > 0) {
            return;
        }
        
        // BASIC - Entry level for whitelist users (lowered requirements)
        ss.loyaltyTierConfigs[LibStakingStorage.LoyaltyTierLevel.BASIC] = LibStakingStorage.LoyaltyTierConfig({
            name: "Basic",
            bonusPercent: 5,         // 5% staking bonus
            active: true,
            stakingRequirement: 1000 ether,   // Reduced from 1000 to 100 ZICO
            durationRequirement: 7           // Reduced from 30 to 7 days
        });
        
        // SILVER - Accessible upgrade tier (adjusted requirements)
        ss.loyaltyTierConfigs[LibStakingStorage.LoyaltyTierLevel.SILVER] = LibStakingStorage.LoyaltyTierConfig({
            name: "Silver",
            bonusPercent: 10,        // 10% staking bonus
            active: true,
            stakingRequirement: 10000 ether,  // Reduced from 5000 to 2500 ZICO
            durationRequirement: 30          // Reduced from 60 to 30 days
        });
        
        // GOLD - Mid-tier for committed users (adjusted requirements)
        ss.loyaltyTierConfigs[LibStakingStorage.LoyaltyTierLevel.GOLD] = LibStakingStorage.LoyaltyTierConfig({
            name: "Gold",
            bonusPercent: 20,        // 20% staking bonus
            active: true,
            stakingRequirement: 30000 ether, // Reduced from 20000 to 10000 ZICO
            durationRequirement: 90          // Reduced from 90 to 60 days
        });
        
        // PLATINUM - High-tier for dedicated users (adjusted requirements)
        ss.loyaltyTierConfigs[LibStakingStorage.LoyaltyTierLevel.PLATINUM] = LibStakingStorage.LoyaltyTierConfig({
            name: "Platinum",
            bonusPercent: 30,        // 30% staking bonus
            active: true,
            stakingRequirement: 50000 ether, // Reduced from 50000 to 25000 ZICO
            durationRequirement: 180         // Reduced from 180 to 120 days
        });
        
        // DIAMOND - Premium tier for whale users (new highest tier)
        ss.loyaltyTierConfigs[LibStakingStorage.LoyaltyTierLevel.DIAMOND] = LibStakingStorage.LoyaltyTierConfig({
            name: "Diamond",
            bonusPercent: 50,        // 50% staking bonus (highest available)
            active: true,
            stakingRequirement: 100000 ether, // 100k ZICO for premium access
            durationRequirement: 365          // 1 year commitment required
        });
            
        // Enable program by default
        ss.loyaltyProgramEnabled = true;
        
        // Enable automatic tier upgrades
        ss.autoTierUpgradesEnabled = true;
        
        // Emit events with simplified signatures
        emit ProgramToggled(true);
        emit AutoUpgradesToggled(true);
        emit TierConfigured(uint8(LibStakingStorage.LoyaltyTierLevel.BASIC), 5);
        emit TierConfigured(uint8(LibStakingStorage.LoyaltyTierLevel.SILVER), 10);
        emit TierConfigured(uint8(LibStakingStorage.LoyaltyTierLevel.GOLD), 20);
        emit TierConfigured(uint8(LibStakingStorage.LoyaltyTierLevel.PLATINUM), 30);
    }
    
    /**
     * @notice Configure a loyalty tier
     * @param tierLevel Tier level from enum
     * @param name Tier name (e.g., "Basic", "Silver", etc.)
     * @param bonusPercent Bonus percentage (e.g., 5, 10, 20)
     * @param stakingRequirement Optional minimum staking amount (0 = no requirement)
     * @param durationRequirement Optional minimum staking duration in days (0 = no requirement)
     */
    function configureLoyaltyTier(
        LibStakingStorage.LoyaltyTierLevel tierLevel, 
        string calldata name, 
        uint256 bonusPercent,
        uint256 stakingRequirement,
        uint256 durationRequirement
    ) external onlyAuthorized whenNotPaused {
        if (tierLevel == LibStakingStorage.LoyaltyTierLevel.NONE) {
            revert InvalidTierParameters();
        }
        
        // Limit max bonus to 50% for safety
        if (bonusPercent == 0 || bonusPercent > 50) {
            revert InvalidTierParameters();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Configure the tier
        ss.loyaltyTierConfigs[tierLevel] = LibStakingStorage.LoyaltyTierConfig({
            name: name,
            bonusPercent: bonusPercent,
            active: true,
            stakingRequirement: stakingRequirement,
            durationRequirement: durationRequirement
        });
        
        // Emituj uproszczony event
        emit TierConfigured(uint8(tierLevel), bonusPercent);
    }
    
    /**
     * @notice Deactivate a loyalty tier
     * @param tierLevel Tier level to deactivate
     */
    function deactivateLoyaltyTier(LibStakingStorage.LoyaltyTierLevel tierLevel) external onlyAuthorized whenNotPaused {
        if (tierLevel == LibStakingStorage.LoyaltyTierLevel.NONE) {
            revert InvalidTierParameters();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Check if tier exists
        if (bytes(ss.loyaltyTierConfigs[tierLevel].name).length == 0) {
            revert TierNotFound();
        }
        
        // Deactivate the tier
        ss.loyaltyTierConfigs[tierLevel].active = false;
        
        // Emituj uproszczony event
        emit TierDeactivated(uint8(tierLevel));
    }
    
    /**
     * @notice Assign an address to a loyalty tier
     * @param account Address to assign
     * @param tierLevel Tier level to assign
     * @param expiryTime Optional expiration timestamp (0 = never expires)
     */
    function assignAddressToTier(
        address account, 
        LibStakingStorage.LoyaltyTierLevel tierLevel, 
        uint256 expiryTime
    ) external onlyAuthorized whenNotPaused {
        if (account == address(0)) {
            revert InvalidTierParameters();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Check that tier exists and is active if assigning to a non-NONE tier
        if (tierLevel != LibStakingStorage.LoyaltyTierLevel.NONE) {
            if (bytes(ss.loyaltyTierConfigs[tierLevel].name).length == 0) {
                revert TierNotFound();
            }
            
            if (!ss.loyaltyTierConfigs[tierLevel].active) {
                revert TierNotFound();
            }
        }
        
        // Check if expiry time is in the future or never expires (0)
        if (expiryTime > 0 && expiryTime <= block.timestamp) {
            revert InvalidExpiryTime();
        }
        
        // Check if address is already in program
        bool isNewAddress = ss.addressTierAssignments[account].tierLevel == LibStakingStorage.LoyaltyTierLevel.NONE;
        
        // Assign address to tier
        ss.addressTierAssignments[account] = LibStakingStorage.LoyaltyTierAssignment({
            tierLevel: tierLevel,
            expiryTime: expiryTime,
            assignedAt: block.timestamp
        });
        
        // Add to address list if new and assigning to a tier
        if (isNewAddress && tierLevel != LibStakingStorage.LoyaltyTierLevel.NONE) {
            ss.loyaltyProgramAddresses.push(account);
        }
        
        // Remove from list if assigning to NONE tier (removing from program)
        if (!isNewAddress && tierLevel == LibStakingStorage.LoyaltyTierLevel.NONE) {
            _removeAddressFromList(account, ss);
        }
        
        // Emituj uproszczony event
        emit AddressAssignedToTier(account, uint8(tierLevel));
    }
    
    /**
     * @notice Remove an address from the loyalty program
     * @param account Address to remove
     */
    function removeAddressFromProgram(address account) external onlyAuthorized whenNotPaused {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Check if address is in program
        if (ss.addressTierAssignments[account].tierLevel == LibStakingStorage.LoyaltyTierLevel.NONE) {
            revert AddressNotInProgram();
        }
        
        // Remove tier assignment
        delete ss.addressTierAssignments[account];
        
        // Remove from address list
        _removeAddressFromList(account, ss);
        
        // Emituj uproszczony event
        emit AddressRemovedFromProgram(account);
    }
    
    /**
     * @notice Enable or disable the loyalty program
     * @param enabled Whether the program is enabled
     */
    function setLoyaltyProgramEnabled(bool enabled) external onlyAuthorized whenNotPaused {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        ss.loyaltyProgramEnabled = enabled;
        
        // Emituj uproszczony event
        emit ProgramToggled(enabled);
    }
    
    /**
     * @notice Enable or disable automatic tier upgrades
     * @param enabled Whether automatic upgrades are enabled
     */
    function setAutoTierUpgradesEnabled(bool enabled) external onlyAuthorized whenNotPaused {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        ss.autoTierUpgradesEnabled = enabled;
        
        // Emituj uproszczony event
        emit AutoUpgradesToggled(enabled);
    }
    
    /**
     * @notice Extend the expiry time of an address's tier
     * @param account Address to update
     * @param newExpiryTime New expiry timestamp (0 = never expires)
     */
    function extendTierExpiry(address account, uint256 newExpiryTime) external onlyAuthorized whenNotPaused {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Check if address is in program
        LibStakingStorage.LoyaltyTierAssignment storage assignment = ss.addressTierAssignments[account];
        if (assignment.tierLevel == LibStakingStorage.LoyaltyTierLevel.NONE) {
            revert AddressNotInProgram();
        }
        
        // Check if new expiry time is in the future or never expires (0)
        if (newExpiryTime > 0 && newExpiryTime <= block.timestamp) {
            revert InvalidExpiryTime();
        }
        
        // Update expiry time
        assignment.expiryTime = newExpiryTime;
        
        // Emituj uproszczony event - informujemy tylko o przypisaniu do istniejącego poziomu
        emit AddressAssignedToTier(account, uint8(assignment.tierLevel));
    }
    
    /**
     * @notice Process batch tier upgrades for addresses meeting criteria
     * @param startIndex Starting index in address list
     * @param limit Maximum number of addresses to process (0 = all)
     * @return processedCount Number of addresses processed
     * @return upgradedCount Number of addresses upgraded
     */
    function batchUpgradeTiers(uint256 startIndex, uint256 limit) external onlyAuthorized whenNotPaused returns (
        uint256 processedCount,
        uint256 upgradedCount
    ) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Check if automatic upgrades are enabled
        if (!ss.autoTierUpgradesEnabled) {
            return (0, 0);
        }
        
        // Set processing limit
        uint256 endIndex = startIndex + limit;
        if (limit == 0 || endIndex > ss.loyaltyProgramAddresses.length) {
            endIndex = ss.loyaltyProgramAddresses.length;
        }
        
        // Process addresses
        for (uint256 i = startIndex; i < endIndex; i++) {
            address account = ss.loyaltyProgramAddresses[i];
            processedCount++;
            
            // Check and upgrade tier
            bool upgraded = _checkAndUpgradeTier(account, ss);
            if (upgraded) {
                upgradedCount++;
            }
        }
        
        return (processedCount, upgradedCount);
    }
    
    /**
     * @notice Check and automatically upgrade an address's tier if criteria are met
     * @param account Address to check
     * @return upgraded Whether the tier was upgraded
     */
    function checkAndUpgradeTier(address account) external returns (bool upgraded) {
        // Only the address owner or admin can call this function
        address sender = LibMeta.msgSender();
        if (sender != account && !AccessHelper.isAuthorized()) {
            revert UnauthorizedCaller();
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Check if automatic upgrades are enabled
        if (!ss.autoTierUpgradesEnabled) {
            return false;
        }
        
        return _checkAndUpgradeTier(account, ss);
    }
    
    /**
     * @notice Get information about an address's tier
     * @param account Address to check
     * @return tierLevel Tier level
     * @return tierName Tier name
     * @return bonusPercent Bonus percentage
     * @return expiryTime Expiry timestamp (0 = never expires)
     * @return active Whether the tier is active
     */
    function getAddressTierInfo(address account) external view returns (
        LibStakingStorage.LoyaltyTierLevel tierLevel,
        string memory tierName,
        uint256 bonusPercent,
        uint256 expiryTime,
        bool active
    ) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Get tier assignment
        LibStakingStorage.LoyaltyTierAssignment storage assignment = ss.addressTierAssignments[account];
        tierLevel = assignment.tierLevel;
        expiryTime = assignment.expiryTime;
        
        // If address has a tier assigned, get tier details
        if (tierLevel != LibStakingStorage.LoyaltyTierLevel.NONE) {
            LibStakingStorage.LoyaltyTierConfig storage tierConfig = ss.loyaltyTierConfigs[tierLevel];
            tierName = tierConfig.name;
            bonusPercent = tierConfig.bonusPercent;
            
            // Check if tier is active and not expired
            active = tierConfig.active && (assignment.expiryTime == 0 || assignment.expiryTime > block.timestamp);
        } else {
            tierName = "";
            bonusPercent = 0;
            active = false;
        }
        
        return (tierLevel, tierName, bonusPercent, expiryTime, active);
    }
    
    /**
     * @notice Get details of a loyalty tier
     * @param tierLevel Tier level to query
     * @return name Tier name
     * @return bonusPercent Bonus percentage
     * @return active Whether the tier is active
     * @return stakingRequirement Staking amount requirement
     * @return durationRequirement Staking duration requirement
     */
    function getLoyaltyTierDetails(LibStakingStorage.LoyaltyTierLevel tierLevel) external view returns (
        string memory name,
        uint256 bonusPercent,
        bool active,
        uint256 stakingRequirement,
        uint256 durationRequirement
    ) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        LibStakingStorage.LoyaltyTierConfig storage tierConfig = ss.loyaltyTierConfigs[tierLevel];
        
        return (
            tierConfig.name,
            tierConfig.bonusPercent,
            tierConfig.active,
            tierConfig.stakingRequirement,
            tierConfig.durationRequirement
        );
    }
    
    /**
     * @notice Get all addresses in the loyalty program
     * @param startIndex Starting index
     * @param limit Maximum number of addresses to return (0 = all)
     * @return addresses List of addresses
     * @return tierLevels List of tier levels
     * @return expiryTimes List of expiry timestamps
     */
    function getLoyaltyProgramAddresses(uint256 startIndex, uint256 limit) external view returns (
        address[] memory addresses,
        uint8[] memory tierLevels,
        uint256[] memory expiryTimes
    ) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        uint256 totalCount = ss.loyaltyProgramAddresses.length;
        
        // Check range
        if (startIndex >= totalCount) {
            return (new address[](0), new uint8[](0), new uint256[](0));
        }
        
        // Set limit
        uint256 endIndex = startIndex + limit;
        if (limit == 0 || endIndex > totalCount) {
            endIndex = totalCount;
        }
        
        // Allocate memory for arrays
        uint256 count = endIndex - startIndex;
        addresses = new address[](count);
        tierLevels = new uint8[](count);
        expiryTimes = new uint256[](count);
        
        // Fill arrays
        for (uint256 i = 0; i < count; i++) {
            address account = ss.loyaltyProgramAddresses[startIndex + i];
            addresses[i] = account;
            
            LibStakingStorage.LoyaltyTierAssignment storage assignment = ss.addressTierAssignments[account];
            // Konwertuj enum na uint8 dla zwrócenia wartości
            tierLevels[i] = uint8(assignment.tierLevel);
            expiryTimes[i] = assignment.expiryTime;
        }
        
        return (addresses, tierLevels, expiryTimes);
    }
    
    /**
     * @notice Get the count of addresses in the loyalty program
     * @return count Number of addresses
     */
    function getLoyaltyProgramAddressCount() external view returns (uint256 count) {
        return LibStakingStorage.stakingStorage().loyaltyProgramAddresses.length;
    }
    
    /**
     * @notice Check if the loyalty program is enabled
     * @return enabled Whether the program is enabled
     */
    function isLoyaltyProgramEnabled() external view returns (bool enabled) {
        return LibStakingStorage.stakingStorage().loyaltyProgramEnabled;
    }
    
    /**
     * @notice Check if automatic tier upgrades are enabled
     * @return enabled Whether automatic upgrades are enabled
     */
    function isAutoTierUpgradesEnabled() external view returns (bool enabled) {
        return LibStakingStorage.stakingStorage().autoTierUpgradesEnabled;
    }

    /**
     * @notice Universal batch assign addresses to specified tier
     * @param addresses Array of addresses to assign
     * @param tierLevel Tier level to assign (use NONE to remove)
     * @param expiryTime Expiration timestamp (0 = never expires)
     */
    function assignAddressesToTier(
        address[] calldata addresses,
        LibStakingStorage.LoyaltyTierLevel tierLevel,
        uint256 expiryTime
    ) external onlyAuthorized whenNotPaused {
        // Validation
        if (tierLevel > LibStakingStorage.LoyaltyTierLevel.DIAMOND) {
            revert InvalidTierParameters(); 
        }
        
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        // Validate tier exists and is active (except NONE)
        if (tierLevel != LibStakingStorage.LoyaltyTierLevel.NONE) {
            if (bytes(ss.loyaltyTierConfigs[tierLevel].name).length == 0 || !ss.loyaltyTierConfigs[tierLevel].active) {
                revert TierNotFound();
            }
        }
        
        // Validate expiry time
        if (expiryTime > 0 && expiryTime <= block.timestamp) {
            revert InvalidExpiryTime();
        }
        
        // Process each address
        for (uint256 i = 0; i < addresses.length; i++) {
            address account = addresses[i];
            
            if (account == address(0)) continue;
            
            bool isNewAddress = ss.addressTierAssignments[account].tierLevel == LibStakingStorage.LoyaltyTierLevel.NONE;
            
            if (tierLevel == LibStakingStorage.LoyaltyTierLevel.NONE) {
                // REMOVAL: Delete assignment and remove from list
                if (!isNewAddress) {
                    delete ss.addressTierAssignments[account];
                    _removeAddressFromList(account, ss);
                    emit AddressRemovedFromProgram(account);
                }
            } else {
                // ASSIGNMENT: Set tier and add to list if new
                ss.addressTierAssignments[account] = LibStakingStorage.LoyaltyTierAssignment({
                    tierLevel: tierLevel,
                    expiryTime: expiryTime,
                    assignedAt: block.timestamp
                });
                
                if (isNewAddress) {
                    ss.loyaltyProgramAddresses.push(account);
                }
                
                emit AddressAssignedToTier(account, uint8(tierLevel));
            }
        }
    }

    /**
     * @notice Batch remove addresses from loyalty program
     * @param addresses Array of addresses to remove
     */
    function removeAddressesFromProgram(
        address[] calldata addresses
    ) external onlyAuthorized whenNotPaused {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        
        for (uint256 i = 0; i < addresses.length; i++) {
            address account = addresses[i];
            
            if (account == address(0)) continue;
            
            // Skip if not in program
            if (ss.addressTierAssignments[account].tierLevel == LibStakingStorage.LoyaltyTierLevel.NONE) {
                continue;
            }
            
            // Remove assignment and from list
            delete ss.addressTierAssignments[account];
            _removeAddressFromList(account, ss);
            emit AddressRemovedFromProgram(account);
        }
    }

    /**
     * @notice Check if address is in loyalty program
     * @param account Address to check
     * @return inProgram Whether address has active tier
     * @return tierLevel Current tier level
     * @return isExpired Whether assignment has expired
     */
    function isAddressInProgram(address account) external view returns (
        bool inProgram,
        LibStakingStorage.LoyaltyTierLevel tierLevel, 
        bool isExpired
    ) {
        LibStakingStorage.StakingStorage storage ss = LibStakingStorage.stakingStorage();
        LibStakingStorage.LoyaltyTierAssignment storage assignment = ss.addressTierAssignments[account];
        
        tierLevel = assignment.tierLevel;
        inProgram = (tierLevel != LibStakingStorage.LoyaltyTierLevel.NONE);
        isExpired = (inProgram && assignment.expiryTime > 0 && block.timestamp > assignment.expiryTime);
        
        return (inProgram, tierLevel, isExpired);
    }

    /**
     * @notice Internal function to check and upgrade an address's tier
     * @param account Address to check
     * @param ss Reference to staking storage
     * @return upgraded Whether the tier was upgraded
     */
    function _checkAndUpgradeTier(address account, LibStakingStorage.StakingStorage storage ss) internal returns (bool upgraded) {
        // Get current tier assignment
        LibStakingStorage.LoyaltyTierAssignment storage assignment = ss.addressTierAssignments[account];
        
        // Skip if address has no tier or is at maximum tier
        if (assignment.tierLevel == LibStakingStorage.LoyaltyTierLevel.NONE || 
            assignment.tierLevel == LibStakingStorage.LoyaltyTierLevel.DIAMOND) {
            return false;
        }
        
        // Usunięto zbędne pobieranie currentTierConfig
        
        // Get next tier level
        LibStakingStorage.LoyaltyTierLevel nextTierLevel;
        if (assignment.tierLevel == LibStakingStorage.LoyaltyTierLevel.BASIC) {
            nextTierLevel = LibStakingStorage.LoyaltyTierLevel.SILVER;
        } else if (assignment.tierLevel == LibStakingStorage.LoyaltyTierLevel.SILVER) {
            nextTierLevel = LibStakingStorage.LoyaltyTierLevel.GOLD;
        } else if (assignment.tierLevel == LibStakingStorage.LoyaltyTierLevel.GOLD) {
            nextTierLevel = LibStakingStorage.LoyaltyTierLevel.PLATINUM;
        } else if (assignment.tierLevel == LibStakingStorage.LoyaltyTierLevel.PLATINUM) {
            nextTierLevel = LibStakingStorage.LoyaltyTierLevel.DIAMOND; 
        } else {
            return false;
        }
        
        // Get next tier config
        LibStakingStorage.LoyaltyTierConfig storage nextTierConfig = 
            ss.loyaltyTierConfigs[nextTierLevel];
        
        // Check if next tier is configured and active
        if (bytes(nextTierConfig.name).length == 0 || !nextTierConfig.active) {
            return false;
        }
        
        // Check eligibility based on staking amount and duration
        bool eligibleForUpgrade = _checkUpgradeEligibility(account, nextTierConfig, ss);
        
        if (eligibleForUpgrade) {
            // Upgrade to next tier
            assignment.tierLevel = nextTierLevel;
            emit TierUpgraded(account, uint8(nextTierLevel));
            
            return true;
        }
        
        return false;
    }

    /**
     * @notice Enhanced address removal from list (OPTIMIZED)
     */
    function _removeAddressFromList(address account, LibStakingStorage.StakingStorage storage ss) internal {
        uint256 length = ss.loyaltyProgramAddresses.length;
        
        if (length == 0) return;
        
        // Find and remove address
        for (uint256 i = 0; i < length; i++) {
            if (ss.loyaltyProgramAddresses[i] == account) {
                // If last element, just pop; otherwise swap with last and pop
                if (i == length - 1) {
                    ss.loyaltyProgramAddresses.pop();
                } else {
                    ss.loyaltyProgramAddresses[i] = ss.loyaltyProgramAddresses[length - 1];
                    ss.loyaltyProgramAddresses.pop();
                }
                break;
            }
        }
    }
            
    /**
     * @notice Internal function to check if an address is eligible for a tier upgrade
     * @param account Address to check
     * @param nextTierConfig Next tier configuration
     * @param ss Reference to staking storage
     * @return eligible Whether the address is eligible for the upgrade
     */
    function _checkUpgradeEligibility(
        address account, 
        LibStakingStorage.LoyaltyTierConfig storage nextTierConfig,
        LibStakingStorage.StakingStorage storage ss
    ) internal view returns (bool eligible) {
        // Check staking requirement if set
        if (nextTierConfig.stakingRequirement > 0) {
            uint256 totalStaked = _getTotalStakedValue(account, ss);
            if (totalStaked < nextTierConfig.stakingRequirement) {
                return false;
            }
        }
        
        // Check duration requirement if set
        if (nextTierConfig.durationRequirement > 0) {
            // Get current tier assignment
            LibStakingStorage.LoyaltyTierAssignment storage assignment = ss.addressTierAssignments[account];
            
            // Calculate time in current tier
            uint256 timeInTier = block.timestamp - assignment.assignedAt;
            
            // Convert duration requirement from days to seconds
            uint256 requiredDuration = nextTierConfig.durationRequirement * 1 days;
            
            if (timeInTier < requiredDuration) {
                return false;
            }
        }
        
        return true;
    }
    
    /**
     * @notice Internal function to get the total staked value for an address
     * @param account Address to check
     * @param ss Reference to staking storage
     * @return totalStaked Total value staked by the address
     */
    function _getTotalStakedValue(address account, LibStakingStorage.StakingStorage storage ss) internal view returns (uint256 totalStaked) {
        // Get list of tokens staked by the address
        uint256[] storage stakerTokens = ss.stakerTokens[account];
        
        // Sum up infused amounts for all tokens
        for (uint256 i = 0; i < stakerTokens.length; i++) {
            uint256 combinedId = stakerTokens[i];
            
            // Add infused amount if token is infused
            if (ss.infusedSpecimens[combinedId].infused) {
                totalStaked += ss.infusedSpecimens[combinedId].infusedAmount;
            }
        }
        
        return totalStaked;
    }
}