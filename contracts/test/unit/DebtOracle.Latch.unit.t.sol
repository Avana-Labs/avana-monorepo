// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IDebtOracleEvents} from "../../src/oracle/debt-oracle/IDebtOracleEvents.sol";
import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {DebtOracleFixture} from "../utils/fixtures/DebtOracleFixture.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title DebtOracleLatchUnitTest
/// @notice The outage latch of REQ-ORACLE-030 and the grace windows it starts (REQ-ORACLE-032, REQ-ORACLE-033): the
/// latch is set by the first poke at or after `staleAt + cachedWindow` and not one second earlier, it is set once per
/// outage, it is cleared by the grace window it starts so the next outage latches again, and a route version change
/// starts grace only while latched.
/// @dev Both routes are stale from `STALE_AT = T0 + 88,101` (the primary's last round at `T0 - 100` plus 88,200 + 1).
contract DebtOracleLatchUnitTest is DebtOracleFixture {
    uint256 internal constant STALE_AT = T0 + 88_101;
    bytes32 internal constant LATCH = keccak256("DebtOutageExpiredLatched(uint64,uint64)");
    bytes32 internal constant GRACE = keccak256("DebtGraceStarted(uint64,uint64,bool)");

    function setUp() public {
        _deployDebtOracle();
    }

    function _pokeCount(
        bytes32 topic
    ) internal returns (uint256 n) {
        vm.recordLogs();
        _poke();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic) ++n;
        }
    }

    // TEST-219 verifies: REQ-ORACLE-030, REQ-ORACLE-065, REQ-ORACLE-092, SPEC-ORC-013
    // Sources: 2.10 REQ-ORACLE-030 (the latch is set only when the source timestamps show Expired)
    /// @notice A poke one second before `STALE_AT + 3,600` records the failure (Cached) but no latch; the poke at
    /// exactly `STALE_AT + 3,600` latches with `(staleAt, now)`; later pokes during the same outage never latch again.
    function test_TEST_219_latchBoundaryAndOncePerOutage() public {
        vm.warp(STALE_AT + 3599);
        assertEq(_pokeCount(LATCH), 0, "one second early");
        assertEq(uint8(_state()), uint8(PriceState.Cached));
        vm.warp(STALE_AT + 3600);
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtOutageExpiredLatched(uint64(STALE_AT), uint64(STALE_AT + 3600));
        _poke();
        vm.warp(STALE_AT + 5000);
        assertEq(_pokeCount(LATCH), 0, "the latch is set once");
        assertEq(uint8(_state()), uint8(PriceState.Expired));
    }

    // TEST-219 verifies: REQ-ORACLE-030, REQ-ORACLE-032, REQ-ORACLE-033, REQ-ORACLE-034, REQ-ORACLE-092
    // Sources: 2.10 REQ-ORACLE-033 (each outage starts at most one grace window), REQ-ORACLE-032
    /// @notice A latched outage recovers and starts one grace window, which clears the latch; a second outage of the
    /// same kind later latches again and its recovery starts a second grace window with a later `recoveredAt`.
    function test_TEST_219_graceClearsTheLatchForTheNextOutage() public {
        vm.warp(STALE_AT + 3600);
        _poke();
        uint256 back1 = STALE_AT + 4000;
        vm.warp(back1);
        _refreshAll();
        assertEq(_pokeCount(GRACE), 1, "first recovery");
        uint64 first = oracle.getPriceState().recoveredAt;
        assertEq(first, back1);
        // Second outage: every feed silent again from back1.
        uint256 stale2 = back1 + 88_201;
        vm.warp(stale2 + 3600);
        assertEq(_pokeCount(LATCH), 1, "the second outage latches again");
        uint256 back2 = stale2 + 4000;
        vm.warp(back2);
        _refreshAll();
        assertEq(_pokeCount(GRACE), 1, "second recovery");
        DebtPriceView memory v = oracle.getPriceState();
        assertGt(v.recoveredAt, first);
        assertTrue(v.inGrace);
    }

    // TEST-231 verifies: REQ-ORACLE-032, REQ-ORACLE-095, REQ-ORACLE-065
    // Sources: 2.10 REQ-ORACLE-032 (a: a switch observed while latched starts grace at the poke)
    /// @notice A standby switch observed while nothing is latched starts no grace window; the same switch while latched
    /// starts one at the poke's time, flagged `fromLatch`.
    function test_TEST_231_versionChangeStartsGraceOnlyWhileLatched() public {
        vm.warp(T0 + 1000);
        reg.useStandby(usdc, RouteSlot.Primary);
        standby.push(99_995_000, T0 + 1000);
        assertEq(_pokeCount(GRACE), 0, "not latched");
        reg.restore(usdc);
        _poke();
        vm.warp(STALE_AT + 3600);
        _poke();
        uint256 t = STALE_AT + 3700;
        vm.warp(t);
        reg.useStandby(usdc, RouteSlot.Primary);
        standby.push(99_995_000, t - 10);
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtGraceStarted(uint64(t), uint64(t + 1800), true);
        _poke();
    }
}
