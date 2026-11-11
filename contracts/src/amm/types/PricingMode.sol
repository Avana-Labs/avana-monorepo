// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Whether an AMM protocol's composition at an oracle price vector is exact.
/// @dev `ClosedForm`: the integration returns the exact token amounts one position holds at the oracle prices
/// (concentrated liquidity: `getAmountsForLiquidity` at the clamped oracle sqrt price; constant product:
/// `r_i = sqrt(k * prod p_j) / p_i` per unit of effective supply). `LowerBound`: no closed form exists (Curve
/// StableSwap); the integration returns amounts whose oracle value is `min_i(p_i) * D / supply`, proved never above
/// the redeemable value (AMM-C2c). Ordinal values are fixed.
/// @custom:spec REQ-AMM-CORE-012, Q-371
enum PricingMode {
    ClosedForm,
    LowerBound
}
