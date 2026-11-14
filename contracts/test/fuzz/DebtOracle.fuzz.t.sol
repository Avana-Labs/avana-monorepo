// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {DebtOracleFixture} from "../utils/fixtures/DebtOracleFixture.sol";
import {MockAggregator} from "../utils/mocks/MockAggregator.sol";

/// @title DebtOracleFuzzTest
/// @notice `TEST-219` for the DebtOracle: sequences of feed answers at and around their bounds, negative answers,
/// decimals mismatches, zero, future and old timestamps, reverting and gas-burning feeds, jumps of ±50 % and ±99 %, and
/// time steps across the age, cached and disagreement windows. After every step the served price is at least 1 and
/// never reverts, it is never below the accepted price unless Live, and it follows `SPEC-ORC-018` by state; `poke()`
/// with enough gas never reverts.
contract DebtOracleFuzzTest is DebtOracleFixture {
    function setUp() public {
        _deployDebtOracle();
    }

    function _ceilStress(
        uint256 a,
        uint256 delta
    ) internal pure returns (uint256) {
        if (delta < 100) delta = 100;
        if (delta > 5000) delta = 5000;
        return (a * (10_000 + delta) + 9999) / 10_000;
    }

    /// @dev One answer of the TEST-219 list for a feed whose pinned bounds are `(0, max)` and whose honest value is `v`.
    function _answer(
        uint256 kind,
        int256 v,
        int256 max
    ) internal pure returns (int256) {
        kind %= 12;
        if (kind == 0) return 0;
        if (kind == 1) return 1;
        if (kind == 2) return -1;
        if (kind == 3) return max - 1;
        if (kind == 4) return max;
        if (kind == 5) return max + 1;
        if (kind == 6) return v + v / 2;
        if (kind == 7) return v - v / 2;
        if (kind == 8) return v + (v * 99) / 100;
        if (kind == 9) return v / 100;
        if (kind == 10) return v + v / 1000;
        return v;
    }

    function _timestamp(
        uint256 kind
    ) internal view returns (uint256) {
        kind %= 6;
        if (kind == 0) return 0;
        if (kind == 1) return block.timestamp + 1;
        if (kind == 2) return block.timestamp > 100_000 ? block.timestamp - 100_000 : 1;
        if (kind == 3) return block.timestamp > 5401 ? block.timestamp - 5401 : 1;
        return block.timestamp;
    }

    function _feed(
        uint256 i
    ) internal view returns (MockAggregator f, int256 v, int256 max) {
        i %= 3;
        if (i == 0) return (pUsd, USDC_USD, 1e12);
        if (i == 1) return (aEth, USDC_ETH, 1e18);
        return (ethUsd, ETH_USD, 1e12);
    }

    function _step(
        uint256 r
    ) internal {
        uint256 action = r % 7;
        r >>= 8;
        (MockAggregator f, int256 v, int256 max) = _feed(r);
        r >>= 8;
        if (action == 0) {
            f.push(_answer(r, v, max), _timestamp(r >> 8));
        } else if (action == 1) {
            vm.warp(block.timestamp + (r % 4) * 1800 + ((r >> 4) % 3) * 88_200 + 1);
        } else if (action == 2) {
            f.setMode(f.latestRoundData.selector, MockAggregator.Mode(r % 6));
        } else if (action == 3) {
            f.setDecimals(uint8(r % 2 == 0 ? (address(f) == address(aEth) ? 18 : 8) : 6));
        } else if (action == 4) {
            _refreshAll();
        } else if (action == 5) {
            store.setTolerance(usdc, uint16(r % 400));
        } else {
            _poke();
        }
    }

    function _check() internal view {
        uint256 served = uint256(oracle.latestAnswer());
        assertGe(served, 1, "served >= 1");
        DebtPriceView memory v = oracle.getPriceState();
        assertEq(uint256(v.answer), served, "getPriceState().answer == latestAnswer()");
        uint256 a = _accepted();
        if (v.state != PriceState.Live) assertGe(served, a, "never below the accepted price unless Live");
        if (v.state == PriceState.Cached) assertEq(served, a, "Cached serves A");
        if (v.state == PriceState.Expired) assertEq(served, _ceilStress(a, STRESS), "Expired serves the stress price");
        if (v.state == PriceState.Drifting) {
            assertEq(
                served, _driftingServed(v.primaryValue, v.alternateValue, a), "a disagreement serves max(counted, A)"
            );
            assertTrue(v.liquidationPaused);
        }
        if (v.state == PriceState.Live) assertEq(served, v.quote, "Live serves the quote");
        if (v.borrowAllowed) assertEq(uint8(v.state), uint8(PriceState.Live));
        assertLe(a, 1e12, "the accepted price stays within MAX_ROUTE_ANSWER");
    }

    // TEST-219 verifies: REQ-ORACLE-093, SPEC-ORC-018, REQ-ORACLE-005, REQ-ORACLE-008, INV-087
    // Sources: fuzz twin of the Halmos PROP-074 check with both one-leg routes symbolic
    function testFuzz_TEST_219_servedByStateBothRoutes(
        uint40 p,
        uint40 b
    ) public {
        reg.setRoutes(usdc, _route1(address(pUsd)), _route1(address(standby)));
        pUsd.push(int256(uint256(p)), block.timestamp);
        standby.push(int256(uint256(b)), block.timestamp);
        uint256 a = _accepted();
        bool pValid = p > 0 && p < 1e12;
        bool bValid = b > 0 && b < 1e12;
        uint256 expected;
        bool live = true;
        if (pValid && bValid) {
            (uint256 lo, uint256 hi) = p < b ? (uint256(p), uint256(b)) : (uint256(b), uint256(p));
            if ((hi - lo) * 10_000 <= uint256(TOLERANCE) * lo) {
                expected = p;
            } else {
                live = false;
                expected = _driftingServed(p, b, a);
            }
        } else if (pValid) {
            expected = p;
        } else if (bValid) {
            expected = b;
        } else {
            live = false;
            expected = a;
        }
        uint256 served = _served();
        assertEq(served, expected);
        assertGe(served, 1);
        if (!live) assertGe(served, a);
    }

    // TEST-219 verifies: REQ-ORACLE-093, SPEC-ORC-012, SPEC-ORC-015, SPEC-ORC-018
    // Sources: fuzz twin of the Halmos PROP-074 served-route checks (review DO-01), both one-leg routes fuzzed with
    // distinct timestamps: while Drifting the reported timestamp and legs are those of the route whose value is served,
    // or the accepted timestamp with no legs and no limits when the accepted price is served.
    function testFuzz_TEST_219_driftingTimestampFollowsServedRoute(
        uint40 p,
        uint40 b
    ) public {
        reg.setRoutes(usdc, _route1(address(pUsd)), _route1(address(standby)));
        pUsd.push(int256(uint256(p)), block.timestamp - 80);
        standby.push(int256(uint256(b)), block.timestamp - 50);
        (uint256 a, uint64 aAt) = oracle.lastAcceptedPrice();
        DebtPriceView memory v = oracle.getPriceState();
        if (v.state != PriceState.Drifting) return;
        uint256 counted = _countedRoute(p, b);
        (,,, uint256 updatedAt,) = oracle.latestRoundData();
        assertEq(updatedAt, v.servedUpdatedAt);
        if (a > counted) {
            assertEq(v.servedUpdatedAt, aAt);
            assertEq(v.legFeeds[0], address(0));
            assertEq(v.borrowPriceMaxAge, 0);
            assertEq(v.liquidationPriceMaxAge, 0);
        } else if (b == counted) {
            assertEq(v.servedUpdatedAt, block.timestamp - 50);
            assertEq(v.legFeeds[0], address(standby));
        } else {
            assertEq(v.servedUpdatedAt, block.timestamp - 80);
            assertEq(v.legFeeds[0], address(pUsd));
        }
    }

    // TEST-230 verifies: REQ-ORACLE-093, SPEC-ORC-018, REQ-ORACLE-092, INV-087
    // Sources: fuzz twin of the Halmos PROP-074 stress-clamp check (review DO-03): any uint16 stress rise is read into
    // [100, 5,000], so the Expired price stays within (A, 1.5 x A + 1].
    function testFuzz_TEST_230_expiredStressRiseClamped(
        uint16 delta
    ) public {
        store.setStressRise(usdc, delta);
        vm.warp(T0 + 200_000);
        uint256 a = _accepted();
        uint256 served = _served();
        assertEq(served, _ceilStress(a, delta));
        assertGt(served, a);
        assertLe(served, (a * 3) / 2 + 1);
    }

    // TEST-219 verifies: REQ-ORACLE-093, SPEC-ORC-018, REQ-ORACLE-061, REQ-ORACLE-092, REQ-ORACLE-002, REQ-ORACLE-017, INV-087, INV-059, Q-247, Q-248
    // Sources: 5.1 TEST-219, HYP-11, HYP-37, HYP-42, MATH-UO-15
    function testFuzz_TEST_219_servedPriceBoundsAfterEveryStep(
        uint256[8] memory steps
    ) public {
        _check();
        for (uint256 i = 0; i < steps.length; ++i) {
            _step(steps[i]);
            _check();
        }
        _poke();
        _check();
    }
}
