// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Risk metadata of one market and, optionally, one position, returned by `IAmmIntegration.riskMetadata`.
/// @dev `avanaUnits` is 0 from every LPVault, which keeps no unit counter (2.2 Storage), so `poolShareBps =
/// floor(avanaUnits * 1e4 / poolUnits)` is 0 as well; Avana's credited units in a market are Collateralization's
/// `getTotalCredited(vaultToken)`, and the pledge-time pool-share cap uses the pool-wide counter of every market of
/// the pool against `RiskStatus.depthUnits` (SPEC-CAP-005). `poolUnits` is in the integration's position units:
/// in-range liquidity for concentrated liquidity, effective LP supply (including pending `feeTo` liquidity) for
/// Uniswap v2, LP supply for Curve and Balancer. `inRange` is false when the pool's current price lies outside the
/// market's range (always true for FullPool). `readSafe` is false while the pool's lock is held (a read inside a pool
/// callback). `positionUnits` is the named position's live units.
/// @custom:spec REQ-AMM-CORE-008, REQ-RISK-004, Q-371
struct RiskMetadata {
    // Current price inside the market's range.
    bool inRange;
    // Pool lock free.
    bool readSafe;
    // Always 0 from an LPVault (no unit counter); read Collateralization for credited units.
    uint256 avanaUnits;
    // Pool units the share is measured against.
    uint256 poolUnits;
    // Avana's pool share, bps.
    uint256 poolShareBps;
    // Units of the named position (0 when no position is named).
    uint128 positionUnits;
}
