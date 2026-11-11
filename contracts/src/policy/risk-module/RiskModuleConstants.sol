// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title RiskModuleConstants
/// @notice Fixed values of the RiskModule implementation; a change is a RiskModule upgrade at the normal delay.
/// @custom:spec REQ-RISK-059, REQ-RISK-067, SPEC-PROXY-001, SPEC-BRK-003, Q-398, Q-229, Q-241, Q-252
library RiskModuleConstants {
    /// @notice `rescueHealthFactor`: a rescue top-up is open to an indebted account below this health factor and
    /// restores it to this value, 1.10 in WAD (Q-398). It is not a borrow gate; the Lens previews borrows at the same
    /// recommended health factor.
    uint256 internal constant RESCUE_HEALTH_FACTOR = 1.1e18;

    /// @notice `RESCUE_MIN_PLEDGE_USD`: a rescue top-up must reach `min(minPledgeUsd, this)`, 8-decimal USD ($10.00).
    uint256 internal constant RESCUE_MIN_PLEDGE_USD = 10e8;

    /// @notice `ISSUER_PROBE_GAS`: gas given to each issuer probe staticcall.
    uint256 internal constant ISSUER_PROBE_GAS = 30_000;

    /// @notice `POST_CALL_GAS`: gas kept after a gas-limited external call returns, added to `ceil(64 * G / 63)` in
    /// the pre-call check (SPEC-ORC-023, REQ-RISK-089).
    uint256 internal constant POST_CALL_GAS = 5000;
}
