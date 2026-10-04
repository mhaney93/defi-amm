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
    event Swap(address indexed trader, address indexed tokenIn, uint256 amountIn, uint256 amountOut);

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
    /// @param amount0Desired Max amount of token0 the caller is willing to deposit.
    /// @param amount1Desired Max amount of token1 the caller is willing to deposit.
    /// @param amount0Min Revert if less than this much token0 would be deposited.
    /// @param amount1Min Revert if less than this much token1 would be deposited.
    /// @return amount0 Amount of token0 actually deposited.
    /// @return amount1 Amount of token1 actually deposited.
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

        if (supply == 0) {
            // First deposit sets the price. Shares = geometric mean of the two amounts.
            amount0 = amount0Desired;
            amount1 = amount1Desired;
            liquidity = Math.sqrt(amount0 * amount1);
            if (liquidity <= MINIMUM_LIQUIDITY) revert InsufficientLiquidityMinted();
            liquidity -= MINIMUM_LIQUIDITY;
            _mint(DEAD, MINIMUM_LIQUIDITY);
        } else {
            // Match the current ratio: use all of one token and the proportional amount of the other.
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
            // Take the smaller share so rounding always favors the pool, never the depositor.
            liquidity = Math.min((amount0 * supply) / _reserve0, (amount1 * supply) / _reserve1);
            if (liquidity == 0) revert InsufficientLiquidityMinted();
        }

        if (amount0 < amount0Min) revert InsufficientAmount0();
        if (amount1 < amount1Min) revert InsufficientAmount1();

        // Effects before interactions: update state, then pull tokens.
        reserve0 = _reserve0 + amount0;
        reserve1 = _reserve1 + amount1;
        _mint(msg.sender, liquidity);

        token0.safeTransferFrom(msg.sender, address(this), amount0);
        token1.safeTransferFrom(msg.sender, address(this), amount1);

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
        reserve0 = _reserve0 - amount0;
        reserve1 = _reserve1 - amount1;

        token0.safeTransfer(msg.sender, amount0);
        token1.safeTransfer(msg.sender, amount1);

        emit LiquidityRemoved(msg.sender, amount0, amount1, liquidity);
    }

    /// @notice Swap an exact amount of one pool token for as much of the other as the curve allows.
    /// @dev The 0.3% fee stays in the pool, so k grows with every trade and LPs earn it pro rata.
    ///      minAmountOut caps slippage, so a sandwich or a stale quote can't fill the trade at a bad price.
    /// @param tokenIn Address of the token being sold; must be token0 or token1.
    /// @param amountIn Exact amount of tokenIn the caller sends.
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

        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        amountOut = getAmountOut(amountIn, reserveIn, reserveOut);
        if (amountOut == 0 || amountOut < minAmountOut) revert InsufficientOutputAmount();

        // Effects before interactions: the full amountIn (fee included) joins the reserves.
        if (zeroForOne) {
            reserve0 = reserveIn + amountIn;
            reserve1 = reserveOut - amountOut;
            token0.safeTransferFrom(msg.sender, address(this), amountIn);
            token1.safeTransfer(msg.sender, amountOut);
        } else {
            reserve1 = reserveIn + amountIn;
            reserve0 = reserveOut - amountOut;
            token1.safeTransferFrom(msg.sender, address(this), amountIn);
            token0.safeTransfer(msg.sender, amountOut);
        }

        emit Swap(msg.sender, tokenIn, amountIn, amountOut);
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
}
