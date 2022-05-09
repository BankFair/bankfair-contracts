// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.12;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./ManagedLendingPool.sol";

/**
 * @title BankFair Lender
 * @notice Extends ManagedLendingPool with lending functionality.
 * @dev This contract is abstract. Extend the contract to implement an intended pool functionality.
 */
abstract contract Lender is ManagedLendingPool {

    using SafeMath for uint256;

    enum LoanStatus {
        APPLIED,
        DENIED,
        APPROVED,
        CANCELLED,
        FUNDS_WITHDRAWN,
        REPAID,
        DEFAULTED
    }

    /// Loan application object
    struct Loan {
        uint256 id;
        address borrower;
        uint256 amount;
        uint256 duration; 
        uint16 apr; 
        uint16 lateAPRDelta; 
        uint256 requestedTime;
        LoanStatus status;
    }

    /// Loan payment details object
    struct LoanDetail {
        uint256 loanId;
        uint256 totalAmountRepaid; //total amount paid including interest
        uint256 baseAmountRepaid;
        uint256 interestPaid;
        uint256 approvedTime;
        uint256 lastPaymentTime;
    }

    event LoanRequested(uint256 loanId, address indexed borrower);
    event LoanApproved(uint256 loanId);
    event LoanDenied(uint256 loanId);
    event LoanCancelled(uint256 loanId);
    event LoanRepaid(uint256 loanId);
    event LoanDefaulted(uint256 loanId, uint256 amountLost);

    modifier loanInStatus(uint256 loanId, LoanStatus status) {
        Loan storage loan = loans[loanId];
        require(loan.id != 0, "Loan is not found.");
        require(loan.status == status, "Loan does not have a valid status for this operation.");
        _;
    }

    modifier onlyLender() {
        address wallet = msg.sender;
        require(wallet != address(0), "BankFair: Address is not present.");
        require(wallet != manager && wallet != protocolWallet, "BankFair: Wallet is a manager or protocol.");
        //FIXME: currently borrower is a wallet that has any past or present loans/application,
        //TODO wallet is a borrower if: has open loan or loan application. Implement basic loan history first.
        require(recentLoanIdOf[wallet] == 0, "BankFair: Wallet is a borrower."); 
        _;
    }

    modifier onlyBorrower() {
        address wallet = msg.sender;
        require(wallet != address(0), "BankFair: Address is not present.");
        require(wallet != manager && wallet != protocolWallet, "BankFair: Wallet is a manager or protocol.");
        require(poolShares[wallet] == 0, "BankFair: Applicant is a lender.");
        _;
    }

    // APR, to represent a percentage value as int, multiply by (10 ^ percentDecimals)

    /// Safe minimum for APR values
    uint16 public constant SAFE_MIN_APR = 0; // 0%

    /// Safe maximum for APR values
    uint16 public constant SAFE_MAX_APR = ONE_HUNDRED_PERCENT;

    /// Loan APR to be applied for the new loan requests
    uint16 public defaultAPR;

    /// Loan late payment APR delta to be applied fot the new loan requests
    uint16 public defaultLateAPRDelta;

    /// Contract math safe minimum loan amount including token decimals
    uint256 public constant SAFE_MIN_AMOUNT = 1000000; // 1 token unit with 6 decimals. i.e. 1 USDC

    /// Minimum allowed loan amount 
    uint256 public minAmount;

    /// Contract math safe minimum loan duration in seconds
    uint256 public constant SAFE_MIN_DURATION = 1 days;

    /// Contract math safe maximum loan duration in seconds
    uint256 public constant SAFE_MAX_DURATION = 51 * 365 days;

    /// Minimum loan duration in seconds
    uint256 public minDuration;

    /// Maximum loan duration in seconds
    uint256 public maxDuration;

    /// Loan id generator counter
    uint256 private nextLoanId;

    /// Quick lookup to check an address has pending loan applications
    mapping(address => bool) private hasOpenApplication;

    /// Total funds borrowed at this time, including both withdrawn and allocated for withdrawal.
    uint256 public borrowedFunds;

    /// Total borrowed funds allocated for withdrawal but not yet withdrawn by the borrowers
    uint256 public loanFundsPendingWithdrawal;

    /// Borrowed funds allocated for withdrawal by borrower addresses
    mapping(address => uint256) public loanFunds; //FIXE make internal

    /// Loan applications by loanId
    mapping(uint256 => Loan) public loans;

    /// Loan payment details by loanId. Loan detail is available only after a loan has been approved.
    mapping(uint256 => LoanDetail) public loanDetails;

    /// Recent loanId of an address. Value of 0 means that the address doe not have any loan requests
    mapping(address => uint256) public recentLoanIdOf;

    /**
     * @notice Create a Lender that ManagedLendingPool.
     * @dev minLoanAmount must be greater than or equal to SAFE_MIN_AMOUNT.
     * @param tokenAddress ERC20 token contract address to be used as main pool liquid currency.
     * @param protocol Address of a wallet to accumulate protocol earnings.
     * @param minLoanAmount Minimum amount to be borrowed per loan.
     */
    constructor(address tokenAddress, address protocol, uint256 minLoanAmount) ManagedLendingPool(tokenAddress, protocol) {
        
        nextLoanId = 1;

        require(SAFE_MIN_AMOUNT <= minLoanAmount, "New min loan amount is less than the safe limit");
        minAmount = minLoanAmount;
        
        defaultAPR = 300; // 30%
        defaultLateAPRDelta = 50; //5%
        minDuration = SAFE_MIN_DURATION;
        maxDuration = SAFE_MAX_DURATION;

        poolLiquidity = 0;
        borrowedFunds = 0;
        loanFundsPendingWithdrawal = 0;
    }

    function loansCount() external view returns(uint256) {
        return nextLoanId - 1;
    }

    //FIXME only allow protocol to edit critical parameters, not the manager

    /**
     * @notice Set annual loan interest rate for the future loans.
     * @dev apr must be inclusively between SAFE_MIN_APR and SAFE_MAX_APR.
     *      Caller must be the manager.
     * @param apr Loan APR to be applied for the new loan requests.
     */
    function setDefaultAPR(uint16 apr) external onlyManager {
        require(SAFE_MIN_APR <= apr && apr <= SAFE_MAX_APR, "APR is out of bounds");
        defaultAPR = apr;
    }

    /**
     * @notice Set late payment annual loan interest rate delta for the future loans.
     * @dev lateAPRDelta must be inclusively between SAFE_MIN_APR and SAFE_MAX_APR.
     *      Caller must be the manager.
     * @param lateAPRDelta Loan late payment APR delta to be applied for the new loan requests.
     */
    function setDefaultLateAPRDelta(uint16 lateAPRDelta) external onlyManager {
        require(SAFE_MIN_APR <= lateAPRDelta && lateAPRDelta <= SAFE_MAX_APR, "APR is out of bounds");
        defaultLateAPRDelta = lateAPRDelta;
    }

    /**
     * @notice Set a minimum loan amount for the future loans.
     * @dev minLoanAmount must be greater than or equal to SAFE_MIN_AMOUNT.
     *      Caller must be the manager.
     * @param minLoanAmount minimum loan amount to be enforced for the new loan requests.
     */
    function setMinLoanAmount(uint256 minLoanAmount) external onlyManager {
        require(SAFE_MIN_AMOUNT <= minLoanAmount, "New min loan amount is less than the safe limit");
        minAmount = minLoanAmount;
    }

    /**
     * @notice Set maximum loan duration for the future loans.
     * @dev Duration must be in seconds and inclusively between SAFE_MIN_DURATION and SAFE_MAX_DURATION.
     *      Caller must be the manager.
     * @param duration Maximum loan duration to be enforced for the new loan requests.
     */
    function setLoanMinDuration(uint256 duration) external onlyManager {
        require(SAFE_MIN_DURATION <= duration && duration <= SAFE_MAX_DURATION, "New min duration is out of bounds");
        require(duration <= maxDuration, "New min duration is greater than current max duration");
        minDuration = duration;
    }

    /**
     * @notice Set maximum loan duration for the future loans.
     * @dev Duration must be in seconds and inclusively between SAFE_MIN_DURATION and SAFE_MAX_DURATION.
     *      Caller must be the manager.
     * @param duration Maximum loan duration to be enforced for the new loan requests.
     */
    function setLoanMaxDuration(uint256 duration) external onlyManager {
        require(SAFE_MIN_DURATION <= duration && duration <= SAFE_MAX_DURATION, "New max duration is out of bounds");
        require(minDuration <= duration, "New max duration is less than current min duration");
        maxDuration = duration;
    }

    /**
     * @notice Request a new loan.
     * @dev Requested amount must be greater or equal to minAmount().
     *      Loan duration must be between minDuration() and maxDuration().
     *      Caller must not be a lender, protocol, or the manager. 
     *      Multiple pending applications from the same address are not allowed,
     *      most recent loan/application of the caller must not have APPLIED status.
     * @param requestedAmount Token amount to be borrowed.
     * @param loanDuration Loan duration in seconds. 
     * @return ID of a new loan application.
     */
    function requestLoan(uint256 requestedAmount, uint256 loanDuration) external onlyBorrower returns (uint256) {

        require(hasOpenApplication[msg.sender] == false, "Another loan application is pending.");

        //FIXME enforce minimum loan amount
        require(requestedAmount > 0, "Loan amount is zero.");
        require(minDuration <= loanDuration, "Loan duration is less than minimum allowed.");
        require(maxDuration >= loanDuration, "Loan duration is more than maximum allowed.");

        //TODO check:
        // ?? must not have unpaid late loans
        // ?? must not have defaulted loans

        uint256 loanId = nextLoanId;
        nextLoanId++;

        loans[loanId] = Loan({
            id: loanId,
            borrower: msg.sender,
            amount: requestedAmount,
            duration: loanDuration,
            apr: defaultAPR,
            lateAPRDelta: defaultLateAPRDelta,
            requestedTime: block.timestamp,
            status: LoanStatus.APPLIED
        });

        hasOpenApplication[msg.sender] = true;
        recentLoanIdOf[msg.sender] = loanId; 

        emit LoanRequested(loanId, msg.sender);

        return loanId;
    }

    /**
     * @notice Approve a loan.
     * @dev Loan must be in APPLIED status.
     *      Caller must be the manager.
     *      Loan amount must not exceed poolLiquidity();
     *      Stake to pool funds ratio must be good - poolCanLend() must be true.
     */
    function approveLoan(uint256 _loanId) external onlyManager loanInStatus(_loanId, LoanStatus.APPLIED) {
        Loan storage loan = loans[_loanId];

        //TODO implement any other checks for the loan to be approved
        // require(block.timestamp <= loan.requestedTime + 31 days, "This loan application has expired.");//FIXME

        require(poolLiquidity >= loan.amount, "BankFair: Pool liquidity is insufficient to approve this loan.");
        require(poolCanLend(), "BankFair: Stake amount is too low to approve new loans.");

        loanDetails[_loanId] = LoanDetail({
            loanId: _loanId,
            totalAmountRepaid: 0,
            baseAmountRepaid: 0,
            interestPaid: 0,
            approvedTime: block.timestamp,
            lastPaymentTime: 0
        });

        loan.status = LoanStatus.APPROVED;
        hasOpenApplication[loan.borrower] = false;

        increaseLoanFunds(loan.borrower, loan.amount);
        poolLiquidity = poolLiquidity.sub(loan.amount);
        borrowedFunds = borrowedFunds.add(loan.amount);

        emit LoanApproved(_loanId);
    }

    /**
     * @notice Deny a loan.
     * @dev Loan must be in APPLIED status.
     *      Caller must be the manager.
     */
    function denyLoan(uint256 loanId) external onlyManager loanInStatus(loanId, LoanStatus.APPLIED) {
        Loan storage loan = loans[loanId];
        loan.status = LoanStatus.DENIED;
        hasOpenApplication[loan.borrower] = false;

        emit LoanDenied(loanId);
    }

     /**
     * @notice Cancel a loan.
     * @dev Loan must be in APPROVED status.
     *      Caller must be the manager.
     */
    function cancelLoan(uint256 loanId) external onlyManager loanInStatus(loanId, LoanStatus.APPROVED) {
        Loan storage loan = loans[loanId];

        // require(block.timestamp > loanDetail.approvedTime + loan.duration + 31 days, "It is too early to cancel this loan."); //FIXME

        loan.status = LoanStatus.CANCELLED;
        decreaseLoanFunds(loan.borrower, loan.amount);
        poolLiquidity = poolLiquidity.add(loan.amount);
        borrowedFunds = borrowedFunds.sub(loan.amount);
        
        emit LoanCancelled(loanId);
    }

    /**
     * @notice Make a payment towards a loan.
     * @dev Caller must be the borrower.
     *      Loan must be in FUNDS_WITHDRAWN status.
     *      Only the necessary sum is charged if amount exceeds amount due.
     *      Amount charged will not exceed the amount parameter. 
     * @param loanId ID of the loan to make a payment towards.
     * @param amount Payment amount in tokens.
     * @return A pair of total amount changed including interest, and the interest charged.
     */
    function repay(uint256 loanId, uint256 amount) external loanInStatus(loanId, LoanStatus.FUNDS_WITHDRAWN) returns (uint256, uint256) {
        Loan storage loan = loans[loanId];

        // require the payer and the borrower to be the same to avoid mispayment
        require(loan.borrower == msg.sender, "Payer is not the borrower.");

        //TODO enforce a small minimum payment amount, except for the last payment 

        (uint256 amountDue, uint256 interestPercent) = loanBalanceDueWithInterest(loanId);
        uint256 transferAmount = Math.min(amountDue, amount);

        chargeTokensFrom(msg.sender, transferAmount);

        if (transferAmount == amountDue) {
            loan.status = LoanStatus.REPAID;
        }

        LoanDetail storage loanDetail = loanDetails[loanId];
        loanDetail.lastPaymentTime = block.timestamp;
        
        uint256 interestPaid = multiplyByFraction(transferAmount, interestPercent, ONE_HUNDRED_PERCENT + interestPercent);
        uint256 baseAmountPaid = transferAmount.sub(interestPaid);

        //share profits to protocol
        uint256 protocolEarnedInterest = multiplyByFraction(interestPaid, protocolEarningPercent, ONE_HUNDRED_PERCENT);
        
        protocolEarnings[protocolWallet] = protocolEarnings[protocolWallet].add(protocolEarnedInterest); 

        //share profits to manager 
        //TODO optimize manager earnings calculation

        uint256 currentStakePercent = multiplyByFraction(stakedShares, ONE_HUNDRED_PERCENT, totalPoolShares);
        uint256 managerEarningsPercent = multiplyByFraction(currentStakePercent, managerExcessLeverageComponent, ONE_HUNDRED_PERCENT);
        uint256 managerEarnedInterest = multiplyByFraction(interestPaid.sub(protocolEarnedInterest), managerEarningsPercent, ONE_HUNDRED_PERCENT);

        protocolEarnings[manager] = protocolEarnings[manager].add(managerEarnedInterest);

        loanDetail.totalAmountRepaid = loanDetail.totalAmountRepaid.add(transferAmount);
        loanDetail.baseAmountRepaid = loanDetail.baseAmountRepaid.add(baseAmountPaid);
        loanDetail.interestPaid = loanDetail.interestPaid.add(interestPaid);

        borrowedFunds = borrowedFunds.sub(baseAmountPaid);
        poolLiquidity = poolLiquidity.add(transferAmount.sub(protocolEarnedInterest.add(managerEarnedInterest)));

        return (transferAmount, interestPaid);
    }

    /**
     * @notice Default a loan.
     * @dev Loan must be in FUNDS_WITHDRAWN status.
     *      Caller must be the manager.
     */
    function defaultLoan(uint256 loanId) external onlyManager loanInStatus(loanId, LoanStatus.FUNDS_WITHDRAWN) {
        Loan storage loan = loans[loanId];
        LoanDetail storage loanDetail = loanDetails[loanId];

        //TODO implement any other checks for the loan to be defaulted
        // require(block.timestamp > loanDetail.approvedTime + loan.duration + 31 days, "It is too early to default this loan."); //FIXME

        loan.status = LoanStatus.DEFAULTED;

        (, uint256 loss) = loan.amount.trySub(loanDetail.totalAmountRepaid); //FIXME is this logic correct
        
        emit LoanDefaulted(loanId, loss);

        if (loss > 0) {
            deductLosses(loss);
        }

        if (loanDetail.baseAmountRepaid < loan.amount) {
            borrowedFunds = borrowedFunds.sub(loan.amount.sub(loanDetail.baseAmountRepaid));
        }
    }

    /**
     * @notice Loan balance due including interest if paid in full at this time. 
     * @dev Loan must be in FUNDS_WITHDRAWN status.
     * @param loanId ID of the loan to check the balance of.
     * @return Total amount due with interest on this loan.
     */
    function loanBalanceDue(uint256 loanId) external view loanInStatus(loanId, LoanStatus.FUNDS_WITHDRAWN) returns(uint256) {
        (uint256 amountDue,) = loanBalanceDueWithInterest(loanId);
        return amountDue;
    }

    /**
     * @notice Loan balance due including interest if paid in full at this time. 
     * @dev Internal method to get the amount due and the interest rate applied.
     * @param loanId ID of the loan to check the balance of.
     * @return A pair of a total amount due with interest on this loan, and a percentage representing the interest part of the due amount.
     */
    function loanBalanceDueWithInterest(uint256 loanId) internal view returns (uint256, uint256) {
        Loan storage loan = loans[loanId];
        if (loan.status == LoanStatus.REPAID) {
            return (0, 0);
        }

        LoanDetail storage loanDetail = loanDetails[loanId];
        uint256 interestPercent = calculateInterestPercent(loan, loanDetail);
        uint256 baseAmountDue = loan.amount.sub(loanDetail.baseAmountRepaid);
        uint256 balanceDue = baseAmountDue.add(multiplyByFraction(baseAmountDue, interestPercent, ONE_HUNDRED_PERCENT));

        return (balanceDue, interestPercent);
    }
    
    /**
     * @notice Get the percentage to calculate the interest due at this time.
     * @dev Internal helper method.
     * @param loan Reference to the loan in question.
     * @param loanDetail Reference to the loanDetail in question.
     * @return Percentage value to calculate the interest due.
     */
    function calculateInterestPercent(Loan storage loan, LoanDetail storage loanDetail) private view returns (uint256) {
        uint256 daysPassed = countInterestDays(loanDetail.approvedTime, block.timestamp);
        
        uint256 apr;
        uint256 loanDueTime = loanDetail.approvedTime.add(loan.duration);
        if (block.timestamp <= loanDueTime) { 
            apr = loan.apr;
        } else {
            uint256 lateDays = countInterestDays(loanDueTime, block.timestamp);
            apr = daysPassed
                .mul(loan.apr)
                .add(lateDays.mul(loan.lateAPRDelta))
                .div(daysPassed);
        }

        return multiplyByFraction(apr, daysPassed, 365);
    }

    /**
     * @notice Get the number of days in a time period to witch an interest can be applied.
     * @dev Internal helper method. Returns the ceiling of the count. 
     * @param timeFrom Epoch timestamp of the start of the time period.
     * @param timeTo Epoch timestamp of the end of the time period. 
     * @return Ceil count of days in a time period to witch an interest can be applied.
     */
    function countInterestDays(uint256 timeFrom, uint256 timeTo) private pure returns(uint256) {
        uint256 countSeconds = timeTo.sub(timeFrom);
        uint256 dayCount = countSeconds.div(86400);

        if (countSeconds.mod(86400) > 0) {
            dayCount++;
        }

        return dayCount;
    }

    //TODO consider security implications of having the following internal function
    /**
     * @dev Internal method to allocate funds to borrow upon loan approval
     * @param wallet Address to allocate funds to.
     * @param amount Token amount to allocate.
     */
    function increaseLoanFunds(address wallet, uint256 amount) private {
        loanFunds[wallet] = loanFunds[wallet].add(amount);
        loanFundsPendingWithdrawal = loanFundsPendingWithdrawal.add(amount);
    }

    //TODO consider security implications of having the following internal function
    /**
     * @dev Internal method to deallocate funds to borrow upon borrow()
     * @param wallet Address to deallocate the funds of.
     * @param amount Token amount to deallocate.
     */
    function decreaseLoanFunds(address wallet, uint256 amount) internal {
        require(loanFunds[wallet] >= amount, "BankFair: requested amount is not available in the funding account");
        loanFunds[wallet] = loanFunds[wallet].sub(amount);
        loanFundsPendingWithdrawal = loanFundsPendingWithdrawal.sub(amount);
    }

    //TODO consider security implications of having the following internal function
    /**
     * @dev Internal method to handle loss on a default.
     * @param lossAmount Unpaid base amount of a defaulted loan.
     */
    function deductLosses(uint256 lossAmount) internal {

        poolFunds = poolFunds.sub(lossAmount);

        uint256 lostShares = tokensToShares(lossAmount);
        uint256 remainingLostShares = lostShares;

        if (stakedShares > 0) {
            uint256 stakedShareLoss = Math.min(lostShares, stakedShares);
            remainingLostShares = lostShares.sub(stakedShareLoss);
            stakedShares = stakedShares.sub(stakedShareLoss);
            updatePoolLimit();

            burnShares(manager, stakedShareLoss);

            if (stakedShares == 0) {
                emit StakedAssetsDepleted();
            }
        }

        if (remainingLostShares > 0) {
            emit UnstakedLoss(lossAmount.sub(sharesToTokens(remainingLostShares)));
        }
    }
}