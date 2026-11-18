// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPPriceMath} from "../../oracle/lp-oracle/LPPriceMath.sol";
import {ClPriceMath} from "./ClPriceMath.sol";

/// @title ClUnitMath
/// @notice Vault-token unit of a CL market: pool exponent `k` (one unit = `10^k` liquidity) and market decimals `d`.
library ClUnitMath {
    /// @notice Largest unit exponent `k`, so a whole vault token's liquidity fits `uint128`.
    uint8 internal constant MAX_UNIT_EXP = 18;
    /// @notice Decades of headroom the pool's unit exponent leaves below its reference range.
    uint8 internal constant UNIT_EXP_HEADROOM = 2;
    /// @notice Largest reference exponent searched, so `k <= MAX_UNIT_EXP`.
    uint8 internal constant MAX_REFERENCE_EXP = LPPriceMath.MAX_VAULT_DECIMALS + MAX_UNIT_EXP - UNIT_EXP_HEADROOM;

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
        (found, e) = firstWorthOneDollar(v, refLower, refUpper, LPPriceMath.MIN_VAULT_DECIMALS, MAX_REFERENCE_EXP);
        // e <= MAX_REFERENCE_EXP = 34, so k = e + 2 - 18 <= MAX_UNIT_EXP = 18.
        if (found && e + UNIT_EXP_HEADROOM > LPPriceMath.MAX_VAULT_DECIMALS) {
            k = e + UNIT_EXP_HEADROOM - LPPriceMath.MAX_VAULT_DECIMALS;
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
            v, tickLower, tickUpper, LPPriceMath.MIN_VAULT_DECIMALS + k, LPPriceMath.MAX_VAULT_DECIMALS + k
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
            (bool valid, uint256 price8) = LPPriceMath.lpPrice(a, v.prices, v.decs);
            if (valid && price8 >= LPPriceMath.PRICE_UNIT) return (true, e);
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
}
