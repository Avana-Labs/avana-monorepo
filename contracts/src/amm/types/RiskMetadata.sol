// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Risk metadata of one market and, optionally, one position, returned by `IAmmIntegration.riskMetadata`.
/// @dev `avanaUnits` and `poolShareBps` are always 0: LPVaults keep no unit counter.
struct RiskMetadata {
    bool inRange;
    bool readSafe;
    uint256 avanaUnits;
    uint256 poolUnits;
    uint256 poolShareBps;
    // 0 when no position is named.
    uint128 positionUnits;
}
