// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Addresses of the five logic contracts a ParameterStore implementation delegatecalls, fixed as
/// implementation immutables by its constructor.
/// @custom:spec REQ-PSTORE-001
struct ParameterStoreLogics {
    // Every tighten setter (short delay).
    address tighten;
    // Every loosen setter (normal delay).
    address loosen;
    // Listing setters, the Spoke liquidation expectations, the sequencer check and the coverage ratio.
    address listing;
    // Structural setters of the oracle configuration, the slippage floor and the flash-fee ceiling (both checked
    // against liquidation liveness), and the views getOracleConfig and liquidationLivenessHolds.
    address adminOracle;
    // Structural setters of the risk configuration, the second sources and the initial parameter write.
    address adminRisk;
}
