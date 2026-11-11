// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IPoolObservations
/// @notice The leading fields of `slot0()` that Uniswap v3 and Aerodrome Slipstream pools share, read by the
/// ParameterStore to compare the pool's observation buffer with `twapMinObservations(marketId)`.
/// @dev Uniswap v3 returns seven words and Slipstream six; both start with `sqrtPriceX96`, `tick`, `observationIndex`
/// and `observationCardinality`, and ABI decoding of return data ignores the trailing words, so one declaration reads
/// both. Example: a Base Slipstream pool with cardinality 151 under a 1,800 s window needs 901 and is refused.
/// @custom:spec REQ-PSTORE-027, SPEC-ORC-022
interface IPoolObservations {
    /// @notice The pool's current price, tick and observation-buffer state.
    /// @return sqrtPriceX96 Current sqrt price, Q64.96.
    /// @return tick Current tick.
    /// @return observationIndex Index of the latest observation.
    /// @return observationCardinality Number of populated observation slots.
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality);
}
