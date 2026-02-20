import { Router, Request, Response } from "express";
import { getAuction, getBids, settleAuctionInStore } from "../lib/store";
import { settleVickrey } from "../lib/vickrey";

const router = Router();

/**
 * POST /settle
 *
 * Runs Vickrey settlement for an auction.
 * Called via Confidential HTTP from CRE Workflow 2 with encryptOutput: true.
 *
 * Body: { auctionId: string }
 *
 * Returns: {
 *   auctionId: string,
 *   winner: string (address),
 *   price: string (uint256 decimal string),
 *   proof: string (HMAC hex)
 * }
 */
router.post("/", (req: Request, res: Response): void => {
  try {
    const { auctionId } = req.body;

    if (!auctionId) {
      res.status(400).json({ error: "Missing auctionId" });
      return;
    }

    // --- Check auction exists ---
    const auction = getAuction(auctionId);
    if (!auction) {
      res.status(400).json({ error: "Auction not found" });
      return;
    }

    if (auction.settled) {
      res.status(400).json({ error: "Auction already settled" });
      return;
    }

    // --- Get bids ---
    const bids = getBids(auctionId);
    if (bids.length === 0) {
      res.status(400).json({ error: "No bids to settle" });
      return;
    }

    // --- Run Vickrey settlement ---
    const hmacKey = process.env.HMAC_KEY || "default-hmac-key";
    const reservePrice = BigInt(0); // TODO: get from auction config

    const result = settleVickrey(bids, reservePrice, hmacKey);

    // --- Update store ---
    settleAuctionInStore(auctionId, result.winner, result.price);

    console.log(
      `[SETTLE] auction=${auctionId.slice(0, 10)}... winner=${result.winner.slice(0, 10)}... price=${result.price}`
    );

    res.status(200).json(result);
  } catch (err) {
    console.error("[SETTLE] Unexpected error:", err);
    res.status(500).json({ error: "Internal server error" });
  }
});

export default router;
