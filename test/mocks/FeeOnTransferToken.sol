// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC20 that burns 1% of every transfer, for tests only. The recipient gets
///         99% of what the sender sent, the way real fee-on-transfer tokens behave.
/// @dev Mints and burns are not charged, only transfers between two accounts.
contract FeeOnTransferToken is ERC20 {
    uint256 public constant FEE_BPS = 100;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = (value * FEE_BPS) / 10_000;
            super._update(from, address(0), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}
