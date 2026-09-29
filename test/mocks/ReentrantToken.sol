// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Malicious ERC20 for tests only. Once armed, the next transfer to or from `target`
///         calls back into `target` with `payload`, the way a hostile token (or an ERC777-style
///         hook) would try to re-enter the pool mid-trade.
contract ReentrantToken is ERC20 {
    address public target;
    bytes public payload;

    constructor() ERC20("Reentrant Token", "EVIL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address _target, bytes calldata _payload) external {
        target = _target;
        payload = _payload;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);

        address _target = target;
        if (_target != address(0) && (from == _target || to == _target)) {
            // One shot, so the callback can't loop on its own transfers.
            target = address(0);
            (bool ok, bytes memory ret) = _target.call(payload);
            // Bubble up the pool's revert so the test can match the exact error.
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }
}
