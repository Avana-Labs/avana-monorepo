// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClTickMath} from "../../src/amm/concentrated-liquidity/ClTickMath.sol";
import {FloorCreditMath} from "../../src/custody/lp-vault/libraries/FloorCreditMath.sol";
import {BigUint} from "../utils/BigUint.sol";
import {FloorCreditMathHarness} from "../utils/harness/FloorCreditMathHarness.sol";
import {Test} from "forge-std/Test.sol";

/// @title FloorCreditMathFuzzTest
/// @notice The floor credit of a position inside a band market (docs/spec/04-security/05-floor-credit-proof.md) over
/// random bands, positions, liquidities and prices: the position is worth at least its credit in band liquidity at
/// every price below, inside and above the band; the credit rounds down and stays within a few units of the exact
/// formula; it is non-decreasing in liquidity; a near-full-range band credits almost nothing; positions outside the
/// band revert; and a partial liquidation at any price leaves floor credit covering the remaining credit.
/// @dev Every value comparison is exact: values are rationals of the Q64.96 square-root prices, compared by
/// cross-multiplication in `BigUint`, so no rounding of the test itself can hide or fake a failure.
contract FloorCreditMathFuzzTest is Test {
    using BigUint for uint256[];

    /// @dev Exact-formula slack of the integer credit: `credit ≥ L·min(r0, r1) − 5` (three floors and the min).
    uint256 internal constant PRECISION = 5;

    FloorCreditMathHarness internal h;

    /// @dev One band, one position inside it and its credit.
    struct Case {
        int24 a;
        int24 b;
        int24 bandA;
        int24 bandB;
        uint160 x;
        uint160 y;
        uint160 sx;
        uint160 sy;
        uint128 liquidity;
        uint128 credit;
    }

    function setUp() public {
        h = new FloorCreditMathHarness();
    }

    // ---------------------------------------------------------------- inputs

    function _case(
        int256 bandLowerSeed,
        int256 bandUpperSeed,
        int256 lowerSeed,
        int256 upperSeed,
        uint256 liquiditySeed,
        uint256 minLiquidity
    ) internal pure returns (Case memory c) {
        c.bandA = int24(_bound(bandLowerSeed, ClTickMath.MIN_TICK, ClTickMath.MAX_TICK - 1));
        c.bandB = int24(_bound(bandUpperSeed, int256(c.bandA) + 1, ClTickMath.MAX_TICK));
        c.a = int24(_bound(lowerSeed, c.bandA, int256(c.bandB) - 1));
        c.b = int24(_bound(upperSeed, int256(c.a) + 1, c.bandB));
        c.liquidity = uint128(_bound(liquiditySeed, minLiquidity, type(uint128).max));
        c.x = ClTickMath.getSqrtPriceAtTick(c.a);
        c.y = ClTickMath.getSqrtPriceAtTick(c.b);
        c.sx = ClTickMath.getSqrtPriceAtTick(c.bandA);
        c.sy = ClTickMath.getSqrtPriceAtTick(c.bandB);
        c.credit = FloorCreditMath.credit(c.a, c.b, c.bandA, c.bandB, c.liquidity);
    }

    /// @dev A square-root price below (mode 0), inside (1) or above (2) the band: uniform in √P for even seeds,
    /// uniform in ticks (log-uniform in price) for odd ones.
    function _price(
        Case memory c,
        uint8 mode,
        uint256 seed
    ) internal pure returns (uint160) {
        mode %= 3;
        if (seed & 1 == 0) {
            if (mode == 0) return uint160(_bound(seed, ClTickMath.MIN_SQRT_PRICE, c.sx));
            if (mode == 1) return uint160(_bound(seed, c.sx, c.sy));
            return uint160(_bound(seed, c.sy, ClTickMath.MAX_SQRT_PRICE));
        }
        int256 s = int256(seed >> 1);
        int256 tick;
        if (mode == 0) tick = _bound(s, ClTickMath.MIN_TICK, c.bandA);
        else if (mode == 1) tick = _bound(s, c.bandA, c.bandB);
        else tick = _bound(s, c.bandB, ClTickMath.MAX_TICK);
        return ClTickMath.getSqrtPriceAtTick(int24(tick));
    }

    // ---------------------------------------------------------------- exact values

    /// @dev Value in token1 of one unit of liquidity on `[lo, hi]` at `s`, as the exact rational `num / den`:
    /// `s²(hi − lo)/(lo·hi)` at or below `lo`, `hi − lo` at or above `hi`, `((s − lo)·hi + s·(hi − s))/hi` between.
    function _unitValue(
        uint256 lo,
        uint256 hi,
        uint256 s
    ) internal pure returns (uint256[] memory num, uint256[] memory den) {
        if (s <= lo) {
            num = BigUint.from(s).mul(s).mul(hi - lo);
            den = BigUint.from(lo).mul(hi);
        } else if (s >= hi) {
            num = BigUint.from(hi - lo);
            den = BigUint.from(1);
        } else {
            num = BigUint.from(s - lo).mul(hi).add(BigUint.from(s).mul(hi - s));
            den = BigUint.from(hi);
        }
    }

    /// @dev `credit · V_band(s) ≤ liquidity · V_position(s)`, exactly.
    function _covers(
        Case memory c,
        uint256 liquidity,
        uint256 credit,
        uint256 s
    ) internal pure returns (bool) {
        (uint256[] memory pn, uint256[] memory pd) = _unitValue(c.x, c.y, s);
        (uint256[] memory bn, uint256[] memory bd) = _unitValue(c.sx, c.sy, s);
        return bn.mul(credit).mul(pd).lte(pn.mul(liquidity).mul(bd));
    }

    /// @dev `k ≤ L·r1` and `k ≤ L·r0` exactly, with `r1 = Δ/D` and `r0 = Δ·sx·sy/(D·x·y)`.
    function _atMostExact(
        Case memory c,
        uint256 liquidity,
        uint256 k
    ) internal pure returns (bool) {
        uint256 delta = c.y - c.x;
        uint256 d = c.sy - c.sx;
        bool token1 = BigUint.from(k).mul(d).lte(BigUint.from(liquidity).mul(delta));
        bool token0 =
            BigUint.from(k).mul(d).mul(c.x).mul(c.y).lte(BigUint.from(liquidity).mul(delta).mul(c.sx).mul(c.sy));
        return token1 && token0;
    }

    // ---------------------------------------------------------------- floor

    /// @notice The position is worth at least its credit in band liquidity at a random price below, inside or above
    /// the band (proof, Section 1).
    function testFuzz_valueCoversCreditAtAnyPrice(
        int256 bandLowerSeed,
        int256 bandUpperSeed,
        int256 lowerSeed,
        int256 upperSeed,
        uint256 liquiditySeed,
        uint8 mode,
        uint256 priceSeed
    ) public pure {
        Case memory c = _case(bandLowerSeed, bandUpperSeed, lowerSeed, upperSeed, liquiditySeed, 1);
        uint160 s = _price(c, mode, priceSeed);
        assertTrue(_covers(c, c.liquidity, c.credit, s), "position value covers its credit");
    }

    /// @notice At both band edges, where the value ratio is least (proof, Section 2), and at the position's own edges.
    function testFuzz_valueCoversCreditAtEdges(
        int256 bandLowerSeed,
        int256 bandUpperSeed,
        int256 lowerSeed,
        int256 upperSeed,
        uint256 liquiditySeed
    ) public pure {
        Case memory c = _case(bandLowerSeed, bandUpperSeed, lowerSeed, upperSeed, liquiditySeed, 1);
        assertTrue(_covers(c, c.liquidity, c.credit, c.sx), "covers at the lower band edge");
        assertTrue(_covers(c, c.liquidity, c.credit, c.sy), "covers at the upper band edge");
        assertTrue(_covers(c, c.liquidity, c.credit, c.x), "covers at the position's lower edge");
        assertTrue(_covers(c, c.liquidity, c.credit, c.y), "covers at the position's upper edge");
    }

    // ---------------------------------------------------------------- rounding

    /// @notice The integer credit is at most the exact `L·min(r0, r1)` (rounding favours the protocol) and within
    /// `PRECISION` units of it.
    function testFuzz_creditRoundsDown(
        int256 bandLowerSeed,
        int256 bandUpperSeed,
        int256 lowerSeed,
        int256 upperSeed,
        uint256 liquiditySeed
    ) public pure {
        Case memory c = _case(bandLowerSeed, bandUpperSeed, lowerSeed, upperSeed, liquiditySeed, 0);
        assertTrue(_atMostExact(c, c.liquidity, c.credit), "credit at most the exact formula");
        assertFalse(_atMostExact(c, c.liquidity, uint256(c.credit) + PRECISION), "credit within PRECISION of it");
        assertLe(c.credit, c.liquidity, "credit at most liquidity");
    }

    /// @notice A position equal to its band gets credit equal to its liquidity.
    function testFuzz_fullBandPositionGetsItsLiquidity(
        int256 bandLowerSeed,
        int256 bandUpperSeed,
        uint128 liquidity
    ) public pure {
        int24 bandA = int24(_bound(bandLowerSeed, ClTickMath.MIN_TICK, ClTickMath.MAX_TICK - 1));
        int24 bandB = int24(_bound(bandUpperSeed, int256(bandA) + 1, ClTickMath.MAX_TICK));
        assertEq(FloorCreditMath.credit(bandA, bandB, bandA, bandB, liquidity), liquidity, "full credit");
    }

    // ---------------------------------------------------------------- monotone

    /// @notice More liquidity on the same ticks never earns less credit.
    function testFuzz_creditMonotoneInLiquidity(
        int256 bandLowerSeed,
        int256 bandUpperSeed,
        int256 lowerSeed,
        int256 upperSeed,
        uint256 liquiditySeed,
        uint256 moreSeed
    ) public pure {
        Case memory c = _case(bandLowerSeed, bandUpperSeed, lowerSeed, upperSeed, liquiditySeed, 0);
        uint128 more = uint128(_bound(moreSeed, c.liquidity, type(uint128).max));
        assertLe(c.credit, FloorCreditMath.credit(c.a, c.b, c.bandA, c.bandB, more), "monotone in liquidity");
    }

    // ---------------------------------------------------------------- band shape

    /// @notice A band spanning nearly the whole tick domain credits a position of moderate width (prices within
    /// e^±10 of 1) at most `L / 2^48`: one band unit is worth almost nothing at most prices.
    function testFuzz_nearFullRangeBandGivesNearZeroCredit(
        int256 bandLowerSeed,
        int256 bandUpperSeed,
        int256 lowerSeed,
        int256 upperSeed,
        uint128 liquidity
    ) public pure {
        int24 bandA = int24(_bound(bandLowerSeed, ClTickMath.MIN_TICK, ClTickMath.MIN_TICK + 1000));
        int24 bandB = int24(_bound(bandUpperSeed, ClTickMath.MAX_TICK - 1000, ClTickMath.MAX_TICK));
        int24 a = int24(_bound(lowerSeed, -200_000, 199_999));
        int24 b = int24(_bound(upperSeed, int256(a) + 1, 200_000));
        uint128 credit = FloorCreditMath.credit(a, b, bandA, bandB, liquidity);
        assertLe(credit, liquidity >> 48, "near-zero credit");
    }

    /// @notice A position that is empty, inverted or leaves the band on either side reverts `NotInsideBand`; square-root
    /// prices out of order or outside Uniswap's domain revert `SqrtPricesNotInsideBand`.
    function testFuzz_revertsOutsideBand(
        int256 bandLowerSeed,
        int256 bandUpperSeed,
        int256 lowerSeed,
        int256 upperSeed,
        uint8 kind,
        uint128 liquidity
    ) public {
        int24 bandA = int24(_bound(bandLowerSeed, ClTickMath.MIN_TICK + 1, ClTickMath.MAX_TICK - 2));
        int24 bandB = int24(_bound(bandUpperSeed, int256(bandA) + 1, ClTickMath.MAX_TICK - 1));
        int24 a;
        int24 b;
        kind %= 3;
        if (kind == 0) {
            // Starts below the band.
            a = int24(_bound(lowerSeed, ClTickMath.MIN_TICK, int256(bandA) - 1));
            b = int24(_bound(upperSeed, int256(a) + 1, ClTickMath.MAX_TICK));
        } else if (kind == 1) {
            // Ends above the band.
            b = int24(_bound(upperSeed, int256(bandB) + 1, ClTickMath.MAX_TICK));
            a = int24(_bound(lowerSeed, ClTickMath.MIN_TICK, int256(b) - 1));
        } else {
            // Empty or inverted, inside the band's ticks.
            a = int24(_bound(lowerSeed, bandA, bandB));
            b = int24(_bound(upperSeed, bandA, a));
        }
        vm.expectRevert(abi.encodeWithSelector(FloorCreditMath.NotInsideBand.selector, a, b, bandA, bandB));
        h.credit(a, b, bandA, bandB, liquidity);
    }

    /// @notice The square-root entry point refuses a band reaching outside `[MIN_SQRT_PRICE, MAX_SQRT_PRICE]`.
    function test_sqrtPricesOutsideDomainRevert() public {
        uint160 lo = ClTickMath.MIN_SQRT_PRICE;
        uint160 hi = ClTickMath.MAX_SQRT_PRICE;
        vm.expectRevert(
            abi.encodeWithSelector(FloorCreditMath.SqrtPricesNotInsideBand.selector, lo, lo + 1, lo - 1, hi)
        );
        h.creditAtSqrtPrices(lo, lo + 1, lo - 1, hi, 1);
        vm.expectRevert(
            abi.encodeWithSelector(FloorCreditMath.SqrtPricesNotInsideBand.selector, lo, lo + 1, lo, hi + 1)
        );
        h.creditAtSqrtPrices(lo, lo + 1, lo, hi + 1, 1);
        assertEq(h.creditAtSqrtPrices(lo, hi, lo, hi, 7), 7, "whole domain");
    }

    // ---------------------------------------------------------------- partial liquidation

    /// @notice A liquidation that seizes credit `c` at a random oracle price and unwinds the least liquidity `λ`
    /// worth at least the seized credit leaves `λ ≤ L` and, exactly, `r·(L − λ) > C − c − 1` for both ratios; the
    /// integer credit of the remainder covers `C − c` up to the rounding of `λ` and of the credit (proof, Section 3).
    function testFuzz_partialLiquidationKeepsFloor(
        int256 bandLowerSeed,
        int256 bandUpperSeed,
        int256 lowerSeed,
        int256 upperSeed,
        uint256 liquiditySeed,
        uint256 seizedSeed,
        uint8 mode,
        uint256 priceSeed
    ) public pure {
        Case memory c = _case(bandLowerSeed, bandUpperSeed, lowerSeed, upperSeed, liquiditySeed, 1 << 64);
        if (c.credit == 0) return;
        uint256 seized = _bound(seizedSeed, 1, c.credit);
        uint256 unwound = _leastLiquidityWorth(c, seized, _price(c, mode, priceSeed));
        assertLe(unwound, c.liquidity, "unwound at most the position");
        _checkRemainder(c, c.liquidity - unwound, c.credit - seized);
    }

    /// @dev The exact and integer floor checks of the liquidation test, on the kept liquidity and remaining credit.
    function _checkRemainder(
        Case memory c,
        uint256 kept,
        uint256 remaining
    ) internal pure {
        // r1·kept + 1 > remaining  ⇔  kept·Δ + D > remaining·D.
        uint256[] memory d = BigUint.from(c.sy - c.sx);
        uint256[] memory keptDelta = BigUint.from(kept).mul(c.y - c.x);
        assertTrue(d.mul(remaining).cmp(keptDelta.add(d)) < 0, "token1-side floor covers the remaining credit");
        // r0·kept + 1 > remaining  ⇔  kept·Δ·sx·sy + D·x·y > remaining·D·x·y.
        _checkToken0Remainder(c, keptDelta.mul(c.sx).mul(c.sy), d.mul(c.x).mul(c.y), remaining);
        uint128 keptCredit = FloorCreditMath.credit(c.a, c.b, c.bandA, c.bandB, uint128(kept));
        assertGe(uint256(keptCredit) + PRECISION + 1, remaining, "integer floor covers the remaining credit");
    }

    /// @dev `keptDeltaSxSy + dxy > remaining·dxy`.
    function _checkToken0Remainder(
        Case memory,
        uint256[] memory keptDeltaSxSy,
        uint256[] memory dxy,
        uint256 remaining
    ) internal pure {
        assertTrue(dxy.mul(remaining).cmp(keptDeltaSxSy.add(dxy)) < 0, "token0-side floor covers the remaining credit");
    }

    /// @dev Least `λ ∈ [0, L]` with `λ·V_position(s) ≥ seized·V_band(s)`, by bisection on exact comparisons.
    function _leastLiquidityWorth(
        Case memory c,
        uint256 seized,
        uint256 s
    ) internal pure returns (uint256 lo) {
        (uint256[] memory pn, uint256[] memory pd) = _unitValue(c.x, c.y, s);
        (uint256[] memory bn, uint256[] memory bd) = _unitValue(c.sx, c.sy, s);
        uint256[] memory need = bn.mul(seized).mul(pd);
        uint256[] memory unit = pn.mul(bd);
        uint256 hi = c.liquidity;
        while (lo < hi) {
            uint256 mid = lo + (hi - lo) / 2;
            if (need.lte(unit.mul(mid))) hi = mid;
            else lo = mid + 1;
        }
    }
}
