// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Copyright 2023 Universal Navigation Inc. (Uniswap Labs): Uniswap v4-core src/libraries/TickMath.sol, tag v4.0.0
// (commit e50237c43811bd9b526eff40f26772152a42daba), licensed MIT (v4-core licenses/MIT_LICENSE).
// Modifications Copyright (c) 2026 Avana Labs, licensed MIT as well: the inline-assembly steps are written as plain
// Solidity with the same results, BitMath.mostSignificantBit is OpenZeppelin Math.log2, the fourteen logarithm steps
// are one loop, the errors take Avana's names, and the tick-spacing helpers are left out.
// The MIT licence text and this notice are reproduced in THIRD_PARTY_LICENSES.md and NOTICE.

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ClTickMath
/// @notice Square-root prices of ticks of size 1.0001 and back: `sqrt(1.0001^tick)` as Q64.96 fixed point, for prices
/// between `2^-128` and `2^128`. Uniswap v4-core `TickMath` (MIT), with the same constants and results.
/// @dev Internal pure functions only. `ClPriceMath` wraps them for Avana's concentrated-liquidity code.
/// @custom:spec SPEC-ORC-006, SPEC-ORC-010, SPEC-AMM-V3-001
library ClTickMath {
    /// @notice A tick outside `[MIN_TICK, MAX_TICK]` (v4-core `InvalidTick`).
    error TickOutOfRange(int24 tick);
    /// @notice A square-root price outside `[MIN_SQRT_PRICE, MAX_SQRT_PRICE)` (v4-core `InvalidSqrtPrice`).
    error SqrtRatioOutOfRange(uint160 sqrtPriceX96);

    /// @dev The minimum tick that may be passed to `getSqrtPriceAtTick`, computed from log base 1.0001 of 2^-128.
    /// If MIN_TICK and MAX_TICK were ever not centred on 0, the absolute-tick step of `getSqrtPriceAtTick` would not
    /// hold.
    int24 internal constant MIN_TICK = -887_272;
    /// @dev The maximum tick that may be passed to `getSqrtPriceAtTick`, computed from log base 1.0001 of 2^128.
    int24 internal constant MAX_TICK = 887_272;

    /// @dev The minimum value `getSqrtPriceAtTick` can return: `getSqrtPriceAtTick(MIN_TICK)`.
    uint160 internal constant MIN_SQRT_PRICE = 4_295_128_739;
    /// @dev The maximum value `getSqrtPriceAtTick` can return: `getSqrtPriceAtTick(MAX_TICK)`.
    uint160 internal constant MAX_SQRT_PRICE = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;
    /// @dev A threshold for the one-comparison bounds check, `MAX_SQRT_PRICE - MIN_SQRT_PRICE - 1`.
    uint160 internal constant MAX_SQRT_PRICE_MINUS_MIN_SQRT_PRICE_MINUS_ONE =
        1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342 - 4_295_128_739 - 1;

    /// @notice Calculates `sqrt(1.0001^tick) * 2^96`.
    /// @dev Reverts `TickOutOfRange` if `|tick| > MAX_TICK`.
    /// @param tick The input tick for the above formula.
    /// @return sqrtPriceX96 A Q64.96 fixed-point number, the square root of the price of the two assets
    /// (currency1/currency0) at the given tick.
    /// @custom:spec SPEC-ORC-006, SPEC-AMM-V3-001
    // One branch per bit of |tick| over v4-core's constant table, kept as written so it can be compared line by line.
    // forge-lint: disable-next-line(cyclomatic-complexity)
    function getSqrtPriceAtTick(
        int24 tick
    ) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            // |tick| of an int24 fits in uint256 without overflow.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            // MAX_TICK is a positive constant.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (absTick > uint256(int256(MAX_TICK))) revert TickOutOfRange(tick);

            // The tick is decomposed into bits, and for each bit with index i that is set, the product of
            // 1/sqrt(1.0001^(2^i)) is calculated (using Q128.128). The constants used for this calculation are rounded
            // to the nearest integer.
            uint256 price = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 1 << 128;
            if (absTick & 0x2 != 0) price = (price * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) price = (price * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) price = (price * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) price = (price * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) price = (price * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) price = (price * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) price = (price * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) price = (price * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) price = (price * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) price = (price * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) price = (price * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) price = (price * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) price = (price * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) price = (price * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) price = (price * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) price = (price * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) price = (price * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) price = (price * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) price = (price * 0x48a170391f7dc42444e8fa2) >> 128;

            if (tick > 0) price = type(uint256).max / price;

            // This divides by 1 << 32 rounding up to go from a Q128.128 to a Q128.96, then downcasts: the result always
            // fits within 160 bits for a tick in range. Rounding up keeps getTickAtSqrtPrice of the output consistent.
            // `price + type(uint32).max` does not overflow because `price` fits in 192 bits.
            // forge-lint: disable-next-line(unsafe-typecast)
            sqrtPriceX96 = uint160((price + type(uint32).max) >> 32);
        }
    }

    /// @notice Calculates the greatest tick value such that `getSqrtPriceAtTick(tick) <= sqrtPriceX96`.
    /// @dev Reverts `SqrtRatioOutOfRange` if `sqrtPriceX96 < MIN_SQRT_PRICE` or `sqrtPriceX96 >= MAX_SQRT_PRICE`.
    /// @param sqrtPriceX96 The square-root price for which to compute the tick, as a Q64.96.
    /// @return tick The greatest tick for which `getSqrtPriceAtTick(tick)` is at most `sqrtPriceX96`.
    /// @custom:spec SPEC-ORC-010
    function getTickAtSqrtPrice(
        uint160 sqrtPriceX96
    ) internal pure returns (int24 tick) {
        unchecked {
            // Equivalent to `sqrtPriceX96 < MIN_SQRT_PRICE || sqrtPriceX96 >= MAX_SQRT_PRICE`: below MIN_SQRT_PRICE
            // the uint160 subtraction wraps above the threshold. The upper test is >= because the price can never
            // reach the price at the max tick.
            if ((sqrtPriceX96 - MIN_SQRT_PRICE) > MAX_SQRT_PRICE_MINUS_MIN_SQRT_PRICE_MINUS_ONE) {
                revert SqrtRatioOutOfRange(sqrtPriceX96);
            }

            uint256 price = uint256(sqrtPriceX96) << 32;

            uint256 r = price;
            uint256 msb = Math.log2(r);

            if (msb >= 128) r = price >> (msb - 127);
            else r = price << (127 - msb);

            // msb < 192.
            // forge-lint: disable-next-line(unsafe-typecast)
            int256 log2X64 = (int256(msb) - 128) << 64;

            // Fourteen squaring steps give the fractional bits 63 down to 50 of the binary logarithm.
            for (uint256 bit = 63; bit >= 50; --bit) {
                r = (r * r) >> 127;
                uint256 f = r >> 128;
                // f is 0 or 1, so the shifted value is below 2^64.
                // forge-lint: disable-next-line(unsafe-typecast)
                log2X64 |= int256(f << bit);
                r >>= f;
            }

            int256 logSqrt10001 = log2X64 * 255_738_958_999_603_826_347_141; // Q22.128 number

            // The magic number is the ceiling of the maximum error when approximating log_sqrt10001(x).
            // forge-lint: disable-next-line(unsafe-typecast)
            int24 tickLow = int24((logSqrt10001 - 3_402_992_956_809_132_418_596_140_100_660_247_210) >> 128);

            // The magic number is the minimum error when approximating log_sqrt10001(x) for a square-root price in
            // (2^-64, 2^64). This holds because MIN_SQRT_PRICE is above 2^-64; a different MIN_SQRT_PRICE may need a
            // different number.
            // forge-lint: disable-next-line(unsafe-typecast)
            int24 tickHi = int24((logSqrt10001 + 291_339_464_771_989_622_907_027_621_153_398_088_495) >> 128);

            tick = tickLow == tickHi ? tickLow : getSqrtPriceAtTick(tickHi) <= sqrtPriceX96 ? tickHi : tickLow;
        }
    }
}
