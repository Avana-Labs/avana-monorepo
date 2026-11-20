// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClTickMath} from "../../integrations/shared/ClTickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @title LPPriceMath
/// @notice Pure arithmetic of the band-unit price: Chainlink answers to 8 decimals, the fair square-root price of two
/// USD prices, and the value of band liquidity at that price.
/// @dev Pool-neutral: ticks, prices and decimals in, numbers out. Every step rounds down, so the value never exceeds
/// what the liquidity holds. The amounts are Uniswap v4-core `SqrtPriceMath`'s, the same the LPVault credits with.
library LPPriceMath {
    /// @notice Decimals of every price here and of the answer.
    uint8 internal constant DECIMALS = 8;
    uint256 internal constant PRICE_UNIT = 1e8;
    /// @notice A USD stablecoin is valued at most $1.
    uint256 internal constant STABLE_CEILING = 1e8;
    /// @notice Largest token price served ($10^10): small enough that no product below overflows.
    uint256 internal constant MAX_PRICE = 1e18;
    /// @notice Largest token or feed decimals accepted.
    uint8 internal constant MAX_DECIMALS = 18;
    /// @notice Exclusive bound of a raw Chainlink answer.
    uint256 internal constant ANSWER_BOUND = 2 ** 128;

    uint256 internal constant Q128 = 2 ** 128;
    uint256 internal constant Q192 = 2 ** 192;

    /// @notice 8-decimal value of a Chainlink answer with `feedDecimals` decimals, rounded down.
    /// @dev 0, which the caller treats as a failed feed, for `answer <= 0` or `answer >= 2^128`. `feedDecimals` is at
    /// most `MAX_DECIMALS` (checked at construction).
    function normalize(
        int256 answer,
        uint8 feedDecimals
    ) internal pure returns (uint256) {
        if (answer <= 0) return 0;
        // answer > 0, so the conversion is exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 a = uint256(answer);
        if (a >= ANSWER_BOUND) return 0;
        if (feedDecimals <= DECIMALS) return a * 10 ** (DECIMALS - feedDecimals);
        return a / 10 ** (feedDecimals - DECIMALS);
    }

    /// @notice Q64.96 square root of the fair raw token1-per-token0 price `(p0 / 10^d0) / (p1 / 10^d1)`, rounded
    /// down and kept inside `[MIN_SQRT_PRICE, MAX_SQRT_PRICE)`.
    /// @dev Requires `0 < p0, p1 <= MAX_PRICE` and `d0, d1 <= MAX_DECIMALS`.
    function sqrtPriceX96(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) internal pure returns (uint160) {
        (uint256 raw, bool high) = rawSqrtPrice(p0, p1, d0, d1);
        if (high) return ClTickMath.MAX_SQRT_PRICE - 1;
        if (raw < ClTickMath.MIN_SQRT_PRICE) return ClTickMath.MIN_SQRT_PRICE;
        // Not high, so raw < MAX_SQRT_PRICE < 2^160.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(raw);
    }

    /// @notice The unbounded square root of `sqrtPriceX96`, and whether it reaches `MAX_SQRT_PRICE`.
    /// @dev Three branches by `num / den` so no `mulDiv` result exceeds 2^256; requires `den < 2^188`, so `den << 64`
    /// fits (here `num, den <= 10^36 < 2^120`).
    function rawSqrtPrice(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) internal pure returns (uint256 raw, bool high) {
        uint256 num = p0 * 10 ** d1;
        uint256 den = p1 * 10 ** d0;
        if (num < den << 64) return (Math.sqrt(Math.mulDiv(num, Q192, den)), false);
        if (num >> 128 >= den) return (0, true);
        raw = Math.sqrt(Math.mulDiv(num, Q128, den)) << 32;
        high = raw >= ClTickMath.MAX_SQRT_PRICE;
    }

    /// @notice Raw token amounts `units` of liquidity on `[sqrtLower, sqrtUpper]` hold at the square-root price `s`,
    /// with `s` clamped to the band first, each rounded down.
    /// @dev Below the band the liquidity is all token0, above it all token1, as in the AMM. Requires
    /// `0 < sqrtLower < sqrtUpper`.
    function amounts(
        uint160 s,
        uint160 sqrtLower,
        uint160 sqrtUpper,
        uint128 units
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (s < sqrtLower) s = sqrtLower;
        else if (s > sqrtUpper) s = sqrtUpper;
        amount0 = SqrtPriceMath.getAmount0Delta(s, sqrtUpper, units, false);
        amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, s, units, false);
    }

    /// @notice 8-decimal USD value of raw amounts at 8-decimal prices, each term rounded down.
    /// @dev Amounts below 2^192 and prices at most `MAX_PRICE` keep each product inside `mulDiv`'s 512 bits.
    function value(
        uint256 amount0,
        uint256 amount1,
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) internal pure returns (uint256) {
        return Math.mulDiv(amount0, p0, 10 ** d0) + Math.mulDiv(amount1, p1, 10 ** d1);
    }
}
