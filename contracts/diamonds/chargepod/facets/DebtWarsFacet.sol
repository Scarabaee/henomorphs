// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibFeeCollection} from "../../staking/libraries/LibFeeCollection.sol";
import {AccessControlBase} from "../../common/facets/AccessControlBase.sol";
import {ColonyHelper} from "../../staking/libraries/ColonyHelper.sol";
import {AccessHelper} from "../../staking/libraries/AccessHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DebtWarsFacet - Complete Implementation
 * @notice Production-ready debt management system for Colony Wars
 * @dev Implements compound interest, bankruptcy protection, and emergency loans
 */
contract DebtWarsFacet is AccessControlBase {
    
    // Events
    event DebtRecorded(bytes32 indexed colonyId, uint256 amount, string reason);
    event InterestCalculated(bytes32 indexed colonyId, uint256 oldDebt, uint256 newDebt, uint8 interestRate);
    event DebtRepaid(bytes32 indexed colonyId, uint256 amount, uint256 remaining);
    event BankruptcyFiled(bytes32 indexed colonyId, uint256 debtForgiven);
    event DebtForgiven(bytes32 indexed colonyId, uint256 amount, string reason);
    event EmergencyLoanIssued(bytes32 indexed colonyId, uint256 amount, string reason);
    event InterestRateAdjusted(bytes32 indexed colonyId, uint8 oldRate, uint8 newRate);
    event StakeChanged(bytes32 indexed colonyId, uint256 newStake, bool increased, uint256 changeAmount);

    // Custom errors
    error DebtLimitExceeded();
    error ColonyNotInDebt();
    error InsufficientRepayment();
    error BankruptcyNotAllowed();
    error LoanLimitExceeded();
    error UnauthorizedDebtOperation();
    error WarfareNotActive();
    error ColonyNotRegistered();
    error InvalidStake();
    error RateLimitExceeded();
    
    /**
     * @notice Record debt for colony
     * @param colonyId Colony incurring debt
     * @param debtAmount Amount of debt in ZICO
     * @param reason Description of debt origin
     */
    function recordColonyDebt(bytes32 colonyId, uint256 debtAmount, string calldata reason) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("debts");
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (!ColonyHelper.isColonyCreator(colonyId, hs.stakingSystemAddress)) {
            revert UnauthorizedDebtOperation();
        }
        
        LibColonyWarsStorage.DebtRecord storage debt = cws.colonyDebts[colonyId];
        uint256 currentDebt = getCurrentColonyDebt(colonyId);
        uint256 newTotalDebt = currentDebt + debtAmount;
        
        if (newTotalDebt > cws.config.emergencyLoanLimit * 3) {
            revert DebtLimitExceeded();
        }
        
        debt.principalDebt = newTotalDebt;
        debt.debtStartTime = uint32(block.timestamp);
        debt.lastInterestCalculation = uint32(block.timestamp);
        
        if (currentDebt == 0) {
            debt.dailyInterestRate = cws.config.initialInterestRate;
        }
        
        emit DebtRecorded(colonyId, debtAmount, reason);
    }

    /**
     * @notice Calculate compound interest for colony debt
     * @param colonyId Colony to calculate interest for
     * @return newDebtAmount Updated debt amount after interest
     */
    function calculateDebtInterest(bytes32 colonyId) 
        public 
        returns (uint256 newDebtAmount) 
    {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.DebtRecord storage debt = cws.colonyDebts[colonyId];
        
        if (debt.principalDebt == 0) {
            return 0;
        }
        
        uint32 currentTime = uint32(block.timestamp);
        uint32 daysSinceLastCalculation = (currentTime - debt.lastInterestCalculation) / 86400;
        
        if (daysSinceLastCalculation == 0) {
            return debt.principalDebt;
        }
        
        uint256 oldDebt = debt.principalDebt;
        uint256 interestMultiplier = 100 + debt.dailyInterestRate;
        newDebtAmount = debt.principalDebt;
        
        for (uint32 i = 0; i < daysSinceLastCalculation && i < 30; i++) {
            newDebtAmount = (newDebtAmount * interestMultiplier) / 100;
        }
        
        // Cap debt at 5x original to prevent runaway interest
        uint256 maxDebt = debt.principalDebt * 5;
        if (newDebtAmount > maxDebt) {
            newDebtAmount = maxDebt;
        }
        
        debt.principalDebt = newDebtAmount;
        debt.lastInterestCalculation = currentTime;
        
        // Increase interest rate for long-term debt
        uint32 debtAgeDays = (currentTime - debt.debtStartTime) / 86400;
        if (debtAgeDays > 14 && debt.dailyInterestRate < cws.config.maxInterestRate) {
            uint8 newRate = debt.dailyInterestRate + 1;
            if (newRate > cws.config.maxInterestRate) {
                newRate = cws.config.maxInterestRate;
            }
            
            emit InterestRateAdjusted(colonyId, debt.dailyInterestRate, newRate);
            debt.dailyInterestRate = newRate;
        }
        
        emit InterestCalculated(colonyId, oldDebt, newDebtAmount, debt.dailyInterestRate);
        return newDebtAmount;
    }

    /**
     * @notice Repay colony debt
     * @param colonyId Colony making payment
     * @param repaymentAmount ZICO amount to repay
     */
    function repayColonyDebt(bytes32 colonyId, uint256 repaymentAmount) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("debts");
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (!ColonyHelper.isColonyCreator(colonyId, hs.stakingSystemAddress)) {
            revert UnauthorizedDebtOperation();
        }
        
        LibColonyWarsStorage.DebtRecord storage debt = cws.colonyDebts[colonyId];
        
        if (debt.principalDebt == 0) {
            revert ColonyNotInDebt();
        }
        
        uint256 currentDebt = calculateDebtInterest(colonyId);
        
        if (repaymentAmount == 0 || repaymentAmount > currentDebt) {
            revert InsufficientRepayment();
        }
        
        address currency = hs.chargeTreasury.treasuryCurrency;
        LibFeeCollection.collectFee(
            IERC20(currency),
            LibMeta.msgSender(),
            hs.chargeTreasury.treasuryAddress,
            repaymentAmount,
            "debt_repayment"
        );
        
        uint256 remainingDebt = currentDebt - repaymentAmount;
        debt.principalDebt = remainingDebt;
        
        if (remainingDebt == 0) {
            delete cws.colonyDebts[colonyId];
        } else {
            debt.lastInterestCalculation = uint32(block.timestamp);
            
            if (debt.dailyInterestRate > cws.config.initialInterestRate) {
                debt.dailyInterestRate -= 1;
            }
        }
        
        emit DebtRepaid(colonyId, repaymentAmount, remainingDebt);
    }

    /**
     * @notice File for bankruptcy protection
     * @param colonyId Colony filing for bankruptcy
     */
    function fileColonyBankruptcy(bytes32 colonyId) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.requireFeatureNotPaused("debts");
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (!ColonyHelper.isColonyCreator(colonyId, hs.stakingSystemAddress)) {
            revert UnauthorizedDebtOperation();
        }
        
        LibColonyWarsStorage.DebtRecord storage debt = cws.colonyDebts[colonyId];
        
        if (debt.principalDebt == 0) {
            revert ColonyNotInDebt();
        }
        
        if (debt.inBankruptcyProtection) {
            revert BankruptcyNotAllowed();
        }
        
        uint256 debtToForgive = calculateDebtInterest(colonyId);
        uint32 debtAge = (uint32(block.timestamp) - debt.debtStartTime) / 86400;
        
        if (debtToForgive < cws.config.emergencyLoanLimit || debtAge < 7) {
            revert BankruptcyNotAllowed();
        }
        
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
        
        if (profile.defensiveStake > 0) {
            uint256 penalty = profile.defensiveStake / 4;
            profile.defensiveStake -= penalty;
            
            LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
            season.prizePool += penalty;
        }
        
        profile.reputation = 6; // Bankrupt reputation
        debt.principalDebt = 0;
        debt.inBankruptcyProtection = true;
        
        emit BankruptcyFiled(colonyId, debtToForgive);
    }

    /**
     * @notice Issue emergency loan (admin function)
     * @param colonyId Colony receiving emergency aid
     * @param loanAmount Amount of emergency loan
     * @param reason Justification for emergency loan
     */
    function issueEmergencyLoan(bytes32 colonyId, uint256 loanAmount, string calldata reason) 
        external 
        onlyAuthorized 
        whenNotPaused 
    {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        if (loanAmount > cws.config.emergencyLoanLimit) {
            revert LoanLimitExceeded();
        }
        
        address colonyOwner = hs.colonyCreators[colonyId];
        if (colonyOwner == address(0)) {
            revert ColonyNotInDebt();
        }
        
        LibFeeCollection.transferFromTreasury(colonyOwner, loanAmount, "emergency_loan");
        
        LibColonyWarsStorage.DebtRecord storage debt = cws.colonyDebts[colonyId];
        debt.principalDebt += loanAmount;
        debt.debtStartTime = uint32(block.timestamp);
        debt.lastInterestCalculation = uint32(block.timestamp);
        debt.dailyInterestRate = 1; // Favorable rate for emergency loans
        
        emit EmergencyLoanIssued(colonyId, loanAmount, reason);
    }

    /**
     * @notice Forgive colony debt (admin function)
     * @param colonyId Colony to forgive debt for
     * @param forgivenessAmount Amount to forgive
     * @param reason Reason for forgiveness
     */
    function forgiveColonyDebt(bytes32 colonyId, uint256 forgivenessAmount, string calldata reason) 
        external 
        onlyAuthorized 
    {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.DebtRecord storage debt = cws.colonyDebts[colonyId];
        
        if (debt.principalDebt == 0) {
            revert ColonyNotInDebt();
        }
        
        uint256 currentDebt = calculateDebtInterest(colonyId);
        uint256 actualForgiveness = forgivenessAmount > currentDebt ? currentDebt : forgivenessAmount;
        
        debt.principalDebt = currentDebt - actualForgiveness;
        
        if (debt.principalDebt == 0) {
            delete cws.colonyDebts[colonyId];
        }
        
        emit DebtForgiven(colonyId, actualForgiveness, reason);
    }

    /**
     * @notice Calculate interest for multiple colonies
     * @param colonyIds Array of colony IDs to process
     */
    function batchCalculateDebtInterest(bytes32[] calldata colonyIds) 
        external 
        whenNotPaused 
    {
        LibColonyWarsStorage.requireInitialized();
        
        for (uint256 i = 0; i < colonyIds.length && i < 20; i++) {
            calculateDebtInterest(colonyIds[i]); // Limit to 20 colonies per call to avoid gas issues
        }
    }

    /**
     * @notice Leverage defensive position through strategic debt financing
     * @param colonyId Colony to leverage
     * @param leverageAmount Amount to borrow for defensive enhancement
     * @dev Enables tactical leverage at the cost of higher interest rates
     */
    function leverageDefensivePosition(bytes32 colonyId, uint256 leverageAmount) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();

        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Only allow during warfare period
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
        if (!season.active || block.timestamp < season.registrationEnd || block.timestamp > season.warfareEnd) {
            revert WarfareNotActive();
        }
        
        // Verify caller controls the colony
        if (!ColonyHelper.isColonyCreator(colonyId, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony controller");
        }
        
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
        if (!profile.registered) {
            revert ColonyNotRegistered();
        }
        
        // Leverage limits
        uint256 currentDebt = getCurrentColonyDebt(colonyId);
        uint256 maxLeverageCapacity = cws.config.emergencyLoanLimit * 2;
        
        if (currentDebt + leverageAmount > maxLeverageCapacity) {
            revert DebtLimitExceeded();
        }
        
        // Limit leverage to reach max stake
        uint256 currentStake = profile.defensiveStake;
        uint256 maxStake = cws.config.maxStakeAmount;
        
        if (currentStake >= maxStake) {
            revert InvalidStake();
        }
        
        uint256 stakeCapacity = maxStake - currentStake;
        if (leverageAmount > stakeCapacity) {
            revert InvalidStake();
        }
        
        // Minimum leverage amount check
        if (leverageAmount < cws.config.minStakeAmount / 2) {
            revert InvalidStake();
        }
        
        // Rate limiting - once per 3 days
        if (!LibColonyWarsStorage.checkRateLimit(
            LibMeta.msgSender(), 
            this.leverageDefensivePosition.selector, 
            259200 // 3 days
        )) {
            revert RateLimitExceeded();
        }
        
        // Premium interest rate for leveraged positions
        LibColonyWarsStorage.DebtRecord storage debt = cws.colonyDebts[colonyId];
        
        if (currentDebt == 0) {
            debt.dailyInterestRate = cws.config.initialInterestRate + 2; // Risk premium
            debt.debtStartTime = uint32(block.timestamp);
        } else {
            if (debt.dailyInterestRate < cws.config.maxInterestRate) {
                debt.dailyInterestRate += 1;
            }
        }
        
        // Record leveraged debt
        debt.principalDebt = currentDebt + leverageAmount;
        debt.lastInterestCalculation = uint32(block.timestamp);
        
        // Increase defensive stake without payment
        profile.defensiveStake = currentStake + leverageAmount;
        profile.stakeIncreases++;
        
        emit DebtRecorded(colonyId, leverageAmount, "Strategic leverage");
        emit StakeChanged(colonyId, profile.defensiveStake, true, leverageAmount);
    }

    /**
     * @notice Assess available leverage capacity for defensive enhancement
     * @param colonyId Colony to evaluate
     * @return eligible Whether colony qualifies for leverage
     * @return capacity Maximum leverage available
     * @return exposure Current debt exposure
     * @return premium Interest rate premium that would apply
     */
    function assessLeverageCapacity(bytes32 colonyId)
        external
        view
        returns (
            bool eligible,
            uint256 capacity,
            uint256 exposure,
            uint8 premium
        )
    {
        LibColonyWarsStorage.requireInitialized();
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        LibColonyWarsStorage.ColonyWarProfile storage profile = cws.colonyWarProfiles[colonyId];
        LibColonyWarsStorage.DebtRecord storage debt = cws.colonyDebts[colonyId];
        
        exposure = getCurrentColonyDebt(colonyId);
        uint256 maxLeverageCapacity = cws.config.emergencyLoanLimit * 2;
        
        // Check eligibility
        if (!profile.registered || 
            exposure >= maxLeverageCapacity || 
            profile.defensiveStake >= cws.config.maxStakeAmount) {
            return (false, 0, exposure, 0);
        }
        
        // Calculate available capacity
        uint256 debtCapacity = maxLeverageCapacity - exposure;
        uint256 stakeCapacity = cws.config.maxStakeAmount - profile.defensiveStake;
        capacity = debtCapacity < stakeCapacity ? debtCapacity : stakeCapacity;
        
        // Calculate interest premium
        if (exposure == 0) {
            premium = cws.config.initialInterestRate + 2;
        } else {
            premium = debt.dailyInterestRate + 1;
            if (premium > cws.config.maxInterestRate) {
                premium = cws.config.maxInterestRate;
            }
        }
        
        eligible = capacity >= cws.config.minStakeAmount / 2;
        
        return (eligible, capacity, exposure, premium);
    }

    // View functions

    /**
     * @notice Get current debt with accrued interest
     * @param colonyId Colony to check
     * @return currentDebt Current debt including interest
     */
    function getCurrentColonyDebt(bytes32 colonyId) 
        public 
        view 
        returns (uint256 currentDebt) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.DebtRecord storage debt = cws.colonyDebts[colonyId];
        
        if (debt.principalDebt == 0) {
            return 0;
        }
        
        uint32 daysSinceLastCalculation = (uint32(block.timestamp) - debt.lastInterestCalculation) / 86400;
        
        if (daysSinceLastCalculation == 0) {
            return debt.principalDebt;
        }
        
        uint256 interestMultiplier = 100 + debt.dailyInterestRate;
        currentDebt = debt.principalDebt;
        
        for (uint32 i = 0; i < daysSinceLastCalculation && i < 30; i++) {
            currentDebt = (currentDebt * interestMultiplier) / 100;
        }
        
        uint256 maxDebt = debt.principalDebt * 5;
        if (currentDebt > maxDebt) {
            currentDebt = maxDebt;
        }
        
        return currentDebt;
    }

    /**
     * @notice Get colony debt record
     * @param colonyId Colony to check
     * @return debt Full debt record
     */
    function getColonyDebt(bytes32 colonyId) 
        external 
        view 
        returns (LibColonyWarsStorage.DebtRecord memory debt) 
    {
        return LibColonyWarsStorage.colonyWarsStorage().colonyDebts[colonyId];
    }

    /**
     * @notice Get colonies with active debt
     * @return debtors Array of colony IDs with debt
     * @return amounts Array of current debt amounts
     */
    function getColoniesWithDebt() 
        external 
        view 
        returns (bytes32[] memory debtors, uint256[] memory amounts) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibColonyWarsStorage.Season storage season = cws.seasons[cws.currentSeason];
        
        uint256 debtorCount = 0;
        for (uint256 i = 0; i < season.registeredColonies.length; i++) {
            if (cws.colonyDebts[season.registeredColonies[i]].principalDebt > 0) {
                debtorCount++;
            }
        }
        
        debtors = new bytes32[](debtorCount);
        amounts = new uint256[](debtorCount);
        
        uint256 index = 0;
        for (uint256 i = 0; i < season.registeredColonies.length; i++) {
            bytes32 colonyId = season.registeredColonies[i];
            if (cws.colonyDebts[colonyId].principalDebt > 0) {
                debtors[index] = colonyId;
                amounts[index] = getCurrentColonyDebt(colonyId);
                index++;
            }
        }
        
        return (debtors, amounts);
    }
}