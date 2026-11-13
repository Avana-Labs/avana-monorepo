// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Evaluation, LegEval, TokenEval} from "../../src/oracle/lp-oracle/LPOracleTypes.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {LPOracleHarnessPokeLogic} from "../utils/harness/LPOracleHarness.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Exposes the LPOracle base's state decision and timer writes on symbolic inputs.
contract LPOracleDecisionHarness is LPOracleHarnessPokeLogic {
    struct Inputs {
        bool failed;
        bool disagreeing;
        bool versionChanged;
        bool hasStaleStart;
        uint64 staleStart;
        uint64 failedSince;
        uint64 disagreeSince;
        uint32 cachedWindow;
        uint32 pauseMax;
        uint256 reasons;
        uint256 fresh;
        uint256 lower;
        uint256 accepted;
        uint64 decimalsCheckedAt;
    }

    struct Outcome {
        PriceState state;
        uint256 served;
        uint64 failureStart;
        bool pauseActive;
        bool disagreementExpired;
        bool liquidationPaused;
        bool borrowAllowed;
        uint64 disagreeSince;
        uint32 borrowMaxAge;
        uint32 liquidationMaxAge;
        uint256 reasons;
    }

    constructor() LPOracleHarnessPokeLogic(address(0x7173), 12, 556_588, 3_000_000, false) {}

    function _load(
        Inputs memory x
    ) internal returns (Evaluation memory e) {
        Layout storage $ = _s();
        ($.failedSince, $.disagreeSince) = (x.failedSince, x.disagreeSince);
        // accepted is a positive price8 below 2^200 (the caller bounds it).
        // forge-lint: disable-next-line(unsafe-typecast)
        $.accepted.answer = int256(x.accepted);
        // No accepted price in this block: the quote-change cap never applies here.
        $.acceptedBlock = type(uint64).max;
        // One token quoted on a one-leg primary read now, so the age limits are the leg's and `borrowAllowed` can hold.
        e.tokens = new TokenEval[](1);
        TokenEval memory t = e.tokens[0];
        (t.used, t.chosen, t.chosenAt) = (1, 1, uint64(block.timestamp));
        t.routes[0].legCount = 1;
        LegEval memory leg = t.routes[0].legs[0];
        (leg.updatedAt, leg.borrowAge, leg.liquidationAge) = (uint64(block.timestamp), 88_200, 88_200);
        e.cfg.ok = true;
        e.cfg.cachedWindow = x.cachedWindow;
        e.cfg.disagreementPauseMax = x.pauseMax;
        e.failed = x.failed;
        e.disagreeing = x.disagreeing && !x.failed;
        e.versionChanged = x.versionChanged;
        e.hasStaleStart = x.hasStaleStart;
        e.staleStart = x.staleStart;
        e.reasons = x.reasons;
        e.fresh = x.fresh;
        e.lower = x.lower;
        e.decimalsCheckedAt = x.decimalsCheckedAt;
        // A chain without a sequencer feed: ready (SPEC-ORC-021), so borrowAllowed depends on the gates under test.
        e.seq.ready = true;
    }

    function decide(
        Inputs memory x
    ) external returns (Outcome memory o) {
        Evaluation memory e = _load(x);
        _decide(e);
        o.state = e.state;
        o.served = e.served;
        o.failureStart = e.failureStart;
        o.pauseActive = e.pauseActive;
        o.disagreementExpired = e.disagreementExpired;
        o.liquidationPaused = e.liquidationPaused;
        o.borrowAllowed = e.borrowAllowed;
        o.disagreeSince = e.disagreeSince;
        o.borrowMaxAge = e.borrowMaxAge;
        o.liquidationMaxAge = e.liquidationMaxAge;
        o.reasons = e.reasons;
    }

    function writeTimers(
        Inputs memory x
    ) external returns (uint64 failedAfter, uint64 disagreeAfter) {
        Evaluation memory e = _load(x);
        _writeVersions(e);
        _writeFailure(e);
        if (!e.versionChanged) _writeDisagreement(e);
        (failedAfter, disagreeAfter) = (_s().failedSince, _s().disagreeSince);
    }
}

