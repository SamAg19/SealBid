
import { ethers } from "ethers";
import * as fs from "fs";

const PRIVATE_KEY = "";
const VERIFYING_CONTRACT = "0xE42Fd40Bf86448595D1EeA64a1B59757609F0C60";
const CHAIN_ID = 11155111;
const AUCTION_ID = "0x0000000000000000000000000000000000000000000000000000000000000001";
const BID_AMOUNT = "2000000"; // 2 USDC (above reserve price of 1 USDC)
const NONCE = 1;

async function main() {
  const wallet = new ethers.Wallet(PRIVATE_KEY);

  const domain = {
    name: "LienFi",
    version: "1",
    chainId: CHAIN_ID,
    verifyingContract: VERIFYING_CONTRACT,
  };

  const types = {
    Bid: [
      { name: "auctionId", type: "bytes32" },
      { name: "bidder", type: "address" },
      { name: "amount", type: "uint256" },
      { name: "nonce", type: "uint256" },
    ],
  };

  const message = {
    auctionId: AUCTION_ID,
    bidder: wallet.address,
    amount: BID_AMOUNT,
    nonce: NONCE,
  };

  const signature = await wallet.signTypedData(domain, types, message);
  const auctionDeadline = Math.floor(Date.now() / 1000) + 3600;

  const payload = {
    auctionId: AUCTION_ID,
    bidder: wallet.address,
    amount: BID_AMOUNT,
    nonce: NONCE,
    signature: signature,
    auctionDeadline: auctionDeadline,
  };

  // Write to file
  fs.writeFileSync("bid-payload.json", JSON.stringify(payload, null, 2));
  console.log("Bid payload written to bid-payload.json");
  console.log(JSON.stringify(payload, null, 2));
}

main().catch(console.error);
