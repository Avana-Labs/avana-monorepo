// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAggregatorProxy} from "../../src/interfaces/external/chainlink/IAggregatorProxy.sol";
import {IDebtOracleEvents} from "../../src/oracle/debt-oracle/IDebtOracleEvents.sol";
import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {DebtOracleFixture} from "../utils/fixtures/DebtOracleFixture.sol";
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
}
