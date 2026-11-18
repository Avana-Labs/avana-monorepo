// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Arguments of `IDebtOracle.initialize`.
/// @dev `asset`, `marketRegistry` and `parameterStore` are fixed for the life of the proxy.
struct DebtOracleInitParams {
    // Must equal the implementation's TIMELOCK.
    address timelock;
    address asset;
    address marketRegistry;
    address parameterStore;
    string description;
    uint32 pokeMinGas;
}
