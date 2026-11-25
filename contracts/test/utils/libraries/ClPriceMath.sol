// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClTickMath} from "../../../src/libraries/ClTickMath.sol";
import {LPPriceMath} from "../../../src/libraries/LPPriceMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title ClPriceMath
/// @notice Concentrated-liquidity arithmetic the pool fixtures and mocks use to price and fill positions.
/// @dev Every division rounds down.
library ClPriceMath {
    int24 internal constant MIN_TICK = ClTickMath.MIN_TICK;
    int24 internal constant MAX_TICK = ClTickMath.MAX_TICK;
    /// @notice `sqrtRatioAtTick(MIN_TICK)`.
    uint160 internal constant MIN_SQRT_RATIO = ClTickMath.MIN_SQRT_PRICE;
    /// @notice `sqrtRatioAtTick(MAX_TICK)`.
    uint160 internal constant MAX_SQRT_RATIO = ClTickMath.MAX_SQRT_PRICE;
    uint256 internal constant Q96 = 2 ** 96;
    /// @notice `2^128`, the scale of the upper branch of `oracleSqrtPrice`.
    uint256 internal constant Q128 = 2 ** 128;
    /// @notice `2^192`, the scale of a squared Q64.96 price.
    uint256 internal constant Q192 = 2 ** 192;

    /// @notice `sqrt(1.0001^tick) * 2^96`, rounded up as Uniswap rounds it.
    /// @dev Reverts `ClTickMath.TickOutOfRange` outside `[MIN_TICK, MAX_TICK]`.
    function sqrtRatioAtTick(
        int24 tick
    ) internal pure returns (uint160) {
        return ClTickMath.getSqrtPriceAtTick(tick);
    }

    /// @notice The greatest tick `t` with `sqrtRatioAtTick(t) <= sqrtPriceX96`.
    /// @dev Reverts `ClTickMath.SqrtRatioOutOfRange` outside `[MIN_SQRT_RATIO, MAX_SQRT_RATIO)`.
    function tickAtSqrtRatio(
        uint160 sqrtPriceX96
    ) internal pure returns (int24) {
        return ClTickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    /// @notice Oracle square-root price of two 8-decimal USD prices in the pool's raw token1-per-token0 format.
    /// @dev Rounds down, then clamps to `[MIN_SQRT_RATIO, MAX_SQRT_RATIO)`; never reverts for prices below 2^128.
    function oracleSqrtPrice(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) internal pure returns (uint160) {
        return LPPriceMath.sqrtPriceX96(p0, p1, d0, d1);
    }

    /// @notice Whether `oracleSqrtPrice` moved the price to a bound.
    function oracleSqrtClamped(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) internal pure returns (bool) {
        (uint256 raw, bool high) = LPPriceMath.rawSqrtPrice(p0, p1, d0, d1);
        return high || raw < MIN_SQRT_RATIO;
    }

    function clamp(
        uint160 s,
        uint160 sa,
        uint160 sb
    ) internal pure returns (uint160) {
        if (s < sa) return sa;
        if (s > sb) return sb;
        return s;
    }

    /// @notice Token amounts `units` of liquidity hold on `[sa, sb]` at the price `s`, each rounded down.
    /// @dev Requires `0 < sa < sb`; a reversed range reverts on the subtraction.
    function amountsForLiquidity(
        uint160 s,
        uint160 sa,
        uint160 sb,
        uint256 units
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (s <= sa) return (_token0Over(sa, sb, units), 0);
        if (s >= sb) return (0, _token1Over(sa, sb, units));
        return (_token0Over(s, sb, units), _token1Over(sa, s, units));
    }

    /// @notice Whether `[tickLower, tickUpper]` is an aligned, ordered range inside the usable ticks of `spacing`.
    function isUsableRange(
        int24 tickLower,
        int24 tickUpper,
        int24 spacing
    ) internal pure returns (bool) {
        if (spacing <= 0) return false;
        if (tickLower % spacing != 0 || tickUpper % spacing != 0 || tickLower >= tickUpper) return false;
        // Truncation toward zero is the ceiling for MIN_TICK and the floor for MAX_TICK, as intended.
        // forge-lint: disable-next-line(divide-before-multiply)
        return tickLower >= (MIN_TICK / spacing) * spacing && tickUpper <= (MAX_TICK / spacing) * spacing;
    }

    /// @notice Pool `maxLiquidityPerTick` of `spacing`: `type(uint128).max` shared over the usable ticks.
    /// @dev Requires `spacing > 0`.
    function maxLiquidityPerTick(
        int24 spacing
    ) internal pure returns (uint128) {
        // s > 0, so the quotient lies in [0, MAX_TICK].
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 perSide = uint256(uint24(MAX_TICK / spacing));
        // The tick count is at least 1, so the quotient is at most type(uint128).max.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(type(uint128).max / (2 * perSide + 1));
    }

    /// @notice Mean tick of a tick-cumulative difference over `window > 0` seconds, rounded toward negative infinity.
    function meanTick(
        int56 tickCumulativeDelta,
        uint32 window
    ) internal pure returns (int24) {
        int256 w = int256(uint256(window));
        // The non-negative remainder; subtracting it leaves an exact multiple of w, whose quotient is the floor.
        int256 r = tickCumulativeDelta % w;
        if (r < 0) r += w;
        return SafeCast.toInt24((tickCumulativeDelta - r) / w);
    }

    /// @notice Harmonic-mean in-range liquidity over `window` seconds from a seconds-per-liquidity difference.
    /// @dev Saturates at `type(uint128).max`; `ok` is false for a zero window or a zero difference.
    function harmonicMeanLiquidity(
        uint160 secondsPerLiquidityDelta,
        uint32 window
    ) internal pure returns (uint256 liquidity, bool ok) {
        if (window == 0 || secondsPerLiquidityDelta == 0) return (0, false);
        // The divisor is below 2^192 and non-zero here.
        liquidity = Math.mulDiv(window, type(uint160).max, uint256(secondsPerLiquidityDelta) << 32);
        return (Math.min(liquidity, type(uint128).max), true);
    }

    /// @dev Token0 that `units` hold over `[x, y]`, floored; `(y - x) << 96` fits since `y - x < 2^160`.
    function _token0Over(
        uint160 x,
        uint160 y,
        uint256 units
    ) private pure returns (uint256) {
        return Math.mulDiv(units, uint256(y - x) << 96, y) / x;
    }

    /// @dev Token1 that `units` hold over `[x, y]`: `floor(units * (y - x) / 2^96)`.
    function _token1Over(
        uint160 x,
        uint160 y,
        uint256 units
    ) private pure returns (uint256) {
        return Math.mulDiv(units, y - x, Q96);
    }
}
