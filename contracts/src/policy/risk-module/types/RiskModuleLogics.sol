// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The five immutable logic contracts the RiskModule calls for its check bodies.
/// @dev The RiskModule holds no state but its roles, so each body runs as a plain call into a stateless logic
/// contract built with the same `RiskModuleImmutables`; the RiskModule constructor checks every `logicConfig()`, so a
/// new logic contract is part of a new implementation and waits the normal delay (REQ-RISK-002).
/// @custom:spec REQ-RISK-002
struct RiskModuleLogics {
    // Aave configuration drift, Hub shares == assets and the expected collateral factor.
    address drift;
    // Breaker conditions of markets and debt reserves.
    address breaker;
    // The pledge check, its preview, the restore amount and the remaining-record minimum.
    address pledge;
    // The borrow-side pre-checks, the rescue-excluded health check and the debt value.
    address borrow;
    // The non-reverting account gate status.
    address status;
}
