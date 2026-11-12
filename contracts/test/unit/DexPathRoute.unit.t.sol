// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DexPathRoute} from "../../src/liquidation/settlement-routes/DexPathRoute.sol";
import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {DexHop} from "../../src/liquidation/settlement-routes/types/DexHop.sol";
import {RouteConfig} from "../../src/liquidation/settlement-routes/types/RouteConfig.sol";
import {ILock} from "../../src/lock/lock/ILock.sol";
import {SwapRouteFixture} from "../utils/fixtures/SwapRouteFixture.sol";
import {SettlementMathHarness} from "../utils/harness/SettlementMathHarness.sol";
import {MockCLPool, MockCurvePool, MockRouteCaller} from "../utils/mocks/SwapRouteMocks.sol";

/// @title DexPathRouteUnitTest
/// @notice Unit tests of the `DexPath` swap route (2.12, route type 1): caller and Lock checks, the measured pull, hops
/// over concentrated-liquidity and Curve pools, the callback rules, the per-swap minimum from SettlementMath, residues,
/// donations, allowances and the views the MarketRegistry reads.
contract DexPathRouteUnitTest is SwapRouteFixture {
    SettlementMathHarness internal math;

    function setUp() public override {
        super.setUp();
        math = new SettlementMathHarness();
    }

    // ─── Caller and Lock (TEST-046) ───

    // TEST-046 verifies: REQ-ROUTE-007, REQ-ROUTE-025, INV-054
    function testFuzz_TEST_046_swapRevertsForAnyCallerButLPVaultSwap(
        address caller
    ) public {
        (DexPathRoute route,) = _usdtUsdcRoute();
        vm.assume(caller != address(swapper));
        vm.prank(address(swapper));
        lock.acquire();
        vm.prank(caller);
        vm.expectRevert(ISettlementRoute.NotLPVaultSwap.selector);
        route.swap(1e6, 1);
    }

    // TEST-046 verifies: REQ-ROUTE-007, REQ-ROUTE-025, INV-054
    function test_TEST_046_swapRevertsWhenLockFree() public {
        (DexPathRoute route,) = _usdtUsdcRoute();
        usdt.mint(address(swapper), 1e6);
        vm.expectRevert(ISettlementRoute.NotLocked.selector);
        swapper.swapHeld(route, 1e6, 1);
    }

    // TEST-046 verifies: REQ-ROUTE-007, REQ-ROUTE-025, INV-054
    function test_TEST_046_callerCheckComesBeforeLockCheck() public {
        (DexPathRoute route,) = _usdtUsdcRoute();
        vm.expectRevert(ISettlementRoute.NotLPVaultSwap.selector);
        route.swap(1e6, 1);
    }

    // TEST-046 verifies: REQ-ROUTE-007, Q-255
    function test_TEST_046_swapAcceptedWhileAdapterHoldsLock() public {
        (DexPathRoute route,) = _usdtUsdcRoute();
        usdt.mint(address(swapper), 1500e6);
        (bool ok, bytes memory ret) =
            adapter.acquireCallRelease(address(swapper), abi.encodeCall(MockRouteCaller.swapHeld, (route, 1500e6, 1)));
        assertTrue(ok, "adapter-held swap failed");
        assertEq(abi.decode(ret, (uint256)), 1500e6);
        assertEq(usdc.balanceOf(address(swapper)), 1500e6);
    }

    // ─── Callback (TEST-046) ───

    // TEST-046 verifies: REQ-ROUTE-013, REQ-ROUTE-029, INV-040
    function testFuzz_TEST_046_callbackRevertsOutsideHop(
        address caller,
        int256 amount0,
        int256 amount1
    ) public {
        (DexPathRoute route,) = _usdtUsdcRoute();
        vm.prank(caller);
        vm.expectRevert(ISettlementRoute.InvalidCallback.selector);
        route.uniswapV3SwapCallback(amount0, amount1, "");
    }

    // TEST-046 verifies: REQ-ROUTE-013, REQ-ROUTE-029, INV-040
    function test_TEST_046_callbackFromRoutePoolOutsideHopReverts() public {
        (DexPathRoute route, MockCLPool pool) = _usdtUsdcRoute();
        usdt.mint(address(route), 10e6);
        vm.expectRevert(ISettlementRoute.InvalidCallback.selector);
        pool.poke(address(route), 1e6, 0);
        vm.expectRevert(ISettlementRoute.InvalidCallback.selector);
        pool.poke(address(route), 0, 1e6);
        assertEq(usdt.balanceOf(address(route)), 10e6);
    }

    // TEST-046 verifies: REQ-ROUTE-013, REQ-ROUTE-029, INV-040, ATTACK-092
    function test_TEST_046_callbackFromOtherAddressDuringHopReverts() public {
        (DexPathRoute route,) = _usdtUsdcRoute();
        MockCLPool attacker = new MockCLPool(address(usdt), address(usdc));
        // The pool's USDC payment to the route runs the hook: an attacker contract calls the callback mid-hop.
        usdc.setHook(address(attacker), abi.encodeCall(MockCLPool.poke, (address(route), 1e6, 1e6)));
        usdt.mint(address(swapper), 1e6);
        vm.expectRevert(ISettlementRoute.InvalidCallback.selector);
        swapper.swapUnderLock(route, 1e6, 1);
    }

    // TEST-046 verifies: REQ-ROUTE-013, REQ-ROUTE-029, INV-040
    function test_TEST_046_poolAskingMoreThanTheHopReverts() public {
        (DexPathRoute route, MockCLPool pool) = _usdtUsdcRoute();
        pool.setMode(MockCLPool.Mode.OverAsk);
        usdt.mint(address(route), 1e6); // a donation the pool would like to take
        usdt.mint(address(swapper), 1e6);
        vm.expectRevert(ISettlementRoute.InvalidCallback.selector);
        swapper.swapUnderLock(route, 1e6, 1);
    }

    // TEST-046 verifies: REQ-ROUTE-013, REQ-ROUTE-029, INV-040
    function test_TEST_046_secondCallbackInOneHopReverts() public {
        (DexPathRoute route, MockCLPool pool) = _usdtUsdcRoute();
        pool.setMode(MockCLPool.Mode.DoubleCallback);
        usdt.mint(address(route), 1e6);
        usdt.mint(address(swapper), 1e6);
        vm.expectRevert(ISettlementRoute.InvalidCallback.selector);
        swapper.swapUnderLock(route, 1e6, 1);
    }

    // TEST-046 verifies: REQ-ROUTE-013, REQ-ROUTE-029
    function test_TEST_046_owedOnOutputSideReverts() public {
        (DexPathRoute route, MockCLPool pool) = _usdtUsdcRoute();
        pool.setMode(MockCLPool.Mode.WrongSide);
        usdt.mint(address(swapper), 1e6);
        vm.expectRevert(ISettlementRoute.InvalidCallback.selector);
        swapper.swapUnderLock(route, 1e6, 1);
    }

    // TEST-046 verifies: REQ-ROUTE-013, REQ-ROUTE-026
    function test_TEST_046_poolThatIsNotPaidReverts() public {
        (DexPathRoute route, MockCLPool pool) = _usdtUsdcRoute();
        pool.setMode(MockCLPool.Mode.NoCallback);
        usdt.mint(address(swapper), 1e6);
        vm.expectRevert(bytes("IIA"));
        swapper.swapUnderLock(route, 1e6, 1);
    }

    // ─── Per-swap minimum (TEST-232) ───

    // TEST-232 verifies: REQ-ROUTE-009, REQ-ROUTE-042, REQ-ROUTE-044, INV-083, SPEC-LIQ-018
    function test_TEST_232_settlementMathMinimumPassesPrimaryAndRevertsSandwich() public {
        // REQ-ROUTE-042 example: 6,211.3 USDT at $0.9995 into USDC, s = 100, one swapped leg, ε = 1 USDC.
        uint256 amountIn = 6_211_300_000;
        uint256 vLeg = math.legValue(amountIn, 99_950_000, 6, 6, 1e8);
        uint256 uLeg = math.unitValue(99_950_000, 6, 6, 1e8);
        uint256 minOut = math.legMinOut(vLeg, 100, uLeg, 1e6, 1);
        assertEq(minOut, 6_145_112_406, "SPEC-LIQ-018 example");

        (DexPathRoute route, MockCLPool pool) = _usdtUsdcRoute();
        pool.setRate(6_205_000_000, amountIn); // the primary returns 6,205 USDC
        assertEq(_swap(route, amountIn, minOut), 6_205_000_000);

        pool.setRate(6_100_000_000, amountIn); // a sandwiched pool returns 6,100 USDC
        usdt.mint(address(swapper), amountIn);
        vm.expectRevert(abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, 6_100_000_000, minOut));
        swapper.swapUnderLock(route, amountIn, minOut);
    }

    // TEST-232 verifies: REQ-ROUTE-009, REQ-ROUTE-042, INV-083
    function test_TEST_232_exactMinimumPassesOneUnitShortReverts() public {
        (DexPathRoute route,) = _usdtUsdcRoute();
        assertEq(_swap(route, 1000e6, 1000e6), 1000e6);
        usdt.mint(address(swapper), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, 1000e6, 1000e6 + 1));
        swapper.swapUnderLock(route, 1000e6, 1000e6 + 1);
    }

    // TEST-232 verifies: REQ-ROUTE-042, INV-083
    function test_TEST_232_zeroMinimumIsRefused() public {
        (DexPathRoute route,) = _usdtUsdcRoute();
        usdt.setRevertOnZero(true);
        usdt.mint(address(swapper), 1e6);
        vm.expectRevert(ISettlementRoute.ZeroMinOut.selector);
        swapper.swapUnderLock(route, 1e6, 0);
        // A zero amount is reported first, before the minimum.
        vm.expectRevert(ISettlementRoute.TransferMismatch.selector);
        swapper.swapUnderLock(route, 0, 0);
    }

    // TEST-232 verifies: REQ-ROUTE-009, REQ-ROUTE-014, REQ-ROUTE-042
    function test_TEST_232_minimumCheckedOnWhatLPVaultSwapReceives() public {
        (DexPathRoute route,) = _usdtUsdcRoute();
        // A 10 bps fee on the debt asset: the pool pays 1,000 USDC, the route receives 999 and forwards them, and
        // LPVaultSwap receives 998.001; the minimum is checked on that last figure.
        usdc.setFeeBps(10);
        usdt.mint(address(swapper), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, 998_001_000, 999e6));
        swapper.swapUnderLock(route, 1000e6, 999e6);
        assertEq(_swap(route, 1000e6, 998_001_000), 998_001_000);
        assertEq(usdc.balanceOf(address(route)), 0);
    }

    // TEST-232 verifies: REQ-ROUTE-009, REQ-ROUTE-042
    function test_TEST_232_everyHopRunsWithZeroMinimumAndExtremeLimit() public {
        MockCLPool p1 = _clPool(cbeth, weth, 11, 10);
        MockCurvePool p2 = _curvePool(weth, usdc, 3000e6, 1e18);
        DexPathRoute route = new DexPathRoute(
            _config(address(cbeth), address(usdc)),
            _hops2(_clHop(address(p1), address(weth)), _curveHop(address(p2), address(usdc), 0, 1))
        );
        uint256 out = _swap(route, 1e18, 3000e6);
        assertEq(out, 3300e6);
        assertEq(p2.lastMinDy(), 0, "Curve min_dy");
        bool zfo = p1.lastZeroForOne();
        assertEq(
            p1.lastLimit(), zfo ? 4_295_128_740 : 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341
        );
        assertEq(zfo, address(cbeth) < address(weth), "direction from token0");
    }

    // ─── Measured pull (TEST-221) ───

    // TEST-221 verifies: REQ-ROUTE-008
    function test_TEST_221_inputTransferFeeSwapsTheAmountReceived() public {
        MockCurvePool pool = _curvePool(usdt, usdc, 1, 1);
        DexPathRoute route = new DexPathRoute(
            _config(address(usdt), address(usdc)), _hops1(_curveHop(address(pool), address(usdc), 0, 1))
        );
        usdt.setFeeBps(10);
        uint256 poolUsdtBefore = usdt.balanceOf(address(pool));
        uint256 out = _swap(route, 6_211_300_000, 6000e6);
        // inRecv = 6,205,088,700 (REQ-ROUTE-008 example); the route's transfer to the pool pays the fee again.
        assertEq(out, 6_205_088_700, "leg runs on inRecv");
        assertEq(usdt.balanceOf(address(pool)) - poolUsdtBefore, 6_205_088_700 - 6_205_088);
        assertEq(usdt.balanceOf(address(route)), 0);
    }

    // TEST-221 verifies: REQ-ROUTE-008
    function test_TEST_221_nothingReceivedReverts() public {
        (DexPathRoute route,) = _usdtUsdcRoute();
        usdt.setFeeBps(10_000);
        usdt.mint(address(swapper), 1e6);
        vm.expectRevert(ISettlementRoute.TransferMismatch.selector);
        swapper.swapUnderLock(route, 1e6, 1);
    }

    // TEST-221 verifies: REQ-ROUTE-008
    function test_TEST_221_moreThanRequestedReverts() public {
        (DexPathRoute route,) = _usdtUsdcRoute();
        usdt.setBonus(1);
        usdt.mint(address(swapper), 1e6);
        vm.expectRevert(ISettlementRoute.TransferMismatch.selector);
        swapper.swapUnderLock(route, 1e6, 1);
    }

    // TEST-221 verifies: REQ-ROUTE-008, REQ-ROUTE-035
    function test_TEST_221_routePullsExactlyAmountInWhateverTheAllowance() public {
        (DexPathRoute route,) = _usdtUsdcRoute();
        usdt.mint(address(swapper), 10e6);
        swapper.swapWithAllowance(route, 10e6, 4e6, 1);
        assertEq(usdt.balanceOf(address(swapper)), 6e6);
    }

    // ─── Zero amounts (TEST-177) ───

    // TEST-177 verifies: REQ-ROUTE-008, REQ-ROUTE-015, INV-021
    function test_TEST_177_zeroAmountInRevertsBeforeAnyTransfer() public {
        (DexPathRoute route,) = _usdtUsdcRoute();
        usdt.setRevertOnZero(true);
        vm.expectRevert(ISettlementRoute.TransferMismatch.selector);
        swapper.swapUnderLock(route, 0, 1);
    }

    // TEST-177 verifies: REQ-ROUTE-015, INV-021
    function test_TEST_177_zeroResiduesAreNotTransferred() public {
        MockCLPool p1 = _clPool(cbeth, weth, 1, 1);
        MockCLPool p2 = _clPool(weth, usdc, 3000e6, 1e18);
        DexPathRoute route = new DexPathRoute(
            _config(address(cbeth), address(usdc)),
            _hops2(_clHop(address(p1), address(weth)), _clHop(address(p2), address(usdc)))
        );
        cbeth.setRevertOnZero(true);
        weth.setRevertOnZero(true);
        usdc.setRevertOnZero(true);
        assertEq(_swap(route, 2e18, 1), 6000e6);
    }

    // TEST-177 verifies: REQ-ROUTE-009, REQ-ROUTE-044
    function test_TEST_177_zeroOutputRevertsMinOutNotMetWithoutZeroTransfers() public {
        (DexPathRoute route, MockCLPool pool) = _usdtUsdcRoute();
        pool.setRate(0, 1);
        usdc.setRevertOnZero(true);
        usdt.mint(address(swapper), 1e6);
        vm.expectRevert(abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, 0, 1));
        swapper.swapUnderLock(route, 1e6, 1);
    }

    // ─── Residues and balances (REQ-ROUTE-015, REQ-ROUTE-016) ───

    // TEST-054 verifies: REQ-ROUTE-015, REQ-ROUTE-016, REQ-ROUTE-034, INV-021
    function test_TEST_054_inputResidueOfAThinPoolGoesBackToLPVaultSwap() public {
        MockCLPool p1 = _clPool(cbeth, weth, 1, 1);
        MockCLPool p2 = _clPool(weth, usdc, 3000e6, 1e18);
        p1.setMaxIn(9.8e18); // the cbETH/WETH pool takes 9.8 of 10 cbETH at the price limit
        DexPathRoute route = new DexPathRoute(
            _config(address(cbeth), address(usdc)),
            _hops2(_clHop(address(p1), address(weth)), _clHop(address(p2), address(usdc)))
        );
        uint256 out = _swap(route, 10e18, 1);
        assertEq(out, 29_400e6);
        assertEq(cbeth.balanceOf(address(swapper)), 0.2e18, "cbETH residue");
        assertEq(cbeth.balanceOf(address(route)), 0);
        assertEq(weth.balanceOf(address(route)), 0);
        assertEq(usdc.balanceOf(address(route)), 0);
    }

    // TEST-054 verifies: REQ-ROUTE-015, REQ-ROUTE-016, INV-021
    function test_TEST_054_intermediateResidueGoesBackToLPVaultSwap() public {
        MockCLPool p1 = _clPool(cbeth, weth, 1, 1);
        MockCLPool p2 = _clPool(weth, usdc, 3000e6, 1e18);
        p2.setMaxIn(1.5e18);
        DexPathRoute route = new DexPathRoute(
            _config(address(cbeth), address(usdc)),
            _hops2(_clHop(address(p1), address(weth)), _clHop(address(p2), address(usdc)))
        );
        assertEq(_swap(route, 2e18, 1), 4500e6);
        assertEq(weth.balanceOf(address(swapper)), 0.5e18, "WETH residue");
        assertEq(weth.balanceOf(address(route)), 0);
    }

    // TEST-054 verifies: REQ-ROUTE-010, REQ-ROUTE-016, INV-021
    function test_TEST_054_noAllowanceOutstandingAfterCurveHops() public {
        MockCurvePool p1 = _curvePool(usdt, dai, 1e12, 1);
        MockCurvePool p2 = _curvePool(dai, usdc, 1, 1e12);
        DexPathRoute route = new DexPathRoute(
            _config(address(usdt), address(usdc)),
            _hops2(_curveHop(address(p1), address(dai), 0, 1), _curveHop(address(p2), address(usdc), 0, 1))
        );
        assertEq(_swap(route, 500e6, 500e6), 500e6);
        _assertNoAllowance(
            address(route), _list3(address(usdt), address(dai), address(usdc)), _list2(address(p1), address(p2))
        );
        assertEq(usdt.allowance(address(swapper), address(route)), 0);
    }

    // TEST-080 verifies: REQ-ROUTE-014, REQ-ROUTE-016, INV-021
    function testFuzz_TEST_080_donationsNeitherBlockNorCount(
        uint32 dustIn,
        uint32 dustMid,
        uint32 dustOut
    ) public {
        MockCLPool p1 = _clPool(cbeth, weth, 1, 1);
        MockCLPool p2 = _clPool(weth, usdc, 3000e6, 1e18);
        DexPathRoute route = new DexPathRoute(
            _config(address(cbeth), address(usdc)),
            _hops2(_clHop(address(p1), address(weth)), _clHop(address(p2), address(usdc)))
        );
        cbeth.mint(address(route), dustIn);
        weth.mint(address(route), dustMid);
        usdc.mint(address(route), dustOut);
        assertEq(_swap(route, 1e18, 3000e6), 3000e6, "donation counted toward the output");
        vm.expectRevert(abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, 3000e6, 3000e6 + 1));
        this.swapExternal(route, 1e18, 3000e6 + 1);
        assertEq(cbeth.balanceOf(address(route)), dustIn);
        assertEq(weth.balanceOf(address(route)), dustMid);
        assertEq(usdc.balanceOf(address(route)), dustOut);
    }

    function swapExternal(
        DexPathRoute route,
        uint256 amountIn,
        uint256 minOut
    ) external returns (uint256) {
        return _swap(route, amountIn, minOut);
    }

    // ─── Reentry (TEST-060) ───

    // TEST-060 verifies: REQ-ROUTE-007, INV-054, ATTACK-092
    function test_TEST_060_reentryThroughTokenHookReverts() public {
        (DexPathRoute route,) = _usdtUsdcRoute();
        usdt.mint(address(swapper), 2e6);
        // The output token calls LPVaultSwap again mid-swap: the Lock is held, so its acquire refuses.
        usdc.setHook(address(swapper), abi.encodeCall(MockRouteCaller.swapUnderLock, (route, 1e6, 1)));
        vm.expectRevert(abi.encodeWithSelector(ILock.LockHeld.selector, address(swapper)));
        swapper.swapUnderLock(route, 1e6, 1);
        // The output token calls the route itself: only LPVaultSwap may call it.
        usdc.setHook(address(route), abi.encodeCall(ISettlementRoute.swap, (1e6, 1)));
        vm.expectRevert(ISettlementRoute.NotLPVaultSwap.selector);
        swapper.swapUnderLock(route, 1e6, 1);
    }

    // ─── Paths, views and deployment checks (TEST-054) ───

    // TEST-054 verifies: REQ-ROUTE-002, REQ-ROUTE-003, REQ-ROUTE-005, REQ-ROUTE-043, Q-379
    function test_TEST_054_threeHopPathAndViews() public {
        MockCurvePool p1 = _curvePool(usdt, dai, 1e12, 1);
        MockCLPool p2 = _clPool(dai, weth, 1, 3000);
        MockCLPool p3 = _clPool(weth, usdc, 3000e6, 1e18);
        DexHop[] memory hops = _hops3(
            _curveHop(address(p1), address(dai), 0, 1),
            _clHop(address(p2), address(weth)),
            _clHop(address(p3), address(usdc))
        );
        DexPathRoute route = new DexPathRoute(_config(address(usdt), address(usdc)), hops);
        assertEq(_swap(route, 3000e6, 2999e6), 3000e6);

        assertEq(route.routeType(), 1);
        assertEq(route.tokenIn(), address(usdt));
        assertEq(route.tokenOut(), address(usdc));
        assertEq(route.LP_VAULT_SWAP(), address(swapper));
        assertEq(route.AAVE_ADAPTER(), address(adapter));
        address[] memory deps = route.dependencies();
        assertEq(deps.length, 3);
        assertEq(deps[0], address(p1));
        assertEq(deps[1], address(p2));
        assertEq(deps[2], address(p3));
        address[] memory mid = route.intermediates();
        assertEq(mid.length, 2);
        assertEq(mid[0], address(dai));
        assertEq(mid[1], address(weth));
        assertTrue(route.supportsTokenClass(1));
        assertFalse(route.supportsTokenClass(0));
        assertFalse(route.supportsTokenClass(2));
        assertFalse(route.supportsTokenClass(3));
        assertFalse(route.supportsTokenClass(4));
    }

    // TEST-054 verifies: REQ-ROUTE-045, Q-379
    function test_TEST_054_constructorRejectsBadSharedConfig() public {
        (, MockCLPool pool) = _usdtUsdcRoute();
        DexHop[] memory hops = _hops1(_clHop(address(pool), address(usdc)));
        RouteConfig memory var_;
        for (uint256 f = 0; f < 6; ++f) {
            var_ = _config(address(usdt), address(usdc));
            if (f == 0) var_.lpVaultSwap = address(0);
            if (f == 1) var_.lock = address(0);
            if (f == 2) var_.aaveAdapter = address(0);
            if (f == 3) var_.tokenIn = address(0);
            if (f == 4) var_.tokenOut = address(0);
            if (f == 5) var_.aaveAdapter = address(swapper);
            vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
            this.deployDexPath(var_, hops);
        }
        // A Lock whose members are other addresses.
        var_ = _config(address(usdt), address(usdc));
        var_.lock = address(new LockStub(address(adapter), address(0xBAD)));
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        this.deployDexPath(var_, hops);
        var_.lock = address(new LockStub(address(0xBAD), address(swapper)));
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        this.deployDexPath(var_, hops);
        // Token-class masks: none, bit 0, bit 4.
        uint8[3] memory masks = [uint8(0), uint8(1), uint8(1 << 4)];
        for (uint256 m = 0; m < 3; ++m) {
            var_ = _config(address(usdt), address(usdc));
            var_.tokenClassMask = masks[m];
            vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
            this.deployDexPath(var_, hops);
        }
        var_ = _config(address(usdt), address(usdc));
        var_.tokenClassMask = STABLE | CORRELATED | VOLATILE;
        DexPathRoute route = new DexPathRoute(var_, hops);
        assertTrue(route.supportsTokenClass(1) && route.supportsTokenClass(2) && route.supportsTokenClass(3));
    }

    // TEST-054 verifies: REQ-ROUTE-045
    function test_TEST_054_constructorRejectsEqualTokens() public {
        MockCurvePool pool = _curvePool(usdt, usdc, 1, 1);
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        this.deployDexPath(_config(address(usdt), address(usdt)), _hops1(_curveHop(address(pool), address(usdt), 1, 0)));
    }

    // TEST-054 verifies: REQ-ROUTE-043, REQ-ROUTE-045
    function test_TEST_054_constructorRejectsHopsThatDoNotConnect() public {
        MockCLPool usdtUsdc = _clPool(usdt, usdc, 1, 1);
        MockCLPool wethUsdc = _clPool(weth, usdc, 1, 1);
        MockCurvePool curve = _curvePool(usdt, usdc, 1, 1);
        DexHop[] memory none = new DexHop[](0);
        _expectBadHops(none);
        // Pool does not hold the input token.
        _expectBadHops(_hops1(_clHop(address(wethUsdc), address(usdc))));
        // Last hop does not end in the debt asset.
        _expectBadHops(_hops1(_clHop(address(usdtUsdc), address(usdt))));
        _expectBadHops(_hops1(_clHop(address(0), address(usdc))));
        // Concentrated-liquidity hop with Curve indices.
        _expectBadHops(_hops1(_curveHopAsCl(address(usdtUsdc), address(usdc))));
        // Curve indices: swapped, equal, negative.
        _expectBadHops(_hops1(_curveHop(address(curve), address(usdc), 1, 0)));
        _expectBadHops(_hops1(_curveHop(address(curve), address(usdc), 0, 0)));
        _expectBadHops(_hops1(_curveHop(address(curve), address(usdc), -1, 1)));
        // Four hops.
        MockCLPool a = _clPool(usdt, dai, 1, 1);
        MockCLPool b = _clPool(dai, weth, 1, 1);
        MockCLPool c = _clPool(weth, cbeth, 1, 1);
        MockCLPool d = _clPool(cbeth, usdc, 1, 1);
        DexHop[] memory four = new DexHop[](4);
        four[0] = _clHop(address(a), address(dai));
        four[1] = _clHop(address(b), address(weth));
        four[2] = _clHop(address(c), address(cbeth));
        four[3] = _clHop(address(d), address(usdc));
        _expectBadHops(four);
    }

    // TEST-054 verifies: REQ-ROUTE-003, REQ-ROUTE-043, REQ-ROUTE-045
    function test_TEST_054_constructorRejectsRepeatedTokensOrPools() public {
        MockCLPool usdtDai = _clPool(usdt, dai, 1, 1);
        MockCLPool daiUsdt = usdtDai;
        MockCLPool usdtUsdc = _clPool(usdt, usdc, 1, 1);
        // A path back through the input token: USDT → DAI → USDT → USDC.
        _expectBadHops(
            _hops3(
                _clHop(address(usdtDai), address(dai)),
                _clHop(address(daiUsdt), address(usdt)),
                _clHop(address(usdtUsdc), address(usdc))
            )
        );
        // Distinct tokens and pools are accepted.
        MockCLPool daiWeth = _clPool(dai, weth, 1, 1);
        MockCLPool wethUsdc = _clPool(weth, usdc, 1, 1);
        DexPathRoute ok = new DexPathRoute(
            _config(address(usdt), address(usdc)),
            _hops3(
                _clHop(address(usdtDai), address(dai)),
                _clHop(address(daiWeth), address(weth)),
                _clHop(address(wethUsdc), address(usdc))
            )
        );
        assertEq(ok.dependencies().length, 3);
    }

    function _expectBadHops(
        DexHop[] memory hops
    ) internal {
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        this.deployDexPath(_config(address(usdt), address(usdc)), hops);
    }

    function _curveHopAsCl(
        address pool,
        address tokenOut
    ) internal pure returns (DexHop memory hop) {
        hop = _clHop(pool, tokenOut);
        hop.i = 1;
    }

    // ─── No buy or sell-back surface (TEST-054) ───

    // TEST-054 verifies: REQ-ROUTE-016, REQ-ROUTE-031, REQ-ROUTE-032, REQ-ROUTE-040, REQ-ROUTE-041
    function test_TEST_054_noBuySellBackOrRescueSelectors() public {
        (DexPathRoute route,) = _usdtUsdcRoute();
        bytes4[6] memory absent = [
            bytes4(keccak256("buy(uint256,uint256)")),
            bytes4(keccak256("sellBack(uint256,uint256)")),
            bytes4(keccak256("convert(uint256,uint256)")),
            bytes4(keccak256("rescue(address,address,uint256)")),
            bytes4(keccak256("sweep(address)")),
            bytes4(keccak256("owner()"))
        ];
        for (uint256 k = 0; k < absent.length; ++k) {
            (bool ok,) = address(route).call(abi.encodeWithSelector(absent[k]));
            assertFalse(ok, "unexpected selector");
        }
        (bool sent,) = address(route).call{value: 1}("");
        assertFalse(sent, "route accepts ETH");
    }
}

/// @notice A Lock look-alike exposing chosen member addresses, to check the route's wiring check.
contract LockStub {
    address public immutable AAVE_ADAPTER;
    address public immutable LP_VAULT_SWAP;

    constructor(
        address adapter_,
        address swap_
    ) {
        AAVE_ADAPTER = adapter_;
        LP_VAULT_SWAP = swap_;
    }
}
