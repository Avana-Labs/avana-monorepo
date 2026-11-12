// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The issuer-action probe recorded at listing for a pool token or debt asset.
/// @dev `None`: no probe. `PausedFlag`: tripped when `paused()` returns true. `UsdtFeeRate`: tripped when
/// `basisPointsRate()` returns a non-zero value. `UsdtFeeRateAndPaused`: both reads, tripped when either trips (USDT on
/// Ethereum has both a fee switch and a pause flag). A read that reverts, runs out of its gas limit or returns malformed
/// data counts as tripped. Every kind is allowed on every chain; the listing package picks, per chain, the kind whose
/// reads the deployed token answers. Ordinal values are fixed: `None` 0, `PausedFlag` 1, `UsdtFeeRate` 2,
/// `UsdtFeeRateAndPaused` 3.
/// @custom:spec REQ-MREG-027, Q-241
enum IssuerProbe {
    None,
    PausedFlag,
    UsdtFeeRate,
    UsdtFeeRateAndPaused
}

/// @title IssuerProbes
/// @notice Which reads a probe kind runs. Every reader of `TokenDef.issuerProbe` decides through these two, so the
/// combined kind is treated exactly as each single kind it contains.
/// @custom:spec REQ-MREG-027, SPEC-BRK-003, REQ-ROUTE-008, REQ-MREG-006
library IssuerProbes {
    /// @notice True when the probe reads `paused()`: `PausedFlag` or `UsdtFeeRateAndPaused`.
    /// @param p The recorded probe kind.
    /// @return reads Whether `paused()` is read.
    /// @custom:spec REQ-MREG-027, SPEC-BRK-003
    function readsPaused(
        IssuerProbe p
    ) internal pure returns (bool reads) {
        reads = p == IssuerProbe.PausedFlag || p == IssuerProbe.UsdtFeeRateAndPaused;
    }

    /// @notice True when the probe reads `basisPointsRate()`, so the token has a transfer-fee switch: `UsdtFeeRate` or
    /// `UsdtFeeRateAndPaused`.
    /// @param p The recorded probe kind.
    /// @return reads Whether `basisPointsRate()` is read.
    /// @custom:spec REQ-MREG-027, SPEC-BRK-003, REQ-ROUTE-008, REQ-MREG-006
    function readsFeeRate(
        IssuerProbe p
    ) internal pure returns (bool reads) {
        reads = p == IssuerProbe.UsdtFeeRate || p == IssuerProbe.UsdtFeeRateAndPaused;
    }
}
