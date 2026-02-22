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

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWorldID} from "./interfaces/IWorldID.sol";
import {ISealBidRWAToken} from "./interfaces/ISealBidRWAToken.sol";
import {ByteHasher} from "./libraries/ByteHasher.sol";
import {ReceiverTemplate} from "./ReceiverTemplate.sol";

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
 * - World ID integration: real on-chain ZK proof verification via Router. Pool
 *   deposits require World ID — one human, one deposit (sybil resistance).
 * - RWA token minting: trusted via Chainlink CRE DON consensus + KeystoneForwarder.
 * - Auction lifecycle: CRE-only bid registration and settlement via onReport.
 *   Only opaque bid hashes stored on-chain during auction. Settlement reveals
 *   only winner + Vickrey price.
 * - Privacy: bid amounts, bidder identities, and losing bids are never exposed on-chain.
 *   Multi-token support adds obfuscation — observers can't tell which token type maps
 *   to which auction.
 *
 * @notice CRE workflows deliver signed reports via the KeystoneForwarder, which calls
 * onReport on this contract. Dispatch is based on the workflowName field in the
 * report metadata (set in each workflow's yaml `name` field):
 *   "mint"   → _mintRWATokens
 *   "bid"    → _registerBid
 *   "settle" → _settleAuction
 *
 * Workflow report encodings:
 *   mint:   abi.encode(uint8 instructionType, address account, uint256 amount, bytes32 bankRef)
 *   bid:    abi.encode(bytes32 auctionId, bytes32 bidHash)
 *   settle: abi.encode(bytes32 auctionId, address winner, uint256 price)
 */
contract SealBidAuction is ReceiverTemplate, ReentrancyGuard {
    using ByteHasher for bytes;

    ///////////////////
    // Workflow Name Constants (bytes10)
    // Encoding: SHA256(name) → 64-char hex string → first 10 hex chars → hex-encode those ASCII chars → bytes10
    // "mint"   → 0x64633666313762626563
    // "bid"    → 0x63306530656663346663
    // "settle" → 0x36383638653833646533
    ///////////////////
    bytes10 private constant WORKFLOW_MINT   = bytes10(0x64633666313762626563);
    bytes10 private constant WORKFLOW_BID    = bytes10(0x63306530656663346663);
    bytes10 private constant WORKFLOW_SETTLE = bytes10(0x36383638653833646533);

    ///////////////////
    // Errors
    ///////////////////
    error SealBidAuction__InvalidNullifier();
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
    error SealBidAuction__UnknownWorkflow(bytes10 workflowName);
    error SealBidAuction__UnknownInstructionType(uint8 instructionType);

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
    mapping(bytes32 => Auction) public auctions;
    mapping(bytes32 => bytes32[]) public bidHashes;

    bytes32 public activeAuctionId;

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

    ///////////////////
    // Functions
    ///////////////////
    constructor(
        address _forwarder,
        address _rwaToken,
        address _usdc,
        IWorldID _worldId,
        string memory _appId,
        string memory _depositAction
    ) ReceiverTemplate(_forwarder) {
        rwaToken = _rwaToken;
        i_worldId = _worldId;

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
    function addAcceptedToken(
        address token,
        uint256 _escrowAmount
    ) external onlyOwner {
        acceptedTokens[token] = true;
        escrowAmount[token] = _escrowAmount;
        emit TokenAccepted(token, _escrowAmount);
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
        if (activeAuctionId != bytes32(0)) {
            revert SealBidAuction__AuctionAlreadyExists();
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

        activeAuctionId = auctionId;

        emit AuctionCreated(
            auctionId,
            msg.sender,
            token,
            deadline,
            reservePrice
        );
    }

    ///////////////////
    // Internal Functions
    ///////////////////

    /// @notice Dispatches CRE reports to the correct handler using the workflowName from metadata.
    /// @dev workflowName is bytes10 encoded per CRE spec: SHA256(name) → hex string → first 10
    ///      hex chars → hex-encode those ASCII chars. Workflow yaml `name` fields must be set to
    ///      "mint", "bid", or "settle" respectively.
    function _processReport(bytes calldata metadata, bytes calldata report) internal override {
        (, bytes10 workflowName,) = _decodeMetadata(metadata);

        if (workflowName == WORKFLOW_MINT) {
            (uint8 instructionType, address account, uint256 amount,) =
                abi.decode(report, (uint8, address, uint256, bytes32));
            if (instructionType != 1) {
                revert SealBidAuction__UnknownInstructionType(instructionType);
            }
            _mintRWATokens(account, amount);

        } else if (workflowName == WORKFLOW_BID) {
            (bytes32 auctionId, bytes32 bidHash) =
                abi.decode(report, (bytes32, bytes32));
            _registerBid(auctionId, bidHash);

        } else if (workflowName == WORKFLOW_SETTLE) {
            (bytes32 auctionId, address winner, uint256 price) =
                abi.decode(report, (bytes32, address, uint256));
            _settleAuction(auctionId, winner, price);

        } else {
            revert SealBidAuction__UnknownWorkflow(workflowName);
        }
    }

    /// @notice Mints RWA tokens to a recipient. Trusted via CRE DON consensus + KeystoneForwarder.
    function _mintRWATokens(address to, uint256 amount) internal {
        ISealBidRWAToken(rwaToken).mint(to, amount);
        emit RWATokensMinted(to, amount);
    }

    /// @notice Registers an opaque bid hash on-chain for the given auction.
    function _registerBid(bytes32 auctionId, bytes32 bidHash) internal {
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

    /// @notice Settles the auction with the Vickrey winner and price computed by the CRE enclave.
    function _settleAuction(bytes32 auctionId, address winner, uint256 price) internal {
        if (auctionId != activeAuctionId) {
            revert SealBidAuction__AuctionNotFound();
        }
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

        activeAuctionId = bytes32(0);

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
