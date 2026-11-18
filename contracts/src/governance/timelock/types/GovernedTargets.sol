// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Addresses of the three contracts whose selectors the AvanaTimelock's short-eligible and DAO-only cancel
/// sets name.
struct GovernedTargets {
    address parameterStore;
    address marketRegistry;
    address lpVaultSwap;
}
