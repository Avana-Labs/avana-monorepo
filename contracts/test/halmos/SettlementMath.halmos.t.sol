// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapBase} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapBase.sol";
import {SettlementMath} from "../../src/liquidation/lp-vault-swap/SettlementMath.sol";
import {SettlementMathHarness} from "../utils/harness/SettlementMathHarness.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
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
/// `SettlementMathHarness` with a low-level call. Halmos abstracts a product of two symbolic values, a division and
/// `mulmod` as uninterpreted functions and falls back to their full 256-bit (or 512-bit) semantics only when the
/// abstract query has a model; that fallback is what ran out of the 5-hour budget. Several checks therefore assert that
/// the code returns a reference formula built from the same terms the code computes (`...Formula`, the
/// `unitAndPendingValues` cases), which holds on the terms alone, and the Z3 models MATH-ST-140…146
/// (`docs/spec/05-verification/z3/settlement/st18_halmos_reference_formulas.py`) prove the original inequalities
/// for those formulas in exact integers.
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
            assert(!ok && bytes4(ret) == ILPVaultSwapBase.InsufficientProceeds.selector);
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
    /// and below it plus 1, and `minRec + U + ε` covers it for every `U`, `ε`. Proved as a formula: for every
    /// `V ≤ 10²⁶`, `s ≤ 10⁴` and every `U`, `ε` (a superset of the earlier `U, ε ≤ 10³⁰`), `recoveryFloor(V, s, U, ε)`
    /// equals `subFloor(Math.ceilDiv(V × (10⁴ − s), 10⁴), U, ε)`, and the slippage term is the case `U = ε = 0`.
    /// MATH-ST-140 bounds `V × (10⁴ − s)` by 10³⁰ (no uint256 term wraps), MATH-ST-141 proves that OpenZeppelin's
    /// `Math.ceilDiv(P, 10⁴)` is `⌈P / 10⁴⌉` (the first two inequalities, with `subFloor(g, 0, 0) = g`) and
    /// MATH-ST-142 proves `0 ≤ minRec ≤ gross ≤ minRec + U + ε`. The earlier form asserted the inequalities on the
    /// product `V × (10⁴ − s)` of two symbolic values and ran out of the 5-hour budget.
    function check_PROP_018_minRecoveryRoundingFormula(
        uint256 v,
        uint256 s,
        uint256 units,
        uint256 allowance
    ) public pure {
        _recoveryFloorIsFormula(v, s, units, allowance);
    }

    // PROP-048 verifies: SPEC-LIQ-005, INV-034, Q-159, Q-198
    /// @notice The floor never asks for more than the net oracle value, and an unwind that loses at most `U` (one raw
    /// unit per token) against it passes the floor, down to a dust seizure. Proved as a formula: the code equals
    /// `subFloor(Math.ceilDiv(V × (10⁴ − s), 10⁴), U, ε)` for every `V ≤ 10²⁶`, `s ≤ 10⁴` and every `U`, `ε` (this
    /// check), and MATH-ST-143 proves for that formula, with `U ≥ 1` and `ε ≥ 1`, `minRec × 10⁴ ≤ V × (10⁴ − s)` and
    /// `R ≥ minRec` for every `R` with `R × 10⁴ + U × 10⁴ ≥ V × (10⁴ − s)` (the earlier domain had `U, ε ≤ 10³⁰` and
    /// `R ≤ 10²⁷`; the model has no upper bound). The earlier form ran out of the 5-hour budget on the product
    /// `V × (10⁴ − s)` of two symbolic values.
    function check_PROP_048_floorWithRoundingTermsFormula(
        uint256 v,
        uint256 s,
        uint256 units,
        uint256 allowance
    ) public pure {
        _recoveryFloorIsFormula(v, s, units, allowance);
    }

    /// @dev `recoveryFloor(V, s, U, ε) == subFloor(Math.ceilDiv(V × (10⁴ − s), 10⁴), U, ε)` for `V ≤ 10²⁶`, `s ≤ 10⁴`
    /// and every `U`, `ε`. The reference computes the product and calls the same `Math.ceilDiv`, so both sides are the
    /// same product and quotient terms and no query needs their semantics (MATH-ST-140…143 hold them).
    function _recoveryFloorIsFormula(
        uint256 v,
        uint256 s,
        uint256 units,
        uint256 allowance
    ) internal pure {
        vm.assume(v <= 1e26 && s <= BPS);
        uint256 gross = Math.ceilDiv(v * (BPS - s), BPS);
        assert(SettlementMath.recoveryFloor(v, s, units, allowance) == _subFloorRef(gross, units, allowance));
    }

    /// @dev `max(0, a − b − c)` in the branch order of `SettlementMath._subFloor`.
    function _subFloorRef(
        uint256 a,
        uint256 b,
        uint256 c
    ) internal pure returns (uint256) {
        if (a <= b) return 0;
        return a - b > c ? a - b - c : 0;
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
            assert(!ok && bytes4(ret) == ILPVaultSwapBase.RecoveryBelowFloor.selector);
        } else if (gap > maxShortfall) {
            assert(!ok && bytes4(ret) == ILPVaultSwapBase.InsufficientProceeds.selector);
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
    /// `R_f = max(R, minRec)`, so the top-up never counts as surplus beyond the floor. Split in two so that no query
    /// carries the fee quotient `⌊G × share / 10⁴⌋` together with the gap and payout sums (the single check, at the
    /// 2,000 bps default share, ran out of the 5-hour budget). This case: for every `V`, `D`, `R` below 2^120,
    /// `minRec ≤ V` and every share ≤ 10⁴, `payouts` on `R_f = recoveryWithFloor(minRec, R)` returns
    /// `S = max(0, max(R, minRec) − D)` and `A + B ≤ S`. `A + B ≤ S` follows from the path conditions of `payouts`
    /// alone (`kr = min(S, G) − A` does not underflow, `B = S − A − kr`), so no query needs the semantics of the fee
    /// product or quotient; `check_PROP_015_settlementIdentity` passes on the same terms.
    function check_PROP_015_gapSettlesWithoutRevertPayouts(
        uint256 value,
        uint256 debt,
        uint256 minRec,
        uint256 recovered,
        uint256 share
    ) public pure {
        vm.assume(value < 2 ** 120 && debt < 2 ** 120 && minRec <= value && recovered < 2 ** 120);
        vm.assume(share <= BPS);
        uint256 rf = SettlementMath.recoveryWithFloor(minRec, recovered);
        assert(rf == (recovered > minRec ? recovered : minRec));
        SettlementMath.Payouts memory p = SettlementMath.payouts(value, debt, rf, share);
        assert(p.surplus == _surplusOnFloor(minRec, recovered, debt));
        assert(p.avanaFee + p.borrowerSurplus <= p.surplus);
    }

    // PROP-015 verifies: SPEC-LIQ-008, SPEC-LIQ-010, SPEC-LIQ-019, SPEC-SET-001, REQ-SWAP-061, REQ-SWAP-062, Q-397, Q-404
    /// @notice The second case of `check_PROP_015_gapSettlesWithoutRevertPayouts`: for every `D`, `Kf − D`, `R` and
    /// `minRec` below 2^120 and every fee `A` and borrower surplus `B` with `A + B ≤ S = max(0, max(R, minRec) − D)`,
    /// the gap is at most `max(0, minRec − R)` (the `Gap` checks) and `keeperPayout` with that top-up does not revert
    /// and balances (the `Settles` checks). Coverage: every input of the single check (`minRec ≤ V < 2^120`, share
    /// 2,000) is an input of the `Payouts` case, which gives its `A`, `B` the bound `A + B ≤ S` with this `S`; `V` and
    /// the share reach the gap and the payout only through `A` and `B`. So the `Payouts` case and the four `AnyPayouts`
    /// checks cover the single check and extend it to every share ≤ 10⁴. The `AnyPayouts` checks are the two
    /// assertions, each split by `R ≥ minRec` (no floor gap, `S = max(0, R − D)`) and `R < minRec` (gap `minRec − R`,
    /// `S = max(0, minRec − D)`), and the `Settles` assertion further by `R_f ≤ D` (`S = 0`, so `A = B = 0`) and
    /// `R_f > D`, with `R_f = max(R, minRec)`: the sides together are every input, and the two assertions together are
    /// what one check asserts. Every term is a sum, a difference or a comparison. One check with both assertions did
    /// not complete within 1 hour over both sides (run 43742353540) nor over either side (run 43777240448); the `Gap`
    /// checks complete in about 1 minute, and the `Settles` assertion split only by the floor did not complete within
    /// 1 hour (run 43791210194), so the `Settles` checks use bitwuzla.
    function check_PROP_015_gapSettlesWithoutRevertAnyPayoutsGapAboveFloor(
        uint256 debt,
        uint256 extraFunding,
        uint256 minRec,
        uint256 recovered,
        uint256 fee,
        uint256 surplusToBorrower
    ) public pure {
        vm.assume(recovered >= minRec);
        _anyPayoutsGap(debt, extraFunding, minRec, recovered, fee, surplusToBorrower);
    }

    // PROP-015 verifies: SPEC-LIQ-008, SPEC-LIQ-010, SPEC-LIQ-019, SPEC-SET-001, REQ-SWAP-061, REQ-SWAP-062, Q-397, Q-404
    /// @notice The `Gap` assertion of `check_PROP_015_gapSettlesWithoutRevertAnyPayoutsGapAboveFloor` for a recovery
    /// below the floor.
    function check_PROP_015_gapSettlesWithoutRevertAnyPayoutsGapBelowFloor(
        uint256 debt,
        uint256 extraFunding,
        uint256 minRec,
        uint256 recovered,
        uint256 fee,
        uint256 surplusToBorrower
    ) public pure {
        vm.assume(recovered < minRec);
        _anyPayoutsGap(debt, extraFunding, minRec, recovered, fee, surplusToBorrower);
    }

    // PROP-015 verifies: SPEC-LIQ-008, SPEC-LIQ-010, SPEC-LIQ-019, SPEC-SET-001, REQ-SWAP-061, REQ-SWAP-062, Q-397, Q-404
    /// @notice The `Settles` assertion of `check_PROP_015_gapSettlesWithoutRevertAnyPayoutsGapAboveFloor` for
    /// a recovery at or above the floor and no surplus (`R ≤ D`).
    /// @custom:halmos --solver bitwuzla
    function check_PROP_015_gapSettlesWithoutRevertAnyPayoutsSettlesAboveFloorNoSurplus(
        uint256 debt,
        uint256 extraFunding,
        uint256 minRec,
        uint256 recovered,
        uint256 fee,
        uint256 surplusToBorrower
    ) public {
        vm.assume(recovered >= minRec && recovered <= debt);
        _anyPayoutsSettles(debt, extraFunding, minRec, recovered, fee, surplusToBorrower);
    }

    // PROP-015 verifies: SPEC-LIQ-008, SPEC-LIQ-010, SPEC-LIQ-019, SPEC-SET-001, REQ-SWAP-061, REQ-SWAP-062, Q-397, Q-404
    /// @notice The `Settles` assertion of `check_PROP_015_gapSettlesWithoutRevertAnyPayoutsGapAboveFloor` for
    /// a recovery at or above the floor and a surplus (`R > D`).
    /// @custom:halmos --solver bitwuzla
    function check_PROP_015_gapSettlesWithoutRevertAnyPayoutsSettlesAboveFloorSurplus(
        uint256 debt,
        uint256 extraFunding,
        uint256 minRec,
        uint256 recovered,
        uint256 fee,
        uint256 surplusToBorrower
    ) public {
        vm.assume(recovered >= minRec && recovered > debt);
        _anyPayoutsSettles(debt, extraFunding, minRec, recovered, fee, surplusToBorrower);
    }

    // PROP-015 verifies: SPEC-LIQ-008, SPEC-LIQ-010, SPEC-LIQ-019, SPEC-SET-001, REQ-SWAP-061, REQ-SWAP-062, Q-397, Q-404
    /// @notice The `Settles` assertion of `check_PROP_015_gapSettlesWithoutRevertAnyPayoutsGapAboveFloor` for
    /// a recovery below the floor and no surplus (`minRec ≤ D`).
    /// @custom:halmos --solver bitwuzla
    function check_PROP_015_gapSettlesWithoutRevertAnyPayoutsSettlesBelowFloorNoSurplus(
        uint256 debt,
        uint256 extraFunding,
        uint256 minRec,
        uint256 recovered,
        uint256 fee,
        uint256 surplusToBorrower
    ) public {
        vm.assume(recovered < minRec && minRec <= debt);
        _anyPayoutsSettles(debt, extraFunding, minRec, recovered, fee, surplusToBorrower);
    }

    // PROP-015 verifies: SPEC-LIQ-008, SPEC-LIQ-010, SPEC-LIQ-019, SPEC-SET-001, REQ-SWAP-061, REQ-SWAP-062, Q-397, Q-404
    /// @notice The `Settles` assertion of `check_PROP_015_gapSettlesWithoutRevertAnyPayoutsGapAboveFloor` for
    /// a recovery below the floor and a surplus (`minRec > D`).
    /// @custom:halmos --solver bitwuzla
    function check_PROP_015_gapSettlesWithoutRevertAnyPayoutsSettlesBelowFloorSurplus(
        uint256 debt,
        uint256 extraFunding,
        uint256 minRec,
        uint256 recovered,
        uint256 fee,
        uint256 surplusToBorrower
    ) public {
        vm.assume(recovered < minRec && minRec > debt);
        _anyPayoutsSettles(debt, extraFunding, minRec, recovered, fee, surplusToBorrower);
    }

    /// @dev The gap of the flows with `A`, `B` is at most the floor gap.
    function _anyPayoutsGap(
        uint256 debt,
        uint256 extraFunding,
        uint256 minRec,
        uint256 recovered,
        uint256 fee,
        uint256 surplusToBorrower
    ) internal pure {
        (Flows memory c, SettlementMath.Payouts memory p, uint256 floorGap) =
            _anyPayoutsInputs(debt, extraFunding, minRec, recovered, fee, surplusToBorrower);
        assert(
            SettlementMath.roundingGap(c.debt, p.avanaFee, p.borrowerSurplus, c.callerFunds, c.recovered) <= floorGap
        );
    }

    /// @dev The call settles with the floor gap as its top-up.
    function _anyPayoutsSettles(
        uint256 debt,
        uint256 extraFunding,
        uint256 minRec,
        uint256 recovered,
        uint256 fee,
        uint256 surplusToBorrower
    ) internal {
        (Flows memory c, SettlementMath.Payouts memory p, uint256 floorGap) =
            _anyPayoutsInputs(debt, extraFunding, minRec, recovered, fee, surplusToBorrower);
        c.shortfall = floorGap;
        _checkSettles(c, p);
    }

    /// @dev The inputs of the `AnyPayouts` checks: the flows `(Kf, R, 0, D)`, `A` and `B` from `p`, and the floor gap
    /// `max(0, minRec − R)`.
    function _anyPayoutsInputs(
        uint256 debt,
        uint256 extraFunding,
        uint256 minRec,
        uint256 recovered,
        uint256 fee,
        uint256 surplusToBorrower
    ) internal pure returns (Flows memory c, SettlementMath.Payouts memory p, uint256 floorGap) {
        vm.assume(debt < 2 ** 120 && extraFunding < 2 ** 120 && minRec < 2 ** 120 && recovered < 2 ** 120);
        uint256 surplus = _surplusOnFloor(minRec, recovered, debt);
        vm.assume(fee <= surplus && surplusToBorrower <= surplus - fee);
        p.avanaFee = fee;
        p.borrowerSurplus = surplusToBorrower;
        c = Flows(debt + extraFunding, recovered, 0, debt);
        floorGap = minRec > recovered ? minRec - recovered : 0;
    }

    /// @dev `S = max(0, R_f − D)` with `R_f = max(R, minRec)`.
    function _surplusOnFloor(
        uint256 minRec,
        uint256 recovered,
        uint256 debt
    ) internal pure returns (uint256) {
        uint256 rf = recovered > minRec ? recovered : minRec;
        return rf > debt ? rf - debt : 0;
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
    /// @notice Leg slippage, `sLeg = min(9,999, s + min(maxShortfallBps, ⌊maxShortfall × 10⁴ / V⌋))`, split by case so
    /// no check divides by a symbolic value: a check with `maxShortfall` and `V` both symbolic ran out of the 5-hour
    /// budget in run 43677588077 with no counterexample. This case: the added term is 0 when `maxShortfall = 0` or
    /// `V = 0`, for every `s ≤ 10⁴` and every `maxShortfallBps`.
    function check_PROP_019_legSlippageNoRelax(
        uint256 s,
        uint256 maxShortfall,
        uint256 value,
        uint256 maxShortfallBps
    ) public pure {
        vm.assume(s <= BPS && (maxShortfall == 0 || value == 0) && maxShortfall < 2 ** 64 && value < 2 ** 64);
        assert(SettlementMath.legSlippage(s, maxShortfall, value, maxShortfallBps) == (s > 9999 ? 9999 : s));
    }

    // PROP-019 verifies: SPEC-LIQ-019
    /// @notice Leg slippage when `maxShortfall ≥ V > 0`: the quotient is at least 10⁴, so
    /// `sLeg = min(9,999, s + min(maxShortfallBps, 10⁴))` for every value below `2^64` and every `maxShortfallBps`.
    function check_PROP_019_legSlippageWide(
        uint256 s,
        uint256 maxShortfall,
        uint256 value,
        uint256 maxShortfallBps
    ) public pure {
        vm.assume(s <= BPS && value != 0 && maxShortfall >= value && maxShortfall < 2 ** 64);
        uint256 relax = maxShortfallBps < BPS ? maxShortfallBps : BPS;
        uint256 want = s + relax > 9999 ? 9999 : s + relax;
        assert(SettlementMath.legSlippage(s, maxShortfall, value, maxShortfallBps) == want);
    }

    // PROP-019 verifies: SPEC-LIQ-019
    /// @notice Leg slippage when `0 < maxShortfall < V`, with `s`, `maxShortfall` and `maxShortfallBps` symbolic, at
    /// `V = 3`. The four `legSlippageQuotient` checks take `V` from a literal (3, 10⁴ where the quotient is
    /// `maxShortfall` itself, the prime 999,999,937 and `2^64 − 1`, the largest value of the range); the 10,000-run
    /// fuzz twin `testFuzz_TEST_198_legSlippageBounds` and the differential `testFuzz_TEST_198_differentialLegSlippage`
    /// cover every `V`.
    function check_PROP_019_legSlippageQuotientV3(
        uint256 s,
        uint256 maxShortfall,
        uint256 maxShortfallBps
    ) public pure {
        _legSlippageQuotient(s, maxShortfall, 3, maxShortfallBps);
    }

    // PROP-019 verifies: SPEC-LIQ-019
    /// @notice `check_PROP_019_legSlippageQuotientV3` at `V = 10⁴`.
    function check_PROP_019_legSlippageQuotientV10000(
        uint256 s,
        uint256 maxShortfall,
        uint256 maxShortfallBps
    ) public pure {
        _legSlippageQuotient(s, maxShortfall, 10_000, maxShortfallBps);
    }

    // PROP-019 verifies: SPEC-LIQ-019
    /// @notice `check_PROP_019_legSlippageQuotientV3` at `V = 999,999,937`.
    function check_PROP_019_legSlippageQuotientVPrime(
        uint256 s,
        uint256 maxShortfall,
        uint256 maxShortfallBps
    ) public pure {
        _legSlippageQuotient(s, maxShortfall, 999_999_937, maxShortfallBps);
    }

    // PROP-019 verifies: SPEC-LIQ-019
    /// @notice `check_PROP_019_legSlippageQuotientV3` at `V = 2^64 − 1`.
    function check_PROP_019_legSlippageQuotientVMax(
        uint256 s,
        uint256 maxShortfall,
        uint256 maxShortfallBps
    ) public pure {
        _legSlippageQuotient(s, maxShortfall, 2 ** 64 - 1, maxShortfallBps);
    }

    /// @dev `sLeg = min(9,999, s + min(maxShortfallBps, ⌊maxShortfall × 10⁴ / V⌋))` for `0 < maxShortfall < V`.
    function _legSlippageQuotient(
        uint256 s,
        uint256 maxShortfall,
        uint256 value,
        uint256 maxShortfallBps
    ) internal pure {
        vm.assume(s <= BPS && maxShortfall != 0 && maxShortfall < value);
        uint256 relax = maxShortfall * BPS / value;
        if (relax > maxShortfallBps) relax = maxShortfallBps;
        uint256 want = s + relax > 9999 ? 9999 : s + relax;
        assert(SettlementMath.legSlippage(s, maxShortfall, value, maxShortfallBps) == want);
    }

    // PROP-018 verifies: SPEC-LIQ-005, SPEC-LIQ-014, SPEC-LIQ-018
    /// @notice Unit, leg and pending values for 6-decimal tokens against an 18-decimal $1 debt asset, prices below 2^64:
    /// the unit value is the ceiling and at least 1, the leg value the floor, the pending value the ceiling, of the exact
    /// value. A $1 debt asset (`Pdebt = 10⁸`); symbolic quotes are covered by `testFuzz_TEST_198_decimals6And18`.
    /// Split into the unit value (this case, every price) and the leg values (`...Leg`, every amount and price), and
    /// proved as formulas: the single check ran out of the 5-hour budget on `Math.mulDiv`, whose high half
    /// `mulmod(x, y, 2^256 − 1) − x × y` Halmos could not show to be 0 without the full 512-bit product. Here
    /// `unitValue(price, 6, 18, 10⁸) = mulDiv(1, Y, 10¹⁴, Ceil)` with `Y = price × 10¹⁸` equals
    /// `Y / 10¹⁴ + [mulmod(1, Y, 10¹⁴) > 0]`; MATH-ST-145 proves that formula at least 1, at least
    /// `price × 10¹² / 10⁸` and less than it plus 1 (the earlier assertions).
    function check_PROP_018_unitAndPendingValuesUnit(
        uint256 price
    ) public pure {
        vm.assume(price >= 1 && price < 2 ** 64);
        uint256 y = price * 1e18; // price × 10^dd, dd = 18
        // Y < 2^124, so mulmod(1, Y, 2^256 − 1) = Y by EVM semantics (MATH-ST-145): this excludes no price. It states
        // the fact on the term `Math.mulDiv` computes, so its branch on the high half of the product needs no 512-bit
        // division.
        vm.assume(mulmod(1, y, type(uint256).max) == y);
        uint256 u = SettlementMath.unitValue(price, 6, 18, 1e8);
        assert(u == y / 1e14 + SafeCast.toUint(mulmod(1, y, 1e14) > 0));
    }

    // PROP-018 verifies: SPEC-LIQ-005, SPEC-LIQ-014, SPEC-LIQ-018
    /// @notice The leg and pending values of `check_PROP_018_unitAndPendingValuesUnit`, for every amount below 2^64
    /// and price in `[1, 2^64)`: with `Y = price × 10¹⁸`, `legValue(amount, price, 6, 18, 10⁸) = (amount × Y) / 10¹⁴`
    /// and `pendingLegValue(...) = (amount × Y) / 10¹⁴ + [mulmod(amount, Y, 10¹⁴) > 0]`. MATH-ST-146 proves
    /// `amount × Y < 2^256 − 1` and, for these formulas, `lv × 10⁸ ≤ amount × price × 10¹² < (lv + 1) × 10⁸`,
    /// `pv × 10⁸ ≥ amount × price × 10¹²` and `pv ≤ lv + 1` (the earlier assertions). Together with the unit case this
    /// covers every input of the single check.
    function check_PROP_018_unitAndPendingValuesLeg(
        uint256 amount,
        uint256 price
    ) public pure {
        vm.assume(amount < 2 ** 64 && price >= 1 && price < 2 ** 64);
        uint256 y = price * 1e18; // price × 10^dd, dd = 18
        uint256 prod;
        unchecked {
            prod = amount * y; // below 2^188 (MATH-ST-146), so the product does not wrap
        }
        // amount × Y < 2^256 − 1, so mulmod(amount, Y, 2^256 − 1) = amount × Y by EVM semantics (MATH-ST-146): this
        // excludes no input. It states the fact on the terms `Math.mulDiv` computes (`x * y` and
        // `mulmod(x, y, not(0))`), so its branch on the high half of the product needs no 512-bit product.
        vm.assume(mulmod(amount, y, type(uint256).max) == prod);
        uint256 lv = SettlementMath.legValue(amount, price, 6, 18, 1e8);
        assert(lv == prod / 1e14);
        uint256 pv = SettlementMath.pendingLegValue(amount, price, 6, 18, 1e8);
        assert(pv == prod / 1e14 + SafeCast.toUint(mulmod(amount, y, 1e14) > 0));
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
    /// @notice `A` is non-decreasing in `V`. Proved as a formula: for every `V`, `R'`, `D` below 2^128 and share
    /// ≤ 10⁴, `payouts` returns `G = max(0, V − D)`, `S = max(0, R' − D)` and `A = min(⌊G × share / 10⁴⌋, S)`, and
    /// MATH-ST-144 proves that `G × share < 2^256` (the uint256 terms are the exact integers) and that the formula is
    /// non-decreasing in `V` for every share ≤ 10⁴. Coverage: each of the two values `v1 ≤ v2` of the earlier form is a
    /// `V` of this check, with the same `R'`, `D` and share. The earlier form compared `G1 × share` with `G2 × share`,
    /// two products of symbolic values, and ran out of the 5-hour budget; here the reference fee multiplies the same
    /// `oracleGain` term the code multiplies, so no query needs the semantics of the product or the division.
    function check_PROP_069_feeMonotoneInValueFormula(
        uint256 value,
        uint256 rp,
        uint256 debt,
        uint256 share
    ) public pure {
        vm.assume(value < 2 ** 128 && rp < 2 ** 128 && debt < 2 ** 128 && share <= BPS);
        SettlementMath.Payouts memory p = SettlementMath.payouts(value, debt, rp, share);
        assert(p.oracleGain == (value > debt ? value - debt : 0));
        assert(p.surplus == (rp > debt ? rp - debt : 0));
        uint256 feeOnGain = p.oracleGain * share / BPS;
        assert(p.avanaFee == (feeOnGain < p.surplus ? feeOnGain : p.surplus));
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
