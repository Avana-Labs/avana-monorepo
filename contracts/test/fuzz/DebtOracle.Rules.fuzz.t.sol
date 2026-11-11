// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {DebtOracleFixture} from "../utils/fixtures/DebtOracleFixture.sol";
import {MockAggregator} from "../utils/mocks/MockAggregator.sol";

/// @title DebtOracleRulesFuzzTest
/// @notice Each validity and gate rule of the USDC DebtOracle against its own formula over random inputs: the pinned
/// answer bounds, the primary's age limit, the agreement tolerance (state Drifting exactly outside it), the second
/// source's tolerance (borrowing open exactly inside it), the sequencer gate of SPEC-ORC-021 and the Expired stress
/// price of SPEC-ORC-018 for any stored rise.
contract DebtOracleRulesFuzzTest is DebtOracleFixture {
    function setUp() public {
        _deployDebtOracle();
        vm.warp(T0 + 10);
    }

    function _view() internal view returns (DebtPriceView memory) {
        return oracle.getPriceState();
    }

    // TEST-219 verifies: REQ-ORACLE-002, REQ-ORACLE-005, REQ-ORACLE-006, REQ-ORACLE-092
    // Sources: 5.1 TEST-219 (answers around minAnswer and maxAnswer)
    /// @notice For any pinned `(min, max)` and answer, the primary is used exactly when `min < answer < max` (and its
    /// value is then the answer); otherwise the asset fails over to the alternate.
    function testFuzz_TEST_219_pinnedBounds(
        int256 lo,
        int256 hi,
        int256 answer
    ) public {
        lo = bound(lo, -1e12, 99_990_000);
        hi = bound(hi, 99_990_001, 1e12);
        answer = bound(answer, -2e12, 2e12);
        store.setFeed(address(pUsd), 8, lo, hi, 86_400, 1800);
        pUsd.push(answer, block.timestamp);
        DebtPriceView memory v = _view();
        bool valid = answer > lo && answer < hi && answer > 0;
        if (valid) {
            assertEq(v.primaryValue, uint256(answer));
            assertEq(uint8(v.routeUsed), uint8(RouteSlot.Primary));
        } else {
            assertEq(uint8(v.routeUsed), uint8(RouteSlot.Alternate), "fail over");
            assertEq(uint8(v.state), uint8(PriceState.Live));
            assertEq(uint256(v.answer), 99_990_000);
        }
        assertGe(v.answer, 1);
    }

    // TEST-276 verifies: SPEC-ORC-019, REQ-ORACLE-003, SPEC-ORC-013, REQ-ORACLE-092
    // Sources: 2.10 SPEC-ORC-019 (fresh iff now - updatedAt <= heartbeat + margin)
    /// @notice With the alternate invalid, the primary of any age is served Live exactly while its age is at most
    /// 88,200 s; older, the asset is failed with the failure starting at the current time (no source-timestamp
    /// failure, the alternate being invalid) and Cached.
    function testFuzz_TEST_276_primaryAgeLimit(
        uint256 age
    ) public {
        age = bound(age, 0, 200_000);
        aEth.push(0, block.timestamp);
        vm.warp(T0 + 300_000);
        pUsd.push(USDC_USD, block.timestamp - age);
        aEth.push(0, block.timestamp);
        DebtPriceView memory v = _view();
        if (age <= 88_200) {
            assertEq(uint8(v.state), uint8(PriceState.Live));
            assertEq(v.primaryAge, age);
        } else {
            assertEq(uint8(v.state), uint8(PriceState.Cached));
            assertEq(v.failureStart, block.timestamp);
            assertEq(v.reasons, 1, "NO_ROUTE only");
        }
    }

    // TEST-219 verifies: SPEC-ORC-003, REQ-ORACLE-008, REQ-ORACLE-092
    // Sources: 2.10 SPEC-ORC-003 (agree iff |p - b| x 10^4 <= T x min(p, b), T = 225)
    /// @notice For any ETH/USD answer moving the alternate, the asset is Drifting exactly when the two routes are outside
    /// the 225 bps tolerance, and Live on the primary otherwise.
    function testFuzz_TEST_219_agreementTolerance(
        int256 ethUsd8
    ) public {
        ethUsd8 = bound(ethUsd8, 250_000_000_000, 350_000_000_000);
        ethUsd.push(ethUsd8, block.timestamp);
        uint256 p = 99_990_000;
        uint256 b = uint256(USDC_ETH) * uint256(ethUsd8) / 1e18;
        DebtPriceView memory v = _view();
        assertEq(v.alternateValue, b, "two-leg route value");
        uint256 diff = p > b ? p - b : b - p;
        bool agree = diff * 1e4 <= 225 * (p < b ? p : b);
        assertEq(uint8(v.state), uint8(agree ? PriceState.Live : PriceState.Drifting));
        if (!agree) assertEq(uint256(v.answer), p > b ? p : b, "max(p, b, A)");
    }

    // TEST-276 verifies: SPEC-ORC-020, REQ-ORACLE-100, REQ-ORACLE-092
    // Sources: 2.10 SPEC-ORC-020 (confirmed iff |q - s| x 10^4 <= S x min(q, s), S = 100)
    /// @notice For any second-source answer, borrowing is open exactly when the source is within 100 bps of the quote;
    /// the state and the liquidation gate never depend on it.
    function testFuzz_TEST_276_secondSourceTolerance(
        int256 s
    ) public {
        s = bound(s, 1, 2e8);
        second.push(s, block.timestamp);
        uint256 q = 99_990_000;
        uint256 su = uint256(s);
        uint256 diff = q > su ? q - su : su - q;
        bool confirmed = diff * 1e4 <= 100 * (q < su ? q : su);
        DebtPriceView memory v = _view();
        assertEq(v.borrowAllowed, confirmed);
        assertEq(v.reasons & (1 << 19) == 0, confirmed);
        assertEq(uint8(v.state), uint8(PriceState.Live));
        assertFalse(v.liquidationPaused);
    }

    // TEST-276 verifies: SPEC-ORC-021, REQ-ORACLE-099, REQ-ORACLE-034, REQ-ORACLE-092
    // Sources: 2.10 SPEC-ORC-021 (up, down, unknown, grace and ready)
    /// @notice For any sequencer answer and restart time, the gates follow SPEC-ORC-021: down (answer 1) pauses
    /// liquidation and closes borrowing; up with `0 < startedAt <= now` is in grace (borrowing closed, `inGrace`) until
    /// `startedAt + 3,600` and ready after; anything else is unknown and closes borrowing only.
    function testFuzz_TEST_276_sequencerGate(
        int256 answer,
        uint256 startedAt
    ) public {
        answer = bound(answer, -1, 3);
        startedAt = bound(startedAt, 0, block.timestamp + 10_000);
        MockAggregator seq = new MockAggregator(0, answer, block.timestamp);
        seq.setStartedAt(startedAt);
        store.setSequencer(address(seq), 3600);
        DebtPriceView memory v = _view();
        bool down = answer == 1;
        bool up = answer == 0 && startedAt != 0 && startedAt <= block.timestamp;
        bool inGrace = up && block.timestamp < startedAt + 3600;
        bool ready = up && !inGrace;
        assertEq(v.liquidationPaused, down, "only down pauses liquidation");
        assertEq(v.borrowAllowed, ready, "only ready opens borrowing");
        assertEq(v.inGrace, inGrace);
        assertEq(v.reasons & (1 << 17) != 0, !up, "down or unknown");
        assertEq(v.reasons & (1 << 18) != 0, inGrace);
        if (inGrace) assertEq(v.graceEndsAt, startedAt + 3600);
        assertEq(uint256(v.answer), 99_990_000, "the price never depends on the sequencer");
    }

    // TEST-230 verifies: SPEC-ORC-018, REQ-ORACLE-093, INV-087
    // Sources: 2.10 SPEC-ORC-018 (Expired serves ceil(A x (10^4 + delta) / 10^4), delta read into [100, 5,000])
    /// @notice For any stored rise, an Expired asset serves the accepted price raised by the rise clamped to
    /// `[100, 5,000]`, rounded up, and never more than `1.5 x A + 1`.
    function testFuzz_TEST_230_expiredStressPrice(
        uint16 delta
    ) public {
        pUsd.push(0, block.timestamp);
        aEth.push(0, block.timestamp);
        _poke();
        vm.warp(block.timestamp + 3600);
        store.setStressRise(usdc, delta);
        uint256 d = delta < 100 ? 100 : delta > 5000 ? 5000 : delta;
        uint256 a = 99_990_000;
        uint256 expected = (a * (10_000 + d) + 9999) / 10_000;
        DebtPriceView memory v = _view();
        assertEq(uint8(v.state), uint8(PriceState.Expired));
        assertEq(uint256(v.answer), expected);
        assertLe(uint256(v.answer), a * 3 / 2 + 1);
        assertGt(uint256(v.answer), a);
    }
}
