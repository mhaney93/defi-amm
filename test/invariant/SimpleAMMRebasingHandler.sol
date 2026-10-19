// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SimpleAMM} from "../../src/SimpleAMM.sol";
import {IMintableERC20} from "../mocks/IMintableERC20.sol";
import {RebasingToken} from "../mocks/RebasingToken.sol";
import {SimpleAMMHandler} from "./SimpleAMMHandler.sol";

/// @notice The base handler plus a rebase action on token0. A positive rebase adds tokens the
///         reserves don't know about, just like a donation. A negative rebase takes tokens away,
///         so the pool can hold less token0 than it has booked until someone calls sync().
/// @dev That shortfall is tracked on its own, in deficit0, instead of folding it into donated0.
///      At most one of donated0 and deficit0 is nonzero: a gain first pays down the deficit, and
///      a loss first eats into the surplus.
contract SimpleAMMRebasingHandler is SimpleAMMHandler {
    RebasingToken public immutable rebasingToken;

    /// @dev Keeps every rebase between -50% and +100% of the starting balance.
    uint256 constant MIN_INDEX = 0.5e18;
    uint256 constant MAX_INDEX = 2e18;

    /// @dev The token moves floor(amount / index) shares, so a transfer out of the pool can leave
    ///      up to ceil(index) wei behind. With the index capped at 2.0 that's at most 2 wei.
    uint256 constant MAX_DUST = 2;

    /// @notice token0 the pool has booked but lost to negative rebases since the last sync.
    uint256 public deficit0;
    /// @notice Set if a transfer out of the pool left it with less than it booked, or more than
    ///         the token's rounding explains.
    bool public dustOutOfBounds;
    uint256 public rebases;

    constructor(SimpleAMM _amm, IMintableERC20 _token0, IMintableERC20 _token1)
        SimpleAMMHandler(_amm, _token0, _token1)
    {
        rebasingToken = RebasingToken(address(_token0));
    }

    /// @notice Change every token0 holder's balance at once, the pool's included.
    function rebase(uint256 newIndex) external {
        newIndex = bound(newIndex, MIN_INDEX, MAX_INDEX);
        uint256 before = _balance0();
        rebasingToken.rebase(newIndex);
        uint256 afterRebase = _balance0();

        if (afterRebase >= before) donated0 += afterRebase - before;
        else deficit0 += before - afterRebase;
        _net0();
        rebases++;
        _checkKPerShare();
    }

    function removeLiquidity(uint256 actorSeed, uint256 liquidity) public override {
        (uint256 balanceBefore, uint256 reserveBefore) = (_balance0(), amm.reserve0());
        super.removeLiquidity(actorSeed, liquidity);
        _bookDust0(balanceBefore, reserveBefore);
    }

    function swap(uint256 actorSeed, bool zeroForOne, uint256 amountIn) public override {
        (uint256 balanceBefore, uint256 reserveBefore) = (_balance0(), amm.reserve0());
        super.swap(actorSeed, zeroForOne, amountIn);
        _bookDust0(balanceBefore, reserveBefore);
    }

    function donate(uint256 actorSeed, bool donate0, uint256 amount) public override {
        super.donate(actorSeed, donate0, amount);
        _net0();
    }

    /// @notice Booking a negative rebase spreads the loss over every share, so k per share is
    ///         allowed to fall here, but only by the fraction of token0 the pool actually lost.
    /// @dev Lowers the baseline before the base sync runs its usual check against it.
    ///      k per share after = b0 * b1 / S^2 >= (b0 / r0) * (r0 * r1 / S^2), because token1 can
    ///      only have grown (donations), so the scaled baseline is a lower bound even after flooring.
    function sync(uint256 actorSeed) public override {
        uint256 reserve0 = amm.reserve0();
        uint256 balance0 = _balance0();
        if (balance0 < reserve0) lastKPerShare = Math.mulDiv(lastKPerShare, balance0, reserve0);
        deficit0 = 0;
        super.sync(actorSeed);
    }

    /// @notice skim() can't send out a shortfall, so deficit0 survives it. Whatever rounding
    ///         left behind on token0 is still surplus afterwards, so it goes back into donated0.
    function skim(uint256 actorSeed) public override {
        super.skim(actorSeed);
        uint256 balance0 = _balance0();
        if (balance0 + deficit0 > amm.reserve0()) donated0 = balance0 + deficit0 - amm.reserve0();
    }

    /// @dev Same check as the base handler for token1. For token0, the books match once the
    ///      deficit is added back, give or take the token's transfer rounding.
    function _reservesMatchBalances() internal view override returns (bool) {
        uint256 held0 = _balance0() + deficit0;
        uint256 reserve0 = amm.reserve0();
        return held0 >= reserve0 && held0 <= reserve0 + MAX_DUST && amm.reserve1() == token1.balanceOf(address(amm));
    }

    /// @dev remove and swap book exactly what the pool sends, but the token can leave a little
    ///      behind. That leftover is real surplus above the reserves, skimmable like a donation.
    ///      Anything below 0 or above MAX_DUST means the pool's books and its balance diverged.
    function _bookDust0(uint256 balanceBefore, uint256 reserveBefore) internal {
        uint256 balanceAfter = _balance0();
        uint256 reserveAfter = amm.reserve0();
        if (balanceAfter + reserveBefore < balanceBefore + reserveAfter) {
            dustOutOfBounds = true;
            return;
        }
        uint256 dust = (balanceAfter + reserveBefore) - (balanceBefore + reserveAfter);
        if (dust > MAX_DUST) dustOutOfBounds = true;
        donated0 += dust;
        _net0();
    }

    /// @dev Cancel surplus against shortfall so at most one of them is nonzero.
    function _net0() internal {
        uint256 overlap = Math.min(donated0, deficit0);
        donated0 -= overlap;
        deficit0 -= overlap;
    }

    function _balance0() internal view returns (uint256) {
        return token0.balanceOf(address(amm));
    }
}
