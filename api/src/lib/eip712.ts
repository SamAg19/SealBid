import { ethers } from "ethers";

/**
 * EIP-712 typed data domain and types for SealBid bids.
 *
 * Domain:
 *   name: "SealBid"
 *   version: "1"
 *   chainId: 11155111 (Sepolia)
 *   verifyingContract: <SealBidAuction address>
 */

const BID_TYPES = {
  Bid: [
    { name: "auctionId", type: "bytes32" },
    { name: "bidder", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "nonce", type: "uint256" },
  ],
};

function getDomain(): ethers.TypedDataDomain {
  return {
    name: "SealBid",
    version: "1",
    chainId: parseInt(process.env.CHAIN_ID || "11155111"),
    verifyingContract: process.env.VERIFYING_CONTRACT || ethers.ZeroAddress,
  };
}

export interface BidMessage {
  auctionId: string;
  bidder: string;
  amount: string;
  nonce: number;
}

/**
 * Verify an EIP-712 signature and return the recovered signer address.
 * Throws if signature is invalid.
 */
export function verifyBidSignature(
  message: BidMessage,
  signature: string
): string {
  const domain = getDomain();

  const value = {
    auctionId: message.auctionId,
    bidder: message.bidder,
    amount: message.amount,
    nonce: message.nonce,
  };

  const recoveredAddress = ethers.verifyTypedData(
    domain,
    BID_TYPES,
    value,
    signature
  );

  return recoveredAddress;
}

/**
 * Compute a bid hash from the bid parameters.
 * This hash is what gets stored on-chain via registerBid().
 */
export function computeBidHash(message: BidMessage): string {
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["bytes32", "address", "uint256", "uint256"],
      [message.auctionId, message.bidder, message.amount, message.nonce]
    )
  );
}
