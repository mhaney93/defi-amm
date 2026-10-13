// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SimpleAMM} from "../src/SimpleAMM.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {HookToken, HookUser} from "./mocks/HookToken.sol";

/// @notice Pool behavior when token0 has ERC777-style hooks. Unlike ReentrantToken (where the token
///         itself calls back), here the callbacks go to the USER, which is how real ERC777 tokens
///         work: `tokensToSend` runs before balances move, `tokensReceived` after.
///         The Uniswap V1 / imBTC drain used the before-hook to trade again against prices that
///         hadn't caught up yet. In this pool every entry point is nonReentrant, so a hook can run
///         but can't get back into the pool.
contract SimpleAMMHooksTest is Test {
    SimpleAMM amm;
    HookToken token0;
    MockERC20 token1;
    HookUser user;

    address alice = makeAddr("alice");

    function setUp() public {
        token0 = new HookToken();
        token1 = new MockERC20("Token B", "TKB");
        amm = new SimpleAMM(address(token0), address(token1));

        // alice is a plain EOA with no hook. She seeds the pool.
        token0.mint(alice, 1_000e18);
        token1.mint(alice, 1_000e18);
        vm.startPrank(alice);
        token0.approve(address(amm), type(uint256).max);
        token1.approve(address(amm), type(uint256).max);
        amm.addLiquidity(100e18, 100e18, 0, 0);
        vm.stopPrank();

        user = _newHookUser();
    }

    function _newHookUser() internal returns (HookUser u) {
        u = new HookUser(address(amm));
        token0.mint(address(u), 1_000e18);
        token1.mint(address(u), 1_000e18);
        u.execute(address(token0), abi.encodeCall(token0.approve, (address(amm), type(uint256).max)));
        u.execute(address(token1), abi.encodeCall(token1.approve, (address(amm), type(uint256).max)));
        u.execute(address(token0), abi.encodeCall(HookToken.setHook, (address(u))));
    }

    function _assertReservesMatchBalances() internal view {
        assertEq(amm.reserve0(), token0.balanceOf(address(amm)));
        assertEq(amm.reserve1(), token1.balanceOf(address(amm)));
    }

    /// @dev Hooks that don't touch the pool are harmless: both fire and the accounting holds.
    function test_hooksFire_fullLifecycleWorks() public {
        bytes memory ret = user.execute(address(amm), abi.encodeCall(amm.addLiquidity, (10e18, 10e18, 0, 0)));
        (,, uint256 liquidity) = abi.decode(ret, (uint256, uint256, uint256));
        assertEq(user.sendCalls(), 1); // token0 pulled in

        user.execute(address(amm), abi.encodeCall(amm.swap, (address(token1), 5e18, 0)));
        assertEq(user.receiveCalls(), 1); // token0 paid out

        user.execute(address(amm), abi.encodeCall(amm.removeLiquidity, (liquidity, 0, 0)));
        assertEq(user.receiveCalls(), 2);
        assertEq(amm.balanceOf(address(user)), 0);
        _assertReservesMatchBalances();
    }

    /// @dev The imBTC shape: pay token0 in, and from tokensToSend (before any balance has moved)
    ///      try to swap again. Blocked by the lock.
    function test_tokensToSend_reenterSwap_blocked() public {
        user.setReenterOnSend(abi.encodeCall(amm.swap, (address(token0), 1e18, 0)));

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        user.execute(address(amm), abi.encodeCall(amm.swap, (address(token0), 10e18, 0)));
    }

    /// @dev Same before-hook, but during a deposit, trying to pull liquidity out mid-deposit.
    function test_tokensToSend_reenterRemoveDuringAdd_blocked() public {
        user.execute(address(amm), abi.encodeCall(amm.addLiquidity, (10e18, 10e18, 0, 0)));
        user.setReenterOnSend(abi.encodeCall(amm.removeLiquidity, (1e18, 0, 0)));

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        user.execute(address(amm), abi.encodeCall(amm.addLiquidity, (10e18, 10e18, 0, 0)));
    }

    /// @dev tokensReceived fires when the pool pays token0 out of a swap. Re-entering from there
    ///      (here: depositing) is blocked too, because the swap hasn't returned yet.
    function test_tokensReceived_reenterAfterSwapOut_blocked() public {
        user.setReenterOnReceive(abi.encodeCall(amm.addLiquidity, (1e18, 1e18, 0, 0)));

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        user.execute(address(amm), abi.encodeCall(amm.swap, (address(token1), 5e18, 0)));
    }

    /// @dev tokensReceived also fires on a withdrawal. Swapping from inside it is blocked.
    function test_tokensReceived_reenterDuringRemove_blocked() public {
        bytes memory ret = user.execute(address(amm), abi.encodeCall(amm.addLiquidity, (10e18, 10e18, 0, 0)));
        (,, uint256 liquidity) = abi.decode(ret, (uint256, uint256, uint256));
        user.setReenterOnReceive(abi.encodeCall(amm.swap, (address(token1), 1e18, 0)));

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        user.execute(address(amm), abi.encodeCall(amm.removeLiquidity, (liquidity, 0, 0)));
    }

    /// @dev A hook that refuses incoming tokens only hurts its own owner. The pool only ever pays
    ///      msg.sender, so one bad receiver can't block anyone else's swap or withdrawal. Once the
    ///      owner fixes the hook, the shares are still there.
    function test_refusingReceiver_onlyBlocksItself() public {
        bytes memory ret = user.execute(address(amm), abi.encodeCall(amm.addLiquidity, (10e18, 10e18, 0, 0)));
        (,, uint256 liquidity) = abi.decode(ret, (uint256, uint256, uint256));
        user.setRefuseIncoming(true);

        vm.expectRevert(HookUser.Refused.selector);
        user.execute(address(amm), abi.encodeCall(amm.removeLiquidity, (liquidity, 0, 0)));
        assertEq(amm.balanceOf(address(user)), liquidity);

        // Everyone else carries on.
        vm.startPrank(alice);
        amm.swap(address(token1), 5e18, 0);
        amm.removeLiquidity(amm.balanceOf(alice), 0, 0);
        vm.stopPrank();
        assertEq(amm.balanceOf(alice), 0);

        user.setRefuseIncoming(false);
        user.execute(address(amm), abi.encodeCall(amm.removeLiquidity, (liquidity, 0, 0)));
        assertEq(amm.balanceOf(address(user)), 0);
        _assertReservesMatchBalances();
    }
}
