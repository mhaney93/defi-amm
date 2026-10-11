// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, stdError} from "forge-std/Test.sol";
import {SimpleAMM} from "../src/SimpleAMM.sol";
import {MockERC20Decimals} from "./mocks/MockERC20Decimals.sol";

/// @notice A 6-decimal token (like USDC) paired with a 24-decimal token in the same pool.
///         The pool never reads decimals, it only sees raw units, so one whole token of each side
///         differs by 10^18 raw units. Small trades into the 6-decimal side are where rounding shows
///         up, and large 24-decimal amounts are where the multiply-before-divide math gets close to
///         the uint256 limit (reserves are uint256 here, not capped at uint112 like Uniswap V2).
contract SimpleAMMDecimalsTest is Test {
    SimpleAMM amm;
    MockERC20Decimals usd6;
    MockERC20Decimals big24;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // 1,000,000 whole tokens on each side, so one token of each is worth about the same.
    uint256 constant SEED6 = 1_000_000e6;
    uint256 constant SEED24 = 1_000_000e24;

    function setUp() public {
        usd6 = new MockERC20Decimals("USD Six", "USD6", 6);
        big24 = new MockERC20Decimals("Big Twenty Four", "BIG24", 24);
        amm = new SimpleAMM(address(usd6), address(big24));

        address[2] memory users = [alice, bob];
        for (uint256 i; i < users.length; i++) {
            usd6.mint(users[i], 1e20);
            big24.mint(users[i], 1e40);
            vm.startPrank(users[i]);
            usd6.approve(address(amm), type(uint256).max);
            big24.approve(address(amm), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _seed(uint256 amount6, uint256 amount24) internal {
        vm.prank(alice);
        amm.addLiquidity(amount6, amount24, 0, 0);
    }

    function _assertReservesMatchBalances() internal view {
        assertEq(amm.reserve0(), usd6.balanceOf(address(amm)));
        assertEq(amm.reserve1(), big24.balanceOf(address(amm)));
    }

    function test_mixedDecimals_normalSwapPricesCorrectly() public {
        _seed(SEED6, SEED24);
        uint256 kBefore = amm.reserve0() * amm.reserve1();

        vm.prank(bob);
        uint256 out = amm.swap(address(usd6), 1_000e6, 0);

        // 1,000 USD6 into a 1M/1M pool: about 996 BIG24 after the 0.3% fee and price impact.
        assertApproxEqRel(out, 996e24, 0.001e18);
        assertGe(amm.reserve0() * amm.reserve1(), kBefore);
        _assertReservesMatchBalances();
    }

    function test_tinySwap_fromSixDecimals_stillPaysOut() public {
        _seed(SEED6, SEED24);

        // The smallest possible 6-decimal input (0.000001) still buys about 10^18 raw BIG24 (also about 0.000001 tokens).
        vm.prank(bob);
        uint256 out = amm.swap(address(usd6), 1, 0);

        assertGt(out, 0);
        _assertReservesMatchBalances();
    }

    function test_tinySwap_intoSixDecimals_roundsToZeroAndReverts() public {
        _seed(SEED6, SEED24);
        uint256 bobBefore = big24.balanceOf(bob);

        // 10^17 raw BIG24 is worth less than one raw unit of USD6, so the output rounds down to 0.
        // The pool reverts instead of keeping the input and paying nothing.
        vm.prank(bob);
        vm.expectRevert(SimpleAMM.InsufficientOutputAmount.selector);
        amm.swap(address(big24), 1e17, 0);

        assertEq(big24.balanceOf(bob), bobBefore);
        assertEq(amm.reserve0(), SEED6);
        assertEq(amm.reserve1(), SEED24);
    }

    function test_dustSwap_intoSixDecimals_roundingStaysInPool() public {
        _seed(SEED6, SEED24);
        uint256 kBefore = amm.reserve0() * amm.reserve1();

        // 2 * 10^18 raw BIG24 is worth about 2 raw units of USD6, but after the fee it floors to 1.
        vm.prank(bob);
        uint256 out = amm.swap(address(big24), 2e18, 0);

        assertEq(out, 1);
        assertGt(amm.reserve0() * amm.reserve1(), kBefore);
        _assertReservesMatchBalances();
    }

    function test_trillionTokenSupply_atTwentyFourDecimals_fitsWithRoom() public {
        // 1 trillion BIG24 is 10^36 raw units. Seed with that against 1M USD6, then swap in
        // another full trillion: the products stay far below the uint256 limit (~1.16 * 10^77).
        _seed(SEED6, 1e36);

        vm.prank(bob);
        uint256 out = amm.swap(address(big24), 1e36, 0);

        // Doubling the BIG24 side pays out a bit under half the USD6 side.
        assertApproxEqRel(out, SEED6 / 2, 0.01e18);
        _assertReservesMatchBalances();
    }

    function test_getAmountOut_overflowRevertsInsteadOfWrapping() public {
        // amountIn * 997 * reserveOut = 10^35 * 997 * 10^40, about 10^78, past the uint256 limit.
        // Checked arithmetic reverts instead of wrapping to a small number and mispricing the trade.
        vm.expectRevert(stdError.arithmeticError);
        amm.getAmountOut(1e35, 1e40, 1e40);
    }
}
