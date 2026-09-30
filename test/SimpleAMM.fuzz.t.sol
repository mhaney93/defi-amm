// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SimpleAMM} from "../src/SimpleAMM.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Stateless fuzz tests: one random input per run, checked against a property
///         that has to hold for every input, not just the hand-picked ones in the unit tests.
contract SimpleAMMFuzzTest is Test {
    SimpleAMM amm;
    MockERC20 token0;
    MockERC20 token1;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    /// @dev Upper bound for fuzzed amounts. 1e30 keeps reserve products well under 2^256.
    uint256 constant MAX = 1e30;

    function setUp() public {
        token0 = new MockERC20("Token A", "TKA");
        token1 = new MockERC20("Token B", "TKB");
        amm = new SimpleAMM(address(token0), address(token1));

        address[2] memory users = [alice, bob];
        for (uint256 i; i < users.length; i++) {
            vm.startPrank(users[i]);
            token0.approve(address(amm), type(uint256).max);
            token1.approve(address(amm), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _seed(uint256 r0, uint256 r1) internal {
        token0.mint(alice, r0);
        token1.mint(alice, r1);
        vm.prank(alice);
        amm.addLiquidity(r0, r1, 0, 0);
    }

    /// @dev Shared bounds for a seeded pool: big enough to clear MINIMUM_LIQUIDITY.
    function _boundReserves(uint256 r0, uint256 r1) internal pure returns (uint256, uint256) {
        return (bound(r0, 1e6, MAX), bound(r1, 1e6, MAX));
    }

    // ---------------------------------------------------------------- getAmountOut

    /// @notice The quote can never ask for the whole output reserve, whatever the input size.
    function testFuzz_getAmountOut_neverDrainsReserve(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public
        view
    {
        amountIn = bound(amountIn, 1, MAX);
        reserveIn = bound(reserveIn, 1, MAX);
        reserveOut = bound(reserveOut, 1, MAX);

        assertLt(amm.getAmountOut(amountIn, reserveIn, reserveOut), reserveOut);
    }

    /// @notice Selling more never gets you less.
    function testFuzz_getAmountOut_monotonic(uint256 amountIn, uint256 extra, uint256 reserveIn, uint256 reserveOut)
        public
        view
    {
        amountIn = bound(amountIn, 1, MAX);
        extra = bound(extra, 0, MAX);
        reserveIn = bound(reserveIn, 1, MAX);
        reserveOut = bound(reserveOut, 1, MAX);

        assertGe(
            amm.getAmountOut(amountIn + extra, reserveIn, reserveOut), amm.getAmountOut(amountIn, reserveIn, reserveOut)
        );
    }

    // ---------------------------------------------------------------- swap

    /// @notice The fee stays in the pool, so k can only go up after a swap.
    function testFuzz_swap_kNeverDecreases(uint256 r0, uint256 r1, uint256 amountIn, bool zeroForOne) public {
        (r0, r1) = _boundReserves(r0, r1);
        _seed(r0, r1);
        amountIn = bound(amountIn, 1, MAX);

        MockERC20 tokenIn = zeroForOne ? token0 : token1;
        uint256 reserveIn = zeroForOne ? r0 : r1;
        uint256 reserveOut = zeroForOne ? r1 : r0;
        // Tiny trades round down to zero output and revert by design; skip those inputs.
        vm.assume(amm.getAmountOut(amountIn, reserveIn, reserveOut) > 0);

        uint256 kBefore = amm.reserve0() * amm.reserve1();
        tokenIn.mint(bob, amountIn);
        vm.prank(bob);
        amm.swap(address(tokenIn), amountIn, 0);

        assertGe(amm.reserve0() * amm.reserve1(), kBefore);
    }

    /// @notice Selling and then selling straight back can't leave the trader with a profit.
    function testFuzz_swap_roundTripNeverProfits(uint256 r0, uint256 r1, uint256 amountIn) public {
        (r0, r1) = _boundReserves(r0, r1);
        _seed(r0, r1);
        amountIn = bound(amountIn, 1, MAX);
        vm.assume(amm.getAmountOut(amountIn, r0, r1) > 0);

        token0.mint(bob, amountIn);
        vm.startPrank(bob);
        uint256 out1 = amm.swap(address(token0), amountIn, 0);
        vm.assume(amm.getAmountOut(out1, amm.reserve1(), amm.reserve0()) > 0);
        uint256 out0 = amm.swap(address(token1), out1, 0);
        vm.stopPrank();

        assertLe(out0, amountIn);
    }

    // ---------------------------------------------------------------- liquidity

    /// @notice Adding and immediately removing liquidity never returns more than was put in.
    ///         If it did, anyone could farm the rounding for free tokens.
    function testFuzz_addRemove_neverProfits(uint256 r0, uint256 r1, uint256 a0, uint256 a1) public {
        (r0, r1) = _boundReserves(r0, r1);
        _seed(r0, r1);
        a0 = bound(a0, 1, MAX);
        a1 = bound(a1, 1, MAX);

        token0.mint(bob, a0);
        token1.mint(bob, a1);
        vm.startPrank(bob);
        // Some fuzzed ratios mint zero shares; that revert is expected, so skip them.
        try amm.addLiquidity(a0, a1, 0, 0) returns (uint256 used0, uint256 used1, uint256 liquidity) {
            try amm.removeLiquidity(liquidity, 0, 0) returns (uint256 out0, uint256 out1) {
                assertLe(out0, used0);
                assertLe(out1, used1);
            } catch {}
        } catch {}
        vm.stopPrank();
    }
}
