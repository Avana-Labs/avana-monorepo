// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILPVaultSwapLogic
/// @notice Identity of an LPVaultSwap logic contract.
/// @dev A logic contract holds the body of `liquidate`, of `settlePending` or of `deleverage` and its flash callback,
/// and runs only by delegatecall from the LPVaultSwap proxy's implementation, in the proxy's ERC-7201 storage. Called
/// directly, every body reverts with `NotDelegated` (`address(this)` is the logic contract itself), so it holds no
/// state and no balance any contract reads.
/// @custom:spec REQ-SWAP-040
interface ILPVaultSwapLogic {
    /// @notice The logic contract's kind and the hash of its implementation immutables.
    /// @return kind `keccak256` of the logic contract's name, for example `keccak256("LPVaultSwapLiquidationLogic")`.
    /// @return immutablesHash `keccak256(abi.encode(LPVaultSwapImmutables))` of the values it was built with.
    /// @custom:spec REQ-SWAP-040
    function logicConfig() external view returns (bytes32 kind, bytes32 immutablesHash);
}
