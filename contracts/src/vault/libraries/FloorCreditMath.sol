// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClTickMath} from "../../integrations/shared/ClTickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @title FloorCreditMath
/// @notice Floor credit of a concentrated-liquidity position pledged to a band market. The credit unit is one unit of
/// liquidity spread over the whole band `[A, B]`. A position of liquidity `L` on `[a, b]`, fully inside the band, is
/// credited what it holds at each band edge divided by what one band unit holds there, the lesser of the two:
///
///     credit = min( amount0(position) / amount0(band unit),    at √A: both hold only token0
///                   amount1(position) / amount1(band unit) )   at √B: both hold only token1
///
/// with the amounts of Uniswap v4-core `SqrtPriceMath` at the Q64.96 square-root prices `getSqrtPriceAtTick`. This is
/// `L · min((1/√a − 1/√b)/(1/√A − 1/√B), (√b − √a)/(√B − √A))` up to rounding. The credit is fixed at pledge and reads
/// no pool price. At every pool price the position is worth at least `credit` units of band liquidity, and the least
/// ratio of the two values is reached at a band edge (contracts/src/vault/FLOOR-CREDIT-PROOF.md).
/// @dev Pure and pool-neutral: ticks and liquidity in, credit out. Rounds down: the position's amounts round down, the
/// band unit's round up, and so does the division, so the credit never exceeds the exact formula. The formula
/// over-credits a position that leaves the band, so `credit` reverts unless `A ≤ a < b ≤ B`.
library FloorCreditMath {
    /// @dev Band liquidity whose amounts measure one band unit: the largest `uint128`, so the round-up of the band's
    /// amounts costs the credit less than one band unit's worth of the token for any `L < 2^128`.
    uint128 internal constant UNIT_SCALE = type(uint128).max;

    /// @notice The position `[tickLower, tickUpper]` is empty, inverted or not fully inside the band
    /// `[bandLower, bandUpper]`.
    error NotInsideBand(int24 tickLower, int24 tickUpper, int24 bandLower, int24 bandUpper);

    /// @notice Floor credit, in band-liquidity units, of liquidity `liquidity` on the ticks `[tickLower, tickUpper]`
    /// pledged to the band `[bandLower, bandUpper]`.
    /// @dev Reverts `NotInsideBand` unless `bandLower ≤ tickLower < tickUpper ≤ bandUpper`, and `TickOutOfRange` (from
    /// `ClTickMath`) for a tick outside `[MIN_TICK, MAX_TICK]`. No step overflows: each amount is below `2^192`, the
    /// divisions are `mulDiv`, and the result is at most `liquidity`.
    /// @param tickLower Lower tick `a` of the position.
    /// @param tickUpper Upper tick `b` of the position.
    /// @param bandLower Lower tick `A` of the band market.
    /// @param bandUpper Upper tick `B` of the band market.
    /// @param liquidity Liquidity `L` of the position.
    /// @return The credit, at most `floor(L · min(r0, r1))`.
    function credit(
        int24 tickLower,
        int24 tickUpper,
        int24 bandLower,
        int24 bandUpper,
        uint128 liquidity
    ) internal pure returns (uint128) {
        if (bandLower > tickLower || tickLower >= tickUpper || tickUpper > bandUpper) {
            revert NotInsideBand(tickLower, tickUpper, bandLower, bandUpper);
        }
        uint160 sqrtLower = ClTickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = ClTickMath.getSqrtPriceAtTick(tickUpper);
        uint160 sqrtBandLower = ClTickMath.getSqrtPriceAtTick(bandLower);
        uint160 sqrtBandUpper = ClTickMath.getSqrtPriceAtTick(bandUpper);

        uint256 token0Side = Math.mulDiv(
            SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, false),
            UNIT_SCALE,
            SqrtPriceMath.getAmount0Delta(sqrtBandLower, sqrtBandUpper, UNIT_SCALE, true)
        );
        uint256 token1Side = Math.mulDiv(
            SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, false),
            UNIT_SCALE,
            SqrtPriceMath.getAmount1Delta(sqrtBandLower, sqrtBandUpper, UNIT_SCALE, true)
        );
        // Each side is at most L · r ≤ L < 2^128.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(token0Side < token1Side ? token0Side : token1Side);
    }
}
