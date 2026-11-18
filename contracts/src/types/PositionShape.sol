// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ShapeKind} from "./ShapeKind.sol";

/// @notice Exact position shape of a market, fixed at listing.
/// @dev For `TickRange`, `tickLower < tickUpper`, both aligned to the tick spacing; for `FullPool` both are 0.
struct PositionShape {
    ShapeKind kind;
    // Lower tick of the exact range (0 for FullPool).
    int24 tickLower;
    // Upper tick of the exact range (0 for FullPool).
    int24 tickUpper;
}
