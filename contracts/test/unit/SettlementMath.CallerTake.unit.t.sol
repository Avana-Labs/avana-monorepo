// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SettlementMath} from "../../src/liquidation/lp-vault-swap/SettlementMath.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {SettlementMathHarness} from "../utils/harness/SettlementMathHarness.sol";

/// @title SettlementMathCallerTakeUnitTest
/// @notice Golden vectors of the caller's take in a liquidation, which takes no flash loan (`F = φ = φD = 0`): the
/// worked examples of 2.11 `SPEC-LIQ-011` (no in-kind cap: the caller's take is bounded by `kr ≤ G − A`) and
/// `SPEC-LIQ-017` (the leftover `Kf − D` returns inside `keeperOut`), run through the same steps LPVaultSwap takes after
/// its last route call: floor, waterfall, settlement gap, shortfall, `keeperOut`.
/// @dev USDC debt (6 decimals), `D = 1,950` USDC, `V = 2,047.5` USDC, `s = 100` bps, USDC and USDT legs (`U = 2`),
/// `ε = 1` USDC, `avanaFeeShareBps = 2,000`.
contract SettlementMathCallerTakeUnitTest is AvanaTest {
    uint256 internal constant USDC = 1e6;
    uint256 internal constant V = 2_047_500_000;
    uint256 internal constant D = 1950 * USDC;
    uint256 internal constant X = 2_047_500_000; // debtToCover with the Lens 5 % margin

    SettlementMathHarness internal m;

    struct Settled {
        uint256 shortfall;
        SettlementMath.Payouts p;
        uint256 keeperOut;
    }

    function setUp() public {
        m = new SettlementMathHarness();
    }

    function _settle(
        uint256 value,
        uint256 debt,
        uint256 callerFunds,
        uint256 minRec,
        uint256 recovered
    ) internal view returns (Settled memory o) {
        o.p = m.payouts(value, debt, 0, m.recoveryWithFloor(minRec, recovered), AVANA_FEE_SHARE_BPS);
        uint256 gap = m.roundingGap(debt, 0, 0, o.p.avanaFee, o.p.borrowerSurplus, callerFunds, recovered);
        o.shortfall = m.shortfallTopUp(minRec, recovered, gap, 0);
        o.keeperOut =
            m.keeperPayout(callerFunds, 0, recovered + o.shortfall, debt, 0, o.p.avanaFee, o.p.borrowerSurplus);
    }

    /// @notice `SPEC-LIQ-011` example: `G = 97.5` USDC and `kr ≤ 78` USDC after `A`. With routes at `R = 2,040.3` the
    /// caller gets back `Kf` plus `kr = 70.8`; with routes above the oracle value (`R = 2,052`) the cap binds,
    /// `kr = G − A = 78` exactly, and the 4.5 USDC above `V` is the borrower's.
    // TEST-198 verifies: SPEC-LIQ-011, SPEC-LIQ-022, SPEC-LIQ-010, Q-401
    // Sources: 2.11 SPEC-LIQ-011 and SPEC-LIQ-022 examples, MATH-ST-96, MATH-ST-97
    function test_TEST_198_callerTakeBoundedByKeeperReward() public view {
        uint256 minRec = m.recoveryFloor(V, 100, 2, USDC);
        assertEq(minRec, 2_026_024_998, "minRec = 2,027.025 - U - eps");
        Settled memory o = _settle(V, D, X, minRec, 2_040_300_000);
        assertEq(o.shortfall, 0, "R above the floor: no top-up");
        assertEq(o.p.oracleGain, 97_500_000, "G");
        assertEq(o.p.avanaFee, 19_500_000, "A = 20 % of G");
        assertEq(o.p.keeperReward, 70_800_000, "kr = S - A");
        assertEq(o.p.borrowerSurplus, 0, "B");
        assertLe(o.p.keeperReward, 78 * USDC, "kr <= G - A = 78 USDC");
        assertEq(o.keeperOut, X + o.p.keeperReward, "keeperOut = Kf + kr");
        assertEq(o.keeperOut, 2_118_300_000, "keeperOut = 2,118.3 USDC");

        o = _settle(V, D, X, minRec, 2052 * USDC);
        assertEq(o.p.keeperReward, 78 * USDC, "kr = G - A when the routes beat the oracle");
        assertEq(o.p.borrowerSurplus, 4_500_000, "B = R_f - max(V, D)");
        assertEq(o.keeperOut, X + 78 * USDC, "the caller's take stops at G - A");
    }

    /// @notice `SPEC-LIQ-017` example: of `Kf = 2,047.5` USDC Aave pulls `D = 1,950`; the 97.5 USDC leftover is neither
    /// swapped nor counted in `R` and returns inside `keeperOut = 2,118.3`. Funding exactly `D`, or 3,000 USDC, moves
    /// `keeperOut` one for one and leaves `A`, `kr`, `B` and the top-up unchanged.
    // TEST-198 verifies: SPEC-LIQ-017, SPEC-LIQ-010, SPEC-LIQ-019, Q-333
    // Sources: 2.11 SPEC-LIQ-017 and SPEC-LIQ-002 examples, MATH-ST-15, MATH-ST-52, MATH-ST-70
    function test_TEST_198_leftoverReturnsInsideKeeperOut() public view {
        uint256 minRec = m.recoveryFloor(V, 100, 2, USDC);
        Settled memory atX = _settle(V, D, X, minRec, 2_040_300_000);
        assertEq(atX.keeperOut - (X - D), 2_020_800_000, "keeperOut less the leftover = R - A - B = 2,020.8");
        Settled memory atD = _settle(V, D, D, minRec, 2_040_300_000);
        assertEq(atD.keeperOut, 2_020_800_000, "funding exactly D");
        Settled memory over = _settle(V, D, 3000 * USDC, minRec, 2_040_300_000);
        assertEq(over.keeperOut, 3_070_800_000, "an oversized debtToCover comes back whole");
        assertEq(over.p.avanaFee, atD.p.avanaFee, "A independent of Kf");
        assertEq(over.p.keeperReward, atD.p.keeperReward, "kr independent of Kf");
        assertEq(over.shortfall, atD.shortfall, "top-up independent of Kf");
    }

    /// @notice `SPEC-LIQ-008` dust example: `D = 3` USDC funded with `Kf = 3`, `V = 3.15`, `R = 2.95` above the floor.
    /// `S = 0`, so `A = kr = B = 0`, and the caller takes the 0.05 USDC loss: `keeperOut = 2.95`, below `Kf + G − A`.
    // TEST-198 verifies: SPEC-LIQ-011, SPEC-LIQ-008, SPEC-LIQ-010, REQ-SWAP-029, Q-397
    // Sources: 2.11 SPEC-LIQ-008 and REQ-SWAP-029 dust examples
    function test_TEST_198_dustCallerBearsTheLoss() public view {
        uint256 minRec = m.recoveryFloor(3_150_000, 100, 2, USDC);
        assertEq(minRec, 2_118_498, "minRec = 3.1185 - U - eps");
        Settled memory o = _settle(3_150_000, 3 * USDC, 3 * USDC, minRec, 2_950_000);
        assertEq(o.shortfall, 0, "no top-up above the floor");
        assertEq(o.p.surplus + o.p.avanaFee + o.p.keeperReward + o.p.borrowerSurplus, 0, "S = A = kr = B = 0");
        assertEq(o.keeperOut, 2_950_000, "keeperOut = Kf - (D - R)");
    }
}
