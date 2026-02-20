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

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWorldID} from "./interfaces/IWorldID.sol";
import {ISealBidRWAToken} from "./interfaces/ISealBidRWAToken.sol";
import {ByteHasher} from "./libraries/ByteHasher.sol";

/**
 * @title SealBidAuction
 * @author SealBid Team
 *
 * Core contract for the SealBid sealed-bid auction system, combining a multi-token
 * deposit pool with World ID sybil resistance and a privacy-preserving auction lifecycle.
 *
 * Properties:
 * - Multi-token deposit pool: supports SRWA (18 decimals) and USDC (6 decimals),
 *   extensible to additional tokens via owner. Pool is auction-blind — deposits
 *   carry no auction reference, so observers cannot link deposits to specific auctions.
 * - World ID integration: real on-chain ZK proof verification via Router. Both RWA
 *   minting and pool deposits require World ID — one human, one action (sybil resistance).
 *   Two separate actions: "mint_rwa" and "deposit_to_pool".
 * - RWA token minting: forwarder-only, World ID gated. Users with existing USDC skip this.
 * - Auction lifecycle: forwarder-only bid registration and settlement. Only opaque bid
 *   hashes stored on-chain during auction. Settlement reveals only winner + Vickrey price.
 * - Privacy: bid amounts, bidder identities, and losing bids are never exposed on-chain.
 *   Multi-token support adds obfuscation — observers can't tell which token type maps
 *   to which auction.
 *
 * @notice Forwarder-gated functions (mintRWATokens, registerBid, settleAuction) are
 * called exclusively via Chainlink CRE workflows operating inside a secure enclave.
 */
