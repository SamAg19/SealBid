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
 * @title SealBidRWAToken
 * @author SealBid Team
 *
 * A minimal ERC-20 token representing tokenized Real World Assets (RWA) for use
 * in the SealBid sealed-bid auction system.
 *
 * Properties:
 * - Restricted minting: only the designated minter (SealBidAuction contract) can mint
 * - World ID gated: minting is triggered via CRE Workflow 0, which verifies World ID
 *   on-chain before calling mint — ensuring one human, one mint (sybil resistance)
 * - 18 decimals, standard ERC-20 otherwise
 * - Owner can update the minter address for deployment flexibility
 *
 * Users who already hold USDC skip this token entirely — they deposit USDC directly
 * into the SealBidAuction deposit pool. SRWA exists for users who need compliance-gated
 * capital to participate in RWA auctions.
 *
 * @notice This contract is intentionally minimal. All access control and World ID
 * verification logic lives in SealBidAuction.sol, which calls mint() as a forwarder.
 */
contract SealBidRWAToken is ERC20, Ownable {
    address public minter;
    error SealBidRWAToken__NeedsNonZeroAddress();
    error SealBidRWAToken__MinterNotAuthorized();

    event MinterUpdated(address indexed oldMinter, address indexed newMinter);

    constructor(
        address _minter
    ) ERC20("SealBid RWA Dollar", "SRWA") Ownable(msg.sender) {
        minter = _minter;
    }

    function setMinter(address _minter) external onlyOwner {
        if (_minter == address(0)) {
            revert SealBidRWAToken__NeedsNonZeroAddress();
        }
        emit MinterUpdated(minter, _minter);
        minter = _minter;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) {
            revert SealBidRWAToken__MinterNotAuthorized();
        }
        _mint(to, amount);
    }
}
