// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Implementation immutables of the RiskModule and of each of its logic contracts, all per chain.
struct RiskModuleImmutables {
    address marketRegistry;
    address parameterStore;
    // Collateralization, the caller of `checkPledge`.
    address collateralization;
    // The AaveAdapter fixed proxy, the caller of the borrow-side checks.
    address adapter;
    // LPVaultSwap fixed proxy, read for `activeKeeperCount`.
    address lpVaultSwap;
    // The chain's AvanaTimelock, the only holder of `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN`.
    address timelock;
}
