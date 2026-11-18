// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title RiskModuleConstants
/// @notice Fixed values of the RiskModule implementation; a change is a RiskModule upgrade.
library RiskModuleConstants {
    /// @notice Health factor below which an indebted account may make a rescue top-up, WAD; not a borrow gate.
    uint256 internal constant RESCUE_HEALTH_FACTOR = 1.1e18;

    /// @notice A rescue top-up must reach `min(minPledgeUsd, this)`, 8-decimal USD.
    uint256 internal constant RESCUE_MIN_PLEDGE_USD = 10e8;

    uint256 internal constant ISSUER_PROBE_GAS = 30_000;

    /// @notice Gas kept after a gas-limited external call returns, added to the pre-call gas check.
    uint256 internal constant POST_CALL_GAS = 5000;
}
