// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketSpeedLimits} from "../../src/policy/parameter-store/types/MarketSpeedLimits.sol";
import {SpeedLimit} from "../../src/policy/parameter-store/types/SpeedLimit.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {IRiskModuleSpeedLogic} from "../../src/policy/risk-module/IRiskModuleSpeedLogic.sol";
import {BorrowSpeedInputs} from "../../src/policy/risk-module/types/BorrowSpeedInputs.sol";
import {PledgeCharge} from "../../src/policy/risk-module/types/PledgeCharge.sol";
import {SpeedScope} from "../../src/policy/risk-module/types/SpeedScope.sol";
import {SpeedView} from "../../src/policy/risk-module/types/SpeedView.sol";
import {SpeedWindow} from "../../src/policy/risk-module/types/SpeedWindow.sol";
import {PledgeCounters} from "../../src/types/PledgeCounters.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @title RiskModuleNetSpeedUnitTest
/// @notice The net-flow speed windows of 2.7 (REQ-RISK-092, REQ-RISK-093, SPEC-CAP-011, SPEC-CAP-012) on the real
/// RiskModule and MarketRegistry: a repay gives room back in both borrow windows and a withdrawal in the pledge window,
/// never below zero; only the AaveAdapter and Collateralization may credit; borrow and repay cycles (ATTACK-206) no
/// longer fill a window; and the limit stays on the window-start base whatever the base does inside the bucket.
/// @dev World as RiskModuleSpeedUnitTest: the CDP Spoke owes 1,000,000 GHO and 2,400,000 USDC at $1.00, so the market
/// base is $3,400,000 and L = $850,000; the USDC (Hub, asset) window has L = 600,000 USDC; the pledge window has
/// L = $1,500,000 on $6,000,000 booked.
contract RiskModuleNetSpeedUnitTest is RiskModuleFixture {
    uint256 internal constant TAU = 21_600;
    uint256 internal constant E8 = 1e8;
    uint128 internal constant TEN_K = 10_000e18; // $20,000 at $2.00 per whole token

    function setUp() public {
        _deployRiskWorld();
        _enableUsdcDebt();
        _debt(1.5e18, 1000);
        rHub.setSpokeListed(USDC_ASSET, address(spoke), true);
        rHub.setSpokeListed(GHO_ASSET, address(spoke), true);
        hub.setOwed(GHO_ASSET, address(spoke), 1_000_000e18, 0);
        hub.setOwed(USDC_ASSET, address(spoke), 2_400_000e6, 0);
        aaveOracle.setPrice(USDC_RESERVE, 1e8);
        store.setMarketSpeed(
            mid, MarketSpeedLimits(uint32(TAU), 2500, 2500, 250_000e8, 2_500_000e8, 1_000_000e8, 10_000_000e8)
        );
        store.setDebtSpeed(address(hub), address(usdc), SpeedLimit(2500, uint32(TAU), 500_000e6, 5_000_000e6));
        store.setDebtSpeed(address(hub), address(gho), SpeedLimit(2500, uint32(TAU), 500_000e18, 5_000_000e18));
    }

    function _borrow(
        uint256 amount
    ) internal {
        vm.prank(address(adapter));
        riskModule.preBorrowCheck(address(proxy), USDC_RESERVE, amount);
    }

    function _repay(
        uint256 amount
    ) internal {
        vm.prank(address(adapter));
        riskModule.creditRepay(address(proxy), USDC_RESERVE, amount);
    }

    function _views() internal view returns (SpeedView memory m, SpeedView memory d) {
        (m, d) = riskModule.getBorrowSpeed(mid, USDC_RESERVE);
    }

    function _pledgeAsColl(
        uint256 bookedUsd
    ) internal returns (PledgeCharge memory c) {
        store.setMarket(mid, 4000, 10e8, 100_000_000e8, 100_000e8, 1e8);
        PledgeCounters memory k = _counters();
        k.regularUsed = uint128(bookedUsd);
        vm.prank(address(coll));
        c = _pledge(TEN_K, k, false);
    }

    // ----------------------------------------------------------------------------------------- repay credit

    // TEST-321 verifies: REQ-RISK-092, REQ-RISK-095, SPEC-CAP-011
    function test_TEST_321_repayGivesRoomBackInBothWindows() public {
        _borrow(600_000e6);
        (SpeedView memory m, SpeedView memory d) = _views();
        assertEq(m.used, 600_000 * E8);
        assertEq(d.used, 600_000e6);
        _repay(250_000e6);
        (m, d) = _views();
        assertEq(m.used, 350_000 * E8, "market window net of the repay, in USD");
        assertEq(d.used, 350_000e6, "debt window net of the repay, in USDC");
        assertEq(m.available, 500_000 * E8);
        _repay(1_000_000e6);
        (m, d) = _views();
        assertEq(m.used, 0, "never below zero");
        assertEq(d.used, 0);
        assertEq(m.limit, 850_000 * E8, "a credit leaves the limit alone");
    }

    // TEST-321 verifies: REQ-RISK-092, SPEC-CAP-013
    function test_TEST_321_repayCreditRoundsTheUsdValueDown() public {
        aaveOracle.setPrice(USDC_RESERVE, 99_990_000);
        _borrow(1e6);
        (SpeedView memory m,) = _views();
        // A borrow of 1 USDC at $0.9999 charges 99,990,000 units of USD; a repay of 0.5 USDC credits 49,995,000.
        assertEq(m.used, 99_990_000);
        _repay(0.5e6);
        (m,) = _views();
        assertEq(m.used, 99_990_000 - 49_995_000);
        // One base unit (0.000001 USDC) is worth 99.99 units of 8-decimal USD: the credit rounds down to 99.
        _repay(1);
        (m,) = _views();
        assertEq(m.used, 99_990_000 - 49_995_000 - 99, "rounded down, against the repayer");
    }

    // TEST-321 verifies: REQ-RISK-095
    function test_TEST_321_onlyTheAdapterAndCollateralizationCredit() public {
        _borrow(100_000e6);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.NotSpeedWriter.selector, wallet));
        vm.prank(wallet);
        riskModule.creditRepay(address(proxy), USDC_RESERVE, 100_000e6);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.NotSpeedWriter.selector, address(coll)));
        vm.prank(address(coll));
        riskModule.creditRepay(address(proxy), USDC_RESERVE, 100_000e6);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.NotSpeedWriter.selector, address(adapter)));
        vm.prank(address(adapter));
        riskModule.creditWithdraw(mid, 1);
        (SpeedView memory m,) = _views();
        assertEq(m.used, 100_000 * E8, "nothing credited");
    }

    // TEST-321 verifies: REQ-RISK-092, SPEC-CAP-011, SPEC-CAP-012, ATTACK-206
    function test_TEST_321_borrowRepayCyclesNoLongerFillTheWindow() public {
        for (uint256 i = 0; i < 10; ++i) {
            _borrow(85_000e6);
            _repay(85_000e6);
            vm.warp(block.timestamp + 12);
        }
        (SpeedView memory m, SpeedView memory d) = _views();
        assertEq(m.used, 0, "net zero after ten cycles");
        assertEq(m.available, 850_000 * E8, "the whole limit is still there");
        assertEq(d.available, 600_000e6);
        // Another borrower takes the full room.
        _borrow(600_000e6);
    }

    // TEST-321 verifies: REQ-RISK-092, SPEC-CAP-012, ATTACK-206
    function test_TEST_321_repaysOfOldDebtDoNotLowerTheLimit() public {
        _borrow(300_000e6);
        // Other accounts repay 2,000,000 USDC of debt from before the window: the Spoke's live debt falls to
        // $1,400,000, but the limit stays on the window-start base of $3,400,000.
        hub.setOwed(USDC_ASSET, address(spoke), 400_000e6, 0);
        (SpeedView memory m, SpeedView memory d) = _views();
        assertEq(m.limit, 850_000 * E8, "L of the window-start base");
        assertEq(d.limit, 600_000e6);
        // Their repays credit the window too, down to zero and no further.
        vm.prank(address(adapter));
        riskModule.creditRepay(address(proxy), USDC_RESERVE, 2_000_000e6);
        (m,) = _views();
        assertEq(m.used, 0);
        assertEq(m.available, 850_000 * E8);
    }

    // TEST-321 verifies: SPEC-CAP-012, ATTACK-205
    function test_TEST_321_ownBorrowsDoNotRaiseTheLimitInsideTheBucket() public {
        _borrow(400_000e6);
        hub.setOwed(USDC_ASSET, address(spoke), 2_800_000e6, 0);
        (SpeedView memory m,) = _views();
        assertEq(m.limit, 850_000 * E8, "the borrow is in the live base, not in the limit");
        assertEq(m.available, 450_000 * E8);
        SpeedWindow memory w = riskModule.getSpeedWindow(SpeedScope.MarketBorrow, bytes32(mid));
        assertEq(w.base, 3_400_000 * E8, "base written with the bucket's first charge");
        assertTrue(w.opened);
        assertEq(w.curr, 400_000 * E8);
    }

    // TEST-321 verifies: REQ-RISK-092, SPEC-CAP-011, SPEC-CAP-012
    function test_TEST_321_nextBucketTakesTheLiveBaseLessPrev() public {
        uint256 t0 = block.timestamp;
        _borrow(400_000e6);
        hub.setOwed(USDC_ASSET, address(spoke), 2_800_000e6, 0);
        vm.warp(t0 + TAU);
        (SpeedView memory m,) = _views();
        // Live $3,800,000 less prev $400,000: the window-start base is $3,400,000 again.
        assertEq(m.limit, 850_000 * E8);
        assertEq(m.used, 400_000 * E8);
        // A repay now takes from prev.
        _repay(100_000e6);
        (m,) = _views();
        assertEq(m.used, 300_000 * E8);
        assertEq(m.limit, 875_000 * E8, "live $3,800,000 less prev $300,000");
        vm.warp(t0 + 2 * TAU);
        (m,) = _views();
        assertEq(m.used, 0, "empty two windows after the first bucket");
    }

    // TEST-321 verifies: REQ-RISK-092, REQ-RISK-097
    function test_TEST_321_getSpeedWindowReturnsTheStoredWindow() public {
        SpeedWindow memory w = riskModule.getSpeedWindow(SpeedScope.DebtBorrow, keccak256(abi.encode(hub, usdc)));
        assertEq(w.start, 0);
        assertFalse(w.opened);
        _borrow(10_000e6);
        w = riskModule.getSpeedWindow(SpeedScope.DebtBorrow, keccak256(abi.encode(address(hub), address(usdc))));
        assertEq(w.start, block.timestamp);
        assertEq(w.curr, 10_000e6);
        assertEq(w.base, 2_400_000e6);
    }

    // TEST-321 verifies: REQ-RISK-092, REQ-RISK-093, REQ-RISK-097
    /// @dev `opened` is set only by a charge: a repay or a withdrawal credit on windows no charge has opened stores them
    /// unopened, and the first charge then opens them.
    function test_TEST_321_aCreditNeverOpensAWindow() public {
        bytes32 debtKey = keccak256(abi.encode(address(hub), address(usdc)));
        _repay(10_000e6);
        vm.prank(address(coll));
        riskModule.creditWithdraw(mid, 5000e8);
        assertFalse(riskModule.getSpeedWindow(SpeedScope.MarketBorrow, bytes32(mid)).opened, "market borrow");
        assertFalse(riskModule.getSpeedWindow(SpeedScope.DebtBorrow, debtKey).opened, "debt borrow");
        assertFalse(riskModule.getSpeedWindow(SpeedScope.MarketPledge, bytes32(mid)).opened, "market pledge");
        _borrow(10_000e6);
        assertTrue(riskModule.getSpeedWindow(SpeedScope.MarketBorrow, bytes32(mid)).opened, "opened by the borrow");
        assertTrue(riskModule.getSpeedWindow(SpeedScope.DebtBorrow, debtKey).opened, "opened by the borrow");
    }

    // TEST-321 verifies: REQ-RISK-092, REQ-RISK-093, REQ-RISK-097
    /// @dev The speed logic's input views: a borrow's market, keys, USD charge and limits; the same with no charge for
    /// the market and reserve; and a market's pledge limits with its booked value `regularUsed + sliceUsed`.
    function test_TEST_321_speedInputViews() public {
        IRiskModuleSpeedLogic logic = IRiskModuleSpeedLogic(rmLogics.speed);
        bytes32 debtKey = keccak256(abi.encode(address(hub), address(usdc)));
        BorrowSpeedInputs memory b = logic.borrowInputs(address(proxy), USDC_RESERVE, 10_000e6);
        assertEq(b.marketId, mid, "market of the proxy");
        assertEq(b.debtKey, debtKey, "(funding Hub, asset) key");
        assertEq(b.amountUsd, 10_000 * E8, "charge in USD");
        assertEq(b.market.window, TAU, "market limits");
        assertEq(b.debt.window, TAU, "debt limits");
        b = logic.borrowInputsOf(mid, USDC_RESERVE);
        assertEq(b.marketId, mid, "market");
        assertEq(b.debtKey, debtKey, "key");
        assertEq(b.amountUsd, 0, "no charge");
        // The market reported is the one asked for: a second identifier, whose record the registry is set to answer
        // with this market's, comes back as itself.
        uint256 other = mid + 1;
        vm.mockCall(address(registry), abi.encodeCall(registry.getMarket, (other)), abi.encode(registry.getMarket(mid)));
        assertEq(logic.borrowInputsOf(other, USDC_RESERVE).marketId, other, "the market asked for");
        vm.clearMockedCalls();
        PledgeCounters memory k = _counters();
        (k.regularUsed, k.sliceUsed) = (6_000_000e8, 250_000e8);
        coll.setCounters(k);
        (MarketSpeedLimits memory limits, uint256 booked) = logic.pledgeInputsOf(mid);
        assertEq(limits.window, TAU, "pledge limits");
        assertEq(limits.pledgeRateBps, 2500, "pledge rate");
        assertEq(booked, 6_250_000e8, "booked value");
    }

    // ----------------------------------------------------------------------------------------- withdrawal credit

    // TEST-322 verifies: REQ-RISK-093, REQ-RISK-095, SPEC-CAP-011
    function test_TEST_322_withdrawalGivesRoomBackInThePledgeWindow() public {
        PledgeCharge memory c = _pledgeAsColl(6_000_000e8);
        assertEq(c.usdCharge, 20_000e8);
        assertEq(riskModule.getPledgeSpeed(mid).used, 20_000e8);
        vm.prank(address(coll));
        riskModule.creditWithdraw(mid, 15_000e8);
        assertEq(riskModule.getPledgeSpeed(mid).used, 5000e8);
        vm.prank(address(coll));
        riskModule.creditWithdraw(mid, 1_000_000e8);
        assertEq(riskModule.getPledgeSpeed(mid).used, 0, "never below zero");
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.NotSpeedWriter.selector, wallet));
        vm.prank(wallet);
        riskModule.creditWithdraw(mid, 1);
    }

    // TEST-322 verifies: REQ-RISK-093, SPEC-CAP-011, ATTACK-206
    function test_TEST_322_pledgeWithdrawCyclesNoLongerFillTheWindow() public {
        // L = $1,500,000 on $6,000,000 booked; 100 pledge and withdrawal cycles of $20,000 leave it empty.
        for (uint256 i = 0; i < 100; ++i) {
            _pledgeAsColl(6_000_000e8);
            vm.prank(address(coll));
            riskModule.creditWithdraw(mid, 20_000e8);
        }
        assertEq(riskModule.getPledgeSpeed(mid).used, 0);
        assertEq(riskModule.getPledgeSpeed(mid).available, 1_500_000e8);
    }

    // TEST-322 verifies: REQ-RISK-093, SPEC-CAP-012
    function test_TEST_322_pledgeLimitStaysOnTheWindowStartBase() public {
        _pledgeAsColl(6_000_000e8);
        // Other depositors withdraw $2,000,000 of older records: the booked value falls, the limit does not.
        coll.setCounters(_countersWith(4_000_000e8));
        assertEq(riskModule.getPledgeSpeed(mid).limit, 1_500_000e8);
    }

    function _countersWith(
        uint256 booked
    ) internal view returns (PledgeCounters memory k) {
        k = _counters();
        k.regularUsed = uint128(booked);
    }
}
