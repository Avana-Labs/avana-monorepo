// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IClPoolObservations
/// @notice Pool reads with one layout on Uniswap v3 and Aerodrome Slipstream: in-range liquidity and observations.
interface IClPoolObservations {
    /// @notice In-range liquidity of the pool.
    function liquidity() external view returns (uint128);

    /// @notice Tick and seconds-per-liquidity cumulatives at each `secondsAgos`.
    function observe(
        uint32[] calldata secondsAgos
    ) external view returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}
