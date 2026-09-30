// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SimpleAMM} from "../../src/SimpleAMM.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {SimpleAMMHandler} from "./SimpleAMMHandler.sol";

/// @notice Stateful invariant tests. Foundry calls random sequences of handler functions
///         (add, remove, swap by different actors) and checks every invariant after each call.
contract SimpleAMMInvariantTest is Test {
    SimpleAMM amm;
    MockERC20 token0;
    MockERC20 token1;
    SimpleAMMHandler handler;

    function setUp() public {
        token0 = new MockERC20("Token A", "TKA");
        token1 = new MockERC20("Token B", "TKB");
        amm = new SimpleAMM(address(token0), address(token1));

        // Seed the pool so every sequence starts from a live market, not an empty one.
        address seeder = makeAddr("seeder");
        token0.mint(seeder, 1_000e18);
        token1.mint(seeder, 4_000e18);
        vm.startPrank(seeder);
        token0.approve(address(amm), type(uint256).max);
        token1.approve(address(amm), type(uint256).max);
        amm.addLiquidity(1_000e18, 4_000e18, 0, 0);
        vm.stopPrank();

        handler = new SimpleAMMHandler(amm, token0, token1);
        targetContract(address(handler));
    }

    /// @notice The stored reserves are exactly what the pool holds. Nothing is lost or created.
    function invariant_reservesMatchBalances() public view {
        assertEq(amm.reserve0(), token0.balanceOf(address(amm)));
        assertEq(amm.reserve1(), token1.balanceOf(address(amm)));
    }

    /// @notice k never goes down on a swap, because the fee stays in the pool.
    function invariant_kNeverDecreasesOnSwap() public view {
        assertFalse(handler.kDecreasedOnSwap());
    }

    /// @notice Pool value per LP share never goes down across any mix of adds, removes and swaps.
    ///         This is the "k never decreases" property, adjusted for liquidity moving in and out.
    function invariant_kPerShareNeverDecreases() public view {
        assertFalse(handler.kPerShareDecreased());
    }

    /// @notice The shares locked on the first deposit keep total supply above zero forever.
    function invariant_supplyNeverBelowMinimum() public view {
        assertGe(amm.totalSupply(), amm.MINIMUM_LIQUIDITY());
    }

    /// @notice Every outstanding LP share is backed: the pool never runs out of either token.
    function invariant_reservesNeverZero() public view {
        assertGt(amm.reserve0(), 0);
        assertGt(amm.reserve1(), 0);
    }

    /// @dev Printed with -vv so you can see the fuzzer actually exercised every path.
    function afterInvariant() external {
        emit log_named_uint("adds", handler.adds());
        emit log_named_uint("removes", handler.removes());
        emit log_named_uint("swaps", handler.swaps());
    }
}
