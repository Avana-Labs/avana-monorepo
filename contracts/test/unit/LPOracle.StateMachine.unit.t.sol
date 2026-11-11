// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {InitParams} from "../../src/oracle/lp-oracle/types/InitParams.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";
import {LPOracleHarness, LPOracleHarnessDeployer} from "../utils/harness/LPOracleHarness.sol";
import {ReadMode} from "../utils/mocks/LPOracleMocks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice The Live / Drifting / Cached / Expired state machine of the LPOracle base (2.10 Price states): one state per
/// read, recomputed from current data and the stored timers with no hysteresis; the precedence of a failure over the
/// Drifting causes; `poke()` evaluating with the code of `getPriceState()`; the stable flags fixed at listing; and the
/// stored state an upgrade keeps.
/// forge-config: default.isolate = false
contract LPOracleStateMachineUnitTest is LPOracleFixture {
    uint256 internal constant T1 = T0 + 60;
    uint256 internal constant FAILED_MASK =
        (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5) | (1 << 6) | (1 << 11) | (1 << 12) | (1 << 16);

    function setUp() public {
        _deployMarket();
        vm.warp(T1);
        vm.roll(block.number + 1);
        _pushAll(int256(ONE), T1);
    }

    /// @dev Price8 of the fixture's composition at per-token valuation prices `v0`, `v1` (one raw unit less than a
    /// whole 6-decimal token of each, `SPEC-ORC-008`).
    function _price8(
        uint256 v0,
        uint256 v1
    ) internal pure returns (uint256) {
        return (999_999 * v0) / 1e6 + (999_999 * v1) / 1e6;
    }

    function _stateOf() internal view returns (PriceState) {
        return _state().state;
    }

    // ─── One state per read, no hysteresis ───

    // TEST-039 verifies: REQ-ORACLE-016, REQ-ORACLE-018, REQ-ORACLE-015, REQ-ORACLE-017, SPEC-ORC-013
    /// @notice Without any write, each read reports the state of its own data: a band breach is Drifting and its end
    /// is Live again at once; two stale routes are Cached and, from source timestamps alone, Expired at `staleAt +
    /// cachedWindow`; a fresh round is Live again at the next read.
    function test_TEST_039_stateRecomputedOnEveryRead() public {
        assertEq(uint8(_stateOf()), uint8(PriceState.Live));
        _pushAll(89_000_000, T1);
        assertEq(uint8(_stateOf()), uint8(PriceState.Drifting), "below the band");
        _pushAll(int256(ONE), T1);
        assertEq(uint8(_stateOf()), uint8(PriceState.Live), "back in band: Live with no write");
        uint256 staleAt = T1 + MAX_AGE + 1;
        vm.warp(staleAt);
        pB.push(int256(ONE), staleAt);
        aB.push(int256(ONE), staleAt);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Cached), "both of token A's routes stale");
        assertEq(v.failureStart, staleAt, "failure starts at staleAt");
        vm.warp(staleAt + 3599);
        assertEq(uint8(_stateOf()), uint8(PriceState.Cached));
        vm.warp(staleAt + 3600);
        assertEq(uint8(_stateOf()), uint8(PriceState.Expired), "Expired with no poke");
        assertEq(oracle.latestAnswer(), 1);
        pA.push(int256(ONE), staleAt + 3600);
        assertEq(uint8(_stateOf()), uint8(PriceState.Live), "a fresh round: Live at the next read");
        (uint64 failedSince,,,) = oracle.storedTimers();
        assertEq(failedSince, 0, "views write nothing");
    }

    // TEST-040 verifies: SPEC-ORC-013, REQ-ORACLE-017, REQ-ORACLE-027
    /// @notice With both routes of both tokens stale, `S_ts` is the earliest `staleAt` over the tokens, whatever their
    /// pool order: token B, last updated at `T0 + 10`, fails before token A, so the failure starts at token B's
    /// `staleAt`, the poke stores it, and Expired comes `cachedWindow` after it.
    function test_TEST_040_failureStartsAtTheEarliestStaleToken() public {
        pB.push(int256(ONE), T0 + 10);
        aB.push(int256(ONE), T0 + 10);
        uint256 staleA = T1 + MAX_AGE + 1;
        uint256 staleB = T0 + 10 + MAX_AGE + 1;
        vm.warp(staleA + 100);
        vm.roll(block.number + 1);
        PriceStateView memory v = _state();
        assertEq(v.failureStart, staleB, "the earlier token's staleAt");
        assertTrue(_has(v.reasons, 8), "SOURCE_TIMESTAMP_FAILURE");
        oracle.poke();
        (uint64 failedSince,,,) = oracle.storedTimers();
        assertEq(failedSince, staleB, "the stored start is S_ts, not now");
        vm.warp(staleB + 3599);
        assertEq(uint8(_stateOf()), uint8(PriceState.Cached));
        vm.warp(staleB + 3600);
        assertEq(uint8(_stateOf()), uint8(PriceState.Expired));
    }

    // TEST-039 verifies: REQ-ORACLE-016, REQ-ORACLE-017, REQ-ORACLE-018
    /// @notice A failed market is Cached or Expired whatever else holds: with token A on no route, token B's routes
    /// disagreeing and the quotes below the band, the market is Cached, and bits 2 to 6, 11, 12 and 16 are 0.
    function test_TEST_039_failureTakesPrecedenceOverDrifting() public {
        pA.setMode(pA.latestRoundData.selector, ReadMode.Revert);
        aA.setMode(aA.latestRoundData.selector, ReadMode.Revert);
        pB.push(89_000_000, T1);
        aB.push(85_000_000, T1);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Cached));
        assertTrue(_has(v.reasons, 0), "ANY_TOKEN_NO_ROUTE");
        assertEq(v.reasons & FAILED_MASK, 0, "Drifting and pause bits are not evaluated when failed");
        assertFalse(v.disagreementPauseActive);
        assertEq(v.freshAnswer, 0);
        assertEq(v.usdLevel, 0);
        assertEq(v.consistencyDeviationBps, type(uint256).max);
        assertTrue(v.liquidationPaused);
        assertFalse(v.borrowAllowed);
    }

    // TEST-039 verifies: REQ-ORACLE-016, REQ-ORACLE-020, SPEC-ORC-017, REQ-ORACLE-085
    /// @notice Severity follows the enum order `Live (0) < Drifting (1) < Cached (2) < Expired (3)`, and each state's
    /// served price is at most the one of every less severe state for the same data: fresh, then at most the
    /// accepted price, then the accepted price, then 1.
    function test_TEST_039_severityOrderAndServedPrice() public {
        assertEq(uint8(PriceState.Live), 0);
        assertEq(uint8(PriceState.Drifting), 1);
        assertEq(uint8(PriceState.Cached), 2);
        assertEq(uint8(PriceState.Expired), 3);
        _pushAll(99_500_000, T1);
        oracle.poke();
        (uint256 accepted,) = oracle.lastAcceptedPrice();
        assertEq(uint256(oracle.latestAnswer()), accepted, "Live serves the fresh price, here the accepted one");
        // Next block: the quotes are back at $1.00 but the consistency check fails, so the market is Drifting with a
        // fresh price above the accepted one.
        vm.roll(block.number + 1);
        _pushAll(int256(ONE), T1);
        oracle.setConsistency(false, true, 80, false);
        PriceStateView memory d = _state();
        assertEq(uint8(d.state), uint8(PriceState.Drifting), "consistency check fails");
        assertGt(uint256(d.freshAnswer), accepted);
        assertEq(uint256(d.answer), accepted, "Drifting serves min(fresh, accepted)");
        pB.setMode(pB.latestRoundData.selector, ReadMode.Revert);
        aB.setMode(aB.latestRoundData.selector, ReadMode.Revert);
        assertEq(uint256(oracle.latestAnswer()), accepted, "Cached serves the accepted price");
        oracle.poke();
        vm.warp(T1 + 3600);
        pA.push(int256(ONE), T1 + 3600);
        aA.push(int256(ONE), T1 + 3600);
        assertEq(uint8(_stateOf()), uint8(PriceState.Expired));
        assertEq(oracle.latestAnswer(), 1, "Expired serves 1");
    }

    // ─── poke uses the code of getPriceState ───

    /// @dev `getPriceState().state` then `poke()` from the same snapshot.
    function _assertPokeMatchesReport(
        string memory label
    ) internal {
        uint256 snap = vm.snapshotState();
        PriceStateView memory v = _state();
        PriceState poked = oracle.poke();
        assertEq(uint8(poked), uint8(v.state), label);
        PriceStateView memory after_ = _state();
        assertEq(uint8(after_.state), uint8(v.state), "the stored timers keep the state");
        assertEq(after_.answer, oracle.latestAnswer(), "answer == latestAnswer() after the poke");
        vm.revertToState(snap);
    }

    // TEST-042 verifies: REQ-ORACLE-026, REQ-ORACLE-042, REQ-ORACLE-016
    /// @notice In every state `poke()` returns the state `getPriceState()` reports in the same block (the token
    /// decimals unchanged), and the report after the poke is the same state.
    function test_TEST_042_pokeReturnsTheReportedState() public {
        _assertPokeMatchesReport("Live");
        aA.push(97_000_000, T1);
        _assertPokeMatchesReport("Drifting by disagreement");
        aA.push(int256(ONE), T1);
        _pushAll(89_000_000, T1);
        _assertPokeMatchesReport("Drifting by the band");
        _pushAll(int256(ONE), T1);
        oracle.setConsistency(true, false, 0, false);
        _assertPokeMatchesReport("Drifting by an unavailable consistency check");
        oracle.setConsistency(false, false, 0, false);
        oracle.setLock(false, true);
        _assertPokeMatchesReport("Cached by the pool lock");
        oracle.setLock(false, false);
        oracle.poke();
        _pushAll(98_000_000, T1);
        _assertPokeMatchesReport("Cached by the quote-change cap");
        uint256 staleAt = T1 + MAX_AGE + 1;
        vm.warp(staleAt + 3600);
        vm.roll(block.number + 1);
        pB.push(int256(ONE), staleAt + 3600);
        aB.push(int256(ONE), staleAt + 3600);
        _assertPokeMatchesReport("Expired from source timestamps");
    }

    // TEST-062 verifies: REQ-ORACLE-082, REQ-ORACLE-024
    /// @notice The `poke()` selector, its empty argument list and its `PriceState` return are the ones the immutable
    /// Collateralization calls for life, and `getPriceState()` keeps its selector.
    function test_TEST_062_pokeAndReportSelectorsAreStable() public {
        assertEq(ILPOracle.poke.selector, bytes4(keccak256("poke()")));
        assertEq(ILPOracle.getPriceState.selector, bytes4(keccak256("getPriceState()")));
        assertEq(ILPOracle.latestAnswer.selector, bytes4(keccak256("latestAnswer()")));
        (bool ok, bytes memory ret) = address(oracle).call(abi.encodeWithSignature("poke()"));
        assertTrue(ok);
        assertEq(ret.length, 32, "one word: the PriceState");
        assertEq(abi.decode(ret, (uint256)), uint256(PriceState.Live));
    }

    // ─── Upgrade keeps the address and the stored state ───

    // TEST-062 verifies: REQ-ORACLE-101, REQ-ORACLE-080, REQ-ORACLE-081, REQ-ORACLE-078, REQ-ORACLE-107
    /// @notice An upgrade through the timelock keeps the proxy address (the Aave price source for life) and every
    /// stored value: the accepted price, the failure timer, the checkpoint, the route versions and the token-decimals
    /// result; `decimals()` stays 8 and the served price at least 1.
    function test_TEST_062_upgradeKeepsAddressAndStoredState() public {
        oracle.poke();
        pB.setMode(pB.latestRoundData.selector, ReadMode.Revert);
        aB.setMode(aB.latestRoundData.selector, ReadMode.Revert);
        vm.warp(T1 + 100);
        vm.roll(block.number + 1);
        oracle.poke();
        address before = address(oracle);
        (uint256 accepted, uint64 acceptedAt) = oracle.lastAcceptedPrice();
        (uint64 failedSince,,,) = oracle.storedTimers();
        (uint256 cp, uint64 cpAt) = oracle.priceCheckpoint();
        (bool invalid, uint64 verifiedAt) = oracle.decimalsStatus();
        LPOracleHarness next = LPOracleHarnessDeployer.deploy(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false);
        vm.prank(tl);
        oracle.upgradeToAndCall(address(next), "");
        assertEq(address(oracle), before, "same proxy address");
        (uint256 a2, uint64 at2) = oracle.lastAcceptedPrice();
        assertEq(a2, accepted);
        assertEq(at2, acceptedAt);
        (uint64 f2,,,) = oracle.storedTimers();
        assertEq(f2, failedSince, "failure timer kept");
        assertEq(f2, T1 + 100);
        (uint256 cp2, uint64 cpAt2) = oracle.priceCheckpoint();
        assertEq(cp2, cp);
        assertEq(cpAt2, cpAt);
        (bool invalid2, uint64 verifiedAt2) = oracle.decimalsStatus();
        assertEq(invalid2, invalid);
        assertEq(verifiedAt2, verifiedAt);
        assertEq(oracle.decimals(), 8);
        assertGe(oracle.latestAnswer(), 1);
        assertEq(uint8(_stateOf()), uint8(PriceState.Cached), "the new implementation reads the same timers");
    }

    // ─── Stable flags fixed at listing ───

    // TEST-036 verifies: REQ-ORACLE-010, SPEC-ORC-004, REQ-ORACLE-009, REQ-ORACLE-056
    /// @notice The stable ceiling applies only to the tokens flagged USD-stable at `initialize`: with token B not
    /// flagged, token A at $1.05 is valued at $1.00 and token B at $1.01 at $1.01; the quotes stay uncapped.
    function test_TEST_036_stableFlagsFixedAtListing() public {
        InitParams memory p = _params();
        p.isUsdStable[1] = false;
        // A market with a token that is not a USD stable has no USD band (REQ-ORACLE-056).
        p.config.usdBandLow = 0;
        p.config.usdBandHigh = type(uint256).max;
        store.setConfig(p.config);
        LPOracleHarness impl = LPOracleHarnessDeployer.deploy(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false);
        _pushAll(int256(ONE), T1);
        LPOracleHarness other =
            LPOracleHarness(address(new ERC1967Proxy(address(impl), abi.encodeCall(ILPOracle.initialize, (p)))));
        pA.push(105_000_000, T1);
        aA.push(105_000_000, T1);
        sA.push(105_000_000, T1);
        pB.push(101_000_000, T1);
        aB.push(101_000_000, T1);
        sB.push(101_000_000, T1);
        PriceStateView memory v = other.getPriceState();
        assertEq(v.tokens[0].quote, 105_000_000, "uncapped quote");
        assertEq(v.tokens[0].valuationPrice, 100_000_000, "flagged: capped at the ceiling");
        assertEq(v.tokens[1].valuationPrice, 101_000_000, "not flagged: not capped");
        assertEq(uint256(v.freshAnswer), _price8(100_000_000, 101_000_000));
        PriceStateView memory both = _state();
        assertEq(both.tokens[1].valuationPrice, 100_000_000, "the fixture flags both tokens");
        assertEq(uint256(both.freshAnswer), _price8(100_000_000, 100_000_000));
    }

    // ─── Accepted price ───

    // TEST-042 verifies: REQ-ORACLE-029, REQ-ORACLE-066, REQ-ORACLE-103
    /// @notice `poke()` stores the accepted price only when Live and newer: a Drifting poke, a Live poke on the same
    /// rounds and a quote-capped poke store nothing; a Live poke on newer rounds stores the fresh price at its oldest
    /// input.
    function test_TEST_042_acceptedOnlyWhenLiveAndNewer() public {
        oracle.poke();
        (uint256 a0, uint64 t0) = oracle.lastAcceptedPrice();
        assertEq(t0, T1);
        vm.roll(block.number + 1);
        oracle.poke();
        (uint256 a1, uint64 t1) = oracle.lastAcceptedPrice();
        assertEq(t1, t0, "same rounds: nothing stored");
        assertEq(a1, a0);
        vm.warp(T1 + 60);
        vm.roll(block.number + 1);
        _pushAll(89_000_000, T1 + 60);
        assertEq(uint8(oracle.poke()), uint8(PriceState.Drifting));
        (, t1) = oracle.lastAcceptedPrice();
        assertEq(t1, t0, "Drifting: nothing stored");
        vm.warp(T1 + 120);
        vm.roll(block.number + 1);
        _pushAll(99_950_000, T1 + 120);
        pA.push(99_950_000, T1 + 100);
        oracle.poke();
        (uint256 a2, uint64 t2) = oracle.lastAcceptedPrice();
        assertEq(t2, T1 + 100, "the oldest input's source timestamp");
        assertEq(a2, _price8(99_950_000, 99_950_000));
        _pushAll(97_000_000, T1 + 120);
        assertEq(uint8(oracle.poke()), uint8(PriceState.Cached), "quote-change cap in the same block");
        (, uint64 t3) = oracle.lastAcceptedPrice();
        assertEq(t3, t2, "the capped price is not stored");
    }

    // TEST-042 verifies: REQ-ORACLE-088, REQ-ORACLE-087
    /// @notice The checkpoint copies the accepted price, not the fresh or served one: in a failed market an hour later
    /// it copies the last accepted price at the block time.
    function test_TEST_042_checkpointCopiesTheAcceptedPrice() public {
        oracle.poke();
        (uint256 accepted,) = oracle.lastAcceptedPrice();
        pB.setMode(pB.latestRoundData.selector, ReadMode.Revert);
        aB.setMode(aB.latestRoundData.selector, ReadMode.Revert);
        vm.warp(T0 + 3600);
        vm.roll(block.number + 1);
        pA.push(99_000_000, T0 + 3600);
        aA.push(99_000_000, T0 + 3600);
        assertEq(uint8(oracle.poke()), uint8(PriceState.Cached));
        (uint256 cp, uint64 at) = oracle.priceCheckpoint();
        assertEq(cp, accepted, "the accepted price, not a fresh one");
        assertEq(at, T0 + 3600, "at the block time");
        vm.warp(T0 + 7199);
        vm.roll(block.number + 1);
        oracle.poke();
        (, at) = oracle.priceCheckpoint();
        assertEq(at, T0 + 3600, "at most once per CHECKPOINT_INTERVAL");
    }

    // ─── borrowAllowed needs every condition ───

    // TEST-276 verifies: REQ-ORACLE-100, REQ-ORACLE-107, REQ-ORACLE-016, SPEC-ORC-015
    /// @notice `borrowAllowed` is the conjunction of Live, every token confirmed, the served age within the borrow age
    /// and a token-decimals verification within 7,200 s; removing any one of them alone makes it false.
    function test_TEST_276_borrowAllowedNeedsEveryCondition() public {
        oracle.poke();
        assertTrue(_state().borrowAllowed, "every condition holds");
        uint256 snap = vm.snapshotState();
        aB.push(97_000_000, T1);
        assertFalse(_state().borrowAllowed, "not Live");
        vm.revertToState(snap);
        sB.push(90_000_000, T1);
        assertFalse(_state().borrowAllowed, "a token unconfirmed");
        vm.revertToState(snap);
        vm.warp(T1 + MAX_AGE + 1);
        pA.push(int256(ONE), T1 + MAX_AGE + 1);
        aA.push(int256(ONE), T1 + MAX_AGE + 1);
        sA.push(int256(ONE), T1 + MAX_AGE + 1);
        sB.push(int256(ONE), T1 + MAX_AGE + 1);
        pB.push(int256(ONE), T1 + MAX_AGE + 1);
        aB.push(int256(ONE), T1);
        oracle.poke();
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Live), "token B on its fresh primary");
        assertTrue(v.borrowAllowed, "the alternate's age does not count while unused");
        vm.revertToState(snap);
        vm.warp(T1 + 7201);
        assertFalse(_state().borrowAllowed, "verification older than 7,200 s");
        assertTrue(_has(_state().reasons, 19));
    }
}
