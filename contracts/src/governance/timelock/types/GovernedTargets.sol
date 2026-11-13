// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The deterministic deployment addresses on the chain of the three contracts whose selectors the AvanaTimelock's
/// `SHORT_ELIGIBLE` and DAO-only cancel sets name: the ParameterStore (its `tighten*` setters), the MarketRegistry (its
/// stops and repairs) and LPVaultSwap (`removeKeeper`, `addKeeper`). The constructor accepts a pair only with the
/// target its selector belongs to (`REQ-ACCESS-155`, `REQ-ACCESS-156`).
/// @custom:spec REQ-ACCESS-155, REQ-ACCESS-156, REQ-ACCESS-181
struct GovernedTargets {
    address parameterStore;
    address marketRegistry;
    address lpVaultSwap;
}
