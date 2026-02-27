// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {clUSDC} from "../src/clUSDC.sol";

contract clUSDCTest is Test {
    clUSDC public token;
    address public owner = makeAddr("owner");
    address public minter = makeAddr("minter");
    address public user = makeAddr("user");

    function setUp() public {
        vm.prank(owner);
        token = new clUSDC();
        vm.prank(owner);
        token.setMinter(minter);
    }

    function test_Name() public view {
        assertEq(token.name(), "LienFi Collateral USDC");
    }

    function test_Symbol() public view {
        assertEq(token.symbol(), "clUSDC");
    }

    function test_Decimals() public view {
        assertEq(token.decimals(), 6);
    }

    function test_MinterCanMint() public {
        vm.prank(minter);
        token.mint(user, 1_000e6);
        assertEq(token.balanceOf(user), 1_000e6);
    }

    function test_MinterCanBurn() public {
        vm.prank(minter);
        token.mint(user, 1_000e6);

        vm.prank(minter);
        token.burn(user, 500e6);
        assertEq(token.balanceOf(user), 500e6);
    }

    function test_NonMinterCannotMint() public {
        vm.prank(user);
        vm.expectRevert(clUSDC.clUSDC__NotMinter.selector);
        token.mint(user, 1_000e6);
    }

    function test_NonMinterCannotBurn() public {
        vm.prank(minter);
        token.mint(user, 1_000e6);

        vm.prank(user);
        vm.expectRevert(clUSDC.clUSDC__NotMinter.selector);
        token.burn(user, 500e6);
    }

    function test_SetMinterOnlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        token.setMinter(user);
    }

    function test_SetMinterZeroAddressReverts() public {
        // Deploy fresh token
        vm.prank(owner);
        clUSDC freshToken = new clUSDC();

        vm.prank(owner);
        vm.expectRevert(clUSDC.clUSDC__ZeroAddress.selector);
        freshToken.setMinter(address(0));
    }

    function test_SetMinterEmitsEvent() public {
        vm.prank(owner);
        clUSDC freshToken = new clUSDC();

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit clUSDC.MinterUpdated(address(0), minter);
        freshToken.setMinter(minter);
    }
}
