//SPDX-License-Identifier: MIT
// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {clUSDC} from "./clUSDC.sol";

/**
 * @title LendingPool
 * @author LienFi Team
 *
 * Shared USDC lending pool powering the LienFi mortgage system.
 *
 * Properties:
 * - Lenders deposit USDC and receive clUSDC at the current exchange rate
 * - clUSDC represents a proportional share of total pool USDC
 * - Exchange rate = (pool USDC balance * 1e18) / clUSDC total supply
 * - As EMI payments flow in, pool USDC grows → exchange rate rises → lenders earn yield passively
 * - No per-lender yield tracking — yield is implicit in the rising exchange rate
 * - Same model as Compound cTokens / Aave aTokens
 *
 * Access control:
 * - deposit / withdraw: open to any address (lenders)
 * - disburse / repayEMI: restricted to LoanManager only
 *
 * @notice Exchange rate uses 1e18 precision multiplier to prevent rounding errors.
 * @notice Withdrawals are blocked if insufficient liquidity (USDC lent out).
 */
contract LendingPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ///////////////////
    // Errors
    ///////////////////
    error LendingPool__ZeroAmount();
    error LendingPool__ZeroAddress();
    error LendingPool__NotLoanManager();
    error LendingPool__InsufficientLiquidity();
    error LendingPool__InsufficientBalance();
    error LendingPool__LoanManagerAlreadySet();

    ///////////////////
    // Constants
    ///////////////////

    /**
     * @notice Precision multiplier for exchange rate calculations.
     * @dev Exchange rate is stored as a 1e18-scaled value to avoid truncation
     *      when dividing small USDC amounts (6 decimals) by clUSDC supply (6 decimals).
     *      Example: 1_000_000 USDC (1 USDC) / 1_000_000 clUSDC = 1e18 (1:1 rate)
     */
    uint256 public constant EXCHANGE_RATE_PRECISION = 1e18;

    /**
     * @notice Initial exchange rate: 1 USDC = 1 clUSDC (scaled by 1e18).
     * @dev Used only for the very first deposit when clUSDC supply is zero.
     */
    uint256 public constant INITIAL_EXCHANGE_RATE = 1e18;

    ///////////////////
    // State Variables
    ///////////////////
    IERC20 public immutable usdc;
    clUSDC public immutable receiptToken;
    address public loanManager; // only LoanManager can call disburse and repayEMI

    /**
     * @notice Total USDC principal currently outstanding as active loans.
     * @dev Incremented on disburse(), decremented on repayEMI() by the principal portion.
     *      This is an accounting variable only — it does NOT affect the USDC balance.
     *      The actual USDC leaves the contract on disburse and re-enters on repayEMI.
     *      Used to track protocol health and total exposure.
     */
    uint256 public totalLoaned;

    ///////////////////
    // Events
    ///////////////////
    event Deposited(
        address indexed lender,
        uint256 usdcAmount,
        uint256 clUsdcMinted
    );
    event Withdrawn(
        address indexed lender,
        uint256 clUsdcBurned,
        uint256 usdcReturned
    );
    event LoanDisbursed(address indexed borrower, uint256 amount);
    event EMIRepaid(uint256 emiAmount, uint256 principalPortion);
    event LoanManagerSet(address indexed loanManager);

    ///////////////////
    // Modifiers
    ///////////////////
    modifier onlyLoanManager() {
        if (msg.sender != loanManager) revert LendingPool__NotLoanManager();
        _;
    }

    modifier nonZeroAmount(uint256 amount) {
        if (amount == 0) revert LendingPool__ZeroAmount();
        _;
    }

    ///////////////////
    // Constructor
    ///////////////////

    /**
     * @param _usdc Address of the USDC token contract
     * @param _receiptToken Address of the clUSDC receipt token contract
     */
    constructor(address _usdc, address _receiptToken) Ownable(msg.sender) {
        if (_usdc == address(0) || _receiptToken == address(0))
            revert LendingPool__ZeroAddress();
        usdc = IERC20(_usdc);
        receiptToken = clUSDC(_receiptToken);
    }

    ///////////////////
    // External Functions — Lender-Facing
    ///////////////////

    /**
     * @notice Deposit USDC into the lending pool and receive clUSDC.
     * @dev Mints clUSDC at the current exchange rate.
     *      First depositor gets 1:1 rate (INITIAL_EXCHANGE_RATE).
     *      Subsequent depositors get: clUsdcToMint = (usdcAmount * 1e18) / exchangeRate()
     *
     *      Example (after pool has grown):
     *        Pool has 1100 USDC, 1000 clUSDC outstanding
     *        exchangeRate = (1100e6 * 1e18) / 1000e6 = 1.1e18
     *        Depositing 110 USDC → (110e6 * 1e18) / 1.1e18 = 100e6 clUSDC
     *        Lender gets 100 clUSDC for 110 USDC (each clUSDC is worth 1.1 USDC)
     *
     * @param amount The amount of USDC to deposit (6 decimals)
     */
    function deposit(
        uint256 amount
    ) external nonReentrant nonZeroAmount(amount) {
        uint256 rate = exchangeRate();
        uint256 clUsdcToMint = (amount * EXCHANGE_RATE_PRECISION) / rate;

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        receiptToken.mint(msg.sender, clUsdcToMint);

        emit Deposited(msg.sender, amount, clUsdcToMint);
    }

    /**
     * @notice Withdraw USDC from the lending pool by burning clUSDC.
     * @dev Burns clUSDC and returns USDC at the current exchange rate.
     *      usdcToReturn = (clUsdcAmount * exchangeRate()) / 1e18
     *
     *      Reverts if the pool doesn't have enough liquid USDC (i.e., most USDC
     *      is currently lent out). Lenders must wait for EMI repayments or
     *      other lenders to deposit before they can withdraw.
     *
     *      Example:
     *        Pool has 1100 USDC, 1000 clUSDC outstanding
     *        exchangeRate = 1.1e18
     *        Burning 100 clUSDC → (100e6 * 1.1e18) / 1e18 = 110e6 USDC
     *
     * @param clUsdcAmount The amount of clUSDC to burn (6 decimals)
     */
    function withdraw(
        uint256 clUsdcAmount
    ) external nonReentrant nonZeroAmount(clUsdcAmount) {
        if (receiptToken.balanceOf(msg.sender) < clUsdcAmount) {
            revert LendingPool__InsufficientBalance();
        }

        uint256 rate = exchangeRate();
        uint256 usdcToReturn = (clUsdcAmount * rate) / EXCHANGE_RATE_PRECISION;

        if (usdcToReturn > availableLiquidity()) {
            revert LendingPool__InsufficientLiquidity();
        }

        receiptToken.burn(msg.sender, clUsdcAmount);
        usdc.safeTransfer(msg.sender, usdcToReturn);

        emit Withdrawn(msg.sender, clUsdcAmount, usdcToReturn);
    }

    ///////////////////
    // External Functions — LoanManager Only
    ///////////////////

    /**
     * @notice Disburse USDC to a borrower for an approved loan. LoanManager only.
     * @dev Transfers USDC out of the pool to the borrower's wallet.
     *      Increments totalLoaned for protocol accounting.
     *      Reverts if insufficient liquidity in the pool.
     *
     * @param borrower The borrower's wallet address
     * @param amount The USDC amount to disburse (6 decimals)
     */
    function disburse(
        address borrower,
        uint256 amount
    ) external onlyLoanManager nonReentrant nonZeroAmount(amount) {
        if (borrower == address(0)) revert LendingPool__ZeroAddress();
        if (amount > availableLiquidity())
            revert LendingPool__InsufficientLiquidity();

        totalLoaned += amount;
        usdc.safeTransfer(borrower, amount);

        emit LoanDisbursed(borrower, amount);
    }

    /**
     * @notice Accept an EMI repayment into the pool. LoanManager only.
     * @dev The full EMI amount (principal + interest) stays in the pool.
     *      The interest portion is what causes clUSDC exchange rate to rise.
     *      totalLoaned is reduced by the principal portion only (accounting).
     *
     *      Example:
     *        EMI = 1000 USDC, principal portion = 800 USDC, interest = 200 USDC
     *        → 1000 USDC enters pool (full EMI)
     *        → totalLoaned decreases by 800 (principal tracked)
     *        → The 200 USDC interest makes pool balance > what was originally deposited
     *        → clUSDC exchange rate rises → lenders earn yield
     *
     * @param emiAmount The full EMI amount in USDC (6 decimals)
     * @param principalPortion The principal portion of this EMI (6 decimals)
     */
    function repayEMI(
        uint256 emiAmount,
        uint256 principalPortion
    ) external onlyLoanManager nonReentrant nonZeroAmount(emiAmount) {
        // Principal portion cannot exceed EMI or outstanding loans
        // LoanManager is trusted to compute this correctly, but we sanity-check
        assert(principalPortion <= emiAmount);
        assert(principalPortion <= totalLoaned);

        totalLoaned -= principalPortion;

        // LoanManager transfers USDC to this contract before calling repayEMI
        // (or: LoanManager calls transferFrom on borrower to pool directly)
        // The USDC is already in the pool by the time this executes.
        // No safeTransferFrom here — LoanManager handles the transfer.

        emit EMIRepaid(emiAmount, principalPortion);
    }

    ///////////////////
    // View Functions
    ///////////////////

    /**
     * @notice Current exchange rate: how much USDC one clUSDC is worth.
     * @dev Returns INITIAL_EXCHANGE_RATE (1e18) when no clUSDC exists yet.
     *      Otherwise: (pool USDC balance * 1e18) / clUSDC total supply
     *
     *      The "pool USDC balance" includes:
     *        - Original deposits from lenders
     *        - EMI payments that have flowed back in
     *        - Minus any USDC currently disbursed as loans (already left the balance)
     *
     *      Since disbursed USDC physically leaves the contract, balanceOf already
     *      reflects only the USDC actually present. No subtraction needed.
     *
     * @return rate The exchange rate scaled by 1e18
     */
    function exchangeRate() public view returns (uint256) {
        uint256 totalSupply = receiptToken.totalSupply();
        if (totalSupply == 0) {
            return INITIAL_EXCHANGE_RATE;
        }
        // totalPoolUSDC = USDC physically present in this contract
        uint256 totalPoolUSDC = usdc.balanceOf(address(this));
        return (totalPoolUSDC * EXCHANGE_RATE_PRECISION) / totalSupply;
    }

    /**
     * @notice Available USDC liquidity that can be withdrawn or disbursed.
     * @dev Simply the USDC balance of this contract.
     *      Disbursed loan USDC has already left the contract.
     *      This represents USDC available for new loans or lender withdrawals.
     *
     * @return The available USDC amount (6 decimals)
     */
    function availableLiquidity() public view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /**
     * @notice Total value of all USDC managed by the pool (liquid + loaned out).
     * @dev Used for protocol dashboards and health monitoring.
     *      totalPoolValue = USDC in contract + USDC out on loan
     *
     * @return The total USDC value (6 decimals)
     */
    function totalPoolValue() external view returns (uint256) {
        return usdc.balanceOf(address(this)) + totalLoaned;
    }

    ///////////////////
    // Admin Functions
    ///////////////////

    /**
     * @notice Set the LoanManager address. Owner only. Can only be set once.
     * @dev Called post-deploy during wiring phase.
     *      Single-set to prevent accidental or malicious re-pointing.
     *
     * @param _loanManager The LoanManager contract address
     */
    function setLoanManager(address _loanManager) external onlyOwner {
        if (_loanManager == address(0)) revert LendingPool__ZeroAddress();
        if (loanManager != address(0))
            revert LendingPool__LoanManagerAlreadySet();
        loanManager = _loanManager;
        emit LoanManagerSet(_loanManager);
    }
}
