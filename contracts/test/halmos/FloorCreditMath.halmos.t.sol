// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClTickMath} from "../../src/amm/concentrated-liquidity/ClTickMath.sol";
import {FloorCreditMath} from "../../src/custody/lp-vault/libraries/FloorCreditMath.sol";
import {Test} from "forge-std/Test.sol";

/// @title FloorCreditMathHalmosTest
/// @notice Bounded symbolic checks of the floor-credit formula (docs/spec/04-security/05-floor-credit-proof.md): a
/// position inside its band is worth at least its credit in band liquidity at both band edges and at every price in
/// the band, and the credit is non-decreasing in liquidity.
/// @dev Bounds: square-root prices in `[MIN_SQRT_PRICE, MIN_SQRT_PRICE + 2^16)` and liquidity below `2^32`, so every
/// cross-multiplied value below fits 256 bits and the library's `mulDiv` stays on its single-word path. The proof and
/// the fuzz suite (`test/fuzz/FloorCreditMath.fuzz.t.sol`) cover the whole domain; these checks cover every input in
/// the bounded one. Values are exact rationals of the square-root prices, compared by cross-multiplication.
contract FloorCreditMathHalmosTest is Test {
    uint256 internal constant WINDOW = 2 ** 16;
    uint256 internal constant MAX_LIQUIDITY = 2 ** 32;

    /// @dev Constrains `MIN ≤ sx ≤ x < y ≤ sy < MIN + WINDOW` and `L < MAX_LIQUIDITY`, and returns the credit.
    function _credit(
        uint160 x,
        uint160 y,
        uint160 sx,
        uint160 sy,
        uint128 liquidity
    ) internal pure returns (uint256) {
        uint256 lo = ClTickMath.MIN_SQRT_PRICE;
        vm.assume(sx >= lo && sy < lo + WINDOW);
        vm.assume(sx <= x && x < y && y <= sy);
        vm.assume(liquidity < MAX_LIQUIDITY);
        return FloorCreditMath.creditAtSqrtPrices(x, y, sx, sy, liquidity);
    }

    /// @dev Value in token1 of one unit of liquidity on `[lo, hi]` at `s`, as `num / den` (see the proof's table).
    function _unitValue(
        uint256 lo,
        uint256 hi,
        uint256 s
    ) internal pure returns (uint256 num, uint256 den) {
        if (s <= lo) return (s * s * (hi - lo), lo * hi);
        if (s >= hi) return (hi - lo, 1);
        return ((s - lo) * hi + s * (hi - s), hi);
    }

    /// @notice At the lower band edge (only token0 held by both) and the upper edge (only token1), the position is
    /// worth at least its credit: `C·(sy − sx)·x·y ≤ L·(y − x)·sx·sy` and `C·(sy − sx) ≤ L·(y − x)`.
    function check_valueCoversCreditAtBandEdges(
        uint160 x,
        uint160 y,
        uint160 sx,
        uint160 sy,
        uint128 liquidity
    ) public pure {
        uint256 c = _credit(x, y, sx, sy, liquidity);
        uint256 band = uint256(sy) - sx;
        uint256 pos = uint256(y) - x;
        assert(c * band * x * y <= uint256(liquidity) * pos * sx * sy);
        assert(c * band <= uint256(liquidity) * pos);
    }

    /// @notice At every price `s` in the band, `C·V_band(s) ≤ L·V_position(s)`.
    function check_valueCoversCreditInsideBand(
        uint160 x,
        uint160 y,
        uint160 sx,
        uint160 sy,
        uint128 liquidity,
        uint160 s
    ) public pure {
        uint256 c = _credit(x, y, sx, sy, liquidity);
        vm.assume(sx <= s && s <= sy);
        (uint256 pn, uint256 pd) = _unitValue(x, y, s);
        (uint256 bn, uint256 bd) = _unitValue(sx, sy, s);
        assert(c * bn * pd <= uint256(liquidity) * pn * bd);
    }

    /// @notice More liquidity on the same prices never earns less credit.
    function check_creditMonotoneInLiquidity(
        uint160 x,
        uint160 y,
        uint160 sx,
        uint160 sy,
        uint128 liquidity,
        uint128 more
    ) public pure {
        uint256 c = _credit(x, y, sx, sy, liquidity);
        vm.assume(liquidity <= more && more < MAX_LIQUIDITY);
        assert(c <= FloorCreditMath.creditAtSqrtPrices(x, y, sx, sy, more));
    }
}
