// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {SettlementMath} from "../../src/liquidation/lp-vault-swap/SettlementMath.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {SettlementMathHarness} from "../utils/harness/SettlementMathHarness.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title SettlementMathFlashRepaymentFuzzTest
/// @notice TEST-198 in the debt asset: for 6- and 18-decimal debt assets and `Pdebt` across [0.5e8, 5,000e8], the
/// slippage inequality holds for the `s` SettlementMath computes and the recovery floor covers `D` within one
/// vault-unit value plus one base unit before its rounding terms (a liquidation has no flash term, Q-404). With it:
/// the rounding direction of every value, conservation of the waterfall with the caller's measured funding, the
/// shortfall rule, the `deleverage` flash bound and repay-with-collateral sizing, and no overflow at the bounds.
contract SettlementMathFlashRepaymentFuzzTest is AvanaTest {
    SettlementMathHarness internal m;

    function setUp() public {
        m = new SettlementMathHarness();
    }

    // TEST-198 verifies: SPEC-LIQ-015, REQ-FLASH-002, Q-235, Q-335
    function testFuzz_TEST_198_flashRepaymentRoundsUp(
        uint256 amount,
        uint256 premiumBps,
        uint256 maxFlashFeeBps
    ) public view {
        amount = bound(amount, 1, 1e32);
        premiumBps = bound(premiumBps, 0, MAX_FLASH_FEE_BPS);
        maxFlashFeeBps = bound(maxFlashFeeBps, 0, 100);
        uint256 repayment = Math.mulDiv(amount, BPS + premiumBps, BPS, Math.Rounding.Ceil);
        uint256 premium = repayment - amount;
        // Never below the exact value, above it by less than one base unit.
        assertGe(repayment * BPS, amount * (BPS + premiumBps), "repayment below exact");
        assertLt(repayment * BPS, amount * (BPS + premiumBps) + BPS, "repayment one unit above exact");
        bool within = m.flashPremiumWithinCap(premium, amount, maxFlashFeeBps);
        assertEq(within, premium * BPS <= maxFlashFeeBps * amount, "cap check differs from the exact inequality");
    }

    // TEST-198 verifies: SPEC-LIQ-004, SPEC-LIQ-005, SPEC-LIQ-018, Q-085, Q-235
    function testFuzz_TEST_198_decimals6And18(
        uint256 units,
        uint256 collateralPrice,
        uint256 debtPrice,
        uint8 decimalsCase
    ) public view {
        units = bound(units, 0, (1 << 120) - 1);
        collateralPrice = bound(collateralPrice, 1, (1 << 64) - 1);
        debtPrice = bound(debtPrice, 0.5e8, 5000e8);
        uint8 dd = decimalsCase % 2 == 0 ? 6 : 18;
        uint8 dv = (decimalsCase / 2) % 2 == 0 ? 6 : 18;
        uint256 num = units * collateralPrice * 10 ** dd;
        uint256 den = 10 ** dv * debtPrice;
        uint256 v = m.seizedValue(units, collateralPrice, dv, dd, debtPrice);
        assertLe(v * den, num, "V rounds up");
        assertGt((v + 1) * den, num, "V more than one unit low");
        // Leg values: the same formula with the token's decimals, down for legs, up for the pending value.
        v = m.legValue(units, collateralPrice, dv, dd, debtPrice);
        uint256 up = m.pendingLegValue(units, collateralPrice, dv, dd, debtPrice);
        assertLe(v * den, num, "Vleg rounds up");
        assertGe(up * den, num, "pending leg value rounds down");
        assertLe(up - v, 1, "floor and ceiling differ by more than 1");
        v = m.unitValue(collateralPrice, dv, dd, debtPrice);
        assertGe(v, 1, "unit value 0");
        assertGe(v * den, collateralPrice * 10 ** dd, "unit value rounds down");
    }

    // TEST-198 verifies: SPEC-LIQ-001, SPEC-LIQ-002, SPEC-LIQ-003, SPEC-LIQ-016, INV-034, Q-159, Q-190, Q-404
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_TEST_198_slippageInequality(
        uint256 bonus,
        uint256 liquidationFee,
        uint256 allowance
    ) public view {
        bonus = bound(bonus, 0, type(uint32).max);
        liquidationFee = bound(liquidationFee, 0, 2 * BPS);
        allowance = bound(allowance, 0, BPS);
        uint256 bNet = m.netBonus(bonus, liquidationFee);
        assertGe(bNet, BPS, "bNet below 1e4");
        if (bonus > BPS && liquidationFee < BPS) {
            assertLe(bNet, bonus, "bNet above b");
            assertGe(bNet * BPS, BPS * BPS + (bonus - BPS) * (BPS - liquidationFee) - BPS + 1, "bNet below floor");
        }
        if (liquidationFee == 0 && bonus >= BPS) assertEq(bNet, bonus, "bNet != b at lf 0");
        uint256 s = m.effectiveSlippage(bNet, allowance);
        assertLe(s, allowance, "s above the allowance");
        assertLt(s, BPS, "s reaches 100 %");
        if (bNet > BPS) {
            assertGe(bNet * (BPS - s), BPS * BPS, "slippage inequality fails");
            // The cap is the largest such s: one more bps breaks the inequality unless the allowance binds.
            if (s < allowance) assertLt(bNet * (BPS - s - 1), BPS * BPS, "cap not maximal");
        } else {
            assertEq(s, 0, "s > 0 without bonus room");
        }
    }

    // TEST-198 verifies: SPEC-LIQ-003, SPEC-LIQ-004, SPEC-LIQ-005, SPEC-LIQ-007, INV-034, INV-038, Q-159, Q-198, Q-235
    // Sources: MATH-ST-07 (gap <= one vault unit + 1), TEST-078 bound
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_TEST_198_floorCoversDebt(
        uint256 debt,
        uint256 bonus,
        uint256 collateralPrice,
        uint256 debtPrice,
        uint8 decimalsCase,
        uint256 allowance
    ) public view {
        FloorCase memory c;
        c.dd = decimalsCase % 2 == 0 ? 6 : 18;
        c.dv = (decimalsCase / 2) % 2 == 0 ? 6 : 18;
        c.debt = bound(debt, 1, c.dd == 18 ? 1e26 : 1e14);
        c.bonus = bound(bonus, BPS + 1, 15_000);
        c.pc = bound(collateralPrice, 1e6, 1e12);
        c.pd = bound(debtPrice, 0.5e8, 5000e8);
        c.s = m.effectiveSlippage(m.netBonus(c.bonus, 0), bound(allowance, 0, BPS));
        _checkFloorCovers(c);
    }

    struct FloorCase {
        uint256 debt;
        uint256 bonus;
        uint256 s;
        uint256 pc;
        uint256 pd;
        uint8 dd;
        uint8 dv;
    }

    function _checkFloorCovers(
        FloorCase memory c
    ) internal view {
        // Aave V4 sizing on the target branch with shares = assets and drawnIndex = RAY.
        uint256 units = Math.mulDiv(c.debt * c.pd, 10 ** c.dv * c.bonus, 10 ** c.dd * c.pc * BPS);
        uint256 v = m.seizedValue(units, c.pc, c.dv, c.dd, c.pd);
        uint256 vaultUnit = m.unitValue(c.pc, c.dv, c.dd, c.pd);
        uint256 owed = c.debt;
        assertLe(owed, Math.mulDiv(v, BPS - c.s, BPS, Math.Rounding.Ceil) + vaultUnit + 1, "slippage term short");
        uint256 eps = 10 ** c.dd;
        assertLe(owed, m.recoveryFloor(v, c.s, 2, eps) + 2 + eps + vaultUnit + 1, "gap above the TEST-078 bound");
    }

    // TEST-198 verifies: SPEC-LIQ-005, SPEC-LIQ-014, SPEC-LIQ-018, REQ-SWAP-100, INV-034, INV-083
    function testFuzz_TEST_198_floorsRoundAgainstTheCaller(
        uint256 value,
        uint256 slippage,
        uint256 units,
        uint256 allowance,
        uint256 legs
    ) public view {
        value = bound(value, 0, (1 << 200) - 1);
        slippage = bound(slippage, 0, BPS);
        // U is at least 1 (SPEC-LIQ-005: one raw unit of each released token, at least 1 debt unit, n >= 1). The
        // slippage term rounds up, so it is the subtracted U that keeps the floor at or below the net oracle value.
        units = bound(units, 1, 1e30);
        allowance = bound(allowance, 0, 1e30);
        legs = bound(legs, 1, 4);
        uint256 exactNum = value * (BPS - slippage);
        uint256 floor = m.recoveryFloor(value, slippage, units, allowance);
        uint256 term = Math.ceilDiv(exactNum, BPS);
        assertGe(term * BPS, exactNum, "slippage term rounds down");
        assertLt(term * BPS, exactNum + BPS, "slippage term above one unit of rounding");
        assertLe(floor * BPS, exactNum, "floor above the net oracle value");
        assertEq(floor, term > units + allowance ? term - units - allowance : 0, "floor formula");
        uint256 minOut = m.legMinOut(value, slippage, units, allowance, legs);
        assertGe(minOut, 1, "leg minimum 0");
        assertLe(minOut, value > 1 ? value : 1, "leg minimum above the leg value");
        assertGe(minOut, floor > 0 ? floor : 1, "leg minimum below the one-leg floor");
    }

    // TEST-198 verifies: SPEC-LIQ-019, REQ-SWAP-101, Q-251
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_TEST_198_legSlippageBounds(
        uint256 slippage,
        uint256 maxShortfall,
        uint256 value,
        uint256 maxShortfallBps
    ) public view {
        slippage = bound(slippage, 0, BPS);
        maxShortfall = bound(maxShortfall, 0, 1 << 128);
        value = bound(value, 0, (1 << 200) - 1);
        maxShortfallBps = bound(maxShortfallBps, 0, 5000);
        uint256 sLeg = m.legSlippage(slippage, maxShortfall, value, maxShortfallBps);
        uint256 relax = maxShortfall == 0 || value == 0 ? 0 : Math.min(maxShortfallBps, maxShortfall * BPS / value);
        assertEq(sLeg, Math.min(9999, slippage + relax), "sLeg formula");
        assertGe(sLeg, Math.min(slippage, 9999), "sLeg below s");
        assertLe(sLeg, 9999, "sLeg above 9,999");
    }

    struct GapCase {
        uint256 minRec;
        uint256 recovered;
        uint256 debt;
        uint256 payoutsDue;
        uint256 callerFunds;
        uint256 maxShortfall;
    }

    // TEST-198 verifies: SPEC-LIQ-019, SPEC-SET-001, REQ-SWAP-025, REQ-SWAP-060, REQ-SWAP-061, REQ-SWAP-029, INV-034, Q-397
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_TEST_198_shortfallClosesFloorAndGap(
        GapCase memory c
    ) public {
        c.minRec = bound(c.minRec, 0, 1 << 128);
        c.recovered = bound(c.recovered, 0, 1 << 128);
        c.debt = bound(c.debt, 0, 1 << 128);
        c.payoutsDue = bound(c.payoutsDue, 0, 1 << 128);
        c.callerFunds = bound(c.callerFunds, 0, 1 << 128);
        c.maxShortfall = bound(c.maxShortfall, 0, 1 << 129);
        uint256 owed = c.debt + c.payoutsDue;
        uint256 gap =
            m.roundingGap(c.debt, c.payoutsDue / 2, c.payoutsDue - c.payoutsDue / 2, c.callerFunds, c.recovered);
        assertGe(gap + c.callerFunds + c.recovered, owed, "gap does not close D + A + B");
        if (gap > 0) assertEq(gap + c.callerFunds + c.recovered, owed, "gap larger than needed");
        uint256 floorGap = c.minRec > c.recovered ? c.minRec - c.recovered : 0;
        if (floorGap > c.maxShortfall) {
            vm.expectRevert(ILPVaultSwapErrors.RecoveryBelowFloor.selector);
            m.shortfallTopUp(c.minRec, c.recovered, gap, c.maxShortfall);
        } else if (gap > c.maxShortfall) {
            vm.expectRevert(ILPVaultSwapErrors.InsufficientProceeds.selector);
            m.shortfallTopUp(c.minRec, c.recovered, gap, c.maxShortfall);
        } else {
            uint256 shortfall = m.shortfallTopUp(c.minRec, c.recovered, gap, c.maxShortfall);
            assertEq(shortfall, Math.max(floorGap, gap), "shortfall = max(0, minRec - R, g)");
            assertGe(c.recovered + shortfall, c.minRec, "R' below the floor");
            assertGe(c.callerFunds + c.recovered + shortfall, owed, "Kf + R' below D + A + B");
            assertLe(shortfall, c.maxShortfall, "shortfall above maxShortfall");
        }
    }

    struct FlowCase {
        uint256 value;
        uint256 debt;
        uint256 callerFunds;
        uint256 minRec;
        uint256 recovered;
        uint256 share;
    }

    // TEST-198 verifies: SPEC-LIQ-008, SPEC-LIQ-010, SPEC-LIQ-017, SPEC-LIQ-019, SPEC-SET-001, REQ-SWAP-029, REQ-SWAP-061, REQ-SWAP-062, INV-038, Q-397, Q-404
    // Sources: 2.11 SPEC-LIQ-019 (with D <= Kf the gap never exceeds the floor gap, so the defensive
    // InsufficientProceeds checks never fire and the floor top-up alone settles every call)
    function testFuzz_TEST_198_callerFundingAlwaysSettles(
        FlowCase memory c
    ) public view {
        c.debt = bound(c.debt, 0, (1 << 120) - 1);
        c.callerFunds = bound(c.callerFunds, c.debt, (1 << 121) - 1); // Kf >= D: Aave pulls D out of Kf
        c.value = bound(c.value, 0, (1 << 121) - 1);
        c.minRec = bound(c.minRec, 0, c.value);
        c.recovered = bound(c.recovered, 0, (1 << 121) - 1);
        c.share = bound(c.share, 0, 5000);
        uint256 rf = m.recoveryWithFloor(c.minRec, c.recovered);
        SettlementMath.Payouts memory p = m.payouts(c.value, c.debt, rf, c.share);
        uint256 gap = m.roundingGap(c.debt, p.avanaFee, p.borrowerSurplus, c.callerFunds, c.recovered);
        uint256 floorGap = c.minRec > c.recovered ? c.minRec - c.recovered : 0;
        assertLe(gap, floorGap, "g above the floor gap");
        uint256 shortfall = m.shortfallTopUp(c.minRec, c.recovered, gap, floorGap);
        assertEq(shortfall, floorGap, "shortfall = max(0, minRec - R)");
        uint256 out = m.keeperPayout(c.callerFunds, c.recovered + shortfall, c.debt, p.avanaFee, p.borrowerSurplus);
        assertEq(c.callerFunds + c.recovered + shortfall, c.debt + p.avanaFee + p.borrowerSurplus + out, "conservation");
        if (c.recovered + shortfall >= c.debt) {
            assertEq(out, c.callerFunds + p.keeperReward, "keeperOut = Kf + kr");
        } else {
            assertEq(out, c.callerFunds - (c.debt - c.recovered - shortfall), "keeperOut = Kf - (D - R')");
        }
        // The top-up never reaches the borrower: B is at most what the collateral itself produced above its oracle value.
        assertLe(p.borrowerSurplus, c.recovered > c.value ? c.recovered - c.value : 0, "top-up reached the borrower");
        if (shortfall > 0) assertEq(p.borrowerSurplus, 0, "B > 0 with a floor top-up");
    }

    // TEST-198 verifies: SPEC-LIQ-008, SPEC-LIQ-009, SPEC-LIQ-022, INV-036, INV-086, Q-256, Q-337
    function testFuzz_TEST_198_waterfallSplitsSurplus(
        uint256 value,
        uint256 debt,
        uint256 recoveredWithTopUp,
        uint256 share
    ) public view {
        value = bound(value, 0, (1 << 128) - 1);
        debt = bound(debt, 0, (1 << 128) - 1);
        recoveredWithTopUp = bound(recoveredWithTopUp, 0, (1 << 128) - 1);
        share = bound(share, 0, BPS);
        SettlementMath.Payouts memory p = m.payouts(value, debt, recoveredWithTopUp, share);
        assertEq(p.surplus, recoveredWithTopUp > debt ? recoveredWithTopUp - debt : 0, "S");
        assertEq(p.oracleGain, value > debt ? value - debt : 0, "G");
        assertEq(p.avanaFee, Math.min(p.oracleGain * share / BPS, p.surplus), "A");
        assertEq(p.avanaFee + p.keeperReward + p.borrowerSurplus, p.surplus, "A + kr + B != S");
        assertLe(p.avanaFee, p.surplus, "A above S");
        assertLe(p.keeperReward + p.avanaFee, p.oracleGain, "kr above G - A");
        assertEq(p.borrowerSurplus, p.surplus > p.oracleGain ? p.surplus - p.oracleGain : 0, "B != max(0, S - G)");
    }

    struct PayoutCase {
        uint256 callerFunds;
        uint256 recoveredWithTopUp;
        uint256 debt;
    }

    // TEST-198 verifies: SPEC-LIQ-010, REQ-SWAP-062, INV-035, Q-097, Q-397
    function testFuzz_TEST_198_keeperPayoutConservesDebtAsset(
        uint256 value,
        uint256 callerFunds,
        uint256 recoveredWithTopUp,
        uint256 debt
    ) public {
        PayoutCase memory c;
        c.callerFunds = bound(callerFunds, 0, (1 << 128) - 1);
        c.recoveredWithTopUp = bound(recoveredWithTopUp, 0, (1 << 128) - 1);
        c.debt = bound(debt, 0, (1 << 128) - 1);
        SettlementMath.Payouts memory p =
            m.payouts(bound(value, 0, (1 << 128) - 1), c.debt, c.recoveredWithTopUp, AVANA_FEE_SHARE_BPS);
        _checkKeeperOut(p, c);
    }

    function _checkKeeperOut(
        SettlementMath.Payouts memory p,
        PayoutCase memory c
    ) internal {
        uint256 inflow = c.callerFunds + c.recoveredWithTopUp;
        uint256 outflow = c.debt + p.avanaFee + p.borrowerSurplus;
        if (inflow < outflow) {
            vm.expectRevert(ILPVaultSwapErrors.InsufficientProceeds.selector);
            m.keeperPayout(c.callerFunds, c.recoveredWithTopUp, c.debt, p.avanaFee, p.borrowerSurplus);
            return;
        }
        uint256 out = m.keeperPayout(c.callerFunds, c.recoveredWithTopUp, c.debt, p.avanaFee, p.borrowerSurplus);
        assertEq(inflow, outflow + out, "T is created or kept");
        if (p.surplus > 0) assertEq(out, c.callerFunds + p.keeperReward, "keeperOut != Kf + kr");
        if (c.callerFunds >= c.debt) assertGe(out + c.debt, c.callerFunds, "keeperOut below Kf - D");
    }

    // TEST-198 verifies: SPEC-LIQ-009, INV-036, INV-086, Q-256
    function testFuzz_TEST_198_feeIndependentOfRouting(
        uint256 value,
        uint256 debt,
        uint256 r1,
        uint256 r2
    ) public view {
        value = bound(value, 0, (1 << 128) - 1);
        debt = bound(debt, 0, (1 << 128) - 1);
        r1 = bound(r1, 0, (1 << 128) - 1);
        r2 = bound(r2, 0, (1 << 128) - 1);
        SettlementMath.Payouts memory p1 = m.payouts(value, debt, r1, AVANA_FEE_SHARE_BPS);
        SettlementMath.Payouts memory p2 = m.payouts(value, debt, r2, AVANA_FEE_SHARE_BPS);
        uint256 feeOnGain = p1.oracleGain * AVANA_FEE_SHARE_BPS / BPS;
        if (p1.surplus >= feeOnGain && p2.surplus >= feeOnGain) assertEq(p1.avanaFee, p2.avanaFee, "fee moved");
        if (r1 <= r2) assertLe(p1.avanaFee, p2.avanaFee, "fee falls as R' rises");
        SettlementMath.Payouts memory pv = m.payouts(value + 1, debt, r1, AVANA_FEE_SHARE_BPS);
        assertGe(pv.avanaFee, p1.avanaFee, "fee falls as V rises");
    }

    // TEST-198 verifies: SPEC-LIQ-020, INV-089, Q-255
    function testFuzz_TEST_198_deleverageRepaysFlashWithinValue(
        uint256 value,
        uint256 slippage,
        uint256 units,
        uint256 maxFlashFeeBps,
        uint256 debt
    ) public view {
        value = bound(value, 0, (1 << 200) - 1);
        slippage = bound(slippage, 0, BPS);
        units = bound(units, 0, 1e30);
        maxFlashFeeBps = bound(maxFlashFeeBps, 0, 100);
        debt = bound(debt, 1, (1 << 200) - 1);
        uint256 allowance = units / 2;
        uint256 cap = m.deleverageCap(value, slippage, units, allowance, maxFlashFeeBps);
        uint256 gross = value * (BPS - slippage) / BPS;
        uint256 vnet = gross > units + allowance ? gross - units - allowance : 0;
        // Largest x with x (1e4 + maxFlashFeeBps) <= Vnet x 1e4.
        assertLe(cap * (BPS + maxFlashFeeBps), vnet * BPS, "repayment plus premium above Vnet");
        assertGt((cap + 1) * (BPS + maxFlashFeeBps), vnet * BPS, "cap not maximal");
        if (cap > 0) {
            uint256 x = m.deleverageRepayment(debt, cap, 0);
            assertEq(x, Math.min(debt, cap), "x != min(debt, cap)");
            uint256 premium = x * maxFlashFeeBps / BPS;
            assertLe(x + premium, vnet, "x + premium above Vnet");
            assertEq(m.deleverageAssetOut(vnet, x, premium), vnet - x - premium, "assetOut");
        }
    }

    // TEST-198 verifies: SPEC-LIQ-004, SPEC-LIQ-005, SPEC-LIQ-009, SPEC-LIQ-010, SPEC-LIQ-018, SPEC-LIQ-019, Q-235
    // No overflow at the bounds: V just below 2^200, waterfall terms just below 2^129, prices just below 2^64, units
    // just below 2^120, 6- and 18-decimal assets, and 36-decimal tokens.
    function testFuzz_TEST_198_noOverflowAtBounds(
        uint256 units,
        uint256 price,
        uint256 value,
        uint256 term,
        bool debt18
    ) public view {
        uint8 dd = debt18 ? 18 : 6;
        units = bound(units, (1 << 120) - 1e6, (1 << 120) - 1);
        price = bound(price, (1 << 64) - 1e6, (1 << 64) - 1);
        value = bound(value, (1 << 200) - 1e6, (1 << 200) - 1);
        term = bound(term, (1 << 129) - 1e6, (1 << 129) - 1);
        m.seizedValue(units, price, 6, dd, 0.5e8);
        m.legValue(units, price, 6, dd, 0.5e8);
        m.pendingLegValue(units, price, 6, dd, 0.5e8);
        m.unitValue(price, 6, dd, 0.5e8);
        m.seizedValue(units, price, 36, 36, 1);
        m.unitValue(price, 0, 36, 1);
        m.recoveryFloor(value, 0, term, term);
        m.legMinOut(value, 0, term, term, 1);
        m.legSlippage(9998, term, 1, 5000);
        m.legSlippage(0, type(uint256).max, value, 5000);
        m.deleverageCap(value, 0, term, term, 100);
        m.payouts(value, term, value, 5000);
        m.payouts(term, 0, term, BPS);
        m.roundingGap(term, term, term, 0, 0);
        m.keeperPayout(term, term, 0, 0, 0);
        m.flashPremiumWithinCap(type(uint256).max, type(uint256).max, 100);
        m.flashPremiumWithinCap(type(uint256).max, type(uint256).max, type(uint256).max);
        m.effectiveSlippage(type(uint32).max, BPS);
        m.netBonus(type(uint32).max, 0);
    }
}
