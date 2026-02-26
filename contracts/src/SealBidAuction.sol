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
import {SealBidRWAToken} from "./SealBidRWAToken.sol";
import {ByteHasher} from "./libraries/ByteHasher.sol";
import {ReceiverTemplate} from "./ReceiverTemplate.sol";

/**
 * @title SealBidAuction
 * @author SealBid Team
 *
 * Privacy-preserving sealed-bid auction platform for fractional real estate equity.
 *
 * A property owner tokenizes a fraction of their property by sending a payload to the
 * CRE create-auction workflow. The workflow verifies the property off-chain via Confidential
 * HTTP, then delivers a DON-signed report that triggers this contract to:
 *   1. Deploy a new ERC-20 property share token (one per property)
 *   2. Mint the verified share amount directly into this contract's escrow
 *   3. Open the sealed-bid auction
 *
 * Bidders compete with USDC. The Vickrey winner pays second-price in USDC and receives
 * the property share tokens. The seller receives the USDC.
 *
 * Properties:
 * - Per-property tokens: each property gets its own ERC-20 deployed inside _createPropertyAuction.
 *   Only contract-deployed tokens are held in escrow; no external token injection.
 * - Bid token is always USDC (i_usdc immutable): bidders deposit arbitrary USDC amounts.
 * - World ID integration: pool deposits require ZK proof — one human, one deposit.
 * - Auction lifecycle: CRE-only bid registration and settlement via onReport.
 *   Only opaque bid hashes stored on-chain. Settlement reveals only winner + Vickrey price.
 * - Privacy: bid amounts, bidder identities, and losing bids are never exposed on-chain.
 *
 * @notice CRE workflows deliver signed reports via the KeystoneForwarder → onReport.
 * Dispatch is based on workflowName (bytes10) from report metadata:
 *   "create" → _createPropertyAuction
 *   "bid"    → _registerBid
 *   "settle" → _settleAuction
 *
 * Workflow report encodings:
 *   create: abi.encode(bytes32 propertyId, address seller, uint256 shareAmount,
 *                      string tokenName, string tokenSymbol,
 *                      bytes32 auctionId, uint256 deadline, uint256 reservePrice)
 *   bid:    abi.encode(bytes32 auctionId, bytes32 bidHash)
 *   settle: abi.encode(bytes32 auctionId, address winner, uint256 price)
 */
