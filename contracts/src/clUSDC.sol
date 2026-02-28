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

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title clUSDC
 * @author LienFi Team
 *
 * Receipt token representing a proportional share of the LienFi lending pool.
 *
 * Properties:
 * - 6 decimals (matching underlying USDC, Aave-style)
 * - Mint/burn restricted to LendingPool contract only
 * - No rebase — yield is captured via rising exchange rate (pool USDC / clUSDC supply)
 * - Exchange rate starts at 1:1 and appreciates as EMI payments flow into the pool
 * - Owner can update the minter address for deployment flexibility
 *
 * @notice This contract is intentionally minimal. All pool logic lives in LendingPool.
 */
 contract clUSDC is ERC20,Ownable{
      ///////////////////
    // Errors
    ///////////////////
    error clUSDC__NotMinter();
    error clUSDC__ZeroAddress();

    ///////////////////
    // State Variables
    ///////////////////
     address public minter;

     ///////////////////
     // Events
        ///////////////////
        event MinterUpdated(address indexed oldMinter, address indexed newMinter);


    ///////////////////
    // Modifiers
    ////////////////////

    modifier onlyMinter(){
        if(msg.sender !=minter) revert clUSDC__NotMinter();
        _;
    }
    ///////////////////
    // Functions
    ///////////////////
    constructor() ERC20("LienFi Collateral USDC","clUSDC") Ownable(msg.sender) {}

     /**
     * @notice Returns 6 decimals to match underlying USDC (like Aave)
     */
    function decimals() public pure override returns (uint8) {
        return 6;
    }

     /**
     * @notice Mint clUSDC to a lender on deposit. LendingPool only.
     * @param to The lender receiving clUSDC
     * @param amount The amount of clUSDC to mint (6 decimals)
     */
     function mint(address to,uint256 amount) external onlyMinter{
        _mint(to,amount);
     }

    /**
     * @notice Burn clUSDC from a lender on withdrawal. LendingPool only.
     * @param from The lender whose clUSDC is burned
     * @param amount The amount of clUSDC to burn (6 decimals)
     */
        function burn(address from,uint256 amount) external onlyMinter{
            _burn(from,amount);
        }

    /**
     * @notice Update the minter address. Owner only.
     * @dev Called post-deploy to set LendingPool as minter.
     * @param newMinter The new minter address (LendingPool)
     */
     function setMinter(address newMinter) external onlyOwner{
        if(newMinter == address(0)) revert clUSDC__ZeroAddress();
        address oldMinter = minter;
        minter = newMinter;
        emit MinterUpdated(oldMinter,newMinter);
     }
    
 }