// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MockWorldIDRouter} from "../src/mocks/MockWorldIDRouter.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {PropertyNFT} from "../src/PropertyNFT.sol";
import {LienFiAuction} from "../src/LienFiAuction.sol";
import {IWorldID} from "../src/interfaces/IWorldID.sol";

contract DeployLienFi is Script {
    function run()
        external
        returns (
            MockWorldIDRouter,
            MockUSDC,
            PropertyNFT,
            LienFiAuction
        )
    {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        string memory appId = vm.envString("WORLD_ID_APP_ID");
        address deployer = vm.addr(deployerKey);

        console.log("=== LienFi Deployment ===");
        console.log("Deployer:", deployer);
        console.log("World ID App ID:", appId);

        vm.startBroadcast(deployerKey);

        // 1. Deploy MockWorldIDRouter
        MockWorldIDRouter mockWorldId = new MockWorldIDRouter();
        console.log("\n[1/4] MockWorldIDRouter deployed:", address(mockWorldId));

        // 2. Deploy MockUSDC
        MockUSDC mockUsdc = new MockUSDC();
        console.log("[2/4] MockUSDC deployed:", address(mockUsdc));

        // 3. Deploy PropertyNFT
        PropertyNFT propertyNFT = new PropertyNFT();
        console.log("[3/4] PropertyNFT deployed:", address(propertyNFT));

        // 4. Deploy LienFiAuction
        address forwarderAddress = vm.envOr("CHAINLINK_FORWARDER_ADDRESS", msg.sender);
        LienFiAuction auction = new LienFiAuction(
            forwarderAddress,
            address(mockUsdc),
            address(propertyNFT),
            IWorldID(address(mockWorldId)),
            appId,
            "deposit_to_pool"
        );
        console.log("[4/4] LienFiAuction deployed:", address(auction));

        vm.stopBroadcast();
        // Print summary for easy copy-paste
        console.log("\n=== Deployment Summary ===");
        console.log("MOCK_WORLD_ID_ADDRESS=%s", address(mockWorldId));
        console.log("MOCK_USDC_ADDRESS=%s", address(mockUsdc));
        console.log("PROPERTY_NFT_ADDRESS=%s", address(propertyNFT));
        console.log("LIENFI_AUCTION_ADDRESS=%s", address(auction));
        console.log("FORWARDER_ADDRESS=%s", forwarderAddress);
        console.log("==========================\n");

        return (mockWorldId, mockUsdc, propertyNFT, auction);
    }
}
