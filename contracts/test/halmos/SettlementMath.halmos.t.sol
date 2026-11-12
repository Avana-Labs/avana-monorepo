// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {SettlementMath} from "../../src/liquidation/lp-vault-swap/SettlementMath.sol";
import {SettlementMathHarness} from "../utils/harness/SettlementMathHarness.sol";
import {Test} from "forge-std/Test.sol";

/// @title SettlementMathHalmosTest
/// @notice Symbolic checks of the settlement arithmetic for every input inside the bounds of 5.2: the waterfall
/// identity and its split (PROP-015), the effective slippage inequality (PROP-017), the rounding of the recovery floor
/// (PROP-018) and the floor covering the debt, its rounding terms (PROP-048), the caller's
/// top-up closing the floor and the settlement gap (PROP-019, restated arithmetic of CVL `callerTopUpClosesTheGap`),
/// a call within its `maxShortfall` always settling (PROP-015), the leg slippage, unit and pending values, and the
/// Avana fee (PROP-069). Every amount is in base units of the repaid debt asset; no liquidation term carries a flash
/// principal, premium or transfer fee (Q-404).
/// @dev Functions are called directly as internal library code, except where a check reads a revert: those go through
/// `SettlementMathHarness` with a low-level call.
contract SettlementMathHalmosTest is Test {
    uint256 internal constant BPS = 10_000;

    SettlementMathHarness internal h;

    function setUp() public {
        h = new SettlementMathHarness();
    }

    // PROP-015 verifies: SPEC-LIQ-008, SPEC-LIQ-009, SPEC-LIQ-010, SPEC-LIQ-022, INV-035, INV-036, Q-097, Q-127, Q-256, Q-337, Q-397
    /// @notice With inputs below 2^128, `avanaFeeShareBps ≤ 10⁴` and a completed call (`keeperOut ≥ 0`):
    /// `Kf + R + shortfall == D + A + B + keeperOut`, `A ≤ S`, `A + kr + B == S`, `B == max(0, S − G)`; and
    /// `keeperPayout` reverts with `InsufficientProceeds` exactly when `keeperOut` would be negative.
    function check_PROP_015_settlementIdentity(
        uint256 callerFunds,
        uint256 recovered,
        uint256 shortfall,
        uint256 debt,
        uint256 value,
        uint256 share
    ) public {
        vm.assume(callerFunds < 2 ** 128 && recovered < 2 ** 128);
        vm.assume(shortfall < 2 ** 128 && debt < 2 ** 128 && value < 2 ** 128);
        vm.assume(share <= BPS);
        SettlementMath.Payouts memory p = SettlementMath.payouts(value, debt, recovered + shortfall, share);
        assert(p.avanaFee <= p.surplus);
        assert(p.avanaFee + p.keeperReward + p.borrowerSurplus == p.surplus);
        assert(p.borrowerSurplus == (p.surplus > p.oracleGain ? p.surplus - p.oracleGain : 0));
        _checkIdentity(Flows(callerFunds, recovered, shortfall, debt), p);
    }

    /// @dev The debt-asset flows of one call: `Kf`, `R`, `shortfall` and `D`.
    struct Flows {
        uint256 callerFunds;
        uint256 recovered;
        uint256 shortfall;
        uint256 debt;
    }

    function _checkIdentity(
        Flows memory c,
        SettlementMath.Payouts memory p
    ) internal {
        uint256 inflow = c.callerFunds + c.recovered + c.shortfall;
        uint256 outflow = c.debt + p.avanaFee + p.borrowerSurplus;
        bytes memory data = abi.encodeCall(
            SettlementMathHarness.keeperPayout,
            (c.callerFunds, c.recovered + c.shortfall, c.debt, p.avanaFee, p.borrowerSurplus)
        );
        (bool ok, bytes memory ret) = address(h).call(data);
        if (inflow >= outflow) {
            assert(ok);
            assert(inflow == outflow + abi.decode(ret, (uint256)));
        } else {
            assert(!ok && bytes4(ret) == ILPVaultSwapErrors.InsufficientProceeds.selector);
        }
    }

    // PROP-015 verifies: SPEC-LIQ-009, SPEC-LIQ-010, SPEC-LIQ-022, INV-035, INV-036, Q-256
    /// @notice The 2.11 example in USDC base units: `Kf = D = 1,950`, `V = 2,047.5`, `R = 2,040.3` give `S = 90.3`,
    /// `G = 97.5`, `A = 19.5`, `kr = 70.8`, `B = 0` and `keeperOut = Kf + kr = 2,020.8`.
    function check_PROP_015_waterfallExample() public pure {
        SettlementMath.Payouts memory p = SettlementMath.payouts(2_047_500_000, 1_950_000_000, 2_040_300_000, 2000);
        assert(p.surplus == 90_300_000 && p.oracleGain == 97_500_000 && p.avanaFee == 19_500_000);
        assert(p.keeperReward == 70_800_000 && p.borrowerSurplus == 0);
        uint256 out = SettlementMath.keeperPayout(1_950_000_000, 2_040_300_000, 1_950_000_000, p.avanaFee, 0);
        assert(out == 2_020_800_000);
    }

    // PROP-017 verifies: SPEC-LIQ-001, SPEC-LIQ-002, SPEC-LIQ-003, INV-034, Q-159, Q-190, Q-235, Q-404
    /// @notice For `b ∈ [10⁴, 2·10⁴]` and any allowance ≤ 10⁴: `s ≤ allowance`; `b × (10⁴ − s) ≥ 10⁸`; if `b > 10⁴`
    /// the cap equals `10⁴ − ⌈10⁸ / b⌉`, else `s = 0`; at `lf = 0` the net bonus is `b`. A liquidation has no cost term.
    function check_PROP_017_effectiveSlippageCoversDebt(
        uint256 b,
        uint256 allowance
    ) public pure {
        vm.assume(b >= BPS && b <= 2 * BPS && allowance <= BPS);
        assert(SettlementMath.netBonus(b, 0) == b);
        uint256 s = SettlementMath.effectiveSlippage(b, allowance);
        assert(s <= allowance);
        assert(b * (BPS - s) >= BPS * BPS);
        if (b > BPS) {
            uint256 cap = SettlementMath.effectiveSlippage(b, BPS);
            assert(cap == BPS - (BPS * BPS + b - 1) / b);
        } else {
            assert(s == 0);
        }
    }

    // PROP-018 verifies: SPEC-LIQ-005, INV-034, Q-085, Q-159, Q-198
    /// @notice For `V ≤ 10²⁶` and `s ≤ 10⁴`: the slippage term `⌈V × (10⁴ − s) / 10⁴⌉` is at least the exact net value
    /// and below it plus 1, and `minRec + U + ε` covers it for every `U`, `ε`.
    function check_PROP_018_minRecoveryRounding(
        uint256 v,
        uint256 s,
        uint256 units,
        uint256 allowance
    ) public pure {
        vm.assume(v <= 1e26 && s <= BPS && units <= 1e30 && allowance <= 1e30);
        uint256 gross = SettlementMath.recoveryFloor(v, s, 0, 0);
        assert(gross * BPS >= v * (BPS - s));
        assert(gross * BPS < v * (BPS - s) + BPS);
        uint256 minRec = SettlementMath.recoveryFloor(v, s, units, allowance);
        assert(minRec + units + allowance >= gross);
        assert(minRec <= gross);
    }

    // PROP-048 verifies: SPEC-LIQ-005, INV-034, Q-159, Q-198
    /// @notice The floor never asks for more than the net oracle value, and an unwind that loses at most `U` (one raw
    /// unit per token) against it passes the floor, down to a dust seizure.
    function check_PROP_048_floorWithRoundingTerms(
        uint256 v,
        uint256 s,
        uint256 units,
        uint256 allowance,
        uint256 recovered
    ) public pure {
        vm.assume(v <= 1e26 && s <= BPS && units >= 1 && units <= 1e30 && allowance >= 1 && allowance <= 1e30);
        vm.assume(recovered <= 1e27 && recovered * BPS + units * BPS >= v * (BPS - s));
        uint256 minRec = SettlementMath.recoveryFloor(v, s, units, allowance);
        assert(minRec * BPS <= v * (BPS - s));
        assert(recovered >= minRec);
    }

    // PROP-019 verifies: SPEC-LIQ-019, SPEC-SET-001, REQ-SWAP-029, INV-034, INV-038, Q-190, Q-397
    /// @notice The caller's top-up: the gap is `max(0, D + A + B − Kf − R)`; `shortfallTopUp` reverts with
    /// `RecoveryBelowFloor` iff `minRec − R > maxShortfall`, else with `InsufficientProceeds` iff `g > maxShortfall`,
    /// and otherwise returns `max(0, minRec − R, g) ≤ maxShortfall` with `R + shortfall ≥ minRec` and
    /// `Kf + R + shortfall ≥ D + A + B`: no Avana funds close a settlement.
    function check_PROP_019_callerTopUpClosesGap(
        uint256 minRec,
        uint256 recovered,
        uint256 debt,
        uint256 due,
        uint256 callerFunds,
        uint256 maxShortfall
    ) public {
        vm.assume(minRec < 2 ** 128 && recovered < 2 ** 128 && debt < 2 ** 128);
        vm.assume(due < 2 ** 128 && callerFunds < 2 ** 128 && maxShortfall < 2 ** 130);
        uint256 owed = debt + due;
        uint256 gap = SettlementMath.roundingGap(debt, due, 0, callerFunds, recovered);
        assert(gap == (owed > callerFunds + recovered ? owed - callerFunds - recovered : 0));
        (bool ok, bytes memory ret) = address(h)
            .call(abi.encodeCall(SettlementMathHarness.shortfallTopUp, (minRec, recovered, gap, maxShortfall)));
        uint256 floorGap = minRec > recovered ? minRec - recovered : 0;
        if (floorGap > maxShortfall) {
            assert(!ok && bytes4(ret) == ILPVaultSwapErrors.RecoveryBelowFloor.selector);
        } else if (gap > maxShortfall) {
            assert(!ok && bytes4(ret) == ILPVaultSwapErrors.InsufficientProceeds.selector);
        } else {
            assert(ok);
            uint256 shortfall = abi.decode(ret, (uint256));
            assert(shortfall == (floorGap > gap ? floorGap : gap) && shortfall <= maxShortfall);
            assert(recovered + shortfall >= minRec);
            assert(callerFunds + recovered + shortfall >= owed);
        }
    }

    // PROP-015 verifies: SPEC-LIQ-008, SPEC-LIQ-010, SPEC-LIQ-019, SPEC-SET-001, REQ-SWAP-061, REQ-SWAP-062, Q-397, Q-404
    /// @notice A caller-funded call always settles: with `Kf ≥ D` (Aave pulls `D` out of `Kf`), the gap never exceeds
    /// the floor gap, the top-up is `max(0, minRec − R)` and `keeperPayout` never reverts; the waterfall reads
    /// `R_f = max(R, minRec)`, so the top-up never counts as surplus beyond the floor. The fee share is the launch
    /// 2,000 bps (a symbolic share makes the fee product nonlinear; the 10,000-run fuzz twin
    /// `testFuzz_TEST_198_callerFundingAlwaysSettles` covers it).
    function check_PROP_015_gapSettlesWithoutRevert(
        uint256 value,
        uint256 debt,
        uint256 extraFunding,
        uint256 minRec,
        uint256 recovered
    ) public {
        vm.assume(value < 2 ** 120 && debt < 2 ** 120 && extraFunding < 2 ** 120);
        vm.assume(minRec <= value && recovered < 2 ** 120);
        uint256 callerFunds = debt + extraFunding;
        Flows memory c = Flows(callerFunds, recovered, 0, debt);
        SettlementMath.Payouts memory p =
            SettlementMath.payouts(value, debt, SettlementMath.recoveryWithFloor(minRec, recovered), 2000);
        uint256 gap = SettlementMath.roundingGap(debt, p.avanaFee, p.borrowerSurplus, callerFunds, recovered);
        uint256 floorGap = minRec > recovered ? minRec - recovered : 0;
        assert(gap <= floorGap);
        c.shortfall = floorGap;
        _checkSettles(c, p);
    }

    function _checkSettles(
        Flows memory c,
        SettlementMath.Payouts memory p
    ) internal {
        (bool ok, bytes memory ret) = address(h)
            .call(
                abi.encodeCall(
                    SettlementMathHarness.keeperPayout,
                    (c.callerFunds, c.recovered + c.shortfall, c.debt, p.avanaFee, p.borrowerSurplus)
                )
            );
        assert(ok);
        assert(
            abi.decode(ret, (uint256)) + c.debt + p.avanaFee + p.borrowerSurplus
                == c.callerFunds + c.recovered + c.shortfall
        );
    }

    // PROP-018 verifies: SPEC-LIQ-003, SPEC-LIQ-004, SPEC-LIQ-005, SPEC-LIQ-007, INV-034, Q-159, Q-198
    /// @notice Main claim of PROP-018 on concrete markets of 2.11 (USDC debt, vault token of 18 decimals at $2.10;
    /// GHO debt, vault token of 6 decimals at $2.00), every debt `D < 2^64` base units and the bonuses 10,500 and
    /// 10,200: with Aave's seizure `c = ⌊D Pdebt 10^dv b / (10^dd Pc 10⁴)⌋`, `minRec` plus one vault-token unit, 1 debt
    /// unit, `U` and `ε` covers `D`.
    function check_PROP_018_floorCoversDebtUsdc(
        uint256 debt
    ) public pure {
        _floorCovers(debt, 10_500, 6, 18, 210_000_000);
    }

    // PROP-018 verifies: SPEC-LIQ-003, SPEC-LIQ-004, SPEC-LIQ-005, SPEC-LIQ-007, INV-034, Q-159, Q-198
    function check_PROP_018_floorCoversDebtGho(
        uint256 debt
    ) public pure {
        _floorCovers(debt, 10_200, 18, 6, 200_000_000);
    }

    function _floorCovers(
        uint256 debt,
        uint256 bonus,
        uint8 dd,
        uint8 dv,
        uint256 pc
    ) internal pure {
        vm.assume(debt >= 1 && debt < 2 ** 64);
        uint256 s = SettlementMath.effectiveSlippage(bonus, 100);
        uint256 c = debt * 1e8 * 10 ** dv * bonus / (10 ** dd * pc * BPS);
        uint256 v = SettlementMath.seizedValue(c, pc, dv, dd, 1e8);
        uint256 vaultUnit = SettlementMath.unitValue(pc, dv, dd, 1e8);
        uint256 eps = 10 ** dd;
        uint256 minRec = SettlementMath.recoveryFloor(v, s, 2, eps);
        assert(debt <= minRec + vaultUnit + 1 + 2 + eps);
    }

    // PROP-019 verifies: SPEC-LIQ-019
    /// @notice Leg slippage: `sLeg = min(9,999, s + min(maxShortfallBps, ⌊maxShortfall × 10⁴ / V⌋))`, with the added
    /// term 0 when `maxShortfall = 0` or `V = 0`, for every `maxShortfallBps` (the saturating shortcuts are exact). The
    /// symbolic division times out at the 60 s assertion limit; the 10,000-run fuzz twin is
    /// `testFuzz_TEST_198_legSlippageBounds` and the differential `testFuzz_TEST_198_differentialLegSlippage`.
    function check_PROP_019_legSlippage(
        uint256 s,
        uint256 maxShortfall,
        uint256 value,
        uint256 maxShortfallBps
    ) public pure {
        vm.assume(s <= BPS && maxShortfall < 2 ** 64 && value < 2 ** 64);
        uint256 relax = maxShortfall == 0 || value == 0 ? 0 : maxShortfall * BPS / value;
        if (relax > maxShortfallBps) relax = maxShortfallBps;
        uint256 want = s + relax > 9999 ? 9999 : s + relax;
        assert(SettlementMath.legSlippage(s, maxShortfall, value, maxShortfallBps) == want);
    }

    // PROP-018 verifies: SPEC-LIQ-005, SPEC-LIQ-014, SPEC-LIQ-018
    /// @notice Unit, leg and pending values for 6-decimal tokens against an 18-decimal $1 debt asset, prices below 2^64:
    /// the unit value is the ceiling and at least 1, the leg value the floor, the pending value the ceiling, of the exact
    /// value.
    function check_PROP_018_unitAndPendingValues(
        uint256 amount,
        uint256 price
    ) public pure {
        vm.assume(amount < 2 ** 64 && price >= 1 && price < 2 ** 64);
        uint256 quote = 1e8; // a $1 debt asset; symbolic quotes are covered by testFuzz_TEST_198_decimals6And18
        uint256 num = amount * price * 1e12; // 10^(18 - 6)
        uint256 u = SettlementMath.unitValue(price, 6, 18, quote);
        assert(u >= 1 && u * quote >= price * 1e12 && (u - 1) * quote < price * 1e12);
        uint256 lv = SettlementMath.legValue(amount, price, 6, 18, quote);
        assert(lv * quote <= num && (lv + 1) * quote > num);
        uint256 pv = SettlementMath.pendingLegValue(amount, price, 6, 18, quote);
        assert(pv * quote >= num && pv <= lv + 1);
    }

    // PROP-069 verifies: SPEC-LIQ-008, SPEC-LIQ-009, INV-036, INV-086, Q-256, Q-333
    /// @notice `A ≤ S = max(0, R' − D)` for every input in range, and `A = 0` when `R' ≤ D`.
    function check_PROP_069_feeAtMostSurplus(
        uint256 value,
        uint256 rp,
        uint256 debt,
        uint256 share
    ) public pure {
        vm.assume(value < 2 ** 128 && rp < 2 ** 128 && debt < 2 ** 128 && share <= BPS);
        SettlementMath.Payouts memory p = SettlementMath.payouts(value, debt, rp, share);
        assert(p.avanaFee <= p.surplus);
        if (rp <= debt) assert(p.avanaFee == 0);
    }

    // PROP-069 verifies: SPEC-LIQ-009, INV-036, INV-086, Q-256
    /// @notice `A` is non-decreasing in `V`.
    function check_PROP_069_feeMonotoneInValue(
        uint256 v1,
        uint256 v2,
        uint256 rp,
        uint256 debt,
        uint256 share
    ) public pure {
        vm.assume(v1 <= v2 && v2 < 2 ** 128 && rp < 2 ** 128 && debt < 2 ** 128 && share <= BPS);
        assert(
            SettlementMath.payouts(v1, debt, rp, share).avanaFee <= SettlementMath.payouts(v2, debt, rp, share).avanaFee
        );
    }

    // PROP-069 verifies: SPEC-LIQ-009, INV-086, Q-256
    /// @notice While `S` covers the oracle-gain fee, `A` does not depend on `R'`: no route choice or sandwich by the
    /// caller lowers it.
    function check_PROP_069_feeIndependentOfRecovery(
        uint256 value,
        uint256 rp1,
        uint256 rp2,
        uint256 debt,
        uint256 share
    ) public pure {
        vm.assume(value < 2 ** 128 && rp1 < 2 ** 128 && rp2 < 2 ** 128 && debt < 2 ** 128);
        vm.assume(share <= BPS);
        SettlementMath.Payouts memory p1 = SettlementMath.payouts(value, debt, rp1, share);
        SettlementMath.Payouts memory p2 = SettlementMath.payouts(value, debt, rp2, share);
        uint256 feeOnGain = p1.oracleGain * share / BPS;
        if (p1.surplus >= feeOnGain && p2.surplus >= feeOnGain) assert(p1.avanaFee == p2.avanaFee);
    }
}
