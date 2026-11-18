// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The chain's fixed dependencies of the AaveAdapter implementation and of each of its logic contracts.
/// @dev Every field is non-zero; the router checks each logic contract was built with the same values.
struct AaveAdapterImmutables {
    address proxyManager;
    address collateralization;
    address riskModule;
    address marketRegistry;
    address parameterStore;
    address lpVaultSwap;
    address lock;
    address vaultTokenFactory;
    address timelock;
}
