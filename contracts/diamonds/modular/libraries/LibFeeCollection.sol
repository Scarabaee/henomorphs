// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LibCollectionStorage} from "./LibCollectionStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
    
    // Minimal errors
    error InsufficientBalance(address token, uint256 required, uint256 available);
    error InsufficientAllowance(address token, uint256 required, uint256 available);
    error FeeTransferFailed(address token, address from, address to, uint256 amount);
    error InsufficientTreasuryBalance(uint256 required, uint256 available);
    error CalculationOverflow(uint256 amount, uint256 multiplier); // NEW ERROR

    /**
     * @notice Process operation fee - BASIC VERSION
     * @param fee Fee configuration
     * @param payer Address paying the fee
     */
    function processOperationFee(LibCollectionStorage.ControlFee memory fee, address payer) internal {
        if (fee.amount == 0 || fee.beneficiary == address(0)) {
            return; // No fee required
        }
        
        collectFee(fee.currency, payer, fee.beneficiary, fee.amount, "operation");
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
        address currency, 
        address payer, 
        address beneficiary, 
        uint256 amount, 
        string memory operation
    ) internal {
        if (amount == 0) return;
        
        // Basic validation
        uint256 balance = IERC20(currency).balanceOf(payer);
        if (balance < amount) {
            revert InsufficientBalance(address(currency), amount, balance);
        }
        
        uint256 allowance = IERC20(currency).allowance(payer, address(this));
        if (allowance < amount) {
            revert InsufficientAllowance(address(currency), amount, allowance);
        }
        
        // Transfer
        IERC20(currency).safeTransferFrom(payer, beneficiary, amount);
        emit FeeCollected(payer, beneficiary, amount, operation);
    }

    /**
     * @notice Transfer rewards from treasury to user - BASIC VERSION
     * @param recipient Address receiving rewards
     * @param amount Amount to transfer
     * @param reason Reason for transfer
     */
    function transferFromTreasury(address recipient, uint256 amount, string memory reason) internal {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.SystemTreasury storage treasury = cs.systemTreasury;
        
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
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.SystemTreasury storage treasury = cs.systemTreasury;
        
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
    function getFeeBeneficiary(LibCollectionStorage.ControlFee storage feeConfig) internal view returns (address) {
        if (feeConfig.beneficiary != address(0)) {
            return feeConfig.beneficiary;
        }
        
        // Fallback to treasury
        return LibCollectionStorage.collectionStorage().systemTreasury.treasuryAddress;
    }

    /**
     * @notice Calculate tiered fee based on amount and tier configuration with overflow protection
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
        LibCollectionStorage.ControlFee storage baseFee
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
        
        // FIXED: Safe fee calculation with overflow protection
        uint256 feeBp = feeBps[tier];
        
        // Check for potential overflow before multiplication
        if (amount > type(uint256).max / feeBp) {
            revert CalculationOverflow(amount, feeBp);
        }
        
        // Calculate fee safely (10000 = 100%)
        unchecked {
            fee = (amount * feeBp) / 10000;
        }
        
        // Check if base fee should be used instead (if percentage fee is too small)
        if (isValidFee(baseFee)) {
            if (fee < baseFee.amount) {
                return (baseFee.amount, tier, true);
            }
        }
        
        return (fee, tier, false);
    }
    
    /**
     * @notice Process tiered fee with base fee integration and overflow protection
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
        LibCollectionStorage.ControlFee storage baseFee,
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
        
        // FIXED: Safe minimum calculation with overflow protection
        uint256 minUserAmount;
        unchecked {
            minUserAmount = amount / 100;  // 1% minimum for user - safe division
        }
        
        if (feeAmount >= amount - minUserAmount) {
            feeAmount = amount - minUserAmount;
        }
        
        // Deduct fee from reward - safe subtraction already validated above
        unchecked {
            netAmount = amount - feeAmount;
        }
        
        // Determine token and beneficiary to use
        IERC20 feeToken;
        address beneficiary;
        
        if (usedBaseFee && address(baseFee.currency) != address(0)) {
            // Use the token specified in the base fee
            feeToken = IERC20(baseFee.currency);
            beneficiary = baseFee.beneficiary;
        } else {
            // Default to ZICO token and treasury address
            feeToken = IERC20(LibCollectionStorage.collectionStorage().systemTreasury.treasuryCurrency);
            beneficiary =  LibCollectionStorage.collectionStorage().systemTreasury.treasuryAddress;
        }
        
        // Transfer fee using two-step process
        collectFee(
            address(feeToken),
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
    function isValidFee(LibCollectionStorage.ControlFee storage fee) internal view returns (bool isValid) {
        return fee.amount > 0 && fee.beneficiary != address(0);
    }
}