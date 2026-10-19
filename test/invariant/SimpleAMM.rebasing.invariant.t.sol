// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "../mocks/MockERC20.sol";
import {RebasingToken} from "../mocks/RebasingToken.sol";
import {IMintableERC20} from "../mocks/IMintableERC20.sol";
import {SimpleAMMHandler} from "./SimpleAMMHandler.sol";
import {SimpleAMMRebasingHandler} from "./SimpleAMMRebasingHandler.sol";
import {SimpleAMMInvariantTest} from "./SimpleAMM.invariant.t.sol";

/// @notice The same invariants with token0 a shares-based rebasing token, and a handler that can
///         rebase it anywhere from -50% to +100% between any two calls.
/// @dev A negative rebase breaks reserve <= balance on purpose: the pool has booked tokens that
///      no longer exist. So the shortfall is tracked as its own ghost (deficit0) and the two
///      balance invariants add it back. sync() is the one call allowed to lower k per share,
///      and only by the fraction of token0 the rebase took (see the handler's sync).
contract SimpleAMMRebasingInvariantTest is SimpleAMMInvariantTest {
    SimpleAMMRebasingHandler rebasingHandler;

    function _deployTokens() internal override returns (IMintableERC20, IMintableERC20) {
        return (
            IMintableERC20(address(new RebasingToken("Rebasing Token", "REB"))),
            IMintableERC20(address(new MockERC20("Token B", "TKB")))
        );
    }

    function _deployHandler() internal override returns (SimpleAMMHandler) {
        rebasingHandler = new SimpleAMMRebasingHandler(amm, token0, token1);
        return rebasingHandler;
    }

    /// @notice The pool never books more token0 than it holds plus what negative rebases took.
    function invariant_reservesNeverExceedBalances() public view override {
        assertLe(amm.reserve0(), token0.balanceOf(address(amm)) + rebasingHandler.deficit0());
        assertLe(amm.reserve1(), token1.balanceOf(address(amm)));
    }

    /// @notice Exact books: reserves plus surplus (donations, positive rebases, transfer rounding)
    ///         equal the balances plus the shortfall from negative rebases.
    function invariant_reservesPlusDonationsEqualBalances() public view override {
        assertEq(amm.reserve0() + handler.donated0(), token0.balanceOf(address(amm)) + rebasingHandler.deficit0());
        assertEq(amm.reserve1() + handler.donated1(), token1.balanceOf(address(amm)));
    }

    /// @notice Each transfer out of the pool leaves at most the token's rounding behind, never less
    ///         than the pool booked.
    function invariant_transferDustBounded() public view {
        assertFalse(rebasingHandler.dustOutOfBounds());
    }

    function afterInvariant() public override {
        super.afterInvariant();
        emit log_named_uint("rebases", rebasingHandler.rebases());
    }
}
