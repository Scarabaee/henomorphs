// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibColonyWarsStorage} from "./LibColonyWarsStorage.sol";
import {LibHenomorphsStorage} from "./LibHenomorphsStorage.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibFeeCollection} from "../../staking/libraries/LibFeeCollection.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ResourceHelper
 * @notice Eliminates duplicate resource balance manipulation code
 * @dev Diamond Proxy compliant - operates on existing storage structures
 * @author rutilicus.eth (ArchXS)
 */
library ResourceHelper {
    using LibColonyWarsStorage for LibColonyWarsStorage.ColonyWarsStorage;

    // =================== ERRORS ===================

    error InsufficientResources(uint8 resourceType, uint256 required, uint256 available);
    error InvalidResourceType(uint8 resourceType);
    error ColonyNotFound(bytes32 colonyId);

    // =================== RESOURCE BALANCE OPERATIONS ===================

    /**
     * @notice Check if colony has sufficient resources
     * @dev Replaces duplicate _hasEnoughResources() in multiple facets
     * @param balance Resource balance storage reference
     * @param resourceType Type of resource (0-3)
     * @param amount Amount required
     * @return sufficient True if balance >= amount
     */
    function hasEnoughResources(
        LibColonyWarsStorage.ResourceBalance storage balance,
        LibColonyWarsStorage.ResourceType resourceType,
        uint256 amount
    ) internal view returns (bool sufficient) {
        if (resourceType == LibColonyWarsStorage.ResourceType.BasicMaterials) {
            return balance.basicMaterials >= amount;
        } else if (resourceType == LibColonyWarsStorage.ResourceType.EnergyCrystals) {
            return balance.energyCrystals >= amount;
        } else if (resourceType == LibColonyWarsStorage.ResourceType.BioCompounds) {
            return balance.bioCompounds >= amount;
        } else if (resourceType == LibColonyWarsStorage.ResourceType.RareElements) {
            return balance.rareElements >= amount;
        }
        return false;
    }

    /**
     * @notice Deduct resources from balance
     * @dev Replaces duplicate _deductResources() in multiple facets
     * @param balance Resource balance storage reference
     * @param resourceType Type of resource (0-3)
     * @param amount Amount to deduct
     */
    function deductResources(
        LibColonyWarsStorage.ResourceBalance storage balance,
        LibColonyWarsStorage.ResourceType resourceType,
        uint256 amount
    ) internal {
        if (resourceType == LibColonyWarsStorage.ResourceType.BasicMaterials) {
            balance.basicMaterials -= amount;
        } else if (resourceType == LibColonyWarsStorage.ResourceType.EnergyCrystals) {
            balance.energyCrystals -= amount;
        } else if (resourceType == LibColonyWarsStorage.ResourceType.BioCompounds) {
            balance.bioCompounds -= amount;
        } else if (resourceType == LibColonyWarsStorage.ResourceType.RareElements) {
            balance.rareElements -= amount;
        }
    }

    /**
     * @notice Add resources to balance
     * @dev Replaces duplicate _addResources() in multiple facets
     * @param balance Resource balance storage reference
     * @param resourceType Type of resource (0-3)
     * @param amount Amount to add
     */
    function addResources(
        LibColonyWarsStorage.ResourceBalance storage balance,
        LibColonyWarsStorage.ResourceType resourceType,
        uint256 amount
    ) internal {
        if (resourceType == LibColonyWarsStorage.ResourceType.BasicMaterials) {
            balance.basicMaterials += amount;
        } else if (resourceType == LibColonyWarsStorage.ResourceType.EnergyCrystals) {
            balance.energyCrystals += amount;
        } else if (resourceType == LibColonyWarsStorage.ResourceType.BioCompounds) {
            balance.bioCompounds += amount;
        } else if (resourceType == LibColonyWarsStorage.ResourceType.RareElements) {
            balance.rareElements += amount;
        }
    }

    /**
     * @notice Check and deduct resources in one call
     * @dev Common pattern: check then deduct
     * @param balance Resource balance storage reference
     * @param resourceType Type of resource (0-3)
     * @param amount Amount to deduct
     */
    function requireAndDeduct(
        LibColonyWarsStorage.ResourceBalance storage balance,
        LibColonyWarsStorage.ResourceType resourceType,
        uint256 amount
    ) internal {
        uint256 available = getResourceAmount(balance, resourceType);
        if (available < amount) {
            revert InsufficientResources(uint8(resourceType), amount, available);
        }
        deductResources(balance, resourceType, amount);
    }

    /**
     * @notice Get resource amount by type
     * @param balance Resource balance storage reference
     * @param resourceType Type of resource (0-3)
     * @return amount Resource amount
     */
    function getResourceAmount(
        LibColonyWarsStorage.ResourceBalance storage balance,
        LibColonyWarsStorage.ResourceType resourceType
    ) internal view returns (uint256 amount) {
        if (resourceType == LibColonyWarsStorage.ResourceType.BasicMaterials) {
            return balance.basicMaterials;
        } else if (resourceType == LibColonyWarsStorage.ResourceType.EnergyCrystals) {
            return balance.energyCrystals;
        } else if (resourceType == LibColonyWarsStorage.ResourceType.BioCompounds) {
            return balance.bioCompounds;
        } else if (resourceType == LibColonyWarsStorage.ResourceType.RareElements) {
            return balance.rareElements;
        }
        return 0;
    }

    // =================== COLONY HELPERS ===================

    /**
     * @notice Get colony ID for user
     * @dev Common pattern across resource facets
     * @param user User address
     * @return colonyId Colony ID (bytes32(0) if none)
     */
    function getUserColony(address user) internal view returns (bytes32) {
        return LibColonyWarsStorage.colonyWarsStorage().userToColony[user];
    }

    /**
     * @notice Require user has colony
     * @param user User address
     * @return colonyId User's colony ID
     */
    function requireUserColony(address user) internal view returns (bytes32 colonyId) {
        colonyId = getUserColony(user);
        if (colonyId == bytes32(0)) {
            revert ColonyNotFound(colonyId);
        }
        return colonyId;
    }

    /**
     * @notice Get colony resource balance
     * @param colonyId Colony ID
     * @return balance Storage reference to colony resources
     */
    function getColonyResources(bytes32 colonyId)
        internal
        view
        returns (LibColonyWarsStorage.ResourceBalance storage)
    {
        return LibColonyWarsStorage.colonyWarsStorage().colonyResources[colonyId];
    }

    // =================== TREASURY TOKEN HELPERS ===================

    /**
     * @notice Get primary currency token address (Premium/Strategic operations)
     * @dev Single source: ChargeTreasury.treasuryCurrency
     * @return Primary currency address
     */
    function getPrimaryCurrency() internal view returns (address) {
        return LibHenomorphsStorage.henomorphsStorage().chargeTreasury.treasuryCurrency;
    }

    /**
     * @notice Get auxiliary currency token address (Utility/Daily operations)
     * @dev Single source: ChargeTreasury.auxiliaryCurrency
     * @return Auxiliary currency address
     */
    function getAuxiliaryCurrency() internal view returns (address) {
        return LibHenomorphsStorage.henomorphsStorage().chargeTreasury.auxiliaryCurrency;
    }

    /**
     * @notice Get treasury address
     * @dev Single source: ChargeTreasury.treasuryAddress
     * @return Treasury address
     */
    function getTreasuryAddress() internal view returns (address) {
        return LibHenomorphsStorage.henomorphsStorage().chargeTreasury.treasuryAddress;
    }

    // =================== TREASURY FEE COLLECTION HELPERS ===================

    /**
     * @notice Collect primary currency fee (ZICO - strategic operations)
     * @dev Wrapper for LibFeeCollection.collectFee with treasury configuration
     * @param payer Address paying the fee
     * @param amount Amount to collect
     * @param operation Operation name for event
     */
    function collectPrimaryFee(
        address payer,
        uint256 amount,
        string memory operation
    ) internal {
        if (amount == 0) return;
        
        LibFeeCollection.collectFee(
            IERC20(getPrimaryCurrency()),
            payer,
            getTreasuryAddress(),
            amount,
            operation
        );
    }

    /**
     * @notice Collect auxiliary currency fee (YLW - utility operations)
     * @dev Wrapper for LibFeeCollection.collectFee with auxiliary currency
     * @param payer Address paying the fee
     * @param amount Amount to collect
     * @param operation Operation name for event
     */
    function collectAuxiliaryFee(
        address payer,
        uint256 amount,
        string memory operation
    ) internal {
        if (amount == 0) return;
        
        address auxCurrency = getAuxiliaryCurrency();
        require(auxCurrency != address(0), "Auxiliary currency not configured");
        
        LibFeeCollection.collectFee(
            IERC20(auxCurrency),
            payer,
            getTreasuryAddress(),
            amount,
            operation
        );
    }

    /**
     * @notice Reward user with currency from treasury
     * @dev Wrapper for LibFeeCollection.transferFromTreasury
     * @param recipient User receiving reward
     * @param amount Reward amount
     * @param reason Reason for reward
     */
    function rewardFromTreasury(
        address recipient,
        uint256 amount,
        string memory reason
    ) internal {
        if (amount == 0) return;
        LibFeeCollection.transferFromTreasury(recipient, amount, reason);
    }

    /**
     * @notice Transfer auxiliary currency (YLW) from treasury to recipient
     * @dev Used for prediction markets LP withdrawal and other YLW-based operations
     * @param recipient Address receiving tokens
     * @param amount Amount to transfer
     */
    function transferAuxiliaryFromTreasury(
        address recipient,
        uint256 amount,
        string memory /* reason */
    ) internal {
        if (amount == 0) return;

        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        address auxCurrency = hs.chargeTreasury.auxiliaryCurrency;
        address treasuryAddress = hs.chargeTreasury.treasuryAddress;

        require(auxCurrency != address(0), "Auxiliary currency not configured");
        require(treasuryAddress != address(0), "Treasury not configured");

        // Check treasury has sufficient auxiliary currency balance
        uint256 available = IERC20(auxCurrency).balanceOf(treasuryAddress);
        require(available >= amount, "Insufficient auxiliary treasury balance");

        // Transfer from treasury to recipient
        IERC20(auxCurrency).transferFrom(treasuryAddress, recipient, amount);
    }

    /**
     * @notice Check if treasury has sufficient balance
     * @param amount Amount needed
     * @return sufficient True if treasury has enough
     */
    function hasSufficientTreasuryBalance(uint256 amount) internal view returns (bool) {
        address currency = getPrimaryCurrency();
        if (currency == address(0)) return false;
        
        uint256 balance = IERC20(currency).balanceOf(getTreasuryAddress());
        return balance >= amount;
    }

    /**
     * @notice Get treasury balance in primary currency
     * @return balance Treasury balance
     */
    function getTreasuryBalance() internal view returns (uint256) {
        address currency = getPrimaryCurrency();
        if (currency == address(0)) return 0;

        return IERC20(currency).balanceOf(getTreasuryAddress());
    }

    // =================== CARD MINT PAYMENT HELPERS ===================

    error InsufficientNativePayment(uint256 required, uint256 sent);
    error NativePaymentNotAccepted();

    /**
     * @notice Collect fee for card minting with configurable payment options
     * @dev Supports native currency, custom ERC20, or default ZICO with discount
     * @param payer Address paying the fee
     * @param baseAmount Base price before discount
     * @param operation Operation name for event
     */
    function collectCardMintFee(
        address payer,
        uint256 baseAmount,
        string memory operation
    ) internal {
        if (baseAmount == 0) return;

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.CardMintPricing storage pricing = cws.cardMintPricing;

        // Apply discount if configured
        uint256 finalAmount = baseAmount;
        if (pricing.discountBps > 0) {
            finalAmount = (baseAmount * (10000 - pricing.discountBps)) / 10000;
        }

        // Native payment path
        if (pricing.useNativePayment) {
            if (msg.value < finalAmount) {
                revert InsufficientNativePayment(finalAmount, msg.value);
            }
            // Transfer native to treasury
            (bool success, ) = getTreasuryAddress().call{value: finalAmount}("");
            require(success, "Native transfer failed");
            // Refund excess
            if (msg.value > finalAmount) {
                (bool refundSuccess, ) = payer.call{value: msg.value - finalAmount}("");
                require(refundSuccess, "Refund failed");
            }
            return;
        }

        // ERC20 payment path
        address paymentToken = pricing.paymentToken;
        if (paymentToken == address(0)) {
            // Default to primary currency (ZICO)
            paymentToken = getPrimaryCurrency();
        }

        LibFeeCollection.collectFee(
            IERC20(paymentToken),
            payer,
            getTreasuryAddress(),
            finalAmount,
            operation
        );
    }

    /**
     * @notice Calculate final price after discount
     * @param baseAmount Base price before discount
     * @return finalAmount Price after discount applied
     */
    function calculateDiscountedPrice(uint256 baseAmount) internal view returns (uint256 finalAmount) {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        uint16 discountBps = cws.cardMintPricing.discountBps;

        if (discountBps == 0) {
            return baseAmount;
        }

        return (baseAmount * (10000 - discountBps)) / 10000;
    }
}