contract SealBidAuction is ReceiverTemplate, ReentrancyGuard {
    using ByteHasher for bytes;

    ///////////////////
    // Workflow Name Constants (bytes10)
    // Encoding: SHA256(name) → 64-char hex string → first 10 hex chars → hex-encode those ASCII chars → bytes10
    // "create" → SHA256 first 10: "fa8847b0c3" → 0x66613838343762306333
    // "bid"    → SHA256 first 10: "c0e0efc4fc" → 0x63306530656663346663
    // "settle" → SHA256 first 10: "6868e83de3" → 0x36383638653833646533
    ///////////////////
    bytes10 private constant WORKFLOW_CREATE = bytes10(0x66613838343762306333);
    bytes10 private constant WORKFLOW_BID    = bytes10(0x63306530656663346663);
    bytes10 private constant WORKFLOW_SETTLE = bytes10(0x36383638653833646533);

    ///////////////////
    // Errors
    ///////////////////
    error SealBidAuction__InvalidNullifier();
    error SealBidAuction__TokenNotAccepted();
    error SealBidAuction__InvalidAmount();
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
        address tokenAddress;  // property ERC-20 deployed by this contract
        uint256 shareAmount;   // property share tokens held in escrow by this contract
        uint256 deadline;
        uint256 reservePrice;  // USDC (6 decimals)
        bool settled;
        address winner;
        uint256 settledPrice;  // USDC (6 decimals)
    }

    ///////////////////
    // State Variables
    ///////////////////
    IWorldID public immutable i_worldId;
    address public immutable i_usdc;
    uint256 public immutable i_groupId = 1;
    uint256 public immutable i_depositExternalNullifierHash;
    mapping(uint256 => bool) public nullifierHashes;

    // Per-property token registry — only tokens deployed by this contract
    mapping(address => bool) public isPropertyToken;

    // Deposit Pool — USDC accepted for bidding
    mapping(address => bool) public acceptedTokens;
    mapping(address => mapping(address => uint256)) public poolBalance;
    mapping(address => uint256) public lockExpiry;

    // Auction Lifecycle
    mapping(bytes32 => Auction) public auctions;
    mapping(bytes32 => bytes32[]) public bidHashes;

    bytes32 public activeAuctionId;

    ///////////////////
    // Events
    ///////////////////
    event PropertyTokenCreated(address indexed tokenAddress, string name, string symbol);
    event PropertyTokensMinted(address indexed tokenAddress, address indexed to, uint256 amount);
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
        address indexed seller,
        address indexed tokenAddress,
        uint256 shareAmount,
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
        address _usdc,
        IWorldID _worldId,
        string memory _appId,
        string memory _depositAction
    ) ReceiverTemplate(_forwarder) {
        i_usdc = _usdc;
        i_worldId = _worldId;

        i_depositExternalNullifierHash = abi
            .encodePacked(
                abi.encodePacked(_appId).hashToField(),
                _depositAction
            )
            .hashToField();

        // USDC accepted for pool deposits (bidding collateral)
        acceptedTokens[_usdc] = true;
    }

    ///////////////////
    // External Functions
    ///////////////////

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
        if (amount == 0) {
            revert SealBidAuction__InvalidAmount();
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

    ///////////////////
    // Internal Functions
    ///////////////////

    /// @notice Dispatches CRE reports to the correct handler using workflowName from metadata.
    function _processReport(bytes calldata metadata, bytes calldata report) internal override {
        (, bytes10 workflowName,) = _decodeMetadata(metadata);

        if (workflowName == WORKFLOW_CREATE) {
            (
                bytes32 propertyId,
                address seller,
                uint256 shareAmount,
                string memory tokenName,
                string memory tokenSymbol,
                bytes32 auctionId,
                uint256 deadline,
                uint256 reservePrice
            ) = abi.decode(report, (bytes32, address, uint256, string, string, bytes32, uint256, uint256));
            _createPropertyAuction(propertyId, seller, shareAmount, tokenName, tokenSymbol, auctionId, deadline, reservePrice);

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

    /**
     * @notice Deploy a per-property ERC-20 token, mint shares into escrow, and open the auction.
     * Called exclusively via CRE "create" workflow report after off-chain property verification.
     */
    function _createPropertyAuction(
        bytes32 propertyId,
        address seller,
        uint256 shareAmount,
        string memory tokenName,
        string memory tokenSymbol,
        bytes32 auctionId,
        uint256 deadline,
        uint256 reservePrice
    ) internal {
        if (auctions[auctionId].deadline != 0) {
            revert SealBidAuction__AuctionAlreadyExists();
        }
        if (activeAuctionId != bytes32(0)) {
            revert SealBidAuction__AuctionAlreadyExists();
        }
        if (shareAmount == 0) {
            revert SealBidAuction__InvalidAmount();
        }

        // Deploy a new property share token; this contract is the exclusive minter
        SealBidRWAToken token = new SealBidRWAToken(tokenName, tokenSymbol, address(this));
        address tokenAddress = address(token);
        isPropertyToken[tokenAddress] = true;

        // Mint share tokens directly into this contract's escrow (no seller approval needed)
        ISealBidRWAToken(tokenAddress).mint(address(this), shareAmount);

        auctions[auctionId] = Auction({
            seller: seller,
            tokenAddress: tokenAddress,
            shareAmount: shareAmount,
            deadline: deadline,
            reservePrice: reservePrice,
            settled: false,
            winner: address(0),
            settledPrice: 0
        });

        activeAuctionId = auctionId;

        emit PropertyTokenCreated(tokenAddress, tokenName, tokenSymbol);
        emit PropertyTokensMinted(tokenAddress, address(this), shareAmount);
        emit AuctionCreated(auctionId, seller, tokenAddress, shareAmount, deadline, reservePrice);
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

    /// @notice Settles the auction: winner's USDC pool debited → seller gets USDC, winner gets property shares.
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
        if (poolBalance[winner][i_usdc] < price) {
            revert SealBidAuction__WinnerUnderfunded();
        }

        a.settled = true;
        a.winner = winner;
        a.settledPrice = price;
        activeAuctionId = bytes32(0);

        // Debit winner's USDC pool → pay seller
        poolBalance[winner][i_usdc] -= price;
        if (!IERC20(i_usdc).transfer(a.seller, price)) {
            revert SealBidAuction__TransferFailed();
        }

        // Release escrowed property share tokens → winner
        if (!IERC20(a.tokenAddress).transfer(winner, a.shareAmount)) {
            revert SealBidAuction__TransferFailed();
        }

        emit AuctionSettled(auctionId, winner, price);
    }

    ///////////////////
    // View & Pure Functions
    ///////////////////

    /// @notice Returns true if the bidder has sufficient USDC pool balance and lock coverage for the auction.
    function canBid(
        address bidder,
        bytes32 auctionId
    ) external view returns (bool) {
        Auction storage a = auctions[auctionId];
        if (a.deadline == 0) {
            return false;
        }
        return
            poolBalance[bidder][i_usdc] >= a.reservePrice &&
            lockExpiry[bidder] >= a.deadline;
    }

    function getBidCount(bytes32 auctionId) external view returns (uint256) {
        return bidHashes[auctionId].length;
    }
}
