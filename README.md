<p align="center">
  <img src="./assets/banner.png" alt="SealBid Banner" width="100%" />
</p>

<h1 align="center">🔒 SealBid</h1>
<p align="center"><i>Privacy-Preserving Sealed-Bid Auctions for Real World Assets</i></p>

<p align="center">
  A sealed-bid Vickrey auction system where bid amounts, bidder identities, and losing bids are never exposed on-chain — powered by Chainlink CRE confidential compute, World ID sybil resistance, and a multi-token deposit pool.
</p>

<p align="center">
  <a href="#"><img src="https://img.shields.io/badge/Built%20with-Chainlink%20CRE-375BD2?style=for-the-badge&logo=chainlink&logoColor=white" /></a>
  <a href="#"><img src="https://img.shields.io/badge/Identity-World%20ID-000000?style=for-the-badge&logo=data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMjQiIGhlaWdodD0iMjQiIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj48Y2lyY2xlIGN4PSIxMiIgY3k9IjEyIiByPSIxMCIgc3Ryb2tlPSJ3aGl0ZSIgc3Ryb2tlLXdpZHRoPSIyIi8+PC9zdmc+&logoColor=white" /></a>
  <a href="#"><img src="https://img.shields.io/badge/Network-Sepolia-6C5CE7?style=for-the-badge&logo=ethereum&logoColor=white" /></a>
  <a href="#"><img src="https://img.shields.io/badge/Hackathon-Chainlink%20Convergence-blue?style=for-the-badge" /></a>
</p>

<p align="center">
  <a href="#-the-problem">Problem</a> •
  <a href="#-how-sealbid-works">Solution</a> •
  <a href="#-architecture">Architecture</a> •
  <a href="#-privacy-guarantees">Privacy</a> •
  <a href="#-smart-contracts">Contracts</a> •
  <a href="#-chainlink-services-used">Chainlink</a> •
  <a href="#-quick-start">Quick Start</a> •
  <a href="#-demo">Demo</a>
</p>

---

## 🎯 The Problem

Traditional on-chain auctions are fundamentally broken for high-value assets:

- **Bid amounts are public** — competitors see what you're willing to pay and snipe accordingly
- **Bidder identities are exposed** — your wallet address links you to every bid you've ever made
- **Losing bidders are visible** — even if you lose, everyone knows you tried to buy
- **Sybil attacks** — a single entity can create hundreds of wallets to manipulate auctions
- **No RWA support** — tokenized real-world assets need compliance-gated participation

For Real World Assets worth millions, this isn't just inconvenient — it's a dealbreaker.

## ✨ How SealBid Works

SealBid implements a **Vickrey (second-price) sealed-bid auction** where the highest bidder wins but pays only the second-highest price. The entire bid collection and settlement process runs inside Chainlink CRE's confidential compute environment.

> *"Deposit tokens. Place your bid. Nobody sees it. The best price wins."*

### Key Features

- **🔐 Sealed Bids** — Bid amounts exist only inside the CRE enclave. On-chain, only opaque bid hashes appear.
- **🌐 World ID Sybil Resistance** — Real on-chain ZK proof verification. One human, one deposit. No fake accounts.
- **💰 Multi-Token Support** — Deposit SRWA (compliance-gated RWA tokens) or USDC. Each auction specifies its settlement token.
- **🕵️ Auction-Blind Pool** — Deposits carry no auction reference. Observers see "address deposited tokens, locked until timestamp" — not which auction.
- **🏆 Vickrey Pricing** — Winner pays the second-highest bid, incentivizing truthful bidding.
- **👻 Losing Bidders Stay Hidden** — Never linked to any auction on-chain. Withdraw after lock expires, no trace.
- **🔑 Encrypted Settlement** — API responses are AES-GCM encrypted before leaving the enclave.

---

## 🏗️ Architecture

