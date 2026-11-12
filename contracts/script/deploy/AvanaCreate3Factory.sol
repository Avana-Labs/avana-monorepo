// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CREATE3} from "solady/utils/CREATE3.sol";

/// @title AvanaCreate3Factory
/// @notice CREATE3 factory whose salts are namespaced by the caller: the address of a deployment depends only on the
/// caller and the caller's salt, never on the init code, and no other caller can reach it.
/// @dev The effective salt is `keccak256(abi.encode(msg.sender, salt))`, so an address predicted for the Avana deployer
/// can be taken only by a transaction the deployer signs. The factory has no owner, no state and no other function; it
/// is itself deployed with CREATE2 through the Safe Singleton Factory with salt 0, so it sits at the same address on
/// every chain and anyone may deploy it there first without effect (the code is fixed by its init code hash). The
/// deployment is Solady's CREATE3 (a minimal CREATE2 proxy that CREATEs the init code), the same library the
/// VaultTokenFactory uses. A failing constructor reverts with `DeploymentFailed()` and no revert data of its own.
/// Example: the deployer `0xD0…` with `salt = keccak256("avana.v1.0.0.AvanaTimelock")` deploys the timelock at
/// `predict(0xD0…, salt)` on Ethereum and on Base alike; a call from any other address with the same salt lands at a
/// different address.
contract AvanaCreate3Factory {
    /// @notice A contract was deployed.
    /// @param caller The caller whose namespace the address belongs to.
    /// @param salt The caller's salt.
    /// @param deployed The new contract.
    event Deployed(address indexed caller, bytes32 indexed salt, address deployed);

    /// @notice Deploys `initCode` at `predict(msg.sender, salt)`.
    /// @param salt The caller's salt.
    /// @param initCode Creation code with its ABI-encoded constructor arguments.
    /// @return deployed The new contract.
    function deploy(
        bytes32 salt,
        bytes calldata initCode
    ) external returns (address deployed) {
        deployed = CREATE3.deployDeterministic(initCode, _namespaced(msg.sender, salt));
        emit Deployed(msg.sender, salt, deployed);
    }

    /// @notice The address `deploy(salt, …)` called by `caller` creates.
    /// @param caller The calling account.
    /// @param salt The caller's salt.
    /// @return deployed The predicted address.
    function predict(
        address caller,
        bytes32 salt
    ) external view returns (address deployed) {
        deployed = CREATE3.predictDeterministicAddress(_namespaced(caller, salt), address(this));
    }

    function _namespaced(
        address caller,
        bytes32 salt
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(caller, salt));
    }
}
