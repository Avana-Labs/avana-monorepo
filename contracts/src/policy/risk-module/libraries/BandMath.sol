// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClTickMath} from "../../../amm/concentrated-liquidity/ClTickMath.sol";
import {LPPriceMath} from "../../../oracle/LPPriceMath.sol";
import {IRiskModule} from "../IRiskModule.sol";

/// @title BandMath
/// @notice The two bands of a pool listing and the decimals of their vault tokens.
/// @dev Pure: ticks, widths, prices and decimals in, ticks and decimals out.
library BandMath {
    /// @notice Fewest tick spacings a Custom range band spans.
    int24 internal constant MIN_BAND_SPACINGS = 4;
    /// @notice A whole vault token is worth at least this at listing: $1 in 8 decimals.
    uint256 internal constant MIN_UNIT_VALUE = 1e8;
    uint8 internal constant MIN_UNIT_DECIMALS = 6;
    uint8 internal constant MAX_UNIT_DECIMALS = 18;

    /// @notice The pool's usable tick range: the extreme ticks rounded toward zero to the spacing.
    function fullRange(
        int24 spacing
    ) internal pure returns (int24 lower, int24 upper) {
        lower = (ClTickMath.MIN_TICK / spacing) * spacing;
        upper = (ClTickMath.MAX_TICK / spacing) * spacing;
    }

    /// @notice The Custom range band: `width` around `listingTick`, rounded outward to the spacing.
    /// @dev Reverts `BandNotNarrowerThanFullRange` when it leaves or equals the usable range, and `BandTooNarrow`
    /// when it spans fewer than `MIN_BAND_SPACINGS` spacings.
    function customRange(
        int24 listingTick,
        IRiskModule.Width memory width,
        int24 spacing
    ) internal pure returns (int24 lower, int24 upper) {
        int256 s = spacing;
        int256 lo = _floorTo(int256(listingTick) - int256(uint256(width.below)), s);
        int256 hi = _ceilTo(int256(listingTick) + int256(uint256(width.above)), s);
        (int24 minUsable, int24 maxUsable) = fullRange(spacing);
        if (lo < minUsable || hi > maxUsable || (lo == minUsable && hi == maxUsable)) {
            revert IRiskModule.BandNotNarrowerThanFullRange(_clamp(lo), _clamp(hi));
        }
        // Both are inside the usable range, so they fit int24.
        // forge-lint: disable-next-line(unsafe-typecast)
        (lower, upper) = (int24(lo), int24(hi));
        if (hi - lo < s * MIN_BAND_SPACINGS) revert IRiskModule.BandTooNarrow(lower, upper);
    }

    /// @notice The fewest decimals in [6, 18] at which a whole vault token, `10^d` units of liquidity on
    /// `[bandLower, bandUpper]`, is worth at least $1 at the square-root price `s`; 0 when none is.
    /// @param p0 Token0's 8-decimal USD price.
    /// @param p1 Token1's 8-decimal USD price.
    /// @param d0 Token0's decimals.
    /// @param d1 Token1's decimals.
    function unitDecimals(
        uint160 s,
        int24 bandLower,
        int24 bandUpper,
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) internal pure returns (uint8) {
        uint160 sqrtLower = ClTickMath.getSqrtPriceAtTick(bandLower);
        uint160 sqrtUpper = ClTickMath.getSqrtPriceAtTick(bandUpper);
        for (uint8 d = MIN_UNIT_DECIMALS; d <= MAX_UNIT_DECIMALS; ++d) {
            // At most 10^18 < 2^128.
            // forge-lint: disable-next-line(unsafe-typecast)
            (uint256 a0, uint256 a1) = LPPriceMath.amounts(s, sqrtLower, sqrtUpper, uint128(10 ** d));
            if (LPPriceMath.value(a0, a1, p0, p1, d0, d1) >= MIN_UNIT_VALUE) return d;
        }
        return 0;
    }

    function _floorTo(
        int256 x,
        int256 s
    ) private pure returns (int256 q) {
        q = x / s;
        if (x % s != 0 && x < 0) --q;
        q *= s;
    }

    function _ceilTo(
        int256 x,
        int256 s
    ) private pure returns (int256 q) {
        q = x / s;
        if (x % s != 0 && x > 0) ++q;
        q *= s;
    }

    /// @dev For the error only: a tick past the int24 range shows as the range's end.
    function _clamp(
        int256 x
    ) private pure returns (int24) {
        if (x < type(int24).min) return type(int24).min;
        if (x > type(int24).max) return type(int24).max;
        // In range after the checks above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(x);
    }
}
