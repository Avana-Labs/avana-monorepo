// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {SettlementMath} from "../../src/liquidation/lp-vault-swap/SettlementMath.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {SettlementMathHarness} from "../utils/harness/SettlementMathHarness.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title SettlementMathUnitTest
/// @notice Golden vectors of SettlementMath: every worked example of 2.11 (USDC debt, 6 decimals; a vault token of 18
/// decimals at $2.10; USDC and USDT legs of 6 decimals, USDT at $0.9995), the 2.13 rounding-gap examples and the
/// boundary of each formula, recomputed exactly by the Z3 worked examples and the FV examples of the spec stage.
/// @dev Library side of TEST-198 (debt-asset settlement arithmetic). The LPVaultSwap rows that use the same examples
/// (TEST-051, TEST-232, TEST-233, TEST-239, TEST-240) check the flow and are written with LPVaultSwap.
contract SettlementMathUnitTest is AvanaTest {
    uint256 internal constant USDC = 1e6;
    uint256 internal constant P_USDT = 99_950_000;
    uint256 internal constant P_VAULT = 210_000_000;

    SettlementMathHarness internal m;

    function setUp() public {
        m = new SettlementMathHarness();
    }

    // TEST-198 verifies: SPEC-LIQ-001, SPEC-LIQ-002, SPEC-LIQ-003, INV-034, Q-159, Q-190, Q-404
    // Sources: 2.11 SPEC-LIQ-001…003 examples (no cost term: a liquidation takes no flash loan)
    function test_TEST_198_bonusAndSlippageExamples() public view {
        assertEq(m.netBonus(10_500, 0), 10_500, "bNet at lf 0");
        assertEq(m.netBonus(10_500, 1000), 10_450, "bNet at lf 1,000");
        assertEq(m.effectiveSlippage(10_500, 100), 100, "s = min(100, 476)");
        assertEq(m.effectiveSlippage(10_500, 1000), 476, "uncapped s at b 10,500");
        assertGe(10_500 * (BPS - 100), BPS * BPS, "10,500 x 9,900 >= 1e8");
        assertEq(m.effectiveSlippage(10_050, 1000), 49, "s at b 10,050");
        assertGe(10_050 * (BPS - 49), BPS * BPS, "10,050 x 9,951 >= 1e8");
        assertLt(10_050 * (BPS - 50), BPS * BPS, "one bp more would not cover D");
    }

    // TEST-198 verifies: SPEC-LIQ-001, SPEC-LIQ-003
    // Sources: MATH-ST-113 (bNet saturates outside Aave's bounds)
    function test_TEST_198_netBonusSaturatesOutsideAaveBounds() public view {
        assertEq(m.netBonus(BPS, 0), BPS, "no bonus");
        assertEq(m.netBonus(9000, 0), BPS, "b below 1e4");
        assertEq(m.netBonus(10_500, BPS), BPS, "lf = 1e4");
        assertEq(m.netBonus(2009, 15_892), BPS, "b < 1e4 and lf > 1e4 do not make a positive bonus");
        assertEq(m.effectiveSlippage(BPS, 100), 0, "bNet = 1e4 gives s = 0");
        assertEq(m.effectiveSlippage(9000, 100), 0, "bNet below 1e4 gives s = 0");
        assertEq(m.effectiveSlippage(10_001, 100), 0, "floor(1e4 / 10,001) = 0");
        assertEq(m.effectiveSlippage(10_002, 100), 1, "floor(2e4 / 10,002) = 1");
    }

    // TEST-198 verifies: SPEC-LIQ-004, SPEC-LIQ-005, INV-034, Q-085, Q-198, Q-267
    // Sources: 2.11 SPEC-LIQ-004/005 regular and dust examples, MATH-ST-81
    function test_TEST_198_valueAndRecoveryFloorExamples() public view {
        uint256 v = m.seizedValue(975e18, P_VAULT, 18, 6, PRICE_UNIT);
        assertEq(v, 2_047_500_000, "V = 2,047.5 USDC");
        uint256 u = 1 + m.unitValue(P_USDT, 6, 6, PRICE_UNIT);
        assertEq(u, 2, "U = 1 (USDC is T) + 1 (USDT)");
        assertEq(m.recoveryFloor(v, 100, u, USDC), 2_026_024_998, "minRec = 2,026.024998 USDC");
        uint256 vDust = m.seizedValue(1.5e18, P_VAULT, 18, 6, PRICE_UNIT);
        assertEq(vDust, 3_150_000, "dust V");
        assertEq(m.recoveryFloor(vDust, 100, u, USDC), 2_118_498, "dust minRec");
        assertGe(2_950_000, m.recoveryFloor(vDust, 100, u, USDC), "R = 2.95 USDC passes the dust floor");
        assertEq(m.recoveryFloor(100, 100, 2, USDC), 0, "floor saturates at 0");
    }

    // TEST-198 verifies: SPEC-LIQ-005, SPEC-LIQ-018, REQ-SWAP-121
    // Sources: 2.11 REQ-SWAP-121 DAI dust-leg example, MATH-ST-111
    function test_TEST_198_unitValueAndDustLeg() public view {
        assertEq(m.unitValue(PRICE_UNIT, 6, 6, PRICE_UNIT), 1, "USDC unit");
        assertEq(m.unitValue(1, 6, 6, PRICE_UNIT), 1, "a unit at the smallest price is worth at least 1");
        assertEq(m.unitValue(PRICE_UNIT, 6, 18, PRICE_UNIT), 1e12, "USDC unit in GHO wei");
        assertEq(m.unitValue(P_USDT, 6, 18, PRICE_UNIT), 999_500_000_000, "USDT unit in GHO wei");
        assertEq(m.unitValue(2 * PRICE_UNIT, 6, 6, PRICE_UNIT), 2, "a $2 token");
        assertEq(m.unitValue(100_000_001, 6, 6, PRICE_UNIT), 2, "rounded up");
        uint256 vLeg = m.legValue(7_349_976_535_931, 5_000_016, 18, 6, 70_000_000);
        uint256 uLeg = m.unitValue(5_000_016, 18, 6, 70_000_000);
        assertEq(vLeg, 0, "DAI leg value 0");
        assertEq(uLeg, 1, "DAI leg unit 1");
        assertTrue(m.isDustLeg(vLeg, uLeg), "dust leg");
        assertTrue(m.isDustLeg(1, 1), "Vleg = Uleg is dust");
        assertFalse(m.isDustLeg(2, 1), "Vleg > Uleg is swapped");
    }

    // TEST-198 verifies: SPEC-LIQ-018, REQ-SWAP-100, INV-083, Q-250
    // Sources: 2.11 SPEC-LIQ-018 example, MATH-ST-86
    function test_TEST_198_legMinOutExample() public view {
        uint256 vLeg = m.legValue(6_211_300_000, P_USDT, 6, 6, PRICE_UNIT);
        assertEq(vLeg, 6_208_194_350, "Vleg of 6,211.3 USDT");
        uint256 uLeg = m.unitValue(P_USDT, 6, 6, PRICE_UNIT);
        assertEq(m.legMinOut(vLeg, 100, uLeg, USDC, 1), 6_145_112_406, "minOut, one swapped leg");
        assertEq(m.legMinOut(2, 100, 1, USDC, 1), 1, "never 0");
        assertEq(m.legMinOut(0, 0, 0, 0, 1), 1, "never 0 at zero value");
        // 18-decimal debt (GHO): 6,211.3 USDC at sLeg 100, two legs, 1 GHO allowance (5.2 PROP-068 shape).
        uint256 vGho = m.legValue(6_211_300_000, PRICE_UNIT, 6, 18, PRICE_UNIT);
        assertEq(m.legMinOut(vGho, 100, 1e12, 1e18, 2), 6_148_686_999_000_000_000_000, "GHO leg minimum");
    }

    // TEST-198 verifies: SPEC-LIQ-019, REQ-SWAP-101, Q-251
    // Sources: 2.11 SPEC-LIQ-019 example, MATH-ST-86
    function test_TEST_198_legSlippageExamples() public view {
        uint256 v = 12_422_600_000;
        assertEq(m.legSlippage(100, 200 * USDC, v, 1000), 260, "maxShortfall 200 USDC");
        assertEq(m.legSlippage(100, 100 * USDC, v, 1000), 180, "maxShortfall 100 USDC");
        assertEq(m.legSlippage(100, 0, v, 1000), 100, "no top-up");
        assertEq(m.legSlippage(100, 200 * USDC, 0, 1000), 100, "V = 0");
        assertEq(m.legSlippage(100, v, v, 1000), 1100, "capped at maxShortfallBps");
        assertEq(m.legSlippage(9500, v, v, 1000), 9999, "capped at 9,999");
        assertEq(m.legSlippage(10_000, 0, v, 0), 9999, "s above the cap");
        assertEq(m.legSlippage(0, type(uint256).max, 1, type(uint256).max), 9999, "extremes saturate");
        assertEq(m.pendingSlippage(100), 30, "s_P = 30");
        assertEq(m.pendingSlippage(20), 20, "s_P below 30");
    }

    // TEST-198 verifies: SPEC-LIQ-019, SPEC-SET-001, REQ-SWAP-025, REQ-SWAP-060, REQ-SWAP-061, INV-034, Q-251, Q-397
    // Sources: 2.11 SPEC-LIQ-019 examples, 2.13 SPEC-SET-001 examples, MATH-ST-86, MATH-ST-88
    function test_TEST_198_shortfallTopUpExamples() public {
        uint256 v = 12_422_600_000;
        uint256 minRec = m.recoveryFloor(v, 100, 2, USDC);
        assertEq(minRec, 12_297_373_998, "minRec at V 12,422.6");
        assertEq(m.shortfallTopUp(minRec, 12_174 * USDC, 0, 200 * USDC), 123_373_998, "pulled 123.373998 USDC");
        vm.expectRevert(ILPVaultSwapErrors.RecoveryBelowFloor.selector);
        m.shortfallTopUp(minRec, 12_174 * USDC, 0, 123_373_997);
        // Dust: Kf = D = 3 USDC, R = 2.95 above the floor: g = max(0, 3 + 0 + 0 - 3 - 2.95) = 0, no top-up.
        uint256 gap = m.roundingGap(3 * USDC, 0, 0, 3 * USDC, 2_950_000);
        assertEq(gap, 0, "g = 0 with Kf = D");
        assertEq(m.shortfallTopUp(2_118_498, 2_950_000, gap, 0), 0, "settles with maxShortfall 0");
        // Defensive: a faulty measurement with Kf below D opens a gap the top-up must close.
        gap = m.roundingGap(3 * USDC, 0, 0, 0, 2_950_000);
        assertEq(gap, 50_000, "g = D - R with Kf = 0");
        assertEq(m.shortfallTopUp(2_118_498, 2_950_000, gap, 50_000), 50_000, "shortfall = g");
        vm.expectRevert(ILPVaultSwapErrors.InsufficientProceeds.selector);
        m.shortfallTopUp(2_118_498, 2_950_000, gap, 0);
        // Both fail: the floor error comes first.
        vm.expectRevert(ILPVaultSwapErrors.RecoveryBelowFloor.selector);
        m.shortfallTopUp(10, 0, 20, 5);
        assertEq(m.shortfallTopUp(10, 0, 20, 20), 20, "max of the floor gap and g");
        assertEq(m.shortfallTopUp(0, 5, 0, 0), 0, "nothing to pull");
        assertEq(m.roundingGap(1950 * USDC, 19_500_000, 0, 1950 * USDC, 2_040_300_000), 0, "routed example: no gap");
    }

    // TEST-198 verifies: SPEC-LIQ-008, SPEC-LIQ-009, SPEC-LIQ-010, SPEC-LIQ-022, INV-035, INV-036, INV-086, Q-256, Q-337
    // Sources: 2.11 SPEC-LIQ-008…010 and SPEC-LIQ-022 examples, REQ-SWAP-075 example
    function test_TEST_198_waterfallExamples() public view {
        uint256 v = 2_047_500_000;
        uint256 d = 1950 * USDC;
        SettlementMath.Payouts memory p = m.payouts(v, d, 2_040_300_000, AVANA_FEE_SHARE_BPS);
        assertEq(p.surplus, 90_300_000, "S = 90.3");
        assertEq(p.oracleGain, 97_500_000, "G = 97.5");
        assertEq(p.avanaFee, 19_500_000, "A = 19.5");
        assertEq(p.keeperReward, 70_800_000, "kr = 70.8");
        assertEq(p.borrowerSurplus, 0, "B");
        uint256 out = m.keeperPayout(d, 2_040_300_000, d, p.avanaFee, p.borrowerSurplus);
        assertEq(out, 2_020_800_000, "keeperOut = Kf + kr = 2,020.8");
        assertEq(d + 2_040_300_000, d + p.avanaFee + p.borrowerSurplus + out, "T in == T out (3,990.3)");
        // A caller that sandwiched its own routes to R = 2,027 USDC still pays A = 19.5.
        p = m.payouts(v, d, 2027 * USDC, AVANA_FEE_SHARE_BPS);
        assertEq(p.surplus, 77 * USDC, "S after a self-sandwich");
        assertEq(p.avanaFee, 19_500_000, "A unchanged");
        // REQ-SWAP-075: routes returning 2,035 USDC pay keeperOut 2,015.5.
        p = m.payouts(v, d, 2035 * USDC, AVANA_FEE_SHARE_BPS);
        assertEq(m.keeperPayout(d, 2035 * USDC, d, p.avanaFee, p.borrowerSurplus), 2_015_500_000, "keeperOut 2,015.5");
        // Routes better than the oracle: the excess goes to the borrower.
        p = m.payouts(v, d, 2052 * USDC, AVANA_FEE_SHARE_BPS);
        assertEq(p.surplus, 102 * USDC, "S at R 2,052");
        assertEq(p.keeperReward, 78 * USDC, "kr = G - A");
        assertEq(p.borrowerSurplus, 4_500_000, "B = R_f - max(V, D)");
        assertEq(m.keeperPayout(d, 2052 * USDC, d, p.avanaFee, p.borrowerSurplus), 2028 * USDC, "keeperOut 2,028");
        // Dust: R_f = max(2.95, 2.118498) = 2.95 USDC, so S = A = B = 0; keeperOut = 3 + 2.95 - 3 = 2.95.
        uint256 rf = m.recoveryWithFloor(2_118_498, 2_950_000);
        assertEq(rf, 2_950_000, "R_f = R above the floor");
        p = m.payouts(3_150_000, 3 * USDC, rf, AVANA_FEE_SHARE_BPS);
        assertEq(p.surplus + p.avanaFee + p.keeperReward + p.borrowerSurplus, 0, "dust split");
        assertEq(m.keeperPayout(3 * USDC, 2_950_000, 3 * USDC, 0, 0), 2_950_000, "dust keeperOut");
    }

    // TEST-198 verifies: SPEC-LIQ-007, SPEC-LIQ-010, SPEC-LIQ-017, REQ-SWAP-089, REQ-SWAP-108, INV-086, Q-333, Q-404
    // Sources: 2.11 SPEC-LIQ-017 example (Lens margin), REQ-SWAP-108 transfer-fee example
    function test_TEST_198_leftoverAndTransferFee() public view {
        uint256 d = 1950 * USDC;
        uint256 x = 2_047_500_000;
        SettlementMath.Payouts memory p = m.payouts(2_047_500_000, d, 2_040_300_000, AVANA_FEE_SHARE_BPS);
        // The unused 97.5 USDC returns inside keeperOut and never changes A.
        uint256 out = m.keeperPayout(x, 2_040_300_000, d, p.avanaFee, p.borrowerSurplus);
        assertEq(out, 2_118_300_000, "keeperOut = 2,118.3 includes the leftover");
        assertEq(out - p.keeperReward - d, x - d, "leftover = Kf - D");
        assertEq(p.avanaFee, 19_500_000, "A independent of debtToCover");
        assertEq(m.roundingGap(d, p.avanaFee, p.borrowerSurplus, x, 2_040_300_000), 0, "no gap");
        // Transfer fee: a 10 bps fee on the funding lowers the measured Kf and keeperOut by the same amount only.
        uint256 kf = x - x * 10 / BPS;
        uint256 outFee = m.keeperPayout(kf, 2_040_300_000, d, p.avanaFee, p.borrowerSurplus);
        assertEq(out - outFee, x - kf, "the fee falls on keeperOut alone");
    }

    // TEST-198 verifies: SPEC-SET-001, SPEC-LIQ-008, SPEC-LIQ-010, SPEC-LIQ-019, REQ-SWAP-029, REQ-SWAP-062, INV-038, Q-397
    // Sources: 2.11 SPEC-LIQ-005 dust example, SPEC-LIQ-019 (g never exceeds the floor gap while D <= Kf)
    function test_TEST_198_gapNeverExceedsFloorGap() public view {
        uint256 d = 3 * USDC;
        uint256 minRec = m.recoveryFloor(3_150_000, 100, 2, USDC);
        // Recovery between the floor and D: no gap, the caller bears D - R in keeperOut.
        uint256 rf = m.recoveryWithFloor(minRec, 2_950_000);
        SettlementMath.Payouts memory p = m.payouts(3_150_000, d, rf, AVANA_FEE_SHARE_BPS);
        uint256 gap = m.roundingGap(d, p.avanaFee, p.borrowerSurplus, d, 2_950_000);
        assertEq(gap, 0, "g = 0");
        assertEq(m.keeperPayout(d, 2_950_000, d, 0, 0), 2_950_000, "loss of 0.05 USDC in keeperOut");
        // Recovery below the floor: the top-up is the floor gap, and g stays below it.
        rf = m.recoveryWithFloor(minRec, 2_000_000);
        p = m.payouts(3_150_000, d, rf, AVANA_FEE_SHARE_BPS);
        gap = m.roundingGap(d, p.avanaFee, p.borrowerSurplus, d, 2_000_000);
        assertEq(gap, 0, "g = 0 below the floor too");
        uint256 shortfall = m.shortfallTopUp(minRec, 2_000_000, gap, 200_000);
        assertEq(shortfall, minRec - 2_000_000, "shortfall = minRec - R");
        assertEq(m.keeperPayout(d, 2_000_000 + shortfall, d, 0, 0), minRec, "keeperOut = R'");
        // Surplus within the oracle gain at the floor: S = R_f - D, A = 20 % of G capped at S.
        p = m.payouts(3_150_000, d, m.recoveryWithFloor(minRec, 3_001_600), AVANA_FEE_SHARE_BPS);
        assertEq(p.surplus, 1600, "S");
        assertEq(p.avanaFee, 1600, "A = S below 20 % of G");
        assertEq(m.keeperPayout(d, 3_001_600, d, p.avanaFee, 0), d, "keeperOut = Kf");
    }

    // TEST-198 verifies: SPEC-LIQ-014, Q-211, Q-338
    // Sources: 2.11 SPEC-LIQ-014 example, MATH-ST-84
    function test_TEST_198_pendingFloorExample() public view {
        uint256 vp = m.pendingLegValue(41_200_000, PRICE_UNIT, 6, 18, PRICE_UNIT)
            + m.pendingLegValue(42_600_000, P_USDT, 6, 18, PRICE_UNIT);
        assertEq(vp, 83.7787e18, "V_P = 83.7787 GHO");
        uint256 u = m.unitValue(PRICE_UNIT, 6, 18, PRICE_UNIT) + m.unitValue(P_USDT, 6, 18, PRICE_UNIT);
        assertEq(u, 1_999_500_000_000, "U");
        uint256 sp = m.pendingSlippage(100);
        assertEq(m.recoveryFloor(vp, sp, u, 1e18), 82.5273619005e18, "minPending");
        assertEq(m.pendingLegValue(1, 1, 18, 6, PRICE_UNIT), 1, "pending value rounds up");
        assertEq(m.legValue(1, 1, 18, 6, PRICE_UNIT), 0, "leg value rounds down");
    }

    // TEST-198 verifies: SPEC-LIQ-015, REQ-FLASH-002, REQ-SWAP-013, Q-335
    // Sources: 2.11 SPEC-LIQ-015 example, MATH-ST-85
    function test_TEST_198_flashPremiumBoundExample() public view {
        uint256 f = 1950 * USDC;
        assertTrue(m.flashPremiumWithinCap(975_000, f, MAX_FLASH_FEE_BPS), "5 bps passes");
        assertTrue(m.flashPremiumWithinCap(1_950_000, f, MAX_FLASH_FEE_BPS), "exactly 10 bps passes");
        assertFalse(m.flashPremiumWithinCap(1_950_001, f, MAX_FLASH_FEE_BPS), "one unit above fails");
        assertFalse(m.flashPremiumWithinCap(3_900_000, f, MAX_FLASH_FEE_BPS), "20 bps fails");
        assertTrue(m.flashPremiumWithinCap(0, 0, 0), "no loan, no premium");
        assertFalse(m.flashPremiumWithinCap(1, 1, 0), "cap 0 refuses any premium");
        assertTrue(m.flashPremiumWithinCap(2, 1, 20_000), "cap above 100 % (exact path)");
        assertFalse(m.flashPremiumWithinCap(3, 1, 20_000), "cap above 100 %, premium above it");
    }

    // TEST-198 verifies: SPEC-LIQ-020, REQ-SWAP-106, REQ-SWAP-116, INV-089, Q-255
    // Sources: 2.11 SPEC-LIQ-020 example, MATH-ST-87
    function test_TEST_198_deleverageExample() public {
        uint256 v = m.seizedValue(1000e18, P_VAULT, 18, 6, PRICE_UNIT);
        assertEq(v, 2100 * USDC, "V");
        uint256 cap = m.deleverageCap(v, 100, 2, USDC, MAX_FLASH_FEE_BPS);
        assertEq(cap, 2_075_924_073, "cap = floor(2,077,999,998 x 1e4 / 10,010)");
        uint256 x = m.deleverageRepayment(6600 * USDC, cap, 0);
        assertEq(x, 2_075_924_073, "x = cap below the debt");
        assertEq(m.deleverageRepayment(100, cap, 100), 100, "x = debt below the cap");
        // The Pool charges its premium half up: floor((x * 5 + 5,000) / 1e4) = 1,037,962 (the ceiling quote is 1,037,963).
        assertEq(m.deleverageAssetOut(2_096_200_000, x, 1_037_962), 19_237_965, "assetOut");
        assertEq(m.deleverageCap(1, 100, 2, USDC, MAX_FLASH_FEE_BPS), 0, "Vnet saturates at 0");
        assertEq(m.deleverageCap(1_000_002, 0, 2, USDC, 0), 0, "Vnet = U + eps saturates at 0");
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.DeleverageTooSmall.selector, 0, 0));
        m.deleverageRepayment(6600 * USDC, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.DeleverageTooSmall.selector, x, x + 1));
        m.deleverageRepayment(6600 * USDC, cap, x + 1);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.DeleverageShortfall.selector, x, x + 1_037_962));
        m.deleverageAssetOut(x, x, 1_037_962);
    }

    // TEST-198 verifies: SPEC-LIQ-020, SPEC-LIQ-018, REQ-SWAP-106, INV-089
    // Sources: SettlementMath review S4 (two legs at their minimums against the repayment and a 9 bps premium)
    function test_TEST_198_deleverageLegsAtMinimumsCoverRepayment() public view {
        uint256 cap = m.deleverageCap(2100 * USDC, 100, 2, USDC, MAX_FLASH_FEE_BPS);
        uint256 phi = Math.mulDiv(cap, 9, BPS, Math.Rounding.Ceil); // a premium strictly below the 10 bps cap
        uint256 legs = 2 * m.legMinOut(1050 * USDC, 100, 1, USDC, 2);
        assertEq(legs, 2_077_999_998, "two USDC/USDT legs at their minimums");
        assertGe(legs, cap + phi, "legs at their minimums repay x + phi");
        // Without eps in Vnet the cap was 2,076,923,074 and the same legs fell 0.79 USDC short at 9 bps.
        uint256 oldCap = (2_079_000_000 - 2) * BPS / (BPS + MAX_FLASH_FEE_BPS);
        assertLt(legs, oldCap + Math.mulDiv(oldCap, 9, BPS, Math.Rounding.Ceil), "the earlier cap fell short");
    }

    // TEST-198 verifies: SPEC-LIQ-004, SPEC-LIQ-005, SPEC-LIQ-014, SPEC-LIQ-018
    // Sources: SettlementMath review A1, A2 (zero prices and decimals above 36 fail closed)
    function test_TEST_198_valuationRejectsZeroPricesAndDecimals() public {
        vm.expectRevert(ILPVaultSwapErrors.ZeroDebtPrice.selector);
        m.seizedValue(1, 1, 18, 6, 0);
        vm.expectRevert(ILPVaultSwapErrors.ZeroCollateralPrice.selector);
        m.seizedValue(1, 0, 18, 6, PRICE_UNIT);
        vm.expectRevert(ILPVaultSwapErrors.ZeroCollateralPrice.selector);
        m.seizedValue(1, 0, 18, 6, 0); // the valued price is checked before the quote price
        vm.expectRevert(ILPVaultSwapErrors.ZeroCollateralPrice.selector);
        m.legValue(1, 0, 18, 6, PRICE_UNIT);
        vm.expectRevert(ILPVaultSwapErrors.ZeroDebtPrice.selector);
        m.pendingLegValue(1, 1, 6, 18, 0);
        vm.expectRevert(ILPVaultSwapErrors.ZeroCollateralPrice.selector);
        m.unitValue(0, 6, 6, PRICE_UNIT);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.InvalidDecimals.selector, uint8(37)));
        m.seizedValue(1, 1, 37, 6, PRICE_UNIT);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.InvalidDecimals.selector, uint8(60)));
        m.legValue(1, 1, 6, 60, PRICE_UNIT);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.InvalidDecimals.selector, uint8(255)));
        m.unitValue(0, 255, 6, 0); // decimals are checked before prices
    }

    // TEST-198 verifies: SPEC-LIQ-004, SPEC-LIQ-005, SPEC-LIQ-018
    // Sources: SettlementMath review C1 (decimals 0, 8 and 36)
    function test_TEST_198_valuesAtDecimals0And8And36() public view {
        // A 0-decimal token at $3 against USDC: one unit is 3 USDC.
        assertEq(m.legValue(5, 3 * PRICE_UNIT, 0, 6, PRICE_UNIT), 15 * USDC, "0-decimal token");
        assertEq(m.unitValue(3 * PRICE_UNIT, 0, 6, PRICE_UNIT), 3 * USDC, "0-decimal unit");
        // WBTC (8 decimals) at $60,000 against GHO: 0.5 WBTC is 30,000 GHO, one satoshi 0.0006 GHO.
        assertEq(m.legValue(0.5e8, 60_000 * PRICE_UNIT, 8, 18, PRICE_UNIT), 30_000e18, "8-decimal token");
        assertEq(m.unitValue(60_000 * PRICE_UNIT, 8, 18, PRICE_UNIT), 6e14, "8-decimal unit");
        // 36 decimals both sides at $1: value equals the amount.
        assertEq(m.seizedValue(7e36, PRICE_UNIT, 36, 36, PRICE_UNIT), 7e36, "36 decimals");
        assertEq(m.unitValue(PRICE_UNIT, 36, 6, PRICE_UNIT), 1, "a 36-decimal unit rounds up to 1");
        assertEq(m.pendingLegValue(1, PRICE_UNIT, 36, 6, PRICE_UNIT), 1, "pending value rounds up");
        assertEq(m.legValue(1, PRICE_UNIT, 36, 6, PRICE_UNIT), 0, "leg value rounds down");
    }

    // TEST-198 verifies: SPEC-LIQ-009, SPEC-LIQ-022
    // Sources: SettlementMath review A3 (a fee share above 1e4 reverts instead of clamping kr)
    function test_TEST_198_feeShareAboveBpsReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.InvalidFeeShare.selector, BPS + 1));
        m.payouts(2_047_500_000, 1950 * USDC, 2_052_000_000, BPS + 1);
        SettlementMath.Payouts memory p = m.payouts(2_047_500_000, 1950 * USDC, 2_052_000_000, BPS);
        assertEq(p.avanaFee, p.oracleGain, "share 1e4 takes the whole oracle gain");
        assertEq(p.keeperReward, 0, "kr = G - A = 0");
        assertEq(p.borrowerSurplus, 4_500_000, "B = S - G");
    }

    // TEST-198 verifies: SPEC-LIQ-009, SPEC-LIQ-003, INV-086
    // Sources: 2.11 SPEC-LIQ-009 best-effort example (s at the bonus cap)
    function test_TEST_198_feeBestEffortAtCappedSlippage() public view {
        uint256 d = 1_000_000 * USDC;
        uint256 s = m.effectiveSlippage(m.netBonus(10_100, 0), 100);
        assertEq(s, 99, "s at the bonus cap, below the 100 bps allowance");
        uint256 v = 1_010_000 * USDC;
        uint256 minRec = m.recoveryFloor(v, s, 2, USDC);
        assertEq(minRec, 999_999_999_998, "minRec = 999,999.999998 USDC");
        SettlementMath.Payouts memory honest = m.payouts(v, d, 1_009_495 * USDC, AVANA_FEE_SHARE_BPS);
        assertEq(honest.avanaFee, 2000 * USDC, "A = 2,000 USDC at R = 0.9995 V");
        assertEq(honest.keeperReward, 7495 * USDC, "kr = 7,495 USDC");
        SettlementMath.Payouts memory atFloor = m.payouts(v, d, minRec, AVANA_FEE_SHARE_BPS);
        assertEq(atFloor.avanaFee, 0, "A = 0 at R = minRec below D");
        assertEq(atFloor.keeperReward, 0, "kr = 0");
        assertEq(m.keeperPayout(d, minRec, d, 0, 0), d - 2, "caller receives Kf - 0.000002 USDC");
    }

    // TEST-198 verifies: SPEC-LIQ-015, REQ-FLASH-002
    // Sources: SettlementMath review S3 (a pool premium equal to maxFlashFeeBps fails the exact cap)
    function test_TEST_198_poolPremiumAtCapFails() public view {
        uint256 f = 1_950_000_001;
        assertFalse(m.flashPremiumWithinCap(_poolPremium(f, 10), f, 10), "ceiling premium at the cap fails");
        uint256 f2 = 1_950_000_500;
        assertFalse(m.flashPremiumWithinCap((f2 * 10 + 5000) / BPS, f2, 10), "half-up premium at the cap fails");
        assertTrue(m.flashPremiumWithinCap(_poolPremium(f, 9), f, 10), "a rate strictly below the cap passes");
    }

    // TEST-198 verifies: SPEC-LIQ-015, REQ-FLASH-002
    // Sources: 5.1 TEST-198 examples (deleverage flash repayment at 5 bps, 6 and 18 decimals)
    function test_TEST_198_flashRepaymentExamples() public view {
        // The Pool's premium ceil(amount x 5 / 1e4) passes the cap.
        uint256 usdcPremium = _poolPremium(1000 * USDC, 5);
        assertEq(1000 * USDC + usdcPremium, 1000.5e6, "1,000e6 USDC repays 1,000.5e6");
        uint256 wethPremium = _poolPremium(1e18, 5);
        assertEq(1e18 + wethPremium, 1.0005e18, "1e18 WETH repays 1.0005e18");
        assertEq(1e18 + 1 + _poolPremium(1e18 + 1, 5), 1.0005e18 + 2, "1e18 + 1 wei rounds up to the next wei");
        assertTrue(m.flashPremiumWithinCap(usdcPremium, 1000 * USDC, 5), "the 5 bps premium meets a 5 bps cap");
        assertFalse(m.flashPremiumWithinCap(_poolPremium(1e18 + 1, 5), 1e18 + 1, 5), "a hair above 5 bps fails it");
        assertTrue(m.flashPremiumWithinCap(wethPremium, 1e18, MAX_FLASH_FEE_BPS), "within the cap");
    }

    function _poolPremium(
        uint256 amount,
        uint256 premiumBps
    ) internal pure returns (uint256) {
        return (amount * premiumBps + BPS - 1) / BPS;
    }
}
