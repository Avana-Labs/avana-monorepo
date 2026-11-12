// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DeployBase} from "./lib/DeployBase.sol";
import {console2} from "forge-std/console2.sol";

/// @title Factories
/// @notice Step 0: the Safe Singleton Factory (CREATE2) and Avana's namespaced CREATE3 factory.
/// @dev The Safe Singleton Factory exists on Ethereum, Base, Sepolia and Base Sepolia; on a local anvil node or a
/// Tenderly Virtual TestNet without it, its runtime code is installed with the node's `setCode` RPC (`AVANA_NETWORK`
/// `anvil` or `tenderly-*`). `AvanaCreate3Factory` is then CREATE2-deployed through it with salt 0, so it has the same
/// address on every chain; the step is skipped where it already exists.
/// Run: `AVANA_NETWORK=anvil forge script script/deploy/00_Factories.s.sol --rpc-url anvil --broadcast --account <a>`.
contract Factories is DeployBase {
    function run() external {
        string memory network = _network();
        if (SAFE_SINGLETON_FACTORY.code.length == 0) {
            string memory method;
            if (_eq(network, "anvil")) method = "anvil_setCode";
            else if (_startsWith(network, "tenderly")) method = "tenderly_setCode";
            else revert("Safe Singleton Factory missing on a network where it cannot be installed");
            vm.rpc(
                method,
                string.concat(
                    '["', vm.toString(SAFE_SINGLETON_FACTORY), '","', vm.toString(SAFE_SINGLETON_FACTORY_CODE), '"]'
                )
            );
            vm.etch(SAFE_SINGLETON_FACTORY, SAFE_SINGLETON_FACTORY_CODE);
        }
        address expected = _create3FactoryAddress();
        if (expected.code.length == 0) {
            bytes memory initCode = _artifact("AvanaCreate3Factory.sol", "AvanaCreate3Factory");
            vm.startBroadcast();
            (bool ok, bytes memory ret) = SAFE_SINGLETON_FACTORY.call(abi.encodePacked(bytes32(0), initCode));
            vm.stopBroadcast();
            require(ok && address(bytes20(ret)) == expected, "AvanaCreate3Factory deployment");
        }
        console2.log("AvanaCreate3Factory", expected);
    }
}
