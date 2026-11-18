// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Exposure counter named in a `CounterSaturated` event.
enum CounterKind {
    MarketRegular,
    MarketSlice,
    Token
}
