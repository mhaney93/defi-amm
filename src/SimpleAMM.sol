// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title SimpleAMM
/// @notice Constant-product (x * y = k) AMM for a single token pair.
///         The pool contract is itself the ERC20 LP token.
/// @dev Every state-changing function is nonReentrant. The lock lives in transient storage
///      (EIP-1153), so it costs far less gas than a storage flag and clears itself after each tx.
contract SimpleAMM is ERC20, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    error IdenticalTokens();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InvalidToken();
    error InsufficientLiquidity();
    error InsufficientOutputAmount();
    error InsufficientAmount0();
    error InsufficientAmount1();

    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1, uint256 liquidity);
    event LiquidityRemoved(address indexed provider, uint256 amount0, uint256 amount1, uint256 liquidity);
    /// @dev amountIn is what the pool received, which is less than what was sent for a fee-on-transfer token.
    event Swap(address indexed trader, address indexed tokenIn, uint256 amountIn, uint256 amountOut);
    event Skim(address indexed caller, address indexed to, uint256 amount0, uint256 amount1);
    event Sync(uint256 reserve0, uint256 reserve1);

    /// @notice Swap fee is 0.3%, expressed as 997/1000 of the input going into the curve.
    uint256 public constant FEE_NUMERATOR = 997;
    uint256 public constant FEE_DENOMINATOR = 1000;

    /// @notice LP shares locked forever on the first deposit, so total supply can never
    ///         return to zero and the first depositor can't inflate the share price.
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    /// @dev OpenZeppelin's ERC20 refuses to mint to address(0), so locked shares go here.
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable token0;
    IERC20 public immutable token1;

    uint256 public reserve0;
    uint256 public reserve1;

    /// @dev Prices are stored as fixed point numbers with 112 fractional bits (Uniswap V2's UQ112x112),
    ///      so a price of 1.0 is 2**112 and fractional prices keep their precision.
    uint256 private constant Q112 = 2 ** 112;

    /// @notice Running sum of (token1 per token0 price) * seconds, for time-weighted average prices.
    /// @dev An oracle reads this twice and divides the difference by the seconds between the reads:
    ///      TWAP = (cumulativeEnd - cumulativeStart) / (timeEnd - timeStart). The sums are allowed to wrap
    ///      on overflow, and the subtraction still gives the right answer as long as the reader also wraps.
    uint256 public price0CumulativeLast;
    /// @notice Running sum of (token0 per token1 price) * seconds.
    uint256 public price1CumulativeLast;
    /// @notice Timestamp of the last block that changed the reserves.
    uint256 public blockTimestampLast;

    constructor(address _token0, address _token1) ERC20("SimpleAMM LP", "SAMM-LP") {
        if (_token0 == _token1) revert IdenticalTokens();
        if (_token0 == address(0) || _token1 == address(0)) revert ZeroAddress();

        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
    }

    /// @notice Deposit both tokens and receive LP shares.
    /// @dev After the first deposit, only the amounts that match the current reserve ratio
    ///      are pulled, so the caller is never charged for the excess of either token.
    ///      The min amounts protect the caller if the ratio moves before the tx lands.
    ///      Tokens are pulled in first and shares are priced on what actually arrived, so a
    ///      fee-on-transfer token can't credit the pool with more than it received.
    /// @param amount0Desired Max amount of token0 the caller is willing to deposit.
    /// @param amount1Desired Max amount of token1 the caller is willing to deposit.
    /// @param amount0Min Revert if the pool receives less than this much token0.
    /// @param amount1Min Revert if the pool receives less than this much token1.
    /// @return amount0 Amount of token0 the pool actually received.
    /// @return amount1 Amount of token1 the pool actually received.
    /// @return liquidity LP shares minted to the caller.
    function addLiquidity(uint256 amount0Desired, uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1, uint256 liquidity)
    {
        if (amount0Desired == 0 || amount1Desired == 0) revert ZeroAmount();

        uint256 _reserve0 = reserve0;
        uint256 _reserve1 = reserve1;
        uint256 supply = totalSupply();

        // Work out how much of each token to pull. After the first deposit, match the current ratio:
        // use all of one token and the proportional amount of the other.
        if (supply == 0) {
            (amount0, amount1) = (amount0Desired, amount1Desired);
        } else {
            uint256 amount1Optimal = (amount0Desired * _reserve1) / _reserve0;
            if (amount1Optimal <= amount1Desired) {
                (amount0, amount1) = (amount0Desired, amount1Optimal);
            } else {
                // Slither flags this as divide-before-multiply because the floored quote feeds the share
                // math below. That's intended: flooring only shrinks the deposit, and the share math floors
                // again, so any rounding loss stays in the pool (Uniswap V2's quote() works the same way).
                // slither-disable-next-line divide-before-multiply
                uint256 amount0Optimal = (amount1Desired * _reserve0) / _reserve1;
                (amount0, amount1) = (amount0Optimal, amount1Desired);
            }
        }

        // Pull first, then book only what arrived. This puts the transfers before the state updates,
        // which is safe here because nonReentrant blocks any callback into the pool.
        amount0 = _pullIn(token0, amount0);
        amount1 = _pullIn(token1, amount1);
        if (amount0 < amount0Min) revert InsufficientAmount0();
        if (amount1 < amount1Min) revert InsufficientAmount1();

        if (supply == 0) {
            // First deposit sets the price. Shares = geometric mean of the two amounts.
            liquidity = Math.sqrt(amount0 * amount1);
            if (liquidity <= MINIMUM_LIQUIDITY) revert InsufficientLiquidityMinted();
            liquidity -= MINIMUM_LIQUIDITY;
            _mint(DEAD, MINIMUM_LIQUIDITY);
        } else {
            // Take the smaller share so rounding always favors the pool, never the depositor.
            // If a transfer fee shrank one side, the extra of the other side stays in the pool.
            liquidity = Math.min((amount0 * supply) / _reserve0, (amount1 * supply) / _reserve1);
            if (liquidity == 0) revert InsufficientLiquidityMinted();
        }

        _updateReserves(_reserve0 + amount0, _reserve1 + amount1);
        _mint(msg.sender, liquidity);

        emit LiquidityAdded(msg.sender, amount0, amount1, liquidity);
    }

    /// @notice Burn LP shares and withdraw the matching share of both reserves.
    /// @dev Payout is pro rata: amount = liquidity * reserve / totalSupply, for each token.
    ///      The min amounts protect the caller if reserves shift before the tx lands.
    /// @param liquidity LP shares to burn from the caller.
    /// @param amount0Min Revert if less than this much token0 would be paid out.
    /// @param amount1Min Revert if less than this much token1 would be paid out.
    /// @return amount0 Amount of token0 sent to the caller.
    /// @return amount1 Amount of token1 sent to the caller.
    function removeLiquidity(uint256 liquidity, uint256 amount0Min, uint256 amount1Min)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (liquidity == 0) revert ZeroAmount();

        uint256 _reserve0 = reserve0;
        uint256 _reserve1 = reserve1;
        uint256 supply = totalSupply();

        // Integer division rounds down, so dust stays in the pool rather than leaking out.
        amount0 = (liquidity * _reserve0) / supply;
        amount1 = (liquidity * _reserve1) / supply;
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();
        if (amount0 < amount0Min) revert InsufficientAmount0();
        if (amount1 < amount1Min) revert InsufficientAmount1();

        // Effects before interactions: burn shares and shrink reserves, then send tokens.
        // _burn reverts if the caller holds fewer than `liquidity` shares.
        _burn(msg.sender, liquidity);
        _updateReserves(_reserve0 - amount0, _reserve1 - amount1);

        token0.safeTransfer(msg.sender, amount0);
        token1.safeTransfer(msg.sender, amount1);

        emit LiquidityRemoved(msg.sender, amount0, amount1, liquidity);
    }

    /// @notice Swap an exact amount of one pool token for as much of the other as the curve allows.
    /// @dev The 0.3% fee stays in the pool, so k grows with every trade and LPs earn it pro rata.
    ///      minAmountOut caps slippage, so a sandwich or a stale quote can't fill the trade at a bad price.
    ///      The input is pulled first and the trade is priced on what arrived, so a fee-on-transfer
    ///      token is charged its fee before the curve sees it.
    /// @param tokenIn Address of the token being sold; must be token0 or token1.
    /// @param amountIn Amount of tokenIn the caller sends (the pool may receive less if the token takes a fee).
    /// @param minAmountOut Revert if the output would be less than this.
    /// @return amountOut Amount of the other token sent to the caller.
    function swap(address tokenIn, uint256 amountIn, uint256 minAmountOut)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();

        bool zeroForOne = tokenIn == address(token0);
        if (!zeroForOne && tokenIn != address(token1)) revert InvalidToken();

        uint256 _reserve0 = reserve0;
        uint256 _reserve1 = reserve1;
        (IERC20 inToken, IERC20 outToken) = zeroForOne ? (token0, token1) : (token1, token0);
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (_reserve0, _reserve1) : (_reserve1, _reserve0);

        // Pull first and price the trade on what arrived. nonReentrant blocks any callback.
        uint256 received = _pullIn(inToken, amountIn);
        amountOut = getAmountOut(received, reserveIn, reserveOut);
        if (amountOut == 0 || amountOut < minAmountOut) revert InsufficientOutputAmount();

        // The full received amount (fee included) joins the reserves.
        if (zeroForOne) {
            _updateReserves(_reserve0 + received, _reserve1 - amountOut);
        } else {
            _updateReserves(_reserve0 - amountOut, _reserve1 + received);
        }
        outToken.safeTransfer(msg.sender, amountOut);

        emit Swap(msg.sender, tokenIn, received, amountOut);
    }

    /// @notice Send whatever the pool holds above its reserves to `to`.
    /// @dev Tokens sent straight to the pool (by mistake, or by a positive rebase) aren't in the reserves,
    ///      so no LP can withdraw them. This lets anyone pull them out. Reserves don't change.
    ///      A side whose balance is at or below its reserve is skipped instead of reverting, and the pool
    ///      never sends 0, so a token that reverts on zero transfers can still be skimmed on the other side.
    /// @param to Address that receives the excess.
    /// @return amount0 Excess token0 sent.
    /// @return amount1 Excess token1 sent.
    function skim(address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        amount0 = _excess(token0, reserve0);
        amount1 = _excess(token1, reserve1);

        if (amount0 > 0) token0.safeTransfer(to, amount0);
        if (amount1 > 0) token1.safeTransfer(to, amount1);

        emit Skim(msg.sender, to, amount0, amount1);
    }

    /// @notice Set the reserves to the pool's actual balances.
    /// @dev The opposite of skim: instead of sending the difference out, the pool books it. After a
    ///      positive rebase the surplus becomes part of every LP's share; after a negative rebase the
    ///      shortfall is split across all LPs pro rata instead of landing on the last one out.
    ///      It goes through _updateReserves like any trade, so the oracle folds in the old price first and
    ///      a price set by donate-and-sync only enters the TWAP for as long as it lasts on chain.
    function sync() external nonReentrant {
        _updateReserves(token0.balanceOf(address(this)), token1.balanceOf(address(this)));
        emit Sync(reserve0, reserve1);
    }

    /// @notice Quote how much comes out for a given input, after the 0.3% fee.
    /// @dev From (reserveIn + amountInWithFee) * (reserveOut - amountOut) = reserveIn * reserveOut:
    ///      amountOut = amountInWithFee * reserveOut / (reserveIn + amountInWithFee).
    ///      Integer division rounds down, so the trader never gets more than the curve allows.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        uint256 amountInWithFee = amountIn * FEE_NUMERATOR;
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * FEE_DENOMINATOR + amountInWithFee);
    }

    /// @notice Quote the smallest input that buys at least `amountOut`, after the 0.3% fee.
    /// @dev The inverse of getAmountOut: amountIn = reserveIn * amountOut * 1000 / ((reserveOut - amountOut) * 997).
    ///      It rounds up, so swap(tokenIn, amountIn, amountOut) always fills, and one wei less would not.
    ///      Uniswap V2 adds 1 after rounding down instead, which overpays by 1 wei when the division is exact.
    ///      mulDiv keeps the full 512-bit product, so the quote doesn't overflow before the division.
    /// @param amountOut Amount of the output token the caller wants.
    /// @param reserveIn Reserve of the token being sold.
    /// @param reserveOut Reserve of the token being bought; must be more than amountOut.
    /// @return amountIn Amount of the input token the pool needs to receive.
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256 amountIn)
    {
        if (amountOut == 0) revert ZeroAmount();
        if (reserveIn == 0 || amountOut >= reserveOut) revert InsufficientLiquidity();

        amountIn = Math.mulDiv(
            reserveIn * FEE_DENOMINATOR, amountOut, (reserveOut - amountOut) * FEE_NUMERATOR, Math.Rounding.Ceil
        );
    }

    /// @notice The cumulative prices as of this block, including the seconds since the last update.
    /// @dev Lets an oracle take a reading without sending a transaction to the pool first.
    ///      Each second adds the price as it stood at the start of the current block, so a trade
    ///      only moves the average for as long as its price actually lasts on chain.
    ///      Math.mulDiv reverts if a price is above 2**144, which would need a reserve ratio
    ///      far beyond any real pair (Uniswap V2 rules it out by capping reserves at uint112).
    function currentCumulativePrices() public view returns (uint256 price0Cumulative, uint256 price1Cumulative) {
        price0Cumulative = price0CumulativeLast;
        price1Cumulative = price1CumulativeLast;

        uint256 _reserve0 = reserve0;
        uint256 _reserve1 = reserve1;
        uint256 timeElapsed = block.timestamp - blockTimestampLast;
        // Only elapsed time is measured, so a validator nudging the timestamp by a few seconds
        // just shifts a little weight between two prices. It can't make up a price.
        // slither-disable-start timestamp
        // forge-lint: disable-next-line(block-timestamp)
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            unchecked {
                price0Cumulative += Math.mulDiv(_reserve1, Q112, _reserve0) * timeElapsed;
                price1Cumulative += Math.mulDiv(_reserve0, Q112, _reserve1) * timeElapsed;
            }
        }
        // slither-disable-end timestamp
    }

    /// @dev Transfers `amount` of `token` from the caller and returns how much the pool's balance
    ///      actually went up. For a normal token that's `amount`; for a fee-on-transfer token it's less.
    function _pullIn(IERC20 token, uint256 amount) private returns (uint256 received) {
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        received = token.balanceOf(address(this)) - balanceBefore;
    }

    /// @dev How much of `token` the pool holds above `reserve`, or 0 if it holds that much or less.
    function _excess(IERC20 token, uint256 reserve) private view returns (uint256) {
        uint256 balance = token.balanceOf(address(this));
        return balance > reserve ? balance - reserve : 0;
    }

    /// @dev Every reserve change goes through here. The first change in a block folds the old
    ///      price into the accumulators before the reserves move; later changes in the same block
    ///      skip that, which is what stops a same-block swap-and-swap-back from moving the TWAP.
    function _updateReserves(uint256 newReserve0, uint256 newReserve1) private {
        // Same reasoning as in currentCumulativePrices: the timestamp only marks a new block.
        // slither-disable-start timestamp
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp != blockTimestampLast) {
            (price0CumulativeLast, price1CumulativeLast) = currentCumulativePrices();
            blockTimestampLast = block.timestamp;
        }
        // slither-disable-end timestamp
        reserve0 = newReserve0;
        reserve1 = newReserve1;
    }
}
