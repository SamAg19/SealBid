# Testing the CRE Bid Workflow

This guide walks through the steps to test the bid workflow end-to-end.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- [CRE CLI](https://docs.chain.link/cre/getting-started/cli-installation) installed
- [Bun](https://bun.sh/) or Node.js installed
- Sepolia ETH for gas

## Step 1: Deploy Contracts

```bash
cd contracts
source .env
forge script script/DeployLienFi.s.sol:DeployLienFi --rpc-url "$SEPOLIA_RPC_URL" --broadcast
```

Note the deployed addresses from the output:
- `MOCK_USDC_ADDRESS`
- `LIENFI_AUCTION_ADDRESS`

## Step 2: Update Contract Addresses

Update the new `LienFiAuction` address in the following files:

| File | Field |
|------|-------|
| `api/.env` | `VERIFYING_CONTRACT` |
| `cre-workflows/bid-workflow/config.staging.json` | `contractAddress` |
| `cre-workflows/generate-bid-payload.ts` | `VERIFYING_CONTRACT` |
| **Render dashboard** (or your server host) | `VERIFYING_CONTRACT` env var |

## Step 3: Deploy/Start the API Server

The API server must be running for the workflow to submit bids.

**Local development:**
```bash
cd api
npm install
npm run dev
```

**Production (Render):**
Ensure the server is deployed and environment variables are updated.

## Step 4: Setup On-Chain State

Run these commands to create an auction and fund the bidder:

```bash
# Set environment variables
export RPC_URL="<your-sepolia-rpc-url>"
export PK="<your-private-key>"
export MOCK_USDC="<MockUSDC-address>"
export AUCTION="<LienFiAuction-address>"
export BIDDER="<your-wallet-address>"
export AUCTION_ID=0x0000000000000000000000000000000000000000000000000000000000000001
export DEADLINE=$(($(date +%s) + 3600))

# 1. Create auction (1 hour deadline, 1 USDC reserve price)
cast send $AUCTION "createAuction(bytes32,address,uint256,uint256)" \
  $AUCTION_ID $MOCK_USDC $DEADLINE 1000000 \
  --rpc-url $RPC_URL --private-key $PK

# 2. Mint 100 USDC to bidder
cast send $MOCK_USDC "mint(address,uint256)" $BIDDER 100000000 \
  --rpc-url $RPC_URL --private-key $PK

# 3. Approve USDC spending
cast send $MOCK_USDC "approve(address,uint256)" $AUCTION 100000000 \
  --rpc-url $RPC_URL --private-key $PK

# 4. Deposit to pool (with mock World ID proof)
export LOCK_UNTIL=$(($(date +%s) + 7200))
cast send $AUCTION "depositToPool(address,uint256,uint256,uint256,uint256,uint256[8])" \
  $MOCK_USDC $LOCK_UNTIL 100000000 1 1 "[1,1,1,1,1,1,1,1]" \
  --rpc-url $RPC_URL --private-key $PK
```

## Step 5: Install CRE Workflow Dependencies

```bash
cd cre-workflows/bid-workflow
bun install
```

This runs `bun x cre-setup` automatically via postinstall, which sets up the Javy compiler.

## Step 6: Generate Signed Bid Payload

A script is already created at `cre-workflows/generate-bid-payload.ts`.

Before running, ensure these values are correct in the script:
- `PRIVATE_KEY` - Your wallet private key
- `VERIFYING_CONTRACT` - The LienFiAuction address
- `AUCTION_ID` - The auction you created
- `BID_AMOUNT` - Must be >= reserve price (1000000 for 1 USDC)
- `NONCE` - Unique per bid (increment if retesting)

Generate the payload:
```bash
cd cre-workflows
npx tsx generate-bid-payload.ts
```

This creates `bid-payload.json` with the signed EIP-712 bid.

## Step 7: Run CRE Workflow Simulation

```bash
cd cre-workflows
cre workflow simulate ./bid-workflow \
  --target staging-settings \
  --http-payload @bid-payload.json \
  --non-interactive \
  --trigger-index 0
```

## Expected Output

```
Initializing...
Checking RPC connectivity...
Compiling workflow...
✓ Workflow compiled

[SIMULATION] Running trigger trigger=http-trigger@1.0.0-alpha
[USER LOG] Bid accepted: 0xa8ff02d13193758528af54815c62fd1d42e8172dd8fd07dd8ed4c3b7e9d855b8
[USER LOG] registerBid submitted: 0x0000000000000000000000000000000000000000000000000000000000000000

✓ Workflow Simulation Result: "0x..."
```

> Note: The tx hash is all zeros in simulation mode. Use `--broadcast` when deploying to the real CRE DON.

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `Bid API failed: 400` | API validation failed | Check API logs or test API directly with curl |
| `Insufficient pool balance` | Bidder hasn't deposited | Run Step 4 (deposit to pool) |
| `Duplicate bid from this bidder` | Already submitted a bid | Use a different nonce or create new auction |
| `Auction not found on-chain` | Auction doesn't exist | Run Step 4 (create auction) |
| `Lock expires before auction deadline` | Lock too short | Increase `LOCK_UNTIL` value |
| `AuctionAlreadyExists` | Active auction exists | Settle current auction or redeploy contracts |

## Testing API Directly (Optional)

You can test the API without CRE simulation:

```bash
curl -X POST https://lienfi.onrender.com/bid \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: <your-BID_API_KEY>" \
  -d @bid-payload.json
```

Expected response:
```json
{
  "auctionId": "0x...",
  "bidHash": "0x..."
}
```

## File Reference

| File | Purpose |
|------|---------|
| `contracts/script/DeployLienFi.s.sol` | Contract deployment script |
| `api/.env` | API environment variables |
| `cre-workflows/.env` | CRE CLI environment variables |
| `cre-workflows/secrets.yaml` | CRE vault secrets mapping |
| `cre-workflows/bid-workflow/config.staging.json` | Workflow config (API URL, contract address) |
| `cre-workflows/bid-workflow/main.ts` | Bid workflow implementation |
| `cre-workflows/bid-workflow/workflow.yaml` | Workflow settings |
| `cre-workflows/generate-bid-payload.ts` | Script to generate signed bid payload |
