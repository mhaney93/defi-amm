// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SimpleAMM} from "../src/SimpleAMM.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {RevertOnZeroToken} from "./mocks/RevertOnZeroToken.sol";

/// @notice Pool behavior when token0 reverts on zero-value transfers.
///         The pool should never try to send zero: every path that could round a payout down to
///         zero checks for it first and reverts with the pool's own error. That matters because a
///         pool that did send zero would be stuck the moment it hit one of these tokens.
contract SimpleAMMRevertOnZeroTest is Test {
    SimpleAMM amm;
    RevertOnZeroToken token0;
    MockERC20 token1;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        token0 = new RevertOnZeroToken("Zero Reverter", "ZERO");
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

    /// @dev The normal lifecycle never moves zero, so the token works like any other.
    function test_fullLifecycle_works() public {
        uint256 liquidity = _seed();

        vm.startPrank(bob);
        uint256 out1 = amm.swap(address(token0), 10e18, 0);
        uint256 out0 = amm.swap(address(token1), out1, 0);
        vm.stopPrank();
        assertGt(out0, 0);

        vm.prank(alice);
        amm.removeLiquidity(liquidity, 0, 0);
        assertEq(amm.balanceOf(alice), 0);
        assertEq(amm.reserve0(), token0.balanceOf(address(amm)));
        assertEq(amm.reserve1(), token1.balanceOf(address(amm)));
    }

    /// @dev A dust swap into token0 rounds the output to zero. The pool catches it before sending,
    ///      so the revert is the pool's InsufficientOutputAmount, not the token's ZeroTransfer.
    function test_swap_dustOutputRevertsBeforeSendingZero() public {
        _seed();

        vm.prank(bob);
        vm.expectRevert(SimpleAMM.InsufficientOutputAmount.selector);
        amm.swap(address(token1), 1, 0);
    }

    /// @dev Burning a few shares rounds the token0 payout to zero. Same story: the pool's check
    ///      fires first.
    function test_removeLiquidity_dustPayoutRevertsBeforeSendingZero() public {
        _seed();
        // Make token0's reserve tiny compared to supply so 1 share is worth less than 1 unit of token0.
        vm.prank(bob);
        amm.swap(address(token1), 900e18, 0);

        vm.prank(alice);
        vm.expectRevert(SimpleAMM.InsufficientLiquidityBurned.selector);
        amm.removeLiquidity(1, 0, 0);
    }

    /// @dev The one place the pool does ask for zero: a deposit so lopsided that the matching
    ///      amount of token0 rounds down to zero. The token reverts on the pull. With a normal token
    ///      the same deposit still fails a few lines later (it would mint zero shares), so the only
    ///      difference is which error the caller sees. Nothing gets booked either way.
    function test_addLiquidity_lopsidedDepositRevertsOnZeroPull() public {
        _seed();
        // Skew the pool so token0 is scarce: 1 wei of token1 is then worth less than 1 unit of token0.
        vm.prank(bob);
        amm.swap(address(token1), 900e18, 0);
        uint256 reserve0Before = amm.reserve0();
        uint256 reserve1Before = amm.reserve1();
        assertLt(reserve0Before, reserve1Before);

        vm.prank(bob);
        vm.expectRevert(RevertOnZeroToken.ZeroTransfer.selector);
        amm.addLiquidity(100e18, 1, 0, 0);

        assertEq(amm.reserve0(), reserve0Before);
        assertEq(amm.reserve1(), reserve1Before);
    }

    /// @dev Control for the test above: the same deposit with a normal token0 also reverts, just
    ///      later, because it would mint zero shares.
    function test_addLiquidity_lopsidedDepositRevertsWithNormalTokenToo() public {
        MockERC20 normal0 = new MockERC20("Token A", "TKA");
        SimpleAMM pool = new SimpleAMM(address(normal0), address(token1));
        normal0.mint(bob, 1_000e18);
        token1.mint(bob, 1_000e18);
        vm.startPrank(bob);
        normal0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        pool.addLiquidity(100e18, 100e18, 0, 0);
        pool.swap(address(token1), 900e18, 0);

        vm.expectRevert(SimpleAMM.InsufficientLiquidityMinted.selector);
        pool.addLiquidity(100e18, 1, 0, 0);
        vm.stopPrank();
    }
}
