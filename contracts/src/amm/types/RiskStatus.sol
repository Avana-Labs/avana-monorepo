// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Time-weighted pool depth of one market, returned by `IAmmIntegration.riskStatus`.
/// @dev `depthUnits` is the pool's depth over the window in the market's own units: for concentrated liquidity the
/// harmonic-mean in-range liquidity of the `observe` buffer, for fungible shares the effective LP supply of
/// `effectiveSupply`. The RiskModule's pool-share cap is per pool, summed over every market (range) of that pool on the
/// chain: `(poolUnits(poolKey) + L) * 1e4 <= poolShareMaxBpsOf(poolKey) * depthUnits` (SPEC-CAP-005, AMMN-RT-05), and it treats
/// `depthAvailable == false` as a share above the cap. Example: depth 2.5e18 units, cap 2,000 bps, two ranges of the
/// pool crediting 2.5e17 and 1.5e17 units: a pledge of 1.0e17 into either passes (5.0e21 <= 5.0e21), a pledge of
/// 1.0e17 + 1 fails.
/// @custom:spec REQ-AMM-CORE-013, SPEC-CAP-005, Q-295, Q-371
struct RiskStatus {
    // Time-weighted depth over the window, the market's units.
    uint256 depthUnits;
    // False when the AMM protocol keeps no history covering the window.
    bool depthAvailable;
}
