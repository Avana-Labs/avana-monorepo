// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PoolKeying} from "../../src/amm/types/AmmTypes.sol";
import {IMarketRegistry} from "../../src/policy/market-registry/IMarketRegistry.sol";
import {IMarketRegistryBase} from "../../src/policy/market-registry/IMarketRegistryBase.sol";
import {IssuerProbe} from "../../src/policy/market-registry/types/IssuerProbe.sol";
import {TokenDef} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {MarketDef} from "../../src/types/MarketTypes.sol";
import {PositionShape, ShapeKind} from "../../src/types/PositionTypes.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {
    RegistryLPOracleMock,
    RegistryRouteMock,
    RegistryTetherMock,
    RegistryTokenMock
} from "../utils/mocks/MarketRegistryMocks.sol";

/// @notice Swap routes: slot checks, peg-module and fee-switch exclusions, disable and restore.
contract MarketRegistryRoutesUnitTest is MarketRegistryFixture {
    uint256 internal id;

    function setUp() public {
        _setUpWorld();
        (id,,) = _listMarket();
    }

    function _set(
        address token,
        address asset,
        uint8 kind,
        address route
    ) internal {
        vm.prank(governor);
        registry.setRoute(id, token, asset, kind, route);
    }

    function _expectInvalidRoute(
        address token,
        address asset,
        uint8 kind,
        address route
    ) internal {
        vm.prank(governor);
        vm.expectRevert(IMarketRegistryBase.InvalidRoute.selector);
        registry.setRoute(id, token, asset, kind, route);
    }

    function _routeWithDeps(
        address tokenIn,
        address tokenOut,
        address a,
        address b
    ) internal returns (RegistryRouteMock) {
        address[] memory deps = new address[](2);
        (deps[0], deps[1]) = (a, b);
        return new RegistryRouteMock(tokenIn, tokenOut, address(lpVaultSwap), deps);
    }

    // TEST-054 verifies: REQ-CONFIG-039, REQ-CONFIG-040, REQ-CONFIG-059, REQ-CONFIG-060, REQ-CONFIG-063, REQ-MREG-014, Q-379, REQ-ACCESS-046, REQ-ROUTE-004, REQ-ROUTE-017, REQ-ROUTE-030
    // Sources: 5.1 TEST-054, TEST-252
    function test_TEST_054_setRouteChecks() public {
        address usdcIn = address(usdc);
        address dex = makeAddr("dexA");
        vm.startPrank(governor);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.UnknownMarket.selector, 42));
        registry.setRoute(42, usdcIn, address(gho), 0, alice);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.TokenNotListed.selector, address(gho)));
        registry.setRoute(id, address(gho), address(usdc), 0, alice);
        RegistryTokenMock stray = new RegistryTokenMock(18);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.TokenNotListed.selector, address(stray)));
        registry.setRoute(id, usdcIn, address(stray), 0, alice);
        vm.stopPrank();
        _expectInvalidRoute(usdcIn, address(gho), 2, address(_routeWithDeps(usdcIn, address(gho), dex, dex)));
        _expectInvalidRoute(usdcIn, address(gho), 0, address(0));
        _expectInvalidRoute(usdcIn, usdcIn, 0, address(_routeWithDeps(usdcIn, usdcIn, dex, dex)));
        _expectInvalidRoute(usdcIn, address(gho), 0, address(_routeWithDeps(address(usdt), address(gho), dex, dex)));
        _expectInvalidRoute(usdcIn, address(gho), 0, address(_routeWithDeps(usdcIn, address(usdt), dex, dex)));
        RegistryRouteMock wrongSwap = new RegistryRouteMock(usdcIn, address(gho), alice, new address[](0));
        _expectInvalidRoute(usdcIn, address(gho), 0, address(wrongSwap));
        RegistryRouteMock noClass = _routeWithDeps(usdcIn, address(gho), dex, dex);
        noClass.setClassOk(false);
        _expectInvalidRoute(usdcIn, address(gho), 0, address(noClass));
        // Through the market's own pool, or its LPVault.
        _expectInvalidRoute(usdcIn, address(gho), 1, address(_routeWithDeps(usdcIn, address(gho), dex, pool)));
        _expectInvalidRoute(
            usdcIn, address(gho), 0, address(_routeWithDeps(usdcIn, address(gho), address(lpVault), dex))
        );
        (address none, bool usable) = registry.getRoute(id, usdcIn, address(gho), 0);
        assertEq(none, address(0));
        assertFalse(usable);
        RegistryRouteMock primary = _routeWithDeps(usdcIn, address(gho), dex, makeAddr("router"));
        vm.expectEmit(address(registry));
        emit IMarketRegistryBase.RouteSet(id, usdcIn, address(gho), 0, address(primary));
        _set(usdcIn, address(gho), 0, address(primary));
        // The backup must be another contract sharing no dependency with the primary.
        _expectInvalidRoute(usdcIn, address(gho), 1, address(primary));
        _expectInvalidRoute(
            usdcIn, address(gho), 1, address(_routeWithDeps(usdcIn, address(gho), makeAddr("dexB"), dex))
        );
        RegistryRouteMock backup = _routeWithDeps(usdcIn, address(gho), makeAddr("dexB"), makeAddr("router2"));
        _set(usdcIn, address(gho), 1, address(backup));
        (address r, bool ok) = registry.getRoute(id, usdcIn, address(gho), 1);
        assertEq(r, address(backup));
        assertTrue(ok);
    }

    // TEST-221 verifies: REQ-ROUTE-003, REQ-ROUTE-005, REQ-ROUTE-008
    // Sources: 2.12 REQ-ROUTE-008 (a token with a transfer-fee switch is never paid into a pool that needs the exact
    // amount)
    /// @notice A route that pays a listed token with the `UsdtFeeRate` issuer probe into a concentrated-liquidity hop or
    /// a GSM deposit is refused in either slot, whatever the token's current rate; the same path through a Curve hop
    /// (not in `exactAmountInputs`) is accepted, and so is a route whose exact-amount inputs carry no fee switch.
    function test_TEST_221_feeSwitchTokenNeverEntersAnExactAmountLeg() public {
        RegistryTetherMock tether = new RegistryTetherMock();
        (address[] memory p, address[] memory a) = _routes("tether");
        TokenDef memory td = _tokenDef(p, a);
        td.issuerProbe = IssuerProbe.UsdtFeeRate;
        vm.prank(governor);
        registry.listToken(address(tether), td);
        address usdcIn = address(usdc);
        address[] memory exact = new address[](2);
        (exact[0], exact[1]) = (usdcIn, address(tether));
        RegistryRouteMock viaClPool = _routeWithDeps(usdcIn, address(gho), makeAddr("clA"), makeAddr("clB"));
        viaClPool.setExactAmountInputs(exact);
        _expectInvalidRoute(usdcIn, address(gho), 0, address(viaClPool));
        _expectInvalidRoute(usdcIn, address(gho), 1, address(viaClPool));
        // The same tokens through Curve hops: only USDC enters a pool that needs the exact amount.
        address[] memory onlyUsdc = new address[](1);
        onlyUsdc[0] = usdcIn;
        RegistryRouteMock viaCurve = _routeWithDeps(usdcIn, address(gho), makeAddr("curveA"), makeAddr("clC"));
        viaCurve.setExactAmountInputs(onlyUsdc);
        _set(usdcIn, address(gho), 0, address(viaCurve));
        (address r, bool usable) = registry.getRoute(id, usdcIn, address(gho), 0);
        assertEq(r, address(viaCurve));
        assertTrue(usable);
    }

    // TEST-054 verifies: REQ-ROUTE-003
    // The primary and the backup of a slot share no intermediate token other than the debt asset: a backup through
    // the primary's USDT hop is refused, one that shares only the debt asset (GHO) is accepted.
    function test_TEST_054_backupSharesNoIntermediateButTheDebtAsset() public {
        address usdcIn = address(usdc);
        address[] memory primaryVia = new address[](2);
        (primaryVia[0], primaryVia[1]) = (address(usdt), address(gho));
        RegistryRouteMock primary = _routeWithDeps(usdcIn, address(gho), makeAddr("dexI1"), makeAddr("dexI2"));
        primary.setIntermediates(primaryVia);
        _set(usdcIn, address(gho), 0, address(primary));
        address[] memory viaUsdt = new address[](1);
        viaUsdt[0] = address(usdt);
        RegistryRouteMock sharesUsdt = _routeWithDeps(usdcIn, address(gho), makeAddr("dexI3"), makeAddr("dexI4"));
        sharesUsdt.setIntermediates(viaUsdt);
        _expectInvalidRoute(usdcIn, address(gho), 1, address(sharesUsdt));
        address[] memory viaGho = new address[](1);
        viaGho[0] = address(gho);
        RegistryRouteMock sharesDebtAsset = _routeWithDeps(usdcIn, address(gho), makeAddr("dexI5"), makeAddr("dexI6"));
        sharesDebtAsset.setIntermediates(viaGho);
        _set(usdcIn, address(gho), 1, address(sharesDebtAsset));
    }

    // TEST-054 verifies: REQ-CONFIG-040, REQ-CONFIG-025, Q-187
    function test_TEST_054_backupAvoidsPegModules() public {
        RegistryTokenMock dai = new RegistryTokenMock(18);
        (address[] memory p, address[] memory a) = _routes("dai");
        TokenDef memory td = _tokenDef(p, a);
        address psm = makeAddr("litePsm");
        td.pegModule = psm;
        vm.prank(governor);
        registry.listToken(address(dai), td);
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (address(usdc), address(dai));
        lpVault.setPoolTokens(toks, 18);
        PositionShape memory wide = PositionShape(ShapeKind.TickRange, -100, 100);
        (address vt2, RegistryLPOracleMock o2) = _deployTokenAndOracle(2, wide);
        MarketDef memory d = _marketDef(vt2, address(o2));
        d.shape = wide;
        vm.prank(governor);
        uint256 id2 = registry.listCollateralMarket(d);
        address usdcIn = address(usdc);
        RegistryRouteMock viaPsm = _routeWithDeps(usdcIn, address(gho), psm, makeAddr("dexP"));
        // The backup of a market holding DAI never passes through DAI's peg module.
        vm.prank(governor);
        vm.expectRevert(IMarketRegistryBase.InvalidRoute.selector);
        registry.setRoute(id2, usdcIn, address(gho), 1, address(viaPsm));
        // A primary may pass through it; the backup then uses other venues.
        vm.prank(governor);
        registry.setRoute(id2, usdcIn, address(gho), 0, address(viaPsm));
        RegistryRouteMock backup = _routeWithDeps(usdcIn, address(gho), makeAddr("dexQ"), makeAddr("dexR"));
        vm.prank(governor);
        registry.setRoute(id2, usdcIn, address(gho), 1, address(backup));
        // On the USDC/USDT market, where no pool token names that module, a backup through it is accepted.
        RegistryRouteMock viaPsm2 = _routeWithDeps(usdcIn, address(gho), psm, makeAddr("dexS"));
        _set(usdcIn, address(gho), 1, address(viaPsm2));
    }

    // TEST-054 verifies: REQ-CONFIG-061, REQ-CONFIG-062, REQ-MREG-012, Q-151, Q-228, REQ-ACCESS-047, REQ-ACCESS-048, REQ-ACCESS-127, REQ-ACCESS-093, REQ-ROUTE-017, REQ-ROUTE-018, REQ-ROUTE-019, REQ-ROUTE-021
    function test_TEST_054_disableAndRestore() public {
        address usdcIn = address(usdc);
        address r1 = _setRoute(id, usdcIn, address(gho), 0, "dexA");
        address r2 = address(_newRoute(usdcIn, address(gho), "dexZ"));
        vm.startPrank(governor);
        vm.expectRevert(IMarketRegistryBase.InvalidRoute.selector);
        registry.disableRoute(id, usdcIn, address(gho), 1);
        vm.expectEmit(address(registry));
        emit IMarketRegistryBase.RouteDisabled(id, usdcIn, address(gho), 0, governor);
        registry.disableRoute(id, usdcIn, address(gho), 0);
        (, bool usable) = registry.getRoute(id, usdcIn, address(gho), 0);
        assertFalse(usable);
        vm.expectRevert(IMarketRegistryBase.NotPreviouslyApproved.selector);
        registry.restoreRoute(id, usdcIn, address(gho), 0, r2);
        vm.expectEmit(address(registry));
        emit IMarketRegistryBase.RouteRestored(id, usdcIn, address(gho), 0, r1);
        registry.restoreRoute(id, usdcIn, address(gho), 0, r1);
        (, usable) = registry.getRoute(id, usdcIn, address(gho), 0);
        assertTrue(usable);
        // A route that `setRoute` replaced leaves the approved set (REQ-ROUTE-017): it cannot come back at the short
        // delay, only through `setRoute` again; the new route is restorable after a disable.
        registry.setRoute(id, usdcIn, address(gho), 0, r2);
        vm.expectRevert(IMarketRegistryBase.NotPreviouslyApproved.selector);
        registry.restoreRoute(id, usdcIn, address(gho), 0, r1);
        registry.disableRoute(id, usdcIn, address(gho), 0);
        registry.restoreRoute(id, usdcIn, address(gho), 0, r2);
        registry.setRoute(id, usdcIn, address(gho), 0, r1);
        vm.stopPrank();
        (address cur,) = registry.getRoute(id, usdcIn, address(gho), 0);
        assertEq(cur, r1);
    }

    // TEST-054 verifies: REQ-ROUTE-017, REQ-CONFIG-060, REQ-CONFIG-062, ATTACK-201
    /// @notice ATTACK-201: a route replaced for cause cannot be restored at the short delay, whether the replacement is
    /// active or disabled; setting the same route again keeps it approved.
    function test_TEST_054_replacedRouteCannotBeRestored() public {
        address usdcIn = address(usdc);
        address bad = _setRoute(id, usdcIn, address(gho), 0, "dexA");
        address good = address(_newRoute(usdcIn, address(gho), "dexZ"));
        vm.startPrank(governor);
        registry.setRoute(id, usdcIn, address(gho), 0, bad);
        registry.disableRoute(id, usdcIn, address(gho), 0);
        registry.restoreRoute(id, usdcIn, address(gho), 0, bad);
        registry.setRoute(id, usdcIn, address(gho), 0, good);
        vm.expectRevert(IMarketRegistryBase.NotPreviouslyApproved.selector);
        registry.restoreRoute(id, usdcIn, address(gho), 0, bad);
        registry.disableRoute(id, usdcIn, address(gho), 0);
        vm.expectRevert(IMarketRegistryBase.NotPreviouslyApproved.selector);
        registry.restoreRoute(id, usdcIn, address(gho), 0, bad);
        registry.restoreRoute(id, usdcIn, address(gho), 0, good);
        vm.stopPrank();
        (address cur, bool usable) = registry.getRoute(id, usdcIn, address(gho), 0);
        assertEq(cur, good);
        assertTrue(usable);
    }

    // TEST-054 verifies: REQ-CONFIG-040, REQ-CONFIG-060, REQ-MREG-035, REQ-ROUTE-004, REQ-ROUTE-030
    // Sources: decisions of 2026-11-11 (a recorded AMM contract is never a route dependency, whatever the keying)
    // A market keyed by pool address refuses a route through any AMM contract recorded for its integration, as an
    // identifier-keyed market does; the world's record holds the position manager and factory.
    function test_TEST_054_addressKeyedMarketRefusesRecordedContract() public {
        address singleton = address(new RegistryTokenMock(0));
        address[] memory amm = new address[](1);
        amm[0] = singleton;
        vm.prank(governor);
        registry.recordIntegrationContracts(V3, amm);
        RegistryRouteMock viaSingleton = _routeWithDeps(address(usdc), address(gho), singleton, makeAddr("wrapper"));
        _expectInvalidRoute(address(usdc), address(gho), 0, address(viaSingleton));
        RegistryRouteMock viaNpm = _routeWithDeps(address(usdc), address(gho), makeAddr("uni"), ammPositionManager);
        _expectInvalidRoute(address(usdc), address(gho), 0, address(viaNpm));
        RegistryRouteMock viaFactory = _routeWithDeps(address(usdc), address(gho), ammFactory, makeAddr("uni"));
        _expectInvalidRoute(address(usdc), address(gho), 1, address(viaFactory));
        RegistryRouteMock elsewhere = _routeWithDeps(address(usdc), address(gho), makeAddr("curve"), makeAddr("uni"));
        _set(address(usdc), address(gho), 0, address(elsewhere));
        (address r,) = registry.getRoute(id, address(usdc), address(gho), 0);
        assertEq(r, address(elsewhere));
    }
}

