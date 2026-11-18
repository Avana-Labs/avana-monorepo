// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Enabled debt reserve of a CDP Spoke.
/// @dev Written by `enableDebtReserve`. `fundingHub` is the home Hub or, through a cross-Hub credit line, another Hub.
struct DebtReserveDef {
    // CDP Spoke reserve identifier.
    uint256 reserveId;
    // Underlying debt asset.
    address asset;
    uint8 decimals;
    // Hub that funds the reserve.
    address fundingHub;
    // Hub asset identifier of the debt asset on the funding Hub.
    uint256 hubAssetId;
    // AaveOracle price source of the reserve.
    address priceSource;
    // True for a fixed-price source; such a source has no age.
    bool fixedPrice;
    // First-Loss Reserve of (fundingHub, asset).
    address firstLossReserve;
    // True when fundingHub differs from the Spoke's home Hub.
    bool crossHub;
    bool approved;
}
