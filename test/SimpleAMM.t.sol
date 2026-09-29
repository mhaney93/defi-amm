// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SimpleAMM} from "../src/SimpleAMM.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ReentrantToken} from "./mocks/ReentrantToken.sol";

/// @notice Unit tests for the constructor, liquidity, swap and getAmountOut.
///         Fuzz and invariant tests come in a later commit.
contract SimpleAMMTest is Test {
    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1, uint256 liquidity);
    event LiquidityRemoved(address indexed provider, uint256 amount0, uint256 amount1, uint256 liquidity);
    event Swap(address indexed trader, address indexed tokenIn, uint256 amountIn, uint256 amountOut);

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

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

    /// @dev Alice seeds the pool at 1 token0 : 4 token1. sqrt(1e18 * 4e18) = 2e18 shares,
    ///      1000 of them locked, so she gets 2e18 - 1000.
    function _seed() internal returns (uint256 liquidity) {
        vm.prank(alice);
        (,, liquidity) = amm.addLiquidity(1e18, 4e18, 0, 0);
    }

    // ---------------------------------------------------------------- constructor

    function test_constructor_setsTokens() public view {
        assertEq(address(amm.token0()), address(token0));
        assertEq(address(amm.token1()), address(token1));
    }

    function test_constructor_revertsOnIdenticalTokens() public {
        vm.expectRevert(SimpleAMM.IdenticalTokens.selector);
        new SimpleAMM(address(token0), address(token0));
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(SimpleAMM.ZeroAddress.selector);
        new SimpleAMM(address(0), address(token1));
    }

    // ---------------------------------------------------------------- addLiquidity: first deposit

    function test_addLiquidity_firstDeposit_mintsSqrtMinusLocked() public {
        uint256 liquidity = _seed();

        assertEq(liquidity, 2e18 - 1000);
        assertEq(amm.balanceOf(alice), 2e18 - 1000);
        assertEq(amm.balanceOf(DEAD), amm.MINIMUM_LIQUIDITY());
        assertEq(amm.totalSupply(), 2e18);
        assertEq(amm.reserve0(), 1e18);
        assertEq(amm.reserve1(), 4e18);
        assertEq(token0.balanceOf(address(amm)), 1e18);
        assertEq(token1.balanceOf(address(amm)), 4e18);
    }

    function test_addLiquidity_firstDeposit_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(amm));
        emit LiquidityAdded(alice, 1e18, 4e18, 2e18 - 1000);
        _seed();
    }

    function test_addLiquidity_revertsWhenFirstDepositTooSmall() public {
        // sqrt(1000 * 1000) = 1000, which doesn't clear MINIMUM_LIQUIDITY.
        vm.prank(alice);
        vm.expectRevert(SimpleAMM.InsufficientLiquidityMinted.selector);
        amm.addLiquidity(1000, 1000, 0, 0);
    }

    function test_addLiquidity_revertsOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(SimpleAMM.ZeroAmount.selector);
        amm.addLiquidity(0, 1e18, 0, 0);
    }

    // ---------------------------------------------------------------- addLiquidity: later deposits

    function test_addLiquidity_usesAllToken0_whenToken1IsInExcess() public {
        _seed();
        uint256 bobToken1Before = token1.balanceOf(bob);

        // Bob offers 1 : 10, but the pool is 1 : 4, so only 4e18 token1 should be pulled.
        vm.prank(bob);
        (uint256 a0, uint256 a1, uint256 liquidity) = amm.addLiquidity(1e18, 10e18, 0, 0);

        assertEq(a0, 1e18);
        assertEq(a1, 4e18);
        assertEq(liquidity, 2e18); // 1e18 * 2e18 supply / 1e18 reserve
        assertEq(bobToken1Before - token1.balanceOf(bob), 4e18);
        assertEq(amm.reserve0(), 2e18);
        assertEq(amm.reserve1(), 8e18);
    }

    function test_addLiquidity_usesAllToken1_whenToken0IsInExcess() public {
        _seed();

        // 2e18 token1 only matches 0.5e18 token0 at 1 : 4.
        vm.prank(bob);
        (uint256 a0, uint256 a1, uint256 liquidity) = amm.addLiquidity(1e18, 2e18, 0, 0);

        assertEq(a0, 0.5e18);
        assertEq(a1, 2e18);
        assertEq(liquidity, 1e18);
    }

    function test_addLiquidity_revertsBelowAmount1Min() public {
        _seed();

        // The ratio only allows 4e18 token1, so a 5e18 floor must fail.
        vm.prank(bob);
        vm.expectRevert(SimpleAMM.InsufficientAmount1.selector);
        amm.addLiquidity(1e18, 10e18, 0, 5e18);
    }

    function test_addLiquidity_revertsBelowAmount0Min() public {
        _seed();

        vm.prank(bob);
        vm.expectRevert(SimpleAMM.InsufficientAmount0.selector);
        amm.addLiquidity(1e18, 2e18, 0.6e18, 0);
    }

    // ---------------------------------------------------------------- removeLiquidity

    function test_removeLiquidity_paysOutProRata() public {
        uint256 liquidity = _seed();
        uint256 a0Before = token0.balanceOf(alice);
        uint256 a1Before = token1.balanceOf(alice);

        vm.prank(alice);
        (uint256 a0, uint256 a1) = amm.removeLiquidity(liquidity, 0, 0);

        // Alice owns (2e18 - 1000) of 2e18 shares, so the locked 1000 keeps a sliver of each reserve.
        assertEq(a0, 1e18 - 500);
        assertEq(a1, 4e18 - 2000);
        assertEq(token0.balanceOf(alice) - a0Before, a0);
        assertEq(token1.balanceOf(alice) - a1Before, a1);
        assertEq(amm.balanceOf(alice), 0);
        assertEq(amm.totalSupply(), amm.MINIMUM_LIQUIDITY());
        assertEq(amm.reserve0(), 500);
        assertEq(amm.reserve1(), 2000);
    }

    function test_removeLiquidity_partial() public {
        _seed();
        vm.prank(bob);
        amm.addLiquidity(1e18, 4e18, 0, 0); // bob gets exactly 2e18 shares

        vm.prank(bob);
        (uint256 a0, uint256 a1) = amm.removeLiquidity(1e18, 0, 0);

        // 1e18 of 4e18 total shares = a quarter of 2e18 / 8e18.
        assertEq(a0, 0.5e18);
        assertEq(a1, 2e18);
        assertEq(amm.balanceOf(bob), 1e18);
    }

    function test_removeLiquidity_emitsEvent() public {
        uint256 liquidity = _seed();

        vm.expectEmit(true, false, false, true, address(amm));
        emit LiquidityRemoved(alice, 1e18 - 500, 4e18 - 2000, liquidity);
        vm.prank(alice);
        amm.removeLiquidity(liquidity, 0, 0);
    }

    function test_removeLiquidity_revertsOnZero() public {
        _seed();
        vm.prank(alice);
        vm.expectRevert(SimpleAMM.ZeroAmount.selector);
        amm.removeLiquidity(0, 0, 0);
    }

    function test_removeLiquidity_revertsWhenBurningMoreThanOwned() public {
        uint256 liquidity = _seed();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, liquidity));
        amm.removeLiquidity(liquidity, 0, 0);
    }

    function test_removeLiquidity_revertsBelowMin() public {
        uint256 liquidity = _seed();

        vm.prank(alice);
        vm.expectRevert(SimpleAMM.InsufficientAmount0.selector);
        amm.removeLiquidity(liquidity, 1e18, 0);
    }

    function test_removeLiquidity_revertsWhenPayoutRoundsToZero() public {
        _seed();

        // 1 share of 2e18 against a 1e18 reserve rounds token0 down to 0.
        vm.prank(alice);
        vm.expectRevert(SimpleAMM.InsufficientLiquidityBurned.selector);
        amm.removeLiquidity(1, 0, 0);
    }

    // ---------------------------------------------------------------- getAmountOut

    function test_getAmountOut_knownValues() public view {
        // 10 * 997 * 1000 / (1000 * 1000 + 10 * 997) = 9.87..., rounds down to 9.
        assertEq(amm.getAmountOut(10, 1000, 1000), 9);
        // 1000 * 997 * 1000 / (1000 * 1000 + 1000 * 997) = 499.24..., rounds down to 499.
        assertEq(amm.getAmountOut(1000, 1000, 1000), 499);
    }

    function test_getAmountOut_revertsOnZeroAmount() public {
        vm.expectRevert(SimpleAMM.ZeroAmount.selector);
        amm.getAmountOut(0, 1000, 1000);
    }

    function test_getAmountOut_revertsOnEmptyReserve() public {
        vm.expectRevert(SimpleAMM.InsufficientLiquidity.selector);
        amm.getAmountOut(10, 0, 1000);
    }

    // ---------------------------------------------------------------- swap

    function test_swap_token0ForToken1() public {
        _seed();
        uint256 expected = amm.getAmountOut(0.1e18, 1e18, 4e18);
        uint256 b0Before = token0.balanceOf(bob);
        uint256 b1Before = token1.balanceOf(bob);

        vm.prank(bob);
        uint256 amountOut = amm.swap(address(token0), 0.1e18, 0);

        assertEq(amountOut, expected);
        assertEq(b0Before - token0.balanceOf(bob), 0.1e18);
        assertEq(token1.balanceOf(bob) - b1Before, expected);
        assertEq(amm.reserve0(), 1.1e18);
        assertEq(amm.reserve1(), 4e18 - expected);
        // Reserves must always match what the pool actually holds.
        assertEq(token0.balanceOf(address(amm)), amm.reserve0());
        assertEq(token1.balanceOf(address(amm)), amm.reserve1());
    }

    function test_swap_token1ForToken0() public {
        _seed();
        uint256 expected = amm.getAmountOut(0.4e18, 4e18, 1e18);

        vm.prank(bob);
        uint256 amountOut = amm.swap(address(token1), 0.4e18, 0);

        assertEq(amountOut, expected);
        assertEq(amm.reserve0(), 1e18 - expected);
        assertEq(amm.reserve1(), 4.4e18);
    }

    function test_swap_feeMakesKGrow() public {
        _seed();
        uint256 kBefore = amm.reserve0() * amm.reserve1();

        vm.prank(bob);
        amm.swap(address(token0), 0.1e18, 0);

        assertGt(amm.reserve0() * amm.reserve1(), kBefore);
    }

    function test_swap_roundTripLosesToFee() public {
        _seed();
        uint256 b0Before = token0.balanceOf(bob);

        vm.startPrank(bob);
        uint256 out1 = amm.swap(address(token0), 0.1e18, 0);
        amm.swap(address(token1), out1, 0);
        vm.stopPrank();

        // Selling straight back should never return the full 0.1e18.
        assertLt(token0.balanceOf(bob), b0Before);
    }

    function test_swap_emitsEvent() public {
        _seed();
        uint256 expected = amm.getAmountOut(0.1e18, 1e18, 4e18);

        vm.expectEmit(true, true, false, true, address(amm));
        emit Swap(bob, address(token0), 0.1e18, expected);
        vm.prank(bob);
        amm.swap(address(token0), 0.1e18, 0);
    }

    function test_swap_revertsBelowMinAmountOut() public {
        _seed();
        uint256 expected = amm.getAmountOut(0.1e18, 1e18, 4e18);

        vm.prank(bob);
        vm.expectRevert(SimpleAMM.InsufficientOutputAmount.selector);
        amm.swap(address(token0), 0.1e18, expected + 1);
    }

    function test_swap_revertsWhenOutputRoundsToZero() public {
        _seed();

        // 1 wei of token0 into a 1e18 / 4e18 pool quotes 3 wei out, but 1 wei of token1
        // into the other side quotes 0, which must revert instead of taking the input for nothing.
        vm.prank(bob);
        vm.expectRevert(SimpleAMM.InsufficientOutputAmount.selector);
        amm.swap(address(token1), 1, 0);
    }

    function test_swap_revertsOnInvalidToken() public {
        _seed();
        MockERC20 other = new MockERC20("Other", "OTH");

        vm.prank(bob);
        vm.expectRevert(SimpleAMM.InvalidToken.selector);
        amm.swap(address(other), 1e18, 0);
    }

    function test_swap_revertsOnZeroAmount() public {
        _seed();
        vm.prank(bob);
        vm.expectRevert(SimpleAMM.ZeroAmount.selector);
        amm.swap(address(token0), 0, 0);
    }

    function test_swap_revertsOnEmptyPool() public {
        vm.prank(bob);
        vm.expectRevert(SimpleAMM.InsufficientLiquidity.selector);
        amm.swap(address(token0), 1e18, 0);
    }
}

