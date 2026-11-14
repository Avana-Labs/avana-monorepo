// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILensErrors} from "../../src/lens/lens/ILensErrors.sol";
import {DebtReserveDef} from "../../src/policy/market-registry/types/DebtReserveDef.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensPreviewUnitTest
/// @notice Borrow, repay-all, re-credit and repay-with-collateral previews against the real Aave V4 Spoke and the real
/// Collateralization: every gate, the inclusion margins and the sizing of SPEC-LIQ-020.
/// forge-config: default.isolate = false
contract LensPreviewUnitTest is LensFixture {
    uint128 internal constant UNITS = 10_000e6;

    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, UNITS);
    }

    // ─── previewBorrowMax / previewBorrowRecommended ───

    // TEST-247 verifies: REQ-LENS-035, REQ-LENS-044, REQ-LENS-041, Q-398
    function test_TEST_247_borrowMaxAndRecommendedWithoutDebt() public view {
        uint256 w = _weighted(aliceProxy);
        assertEq(w, 16_000e26, "$20,000 at CF 80 %");
        (uint256 rec, uint256 max) = lens.previewBorrowRecommended(alice, MARKET_ID, debtReserveId, block.timestamp);
        assertEq(max, Math.mulDiv(w, 1e18, 1.005e18) / 1e8, "16,000 / 1.005 GHO at a zero rate");
        assertEq(rec, Math.mulDiv(w, 1e18, 1.1e18) / 1e8, "16,000 / 1.10 GHO");
        assertEq(lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp), max, "same maximum");
        assertLt(rec, max, "recommended below the maximum");
    }

    // TEST-247 verifies: REQ-LENS-035, REQ-LENS-041
    function test_TEST_247_borrowMaxExecutesAtDeadline() public {
        _borrow(aliceProxy, 3000e18);
        uint256 deadline = block.timestamp + 1200;
        uint256 amount = lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, deadline);
        vm.warp(deadline);
        _borrow(aliceProxy, amount);
        assertGe(_hf(aliceProxy), 1e18, "the max borrow lands at or above HF 1.00");
        assertLt(_hf(aliceProxy), 1.006e18, "and close to the 1.005 margin");
    }

    // TEST-247 verifies: REQ-LENS-035, REQ-LENS-041
    function test_TEST_247_borrowMaxUsdcUnits() public view {
        uint256 amount = lens.previewBorrowMax(alice, MARKET_ID, usdcReserveId, block.timestamp);
        uint256 w = _weighted(aliceProxy);
        assertEq(amount, Math.mulDiv(w, 1e18, 1.005e18) / (0.9999e8 * 1e12), "USDC base units at $0.9999");
        assertGt(amount, 0, "no minimum zeroes a capacity");
    }

    // TEST-247 verifies: REQ-LENS-035
    function test_TEST_247_borrowMaxRateGrowsTarget() public {
        _borrow(aliceProxy, 8000e18);
        uint256 now_ = lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp);
        uint256 later = lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp + 365 days);
        assertLt(later, now_, "a later deadline needs a higher health factor");
        uint256 past = lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp - 100);
        assertEq(past, now_, "a deadline in the past counts no time");
    }

    // TEST-247 verifies: REQ-LENS-035
    function test_TEST_247_borrowMaxUsesTheHighestRateOfTheAccount() public {
        _borrowUsdc(aliceProxy, 1000e6);
        uint256 deadline = block.timestamp + 365 days;
        vm.mockCall(aave.hub, abi.encodeWithSignature("getAssetDrawnRate(uint256)", ghoAssetId), abi.encode(0));
        vm.mockCall(aave.hub, abi.encodeWithSignature("getAssetDrawnRate(uint256)", usdcAssetId), abi.encode(0));
        uint256 flat = lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, deadline);
        vm.mockCall(aave.hub, abi.encodeWithSignature("getAssetDrawnRate(uint256)", usdcAssetId), abi.encode(0.5e27));
        uint256 steep = lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, deadline);
        assertLt(steep, flat, "the USDC debt's 50 % rate sets the target, though GHO is borrowed at 0 %");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-035, Q-398
    function test_TEST_247_borrowMaxHardFloor() public {
        store.setHardHealthFloor(MARKET_ID, 1.2e18);
        uint256 w = _weighted(aliceProxy);
        (uint256 rec, uint256 max) = lens.previewBorrowRecommended(alice, MARKET_ID, debtReserveId, block.timestamp);
        assertEq(max, Math.mulDiv(w, 1e18, 1.206e18) / 1e8, "H0 = 1.20 x 1.005");
        assertEq(rec, max, "recommended never above the maximum");
        store.setHardHealthFloor(MARKET_ID, 0.5e18);
        assertEq(
            lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp),
            Math.mulDiv(w, 1e18, 1.005e18) / 1e8,
            "a floor below 1.00 never lowers Aave's threshold"
        );
    }

    // TEST-247 verifies: REQ-LENS-035, REQ-LENS-019
    function test_TEST_247_borrowMaxCappedByDrawHeadroom() public {
        _borrow(aliceProxy, 500e18);
        _setDrawCap(ghoAssetId, aave.cdpSpoke, 1000);
        assertEq(lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp), 500e18, "1,000 cap - 500");
        _setDrawCap(ghoAssetId, aave.cdpSpoke, 400);
        assertEq(lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp), 0, "cap reached");
    }

    // TEST-247 verifies: REQ-LENS-035, REQ-LENS-044, SPEC-CF-005, Q-253
    function test_TEST_247_borrowMaxExcludesRescueUnits() public {
        uint256 before = lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp);
        riskModule.setRescue(true);
        _open(alice, aliceProxy, 2, 5000e6);
        uint256 after_ = lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp);
        assertApproxEqAbs(after_, before, 1e9, "rescue units add no borrowing capacity");
        assertGt(_weighted(aliceProxy), 16_000e26, "Aave counts them");
    }

    // TEST-247 verifies: REQ-LENS-035, REQ-ADAPTER-038
    function test_TEST_247_borrowGateClosedReturnsZero() public {
        rm.setGate(aliceProxy, false, false, PauseState.None);
        _assertBorrowZero("borrow not allowed");
        rm.setGate(aliceProxy, true, true, PauseState.None);
        _assertBorrowZero("status unavailable");
        rm.setGate(aliceProxy, true, false, PauseState.Frozen);
        _assertBorrowZero("Frozen");
        rm.setGate(aliceProxy, true, false, PauseState.None);
        rm.setDebtBreaker(aave.cdpSpoke, debtReserveId, 32, type(uint64).max);
        _assertBorrowZero("debt breaker on the reserve");
        assertGt(lens.previewBorrowMax(alice, MARKET_ID, usdcReserveId, block.timestamp), 0, "the other reserve");
    }

    // TEST-247 verifies: REQ-LENS-035, REQ-LENS-008
    function test_TEST_247_borrowUndeployedProxyIsZero() public view {
        (uint256 rec, uint256 max) = lens.previewBorrowRecommended(bob, MARKET_ID, debtReserveId, block.timestamp);
        assertEq(rec + max, 0, "no account yet");
    }

    // TEST-247 verifies: REQ-LENS-035, REQ-LENS-032
    function test_TEST_247_borrowUnknownReserveReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ILensErrors.UnknownDebtReserve.selector, aave.cdpSpoke, 99));
        lens.previewBorrowMax(alice, MARKET_ID, 99, block.timestamp);
    }

    // TEST-247 verifies: REQ-LENS-035, REQ-RISK-082
    function test_TEST_247_borrowCrossHubLineGate() public {
        address hub2 = makeAddr("fundingHub2");
        vm.etch(hub2, hex"00");
        DebtReserveDef memory d = reg.getDebtReserve(aave.cdpSpoke, debtReserveId);
        d.fundingHub = hub2;
        reg.setDebtReserve(aave.cdpSpoke, d);
        vm.mockCall(hub2, abi.encodeWithSignature("getAssetDrawnRate(uint256)"), abi.encode(0));
        vm.mockCall(
            hub2,
            abi.encodeWithSignature("getSpokeConfig(uint256,address)"),
            abi.encode(0, type(uint40).max, 0, true, false)
        );
        _assertBorrowZero("cross-Hub lines disabled");
        reg.setCrossHubLinesEnabled(true);
        reg.setCreditLine(hub2, address(debt), 1000, 1001, 0, 0);
        _assertBorrowZero("draw caps above the line");
        reg.setCreditLine(hub2, address(debt), 1000, 1000, 50, 49);
        _assertBorrowZero("line not covered");
        reg.setCreditLine(hub2, address(debt), 1000, 1000, 50, 50);
        assertGt(lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp), 0, "every gate passes");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-044
    function test_TEST_247_recommendedZeroWhenAboveTarget() public {
        _borrow(aliceProxy, 15_000e18);
        (uint256 rec, uint256 max) = lens.previewBorrowRecommended(alice, MARKET_ID, debtReserveId, block.timestamp);
        assertEq(rec, 0, "HF 1.067 is below 1.10: no recommended borrow");
        assertEq(max, Math.mulDiv(_weighted(aliceProxy), 1e18, 1.005e18) / 1e8 - 15_000e18, "maximum still");
    }

    // ─── quoteRepayAll ───

    // TEST-248 verifies: REQ-LENS-036, Q-269
    function test_TEST_248_repayAllAtTheBlock() public {
        _borrow(aliceProxy, 10_000e18);
        uint256 total = _debtOf(aliceProxy, debtReserveId);
        assertEq(
            lens.quoteRepayAll(alice, MARKET_ID, debtReserveId, block.timestamp),
            Math.mulDiv(total, 10_010, 10_000, Math.Rounding.Ceil),
            "debt x 1.001, rounded up"
        );
    }

    // TEST-248 verifies: REQ-LENS-036, Q-269
    function test_TEST_248_repayAllCoversDebtAtDeadline() public {
        _borrow(aliceProxy, 10_000e18);
        _borrowUsdc(aliceProxy, 2000e6);
        uint256 deadline = block.timestamp + 30 days;
        uint256 ghoQuote = lens.quoteRepayAll(alice, MARKET_ID, debtReserveId, deadline);
        uint256 usdcQuote = lens.quoteRepayAll(alice, MARKET_ID, usdcReserveId, deadline);
        uint256 rate = _drawnRate(ghoAssetId);
        uint256 rp = IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(aliceProxy).riskPremium;
        uint256 total = _debtOf(aliceProxy, debtReserveId);
        uint256 growth = RAY
            + Math.mulDiv(Math.mulDiv(rate, 1e4 + rp, 1e4, Math.Rounding.Ceil), 30 days, 365 days, Math.Rounding.Ceil);
        assertEq(ghoQuote, Math.mulDiv(total, growth * 10_010, RAY * 1e4, Math.Rounding.Ceil), "formula");
        vm.warp(deadline);
        assertGe(ghoQuote, _debtOf(aliceProxy, debtReserveId), "covers the GHO debt at the deadline");
        assertGe(usdcQuote, _debtOf(aliceProxy, usdcReserveId), "covers the USDC debt at the deadline");
    }

    // TEST-248 verifies: REQ-LENS-036
    function test_TEST_248_repayAllZeroCases() public {
        assertEq(lens.quoteRepayAll(bob, MARKET_ID, debtReserveId, block.timestamp), 0, "no proxy");
        assertEq(lens.quoteRepayAll(alice, MARKET_ID, debtReserveId, block.timestamp), 0, "no debt");
        vm.expectRevert(abi.encodeWithSelector(ILensErrors.UnknownDebtReserve.selector, aave.cdpSpoke, 42));
        lens.quoteRepayAll(alice, MARKET_ID, 42, block.timestamp);
    }

    // TEST-248 verifies: REQ-LENS-036
    function test_TEST_248_repayAllDeadlineInPast() public {
        _borrow(aliceProxy, 10_000e18);
        assertEq(
            lens.quoteRepayAll(alice, MARKET_ID, debtReserveId, 1),
            lens.quoteRepayAll(alice, MARKET_ID, debtReserveId, block.timestamp),
            "no negative time"
        );
    }

    // ─── previewRecredit ───

    // TEST-238 verifies: REQ-LENS-038, SPEC-CAP-001, Q-254
    function test_TEST_238_recreditAfterDonation() public {
        (uint128 added, uint256 charge, bool rescue) = lens.previewRecredit(MARKET_ID, _key(1));
        assertEq(added + charge, 0, "nothing to add");
        assertFalse(rescue, "nothing to book");
        vault.addUnits(_key(1), 2500e6);
        (added, charge, rescue) = lens.previewRecredit(MARKET_ID, _key(1));
        assertEq(added, coll.previewRecredit(INTEGRATION, _key(1)), "Collateralization's units");
        assertEq(added, 2500e6, "2,500 whole vault tokens");
        assertEq(charge, 5000e8, "at the accepted $2.00");
        assertFalse(rescue, "a regular top-up");
    }

    // TEST-238 verifies: REQ-LENS-038, SPEC-CAP-001
    function test_TEST_238_recreditChargeRoundsUpAtStressFloor() public {
        vault.addUnits(_key(1), 3);
        lpo.setAccepted(199_990_000, uint64(block.timestamp));
        (, uint256 charge,) = lens.previewRecredit(MARKET_ID, _key(1));
        assertEq(charge, 600, "ceil(3 x 199,990,000 / 1e6)");
        store.setCaps(MARKET_ID, 1_000_000e8, 100_000e8, 3e8);
        (, charge,) = lens.previewRecredit(MARKET_ID, _key(1));
        assertEq(charge, 900, "stress floor above the accepted price");
    }

    // TEST-238 verifies: REQ-LENS-038, REQ-RISK-066, Q-252
    function test_TEST_238_recreditRescueOnlyCases() public {
        vault.addUnits(_key(1), 2500e6);
        assertFalse(_rescueOnly(), "regular");
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.General);
        assertTrue(_rescueOnly(), "Paused(General)");
        reg.setPause(aave.hub, PauseState.Frozen, PauseReason.None);
        assertFalse(_rescueOnly(), "Frozen does not force a rescue");
        reg.setPause(aave.hub, PauseState.None, PauseReason.None);
        reg.setFrozen(alice, true);
        assertTrue(_rescueOnly(), "frozen depositor");
        reg.setFrozen(alice, false);
        rm.setMarketBreaker(MARKET_ID, 4, uint64(block.timestamp + 60));
        assertTrue(_rescueOnly(), "POOL_SHARE breaker");
        rm.setMarketBreaker(MARKET_ID, 1 | (1 << 10), uint64(block.timestamp + 60));
        assertFalse(_rescueOnly(), "ORACLE and CONFIG_DRIFT never stop a top-up");
        rm.setMarketBreaker(MARKET_ID, 0, 0);
        store.setMinPledgeUsd(MARKET_ID, 5001e8);
        assertTrue(_rescueOnly(), "charge below minPledgeUsd");
    }

    // TEST-238 verifies: REQ-LENS-038, SPEC-CAP-005
    function test_TEST_238_recreditPoolShareGate() public {
        vault.addUnits(_key(1), 2500e6);
        bytes32 key = keccak256(abi.encode(INTEGRATION, pool, bytes32(0)));
        store.setPoolShareMax(key, 1000);
        vault.setDepth(125_000e6, true);
        assertFalse(_rescueOnly(), "12,500 of 125,000 = 10 %: at the cap");
        vault.setDepth(124_999e6, true);
        assertTrue(_rescueOnly(), "above the cap");
        vault.setDepth(1e15, false);
        assertTrue(_rescueOnly(), "depth unavailable");
        store.setPoolShareMax(key, 10_000);
        assertFalse(_rescueOnly(), "no cap");
    }

    // TEST-238 verifies: REQ-LENS-038
    function test_TEST_238_recreditUnknownPositionReverts() public {
        vm.expectRevert();
        lens.previewRecredit(MARKET_ID, _key(99));
    }

    // ─── previewRepayWithCollateral ───

    // TEST-239 verifies: REQ-LENS-038, SPEC-LIQ-020, Q-255
    function test_TEST_239_repayWithCollateralSizing() public {
        _borrow(aliceProxy, 8000e18);
        (uint256 x, uint256 out, uint256 hfAfter) =
            lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), 1000e6, debtReserveId);
        uint256 v = 2000e18;
        uint256 vnet = v * 9900 / 1e4 - 2e12 - 1e18;
        uint256 cap = vnet * 1e4 / (1e4 + 10);
        assertEq(x, cap, "x = min(debt, cap)");
        uint256 premium = (x * 5 + 9999) / 1e4;
        assertEq(out, v - x - premium, "V - x - premium");
        IAaveV4Spoke.UserAccountData memory a = IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(aliceProxy);
        uint256 w = Math.mulDiv(a.avgCollateralFactor, a.totalCollateralValue, 1e18) - 1600e26;
        uint256 debtRay = a.totalDebtValueRay - x * 1e8 * RAY;
        assertEq(hfAfter, Math.mulDiv(w * 1e18, RAY, debtRay), "Aave HF with the units out and x repaid");
        assertGt(hfAfter, a.healthFactor, "the health factor rises");
    }

    // TEST-239 verifies: REQ-LENS-038, SPEC-LIQ-020
    function test_TEST_239_repayWithCollateralCappedByDebt() public {
        _borrow(aliceProxy, 100e18);
        (uint256 x, uint256 out, uint256 hfAfter) =
            lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), 1000e6, debtReserveId);
        assertEq(x, 100e18, "the whole debt");
        assertEq(out, 2000e18 - 100e18 - 0.05e18, "the rest to the wallet");
        assertEq(hfAfter, type(uint256).max, "no debt remains");
    }

    // TEST-239 verifies: REQ-LENS-038, SPEC-LIQ-020
    function test_TEST_239_repayWithCollateralUsdcDebt() public {
        _borrowUsdc(aliceProxy, 8000e6);
        (uint256 x,,) = lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), 1000e6, usdcReserveId);
        uint256 v = uint256(1000e6) * 2e8 * 1e6 / (1e6 * 0.9999e8);
        uint256 vnet = v * 9900 / 1e4 - 3 - 1e6;
        assertEq(x, vnet * 1e4 / (1e4 + 10), "USDC counts 1, one raw USDT 2 units, epsilon 1 USDC");
    }

    // TEST-239 verifies: REQ-LENS-038
    function test_TEST_239_repayWithCollateralRevertCasesReturnZeros() public {
        uint256 hf = _hf(aliceProxy);
        _assertRwcZero(alice, _key(1), 1000e6, debtReserveId, hf, "no debt");
        _borrow(aliceProxy, 8000e18);
        hf = _hf(aliceProxy);
        _assertRwcZero(alice, _key(1), 0, debtReserveId, hf, "zero units");
        _assertRwcZero(alice, _key(1), UNITS + 1, debtReserveId, hf, "above the record's credited units");
        _open(bob, bobProxy, 2, 1000e6);
        _assertRwcZero(alice, _key(2), 100e6, debtReserveId, hf, "another account's record");
        _assertRwcZero(alice, _key(77), 100e6, debtReserveId, hf, "no record");
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.MintPathSuspect);
        _assertRwcZero(alice, _key(1), 100e6, debtReserveId, hf, "Paused(MintPathSuspect)");
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.General);
        (uint256 x,,) = lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), 100e6, debtReserveId);
        assertGt(x, 0, "Paused(General) leaves repay with collateral open");
        reg.setPause(aave.hub, PauseState.Frozen, PauseReason.None);
        (x,,) = lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), 100e6, debtReserveId);
        assertGt(x, 0, "Frozen leaves repay with collateral open");
        reg.setPause(aave.hub, PauseState.None, PauseReason.None);
        reg.setFrozen(alice, true);
        (x,,) = lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), 100e6, debtReserveId);
        assertGt(x, 0, "a frozen wallet can still repay with collateral (REQ-ADAPTER-082, Q-356)");
    }

    // TEST-239 verifies: REQ-LENS-038, SPEC-LIQ-020
    function test_TEST_239_repayWithCollateralThatLowersHealthReturnsZeros() public {
        _borrow(aliceProxy, 15_000e18);
        uint256 hf = _hf(aliceProxy);
        // One whole vault token ($2) repays about $0.98 after the $1 allowance while it removes $1.60 of weighted
        // collateral: the AaveAdapter refuses a repayment that lowers the health factor while debt remains.
        _assertRwcZero(alice, _key(1), 1e6, debtReserveId, hf, "HealthFactorNotImproved");
        (uint256 x,, uint256 after_) = lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), 1000e6, debtReserveId);
        assertGt(x, 0, "a larger repayment improves it");
        assertGt(after_, hf, "and is shown");
    }

    // TEST-239 verifies: REQ-LENS-038, REQ-LENS-007
    function test_TEST_239_repayWithCollateralPriceGates() public {
        _borrow(aliceProxy, 8000e18);
        _borrowUsdc(aliceProxy, 100e6);
        uint256 hf = _hf(aliceProxy);
        lpo.setState(PriceState.Cached, 0, true);
        _assertRwcZero(alice, _key(1), 100e6, debtReserveId, hf, "market not liquidation-grade");
        lpo.setState(PriceState.Live, 0, false);
        lpo.setTokenAt(0, uint64(block.timestamp - FEED_AGE - 1), 0);
        _assertRwcZero(alice, _key(1), 100e6, debtReserveId, hf, "an input past its liquidation age");
        lpo.setTokenAt(0, uint64(block.timestamp), 0);
        usdcOracle.set(1e8, PriceState.Cached, 1e8, uint64(block.timestamp));
        _assertRwcZero(alice, _key(1), 100e6, usdcReserveId, _hf(aliceProxy), "debt price not fresh");
        hf = _hf(aliceProxy);
        vm.mockCall(aave.hub, abi.encodeWithSignature("getAddedAssets(uint256)", vtAssetId), abi.encode(1));
        _assertRwcZero(alice, _key(1), 100e6, debtReserveId, hf, "Hub shares differ from assets");
        vm.clearMockedCalls();
    }

    // TEST-239 verifies: REQ-LENS-038
    function test_TEST_239_repayWithCollateralUndeployedProxy() public view {
        (uint256 x, uint256 out, uint256 hf) =
            lens.previewRepayWithCollateral(bob, MARKET_ID, _key(1), 100e6, debtReserveId);
        assertEq(x + out, 0, "no account");
        assertEq(hf, type(uint256).max, "no debt: Aave's max");
    }

    // TEST-239 verifies: REQ-LENS-038, REQ-LENS-032
    function test_TEST_239_repayWithCollateralUnknownReserveReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ILensErrors.UnknownDebtReserve.selector, aave.cdpSpoke, 9));
        lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), 100e6, 9);
    }

    // TEST-239 verifies: REQ-LENS-038, SPEC-LIQ-020
    function test_TEST_239_repayWithCollateralWithinReconciledUnits() public {
        _borrow(aliceProxy, 15_000e18);
        _setVtPrice(1.8e8);
        uint256 seized = _seizeAndKeep(aliceProxy, 3000e18);
        _setVtPrice(2e8);
        uint256 limit = coll.previewRelease(INTEGRATION, _key(1));
        assertEq(limit, UNITS - seized, "credited after reconciliation");
        (uint256 x,,) = lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), uint128(limit), debtReserveId);
        assertGt(x, 0, "within the reconciled units");
        uint256 hf = _hf(aliceProxy);
        _assertRwcZero(alice, _key(1), uint128(limit + 1), debtReserveId, hf, "one unit above");
    }

    // ─── helpers ───

    function _weighted(
        address proxy
    ) internal view returns (uint256) {
        IAaveV4Spoke.UserAccountData memory a = IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(proxy);
        return Math.mulDiv(a.avgCollateralFactor, a.totalCollateralValue, 1e18);
    }

    function _drawnRate(
        uint256 assetId
    ) internal view returns (uint256 rate) {
        (bool ok, bytes memory data) =
            aave.hub.staticcall(abi.encodeWithSignature("getAssetDrawnRate(uint256)", assetId));
        require(ok, "rate");
        rate = abi.decode(data, (uint256));
    }

    function _assertBorrowZero(
        string memory why
    ) internal view {
        (uint256 rec, uint256 max) = lens.previewBorrowRecommended(alice, MARKET_ID, debtReserveId, block.timestamp);
        assertEq(rec, 0, why);
        assertEq(max, 0, why);
        assertEq(lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp), 0, why);
    }

    function _rescueOnly() internal view returns (bool rescue) {
        (,, rescue) = lens.previewRecredit(MARKET_ID, _key(1));
    }

    function _assertRwcZero(
        address wallet,
        bytes32 key,
        uint128 units,
        uint256 reserveId,
        uint256 hf,
        string memory why
    ) internal view {
        (uint256 x, uint256 out, uint256 hfAfter) =
            lens.previewRepayWithCollateral(wallet, MARKET_ID, key, units, reserveId);
        assertEq(x, 0, why);
        assertEq(out, 0, why);
        assertEq(hfAfter, hf, why);
    }
}
