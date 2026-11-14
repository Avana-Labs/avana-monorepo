// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Pending-settlement balance of a market and whether LPVaultSwap can settle it.
/// @dev `units` and `amounts` (pool order) from `Collateralization.getPending`; `unsettledSeizedUnits` is the
/// vault-token balance of LPVaultSwap for the market; `settleableUnits = min(units, unsettledSeizedUnits)`, the units
/// LPVaultSwap's `settlePending(marketId)` would settle; `settleable = settleableUnits > 0`; `valueDebt` is the oracle
/// value of `units` in base units of `debtAsset` per `SPEC-LIQ-004` with `c = units`, the amount a settlement funds
/// into `firstLossReserve`, the First-Loss Reserve of the market's (Hub, debt asset).
/// @custom:spec REQ-LENS-026, Q-370
struct PendingView {
    uint256 blockNumber;
    uint256 timestamp;
    address vaultToken;
    uint256 units;
    uint256[] amounts;
    uint256 unsettledSeizedUnits;
    uint256 settleableUnits;
    bool settleable;
    address debtAsset;
    address firstLossReserve;
    uint256 valueDebt;
}
