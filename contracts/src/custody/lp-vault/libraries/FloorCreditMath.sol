// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClTickMath} from "../../../amm/concentrated-liquidity/ClTickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FloorCreditMath
/// @notice Floor credit of a concentrated-liquidity position pledged to a band market. The credit unit is one unit of
/// liquidity spread over the whole band `[A, B]`; a position of liquidity `L` on `[a, b]`, fully inside the band, is
/// credited
///
///     credit = L · min( (1/√a − 1/√b) / (1/√A − 1/√B), (√b − √a) / (√B − √A) )
///
/// band units, where every `√x` is the Q64.96 square-root price `getSqrtPriceAtTick(x)`. The credit is fixed at pledge
/// and reads no pool price. At every pool price the position is worth at least `credit` units of band liquidity, and
/// the least ratio of the two values is reached at a band edge (docs/spec/04-security/05-floor-credit-proof.md).
/// @dev Pure and pool-neutral. Every division rounds down, so the credit never exceeds the exact formula. The formula
/// over-credits a position that leaves the band, so both entry points revert unless `A ≤ a < b ≤ B`.
library FloorCreditMath {
    /// @notice The position `[tickLower, tickUpper]` is empty, inverted or not fully inside the band
    /// `[bandLower, bandUpper]`.
    error NotInsideBand(int24 tickLower, int24 tickUpper, int24 bandLower, int24 bandUpper);
    /// @notice The square-root prices are not ordered `MIN_SQRT_PRICE ≤ sqrtBandLower ≤ sqrtLower < sqrtUpper ≤
    /// sqrtBandUpper ≤ MAX_SQRT_PRICE`.
    error SqrtPricesNotInsideBand(uint160 sqrtLower, uint160 sqrtUpper, uint160 sqrtBandLower, uint160 sqrtBandUpper);

    /// @notice Floor credit, in band-liquidity units, of liquidity `liquidity` on the ticks `[tickLower, tickUpper]`
    /// pledged to the band `[bandLower, bandUpper]`.
    /// @dev Reverts `NotInsideBand` unless `bandLower ≤ tickLower < tickUpper ≤ bandUpper`, and `TickOutOfRange` (from
    /// `ClTickMath`) for a tick outside `[MIN_TICK, MAX_TICK]`. Rounds down; never above `liquidity`.
    /// @param tickLower Lower tick `a` of the position.
    /// @param tickUpper Upper tick `b` of the position.
    /// @param bandLower Lower tick `A` of the band market.
    /// @param bandUpper Upper tick `B` of the band market.
    /// @param liquidity Liquidity `L` of the position.
    /// @return The credit `floor(L · min(r0, r1))`, computed as in `creditAtSqrtPrices`.
    function credit(
        int24 tickLower,
        int24 tickUpper,
        int24 bandLower,
        int24 bandUpper,
        uint128 liquidity
    ) internal pure returns (uint128) {
        // getSqrtPriceAtTick is strictly increasing, so this is the order test of creditAtSqrtPrices, on ticks.
        if (bandLower > tickLower || tickLower >= tickUpper || tickUpper > bandUpper) {
            revert NotInsideBand(tickLower, tickUpper, bandLower, bandUpper);
        }
        return creditAtSqrtPrices(
            ClTickMath.getSqrtPriceAtTick(tickLower),
            ClTickMath.getSqrtPriceAtTick(tickUpper),
            ClTickMath.getSqrtPriceAtTick(bandLower),
            ClTickMath.getSqrtPriceAtTick(bandUpper),
            liquidity
        );
    }

    /// @notice Floor credit from the Q64.96 square-root prices `sa = √a`, `sb = √b` of the position and `sA = √A`,
    /// `sB = √B` of the band.
    /// @dev Reverts `SqrtPricesNotInsideBand` unless `MIN_SQRT_PRICE ≤ sA ≤ sa < sb ≤ sB ≤ MAX_SQRT_PRICE`.
    /// With `Δ = sb − sa` and `D = sB − sA`:
    ///
    ///     r1 = Δ / D                                    token1 side: (√b − √a) / (√B − √A)
    ///     r0 = (Δ / (sa·sb)) / (D / (sA·sB))            token0 side: (1/√a − 1/√b) / (1/√A − 1/√B)
    ///        = r1 · (sB / sb) · (sA / sa)
    ///
    /// so `credit = min(t, floor(floor(t·sB/sb)·sA/sa))` with `t = floor(L·Δ/D)`. Each floor only lowers a value, so
    /// the result is at most the exact `L · min(r0, r1)`, and each step is non-decreasing in `L`. The Q96 scale cancels
    /// in both ratios. No step overflows: `t ≤ L < 2^128` (`Δ ≤ D`) and `sB/sb ≤ MAX_SQRT_PRICE/MIN_SQRT_PRICE < 2^128`.
    /// @param sqrtLower `sa`, Q64.96 square-root price of the position's lower tick.
    /// @param sqrtUpper `sb`, Q64.96 square-root price of the position's upper tick.
    /// @param sqrtBandLower `sA`, Q64.96 square-root price of the band's lower tick.
    /// @param sqrtBandUpper `sB`, Q64.96 square-root price of the band's upper tick.
    /// @param liquidity Liquidity `L` of the position.
    /// @return The credit, at most `liquidity`.
    function creditAtSqrtPrices(
        uint160 sqrtLower,
        uint160 sqrtUpper,
        uint160 sqrtBandLower,
        uint160 sqrtBandUpper,
        uint128 liquidity
    ) internal pure returns (uint128) {
        if (
            sqrtBandLower < ClTickMath.MIN_SQRT_PRICE || sqrtBandLower > sqrtLower || sqrtLower >= sqrtUpper
                || sqrtUpper > sqrtBandUpper || sqrtBandUpper > ClTickMath.MAX_SQRT_PRICE
        ) {
            revert SqrtPricesNotInsideBand(sqrtLower, sqrtUpper, sqrtBandLower, sqrtBandUpper);
        }
        // Token1 side, L·(√b − √a)/(√B − √A); at most L since the position is inside the band.
        uint256 t = Math.mulDiv(liquidity, sqrtUpper - sqrtLower, sqrtBandUpper - sqrtBandLower);
        // Token0 side, t·(√B/√b)·(√A/√a): the factor ≥ 1 first, so the second floor loses the least.
        uint256 token0Side = Math.mulDiv(Math.mulDiv(t, sqrtBandUpper, sqrtUpper), sqrtBandLower, sqrtLower);
        // The min is at most t ≤ L < 2^128.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(token0Side < t ? token0Side : t);
    }
}
