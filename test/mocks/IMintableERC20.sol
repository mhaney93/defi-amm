// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The test tokens (MockERC20, FeeOnTransferToken) all expose a public mint, so the
///         invariant handler can fund actors without caring which kind of token it's using.
interface IMintableERC20 is IERC20 {
    function mint(address to, uint256 amount) external;
}
