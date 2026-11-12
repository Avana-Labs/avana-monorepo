// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILensErrors} from "../../src/lens/lens/ILensErrors.sol";
import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {RecordBackingView} from "../../src/lens/lens/types/RecordBackingView.sol";
import {RecordView} from "../../src/lens/lens/types/RecordView.sol";
import {TailCoverageView} from "../../src/lens/lens/types/TailCoverageView.sol";
import {WithdrawPreview} from "../../src/lens/lens/types/WithdrawPreview.sol";
import {LensProperties} from "../invariant/echidna/LensProperties.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";
import {CollPoolToken} from "../utils/mocks/CollateralizationMocks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensFuzzTest
/// @notice Previews against execution on the real Aave V4 Spoke and Collateralization over random accounts, prices,
/// debts and delays; paging over every offset and limit.
/// forge-config: default.isolate = false
contract LensFuzzTest is LensFixture {
    function setUp() public {
        _deployLens();
    }

    // TEST-069 verifies: REQ-LENS-017, REQ-LENS-028, REQ-LENS-029, Q-232
    function testFuzz_TEST_069_ghoPreviewEqualsExecution(
        uint256 units,
        uint256 debtBps,
        uint256 price
    ) public {
        units = bound(units, 600e6, 200_000e6);
        uint256 collateralUsd = units * 2e12;
        debtBps = bound(debtBps, 3000, 7900);
        price = bound(price, 0.05e8, 1.99e8);
        _open(alice, aliceProxy, 1, uint128(units));
        _borrow(aliceProxy, collateralUsd * debtBps / 1e4);
        _setVtPrice(int256(price));
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, T0);
        vm.assume(p.aaveLiquidatable && p.expectedDebtRepaid > 0);
        assertLe(p.expectedDebtRepaid, p.params.debtToCover, "Aave never pulls more than sent");
        (uint256 repaid, uint256 seized) = _execute(address(debt), debtReserveId, aliceProxy, p.params.debtToCover);
        assertEq(repaid, p.expectedDebtRepaid, "debt repaid");
        assertEq(seized, p.expectedUnitsSeized, "units seized");
    }

    // TEST-069 verifies: REQ-LENS-017, REQ-LENS-029
    function testFuzz_TEST_069_usdcPreviewEqualsExecution(
        uint256 units,
        uint256 debtBps,
        uint256 price
    ) public {
        units = bound(units, 600e6, 200_000e6);
        debtBps = bound(debtBps, 3000, 7900);
        price = bound(price, 0.05e8, 1.99e8);
        _open(alice, aliceProxy, 1, uint128(units));
        _borrowUsdc(aliceProxy, units * 2 * debtBps / 1e4);
        _setVtPrice(int256(price));
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, usdcReserveId, T0);
        vm.assume(p.aaveLiquidatable && p.expectedDebtRepaid > 0);
        (uint256 repaid, uint256 seized) = _execute(address(usdc), usdcReserveId, aliceProxy, p.params.debtToCover);
        assertEq(repaid, p.expectedDebtRepaid, "USDC repaid");
        assertEq(seized, p.expectedUnitsSeized, "units seized");
    }

    // TEST-069 verifies: REQ-LENS-028, Q-268
    function testFuzz_TEST_069_paramsStayValidUntilInclusion(
        uint256 units,
        uint256 price,
        uint256 delay
    ) public {
        units = bound(units, 300e6, 20_000e6);
        price = bound(price, 0.3e8, 1.95e8);
        delay = bound(delay, 1, 3 days);
        _open(alice, aliceProxy, 1, uint128(units));
        _borrow(aliceProxy, units * 2e12 * 7800 / 1e4);
        _setVtPrice(int256(price));
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, T0);
        vm.assume(p.aaveLiquidatable && p.expectedDebtRepaid > 0);
        vm.warp(block.timestamp + delay);
        vm.roll(block.number + delay / 12 + 1);
        uint256 before = _debtOf(aliceProxy, debtReserveId);
        (uint256 repaid,) = _execute(address(debt), debtReserveId, aliceProxy, p.params.debtToCover);
        assertGt(repaid, 0, "the params from an earlier block still execute");
        assertLe(repaid, p.params.debtToCover, "within the funding");
        assertLe(repaid, before, "never more than the debt");
    }

    // TEST-069 verifies: REQ-LENS-029, SPEC-LIQ-010
    function testFuzz_TEST_069_payoutIdentity(
        uint256 units,
        uint256 price
    ) public {
        units = bound(units, 600e6, 100_000e6);
        price = bound(price, 0.5e8, 1.99e8);
        _open(alice, aliceProxy, 1, uint128(units));
        _borrow(aliceProxy, units * 2e12 * 7500 / 1e4);
        _setVtPrice(int256(price));
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, T0);
        vm.assume(p.expectedUnitsSeized > 0);
        uint256 v = p.expectedUnitsSeized * price * 1e18 / (1e6 * 1e8);
        assertEq(
            p.expectedPayout + p.expectedAvanaFee + p.expectedBorrowerSurplus,
            p.params.debtToCover + v - p.expectedDebtRepaid,
            "Kf + V = D + A + B + keeperOut"
        );
        assertLe(p.recoveryFloor, v, "the floor never exceeds the oracle value");
        assertEq(
            p.expectedNetPayout,
            p.expectedPayout > p.params.debtToCover ? p.expectedPayout - p.params.debtToCover : 0,
            "net"
        );
    }

    // TEST-247 verifies: REQ-LENS-011, REQ-LENS-023, REQ-LENS-024
    function testFuzz_TEST_247_getRecordsPaging(
        uint256 count,
        uint256 offset,
        uint256 limit
    ) public {
        count = bound(count, 1, 16);
        for (uint256 i = 1; i <= count; ++i) {
            _open(alice, aliceProxy, i, uint128(100e6 + i));
        }
        if (limit > 200) {
            vm.expectRevert(abi.encodeWithSelector(ILensErrors.LimitTooHigh.selector, limit));
            lens.getRecords(aliceProxy, offset, limit);
            return;
        }
        RecordView[] memory r = lens.getRecords(aliceProxy, offset, limit);
        uint256 expected = offset >= count ? 0 : Math.min(limit, count - offset);
        assertEq(r.length, expected, "min(limit, n - offset), never an overflow");
    }

    // TEST-247 verifies: REQ-LENS-014, REQ-LENS-023, REQ-LENS-024
    function testFuzz_TEST_247_checkRecordBackingPaging(
        uint256 count,
        uint256 offset,
        uint256 limit
    ) public {
        count = bound(count, 1, 12);
        for (uint256 i = 1; i <= count; ++i) {
            _open(alice, aliceProxy, i, uint128(100e6 + i));
        }
        if (limit > 200) {
            vm.expectRevert(abi.encodeWithSelector(ILensErrors.LimitTooHigh.selector, limit));
            lens.checkRecordBacking(vt, offset, limit);
            return;
        }
        RecordBackingView[] memory r = lens.checkRecordBacking(vt, offset, limit);
        assertEq(r.length, offset >= count ? 0 : Math.min(limit, count - offset), "page size");
        for (uint256 i = 0; i < r.length; ++i) {
            assertTrue(r[i].backed, "every honest record is backed");
        }
    }

    // TEST-247 verifies: REQ-LENS-011, SPEC-BACK-011
    function testFuzz_TEST_247_creditedAfterReconcileEqualsPreviewRelease(
        uint128 a,
        uint128 b,
        uint128 c,
        uint256 price,
        uint256 cover
    ) public {
        a = uint128(bound(a, 500e6, 20_000e6));
        b = uint128(bound(b, 500e6, 20_000e6));
        c = uint128(bound(c, 500e6, 20_000e6));
        _open(alice, aliceProxy, 1, a);
        _open(alice, aliceProxy, 2, b);
        _open(alice, aliceProxy, 3, c);
        uint256 total = uint256(a) + b + c;
        _borrow(aliceProxy, total * 2e12 * 7800 / 1e4);
        _setVtPrice(int256(bound(price, 0.5e8, 1.99e8)));
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, T0);
        if (p.expectedDebtRepaid > 0) _execute(address(debt), debtReserveId, aliceProxy, p.params.debtToCover);
        cover;
        RecordView[] memory r = lens.getRecords(aliceProxy, 0, 16);
        uint256 debited = 0;
        for (uint256 i = 0; i < r.length; ++i) {
            assertEq(
                r[i].creditedAfterReconcile, coll.previewRelease(INTEGRATION, r[i].positionKey), "= Collateralization"
            );
            debited += r[i].credited - r[i].creditedAfterReconcile;
        }
        uint256 supplied = IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(vtReserveId, aliceProxy);
        assertEq(debited, total - supplied, "the shortfall is debited once");
    }

    // TEST-247 verifies: REQ-LENS-035, REQ-LENS-041, Q-268
    function testFuzz_TEST_247_borrowMaxLandsAtDeadline(
        uint256 units,
        uint256 debtBps,
        uint256 wait
    ) public {
        units = bound(units, 10e6, 200_000e6);
        debtBps = bound(debtBps, 0, 7000);
        wait = bound(wait, 0, 30 days);
        _open(alice, aliceProxy, 1, uint128(units));
        if (debtBps > 0) _borrow(aliceProxy, units * 2e12 * debtBps / 1e4);
        uint256 deadline = block.timestamp + wait;
        uint256 amount = lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, deadline);
        vm.assume(amount > 0);
        vm.warp(deadline);
        _borrow(aliceProxy, amount);
        assertGe(_hf(aliceProxy), 1e18, "the protocol maximum lands at or above HF 1.00");
    }

    // TEST-247 verifies: REQ-LENS-044, REQ-LENS-035
    function testFuzz_TEST_247_recommendedBelowMaximum(
        uint256 units,
        uint256 debtBps,
        uint256 floor
    ) public {
        units = bound(units, 10e6, 200_000e6);
        debtBps = bound(debtBps, 0, 7900);
        _open(alice, aliceProxy, 1, uint128(units));
        if (debtBps > 0) _borrow(aliceProxy, units * 2e12 * debtBps / 1e4);
        store.setHardHealthFloor(MARKET_ID, bound(floor, 0, 2e18));
        (uint256 rec, uint256 max) = lens.previewBorrowRecommended(alice, MARKET_ID, debtReserveId, block.timestamp);
        assertLe(rec, max, "recommended <= maximum");
        assertEq(max, lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp), "the same maximum");
    }

    // TEST-248 verifies: REQ-LENS-036, Q-269
    function testFuzz_TEST_248_repayAllCoversDebtAtDeadline(
        uint256 amount,
        uint256 wait
    ) public {
        _open(alice, aliceProxy, 1, 200_000e6);
        amount = bound(amount, 1e18, 300_000e18);
        wait = bound(wait, 0, 365 days);
        _borrow(aliceProxy, amount);
        uint256 deadline = block.timestamp + wait;
        uint256 quote = lens.quoteRepayAll(alice, MARKET_ID, debtReserveId, deadline);
        vm.warp(deadline);
        uint256 owed = _debtOf(aliceProxy, debtReserveId);
        assertGe(quote, owed, "the spend cap covers the debt at the deadline");
        assertLe(quote, Math.mulDiv(owed, 10_020, 10_000) + 1, "and stays within the margins");
    }

    // TEST-239 verifies: REQ-LENS-038, SPEC-LIQ-020, INV-089
    function testFuzz_TEST_239_repayWithCollateralBounds(
        uint256 units,
        uint256 debtAmount,
        uint256 bps
    ) public {
        _open(alice, aliceProxy, 1, 50_000e6);
        debtAmount = bound(debtAmount, 1e18, 70_000e18);
        units = bound(units, 1, 50_000e6);
        flash.setBps(bound(bps, 0, 10));
        _borrow(aliceProxy, debtAmount);
        (uint256 x, uint256 out, uint256 hfAfter) =
            lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), uint128(units), debtReserveId);
        uint256 v = units * 2e12;
        assertLe(x, _debtOf(aliceProxy, debtReserveId), "never above the debt");
        assertLe(x * (1e4 + 10), v * 1e4, "within the oracle value net of the flash cap");
        if (x > 0) {
            uint256 premium = (x * flash.bps() + 9999) / 1e4;
            assertEq(out + x + premium, v, "V = x + premium + returned");
            assertGe(hfAfter, _hf(aliceProxy), "the health factor never falls");
        }
    }

    // TEST-247 verifies: REQ-LENS-001
    function testFuzz_TEST_247_entryPointRouting(
        uint8 which,
        uint256 x
    ) public {
        LensProperties h = new LensProperties();
        h.checkRoute(which, x);
        assertTrue(h.property_constants() && h.property_coreAndModules(), "harness properties");
    }

    // TEST-247 verifies: REQ-LENS-034, SPEC-CAP-008, Q-249
    function testFuzz_TEST_247_tailCoverageMatchesSizingFormula(
        uint256 capUsdc,
        uint256 capUsdt,
        uint256 slice,
        uint256 drawCap,
        uint256 funded
    ) public {
        capUsdc = bound(capUsdc, 0, 10_000_000e8);
        capUsdt = bound(capUsdt, 0, 10_000_000e8);
        slice = bound(slice, 0, 1_000_000e8);
        drawCap = bound(drawCap, 0, 5_000_000);
        funded = bound(funded, 0, 10_000_000e18);
        store.setTokenCap(aave.hub, address(usdc), capUsdc);
        store.setTokenCap(aave.hub, address(usdt), capUsdt);
        store.setCaps(MARKET_ID, 1_000_000e8, slice, 1e8);
        _setDrawCap(ghoAssetId, aave.cdpSpoke, drawCap);
        ghoCov.set(funded, 100_000e18);
        TailCoverageView memory t = lens.getTailCoverage(aave.hub, address(debt));
        uint256 drawUsd = drawCap * 1e8;
        uint256 tailUsdc = Math.min(Math.mulDiv(capUsdc + slice, 8000, 1e4, Math.Rounding.Ceil), drawUsd);
        uint256 tailUsdt = Math.min(Math.mulDiv(capUsdt + slice, 8000, 1e4, Math.Rounding.Ceil), drawUsd);
        uint256 worst = tailUsdc >= tailUsdt ? tailUsdc : tailUsdt;
        assertEq(t.drawCapUsd, drawUsd, "draw caps at $1.00");
        assertEq(t.tailUsd, worst, "largest one-token tail, rounded up, capped by draw caps");
        assertEq(t.fundedUsd, funded / 1e10, "funded value rounded down");
        assertEq(t.ratioBps, worst == 0 ? type(uint256).max : t.fundedUsd * 1e4 / worst, "ratio rounded down");
        if (worst > 0) assertEq(t.worstToken, tailUsdc >= tailUsdt ? address(usdc) : address(usdt), "first on a tie");
    }

    // TEST-247 verifies: REQ-LENS-047
    function testFuzz_TEST_247_liquidationPriceIsTheBoundary(
        uint256 units,
        uint256 ghoDebt,
        uint256 usdcDebt
    ) public {
        units = bound(units, 100e6, 500_000e6);
        uint256 capacity = units * 2e12 * 7900 / 1e4;
        ghoDebt = bound(ghoDebt, 1e18, capacity / 2);
        usdcDebt = bound(usdcDebt, 0, capacity / 2 / 1e12);
        _open(alice, aliceProxy, 1, uint128(units));
        _borrow(aliceProxy, ghoDebt);
        if (usdcDebt > 1e6) _borrowUsdc(aliceProxy, usdcDebt);
        uint256 p = lens.getAccountRisk(alice, MARKET_ID).liquidationPrice;
        _setVtPrice(int256(p));
        assertGe(_hf(aliceProxy), 1e18, "at the price: HF >= 1.00");
        _setVtPrice(int256(p - 1));
        assertLt(_hf(aliceProxy), 1e18, "one unit below: liquidatable");
    }

    // TEST-247 verifies: REQ-LENS-049
    function testFuzz_TEST_247_withdrawPreviewMatchesAave(
        uint256 debtBps,
        uint256 units
    ) public {
        _open(alice, aliceProxy, 1, 50_000e6);
        debtBps = bound(debtBps, 1, 7900);
        _borrow(aliceProxy, 100_000e18 * debtBps / 1e4);
        units = bound(units, 1, 50_000e6);
        WithdrawPreview memory v = lens.previewWithdraw(alice, MARKET_ID, _key(1), units);
        vm.prank(aliceProxy);
        (bool ok,) = aave.cdpSpoke.call(abi.encodeCall(IAaveV4Spoke.withdraw, (vtReserveId, units, aliceProxy)));
        if (v.allowed) assertTrue(ok, "an allowed withdrawal passes Aave's health check");
        if (ok) assertEq(_hf(aliceProxy), v.healthFactorAfter, "and lands at the previewed health factor");
    }

    // ─── helpers ───

    function _execute(
        address asset,
        uint256 reserveId,
        address proxy,
        uint256 debtToCover
    ) internal returns (uint256 repaid, uint256 seized) {
        CollPoolToken(asset).mint(lpVaultSwap, debtToCover);
        uint256 debtBefore = CollPoolToken(asset).balanceOf(lpVaultSwap);
        uint256 unitsBefore = token.balanceOf(lpVaultSwap);
        vm.startPrank(lpVaultSwap);
        CollPoolToken(asset).approve(aave.cdpSpoke, debtToCover);
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(vtReserveId, reserveId, proxy, debtToCover, false);
        vm.stopPrank();
        repaid = debtBefore - CollPoolToken(asset).balanceOf(lpVaultSwap);
        seized = token.balanceOf(lpVaultSwap) - unitsBefore;
    }
}
