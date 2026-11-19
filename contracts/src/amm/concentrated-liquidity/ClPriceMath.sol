// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LegacyPriceMath} from "../../legacy/LegacyPriceMath.sol";
import {LPPriceMath} from "../../oracle/LPPriceMath.sol";
import {ClTickMath} from "./ClTickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title ClPriceMath
/// @notice Concentrated-liquidity arithmetic shared by the concentrated-liquidity LPVaults and LPOracle module.
/// @dev Every division rounds down.
library ClPriceMath {
    /// @notice Largest unit exponent `k`, so a whole vault token's liquidity fits `uint128`.
    uint8 internal constant MAX_UNIT_EXP = 18;
    /// @notice Decades of headroom the pool's unit exponent leaves below its reference range.
    uint8 internal constant UNIT_EXP_HEADROOM = 2;
    /// @notice Largest reference exponent searched, so `k <= MAX_UNIT_EXP`.
    uint8 internal constant MAX_REFERENCE_EXP = LegacyPriceMath.MAX_VAULT_DECIMALS + MAX_UNIT_EXP - UNIT_EXP_HEADROOM;

    /// @notice The listing prices of a binding: the price vector, the token decimals and the oracle square-root price.
    struct Valuation {
        uint256[] prices;
        uint8[] decs;
        uint160 sO;
    }

    /// @notice The valuation at listing prices `(price0, price1)` (8 decimals) of tokens of decimals `(d0, d1)`.
    /// @dev The caller checks the prices are in `[1, MAX_ROUTE_ANSWER]` and the decimals at most 18.
    function valuation(
        uint256 price0,
        uint256 price1,
        uint8 d0,
        uint8 d1
    ) internal pure returns (Valuation memory v) {
        v.prices = new uint256[](2);
        (v.prices[0], v.prices[1]) = (price0, price1);
        v.decs = new uint8[](2);
        (v.decs[0], v.decs[1]) = (d0, d1);
        v.sO = ClPriceMath.oracleSqrtPrice(price0, price1, d0, d1);
    }

    /// @notice First-binding unit exponent, from the smallest `10^e` liquidity worth $1 on the reference range.
    /// @return found False when no `e` passes (the binding is refused).
    function firstBindingExponent(
        Valuation memory v,
        int24 tickSpacing
    ) internal pure returns (bool found, uint8 k) {
        (int24 refLower, int24 refUpper) = referenceRange(v.sO, tickSpacing);
        uint8 e;
        (found, e) = firstWorthOneDollar(v, refLower, refUpper, LegacyPriceMath.MIN_VAULT_DECIMALS, MAX_REFERENCE_EXP);
        // e <= MAX_REFERENCE_EXP = 34, so k = e + 2 - 18 <= MAX_UNIT_EXP = 18.
        if (found && e + UNIT_EXP_HEADROOM > LegacyPriceMath.MAX_VAULT_DECIMALS) {
            k = e + UNIT_EXP_HEADROOM - LegacyPriceMath.MAX_VAULT_DECIMALS;
        }
    }

    /// @notice The market's decimals: the smallest `d` in `[6, 18]` whose whole token is worth at least $1.
    /// @return found False when no `d` passes (the binding is refused).
    function unitDecimals(
        Valuation memory v,
        int24 tickLower,
        int24 tickUpper,
        uint8 k
    ) internal pure returns (bool found, uint8 d) {
        uint8 e;
        (found, e) = firstWorthOneDollar(
            v, tickLower, tickUpper, LegacyPriceMath.MIN_VAULT_DECIMALS + k, LegacyPriceMath.MAX_VAULT_DECIMALS + k
        );
        if (found) d = e - k;
    }

    /// @notice The smallest `e` in `[from, to]` whose `10^e` liquidity on the range is worth at least $1.
    function firstWorthOneDollar(
        Valuation memory v,
        int24 tickLower,
        int24 tickUpper,
        uint8 from,
        uint8 to
    ) internal pure returns (bool found, uint8 e) {
        uint160 sa = ClPriceMath.sqrtRatioAtTick(tickLower);
        uint160 sb = ClPriceMath.sqrtRatioAtTick(tickUpper);
        uint160 s = ClPriceMath.clamp(v.sO, sa, sb);
        for (e = from; e <= to; ++e) {
            uint256[] memory a = new uint256[](2);
            (a[0], a[1]) = ClPriceMath.amountsForLiquidity(s, sa, sb, 10 ** e);
            (bool valid, uint256 price8) = LegacyPriceMath.lpPrice(a, v.prices, v.decs);
            if (valid && price8 >= LegacyPriceMath.PRICE_UNIT) return (true, e);
        }
        return (false, 0);
    }

    /// @notice The pool's reference range: the one tick spacing `[t, t + s]` holding the tick of the listing price.
    /// @dev Always inside the usable ticks for listable prices and decimals.
    function referenceRange(
        uint160 sO,
        int24 spacing
    ) internal pure returns (int24 lower, int24 upper) {
        int24 tick = ClPriceMath.tickAtSqrtRatio(sO);
        // Floor of tick / spacing toward −∞; Solidity truncates toward zero.
        // forge-lint: disable-next-line(divide-before-multiply)
        lower = (tick / spacing) * spacing;
        if (lower > tick) lower -= spacing;
        upper = lower + spacing;
    }

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
