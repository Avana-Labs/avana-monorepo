// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs
// Contains code ported from Uniswap v3 (c) 2021 Uniswap Labs, under GPL-2.0-or-later: `sqrtRatioAtTick` and
// `tickAtSqrtRatio` from v3-core contracts/libraries/TickMath.sol (commit 5ea68a7); `maxLiquidityPerTick`
// from v3-core contracts/libraries/Tick.sol (BUSL-1.1, converted to GPL-2.0-or-later on 2023-04-01);
// `amountsForLiquidity` from v3-periphery contracts/libraries/LiquidityAmounts.sol and `meanTick` and
// `harmonicMeanLiquidity` from v3-periphery contracts/libraries/OracleLibrary.sol (commit 24ccf01). This file
// is therefore licensed GPL-2.0-or-later; see THIRD_PARTY_LICENSES.md.

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title ClPriceMath
/// @notice Concentrated-liquidity arithmetic shared by every concentrated-liquidity LPVault (Uniswap v3, Aerodrome
/// Slipstream) and the concentrated-liquidity LPOracle module: the tick and square-root price conversions of the v3
/// liquidity math, the oracle square-root price of two token prices, the composition of `L` units on a range at a
/// clamped price, the exact-range test, the per-tick liquidity bound, and the mean tick and harmonic-mean liquidity of
/// an observation pair.
/// @dev Internal pure functions; no storage and no external call. Every division rounds down (`REQ-ORACLE-012`).
/// `sqrtRatioAtTick` and `tickAtSqrtRatio` are Uniswap v3-core `TickMath` (commit 5ea68a7) in Solidity 0.8 with
/// unchecked arithmetic, the same constants and the same results; the logarithm steps are written without assembly.
/// @custom:spec SPEC-ORC-006, SPEC-ORC-009, SPEC-ORC-010, SPEC-AMM-V3-001, SPEC-AMM-CORE-001, SPEC-BACK-001, REQ-AMM-V3-005, REQ-AMM-V3-006, REQ-AMM-V3-007, REQ-ORACLE-012
library ClPriceMath {
    /// @notice Lowest tick of the v3 liquidity math.
    int24 internal constant MIN_TICK = -887_272;
    /// @notice Highest tick of the v3 liquidity math.
    int24 internal constant MAX_TICK = 887_272;
    /// @notice `sqrtRatioAtTick(MIN_TICK)`.
    uint160 internal constant MIN_SQRT_RATIO = 4_295_128_739;
    /// @notice `sqrtRatioAtTick(MAX_TICK)`.
    uint160 internal constant MAX_SQRT_RATIO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;
    /// @notice `2^96`, one in Q64.96.
    uint256 internal constant Q96 = 2 ** 96;
    /// @notice `2^128`, the scale of the upper branch of `SPEC-ORC-009`.
    uint256 internal constant Q128 = 2 ** 128;
    /// @notice `2^192`, the scale of a squared Q64.96 price.
    uint256 internal constant Q192 = 2 ** 192;

    /// @notice A tick outside `[MIN_TICK, MAX_TICK]`.
    error TickOutOfRange(int24 tick);
    /// @notice A square-root price outside `[MIN_SQRT_RATIO, MAX_SQRT_RATIO)`.
    error SqrtRatioOutOfRange(uint160 sqrtPriceX96);

    /// @notice `sqrt(1.0001^tick) * 2^96`, rounded up as Uniswap v3 rounds it.
    /// @dev Reverts `TickOutOfRange` outside `[MIN_TICK, MAX_TICK]`. Example: tick 0 gives `2^96`.
    /// @custom:spec SPEC-ORC-006, SPEC-AMM-V3-001
    // One branch per bit of |tick|, the table of Uniswap's TickMath, kept as written so it can be compared line by line.
    // forge-lint: disable-next-line(cyclomatic-complexity)
    function sqrtRatioAtTick(
        int24 tick
    ) internal pure returns (uint160 sqrtPriceX96) {
        if (tick < MIN_TICK || tick > MAX_TICK) revert TickOutOfRange(tick);
        unchecked {
            // |tick| <= 887,272, so the negation cannot overflow.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 2 ** 128;
            if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;
            if (tick > 0) ratio = type(uint256).max / ratio;
            // Q128.128 to Q64.96, rounding up; the result fits 160 bits for every tick in range.
            // forge-lint: disable-next-line(unsafe-typecast)
            sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
        }
    }

    /// @notice The greatest tick `t` with `sqrtRatioAtTick(t) <= sqrtPriceX96`.
    /// @dev Reverts `SqrtRatioOutOfRange` outside `[MIN_SQRT_RATIO, MAX_SQRT_RATIO)`. Same result as Uniswap v3
    /// `TickMath.getTickAtSqrtRatio`: the binary logarithm by `Math.log2` and fourteen squaring steps, then the two
    /// candidate ticks compared with `sqrtRatioAtTick`.
    /// @custom:spec SPEC-ORC-010
    function tickAtSqrtRatio(
        uint160 sqrtPriceX96
    ) internal pure returns (int24 tick) {
        if (sqrtPriceX96 < MIN_SQRT_RATIO || sqrtPriceX96 >= MAX_SQRT_RATIO) revert SqrtRatioOutOfRange(sqrtPriceX96);
        unchecked {
            uint256 ratio = uint256(sqrtPriceX96) << 32;
            uint256 msb = Math.log2(ratio);
            uint256 r = msb >= 128 ? ratio >> (msb - 127) : ratio << (127 - msb);
            // msb < 192.
            // forge-lint: disable-next-line(unsafe-typecast)
            int256 log2 = (int256(msb) - 128) << 64;
            for (uint256 bit = 63; bit > 49; --bit) {
                r = (r * r) >> 127;
                uint256 f = r >> 128;
                // f is 0 or 1, so the shifted value is below 2^64.
                // forge-lint: disable-next-line(unsafe-typecast)
                log2 |= int256(f << bit);
                r >>= f;
            }
            int256 logSqrt10001 = log2 * 255_738_958_999_603_826_347_141;
            // Both bounds lie within one tick of the true tick, inside int24.
            // forge-lint: disable-next-line(unsafe-typecast)
            int24 tickLow = int24((logSqrt10001 - 3_402_992_956_809_132_418_596_140_100_660_247_210) >> 128);
            // forge-lint: disable-next-line(unsafe-typecast)
            int24 tickHi = int24((logSqrt10001 + 291_339_464_771_989_622_907_027_621_153_398_088_495) >> 128);
            tick = tickLow == tickHi ? tickLow : sqrtRatioAtTick(tickHi) <= sqrtPriceX96 ? tickHi : tickLow;
        }
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
    /// (`SPEC-ORC-006`, Uniswap `LiquidityAmounts.getAmountsForLiquidity`).
    /// @dev `s <= sa`: `a0 = floor(floor(u * 2^96 * (sb - sa) / sb) / sa)`, `a1 = 0`; `s >= sb`: `a0 = 0`,
    /// `a1 = floor(u * (sb - sa) / 2^96)`; otherwise `a0 = floor(floor(u * 2^96 * (sb - s) / sb) / s)` and
    /// `a1 = floor(u * (s - sa) / 2^96)`. Requires `0 < sa < sb`. Example: full range at spacing 60 with `s = 2^96`
    /// and `u = 5,000,000,000` gives `(4,999,999,999, 4,999,999,999)`.
    /// @custom:spec SPEC-ORC-006, SPEC-AMM-V3-001
    function amountsForLiquidity(
        uint160 s,
        uint160 sa,
        uint160 sb,
        uint256 units
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (s <= sa) {
            amount0 = _amount0(sa, sb, units);
        } else if (s < sb) {
            amount0 = _amount0(s, sb, units);
            amount1 = Math.mulDiv(units, s - sa, Q96);
        } else {
            amount1 = Math.mulDiv(units, sb - sa, Q96);
        }
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

    /// @notice Pool `maxLiquidityPerTick` of spacing `s`: `type(uint128).max / numTicks(s)` (`REQ-AMM-V3-007`).
    /// @dev Uniswap v3 `Tick.tickSpacingToMaxLiquidityPerTick`. Requires `s > 0`. Example: about `1.92 * 10^32` for
    /// `s = 1` and `3.83 * 10^34` for `s = 200`.
    /// @custom:spec REQ-AMM-V3-007
    function maxLiquidityPerTick(
        int24 spacing
    ) internal pure returns (uint128) {
        // Truncating divisions give the usable tick bounds, as Uniswap's Tick.tickSpacingToMaxLiquidityPerTick does.
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 minTick = (MIN_TICK / spacing) * spacing;
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 maxTick = (MAX_TICK / spacing) * spacing;
        // The tick count is positive and below 2^21.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 numTicks = uint256(uint24((maxTick - minTick) / spacing)) + 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(type(uint128).max / numTicks);
    }

    /// @notice Arithmetic mean tick of a tick-cumulative difference over `window` seconds, rounded toward negative
    /// infinity (`SPEC-ORC-010`, Uniswap `OracleLibrary.consult`). Requires `window > 0`; reverts
    /// `SafeCastOverflowedIntDowncast` for a mean outside `int24`, which no pool's cumulatives produce.
    /// @custom:spec SPEC-ORC-010
    function meanTick(
        int56 tickCumulativeDelta,
        uint32 window
    ) internal pure returns (int24 tick) {
        int56 w = int56(uint56(window));
        // |delta / w| <= MAX_TICK for cumulatives a pool writes; the difference comes from the pool's `observe`, so a
        // value outside int24 reverts rather than wrapping.
        tick = SafeCast.toInt24(tickCumulativeDelta / w);
        if (tickCumulativeDelta < 0 && tickCumulativeDelta % w != 0) --tick;
    }

    /// @notice Harmonic-mean in-range liquidity over `window` seconds from a seconds-per-liquidity difference
    /// (`REQ-AMM-V3-006`, Uniswap `OracleLibrary.consult`).
    /// @dev `floor(window * (2^160 - 1) / (delta * 2^32))`, saturated at `type(uint128).max`; `ok` is false for a zero
    /// window or a zero difference, which the caller reports as unavailable depth.
    /// @custom:spec REQ-AMM-V3-006, REQ-AMM-CORE-013
    function harmonicMeanLiquidity(
        uint160 secondsPerLiquidityDelta,
        uint32 window
    ) internal pure returns (uint256 liquidity, bool ok) {
        if (window == 0 || secondsPerLiquidityDelta == 0) return (0, false);
        uint256 h = (uint256(window) * type(uint160).max) / (uint256(secondsPerLiquidityDelta) << 32);
        return (h > type(uint128).max ? type(uint128).max : h, true);
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

    function _amount0(
        uint160 sLow,
        uint160 sHigh,
        uint256 units
    ) private pure returns (uint256) {
        return Math.mulDiv(units, uint256(sHigh - sLow) << 96, sHigh) / sLow;
    }
}
