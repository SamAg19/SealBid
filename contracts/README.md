# LienFi Contracts

Smart contracts for the LienFi protocol - a privacy-preserving mortgage system on Ethereum.

## Deployed Addresses (Sepolia)

| Contract | Address |
|----------|---------|
| MockWorldIDRouter | `0xFEc1c2eFbA39ba9e3A05D503F5EE33e4581849B2` |
| MockUSDC | `0x94C63C64FeAB10500d834FaB472B1E50C1ef4213` |
| PropertyNFT | `0xdE9845F5350b6bED6275b201fB836775f543F0C0` |
| clUSDC | `0xD10909520D230243BEDC408CbBAa9F7717513080` |
| LendingPool | `0xA2f23B169478E3AFe1590432D324A78B6CC274c3` |
| LienFiAuction | `0xf96a2282f708f65f3a05EDb8ea2172b6A2E5138d` |
| LoanManager | `0x37A37C8653b7FDF128613D8C05a9c1bBD1aBd98d` |
| Forwarder | `0xf6aC8a8715024fE9Ff592D6A3f186E2B502B356a` |

## Configuration

- Interest Rate: 800 bps (8%)
- Chain ID: 11155111 (Sepolia)

## Usage

### Build

```shell
forge build
```

### Test

```shell
forge test
```

### Deploy

```shell
source .env && forge script script/DeployLienFi.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast
```

## Environment Variables

Create a `.env` file with:

```env
PRIVATE_KEY=0x...
SEPOLIA_RPC_URL=https://...
WORLD_ID_APP_ID=app_staging_test
CHAINLINK_FORWARDER_ADDRESS=0x...  # Optional, defaults to deployer
INTEREST_RATE_BPS=800              # Optional, defaults to 800

# Deployed Contract Addresses (Sepolia)
MOCK_WORLD_ID_ADDRESS=0xFEc1c2eFbA39ba9e3A05D503F5EE33e4581849B2
MOCK_USDC_ADDRESS=0x94C63C64FeAB10500d834FaB472B1E50C1ef4213
PROPERTY_NFT_ADDRESS=0xdE9845F5350b6bED6275b201fB836775f543F0C0
CL_USDC_ADDRESS=0xD10909520D230243BEDC408CbBAa9F7717513080
LENDING_POOL_ADDRESS=0xA2f23B169478E3AFe1590432D324A78B6CC274c3
LIENFI_AUCTION_ADDRESS=0xf96a2282f708f65f3a05EDb8ea2172b6A2E5138d
LOAN_MANAGER_ADDRESS=0x37A37C8653b7FDF128613D8C05a9c1bBD1aBd98d
FORWARDER_ADDRESS=0xf6aC8a8715024fE9Ff592D6A3f186E2B502B356a
INTEREST_RATE_BPS=800
```
