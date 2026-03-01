// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILienFiAuction {
    function initiateDefaultAuction(
        uint256 tokenId,
        uint256 reservePrice,
        bytes32 auctionId,
        uint256 deadline
    ) external;
}