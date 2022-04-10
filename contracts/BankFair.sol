pragma solidity ^0.8.12;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./Lender.sol";

contract BankFair is Lender {

    using SafeMath for uint256;

    event UnstakedLoss(uint256 amount);
    event StakedAssetsDepleted();

    modifier validLender(address wallet) {
        require(wallet != address(0), "BankFair: Address is not prsent.");
        require(wallet != manager && wallet != protocolWallet, "BankFair: Wallet is a manager or protocol.");
        //FIXME: currently borrower is a wallet that has any past or present loans/application,
        //TODO wallet is a borrower if: has open loan or loan application. Implement basic loan history first.
        require(recentLoanIdOf[wallet] == 0, "BankFair: Wallet is a borrower."); 
        _;
    }
    
    constructor(address tokenAddress, address protocol, uint256 minLoanAmount) Lender(tokenAddress, protocol, minLoanAmount) {
        poolFunds = 0;
    }

    function deposit(uint256 amount) external validLender(msg.sender) {
        enterPool(amount);
    }

    function enterPool(uint256 amount) private returns (uint256) {
        require(amount > 0, "BankFair: pool deposit amount is 0");

        uint256 shares = tokensToShares(amount);

        chargeTokensFrom(msg.sender, amount);
        poolLiqudity = poolLiqudity.add(amount);
        poolFunds = poolFunds.add(amount);

        mintShares(msg.sender, shares);

        return shares;
    }

    function withdraw(uint256 amount) external validLender(msg.sender) {
        exitPool(amount);
    }

    function exitPool(uint256 amount) private returns (uint256) {
        require(amount > 0, "BankFair: pool withdrawal amount is 0");
        require(poolLiqudity >= amount, "BankFair: pool liquidity is too low");

        uint256 shares = tokensToShares(amount); 
        //TODO handle failed pool case when any amount equates to 0 shares

        burnShares(msg.sender, shares);

        poolFunds = poolFunds.sub(amount);
        poolLiqudity = poolLiqudity.sub(amount);
        giveTokensTo(msg.sender, amount);

        return shares;
    }

    function withdrawLoanFunds(uint256 loanId) external loanInStatus(loanId, LoanStatus.APPROVED) {
        Loan storage loan = loans[loanId];
        loan.status = LoanStatus.FUNDS_WITHDRAWN;
        
        decreaseLoanFunds(msg.sender, loan.amount);
        tokenBalance = tokenBalance.sub(loan.amount);
        giveTokensTo(msg.sender, loan.amount);
    }

    function balanceOf(address wallet) external view returns (uint256) {
        return sharesToTokens(poolShares[wallet]);
    }

    function stake(uint256 amount) external onlyManager {
        require(amount > 0, "BankFair: stake amount is 0");

        uint256 shares = enterPool(amount);
        sharesStaked = sharesStaked.add(shares);
    }
    
    function unstake(uint256 amount) external onlyManager {
        require(amount > 0, "BankFair: unstake amount is 0");
        require(amount <= balanceStakedUnlocked(), "BankFair: requested amount is not available to be unstaked");

        uint256 shares = tokensToShares(amount);
        sharesStaked = sharesStaked.sub(shares);
        exitPool(amount);
    }

    function balanceStakedUnlocked() public view returns (uint256) {
        //staked funds locked up to 1/10 of the currently borrowed amount
        (,uint256 unlocked) = sharesStaked.trySub(tokensToShares(borrowedFunds.div(10))); 
        return sharesToTokens(unlocked);
    }

    function deductLosses(uint256 lossAmount) internal override {

        poolFunds = poolFunds.sub(lossAmount);

        uint256 lostShares = tokensToShares(lossAmount);
        uint256 remainingLostShares = lostShares;

        if (sharesStaked > 0) {
            uint256 stakedShareLoss = Math.min(lostShares, sharesStaked);
            remainingLostShares = lostShares.sub(stakedShareLoss);
            sharesStaked = sharesStaked.sub(stakedShareLoss);

            burnShares(manager, stakedShareLoss);

            if (sharesStaked == 0) {
                emit StakedAssetsDepleted();
            }
        }

        if (remainingLostShares > 0) {
            emit UnstakedLoss(lossAmount.sub(sharesToTokens(remainingLostShares)));
        }
    }

    function mintShares(address wallet, uint256 shares) private {
        poolShares[wallet] = poolShares[wallet].add(shares);
        totalPoolShares = totalPoolShares.add(shares);
    }

    function burnShares(address wallet, uint256 shares) private {
        poolShares[wallet] = poolShares[wallet].sub(shares);
        totalPoolShares = totalPoolShares.sub(shares);
    }
    
    function sharesToTokens(uint256 shares) private view returns (uint256) {
        if (shares == 0 || poolFunds == 0) {
             return 0;
        }

        return multiplyByFraction(shares, poolFunds, totalPoolShares);
    }

    function tokensToShares(uint256 tokens) private view returns (uint256) {
        if (tokens == 0) {
            return 0;
        } else if (totalPoolShares == 0) {
            return tokens;
        }

        return multiplyByFraction(tokens, totalPoolShares, poolFunds);
    }
}
