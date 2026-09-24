// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title SimpleAMM
/// @notice Constant-product (x * y = k) AMM for a single token pair.
///         The pool contract is itself the ERC20 LP token.
contract SimpleAMM is ERC20 {
    error IdenticalTokens();
    error ZeroAddress();

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
}
