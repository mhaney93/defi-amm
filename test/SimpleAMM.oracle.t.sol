// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SimpleAMM} from "../src/SimpleAMM.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Tests for the TWAP price accumulators: what gets added, when, and why a
///         same-block price spike can't move the average.
contract SimpleAMMOracleTest is Test {
    uint256 constant Q112 = 2 ** 112;

    SimpleAMM amm;
    MockERC20 token0;
    MockERC20 token1;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        token0 = new MockERC20("Token A", "TKA");
        token1 = new MockERC20("Token B", "TKB");
        amm = new SimpleAMM(address(token0), address(token1));

        address[2] memory users = [alice, bob];
        for (uint256 i; i < users.length; i++) {
            token0.mint(users[i], 100e18);
            token1.mint(users[i], 100e18);
            vm.startPrank(users[i]);
            token0.approve(address(amm), type(uint256).max);
            token1.approve(address(amm), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// @dev Alice seeds the pool at 1 token0 : 4 token1, so price0 = 4 and price1 = 0.25.
    function _seed() internal {
        vm.prank(alice);
        amm.addLiquidity(1e18, 4e18, 0, 0);
    }

    function _price0() internal view returns (uint256) {
        return Math.mulDiv(amm.reserve1(), Q112, amm.reserve0());
    }

    function _price1() internal view returns (uint256) {
        return Math.mulDiv(amm.reserve0(), Q112, amm.reserve1());
    }

    function _swap0For1(uint256 amountIn) internal {
        vm.prank(bob);
        amm.swap(address(token0), amountIn, 0);
    }

    // ---------------------------------------------------------------- accumulation

    /// @notice An empty pool has no price, so the first deposit only starts the clock.
    function test_firstDeposit_startsClockWithoutAccumulating() public {
        vm.warp(1000);
        _seed();

        assertEq(amm.blockTimestampLast(), 1000);
        assertEq(amm.price0CumulativeLast(), 0);
        assertEq(amm.price1CumulativeLast(), 0);
    }

    /// @notice Each elapsed second adds the price that held during it.
    function test_update_addsPriceTimesElapsed() public {
        _seed();
        uint256 later = vm.getBlockTimestamp() + 100;
        vm.warp(later);
        _swap0For1(1e15);

        assertEq(amm.price0CumulativeLast(), 4 * Q112 * 100);
        assertEq(amm.price1CumulativeLast(), (Q112 / 4) * 100);
        assertEq(amm.blockTimestampLast(), later);
    }

    /// @notice A second trade in the same block adds nothing: no time has passed.
    function test_sameBlock_secondUpdateAddsNothing() public {
        _seed();
        vm.warp(block.timestamp + 100);
        _swap0For1(1e15);
        uint256 cumulative = amm.price0CumulativeLast();

        _swap0For1(1e15);

        assertEq(amm.price0CumulativeLast(), cumulative);
    }

    /// @notice The view counts the seconds since the last update without a transaction.
    function test_currentCumulativePrices_includesTimeSinceLastUpdate() public {
        _seed();
        vm.warp(block.timestamp + 50);

        (uint256 price0Cumulative, uint256 price1Cumulative) = amm.currentCumulativePrices();

        assertEq(price0Cumulative, 4 * Q112 * 50);
        assertEq(price1Cumulative, (Q112 / 4) * 50);
        assertEq(amm.price0CumulativeLast(), 0); // nothing written yet
    }

    // ---------------------------------------------------------------- TWAP

    /// @notice The average weights each price by how long it lasted: 4.0 for 10s, then the
    ///         post-trade price for 30s.
    function test_twap_weightsEachPriceByDuration() public {
        _seed();
        uint256 start = block.timestamp;

        vm.warp(start + 10);
        _swap0For1(0.5e18);
        uint256 priceAfter = _price0();

        vm.warp(start + 40);
        (uint256 price0Cumulative,) = amm.currentCumulativePrices();

        uint256 twap = price0Cumulative / 40;
        assertEq(twap, (4 * Q112 * 10 + priceAfter * 30) / 40);
        assertLt(priceAfter, 4 * Q112); // selling token0 made it cheaper
    }

    /// @notice A huge swap moves the spot price ~99%, but an hour-long TWAP that ends in the
    ///         same block doesn't move at all, and one second later it has barely moved.
    function test_twap_resistsShortLivedManipulation() public {
        _seed();
        uint256 start = block.timestamp;

        vm.warp(start + 3600);
        _swap0For1(10e18); // dumps 10x the pool's token0 reserve
        assertLt(_price0(), (4 * Q112) / 50); // spot price is now under 1/50th of where it was

        (uint256 sameBlock,) = amm.currentCumulativePrices();
        assertEq(sameBlock / 3600, 4 * Q112);

        vm.warp(start + 3601);
        (uint256 oneSecondLater,) = amm.currentCumulativePrices();
        assertApproxEqRel(oneSecondLater / 3601, 4 * Q112, 0.001e18); // within 0.1%
    }

    // ---------------------------------------------------------------- fuzz

    /// @notice For any pool and any gap, the view adds spot price * seconds, and the next
    ///         trade stores exactly what the view reported.
    function testFuzz_update_storesPriceTimesElapsed(uint256 r0, uint256 r1, uint256 elapsed) public {
        r0 = bound(r0, 1e6, 1e30);
        r1 = bound(r1, 1e6, 1e30);
        elapsed = bound(elapsed, 1, 365 days);

        token0.mint(alice, r0);
        token1.mint(alice, r1);
        vm.prank(alice);
        amm.addLiquidity(r0, r1, 0, 0);

        uint256 expected0 = _price0() * elapsed;
        uint256 expected1 = _price1() * elapsed;

        vm.warp(block.timestamp + elapsed);
        (uint256 view0, uint256 view1) = amm.currentCumulativePrices();
        assertEq(view0, expected0);
        assertEq(view1, expected1);

        uint256 amountIn = r0 / 100;
        token0.mint(bob, amountIn);
        _swap0For1(amountIn);
        assertEq(amm.price0CumulativeLast(), view0);
        assertEq(amm.price1CumulativeLast(), view1);
    }
}
