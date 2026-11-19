// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClTickMath} from "../../src/amm/concentrated-liquidity/ClTickMath.sol";
import {FloorCreditMath} from "../../src/custody/lp-vault/libraries/FloorCreditMath.sol";
import {Test} from "forge-std/Test.sol";

/// @title FloorCreditMathHalmosTest
/// @notice Bounded symbolic checks of the floor credit (docs/spec/04-security/05-floor-credit-proof.md), split into
/// lemmas small enough for the solver. With `x, y` the position's and `X, Y` the band's square-root prices, `Δ = y − x`,
/// `D = Y − X`, `r1 = Δ/D`, `r0 = Δ·X·Y/(D·x·y)` and `m = min(r0, r1)`:
///
/// 1. `check_creditMatchesReference`: the library returns `ref(L) = min(t, ⌊⌊t·Y/y⌋·X/x⌋)`, `t = ⌊L·Δ/D⌋`.
/// 2. `check_referenceAtMostToken1Ratio`, `check_referenceAtMostToken0Ratio`: `ref(L) ≤ L·r1` and `ref(L) ≤ L·r0`,
///    i.e. the position covers its credit at the upper and the lower band edge (the value ratio there is `r1`, `r0`).
/// 3. `check_referenceMonotoneInLiquidity`: `ref` is non-decreasing in `L`.
/// 4. `check_ratioCovers{BelowPosition,InsidePosition,AbovePosition}`: for every price `s` in the band,
///    `m·V_band(s) ≤ V_position(s)`, in the three price regimes of the position. With 1 and 2 (`credit ≤ L·m`) this
///    gives `credit·V_band(s) ≤ L·V_position(s)` at every price in the band. Outside the band the ratio is constant
///    (`r0` below, `r1` above), which 2 covers.
/// @dev Bounds: five fixed bands and positions near `MIN_TICK`, their ticks converted with `ClTickMath` (concrete
/// values below `2^34`), and liquidity below `2^64`; the fuzz suite (`test/fuzz/FloorCreditMath.fuzz.t.sol`) covers
/// the whole domain. Every product below then fits 256 bits, so the checks use plain arithmetic. Lemma 1 assumes
/// `mulmod(a, b, 2^256 − 1) == a·b` for the three products `Math.mulDiv` forms; each is below `2^128`, so the
/// assumption removes no input and only rules out `mulDiv`'s 512-bit branch.
contract FloorCreditMathHalmosTest is Test {
    uint256 internal constant MAX_LIQUIDITY = 2 ** 64;
    uint256 internal constant SHAPES = 5;

    /// @dev Square-root prices of one position `[x, y]` inside one band `[X, Y]`.
    struct Shape {
        uint256 x;
        uint256 y;
        uint256 bx;
        uint256 by;
    }

    /// @dev Shape `k`: a narrow position in the middle of a wide band, one at each band edge, the whole band, and a
    /// narrow position in a narrow (stable-like) band. All ticks lie in `[MIN_TICK, −870_000]`.
    function _shape(
        uint256 k
    ) internal pure returns (Shape memory s) {
        vm.assume(k < SHAPES);
        int24 a;
        int24 b;
        int24 ba = -880_000;
        int24 bb = -870_000;
        if (k == 0) (a, b) = (-876_000, -874_000);
        else if (k == 1) (a, b) = (-880_000, -879_000);
        else if (k == 2) (a, b) = (-871_000, -870_000);
        else if (k == 3) (a, b) = (ba, bb);
        else (a, b, ba, bb) = (-878_960, -878_940, -879_000, -878_900);
        s.x = ClTickMath.getSqrtPriceAtTick(a);
        s.y = ClTickMath.getSqrtPriceAtTick(b);
        s.bx = ClTickMath.getSqrtPriceAtTick(ba);
        s.by = ClTickMath.getSqrtPriceAtTick(bb);
    }

    /// @dev `ref(L)`, the credit in plain arithmetic, with its intermediate terms.
    function _reference(
        Shape memory s,
        uint256 liquidity
    ) internal pure returns (uint256 ref, uint256 t, uint256 u) {
        t = liquidity * (s.y - s.x) / (s.by - s.bx);
        u = t * s.by / s.y;
        uint256 token0 = u * s.bx / s.x;
        ref = token0 < t ? token0 : t;
    }

    /// @dev See the contract's `@dev`: states that the high word of `a·b` is 0, as `Math.mulDiv` tests it.
    function _assumeExactProduct(
        uint256 a,
        uint256 b
    ) internal pure {
        unchecked {
            vm.assume(mulmod(a, b, type(uint256).max) == a * b);
            vm.assume(mulmod(a, b, type(uint256).max) == b * a);
        }
    }

    // ---------------------------------------------------------------- lemma 1

    /// @notice The library's credit equals the plain-arithmetic reference on the same terms.
    function check_creditMatchesReference(
        uint256 k,
        uint128 liquidity
    ) public pure {
        Shape memory s = _shape(k);
        vm.assume(liquidity < MAX_LIQUIDITY);
        (uint256 ref, uint256 t, uint256 u) = _reference(s, liquidity);
        _assumeExactProduct(liquidity, s.y - s.x);
        _assumeExactProduct(t, s.by);
        _assumeExactProduct(u, s.bx);
        uint256 credit =
            FloorCreditMath.creditAtSqrtPrices(uint160(s.x), uint160(s.y), uint160(s.bx), uint160(s.by), liquidity);
        assert(credit == ref);
    }

    // ---------------------------------------------------------------- lemma 2

    /// @notice `ref(L) ≤ L·r1`: at the upper band edge (token1 only) the position covers its credit.
    function check_referenceAtMostToken1Ratio(
        uint256 k,
        uint256 liquidity
    ) public pure {
        Shape memory s = _shape(k);
        vm.assume(liquidity < MAX_LIQUIDITY);
        (uint256 ref,,) = _reference(s, liquidity);
        assert(ref * (s.by - s.bx) <= liquidity * (s.y - s.x));
    }

    /// @notice `ref(L) ≤ L·r0`: at the lower band edge (token0 only) the position covers its credit.
    function check_referenceAtMostToken0Ratio(
        uint256 k,
        uint256 liquidity
    ) public pure {
        Shape memory s = _shape(k);
        vm.assume(liquidity < MAX_LIQUIDITY);
        (uint256 ref,,) = _reference(s, liquidity);
        assert(ref * (s.by - s.bx) * s.x * s.y <= liquidity * (s.y - s.x) * s.bx * s.by);
    }

    // ---------------------------------------------------------------- lemma 3

    /// @notice More liquidity never earns less credit.
    function check_referenceMonotoneInLiquidity(
        uint256 k,
        uint256 liquidity,
        uint256 more
    ) public pure {
        Shape memory s = _shape(k);
        vm.assume(liquidity <= more && more < MAX_LIQUIDITY);
        (uint256 lo,,) = _reference(s, liquidity);
        (uint256 hi,,) = _reference(s, more);
        assert(lo <= hi);
    }

    // ---------------------------------------------------------------- lemma 4

    /// @dev `m = p/q`: `r1 = Δ/D` when `x·y ≤ X·Y` (then `r1 ≤ r0`), else `r0 = Δ·X·Y/(D·x·y)`.
    function _ratio(
        Shape memory s
    ) internal pure returns (uint256 p, uint256 q) {
        if (s.x * s.y <= s.bx * s.by) return (s.y - s.x, s.by - s.bx);
        return ((s.y - s.x) * s.bx * s.by, (s.by - s.bx) * s.x * s.y);
    }

    /// @dev `p·V_band(s) ≤ q·V_position(s)` for `s` in the band, the position's value given as `num/den`; the band is
    /// in range, `V_band(s) = (2·s·Y − X·Y − s²)/Y`.
    function _ratioCovers(
        Shape memory s,
        uint256 price,
        uint256 num,
        uint256 den
    ) internal pure {
        (uint256 p, uint256 q) = _ratio(s);
        uint256 bandNum = 2 * price * s.by - s.bx * s.by - price * price;
        assert(p * bandNum * den <= q * num * s.by);
    }

    /// @notice `X ≤ s ≤ x`: the position holds only token0, `V_position(s) = s²·Δ/(x·y)`.
    function check_ratioCoversBelowPosition(
        uint256 k,
        uint256 price
    ) public pure {
        Shape memory s = _shape(k);
        vm.assume(s.bx <= price && price <= s.x);
        _ratioCovers(s, price, price * price * (s.y - s.x), s.x * s.y);
    }

    /// @notice `x < s < y`: the position is in range, `V_position(s) = (2·s·y − x·y − s²)/y`.
    function check_ratioCoversInsidePosition(
        uint256 k,
        uint256 price
    ) public pure {
        Shape memory s = _shape(k);
        vm.assume(s.x < price && price < s.y);
        _ratioCovers(s, price, 2 * price * s.y - s.x * s.y - price * price, s.y);
    }

    /// @notice `y ≤ s ≤ Y`: the position holds only token1, `V_position(s) = Δ`.
    function check_ratioCoversAbovePosition(
        uint256 k,
        uint256 price
    ) public pure {
        Shape memory s = _shape(k);
        vm.assume(s.y <= price && price <= s.by);
        _ratioCovers(s, price, s.y - s.x, 1);
    }
}
