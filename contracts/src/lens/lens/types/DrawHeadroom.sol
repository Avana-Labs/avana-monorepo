// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Aave `drawCap` headroom of a CDP Spoke on one approved debt reserve.
/// @dev Debt-asset base units; max for an unlimited cap. Rounding never overstates headroom.
struct DrawHeadroom {
    uint256 reserveId;
    uint256 headroom;
}
