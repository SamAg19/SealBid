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
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IWorldID} from "./interfaces/IWorldID.sol";
import {ByteHasher} from "./libraries/ByteHasher.sol";
import {ReceiverTemplate} from "./ReceiverTemplate.sol";

/**
 * @title LienFi Auction
 * @author LienFi Team
 *
 * Privacy-preserving sealed-bid auction platform for tokenized real estate.
 *
 * Each property is represented by an ERC-721 token (PropertyNFT). The NFT is held in escrow
 * by this contract during the auction. Bidders compete with USDC. The Vickrey winner pays
 * second-price in USDC and receives the property NFT. The seller receives the USDC.
 *
 * Properties:
 * - One ERC-721 per property: the PropertyNFT contract address is set at deploy time.
 *   The NFT must be transferred to this contract before auction creation.
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
 *   create: abi.encode(bytes32 propertyId, address seller, uint256 tokenId,
 *                      bytes32 auctionId, uint256 deadline, uint256 reservePrice)
 *   bid:    abi.encode(bytes32 auctionId, bytes32 bidHash)
 *   settle: abi.encode(bytes32 auctionId, address winner, uint256 price)
 */
contract LienFiAuction is ReceiverTemplate, ReentrancyGuard {
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
    error LienFiAuction__InvalidNullifier();
    error LienFiAuction__TokenNotAccepted();
    error LienFiAuction__InvalidAmount();
    error LienFiAuction__LockMustBeInFuture();
    error LienFiAuction__TransferFailed();
    error LienFiAuction__FundsLocked();
    error LienFiAuction__InsufficientBalance();
    error LienFiAuction__AuctionNotFound();
    error LienFiAuction__AuctionAlreadyExists();
    error LienFiAuction__DeadlineMustBeFuture();
    error LienFiAuction__AuctionExpired();
    error LienFiAuction__AuctionNotExpired();
    error LienFiAuction__AuctionAlreadySettled();
    error LienFiAuction__WinnerUnderfunded();
    error LienFiAuction__CanOnlyExtendLock();
    error LienFiAuction__UnknownWorkflow(bytes10 workflowName);
    error LienFiAuction__UnknownInstructionType(uint8 instructionType);

    ///////////////////
    // Type Declarations
    ///////////////////
    struct Auction {
        address seller;
        uint256 tokenId;       // PropertyNFT token held in escrow
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
    address public immutable i_propertyNFT;
    uint256 public immutable i_groupId = 1;
    uint256 public immutable i_depositExternalNullifierHash;
    mapping(uint256 => bool) public nullifierHashes;

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
        uint256 indexed tokenId,
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
        address _propertyNFT,
        IWorldID _worldId,
        string memory _appId,
        string memory _depositAction
    ) ReceiverTemplate(_forwarder) {
        i_usdc = _usdc;
        i_propertyNFT = _propertyNFT;
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
            revert LienFiAuction__TokenNotAccepted();
        }
        if (amount == 0) {
            revert LienFiAuction__InvalidAmount();
        }
        if (lockUntil <= block.timestamp) {
            revert LienFiAuction__LockMustBeInFuture();
        }
        if (nullifierHashes[nullifierHash]) {
            revert LienFiAuction__InvalidNullifier();
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
            revert LienFiAuction__TransferFailed();
        }

        poolBalance[msg.sender][token] += amount;

        if (lockUntil > lockExpiry[msg.sender]) {
            lockExpiry[msg.sender] = lockUntil;
        }

        emit PoolDeposit(msg.sender, token, amount, lockUntil);
    }

    function extendLock(uint256 newExpiry) external {
        if (newExpiry <= lockExpiry[msg.sender]) {
            revert LienFiAuction__CanOnlyExtendLock();
        }
        lockExpiry[msg.sender] = newExpiry;
        emit LockExtended(msg.sender, newExpiry);
    }

    function withdrawFromPool(
        address token,
        uint256 amount
    ) external nonReentrant {
        if (block.timestamp < lockExpiry[msg.sender]) {
            revert LienFiAuction__FundsLocked();
        }
        if (poolBalance[msg.sender][token] < amount) {
            revert LienFiAuction__InsufficientBalance();
        }

        poolBalance[msg.sender][token] -= amount;

        if (!IERC20(token).transfer(msg.sender, amount)) {
            revert LienFiAuction__TransferFailed();
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
                uint256 tokenId,
                bytes32 auctionId,
                uint256 deadline,
                uint256 reservePrice
            ) = abi.decode(report, (bytes32, address, uint256, bytes32, uint256, uint256));
            _createPropertyAuction(propertyId, seller, tokenId, auctionId, deadline, reservePrice);

        } else if (workflowName == WORKFLOW_BID) {
            (bytes32 auctionId, bytes32 bidHash) =
                abi.decode(report, (bytes32, bytes32));
            _registerBid(auctionId, bidHash);

        } else if (workflowName == WORKFLOW_SETTLE) {
            (bytes32 auctionId, address winner, uint256 price) =
                abi.decode(report, (bytes32, address, uint256));
            _settleAuction(auctionId, winner, price);

        } else {
            revert LienFiAuction__UnknownWorkflow(workflowName);
        }
    }

    /**
     * @notice Open a sealed-bid auction for a property NFT already held in escrow.
     * Called exclusively via CRE "create" workflow report after off-chain property verification.
     * The NFT must have been transferred to this contract before the report is submitted.
     */
    function _createPropertyAuction(
        bytes32 propertyId,
        address seller,
        uint256 tokenId,
        bytes32 auctionId,
        uint256 deadline,
        uint256 reservePrice
    ) internal {
        if (auctions[auctionId].deadline != 0) {
            revert LienFiAuction__AuctionAlreadyExists();
        }
        if (activeAuctionId != bytes32(0)) {
            revert LienFiAuction__AuctionAlreadyExists();
        }

        // Verify this contract holds the NFT in escrow
        if (IERC721(i_propertyNFT).ownerOf(tokenId) != address(this)) {
            revert LienFiAuction__TransferFailed();
        }

        auctions[auctionId] = Auction({
            seller: seller,
            tokenId: tokenId,
            deadline: deadline,
            reservePrice: reservePrice,
            settled: false,
            winner: address(0),
            settledPrice: 0
        });

        activeAuctionId = auctionId;

        emit AuctionCreated(auctionId, seller, tokenId, deadline, reservePrice);
    }

    /// @notice Registers an opaque bid hash on-chain for the given auction.
    function _registerBid(bytes32 auctionId, bytes32 bidHash) internal {
        Auction storage a = auctions[auctionId];
        if (a.deadline == 0) {
            revert LienFiAuction__AuctionNotFound();
        }
        if (block.timestamp >= a.deadline) {
            revert LienFiAuction__AuctionExpired();
        }
        if (a.settled) {
            revert LienFiAuction__AuctionAlreadySettled();
        }

        bidHashes[auctionId].push(bidHash);
        emit BidRegistered(auctionId, bidHash);
    }

    /// @notice Settles the auction: winner's USDC pool debited → seller gets USDC, winner gets property NFT.
    function _settleAuction(bytes32 auctionId, address winner, uint256 price) internal {
        if (auctionId != activeAuctionId) {
            revert LienFiAuction__AuctionNotFound();
        }
        Auction storage a = auctions[auctionId];
        if (a.deadline == 0) {
            revert LienFiAuction__AuctionNotFound();
        }
        if (block.timestamp < a.deadline) {
            revert LienFiAuction__AuctionNotExpired();
        }
        if (a.settled) {
            revert LienFiAuction__AuctionAlreadySettled();
        }
        if (poolBalance[winner][i_usdc] < price) {
            revert LienFiAuction__WinnerUnderfunded();
        }

        a.settled = true;
        a.winner = winner;
        a.settledPrice = price;
        activeAuctionId = bytes32(0);

        // Debit winner's USDC pool → pay seller
        poolBalance[winner][i_usdc] -= price;
        if (!IERC20(i_usdc).transfer(a.seller, price)) {
            revert LienFiAuction__TransferFailed();
        }

        // Transfer property NFT from escrow → winner
        IERC721(i_propertyNFT).safeTransferFrom(address(this), winner, a.tokenId);

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
