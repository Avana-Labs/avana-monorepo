// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";

/// @title LPVaultSwapShortfallUnitTest
/// @notice The caller's shortfall top-up (2.11 SPEC-LIQ-019, REQ-SWAP-025, REQ-SWAP-101): with `maxShortfall`, every
/// leg runs at `sLeg = min(9,999, s + min(maxShortfallBps, ⌊maxShortfall × 10⁴ / V⌋))`; after the swaps the floor is
/// tested on `R + shortfall`, exactly `max(0, minRec − R)` is pulled from `msg.sender`, `RecoveryBelowFloor` when the
/// floor gap exceeds `maxShortfall`; the top-up never counts as recovery, never raises `A` beyond the floor surplus
/// and never reaches the borrower.
/// forge-config: default.isolate = false
contract LPVaultSwapShortfallUnitTest is LPVaultSwapUnitBase {
    address internal proxy;

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
    }

    /// @dev The LPVault's unwind returns `usdcRate` raw USDC per 1e6 units instead of the fixture rate, so the
    /// released tokens are worth less than the seized oracle value.
    function _poorUnwind(
        uint256 usdcRate
    ) internal {
        uint256[] memory rates = new uint256[](2);
        rates[0] = usdcRate;
        rates[1] = USDT_RATE;
        lpVault.bind(MARKET_ID, pool, _pair(address(usdc), address(usdt)), rates);
    }

    /// @notice Routes in a crash: both USDT routes return 0.95; with `maxShortfall = 200` USDC the leg runs at
    /// `sLeg = 100 + 976 = 1,076` bps and passes; `R` is below `minRec`, so exactly the floor gap is pulled; the
    /// waterfall reads `R_f = minRec`, so `keeperOut = Kf + kr` and `B = 0`.
    // TEST-233 verifies: SPEC-LIQ-019, SPEC-LIQ-008, SPEC-LIQ-010, REQ-SWAP-025, REQ-SWAP-101, INV-034, Q-251
    function test_TEST_233_floorOnRPlusShortfall() public {
        usdtUsdcPool.setRate(95, 100);
        usdtUsdcPool2.setRate(95, 100);
        LiquidationParams memory p = _params(proxy, 1950e6);
        p.maxShortfall = 200e6;
        _fund(usdc, keeper, 1950e6 + 200e6);
        uint256 callerBefore = usdc.balanceOf(keeper);
        vm.prank(keeper);
        LiquidationResult memory r = lvs.liquidate(p);
        (uint256 a0, uint256 a1) = _released(975e6);
        assertEq(r.recovered, a0 + a1 * 95 / 100, "R measured over the routes only");
        assertLt(r.recovered, r.minOut, "R below the floor");
        assertEq(r.shortfall, r.minOut - r.recovered, "shortfall = minRec - R");
        Expect memory e = _expectUsdc(975e6, 1950e6, 1950e6, r.recovered, 10_500, P_VAULT, 200e6);
        _assertResult(r, e);
        assertEq(r.borrowerSurplus, 0, "the top-up never reaches the borrower");
        assertEq(r.keeperOut, r.callerFunds + r.keeperReward, "keeperOut = Kf + kr");
        assertEq(usdc.balanceOf(keeper), callerBefore - 1950e6 - r.shortfall + r.keeperOut, "pulled exactly");
    }

    /// @notice Without `maxShortfall` the same crash fails the leg minimum on both routes (`NoRouteAvailable`); with
    /// it but a floor gap above `maxShortfall`, `RecoveryBelowFloor`; at exactly the gap it settles.
    // TEST-233 verifies: SPEC-LIQ-019, REQ-SWAP-025, REQ-SWAP-060, REQ-SWAP-101
    function test_TEST_233_aboveMaxShortfallReverts() public {
        _poorUnwind(900_000); // 877.5 USDC instead of 1,030.2
        LiquidationParams memory p = _params(proxy, 1950e6);
        _expectLiquidateRevert(keeper, p, _err(ILPVaultSwapErrors.RecoveryBelowFloor.selector));
        p.maxShortfall = 100e6;
        _expectLiquidateRevert(keeper, p, _err(ILPVaultSwapErrors.RecoveryBelowFloor.selector));
        (, uint256 a1) = _released(975e6);
        uint256 r = 877_500_000 + a1 * 9995 / 10_000;
        Expect memory e = _expectUsdc(975e6, 1950e6, 1950e6, r, 10_500, P_VAULT, type(uint256).max);
        uint256 gap = e.minRec - r;
        p.maxShortfall = gap - 1;
        _expectLiquidateRevert(keeper, p, _err(ILPVaultSwapErrors.RecoveryBelowFloor.selector));
        p.maxShortfall = gap;
        LiquidationResult memory res = _liquidateAs(keeper, p);
        assertEq(res.shortfall, gap, "exactly the gap");
        assertEq(res.recovered + res.shortfall, res.minOut, "R' = minRec");
    }

    /// @notice The leg relaxation: `⌊maxShortfall × 10⁴ / V⌋` added to `s`, capped at `maxShortfallBps` (read per call)
    /// and at 9,999. The minimum each route receives is the SPEC-LIQ-018 value at that `sLeg`.
    // TEST-233 verifies: SPEC-LIQ-018, SPEC-LIQ-019, REQ-SWAP-046, REQ-SWAP-100
    // TEST-233 verifies: REQ-ROUTE-023
    function test_TEST_233_legRelaxationCapped() public {
        (, uint256 a1) = _released(975e6);
        LiquidationParams memory p = _params(proxy, 1950e6);
        p.maxShortfall = 200e6; // floor(200e6 x 1e4 / 2,047.5e6) = 976
        vm.expectCall(address(usdtPrimary), abi.encodeCall(ISettlementRoute.swap, (a1, _usdtLegMinOut(a1, 1076, 1))));
        uint256 snapshot = vm.snapshotState();
        _liquidateAs(keeper, p);
        vm.revertToState(snapshot);
        p.maxShortfall = 1_000_000e6; // above V: capped at maxShortfallBps = 1,000
        vm.expectCall(address(usdtPrimary), abi.encodeCall(ISettlementRoute.swap, (a1, _usdtLegMinOut(a1, 1100, 1))));
        _liquidateAs(keeper, p);
        vm.revertToState(snapshot);
        store.setMaxShortfallBps(300);
        vm.expectCall(address(usdtPrimary), abi.encodeCall(ISettlementRoute.swap, (a1, _usdtLegMinOut(a1, 400, 1))));
        _liquidateAs(keeper, p);
        vm.revertToState(snapshot);
        store.setMaxShortfallBps(0);
        vm.expectCall(address(usdtPrimary), abi.encodeCall(ISettlementRoute.swap, (a1, _usdtLegMinOut(a1, 100, 1))));
        _liquidateAs(keeper, p);
    }

    /// @notice `maxShortfall` only adds the caller's own funds: an unused budget is never pulled, the recovery, the
    /// floor, `A` and `B` are those of the call without it, and only the leg minimums move.
    // TEST-233 verifies: SPEC-LIQ-019, REQ-SWAP-046, REQ-SWAP-101
    function test_TEST_233_unusedBudgetNeverPulled() public {
        uint256 snapshot = vm.snapshotState();
        LiquidationResult memory plain = _liquidateAs(keeper, _params(proxy, 1950e6));
        vm.revertToState(snapshot);
        LiquidationParams memory p = _params(proxy, 1950e6);
        p.maxShortfall = 300e6;
        _fund(usdc, keeper, 1950e6 + 300e6);
        uint256 before = usdc.balanceOf(keeper);
        vm.prank(keeper);
        LiquidationResult memory r = lvs.liquidate(p);
        assertEq(r.shortfall, 0, "nothing pulled");
        assertEq(r.minOut, plain.minOut, "floor independent of maxShortfall");
        assertEq(r.avanaFee, plain.avanaFee, "A");
        assertEq(r.keeperOut, plain.keeperOut, "keeperOut");
        assertEq(usdc.balanceOf(keeper), before - 1950e6 + r.keeperOut, "only X pulled");
    }

    /// @notice The top-up is pulled from `msg.sender` only and fails in the token without allowance for it (the call
    /// reverts and nothing settles).
    // TEST-233 verifies: SPEC-LIQ-019, REQ-SWAP-064, REQ-SWAP-112
    function test_TEST_233_shortfallPulledFromCallerOnly() public {
        _poorUnwind(900_000);
        LiquidationParams memory p = _params(proxy, 1950e6);
        p.maxShortfall = 200e6;
        usdc.mint(keeper, 1950e6 + 200e6);
        vm.prank(keeper);
        usdc.approve(address(lvs), 1950e6); // allowance for X only
        uint256 debt = _debtOf(proxy, usdcReserveId);
        vm.prank(keeper);
        vm.expectRevert();
        lvs.liquidate(p);
        assertEq(_debtOf(proxy, usdcReserveId), debt, "nothing settled");
        vm.prank(keeper);
        usdc.approve(address(lvs), 1950e6 + 200e6);
        uint256 others = usdc.balanceOf(carol) + usdc.balanceOf(bob);
        vm.prank(keeper);
        LiquidationResult memory r = lvs.liquidate(p);
        assertGt(r.shortfall, 0, "top-up pulled");
        assertEq(usdc.balanceOf(carol) + usdc.balanceOf(bob), others, "no other address funds it");
    }

    /// @notice Dust (SPEC-LIQ-019 dust example): `Kf = D = 3` USDC and a recovery above the floor need no top-up even
    /// with `maxShortfall = 0`; the gap is never above the floor gap while `D ≤ Kf`.
    // TEST-233 verifies: SPEC-LIQ-019, SPEC-SET-001, REQ-SWAP-061, REQ-SWAP-029
    function test_TEST_233_dustNeedsNoTopUp() public {
        usdtUsdcPool.setRate(5, 10);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 3e6));
        assertEq(r.shortfall, 0, "no top-up");
        assertLt(r.recovered, r.debtRepaid, "R below D");
        assertEq(r.keeperOut, 3e6 - (3e6 - r.recovered), "keeperOut = R");
    }

    /// @notice LIQ-I4, the per-call relaxation bound kept on purpose: with both USDT routes 12 % below the oracle, the
    /// leg minimum at `sLeg = s + maxShortfallBps = 1,100` bps is above what any route returns, so no caller can
    /// liquidate whatever `maxShortfall` it offers (`NoRouteAvailable`). The bound limits how far below the oracle a
    /// single call may sell into a crashed route (and how much a sandwich can take from the caller's top-up); liveness
    /// in a cascade comes from smaller calls once arbitrage restores the route, or from governance raising
    /// `maxShortfallBps` (bounds [0, 5,000]), after which the same call settles with the caller's top-up.
    // TEST-233 verifies: SPEC-LIQ-019, REQ-SWAP-046, REQ-PSTORE-018, ATTACK-065, EMG-057
    function test_TEST_233_relaxationBoundHoldsInACascade() public {
        usdtUsdcPool.setRate(88, 100);
        usdtUsdcPool2.setRate(88, 100);
        LiquidationParams memory p = _params(proxy, 1950e6);
        p.maxShortfall = 1_000_000e6;
        _fund(usdc, keeper, 1950e6 + 1_000_000e6);
        _expectLiquidateRevert(keeper, p, _err(ILPVaultSwapErrors.NoRouteAvailable.selector));
        store.setMaxShortfallBps(1500);
        LiquidationResult memory r = _liquidateAs(keeper, p);
        assertGt(r.shortfall, 0, "the caller tops up the floor gap");
        assertEq(r.recovered + r.shortfall, r.minOut, "R' = minRec");
    }
}
