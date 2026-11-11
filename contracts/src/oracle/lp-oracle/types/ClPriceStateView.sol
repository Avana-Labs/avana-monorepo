// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Concentrated-liquidity detail of an LPOracle evaluation, returned by `ILPOracleCL.getClPriceState()`.
/// @dev The oracle sqrt price is `sO = isqrt(mulDiv(num, 2^192, den))` (Q64.96, floored) from the token quotes, then
/// clamped to `[sqrtRatioAtTick(tickLower), sqrtRatioAtTick(tickUpper)]` (AMMN-RT-02): outside the range the
/// position is entirely one token and the clamp makes the composition exactly that token. The consistency check
/// compares `meanTick` (pool TWAP over `twapWindow`, rounded toward negative infinity) with `tickRef` (the tick of the
/// unclamped oracle sqrt price); one tick is a price ratio of 1.0001, so `twapToleranceTicks` = 50 admits a 0.501 % gap.
/// @custom:spec REQ-ORACLE-042, REQ-AMM-V3-005, REQ-AMM-SLIP-005, Q-325, Q-330
struct ClPriceStateView {
    // Market range lower tick.
    int24 tickLower;
    // Market range upper tick.
    int24 tickUpper;
    // Oracle sqrt price before the clamp, Q64.96.
    uint160 sqrtPriceOracleX96;
    // Oracle sqrt price after the clamp, Q64.96 (the composition input).
    uint160 sqrtPriceUsedX96;
    // True when the clamp changed the sqrt price.
    bool clamped;
    // Pool TWAP mean tick over twapWindow, rounded toward negative infinity.
    int24 meanTick;
    // Oracle-implied reference tick from the uncapped quotes.
    int24 tickRef;
    // |meanTick - tickRef| in ticks.
    uint24 tickDeviation;
    // TWAP tolerance in ticks, equal to OracleConfig.consistencyToleranceBps.
    uint24 twapToleranceTicks;
    // Observation cardinality of the pool at evaluation.
    uint16 observationCardinality;
}
