// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SimpleAMM} from "../src/SimpleAMM.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {DeploySimpleAMM} from "../script/DeploySimpleAMM.s.sol";

/// @notice Runs the deploy script locally, so a broken script fails CI before it costs Sepolia gas.
contract DeploySimpleAMMTest is Test {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address deployer = makeAddr("deployer");

    SimpleAMM amm;
    MockERC20 tokenA;
    MockERC20 tokenB;
    uint256 seed;

    function setUp() public {
        DeploySimpleAMM script = new DeploySimpleAMM();
        seed = script.SEED_AMOUNT();
        (amm, tokenA, tokenB) = script.deploy(deployer);
    }

    function test_Deploy_WiresTokensIntoPool() public view {
        assertEq(address(amm.token0()), address(tokenA));
        assertEq(address(amm.token1()), address(tokenB));
    }

    function test_Deploy_SeedsReservesAndLocksMinimumLiquidity() public view {
        assertEq(amm.reserve0(), seed);
        assertEq(amm.reserve1(), seed);
        assertEq(tokenA.balanceOf(address(amm)), seed);
        assertEq(tokenB.balanceOf(address(amm)), seed);

        // First deposit mints sqrt(seed * seed) = seed shares, minus the locked minimum.
        assertEq(amm.balanceOf(deployer), seed - amm.MINIMUM_LIQUIDITY());
        assertEq(amm.balanceOf(DEAD), amm.MINIMUM_LIQUIDITY());
    }

    function test_Deploy_PoolIsSwappableRightAway() public {
        address trader = makeAddr("trader");
        tokenA.mint(trader, 10e18);

        vm.startPrank(trader);
        tokenA.approve(address(amm), 10e18);
        uint256 out = amm.swap(address(tokenA), 10e18, 1);
        vm.stopPrank();

        assertGt(out, 0);
        assertEq(tokenB.balanceOf(trader), out);
    }
}
