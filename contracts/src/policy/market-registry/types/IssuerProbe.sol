// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The issuer-action probe recorded at listing for a pool token or debt asset.
/// @dev A failed or malformed read counts as tripped. Ordinal values are fixed.
enum IssuerProbe {
    None,
    PausedFlag,
    UsdtFeeRate,
    UsdtFeeRateAndPaused
}

/// @title IssuerProbes
/// @notice Which reads a probe kind runs.
library IssuerProbes {
    /// @notice True when the probe reads `paused()`: `PausedFlag` or `UsdtFeeRateAndPaused`.
    function readsPaused(
        IssuerProbe p
    ) internal pure returns (bool reads) {
        reads = p == IssuerProbe.PausedFlag || p == IssuerProbe.UsdtFeeRateAndPaused;
    }

    /// @notice True when the probe reads `basisPointsRate()`: `UsdtFeeRate` or `UsdtFeeRateAndPaused`.
    function readsFeeRate(
        IssuerProbe p
    ) internal pure returns (bool reads) {
        reads = p == IssuerProbe.UsdtFeeRate || p == IssuerProbe.UsdtFeeRateAndPaused;
    }
}
