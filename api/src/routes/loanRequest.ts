import { Router, Request, Response } from "express";
import { keccak256, AbiCoder } from "ethers";
import {
  storeLoanRequest,
  getLoanRequest,
  getProperty,
} from "../lib/store";

const router = Router();

/**
 * POST /loan-request
 *
 * Borrower submits full loan request details off-chain.
 * API computes requestHash = keccak256(borrowerAddress + tokenId + requestedAmount + tenureMonths + nonce)
 * and stores the request keyed by that hash.
 *
 * The borrower then submits requestHash on-chain via LoanManager.submitRequest().
 *
 * Body: {
 *   borrowerAddress: string,     // Ethereum address
 *   plaidToken: string,          // Plaid access token for credit assessment
 *   tokenId: number,             // PropertyNFT token ID (must be verified)
 *   requestedAmount: string,     // USDC amount (6-decimal string, e.g. "500000000000" = $500k)
 *   tenureMonths: number,        // loan tenure in months (e.g. 360 = 30 years)
 *   nonce: number                // unique per request, tracked on-chain in LoanManager
 * }
 *
 * Returns: {
 *   requestHash: string,
 *   tokenId: number,
 *   nonce: number
 * }
 */
router.post("/", (req: Request, res: Response): void => {
  const { borrowerAddress, plaidToken, tokenId, requestedAmount, tenureMonths, nonce } = req.body;

  // --- Validate required fields ---
  if (!borrowerAddress || !plaidToken || tokenId === undefined || !requestedAmount || tenureMonths === undefined || nonce === undefined) {
    res.status(400).json({
      error: "Missing required fields: borrowerAddress, plaidToken, tokenId, requestedAmount, tenureMonths, nonce",
    });
    return;
  }

  // --- Validate types ---
  if (typeof borrowerAddress !== "string" || !borrowerAddress.startsWith("0x")) {
    res.status(400).json({ error: "borrowerAddress must be a hex string starting with 0x" });
    return;
  }

  if (typeof requestedAmount !== "string" || !/^\d+$/.test(requestedAmount)) {
    res.status(400).json({ error: "requestedAmount must be a numeric string" });
    return;
  }

  if (typeof tokenId !== "number" || tokenId <= 0) {
    res.status(400).json({ error: "tokenId must be a positive number" });
    return;
  }

  if (typeof tenureMonths !== "number" || tenureMonths <= 0) {
    res.status(400).json({ error: "tenureMonths must be a positive number" });
    return;
  }

  if (typeof nonce !== "number" || nonce < 0) {
    res.status(400).json({ error: "nonce must be a non-negative number" });
    return;
  }

  // --- Verify property exists ---
  const property = getProperty(tokenId);
  if (!property) {
    res.status(400).json({
      error: `Property with tokenId ${tokenId} not found. Verify property first via /verify-property.`,
    });
    return;
  }

  // --- Compute requestHash ---
  const abiCoder = AbiCoder.defaultAbiCoder();
  const packed = abiCoder.encode(
    ["address", "uint256", "uint256", "uint256", "uint256"],
    [borrowerAddress, tokenId, requestedAmount, tenureMonths, nonce]
  );
  const requestHash = keccak256(packed);

  // --- Store loan request ---
  const stored = storeLoanRequest({
    requestHash,
    borrowerAddress,
    plaidToken,
    tokenId,
    requestedAmount,
    tenureMonths,
    nonce,
    timestamp: Date.now(),
  });

  if (!stored) {
    res.status(409).json({ error: "Duplicate loan request (same requestHash)" });
    return;
  }

  console.log(
    `[LOAN-REQUEST] borrower=${borrowerAddress} tokenId=${tokenId} amount=${requestedAmount} tenure=${tenureMonths} nonce=${nonce} hash=${requestHash}`
  );

  res.status(200).json({
    requestHash,
    tokenId,
    nonce,
  });
});

/**
 * GET /loan-request/:requestHash
 *
 * Fetch full loan request details by requestHash.
 * Used by the CRE credit-assessment workflow to retrieve request details.
 * Includes appraisedValueUsd from the property store.
 */
router.get("/:requestHash", (req: Request, res: Response): void => {
  const { requestHash } = req.params;

  const request = getLoanRequest(requestHash);
  if (!request) {
    res.status(404).json({ error: "Loan request not found" });
    return;
  }

  // Look up property appraisal value for the CRE workflow
  const property = getProperty(request.tokenId);
  const appraisedValueUsd = property ? property.appraisedValueUsd : 0;

  res.status(200).json({
    ...request,
    appraisedValueUsd,
  });
});

export default router;
