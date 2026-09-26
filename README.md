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
- **Checks-effects-interactions.** Reserves and shares update before any token transfer, and transfers use `SafeERC20`.

## Roadmap

| # | Milestone | Status |
|---|---|---|
| 1 | Contract skeleton: token pair, reserves, LP token | ✅ Done |
| 2 | `addLiquidity` | ✅ Done |
| 3 | `removeLiquidity` | ✅ Done |
| 4 | `swap` with 0.3% fee + `getAmountOut` | ⏳ Next |
| 5 | Slippage protection (`minOut`), `ReentrancyGuard`, full events | |
| 6 | Test suite: unit, fuzz, and invariant (`k` never decreases) | |
| 7 | Sepolia deployment | |

## How to run

Requires [Foundry](https://getfoundry.sh/).

```bash
git clone --recurse-submodules https://github.com/mhaney93/defi-amm.git
cd defi-amm
forge build
forge test   # the test suite arrives in milestone 6
```

## Stack

Solidity ^0.8.24 · Foundry · OpenZeppelin Contracts v5

## Author

Matthew Haney · [LinkedIn](https://www.linkedin.com/in/matthewhaney93/) · [GitHub](https://github.com/mhaney93)
