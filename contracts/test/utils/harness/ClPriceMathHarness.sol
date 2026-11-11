// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../../src/amm/concentrated-liquidity/ClPriceMath.sol";

/// @title ClPriceMathHarness
/// @notice External wrappers over the internal ClPriceMath functions, for unit, fuzz, differential and Halmos suites.
contract ClPriceMathHarness {
    function sqrtRatioAtTick(
        int24 tick
    ) external pure returns (uint160) {
        return ClPriceMath.sqrtRatioAtTick(tick);
    }

    function tickAtSqrtRatio(
        uint160 s
    ) external pure returns (int24) {
        return ClPriceMath.tickAtSqrtRatio(s);
    }

    function oracleSqrtPrice(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) external pure returns (uint160, bool) {
        return (ClPriceMath.oracleSqrtPrice(p0, p1, d0, d1), ClPriceMath.oracleSqrtClamped(p0, p1, d0, d1));
    }

    function clamp(
        uint160 s,
        uint160 sa,
        uint160 sb
    ) external pure returns (uint160) {
        return ClPriceMath.clamp(s, sa, sb);
    }

    function amountsForLiquidity(
        uint160 s,
        uint160 sa,
        uint160 sb,
        uint256 units
    ) external pure returns (uint256, uint256) {
        return ClPriceMath.amountsForLiquidity(s, sa, sb, units);
    }

    function isUsableRange(
        int24 lower,
        int24 upper,
        int24 spacing
    ) external pure returns (bool) {
        return ClPriceMath.isUsableRange(lower, upper, spacing);
    }

    function maxLiquidityPerTick(
        int24 spacing
    ) external pure returns (uint128) {
        return ClPriceMath.maxLiquidityPerTick(spacing);
    }

    function meanTick(
        int56 delta,
        uint32 window
    ) external pure returns (int24) {
        return ClPriceMath.meanTick(delta, window);
    }

    function harmonicMeanLiquidity(
        uint160 delta,
        uint32 window
    ) external pure returns (uint256, bool) {
        return ClPriceMath.harmonicMeanLiquidity(delta, window);
    }
}
