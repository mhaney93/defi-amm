// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SimpleAMM} from "../src/SimpleAMM.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FeeOnTransferToken} from "./mocks/FeeOnTransferToken.sol";

/// @notice Pool behavior when one side is a fee-on-transfer token (1% burned on every transfer).
///         The pool measures its balance before and after each transfer in and books only the
///         difference, so the stored reserves always match the real balances.
/// @dev Before the fix these tests showed reserves drifting above balances and the last LP
///      being unable to exit (commit 85d4c6e). They now assert the corrected behavior.
contract SimpleAMMFeeOnTransferTest is Test {
    SimpleAMM amm;
    FeeOnTransferToken token0;
    MockERC20 token1;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        token0 = new FeeOnTransferToken("Fee Token", "FEE");
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

    /// @dev Alice seeds 100 : 100. Only 99e18 of token0 arrives.
    function _seed() internal returns (uint256 liquidity) {
        vm.prank(alice);
        (,, liquidity) = amm.addLiquidity(100e18, 100e18, 0, 0);
    }

    function _assertReservesMatchBalances() internal view {
        assertEq(amm.reserve0(), token0.balanceOf(address(amm)), "reserve0 != balance0");
        assertEq(amm.reserve1(), token1.balanceOf(address(amm)), "reserve1 != balance1");
    }

    function test_addLiquidity_booksWhatArrived() public {
        vm.prank(alice);
        (uint256 amount0, uint256 amount1, uint256 liquidity) = amm.addLiquidity(100e18, 100e18, 0, 0);

        assertEq(amount0, 99e18);
        assertEq(amount1, 100e18);
        assertEq(liquidity, Math.sqrt(99e18 * 100e18) - amm.MINIMUM_LIQUIDITY());
        _assertReservesMatchBalances();
    }

    /// @dev Bob offers 10 : 10 into a 99 : 100 pool. Ratio matching pulls 9.9 token0 and 10 token1,
    ///      but only 9.801 token0 arrives, so his shares are set by the token0 side and the extra
    ///      token1 stays in the pool for the existing LPs.
    function test_addLiquidity_laterDepositSharesUseReceivedAmount() public {
        _seed();
        uint256 supply = amm.totalSupply();

        vm.prank(bob);
        (uint256 amount0,, uint256 liquidity) = amm.addLiquidity(10e18, 10e18, 0, 0);

        assertEq(amount0, 9.801e18);
        assertEq(liquidity, (9.801e18 * supply) / 99e18);
        _assertReservesMatchBalances();
    }

    /// @dev The min amounts are checked against what the pool received, not what was sent.
    function test_addLiquidity_minCheckedAgainstReceived() public {
        _seed();

        vm.prank(bob);
        vm.expectRevert(SimpleAMM.InsufficientAmount0.selector);
        amm.addLiquidity(10e18, 10e18, 10e18, 0);
    }

    function test_swap_feeTokenIn_pricedOnWhatArrived() public {
        _seed();
        uint256 expectedOut = amm.getAmountOut(9.9e18, amm.reserve0(), amm.reserve1());

        vm.prank(bob);
        uint256 amountOut = amm.swap(address(token0), 10e18, 0);

        // Bob sent 10e18 but only 9.9e18 arrived, and that's what he's paid for.
        assertEq(amountOut, expectedOut);
        assertEq(amm.reserve0(), 99e18 + 9.9e18);
        _assertReservesMatchBalances();
    }

    /// @dev Selling the plain token for the fee token: the pool sends amountOut in full (the token
    ///      burns its fee from that), so the reserves still match. Bob receives 99% of amountOut.
    function test_swap_feeTokenOut_reservesStillMatch() public {
        _seed();
        uint256 bobBefore = token0.balanceOf(bob);

        vm.prank(bob);
        uint256 amountOut = amm.swap(address(token1), 10e18, 0);

        assertEq(token0.balanceOf(bob) - bobBefore, amountOut - (amountOut * token0.FEE_BPS()) / 10_000);
        _assertReservesMatchBalances();
    }

    /// @dev Before the fix this reverted with ERC20InsufficientBalance.
    function test_removeLiquidity_lastLpCanExit() public {
        uint256 liquidity = _seed();
        vm.prank(bob);
        amm.swap(address(token0), 10e18, 0);

        vm.prank(alice);
        (uint256 amount0, uint256 amount1) = amm.removeLiquidity(liquidity, 0, 0);

        assertGt(amount0, 0);
        assertGt(amount1, 0);
        // Only the dust backing the locked MINIMUM_LIQUIDITY shares is left.
        assertEq(amm.totalSupply(), amm.MINIMUM_LIQUIDITY());
        _assertReservesMatchBalances();
    }

    /// @dev Any mix of deposits and swaps in both directions keeps reserves equal to balances.
    function testFuzz_reservesMatchBalances(uint256 add0, uint256 add1, uint256 in0, uint256 in1) public {
        _seed();
        add0 = bound(add0, 1e18, 100e18);
        add1 = bound(add1, 1e18, 100e18);
        in0 = bound(in0, 1e15, 100e18);
        in1 = bound(in1, 1e15, 100e18);

        vm.startPrank(bob);
        amm.addLiquidity(add0, add1, 0, 0);
        amm.swap(address(token0), in0, 0);
        amm.swap(address(token1), in1, 0);
        amm.removeLiquidity(amm.balanceOf(bob), 0, 0);
        vm.stopPrank();

        _assertReservesMatchBalances();
    }
}
