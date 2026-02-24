// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MockWorldIDRouter} from "../src/mocks/MockWorldIDRouter.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {SealBidAuction} from "../src/SealBidAuction.sol";
import {IWorldID} from "../src/interfaces/IWorldID.sol";

contract DeploySealBid is Script {
    function run()
        external
        returns (
            MockWorldIDRouter,
            MockUSDC,
            SealBidAuction
        )
    {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        string memory appId = vm.envString("WORLD_ID_APP_ID");

        vm.startBroadcast(deployerKey);

        // 1. Deploy MockWorldIDRouter
        MockWorldIDRouter mockWorldId = new MockWorldIDRouter();
        console.log("MockWorldIDRouter deployed:", address(mockWorldId));

        // 2. Deploy MockUSDC
        MockUSDC mockUsdc = new MockUSDC();
        console.log("MockUSDC deployed:", address(mockUsdc));

        // 3. Deploy SealBidAuction
        // Property share tokens are deployed on-demand via the CRE create-auction workflow.
        // No global RWA token needed at deploy time.
        address forwarderAddress = vm.envOr("CHAINLINK_FORWARDER_ADDRESS", msg.sender);
        SealBidAuction auction = new SealBidAuction(
            forwarderAddress,
            address(mockUsdc),
            IWorldID(address(mockWorldId)),
            appId,
            "deposit_to_pool"
        );
        console.log("SealBidAuction deployed:", address(auction));

        vm.stopBroadcast();

        return (mockWorldId, mockUsdc, auction);
    }
}
