// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPOracleCLModuleLogic} from "../../src/oracle/lp-oracle/LPOracleCLModuleLogic.sol";
import {LPOracleCLPokeLogic} from "../../src/oracle/lp-oracle/LPOracleCLPokeLogic.sol";
import {Evaluation, LegEval, TokenEval} from "../../src/oracle/lp-oracle/LPOracleTypes.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Exposes the state decision of the deployed concentrated-liquidity poke logic, `LPOracleCLPokeLogic` (the
/// contract `LPOracleCL` delegates `poke()` to), on symbolic evaluation inputs. It adds only a loader and a getter;
/// the decision is the production code.
contract LPOracleCLDecisionExposer is LPOracleCLPokeLogic {
    struct Inputs {
        bool failed;
        bool disagreeing;
        uint64 failedSince;
        uint32 cachedWindow;
        uint32 pauseMax;
        uint256 reasons;
        uint256 fresh;
        uint256 accepted;
        uint64 decimalsCheckedAt;
    }

    struct Outcome {
        PriceState state;
        uint256 served;
        uint64 failureStart;
        bool liquidationPaused;
        bool borrowAllowed;
        uint32 borrowMaxAge;
        uint32 liquidationMaxAge;
        uint256 reasons;
    }

    constructor(
        address moduleLogic
    ) LPOracleCLPokeLogic(address(0x7173), 12, 900_000, 3_000_000, false, 7, moduleLogic) {}

    function _load(
        Inputs memory x
    ) internal returns (Evaluation memory e) {
        Layout storage $ = _s();
        $.failedSince = x.failedSince;
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
        e.reasons = x.reasons;
        e.fresh = x.fresh;
        e.lower = x.fresh;
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
        o.liquidationPaused = e.liquidationPaused;
        o.borrowAllowed = e.borrowAllowed;
        o.borrowMaxAge = e.borrowMaxAge;
        o.liquidationMaxAge = e.liquidationMaxAge;
        o.reasons = e.reasons;
    }
}

/// @title LPOracleCLGatesHalmosTest
/// @notice Symbolic check of the borrow-only gates of the deployed concentrated-liquidity poke logic (2.10
/// `REQ-ORACLE-100`, `REQ-ORACLE-107`): the second-source result and the age of the token-decimals verification move
/// nothing but `borrowAllowed`.
/// @dev The evaluation's inputs (failure, disagreement, timers, prices) are symbolic as in `PROP-074`; the external
/// reads that produce them are covered by the unit and fuzz suites on the real oracle. Prices are bounded below
/// `2^200`, timestamps to `uint64`, windows to `uint32`, as stored.
contract LPOracleCLGatesHalmosTest is Test {
    LPOracleCLDecisionExposer internal h;

    function setUp() public {
        address m = address(new LPOracleCLModuleLogic(address(0x7173), 12, 900_000, 3_000_000, false, 7));
        h = new LPOracleCLDecisionExposer(m);
    }

    // PROP-100 verifies: REQ-ORACLE-100, REQ-ORACLE-107, REQ-ORACLE-016, SPEC-ORC-020, Q-323
    // Sources: MATH-UO-72
    /// @notice Two evaluations that differ only in the second-source result (market bit 16) and the time of the
    /// token-decimals verification have the same state, served price, `liquidationPaused`, age limits and failure
    /// start; `borrowAllowed` implies Live, bit 16 clear and a verification within 7,200 s; an older verification sets
    /// bit 19.
    function check_PROP_100_borrowOnlyGates(
        bool failed,
        bool disagreeing,
        bool unconfirmed,
        uint64 checkedA,
        uint64 checkedB,
        uint256 fresh,
        uint256 accepted,
        uint64 failedSince,
        uint32 cachedWindow
    ) public {
        vm.assume(checkedA <= block.timestamp && checkedB <= block.timestamp);
        vm.assume(accepted >= 1 && accepted < 2 ** 200 && fresh < 2 ** 200);
        vm.assume(failedSince <= block.timestamp);
        LPOracleCLDecisionExposer.Inputs memory x;
        x.failed = failed;
        x.disagreeing = disagreeing;
        x.failedSince = failedSince;
        x.cachedWindow = cachedWindow;
        x.pauseMax = 3600;
        x.fresh = fresh;
        x.accepted = accepted;
        // Drifting causes are present whenever a token disagrees (bit 2).
        if (disagreeing) x.reasons = 1 << 2;
        x.decimalsCheckedAt = checkedA;
        LPOracleCLDecisionExposer.Outcome memory a = h.decide(x);
        x.decimalsCheckedAt = checkedB;
        if (unconfirmed) x.reasons |= uint256(1) << 16;
        LPOracleCLDecisionExposer.Outcome memory b = h.decide(x);
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
