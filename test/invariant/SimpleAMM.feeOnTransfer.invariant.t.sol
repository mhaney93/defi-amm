// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "../mocks/MockERC20.sol";
import {FeeOnTransferToken} from "../mocks/FeeOnTransferToken.sol";
import {IMintableERC20} from "../mocks/IMintableERC20.sol";
import {SimpleAMMInvariantTest} from "./SimpleAMM.invariant.t.sol";

/// @notice The same 8 invariants and the same handler, but token0 burns 1% on every transfer.
///         The unit tests check fee-on-transfer behavior on hand-picked paths; this runs random
///         sequences of adds, removes, swaps in both directions, donations, syncs and skims
///         by several actors.
/// @dev Before the balance-delta fix (b5c02a6), reservesMatchBalances failed here on the
///      first deposit, because the pool booked the amount sent instead of the amount received.
///      That invariant is now reservesNeverExceedBalances, which still catches it (1000 > 990).
contract SimpleAMMFeeOnTransferInvariantTest is SimpleAMMInvariantTest {
    function _deployTokens() internal override returns (IMintableERC20, IMintableERC20) {
        return (
            IMintableERC20(address(new FeeOnTransferToken("Fee Token", "FEE"))),
            IMintableERC20(address(new MockERC20("Token B", "TKB")))
        );
    }
}
