// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IPoolObservations
/// @notice The leading `slot0()` fields shared by Uniswap v3 and Aerodrome Slipstream pools.
/// @dev ABI decoding ignores the trailing return words, so one declaration reads both pool kinds.
interface IPoolObservations {
    /// @notice The pool's current price, tick and observation-buffer state.
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality);
}
