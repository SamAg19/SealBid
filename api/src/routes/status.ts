import { Router, Request, Response } from "express";
import { getAuction } from "../lib/store";

const router = Router();

/**
 * GET /status/:auctionId
 *
 * Returns auction status: bid count, deadline, settled state.
 *
 * Returns: { bidCount: number, deadline: number, settled: boolean }
 */
router.get("/:auctionId", (req: Request<{ auctionId: string }>, res: Response): void => {
  try {
    const { auctionId } = req.params;

    const auction = getAuction(auctionId);
    if (!auction) {
      res.status(200).json({
        bidCount: 0,
        deadline: 0,
        settled: false,
      });
      return;
    }

    res.status(200).json({
      bidCount: auction.bids.length,
      deadline: auction.deadline,
      settled: auction.settled,
    });
  } catch (err) {
    console.error("[STATUS] Unexpected error:", err);
    res.status(500).json({ error: "Internal server error" });
  }
});

export default router;
