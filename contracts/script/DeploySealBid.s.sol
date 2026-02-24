// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MockWorldIDRouter} from "../src/mocks/MockWorldIDRouter.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {SealBidRWAToken} from "../src/SealBidRWAToken.sol";
import {SealBidAuction} from "../src/SealBidAuction.sol";
import {IWorldID} from "../src/interfaces/IWorldID.sol";

contract DeploySealBid is Script {
    function run()
        external
        returns (
            MockWorldIDRouter,
            MockUSDC,
            SealBidRWAToken,
            SealBidAuction
        )
    {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        string memory appId = vm.envString("WORLD_ID_APP_ID");
        address deployer = vm.addr(deployerKey);

        console.log("=== SealBid Deployment ===");
        console.log("Deployer:", deployer);
        console.log("World ID App ID:", appId);

        vm.startBroadcast(deployerKey);

        // 1. Deploy MockWorldIDRouter
        MockWorldIDRouter mockWorldId = new MockWorldIDRouter();
        console.log("\n[1/4] MockWorldIDRouter deployed:", address(mockWorldId));

        // 2. Deploy MockUSDC
        MockUSDC mockUsdc = new MockUSDC();
        console.log("[2/4] MockUSDC deployed:", address(mockUsdc));

        // 3. Deploy SealBidRWAToken (deployer as temporary minter)
        SealBidRWAToken rwaToken = new SealBidRWAToken(deployer);
        console.log("[3/4] SealBidRWAToken deployed:", address(rwaToken));

        // 4. Deploy SealBidAuction
        // forwarder: use CHAINLINK_FORWARDER_ADDRESS env var if set, otherwise deployer (for local testing)
        address forwarderAddress = vm.envOr("CHAINLINK_FORWARDER_ADDRESS", deployer);
        console.log("Using forwarder address:", forwarderAddress);

        SealBidAuction auction = new SealBidAuction(
            forwarderAddress,
            address(rwaToken),
            address(mockUsdc),
            IWorldID(address(mockWorldId)),
            appId,
            "deposit_to_pool"
        );
        console.log("[4/4] SealBidAuction deployed:", address(auction));

        // 5. Wire: auction contract becomes the minter for RWA token
        rwaToken.setMinter(address(auction));
        console.log("\nRWAToken minter set to SealBidAuction");

        vm.stopBroadcast();

        // Print summary for easy copy-paste
        console.log("\n=== Deployment Summary ===");
        console.log("MOCK_WORLD_ID_ADDRESS=%s", address(mockWorldId));
        console.log("MOCK_USDC_ADDRESS=%s", address(mockUsdc));
        console.log("SRWA_TOKEN_ADDRESS=%s", address(rwaToken));
        console.log("SEAL_BID_AUCTION_ADDRESS=%s", address(auction));
        console.log("FORWARDER_ADDRESS=%s", forwarderAddress);
        console.log("==========================\n");

        return (mockWorldId, mockUsdc, rwaToken, auction);
    }
}