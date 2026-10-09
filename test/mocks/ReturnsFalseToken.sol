// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC20 that can be switched into failing transfers by returning false instead of
///         reverting, the way some older tokens behave. For tests only.
/// @dev While `failing` is set, transfer and transferFrom move nothing and return false. A caller
///      that ignores the return value would think the transfer worked.
contract ReturnsFalseToken is ERC20 {
    bool public failing;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailing(bool failing_) external {
        failing = failing_;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (failing) return false;
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (failing) return false;
        return super.transferFrom(from, to, value);
    }
}
