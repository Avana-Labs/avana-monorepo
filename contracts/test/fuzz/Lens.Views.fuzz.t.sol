// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {DebtReserveView} from "../../src/lens/lens/types/DebtReserveView.sol";
import {MarketView} from "../../src/lens/lens/types/MarketView.sol";
import {RecordBackingView} from "../../src/lens/lens/types/RecordBackingView.sol";
import {WithdrawPreview} from "../../src/lens/lens/types/WithdrawPreview.sol";
import {CapView} from "../../src/types/CapView.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensViewsFuzzTest
/// @notice The formulas of the market, reserve, headroom, re-credit and preview views over random states on the real
/// Aave V4 Hub and Spoke and the real Collateralization: each value against its spec formula computed here from the
/// chain's own reads, and the monotonicity the app relies on.
/// forge-config: default.isolate = false
contract LensViewsFuzzTest is LensFixture {
    function setUp() public {
        _deployLens();
    }

    // TEST-247 verifies: REQ-LENS-045
    function testFuzz_TEST_247_marketSupplyValue(
        uint256 units,
        uint256 accepted
    ) public {
        units = bound(units, 1, 1_000_000e6);
        accepted = bound(accepted, 1, 1e12);
        _open(alice, aliceProxy, 1, uint128(units));
        lpo.setAccepted(accepted, uint64(block.timestamp));
        MarketView memory v = lens.getMarket(MARKET_ID);
        assertEq(v.suppliedUnits, IAaveV4Hub(aave.hub).getSpokeAddedAssets(vtAssetId, aave.cdpSpoke), "Hub supply");
        assertEq(v.suppliedUsd, units * accepted / 1e6, "floor(units x accepted / 10^d)");
        assertEq(v.acceptedPrice, accepted, "accepted");
    }

    // TEST-247 verifies: REQ-LENS-046
    function testFuzz_TEST_247_reserveRatesFollowTheHub(
        uint256 borrowGho,
        uint256 fee,
        uint256 wait
    ) public {
        _open(alice, aliceProxy, 1, 1_000_000e6);
        borrowGho = bound(borrowGho, 1e18, 900_000e18);
        fee = bound(fee, 0, 5000);
        wait = bound(wait, 0, 365 days);
        _borrow(aliceProxy, borrowGho);
        _hubConfig(abi.encodeWithSignature("updateLiquidityFee(address,uint256,uint256)", aave.hub, ghoAssetId, fee));
        vm.warp(block.timestamp + wait);
        DebtReserveView memory v = lens.getDebtReserve(aave.cdpSpoke, debtReserveId);
        uint256 owed = v.drawn + v.premium;
        assertEq(owed, IAaveV4Hub(aave.hub).getSpokeTotalOwed(ghoAssetId, aave.cdpSpoke), "one Spoke draws GHO");
        assertEq(v.utilizationBps, owed * 1e4 / v.added, "utilization");
        assertEq(v.supplyRateRay, Math.mulDiv(v.drawnRateRay, owed * (1e4 - fee), v.added * 1e4), "supply rate");
        assertLe(v.supplyRateRay, v.drawnRateRay, "never above the drawn rate");
        assertEq(v.drawHeadroom, BORROW_CAP * 1e18 > owed ? BORROW_CAP * 1e18 - owed : 0, "headroom");
    }

    // TEST-247 verifies: REQ-LENS-018
    function testFuzz_TEST_247_capHeadroomFormula(
        uint256 units,
        uint256 marketCap,
        uint256 tokenCap,
        uint256 depositorCap
    ) public {
        units = bound(units, 10e6, 100_000e6);
        _open(alice, aliceProxy, 1, uint128(units));
        marketCap = bound(marketCap, 0, 10_000_000e8);
        tokenCap = bound(tokenCap, 0, 10_000_000e8);
        depositorCap = bound(depositorCap, 0, 10_000_000e8);
        store.setCaps(MARKET_ID, marketCap, 100_000e8, 1e8);
        store.setTokenCap(aave.hub, address(usdc), tokenCap);
        store.setDepositorCap(aave.hub, depositorCap);
        CapView memory c = lens.getCapHeadroom(vt, alice);
        uint256 charge = units * 2e8 / 1e6;
        assertEq(c.marketHeadroomUsd, marketCap > charge ? marketCap - charge : 0, "market");
        uint256 usedUsdc = coll.getCounters(vt, alice).tokenUsed[0];
        assertEq(c.tokenHeadroomUsd[0], tokenCap > usedUsdc ? tokenCap - usedUsdc : 0, "USDC");
        assertEq(c.depositorHeadroomUsd, depositorCap > charge ? depositorCap - charge : 0, "depositor");
    }

    // TEST-238 verifies: REQ-LENS-038, SPEC-CAP-001
    function testFuzz_TEST_238_recreditCharge(
        uint128 donation,
        uint256 accepted,
        uint256 floor
    ) public {
        _open(alice, aliceProxy, 1, 10_000e6);
        donation = uint128(bound(donation, 1, 1_000_000e6));
        accepted = bound(accepted, 1, 1e10);
        floor = bound(floor, 0, 1e10);
        vault.addUnits(_key(1), donation);
        lpo.setAccepted(accepted, uint64(block.timestamp));
        store.setCaps(MARKET_ID, 1_000_000e8, 100_000e8, floor);
        (uint128 added, uint256 charge,) = lens.previewRecredit(MARKET_ID, _key(1));
        assertEq(added, donation, "the donated units");
        uint256 price = accepted > floor ? accepted : floor;
        assertEq(
            charge, Math.mulDiv(donation, price, 1e6, Math.Rounding.Ceil), "ceil(added x max(price, floor) / 10^d)"
        );
    }

    // TEST-247 verifies: REQ-LENS-014, INV-002
    function testFuzz_TEST_247_recordBackedIffLiveCoversCredit(
        uint128 live,
        bool inCustody
    ) public {
        _open(alice, aliceProxy, 1, 10_000e6);
        live = uint128(bound(live, 0, 20_000e6));
        vm.mockCall(address(lpVault), abi.encodeWithSignature("unitsOf(bytes32)", _key(1)), abi.encode(live));
        if (!inCustody) {
            vm.mockCall(
                address(lpVault), abi.encodeWithSignature("depositorOf(bytes32)", _key(1)), abi.encode(address(0))
            );
        }
        RecordBackingView[] memory r = lens.checkRecordBacking(vt, 0, 1);
        assertEq(r[0].inCustody, inCustody, "custody");
        assertEq(r[0].liveUnits, inCustody ? live : 0, "live units");
        assertEq(r[0].backed, inCustody && live >= 10_000e6, "backed iff in custody and live >= credited");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-049
    function testFuzz_TEST_247_withdrawPreviewMonotone(
        uint256 debtBps,
        uint256 a,
        uint256 b
    ) public {
        _open(alice, aliceProxy, 1, 50_000e6);
        _borrow(aliceProxy, 100_000e18 * bound(debtBps, 1, 7900) / 1e4);
        a = bound(a, 1, 50_000e6);
        b = bound(b, a, 50_000e6);
        WithdrawPreview memory va = lens.previewWithdraw(alice, MARKET_ID, _key(1), a);
        WithdrawPreview memory vb = lens.previewWithdraw(alice, MARKET_ID, _key(1), b);
        assertGe(va.healthFactorAfter, vb.healthFactorAfter, "more units out, lower health factor");
        assertLe(va.healthFactorAfter, _hf(aliceProxy), "never above the current health factor");
        if (vb.allowed) assertTrue(va.allowed, "a smaller withdrawal of an allowed one is allowed");
    }

    // TEST-247 verifies: REQ-LENS-035, REQ-LENS-036
    function testFuzz_TEST_247_previewsMonotoneInDeadline(
        uint256 debtAmount,
        uint256 t1,
        uint256 t2
    ) public {
        _open(alice, aliceProxy, 1, 100_000e6);
        _borrow(aliceProxy, bound(debtAmount, 1e18, 100_000e18));
        t1 = bound(t1, block.timestamp, block.timestamp + 365 days);
        t2 = bound(t2, t1, block.timestamp + 365 days);
        assertGe(
            lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, t1),
            lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, t2),
            "a later deadline never allows more"
        );
        assertLe(
            lens.quoteRepayAll(alice, MARKET_ID, debtReserveId, t1),
            lens.quoteRepayAll(alice, MARKET_ID, debtReserveId, t2),
            "a later deadline never needs less"
        );
    }

    // TEST-239 verifies: REQ-LENS-038, SPEC-LIQ-020
    function testFuzz_TEST_239_repayWithCollateralMonotoneInUnits(
        uint256 debtAmount,
        uint256 a,
        uint256 b
    ) public {
        _open(alice, aliceProxy, 1, 50_000e6);
        _borrow(aliceProxy, bound(debtAmount, 1e18, 70_000e18));
        a = bound(a, 1, 50_000e6);
        b = bound(b, a, 50_000e6);
        (uint256 xa,,) = lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), uint128(a), debtReserveId);
        (uint256 xb,,) = lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), uint128(b), debtReserveId);
        if (xa > 0 && xb > 0) assertLe(xa, xb, "more units repay at least as much");
        assertLe(xb, _debtOf(aliceProxy, debtReserveId), "never above the debt");
    }

    // TEST-247 verifies: REQ-LENS-047
    function testFuzz_TEST_247_borrowRatesFollowRiskPremium(
        uint256 drawnRate,
        uint256 premium
    ) public {
        _open(alice, aliceProxy, 1, 10_000e6);
        drawnRate = bound(drawnRate, 0, 10e27);
        premium = bound(premium, 0, 1e4);
        vm.mockCall(aave.hub, abi.encodeWithSignature("getAssetDrawnRate(uint256)"), abi.encode(drawnRate));
        vm.mockCall(
            aave.cdpSpoke,
            abi.encodeWithSignature("getUserAccountData(address)", aliceProxy),
            abi.encode(IAaveV4Spoke.UserAccountData(premium, 0, type(uint256).max, 0, 0, 1, 0))
        );
        uint256[] memory rates = lens.getAccountRisk(alice, MARKET_ID).borrowRatesRay;
        for (uint256 i = 0; i < rates.length; ++i) {
            assertEq(rates[i], Math.mulDiv(drawnRate, 1e4 + premium, 1e4, Math.Rounding.Ceil), "drawn x (1 + premium)");
        }
        vm.clearMockedCalls();
    }
}
