// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAggregatorProxy} from "../../src/interfaces/external/chainlink/IAggregatorProxy.sol";
import {IDebtOracleEvents} from "../../src/oracle/debt-oracle/IDebtOracleEvents.sol";
import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {DebtOracleFixture} from "../utils/fixtures/DebtOracleFixture.sol";
import {HostileConfig} from "../utils/mocks/DebtOracleConfigMocks.sol";
import {MockAggregator} from "../utils/mocks/MockAggregator.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title DebtOracleRecoveryEdgesUnitTest
/// @notice The edges of recovery evidence from source timestamps (SPEC-ORC-014, REQ-ORACLE-089): a two-leg route whose
/// first or second leg has no gap takes the other leg's gap; a round the oracle never saw between the recorded one and
/// the current one bounds the gap to nothing; an aggregator round of 0 is an unusable lookup; and on the first round of
/// a phase the previous phase's last round is used only when phase 1 is not the current phase and the proxy names a
/// readable aggregator, else the gap starts at the recorded round.
/// @dev Timeline: every feed published at `T0 - 100` and was recorded at `initialize`. The primary USDC/USD has an
/// hourly heartbeat here (`feedMaxAge = 5,400`), as has ETH/USD; USDC/ETH keeps `feedMaxAge = 88,200`. Gaps are
/// `[prev + feedMaxAge + 1, updatedAt)`; `cachedWindow = 3,600`.
contract DebtOracleRecoveryEdgesUnitTest is DebtOracleFixture {
    bytes32 internal constant GRACE = keccak256("DebtGraceStarted(uint64,uint64,bool)");

    function setUp() public {
        _deployDebtOracle();
        store.setFeed(address(pUsd), 8, 0, 1e12, 3600, 1800);
    }

    // TEST-219 verifies: SPEC-ORC-014, REQ-ORACLE-032, REQ-ORACLE-033, REQ-ORACLE-092
    // Sources: 2.10 SPEC-ORC-014 (a valid route's stale interval: an absent gap yields the other leg's)
    /// @notice At `T0 + 20,000` the primary and ETH/USD publish after gaps `[T0 + 5,301, T0 + 20,000)`, while USDC/ETH
    /// keeps its recorded round and has no gap: the alternate's interval is the ETH/USD gap alone, both routes were stale
    /// together for 14,699 s, so the poke opens grace recovered at `T0 + 20,000`.
    function test_TEST_219_absentFirstLegGapTakesTheSecond() public {
        vm.warp(T0 + 20_000);
        ethUsd.push(ETH_USD, T0 + 20_000);
        pUsd.push(USDC_USD, T0 + 20_000);
        assertEq(uint8(_state()), uint8(PriceState.Live));
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtGraceStarted(uint64(T0 + 20_000), uint64(T0 + 20_000 + 1800), false);
        _poke();
        DebtPriceView memory v = oracle.getPriceState();
        assertEq(v.recoveredAt, T0 + 20_000);
        assertTrue(v.inGrace);
    }

    // TEST-219 verifies: SPEC-ORC-014, REQ-ORACLE-032, REQ-ORACLE-033, REQ-ORACLE-092
    // Sources: 2.10 SPEC-ORC-014 (a valid route's stale interval: an absent gap yields the other leg's)
    /// @notice With a daily primary (`feedMaxAge = 88,200`), a poke at `T0 + 88,000` records a fresh ETH/USD round and
    /// sees no gap anywhere. At `T0 + 92,000` the primary and USDC/ETH publish after gaps `[T0 + 88,101, T0 + 92,000)`
    /// while ETH/USD publishes 4,000 s after its recorded round (no gap): the alternate's interval is the USDC/ETH gap
    /// alone, both routes were stale together for 3,899 s, and grace opens at `T0 + 92,000`.
    function test_TEST_219_absentSecondLegGapTakesTheFirst() public {
        store.setFeed(address(pUsd), 8, 0, 1e12, 86_400, 1800);
        vm.warp(T0 + 88_000);
        ethUsd.push(ETH_USD, T0 + 88_000);
        (uint256 n,) = _graces();
        assertEq(n, 0, "no gap on any leg yet");
        assertEq(uint8(_state()), uint8(PriceState.Live));
        vm.warp(T0 + 92_000);
        pUsd.push(USDC_USD, T0 + 92_000);
        aEth.push(USDC_ETH, T0 + 92_000);
        ethUsd.push(ETH_USD, T0 + 92_000);
        uint64 rec;
        (n, rec) = _graces();
        assertEq(n, 1);
        assertEq(rec, T0 + 92_000);
        assertEq(oracle.getPriceState().recoveredAt, T0 + 92_000);
    }

    // TEST-219 verifies: SPEC-ORC-014, REQ-ORACLE-031, REQ-ORACLE-033, REQ-ORACLE-092
    // Sources: 2.10 SPEC-ORC-014 (the gap is [prev + feedMaxAge + 1, updatedAt); none when it is empty)
    /// @notice The primary publishes at `T0 + 5,000` and `T0 + 10,000` with no poke between. The current round is 10,100 s
    /// after the recorded one, so its previous round is looked up: `T0 + 5,000`, which puts the gap's start at
    /// `T0 + 10,401`, after the current round, so the primary has no gap and no grace opens. Without the round at
    /// `T0 + 5,000` the same poke finds the gap `[T0 + 5,301, T0 + 10,000)` and opens grace.
    function test_TEST_219_unseenRoundBetweenLeavesNoGap() public {
        uint256 snap = vm.snapshotState();
        vm.warp(T0 + 10_000);
        pUsd.push(USDC_USD, T0 + 10_000);
        (uint256 n,) = _graces();
        assertEq(n, 1, "control: the 4,699-second gap opens grace");
        vm.revertToState(snap);
        vm.warp(T0 + 5000);
        pUsd.push(USDC_USD, T0 + 5000);
        vm.warp(T0 + 10_000);
        pUsd.push(USDC_USD, T0 + 10_000);
        uint80 between = pUsd.roundId() - 1;
        vm.expectCall(address(pUsd), abi.encodeCall(MockAggregator.getRoundData, (between)), 1);
        (n,) = _graces();
        assertEq(n, 0, "the round at T0 + 5,000 bounds the gap to nothing");
        DebtPriceView memory v = oracle.getPriceState();
        assertEq(v.recoveredAt, 0);
        assertEq(uint8(v.state), uint8(PriceState.Live));
    }

    // TEST-219 verifies: SPEC-ORC-014, REQ-ORACLE-089, REQ-ORACLE-075, REQ-ORACLE-092
    // Sources: 2.10 SPEC-ORC-014 (an unusable lookup gives no evidence)
    /// @notice The primary reports round id `1 << 64` (phase 1, aggregator round 0) at `T0 + 10,000`: there is no
    /// previous round to look up, so the leg is unusable and no grace opens, although the same timestamps on round 2
    /// open grace.
    function test_TEST_219_aggregatorRoundZeroIsUnusable() public {
        vm.warp(T0 + 10_000);
        uint256 snap = vm.snapshotState();
        pUsd.push(USDC_USD, T0 + 10_000);
        (uint256 n,) = _graces();
        assertEq(n, 1, "control: round 2");
        vm.revertToState(snap);
        uint80 zeroRound = uint80(1) << 64;
        _mockLatest(pUsd, zeroRound, T0 + 10_000);
        assertEq(uint8(_state()), uint8(PriceState.Live));
        vm.expectCall(address(pUsd), abi.encodeWithSelector(MockAggregator.getRoundData.selector), 0);
        (n,) = _graces();
        assertEq(n, 0, "aggregator round 0");
        assertEq(oracle.getPriceState().recoveredAt, 0);
    }

    // TEST-220 verifies: REQ-ORACLE-089, SPEC-ORC-014, REQ-ORACLE-075, REQ-ORACLE-092
    // Sources: 2.10 REQ-ORACLE-089 (on the first round of a phase, the previous phase's last round; phase 1 has none)
    /// @notice A poke at `T0 + 1,000` records the primary's round 2. At `T0 + 11,000` the primary reports the first
    /// round of phase 1: there is no earlier phase, so `phaseAggregators` is not read and the gap starts at the recorded
    /// `T0 + 1,000`: `[T0 + 6,401, T0 + 11,000)`, 4,599 s with the stale alternate, and grace opens at `T0 + 11,000`.
    function test_TEST_220_firstRoundOfPhaseOneFallsBackToSeen() public {
        vm.warp(T0 + 1000);
        pUsd.push(USDC_USD, T0 + 1000);
        (uint256 n,) = _graces();
        assertEq(n, 0);
        vm.warp(T0 + 11_000);
        _mockLatest(pUsd, (uint80(1) << 64) | 1, T0 + 11_000);
        vm.expectCall(address(pUsd), abi.encodeWithSelector(IAggregatorProxy.phaseAggregators.selector), 0);
        uint64 rec;
        (n, rec) = _graces();
        assertEq(n, 1);
        assertEq(rec, T0 + 11_000);
    }

    // TEST-220 verifies: REQ-ORACLE-089, SPEC-ORC-014, REQ-ORACLE-075, REQ-ORACLE-092, Q-272
    // Sources: 2.10 REQ-ORACLE-089 (an unusable previous-phase read falls back to seen.updatedAt)
    /// @notice The primary recovers at `T0 + 92,000` on the first round of phase 2. With the previous phase's last round
    /// at `T0 + 91,000` the gap starts at `T0 + 96,401`, after the round, and no grace opens; when the proxy's
    /// `phaseAggregators(1)` reverts, or answers a word above 160 bits, the gap starts at the recorded `T0 - 100`, so
    /// `[T0 + 5,301, T0 + 92,000)` with the stale alternate opens grace at `T0 + 92,000`.
    function test_TEST_220_unreadablePhaseAggregatorFallsBackToSeen() public {
        MockAggregator previous = new MockAggregator(8, USDC_USD, T0 + 91_000);
        vm.warp(T0 + 92_010);
        pUsd.pushNewPhase(USDC_USD, T0 + 92_000, address(previous));
        bytes memory call = abi.encodeCall(IAggregatorProxy.phaseAggregators, (uint16(1)));
        uint256 snap = vm.snapshotState();
        (uint256 n,) = _graces();
        assertEq(n, 0, "control: the previous phase bounds the gap");
        vm.revertToState(snap);
        vm.mockCallRevert(address(pUsd), call, "no phase");
        uint64 rec;
        (n, rec) = _graces();
        assertEq(n, 1, "reverting phaseAggregators");
        assertEq(rec, T0 + 92_000);
        vm.revertToState(snap);
        vm.mockCall(address(pUsd), call, abi.encode(uint256(1) << 160));
        (n, rec) = _graces();
        assertEq(n, 1, "a phase aggregator word above 160 bits");
        assertEq(rec, T0 + 92_000);
    }

    /// @dev Makes `feed.latestRoundData()` answer `roundId` at `at` with the fixture's USDC/USD answer.
    function _mockLatest(
        MockAggregator feed,
        uint80 roundId,
        uint256 at
    ) internal {
        vm.mockCall(
            address(feed),
            abi.encodeWithSelector(MockAggregator.latestRoundData.selector),
            abi.encode(roundId, USDC_USD, at, at, roundId)
        );
    }

    /// @dev Pokes once and returns the number of grace windows it opened and the last recovery time.
    function _graces() internal returns (uint256 n, uint64 recoveredAt) {
        vm.recordLogs();
        _poke();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == GRACE) {
                ++n;
                (recoveredAt,,) = abi.decode(logs[i].data, (uint64, uint64, bool));
            }
        }
    }

    // ─── Recovery evidence: routes, merges and previous rounds (mutation-gate triage, run 43492416937) ───

    // TEST-219 verifies: SPEC-ORC-014, REQ-ORACLE-032, REQ-ORACLE-033, REQ-ORACLE-092
    /// @notice The both-stale interval ends at the earlier of the two routes' ends: the alternate recovers at
    /// `T0 + 12,000` and the primary at `T0 + 12,500`, so grace opens recovered at `T0 + 12,000`.
    function test_TEST_219_bothStaleEndsAtTheEarlierEnd() public {
        ethUsd.push(ETH_USD, T0 + 12_000);
        pUsd.push(USDC_USD, T0 + 12_500);
        vm.warp(T0 + 12_600);
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 1);
        assertEq(rec, T0 + 12_000, "min of the two ends");
    }

    // TEST-219 verifies: SPEC-ORC-014, REQ-ORACLE-032, REQ-ORACLE-033, REQ-ORACLE-092
    /// @notice An Invalid route gives no evidence even when one of its legs has a gap: ETH/USD returns at
    /// `T0 + 20,000` with an answer above its `maxAnswer`, so no grace opens, although the primary's gap and ETH/USD's
    /// silence are the same as in `test_TEST_219_absentFirstLegGapTakesTheSecond`.
    function test_TEST_219_invalidRouteGivesNoEvidence() public {
        vm.warp(T0 + 20_000);
        ethUsd.push(2e12, T0 + 20_000);
        pUsd.push(USDC_USD, T0 + 20_000);
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 0, "Invalid alternate");
        assertEq(rec, 0);
    }

    // TEST-219 verifies: SPEC-ORC-014, REQ-ORACLE-089, REQ-ORACLE-075, REQ-ORACLE-092
    /// @notice With a daily primary, all three feeds return at `T0 + 92,000`; when either alternate leg's previous-round
    /// lookup reverts, the alternate gives no evidence and no grace opens, although the other leg's gap overlaps the
    /// primary's `[T0 + 88,101, T0 + 92,000)` for 3,899 s.
    function test_TEST_219_unusableLookupOnEitherAlternateLeg() public {
        store.setFeed(address(pUsd), 8, 0, 1e12, 86_400, 1800);
        vm.warp(T0 + 92_000);
        pUsd.push(USDC_USD, T0 + 92_000);
        aEth.push(USDC_ETH, T0 + 92_000);
        ethUsd.push(ETH_USD, T0 + 92_000);
        uint256 snap = vm.snapshotState();
        aEth.setMode(MockAggregator.getRoundData.selector, MockAggregator.Mode.Revert);
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 0, "first leg's lookup reverts");
        assertEq(rec, 0);
        vm.revertToState(snap);
        ethUsd.setMode(MockAggregator.getRoundData.selector, MockAggregator.Mode.Revert);
        (n, rec) = _graces();
        assertEq(n, 0, "second leg's lookup reverts");
        assertEq(rec, 0);
    }

    // TEST-219 verifies: SPEC-ORC-014, REQ-ORACLE-032, REQ-ORACLE-033, REQ-ORACLE-092
    /// @notice Disjoint leg gaps keep the one with the later end. A poke at `T0 + 85,000` records a fresh ETH/USD round;
    /// USDC/ETH then returns at `T0 + 90,000` (gap `[T0 + 88,101, T0 + 90,000)`) and ETH/USD at `T0 + 97,000` (gap
    /// `[T0 + 90,401, T0 + 97,000)`); with the daily primary's gap `[T0 + 88,101, T0 + 97,000)` the routes were stale
    /// together for 6,599 s and grace opens at `T0 + 97,000` (the first leg's gap alone would give 1,899 s).
    function test_TEST_219_disjointLegGapsKeepTheLaterOne() public {
        store.setFeed(address(pUsd), 8, 0, 1e12, 86_400, 1800);
        vm.warp(T0 + 85_000);
        ethUsd.push(ETH_USD, T0 + 85_000);
        (uint256 n,) = _graces();
        assertEq(n, 0, "no gap yet");
        aEth.push(USDC_ETH, T0 + 90_000);
        ethUsd.push(ETH_USD, T0 + 97_000);
        pUsd.push(USDC_USD, T0 + 97_000);
        vm.warp(T0 + 97_010);
        uint64 rec;
        (n, rec) = _graces();
        assertEq(n, 1, "later gap");
        assertEq(rec, T0 + 97_000);
    }

    // TEST-219 verifies: SPEC-ORC-014, REQ-ORACLE-032, REQ-ORACLE-033, REQ-ORACLE-092
    /// @notice Overlapping leg gaps join from the earlier start: USDC/ETH is stale over `[T0 + 88,101, T0 + 92,000)`
    /// and ETH/USD over `[T0 + 5,301, T0 + 95,000)`, so the alternate was stale from `T0 + 5,301`; with the primary
    /// stale over `[T0 + 5,301, T0 + 91,000)` grace opens at `T0 + 91,000` (a union from the first leg's start would
    /// give 2,899 s).
    function test_TEST_219_overlappingLegGapsJoinFromTheEarlierStart() public {
        aEth.push(USDC_ETH, T0 + 92_000);
        ethUsd.push(ETH_USD, T0 + 95_000);
        pUsd.push(USDC_USD, T0 + 91_000);
        vm.warp(T0 + 95_010);
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 1);
        assertEq(rec, T0 + 91_000);
    }

    // TEST-220 verifies: REQ-ORACLE-089, SPEC-ORC-014, REQ-ORACLE-075, REQ-ORACLE-092
    /// @notice Round 1 of phase 0 (round id 1) has no earlier phase either: the gap starts at the recorded round and
    /// grace opens at `T0 + 11,000`, as for phase 1.
    function test_TEST_220_firstRoundOfPhaseZeroFallsBackToSeen() public {
        vm.warp(T0 + 1000);
        pUsd.push(USDC_USD, T0 + 1000);
        (uint256 n,) = _graces();
        assertEq(n, 0);
        vm.warp(T0 + 11_000);
        _mockLatest(pUsd, 1, T0 + 11_000);
        uint64 rec;
        (n, rec) = _graces();
        assertEq(n, 1);
        assertEq(rec, T0 + 11_000);
    }

    // TEST-219 verifies: SPEC-ORC-014, REQ-ORACLE-089, REQ-ORACLE-075, REQ-ORACLE-092
    /// @notice A previous round reporting time 0 is unusable: no grace opens, where a gap counted from time 0 would.
    function test_TEST_219_previousRoundAtTimeZeroIsUnusable() public {
        vm.warp(T0 + 10_000);
        pUsd.push(USDC_USD, T0 + 10_000);
        uint80 previous = pUsd.roundId() - 1;
        vm.mockCall(
            address(pUsd),
            abi.encodeCall(MockAggregator.getRoundData, (previous)),
            abi.encode(previous, USDC_USD, uint256(0), uint256(0), previous)
        );
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 0, "previous round at time 0");
        assertEq(rec, 0);
    }

    // ─── Records and gap edges (mutation-gate triage, run 43492416937, second pass) ───

    // TEST-219 verifies: SPEC-ORC-014, REQ-ORACLE-031, REQ-ORACLE-033, REQ-ORACLE-092
    /// @notice With a two-leg primary `USDC/ETH x ETH/USD` and the hourly USDC/USD as the alternate, a poke at `T0 + 10`
    /// records both primary legs. At `T0 + 20,000` ETH/USD and USDC/USD publish after their gaps
    /// `[T0 + 5,301, T0 + 20,000)`: the primary's interval is its second leg's gap, so grace opens at `T0 + 20,000`.
    function test_TEST_219_secondLegOfATwoLegPrimaryIsRecorded() public {
        reg.setRoutes(usdc, _route2(address(aEth), address(ethUsd)), _route1(address(pUsd)));
        vm.warp(T0 + 10);
        _poke();
        vm.warp(T0 + 20_000);
        ethUsd.push(ETH_USD, T0 + 20_000);
        pUsd.push(USDC_USD, T0 + 20_000);
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 1, "the second primary leg's gap");
        assertEq(rec, T0 + 20_000);
    }

    // TEST-219 verifies: SPEC-ORC-014, REQ-ORACLE-031, REQ-ORACLE-033, REQ-ORACLE-092
    /// @notice A poke whose configuration read fails reads no route and writes no leg record: after it, the primary and
    /// ETH/USD publish at `T0 + 20,000` after gaps from their records at `T0 - 100`, and grace opens at `T0 + 20,000`.
    function test_TEST_219_failedConfigurationReadKeepsTheRecords() public {
        vm.warp(T0 + 1000);
        store.setMode(store.cachedWindow.selector, HostileConfig.Mode.Revert);
        _poke();
        assertEq(uint8(_state()), uint8(PriceState.Cached), "configuration unavailable");
        store.setMode(store.cachedWindow.selector, HostileConfig.Mode.Normal);
        vm.warp(T0 + 20_000);
        ethUsd.push(ETH_USD, T0 + 20_000);
        pUsd.push(USDC_USD, T0 + 20_000);
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 1, "records kept");
        assertEq(rec, T0 + 20_000);
    }

    // TEST-219 verifies: SPEC-ORC-014, REQ-ORACLE-031, REQ-ORACLE-089, REQ-ORACLE-092
    /// @notice A leg whose read reverts keeps its previous record. A poke at `T0 + 1,000` finds the primary's and
    /// ETH/USD's `latestRoundData` reverting; at `T0 + 20,000` both publish the first round of a new phase whose previous
    /// phase cannot be read, so each gap starts from the recorded `T0 - 100`, and grace opens at `T0 + 20,000` (a record
    /// overwritten with time 0 would make the lookup unusable).
    function test_TEST_219_erroredLegKeepsItsRecord() public {
        vm.warp(T0 + 1000);
        pUsd.setMode(MockAggregator.latestRoundData.selector, MockAggregator.Mode.Revert);
        ethUsd.setMode(MockAggregator.latestRoundData.selector, MockAggregator.Mode.Revert);
        _poke();
        pUsd.setMode(MockAggregator.latestRoundData.selector, MockAggregator.Mode.Normal);
        ethUsd.setMode(MockAggregator.latestRoundData.selector, MockAggregator.Mode.Normal);
        vm.warp(T0 + 20_000);
        pUsd.pushNewPhase(USDC_USD, T0 + 20_000, address(0));
        ethUsd.pushNewPhase(ETH_USD, T0 + 20_000, address(0));
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 1, "gaps from the kept records");
        assertEq(rec, T0 + 20_000);
    }

    // TEST-219 verifies: SPEC-ORC-014, REQ-ORACLE-031, REQ-ORACLE-001, REQ-ORACLE-092
    /// @notice A leg whose `decimals()` read fails is an Error and is not recorded, even though its round decoded: a poke
    /// at `T0 + 20,000` reads the primary's and ETH/USD's new rounds with `decimals()` reverting; the next poke, with
    /// `decimals()` readable, still finds both gaps from the records at `T0 - 100` and opens grace at `T0 + 20,000`.
    function test_TEST_219_unreadableDecimalsLegIsNotRecorded() public {
        vm.warp(T0 + 20_000);
        pUsd.push(USDC_USD, T0 + 20_000);
        ethUsd.push(ETH_USD, T0 + 20_000);
        pUsd.setMode(MockAggregator.decimals.selector, MockAggregator.Mode.Revert);
        ethUsd.setMode(MockAggregator.decimals.selector, MockAggregator.Mode.Revert);
        (uint256 n,) = _graces();
        assertEq(n, 0, "no route while decimals fail");
        pUsd.setMode(MockAggregator.decimals.selector, MockAggregator.Mode.Normal);
        ethUsd.setMode(MockAggregator.decimals.selector, MockAggregator.Mode.Normal);
        vm.warp(T0 + 20_010);
        uint64 rec;
        (n, rec) = _graces();
        assertEq(n, 1, "gaps from the records before the failed read");
        assertEq(rec, T0 + 20_000);
    }

    // TEST-219 verifies: SPEC-ORC-014, REQ-ORACLE-031, REQ-ORACLE-033, REQ-ORACLE-092
    /// @notice A leg whose round did not change has no gap, even when that round's timestamp moved: after a poke at
    /// `T0 + 10` records round 2 of the primary and ETH/USD, both rewrite round 2 with time `T0 + 20,000` and no grace
    /// opens. A real new round at `T0 + 20,000` instead gives the gap `[T0 + 5,411, T0 + 20,000)` and grace.
    function test_TEST_219_sameRoundWithANewTimeIsNoGap() public {
        vm.warp(T0 + 10);
        pUsd.push(USDC_USD, T0 + 10);
        ethUsd.push(ETH_USD, T0 + 10);
        _poke();
        vm.warp(T0 + 20_000);
        uint256 snap = vm.snapshotState();
        pUsd.setCurrent(USDC_USD, T0 + 20_000);
        ethUsd.setCurrent(ETH_USD, T0 + 20_000);
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 0, "same round");
        assertEq(rec, 0);
        vm.revertToState(snap);
        pUsd.push(USDC_USD, T0 + 20_000);
        ethUsd.push(ETH_USD, T0 + 20_000);
        (n, rec) = _graces();
        assertEq(n, 1, "control: new rounds");
        assertEq(rec, T0 + 20_000);
    }

    // TEST-219 verifies: SPEC-ORC-014, REQ-ORACLE-032, REQ-ORACLE-033, REQ-ORACLE-092
    /// @notice A leg gap that would start at or after its round is no gap. The primary and USDC/ETH return at
    /// `T0 + 92,000` (gaps from `T0 + 5,301` and `T0 + 88,101`); ETH/USD publishes at `T0 + 87,599` (start
    /// `T0 + 93,000`, equal to its next round) or `T0 + 88,000` (start `T0 + 93,401`, after it) and again at
    /// `T0 + 93,000`. The alternate's interval is USDC/ETH's gap, and grace opens at `T0 + 92,000`.
    function test_TEST_219_legGapStartingAtOrAfterItsRoundIsNoGap() public {
        uint256[2] memory mids = [T0 + 87_599, T0 + 88_000];
        uint256 snap = vm.snapshotState();
        for (uint256 k = 0; k < 2; ++k) {
            pUsd.push(USDC_USD, T0 + 92_000);
            aEth.push(USDC_ETH, T0 + 92_000);
            ethUsd.push(ETH_USD, mids[k]);
            ethUsd.push(ETH_USD, T0 + 93_000);
            vm.warp(T0 + 93_010);
            (uint256 n, uint64 rec) = _graces();
            assertEq(n, 1, k == 0 ? "start equal to the round" : "start after the round");
            assertEq(rec, T0 + 92_000);
            vm.revertToState(snap);
        }
    }

    // TEST-219 verifies: SPEC-ORC-014, REQ-ORACLE-089, REQ-ORACLE-075, REQ-ORACLE-092
    /// @notice With a daily primary, all three feeds return at `T0 + 92,000` and grace opens there. When USDC/ETH's
    /// previous round reports the current round's own time, or time 0, that lookup is unusable and the alternate gives no
    /// evidence, although ETH/USD's gap alone overlaps the primary's for 3,899 s.
    function test_TEST_219_unusablePreviousTimeOnTheFirstAlternateLeg() public {
        store.setFeed(address(pUsd), 8, 0, 1e12, 86_400, 1800);
        vm.warp(T0 + 92_000);
        pUsd.push(USDC_USD, T0 + 92_000);
        aEth.push(USDC_ETH, T0 + 92_000);
        ethUsd.push(ETH_USD, T0 + 92_000);
        uint80 previous = aEth.roundId() - 1;
        uint256 snap = vm.snapshotState();
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 1, "control");
        assertEq(rec, T0 + 92_000);
        uint256[2] memory times = [T0 + 92_000, 0];
        for (uint256 k = 0; k < 2; ++k) {
            vm.revertToState(snap);
            vm.mockCall(
                address(aEth),
                abi.encodeCall(MockAggregator.getRoundData, (previous)),
                abi.encode(previous, USDC_ETH, times[k], times[k], previous)
            );
            (n, rec) = _graces();
            assertEq(n, 0, k == 0 ? "previous round at the round's time" : "previous round at time 0");
            assertEq(rec, 0);
            vm.clearMockedCalls();
        }
    }
}
