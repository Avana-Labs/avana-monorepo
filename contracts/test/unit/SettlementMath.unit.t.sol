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

    // TEST-198 verifies: SPEC-LIQ-001, SPEC-LIQ-002, SPEC-LIQ-003, INV-034, Q-159, Q-190
    // Sources: 2.11 SPEC-LIQ-001…003 examples, MATH-ST-80, MATH-ST-85
    function test_TEST_198_bonusCostsAndSlippageExamples() public view {
        assertEq(m.netBonus(10_500, 0), 10_500, "bNet at lf 0");
        assertEq(m.netBonus(10_500, 1000), 10_450, "bNet at lf 1,000");
        uint256 phi = 975_000; // ceil(1,950e6 x 5 / 1e4)
        assertEq(m.costsBps(phi, 1950 * USDC), 5, "costsBps of the 5 bps premium");
        assertEq(m.costsBps(0, 1950 * USDC), 0, "FLASH_BORROWER: no premium");
        assertEq(m.costsBps(phi, 0), 0, "F = 0");
        assertEq(m.effectiveSlippage(10_500, 5, 100), 100, "s capped by the allowance");
        assertEq(m.effectiveSlippage(10_500, 5, 1000), 471, "uncapped s at b 10,500");
        assertGe(10_500 * (BPS - 100), BPS * (BPS + 5), "10,500 x 9,900 >= 1e4 x 10,005");
        assertEq(m.effectiveSlippage(10_050, 5, 1000), 44, "s at b 10,050");
    }

    // TEST-198 verifies: SPEC-LIQ-001, SPEC-LIQ-003
    // Sources: MATH-ST-113 (bNet saturates outside Aave's bounds)
    function test_TEST_198_netBonusSaturatesOutsideAaveBounds() public view {
        assertEq(m.netBonus(BPS, 0), BPS, "no bonus");
        assertEq(m.netBonus(9000, 0), BPS, "b below 1e4");
        assertEq(m.netBonus(10_500, BPS), BPS, "lf = 1e4");
        assertEq(m.netBonus(2009, 15_892), BPS, "b < 1e4 and lf > 1e4 do not make a positive bonus");
        assertEq(m.effectiveSlippage(BPS, 0, 100), 0, "bNet = 1e4 gives s = 0");
        assertEq(m.effectiveSlippage(10_005, 5, 100), 0, "bNet = 1e4 + costs gives s = 0");
        assertEq(m.effectiveSlippage(10_006, 5, 100), 0, "floor(1e4 / 10,006) = 0");
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

    // TEST-198 verifies: SPEC-LIQ-019, SPEC-SET-001, REQ-SWAP-025, REQ-SWAP-060, INV-034, Q-251, Q-397
    // Sources: 2.11 SPEC-LIQ-019 examples, 2.13 SPEC-SET-001 examples, MATH-ST-86, MATH-ST-88
    function test_TEST_198_shortfallTopUpExamples() public {
        uint256 v = 12_422_600_000;
        uint256 minRec = m.recoveryFloor(v, 100, 2, USDC);
        assertEq(minRec, 12_297_373_998, "minRec at V 12,422.6");
        assertEq(m.shortfallTopUp(minRec, 12_174 * USDC, 0, 200 * USDC), 123_373_998, "pulled 123.373998 USDC");
        vm.expectRevert(ILPVaultSwapErrors.RecoveryBelowFloor.selector);
        m.shortfallTopUp(minRec, 12_174 * USDC, 0, 123_373_997);
        // Dust: K = 0, F = D = 3 USDC, phiD = 0.0015, R = 2.95 above the floor.
        uint256 gap = m.roundingGap(3 * USDC, 1500, 0, 0, 0, 0, 2_950_000);
        assertEq(gap, 51_500, "g = 0.0515 USDC");
        assertEq(m.roundingGap(3 * USDC, 1500, 0, 0, 0, 3 * USDC, 2_950_000), 0, "K = 3 USDC closes it");
        assertEq(m.shortfallTopUp(2_118_498, 2_950_000, gap, 51_500), 51_500, "shortfall = g");
        vm.expectRevert(ILPVaultSwapErrors.InsufficientProceeds.selector);
        m.shortfallTopUp(2_118_498, 2_950_000, gap, 0);
        // Both fail: the floor error comes first.
        vm.expectRevert(ILPVaultSwapErrors.RecoveryBelowFloor.selector);
        m.shortfallTopUp(10, 0, 20, 5);
        assertEq(m.shortfallTopUp(10, 0, 20, 20), 20, "max of the floor gap and g");
        assertEq(m.shortfallTopUp(0, 5, 0, 0), 0, "nothing to pull");
    }

    // TEST-198 verifies: SPEC-LIQ-008, SPEC-LIQ-009, SPEC-LIQ-010, SPEC-LIQ-022, INV-035, INV-036, INV-086, Q-256, Q-337
    // Sources: 2.11 SPEC-LIQ-008…010 and SPEC-LIQ-022 examples, MATH-ST-82, MATH-ST-83
    function test_TEST_198_waterfallExamples() public view {
        uint256 v = 2_047_500_000;
        uint256 d = 1950 * USDC;
        uint256 phi = 975_000;
        SettlementMath.Payouts memory p = m.payouts(v, d, phi, 2_040_300_000, AVANA_FEE_SHARE_BPS);
        assertEq(p.surplus, 89_325_000, "S");
        assertEq(p.oracleGain, 96_525_000, "G");
        assertEq(p.avanaFee, 19_305_000, "A");
        assertEq(p.keeperReward, 70_020_000, "kr");
        assertEq(p.borrowerSurplus, 0, "B");
        uint256 out = m.keeperPayout(0, d, 2_040_300_000, d, d + phi, p.avanaFee, p.borrowerSurplus);
        assertEq(out, 70_020_000, "keeperOut");
        assertEq(0 + d + 2_040_300_000, d + (d + phi) + p.avanaFee + p.borrowerSurplus + out, "T in == T out");
        // A caller that sandwiched its own routes to R = 2,027 USDC still pays A = 19.305.
        p = m.payouts(v, d, phi, 2027 * USDC, AVANA_FEE_SHARE_BPS);
        assertEq(p.surplus, 76_025_000, "S after a self-sandwich");
        assertEq(p.avanaFee, 19_305_000, "A unchanged");
        // Routes better than the oracle: the excess goes to the borrower.
        p = m.payouts(v, d, phi, 2052 * USDC, AVANA_FEE_SHARE_BPS);
        assertEq(p.surplus, 101_025_000, "S at R 2,052");
        assertEq(p.keeperReward, 77_220_000, "kr = G - A");
        assertEq(p.borrowerSurplus, 4_500_000, "B = R' - max(V, D + phiD)");
        assertEq(m.keeperPayout(0, d, 2052 * USDC, d, d + phi, p.avanaFee, p.borrowerSurplus), 77_220_000, "keeperOut");
        // Dust: R_f = max(2.95, 2.118498) = 2.95 USDC, so S = A = B = 0; R' = 2.95 + g = 3.0015 and keeperOut = 0.
        uint256 rf = m.recoveryWithFloor(2_118_498, 2_950_000);
        assertEq(rf, 2_950_000, "R_f = R above the floor");
        p = m.payouts(3_150_000, 3 * USDC, 1500, rf, AVANA_FEE_SHARE_BPS);
        assertEq(p.surplus + p.avanaFee + p.keeperReward + p.borrowerSurplus, 0, "dust split");
        assertEq(m.keeperPayout(0, 3 * USDC, 3_001_500, 3 * USDC, 3_001_500, 0, 0), 0, "dust keeperOut");
    }

    // TEST-198 verifies: SPEC-LIQ-007, SPEC-LIQ-010, SPEC-LIQ-019, SPEC-SET-001, REQ-SWAP-062, INV-086, Q-267
    // Sources: 2.11 SPEC-LIQ-007 and SPEC-LIQ-017 examples (oversized flash), REQ-SWAP-108 transfer-fee example
    function test_TEST_198_oversizedFlashAndTransferFee() public view {
        uint256 d = 1950 * USDC;
        uint256 f = 2_047_500_000;
        uint256 phi = 1_023_750; // ceil(2,047.5e6 x 5 / 1e4)
        uint256 phiD = 975_000; // premium on min(F, D)
        SettlementMath.Payouts memory p = m.payouts(2_047_500_000, d, phiD, 2_040_300_000, AVANA_FEE_SHARE_BPS);
        // Leftover X - D = 97.5 USDC repays part of F; the caller alone bears phi - phiD = 0.04875 USDC.
        uint256 out = m.keeperPayout(0, f, 2_040_300_000, d, f + phi, p.avanaFee, p.borrowerSurplus);
        assertEq(out, p.keeperReward - (phi - phiD), "keeperOut = kr - (phi - phiD)");
        assertEq(p.avanaFee, 19_305_000, "A independent of the oversized flash");
        assertEq(m.roundingGap(d, phi, 0, p.avanaFee, p.borrowerSurplus, 0, 2_040_300_000), 0, "no gap");
        // Transfer fee: the measured Fr and P lower keeperOut by tau = (F - Fr) + (P - F - phi).
        uint256 outFee = m.keeperPayout(0, f - 10, 2_040_300_000, d, f + phi + 7, p.avanaFee, p.borrowerSurplus);
        assertEq(out - outFee, 17, "tau falls on keeperOut alone");
    }

    // TEST-198 verifies: SPEC-SET-001, SPEC-LIQ-008, SPEC-LIQ-010, SPEC-LIQ-019, REQ-SWAP-029, REQ-SWAP-062, Q-397
    // Sources: 2.13 SPEC-SET-001 oversized-flash example (the Lens 5 % margin on a dust liquidation)
    function test_TEST_198_gapCoversWholeFlashObligation() public view {
        uint256 d = 3 * USDC;
        uint256 f = 3_150_000; // debtToCover and F with the Lens margin
        uint256 phi = 1575; // ceil(3.15e6 x 5 / 1e4)
        uint256 phiD = 1500; // premium on min(F, D)
        uint256 minRec = m.recoveryFloor(3_150_000, 100, 2, USDC);
        uint256 rf = m.recoveryWithFloor(minRec, 2_950_000);
        SettlementMath.Payouts memory p = m.payouts(3_150_000, d, phiD, rf, AVANA_FEE_SHARE_BPS);
        uint256 gap = m.roundingGap(d, phi, 0, p.avanaFee, p.borrowerSurplus, 0, 2_950_000);
        assertEq(gap, 51_575, "g = 0.051575 USDC covers the whole premium");
        uint256 shortfall = m.shortfallTopUp(minRec, 2_950_000, gap, 60_000);
        assertEq(m.keeperPayout(0, f, 2_950_000 + shortfall, d, f + phi, 0, 0), 0, "settles with keeperOut 0");
        // The gap of the earlier rule, D + phiD - K - R = 51,500, left keeperOut = phiD - phi < 0.
        assertLt(2_950_000 + 51_500 + f, d + f + phi, "D + phiD would have reverted");
        // Surplus within reach of the flash cost: R = 3.0016 USDC, F = 3.15 USDC, K = 0. S = 100, A = 100 (20 % of
        // G = 0.1485 USDC is above S), kr = B = 0; the caller tops up the 75 units its oversized premium costs.
        p = m.payouts(3_150_000, d, phiD, m.recoveryWithFloor(minRec, 3_001_600), AVANA_FEE_SHARE_BPS);
        assertEq(p.surplus, 100, "S");
        assertEq(p.avanaFee, 100, "A = S");
        gap = m.roundingGap(d, phi, 0, p.avanaFee, p.borrowerSurplus, 0, 3_001_600);
        assertEq(gap, 75, "g = phi - phiD - kr");
        assertEq(m.keeperPayout(0, f, 3_001_600 + gap, d, f + phi, p.avanaFee, 0), 0, "keeperOut 0, A paid in full");
        // Transfer fee on the flash principal: Fr = F - 3,150 (10 bps) with K = 0 and R = 2.95 USDC.
        gap = m.roundingGap(d, phi, 3150, 0, 0, 0, 2_950_000);
        assertEq(gap, 54_725, "g includes tau = F - Fr");
        assertEq(m.keeperPayout(0, f - 3150, 2_950_000 + gap, d, f + phi, 0, 0), 0, "settles with keeperOut 0");
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
        m.payouts(2_047_500_000, 1950 * USDC, 975_000, 2_052_000_000, BPS + 1);
        SettlementMath.Payouts memory p = m.payouts(2_047_500_000, 1950 * USDC, 975_000, 2_052_000_000, BPS);
        assertEq(p.avanaFee, p.oracleGain, "share 1e4 takes the whole oracle gain");
        assertEq(p.keeperReward, 0, "kr = G - A = 0");
        assertEq(p.borrowerSurplus, 4_500_000, "B = S - G");
    }

    // TEST-198 verifies: SPEC-LIQ-009, SPEC-LIQ-003, INV-086
    // Sources: SettlementMath review S1 (Avana's share is best-effort when s sits at the bonus cap)
    function test_TEST_198_feeBestEffortAtCappedSlippage() public view {
        uint256 d = 1_000_000 * USDC;
        uint256 phi = 500 * USDC; // F = D at 5 bps
        uint256 s = m.effectiveSlippage(m.netBonus(10_100, 0), m.costsBps(phi, d), 100);
        assertEq(s, 94, "s at the bonus cap, below the 100 bps allowance");
        uint256 v = 1_010_000 * USDC;
        uint256 minRec = m.recoveryFloor(v, s, 2, USDC);
        assertEq(minRec, 1_000_504_999_998, "minRec = 1,000,504.999998 USDC");
        SettlementMath.Payouts memory honest = m.payouts(v, d, phi, 1_009_495 * USDC, AVANA_FEE_SHARE_BPS);
        assertEq(honest.avanaFee, 1900 * USDC, "A = 1,900 USDC at R = 0.9995 V");
        assertEq(honest.keeperReward, 7095 * USDC, "kr = 7,095 USDC");
        SettlementMath.Payouts memory atFloor = m.payouts(v, d, phi, minRec, AVANA_FEE_SHARE_BPS);
        assertEq(atFloor.avanaFee, 4_999_998, "A = 4.999998 USDC at R = minRec");
        assertEq(atFloor.keeperReward, 0, "kr = 0");
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

    // TEST-198 verifies: SPEC-LIQ-001, SPEC-LIQ-002, SPEC-LIQ-003
    // Sources: 5.1 TEST-198 examples (flash repayment at 5 bps, 6 and 18 decimals)
    function test_TEST_198_flashRepaymentExamples() public view {
        // The Pool's premium ceil(amount x 5 / 1e4) passes the cap and its costsBps is the premium rate.
        uint256 usdcPremium = _poolPremium(1000 * USDC, 5);
        assertEq(1000 * USDC + usdcPremium, 1000.5e6, "1,000e6 USDC repays 1,000.5e6");
        uint256 wethPremium = _poolPremium(1e18, 5);
        assertEq(1e18 + wethPremium, 1.0005e18, "1e18 WETH repays 1.0005e18");
        assertEq(1e18 + 1 + _poolPremium(1e18 + 1, 5), 1.0005e18 + 2, "1e18 + 1 wei rounds up to the next wei");
        assertEq(m.costsBps(usdcPremium, 1000 * USDC), 5, "costsBps 5");
        assertEq(m.costsBps(_poolPremium(1e18 + 1, 5), 1e18 + 1), 6, "a premium a hair above 5 bps rounds up to 6");
        assertTrue(m.flashPremiumWithinCap(wethPremium, 1e18, MAX_FLASH_FEE_BPS), "within the cap");
    }

    function _poolPremium(
        uint256 amount,
        uint256 premiumBps
    ) internal pure returns (uint256) {
        return (amount * premiumBps + BPS - 1) / BPS;
    }
}
