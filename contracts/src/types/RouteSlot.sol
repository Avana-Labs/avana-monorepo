// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice A token's Chainlink price-route slot that its pre-approved standby route can replace.
/// @dev `None` means no slot is replaced (both recorded routes in force). Ordinal values are fixed: `None` 0,
/// `Primary` 1, `Alternate` 2. Read by the LPOracle and the DebtOracle through
/// `IMarketRegistry.activePriceRoutes(token)`.
/// @custom:spec REQ-MREG-027, REQ-MREG-028, REQ-ORACLE-091, Q-248
enum RouteSlot {
    None,
    Primary,
    Alternate
}
