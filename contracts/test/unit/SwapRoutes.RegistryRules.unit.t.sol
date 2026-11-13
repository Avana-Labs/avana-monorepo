// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {DexPathRoute} from "../../src/liquidation/settlement-routes/DexPathRoute.sol";
import {DexHop, HopKind} from "../../src/liquidation/settlement-routes/types/DexHop.sol";
import {RouteConfig} from "../../src/liquidation/settlement-routes/types/RouteConfig.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {DebtReserveDef} from "../../src/policy/market-registry/types/DebtReserveDef.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {
    RegistryCoverageSpokeMock,
    RegistryDebtOracleMock,
    RegistryTokenMock
} from "../utils/mocks/MarketRegistryMocks.sol";
import {MockCLPool, MockPoolFactory} from "../utils/mocks/SwapRouteMocks.sol";

/// @title SwapRoutesRegistryRulesUnitTest
/// @notice The MarketRegistry's route rules of 2.12 applied to real DexPath route contracts (not route stand-ins): each
/// route is a deployed `DexPathRoute` whose hops are concentrated-liquidity pools of a pinned factory, and its
/// `tokenIn`, `tokenOut`, `LP_VAULT_SWAP`, token-class mask and `dependencies()` (its hop pools) are the route's own.
/// The market's own pool is a pool of the same factory, so a route can name it. Covered: no route through the market's
/// own pool and the `setRoute` refusals (REQ-ROUTE-004, REQ-ROUTE-030); activation only with an Active primary and
/// backup from every pool token into every debt asset (REQ-ROUTE-001); usability is the slot's Active status and
/// disable and restore act on either slot alike (REQ-ROUTE-021, REQ-ROUTE-038); a debt reserve is enabled only once
/// every liquidatable market of the Spoke has both routes into it (REQ-ROUTE-036).
contract SwapRoutesRegistryRulesUnitTest is MarketRegistryFixture {
    uint256 internal constant DAI_RESERVE = 7;
    uint256 internal constant DAI_ASSET = 4;

    MockPoolFactory internal v3;
    MockCLPool internal ownPool;
    Lock internal routeLock;
    RegistryTokenMock internal dai;
    uint256 internal id;
    address internal vaultToken;

    function setUp() public {
        _setUpWorld();
        // The registry's token stand-ins expose Tether's fee-rate switch, which a route refuses to pay into a pool;
        // the launch stables here have none, so the read reverts as it does on a token without the switch.
        _noFeeSwitch(address(usdc));
        _noFeeSwitch(address(usdt));
        _noFeeSwitch(address(gho));
        v3 = new MockPoolFactory();
        routeLock = new Lock(address(adapterMock), address(lpVaultSwap));
        ownPool = _pool(address(usdc), address(usdt));
        pool = address(ownPool);
        (id, vaultToken,) = _listMarket();
    }

    function _noFeeSwitch(
        address token
    ) internal {
        vm.mockCallRevert(token, abi.encodeWithSignature("basisPointsRate()"), "");
    }

    function _pool(
        address a,
        address b
    ) internal returns (MockCLPool p) {
        p = new MockCLPool(a, b);
        v3.register(address(p));
    }

    function _config(
        address tokenIn,
        address tokenOut
    ) internal view returns (RouteConfig memory c) {
        c = RouteConfig({
            lpVaultSwap: address(lpVaultSwap),
            lock: address(routeLock),
            aaveAdapter: address(adapterMock),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            tokenClassMask: 1 << 1,
            uniswapV3Factory: address(v3),
            slipstreamFactory: address(0),
            curveFactory: address(0),
            curveLegacyPools: new address[](0)
        });
    }

    /// @dev A one-hop route `tokenIn → tokenOut` through a new pool of the pinned factory.
    function _route(
        address tokenIn,
        address tokenOut
    ) internal returns (address) {
        return _routeVia(tokenIn, tokenOut, _pool(tokenIn, tokenOut));
    }

    function _routeVia(
        address tokenIn,
        address tokenOut,
        MockCLPool p
    ) internal returns (address) {
        DexHop[] memory hops = new DexHop[](1);
        hops[0] = DexHop({kind: HopKind.ConcentratedLiquidity, pool: address(p), tokenOut: tokenOut, i: 0, j: 0});
        return address(new DexPathRoute(_config(tokenIn, tokenOut), hops));
    }

    function _set(
        address token,
        address asset,
        uint8 kind,
        address route
    ) internal {
        vm.prank(address(timelock));
        registry.setRoute(id, token, asset, kind, route);
    }

    function _expectInvalid(
        address token,
        address asset,
        uint8 kind,
        address route
    ) internal {
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.InvalidRoute.selector);
        registry.setRoute(id, token, asset, kind, route);
    }

    /// @notice The Aave payload, caps and ParameterStore values of the market, without any route.
    function _prepareWithoutRoutes() internal {
        hub.setAsset(vaultToken, VT_ASSET);
        hub.setSpokeConfig(VT_ASSET, address(spoke), 2_000_000, 0);
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (vaultToken, address(hub), uint16(VT_ASSET), 18);
        IAaveV4Spoke.ReserveConfig memory c;
        IAaveV4Spoke.DynamicReserveConfig memory d;
        (d.collateralFactor, d.maxLiquidationBonus) = (7500, 10_500);
        spoke.setReserve(VT_RESERVE, r, c, d);
        spoke.setLiquidationConfig(1.1e18, 5000);
        ps.setLiquidationExpectations(address(spoke), 1.1e18, 200);
        ps.setMarket(id, 9500, 10e8, 1_000_000e8, 100_000e8, 1e8);
    }

    function _routesErr() internal view returns (bytes memory) {
        return abi.encodeWithSelector(IMarketRegistryErrors.ActivationCheckFailed.selector, id, bytes32("routes"));
    }

    function _activate(
        bytes memory err
    ) internal {
        vm.prank(address(timelock));
        if (err.length != 0) vm.expectRevert(err);
        registry.activateMarket(id);
    }

    /// @notice A real route that swaps through the market's own pool on any hop is refused in either slot; so are a
    /// route of another token, a route into another asset, and a backup that shares a pool with the primary. A route
    /// through other pools is accepted and reported usable.
    // TEST-054 verifies: REQ-ROUTE-004, REQ-ROUTE-030, REQ-ROUTE-017
    function test_TEST_054_realRouteThroughOwnPoolRefused() public {
        MockCLPool usdtGho = _pool(address(usdt), address(gho));
        DexHop[] memory hops = new DexHop[](2);
        hops[0] =
            DexHop({kind: HopKind.ConcentratedLiquidity, pool: address(ownPool), tokenOut: address(usdt), i: 0, j: 0});
        hops[1] =
            DexHop({kind: HopKind.ConcentratedLiquidity, pool: address(usdtGho), tokenOut: address(gho), i: 0, j: 0});
        address viaOwnPool = address(new DexPathRoute(_config(address(usdc), address(gho)), hops));
        _expectInvalid(address(usdc), address(gho), 0, viaOwnPool);
        _expectInvalid(address(usdc), address(gho), 1, viaOwnPool);
        address direct = _routeVia(address(usdc), address(usdt), ownPool);
        _expectInvalid(address(usdt), address(usdc), 0, _routeVia(address(usdt), address(usdc), ownPool));

        _expectInvalid(address(usdc), address(gho), 0, _route(address(usdt), address(gho)));
        _expectInvalid(address(usdc), address(gho), 0, direct);

        MockCLPool shared = _pool(address(usdc), address(gho));
        address primary = _routeVia(address(usdc), address(gho), shared);
        _set(address(usdc), address(gho), 0, primary);
        _expectInvalid(address(usdc), address(gho), 1, primary);
        _expectInvalid(address(usdc), address(gho), 1, _routeVia(address(usdc), address(gho), shared));
        address backup = _route(address(usdc), address(gho));
        _set(address(usdc), address(gho), 1, backup);
        (address r, bool usable) = registry.getRoute(id, address(usdc), address(gho), 1);
        assertEq(r, backup, "backup set");
        assertTrue(usable, "Active");
    }

    /// @notice Activation needs an Active primary and backup from each pool token into GHO: with any one of the four
    /// real routes missing it fails `routes`; with all four it passes only while every slot is Active. Disabling either
    /// slot makes `getRoute` report it unusable and activation fail again; restoring it makes it usable again.
    // TEST-054 verifies: REQ-ROUTE-001, REQ-ROUTE-021, REQ-ROUTE-038
    function test_TEST_054_activationNeedsBothRealRoutesPerToken() public {
        _prepareWithoutRoutes();
        address[4] memory routes = [
            _route(address(usdc), address(gho)),
            _route(address(usdc), address(gho)),
            _route(address(usdt), address(gho)),
            _route(address(usdt), address(gho))
        ];
        address[2] memory toks = [address(usdc), address(usdt)];
        for (uint256 skip = 0; skip < 4; ++skip) {
            uint256 snapshot = vm.snapshotState();
            for (uint256 k = 0; k < 4; ++k) {
                if (k != skip) _set(toks[k / 2], address(gho), uint8(k % 2), routes[k]);
            }
            _activate(_routesErr());
            vm.revertToState(snapshot);
        }
        for (uint256 k = 0; k < 4; ++k) {
            _set(toks[k / 2], address(gho), uint8(k % 2), routes[k]);
        }
        for (uint8 kind = 0; kind < 2; ++kind) {
            vm.prank(address(timelock));
            registry.disableRoute(id, address(usdt), address(gho), kind);
            (address r, bool usable) = registry.getRoute(id, address(usdt), address(gho), kind);
            assertEq(r, routes[2 + kind], "the slot keeps its route");
            assertFalse(usable, "a disabled slot is unusable");
            _activate(_routesErr());
            vm.prank(address(timelock));
            registry.restoreRoute(id, address(usdt), address(gho), kind, routes[2 + kind]);
            (, usable) = registry.getRoute(id, address(usdt), address(gho), kind);
            assertTrue(usable, "restored");
        }
        _activate("");
    }

    /// @notice With the market Active on GHO, enabling a DAI reserve on its Spoke reverts `LivenessBound` for that
    /// market until both real routes from each pool token into DAI are set, and then succeeds.
    // TEST-245 verifies: REQ-ROUTE-036, REQ-ROUTE-001, REQ-MREG-032
    function test_TEST_245_debtReserveEnabledOnlyWithBothRealRoutes() public {
        _prepareWithoutRoutes();
        _set(address(usdc), address(gho), 0, _route(address(usdc), address(gho)));
        _set(address(usdc), address(gho), 1, _route(address(usdc), address(gho)));
        _set(address(usdt), address(gho), 0, _route(address(usdt), address(gho)));
        _set(address(usdt), address(gho), 1, _route(address(usdt), address(gho)));
        _activate("");
        DebtReserveDef memory def = _listDai();
        bytes memory bound =
            abi.encodeWithSelector(IMarketRegistryErrors.LivenessBound.selector, address(spoke), id, DAI_RESERVE);

        vm.prank(address(timelock));
        vm.expectRevert(bound);
        registry.enableDebtReserve(address(spoke), def);
        _set(address(usdc), address(dai), 0, _route(address(usdc), address(dai)));
        _set(address(usdc), address(dai), 1, _route(address(usdc), address(dai)));
        _set(address(usdt), address(dai), 0, _route(address(usdt), address(dai)));
        vm.prank(address(timelock));
        vm.expectRevert(bound);
        registry.enableDebtReserve(address(spoke), def);
        _set(address(usdt), address(dai), 1, _route(address(usdt), address(dai)));
        vm.prank(address(timelock));
        registry.enableDebtReserve(address(spoke), def);
        assertTrue(registry.isApprovedDebtReserve(address(spoke), DAI_RESERVE), "enabled with every route in place");
    }

    function _listDai() internal returns (DebtReserveDef memory def) {
        dai = new RegistryTokenMock(18);
        _noFeeSwitch(address(dai));
        _listToken(address(dai), "dai");
        RegistryDebtOracleMock daiOracle = new RegistryDebtOracleMock(address(dai), address(registry), address(ps));
        RegistryCoverageSpokeMock daiCoverage = new RegistryCoverageSpokeMock(address(hub), address(dai), DAI_ASSET);
        daiCoverage.setFunded(1e30, false);
        hub.setAsset(address(dai), DAI_ASSET);
        hub.setSpokeConfig(DAI_ASSET, address(spoke), 0, 1_000_000);
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (address(dai), address(hub), uint16(DAI_ASSET), 18);
        IAaveV4Spoke.ReserveConfig memory c;
        c.borrowable = true;
        IAaveV4Spoke.DynamicReserveConfig memory d;
        spoke.setReserve(DAI_RESERVE, r, c, d);
        aaveOracle.setSource(DAI_RESERVE, address(daiOracle));
        ps.setStressRise(address(dai), 500);
        vm.startPrank(address(timelock));
        registry.setCoverageSpoke(address(hub), address(dai), address(daiCoverage));
        registry.recordCreditLine(address(hub), address(dai), 2_000_000);
        vm.stopPrank();
        def = DebtReserveDef({
            reserveId: DAI_RESERVE,
            asset: address(dai),
            decimals: 18,
            fundingHub: address(hub),
            hubAssetId: DAI_ASSET,
            priceSource: address(daiOracle),
            fixedPrice: false,
            coverageSpoke: address(daiCoverage),
            crossHub: false,
            approved: false
        });
    }
}
