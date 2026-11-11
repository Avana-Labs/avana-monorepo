// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Aave `drawCap` headroom of a CDP Spoke on one approved debt reserve.
/// @dev `headroom = max(0, drawCap * 10^decimals - getSpokeTotalOwed - ceil(getSpokeDeficitRay / 1e27))` in the debt
/// asset's base units, on the Hub and Hub asset the reserve's `DebtReserveDef` names; a `type(uint40).max` cap reports
/// `type(uint256).max`. Rounding never overstates headroom.
/// @custom:spec REQ-LENS-019
struct DrawHeadroom {
    uint256 reserveId;
    uint256 headroom;
}
