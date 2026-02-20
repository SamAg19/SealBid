import { Router, Request, Response } from "express";
import { verifyBidSignature, computeBidHash } from "../lib/eip712";
import { storeBid, getOrCreateAuction } from "../lib/store";

const router = Router();

/**
 * POST /bid
 *
 * Accepts a signed bid via Confidential HTTP from CRE Workflow 1.
 *
 * Body: {
 *   auctionId: string (bytes32 hex),
 *   bidder: string (address),
 *   amount: string (uint256 decimal string),
 *   nonce: number,
 *   signature: string (hex),
 *   auctionDeadline: number (unix timestamp)
 * }
 *
 * Returns: { bidHash: string, timestamp: number }
 */
router.post("/", (req: Request, res: Response): void => {
  try {
    const { auctionId, bidder, amount, nonce, signature, auctionDeadline } =
      req.body;

    // --- Validate required fields ---
    if (!auctionId || !bidder || !amount || nonce === undefined || !signature) {
      res.status(400).json({
        error:
          "Missing required fields: auctionId, bidder, amount, nonce, signature",
      });
      return;
    }

    // --- Validate types ---
    if (typeof auctionId !== "string" || !auctionId.startsWith("0x")) {
      res.status(400).json({ error: "auctionId must be a hex string" });
      return;
    }

    if (typeof bidder !== "string" || !bidder.startsWith("0x")) {
      res.status(400).json({ error: "bidder must be an address" });
      return;
    }

    if (typeof amount !== "string" || !/^\d+$/.test(amount)) {
      res.status(400).json({ error: "amount must be a uint256 decimal string" });
      return;
    }

    if (typeof nonce !== "number" || nonce < 0) {
      res.status(400).json({ error: "nonce must be a non-negative number" });
      return;
    }

    // --- Check auction deadline ---
    const auction = getOrCreateAuction(auctionId, auctionDeadline);
    if (auction.settled) {
      res.status(400).json({ error: "Auction already settled" });
      return;
    }

    const now = Math.floor(Date.now() / 1000);
    if (now >= auction.deadline) {
      res.status(400).json({ error: "Auction expired" });
      return;
    }

    // --- Verify EIP-712 signature ---
    let recoveredAddress: string;
    try {
      recoveredAddress = verifyBidSignature(
        { auctionId, bidder, amount, nonce },
        signature
      );
    } catch (err) {
      res.status(403).json({ error: "Invalid signature" });
      return;
    }

    // Recovered address must match claimed bidder
    if (recoveredAddress.toLowerCase() !== bidder.toLowerCase()) {
      res.status(403).json({
        error: "Invalid signature",
      });
      return;
    }

    // --- Compute bid hash ---
    const bidHash = computeBidHash({ auctionId, bidder, amount, nonce });
    const timestamp = Math.floor(Date.now() / 1000);

    // --- Store bid (rejects duplicates) ---
    const stored = storeBid({
      auctionId,
      bidder,
      amount,
      nonce,
      signature,
      bidHash,
      timestamp,
    });

    if (!stored) {
      res.status(400).json({ error: "Duplicate bid from this bidder" });
      return;
    }

    console.log(
      `[BID] auction=${auctionId.slice(0, 10)}... bidder=${bidder.slice(0, 10)}... hash=${bidHash.slice(0, 10)}...`
    );

    res.status(200).json({ bidHash, timestamp });
  } catch (err) {
    console.error("[BID] Unexpected error:", err);
    res.status(500).json({ error: "Internal server error" });
  }
});

export default router;
