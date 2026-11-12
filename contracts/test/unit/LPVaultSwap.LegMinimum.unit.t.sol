// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {RouteMode} from "../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {SettlementReport} from "../../src/types/SettlementReport.sol";
import {LVSLyingRoute, LVSRevertingRoute} from "../utils/mocks/LPVaultSwapMocks.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title LPVaultSwapLegMinimumUnitTest
/// @notice The swap legs (2.11 REQ-SWAP-022, REQ-SWAP-023, REQ-SWAP-100, SPEC-LIQ-018, REQ-SWAP-058, REQ-SWAP-059):
/// each released token other than the debt asset is swapped over the market's usable primary route, inside try/catch,
/// then the usable backup with the same oracle-derived minimum `minOutᵢ ≥ 1`; a primary that reverts emits
/// `RouteFailed`; each route is approved for exactly its input and reset to 0 after the call whether it succeeded or
/// not; `NoRouteAvailable` when no usable route swaps a token; a faulty route that ignores its minimum is still held
/// to the aggregate recovery floor.
/// forge-config: default.isolate = false
contract LPVaultSwapLegMinimumUnitTest is LPVaultSwapUnitBase {
    address internal proxy;
    uint256 internal a1;

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
        (, a1) = _released(975e6);
    }

    /// @notice The USDT leg's route gets `swap(a₁, minOut₁)` with `minOut₁` the SPEC-LIQ-018 value at `sLeg = s = 100`
    /// bps and `n' = 1` (USDC is the debt asset and is not swapped).
    // TEST-232 verifies: SPEC-LIQ-018, REQ-SWAP-100, INV-083, PROP-068, Q-250
    function test_TEST_232_everyRouteCallHasMinOut() public {
        uint256 minOut = _usdtLegMinOut(a1, 100, 1);
        assertGt(minOut, 0, "minOut >= 1");
        vm.expectCall(address(usdtPrimary), abi.encodeCall(ISettlementRoute.swap, (a1, minOut)), 1);
        vm.expectCall(address(usdtBackup), abi.encodeWithSelector(ISettlementRoute.swap.selector), 0);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertGe(r.recovered - 1_030_199_625, minOut, "leg output at least its minimum");
    }

    /// @notice A primary returning one unit below the minimum reverts `MinOutNotMet`: LPVaultSwap emits `RouteFailed`
    /// with that selector, resets the allowance and calls the backup with the same minimum; at exactly the minimum the
    /// primary settles.
    // TEST-232 verifies: SPEC-LIQ-018, REQ-SWAP-022, REQ-SWAP-023, REQ-SWAP-058, REQ-SWAP-100, REQ-SWAP-110, INV-083
    function test_TEST_232_primaryBelowMinimumFallsBack() public {
        uint256 minOut = _usdtLegMinOut(a1, 100, 1);
        usdtUsdcPool.setRate(minOut - 1, a1);
        _fund(usdc, keeper, 1950e6);
        vm.expectEmit(true, true, false, true, address(lvs));
        emit RouteFailed(MARKET_ID, address(usdt), address(usdtPrimary), ISettlementRoute.MinOutNotMet.selector);
        vm.expectCall(address(usdtBackup), abi.encodeCall(ISettlementRoute.swap, (a1, minOut)), 1);
        vm.recordLogs();
        vm.prank(keeper);
        lvs.liquidate(_params(proxy, 1950e6));
        (SettlementReport memory rep,) = _settledReport(vm.getRecordedLogs());
        assertEq(rep.routeUsed[1], 2, "backup used");
        _assertNoAllowances();
        usdtUsdcPool.setRate(minOut, a1);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertEq(r.recovered, 1_030_199_625 + minOut, "primary at exactly its minimum");
    }

    /// @notice An unusable primary is skipped without `RouteFailed`; an unusable backup with a failing primary, or both
    /// unusable, revert `NoRouteAvailable`; `BackupOnly` with an unusable backup reverts even when the primary works.
    // TEST-232 verifies: REQ-SWAP-022, REQ-SWAP-059, SPEC-LIQ-013
    // TEST-053 verifies: REQ-SWAP-059, SPEC-LIQ-013, Q-401
    // TEST-053 verifies: REQ-ROUTE-022, REQ-ROUTE-027
    function test_TEST_053_bothRoutesFailRevertsNoRouteAvailable() public {
        registry.setRoute(MARKET_ID, address(usdt), address(usdc), 0, address(usdtPrimary), false);
        uint256 primarySwaps = usdtUsdcPool.swaps();
        _fund(usdc, keeper, 1950e6);
        vm.recordLogs();
        vm.prank(keeper);
        lvs.liquidate(_params(proxy, 1950e6));
        assertEq(_count(vm.getRecordedLogs(), RouteFailed.selector), 0, "no RouteFailed for an unusable primary");
        assertEq(usdtUsdcPool.swaps(), primarySwaps, "primary not called");
        registry.setRoute(MARKET_ID, address(usdt), address(usdc), 1, address(usdtBackup), false);
        bytes memory noRoute = _err(ILPVaultSwapErrors.NoRouteAvailable.selector);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), noRoute);
        registry.setRoute(MARKET_ID, address(usdt), address(usdc), 0, address(usdtPrimary), true);
        usdtUsdcPool.setRate(1, 2);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), noRoute);
        usdtUsdcPool.setRate(9995, 10_000);
        LiquidationParams memory p = _params(proxy, 1950e6);
        p.routeMode = RouteMode.BackupOnly;
        _expectLiquidateRevert(keeper, p, noRoute);
        // An unknown slot (no route recorded) is unusable too.
        registry.setRoute(MARKET_ID, address(usdt), address(usdc), 0, address(0), true);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), noRoute);
    }

    /// @notice A route that reverts with its own error emits `RouteFailed` with that error's selector; a route whose
    /// `intermediates()` read reverts counts as failed and emits `RouteFailed` with `Error(string)`.
    // TEST-232 verifies: REQ-SWAP-022, REQ-SWAP-058, REQ-SWAP-024
    function test_TEST_232_routeFailureSelectors() public {
        LVSRevertingRoute down = new LVSRevertingRoute();
        registry.setRoute(MARKET_ID, address(usdt), address(usdc), 0, address(down), true);
        _fund(usdc, keeper, 2 * 1950e6);
        vm.expectEmit(true, true, false, true, address(lvs));
        emit RouteFailed(MARKET_ID, address(usdt), address(down), LVSRevertingRoute.RouteDown.selector);
        vm.prank(keeper);
        lvs.liquidate(_params(proxy, 1950e6));
        down.setIntermediatesRevert(true);
        vm.expectEmit(true, true, false, true, address(lvs));
        emit RouteFailed(MARKET_ID, address(usdt), address(down), bytes4(keccak256("Error(string)")));
        vm.prank(keeper);
        LiquidationResult memory r = lvs.liquidate(_params(proxy, 1950e6));
        assertGt(r.recovered, 0, "backup settled");
        assertEq(usdt.allowance(address(lvs), address(down)), 0, "no allowance to the failed route");
    }

    /// @notice A faulty recorded route that ignores its minimum and returns 1 unit is still held to the aggregate
    /// recovery floor: `RecoveryBelowFloor`, nothing settles (REQ-SWAP-025).
    // TEST-232 verifies: REQ-SWAP-025, SPEC-LIQ-005, INV-034
    // TEST-232 verifies: REQ-ROUTE-028
    function test_TEST_232_recoveryBelowFloorReverts() public {
        LVSLyingRoute liar = new LVSLyingRoute(address(usdt), address(usdc));
        usdc.mint(address(liar), 1);
        liar.setOut(1);
        registry.setRoute(MARKET_ID, address(usdt), address(usdc), 0, address(liar), true);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _err(ILPVaultSwapErrors.RecoveryBelowFloor.selector));
    }

    /// @notice A sandwich of every route up to the slippage the leg minimum allows settles; one unit more and both
    /// routes fail, so a searcher can take at most `sLeg` of each leg (TEST-227 shape on local pools).
    // TEST-227 verifies: SPEC-LIQ-018, REQ-SWAP-100, INV-083, Q-250
    // TEST-227 verifies: REQ-ROUTE-023
    function test_TEST_227_sandwichBoundedByLegMinimum() public {
        uint256 minOut = _usdtLegMinOut(a1, 100, 1);
        usdtUsdcPool.setRate(minOut - 1, a1);
        usdtUsdcPool2.setRate(minOut - 1, a1);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _err(ILPVaultSwapErrors.NoRouteAvailable.selector));
        usdtUsdcPool2.setRate(minOut, a1);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        uint256 legValue = a1 * P_USDT / PRICE_UNIT;
        assertLe((legValue - minOut) * BPS, legValue * 100 + (1 + FLOOR_ROUNDING_ALLOWANCE_USDC) * BPS, "take <= sLeg");
        assertGe(r.recovered, r.minOut, "the floor still holds");
    }

    /// @notice With GHO debt both USDC and USDT are swapped (`n' = 2`): each leg's minimum subtracts its own unit value
    /// and `⌊ε / 2⌋`, in 18-decimal GHO units.
    // TEST-232 verifies: SPEC-LIQ-018, REQ-SWAP-100, INV-083
    function test_TEST_232_ghoDebtTwoLegsSplitAllowance() public {
        address ghoProxy = _ghoAccount(alice);
        (uint256 c, uint256 d) = (0, 0);
        uint256 snapshot = vm.snapshotState();
        LiquidationParams memory p = _params(ghoProxy, 1950e18);
        p.debtReserveId = ghoReserveId;
        LiquidationResult memory probe = _liquidateAs(keeper, p);
        (c, d) = (probe.unitsSeized, probe.debtRepaid);
        vm.revertToState(snapshot);
        (uint256 g0, uint256 g1) = _released(c);
        uint256 min0 = _ghoMinOut(g0 * 1e12, 1e12);
        uint256 min1 = _ghoMinOut(g1 * P_USDT * 1e12 / PRICE_UNIT, _ceilDiv(P_USDT * 1e12, PRICE_UNIT));
        vm.expectCall(address(usdcToGho), abi.encodeCall(ISettlementRoute.swap, (g0, min0)), 1);
        vm.expectCall(address(usdtToGho), abi.encodeCall(ISettlementRoute.swap, (g1, min1)), 1);
        LiquidationResult memory r = _liquidateAs(keeper, p);
        assertEq(r.debtRepaid, d, "same seizure");
        assertEq(r.recovered, (g0 + g1) * 1e12, "both legs at 1:1 into GHO");
    }

    function _ghoMinOut(
        uint256 vLeg,
        uint256 uLeg
    ) internal pure returns (uint256) {
        uint256 term = _ceilDiv(vLeg * (BPS - 100), BPS);
        uint256 cut = uLeg + FLOOR_ROUNDING_ALLOWANCE_GHO / 2;
        return term > cut ? term - cut : 1;
    }

    /// @notice An account with only GHO debt: 10,000 vault tokens at $2.50, 18,000 GHO borrowed, then $2.10.
    function _ghoAccount(
        address wallet
    ) internal returns (address ghoProxy) {
        (ghoProxy,) = _openAccount(wallet, 10_000e6, 0, 250_000_000);
        lpOracle.setAnswer(250_000_000);
        adapter.borrow(ghoProxy, ghoReserveId, address(gho), 18_000e18, wallet);
        lpOracle.setAnswer(int256(P_VAULT));
    }

    /// @notice Each route is approved for exactly its input during the call and reset to 0 after it (allowances read
    /// from inside the route call by a re-entering route).
    // TEST-232 verifies: REQ-SWAP-023, REQ-SWAP-042, INV-021
    // TEST-232 verifies: REQ-ROUTE-024
    function test_TEST_232_exactApprovalDuringCall() public {
        LVSLyingRoute probe = new LVSLyingRoute(address(usdt), address(usdc));
        usdc.mint(address(probe), 1100e6);
        probe.setOut(1_009_594_950);
        probe.setReenter(
            address(usdt), abi.encodeWithSignature("allowance(address,address)", address(lvs), address(probe))
        );
        registry.setRoute(MARKET_ID, address(usdt), address(usdc), 0, address(probe), true);
        _liquidateAs(keeper, _params(proxy, 1950e6));
        assertTrue(probe.lastReenterOk(), "read inside the call");
        assertEq(abi.decode(probe.lastReenterData(), (uint256)), a1, "allowance = exactly the leg input");
        assertEq(usdt.allowance(address(lvs), address(probe)), 0, "reset after the call");
    }

    /// @notice A leg with no released amount is not swapped and its route is not read.
    // TEST-232 verifies: REQ-SWAP-022, REQ-SWAP-077
    function test_TEST_232_zeroLegSkipped() public {
        uint256[] memory rates = new uint256[](2);
        rates[0] = 2_100_000; // the whole value in USDC
        rates[1] = 0;
        lpVault.bind(MARKET_ID, pool, _pair(address(usdc), address(usdt)), rates);
        vm.expectCall(address(registry), abi.encodeWithSignature("getRoute(uint256,address,address,uint8)"), 0);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertEq(r.amountsOut[1], 0, "no USDT released");
        assertEq(r.recovered, r.amountsOut[0], "R = the USDC leg");
    }
}
