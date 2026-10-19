# defi-amm

A Uniswap V2-style constant-product AMM (`x * y = k`) for a single token pair, written from scratch in Solidity with Foundry.

> **Work in progress.** Built in public, one milestone per commit. See the [roadmap](#roadmap) for what's done and what's next.

## Why

AMMs are the base layer of DeFi: most DEXs, lending liquidations and on-chain price oracles depend on them. I'm building one without copying Uniswap's code so I understand each design decision well enough to defend it: why the first deposit uses a square root, why some LP shares are burned forever, and why rounding always favors the pool.

## What it does (so far)

- **The pool is the LP token.** `SimpleAMM` inherits OpenZeppelin's `ERC20`, so shares are minted and burned directly by the pool.
- **First deposit sets the price.** The first LP receives `sqrt(amount0 * amount1)` shares (the geometric mean), which keeps the share value independent of the pair's price.
- **Inflation-attack guard.** The first 1,000 shares (`MINIMUM_LIQUIDITY`) are minted to `0x…dEaD` and locked forever, so the total supply can never drop back to zero and the first depositor can't manipulate the share price. `test/SimpleAMM.inflation.t.sol` runs the attack: seed the pool with dust for one share, donate 10,000 of each token and `sync()`, so one share is worth about 10 tokens. A 1,000-token deposit then rounds down and loses under 1 token, but the locked shares keep over 99% of the donation, so the attacker loses more than 9,900. A deposit worth less than one share reverts instead of minting 0, and a fuzz test checks that the attacker never gets back what they put in.
- **Ratio-matched deposits.** Later deposits pull only the amounts that match the current reserve ratio, so the caller is never charged for excess tokens.
- **Rounding favors the pool.** New shares are `min(amount0 * supply / reserve0, amount1 * supply / reserve1)`.
- **Swaps with a 0.3% fee.** `swap` sells an exact input for the other token. The fee stays in the pool, so `k` grows with every trade and LPs earn it pro rata.
- **Slippage limits.** `addLiquidity` and `removeLiquidity` take min amounts for each token, and `swap` takes `minAmountOut`. If the price moves before the tx lands, it reverts instead of filling at a worse rate.
- **Reentrancy guard.** Every state-changing function is `nonReentrant`, using OpenZeppelin's `ReentrancyGuardTransient` (the lock lives in EIP-1153 transient storage, so it's cheap and clears itself after each tx).
- **Checks-effects-interactions.** Reserves and shares update before any token transfer, and transfers use `SafeERC20`.
- **`skim(to)` recovers stray tokens.** Tokens sent straight to the pool never enter the reserves, so no LP can withdraw them. `skim` sends anything above the reserves to `to` and leaves the reserves alone. A side with nothing extra is skipped, so it never sends 0. Tests: `test/SimpleAMM.skim.t.sol`.
- **`sync()` books them instead.** It sets the reserves to the real balances, so tokens sent to the pool (or a rebase) become part of every LP's share. It updates the oracle the same way a trade does. Tests: `test/SimpleAMM.sync.t.sol`.
- **The invariant tests donate too.** The fuzzer's handler can send tokens straight to the pool, then `sync` or `skim` at random. So the invariant is `reserve <= balance` (the pool never books more than it holds), not `==`. The handler also tracks how much each donation actually added to the pool's balance (clearing it on `sync` or `skim`), and an exact invariant checks `reserve + donated == balance`, so a pool that books less than it receives is still caught. Two more invariants check that right after `sync()` the reserves equal the balances, and that `skim()` leaves the reserves unchanged and the balances back at the reserves.
- **TWAP price oracle.** The pool keeps Uniswap V2-style running sums of price × seconds, so other contracts can read a time-weighted average price. See [Price oracle](#price-oracle).

## Roadmap

| # | Milestone | Status |
|---|---|---|
| 1 | Contract skeleton: token pair, reserves, LP token | ✅ Done |
| 2 | `addLiquidity` | ✅ Done |
| 3 | `removeLiquidity` | ✅ Done |
| 4 | `swap` with 0.3% fee + `getAmountOut` | ✅ Done |
| 5 | Slippage protection (`minOut`), `ReentrancyGuard`, full events | ✅ Done |
| 6 | Test suite: unit, fuzz, and invariant (`k` never decreases) | ✅ Done (unit, reentrancy, fuzz, and handler-based invariants) |
| 7 | Sepolia deployment | 🔨 In progress (deploy script + script tests done; Sepolia broadcast next) |
| 8 | TWAP price oracle (cumulative prices) | ✅ Done |
| 9 | Fee-on-transfer tokens: book what actually arrived | ✅ Done |

## How to run

Requires [Foundry](https://getfoundry.sh/).

```bash
git clone --recurse-submodules https://github.com/mhaney93/defi-amm.git
cd defi-amm
forge build
forge test   # 124 tests (Foundry 1.8+ runs each invariant suite (8, 8 and 9 invariants) as one campaign, so it prints 102); add -vv for call counts
```

Deploy two test tokens plus a seeded pool (uses an encrypted keystore, so no private key in `.env`):

```bash
cp .env.example .env   # fill in SEPOLIA_RPC_URL and ETHERSCAN_API_KEY
cast wallet import deployer --interactive
source .env
forge script script/DeploySimpleAMM.s.sol --rpc-url $SEPOLIA_RPC_URL \
  --account deployer --sender <deployer address> --broadcast --verify
```

## Gas

Measured with `forge test --gas-report` on the unit tests (Foundry v1.8.4). Costs include the ERC20 transfers. Runtime size: 10,743 bytes (the EIP-170 limit is 24,576).

| Function | Median | Max | Notes |
|---|---|---|---|
| `addLiquidity` | 249,924 | 252,267 | Highest on the first deposit, which writes fresh storage and locks `MINIMUM_LIQUIDITY` |
| `swap` | 72,860 | 78,689 | |
| `removeLiquidity` | 58,100 | 84,432 | |

Each token pulled in costs two extra `balanceOf` calls, because the pool measures its balance before and after the transfer (see Fee-on-transfer tokens below).

`.gas-snapshot` records per-test gas for the unit tests, and CI fails if a change moves any of them by more than 1%. To update it on purpose: `forge snapshot --match-path test/SimpleAMM.t.sol`.

The unit tests all run in one block, so this table doesn't show the oracle's main cost: the first trade in each block also updates the price sums, about 16k more gas than a trade that doesn't touch them (2k for later trades in the same block). These are warm-storage figures from a single test transaction, so a real transaction pays a little more.

## Price oracle

Spot price is easy to manipulate: one large swap moves it, and a lending protocol that reads it can be drained in the same transaction. A time-weighted average price (TWAP) is much harder to move, because an attacker has to hold the distorted price for the whole averaging window.

- **Running sums.** `price0CumulativeLast` adds up `(reserve1 / reserve0) × seconds`, and `price1CumulativeLast` does the same for the inverse price. Prices are fixed point with 112 fractional bits (Uniswap V2's UQ112x112).
- **Updated once per block, before reserves change.** The first trade in a block adds the price that held since the last update; later trades in the same block add nothing. A swap followed by a swap back in the same block therefore can't move the average at all.
- **Reading a TWAP.** Take two readings of `currentCumulativePrices()` some time apart: `TWAP = (cumulativeEnd - cumulativeStart) / (timeEnd - timeStart)`. The view includes the seconds since the last trade, so no transaction to the pool is needed.
- **Overflow.** The sums are allowed to wrap, as in Uniswap V2; the difference between two readings is still correct if the reader subtracts in an `unchecked` block.

The oracle tests (`test/SimpleAMM.oracle.t.sol`) include one that dumps 10× the pool's reserve in a single swap: the spot price drops by more than 98%, but an hour-long TWAP ending in that block doesn't change, and one second later it has moved by less than 0.1%.

## Fee-on-transfer tokens

Some tokens take a cut on every transfer, so the pool receives less than the caller sent. If the pool booked the amount sent, its stored reserves would drift above its real balance, traders would be paid for tokens that never arrived, and the last LP to withdraw would hit a failed transfer. `test/SimpleAMM.feeOnTransfer.t.sol` reproduced all three in commit `85d4c6e`.

The fix is balance-delta accounting, as in Uniswap V2: `addLiquidity` and `swap` read the pool's balance, pull the tokens in, read it again, and use the difference.

- **Shares and swap output are priced on what arrived.** A 1%-fee token sending 10 is treated as 9.9.
- **The min amounts in `addLiquidity` are checked against what arrived**, so callers should allow for the fee.
- **Transfers now come before the state updates** in those two functions. That's safe because every function is `nonReentrant`, so a token can't call back into the pool mid-transfer (the reentrancy tests still pass).
- **Sending the fee token out needs no change.** The pool's balance drops by the full amount it sends; the trader just receives less. `minAmountOut` is checked against what the pool sends, not what the trader ends up with.

The fee-on-transfer tests now assert that reserves equal balances after deposits, swaps in both directions and a full exit, including a fuzz test over random amounts.

The invariant suite also runs against a fee token. `test/invariant/SimpleAMM.feeOnTransfer.invariant.t.sol` reuses the same handler and all 8 invariants, with token0 swapped for a token that burns 1% per transfer, so random sequences of adds, removes, swaps, donations, syncs and skims by several actors must never book more than the pool holds. Run against the pre-fix contract (`85d4c6e`), the reserves-vs-balances invariant (then `reservesMatchBalances`, now `reservesNeverExceedBalances`) fails on the first deposit (1000 booked, 990 held); against the current contract all 8 pass over 256 runs × 500 calls.

## Tokens that return false

Some older tokens don't revert when a transfer fails. They return `false` and move nothing. A pool that ignored the return value would book a deposit that never arrived, or pay out a swap for nothing.

Every transfer in the pool goes through OpenZeppelin's `SafeERC20`, which turns a `false` return into a revert. `test/SimpleAMM.returnsFalse.t.sol` uses a token that can be switched into returning `false` and checks all four transfer paths: a deposit, a swap paying in, a swap paying out, and a withdrawal. Each one reverts with `SafeERC20FailedOperation`, nothing is booked, and an LP whose withdrawal failed keeps their shares and can withdraw once the token works again.

## Tokens that revert on zero transfers

Some tokens revert on any transfer of 0. A pool that ever tried to send 0 (say, a payout that rounded down) would get stuck on one of these.

`test/SimpleAMM.revertOnZero.t.sol` pairs one with a normal token. The full lifecycle (deposit, swaps both ways, withdrawal) works. A dust swap whose output rounds to 0 and a dust withdrawal whose payout rounds to 0 both hit the pool's own check (`InsufficientOutputAmount`, `InsufficientLiquidityBurned`) before any transfer, so the pool never sends 0. The one place it asks for 0 is a deposit so lopsided that the matching amount of the scarce token rounds down to 0. That pull reverts with the token's error, but the same deposit with a normal token reverts a few lines later anyway because it would mint 0 shares, so the only difference is which error the caller sees.

## ERC777-style hook tokens

ERC777 tokens call hooks on their holders: `tokensToSend` on the sender before balances move, and `tokensReceived` on the recipient after. The before-hook hands control to the sender while the pool still shows the old balances. That's how Uniswap V1 pools holding imBTC were drained in 2020: the attacker traded again from inside the hook.

The reentrancy tests in `test/SimpleAMM.t.sol` use a token that calls back into the pool itself. `test/SimpleAMM.hooks.t.sol` covers the ERC777 shape, where the callbacks go to the user's own contract:

- **Hooks that leave the pool alone are harmless.** Both hooks fire during a deposit, a swap and a withdrawal, and reserves still equal balances afterwards.
- **Re-entering from either hook is blocked.** Swapping again from `tokensToSend`, withdrawing from `tokensToSend` mid-deposit, depositing from `tokensReceived` after a swap, and swapping from `tokensReceived` mid-withdrawal all revert with `ReentrancyGuardReentrantCall`.
- **A receiver that refuses tokens only blocks itself.** The pool only ever pays `msg.sender`, so an LP whose hook reverts can't withdraw, but everyone else can still swap and withdraw, and the LP keeps their shares until they fix the hook.

## Mixed decimals

The pool never reads `decimals()`; it only sees raw units. Pairing a 6-decimal token (like USDC) with a 24-decimal one means one whole token on each side differs by 10^18 raw units, which stresses the math from both ends. `test/SimpleAMM.decimals.t.sol` puts both in the same pool:

- **Small trades into the 6-decimal side round down.** A trade worth less than one raw unit of the 6-decimal token gets 0 out, and the pool reverts with `InsufficientOutputAmount` instead of keeping the input. A trade worth about 2 raw units gets 1 after the fee, and the rounding loss stays in the pool (k goes up).
- **Large 24-decimal amounts get close to the uint256 limit.** Reserves here are `uint256`, not capped at `uint112` like Uniswap V2, and `getAmountOut` multiplies before it divides. A trillion-token supply at 24 decimals (10^36 raw units) still fits with lots of room, but amounts around 10^35 against reserves of 10^40 overflow. Solidity 0.8's checked arithmetic makes that revert instead of wrapping around, so the worst case is a pool that can't trade, not a mispriced trade.

## Static analysis

CI runs [Slither](https://github.com/crytic/slither) on `src/` and fails on any finding. Run it locally with `pip install slither-analyzer` then `slither .`.

The first run flagged two things:

- **`divide-before-multiply` in `addLiquidity`.** The ratio-matched deposit amount is floored, then used in the share math. This is intended: flooring only makes the deposit smaller, and the share math floors again, so the rounding loss stays in the pool. It's suppressed inline with a comment explaining why.
- **`uninitialized-local` in `swap`.** `zeroForOne` relied on the default `false`. It was harmless, but it's now set explicitly.

The oracle added a third: **`timestamp`**, because the pool compares `block.timestamp`. It's suppressed with a comment: the timestamp only measures elapsed time, so a validator shifting it by a few seconds just moves a little weight between two real prices. It can't create a price.

Balance-delta accounting added a fourth: **`incorrect-equality`** on six `== 0` checks, because those values now come from `balanceOf`, which anyone can raise by sending tokens straight to the pool. Each check only reverts on zero, and raising a value from zero just makes it a normal, valid state, so none of them can be gamed. This detector is excluded in `slither.config.json`.

## Known limitations

**Rebasing tokens need someone to call `sync()`.** Their balances change without any transfer, so the stored reserves drift away from the real balance until someone calls `sync()`. `test/SimpleAMM.rebasing.t.sol` uses a shares-based token (like stETH) to show both sides:

- **Positive rebase without sync: the extra is stranded.** After a +10% rebase the pool holds 110 but still prices trades on 100. When the only LP exits she gets her share of the 100, and a later deposit doesn't pick up the other 10 either, because the pool books only what arrives. `skim()` can get it out, but to whoever calls it first, not to the LPs.
- **Negative rebase without sync: the last LP out takes the whole loss.** After a -10% rebase with two equal LPs, the pool holds 180 but owes 200. The first LP to exit gets a full 100, and the second one's withdrawal then reverts, because it needs 100 from a pool holding 80.
- **With sync, LPs share it pro rata.** Calling `sync()` right after the rebase gives the +10% to the LP, and splits the -10% so each LP gets about 90.

The invariant suite runs with a rebasing token too. `test/invariant/SimpleAMM.rebasing.invariant.t.sol` gives the handler a `rebase` action (anywhere from -50% to +100%) on top of the usual adds, removes, swaps, donations, syncs and skims. A negative rebase breaks `reserve <= balance` on purpose, so the handler tracks the shortfall separately as `deficit0`, and the balance invariants become `reserve <= balance + deficit` and `reserve + donated == balance + deficit`. Rebases also allow one exception to "k per share never decreases": when `sync()` books a loss, k per share is allowed to fall, but only by the fraction of token0 the rebase took. A ninth invariant checks the token's rounding: each transfer out of the pool can leave at most 2 wei behind (the token moves whole shares and rounds down), and never less than the pool booked. All 9 pass over 256 runs × 500 calls. Removing the k-per-share allowance or the deficit tracking makes them fail.

The catch is that the pool doesn't call `sync()` itself. Between a negative rebase and the next sync, an LP who sees it coming can exit first at the old reserves and leave the loss to everyone else. The safer option is still to hold the wrapped, non-rebasing version (wstETH rather than stETH).

**Freezable tokens put the pool under the issuer's control.** USDC and USDT can blocklist an address at the token contract. If the pool's own address were blocklisted, its balance of that token would be stuck, and nothing in the pool's code can get it out. LPs in a pool with a freezable token are trusting the issuer on top of the contract.

## Stack

Solidity ^0.8.24 · Foundry · OpenZeppelin Contracts v5

## Author

Matthew Haney · [LinkedIn](https://www.linkedin.com/in/matthewhaney93/) · [GitHub](https://github.com/mhaney93)
