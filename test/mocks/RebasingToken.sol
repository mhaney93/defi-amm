// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Shares-based rebasing token, the way stETH and AMPL work. For tests only.
/// @dev Each holder owns shares. balanceOf = shares * index / 1e18, so calling rebase() changes
///      every holder's balance at once without a single transfer. Transfers move
///      amount * 1e18 / index shares, which rounds down, so after a rebase a transfer can deliver
///      1 wei less than asked (stETH has the same 1-2 wei quirk).
contract RebasingToken is IERC20 {
    error InsufficientBalance();
    error InsufficientAllowance();

    uint256 private constant ONE = 1e18;

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    /// @notice Balance per share, scaled by 1e18. Starts at 1.0.
    uint256 public index = ONE;
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        uint256 shares = (amount * ONE) / index;
        sharesOf[to] += shares;
        totalShares += shares;
        emit Transfer(address(0), to, amount);
    }

    /// @notice Set the new balance per share, e.g. 1.1e18 for +10% or 0.9e18 for -10%.
    function rebase(uint256 newIndex) external {
        index = newIndex;
    }

    function balanceOf(address account) public view returns (uint256) {
        return (sharesOf[account] * index) / ONE;
    }

    function totalSupply() external view returns (uint256) {
        return (totalShares * index) / ONE;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (balanceOf(from) < amount) revert InsufficientBalance();
        uint256 shares = (amount * ONE) / index;
        sharesOf[from] -= shares;
        sharesOf[to] += shares;
        emit Transfer(from, to, amount);
    }
}
