import { Router, Request, Response } from "express";

const router = Router();

interface Property {
  propertyId: string;
  address: string;
  titleDeedNumber: string;
  appraisedValueUsd: number;
  ownerVerified: boolean;
  tokenized: boolean; // prevents double-tokenization
}

// Simulated property title registry — pre-seeded for demo
const propertyRegistry: Map<string, Property> = new Map([
  [
    "PROP-001",
    {
      propertyId: "PROP-001",
      address: "123 Main St, Austin TX",
      titleDeedNumber: "TX-2024-00123",
      appraisedValueUsd: 1_000_000,
      ownerVerified: true,
      tokenized: false,
    },
  ],
  [
    "PROP-002",
    {
      propertyId: "PROP-002",
      address: "456 Ocean Dr, Miami FL",
      titleDeedNumber: "FL-2024-00456",
      appraisedValueUsd: 2_500_000,
      ownerVerified: true,
      tokenized: false,
    },
  ],
  [
    "PROP-003",
    {
      propertyId: "PROP-003",
      address: "789 Sunset Blvd, Los Angeles CA",
      titleDeedNumber: "CA-2024-00789",
      appraisedValueUsd: 800_000,
      ownerVerified: false, // unverified owner — for negative test
      tokenized: false,
    },
  ],
]);

/**
 * POST /verify-property
 *
 * Called via Confidential HTTP from the CRE create-auction workflow.
 * Verifies that a property exists, has a clear title, and hasn't already been tokenized.
 * Returns the share amount (18-decimal scaled) the workflow should mint.
 *
 * Body: {
 *   propertyId: string,      // e.g. "PROP-001"
 *   fractionBps: number,     // basis points to tokenize (1-10000, e.g. 2500 = 25%)
 *   sellerAddress: string    // Ethereum address of the property owner
 * }
 *
 * Returns: {
 *   valid: boolean,
 *   shareAmount: string,      // uint256 decimal string, 18-decimal scaled
 *   appraisedValue: string,   // total property value in USD
 *   message: string
 * }
 */
router.post("/", (req: Request, res: Response): void => {
  const { propertyId, fractionBps, sellerAddress } = req.body;

  // --- Validate required fields ---
  if (!propertyId || fractionBps === undefined || !sellerAddress) {
    res.status(400).json({
      error: "Missing required fields: propertyId, fractionBps, sellerAddress",
    });
    return;
  }

  if (typeof fractionBps !== "number" || fractionBps < 1 || fractionBps > 10000) {
    res.status(400).json({
      error: "fractionBps must be a number between 1 and 10000",
    });
    return;
  }

  // --- Look up property ---
  const property = propertyRegistry.get(propertyId);

  if (!property) {
    res.status(200).json({
      valid: false,
      shareAmount: "0",
      appraisedValue: "0",
      message: `Property ${propertyId} not found in registry`,
    });
    return;
  }

  if (!property.ownerVerified) {
    res.status(200).json({
      valid: false,
      shareAmount: "0",
      appraisedValue: property.appraisedValueUsd.toString(),
      message: "Property owner not verified — title deed pending clearance",
    });
    return;
  }

  if (property.tokenized) {
    res.status(200).json({
      valid: false,
      shareAmount: "0",
      appraisedValue: property.appraisedValueUsd.toString(),
      message: "Property already tokenized — cannot tokenize twice",
    });
    return;
  }

  // --- Compute share amount (18-decimal scaled) ---
  // shareAmount = floor(appraisedValueUsd * fractionBps / 10000) * 1e18
  const fractionalValueUsd = Math.floor(
    (property.appraisedValueUsd * fractionBps) / 10000
  );
  // Use BigInt to avoid floating point issues at 1e18 scale
  const shareAmount = (BigInt(fractionalValueUsd) * BigInt(1e18)).toString();

  // --- Mark property as tokenized (prevents double-tokenization) ---
  property.tokenized = true;

  console.log(
    `[VERIFY-PROPERTY] propertyId=${propertyId} fractionBps=${fractionBps} seller=${sellerAddress} shareAmount=${shareAmount}`
  );

  res.status(200).json({
    valid: true,
    shareAmount,
    appraisedValue: property.appraisedValueUsd.toString(),
    message: `Property ${propertyId} (${property.address}) verified. Tokenizing ${fractionBps / 100}% = $${fractionalValueUsd.toLocaleString()} USD`,
  });
});

export default router;
