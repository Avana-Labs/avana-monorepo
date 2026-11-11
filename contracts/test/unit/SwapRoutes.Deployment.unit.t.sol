// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DexPathRoute} from "../../src/liquidation/settlement-routes/DexPathRoute.sol";
import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {PegModuleRoute} from "../../src/liquidation/settlement-routes/PegModuleRoute.sol";
import {WrapperThenDexRoute} from "../../src/liquidation/settlement-routes/WrapperThenDexRoute.sol";
import {DexHop} from "../../src/liquidation/settlement-routes/types/DexHop.sol";
import {PegModuleKind, PegModuleStep} from "../../src/liquidation/settlement-routes/types/PegModuleStep.sol";
import {RouteConfig} from "../../src/liquidation/settlement-routes/types/RouteConfig.sol";
import {WrapperKind, WrapperStep} from "../../src/liquidation/settlement-routes/types/WrapperStep.sol";
import {SwapRouteFixture} from "../utils/fixtures/SwapRouteFixture.sol";
import {
    MockCLPool,
    MockCurvePool,
    MockDaiUsds,
    MockGsm,
    MockLitePsm,
    MockPsmAndConverter,
    MockVault4626,
    VerboseSlipstreamPool
} from "../utils/mocks/SwapRouteMocks.sol";

/// @notice Deploys a `DexPathRoute` inside a call, so a test can cap the gas the deployment receives.
contract DexPathDeployer {
    function deploy(
        RouteConfig calldata config,
        DexHop[] calldata hops
    ) external returns (DexPathRoute route) {
        route = new DexPathRoute(config, hops);
    }
}

