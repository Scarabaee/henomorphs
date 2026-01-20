// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibHenomorphsStorage} from "../../chargepod/libraries/LibHenomorphsStorage.sol";
import {LibColonyWarsStorage} from "../../chargepod/libraries/LibColonyWarsStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LibStakingStorage} from "./LibStakingStorage.sol";
import {ControlFee} from "../../../libraries/HenomorphsModel.sol";

/**
 * @notice Interface for YELLOW token burn functionality
 */
interface IYellowToken {
    function burnFrom(address account, uint256 amount, string calldata reason) external;
}

/**
 * @title LibFeeCollection
 * @notice ULTRA SIMPLE fee collection library - only essential functions
 * @dev No bloat, no over-engineering
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
library LibFeeCollection {
    using SafeERC20 for IERC20;
    
    // Minimal events
    event FeeCollected(address indexed payer, address indexed beneficiary, uint256 amount, string operation);
    event TreasuryWithdrawal(address indexed recipient, uint256 amount, string reason);
    event TieredFeeApplied(address indexed from, uint256 amount, uint256 feeAmount, uint256 tier);
    event FeeBurned(address indexed from, uint256 amount, string operation);
    
    // Minimal errors
    error InsufficientBalance(address token, uint256 required, uint256 available);
    error InsufficientAllowance(address token, uint256 required, uint256 available);
    error FeeTransferFailed(address token, address from, address to, uint256 amount);
    error InsufficientTreasuryBalance(uint256 required, uint256 available);

    /**
     * @notice Process operation fee - BASIC VERSION
     * @param fee Fee configuration
     * @param payer Address paying the fee
     */
    function processOperationFee(ControlFee memory fee, address payer) internal {
        if (fee.amount == 0 || fee.beneficiary == address(0)) {
            return; // No fee required
        }

        if (fee.burnOnCollect) {
            collectAndBurnFee(fee.currency, payer, fee.beneficiary, fee.amount, "operation");
        } else {
            collectFee(fee.currency, payer, fee.beneficiary, fee.amount, "operation");
        }
    }

    /**
     * @notice Collect fee from payer to beneficiary - CORE FUNCTION
     * @param currency Token contract for payment
     * @param payer Address paying the fee
     * @param beneficiary Address receiving the fee
     * @param amount Amount to collect
     * @param operation Operation identifier for events
     */
    function collectFee(
        IERC20 currency, 
        address payer, 
        address beneficiary, 
        uint256 amount, 
        string memory operation
    ) internal {
        if (amount == 0) return;
        
        // Basic validation
        uint256 balance = currency.balanceOf(payer);
        if (balance < amount) {
            revert InsufficientBalance(address(currency), amount, balance);
        }
        
        uint256 allowance = currency.allowance(payer, address(this));
        if (allowance < amount) {
            revert InsufficientAllowance(address(currency), amount, allowance);
        }
        
        // Transfer
        currency.safeTransferFrom(payer, beneficiary, amount);
        emit FeeCollected(payer, beneficiary, amount, operation);
    }

    /**
     * @notice Collect fee to treasury and immediately burn it
     * @param currency Token contract (YELLOW)
     * @param payer Address paying the fee
     * @param treasury Treasury address (unused, kept for interface compatibility)
     * @param amount Amount to collect and burn
     * @param operation Operation identifier for events
     */
    function collectAndBurnFee(
        IERC20 currency,
        address payer,
        address treasury,
        uint256 amount,
        string memory operation
    ) internal {
        if (amount == 0) return;

        // Validation
        uint256 balance = currency.balanceOf(payer);
        if (balance < amount) {
            revert InsufficientBalance(address(currency), amount, balance);
        }

        uint256 allowance = currency.allowance(payer, address(this));
        if (allowance < amount) {
            revert InsufficientAllowance(address(currency), amount, allowance);
        }

        // Burn directly from payer (requires contract to be burner in YELLOW token)
        IYellowToken(address(currency)).burnFrom(payer, amount, operation);
        emit FeeBurned(payer, amount, operation);

        // Suppress unused variable warning
        treasury;
    }

    /**
     * @notice Process configured operation fee with token-agnostic support
     * @param fee OperationFee configuration from storage
     * @param payer Address paying the fee
     * @param quantityMultiplier Quantity multiplier (e.g., damage points, token count)
     * @param operation Operation identifier for events
     */
    function processConfiguredFee(
        LibColonyWarsStorage.OperationFee storage fee,
        address payer,
        uint256 quantityMultiplier,
        string memory operation
    ) internal {
        // Skip if disabled or no base amount
        if (!fee.enabled || fee.baseAmount == 0) return;
        
        // Calculate final amount: (baseAmount * multiplier * quantity) / 100
        // multiplier: 100 = 1x, 200 = 2x, 50 = 0.5x
        uint256 finalAmount = (fee.baseAmount * fee.multiplier * quantityMultiplier) / 100;
        
        if (finalAmount == 0) return;
        
        // Process fee with burn if configured
        if (fee.burnOnCollect) {
            collectAndBurnFee(IERC20(fee.currency), payer, fee.beneficiary, finalAmount, operation);
        } else {
            collectFee(IERC20(fee.currency), payer, fee.beneficiary, finalAmount, operation);
        }
    }

    /**
     * @notice Process configured operation fee (single quantity overload)
     * @param fee OperationFee configuration from storage
     * @param payer Address paying the fee
     * @param operation Operation identifier for events
     */
    function processConfiguredFee(
        LibColonyWarsStorage.OperationFee storage fee,
        address payer,
        string memory operation
    ) internal {
        processConfiguredFee(fee, payer, 1, operation);
    }

    /**
     * @notice Process OperationFee from ChargeFees with multiplier support
     * @param currency Token address
     * @param beneficiary Destination address
     * @param baseAmount Base fee amount
     * @param multiplier Scaling factor (100 = 1x)
     * @param burnOnCollect Whether to burn after collection
     * @param enabled Whether fee is enabled
     * @param payer Address paying the fee
     * @param quantityMultiplier Quantity multiplier
     * @param operation Operation identifier
     */
    function processOperationFee(
        address currency,
        address beneficiary,
        uint256 baseAmount,
        uint256 multiplier,
        bool burnOnCollect,
        bool enabled,
        address payer,
        uint256 quantityMultiplier,
        string memory operation
    ) internal {
        if (!enabled || baseAmount == 0) return;
        
        uint256 finalAmount = (baseAmount * multiplier * quantityMultiplier) / 100;
        if (finalAmount == 0) return;
        
        if (burnOnCollect) {
            collectAndBurnFee(IERC20(currency), payer, beneficiary, finalAmount, operation);
        } else {
            collectFee(IERC20(currency), payer, beneficiary, finalAmount, operation);
        }
    }

    /**
     * @notice Transfer rewards from treasury to user - BASIC VERSION
     * @param recipient Address receiving rewards
     * @param amount Amount to transfer
     * @param reason Reason for transfer
     */
    function transferFromTreasury(address recipient, uint256 amount, string memory reason) internal {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibHenomorphsStorage.ChargeTreasury storage treasury = hs.chargeTreasury;
        
        // Check balance
        uint256 available = getTreasuryBalance();
        if (available < amount) {
            revert InsufficientTreasuryBalance(amount, available);
        }
        
        // Transfer
        if (treasury.treasuryCurrency == address(0)) {
            // Native currency
            (bool success, ) = payable(recipient).call{value: amount}("");
            require(success, "Native transfer failed");
        } else {
            // ERC20
            IERC20(treasury.treasuryCurrency).safeTransferFrom(
                treasury.treasuryAddress,
                recipient,
                amount
            );
        }
        
        emit TreasuryWithdrawal(recipient, amount, reason);
    }

    /**
     * @notice Get current treasury balance - BASIC VERSION
     * @return balance Current balance in treasury currency
     */
    function getTreasuryBalance() internal view returns (uint256 balance) {
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        LibHenomorphsStorage.ChargeTreasury storage treasury = hs.chargeTreasury;
        
        if (treasury.treasuryCurrency == address(0)) {
            return treasury.treasuryAddress.balance;
        } else {
            return IERC20(treasury.treasuryCurrency).balanceOf(treasury.treasuryAddress);
        }
    }

    /**
     * @notice Check if treasury has sufficient balance - BASIC VERSION
     * @param amount Amount to check
     * @return sufficient Whether treasury can support the operation
     */
    function checkTreasuryBalance(uint256 amount) internal view returns (bool sufficient) {
        return getTreasuryBalance() >= amount;
    }

        /**
     * @notice Get proper beneficiary address for a fee
     * @dev Applies fallback logic if beneficiary not set
     * @param feeConfig Fee configuration
     * @return Appropriate beneficiary address
     */
    function getFeeBeneficiary(ControlFee storage feeConfig) internal view returns (address) {
        if (feeConfig.beneficiary != address(0)) {
            return feeConfig.beneficiary;
        }
        
        // Fallback to treasury
        return LibStakingStorage.stakingStorage().settings.treasuryAddress;
    }

    /**
     * @notice Calculate tiered fee based on amount and tier configuration with base fee consideration
     * @param amount Amount to calculate fee for
     * @param enabled Whether tiered fees are enabled
     * @param thresholds Array of thresholds for fee tiers
     * @param feeBps Array of fee percentages in basis points (100 = 1%)
     * @param baseFee Base fee configuration for the operation
     * @return fee Calculated fee amount (never less than baseFee if applicable)
     * @return tier Tier used for calculation
     * @return useBaseFee Whether the base fee was used instead of calculated percentage
     */
    function calculateTieredFee(
        uint256 amount,
        bool enabled,
        uint256[] storage thresholds,
        uint256[] storage feeBps,
        ControlFee storage baseFee
    ) internal view returns (uint256 fee, uint256 tier, bool useBaseFee) {
        // Check if we should use base fee directly (tiered fees disabled or invalid config)
        if (!enabled || thresholds.length == 0 || feeBps.length == 0 || thresholds.length != feeBps.length) {
            // Use base fee if it's configured
            if (isValidFee(baseFee)) {
                return (baseFee.amount, 0, true);
            }
            return (0, 0, false);
        }
        
        // Skip calculation if amount is zero
        if (amount == 0) {
            return (0, 0, false);
        }
        
        // Find appropriate fee tier
        tier = 0;
        for (uint256 i = 0; i < thresholds.length; i++) {
            if (amount <= thresholds[i]) {
                tier = i;
                break;
            }
            
            if (i == thresholds.length - 1) {
                tier = i;
            }
        }
        
        // Calculate fee (10000 = 100%)
        fee = (amount * feeBps[tier]) / 10000;
        
        // Check if base fee should be used instead (if percentage fee is too small)
        if (isValidFee(baseFee)) {
            if (fee < baseFee.amount) {
                return (baseFee.amount, tier, true);
            }
        }
        
        return (fee, tier, false);
    }
    
    /**
     * @notice Process tiered fee with base fee integration
     * @dev Uses the higher of tiered percentage-based fee or base fee
     * @param amount Amount to calculate fee on 
     * @param enabled Whether tiered fees are enabled
     * @param thresholds Tier thresholds
     * @param feeBps Fee percentages per tier
     * @param baseFee Base fee to use as minimum
     * @param sender User paying the fee
     * @return netAmount Amount after fee deduction
     */
    function processTieredFeeWithFallback(
        uint256 amount,
        bool enabled,
        uint256[] storage thresholds,
        uint256[] storage feeBps,
        ControlFee storage baseFee,
        address sender
    ) internal returns (uint256 netAmount) {
        // Initialize with full amount
        netAmount = amount;
        
        // Calculate tiered fee with base fee integration
        (uint256 feeAmount, uint256 tier, bool usedBaseFee) = calculateTieredFee(
            amount,
            enabled,
            thresholds,
            feeBps,
            baseFee
        );
        
        // Skip if no fee to collect
        if (feeAmount == 0) {
            return amount;
        }
        
        // Ensure fee doesn't exceed reward (leave at least 1% for user)
        uint256 minUserAmount = amount / 100;  // 1% minimum for user
        if (feeAmount >= amount - minUserAmount) {
            feeAmount = amount - minUserAmount;
        }
        
        // Deduct fee from reward
        netAmount = amount - feeAmount;
        
        // Determine token and beneficiary to use
        IERC20 feeToken;
        address beneficiary;
        
        if (usedBaseFee && address(baseFee.currency) != address(0)) {
            // Use the token specified in the base fee
            feeToken = baseFee.currency;
            beneficiary = baseFee.beneficiary;
        } else {
            // Default to ZICO token and treasury address
            feeToken = LibStakingStorage.stakingStorage().zicoToken;
            beneficiary = LibStakingStorage.stakingStorage().settings.treasuryAddress;
        }
        
        // Transfer fee using two-step process
        collectFee(
            feeToken,
            sender,
            beneficiary,
            feeAmount,
            usedBaseFee ? "base_fee" : "tiered_fee"
        );
        
        // Emit appropriate event
        if (usedBaseFee) {
            emit FeeCollected(sender, beneficiary, feeAmount, "base_fee");
        } else {
            emit TieredFeeApplied(sender, amount, feeAmount, tier);
        }
        
        return netAmount;
    }

    /**
     * @notice Validate if a fee is properly configured
     * @param fee ControlFee configuration to check
     * @return isValid True if fee is valid (has both amount and beneficiary)
     */
    function isValidFee(ControlFee storage fee) internal view returns (bool isValid) {
        return fee.amount > 0 && fee.beneficiary != address(0);
    }

    /**
     * @notice Get appropriate fee configuration for an operation type
     * @dev Uses existing fee types as fallback if specific fee not configured
     * @param operationType Type of operation (e.g., "stake", "claim", "harvest")
     * @param ss Storage reference
     * @return fee Reference to appropriate fee configuration
     */
    function getOperationFee(
        string memory operationType,
        LibStakingStorage.StakingStorage storage ss
    ) internal view returns (ControlFee storage fee) {
        bytes32 typeHash = keccak256(bytes(operationType));

        // Support both "stake" and "stakeFee" naming conventions
        if (typeHash == keccak256(bytes("stake")) || typeHash == keccak256(bytes("stakeFee"))) {
            return ss.fees.stakeFee;
        }
        else if (typeHash == keccak256(bytes("unstake")) || typeHash == keccak256(bytes("unstakeFee"))) {
            return ss.fees.unstakeFee;
        }
        else if (typeHash == keccak256(bytes("claim")) || typeHash == keccak256(bytes("claimFee"))) {
            return ss.fees.claimFee;
        }
        else if (typeHash == keccak256(bytes("infusion")) || typeHash == keccak256(bytes("infusionFee"))) {
            return ss.fees.infusionFee;
        }
        else if (typeHash == keccak256(bytes("harvest")) || typeHash == keccak256(bytes("harvestFee"))) {
            // Use harvestFee if configured, otherwise fall back to claimFee
            return isValidFee(ss.fees.harvestFee) ? ss.fees.harvestFee : ss.fees.claimFee;
        }
        else if (typeHash == keccak256(bytes("withdraw")) || typeHash == keccak256(bytes("withdrawalFee"))) {
            // Use withdrawalFee if configured, otherwise fall back to unstakeFee
            return isValidFee(ss.fees.withdrawalFee) ? ss.fees.withdrawalFee : ss.fees.unstakeFee;
        }
        else if (typeHash == keccak256(bytes("reinvest")) || typeHash == keccak256(bytes("reinvestFee"))) {
            // Use reinvestFee if configured, otherwise fall back to infusionFee
            return isValidFee(ss.fees.reinvestFee) ? ss.fees.reinvestFee : ss.fees.infusionFee;
        }
        else if (typeHash == keccak256(bytes("repair")) || typeHash == keccak256(bytes("wearRepairFee"))) {
            return ss.fees.wearRepairFee;
        }
        else if (typeHash == keccak256(bytes("colony")) || typeHash == keccak256(bytes("colonyCreationFee"))) {
            return ss.fees.colonyCreationFee;
        }
        else if (typeHash == keccak256(bytes("membership")) || typeHash == keccak256(bytes("colonyMembershipFee"))) {
            return ss.fees.colonyMembershipFee;
        }

        // Default to claimFee if operation type not recognized
        return ss.fees.claimFee;
    }
}