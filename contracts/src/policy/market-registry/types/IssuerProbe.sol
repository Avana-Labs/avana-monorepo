// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The issuer-action probe recorded at listing for a pool token or debt asset.
/// @dev `None`: no probe. `PausedFlag`: tripped when `paused()` returns true. `UsdtFeeRate`: tripped when
/// `basisPointsRate()` returns a non-zero value. A probe that reverts, runs out of its gas limit or returns malformed
/// data counts as tripped. Ordinal values are fixed: `None` 0, `PausedFlag` 1, `UsdtFeeRate` 2.
/// @custom:spec REQ-MREG-027, Q-241
enum IssuerProbe {
    None,
    PausedFlag,
    UsdtFeeRate
}