/// @title SwapRoutesDeploymentUnitTest
/// @notice The 2026-11-10 swap-route review fixes: a token with a transfer-fee switch (USDT) is never paid into a
/// concentrated-liquidity pool or a GSM's static aToken, and with the fee on it still swaps through Curve; every hop pool
/// is the pinned factory's pool; every failed deployment check reverts `InvalidRouteConfig`, including contracts that do
/// not answer and a LitePSM or converter with other tokens; a callback from another pool of the route while a hop is in
/// progress is refused; a rebasing input that credits one unit less swaps what arrived.
contract SwapRoutesDeploymentUnitTest is SwapRouteFixture {
    // ─── Transfer-fee switch (REQ-ROUTE-008) ───

    // TEST-221 verifies: REQ-ROUTE-008, REQ-ROUTE-045
    // Sources: 2.12 REQ-ROUTE-008, swap-routes review M-1
    /// @notice USDT as the input or an intermediate of a concentrated-liquidity hop is refused at deployment, with its
    /// fee off or on: the pool checks its balance after the callback, so a fee switched on later would revert the hop.
    function test_TEST_221_feeSwitchTokenRefusedOnConcentratedHop() public {
        MockCLPool tetherUsdc = _clPool(tether, usdc, 1, 1);
        _expectBad(_config(address(tether), address(usdc)), _hops1(_clHop(address(tetherUsdc), address(usdc))));
        tether.setFeeBps(10);
        _expectBad(_config(address(tether), address(usdc)), _hops1(_clHop(address(tetherUsdc), address(usdc))));
        // As an intermediate: DAI → USDT on Curve, then USDT → USDC on a concentrated pool.
        MockCurvePool daiTether = _curvePool(dai, tether, 1, 1e12);
        _expectBad(
            _config(address(dai), address(usdc)),
            _hops2(_curveHop(address(daiTether), address(tether), 0, 1), _clHop(address(tetherUsdc), address(usdc)))
        );
        // A USDT output of a concentrated hop is accepted: the pool pays the route and the route measures the rise.
        MockCLPool usdcTether = tetherUsdc;
        DexPathRoute out = new DexPathRoute(
            _config(address(usdc), address(tether)), _hops1(_clHop(address(usdcTether), address(tether)))
        );
        assertEq(out.exactAmountInputs().length, 1);
        assertEq(out.exactAmountInputs()[0], address(usdc));
    }

    // TEST-221 verifies: REQ-ROUTE-008, REQ-ROUTE-045
    // Sources: 2.12 REQ-ROUTE-008 (the fee-switch probe runs with its full gas or the deployment fails)
    /// @notice A deployment sent with any amount of gas from 30,000 to 1,000,000 never yields a route that pays USDT
    /// into a concentrated-liquidity pool: a starved probe counts as a switch and the deployment reverts.
    function test_TEST_221_starvedFeeSwitchProbeNeverAcceptsTheToken() public {
        MockCLPool tetherUsdc = _clPool(tether, usdc, 1, 1);
        RouteConfig memory config = _config(address(tether), address(usdc));
        DexHop[] memory hops = _hops1(_clHop(address(tetherUsdc), address(usdc)));
        DexPathDeployer deployer = new DexPathDeployer();
        uint256 refusedWithError = 0;
        for (uint256 g = 30_000; g <= 1_000_000; g += 2500) {
            try deployer.deploy{gas: g}(config, hops) returns (DexPathRoute route) {
                revert(string.concat("deployed at gas ", vm.toString(g), ": ", vm.toString(address(route))));
            } catch (bytes memory reason) {
                if (bytes4(reason) == ISettlementRoute.InvalidRouteConfig.selector) ++refusedWithError;
            }
        }
        assertGt(refusedWithError, 0);
    }

    // TEST-221 verifies: REQ-ROUTE-003, REQ-ROUTE-008, REQ-ROUTE-015
    // Sources: 2.12 REQ-ROUTE-008 example (10 bps fee on 6,211.3 USDT)
    /// @notice With the fee switched on, USDT routed only through Curve hops still swaps, as the input and as an
    /// intermediate, and such a route lists no exact-amount input.
    function test_TEST_221_feeSwitchTokenSwapsThroughCurveWithFeeOn() public {
        MockCurvePool tetherUsdc = _curvePool(tether, usdc, 1, 1);
        DexPathRoute direct = new DexPathRoute(
            _config(address(tether), address(usdc)), _hops1(_curveHop(address(tetherUsdc), address(usdc), 0, 1))
        );
        assertEq(direct.exactAmountInputs().length, 0);
        tether.setFeeBps(10);
        uint256 out = _swap(direct, 6_211_300_000, 6000e6);
        assertEq(out, 6_205_088_700, "the leg runs on inRecv");
        MockCurvePool daiTether = _curvePool(dai, tether, 1, 1e12);
        DexPathRoute through = new DexPathRoute(
            _config(address(dai), address(usdc)),
            _hops2(
                _curveHop(address(daiTether), address(tether), 0, 1),
                _curveHop(address(tetherUsdc), address(usdc), 0, 1)
            )
        );
        out = _swap(through, 1000e18, 990e6);
        assertGt(out, 990e6);
        assertEq(tether.balanceOf(address(through)), 0, "no intermediate left behind");
    }

    // TEST-221 verifies: REQ-ROUTE-008, REQ-ROUTE-011, REQ-ROUTE-045
    // Sources: 2.12 REQ-ROUTE-008 (a GSM's static aToken supplies the amount it pulled to the Aave Pool)
    /// @notice A GSM route whose input has a fee switch is refused at deployment; a USDC GSM route deploys and lists
    /// USDC as its exact-amount input.
    function test_TEST_221_gsmRouteRefusesFeeSwitchInput() public {
        MockVault4626 stataTether = new MockVault4626(tether, "stataUSDT");
        MockGsm gsmTether = new MockGsm(address(stataTether), address(gho));
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        new PegModuleRoute(
            _config(address(tether), address(gho)),
            PegModuleStep({
                kind: PegModuleKind.Gsm,
                module: address(gsmTether),
                wrapper: address(stataTether),
                intermediate: address(stataTether)
            })
        );
        MockVault4626 stataUsdc = new MockVault4626(usdc, "stataUSDC");
        MockGsm gsmUsdc = new MockGsm(address(stataUsdc), address(gho));
        PegModuleRoute route = new PegModuleRoute(
            _config(address(usdc), address(gho)),
            PegModuleStep({
                kind: PegModuleKind.Gsm,
                module: address(gsmUsdc),
                wrapper: address(stataUsdc),
                intermediate: address(stataUsdc)
            })
        );
        assertEq(route.exactAmountInputs().length, 1);
        assertEq(route.exactAmountInputs()[0], address(usdc));
    }

    // TEST-221 verifies: REQ-ROUTE-008, REQ-ROUTE-016
    // Sources: 2.12 REQ-ROUTE-008 and REQ-ROUTE-016 (rebasing rounding)
    /// @notice A rebasing input whose transfer credits one unit less than requested swaps the amount that arrived; one
    /// that credits one unit more reverts `TransferMismatch`, so the route never counts units it was not sent.
    function test_TEST_221_rebasingInputRounding() public {
        MockCurvePool pool = _curvePool(usdt, usdc, 1, 1);
        DexPathRoute route = new DexPathRoute(
            _config(address(usdt), address(usdc)), _hops1(_curveHop(address(pool), address(usdc), 0, 1))
        );
        usdt.setDrain(1);
        uint256 out = _swap(route, 1000e6, 990e6);
        assertEq(out, 1000e6 - 1, "the hop runs on the unit-short amount that arrived");
        assertEq(usdt.balanceOf(address(route)), 0);
        usdt.setDrain(0);
        usdt.setBonus(1);
        usdt.mint(address(swapper), 1000e6);
        vm.expectRevert(ISettlementRoute.TransferMismatch.selector);
        swapper.swapUnderLock(route, 1000e6, 990e6);
    }

    // ─── Pinned factories (REQ-ROUTE-045) ───

    // TEST-054 verifies: REQ-ROUTE-043, REQ-ROUTE-045
    // Sources: 2.12 REQ-ROUTE-045, swap-routes review L-1 (look-alike pool)
    /// @notice A concentrated pool with the right tokens but no factory record is refused; the same pool registered
    /// with the pinned Slipstream factory is accepted; a chain without either factory refuses every concentrated hop; a
    /// Curve pool the pinned factory does not know, or knows at other indices, is refused.
    function test_TEST_054_hopPoolsMustComeFromPinnedFactories() public {
        MockCLPool lookalike = new MockCLPool(address(usdt), address(usdc));
        DexHop[] memory hops = _hops1(_clHop(address(lookalike), address(usdc)));
        _expectBad(_config(address(usdt), address(usdc)), hops);
        slipFactory.register(address(lookalike));
        DexPathRoute route = new DexPathRoute(_config(address(usdt), address(usdc)), hops);
        (address v3, address slip, address curve) = route.poolFactories();
        assertEq(v3, address(v3Factory));
        assertEq(slip, address(slipFactory));
        assertEq(curve, address(curveFactory));
        RouteConfig memory noFactories = _config(address(usdt), address(usdc));
        (noFactories.uniswapV3Factory, noFactories.slipstreamFactory) = (address(0), address(0));
        _expectBad(noFactories, hops);
        // Curve: unknown to the factory, then known with the coins in the other order.
        address[] memory coins = _list2(address(usdt), address(usdc));
        MockCurvePool unknown = new MockCurvePool(coins);
        _expectBad(_config(address(usdt), address(usdc)), _hops1(_curveHop(address(unknown), address(usdc), 0, 1)));
        curveFactory.registerCurve(address(unknown), _list2(address(usdc), address(usdt)));
        _expectBad(_config(address(usdt), address(usdc)), _hops1(_curveHop(address(unknown), address(usdc), 0, 1)));
        RouteConfig memory noCurve = _config(address(usdt), address(usdc));
        noCurve.curveFactory = address(0);
        MockCurvePool known = _curvePool(usdt, usdc, 1, 1);
        _expectBad(noCurve, _hops1(_curveHop(address(known), address(usdc), 0, 1)));
    }

    // TEST-054 verifies: REQ-ROUTE-045
    /// @notice A Slipstream pool whose `fee()` read fails is not a Uniswap v3 pool but is still recognized through the
    /// Slipstream factory's tick-spacing key, and answers longer than one word are read by their first word only (the
    /// copy is bounded to the words decoded).
    function test_TEST_054_slipstreamPoolRecognizedByTickSpacing() public {
        VerboseSlipstreamPool pool = new VerboseSlipstreamPool(address(usdt), address(usdc));
        slipFactory.registerSpacing(address(pool), address(usdt), address(usdc), 1);
        DexPathRoute route =
            new DexPathRoute(_config(address(usdt), address(usdc)), _hops1(_clHop(address(pool), address(usdc))));
        assertEq(route.dependencies()[0], address(pool));
        RouteConfig memory v3Only = _config(address(usdt), address(usdc));
        v3Only.slipstreamFactory = address(0);
        _expectBad(v3Only, _hops1(_clHop(address(pool), address(usdc))));
    }

    // ─── Every deployment failure is InvalidRouteConfig (REQ-ROUTE-045) ───

    // TEST-054 verifies: REQ-ROUTE-045
    // Sources: swap-routes review I-1
    /// @notice A pool without code, a Curve index past the pool's coins, and a Lock without code all revert
    /// `InvalidRouteConfig`, not an empty revert or a panic.
    function test_TEST_054_unansweredReadsRevertInvalidRouteConfig() public {
        _expectBad(_config(address(usdt), address(usdc)), _hops1(_clHop(address(0xBEEF), address(usdc))));
        MockCurvePool pool = _curvePool(usdt, usdc, 1, 1);
        _expectBad(_config(address(usdt), address(usdc)), _hops1(_curveHop(address(pool), address(usdc), 0, 5)));
        RouteConfig memory codelessLock = _config(address(usdt), address(usdc));
        codelessLock.lock = address(0xB0B);
        _expectBad(codelessLock, _hops1(_curveHop(address(pool), address(usdc), 0, 1)));
    }

    // TEST-054 verifies: REQ-ROUTE-012, REQ-ROUTE-045
    // Sources: swap-routes review I-2 (LitePSM with the wrong gem)
    /// @notice A LitePSM whose gem is not the output token, whose DAI is not the DAI the route spends, or whose
    /// conversion factor differs, and a DAI/USDS converter with other tokens, are refused at deployment.
    function test_TEST_054_litePsmAndConverterTokensChecked() public {
        PegModuleStep memory daiStep = PegModuleStep({
            kind: PegModuleKind.LitePsm, module: address(0), wrapper: address(0), intermediate: address(0)
        });
        daiStep.module = address(new MockLitePsm(address(dai), address(usdt), 6));
        _expectBadPeg(_config(address(dai), address(usdc)), daiStep);
        daiStep.module = address(new MockLitePsm(address(usds), address(usdc), 6));
        _expectBadPeg(_config(address(dai), address(usdc)), daiStep);
        daiStep.module = address(new MockLitePsm(address(dai), address(usdc), 18));
        _expectBadPeg(_config(address(dai), address(usdc)), daiStep);
        MockLitePsm psm = new MockLitePsm(address(dai), address(usdc), 6);
        daiStep.module = address(psm);
        new PegModuleRoute(_config(address(dai), address(usdc)), daiStep);
        // USDS input: the converter's tokens must be the input and the DAI the LitePSM takes.
        MockDaiUsds wrongConverter = new MockDaiUsds(address(usdt), address(dai));
        PegModuleStep memory usdsStep = PegModuleStep({
            kind: PegModuleKind.LitePsm,
            module: address(psm),
            wrapper: address(wrongConverter),
            intermediate: address(dai)
        });
        _expectBadPeg(_config(address(usds), address(usdc)), usdsStep);
        usdsStep.wrapper = address(new MockDaiUsds(address(usds), address(dai)));
        new PegModuleRoute(_config(address(usds), address(usdc)), usdsStep);
        // The same converter check for a WrapperThenDex route.
        MockCLPool daiUsdc = _clPool(dai, usdc, 1, 1e12);
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        new WrapperThenDexRoute(
            _config(address(usds), address(usdc)),
            WrapperStep({kind: WrapperKind.UsdsToDai, wrapper: address(wrongConverter), underlying: address(dai)}),
            _hops1(_clHop(address(daiUsdc), address(usdc)))
        );
    }

    // TEST-054 verifies: REQ-ROUTE-045
    /// @notice A contract named as both the LitePSM and the converter passes every token check and is refused because
    /// the module and the wrapper must be distinct contracts.
    function test_TEST_054_moduleNamedTwiceRefused() public {
        MockPsmAndConverter both = new MockPsmAndConverter(address(dai), address(usdc), address(usds), 6);
        _expectBadPeg(
            _config(address(usds), address(usdc)),
            PegModuleStep({
                kind: PegModuleKind.LitePsm, module: address(both), wrapper: address(both), intermediate: address(dai)
            })
        );
    }

    // ─── Callback while a hop is in progress (REQ-ROUTE-013) ───

    // TEST-046 verifies: REQ-ROUTE-013, REQ-ROUTE-029, REQ-ROUTE-033, INV-040
    // Sources: 2.12 REQ-ROUTE-013, swap-routes review (callback refusal during a hop)
    /// @notice While hop 0 is in progress, the route's own hop-1 pool calls the callback (through the hook of the
    /// token hop 0 pays out): it is not the hop's pool, so the call reverts `InvalidCallback` and the swap fails.
    function test_TEST_046_otherRoutePoolCannotCallBackDuringHop() public {
        MockCLPool usdtDai = _clPool(usdt, dai, 1e12, 1);
        MockCLPool daiUsdc = _clPool(dai, usdc, 1, 1e12);
        DexPathRoute route = new DexPathRoute(
            _config(address(usdt), address(usdc)),
            _hops2(_clHop(address(usdtDai), address(dai)), _clHop(address(daiUsdc), address(usdc)))
        );
        dai.setHook(address(daiUsdc), abi.encodeCall(MockCLPool.poke, (address(route), 1e18, 1e18)));
        usdt.mint(address(swapper), 1e6);
        vm.expectRevert(ISettlementRoute.InvalidCallback.selector);
        swapper.swapUnderLock(route, 1e6, 1);
    }

    // ─── Helpers ───

    function _expectBad(
        RouteConfig memory config,
        DexHop[] memory hops
    ) internal {
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        new DexPathRoute(config, hops);
    }

    function _expectBadPeg(
        RouteConfig memory config,
        PegModuleStep memory step
    ) internal {
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        new PegModuleRoute(config, step);
    }
}
