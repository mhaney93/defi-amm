// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SimpleAMM} from "../src/SimpleAMM.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice The first-depositor inflation attack. The attacker seeds the pool with dust for a single share,
///         donates a large amount and calls sync() so each share is worth a lot, then waits for a victim
///         whose deposit rounds down to fewer shares than it paid for. The 1,000 shares locked on the first
///         deposit (MINIMUM_LIQUIDITY) own most of the donation, so the attacker loses far more than any
///         victim does.
contract SimpleAMMInflationTest is Test {
    SimpleAMM amm;
    MockERC20 token0;
    MockERC20 token1;

    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");

    function setUp() public {
        token0 = new MockERC20("Token A", "TKA");
        token1 = new MockERC20("Token B", "TKB");
        amm = new SimpleAMM(address(token0), address(token1));

        address[2] memory users = [attacker, victim];
        for (uint256 i; i < users.length; i++) {
            token0.mint(users[i], 1e30);
            token1.mint(users[i], 1e30);
            vm.startPrank(users[i]);
            token0.approve(address(amm), type(uint256).max);
            token1.approve(address(amm), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// @dev Seed with `seed` of each token, then donate `donation` of each and sync. Returns the
    ///      attacker's total spend per token.
    function _setUpAttack(uint256 seed, uint256 donation) internal returns (uint256 spent) {
        vm.startPrank(attacker);
        amm.addLiquidity(seed, seed, 0, 0);
        token0.transfer(address(amm), donation);
        token1.transfer(address(amm), donation);
        amm.sync();
        vm.stopPrank();
        return seed + donation;
    }

    /// @dev The textbook setup: the smallest seed that mints anything (1,001 wei each gives 1 share),
    ///      then 10,000 tokens donated, so one share is worth about 10 tokens. A 1,000-token deposit
    ///      rounds down and the victim loses under 1 token, while the attacker loses almost all 10,000.
    function test_inflation_attackerLosesFarMoreThanVictim() public {
        uint256 spent = _setUpAttack(1001, 10_000e18);
        assertEq(amm.balanceOf(attacker), 1);
        assertEq(amm.totalSupply(), 1001);

        vm.prank(victim);
        (,, uint256 victimShares) = amm.addLiquidity(1_000e18, 1_000e18, 0, 0);

        // Withdraw both positions in full and compare with what each one put in.
        vm.prank(victim);
        (uint256 victimOut,) = amm.removeLiquidity(victimShares, 0, 0);
        vm.prank(attacker);
        (uint256 attackerOut,) = amm.removeLiquidity(1, 0, 0);

        uint256 victimLoss = 1_000e18 - victimOut;
        uint256 attackerLoss = spent - attackerOut;

        // The victim pays for the rounding, but less than one share's worth (about 10 tokens).
        assertGt(victimLoss, 0);
        assertLt(victimLoss, 1e18);
        // The locked shares keep over 99% of the donation, so the attacker pays over 1,000x what the victim lost.
        assertGt(attackerLoss, 9_900e18);
        assertGt(attackerLoss, victimLoss * 1_000);
    }

    /// @dev A deposit worth less than one inflated share would mint 0. The pool reverts instead of taking
    ///      the tokens, so the victim keeps them.
    function test_inflation_depositBelowOneShare_reverts() public {
        _setUpAttack(1001, 10_000e18);

        vm.prank(victim);
        vm.expectRevert(SimpleAMM.InsufficientLiquidityMinted.selector);
        amm.addLiquidity(1e18, 1e18, 0, 0);

        assertEq(token0.balanceOf(victim), 1e30);
        assertEq(token1.balanceOf(victim), 1e30);
    }

    /// @dev For any seed, donation and victim deposit, the attacker never gets back what they put in.
    function testFuzz_inflation_neverProfitable(uint256 seed, uint256 donation, uint256 deposit) public {
        seed = bound(seed, 1001, 1e24);
        donation = bound(donation, 0, 1e27);
        deposit = bound(deposit, 1, 1e27);

        uint256 spent = _setUpAttack(seed, donation);

        // Skip deposits too small to mint a share; the test above covers those.
        if ((deposit * amm.totalSupply()) / amm.reserve0() == 0) return;
        vm.prank(victim);
        amm.addLiquidity(deposit, deposit, 0, 0);

        uint256 attackerShares = amm.balanceOf(attacker);
        vm.prank(attacker);
        (uint256 out0, uint256 out1) = amm.removeLiquidity(attackerShares, 0, 0);

        assertLe(out0, spent);
        assertLe(out1, spent);
    }
}
