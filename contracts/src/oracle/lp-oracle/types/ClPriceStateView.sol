// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Concentrated-liquidity detail of an LPOracle evaluation, returned by `ILPOracleCL.getClPriceState()`.
/// @dev One tick is a price ratio of 1.0001, about 1 bp.
struct ClPriceStateView {
    int24 tickLower;
    int24 tickUpper;
    // Oracle sqrt price before the clamp, Q64.96.
    uint160 sqrtPriceOracleX96;
    // Oracle sqrt price after the clamp to the range, Q64.96 (the composition input).
    uint160 sqrtPriceUsedX96;
    bool clamped;
    // Pool TWAP mean tick over twapWindow, rounded toward negative infinity.
    int24 meanTick;
    // Oracle-implied tick from the uncapped quotes.
    int24 tickRef;
    // |meanTick - tickRef| in ticks.
    uint24 tickDeviation;
    // TWAP tolerance in ticks (`OracleConfig.consistencyToleranceBps`).
    uint24 twapToleranceTicks;
    uint16 observationCardinality;
}