```
               Frontend (built after sprint)
               │
               │  IDKit generates World ID ZK proof
               │  User signs EIP-712 bid
               │
┌──────────────┼──────────────────────────────────────┐
│              ▼                                      │
│   CRE Workflow 0 (HTTP Trigger)                     │
│   "Mint RWA Tokens"                                 │
│     → EVM Write: mintRWATokens(                     │
│         user, amount, root,                         │
│         nullifierHash, proof)                       │
│     → Contract verifies World ID on-chain           │
│     → Mints SRWA tokens to user                     │
│                                                     │
│   CRE Workflow 1 (HTTP Trigger)                     │
│   "Bid Collection"                                  │
│     → EVM Read: canBid(bidder, auctionId)           │
│     → Confidential HTTP: POST /bid                  │
│       (API key injected in enclave)                 │
│     → EVM Write: registerBid(auctionId, bidHash)    │
│                                                     │
│   CRE Workflow 2 (Cron Trigger)                     │
│   "Settlement"                                      │
│     → Confidential HTTP: POST /settle               │
│       (encryptOutput: true, AES-GCM)               │
│     → EVM Write: settleAuction(                     │
│         auctionId, winner, price, proof)            │
│                                                     │
└──────────────┬──────────────────────────────────────┘
               │
┌──────────────┼──────────────────────────────────────┐
│              ▼                                      │
│   SealBidAuction.sol (Sepolia)                      │
│                                                     │
│   MULTI-TOKEN DEPOSIT POOL:                         │
│     SRWA (18 dec): 100e18 escrow                    │
│     USDC (6 dec): 100e6 escrow                      │
│     Per-token tracking, extensible                  │
│                                                     │
│   WORLD ID (on-chain ZK verification):              │
│     Two actions: "mint_rwa" + "deposit_to_pool"     │
│     Nullifier tracking for sybil resistance         │
│                                                     │
│   AUCTION LIFECYCLE:                                │
│     createAuction → registerBid → settleAuction     │
│     Each auction specifies its settlement token     │
│                                                     │
│   SealBidRWAToken.sol (ERC-20, restricted mint)     │
│   MockWorldIDRouter.sol (testing)                   │
│   MockUSDC.sol (testing, 6 decimals)                │
│                                                     │
└─────────────────────────────────────────────────────┘
               │
┌──────────────┼──────────────────────────────────────┐
│              ▼                                      │
│   Private Bid / Settlement API (Express)            │
│     POST /bid    — validate EIP-712, store bid      │
│     POST /settle — run Vickrey, return result       │
│     GET  /status — bid count, deadline, settled     │
│                                                     │
│   Called only via Confidential HTTP from CRE.       │
│   API key decrypted in enclave, never exposed.      │
│   Settlement response AES-GCM encrypted.            │
└─────────────────────────────────────────────────────┘
```

---

## 🔒 Privacy Guarantees

| Phase | What's Visible On-Chain | What's Hidden |
|-------|------------------------|---------------|
| **Deposit** | "Address deposited tokens, locked until timestamp" | Which auction the deposit is for |
| **During Auction** | Opaque bid hashes only | Bid amounts, bidder addresses |
| **Settlement** | Winner address + Vickrey price | All losing bids and bidders |
| **Post-Auction** | Losers withdraw tokens | No link between losers and any auction |

**Additional privacy layers:**
- Multi-token obfuscation — observers can't tell if a USDC deposit is for an SRWA auction or vice versa
- API credentials decrypted only inside CRE enclave
- Settlement responses AES-GCM encrypted before leaving enclave
- World ID ZK proofs — identity verified without revealing who you are

---

## ⛓️ Smart Contracts

### Deployed Contracts (Sepolia)

| Contract | Address | Purpose |
|----------|---------|---------|
| **MockWorldIDRouter** | `0xa35b312c8382cf9b3cf25ebf22671b33ef3c0e45` | Mock World ID verification for testing |
| **MockUSDC** | `0x36c8ed6334bfd268225cfa6992efb2d2ff3046dc` | Mock USDC token (6 decimals) for testing |
| **SealBidRWAToken** | `0xe8e4cd653a1b9ab7b5be20ded376ca3f8da258eb` | ERC-20 RWA token, restricted minting |
| **SealBidAuction** | `0x9e2a38c2544671c3cb950096dd24f1a0d80a270b` | Core auction contract — pool, World ID, lifecycle |

### Contract Overview

**SealBidAuction.sol** — The core contract combining:
- Multi-token deposit pool (SRWA + USDC, extensible)
- World ID on-chain ZK proof verification (two actions: mint + deposit)
- Forwarder-gated auction lifecycle (bid registration + settlement via CRE)
- Vickrey settlement with per-token accounting

**SealBidRWAToken.sol** — Minimal ERC-20 with restricted minting:
- Only the auction contract (as minter) can mint tokens
- World ID gated via CRE Workflow 0
- Users with existing USDC skip this entirely



---

## 🔗 Chainlink Services Used

| Service | Usage | Workflow |
|---------|-------|----------|
| **CRE Workflow Engine** | 3 workflows orchestrating the entire auction lifecycle | All |
| **Confidential HTTP** | Bid submission + settlement via private API, API key injected in enclave | WF 1, WF 2 |
| **Vault DON Secrets** | API keys and AES encryption keys stored securely | WF 1, WF 2 |
| **Encrypted Output** | AES-GCM encryption of settlement results before leaving enclave | WF 2 |

---

## 🛠️ Tech Stack

| Layer | Technology | Purpose |
|-------|-----------|---------|
| **Smart Contracts** | Solidity 0.8.24 + Foundry | SealBidAuction, SealBidRWAToken, mocks |
| **Contract Framework** | OpenZeppelin | ERC-20, Ownable, ReentrancyGuard |
| **Identity** | World ID (Worldcoin) | On-chain ZK proof verification, sybil resistance |
| **Confidential Compute** | Chainlink CRE | 3 workflows — mint, bid, settle |
| **Network** | Sepolia (Tenderly fork) | Testing and demo deployment |
| **Private API** | Express.js + TypeScript | Bid storage, EIP-712 verification, Vickrey logic |
| **Signature Standard** | EIP-712 | Typed structured data for bid signing |
| **Encryption** | AES-GCM | Settlement response encryption in enclave |

