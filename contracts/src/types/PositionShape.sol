// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ShapeKind} from "./ShapeKind.sol";

/// @notice Exact position shape of a market.
/// @dev For `TickRange`, `tickLower < tickUpper`, both aligned to the pool's tick spacing with signed int24
/// `tick % tickSpacing == 0` (a `uint24` cast accepts tick -516 for spacing 10, AMM-A5c) and inside
/// `[ceil(MIN_TICK / s) * s, floor(MAX_TICK / s) * s]`; a pledged position must match both ticks exactly. For
/// `FullPool` both ticks are 0. The shape is fixed at listing and never changes.
/// @custom:spec REQ-AMM-CORE-003, REQ-AMM-CORE-004, Q-370
struct PositionShape {
    // Shape kind.
    ShapeKind kind;
    // Lower tick of the exact range (0 for FullPool).
    int24 tickLower;
    // Upper tick of the exact range (0 for FullPool).
    int24 tickUpper;
}
