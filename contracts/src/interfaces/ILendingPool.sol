// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILendingPool {
    function deposit(uint256 amount) external;
    function withdraw(uint256 clUsdcAmount) external;
    function disburse(address borrower, uint256 amount) external;
    function repayEMI(uint256 emiAmount, uint256 principalPortion) external;

    function exchangeRate() external view returns (uint256);
    function availableLiquidity() external view returns (uint256);
    function totalPoolValue() external view returns (uint256);
    function setLoanManager(address _loanManager) external;
}