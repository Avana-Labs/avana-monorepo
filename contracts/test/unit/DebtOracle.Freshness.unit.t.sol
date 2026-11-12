// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {SecondSource} from "../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../src/types/SecondSourceKind.sol";
import {DebtOracleFixture} from "../utils/fixtures/DebtOracleFixture.sol";
import {MockAggregator} from "../utils/mocks/MockAggregator.sol";

/// @title DebtOracleFreshnessUnitTest
/// @notice Per-feed age limits (`SPEC-ORC-019`, `SPEC-ORC-015`), the alternate held to its borrow age
/// (`REQ-ORACLE-090`), the second source (`SPEC-ORC-020`) and the sequencer gate (`SPEC-ORC-021`).
contract DebtOracleFreshnessUnitTest is DebtOracleFixture {
    uint256 internal constant BIT_ALT_PAST_BORROW = 1 << 15;
    uint256 internal constant BIT_SEQ_DOWN = 1 << 17;
    uint256 internal constant BIT_SEQ_GRACE = 1 << 18;
    uint256 internal constant BIT_SECOND = 1 << 19;
    uint256 internal constant BIT_GRACE = 1 << 13;

    function setUp() public {
        _deployDebtOracle();
    }

    function _view() internal view returns (DebtPriceView memory) {
        return oracle.getPriceState();
    }

    /// @dev Keeps the alternate legs and the second source fresh at the current time.
    function _freshAlternate() internal {
        _refresh(aEth);
        _refresh(ethUsd);
        _refresh(second);
    }

    // TEST-276 verifies: SPEC-ORC-019, REQ-ORACLE-002, REQ-ORACLE-003, REQ-ORACLE-092, REQ-ORACLE-054
    // Sources: 5.1 TEST-276 (a USDC/USD feed with an 86,400 s heartbeat is fresh at 86,400 s and stale after heartbeat
    // plus margin)
    function test_TEST_276_feedFreshUntilHeartbeatPlusMargin() public {
        pUsd.push(USDC_USD, T0);
        vm.warp(T0 + 86_400);
        _freshAlternate();
        assertEq(uint8(_view().routeUsed), uint8(RouteSlot.Primary));
        vm.warp(T0 + 88_200);
        _freshAlternate();
        DebtPriceView memory v = _view();
        assertEq(uint8(v.routeUsed), uint8(RouteSlot.Primary));
        assertEq(v.borrowPriceMaxAge, 88_200);
        assertEq(v.liquidationPriceMaxAge, 88_200);
        assertTrue(v.borrowAllowed);
        vm.warp(T0 + 88_201);
        _freshAlternate();
        v = _view();
        assertEq(uint8(v.routeUsed), uint8(RouteSlot.Alternate));
        assertEq(uint8(v.state), uint8(PriceState.Live));
        assertEq(v.primaryAge, 88_201);
    }

    // TEST-276 verifies: SPEC-ORC-015, REQ-ORACLE-043, REQ-ORACLE-093, REQ-ORACLE-092
    // Sources: SPEC-ORC-015 example (the hourly ETH/USD leg binds on the alternate)
    function test_TEST_276_ageLimitsOnTheAlternate() public {
        uint256 x = T0 + 1000;
        vm.warp(x + 5000);
        pUsd.push(0, block.timestamp);
        aEth.push(USDC_ETH, x);
        ethUsd.push(ETH_USD, x + 5000);
        DebtPriceView memory v = _view();
        assertEq(v.servedUpdatedAt, x);
        // Deadlines: USDC/ETH x + 88,200; ETH/USD x + 5,000 + 5,400 = x + 10,400.
        assertEq(oracle.borrowPriceMaxAge(), 10_400);
        assertEq(oracle.liquidationPriceMaxAge(), 10_400);
        assertEq(v.legLiquidationPriceMaxAge[0], 88_200);
        assertEq(v.legLiquidationPriceMaxAge[1], 5400);
    }

    // TEST-276 verifies: REQ-ORACLE-090, SPEC-ORC-015, REQ-ORACLE-093, REQ-ORACLE-092, Q-274
    // Sources: REQ-ORACLE-090 example (governance lowers the alternate leg's borrow age during an incident)
    function test_TEST_276_alternateHeldToItsBorrowAge() public {
        uint256 x = T0 + 1000;
        vm.warp(x);
        pUsd.push(0, x);
        aEth.push(USDC_ETH, x);
        ethUsd.push(ETH_USD, x);
        store.setBorrowAge(address(aEth), 21_600);
        vm.warp(x + 21_000);
        ethUsd.push(ETH_USD, x + 21_000);
        DebtPriceView memory v = _view();
        assertEq(v.liquidationPriceMaxAge, 21_600, "liquidation limit is min(liquidation, borrow) on the alternate");
        assertFalse(v.liquidationPaused);
        vm.warp(x + 21_601);
        ethUsd.push(ETH_USD, x + 21_601);
        _refresh(second);
        v = _view();
        assertTrue(v.reasons & BIT_ALT_PAST_BORROW != 0);
        assertTrue(v.liquidationPaused);
        assertEq(uint8(v.state), uint8(PriceState.Live), "the state is unchanged");
        assertEq(uint256(v.answer), 99_990_000, "the served price is unchanged");
        assertFalse(v.borrowAllowed);
        // On the primary the same lowered limit would not pause liquidation.
        pUsd.push(USDC_USD, block.timestamp);
        assertFalse(_view().liquidationPaused);
    }

    // TEST-276 verifies: REQ-ORACLE-100, SPEC-ORC-020, REQ-ORACLE-092, Q-323
    // Sources: 5.1 TEST-276 (a borrow requires the independent second source to agree; it reverts when the source
    // disagrees or is stale; liquidation does not require it)
    function test_TEST_276_secondSourceGatesBorrowOnly() public {
        vm.warp(T0 + 60);
        assertTrue(_view().borrowAllowed);
        // q = 99,990,000, S = 100: s = 99,000,000 is exactly at the bound and confirmed; 98,999,999 is not.
        second.push(99_000_000, block.timestamp);
        assertTrue(_view().borrowAllowed);
        second.push(98_999_999, block.timestamp);
        DebtPriceView memory v = _view();
        assertFalse(v.borrowAllowed);
        assertTrue(v.reasons & BIT_SECOND != 0);
        assertEq(uint8(v.state), uint8(PriceState.Live));
        assertFalse(v.liquidationPaused);
        // A stale second source is not confirmed either.
        second.push(99_990_000, T0 - 88_201 + 60);
        assertFalse(_view().borrowAllowed);
        // The guardian's standby second source takes effect on the next evaluation.
        MockAggregator standbySource = new MockAggregator(8, 99_995_000, block.timestamp);
        store.setFeed(address(standbySource), 8, 0, 1e12, 86_400, 1800);
        store.setSecondSource(usdc, _oracleNetwork(address(standbySource)));
        assertTrue(_view().borrowAllowed);
    }

    // TEST-276 verifies: REQ-ORACLE-100, REQ-ORACLE-092, SPEC-ORC-020
    function test_TEST_276_onlyAnOracleNetworkSourceConfirms() public {
        vm.warp(T0 + 60);
        SecondSource memory s = _oracleNetwork(address(second));
        s.kind = SecondSourceKind.PoolTwap;
        store.setSecondSource(usdc, s);
        assertFalse(_view().borrowAllowed);
        s.kind = SecondSourceKind.None;
        store.setSecondSource(usdc, s);
        assertFalse(_view().borrowAllowed);
        store.setSecondSource(usdc, _oracleNetwork(address(second)));
        store.clearFeed(address(second));
        assertFalse(_view().borrowAllowed);
        store.setFeed(address(second), 8, 0, 1e12, 86_400, 1800);
        second.setMode(second.latestRoundData.selector, MockAggregator.Mode.Revert);
        DebtPriceView memory v = _view();
        assertFalse(v.borrowAllowed);
        assertEq(uint8(v.state), uint8(PriceState.Live));
    }

    // TEST-276 verifies: REQ-ORACLE-100, SPEC-ORC-015, REQ-ORACLE-093, REQ-ORACLE-092
    function test_TEST_276_borrowNeedsServedPriceWithinBorrowAge() public {
        store.setBorrowAge(address(pUsd), 3600);
        vm.warp(T0 - 100 + 3600);
        _refresh(second);
        DebtPriceView memory v = _view();
        assertEq(v.borrowPriceMaxAge, 3600);
        assertTrue(v.borrowAllowed);
        vm.warp(T0 - 100 + 3601);
        _freshAlternate();
        v = _view();
        assertEq(uint8(v.routeUsed), uint8(RouteSlot.Primary));
        assertFalse(v.borrowAllowed);
        assertFalse(v.liquidationPaused, "the primary's liquidation limit stays 88,200");
        assertEq(v.liquidationPriceMaxAge, 88_200);
    }

    // TEST-276 verifies: REQ-ORACLE-099, SPEC-ORC-021, REQ-ORACLE-092, REQ-ORACLE-034, ATTACK-171, INV-098, Q-324
    // Sources: SPEC-ORC-021 example (Base sequencer down at 1,000,000, restart at 1,010,000, grace 3,600 s)
    function test_TEST_276_sequencerGate() public {
        MockAggregator seq = new MockAggregator(0, 0, T0 - 50_000);
        store.setSequencer(address(seq), 3600);
        vm.warp(T0 + 60);
        assertTrue(_view().borrowAllowed);
        seq.push(1, block.timestamp);
        DebtPriceView memory v = _view();
        assertTrue(v.reasons & BIT_SEQ_DOWN != 0);
        assertTrue(v.liquidationPaused);
        assertFalse(v.borrowAllowed);
        assertEq(uint8(v.state), uint8(PriceState.Live));
        assertEq(uint256(v.answer), 99_990_000);
        uint256 restart = block.timestamp + 10_000;
        vm.warp(restart);
        seq.push(0, restart);
        _refreshAll();
        v = _view();
        assertTrue(v.reasons & BIT_SEQ_GRACE != 0);
        assertTrue(v.reasons & BIT_GRACE != 0);
        assertTrue(v.inGrace);
        assertEq(v.graceEndsAt, restart + 3600);
        assertFalse(v.liquidationPaused);
        assertFalse(v.borrowAllowed);
        vm.warp(restart + 3599);
        assertFalse(_view().borrowAllowed);
        vm.warp(restart + 3600);
        _refreshAll();
        v = _view();
        assertTrue(v.borrowAllowed);
        assertFalse(v.inGrace);
        // Any other answer, or a reverting feed, blocks borrowing only.
        seq.push(2, block.timestamp);
        v = _view();
        assertTrue(v.reasons & BIT_SEQ_DOWN != 0);
        assertFalse(v.borrowAllowed);
        assertFalse(v.liquidationPaused);
        seq.setMode(seq.latestRoundData.selector, MockAggregator.Mode.Burn);
        v = _view();
        assertFalse(v.borrowAllowed);
        assertFalse(v.liquidationPaused);
    }

    /// @notice Base, restart at `T0 + 100` with a 3,600 s grace period: past the grace period, a served round from
    /// before the restart, or from the restart second, never admits a borrow, while the state stays Live, the same
    /// price is served and liquidation is not paused; a round newer than the restart reopens borrowing. Ethereum (no
    /// sequencer feed) is unchanged: the same old rounds admit a borrow.
    // TEST-276 verifies: REQ-ORACLE-099, REQ-ORACLE-092, REQ-ORACLE-100, SPEC-ORC-021, ATTACK-171
    // Sources: SPEC-ORC-021 example (restart, grace, borrowing reopens on a round newer than the restart)
    function test_TEST_276_sequencerRestartNeedsNewerRound() public {
        uint256 restart = T0 + 100;
        vm.warp(restart + 3600);
        assertTrue(_view().borrowAllowed, "Ethereum: no feed, rounds from T0 - 100 admit a borrow");
        MockAggregator seq = new MockAggregator(0, 0, restart);
        store.setSequencer(address(seq), 3600);
        DebtPriceView memory v = _view();
        assertEq(uint8(v.state), uint8(PriceState.Live));
        assertFalse(v.inGrace, "grace period over");
        assertFalse(v.borrowAllowed, "served round from T0 - 100, before the restart");
        assertFalse(v.liquidationPaused, "liquidation and repayment run on the same price");
        int256 served = v.answer;
        vm.warp(restart);
        _refreshAll();
        vm.warp(restart + 3600);
        v = _view();
        assertFalse(v.borrowAllowed, "a round at the restart second is not newer");
        assertEq(v.answer, served);
        _refreshAll();
        assertTrue(_view().borrowAllowed, "a round newer than the restart");
    }

    /// @notice For every restart time, time past the grace period and round time: borrowing is allowed exactly when the
    /// served round is newer than the restart; liquidation is never paused by the rule.
    // TEST-276 verifies: REQ-ORACLE-099, REQ-ORACLE-092, SPEC-ORC-021
    function testFuzz_TEST_276_borrowOnlyOnRoundsAfterRestart(
        uint256 restartOffset,
        uint256 extra,
        uint256 roundAt
    ) public {
        uint256 restart = T0 + bound(restartOffset, 1, 7200);
        uint256 nowTs = restart + 3600 + bound(extra, 0, 7200);
        roundAt = bound(roundAt, T0, nowTs);
        store.setSequencer(address(new MockAggregator(0, 0, restart)), 3600);
        vm.warp(roundAt);
        _refreshAll();
        vm.warp(nowTs);
        DebtPriceView memory v = _view();
        assertEq(uint8(v.state), uint8(PriceState.Live));
        assertEq(v.borrowAllowed, roundAt > restart, "borrow iff the served round is newer than the restart");
        assertFalse(v.liquidationPaused);
    }
}
