import { ethers } from "ethers";

// Minimal ABI fragments — only the mappings we need to read
const CONTRACT_ABI = [
  "function poolBalance(address, address) view returns (uint256)",
  "function lockExpiry(address) view returns (uint256)",
  "function auctions(bytes32) view returns (address seller, address token, uint256 deadline, uint256 reservePrice, bool settled, address winner, uint256 settledPrice)",
];

function getContract(): ethers.Contract {
  const provider = new ethers.JsonRpcProvider(
    process.env.RPC_URL || "https://rpc.sepolia.org"
  );
  const contractAddress =
    process.env.VERIFYING_CONTRACT || ethers.ZeroAddress;
  return new ethers.Contract(contractAddress, CONTRACT_ABI, provider);
}

export async function getPoolBalance(
  bidder: string,
  token: string
): Promise<bigint> {
  const contract = getContract();
  return contract.poolBalance(bidder, token) as Promise<bigint>;
}

export async function getLockExpiry(bidder: string): Promise<bigint> {
  const contract = getContract();
  return contract.lockExpiry(bidder) as Promise<bigint>;
}

export interface AuctionOnChain {
  seller: string;
  token: string;
  deadline: bigint;
  reservePrice: bigint;
  settled: boolean;
  winner: string;
  settledPrice: bigint;
}

export async function getAuctionOnChain(
  auctionId: string
): Promise<AuctionOnChain> {
  const contract = getContract();
  const result = await contract.auctions(auctionId);
  return {
    seller: result[0],
    token: result[1],
    deadline: result[2],
    reservePrice: result[3],
    settled: result[4],
    winner: result[5],
    settledPrice: result[6],
  };
}
