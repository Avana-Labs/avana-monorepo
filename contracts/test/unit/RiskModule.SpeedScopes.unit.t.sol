// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketSpeedLimits} from "../../src/policy/parameter-store/types/MarketSpeedLimits.sol";
import {SpeedLimit} from "../../src/policy/parameter-store/types/SpeedLimit.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PledgeCharge} from "../../src/policy/risk-module/types/PledgeCharge.sol";
import {SpeedView} from "../../src/policy/risk-module/types/SpeedView.sol";
import {PledgeCounters} from "../../src/types/PledgeCounters.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @title RiskModuleSpeedScopesUnitTest
/// @notice The keys and bases of the speed windows (2.7 REQ-RISK-092, REQ-RISK-093, REQ-RISK-095): a cross-Hub debt
/// reserve has its own (funding Hub, asset) window and base while sharing the market window; the market base sums the
/// Spoke's debt over every funding Hub; windows of other markets and assets stay untouched; the pledge base counts the
/// slice; a re-credit is charged like a pledge.
/// @dev World: the RiskModule fixture with DAI enabled as a cross-Hub reserve funded by `hub2`; the Spoke owes 600,000
/// GHO to the home Hub and 400,000 DAI to `hub2`, both at $1.00, so the market base is $1,000,000.
contract RiskModuleSpeedScopesUnitTest is RiskModuleFixture {
    uint256 internal constant TAU = 21_600;
    uint256 internal constant E8 = 1e8;
    uint128 internal constant TEN_K = 10_000e18;

    function setUp() public {
        _deployRiskWorld();
        _enableCrossHubDebt();
        _debt(1.5e18, 1000);
        rHub.setSpokeListed(GHO_ASSET, address(spoke), true);
        hub2.setSpokeListed(DAI_ASSET, address(spoke), true);
        hub.setOwed(GHO_ASSET, address(spoke), 600_000e18, 0);
        hub2.setOwed(DAI_ASSET, address(spoke), 400_000e18, 0);
        store.setMarketSpeed(
            mid, MarketSpeedLimits(uint32(TAU), 5000, 2500, 0, 10_000_000e8, 1_000_000e8, 10_000_000e8)
        );
        store.setDebtSpeed(address(hub), address(gho), SpeedLimit(5000, uint32(TAU), 0, 10_000_000e18));
        store.setDebtSpeed(address(hub2), address(tDai), SpeedLimit(5000, uint32(TAU), 0, 10_000_000e18));
    }

    function _borrow(
        uint256 r,
        uint256 amount
    ) internal {
        vm.prank(address(adapter));
        riskModule.preBorrowCheck(address(proxy), r, amount);
    }

    // TEST-321 verifies: REQ-RISK-092, SPEC-CAP-012
    function test_TEST_321_marketBaseSumsEveryFundingHub() public view {
        (SpeedView memory m, SpeedView memory g) = riskModule.getBorrowSpeed(mid, GHO_RESERVE);
        (, SpeedView memory d) = riskModule.getBorrowSpeed(mid, DAI_RESERVE);
        assertEq(m.limit, 500_000 * E8, "50 % of $600,000 GHO + $400,000 DAI");
        assertEq(g.limit, 300_000e18, "50 % of the GHO the Spoke owes the home Hub");
        assertEq(d.limit, 200_000e18, "50 % of the DAI the Spoke owes hub2");
    }

    // TEST-321 verifies: REQ-RISK-092, REQ-RISK-095
    function test_TEST_321_crossHubReserveHasItsOwnDebtWindow() public {
        _borrow(DAI_RESERVE, 150_000e18);
        (SpeedView memory m, SpeedView memory g) = riskModule.getBorrowSpeed(mid, GHO_RESERVE);
        (, SpeedView memory d) = riskModule.getBorrowSpeed(mid, DAI_RESERVE);
        assertEq(m.used, 150_000 * E8, "the market window counts every reserve");
        assertEq(d.used, 150_000e18, "the (hub2, DAI) window is charged");
        assertEq(g.used, 0, "the (home Hub, GHO) window is not");
        // DAI room left: 50 % of (400,000 − 150,000) = 125,000 limit, 150,000 used: none.
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DebtSpeedExceeded.selector,
                address(hub2),
                address(tDai),
                uint256(0),
                uint64(block.timestamp + 2 * TAU)
            )
        );
        _borrow(DAI_RESERVE, 1e18);
        // GHO still has its own room under the shared market window.
        _borrow(GHO_RESERVE, 100_000e18);
    }

    // TEST-321 verifies: REQ-RISK-092
    function test_TEST_321_debtBaseCountsOnlyTheFundingHub() public {
        // The Spoke also owes GHO on hub2 (an unrelated asset id there): the (home Hub, GHO) base is unchanged.
        hub2.setOwed(GHO_ASSET, address(spoke), 9_000_000e18, 0);
        (, SpeedView memory g) = riskModule.getBorrowSpeed(mid, GHO_RESERVE);
        assertEq(g.limit, 300_000e18);
    }

    // TEST-321 verifies: REQ-RISK-092, REQ-RISK-097
    function test_TEST_321_unknownReserveViewIsUnavailable() public view {
        (SpeedView memory m, SpeedView memory d) = riskModule.getBorrowSpeed(mid, 77);
        assertTrue(m.unavailable && d.unavailable);
    }

    // TEST-321 verifies: REQ-RISK-092, REQ-RISK-095
    function test_TEST_321_otherMarketWindowUntouched() public {
        uint256 other = _listRegisteredMarket();
        _borrow(GHO_RESERVE, 100_000e18);
        (SpeedView memory m,) = riskModule.getBorrowSpeed(other, GHO_RESERVE);
        assertEq(m.used, 0, "each market has its own window");
    }

    // TEST-321 verifies: SPEC-CAP-013, REQ-RISK-092
    function test_TEST_321_usdChargeAtTheReservePrice() public {
        aaveOracle.setPrice(DAI_RESERVE, 99_990_001);
        _borrow(DAI_RESERVE, 1e18 + 1);
        (SpeedView memory m,) = riskModule.getBorrowSpeed(mid, DAI_RESERVE);
        // ⌈(1e18 + 1) × 99,990,001 / 1e18⌉ = 99,990,002: rounded up against the borrower.
        assertEq(m.used, 99_990_002);
    }

    // TEST-322 verifies: REQ-RISK-093, SPEC-CAP-012
    function test_TEST_322_pledgeBaseCountsTheSlice() public {
        store.setMarket(mid, 4000, 10e8, 100_000_000e8, 100_000_000e8, 1e8);
        PledgeCounters memory k = _counters();
        (k.regularUsed, k.sliceUsed) = (3_000_000e8, 5_000_000e8);
        vm.prank(address(coll));
        riskModule.checkPledge(wallet, address(proxy), mid, V3, bytes32(uint256(1)), TEN_K, k, false);
        coll.setCounters(k);
        SpeedView memory p = riskModule.getPledgeSpeed(mid);
        // 25 % of ($8,000,000 − $20,000) = $1,995,000.
        assertEq(p.limit, 1_995_000e8);
        assertEq(p.used, 20_000e8);
    }

    // TEST-322 verifies: REQ-RISK-093, REQ-RISK-099
    function test_TEST_322_recreditIsChargedLikeAPledge() public {
        // A re-credit is a checkPledge of the added units with the account's open record counted.
        PledgeCounters memory k = _counters();
        k.accountRecords = 1;
        vm.prank(address(coll));
        PledgeCharge memory c =
            riskModule.checkPledge(wallet, address(proxy), mid, V3, bytes32(uint256(1)), TEN_K, k, false);
        assertEq(riskModule.getPledgeSpeed(mid).used, c.usdCharge);
    }

    // TEST-322 verifies: REQ-RISK-093, REQ-RISK-097
    function test_TEST_322_pledgeWindowFreesAndReportsMoreAt() public {
        PledgeCounters memory k = _counters();
        uint256 t0 = block.timestamp;
        vm.prank(address(coll));
        riskModule.checkPledge(wallet, address(proxy), mid, V3, bytes32(uint256(1)), TEN_K, k, false);
        SpeedView memory p = riskModule.getPledgeSpeed(mid);
        assertEq(p.moreAt, uint64(t0 + 2 * TAU));
        assertEq(p.moreAmount, 20_000e8);
        vm.warp(t0 + TAU);
        _report(uint64(t0 + TAU), 1e8, 1e8);
        p = riskModule.getPledgeSpeed(mid);
        assertEq(p.moreAt, uint64(t0 + 2 * TAU), "rolled into prev, frees at start + tau");
        vm.warp(t0 + 2 * TAU);
        assertEq(riskModule.getPledgeSpeed(mid).used, 0);
    }

    // TEST-322 verifies: REQ-RISK-096, REQ-RISK-099
    function test_TEST_322_unsetPledgeWindowFailsClosed() public {
        store.setMarketSpeed(mid, MarketSpeedLimits(0, 0, 0, 0, 0, 0, 0));
        PledgeCounters memory k = _counters();
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PledgeSpeedExceeded.selector, mid, 0, uint64(0)));
        vm.prank(address(coll));
        riskModule.checkPledge(wallet, address(proxy), mid, V3, bytes32(uint256(1)), TEN_K, k, false);
        assertEq(riskModule.getPledgeSpeed(mid).limit, 0);
    }

    // TEST-322 verifies: REQ-RISK-093, REQ-RISK-096
    function test_TEST_322_pledgeGatesRunBeforeTheWindow() public {
        store.setMarketSpeed(mid, MarketSpeedLimits(0, 0, 0, 0, 0, 0, 0));
        PledgeCounters memory k = _counters();
        // Below the minimum pledge: the minimum is reported, not the closed window.
        vm.expectRevert();
        vm.prank(address(coll));
        riskModule.checkPledge(wallet, address(proxy), mid, V3, bytes32(uint256(1)), 1e18, k, false);
        // Zero units: ZeroLiquidity first.
        vm.expectRevert(IRiskModuleErrors.ZeroLiquidity.selector);
        vm.prank(address(coll));
        riskModule.checkPledge(wallet, address(proxy), mid, V3, bytes32(uint256(1)), 0, k, false);
        // A valid pledge meets the closed window last.
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PledgeSpeedExceeded.selector, mid, 0, uint64(0)));
        vm.prank(address(coll));
        riskModule.checkPledge(wallet, address(proxy), mid, V3, bytes32(uint256(1)), TEN_K, k, false);
    }

    // TEST-322 verifies: REQ-RISK-031, REQ-RISK-097
    function test_TEST_322_previewPledgeIgnoresTheWindow() public {
        store.setMarketSpeed(mid, MarketSpeedLimits(0, 0, 0, 0, 0, 0, 0));
        // The app reads getPledgeSpeed beside previewPledge; the preview itself is unchanged by the window.
        assertTrue(riskModule.getPledgeSpeed(mid).limit == 0);
        riskModule.previewPledge(wallet, mid, bytes32(uint256(1)));
    }

    // TEST-321 verifies: REQ-RISK-092, REQ-RISK-098
    function test_TEST_321_zeroAmountFromTheAdapterChargesNothing() public {
        _borrow(GHO_RESERVE, 0);
        (SpeedView memory m, SpeedView memory g) = riskModule.getBorrowSpeed(mid, GHO_RESERVE);
        assertEq(m.used + g.used, 0);
        // But a window already over its limit refuses even zero.
        _borrow(GHO_RESERVE, 300_000e18);
        store.setMarketSpeed(mid, MarketSpeedLimits(uint32(TAU), 0, 0, 0, 100_000e8, 0, 0));
        vm.expectRevert();
        _borrow(GHO_RESERVE, 0);
    }
}
