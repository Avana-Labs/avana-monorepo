// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Enabled debt reserve of a CDP Spoke.
/// @dev Written by `enableDebtReserve`. `fundingHub` is the Hub that lends the asset: the Spoke's home Hub, or another
/// Hub on the same chain through a cross-Hub credit line (off at launch). The funding Hub owns the line's cap, a pause
/// of the funding Hub stops the line, and `firstLossReserve` is the First-Loss Reserve of `(fundingHub, asset)`. An asset
/// with a fixed-price Aave source (such as GHO) has `fixedPrice = true`; every other asset has its DebtOracle on an 8-decimal
/// Chainlink USD feed.
/// @custom:spec REQ-MREG-006, REQ-MREG-008, REQ-MREG-009, Q-233, Q-236, Q-238, Q-378
struct DebtReserveDef {
    // CDP Spoke reserve identifier.
    uint256 reserveId;
    // Underlying debt asset.
    address asset;
    // Debt asset decimals.
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
    // True while enabled.
    bool approved;
}
