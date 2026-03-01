// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MockWorldIDRouter} from "../src/mocks/MockWorldIDRouter.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {PropertyNFT} from "../src/PropertyNFT.sol";
import {clUSDC} from "../src/clUSDC.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {LienFiAuction} from "../src/LienFiAuction.sol";
import {LoanManager} from "../src/LoanManager.sol";
import {IWorldID} from "../src/interfaces/IWorldID.sol";

/**
 * @title DeployLienFi
 * @author LienFi Team
 *
 * Deploys the complete LienFi protocol to Sepolia with mock dependencies.
 *
 * Deployment order (respects constructor dependencies):
 *   1. MockWorldIDRouter  — no deps
 *   2. MockUSDC           — no deps
 *   3. PropertyNFT        — no deps
 *   4. clUSDC             — no deps
 *   5. LendingPool        — needs: MockUSDC, clUSDC
 *   6. LienFiAuction      — needs: forwarder, MockUSDC, PropertyNFT, WorldID
 *   7. LoanManager        — needs: forwarder, LendingPool, PropertyNFT, LienFiAuction, MockUSDC
 *
 * Post-deploy wiring:
 *   - clUSDC.setMinter(LendingPool)              → only pool can mint/burn receipt tokens
 *   - LendingPool.setLoanManager(LoanManager)     → only LoanManager can disburse/repayEMI
 *   - PropertyNFT.setMinter(LoanManager)           → only LoanManager can mint property NFTs
 *
 * Required .env:
 *   PRIVATE_KEY=0x...
 *   WORLD_ID_APP_ID=app_staging_test   (any string for MockWorldIDRouter)
 *
 * Optional .env:
 *   CHAINLINK_FORWARDER_ADDRESS=0x...  (defaults to deployer if not set)
 *   INTEREST_RATE_BPS=800              (defaults to 800 = 8% if not set)
 *
 * Usage:
 *   source .env && forge script script/DeployLienFi.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast
 */

 contract DeployLienFi is Script {
    function run()
        external
        returns (
            MockWorldIDRouter,
            MockUSDC,
            PropertyNFT,
            clUSDC,
            LendingPool,
            LienFiAuction,
            LoanManager
        )
    {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        string memory appId = vm.envString("WORLD_ID_APP_ID");
        address deployer = vm.addr(deployerKey);
        address forwarderAddress = vm.envOr("CHAINLINK_FORWARDER_ADDRESS", deployer);
        uint256 interestRateBps = vm.envOr("INTEREST_RATE_BPS", uint256(800));

        console.log("=== LienFi Protocol Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Forwarder:", forwarderAddress);
        console.log("Interest Rate (bps):", interestRateBps);
        console.log("World ID App ID:", appId);

        vm.startBroadcast(deployerKey);

        // ═══════════════════════════════════════
        // STEP 1: MOCKS — no dependencies
        // ═══════════════════════════════════════

        MockWorldIDRouter mockWorldId = new MockWorldIDRouter();
        console.log("\n[1/7] MockWorldIDRouter:", address(mockWorldId));

        MockUSDC mockUsdc = new MockUSDC();
        console.log("[2/7] MockUSDC:", address(mockUsdc));

        // ═══════════════════════════════════════
        // STEP 2: STANDALONE CONTRACTS — no dependencies
        // ═══════════════════════════════════════

        PropertyNFT propertyNFT = new PropertyNFT();
        console.log("[3/7] PropertyNFT:", address(propertyNFT));

        clUSDC receiptToken = new clUSDC();
        console.log("[4/7] clUSDC:", address(receiptToken));

        // ═══════════════════════════════════════
        // STEP 3: LENDING POOL — needs MockUSDC + clUSDC
        // ═══════════════════════════════════════

        LendingPool lendingPool = new LendingPool(
            address(mockUsdc),
            address(receiptToken)
        );
        console.log("[5/7] LendingPool:", address(lendingPool));

        // ═══════════════════════════════════════
        // STEP 4: LIENFI AUCTION — needs forwarder, MockUSDC, PropertyNFT, WorldID
        // ═══════════════════════════════════════

        LienFiAuction lienFiAuction = new LienFiAuction(
            forwarderAddress,
            address(mockUsdc),
            address(propertyNFT),
            IWorldID(address(mockWorldId)),
            appId,
            "deposit_to_pool"
        );
        console.log("[6/7] LienFiAuction:", address(lienFiAuction));

        // ═══════════════════════════════════════
        // STEP 5: LOAN MANAGER — needs everything above
        // ═══════════════════════════════════════

        LoanManager loanManager = new LoanManager(
            forwarderAddress,
            address(lendingPool),
            address(propertyNFT),
            address(lienFiAuction),
            address(mockUsdc),
            interestRateBps
        );
        console.log("[7/7] LoanManager:", address(loanManager));

        // ═══════════════════════════════════════
        // STEP 6: POST-DEPLOY WIRING
        // ═══════════════════════════════════════

        console.log("\n--- Wiring contracts ---");

        // clUSDC: only LendingPool can mint/burn receipt tokens
        receiptToken.setMinter(address(lendingPool));
        console.log("  clUSDC.setMinter -> LendingPool");

        // LendingPool: only LoanManager can call disburse() and repayEMI()
        lendingPool.setLoanManager(address(loanManager));
        console.log("  LendingPool.setLoanManager -> LoanManager");

        // PropertyNFT: only LoanManager can mint new property NFTs
        propertyNFT.setMinter(address(loanManager));
        console.log("  PropertyNFT.setMinter -> LoanManager");

        vm.stopBroadcast();

        // ═══════════════════════════════════════
        // DEPLOYMENT SUMMARY
        // ═══════════════════════════════════════

        console.log("\n=== Deployment Summary ===");
        console.log("MOCK_WORLD_ID_ADDRESS=%s", address(mockWorldId));
        console.log("MOCK_USDC_ADDRESS=%s", address(mockUsdc));
        console.log("PROPERTY_NFT_ADDRESS=%s", address(propertyNFT));
        console.log("CL_USDC_ADDRESS=%s", address(receiptToken));
        console.log("LENDING_POOL_ADDRESS=%s", address(lendingPool));
        console.log("LIENFI_AUCTION_ADDRESS=%s", address(lienFiAuction));
        console.log("LOAN_MANAGER_ADDRESS=%s", address(loanManager));
        console.log("FORWARDER_ADDRESS=%s", forwarderAddress);
        console.log("INTEREST_RATE_BPS=%s", interestRateBps);
        console.log("==========================\n");

        return (
            mockWorldId,
            mockUsdc,
            propertyNFT,
            receiptToken,
            lendingPool,
            lienFiAuction,
            loanManager
        );
    }
}
