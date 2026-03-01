//SPDX-License-Identifier:MIT

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
 * @title LienFiRWAToken
 * @author LienFi Team
 *
 * A minimal ERC-20 token template representing fractional ownership of a real estate property.
 * One instance is deployed per property via LienFiAuction.createPropertyToken().
 *
 * Properties:
 * - Restricted minting: only the designated minter (LienFiAuction contract) can mint
 * - Minting is triggered via the CRE mint workflow after off-chain property verification
 * - Name and symbol are set at construction time (e.g. "123 Main St Share" / "MAIN123")
 * - 18 decimals, standard ERC-20 otherwise
 * - Owner can update the minter address for deployment flexibility
 *
 * @notice Deployed by LienFiAuction.createPropertyToken(). The auction contract is
 * set as the minter at construction time and retains exclusive mint rights.
 */
contract LienFiRWAToken is ERC20, Ownable {
    address public minter;
    error LienFiRWAToken__NeedsNonZeroAddress();
    error LienFiRWAToken__MinterNotAuthorized();

    event MinterUpdated(address indexed oldMinter, address indexed newMinter);

    constructor(
        string memory name,
        string memory symbol,
        address _minter
    ) ERC20(name, symbol) Ownable(msg.sender) {
        minter = _minter;
    }

    function setMinter(address _minter) external onlyOwner {
        if (_minter == address(0)) {
            revert LienFiRWAToken__NeedsNonZeroAddress();
        }
        emit MinterUpdated(minter, _minter);
        minter = _minter;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) {
            revert LienFiRWAToken__MinterNotAuthorized();
        }
        _mint(to, amount);
    }
}
