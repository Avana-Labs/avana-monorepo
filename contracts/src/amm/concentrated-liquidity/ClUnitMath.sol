// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPPriceMath} from "../../oracle/lp-oracle/LPPriceMath.sol";
import {ClPriceMath} from "./ClPriceMath.sol";

/// @title ClUnitMath
/// @notice The vault-token unit of a concentrated-liquidity market (`SPEC-ORC-005`): the pool's unit exponent `k` (one
/// unit = `10^k` liquidity) and the market's decimals `d` (one whole token = `10^d` units = `10^(d + k)` liquidity).
/// @dev One copy of the rule, compiled into the concentrated-liquidity LPVaults (`bindMarket`), so a listing script or
/// a test computes the `k` an LPOracle's `market` argument must carry with the code that binds the market. Pure: the
/// caller supplies the listing prices, the token decimals, the pool's tick spacing and the range. Example: two
/// 18-decimal $1 tokens on spacing 1 find `e = 23` on one tick, so `k = 7`; `[−10, 10]` then lists at `d = 15`.
/// @custom:spec SPEC-ORC-005, SPEC-UNIT-001, SPEC-UNIT-002
library ClUnitMath {
    /// @notice Largest unit exponent `k`: `10^(18 + k) <= 10^36 < 2^128`, so the liquidity of a whole vault token always
    /// fits the position manager's `uint128`.
    uint8 internal constant MAX_UNIT_EXP = 18;
    /// @notice Decades of headroom the pool's unit exponent leaves below its reference range: a later market of the
    /// pool whose liquidity is worth down to 1/100 of the reference range's per unit still lists.
    uint8 internal constant UNIT_EXP_HEADROOM = 2;
    /// @notice Largest reference exponent searched, `MAX_VAULT_DECIMALS + MAX_UNIT_EXP - UNIT_EXP_HEADROOM = 34`, so
    /// `k <= MAX_UNIT_EXP`. Even at the cheapest listing prices, $10^-8 per whole token, two 18-decimal tokens on one
    /// tick find `e = 31` (`MATH-UO-77g`), so the search ends inside the bound for every listable pool.
    uint8 internal constant MAX_REFERENCE_EXP = LPPriceMath.MAX_VAULT_DECIMALS + MAX_UNIT_EXP - UNIT_EXP_HEADROOM;

    /// @notice The listing prices of a binding: the price vector, the token decimals and the oracle square-root price.
    struct Valuation {
        uint256[] prices;
        uint8[] decs;
        uint160 sO;
    }

    /// @notice The valuation at listing prices `(price0, price1)` (8 decimals) of tokens of decimals `(d0, d1)`.
    /// @dev The caller checks the prices are in `[1, MAX_ROUTE_ANSWER]` and the decimals at most 18 (`SPEC-ORC-009`).
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

    /// @notice The unit exponent a pool takes at its first binding: `k = max(0, e + UNIT_EXP_HEADROOM − 18)` with `e`
    /// the smallest exponent in `[6, MAX_REFERENCE_EXP]` whose `10^e` liquidity on the pool's reference range (one tick
    /// spacing, holding the listing price) is worth at least $1 at the listing prices.
    /// @return found False when no `e` passes (the binding is refused).
    /// @return k The pool's unit exponent, at most `MAX_UNIT_EXP`.
    function firstBindingExponent(
        Valuation memory v,
        int24 tickSpacing
    ) internal pure returns (bool found, uint8 k) {
        (int24 refLower, int24 refUpper) = referenceRange(v.sO, tickSpacing);
        uint8 e;
        (found, e) = firstWorthOneDollar(v, refLower, refUpper, LPPriceMath.MIN_VAULT_DECIMALS, MAX_REFERENCE_EXP);
        // e <= MAX_REFERENCE_EXP = 34, so k = e + 2 - 18 <= MAX_UNIT_EXP = 18.
        if (found && e + UNIT_EXP_HEADROOM > LPPriceMath.MAX_VAULT_DECIMALS) {
            k = e + UNIT_EXP_HEADROOM - LPPriceMath.MAX_VAULT_DECIMALS;
        }
    }

    /// @notice The market's decimals: the smallest `d` in `[6, 18]` whose whole token, `10^(d + k)` liquidity on
    /// `[tickLower, tickUpper]`, is worth at least $1 at the listing prices.
    /// @return found False when no `d` passes (the binding is refused).
    /// @return d The vault token's decimals.
    function unitDecimals(
        Valuation memory v,
        int24 tickLower,
        int24 tickUpper,
        uint8 k
    ) internal pure returns (bool found, uint8 d) {
        uint8 e;
        (found, e) = firstWorthOneDollar(
            v, tickLower, tickUpper, LPPriceMath.MIN_VAULT_DECIMALS + k, LPPriceMath.MAX_VAULT_DECIMALS + k
        );
        if (found) d = e - k;
    }

    /// @notice The smallest `e` in `[from, to]` whose `10^e` liquidity on `[tickLower, tickUpper]` at the listing price
    /// clamped to the range is worth at least $1 at the listing prices (`LPPriceMath.lpPrice`, one raw unit off each
    /// token); `found` false when none is.
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
            (bool valid, uint256 price8) = LPPriceMath.lpPrice(a, v.prices, v.decs);
            if (valid && price8 >= LPPriceMath.PRICE_UNIT) return (true, e);
        }
        return (false, 0);
    }

    /// @notice The pool's reference range: the one tick spacing `[t, t + s]` holding the tick of the listing price.
    /// @dev It always lies inside the usable ticks: listing prices lie in `[1, MAX_ROUTE_ANSWER = 10^18]` and token
    /// decimals in `[0, 18]`, so the raw price ratio lies in `[10^-36, 10^36]` and `|t| <= 828,973`, so the range
    /// reaches at most `828,973 + 6,931 = 835,904`, while the usable ticks reach at least `±880,237` for every spacing
    /// up to Slipstream's largest, 6,931.
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
}
