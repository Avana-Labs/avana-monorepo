// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Lifecycle status of a market.
/// @dev `Registered` markets are treated as not listed; `Offboarding` is terminal and blocks every pledge into the
/// market and borrowing by accounts with collateral in it, while repay, withdrawals and liquidation continue. Ordinal
/// values are fixed; `Offboarding`, `Cancelled` and then `Closed` are appended. A `Cancelled` market keeps its identifier
/// reserved for its pool.
/// @custom:spec REQ-CONFIG-012, REQ-CONFIG-013, REQ-CONFIG-042, REQ-CONFIG-048, REQ-MREG-015, REQ-MREG-030, REQ-CONFIG-080
enum MarketStatus {
    None,
    Registered,
    Active,
    Offboarding,
    Cancelled,
    // Terminal after wind-down: no account of the market has debt (REQ-CONFIG-080).
    Closed
}
