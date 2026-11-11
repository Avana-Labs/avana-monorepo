// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Test} from "forge-std/Test.sol";
import {LPPriceMathHarness} from "./LPPriceMathHarness.sol";
import {PriceState} from "../src/types/PriceState.sol";

contract PoC is Test {
    LPPriceMathHarness m;
    function setUp() public { m = new LPPriceMathHarness(); }
    function u2(uint256 a, uint256 b) internal pure returns (uint256[] memory o) { o = new uint256[](2); (o[0], o[1]) = (a, b); }
    function d2(uint8 a, uint8 b) internal pure returns (uint8[] memory o) { o = new uint8[](2); (o[0], o[1]) = (a, b); }

    function test_deviationBpsReverts() public {
        vm.expectRevert();
        m.deviationBps(1, type(uint256).max);
    }
    function test_deviationBpsRevertsAtRouteScale() public {
        // an Invalid route value far above MAX_ROUTE_ANSWER, against a valid $1 route
        vm.expectRevert();
        m.deviationBps(1e8, 2**250);
    }
    function test_negativeCastNormalize() public {
        uint256 neg = uint256(int256(-1));
        vm.expectRevert();
        m.normalizeAnswer(neg, 6);
        uint256 n = m.normalizeAnswer(neg, 18);
        emit log_named_uint("normalize(-1 cast, 18)", n);
        assertGt(n, 1e60);
    }
    function test_negativeCastRoute() public view {
        uint256 neg = uint256(int256(-1e8));
        uint256 r = m.routeValue2(neg, 18, 3e11, 8);
        assertGt(r, 1e60);
    }
    function test_lpPriceLengthMismatch() public {
        uint256[] memory a3 = new uint256[](3);
        (a3[0], a3[1], a3[2]) = (1e6, 1e6, 1e6);
        vm.expectRevert(); // panic 0x32
        m.lpPrice(a3, u2(1e8, 1e8), d2(6, 6));
        // empty composition: price 1 served as a Live fresh price
        assertEq(m.lpPrice(new uint256[](0), u2(1e8, 1e8), d2(6, 6)), 1);
        uint256[] memory a1 = new uint256[](1); a1[0] = 1e6 + 1;
        assertEq(m.lpPrice(a1, u2(1e8, 1e8), d2(6, 6)), 1e8); // second token silently dropped
    }
    function test_servedTimestampEmpty() public view {
        assertEq(m.servedTimestamp(new uint64[](0), false, 123), type(uint64).max);
    }
    function test_saturationNotSticky() public view {
        uint256[] memory xs = new uint256[](3);
        (xs[0], xs[1], xs[2]) = (2**200, 2**200, 1);
        assertLt(m.fixedPointProduct(xs), type(uint256).max);
        (xs[0], xs[1], xs[2]) = (2**200, 2**200, 0);
        assertEq(m.fixedPointProduct(xs), 0);
    }
    function test_bandOrderDependent() public view {
        uint256[] memory a = new uint256[](3);
        (a[0], a[1], a[2]) = (95_243_313, 98_905_925, 97_089_205);
        uint256[] memory b = new uint256[](3);
        (b[0], b[1], b[2]) = (97_089_205, 98_905_925, 95_243_313);
        uint256[] memory v = new uint256[](3);
        bool fwd = m.inUsdBand(a, a, 97_067_963, type(uint256).max);
        bool rev = m.inUsdBand(b, b, 97_067_963, type(uint256).max);
        assertTrue(fwd != rev);
        v;
    }
    function test_servedAboveFresh() public view {
        // full-range USDC/USDT d=6: compositions from SPEC-ORC-009/006 (python cl.py)
        uint256 fresh = m.lpPrice(u2(999_173, 1_000_826), u2(97_544_839, 97_383_701), d2(6, 6));
        uint256 lower = m.lpPrice(u2(999_173, 1_000_827), u2(97_544_839, 97_383_663), d2(6, 6));
        assertEq(fresh, 194_928_113); assertEq(lower, 194_928_172);
        uint256 served = m.servedPrice(PriceState.Drifting, true, fresh, lower, 2e8);
        assertGt(served, fresh);
    }
    function test_minObsZeroBlockTime() public {
        vm.expectRevert();
        m.minObservations(1800, 0);
    }
    function test_agreeOverflow() public {
        vm.expectRevert();
        m.routesAgree(1, 2**243, 100);
    }
    function test_usdLevelInBandBelowLow() public view {
        // low^(x)2 = 81,000,001 <= q0 (x) q1 = 81,000,001: in band, yet isqrt(P * 1e8) = 90,000,000 < low
        assertTrue(m.inUsdBand(u2(81_000_001, 1e8), u2(81_000_001, 1e8), 90_000_001, 102_000_000));
    }
}
