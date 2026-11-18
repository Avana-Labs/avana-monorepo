// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketDynamicCap} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {DynamicCap} from "../../src/policy/risk-module/types/RiskModuleTypes.sol";
import {PositionProxy} from "../../src/proxy/position-proxy/PositionProxy.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @title RiskModuleDynamicCapUnitTest
/// @notice The per-market dynamic borrow cap of the Aave ARFC "Dynamic Caps Oracle: Rate Limiter" on the real
/// RiskModule and MarketRegistry: the first borrow of each interval fixes `C = D_start + L(D_start)` with
/// `L = clamp(alpha * D, L_min, L_max)`, a borrow reverts when the market's debt after it exceeds `C`, repays and
/// withdrawals are never limited, who stores, fail-closed terms, gate precedence and the view.
/// @dev World: the RiskModule fixture with USDC enabled as debt reserve 5 and the account in debt (HF 1.5). The CDP
/// Spoke owes 1,000,000 GHO and 2,400,000 USDC, both at $1.00 unless a test sets another price, so the market's debt
/// is $3,400,000. Terms: tau = 21,600 s, alpha 2,500 bps, L_min $250,000, L_max $2,500,000; the first borrow of an
/// interval therefore fixes C = $3,400,000 + $850,000 = $4,250,000.
contract RiskModuleDynamicCapUnitTest is RiskModuleFixture {
    uint256 internal constant TAU = 21_600;
    uint256 internal constant E8 = 1e8;
    uint256 internal constant CAP = 4_250_000 * E8;

    function setUp() public {
        _deployRiskWorld();
        _enableUsdcDebt();
        _debt(1.5e18, 1000);
        hub.setOwed(GHO_ASSET, address(spoke), 1_000_000e18, 0);
        hub.setOwed(USDC_ASSET, address(spoke), 2_400_000e6, 0);
        aaveOracle.setPrice(USDC_RESERVE, 1e8);
        store.setMarketDynamicCap(mid, _terms());
    }

    function _terms() internal pure returns (MarketDynamicCap memory) {
        return MarketDynamicCap(uint32(TAU), 2500, 250_000 * 1e8, 2_500_000 * 1e8);
    }

    function _borrowAsAdapter(
        uint256 r,
        uint256 amount
    ) internal {
        vm.prank(address(adapter));
        riskModule.preBorrowCheck(address(proxy), r, amount);
    }

    function _capView() internal view returns (uint256 cap, uint256 debt, uint64 start) {
        return riskModule.getDynamicBorrowCap(mid);
    }

    /// @dev Aave books a draw on the Spoke: GHO owed rises by `gho` whole tokens.
    function _book(
        uint256 gho
    ) internal {
        hub.setOwed(GHO_ASSET, address(spoke), 1_000_000e18 + gho * 1e18, 0);
    }

    // ------------------------------------------------------------------------------------------ the cap of an interval

    function test_firstBorrowFixesTheCapOnTheCurrentDebt() public {
        (uint256 cap, uint256 debt, uint64 start) = _capView();
        assertEq(debt, 3_400_000 * E8, "the Spoke's debt over every debt reserve");
        assertEq(cap, CAP, "D + 25 % of D");
        assertEq(start, uint64(block.timestamp), "the next borrow opens an interval now");
        assertEq(uint256(riskModule.getDynamicCap(mid).intervalStart), 0, "nothing stored before a borrow");
        _borrowAsAdapter(USDC_RESERVE, 600_000e6);
        DynamicCap memory d = riskModule.getDynamicCap(mid);
        assertEq(d.intervalStart, uint64(block.timestamp));
        assertEq(d.cap, CAP);
        (cap,, start) = _capView();
        assertEq(cap, CAP, "the view reports the running interval's cap");
        assertEq(start, uint64(block.timestamp));
    }

    function test_otherCallersNeverStore() public {
        riskModule.preBorrowCheck(address(proxy), USDC_RESERVE, 600_000e6);
        vm.prank(wallet);
        riskModule.preBorrowCheck(address(proxy), USDC_RESERVE, 600_000e6);
        vm.prank(address(coll));
        riskModule.preBorrowCheck(address(proxy), USDC_RESERVE, 600_000e6);
        DynamicCap memory d = riskModule.getDynamicCap(mid);
        assertEq(uint256(d.intervalStart) + d.cap, 0, "no interval stored without the Adapter");
    }

    function test_borrowExactlyToTheCapPassesAndOneMoreReverts() public {
        // 1 wei of GHO is one 8-decimal unit, rounded up: the debt after the borrow is the cap plus one.
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.DynamicBorrowCapExceeded.selector, mid, CAP, CAP + 1));
        _borrowAsAdapter(GHO_RESERVE, 850_000e18 + 1);
        assertEq(uint256(riskModule.getDynamicCap(mid).intervalStart), 0, "a refused borrow opens no interval");
        _borrowAsAdapter(GHO_RESERVE, 850_000e18);
        DynamicCap memory d = riskModule.getDynamicCap(mid);
        assertEq(d.cap, CAP);
        // USDC has 6 decimals: one base unit is $0.000001 = 100 units; the debt after the borrow is the cap plus 100.
        _book(850_000);
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.DynamicBorrowCapExceeded.selector, mid, CAP, CAP + 100)
        );
        _borrowAsAdapter(USDC_RESERVE, 1);
        _borrowAsAdapter(USDC_RESERVE, 0);
    }

    function test_theCapStaysFixedWhileOwnBorrowsRaiseTheDebt() public {
        uint256 t0 = block.timestamp;
        _borrowAsAdapter(USDC_RESERVE, 400_000e6);
        // Aave books the draw: the debt is now $3,800,000, but the interval's cap stays $4,250,000.
        hub.setOwed(USDC_ASSET, address(spoke), 2_800_000e6, 0);
        vm.warp(t0 + 60);
        (uint256 cap, uint256 debt,) = _capView();
        assertEq(cap, CAP, "the cap does not follow the debt inside the interval");
        assertEq(debt, 3_800_000 * E8);
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.DynamicBorrowCapExceeded.selector, mid, CAP, CAP + 100)
        );
        _borrowAsAdapter(USDC_RESERVE, 450_000e6 + 1);
        _borrowAsAdapter(USDC_RESERVE, 450_000e6);
    }

    function test_splitAcrossAccountsSharesOneCap() public {
        PositionProxy second = new PositionProxy(address(adapter), makeAddr("wallet2"), address(spoke), mid);
        rSpoke.setStatus(address(second), VT_RESERVE, true, false);
        rSpoke.setSupplied(address(second), VT_RESERVE, 1e21);
        _borrowAsAdapter(USDC_RESERVE, 400_000e6);
        hub.setOwed(USDC_ASSET, address(spoke), 2_800_000e6, 0);
        vm.prank(address(adapter));
        riskModule.preBorrowCheck(address(second), GHO_RESERVE, 400_000e18);
        hub.setOwed(GHO_ASSET, address(spoke), 1_400_000e18, 0);
        (, uint256 debt,) = _capView();
        assertEq(debt, 4_200_000 * E8, "both accounts and both reserves in one market debt");
        vm.expectRevert();
        vm.prank(address(adapter));
        riskModule.preBorrowCheck(address(second), GHO_RESERVE, 50_001e18);
        vm.prank(address(adapter));
        riskModule.preBorrowCheck(address(second), GHO_RESERVE, 50_000e18);
    }

    function test_usdAmountIsRoundedUpAtTheReservePrice() public {
        // USDC at $0.9999: D = 1,000,000 + 2,400,000 x 0.9999 = $3,399,760, so C = D + $849,940.
        aaveOracle.setPrice(USDC_RESERVE, 99_990_000);
        uint256 cap = 424_970_000_000_000;
        // 850,025 USDC is $849,939.9975: it fits. 850,026 USDC is $849,940.9974: one too many.
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DynamicBorrowCapExceeded.selector, mid, cap, 339_976_000_000_000 + 84_994_099_740_000
            )
        );
        _borrowAsAdapter(USDC_RESERVE, 850_026e6);
        _borrowAsAdapter(USDC_RESERVE, 850_025e6);
        assertEq(riskModule.getDynamicCap(mid).cap, cap);
    }

    // ------------------------------------------------------------------------------------------ a new interval

    function test_newIntervalFixesTheCapOnTheCurrentDebt() public {
        uint256 t0 = block.timestamp;
        _borrowAsAdapter(USDC_RESERVE, 850_000e6);
        hub.setOwed(USDC_ASSET, address(spoke), 3_250_000e6, 0);
        // One second before tau the interval still runs on its cap.
        vm.warp(t0 + TAU - 1);
        (uint256 cap,, uint64 start) = _capView();
        assertEq(cap, CAP);
        assertEq(start, uint64(t0));
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.DynamicBorrowCapExceeded.selector, mid, CAP, CAP + 100)
        );
        _borrowAsAdapter(USDC_RESERVE, 1);
        // At tau exactly the next borrow opens an interval on D = $4,250,000: L = $1,062,500, C = $5,312,500.
        vm.warp(t0 + TAU);
        (cap,, start) = _capView();
        assertEq(cap, 5_312_500 * E8, "reset from the current debt");
        assertEq(start, uint64(t0 + TAU));
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DynamicBorrowCapExceeded.selector, mid, 5_312_500 * E8, 5_312_500 * E8 + 100
            )
        );
        _borrowAsAdapter(USDC_RESERVE, 1_062_500e6 + 1);
        _borrowAsAdapter(USDC_RESERVE, 1_062_500e6);
        DynamicCap memory d = riskModule.getDynamicCap(mid);
        assertEq(d.intervalStart, uint64(t0 + TAU));
        assertEq(d.cap, 5_312_500 * E8);
    }

    function test_newIntervalAfterRepaysFixesALowerCap() public {
        uint256 t0 = block.timestamp;
        _borrowAsAdapter(USDC_RESERVE, 100_000e6);
        // Repays brought the debt to $1,000,000 (GHO only).
        hub.setOwed(USDC_ASSET, address(spoke), 0, 0);
        vm.warp(t0 + TAU);
        (uint256 cap, uint256 debt,) = _capView();
        assertEq(debt, 1_000_000 * E8);
        assertEq(cap, 1_250_000 * E8, "D + L_min: 25 % of $1,000,000 is exactly L_min");
        _borrowAsAdapter(GHO_RESERVE, 250_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DynamicBorrowCapExceeded.selector, mid, 1_250_000 * E8, 1_250_000 * E8 + 1
            )
        );
        _borrowAsAdapter(GHO_RESERVE, 250_000e18 + 1);
    }

    function test_theIntervalMovesAtTheFirstBorrowAfterTauNotOnATimer() public {
        uint256 t0 = block.timestamp;
        _borrowAsAdapter(USDC_RESERVE, 100_000e6);
        vm.warp(t0 + 5 * TAU + 7);
        _report(uint64(block.timestamp), 1e8, 1e8);
        _borrowAsAdapter(GHO_RESERVE, 100_000e18);
        assertEq(riskModule.getDynamicCap(mid).intervalStart, uint64(t0 + 5 * TAU + 7), "from the borrow, not a grid");
    }

    // ------------------------------------------------------------------------------------------ the buffer's clamps

    function test_bufferClampsAtLMin() public {
        // Debt $100,000: 25 % is $25,000, below L_min $250,000.
        hub.setOwed(GHO_ASSET, address(spoke), 0, 0);
        hub.setOwed(USDC_ASSET, address(spoke), 100_000e6, 0);
        (uint256 cap,,) = _capView();
        assertEq(cap, 350_000 * E8, "D + L_min");
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DynamicBorrowCapExceeded.selector, mid, 350_000 * E8, 350_000 * E8 + 100
            )
        );
        _borrowAsAdapter(USDC_RESERVE, 250_000e6 + 1);
        _borrowAsAdapter(USDC_RESERVE, 250_000e6);
    }

    function test_bufferClampsAtLMax() public {
        // Debt $20,000,000: 25 % is $5,000,000, above L_max $2,500,000.
        hub.setOwed(GHO_ASSET, address(spoke), 20_000_000e18, 0);
        hub.setOwed(USDC_ASSET, address(spoke), 0, 0);
        (uint256 cap,,) = _capView();
        assertEq(cap, 22_500_000 * E8, "D + L_max");
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DynamicBorrowCapExceeded.selector, mid, 22_500_000 * E8, 22_500_000 * E8 + 1
            )
        );
        _borrowAsAdapter(GHO_RESERVE, 2_500_000e18 + 1);
        _borrowAsAdapter(GHO_RESERVE, 2_500_000e18);
    }

    function test_bufferIsAlphaOfDebtBetweenTheClamps() public {
        hub.setOwed(GHO_ASSET, address(spoke), 0, 0);
        assertEq(_cap(), 3_000_000 * E8, "25 % of the USDC debt alone: $2,400,000 + $600,000");
        hub.setOwed(GHO_ASSET, address(spoke), 4_000_000e18, 0);
        hub.setOwed(USDC_ASSET, address(spoke), 0, 0);
        assertEq(_cap(), 5_000_000 * E8, "$4,000,000 + $1,000,000");
    }

    function _cap() internal view returns (uint256 cap) {
        (cap,,) = _capView();
    }

    // ------------------------------------------------------------------------------------------ repays and exits

    function test_repaysAreNeverLimitedAndGiveRoomBackInsideTheInterval() public {
        _borrowAsAdapter(GHO_RESERVE, 850_000e18);
        _book(850_000);
        vm.expectRevert();
        _borrowAsAdapter(GHO_RESERVE, 1e18);
        // A repay is Aave's alone: it calls no RiskModule check, and the debt it removes is room under the same cap.
        _book(350_000);
        _borrowAsAdapter(GHO_RESERVE, 500_000e18);
        assertEq(riskModule.getDynamicCap(mid).cap, CAP, "a repay does not change the interval's cap");
    }

    function test_withdrawWithDebtIgnoresTheCap() public {
        store.setMarketDynamicCap(mid, MarketDynamicCap(0, 0, 0, 0));
        vm.prank(address(adapter));
        riskModule.preWithdrawCheck(address(proxy));
        store.setMarketDynamicCap(mid, _terms());
        _borrowAsAdapter(GHO_RESERVE, 850_000e18);
        _book(2_000_000);
        vm.prank(address(adapter));
        riskModule.preWithdrawCheck(address(proxy));
    }

    // ------------------------------------------------------------------------------------------ terms and gates

    function test_unsetTermsFailClosed() public {
        store.setMarketDynamicCap(mid, MarketDynamicCap(0, 0, 0, 0));
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DynamicBorrowCapExceeded.selector, mid, 3_400_000 * E8, 3_400_000 * E8 + 1
            )
        );
        _borrowAsAdapter(GHO_RESERVE, 1);
        // A stopped market (a zero buffer maximum) refuses the same way.
        store.setMarketDynamicCap(mid, MarketDynamicCap(uint32(TAU), 2500, 0, 0));
        vm.expectRevert();
        _borrowAsAdapter(GHO_RESERVE, 1e10);
    }

    function test_gatesRunBeforeTheCap() public {
        store.setMarketDynamicCap(mid, MarketDynamicCap(0, 0, 0, 0));
        swap.setKeepers(0);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.LiquidationHalted.selector, mid));
        _borrowAsAdapter(GHO_RESERVE, 1e18);
        swap.setKeepers(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DynamicBorrowCapExceeded.selector, mid, 3_400_000 * E8, 3_400_000 * E8 + 1e8
            )
        );
        _borrowAsAdapter(GHO_RESERVE, 1e18);
    }

    function test_termsChangeTakesEffectAtTheNextInterval() public {
        uint256 t0 = block.timestamp;
        _borrowAsAdapter(USDC_RESERVE, 100_000e6);
        // Tightened mid-interval: the running interval keeps its cap.
        store.setMarketDynamicCap(mid, MarketDynamicCap(uint32(TAU), 0, 0, 0));
        _borrowAsAdapter(USDC_RESERVE, 100_000e6);
        assertEq(riskModule.getDynamicCap(mid).cap, CAP);
        vm.warp(t0 + TAU);
        (uint256 cap,,) = _capView();
        assertEq(cap, 3_400_000 * E8, "the next interval has no buffer");
        vm.expectRevert();
        _borrowAsAdapter(USDC_RESERVE, 1);
        // Loosened: the next interval fixes its cap on the new terms.
        store.setMarketDynamicCap(mid, MarketDynamicCap(uint32(TAU), 10_000, 5_000_000 * 1e8, 5_000_000 * 1e8));
        _borrowAsAdapter(USDC_RESERVE, 4_000_000e6);
    }

    function test_interestAboveTheCapRefusesBorrowsUntilTheNextInterval() public {
        uint256 t0 = block.timestamp;
        _borrowAsAdapter(USDC_RESERVE, 850_000e6);
        // Interest took the Spoke's debt above the interval's cap.
        hub.setOwed(USDC_ASSET, address(spoke), 3_400_000e6, 0);
        vm.expectRevert();
        _borrowAsAdapter(USDC_RESERVE, 1);
        vm.warp(t0 + TAU);
        _borrowAsAdapter(USDC_RESERVE, 1);
    }

    // ------------------------------------------------------------------------------------------ the view

    function test_viewOfAnInactiveMarketReverts() public {
        vm.expectRevert();
        riskModule.getDynamicBorrowCap(mid + 50);
    }

    function test_marketDebtSumsEverySpokeReserve() public {
        hub.setOwed(GHO_ASSET, address(spoke), 0, 0);
        (, uint256 debt,) = _capView();
        assertEq(debt, 2_400_000 * E8, "USDC alone");
        hub.setOwed(USDC_ASSET, address(spoke), 0, 0);
        (, debt,) = _capView();
        assertEq(debt, 0, "no debt");
        hub.setOwed(GHO_ASSET, address(spoke), 20_000_000e18, 0);
        (, debt,) = _capView();
        assertEq(debt, 20_000_000 * E8);
    }
}
