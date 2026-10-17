// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SimpleAMM} from "../src/SimpleAMM.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {RebasingToken} from "./mocks/RebasingToken.sol";

/// @notice Pins down what goes wrong when token0 rebases. The README lists rebasing tokens as
///         unsupported; these tests show exactly how. The pool only learns about balances through
///         its own transfers, so a rebase leaves the stored reserves out of date:
///         - after a positive rebase the extra tokens sit in the pool, unpriced and unclaimable;
///         - after a negative rebase the pool owes more than it holds, and the last LP out can't leave.
///         Uniswap V2's sync() and skim() exist for exactly this; SimpleAMM doesn't have them.
contract SimpleAMMRebasingTest is Test {
    SimpleAMM amm;
    RebasingToken token0;
    MockERC20 token1;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        token0 = new RebasingToken("Rebasing Token", "REB");
        token1 = new MockERC20("Token B", "TKB");
        amm = new SimpleAMM(address(token0), address(token1));

        address[2] memory users = [alice, bob];
        for (uint256 i; i < users.length; i++) {
            token0.mint(users[i], 1_000e18);
            token1.mint(users[i], 1_000e18);
            vm.startPrank(users[i]);
            token0.approve(address(amm), type(uint256).max);
            token1.approve(address(amm), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _seed() internal returns (uint256 liquidity) {
        vm.prank(alice);
        (,, liquidity) = amm.addLiquidity(100e18, 100e18, 0, 0);
    }

    /// @dev Before any rebase the token behaves normally and the books match.
    function test_noRebase_reservesMatchBalances() public {
        _seed();
        vm.prank(bob);
        amm.swap(address(token1), 10e18, 0);

        assertEq(amm.reserve0(), token0.balanceOf(address(amm)));
        assertEq(amm.reserve1(), token1.balanceOf(address(amm)));
    }

    /// @dev +10% rebase: the pool now holds 110 token0 but still prices trades on 100.
    function test_positiveRebase_swapPricesOnStaleReserve() public {
        _seed();
        token0.rebase(1.1e18);
        assertEq(token0.balanceOf(address(amm)), 110e18);
        assertEq(amm.reserve0(), 100e18);

        uint256 quoteOnStale = amm.getAmountOut(10e18, amm.reserve1(), amm.reserve0());
        uint256 quoteOnReal = amm.getAmountOut(10e18, amm.reserve1(), token0.balanceOf(address(amm)));

        vm.prank(bob);
        uint256 out = amm.swap(address(token1), 10e18, 0);

        assertEq(out, quoteOnStale);
        assertLt(out, quoteOnReal);
    }

    /// @dev +10% rebase, then the only LP exits. She gets her share of the 100 the pool knows
    ///      about, not the 110 it holds. The extra 10 stay in the pool with no shares against them,
    ///      so nobody can ever withdraw them.
    function test_positiveRebase_surplusIsStrandedAfterLastExit() public {
        uint256 liquidity = _seed();
        token0.rebase(1.1e18);

        uint256 aliceBefore = token0.balanceOf(alice);
        vm.prank(alice);
        amm.removeLiquidity(liquidity, 0, 0);
        uint256 received = token0.balanceOf(alice) - aliceBefore;

        // ~100e18 minus the MINIMUM_LIQUIDITY share, and up to 1 wei of share rounding.
        assertApproxEqAbs(received, 100e18 - amm.MINIMUM_LIQUIDITY(), 1);

        uint256 stranded = token0.balanceOf(address(amm)) - amm.reserve0();
        assertApproxEqAbs(stranded, 10e18, 2);
        // The only shares left are the locked ones at the dead address.
        assertEq(amm.totalSupply(), amm.MINIMUM_LIQUIDITY());
    }

    /// @dev A new deposit after a positive rebase doesn't pick up the surplus either: the pool
    ///      books only what arrived (balance delta), so the extra stays outside the reserves.
    function test_positiveRebase_newDepositDoesNotCaptureSurplus() public {
        _seed();
        token0.rebase(1.1e18);

        vm.prank(bob);
        (uint256 amount0,,) = amm.addLiquidity(50e18, 50e18, 0, 0);

        assertApproxEqAbs(amount0, 50e18, 1);
        assertApproxEqAbs(token0.balanceOf(address(amm)) - amm.reserve0(), 10e18, 2);
    }

    /// @dev skim() gets the +10% surplus out, but it goes to whoever calls skim first, not to the LP
    ///      whose share of the pool it grew. Skim recovers stray tokens; it doesn't fix rebasing.
    function test_positiveRebase_skimSendsSurplusToCaller() public {
        _seed();
        token0.rebase(1.1e18);

        address caller = makeAddr("caller");
        vm.prank(caller);
        (uint256 amount0, uint256 amount1) = amm.skim(caller);

        assertApproxEqAbs(amount0, 10e18, 2);
        assertEq(amount1, 0);
        assertApproxEqAbs(token0.balanceOf(caller), 10e18, 2);
        assertEq(amm.reserve0(), 100e18);
    }

    /// @dev After a -10% rebase the pool holds less token0 than its reserve. skim() skips that side
    ///      instead of reverting on the underflow, and the shortfall is still there afterwards.
    function test_negativeRebase_skimSkipsShortSide() public {
        _seed();
        token0.rebase(0.9e18);

        (uint256 amount0, uint256 amount1) = amm.skim(bob);

        assertEq(amount0, 0);
        assertEq(amount1, 0);
        assertEq(amm.reserve0() - token0.balanceOf(address(amm)), 10e18);
    }

    /// @dev sync() after a +10% rebase books the surplus, so the only LP gets it when she exits and
    ///      nothing is stranded.
    function test_positiveRebase_syncGivesSurplusToLp() public {
        uint256 liquidity = _seed();
        token0.rebase(1.1e18);
        amm.sync();
        assertEq(amm.reserve0(), token0.balanceOf(address(amm)));

        uint256 aliceBefore = token0.balanceOf(alice);
        vm.prank(alice);
        amm.removeLiquidity(liquidity, 0, 0);

        assertGt(token0.balanceOf(alice) - aliceBefore, 109e18);
        (uint256 skimmed0,) = amm.skim(bob);
        assertEq(skimmed0, 0);
    }

    /// @dev sync() after a -10% rebase with two equal LPs splits the loss: each one gets about 90
    ///      instead of the first getting 100 and the second getting stuck.
    function test_negativeRebase_syncSplitsLossAcrossLps() public {
        uint256 aliceLiq = _seed();
        vm.prank(bob);
        (,, uint256 bobLiq) = amm.addLiquidity(100e18, 100e18, 0, 0);

        token0.rebase(0.9e18);
        amm.sync();
        assertEq(amm.reserve0(), 180e18);

        uint256 aliceBefore = token0.balanceOf(alice);
        vm.prank(alice);
        amm.removeLiquidity(aliceLiq, 0, 0);
        uint256 bobBefore = token0.balanceOf(bob);
        vm.prank(bob);
        amm.removeLiquidity(bobLiq, 0, 0);

        assertApproxEqAbs(token0.balanceOf(alice) - aliceBefore, 90e18, 1e6);
        assertApproxEqAbs(token0.balanceOf(bob) - bobBefore, 90e18, 1e6);
    }

    /// @dev -10% rebase with two equal LPs. The pool holds 180 token0 but owes 200. Whoever
    ///      exits first gets a full 100; the second LP's full withdrawal then needs 100 from a
    ///      pool holding 80, and reverts. The whole loss lands on the last one out.
    function test_negativeRebase_lastLpCannotExit() public {
        uint256 aliceLiq = _seed();
        vm.prank(bob);
        (,, uint256 bobLiq) = amm.addLiquidity(100e18, 100e18, 0, 0);

        token0.rebase(0.9e18);
        assertEq(token0.balanceOf(address(amm)), 180e18);
        assertEq(amm.reserve0(), 200e18);

        uint256 aliceBefore = token0.balanceOf(alice);
        vm.prank(alice);
        amm.removeLiquidity(aliceLiq, 0, 0);
        assertApproxEqAbs(token0.balanceOf(alice) - aliceBefore, 100e18 - amm.MINIMUM_LIQUIDITY(), 1);

        uint256 shortfall = amm.reserve0() - token0.balanceOf(address(amm));
        assertApproxEqAbs(shortfall, 20e18, 2);

        vm.prank(bob);
        vm.expectRevert(RebasingToken.InsufficientBalance.selector);
        amm.removeLiquidity(bobLiq, 0, 0);
        assertEq(amm.balanceOf(bob), bobLiq);
    }
}
