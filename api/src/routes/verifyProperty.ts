import { Router, Request, Response } from "express";
import { keccak256, AbiCoder } from "ethers";
import {
  getNextTokenId,
  storeProperty,
} from "../lib/store";

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

// Secret used to make metadataHash unpredictable — in production this lives in CRE enclave
const COMMITMENT_SECRET = "lienfi-demo-secret-2024";

/**
 * POST /verify-property
 *
 * Called via Confidential HTTP from the CRE workflow.
 * Verifies that a property exists, has a clear title, and hasn't already been tokenized.
 * Returns a tokenId and metadataHash (keccak256 of property details) for NFT minting.
 *
 * Body: {
 *   propertyId: string,      // e.g. "PROP-001"
 *   sellerAddress: string    // Ethereum address of the property owner
 * }
 *
 * Returns: {
 *   valid: boolean,
 *   tokenId: number,          // assigned token ID
 *   metadataHash: string,     // keccak256(address + appraisedValue + titleDeed + secret)
 *   appraisedValue: string,   // total property value in USD
 *   message: string
 * }
 */
router.post("/", (req: Request, res: Response): void => {
  const { propertyId, sellerAddress } = req.body;

  // --- Validate required fields ---
  if (!propertyId || !sellerAddress) {
    res.status(400).json({
      error: "Missing required fields: propertyId, sellerAddress",
    });
    return;
  }

  // --- Look up property ---
  const property = propertyRegistry.get(propertyId);

  if (!property) {
    res.status(200).json({
      valid: false,
      tokenId: 0,
      metadataHash: "0x",
      appraisedValue: "0",
      message: `Property ${propertyId} not found in registry`,
    });
    return;
  }

  if (!property.ownerVerified) {
    res.status(200).json({
      valid: false,
      tokenId: 0,
      metadataHash: "0x",
      appraisedValue: property.appraisedValueUsd.toString(),
      message: "Property owner not verified — title deed pending clearance",
    });
    return;
  }

  if (property.tokenized) {
    res.status(200).json({
      valid: false,
      tokenId: 0,
      metadataHash: "0x",
      appraisedValue: property.appraisedValueUsd.toString(),
      message: "Property already tokenized — cannot tokenize twice",
    });
    return;
  }

  // --- Compute metadataHash ---
  // keccak256(propertyAddress + appraisedValue + titleDeedNumber + secret)
  const abiCoder = AbiCoder.defaultAbiCoder();
  const packed = abiCoder.encode(
    ["string", "uint256", "string", "string"],
    [property.address, property.appraisedValueUsd, property.titleDeedNumber, COMMITMENT_SECRET]
  );
  const metadataHash = keccak256(packed);

  // --- Assign tokenId and store ---
  const tokenId = getNextTokenId();
  property.tokenized = true;

  storeProperty({
    tokenId,
    propertyId: property.propertyId,
    address: property.address,
    appraisedValueUsd: property.appraisedValueUsd,
    ownerAddress: sellerAddress,
    metadataHash,
  });

  console.log(
    `[VERIFY-PROPERTY] propertyId=${propertyId} seller=${sellerAddress} tokenId=${tokenId} metadataHash=${metadataHash}`
  );

  res.status(200).json({
    valid: true,
    tokenId,
    metadataHash,
    appraisedValue: property.appraisedValueUsd.toString(),
    message: `Property ${propertyId} (${property.address}) verified. TokenId=${tokenId}`,
  });
});

export default router;
