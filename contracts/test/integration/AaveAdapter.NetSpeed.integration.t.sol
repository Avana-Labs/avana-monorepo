// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {IAaveAdapterUser} from "../../src/policy/aave-adapter/IAaveAdapterUser.sol";
import {MarketSpeedLimits} from "../../src/policy/parameter-store/types/MarketSpeedLimits.sol";
import {SpeedLimit} from "../../src/policy/parameter-store/types/SpeedLimit.sol";
import {IRiskModuleChecks} from "../../src/policy/risk-module/IRiskModuleChecks.sol";
import {SpeedView} from "../../src/policy/risk-module/types/SpeedView.sol";
import {AaveAdapterRiskFixture} from "../utils/fixtures/AaveAdapterRiskFixture.sol";

/// @title AaveAdapterNetSpeedIntegrationTest
/// @notice The net-flow borrow-speed windows through the real AaveAdapter, RiskModule and local Aave V4 (TEST-326): a
/// repay gives its amount back to both windows, borrow and repay cycles no longer fill a window (ATTACK-206), a failing
/// credit never stops a repay (REQ-RISK-005), and no gas limit lets a repay succeed without the credit.
/// @dev The account holds two records ($30,000 at CF 80 %) and owes 1,000 GHO; the windows are cleared by waiting two
/// windows. Limits: $2,000 market window, 5,000 GHO debt window, one hour.
/// forge-config: default.isolate = false
contract AaveAdapterNetSpeedIntegrationTest is AaveAdapterRiskFixture {
    uint32 internal constant TAU = 3600;

    address internal p;

    function setUp() public override {
        super.setUp();
        (, p) = _pledgeAs(alice, MARKET_ID, UNITS);
        _pledgeAs(alice, MARKET_ID, UNITS / 2);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1000e18);
        vm.warp(block.timestamp + 30 days);
        _report(lpOracleA, uint64(block.timestamp));
        _report(lpOracleB, uint64(block.timestamp));
        rstore.setMarketSpeed(MARKET_ID, MarketSpeedLimits(TAU, 0, 0, 2000e8, 2000e8, 0, 0));
        rstore.setDebtSpeed(aave.hub, address(debt), SpeedLimit(0, TAU, 5000e18, 5000e18));
    }

    function _repay(
        uint256 amount
    ) internal {
        _fund(alice, debtReserveId, amount);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, amount, false, _deadline());
    }

    function _views() internal view returns (SpeedView memory m, SpeedView memory d) {
        (m, d) = rm.getBorrowSpeed(MARKET_ID, debtReserveId);
    }

    // TEST-326 verifies: REQ-RISK-092, REQ-PROXY-027, SPEC-CAP-011
    function test_TEST_326_repayGivesRoomBack() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 1500e18);
        (SpeedView memory m, SpeedView memory d) = _views();
        assertEq(d.used, 1500e18);
        uint256 charged = m.used;
        _repay(1500e18);
        (m, d) = _views();
        assertEq(d.used, 0, "the debt window gives the repay back");
        // The borrow's charge rounds up and the repay's credit down: at most one unit stays.
        assertLe(m.used, 1, "the market window gives it back too");
        assertGt(charged, 1);
    }

    // TEST-326 verifies: REQ-RISK-092, ATTACK-206
    function test_TEST_326_borrowRepayCyclesNoLongerFillTheWindow() public {
        for (uint256 i = 0; i < 8; ++i) {
            _borrowAs(alice, MARKET_ID, debtReserveId, 1500e18);
            _repay(1500e18);
        }
        (SpeedView memory m, SpeedView memory d) = _views();
        assertEq(d.used, 0);
        assertLe(m.used, 8, "one unit of rounding per cycle at most");
        _borrowAs(alice, MARKET_ID, debtReserveId, 1900e18);
    }

    // TEST-326 verifies: REQ-RISK-005, REQ-RISK-092
    function test_TEST_326_aFailingCreditNeverStopsARepay() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 500e18);
        vm.mockCallRevert(address(rm), abi.encodeWithSelector(IRiskModuleChecks.creditRepay.selector), "boom");
        _repay(500e18);
        vm.clearMockedCalls();
        (, SpeedView memory d) = _views();
        assertEq(d.used, 500e18, "nothing credited, the repay went through");
    }

    // TEST-326 verifies: REQ-RISK-005, REQ-RISK-092
    /// @dev Over a range of gas limits a repay either reverts or has credited the window: a caller cannot pick a limit
    /// that skips the credit. The low end reverts `InsufficientGas` at the floor.
    function test_TEST_326_noGasLimitSkipsTheCredit() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 500e18);
        _fund(alice, debtReserveId, 500e18);
        uint256 deadline = _deadline();
        bool sawFloor = false;
        bool sawSuccess = false;
        for (uint256 g = 300_000; g <= 1_500_000; g += 10_000) {
            uint256 snap = vm.snapshotState();
            vm.prank(alice);
            (bool ok, bytes memory data) = address(adapterC).call{gas: g}(
                abi.encodeCall(IAaveAdapterUser.repay, (alice, MARKET_ID, debtReserveId, 500e18, false, deadline))
            );
            if (ok) {
                sawSuccess = true;
                (, SpeedView memory d) = _views();
                assertEq(d.used, 0, "a successful repay credited the window");
            } else if (data.length >= 4 && bytes4(data) == IAaveAdapterErrors.InsufficientGas.selector) {
                sawFloor = true;
            }
            vm.revertToState(snap);
        }
        assertTrue(sawFloor, "some limit stopped at the floor");
        assertTrue(sawSuccess, "some limit succeeded");
    }
}
