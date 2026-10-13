// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC20 that reverts on any transfer of zero tokens, the way some tokens (LEND, for one)
///         behave. For tests only.
/// @dev Mints and burns of zero are left alone; only real transfers between two accounts are checked.
contract RevertOnZeroToken is ERC20 {
    error ZeroTransfer();

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (value == 0 && from != address(0) && to != address(0)) revert ZeroTransfer();
        super._update(from, to, value);
    }
}
