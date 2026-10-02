// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {SimpleAMM} from "../src/SimpleAMM.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Deploys two test tokens and a SimpleAMM pool for them, then seeds the pool
///         with the first deposit so it's usable right away.
/// @dev Run against Sepolia with an encrypted keystore account, so no private key ever
///      sits in a .env file or the shell history:
///        cast wallet import deployer --interactive
///        forge script script/DeploySimpleAMM.s.sol --rpc-url $SEPOLIA_RPC_URL \
///          --account deployer --sender <deployer address> --broadcast --verify
contract DeploySimpleAMM is Script {
    /// @notice Each token is seeded 1:1, so the opening price is 1 TKA = 1 TKB.
    uint256 public constant SEED_AMOUNT = 1_000e18;

    function run() external returns (SimpleAMM amm, MockERC20 tokenA, MockERC20 tokenB) {
        return deploy(msg.sender);
    }

    /// @dev Split out from run() so tests can choose the deployer address.
    function deploy(address deployer) public returns (SimpleAMM amm, MockERC20 tokenA, MockERC20 tokenB) {
        vm.startBroadcast(deployer);

        tokenA = new MockERC20("AMM Test Token A", "TKA");
        tokenB = new MockERC20("AMM Test Token B", "TKB");
        amm = new SimpleAMM(address(tokenA), address(tokenB));

        tokenA.mint(deployer, SEED_AMOUNT);
        tokenB.mint(deployer, SEED_AMOUNT);
        tokenA.approve(address(amm), SEED_AMOUNT);
        tokenB.approve(address(amm), SEED_AMOUNT);
        amm.addLiquidity(SEED_AMOUNT, SEED_AMOUNT, SEED_AMOUNT, SEED_AMOUNT);

        vm.stopBroadcast();

        console.log("TokenA:    ", address(tokenA));
        console.log("TokenB:    ", address(tokenB));
        console.log("SimpleAMM: ", address(amm));
    }
}
