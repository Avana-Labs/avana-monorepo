// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketSpeedLimits} from "../../src/policy/parameter-store/types/MarketSpeedLimits.sol";
import {SpeedLimit} from "../../src/policy/parameter-store/types/SpeedLimit.sol";
import {IRiskModuleChecks} from "../../src/policy/risk-module/IRiskModuleChecks.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PledgeCharge} from "../../src/policy/risk-module/types/PledgeCharge.sol";
import {SpeedView} from "../../src/policy/risk-module/types/SpeedView.sol";
import {PositionProxy} from "../../src/proxy/position-proxy/PositionProxy.sol";
import {PledgeCounters} from "../../src/types/PledgeCounters.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @title RiskModuleSpeedUnitTest
/// @notice The borrow-speed and pledge-speed limits of 2.7 (REQ-RISK-092 to REQ-RISK-099) on the real RiskModule and
/// MarketRegistry: the two borrow windows and their bases, the pledge window, who writes, fail-closed scopes,
/// parameter changes, gate precedence and the views.
/// @dev World: the RiskModule fixture with USDC enabled as debt reserve 5 and the account in debt (HF 1.5). The CDP
/// Spoke owes the Hub 1,000,000 GHO and 2,400,000 USDC, both at $1.00 unless a test sets another price, so the
/// market's base is $3,400,000. Launch parameters: τ = 21,600 s, 2,500 bps, $250,000 .. $2,500,000 (borrow),
/// $1,000,000 .. $10,000,000 (pledge); USDC (Hub, asset) 2,500 bps within 500,000 .. 5,000,000 USDC.
contract RiskModuleSpeedUnitTest is RiskModuleFixture {
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
        store.setMarketSpeed(mid, _launchMarket());
        store.setDebtSpeed(address(hub), address(usdc), SpeedLimit(2500, uint32(TAU), 500_000e6, 5_000_000e6));
        store.setDebtSpeed(address(hub), address(gho), SpeedLimit(2500, uint32(TAU), 500_000e18, 5_000_000e18));
    }

    function _launchMarket() internal pure returns (MarketSpeedLimits memory) {
        return
            MarketSpeedLimits(
                uint32(TAU), 2500, 2500, 250_000 * 1e8, 2_500_000 * 1e8, 1_000_000 * 1e8, 10_000_000 * 1e8
            );
    }

    function _borrowAsAdapter(
        uint256 r,
        uint256 amount
    ) internal {
        vm.prank(address(adapter));
        riskModule.preBorrowCheck(address(proxy), r, amount);
    }

    function _marketView() internal view returns (SpeedView memory m) {
        (m,) = riskModule.getBorrowSpeed(mid, USDC_RESERVE);
    }

    function _debtView() internal view returns (SpeedView memory d) {
        (, d) = riskModule.getBorrowSpeed(mid, USDC_RESERVE);
    }

    // ----------------------------------------------------------------------------------------- borrow windows

    // TEST-321 verifies: REQ-RISK-092, REQ-RISK-095, REQ-RISK-097, SPEC-CAP-012
    function test_TEST_321_adapterBorrowChargesBothWindows() public {
        SpeedView memory m = _marketView();
        assertEq(m.limit, 850_000 * E8, "25 % of $3,400,000");
        assertEq(m.used, 0);
        _borrowAsAdapter(USDC_RESERVE, 600_000e6);
        m = _marketView();
        SpeedView memory d = _debtView();
        assertEq(m.used, 600_000 * E8, "market window charged in USD");
        assertEq(d.used, 600_000e6, "debt window charged in USDC base units");
        assertEq(m.moreAt, uint64(block.timestamp + 2 * TAU), "frees two windows after the bucket start");
        assertEq(m.moreAmount, 600_000 * E8);
    }

    // TEST-321 verifies: REQ-RISK-095, ATTACK-205
    function test_TEST_321_otherCallersNeverWrite() public {
        riskModule.preBorrowCheck(address(proxy), USDC_RESERVE, 600_000e6);
        vm.prank(wallet);
        riskModule.preBorrowCheck(address(proxy), USDC_RESERVE, 600_000e6);
        vm.prank(address(coll));
        riskModule.preBorrowCheck(address(proxy), USDC_RESERVE, 600_000e6);
        assertEq(_marketView().used, 0, "no window filled without the Adapter");
        assertEq(_debtView().used, 0);
    }

    // TEST-321 verifies: REQ-RISK-092, REQ-RISK-098, SPEC-CAP-011, SPEC-CAP-012, SPEC-CAP-013, BOR-023
    function test_TEST_321_workedExampleRevertsWithRoomAndTime() public {
        uint256 t0 = block.timestamp;
        _borrowAsAdapter(USDC_RESERVE, 600_000e6);
        // The Spoke now owes the borrowed 600,000 USDC too: debt $4,000,000, base $3,400,000, L = $850,000.
        hub.setOwed(USDC_ASSET, address(spoke), 3_000_000e6, 0);
        aaveOracle.setPrice(USDC_RESERVE, 99_990_000);
        vm.warp(t0 + 100);
        SpeedView memory m = _marketView();
        // $1,000,000 GHO + 3,000,000 USDC at $0.9999 = $3,999,700; base $3,399,700; L = $849,925.
        assertEq(m.limit, 849_925 * E8);
        assertEq(m.available, 249_925 * E8);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.BorrowSpeedExceeded.selector, mid, 249_925 * E8, uint64(t0 + 2 * TAU)
            )
        );
        _borrowAsAdapter(USDC_RESERVE, 300_000e6);
        // 249,950 USDC charges ⌈249,950 × 0.9999⌉ = $249,925.005 → 24,992,500,500,000 units: one too many.
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.BorrowSpeedExceeded.selector, mid, 249_925 * E8, uint64(t0 + 2 * TAU)
            )
        );
        _borrowAsAdapter(USDC_RESERVE, 249_950e6);
        // At $1.00 the example of 2.7 holds exactly: $250,000 of room.
        aaveOracle.setPrice(USDC_RESERVE, 1e8);
        assertEq(_marketView().available, 250_000 * E8);
    }

    // TEST-321 verifies: REQ-RISK-092, REQ-RISK-098
    function test_TEST_321_debtWindowBindsAndNothingIsCharged() public {
        // USDC window: owed 2,400,000 → L = 600,000 USDC; market window has $850,000.
        _borrowAsAdapter(USDC_RESERVE, 500_000e6);
        SpeedView memory d = _debtView();
        // Own charge left out of the base: 25 % of 1,900,000 = 475,000, below the 500,000 minimum.
        assertEq(d.limit, 500_000e6);
        assertEq(d.available, 0);
        uint256 usedBefore = _marketView().used;
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DebtSpeedExceeded.selector,
                address(hub),
                address(usdc),
                uint256(0),
                uint64(block.timestamp + 2 * TAU)
            )
        );
        _borrowAsAdapter(USDC_RESERVE, 1e6);
        assertEq(_marketView().used, usedBefore, "a refused borrow charges neither window");
    }

    // TEST-321 verifies: REQ-RISK-092, SPEC-CAP-012, ATTACK-205
    function test_TEST_321_ownChargesNeverRaiseTheLimit() public {
        uint256 limitBefore = _marketView().limit;
        for (uint256 i = 0; i < 8; ++i) {
            _borrowAsAdapter(USDC_RESERVE, 50_000e6);
            // The Spoke's owed amount grows by each borrow, as Aave books it.
            hub.setOwed(USDC_ASSET, address(spoke), 2_400_000e6 + (i + 1) * 50_000e6, 0);
            vm.warp(block.timestamp + 60);
            assertEq(_marketView().limit, limitBefore, "L stays the L of the base before the window");
        }
        assertEq(_marketView().used, 400_000 * E8);
    }

    // TEST-321 verifies: REQ-RISK-092, ATTACK-205
    function test_TEST_321_splitAcrossAccountsSharesOneWindow() public {
        PositionProxy second = new PositionProxy(address(adapter), makeAddr("wallet2"), address(spoke), mid);
        rSpoke.setStatus(address(second), VT_RESERVE, true, false);
        rSpoke.setSupplied(address(second), VT_RESERVE, 1e21);
        _borrowAsAdapter(USDC_RESERVE, 400_000e6);
        // Aave books each draw on the Spoke, so the base before the window stays $3,400,000.
        hub.setOwed(USDC_ASSET, address(spoke), 2_800_000e6, 0);
        vm.prank(address(adapter));
        riskModule.preBorrowCheck(address(second), GHO_RESERVE, 400_000e18);
        hub.setOwed(GHO_ASSET, address(spoke), 1_400_000e18, 0);
        assertEq(_marketView().limit, 850_000 * E8, "the limit of the base before the window");
        assertEq(_marketView().used, 800_000 * E8, "both accounts and both reserves in one market window");
        vm.expectRevert();
        vm.prank(address(adapter));
        riskModule.preBorrowCheck(address(second), GHO_RESERVE, 50_001e18);
        vm.prank(address(adapter));
        riskModule.preBorrowCheck(address(second), GHO_RESERVE, 50_000e18);
        assertEq(_marketView().available, 0);
    }

    // TEST-321 verifies: REQ-RISK-092, SPEC-CAP-011
    function test_TEST_321_roomFreesAtBucketBoundaries() public {
        store.setDebtSpeed(address(hub), address(usdc), SpeedLimit(2500, uint32(TAU), 5_000_000e6, 5_000_000e6));
        uint256 t0 = block.timestamp;
        _borrowAsAdapter(USDC_RESERVE, 300_000e6);
        vm.warp(t0 + TAU - 1);
        _borrowAsAdapter(USDC_RESERVE, 300_000e6);
        vm.warp(t0 + TAU);
        SpeedView memory m = _marketView();
        assertEq(m.used, 600_000 * E8, "one rollover: both charges in prev");
        assertEq(m.moreAt, uint64(t0 + 2 * TAU));
        assertEq(m.moreAmount, 600_000 * E8);
        vm.warp(t0 + 2 * TAU - 1);
        assertEq(_marketView().used, 600_000 * E8);
        vm.warp(t0 + 2 * TAU);
        assertEq(_marketView().used, 0, "both freed two windows after the first bucket's start");
    }

    // TEST-321 verifies: REQ-RISK-096, REQ-RISK-098
    function test_TEST_321_unsetScopesFailClosed() public {
        store.setMarketSpeed(mid, MarketSpeedLimits(0, 0, 0, 0, 0, 0, 0));
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.BorrowSpeedExceeded.selector, mid, 0, uint64(0)));
        _borrowAsAdapter(USDC_RESERVE, 1);
        store.setMarketSpeed(mid, _launchMarket());
        store.setDebtSpeed(address(hub), address(usdc), SpeedLimit(0, 0, 0, 0));
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DebtSpeedExceeded.selector, address(hub), address(usdc), 0, uint64(0)
            )
        );
        _borrowAsAdapter(USDC_RESERVE, 1);
        // A scope with a window but a zero maximum (stopped by a tightening) refuses too.
        store.setDebtSpeed(address(hub), address(usdc), SpeedLimit(2500, uint32(TAU), 0, 0));
        vm.expectRevert();
        _borrowAsAdapter(USDC_RESERVE, 1);
    }

    // TEST-321 verifies: REQ-RISK-096
    function test_TEST_321_tighteningRefusesUntilRolloverAndLooseningAdmitsAtOnce() public {
        uint256 t0 = block.timestamp;
        _borrowAsAdapter(USDC_RESERVE, 400_000e6);
        MarketSpeedLimits memory tight = _launchMarket();
        (tight.borrowMinUsd, tight.borrowMaxUsd) = (0, 300_000 * 1e8);
        store.setMarketSpeed(mid, tight);
        assertEq(_marketView().available, 0, "used above the new L");
        vm.expectRevert();
        _borrowAsAdapter(USDC_RESERVE, 1);
        vm.warp(t0 + TAU);
        vm.expectRevert();
        _borrowAsAdapter(USDC_RESERVE, 1);
        vm.warp(t0 + 2 * TAU);
        _borrowAsAdapter(USDC_RESERVE, 1);
        // The large-borrow path: a loosening of L_max admits at once.
        MarketSpeedLimits memory loose = _launchMarket();
        loose.borrowRateBps = 10_000;
        (loose.borrowMinUsd, loose.borrowMaxUsd) = (10_000_000 * 1e8, 10_000_000 * 1e8);
        store.setMarketSpeed(mid, loose);
        store.setDebtSpeed(address(hub), address(usdc), SpeedLimit(10_000, uint32(TAU), 10_000_000e6, 10_000_000e6));
        _borrowAsAdapter(USDC_RESERVE, 5_000_000e6);
    }

    // TEST-321 verifies: REQ-RISK-096, ATTACK-204
    function test_TEST_321_gatesRunBeforeTheWindow() public {
        store.setMarketSpeed(mid, MarketSpeedLimits(0, 0, 0, 0, 0, 0, 0));
        swap.setKeepers(0);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.LiquidationHalted.selector, mid));
        _borrowAsAdapter(USDC_RESERVE, 1);
        swap.setKeepers(1);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.BorrowSpeedExceeded.selector, mid, 0, uint64(0)));
        _borrowAsAdapter(USDC_RESERVE, 1);
    }

    // TEST-321 verifies: REQ-RISK-094
    function test_TEST_321_withdrawWithDebtIgnoresFullWindows() public {
        store.setMarketSpeed(mid, MarketSpeedLimits(0, 0, 0, 0, 0, 0, 0));
        store.setDebtSpeed(address(hub), address(usdc), SpeedLimit(0, 0, 0, 0));
        vm.prank(address(adapter));
        riskModule.preWithdrawCheck(address(proxy));
    }

    // TEST-321 verifies: REQ-RISK-097
    function test_TEST_321_viewsNeverRevert() public view {
        (SpeedView memory m, SpeedView memory d) = riskModule.getBorrowSpeed(mid + 50, USDC_RESERVE);
        assertTrue(m.unavailable && d.unavailable, "unknown market");
        assertEq(m.limit + m.used + m.available + m.moreAmount + m.moreAt, 0);
        SpeedView memory p = riskModule.getPledgeSpeed(mid + 50);
        assertTrue(p.unavailable);
    }

    // TEST-321 verifies: REQ-RISK-092, SPEC-CAP-012
    function test_TEST_321_marketBaseSumsEverySpokeReserve() public {
        hub.setOwed(GHO_ASSET, address(spoke), 0, 0);
        assertEq(_marketView().limit, 600_000 * E8, "25 % of the USDC debt alone");
        hub.setOwed(USDC_ASSET, address(spoke), 0, 0);
        assertEq(_marketView().limit, 250_000 * E8, "no debt: L_min");
        hub.setOwed(GHO_ASSET, address(spoke), 20_000_000e18, 0);
        assertEq(_marketView().limit, 2_500_000 * E8, "large Spoke debt: L_max");
    }

    // TEST-321 verifies: REQ-RISK-092
    function test_TEST_321_debtBaseCountsOnlyListedRegistrySpokes() public {
        assertEq(_debtView().limit, 600_000e6);
        rHub.setSpokeListed(USDC_ASSET, address(spoke), false);
        assertEq(_debtView().limit, 500_000e6, "an unlisted Spoke owes nothing: min");
    }

    // ----------------------------------------------------------------------------------------- pledge window

    function _pledgeAsCollateralization(
        uint128 units,
        PledgeCounters memory k,
        bool rescue
    ) internal returns (PledgeCharge memory c) {
        vm.prank(address(coll));
        c = riskModule.checkPledge(wallet, address(proxy), mid, V3, bytes32(uint256(1)), units, k, rescue);
    }

    // TEST-322 verifies: REQ-RISK-093, REQ-RISK-095, REQ-RISK-097
    function test_TEST_322_collateralizationPledgeChargesThePledgeWindow() public {
        store.setMarket(mid, 4000, 10e8, 100_000_000e8, 100_000e8, 1e8);
        PledgeCounters memory k = _counters();
        k.regularUsed = 6_000_000e8;
        coll.setCounters(k);
        PledgeCharge memory c = _pledgeAsCollateralization(TEN_K, k, false);
        assertEq(c.usdCharge, 20_000e8);
        SpeedView memory p = riskModule.getPledgeSpeed(mid);
        assertEq(p.used, 20_000e8);
        // Base $6,000,000 less the $20,000 charged: L = $1,495,000.
        assertEq(p.limit, 1_495_000e8);
    }

    // TEST-322 verifies: REQ-RISK-006, REQ-RISK-095
    function test_TEST_322_otherCallersWriteNothingAndStaticcallWorks() public {
        PledgeCounters memory k = _counters();
        _pledge(TEN_K, k, false);
        (bool ok,) = address(riskModule)
            .staticcall(
                abi.encodeCall(
                    IRiskModuleChecks.checkPledge,
                    (wallet, address(proxy), mid, V3, bytes32(uint256(1)), TEN_K, k, false)
                )
            );
        assertTrue(ok, "a STATICCALL by anyone but Collateralization succeeds");
        assertEq(riskModule.getPledgeSpeed(mid).used, 0);
    }

    // TEST-322 verifies: REQ-RISK-093, REQ-RISK-099, SPEC-CAP-011
    function test_TEST_322_pledgeOverTheWindowReverts() public {
        PledgeCounters memory k = _counters();
        // Empty market: P = P_min $1,000,000. Fifty $20,000 pledges fill it exactly.
        uint256 t0 = block.timestamp;
        for (uint256 i = 0; i < 50; ++i) {
            _pledgeAsCollateralization(TEN_K, k, false);
        }
        assertEq(riskModule.getPledgeSpeed(mid).available, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.PledgeSpeedExceeded.selector, mid, 0, uint64(t0 + 2 * TAU))
        );
        _pledgeAsCollateralization(TEN_K, k, false);
        vm.warp(t0 + 2 * TAU);
        _pledgeAsCollateralization(TEN_K, k, false);
    }

    // TEST-322 verifies: REQ-RISK-093, REQ-RISK-094
    function test_TEST_322_rescueTopUpIsNeitherTestedNorCharged() public {
        store.setMarketSpeed(mid, MarketSpeedLimits(0, 0, 0, 0, 0, 0, 0));
        PledgeCounters memory k = _counters();
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PledgeSpeedExceeded.selector, mid, 0, uint64(0)));
        _pledgeAsCollateralization(TEN_K, k, false);
        // An indebted account below 1.10 under requireRescue enters as a rescue top-up past a closed window.
        _debt(1.04e18, 15_000);
        PledgeCharge memory c = _pledgeAsCollateralization(1000e18, k, true);
        assertTrue(c.rescue);
        assertEq(riskModule.getPledgeSpeed(mid).used, 0, "nothing charged");
    }

    // TEST-322 verifies: REQ-RISK-097
    function test_TEST_322_pledgeViewUsesTheBookedValue() public {
        store.setMarket(mid, 4000, 10e8, 100_000_000e8, 100_000e8, 1e8);
        PledgeCounters memory k = _counters();
        k.regularUsed = 5_000_000e8;
        k.sliceUsed = 1_000_000e8;
        coll.setCounters(k);
        SpeedView memory p = riskModule.getPledgeSpeed(mid);
        assertEq(p.limit, 1_500_000e8, "25 % of $6,000,000");
        assertEq(p.available, 1_500_000e8);
        assertFalse(p.unavailable);
    }
}
