// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {MarketDynamicCap} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {DynamicCap} from "../../src/policy/risk-module/types/RiskModuleTypes.sol";
import {PriceState} from "../../src/types/OracleTypes.sol";
import {AaveAdapterRiskFixture} from "../utils/fixtures/AaveAdapterRiskFixture.sol";

/// @title AaveAdapterDynamicCapIntegrationTest
/// @notice The dynamic borrow cap through the real AaveAdapter on the real local Aave V4 Hub, CDP Spoke and AaveOracle:
/// the market's debt is the Spoke's real debt, a borrow stores the interval and fixes its cap, a borrow over the cap
/// reverts and passes once a new interval opens, a repay gives room back inside the interval, and repay, withdrawal
/// with and without debt and `repayAllAndWithdraw` pass while the cap refuses every borrow.
/// @dev The account holds two records ($30,000 at CF 80 %) and owes 1,000 GHO; each test sets its terms after waiting
/// out the interval the setup's borrow opened under the store's open defaults.
/// forge-config: default.isolate = false
contract AaveAdapterDynamicCapIntegrationTest is AaveAdapterRiskFixture {
    uint32 internal constant TAU = 3600;

    bytes32 internal k1;
    bytes32 internal k2;
    address internal p;

    function setUp() public override {
        super.setUp();
        (k1, p) = _pledgeAs(alice, MARKET_ID, UNITS);
        (k2,) = _pledgeAs(alice, MARKET_ID, UNITS / 2);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1000e18);
        // Past the interval the setup charged under the store's open defaults.
        vm.warp(block.timestamp + 30 days);
        _report(lpOracleA, uint64(block.timestamp));
        _report(lpOracleB, uint64(block.timestamp));
    }

    /// @dev A fixed buffer: alpha 0 with `L_min = L_max = bufferUsd` (whole dollars).
    function _buffer(
        uint96 bufferUsd
    ) internal {
        rstore.setMarketDynamicCap(MARKET_ID, MarketDynamicCap(TAU, 0, bufferUsd * 1e8, bufferUsd * 1e8));
    }

    function _borrowExpectCap(
        uint256 reserveId,
        uint256 amount
    ) internal {
        uint256 nonce = adapterC.borrowNonce(p);
        uint256 d = _deadline();
        vm.expectPartialRevert(IRiskModuleErrors.DynamicBorrowCapExceeded.selector);
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, reserveId, amount, alice, d, 0, nonce);
    }

    function test_marketDebtIsTheSpokesRealDebt() public {
        rstore.setMarketDynamicCap(MARKET_ID, MarketDynamicCap(TAU, 10_000, 0, type(uint96).max));
        (uint256 cap, uint256 debt,) = rm.getDynamicBorrowCap(MARKET_ID);
        uint256 owed = IAaveV4Hub(aave.hub).getSpokeTotalOwed(ghoAssetId, aave.cdpSpoke);
        assertGt(owed, 1000e18, "1,000 GHO plus a month of interest");
        assertGt(debt, 1000e8, "the debt in 8-decimal USD");
        assertApproxEqAbs(debt, owed / 1e10, 1e8, "owed GHO at about $1.00");
        assertEq(cap, 2 * debt, "alpha 100 %: D + D");
    }

    function test_borrowStoresTheIntervalAndRefusesAboveItsCapWithFigures() public {
        _buffer(2000);
        uint256 t0 = block.timestamp;
        (uint256 cap0, uint256 debt0,) = rm.getDynamicBorrowCap(MARKET_ID);
        assertEq(cap0, debt0 + 2000e8, "D + L");
        _borrowAs(alice, MARKET_ID, debtReserveId, 1500e18);
        DynamicCap memory d = rm.getDynamicCap(MARKET_ID);
        assertEq(d.intervalStart, uint64(t0));
        assertEq(d.cap, cap0, "the cap is fixed on the debt before the first borrow");
        (uint256 cap1, uint256 debt1,) = rm.getDynamicBorrowCap(MARKET_ID);
        assertEq(cap1, cap0, "the running interval's cap");
        assertApproxEqAbs(debt1, debt0 + 1500e8, 1, "Aave booked the draw");
        // 500 left under the cap: 600 does not fit.
        _borrowExpectCap(debtReserveId, 600e18);
        _borrowAs(alice, MARKET_ID, debtReserveId, 490e18);
        vm.warp(t0 + TAU);
        _report(lpOracleA, uint64(block.timestamp));
        _borrowAs(alice, MARKET_ID, debtReserveId, 600e18);
        assertEq(rm.getDynamicCap(MARKET_ID).intervalStart, uint64(t0 + TAU), "a new interval");
    }

    function test_repayGivesRoomBackInsideTheInterval() public {
        _buffer(2000);
        _borrowAs(alice, MARKET_ID, debtReserveId, 2000e18);
        _borrowExpectCap(debtReserveId, 100e18);
        _fund(alice, debtReserveId, 1000e18);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, 1000e18, false, _deadline());
        _borrowAs(alice, MARKET_ID, debtReserveId, 900e18);
    }

    function test_exitsPassWhileTheCapRefusesEveryBorrow() public {
        rstore.setMarketDynamicCap(MARKET_ID, MarketDynamicCap(0, 0, 0, 0));
        _borrowExpectCap(debtReserveId, 1e18);
        // Withdrawal of the second record with debt left (HF stays above 1).
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k2), UNITS / 2, _deadline(), 1.1e18);
        assertEq(lpVault.ownerOf(k2), alice, "withdrawn with debt");
        // Repay all, then the debt-free withdrawal of the last record.
        uint256 owed = _debtOf(p, debtReserveId);
        _fund(alice, debtReserveId, owed);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, owed, false, _deadline());
        assertEq(_borrowCountOf(p), 0, "debt-free");
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k1), UNITS, _deadline(), 0);
        assertEq(lpVault.ownerOf(k1), alice, "k1 back");
    }

    function test_usdcBorrowCountsUsdAtTheReservePrice() public {
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp), true);
        _buffer(5000);
        (uint256 cap0, uint256 debt0,) = rm.getDynamicBorrowCap(MARKET_ID);
        _borrowAs(alice, MARKET_ID, usdcReserveId, 2000e6);
        (uint256 cap1, uint256 debt1,) = rm.getDynamicBorrowCap(MARKET_ID);
        assertEq(cap1, cap0, "the cap is fixed for the interval");
        assertApproxEqAbs(debt1, debt0 + 2000e8, 1e5, "6-decimal USDC at about $1.00 in 8-decimal USD");
    }

    function test_interestRaisesTheDebtTheNextIntervalCounts() public {
        rstore.setMarketDynamicCap(MARKET_ID, MarketDynamicCap(TAU, 10_000, 0, type(uint96).max));
        (, uint256 before,) = rm.getDynamicBorrowCap(MARKET_ID);
        vm.warp(block.timestamp + 365 days);
        (uint256 cap, uint256 later,) = rm.getDynamicBorrowCap(MARKET_ID);
        assertGt(later, before, "accrued interest is debt");
        assertEq(cap, 2 * later);
    }

    function test_twoWalletsShareTheMarketCap() public {
        _buffer(2000);
        _pledgeAs(bob, MARKET_ID, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1200e18);
        address pb = adapterC.proxyOf(bob, MARKET_ID);
        uint256 nonce = adapterC.borrowNonce(pb);
        uint256 dl = _deadline();
        vm.expectPartialRevert(IRiskModuleErrors.DynamicBorrowCapExceeded.selector);
        vm.prank(bob);
        adapterC.borrow(MARKET_ID, debtReserveId, 900e18, bob, dl, 0, nonce);
        _borrowAs(bob, MARKET_ID, debtReserveId, 790e18);
    }
}
