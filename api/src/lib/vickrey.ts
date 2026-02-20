import crypto from "crypto";
import { StoredBid } from "./store";

export interface SettlementResult {
  auctionId: string;
  winner: string;
  price: string; // uint256 decimal string — token-agnostic
  proof: string; // HMAC hex
}

/**
 * Vickrey (second-price) auction settlement.
 *
 * Rules:
 * - Highest bidder wins
 * - Winner pays the second-highest bid price
 * - If only one bid, winner pays the reserve price
 * - HMAC proof ties the result to the settlement for on-chain verification
 *
 * Token-agnostic: amounts compared as bigints regardless of decimal scheme.
 *
 * TODO (Day 2): Replace stub with real implementation
 */
export function settleVickrey(
  bids: StoredBid[],
  reservePrice: bigint,
  hmacKey: string
): SettlementResult {
  if (bids.length === 0) {
    throw new Error("No bids to settle");
  }

  // Sort descending by amount (bigint comparison)
  const sorted = [...bids].sort((a, b) => {
    const amountA = BigInt(a.amount);
    const amountB = BigInt(b.amount);
    if (amountA > amountB) return -1;
    if (amountA < amountB) return 1;
    return 0;
  });

  const winner = sorted[0].bidder;

  // Vickrey: pay second-highest price, or reserve if only one bid
  const price =
    sorted.length > 1 ? BigInt(sorted[1].amount) : reservePrice;

  // HMAC proof for on-chain verification
  const hmac = crypto
    .createHmac("sha256", hmacKey)
    .update(`${winner}:${price.toString()}`)
    .digest("hex");

  return {
    auctionId: sorted[0].auctionId,
    winner,
    price: price.toString(),
    proof: `0x${hmac}`,
  };
}
