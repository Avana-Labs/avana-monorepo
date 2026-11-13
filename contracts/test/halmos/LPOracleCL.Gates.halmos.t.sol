// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPOracleCLModuleLogic} from "../../src/oracle/lp-oracle/LPOracleCLModuleLogic.sol";
import {LPOracleCLPokeLogic} from "../../src/oracle/lp-oracle/LPOracleCLPokeLogic.sol";
import {Evaluation, LegEval, TokenEval} from "../../src/oracle/lp-oracle/LPOracleTypes.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Exposes the state decision of the deployed concentrated-liquidity poke logic, `LPOracleCLPokeLogic` (the
/// contract `LPOracleCL` delegates `poke()` to), on symbolic evaluation inputs. It adds one entry point that loads the
/// inputs and returns the outcome; the decision is the production code.
/// @dev The outcome is returned in three words with every field kept whole, so the exposer stays within EIP-170 on
/// top of the poke logic it extends: `served`; `timers = failureStart << 64 | borrowMaxAge << 32 |
/// liquidationMaxAge`; `flags = state | liquidationPaused << 8 | borrowAllowed << 9 | decimalsUnverified << 10`.
contract LPOracleCLDecisionExposer is LPOracleCLPokeLogic {
    constructor(
        address moduleLogic
    ) LPOracleCLPokeLogic(address(0x7173), 12, 900_000, 3_000_000, false, 7, moduleLogic) {}

    /// @notice One token quoted on a one-leg primary read now (age limits 88,200 s, so `borrowAllowed` can hold), no
    /// accepted price in this block (the quote-change cap never applies), `disagreementPauseMax = 3,600` and a chain
    /// without a sequencer feed (ready, `SPEC-ORC-021`). `w` holds, in order: failed (0 or 1), disagreeing (0 or 1),
    /// `failedSince`, `cachedWindow`, the reason bits, the fresh price, the accepted price (positive, below `2^200`) and
    /// the token-decimals verification time; the caller keeps each within its stored type.
    function decide(
        uint256[8] calldata w
    ) external returns (uint256 served, uint256 timers, uint256 flags) {
        Layout storage $ = _s();
        // Each word is within its stored type (see @notice).
        // forge-lint: disable-next-line(unsafe-typecast)
        $.failedSince = uint64(w[2]);
        // forge-lint: disable-next-line(unsafe-typecast)
        $.accepted.answer = int256(w[6]);
        $.acceptedBlock = type(uint64).max;
        Evaluation memory e;
        e.tokens = new TokenEval[](1);
        TokenEval memory t = e.tokens[0];
        (t.used, t.chosen, t.chosenAt) = (1, 1, uint64(block.timestamp));
        t.routes[0].legCount = 1;
        LegEval memory leg = t.routes[0].legs[0];
        (leg.updatedAt, leg.borrowAge, leg.liquidationAge) = (uint64(block.timestamp), 88_200, 88_200);
        e.cfg.ok = true;
        // forge-lint: disable-next-line(unsafe-typecast)
        (e.cfg.cachedWindow, e.cfg.disagreementPauseMax) = (uint32(w[3]), 3600);
        (e.failed, e.disagreeing) = (w[0] != 0, w[1] != 0 && w[0] == 0);
        // forge-lint: disable-next-line(unsafe-typecast)
        (e.reasons, e.fresh, e.lower, e.decimalsCheckedAt) = (w[4], w[5], w[5], uint64(w[7]));
        e.seq.ready = true;
        _decide(e);
        served = e.served;
        timers = uint256(e.failureStart) << 64 | uint256(e.borrowMaxAge) << 32 | e.liquidationMaxAge;
        flags = uint256(uint8(e.state)) | (e.liquidationPaused ? 1 << 8 : 0) | (e.borrowAllowed ? 1 << 9 : 0)
            | (e.reasons & (1 << 19) != 0 ? 1 << 10 : 0);
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
    uint256 internal constant STATE_MASK = 0xff;
    uint256 internal constant LIQUIDATION_PAUSED = 1 << 8;
    uint256 internal constant BORROW_ALLOWED = 1 << 9;
    uint256 internal constant DECIMALS_UNVERIFIED = 1 << 10;

    /// @dev The symbolic inputs both evaluations share.
    struct Inputs {
        bool failed;
        bool disagreeing;
        uint64 failedSince;
        uint32 cachedWindow;
        uint256 fresh;
        uint256 accepted;
    }

    LPOracleCLDecisionExposer internal h;

    function setUp() public {
        address m = address(new LPOracleCLModuleLogic(address(0x7173), 12, 900_000, 3_000_000, false, 7));
        h = new LPOracleCLDecisionExposer(m);
    }

    /// @dev The exposer's three outcome words (served, timers, flags) for `x` with `reasons` and a token-decimals
    /// verification at `checked`.
    function _run(
        Inputs memory x,
        uint256 reasons,
        uint64 checked
    ) internal returns (uint256[3] memory o) {
        uint256[8] memory w = [
            x.failed ? 1 : 0,
            x.disagreeing ? 1 : 0,
            uint256(x.failedSince),
            uint256(x.cachedWindow),
            reasons,
            x.fresh,
            x.accepted,
            uint256(checked)
        ];
        (o[0], o[1], o[2]) = h.decide(w);
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
        Inputs memory x = Inputs(failed, disagreeing, failedSince, cachedWindow, fresh, accepted);
        // Drifting causes are present whenever a token disagrees (bit 2).
        uint256 reasons = disagreeing ? 1 << 2 : 0;
        uint256[3] memory a = _run(x, reasons, checkedA);
        if (unconfirmed) reasons |= uint256(1) << 16;
        uint256[3] memory o = _run(x, reasons, checkedB);
        uint256 flagsB = o[2];
        assertEq(a[2] & STATE_MASK, flagsB & STATE_MASK, "state");
        assertEq(a[0], o[0], "served price");
        assertEq(a[2] & LIQUIDATION_PAUSED, flagsB & LIQUIDATION_PAUSED, "liquidationPaused");
        assertEq(a[1] >> 64, o[1] >> 64, "failure start");
        assertEq(uint32(a[1] >> 32), uint32(o[1] >> 32), "borrow age");
        assertEq(uint32(a[1]), uint32(o[1]), "liquidation age");
        if (flagsB & BORROW_ALLOWED != 0) {
            assertEq(flagsB & STATE_MASK, uint256(PriceState.Live), "borrowAllowed only when Live");
            assertFalse(unconfirmed, "borrowAllowed with an unconfirmed token");
            assertLe(block.timestamp - checkedB, 7200, "borrowAllowed with an old verification");
        }
        if (block.timestamp - checkedB > 7200) assertTrue(flagsB & DECIMALS_UNVERIFIED != 0, "bit 19");
    }
}
