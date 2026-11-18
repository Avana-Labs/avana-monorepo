// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Pending-settlement balance of a market and whether LPVaultSwap can settle it.
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