---

## 🚀 Quick Start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`foundryup`)
- Node.js 20+
- Sepolia ETH for gas

### Installation

```bash
# Clone the repository
git clone https://github.com/yourusername/sealbid.git
cd sealbid

# ─── Smart Contracts ───────────────────────────────────────────────
cd contracts

# Install dependencies
forge install

# Configure environment
cp .env.example .env
# Add PRIVATE_KEY and WORLD_ID_APP_ID

# Deploy all contracts (MockWorldIDRouter → MockUSDC → SealBidRWAToken → SealBidAuction)
source .env
forge script script/DeploySealBid.s.sol --fork-url $SEPOLIA_RPC_URL --broadcast

# Run tests
forge test -vvv

# ─── Private API ───────────────────────────────────────────────────
cd ../api
npm install
cp .env.example .env
# Add BID_API_KEY, AES_KEY, deployed contract addresses
npm run dev

# ─── CRE Workflows ────────────────────────────────────────────────
cd ../sealbid
# Install CRE CLI and configure workflows
# See CRE Workflow section in docs
```

### Environment Variables

```env
# ─── Deployer ──────────────────────────────────────────────────────
PRIVATE_KEY=0x...
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY

# ─── World ID ──────────────────────────────────────────────────────
WORLD_ID_APP_ID=app_staging_...

# ─── Shared Secrets (generated with openssl rand -hex 32) ──────────
BID_API_KEY=...
AES_KEY=...

# ─── Deployed Contracts (populated after deployment) ───────────────
MOCK_WORLD_ID_ROUTER=
MOCK_USDC=
SRWA_TOKEN=
SEAL_BID_AUCTION=
```

---

## 🧪 Testing

### Forge Tests (40 tests)

```bash
cd contracts
forge test -vvv
```

**Test Coverage:**

| Category | Tests | Description |
|----------|-------|-------------|
| World ID + RWA Minting | 3 | Mint, non-forwarder revert, nullifier reuse |
| Multi-Token Deposit Pool | 20 | SRWA/USDC deposits, locks, withdrawals, canBid |
| Auction Lifecycle | 13 | Create, register bid, settle — both token types |
| Full Integration | 4 | End-to-end flows, mixed token scenarios |

---


## 📁 Project Structure

```
sealbid/
├── contracts/                        # Solidity smart contracts (Foundry)
│   ├── src/
│   │   ├── SealBidAuction.sol        # Core: pool + World ID + auction lifecycle
│   │   ├── SealBidRWAToken.sol       # ERC-20 RWA token, restricted mint
│   │   ├── interfaces/
│   │   │   ├── IWorldID.sol          # World ID router interface
│   │   │   └── ISealBidRWAToken.sol  # RWA token mint interface
│   │   ├── libraries/
│   │   │   └── ByteHasher.sol        # World ID field hashing
│   │   └── mocks/
│   │       ├── MockWorldIDRouter.sol  # Always-pass World ID mock
│   │       └── MockUSDC.sol          # 6-decimal test USDC
│   ├── script/
│   │   └── DeploySealBid.s.sol       # Full deployment script
│   ├── test/
│   │   └── SealBidAuction.t.sol      # 40 Forge tests
│   └── foundry.toml
├── api/                              # Private bid/settlement API
│   ├── src/
│   │   ├── server.ts
│   │   ├── routes/
│   │   │   ├── bid.ts               # POST /bid — EIP-712 validation
│   │   │   ├── settle.ts            # POST /settle — Vickrey logic
│   │   │   └── status.ts            # GET /status/:auctionId
│   │   └── lib/
│   │       ├── store.ts             # In-memory bid storage
│   │       ├── eip712.ts            # Signature verification
│   │       ├── auth.ts              # API key middleware
│   │       └── vickrey.ts           # Second-price auction logic
│   └── package.json
├── sealbid/                          # CRE Workflows
│   ├── project.yaml
│   ├── secrets.yaml
│   ├── mint-workflow/                # Workflow 0: RWA Token Minting
│   ├── bid-workflow/                 # Workflow 1: Bid Collection
│   └── settlement-workflow/          # Workflow 2: Settlement
├── assets/                           # Logo, banner, diagrams
└── README.md
```

---

## 🎥 Demo

> 📺 **Video Walkthrough:** [Coming Soon](#)
>
> 🔗 **Tenderly Contracts:** [Coming Soon](#)
>
> 🌐 **Deployed API:** [Coming Soon](#)

---

## 👥 Team

Built by the **SealBid Team** for the Chainlink CRE Hackathon.

---

## 📄 License

MIT License — see [LICENSE](./LICENSE) for details.

---

<p align="center">
  <img src="./assets/logo.png" alt="SealBid Logo" width="80" />
</p>

<p align="center">
  <i>Built for the Chainlink Convergence Hackathon 2026</i><br/>
  <i>Powered by <a href="https://chain.link">Chainlink CRE</a> · Verified by <a href="https://worldcoin.org">World ID</a> · Deployed on <a href="https://sepolia.etherscan.io">Sepolia</a></i>
</p>