contract SealBidAuction is Ownable, ReentrancyGuard {
    using ByteHasher for bytes;

    ///////////////////
    // Errors
    ///////////////////
    error SealBidAuction__InvalidNullifier();
    error SealBidAuction__NotForwarder();
    error SealBidAuction__TokenNotAccepted();
    error SealBidAuction__FixedAmountOnly();
    error SealBidAuction__LockMustBeInFuture();
    error SealBidAuction__TransferFailed();
    error SealBidAuction__FundsLocked();
    error SealBidAuction__InsufficientBalance();
    error SealBidAuction__AuctionNotFound();
    error SealBidAuction__AuctionAlreadyExists();
    error SealBidAuction__DeadlineMustBeFuture();
    error SealBidAuction__AuctionExpired();
    error SealBidAuction__AuctionNotExpired();
    error SealBidAuction__AuctionAlreadySettled();
    error SealBidAuction__WinnerUnderfunded();
    error SealBidAuction__CanOnlyExtendLock();

    ///////////////////
    // Type Declarations
    ///////////////////
    struct Auction {
        address seller;
        address token;
        uint256 deadline;
        uint256 reservePrice;
        bool settled;
        address winner;
        uint256 settledPrice;
    }

    ///////////////////
    // State Variables
    ///////////////////
    IWorldID public immutable i_worldId;
    uint256 public immutable i_groupId = 1;
    uint256 public immutable i_mintExternalNullifierHash;
    uint256 public immutable i_depositExternalNullifierHash;
    mapping(uint256 => bool) public nullifierHashes;

    // Multi-Token Support
    address public rwaToken;
    mapping(address => bool) public acceptedTokens;
    mapping(address => uint256) public escrowAmount;

    // Deposit Pool
    mapping(address => mapping(address => uint256)) public poolBalance;
    mapping(address => uint256) public lockExpiry;

    // Auction Lifecycle
    address public forwarder;
    mapping(bytes32 => Auction) public auctions;
    mapping(bytes32 => bytes32[]) public bidHashes;

    ///////////////////
    // Events
    ///////////////////
    event TokenAccepted(address indexed token, uint256 escrowAmount);
    event RWATokensMinted(address indexed to, uint256 amount);
    event PoolDeposit(
        address indexed depositor,
        address indexed token,
        uint256 amount,
        uint256 lockUntil
    );
    event LockExtended(address indexed depositor, uint256 newExpiry);
    event PoolWithdrawal(
        address indexed depositor,
        address indexed token,
        uint256 amount
    );
    event AuctionCreated(
        bytes32 indexed auctionId,
        address seller,
        address indexed token,
        uint256 deadline,
        uint256 reservePrice
    );
    event BidRegistered(bytes32 indexed auctionId, bytes32 bidHash);
    event AuctionSettled(
        bytes32 indexed auctionId,
        address winner,
        uint256 price
    );
    event ForwarderUpdated(
        address indexed oldForwarder,
        address indexed newForwarder
    );

    ///////////////////
    // Modifiers
    ///////////////////
    modifier onlyForwarder() {
        if (msg.sender != forwarder) {
            revert SealBidAuction__NotForwarder();
        }
        _;
    }

    ///////////////////
    // Functions
    ///////////////////
    constructor(
        address _forwarder,
        address _rwaToken,
        address _usdc,
        IWorldID _worldId,
        string memory _appId,
        string memory _mintAction,
        string memory _depositAction
    ) Ownable(msg.sender) {
        forwarder = _forwarder;
        rwaToken = _rwaToken;
        i_worldId = _worldId;

        i_mintExternalNullifierHash = abi
            .encodePacked(abi.encodePacked(_appId).hashToField(), _mintAction)
            .hashToField();
        i_depositExternalNullifierHash = abi
            .encodePacked(
                abi.encodePacked(_appId).hashToField(),
                _depositAction
            )
            .hashToField();

        // SRWA: 18 decimals, 100 tokens escrow
        acceptedTokens[_rwaToken] = true;
        escrowAmount[_rwaToken] = 100e18;

        // USDC: 6 decimals, 100 USDC escrow
        acceptedTokens[_usdc] = true;
        escrowAmount[_usdc] = 100e6;
    }

    ///////////////////
    // External Functions
    ///////////////////
    function setForwarder(address _forwarder) external onlyOwner {
        emit ForwarderUpdated(forwarder, _forwarder);
        forwarder = _forwarder;
    }

    function addAcceptedToken(
        address token,
        uint256 _escrowAmount
    ) external onlyOwner {
        acceptedTokens[token] = true;
        escrowAmount[token] = _escrowAmount;
        emit TokenAccepted(token, _escrowAmount);
    }

    function mintRWATokens(
        address to,
        uint256 amount,
        uint256 root,
        uint256 nullifierHash,
        uint256[8] calldata proof
    ) external onlyForwarder {
        if (nullifierHashes[nullifierHash]) {
            revert SealBidAuction__InvalidNullifier();
        }

        i_worldId.verifyProof(
            root,
            i_groupId,
            abi.encodePacked(to).hashToField(),
            nullifierHash,
            i_mintExternalNullifierHash,
            proof
        );

        nullifierHashes[nullifierHash] = true;
        ISealBidRWAToken(rwaToken).mint(to, amount);
        emit RWATokensMinted(to, amount);
    }

    function depositToPool(
        address token,
        uint256 lockUntil,
        uint256 amount,
        uint256 root,
        uint256 nullifierHash,
        uint256[8] calldata proof
    ) external {
        if (!acceptedTokens[token]) {
            revert SealBidAuction__TokenNotAccepted();
        }
        if (amount != escrowAmount[token]) {
            revert SealBidAuction__FixedAmountOnly();
        }
        if (lockUntil <= block.timestamp) {
            revert SealBidAuction__LockMustBeInFuture();
        }
        if (nullifierHashes[nullifierHash]) {
            revert SealBidAuction__InvalidNullifier();
        }

        i_worldId.verifyProof(
            root,
            i_groupId,
            abi.encodePacked(msg.sender).hashToField(),
            nullifierHash,
            i_depositExternalNullifierHash,
            proof
        );

        nullifierHashes[nullifierHash] = true;

        if (!IERC20(token).transferFrom(msg.sender, address(this), amount)) {
            revert SealBidAuction__TransferFailed();
        }

        poolBalance[msg.sender][token] += amount;

        if (lockUntil > lockExpiry[msg.sender]) {
            lockExpiry[msg.sender] = lockUntil;
        }

        emit PoolDeposit(msg.sender, token, amount, lockUntil);
    }

    function extendLock(uint256 newExpiry) external {
        if (newExpiry <= lockExpiry[msg.sender]) {
            revert SealBidAuction__CanOnlyExtendLock();
        }
        lockExpiry[msg.sender] = newExpiry;
        emit LockExtended(msg.sender, newExpiry);
    }

    function withdrawFromPool(
        address token,
        uint256 amount
    ) external nonReentrant {
        if (block.timestamp < lockExpiry[msg.sender]) {
            revert SealBidAuction__FundsLocked();
        }
        if (poolBalance[msg.sender][token] < amount) {
            revert SealBidAuction__InsufficientBalance();
        }

        poolBalance[msg.sender][token] -= amount;

        if (!IERC20(token).transfer(msg.sender, amount)) {
            revert SealBidAuction__TransferFailed();
        }

        emit PoolWithdrawal(msg.sender, token, amount);
    }

    function createAuction(
        bytes32 auctionId,
        address token,
        uint256 deadline,
        uint256 reservePrice
    ) external {
        if (auctions[auctionId].deadline != 0) {
            revert SealBidAuction__AuctionAlreadyExists();
        }
        if (deadline <= block.timestamp) {
            revert SealBidAuction__DeadlineMustBeFuture();
        }
        if (!acceptedTokens[token]) {
            revert SealBidAuction__TokenNotAccepted();
        }

        auctions[auctionId] = Auction({
            seller: msg.sender,
            token: token,
            deadline: deadline,
            reservePrice: reservePrice,
            settled: false,
            winner: address(0),
            settledPrice: 0
        });

        emit AuctionCreated(
            auctionId,
            msg.sender,
            token,
            deadline,
            reservePrice
        );
    }

    function registerBid(
        bytes32 auctionId,
        bytes32 bidHash
    ) external onlyForwarder {
        Auction storage a = auctions[auctionId];
        if (a.deadline == 0) {
            revert SealBidAuction__AuctionNotFound();
        }
        if (block.timestamp >= a.deadline) {
            revert SealBidAuction__AuctionExpired();
        }
        if (a.settled) {
            revert SealBidAuction__AuctionAlreadySettled();
        }

        bidHashes[auctionId].push(bidHash);
        emit BidRegistered(auctionId, bidHash);
    }

    function settleAuction(
        bytes32 auctionId,
        address winner,
        uint256 price,
        bytes32 proof
    ) external onlyForwarder {
        Auction storage a = auctions[auctionId];
        if (a.deadline == 0) {
            revert SealBidAuction__AuctionNotFound();
        }
        if (block.timestamp < a.deadline) {
            revert SealBidAuction__AuctionNotExpired();
        }
        if (a.settled) {
            revert SealBidAuction__AuctionAlreadySettled();
        }
        if (poolBalance[winner][a.token] < price) {
            revert SealBidAuction__WinnerUnderfunded();
        }

        a.settled = true;
        a.winner = winner;
        a.settledPrice = price;

        poolBalance[winner][a.token] -= price;

        if (!IERC20(a.token).transfer(a.seller, price)) {
            revert SealBidAuction__TransferFailed();
        }

        emit AuctionSettled(auctionId, winner, price);
    }

    ///////////////////
    // View & Pure Functions
    ///////////////////
    function canBid(
        address bidder,
        bytes32 auctionId
    ) external view returns (bool) {
        Auction storage a = auctions[auctionId];
        if (a.deadline == 0) {
            return false;
        }
        return
            poolBalance[bidder][a.token] >= escrowAmount[a.token] &&
            lockExpiry[bidder] >= a.deadline;
    }

    function getBidCount(bytes32 auctionId) external view returns (uint256) {
        return bidHashes[auctionId].length;
    }
}