/// @title LPOracleHalmosTest
/// @notice Symbolic checks of the LPOracle base's state machine (2.10): the served price by state (`SPEC-ORC-017`),
/// the failure start and the Cached-to-Expired boundary (`SPEC-ORC-013`), the disagreement windows (`SPEC-ORC-016`)
/// and the stored first observation of a disagreement (`REQ-ORACLE-028`, `REQ-ORACLE-095`).
/// @dev The evaluation's inputs (failure, disagreement, version change, timers, prices) are symbolic; the external
/// reads that produce them are covered by the unit and fuzz suites. Prices are bounded below `2^200`, timestamps to
/// `uint64`, windows to `uint32`, as stored.
contract LPOracleHalmosTest is Test {
    LPOracleDecisionHarness internal h;

    function setUp() public {
        h = new LPOracleDecisionHarness();
    }

    function _inputs(
        bool failed,
        bool disagreeing,
        bool versionChanged,
        uint64 failedSince,
        uint64 disagreeSince,
        uint32 cachedWindow,
        uint32 pauseMax,
        uint256 fresh,
        uint256 lower,
        uint256 accepted
    ) internal view returns (LPOracleDecisionHarness.Inputs memory x) {
        vm.assume(accepted >= 1 && accepted < 2 ** 200 && fresh < 2 ** 200 && lower < 2 ** 200);
        vm.assume(failedSince <= block.timestamp && disagreeSince <= block.timestamp);
        x.failed = failed;
        x.disagreeing = disagreeing;
        x.versionChanged = versionChanged;
        x.failedSince = failedSince;
        x.disagreeSince = disagreeSince;
        x.cachedWindow = cachedWindow;
        x.pauseMax = pauseMax;
        x.fresh = fresh;
        x.lower = lower;
        x.accepted = accepted;
        // Drifting causes are present whenever a token disagrees (bit 2).
        if (disagreeing) x.reasons = 1 << 2;
    }

    // PROP-074 verifies: SPEC-ORC-017, REQ-ORACLE-020, REQ-ORACLE-085, REQ-ORACLE-086, REQ-ORACLE-060, INV-087, INV-055, Q-247
    // Sources: MATH-UO-42, MATH-UO-59
    function check_PROP_074_servedByState(
        bool failed,
        bool disagreeing,
        uint256 fresh,
        uint256 lower,
        uint256 accepted,
        uint64 failedSince,
        uint32 cachedWindow
    ) public {
        LPOracleDecisionHarness.Inputs memory x =
            _inputs(failed, disagreeing, false, failedSince, 0, cachedWindow, 3600, fresh, lower, accepted);
        LPOracleDecisionHarness.Outcome memory e = h.decide(x);
        assertGe(e.served, 1, "served below 1");
        if (e.state == PriceState.Expired) assertEq(e.served, 1, "Expired did not serve 1");
        if (e.state == PriceState.Cached) assertEq(e.served, accepted, "Cached did not serve A");
        if (failed) assertTrue(e.state == PriceState.Cached || e.state == PriceState.Expired, "failed but not stale");
        if (!failed && fresh >= 1) assertLe(e.served, fresh, "served above the fresh price");
        // The accepted price bounds borrowing only (SPEC-ORC-017): Live and Drifting serve the fresh price.
        if (!failed && !disagreeing && (e.state == PriceState.Live || e.state == PriceState.Drifting)) {
            assertEq(e.served, fresh == 0 ? 1 : fresh, "Live or Drifting: fresh");
        }
    }

    // PROP-074 verifies: SPEC-ORC-017, INV-087
    // Sources: MATH-UO-42
    /// @dev A rally never lowers the served price: with the same state inputs, a higher fresh price (and the lower-route
    /// price that follows it) serves at least as much, whatever the accepted price.
    function check_PROP_074_rallyNeverLowersServed(
        bool disagreeing,
        uint256 fresh,
        uint256 rise,
        uint256 lower,
        uint256 accepted
    ) public {
        vm.assume(rise < 2 ** 199 && fresh < 2 ** 199);
        LPOracleDecisionHarness.Inputs memory x =
            _inputs(false, disagreeing, false, 0, 0, 3600, 3600, fresh, lower, accepted);
        uint256 before = h.decide(x).served;
        x.fresh = fresh + rise;
        x.lower = lower + rise;
        uint256 afterRally = h.decide(x).served;
        assertGe(afterRally, before, "a rally lowered the served price");
    }

    // PROP-074 verifies: SPEC-ORC-013, REQ-ORACLE-017, REQ-ORACLE-027, INV-031, Q-183
    // Sources: SIM-02D, QNT-22
    function check_PROP_074_failureStartAndExpiry(
        bool hasStale,
        uint64 staleStart,
        uint64 failedSince,
        uint32 cachedWindow
    ) public {
        LPOracleDecisionHarness.Inputs memory x =
            _inputs(true, false, false, failedSince, 0, cachedWindow, 3600, 0, 0, 1e8);
        x.hasStaleStart = hasStale;
        x.staleStart = staleStart;
        LPOracleDecisionHarness.Outcome memory e = h.decide(x);
        assertLe(e.failureStart, block.timestamp, "failure start after now");
        if (failedSince != 0) assertLe(e.failureStart, failedSince, "failure start after failedSince");
        if (hasStale) assertLe(e.failureStart, staleStart, "failure start after S_ts");
        bool cached = block.timestamp < uint256(e.failureStart) + cachedWindow;
        assertEq(e.state == PriceState.Cached, cached, "Cached exactly before failureStart + cachedWindow");
        assertEq(e.borrowMaxAge, 0);
        assertEq(e.liquidationMaxAge, 0);
        assertTrue(e.liquidationPaused);
    }

    // PROP-049 verifies: SPEC-ORC-016, REQ-ORACLE-022, REQ-ORACLE-084, REQ-ORACLE-095, INV-059, Q-162, Q-208, Q-248
    // Sources: HYP-56, QNT-22, SIM-01E
    function check_PROP_049_disagreementWindows(
        bool versionChanged,
        uint64 disagreeSince,
        uint32 pauseMax
    ) public {
        LPOracleDecisionHarness.Inputs memory x =
            _inputs(false, true, versionChanged, 0, disagreeSince, 3600, pauseMax, 1e8, 1e8, 1e8);
        LPOracleDecisionHarness.Outcome memory e = h.decide(x);
        assertTrue(e.pauseActive != e.disagreementExpired, "D implies exactly one of pause and expiry");
        assertTrue(e.liquidationPaused, "a disagreeing market's seizure waits");
        assertFalse(e.borrowAllowed);
        uint256 s = (!versionChanged && disagreeSince != 0) ? disagreeSince : block.timestamp;
        assertEq(e.pauseActive, block.timestamp < s + pauseMax, "pause measured from disagreeSince or now");
        if (versionChanged) assertEq(e.disagreeSince, 0, "a version change measures the new routes from now");
    }

    // PROP-049 verifies: REQ-ORACLE-028, REQ-ORACLE-095, REQ-ORACLE-027, INV-059, Q-199, Q-248
    // Sources: QNT-T18
    function check_PROP_049_disagreementStartSetOnce(
        bool failed,
        bool disagreeing,
        bool versionChanged,
        uint64 failedSince,
        uint64 disagreeSince
    ) public {
        LPOracleDecisionHarness.Inputs memory x =
            _inputs(failed, disagreeing, versionChanged, failedSince, disagreeSince, 3600, 3600, 1e8, 1e8, 1e8);
        (uint64 failedAfter, uint64 after_) = h.writeTimers(x);
        if (disagreeSince != 0 && after_ != disagreeSince) {
            assertTrue(after_ == 0 || (versionChanged && after_ == block.timestamp), "the stored start moved");
        }
        if (disagreeSince == 0 && after_ != 0) {
            assertEq(after_, block.timestamp, "a new start is the observation time");
        }
        if (failed && failedSince != 0) assertEq(failedAfter, failedSince, "the failure timer moved");
        if (!failed) assertEq(failedAfter, 0, "a market that is not failed keeps a failure timer");
    }

    // PROP-100 verifies: REQ-ORACLE-100, REQ-ORACLE-107, REQ-ORACLE-016, SPEC-ORC-020, Q-323
    // Sources: MATH-UO-72
    /// @notice The second-source result (market bit 16) and the age of the token-decimals verification are borrow-only
    /// gates: two evaluations that differ only in them have the same state, served price, `liquidationPaused`, age
    /// limits and failure start, and `borrowAllowed` implies Live, bit 16 clear and a verification within 7,200 s.
    function check_PROP_100_borrowOnlyGates(
        bool failed,
        bool disagreeing,
        bool unconfirmed,
        uint64 checkedA,
        uint64 checkedB,
        uint256 fresh,
        uint256 accepted,
        uint64 failedSince
    ) public {
        vm.assume(checkedA <= block.timestamp && checkedB <= block.timestamp);
        LPOracleDecisionHarness.Inputs memory x =
            _inputs(failed, disagreeing, false, failedSince, 0, 3600, 3600, fresh, fresh, accepted);
        x.decimalsCheckedAt = checkedA;
        LPOracleDecisionHarness.Outcome memory a = h.decide(x);
        x.decimalsCheckedAt = checkedB;
        if (unconfirmed) x.reasons |= uint256(1) << 16;
        LPOracleDecisionHarness.Outcome memory b = h.decide(x);
        assertEq(uint8(a.state), uint8(b.state), "state");
        assertEq(a.served, b.served, "served price");
        assertEq(a.liquidationPaused, b.liquidationPaused, "liquidationPaused");
        assertEq(a.failureStart, b.failureStart, "failure start");
        assertEq(a.borrowMaxAge, b.borrowMaxAge, "borrow age");
        assertEq(a.liquidationMaxAge, b.liquidationMaxAge, "liquidation age");
        if (b.borrowAllowed) {
            assertEq(uint8(b.state), uint8(PriceState.Live), "borrowAllowed only when Live");
            assertFalse(unconfirmed, "borrowAllowed with an unconfirmed token");
            assertLe(block.timestamp - checkedB, 7200, "borrowAllowed with an old verification");
        }
        if (block.timestamp - checkedB > 7200) assertTrue(b.reasons & (uint256(1) << 19) != 0, "bit 19");
    }
}
