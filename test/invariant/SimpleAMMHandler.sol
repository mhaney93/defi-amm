// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SimpleAMM} from "../../src/SimpleAMM.sol";
import {IMintableERC20} from "../mocks/IMintableERC20.sol";

/// @notice The fuzzer calls this contract, not the pool directly. Each function bounds its
///         random inputs to something a real user could do, then calls the pool as one of a
///         few actors. That keeps runs from being wasted on calls that can only revert.
/// @dev After every call the handler checks that k per LP share did not go down, and
///      records a failure in a ghost flag that the invariant test asserts on.
///      Tokens are typed as IMintableERC20 so the same handler drives both the plain-token
///      suite and the fee-on-transfer suite.
contract SimpleAMMHandler is Test {
    SimpleAMM public immutable amm;
    IMintableERC20 public immutable token0;
    IMintableERC20 public immutable token1;

    address[] public actors;

    /// @dev Keeps reserve products far below 2^256 even after many deposits.
    uint256 constant MAX_AMOUNT = 1e27;

    /// @notice k / totalSupply^2, scaled by 1e18, as of the last call.
    uint256 public lastKPerShare;
    bool public kPerShareDecreased;
    bool public kDecreasedOnSwap;

    uint256 public swaps;
    uint256 public adds;
    uint256 public removes;

    constructor(SimpleAMM _amm, IMintableERC20 _token0, IMintableERC20 _token1) {
        amm = _amm;
        token0 = _token0;
        token1 = _token1;

        for (uint256 i; i < 3; i++) {
            address actor = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(actor);
            vm.startPrank(actor);
            token0.approve(address(amm), type(uint256).max);
            token1.approve(address(amm), type(uint256).max);
            vm.stopPrank();
        }
        lastKPerShare = kPerShare();
    }

    /// @notice Pool value per LP share. Swaps raise it (fees) and rounding on add/remove
    ///         always favors the pool, so it should never go down.
    /// @dev mulDiv avoids overflow in k * 1e18. Flooring can't flip the comparison:
    ///      if the true value didn't drop, the floored value can't drop either.
    function kPerShare() public view returns (uint256) {
        uint256 supply = amm.totalSupply();
        if (supply == 0) return 0;
        return Math.mulDiv(amm.reserve0() * amm.reserve1(), 1e18, supply * supply);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _checkKPerShare() internal {
        uint256 current = kPerShare();
        if (current < lastKPerShare) kPerShareDecreased = true;
        lastKPerShare = current;
    }

    function addLiquidity(uint256 actorSeed, uint256 amount0, uint256 amount1) external {
        address actor = _actor(actorSeed);
        amount0 = bound(amount0, 1, MAX_AMOUNT);
        amount1 = bound(amount1, 1, MAX_AMOUNT);
        token0.mint(actor, amount0);
        token1.mint(actor, amount1);

        vm.prank(actor);
        // Deposits too small to mint a share revert by design; that's not a finding.
        try amm.addLiquidity(amount0, amount1, 0, 0) {
            adds++;
        } catch {}
        _checkKPerShare();
    }

    function removeLiquidity(uint256 actorSeed, uint256 liquidity) external {
        address actor = _actor(actorSeed);
        uint256 balance = amm.balanceOf(actor);
        if (balance == 0) return;
        liquidity = bound(liquidity, 1, balance);

        vm.prank(actor);
        try amm.removeLiquidity(liquidity, 0, 0) {
            removes++;
        } catch {}
        _checkKPerShare();
    }

    function swap(uint256 actorSeed, bool zeroForOne, uint256 amountIn) external {
        address actor = _actor(actorSeed);
        amountIn = bound(amountIn, 1, MAX_AMOUNT);
        IMintableERC20 tokenIn = zeroForOne ? token0 : token1;
        tokenIn.mint(actor, amountIn);

        uint256 kBefore = amm.reserve0() * amm.reserve1();
        vm.prank(actor);
        try amm.swap(address(tokenIn), amountIn, 0) {
            swaps++;
            if (amm.reserve0() * amm.reserve1() < kBefore) kDecreasedOnSwap = true;
        } catch {}
        _checkKPerShare();
    }
}
