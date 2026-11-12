// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {FeedDef} from "../../src/policy/parameter-store/types/FeedDef.sol";
import {OracleConfig} from "../../src/types/OracleConfig.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {SecondSourceKind} from "../../src/types/SecondSourceKind.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";
import {ReadMode} from "../utils/mocks/LPOracleMocks.sol";

/// @notice Per-feed age limits, second sources, the sequencer gate and the alternate held to its borrow age.
contract LPOracleBorrowGatesUnitTest is LPOracleFixture {
    function setUp() public {
        _deployMarket(true);
    }

    function _sequencerUp(
        uint256 startedAt
    ) internal {
        seqFeed.setRound(1, 0, startedAt, startedAt);
    }

    // TEST-276 verifies: REQ-ORACLE-100, SPEC-ORC-020, SPEC-ORC-019, REQ-ORACLE-054, ATTACK-044, ATTACK-056, Q-322, Q-323
    // Sources: 5.1 TEST-276, MATH-UO-22, SIM-02C
    function test_TEST_276_secondSourceGatesBorrowOnly() public {
        _sequencerUp(T0 - 7200);
        vm.warp(T0 + 60);
        PriceStateView memory v = _state();
        assertTrue(v.borrowAllowed, "Live, sequencer ready, both confirmed, within borrow age");
        // Token A's second source reads 98.9 cents against a quote of 1.00 with S = 100 bps: not confirmed.
        sA.push(98_900_000, T0 + 60);
        v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Live), "the second source never changes the state");
        assertFalse(v.borrowAllowed);
        assertTrue(_has(v.reasons, 16), "SECOND_SOURCE_DISAGREE");
        assertTrue(v.tokens[0].reasons & (1 << 4) != 0, "token SECOND_SOURCE_DISAGREE");
        assertFalse(v.liquidationPaused, "never gates liquidation");
        // 99.4 cents is within 100 bps.
        sA.push(99_400_000, T0 + 60);
        assertTrue(_state().borrowAllowed);
        // A stale second source is unavailable.
        sA.setMode(sA.latestRoundData.selector, ReadMode.Revert);
        v = _state();
        assertFalse(v.borrowAllowed);
        assertTrue(v.tokens[0].reasons & (1 << 5) != 0, "SECOND_SOURCE_UNAVAILABLE");
    }

    // TEST-276 verifies: REQ-ORACLE-100, SPEC-ORC-020, Q-323, Q-385
    function test_TEST_276_poolTwapSecondSource() public {
        _sequencerUp(T0 - 7200);
        OracleConfig memory c = _config();
        c.tokens[1].secondSource.kind = SecondSourceKind.PoolTwap;
        c.tokens[1].secondSource.twapWindow = 1800;
        store.setConfig(c);
        assertFalse(_state().borrowAllowed, "no TWAP value: unavailable");
        oracle.setTwapValue(1, 99_950_000);
        assertTrue(_state().borrowAllowed, "the standby or recorded TWAP source confirms");
    }

    // TEST-250 verifies: SPEC-ORC-019, SPEC-ORC-015, REQ-ORACLE-043, REQ-ORACLE-100, Q-182, Q-274, Q-322
    // Sources: 5.1 TEST-250
    function test_TEST_250_borrowAgeAtHeartbeatPlusMargin() public {
        _sequencerUp(T0 - 7200);
        vm.warp(T0 + MAX_AGE);
        // A borrow pokes first (REQ-ORACLE-036), which also verifies the token decimals (REQ-ORACLE-107).
        oracle.poke();
        PriceStateView memory v = _state();
        assertEq(v.borrowPriceMaxAge, MAX_AGE);
        assertEq(v.liquidationPriceMaxAge, MAX_AGE);
        assertTrue(v.borrowAllowed, "age 88,200 passes");
        vm.warp(T0 + MAX_AGE + 1);
        assertFalse(_state().borrowAllowed, "age 88,201 is refused");
    }

    // TEST-250 verifies: REQ-ORACLE-090, SPEC-ORC-015, SPEC-ORC-016, ATTACK-044, Q-274
    function test_TEST_250_alternateHeldToItsBorrowAge() public {
        _sequencerUp(T0 - 7200);
        // Governance lowers token B alternate's borrow age to 21,600; the primary goes stale.
        FeedDef memory d = store.getFeed(address(aB));
        d.borrowPriceMaxAge = 21_600;
        store.setFeed(address(aB), d);
        pB.setMode(pB.latestRoundData.selector, ReadMode.Revert);
        vm.warp(T0 + 21_600);
        PriceStateView memory v = _state();
        assertEq(v.liquidationPriceMaxAge, 21_600, "liquidation limit min(liquidation, borrow) on the alternate");
        assertFalse(v.liquidationPaused);
        vm.warp(T0 + 21_601);
        v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Live), "state and price unchanged");
        assertTrue(v.liquidationPaused, "ALTERNATE_PAST_BORROW_AGE");
        assertTrue(_has(v.reasons, 12));
    }

    // TEST-276 verifies: REQ-ORACLE-099, SPEC-ORC-021, ATTACK-171, Q-324
    function test_TEST_276_sequencerGate() public {
        // Down: seizure paused and borrowing blocked; the state and price are unchanged.
        seqFeed.setRound(1, 1, T0, T0);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Live));
        assertTrue(v.liquidationPaused);
        assertFalse(v.borrowAllowed);
        assertTrue(_has(v.reasons, 14), "SEQUENCER_DOWN");
        // Restart: grace for 3,600 s, borrowing closed, inGrace true.
        vm.warp(T0 + 100);
        _sequencerUp(T0 + 100);
        v = _state();
        assertTrue(v.inGrace);
        assertTrue(_has(v.reasons, 15), "SEQUENCER_GRACE");
        assertEq(v.graceEndsAt, T0 + 100 + 3600);
        assertFalse(v.borrowAllowed);
        assertFalse(v.liquidationPaused);
        vm.warp(T0 + 3700);
        v = _state();
        assertTrue(v.sequencerReady);
        assertFalse(v.borrowAllowed, "every leg's round is from before the restart");
        _pushAll(int256(ONE), T0 + 3700);
        assertTrue(_state().borrowAllowed, "rounds newer than the restart");
        // Unreadable: borrowing blocked, liquidation not paused.
        seqFeed.setMode(seqFeed.latestRoundData.selector, ReadMode.Revert);
        v = _state();
        assertFalse(v.borrowAllowed);
        assertFalse(v.liquidationPaused);
        assertTrue(_has(v.reasons, 14));
    }

    /// @notice Base, restart at `T0 + 100` with a 3,600 s grace period: past the grace period, a served price whose
    /// oldest leg round is from before the restart, or from the restart second itself, never admits a borrow, while
    /// the state stays Live and liquidation is not paused; once every leg in use has a round newer than the restart,
    /// borrowing reopens. One token's stale leg is enough to refuse: `servedUpdatedAt` is the oldest leg in use.
    // TEST-276 verifies: REQ-ORACLE-099, REQ-ORACLE-100, SPEC-ORC-021, ATTACK-171
    // Sources: SPEC-ORC-021 example (restart, grace, borrowing reopens on a round newer than the restart)
    function test_TEST_276_sequencerRestartNeedsNewerRound() public {
        uint256 restart = T0 + 100;
        vm.warp(restart);
        _sequencerUp(restart);
        vm.warp(restart + 3600);
        PriceStateView memory v = _state();
        assertTrue(v.sequencerReady, "grace period over");
        assertFalse(v.inGrace);
        assertEq(uint8(v.state), uint8(PriceState.Live));
        assertFalse(v.borrowAllowed, "rounds from T0, before the restart");
        assertFalse(v.liquidationPaused, "liquidation runs on the same price");
        _pushAll(int256(ONE), restart);
        assertFalse(_state().borrowAllowed, "a round at the restart second is not newer");
        _pushAll(int256(ONE), restart + 1);
        pB.push(int256(ONE), restart - 1);
        v = _state();
        assertFalse(v.borrowAllowed, "token B's primary is from before the restart");
        assertFalse(v.liquidationPaused);
        pB.push(int256(ONE), restart + 1);
        assertTrue(_state().borrowAllowed, "every leg newer than the restart");
    }

    /// @notice For every restart time, time past the grace period and leg round time: borrowing is allowed exactly when
    /// the rounds are newer than the restart, and liquidation is never paused by the rule.
    // TEST-276 verifies: REQ-ORACLE-099, SPEC-ORC-021
    function testFuzz_TEST_276_borrowOnlyOnRoundsAfterRestart(
        uint256 restartOffset,
        uint256 extra,
        uint256 legAt
    ) public {
        // Within the 7,200 s token-decimals verification of initialize, so no other borrow gate closes.
        uint256 restart = T0 + bound(restartOffset, 1, 1800);
        uint256 nowTs = restart + 3600 + bound(extra, 0, 1700);
        legAt = bound(legAt, T0 + 1, nowTs);
        vm.warp(restart);
        _sequencerUp(restart);
        vm.warp(nowTs);
        _pushAll(int256(ONE), legAt);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Live));
        assertEq(v.borrowAllowed, legAt > restart, "borrow iff rounds newer than the restart");
        assertFalse(v.liquidationPaused);
    }
}

/// @notice Ethereum has no sequencer feed: the restart rule does not exist and a round of any age within the borrow
/// limit admits a borrow, as before.
contract LPOracleBorrowGatesEthereumUnitTest is LPOracleFixture {
    function setUp() public {
        _deployMarket(false);
    }

    // TEST-276 verifies: REQ-ORACLE-099, SPEC-ORC-021
    function test_TEST_276_noSequencerNoRestartRule() public {
        vm.warp(T0 + 3700);
        PriceStateView memory v = _state();
        assertTrue(v.sequencerReady, "no feed: ready");
        assertTrue(v.borrowAllowed, "rounds from T0 admit a borrow");
    }
}
