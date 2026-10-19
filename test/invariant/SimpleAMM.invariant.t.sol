// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SimpleAMM} from "../../src/SimpleAMM.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IMintableERC20} from "../mocks/IMintableERC20.sol";
import {SimpleAMMHandler} from "./SimpleAMMHandler.sol";

/// @notice Stateful invariant tests. Foundry calls random sequences of handler functions
///         (add, remove, swap, donate, sync, skim by different actors) and checks every invariant
///         after each call.
contract SimpleAMMInvariantTest is Test {
    SimpleAMM amm;
    IMintableERC20 token0;
    IMintableERC20 token1;
    SimpleAMMHandler handler;

    /// @dev Overridden by the fee-on-transfer and rebasing suites to swap in an unusual token0.
    function _deployTokens() internal virtual returns (IMintableERC20, IMintableERC20) {
        return (
            IMintableERC20(address(new MockERC20("Token A", "TKA"))),
            IMintableERC20(address(new MockERC20("Token B", "TKB")))
        );
    }

    /// @dev Overridden by the rebasing suite to add a rebase action.
    function _deployHandler() internal virtual returns (SimpleAMMHandler) {
        return new SimpleAMMHandler(amm, token0, token1);
    }

    function setUp() public {
        (token0, token1) = _deployTokens();
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

        handler = _deployHandler();
        targetContract(address(handler));
    }

    /// @notice The pool always holds at least what it has booked, so every LP share is fully backed.
    /// @dev Not == because anyone can send tokens straight to the pool (the handler's donate), and
    ///      those sit above the reserves until a sync or skim. Booking more than arrived would break this.
    function invariant_reservesNeverExceedBalances() public view virtual {
        assertLe(amm.reserve0(), token0.balanceOf(address(amm)));
        assertLe(amm.reserve1(), token1.balanceOf(address(amm)));
    }

    /// @notice The pool books exactly what it holds, apart from tokens donated since the last
    ///         sync or skim. Catches a pool that books less than it receives (or more than it
    ///         sends), which the <= check above would let through as skimmable surplus.
    function invariant_reservesPlusDonationsEqualBalances() public view virtual {
        assertEq(amm.reserve0() + handler.donated0(), token0.balanceOf(address(amm)));
        assertEq(amm.reserve1() + handler.donated1(), token1.balanceOf(address(amm)));
    }

    /// @notice Right after sync(), the reserves equal the balances again.
    function invariant_syncRestoresEquality() public view {
        assertFalse(handler.syncLeftGap());
    }

    /// @notice skim() never moves the reserves, and right after it the balances equal the reserves.
    function invariant_skimLeavesReservesUnchanged() public view {
        assertFalse(handler.skimChangedReserves());
        assertFalse(handler.skimLeftGap());
    }

    /// @notice k never goes down on a swap, because the fee stays in the pool.
    function invariant_kNeverDecreasesOnSwap() public view {
        assertFalse(handler.kDecreasedOnSwap());
    }

    /// @notice Pool value per LP share never goes down across any mix of adds, removes, swaps,
    ///         donations, syncs and skims.
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
    function afterInvariant() public virtual {
        emit log_named_uint("adds", handler.adds());
        emit log_named_uint("removes", handler.removes());
        emit log_named_uint("swaps", handler.swaps());
        emit log_named_uint("donations", handler.donations());
        emit log_named_uint("syncs", handler.syncs());
        emit log_named_uint("skims", handler.skims());
    }
}
