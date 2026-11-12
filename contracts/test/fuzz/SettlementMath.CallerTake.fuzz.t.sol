// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SettlementMath} from "../../src/liquidation/lp-vault-swap/SettlementMath.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {SettlementMathHarness} from "../utils/harness/SettlementMathHarness.sol";

/// @title SettlementMathCallerTakeFuzzTest
/// @notice The caller's take in a liquidation (no flash term), over every seizure value, debt, funding `Kf ≥ D`,
/// recovery, floor and fee share within the spec bounds: the take `keeperOut − Kf` never exceeds `G − A` (2.11
/// `SPEC-LIQ-011`), equals `kr` whenever `R' ≥ D` (`SPEC-LIQ-010`), and the leftover `Kf − D` passes through to
/// `keeperOut` one for one without moving `A`, `kr`, `B` or the top-up (`SPEC-LIQ-017`, `SPEC-LIQ-019`).
contract SettlementMathCallerTakeFuzzTest is AvanaTest {
    SettlementMathHarness internal m;

    struct Case {
        uint256 value;
        uint256 debt;
        uint256 callerFunds;
        uint256 minRec;
        uint256 recovered;
        uint256 share;
    }

    struct Settled {
        uint256 shortfall;
        SettlementMath.Payouts p;
        uint256 keeperOut;
    }

    function setUp() public {
        m = new SettlementMathHarness();
    }

    function _bound(
        Case memory c
    ) internal pure {
        c.value = bound(c.value, 0, (1 << 121) - 1);
        c.debt = bound(c.debt, 0, (1 << 120) - 1);
        c.callerFunds = bound(c.callerFunds, c.debt, (1 << 121) - 1); // Aave pulls D out of Kf
        c.minRec = bound(c.minRec, 0, c.value); // the floor never exceeds V
        c.recovered = bound(c.recovered, 0, (1 << 121) - 1);
        c.share = bound(c.share, 0, 5000); // avanaFeeShareBps bound
    }

    function _settle(
        Case memory c
    ) internal view returns (Settled memory o) {
        o.p = m.payouts(c.value, c.debt, m.recoveryWithFloor(c.minRec, c.recovered), c.share);
        uint256 gap = m.roundingGap(c.debt, o.p.avanaFee, o.p.borrowerSurplus, c.callerFunds, c.recovered);
        o.shortfall = m.shortfallTopUp(c.minRec, c.recovered, gap, type(uint128).max);
        o.keeperOut =
            m.keeperPayout(c.callerFunds, c.recovered + o.shortfall, c.debt, o.p.avanaFee, o.p.borrowerSurplus);
    }

    // TEST-198 verifies: SPEC-LIQ-011, SPEC-LIQ-010, SPEC-LIQ-019, SPEC-LIQ-022, INV-035, Q-401
    // Sources: MATH-ST-96, MATH-ST-97, SYM-48a–b
    function testFuzz_TEST_198_callerTakeAtMostGainLessFee(
        Case memory c
    ) public view {
        _bound(c);
        Settled memory o = _settle(c);
        uint256 gainLessFee = o.p.oracleGain - o.p.avanaFee;
        assertLe(o.p.keeperReward, gainLessFee, "kr above G - A");
        assertLe(o.keeperOut, c.callerFunds + gainLessFee, "caller take above G - A");
        uint256 floorGap = c.minRec > c.recovered ? c.minRec - c.recovered : 0;
        assertEq(o.shortfall, floorGap, "the settlement gap never exceeds the floor gap while Kf >= D");
        uint256 recoveredWithTopUp = c.recovered + o.shortfall;
        if (recoveredWithTopUp >= c.debt) {
            assertEq(o.keeperOut, c.callerFunds + o.p.keeperReward, "keeperOut = Kf + kr");
        } else {
            assertEq(o.keeperOut, c.callerFunds - (c.debt - recoveredWithTopUp), "keeperOut = Kf - (D - R')");
        }
    }

    // TEST-198 verifies: SPEC-LIQ-017, SPEC-LIQ-010, SPEC-LIQ-019, Q-333
    // Sources: MATH-ST-15, MATH-ST-52, MATH-ST-70
    function testFuzz_TEST_198_leftoverPassesThrough(
        Case memory c,
        uint256 extra
    ) public view {
        _bound(c);
        extra = bound(extra, 0, (1 << 120) - 1);
        Settled memory base = _settle(c);
        c.callerFunds += extra;
        Settled memory more = _settle(c);
        assertEq(more.keeperOut, base.keeperOut + extra, "leftover not returned one for one");
        assertEq(more.shortfall, base.shortfall, "top-up moved with Kf");
        assertEq(more.p.avanaFee, base.p.avanaFee, "A moved with Kf");
        assertEq(more.p.keeperReward, base.p.keeperReward, "kr moved with Kf");
        assertEq(more.p.borrowerSurplus, base.p.borrowerSurplus, "B moved with Kf");
    }
}
