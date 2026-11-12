// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {SettlementMath} from "../../src/liquidation/lp-vault-swap/SettlementMath.sol";
import {SettlementMathHarness} from "../utils/harness/SettlementMathHarness.sol";
import {DifferentialTest} from "./utils/DifferentialTest.sol";

/// @title SettlementMathDifferentialTest
/// @notice Every SettlementMath formula against the exact Python reference (`avana_reference.py`, integers and
/// `Fraction` only): the same inputs must give the same word, and a Solidity revert must match the reference's status.
/// @dev Inputs span the listing bounds and the 6- and 18-decimal assets; each run spawns one Python process.
/// forge-config: differential.fuzz.runs = 128
contract SettlementMathDifferentialTest is DifferentialTest {
    SettlementMathHarness internal m;

    function setUp() public {
        m = new SettlementMathHarness();
    }

    // TEST-198 verifies: SPEC-LIQ-001, SPEC-LIQ-002, SPEC-LIQ-003
    function testFuzz_TEST_198_differentialBonusSlippage(
        uint256 bonus,
        uint256 lf,
        uint256 allowance
    ) public {
        bonus = bound(bonus, 0, type(uint32).max);
        lf = bound(lf, 0, 2 * BPS);
        allowance = bound(allowance, 0, BPS);
        uint256 bNet = m.netBonus(bonus, lf);
        assertEq(bNet, _one("netBonus", _a2(bonus, lf)), "netBonus");
        assertEq(
            m.effectiveSlippage(bNet, allowance), _one("effectiveSlippage", _a2(bNet, allowance)), "effectiveSlippage"
        );
    }

    // TEST-198 verifies: SPEC-LIQ-014, SPEC-LIQ-019
    function testFuzz_TEST_198_differentialLegSlippage(
        uint256 s,
        uint256 maxShortfall,
        uint256 value,
        uint256 maxShortfallBps
    ) public {
        s = bound(s, 0, BPS);
        maxShortfall = bound(maxShortfall, 0, 1 << 129);
        value = bound(value, 0, (1 << 200) - 1);
        // The whole uint256 range of maxShortfallBps: the saturating shortcuts must match the exact formula.
        assertEq(
            m.legSlippage(s, maxShortfall, value, maxShortfallBps),
            _one("legSlippage", _args(s, maxShortfall, value, maxShortfallBps)),
            "legSlippage"
        );
        assertEq(m.pendingSlippage(s), _one("pendingSlippage", _a1(s)), "pendingSlippage");
    }

    // TEST-198 verifies: SPEC-LIQ-004, SPEC-LIQ-005, SPEC-LIQ-014, SPEC-LIQ-018
    // Decimals 0, 6, 8, 18 and 36 on either side; the target decimals at most 18 above the source keep every exact
    // value below 2^256 for amounts below 2^120 and prices below 2^64.
    function testFuzz_TEST_198_differentialOracleValues(
        uint256 amount,
        uint256 price,
        uint256 debtPrice,
        uint8 fromCase,
        uint8 toCase
    ) public {
        amount = bound(amount, 0, (1 << 120) - 1);
        price = bound(price, 1, (1 << 64) - 1);
        debtPrice = bound(debtPrice, 1, (1 << 64) - 1);
        uint8 from = _decimals(fromCase);
        uint8 to = _decimals(toCase);
        if (to > from + 18) to = from + 18;
        _compareValues(amount, price, from, to, debtPrice);
    }

    // TEST-198 verifies: SPEC-LIQ-004, SPEC-LIQ-014, SPEC-LIQ-018
    // Amounts up to 2^200 (the bound on V), with the target decimals at most the source and prices below 2^40.
    function testFuzz_TEST_198_differentialOracleValuesLargeAmounts(
        uint256 amount,
        uint256 price,
        uint256 debtPrice,
        uint8 fromCase,
        uint8 toCase
    ) public {
        amount = bound(amount, 0, (1 << 200) - 1);
        price = bound(price, 1, (1 << 40) - 1);
        debtPrice = bound(debtPrice, 1, (1 << 64) - 1);
        uint8 from = _decimals(fromCase);
        uint8 to = _decimals(toCase);
        if (to > from) (from, to) = (to, from);
        _compareValues(amount, price, from, to, debtPrice);
    }

    function _compareValues(
        uint256 amount,
        uint256 price,
        uint8 from,
        uint8 to,
        uint256 debtPrice
    ) internal {
        uint256[] memory a = _a5(amount, price, from, to, debtPrice);
        assertEq(m.seizedValue(amount, price, from, to, debtPrice), _one("seizedValue", a), "seizedValue");
        assertEq(m.legValue(amount, price, from, to, debtPrice), _one("legValue", a), "legValue");
        assertEq(m.pendingLegValue(amount, price, from, to, debtPrice), _one("pendingLegValue", a), "pendingLegValue");
        assertEq(
            m.unitValue(price, from, to, debtPrice), _one("unitValue", _args(price, from, to, debtPrice)), "unitValue"
        );
    }

    function _decimals(
        uint8 c
    ) internal pure returns (uint8) {
        uint8[5] memory d = [0, 6, 8, 18, 36];
        return d[c % 5];
    }

    // TEST-198 verifies: SPEC-LIQ-005, SPEC-LIQ-014, SPEC-LIQ-018
    function testFuzz_TEST_198_differentialFloorAndLegMinimum(
        uint256 value,
        uint256 s,
        uint256 units,
        uint256 allowance,
        uint256 legs
    ) public {
        value = bound(value, 0, (1 << 200) - 1);
        s = bound(s, 0, BPS);
        units = bound(units, 0, 1e30);
        allowance = bound(allowance, 0, 1e30);
        legs = bound(legs, 1, 4);
        assertEq(
            m.recoveryFloor(value, s, units, allowance),
            _one("recoveryFloor", _args(value, s, units, allowance)),
            "recoveryFloor"
        );
        assertEq(
            m.legMinOut(value, s, units, allowance, legs),
            _one("legMinOut", _a5(value, s, units, allowance, legs)),
            "legMinOut"
        );
    }

    struct ShortfallCase {
        uint256 minRec;
        uint256 recovered;
        uint256 debt;
        uint256 avanaFee;
        uint256 borrowerSurplus;
        uint256 callerFunds;
        uint256 maxShortfall;
    }

    // TEST-198 verifies: SPEC-LIQ-019, SPEC-SET-001
    function testFuzz_TEST_198_differentialShortfall(
        ShortfallCase memory c
    ) public {
        c.minRec = bound(c.minRec, 0, 1 << 128);
        c.recovered = bound(c.recovered, 0, 1 << 128);
        c.debt = bound(c.debt, 0, 1 << 128);
        c.avanaFee = bound(c.avanaFee, 0, 1 << 128);
        c.borrowerSurplus = bound(c.borrowerSurplus, 0, 1 << 128);
        c.callerFunds = bound(c.callerFunds, 0, 1 << 128);
        c.maxShortfall = bound(c.maxShortfall, 0, 1 << 130);
        assertEq(
            m.recoveryWithFloor(c.minRec, c.recovered),
            _one("recoveryWithFloor", _a2(c.minRec, c.recovered)),
            "recoveryWithFloor"
        );
        uint256[] memory g = _a5(c.debt, c.avanaFee, c.borrowerSurplus, c.callerFunds, c.recovered);
        uint256 gap = m.roundingGap(g[0], g[1], g[2], g[3], g[4]);
        assertEq(gap, _one("roundingGap", g), "roundingGap");
        uint256[2] memory ref =
            abi.decode(_reference("shortfallTopUp", _args(c.minRec, c.recovered, gap, c.maxShortfall)), (uint256[2]));
        try m.shortfallTopUp(c.minRec, c.recovered, gap, c.maxShortfall) returns (uint256 shortfall) {
            assertEq(ref[0], 0, "reference reverts, Solidity does not");
            assertEq(shortfall, ref[1], "shortfall");
        } catch (bytes memory err) {
            bytes4 expected = ref[0] == 1
                ? ILPVaultSwapErrors.RecoveryBelowFloor.selector
                : ILPVaultSwapErrors.InsufficientProceeds.selector;
            assertGt(ref[0], 0, "Solidity reverts, reference does not");
            assertEq(bytes4(err), expected, "revert reason");
        }
    }

    // TEST-198 verifies: SPEC-LIQ-008, SPEC-LIQ-009, SPEC-LIQ-010, SPEC-LIQ-022
    function testFuzz_TEST_198_differentialWaterfall(
        uint256 value,
        uint256 debt,
        uint256 recoveredWithFloor,
        uint256 share,
        uint256 callerFunds
    ) public {
        value = bound(value, 0, (1 << 128) - 1);
        debt = bound(debt, 0, (1 << 128) - 1);
        recoveredWithFloor = bound(recoveredWithFloor, 0, (1 << 128) - 1);
        share = bound(share, 0, 2 * BPS); // shares above 1e4 must revert in both
        callerFunds = bound(callerFunds, 0, (1 << 128) - 1);
        uint256[6] memory r =
            abi.decode(_reference("payouts", _args(value, debt, recoveredWithFloor, share)), (uint256[6]));
        try m.payouts(value, debt, recoveredWithFloor, share) returns (SettlementMath.Payouts memory p) {
            assertEq(r[0], 0, "reference reverts, Solidity does not");
            assertEq(p.surplus, r[1], "S");
            assertEq(p.oracleGain, r[2], "G");
            assertEq(p.avanaFee, r[3], "A");
            assertEq(p.keeperReward, r[4], "kr");
            assertEq(p.borrowerSurplus, r[5], "B");
            _compareKeeperPayout(callerFunds, debt, recoveredWithFloor, p);
        } catch (bytes memory err) {
            assertEq(r[0], 1, "Solidity reverts, reference does not");
            assertEq(
                keccak256(err),
                keccak256(abi.encodeWithSelector(ILPVaultSwapErrors.InvalidFeeShare.selector, share)),
                "revert data"
            );
        }
    }

    struct LiquidationCase {
        uint256 value;
        uint256 debt;
        uint256 callerFunds;
        uint256 minRec;
        uint256 recovered;
        uint256 share;
        uint256 maxShortfall;
    }

    // TEST-198 verifies: SPEC-LIQ-011, SPEC-LIQ-017, SPEC-LIQ-008, SPEC-LIQ-010, SPEC-LIQ-019, SPEC-LIQ-022, Q-401
    // A liquidation after its last route call, with no flash term: floor, waterfall, settlement gap, shortfall and
    // keeperOut against the reference's single transcription of the spec, and the caller's take within G - A.
    function testFuzz_TEST_198_differentialLiquidationCallerTake(
        LiquidationCase memory c
    ) public {
        c.value = bound(c.value, 0, (1 << 121) - 1);
        c.debt = bound(c.debt, 0, (1 << 120) - 1);
        c.callerFunds = bound(c.callerFunds, c.debt, (1 << 121) - 1);
        c.minRec = bound(c.minRec, 0, c.value);
        c.recovered = bound(c.recovered, 0, (1 << 121) - 1);
        c.share = bound(c.share, 0, 5000);
        c.maxShortfall = bound(c.maxShortfall, 0, (1 << 122) - 1);
        uint256[] memory a = new uint256[](7);
        (a[0], a[1], a[2], a[3], a[4], a[5], a[6]) =
        (c.value, c.debt, c.callerFunds, c.minRec, c.recovered, c.share, c.maxShortfall);
        uint256[6] memory r = abi.decode(_reference("liquidationSettlement", a), (uint256[6]));
        SettlementMath.Payouts memory p =
            m.payouts(c.value, c.debt, m.recoveryWithFloor(c.minRec, c.recovered), c.share);
        uint256 gap = m.roundingGap(c.debt, p.avanaFee, p.borrowerSurplus, c.callerFunds, c.recovered);
        try m.shortfallTopUp(c.minRec, c.recovered, gap, c.maxShortfall) returns (uint256 shortfall) {
            assertEq(r[0], 0, "reference reverts, Solidity does not");
            uint256 out = m.keeperPayout(c.callerFunds, c.recovered + shortfall, c.debt, p.avanaFee, p.borrowerSurplus);
            assertEq(shortfall, r[1], "shortfall");
            assertEq(p.avanaFee, r[2], "A");
            assertEq(p.keeperReward, r[3], "kr");
            assertEq(p.borrowerSurplus, r[4], "B");
            assertEq(out, r[5], "keeperOut");
            assertLe(out, c.callerFunds + p.oracleGain - p.avanaFee, "caller take above G - A");
        } catch (bytes memory err) {
            // With Kf >= D the gap never exceeds the floor gap, so only RecoveryBelowFloor can fire.
            assertEq(r[0], 1, "Solidity reverts, reference does not");
            assertEq(bytes4(err), ILPVaultSwapErrors.RecoveryBelowFloor.selector, "revert reason");
        }
    }

    struct FeeCase {
        uint256 value;
        uint256 debt;
        uint256 debtToCover;
        uint256 feeBps;
        uint256 minRec;
        uint256 recovered;
    }

    // TEST-198 verifies: SPEC-LIQ-010, SPEC-LIQ-017, SPEC-LIQ-019, SPEC-SET-001, REQ-SWAP-108, REQ-SWAP-089
    // An oversized debtToCover (X >= D, the unused X - D returned in keeperOut) and a transfer fee on the caller's
    // funding (Kf < X, still Kf >= D): each step of the settlement against the reference, and the fee falling on
    // keeperOut alone.
    function testFuzz_TEST_198_differentialOversizedFundingAndTransferFee(
        FeeCase memory c
    ) public {
        c.debt = bound(c.debt, 0, (1 << 120) - 1);
        c.feeBps = bound(c.feeBps, 0, 20);
        c.debtToCover = bound(c.debtToCover, c.debt + c.debt * c.feeBps / BPS + 1, (1 << 121) - 1);
        uint256 kf = c.debtToCover - c.debtToCover * c.feeBps / BPS;
        vm.assume(kf >= c.debt);
        c.value = bound(c.value, 0, (1 << 121) - 1);
        c.minRec = bound(c.minRec, 0, c.value);
        c.recovered = bound(c.recovered, 0, (1 << 121) - 1);
        uint256 rf = m.recoveryWithFloor(c.minRec, c.recovered);
        SettlementMath.Payouts memory p = m.payouts(c.value, c.debt, rf, AVANA_FEE_SHARE_BPS);
        uint256[] memory g = _a5(c.debt, p.avanaFee, p.borrowerSurplus, kf, c.recovered);
        uint256 gap = m.roundingGap(g[0], g[1], g[2], g[3], g[4]);
        assertEq(gap, _one("roundingGap", g), "roundingGap");
        uint256 shortfall = m.shortfallTopUp(c.minRec, c.recovered, gap, type(uint128).max);
        _compareKeeperPayout(kf, c.debt, c.recovered + shortfall, p);
        uint256 outFull = m.keeperPayout(c.debtToCover, c.recovered + shortfall, c.debt, p.avanaFee, p.borrowerSurplus);
        uint256 outFee = m.keeperPayout(kf, c.recovered + shortfall, c.debt, p.avanaFee, p.borrowerSurplus);
        assertEq(outFull - outFee, c.debtToCover - kf, "the funding fee falls on keeperOut alone");
    }

    function _compareKeeperPayout(
        uint256 callerFunds,
        uint256 debt,
        uint256 recoveredWithTopUp,
        SettlementMath.Payouts memory p
    ) internal {
        uint256[] memory k = _a5(callerFunds, recoveredWithTopUp, debt, p.avanaFee, p.borrowerSurplus);
        uint256[2] memory ref = abi.decode(_reference("keeperPayout", k), (uint256[2]));
        try m.keeperPayout(k[0], k[1], k[2], k[3], k[4]) returns (uint256 out) {
            assertEq(ref[0], 0, "reference reverts, Solidity does not");
            assertEq(out, ref[1], "keeperOut");
        } catch (bytes memory err) {
            assertEq(ref[0], 1, "Solidity reverts, reference does not");
            assertEq(bytes4(err), ILPVaultSwapErrors.InsufficientProceeds.selector, "revert reason");
        }
    }

    // TEST-198 verifies: SPEC-LIQ-015, SPEC-LIQ-020
    function testFuzz_TEST_198_differentialFlashAndDeleverage(
        uint256 premium,
        uint256 amount,
        uint256 maxFlashFeeBps,
        uint256 value,
        uint256 s,
        uint256 debt
    ) public {
        premium = bound(premium, 0, 1 << 128);
        amount = bound(amount, 0, 1 << 128);
        maxFlashFeeBps = bound(maxFlashFeeBps, 0, 20_000);
        value = bound(value, 0, (1 << 200) - 1);
        s = bound(s, 0, BPS);
        debt = bound(debt, 0, (1 << 200) - 1);
        assertEq(
            m.flashPremiumWithinCap(premium, amount, maxFlashFeeBps) ? 1 : 0,
            _one("flashPremiumWithinCap", _a3(premium, amount, maxFlashFeeBps)),
            "flashPremiumWithinCap"
        );
        uint256 fee = maxFlashFeeBps % 101;
        uint256 eps = premium % 1e30;
        uint256 cap = m.deleverageCap(value, s, 2, eps, fee);
        assertEq(cap, _one("deleverageCap", _a5(value, s, 2, eps, fee)), "deleverageCap");
        uint256[2] memory ref = abi.decode(_reference("deleverageRepayment", _a3(debt, cap, premium)), (uint256[2]));
        try m.deleverageRepayment(debt, cap, premium) returns (uint256 x) {
            assertEq(ref[0], 0, "reference reverts, Solidity does not");
            assertEq(x, ref[1], "x");
        } catch (bytes memory err) {
            assertEq(ref[0], 1, "Solidity reverts, reference does not");
            assertEq(
                keccak256(err),
                keccak256(abi.encodeWithSelector(ILPVaultSwapErrors.DeleverageTooSmall.selector, ref[1], premium)),
                "revert data"
            );
        }
        ref = abi.decode(_reference("deleverageAssetOut", _a3(value, debt, premium)), (uint256[2]));
        try m.deleverageAssetOut(value, debt, premium) returns (uint256 out) {
            assertEq(ref[0], 0, "reference reverts, Solidity does not");
            assertEq(out, ref[1], "assetOut");
        } catch {
            assertEq(ref[0], 1, "Solidity reverts, reference does not");
        }
    }

    function _one(
        string memory fn,
        uint256[] memory args
    ) internal returns (uint256) {
        return abi.decode(_reference(fn, args), (uint256));
    }

    function _a1(
        uint256 a
    ) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    function _a2(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        (out[0], out[1]) = (a, b);
    }

    function _a3(
        uint256 a,
        uint256 b,
        uint256 c
    ) internal pure returns (uint256[] memory out) {
        out = new uint256[](3);
        (out[0], out[1], out[2]) = (a, b, c);
    }

    function _a5(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 d,
        uint256 e
    ) internal pure returns (uint256[] memory out) {
        out = new uint256[](5);
        (out[0], out[1], out[2], out[3], out[4]) = (a, b, c, d, e);
    }
}