/// @notice Own-pool check of a market keyed by pool identifier: the integration's LPVault declares `PoolKeying.Id`
/// before the factory records it, as an AMM protocol with a singleton pool manager would.
contract MarketRegistryRoutesIdKeyedUnitTest is MarketRegistryFixture {
    function setUp() public {
        _setUpWorld();
    }

    /// @dev The test records the singleton itself, so the world records nothing.
    function _recordAmmContracts() internal override {}

    function _beforeIntegrationRegistered() internal override {
        lpVault.setKeying(PoolKeying.Id, ShapeKind.FullPool);
    }

    function _routeWithDeps(
        address tokenIn,
        address tokenOut,
        address a,
        address b
    ) internal returns (RegistryRouteMock) {
        address[] memory deps = new address[](2);
        (deps[0], deps[1]) = (a, b);
        return new RegistryRouteMock(tokenIn, tokenOut, address(lpVaultSwap), deps);
    }

    // TEST-054 verifies: REQ-CONFIG-040, REQ-CONFIG-060, REQ-MREG-020, REQ-MREG-035, REQ-ROUTE-004
    // Sources: MarketRegistry review 2026-11-10 finding 5 (own-pool check of a market keyed by pool id)
    function test_TEST_054_idKeyedMarketRefusesItsSingleton() public {
        uint256 idm = registry.marketCount() + 1;
        bytes32 poolId = keccak256("usdc-usdt-v4");
        PositionShape memory full = PositionShape(ShapeKind.FullPool, 0, 0);
        RegistryLPOracleMock o = new RegistryLPOracleMock(idm, address(lpVault));
        vm.prank(governor);
        address vtm = factory.deployVaultToken(
            V3, address(0), poolId, full, address(hub), address(spoke), idm, address(o), 18, "Avana v4", "avV4"
        );
        MarketDef memory d = _marketDef(vtm, address(o));
        (d.pool, d.poolId, d.shape) = (address(0), poolId, full);
        vm.prank(governor);
        assertEq(registry.listCollateralMarket(d), idm);
        address singleton = address(new RegistryTokenMock(0));
        RegistryRouteMock viaSingleton = _routeWithDeps(address(usdc), address(gho), singleton, makeAddr("wrapper"));
        RegistryRouteMock elsewhere = _routeWithDeps(address(usdc), address(gho), makeAddr("curve"), makeAddr("uni"));
        // With no AMM contract recorded for the integration, every route of the market is refused (fail closed).
        vm.prank(governor);
        vm.expectRevert(IMarketRegistryBase.InvalidRoute.selector);
        registry.setRoute(idm, address(usdc), address(gho), 0, address(elsewhere));
        address[] memory amm = new address[](1);
        amm[0] = singleton;
        vm.prank(governor);
        registry.recordIntegrationContracts(V3, amm);
        // Recorded but not finalized: still refused (REQ-MREG-035).
        vm.prank(governor);
        vm.expectRevert(IMarketRegistryBase.InvalidRoute.selector);
        registry.setRoute(idm, address(usdc), address(gho), 0, address(elsewhere));
        vm.prank(governor);
        registry.finalizeIntegrationContracts(V3);
        // A route through the singleton cannot show it avoids the market's own pool id.
        vm.prank(governor);
        vm.expectRevert(IMarketRegistryBase.InvalidRoute.selector);
        registry.setRoute(idm, address(usdc), address(gho), 0, address(viaSingleton));
        vm.prank(governor);
        registry.setRoute(idm, address(usdc), address(gho), 0, address(elsewhere));
    }
}
