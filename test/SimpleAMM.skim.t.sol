// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SimpleAMM} from "../src/SimpleAMM.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {RevertOnZeroToken} from "./mocks/RevertOnZeroToken.sol";

/// @notice skim() pays out whatever the pool holds above its reserves. Tokens sent straight to the
///         pool never enter the reserves (deposits and swaps book only their own balance delta), so
///         without skim they'd be stuck for good.
contract SimpleAMMSkimTest is Test {
    event Skim(address indexed caller, address indexed to, uint256 amount0, uint256 amount1);

    SimpleAMM amm;
    MockERC20 token0;
    MockERC20 token1;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

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

    function _donate(uint256 amount0, uint256 amount1) internal {
        token0.mint(address(amm), amount0);
        token1.mint(address(amm), amount1);
    }

    /// @dev Tokens sent straight to the pool go to the skim recipient, and the reserves don't move.
    function test_skim_sendsExcessToRecipient() public {
        _donate(5e18, 7e18);

        vm.expectEmit(true, true, false, true);
        emit Skim(bob, carol, 5e18, 7e18);
        vm.prank(bob);
        (uint256 amount0, uint256 amount1) = amm.skim(carol);

        assertEq(amount0, 5e18);
        assertEq(amount1, 7e18);
        assertEq(token0.balanceOf(carol), 5e18);
        assertEq(token1.balanceOf(carol), 7e18);
        assertEq(amm.reserve0(), 100e18);
        assertEq(amm.reserve1(), 100e18);
        assertEq(token0.balanceOf(address(amm)), amm.reserve0());
        assertEq(token1.balanceOf(address(amm)), amm.reserve1());
    }

    /// @dev With nothing extra in the pool, skim sends nothing and changes nothing.
    function test_skim_nothingExtra_sendsNothing() public {
        vm.prank(bob);
        (uint256 amount0, uint256 amount1) = amm.skim(carol);

        assertEq(amount0, 0);
        assertEq(amount1, 0);
        assertEq(token0.balanceOf(carol), 0);
        assertEq(token1.balanceOf(carol), 0);
    }

    /// @dev Skim can't take anything that belongs to LPs: after it runs, a swap quotes the same
    ///      as before the donation, and Alice can still withdraw her full share.
    function test_skim_leavesLpFundsAlone() public {
        uint256 quoteBefore = amm.getAmountOut(10e18, amm.reserve0(), amm.reserve1());
        _donate(5e18, 0);
        amm.skim(carol);
        assertEq(amm.getAmountOut(10e18, amm.reserve0(), amm.reserve1()), quoteBefore);

        uint256 liquidity = amm.balanceOf(alice);
        vm.prank(alice);
        (uint256 out0, uint256 out1) = amm.removeLiquidity(liquidity, 0, 0);
        assertApproxEqAbs(out0, 100e18 - amm.MINIMUM_LIQUIDITY(), 1);
        assertApproxEqAbs(out1, 100e18 - amm.MINIMUM_LIQUIDITY(), 1);
    }

    /// @dev If one side has nothing extra, skim skips it rather than sending 0. With a token that
    ///      reverts on zero transfers, sending 0 would block skimming the other side.
    function test_skim_revertOnZeroToken_skipsEmptySide() public {
        RevertOnZeroToken zeroToken = new RevertOnZeroToken("Revert On Zero", "ROZ");
        MockERC20 other = new MockERC20("Token C", "TKC");
        SimpleAMM pool = new SimpleAMM(address(zeroToken), address(other));

        zeroToken.mint(alice, 100e18);
        other.mint(alice, 100e18);
        vm.startPrank(alice);
        zeroToken.approve(address(pool), type(uint256).max);
        other.approve(address(pool), type(uint256).max);
        pool.addLiquidity(100e18, 100e18, 0, 0);
        vm.stopPrank();

        other.mint(address(pool), 3e18);
        (uint256 amount0, uint256 amount1) = pool.skim(carol);

        assertEq(amount0, 0);
        assertEq(amount1, 3e18);
        assertEq(other.balanceOf(carol), 3e18);
    }

    /// @dev For any donation, skim returns exactly the donation and leaves reserves equal to balances.
    function testFuzz_skim_returnsExactlyTheDonation(uint256 amount0, uint256 amount1) public {
        amount0 = bound(amount0, 0, 1e30);
        amount1 = bound(amount1, 0, 1e30);
        _donate(amount0, amount1);

        (uint256 out0, uint256 out1) = amm.skim(carol);

        assertEq(out0, amount0);
        assertEq(out1, amount1);
        assertEq(token0.balanceOf(address(amm)), amm.reserve0());
        assertEq(token1.balanceOf(address(amm)), amm.reserve1());
    }
}
