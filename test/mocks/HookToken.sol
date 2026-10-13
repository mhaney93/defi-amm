// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The two hooks an ERC777 token calls on its holders.
interface ITokenHooks {
    function tokensToSend(address operator, address from, address to, uint256 amount) external;
    function tokensReceived(address operator, address from, address to, uint256 amount) external;
}

/// @notice ERC20 with ERC777-style hooks, for tests only. A holder registers a hook contract, and
///         the token then calls `tokensToSend` on the sender's hook BEFORE balances move and
///         `tokensReceived` on the recipient's hook AFTER. Real ERC777 tokens look hooks up in the
///         ERC1820 registry; a plain mapping is enough to test the pool.
/// @dev The before-hook is the dangerous one: it hands control to the sender while the token
///      balances still show the old state. That's how Uniswap V1 pools holding imBTC were drained
///      in 2020.
contract HookToken is ERC20 {
    mapping(address account => address hook) public hookOf;

    constructor() ERC20("Hook Token", "HOOK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHook(address hook) external {
        hookOf[msg.sender] = hook;
    }

    function _update(address from, address to, uint256 value) internal override {
        address sendHook = from == address(0) ? address(0) : hookOf[from];
        if (sendHook != address(0)) ITokenHooks(sendHook).tokensToSend(msg.sender, from, to, value);

        super._update(from, to, value);

        address receiveHook = to == address(0) ? address(0) : hookOf[to];
        if (receiveHook != address(0)) ITokenHooks(receiveHook).tokensReceived(msg.sender, from, to, value);
    }
}

/// @notice A pool user that registers itself as its own hook. It can count hook calls, re-enter
///         the pool from a hook, or refuse incoming tokens.
contract HookUser is ITokenHooks {
    address public immutable pool;

    uint256 public sendCalls;
    uint256 public receiveCalls;

    bytes public reenterOnSend;
    bytes public reenterOnReceive;
    bool public refuseIncoming;

    error Refused();

    constructor(address _pool) {
        pool = _pool;
    }

    /// @dev Make any call as this contract (approve, setHook, addLiquidity, swap...), bubbling reverts.
    function execute(address target, bytes calldata data) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.call(data);
        if (!ok) _bubble(ret);
    }

    function setReenterOnSend(bytes calldata data) external {
        reenterOnSend = data;
    }

    function setReenterOnReceive(bytes calldata data) external {
        reenterOnReceive = data;
    }

    function setRefuseIncoming(bool refuse) external {
        refuseIncoming = refuse;
    }

    function tokensToSend(address, address, address, uint256) external {
        sendCalls++;
        _maybeReenter(reenterOnSend);
    }

    function tokensReceived(address, address from, address, uint256) external {
        receiveCalls++;
        // Mints come from address(0); only refuse real transfers in.
        if (refuseIncoming && from != address(0)) revert Refused();
        _maybeReenter(reenterOnReceive);
    }

    function _maybeReenter(bytes memory data) private {
        if (data.length == 0) return;
        (bool ok, bytes memory ret) = pool.call(data);
        if (!ok) _bubble(ret);
    }

    function _bubble(bytes memory ret) private pure {
        assembly {
            revert(add(ret, 32), mload(ret))
        }
    }
}
