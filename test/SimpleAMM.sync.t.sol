// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SimpleAMM} from "../src/SimpleAMM.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice sync() sets the reserves to the pool's real balances, so tokens sent straight to the pool
///         become part of the LPs' shares instead of sitting outside the books.
contract SimpleAMMSyncTest is Test {
    event Sync(uint256 reserve0, uint256 reserve1);

    SimpleAMM amm;
    MockERC20 token0;
    MockERC20 token1;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        token0 = new MockERC20("Token A", "TKA");
        token1 = new MockERC20("Token B", "TKB");
        amm = new SimpleAMM(address(token0), address(token1));

        token0.mint(alice, 1_000e18);
        token1.mint(alice, 1_000e18);
        vm.startPrank(alice);
        token0.approve(address(amm), type(uint256).max);
        token1.approve(address(amm), type(uint256).max);
        amm.addLiquidity(100e18, 100e18, 0, 0);
        vm.stopPrank();
    }

    /// @dev After a donation, sync books it: reserves equal balances again and the event reports them.
    function test_sync_booksDonation() public {
        token0.mint(address(amm), 5e18);
        token1.mint(address(amm), 7e18);

        vm.expectEmit(false, false, false, true);
        emit Sync(105e18, 107e18);
        vm.prank(bob);
        amm.sync();

        assertEq(amm.reserve0(), 105e18);
        assertEq(amm.reserve1(), 107e18);
    }

    /// @dev With nothing extra in the pool, sync leaves the reserves as they were.
    function test_sync_nothingExtra_noChange() public {
        amm.sync();
        assertEq(amm.reserve0(), 100e18);
        assertEq(amm.reserve1(), 100e18);
    }

    /// @dev A synced donation belongs to the LPs: Alice's withdrawal includes it, and there's
    ///      nothing left for skim to take.
    function test_sync_donationGoesToLps() public {
        token0.mint(address(amm), 10e18);
        amm.sync();

        (uint256 skimmed0, uint256 skimmed1) = amm.skim(bob);
        assertEq(skimmed0, 0);
        assertEq(skimmed1, 0);

        uint256 liquidity = amm.balanceOf(alice);
        // Alice's pro rata share of all 110, including the donated 10.
        uint256 expected = (liquidity * 110e18) / amm.totalSupply();
        vm.prank(alice);
        (uint256 out0,) = amm.removeLiquidity(liquidity, 0, 0);
        assertEq(out0, expected);
        assertGt(out0, 109e18);
    }

    /// @dev Sync goes through the same oracle update as a trade. The price before the donation is
    ///      folded in for the elapsed time, and the new price only counts from this block on.
    function test_sync_oracleFoldsInOldPriceFirst() public {
        (uint256 cumBefore,) = amm.currentCumulativePrices();
        vm.warp(block.timestamp + 100);

        // Doubling token1 doubles token1 per token0.
        token1.mint(address(amm), 100e18);
        amm.sync();

        // The 100 seconds before the sync were all at price 1.0 (2**112 in UQ112x112).
        assertEq(amm.price0CumulativeLast() - cumBefore, 100 * 2 ** 112);

        vm.warp(block.timestamp + 10);
        (uint256 cumAfter,) = amm.currentCumulativePrices();
        // The next 10 seconds are at the synced price of 2.0.
        assertEq(cumAfter - amm.price0CumulativeLast(), 10 * 2 * 2 ** 112);
    }

    /// @dev For any donation, sync leaves reserves equal to balances.
    function testFuzz_sync_reservesMatchBalances(uint256 amount0, uint256 amount1) public {
        amount0 = bound(amount0, 0, 1e30);
        amount1 = bound(amount1, 0, 1e30);
        token0.mint(address(amm), amount0);
        token1.mint(address(amm), amount1);

        amm.sync();

        assertEq(amm.reserve0(), token0.balanceOf(address(amm)));
        assertEq(amm.reserve1(), token1.balanceOf(address(amm)));
    }
}
