// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SimpleAMM} from "../src/SimpleAMM.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ReturnsFalseToken} from "./mocks/ReturnsFalseToken.sol";

/// @notice Pool behavior when token0 returns false on a failed transfer instead of reverting.
///         Every transfer goes through SafeERC20, which turns a false return into a revert, so a
///         transfer that moved nothing can never be booked as if it worked.
contract SimpleAMMReturnsFalseTest is Test {
    SimpleAMM amm;
    ReturnsFalseToken token0;
    MockERC20 token1;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        token0 = new ReturnsFalseToken("False Token", "FALSE");
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

    function _expectFailedOperation() internal {
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token0)));
    }

    function test_addLiquidity_revertsWhenTransferInReturnsFalse() public {
        token0.setFailing(true);

        vm.prank(alice);
        _expectFailedOperation();
        amm.addLiquidity(100e18, 100e18, 0, 0);

        assertEq(amm.totalSupply(), 0);
        assertEq(amm.reserve0(), 0);
        assertEq(amm.reserve1(), 0);
    }

    function test_swap_revertsWhenTokenInReturnsFalse() public {
        _seed();
        token0.setFailing(true);

        vm.prank(bob);
        _expectFailedOperation();
        amm.swap(address(token0), 10e18, 0);

        assertEq(amm.reserve0(), 100e18);
        assertEq(amm.reserve1(), 100e18);
        assertEq(token1.balanceOf(bob), 1_000e18, "bob got paid for tokens that never arrived");
    }

    /// @dev The payout side fails too. The whole call reverts, so the LP keeps their shares and
    ///      can withdraw once the token works again.
    function test_removeLiquidity_revertsWhenPayoutReturnsFalse_sharesKept() public {
        uint256 liquidity = _seed();
        token0.setFailing(true);

        vm.prank(alice);
        _expectFailedOperation();
        amm.removeLiquidity(liquidity, 0, 0);

        assertEq(amm.balanceOf(alice), liquidity);
        assertEq(amm.reserve0(), 100e18);

        token0.setFailing(false);
        vm.prank(alice);
        amm.removeLiquidity(liquidity, 0, 0);
        assertEq(amm.balanceOf(alice), 0);
    }

    function test_swap_revertsWhenTokenOutReturnsFalse() public {
        _seed();
        token0.setFailing(true);

        vm.prank(bob);
        _expectFailedOperation();
        amm.swap(address(token1), 10e18, 0);

        assertEq(amm.reserve0(), 100e18);
        assertEq(amm.reserve1(), 100e18);
    }
}
