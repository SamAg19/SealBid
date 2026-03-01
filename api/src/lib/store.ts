/**
 * In-memory storage for the LienFi private API.
 *
 * Stores:
 * - Bid data for sealed-bid auctions (keyed by auctionId)
 * - Verified property details (keyed by tokenId) — full details stored here,
 *   only the metadataHash lives on-chain in the PropertyNFT
 */

export interface StoredBid {
  auctionId: string;
  bidder: string;
  amount: string; // uint256 decimal string — token-agnostic
  nonce: number;
  signature: string;
  bidHash: string;
  timestamp: number;
}

export interface AuctionState {
  auctionId: string;
  bids: StoredBid[];
  deadline: number;
  settled: boolean;
  winner?: string;
  price?: string;
}

// In-memory store — keyed by auctionId
const auctions: Map<string, AuctionState> = new Map();

/**
 * Get or auto-create an auction state.
 * Auto-creates on first bid for dev convenience.
 */
export function getOrCreateAuction(
  auctionId: string,
  deadline?: number
): AuctionState {
  let auction = auctions.get(auctionId);
  if (!auction) {
    auction = {
      auctionId,
      bids: [],
      deadline: deadline || Math.floor(Date.now() / 1000) + 3600, // default 1hr
      settled: false,
    };
    auctions.set(auctionId, auction);
  }
  return auction;
}

/**
 * Get an existing auction or return null.
 */
export function getAuction(auctionId: string): AuctionState | null {
  return auctions.get(auctionId) || null;
}

/**
 * Store a bid in the auction's bid list.
 * Returns false if duplicate (same bidder + auctionId).
 */
export function storeBid(bid: StoredBid): boolean {
  const auction = getOrCreateAuction(bid.auctionId);

  // Reject duplicates — same bidder in same auction
  const duplicate = auction.bids.find(
    (b) => b.bidder.toLowerCase() === bid.bidder.toLowerCase()
  );
  if (duplicate) {
    return false;
  }

  auction.bids.push(bid);
  return true;
}

/**
 * Get all bids for an auction.
 */
export function getBids(auctionId: string): StoredBid[] {
  const auction = auctions.get(auctionId);
  return auction ? auction.bids : [];
}

/**
 * Mark an auction as settled with winner and price.
 */
export function settleAuctionInStore(
  auctionId: string,
  winner: string,
  price: string
): void {
  const auction = auctions.get(auctionId);
  if (auction) {
    auction.settled = true;
    auction.winner = winner;
    auction.price = price;
  }
}

// ─── Property Storage ─────────────────────────────────────────────────────────

export interface StoredProperty {
  tokenId: number;
  propertyId: string;
  address: string;
  appraisedValueUsd: number;
  ownerAddress: string;
  metadataHash: string; // keccak256 of property details — matches on-chain NFT metadata
}

// In-memory store — keyed by tokenId
const properties: Map<number, StoredProperty> = new Map();
let nextTokenId = 1;

export function getNextTokenId(): number {
  return nextTokenId++;
}

export function storeProperty(property: StoredProperty): void {
  properties.set(property.tokenId, property);
}

export function getProperty(tokenId: number): StoredProperty | null {
  return properties.get(tokenId) || null;
}

// ─── Loan Request Storage ────────────────────────────────────────────────────

export interface StoredLoanRequest {
  requestHash: string;
  borrowerAddress: string;
  plaidToken: string;
  tokenId: number;
  requestedAmount: string; // uint256 decimal string (USDC 6 decimals)
  tenureMonths: number;
  nonce: number; // provided by borrower, tracked on-chain in LoanManager
  timestamp: number;
}

// In-memory store — keyed by requestHash
const loanRequests: Map<string, StoredLoanRequest> = new Map();

export function storeLoanRequest(request: StoredLoanRequest): boolean {
  if (loanRequests.has(request.requestHash)) return false;
  loanRequests.set(request.requestHash, request);
  return true;
}

export function getLoanRequest(requestHash: string): StoredLoanRequest | null {
  return loanRequests.get(requestHash) || null;
}
