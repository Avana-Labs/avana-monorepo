// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClTickMath} from "./ClTickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title ClPriceMath
/// @notice Concentrated-liquidity arithmetic shared by every concentrated-liquidity LPVault (Uniswap v3, Aerodrome
/// Slipstream) and the concentrated-liquidity LPOracle module: the tick and square-root price conversions of the v3
/// liquidity math, the oracle square-root price of two token prices, the composition of `L` units on a range at a
/// clamped price, the exact-range test, the per-tick liquidity bound, and the mean tick and harmonic-mean liquidity of
/// an observation pair.
/// @dev Internal pure functions; no storage and no external call. Every division rounds down (`REQ-ORACLE-012`).
/// `sqrtRatioAtTick` and `tickAtSqrtRatio` call `ClTickMath`, the MIT-licensed Uniswap v4-core `TickMath`, whose
/// results equal the v3 tick math the pools run; everything else here is Avana's own code, written from the spec.
/// @custom:spec SPEC-ORC-006, SPEC-ORC-009, SPEC-ORC-010, SPEC-AMM-V3-001, SPEC-AMM-CORE-001, SPEC-BACK-001, REQ-AMM-V3-005, REQ-AMM-V3-006, REQ-AMM-V3-007, REQ-ORACLE-012
library ClPriceMath {
    /// @notice Lowest tick of the v3 liquidity math.
    int24 internal constant MIN_TICK = ClTickMath.MIN_TICK;
    /// @notice Highest tick of the v3 liquidity math.
    int24 internal constant MAX_TICK = ClTickMath.MAX_TICK;
    /// @notice `sqrtRatioAtTick(MIN_TICK)`, 4,295,128,739.
    uint160 internal constant MIN_SQRT_RATIO = ClTickMath.MIN_SQRT_PRICE;
    /// @notice `sqrtRatioAtTick(MAX_TICK)`, 1,461,446,703,485,210,103,287,273,052,203,988,822,378,723,970,342.
    uint160 internal constant MAX_SQRT_RATIO = ClTickMath.MAX_SQRT_PRICE;
    /// @notice `2^96`, one in Q64.96.
    uint256 internal constant Q96 = 2 ** 96;
    /// @notice `2^128`, the scale of the upper branch of `SPEC-ORC-009`.
    uint256 internal constant Q128 = 2 ** 128;
    /// @notice `2^192`, the scale of a squared Q64.96 price.
    uint256 internal constant Q192 = 2 ** 192;

    /// @notice `sqrt(1.0001^tick) * 2^96`, rounded up as Uniswap rounds it.
    /// @dev `ClTickMath.getSqrtPriceAtTick`. Reverts `ClTickMath.TickOutOfRange` outside `[MIN_TICK, MAX_TICK]`. Example: tick 0
    /// gives `2^96`.
    /// @custom:spec SPEC-ORC-006, SPEC-AMM-V3-001
    function sqrtRatioAtTick(
        int24 tick
    ) internal pure returns (uint160) {
        return ClTickMath.getSqrtPriceAtTick(tick);
    }

    /// @notice The greatest tick `t` with `sqrtRatioAtTick(t) <= sqrtPriceX96`.
    /// @dev `ClTickMath.getTickAtSqrtPrice`. Reverts `ClTickMath.SqrtRatioOutOfRange` outside `[MIN_SQRT_RATIO, MAX_SQRT_RATIO)`.
    /// @custom:spec SPEC-ORC-010
    function tickAtSqrtRatio(
        uint160 sqrtPriceX96
    ) internal pure returns (int24) {
        return ClTickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    /// @notice Oracle square-root price of two 8-decimal USD prices in the pool's raw token1-per-token0 format
    /// (`SPEC-ORC-009`).
    /// @dev `num = p0 * 10^d1`, `den = p1 * 10^d0`. Below `num = 2^64 * den`: `isqrt(mulDiv(num, 2^192, den))`, floored,
    /// raised to `MIN_SQRT_RATIO` when below it. From `2^64 * den` to below `2^128 * den`: `isqrt(mulDiv(num, 2^128,
    /// den)) * 2^32`, at most `2^32` below the exact root, lowered to `MAX_SQRT_RATIO - 1` when at or above
    /// `MAX_SQRT_RATIO`. From `2^128 * den`: `MAX_SQRT_RATIO - 1`. Never above the exact root except where raised to
    /// `MIN_SQRT_RATIO`, non-decreasing in `num / den`, and never reverts for `p0, p1` in `[1, 2^128)` and decimals at
    /// most 18 (the callers' bounds). Examples: DAI (18) / USDC (6) at $1 each gives `79,228,162,514,264,337,593,543`
    /// (`2^96 * 10^-6`); a 6-decimal token0 at $1 and an 18-decimal token1 at $5e-8 give
    /// `354,319,114,228,591,420,592,203,432,319,359,385,600`.
    /// @param p0 Price of token0, 8 decimals.
    /// @param p1 Price of token1, 8 decimals.
    /// @param d0 Decimals of token0.
    /// @param d1 Decimals of token1.
    /// @return Q64.96 square root of raw token1 per raw token0, in `[MIN_SQRT_RATIO, MAX_SQRT_RATIO)`.
    /// @custom:spec SPEC-ORC-009, REQ-ORACLE-012
    function oracleSqrtPrice(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) internal pure returns (uint160) {
        (uint256 raw, bool high) = _rawOracleSqrt(p0, p1, d0, d1);
        if (high) return MAX_SQRT_RATIO - 1;
        if (raw < MIN_SQRT_RATIO) return MIN_SQRT_RATIO;
        // Not high, so raw < MAX_SQRT_RATIO < 2^160.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(raw);
    }

    /// @notice Whether `oracleSqrtPrice` moved the price to a bound (`SPEC-ORC-009` "clamped").
    /// @custom:spec SPEC-ORC-009, REQ-ORACLE-104
    function oracleSqrtClamped(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) internal pure returns (bool) {
        (uint256 raw, bool high) = _rawOracleSqrt(p0, p1, d0, d1);
        return high || raw < MIN_SQRT_RATIO;
    }

    /// @notice `min(max(s, sa), sb)`: a price clamped to a range (`SPEC-ORC-006`).
    /// @custom:spec SPEC-ORC-006, SPEC-AMM-V3-001
    function clamp(
        uint160 s,
        uint160 sa,
        uint160 sb
    ) internal pure returns (uint160) {
        if (s < sa) return sa;
        if (s > sb) return sb;
        return s;
    }

    /// @notice Token amounts `units` of liquidity hold on `[sa, sb]` at the price `s`, each rounded down
    /// (`SPEC-ORC-006`).
    /// @dev The price is placed in the range: at or above `sb` the position is all token1, at or below `sa` all token0,
    /// and in between it holds token0 for `[s, sb]` and token1 for `[sa, s]`. Token0 over `[x, y]` is
    /// `floor(floor(u * 2^96 * (y - x) / y) / x)` and token1 over `[x, y]` is `floor(u * (y - x) / 2^96)`. Requires
    /// `0 < sa < sb`; a reversed range reverts on the subtraction. Example: full range at spacing 60 with `s = 2^96` and
    /// `u = 5,000,000,000` gives `(4,999,999,999, 4,999,999,999)`.
    /// @custom:spec SPEC-ORC-006, SPEC-AMM-V3-001
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

    /// @notice Whether `[tickLower, tickUpper]` is an aligned, ordered range inside the usable ticks of spacing `s`
    /// (`SPEC-BACK-001`).
    /// @dev Signed `int24` remainder (`-516 % 10 == -6`, refused), `tickLower < tickUpper`, and both inside
    /// `[ceil(MIN_TICK / s) * s, floor(MAX_TICK / s) * s]`. False for `s <= 0`. Example: spacing 60 gives the full range
    /// `[-887,220, 887,220]`.
    /// @custom:spec SPEC-BACK-001
    function isUsableRange(
        int24 tickLower,
        int24 tickUpper,
        int24 spacing
    ) internal pure returns (bool) {
        if (spacing <= 0) return false;
        if (tickLower % spacing != 0 || tickUpper % spacing != 0 || tickLower >= tickUpper) return false;
        // Solidity division truncates toward zero, which is the ceiling for MIN_TICK and the floor for MAX_TICK; the
        // truncation is the rounding SPEC-BACK-001 asks for.
        // forge-lint: disable-next-line(divide-before-multiply)
        return tickLower >= (MIN_TICK / spacing) * spacing && tickUpper <= (MAX_TICK / spacing) * spacing;
    }

    /// @notice Pool `maxLiquidityPerTick` of spacing `s`: `type(uint128).max` shared over the usable ticks
    /// (`REQ-AMM-V3-007`).
    /// @dev The usable ticks are the multiples of `s` in `[-MAX_TICK, MAX_TICK]`: `n = floor(MAX_TICK / s)` on each side
    /// of 0 and 0 itself, `2n + 1` in all, as the pools count them. Requires `s > 0`. Example: about `1.92 * 10^32` for
    /// `s = 1` and `3.83 * 10^34` for `s = 200`.
    /// @custom:spec REQ-AMM-V3-007
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

    /// @notice Arithmetic mean tick of a tick-cumulative difference over `window` seconds, rounded toward negative
    /// infinity (`SPEC-ORC-010`). Requires `window > 0`; reverts `SafeCastOverflowedIntDowncast` for a mean outside
    /// `int24`, which no pool's cumulatives produce.
    /// @custom:spec SPEC-ORC-010
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

    /// @notice Harmonic-mean in-range liquidity over `window` seconds from a seconds-per-liquidity difference
    /// (`REQ-AMM-V3-006`).
    /// @dev `floor(window * (2^160 - 1) / (delta * 2^32))`, saturated at `type(uint128).max`; `ok` is false for a zero
    /// window or a zero difference, which the caller reports as unavailable depth.
    /// @custom:spec REQ-AMM-V3-006, REQ-AMM-CORE-013
    function harmonicMeanLiquidity(
        uint160 secondsPerLiquidityDelta,
        uint32 window
    ) internal pure returns (uint256 liquidity, bool ok) {
        if (window == 0 || secondsPerLiquidityDelta == 0) return (0, false);
        // The divisor is below 2^192 and non-zero here.
        liquidity = Math.mulDiv(window, type(uint160).max, uint256(secondsPerLiquidityDelta) << 32);
        return (Math.min(liquidity, type(uint128).max), true);
    }

    /// @dev The three branches of `SPEC-ORC-009`: below `2^64 * den` the floored `isqrt(mulDiv(num, 2^192, den))`
    /// (`X < 2^256`); below `2^128 * den` the floored `isqrt(mulDiv(num, 2^128, den)) * 2^32` (`2^192 <= Y < 2^256`),
    /// `high` when it reaches `MAX_SQRT_RATIO`; from `2^128 * den` on, `high`. `den < 2^188`, so `den << 64` fits, and
    /// the `2^128 * den` test is `num >> 128 >= den`, which cannot overflow.
    function _rawOracleSqrt(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) private pure returns (uint256 raw, bool high) {
        uint256 num = p0 * 10 ** d1;
        uint256 den = p1 * 10 ** d0;
        if (num < den << 64) return (Math.sqrt(Math.mulDiv(num, Q192, den)), false);
        if (num >> 128 >= den) return (0, true);
        raw = Math.sqrt(Math.mulDiv(num, Q128, den)) << 32;
        high = raw >= MAX_SQRT_RATIO;
    }

    /// @dev Token0 that `units` hold over `[x, y]`: `floor(floor(units * 2^96 * (y - x) / y) / x)`. `(y - x) << 96` is
    /// below `2^256` because `y - x < 2^160`.
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
