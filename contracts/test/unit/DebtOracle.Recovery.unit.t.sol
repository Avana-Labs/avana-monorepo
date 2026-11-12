// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IDebtOracleEvents} from "../../src/oracle/debt-oracle/IDebtOracleEvents.sol";
import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {DebtOracleFixture} from "../utils/fixtures/DebtOracleFixture.sol";
import {MockAggregator} from "../utils/mocks/MockAggregator.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title DebtOracleRecoveryUnitTest
/// @notice Recovery evidence from source timestamps (SPEC-ORC-014) when no poke saw the outage: the two legs of the
/// alternate merged into one stale interval when their gaps overlap and reduced to the later gap when they do not; a
/// route that is still stale counting from its first failed read to now; an unusable previous-round lookup and a leg
/// whose feed changed giving no evidence; and the both-stale interval measured against the cached window at its exact
/// length.
/// @dev Timeline: every feed published at `T0 - 100` and was recorded at `initialize`. Gaps are
/// `[prev + feedMaxAge + 1, updatedAt)`.
contract DebtOracleRecoveryUnitTest is DebtOracleFixture {
    bytes32 internal constant GRACE = keccak256("DebtGraceStarted(uint64,uint64,bool)");

    function setUp() public {
        _deployDebtOracle();
        // A primary with an hourly heartbeat (feedMaxAge 5,400) so its gap starts at T0 + 5,301.
        store.setFeed(address(pUsd), 8, 0, 1e12, 3600, 1800);
    }

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

    // TEST-219 verifies: SPEC-ORC-014, REQ-ORACLE-032, REQ-ORACLE-092, ATTACK-145
    // Sources: 2.10 SPEC-ORC-014 (a valid route's stale interval is the union of its legs' gaps if they overlap)
    /// @notice The alternate's ETH/USD gap `[T0 + 25,401, T0 + 88,500)` overlaps its USDC/ETH gap
    /// `[T0 + 88,101, T0 + 89,000)`, so the alternate was stale over their union; with the primary's gap
    /// `[T0 + 5,301, T0 + 89,000)` both routes were stale for 63,599 s, at least the 3,600-second window: the first poke
    /// at `T0 + 89,000` opens a grace window recovered at `T0 + 89,000`.
    function test_TEST_219_overlappingLegGapsMerge() public {
        vm.warp(T0 + 20_000);
        ethUsd.push(ETH_USD, T0 + 20_000);
        vm.warp(T0 + 88_500);
        ethUsd.push(ETH_USD, T0 + 88_500);
        vm.warp(T0 + 89_000);
        aEth.push(USDC_ETH, T0 + 89_000);
        pUsd.push(USDC_USD, T0 + 89_000);
        assertEq(uint8(_state()), uint8(PriceState.Live));
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtGraceStarted(uint64(T0 + 89_000), uint64(T0 + 89_000 + 1800), false);
        _poke();
        DebtPriceView memory v = oracle.getPriceState();
        assertEq(v.recoveredAt, T0 + 89_000);
        assertTrue(v.inGrace);
    }

    // TEST-219 verifies: SPEC-ORC-014, REQ-ORACLE-032, REQ-ORACLE-033, REQ-ORACLE-092
    // Sources: 2.10 SPEC-ORC-014 (else the gap with the later end)
    /// @notice The same, but the ETH/USD gap ends at `T0 + 87,000`, before the USDC/ETH gap starts: the alternate's
    /// interval is only the later gap `[T0 + 88,101, T0 + 89,000)`, both routes were stale together for 899 s, below the
    /// window, and no grace window opens.
    function test_TEST_219_disjointLegGapsKeepTheLaterOne() public {
        vm.warp(T0 + 20_000);
        ethUsd.push(ETH_USD, T0 + 20_000);
        vm.warp(T0 + 87_000);
        ethUsd.push(ETH_USD, T0 + 87_000);
        vm.warp(T0 + 89_000);
        aEth.push(USDC_ETH, T0 + 89_000);
        pUsd.push(USDC_USD, T0 + 89_000);
        assertEq(uint8(_state()), uint8(PriceState.Live));
        (uint256 n,) = _graces();
        assertEq(n, 0, "899 s together is below the window");
        assertEq(oracle.getPriceState().recoveredAt, 0);
    }

    // TEST-219 verifies: SPEC-ORC-014, REQ-ORACLE-032, REQ-ORACLE-092
    // Sources: 2.10 SPEC-ORC-014 (a currently Stale route has S_r = [staleFrom_r, now])
    /// @notice The alternate is still stale (from `T0 + 5,301`) when the primary publishes at `T0 + 100,000` after a
    /// gap from `T0 + 5,301`: both were stale over `[T0 + 5,301, T0 + 100,000)`, so the poke opens grace recovered at
    /// `T0 + 100,000`, and the asset is Live on the primary in grace.
    function test_TEST_219_staleRouteSpansToNow() public {
        vm.warp(T0 + 100_000);
        pUsd.push(USDC_USD, T0 + 100_000);
        DebtPriceView memory v = oracle.getPriceState();
        assertEq(uint8(v.state), uint8(PriceState.Live));
        assertEq(uint8(v.routeUsed), uint8(RouteSlot.Primary));
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 1);
        assertEq(rec, T0 + 100_000);
        v = oracle.getPriceState();
        assertTrue(v.inGrace);
        assertEq(v.reasons & (1 << 13), 1 << 13, "IN_GRACE reason");
    }

    // TEST-219 verifies: SPEC-ORC-014, REQ-ORACLE-075, REQ-ORACLE-065, REQ-ORACLE-092
    // Sources: 2.10 SPEC-ORC-014 (an unusable lookup gives no evidence: a revert, updatedAt 0, prev >= updatedAt)
    /// @notice The same recovery gives no grace when the primary's previous-round lookup reverts, or when the previous
    /// round reports the same time as the current one (`prev >= updatedAt`).
    function test_TEST_219_unusablePreviousRoundGivesNoEvidence() public {
        vm.warp(T0 + 100_000);
        pUsd.push(USDC_USD, T0 + 100_000);
        pUsd.setMode(pUsd.getRoundData.selector, MockAggregator.Mode.Revert);
        (uint256 n,) = _noWriteGraces();
        assertEq(n, 0, "reverting lookup");
        pUsd.setMode(pUsd.getRoundData.selector, MockAggregator.Mode.Normal);
        (n,) = _noWriteGraces();
        assertEq(n, 1, "the same recovery with a usable lookup opens grace");
        pUsd.push(USDC_USD, T0 + 100_000);
        (n,) = _graces();
        assertEq(n, 0, "a previous round at the same time is unusable");
        assertEq(oracle.getPriceState().recoveredAt, 0);
    }

    // TEST-231 verifies: SPEC-ORC-014, REQ-ORACLE-095, REQ-ORACLE-092, ATTACK-140
    // Sources: 2.10 SPEC-ORC-014 (only legs whose seen.feed is the leg's aggregator are looked up)
    /// @notice A standby switch replaces the primary with a feed the oracle never recorded: its long silence is no
    /// evidence, so a poke after the switch observes the new version and opens no grace window.
    function test_TEST_231_switchedFeedHasNoRecordedGap() public {
        vm.warp(T0 + 100_000);
        reg.useStandby(usdc, RouteSlot.Primary);
        standby.push(99_995_000, T0 + 100_000);
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtRouteVersionObserved(1, 2);
        (uint256 n,) = _graces();
        assertEq(n, 0, "no recorded round for the standby feed");
        assertEq(uint8(_state()), uint8(PriceState.Live));
        assertEq(oracle.getPriceState().reasons & (1 << 16), 1 << 16, "ON_STANDBY");
    }

    // TEST-219 verifies: SPEC-ORC-014, REQ-ORACLE-032, REQ-ORACLE-092
    // Sources: 2.10 SPEC-ORC-014 (length >= cachedWindow)
    /// @notice The both-stale interval against the window at its exact length: with the alternate stale from
    /// `T0 + 5,301` and the primary's gap starting there too, a primary round at `T0 + 5,301 + 3,599` gives 3,599 s and
    /// no grace; at `T0 + 5,301 + 3,600` exactly the window, and grace opens.
    function test_TEST_219_bothStaleLengthAtTheWindow() public {
        uint256 start = T0 + 5301;
        uint256 snap = vm.snapshotState();
        vm.warp(start + 3599);
        pUsd.push(USDC_USD, start + 3599);
        (uint256 n,) = _graces();
        assertEq(n, 0, "3,599 s");
        vm.revertToState(snap);
        vm.warp(start + 3600);
        pUsd.push(USDC_USD, start + 3600);
        uint64 rec;
        (n, rec) = _graces();
        assertEq(n, 1, "3,600 s");
        assertEq(rec, start + 3600);
    }

    // TEST-219 verifies: SPEC-ORC-014, REQ-ORACLE-031, REQ-ORACLE-033, REQ-ORACLE-092
    // Sources: 2.10 SPEC-ORC-014 (only legs with updatedAt - seen.updatedAt > feedMaxAge are looked up)
    /// @notice A leg whose new round comes exactly `feedMaxAge` after the round the oracle recorded is not looked up
    /// (no `getRoundData` call) and has no gap, even when an out-of-order older round sits between them whose
    /// timestamp would open a 10,099-second both-stale interval with the stale alternate: no grace window opens.
    function test_TEST_219_newRoundWithinMaxAgeOfTheRecordedOneIsNotLookedUp() public {
        uint256 y = T0 + 10_000;
        vm.warp(y);
        pUsd.push(USDC_USD, y);
        // This poke records the round at y; its own 4,699-second outage with the stale alternate opens grace at y.
        _poke();
        assertEq(oracle.getPriceState().recoveredAt, y);
        pUsd.push(USDC_USD, y - 20_000);
        vm.warp(y + 5400);
        pUsd.push(USDC_USD, y + 5400);
        assertEq(uint8(_state()), uint8(PriceState.Live));
        vm.expectCall(address(pUsd), abi.encodeWithSelector(MockAggregator.getRoundData.selector), 0);
        (uint256 n,) = _graces();
        assertEq(n, 0, "no gap for a round within feedMaxAge of the recorded one");
        assertEq(oracle.getPriceState().recoveredAt, y, "the earlier recovery stands");
    }

    /// @dev Counts grace windows a poke would open, then rolls the poke back.
    function _noWriteGraces() internal returns (uint256 n, uint64 rec) {
        uint256 snap = vm.snapshotState();
        (n, rec) = _graces();
        vm.revertToState(snap);
    }
}
