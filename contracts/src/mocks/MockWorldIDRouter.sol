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

contract MockWorldIDRouter{
    function verifyProof(
        uint256,  // root
        uint256,  // groupId
        uint256,  // signalHash
        uint256,  // nullifierHash
        uint256,  // externalNullifierHash
        uint256[8] calldata  // proof
    ) external pure {}
}