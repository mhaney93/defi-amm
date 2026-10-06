// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SimpleAMM} from "../src/SimpleAMM.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FeeOnTransferToken} from "./mocks/FeeOnTransferToken.sol";

/// @notice Shows what happens when one side of the pool is a fee-on-transfer token.
///         The pool books the amount the caller asked to send, not the amount that arrived,
///         so the stored reserves drift above the real balances and the last LP can't exit.
/// @dev These tests document a known limitation (see README). They assert the broken
///      behavior on purpose; when the pool switches to balance-delta accounting they
///      should be rewritten to assert that reserves match balances.
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

    /// @dev Alice seeds 100 : 100. The pool records 100e18 of token0 but only 99e18 arrives.
    function _seed() internal returns (uint256 liquidity) {
        vm.prank(alice);
        (,, liquidity) = amm.addLiquidity(100e18, 100e18, 0, 0);
    }

    function test_addLiquidity_reserveRecordsMoreThanArrived() public {
        _seed();

        assertEq(amm.reserve0(), 100e18);
        assertEq(token0.balanceOf(address(amm)), 99e18);
        // The plain token is unaffected.
        assertEq(amm.reserve1(), token1.balanceOf(address(amm)));
    }

    function test_swap_paysOutForTokensThatNeverArrived() public {
        _seed();
        uint256 expectedOut = amm.getAmountOut(10e18, amm.reserve0(), amm.reserve1());

        vm.prank(bob);
        uint256 amountOut = amm.swap(address(token0), 10e18, 0);

        // Bob is priced as if 10e18 came in, but the pool only received 9.9e18.
        assertEq(amountOut, expectedOut);
        assertEq(amm.reserve0(), 110e18);
        assertEq(token0.balanceOf(address(amm)), 99e18 + 9.9e18);
        // The gap grew from 1e18 to 1.1e18.
        assertEq(amm.reserve0() - token0.balanceOf(address(amm)), 1.1e18);
    }

    /// @dev Alice owns every share except the 1000 locked ones, so she should be able to take
    ///      out almost the whole pool. Her payout is based on reserve0 (100e18), but the pool
    ///      only holds 99e18, so the transfer fails. The token burns its 1% fee out of the pool's
    ///      balance first, then tries to move the other 99%, which is what the error reports.
    function test_removeLiquidity_lastLpCannotExit() public {
        uint256 liquidity = _seed();
        uint256 amount0 = (liquidity * amm.reserve0()) / amm.totalSupply();
        uint256 fee = (amount0 * token0.FEE_BPS()) / 10_000;
        assertGt(amount0, token0.balanceOf(address(amm)));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(amm), 99e18 - fee, amount0 - fee
            )
        );
        amm.removeLiquidity(liquidity, 0, 0);
    }
}
