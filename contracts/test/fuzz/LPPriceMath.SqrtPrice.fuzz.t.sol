// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPOracle} from "../../src/LPOracle.sol";
import {ILPOracle} from "../../src/interfaces/ILPOracle.sol";
import {ClTickMath} from "../../src/libraries/ClTickMath.sol";
import {LPPriceMath} from "../../src/libraries/LPPriceMath.sol";
import {BigUint} from "../utils/BigUint.sol";
import {BandTestFeed, BandTestPriceSpoke, BandTestToken, BandTestVault} from "../utils/mocks/BandOracleMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The LPOracle's fair square-root price `√(p0 · 10^d1 / (p1 · 10^d0)) · 2^96` over every price × decimals pair
/// the oracle accepts: prices 1 to `MAX_PRICE` (10^18 at 8 decimals) and token decimals 0 to 18.
contract LPPriceMathSqrtPriceFuzzTest is Test {
    using BigUint for uint256[];

    uint256 internal constant MARKET = 1;
    uint256 internal constant Q192 = 1 << 192;

    BandTestVault internal vault;
    BandTestPriceSpoke internal priceSpoke;

    function setUp() public {
        vault = new BandTestVault();
        priceSpoke = new BandTestPriceSpoke(8);
        priceSpoke.init();
    }

    function _bounded(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) internal pure returns (uint256, uint256, uint8, uint8) {
        return (
            bound(p0, 1, LPPriceMath.MAX_PRICE),
            bound(p1, 1, LPPriceMath.MAX_PRICE),
            uint8(bound(d0, 0, LPPriceMath.MAX_DECIMALS)),
            uint8(bound(d1, 0, LPPriceMath.MAX_DECIMALS))
        );
    }

    /// @notice Bug hunted: a clamp at the tick-range ends binding inside the accepted bounds, which would price a real
    /// pair at `MIN_SQRT_PRICE` or `MAX_SQRT_PRICE - 1` instead of its own price. The extremes are
    /// `10^18 · 10^18 / 1` and its inverse, √ of which times 2^96 is about 7.9e46 and 7.9e10, inside
    /// `[4.3e9, 1.46e48)`; so the raw root is never `high` and is returned unchanged.
    function testFuzz_neverClampedInsideTheBounds(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) public pure {
        (p0, p1, d0, d1) = _bounded(p0, p1, d0, d1);
        (uint256 raw, bool high) = LPPriceMath.rawSqrtPrice(p0, p1, d0, d1);
        assertFalse(high, "high inside the bounds");
        assertGe(raw, ClTickMath.MIN_SQRT_PRICE, "below MIN_SQRT_PRICE inside the bounds");
        assertLt(raw, ClTickMath.MAX_SQRT_PRICE, "at or above MAX_SQRT_PRICE inside the bounds");
        assertEq(LPPriceMath.sqrtPriceX96(p0, p1, d0, d1), raw, "clamped inside the bounds");
    }

    /// @notice The corners of the bounds, where a clamp would first bind.
    function test_cornersAreNotClamped() public pure {
        uint256 maxP = LPPriceMath.MAX_PRICE;
        uint8 maxD = LPPriceMath.MAX_DECIMALS;
        uint160 top = LPPriceMath.sqrtPriceX96(maxP, 1, 0, maxD);
        uint160 bottom = LPPriceMath.sqrtPriceX96(1, maxP, maxD, 0);
        assertGt(top, ClTickMath.MIN_SQRT_PRICE);
        assertLt(top, ClTickMath.MAX_SQRT_PRICE - 1);
        assertGt(bottom, ClTickMath.MIN_SQRT_PRICE);
        // √(10^36) · 2^96 and √(10^-36) · 2^96, rounded down.
        assertEq(top, 79_228_162_514_264_337_593_543_950_336 * 1e18);
        assertEq(bottom, 79_228_162_514);
    }

    /// @notice Bug hunted: an input past the accepted bounds (a caller that skips the oracle's price and decimals
    /// checks) gets a √price the tick math refuses, or one that wraps in the uint160 cast. Past either end of the tick
    /// range the result is the nearest valid √price, which `getTickAtSqrtPrice` accepts; inside it, the raw root.
    function testFuzz_pastTheBoundsStaysAValidSqrtPrice(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) public pure {
        // 10^30 · 10^18 < 2^160, so `den << 64` and the root's mulDiv stay exact.
        p0 = bound(p0, 1, 1e30);
        p1 = bound(p1, 1, 1e30);
        d0 = uint8(bound(d0, 0, LPPriceMath.MAX_DECIMALS));
        d1 = uint8(bound(d1, 0, LPPriceMath.MAX_DECIMALS));
        uint160 s = LPPriceMath.sqrtPriceX96(p0, p1, d0, d1);
        assertGe(s, ClTickMath.MIN_SQRT_PRICE, "below the tick range");
        assertLt(s, ClTickMath.MAX_SQRT_PRICE, "at or above the tick range");
        ClTickMath.getTickAtSqrtPrice(s);
        (uint256 raw, bool high) = LPPriceMath.rawSqrtPrice(p0, p1, d0, d1);
        if (high) assertEq(s, ClTickMath.MAX_SQRT_PRICE - 1, "high not clamped to the top");
        else if (raw < ClTickMath.MIN_SQRT_PRICE) assertEq(s, ClTickMath.MIN_SQRT_PRICE, "low not clamped");
        else assertEq(s, raw, "clamped inside the tick range");
    }

    /// @notice The three ways out of the tick range, each clamped to the edge the tick math accepts: a ratio of 2^128
    /// or more (the early `high`), a ratio just under 2^128 whose root still reaches `MAX_SQRT_PRICE`, and a ratio
    /// whose root is under `MIN_SQRT_PRICE`.
    function test_pastTheBoundsClampsToTheNearestEdge() public pure {
        (uint256 raw, bool high) = LPPriceMath.rawSqrtPrice(1e21, 1, 0, 18);
        assertTrue(high);
        assertEq(raw, 0);
        assertEq(LPPriceMath.sqrtPriceX96(1e21, 1, 0, 18), ClTickMath.MAX_SQRT_PRICE - 1);
        // 3.4028e38 is 0.99999 · 2^128, above (MAX_SQRT_PRICE / 2^160)^2 · 2^128 = 0.99992 · 2^128.
        (raw, high) = LPPriceMath.rawSqrtPrice(340_280e15, 1, 0, 18);
        assertTrue(high);
        assertGe(raw, ClTickMath.MAX_SQRT_PRICE);
        assertEq(LPPriceMath.sqrtPriceX96(340_280e15, 1, 0, 18), ClTickMath.MAX_SQRT_PRICE - 1);
        assertEq(ClTickMath.getTickAtSqrtPrice(ClTickMath.MAX_SQRT_PRICE - 1), ClTickMath.MAX_TICK - 1);
        assertEq(LPPriceMath.sqrtPriceX96(1, 1e21, 18, 0), ClTickMath.MIN_SQRT_PRICE);
        assertEq(ClTickMath.getTickAtSqrtPrice(ClTickMath.MIN_SQRT_PRICE), ClTickMath.MIN_TICK);
    }

    /// @notice Bug hunted: a wrong root, or one rounded up. With `X = p0 · 10^d1 · 2^192 / (p1 · 10^d0)` exact,
    /// `s² ≤ X < (s + e)²`, where `e` is 1 on the direct branch and 2^32 on the branch that roots `X / 2^64` (prices
    /// 2^64 or more), checked in big integers. So the root is rounded down, and short by less than one Q64.96 unit,
    /// or by less than a relative 2^-96 on the high branch.
    function testFuzz_rootIsTheFloorWithinOneStep(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) public pure {
        (p0, p1, d0, d1) = _bounded(p0, p1, d0, d1);
        uint256 s = LPPriceMath.sqrtPriceX96(p0, p1, d0, d1);
        uint256 num = p0 * 10 ** d1;
        uint256 den = p1 * 10 ** d0;
        uint256 e = num < den << 64 ? 1 : 1 << 32;
        // s² · den ≤ num · 2^192 < (s + e)² · den
        uint256[] memory x = BigUint.from(num).mul(Q192);
        assertTrue(BigUint.from(s).mul(s).mul(den).lte(x), "root rounded up");
        assertFalse(BigUint.from(s + e).mul(s + e).mul(den).lte(x), "root short by a step or more");
    }

    /// @notice Bug hunted: a non-monotone result, at the switch between the two branches (`num = den · 2^64`) above
    /// all, where the second branch drops the low 32 bits. A higher token0 price or token1 decimals never lowers the
    /// root; a higher token1 price or token0 decimals never raises it.
    function testFuzz_monotone(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1,
        uint256 up
    ) public pure {
        (p0, p1, d0, d1) = _bounded(p0, p1, d0, d1);
        uint160 s = LPPriceMath.sqrtPriceX96(p0, p1, d0, d1);
        uint256 q0 = bound(up, p0, LPPriceMath.MAX_PRICE);
        uint256 q1 = bound(up, p1, LPPriceMath.MAX_PRICE);
        assertGe(LPPriceMath.sqrtPriceX96(q0, p1, d0, d1), s, "token0 price up lowered the root");
        assertLe(LPPriceMath.sqrtPriceX96(p0, q1, d0, d1), s, "token1 price up raised the root");
        if (d1 < LPPriceMath.MAX_DECIMALS) {
            assertGe(LPPriceMath.sqrtPriceX96(p0, p1, d0, d1 + 1), s, "token1 decimals up lowered the root");
        }
        if (d0 < LPPriceMath.MAX_DECIMALS) {
            assertLe(LPPriceMath.sqrtPriceX96(p0, p1, d0 + 1, d1), s, "token0 decimals up raised the root");
        }
    }

    /// @notice Bug hunted: a step down where the branches meet. `p0 · 10^2 = 2^64` falls between integer prices, so
    /// token0 prices 184,467,440,737,095,516 ± 64 with token1 at 1 (d0 = 0, d1 = 2) walk across the switch one unit
    /// at a time; each root is at least the one before.
    function testFuzz_monotoneAcrossTheBranchSwitch(
        uint8 start
    ) public pure {
        uint256 p = 184_467_440_737_095_516 - 64 + (start % 64);
        uint160 prev = LPPriceMath.sqrtPriceX96(p, 1, 0, 2);
        for (uint256 i = 1; i <= 64; ++i) {
            uint160 next = LPPriceMath.sqrtPriceX96(p + i, 1, 0, 2);
            assertGe(next, prev, "root fell across the branch switch");
            prev = next;
        }
    }

    /// @notice Bug hunted: an overflow anywhere in a read of the whole oracle (both prices, the root, the band
    /// amounts and their value) for any accepted price × decimals pair, unit decimals 6 to 18 and any band of the
    /// tick range, the full range included. The answer is positive and fits an int256.
    function testFuzz_answerNeverOverflows(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1,
        uint8 ud,
        int24 lower,
        int24 upper,
        bool fullRange
    ) public {
        (p0, p1, d0, d1) = _bounded(p0, p1, d0, d1);
        ud = uint8(bound(ud, 6, 18));
        if (fullRange) {
            (lower, upper) = (ClTickMath.MIN_TICK, ClTickMath.MAX_TICK);
        } else {
            lower = int24(bound(lower, ClTickMath.MIN_TICK, ClTickMath.MAX_TICK - 1));
            upper = int24(bound(upper, int256(lower) + 1, ClTickMath.MAX_TICK));
        }
        LPOracle oracle = _oracle([p0, p1], [d0, d1, ud], lower, upper);
        assertGt(oracle.latestAnswer(), 0);
        (,, uint160 s) = oracle.getPrices();
        assertEq(s, LPPriceMath.sqrtPriceX96(p0, p1, d0, d1));
    }

    function _oracle(
        uint256[2] memory p,
        uint8[3] memory d,
        int24 lower,
        int24 upper
    ) internal returns (LPOracle) {
        BandTestToken a = new BandTestToken("T0", d[0]);
        BandTestToken b = new BandTestToken("T1", d[1]);
        vault.setMarket(MARKET, address(a), address(b), lower, upper);
        // Prices are at most 1e18 < 2^255.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 id0 = priceSpoke.addReserve(address(a), d[0], address(new BandTestFeed(8, int256(p[0]))));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 id1 = priceSpoke.addReserve(address(b), d[1], address(new BandTestFeed(8, int256(p[1]))));
        return new LPOracle(
            ILPOracle.Params({
                lpVault: address(vault),
                marketId: MARKET,
                unitDecimals: d[2],
                priceSpoke: address(priceSpoke),
                reserveId0: id0,
                reserveId1: id1,
                description: "sqrt fuzz"
            })
        );
    }
}
