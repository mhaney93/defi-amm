# defi-amm

A Uniswap V2-style constant-product AMM (`x * y = k`) for a single token pair, written from scratch in Solidity with Foundry.

> **Work in progress.** Built in public, one milestone per commit. See the [roadmap](#roadmap) for what's done and what's next.

## Why

AMMs are the base layer of DeFi: most DEXs, lending liquidations and on-chain price oracles depend on them. I'm building one without copying Uniswap's code so I understand each design decision well enough to defend it: why the first deposit uses a square root, why some LP shares are burned forever, and why rounding always favors the pool.

## What it does (so far)

- **The pool is the LP token.** `SimpleAMM` inherits OpenZeppelin's `ERC20`, so shares are minted and burned directly by the pool.
- **First deposit sets the price.** The first LP receives `sqrt(amount0 * amount1)` shares (the geometric mean), which keeps the share value independent of the pair's price.
- **Inflation-attack guard.** The first 1,000 shares (`MINIMUM_LIQUIDITY`) are minted to `0x…dEaD` and locked forever, so the total supply can never drop back to zero and the first depositor can't manipulate the share price.
- **Ratio-matched deposits.** Later deposits pull only the amounts that match the current reserve ratio, so the caller is never charged for excess tokens.
- **Rounding favors the pool.** New shares are `min(amount0 * supply / reserve0, amount1 * supply / reserve1)`.
- **Swaps with a 0.3% fee.** `swap` sells an exact input for the other token. The fee stays in the pool, so `k` grows with every trade and LPs earn it pro rata.
- **Slippage limits.** `addLiquidity` and `removeLiquidity` take min amounts for each token, and `swap` takes `minAmountOut`. If the price moves before the tx lands, it reverts instead of filling at a worse rate.
- **Reentrancy guard.** Every state-changing function is `nonReentrant`, using OpenZeppelin's `ReentrancyGuardTransient` (the lock lives in EIP-1153 transient storage, so it's cheap and clears itself after each tx).
- **Checks-effects-interactions.** Reserves and shares update before any token transfer, and transfers use `SafeERC20`.
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
| 9 | Fee-on-transfer tokens: book what actually arrived | 🔨 In progress (problem reproduced in tests; fix next) |

## How to run

Requires [Foundry](https://getfoundry.sh/).

```bash
git clone --recurse-submodules https://github.com/mhaney93/defi-amm.git
cd defi-amm
forge build
forge test   # 57 tests (Foundry 1.8+ runs the 5 invariants as one campaign, so it prints 53); add -vv for call counts
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

Measured with `forge test --gas-report` on the unit tests (Foundry v1.8.4). Costs include the ERC20 transfers. Runtime size: 9,467 bytes (the EIP-170 limit is 24,576).

| Function | Median | Max | Notes |
|---|---|---|---|
| `addLiquidity` | 243,122 | 245,419 | Highest on the first deposit, which writes fresh storage and locks `MINIMUM_LIQUIDITY` |
| `swap` | 74,711 | 75,331 | |
| `removeLiquidity` | 58,133 | 84,454 | |

`.gas-snapshot` records per-test gas for the unit tests, and CI fails if a change moves any of them by more than 1%. To update it on purpose: `forge snapshot --match-path test/SimpleAMM.t.sol`.

The unit tests all run in one block, so this table doesn't show the oracle's main cost: the first trade in each block also updates the price sums, about 16k more gas than a trade that doesn't touch them (2k for later trades in the same block). These are warm-storage figures from a single test transaction, so a real transaction pays a little more.

## Price oracle

Spot price is easy to manipulate: one large swap moves it, and a lending protocol that reads it can be drained in the same transaction. A time-weighted average price (TWAP) is much harder to move, because an attacker has to hold the distorted price for the whole averaging window.

- **Running sums.** `price0CumulativeLast` adds up `(reserve1 / reserve0) × seconds`, and `price1CumulativeLast` does the same for the inverse price. Prices are fixed point with 112 fractional bits (Uniswap V2's UQ112x112).
- **Updated once per block, before reserves change.** The first trade in a block adds the price that held since the last update; later trades in the same block add nothing. A swap followed by a swap back in the same block therefore can't move the average at all.
- **Reading a TWAP.** Take two readings of `currentCumulativePrices()` some time apart: `TWAP = (cumulativeEnd - cumulativeStart) / (timeEnd - timeStart)`. The view includes the seconds since the last trade, so no transaction to the pool is needed.
- **Overflow.** The sums are allowed to wrap, as in Uniswap V2; the difference between two readings is still correct if the reader subtracts in an `unchecked` block.

The oracle tests (`test/SimpleAMM.oracle.t.sol`) include one that dumps 10× the pool's reserve in a single swap: the spot price drops by more than 98%, but an hour-long TWAP ending in that block doesn't change, and one second later it has moved by less than 0.1%.

## Static analysis

CI runs [Slither](https://github.com/crytic/slither) on `src/` and fails on any finding. Run it locally with `pip install slither-analyzer` then `slither .`.

The first run flagged two things:

- **`divide-before-multiply` in `addLiquidity`.** The ratio-matched deposit amount is floored, then used in the share math. This is intended: flooring only makes the deposit smaller, and the share math floors again, so the rounding loss stays in the pool. It's suppressed inline with a comment explaining why.
- **`uninitialized-local` in `swap`.** `zeroForOne` relied on the default `false`. It was harmless, but it's now set explicitly.

The oracle added a third: **`timestamp`**, because the pool compares `block.timestamp`. It's suppressed with a comment: the timestamp only measures elapsed time, so a validator shifting it by a few seconds just moves a little weight between two real prices. It can't create a price.

## Known limitations

**Fee-on-transfer tokens break the accounting.** The pool books the amount the caller asked to send, not the amount that arrived. If a token takes a cut on every transfer, the stored reserves end up higher than the pool's real balance:

- a deposit of 100 tokens records 100 but only 99 arrive;
- a swap prices the trader as if the full input arrived, so they're paid for tokens the pool never got;
- the gap grows with every trade, and the last LP to withdraw hits a failed transfer because the pool doesn't hold what its reserves say.

`test/SimpleAMM.feeOnTransfer.t.sol` reproduces all three with a 1%-fee mock token. The fix (roadmap row 9) is to measure each token's balance before and after the transfer in, and book the difference, like Uniswap V2 does. Rebasing tokens, whose balances change without any transfer, have the same problem and aren't supported either.

## Stack

Solidity ^0.8.24 · Foundry · OpenZeppelin Contracts v5

## Author

Matthew Haney · [LinkedIn](https://www.linkedin.com/in/matthewhaney93/) · [GitHub](https://github.com/mhaney93)
