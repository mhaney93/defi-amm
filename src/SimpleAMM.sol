// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title SimpleAMM
/// @notice Constant-product (x * y = k) AMM for a single token pair.
///         The pool contract is itself the ERC20 LP token.
contract SimpleAMM is ERC20 {
    using SafeERC20 for IERC20;

    error IdenticalTokens();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();

    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1, uint256 liquidity);
    event LiquidityRemoved(address indexed provider, uint256 amount0, uint256 amount1, uint256 liquidity);

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
    ///      Slippage limits and a reentrancy guard come in a later milestone.
    /// @param amount0Desired Max amount of token0 the caller is willing to deposit.
    /// @param amount1Desired Max amount of token1 the caller is willing to deposit.
    /// @return amount0 Amount of token0 actually deposited.
    /// @return amount1 Amount of token1 actually deposited.
    /// @return liquidity LP shares minted to the caller.
    function addLiquidity(uint256 amount0Desired, uint256 amount1Desired)
        external
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
                uint256 amount0Optimal = (amount1Desired * _reserve0) / _reserve1;
                (amount0, amount1) = (amount0Optimal, amount1Desired);
            }
            // Take the smaller share so rounding always favors the pool, never the depositor.
            liquidity = Math.min((amount0 * supply) / _reserve0, (amount1 * supply) / _reserve1);
            if (liquidity == 0) revert InsufficientLiquidityMinted();
        }

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
    ///      Slippage limits and a reentrancy guard come in a later milestone.
    /// @param liquidity LP shares to burn from the caller.
    /// @return amount0 Amount of token0 sent to the caller.
    /// @return amount1 Amount of token1 sent to the caller.
    function removeLiquidity(uint256 liquidity) external returns (uint256 amount0, uint256 amount1) {
        if (liquidity == 0) revert ZeroAmount();

        uint256 _reserve0 = reserve0;
        uint256 _reserve1 = reserve1;
        uint256 supply = totalSupply();

        // Integer division rounds down, so dust stays in the pool rather than leaking out.
        amount0 = (liquidity * _reserve0) / supply;
        amount1 = (liquidity * _reserve1) / supply;
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();

        // Effects before interactions: burn shares and shrink reserves, then send tokens.
        // _burn reverts if the caller holds fewer than `liquidity` shares.
        _burn(msg.sender, liquidity);
        reserve0 = _reserve0 - amount0;
        reserve1 = _reserve1 - amount1;

        token0.safeTransfer(msg.sender, amount0);
        token1.safeTransfer(msg.sender, amount1);

        emit LiquidityRemoved(msg.sender, amount0, amount1, liquidity);
    }
}
