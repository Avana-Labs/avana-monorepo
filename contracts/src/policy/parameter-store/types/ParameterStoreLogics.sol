// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Addresses of the five logic contracts a ParameterStore implementation delegatecalls.
struct ParameterStoreLogics {
    // Every tighten setter (short delay).
    address tighten;
    // Every loosen setter (normal delay).
    address loosen;
    // Listing, chain, Spoke and coverage setters.
    address listing;
    // Structural oracle setters and liveness-checked setters.
    address adminOracle;
    // Structural risk setters, second sources and the initial parameter write.
    address adminRisk;
}