/// @notice Reentrancy tests. token0 is a malicious token that calls back into the pool
///         in the middle of a transfer; the transient-storage guard must block every re-entry.
contract SimpleAMMReentrancyTest is Test {
    SimpleAMM amm;
    ReentrantToken evil;
    MockERC20 token1;

    address alice = makeAddr("alice");

    function setUp() public {
        evil = new ReentrantToken();
        token1 = new MockERC20("Token B", "TKB");
        amm = new SimpleAMM(address(evil), address(token1));

        evil.mint(alice, 100e18);
        token1.mint(alice, 100e18);
        vm.startPrank(alice);
        evil.approve(address(amm), type(uint256).max);
        token1.approve(address(amm), type(uint256).max);
        amm.addLiquidity(10e18, 10e18, 0, 0);
        vm.stopPrank();
    }

    function test_reentrancy_swapIntoSwap_isBlocked() public {
        // While the pool pulls evil in, the token tries to run a second swap.
        evil.arm(address(amm), abi.encodeCall(SimpleAMM.swap, (address(token1), 1e18, 0)));

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        amm.swap(address(evil), 1e18, 0);
    }

    function test_reentrancy_removeIntoSwap_isBlocked() public {
        // While the pool pays evil out, the token tries to swap against the half-updated pool.
        evil.arm(address(amm), abi.encodeCall(SimpleAMM.swap, (address(token1), 1e18, 0)));
        uint256 liquidity = amm.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        amm.removeLiquidity(liquidity / 2, 0, 0);
    }

    function test_reentrancy_addIntoRemove_isBlocked() public {
        evil.arm(address(amm), abi.encodeCall(SimpleAMM.removeLiquidity, (1e18, 0, 0)));

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        amm.addLiquidity(1e18, 1e18, 0, 0);
    }
}
