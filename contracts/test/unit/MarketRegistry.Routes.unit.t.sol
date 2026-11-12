// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PoolKeying} from "../../src/amm/types/PoolKeying.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {IMarketRegistryEvents} from "../../src/policy/market-registry/IMarketRegistryEvents.sol";
import {IMarketRegistrySafetyEvents} from "../../src/policy/market-registry/IMarketRegistrySafetyEvents.sol";
import {IMarketRegistryStandby} from "../../src/policy/market-registry/IMarketRegistryStandby.sol";
import {IssuerProbe} from "../../src/policy/market-registry/types/IssuerProbe.sol";
import {TokenDef} from "../../src/policy/market-registry/types/TokenDef.sol";
import {MarketDef} from "../../src/types/MarketDef.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {
    RegistryLPOracleMock,
    RegistryRouteMock,
    RegistryTetherMock,
    RegistryTokenMock
} from "../utils/mocks/MarketRegistryMocks.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Swap routes and the standby price-route switch.
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
        vm.prank(address(timelock));
        registry.setRoute(id, token, asset, kind, route);
    }

    function _expectInvalidRoute(
        address token,
        address asset,
        uint8 kind,
        address route
    ) internal {
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.InvalidRoute.selector);
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

    // TEST-054 verifies: REQ-CONFIG-039, REQ-CONFIG-040, REQ-CONFIG-059, REQ-CONFIG-060, REQ-CONFIG-063, REQ-MREG-014, Q-379
    // Sources: 5.1 TEST-054, TEST-252
    function test_TEST_054_setRouteChecks() public {
        address usdcIn = address(usdc);
        address dex = makeAddr("dexA");
        vm.startPrank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.UnknownMarket.selector, 42));
        registry.setRoute(42, usdcIn, address(gho), 0, alice);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.TokenNotListed.selector, address(gho)));
        registry.setRoute(id, address(gho), address(usdc), 0, alice);
        RegistryTokenMock stray = new RegistryTokenMock(18);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.TokenNotListed.selector, address(stray)));
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
        emit IMarketRegistryEvents.RouteSet(id, usdcIn, address(gho), 0, address(primary));
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
        (address[] memory p, address[] memory a, address[] memory s) = _routes("tether");
        TokenDef memory td = _tokenDef(p, a, s);
        td.issuerProbe = IssuerProbe.UsdtFeeRate;
        ps.setTolerance(address(tether), 100, 50);
        vm.prank(address(timelock));
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

    // TEST-054 verifies: REQ-CONFIG-040, REQ-CONFIG-025, Q-187
    function test_TEST_054_backupAvoidsPegModules() public {
        RegistryTokenMock dai = new RegistryTokenMock(18);
        (address[] memory p, address[] memory a, address[] memory s) = _routes("dai");
        TokenDef memory td = _tokenDef(p, a, s);
        address psm = makeAddr("litePsm");
        td.pegModule = psm;
        vm.prank(address(timelock));
        registry.listToken(address(dai), td);
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (address(usdc), address(dai));
        lpVault.setPoolTokens(toks, 18);
        PositionShape memory wide = PositionShape(ShapeKind.TickRange, -100, 100);
        (address vt2, RegistryLPOracleMock o2) = _deployTokenAndOracle(2, wide);
        MarketDef memory d = _marketDef(vt2, address(o2));
        d.shape = wide;
        vm.prank(address(timelock));
        uint256 id2 = registry.listCollateralMarket(d);
        address usdcIn = address(usdc);
        RegistryRouteMock viaPsm = _routeWithDeps(usdcIn, address(gho), psm, makeAddr("dexP"));
        // The backup of a market holding DAI never passes through DAI's peg module.
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.InvalidRoute.selector);
        registry.setRoute(id2, usdcIn, address(gho), 1, address(viaPsm));
        // A primary may pass through it; the backup then uses other venues.
        vm.prank(address(timelock));
        registry.setRoute(id2, usdcIn, address(gho), 0, address(viaPsm));
        RegistryRouteMock backup = _routeWithDeps(usdcIn, address(gho), makeAddr("dexQ"), makeAddr("dexR"));
        vm.prank(address(timelock));
        registry.setRoute(id2, usdcIn, address(gho), 1, address(backup));
        // On the USDC/USDT market, where no pool token names that module, a backup through it is accepted.
        RegistryRouteMock viaPsm2 = _routeWithDeps(usdcIn, address(gho), psm, makeAddr("dexS"));
        _set(usdcIn, address(gho), 1, address(viaPsm2));
    }

    // TEST-054 verifies: REQ-CONFIG-061, REQ-CONFIG-062, REQ-MREG-012, Q-151, Q-228
    function test_TEST_054_disableAndRestore() public {
        address usdcIn = address(usdc);
        address r1 = _setRoute(id, usdcIn, address(gho), 0, "dexA");
        address r2 = address(_newRoute(usdcIn, address(gho), "dexZ"));
        vm.startPrank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.InvalidRoute.selector);
        registry.disableRoute(id, usdcIn, address(gho), 1);
        vm.expectEmit(address(registry));
        emit IMarketRegistryEvents.RouteDisabled(id, usdcIn, address(gho), 0, address(timelock));
        registry.disableRoute(id, usdcIn, address(gho), 0);
        (, bool usable) = registry.getRoute(id, usdcIn, address(gho), 0);
        assertFalse(usable);
        vm.expectRevert(IMarketRegistryErrors.NotPreviouslyApproved.selector);
        registry.restoreRoute(id, usdcIn, address(gho), 0, r2);
        vm.expectEmit(address(registry));
        emit IMarketRegistryEvents.RouteRestored(id, usdcIn, address(gho), 0, r1);
        registry.restoreRoute(id, usdcIn, address(gho), 0, r1);
        (, usable) = registry.getRoute(id, usdcIn, address(gho), 0);
        assertTrue(usable);
        // A route approved before stays restorable after being replaced.
        registry.setRoute(id, usdcIn, address(gho), 0, r2);
        registry.restoreRoute(id, usdcIn, address(gho), 0, r1);
        vm.stopPrank();
        (address cur,) = registry.getRoute(id, usdcIn, address(gho), 0);
        assertEq(cur, r1);
    }

    // TEST-231 verifies: REQ-MREG-028, REQ-CONFIG-009, REQ-CONFIG-026, Q-248, Q-262, Q-263
    // Sources: 5.1 TEST-231
    function test_TEST_231_standbySwitch() public {
        address t = address(usdc);
        TokenDef memory def = registry.getToken(t);
        vm.startPrank(emergencyGuardian);
        vm.expectRevert(IMarketRegistryErrors.InvalidRouteSlot.selector);
        registry.useStandbyRoute(t, RouteSlot.None);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.TokenNotListed.selector, alice));
        registry.useStandbyRoute(alice, RouteSlot.Primary);
        vm.expectEmit(address(registry));
        emit IMarketRegistrySafetyEvents.StandbyRouteActivated(t, RouteSlot.Primary, emergencyGuardian);
        registry.useStandbyRoute(t, RouteSlot.Primary);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.StandbyAlreadyActive.selector, t));
        registry.useStandbyRoute(t, RouteSlot.Alternate);
        vm.stopPrank();
        assertEq(registry.priceRouteVersion(t), 1);
        (address[] memory p, address[] memory a, RouteSlot replaced) = registry.activePriceRoutes(t);
        assertEq(uint8(replaced), uint8(RouteSlot.Primary));
        assertEq(p[0], def.standbyRoute[0]);
        assertEq(a[1], def.alternateRoute[1]);
        // Only the Aave governance executor cancels at once.
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.Unauthorized.selector, address(timelock)));
        registry.cancelStandbySwitch(t);
        vm.expectEmit(address(registry));
        emit IMarketRegistrySafetyEvents.StandbySwitchCancelled(t, aaveGovernanceExecutor);
        vm.prank(aaveGovernanceExecutor);
        registry.cancelStandbySwitch(t);
        assertEq(registry.priceRouteVersion(t), 2);
        vm.prank(aaveGovernanceExecutor);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.StandbyNotActive.selector, t));
        registry.cancelStandbySwitch(t);
        // The timelock switches the alternate (short delay) and restores at the normal delay.
        vm.prank(address(timelock));
        registry.useStandbyRoute(t, RouteSlot.Alternate);
        (, a,) = registry.activePriceRoutes(t);
        assertEq(a.length, 1);
        assertEq(a[0], def.standbyRoute[0]);
        vm.prank(emergencyGuardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, emergencyGuardian, APP_ADMIN
            )
        );
        registry.restorePriceRoute(t);
        vm.expectEmit(address(registry));
        emit IMarketRegistrySafetyEvents.PriceRouteRestored(t);
        vm.prank(address(timelock));
        registry.restorePriceRoute(t);
        assertEq(registry.priceRouteVersion(t), 4);
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.StandbyNotActive.selector, t));
        registry.restorePriceRoute(t);
    }

    // TEST-231 verifies: REQ-MREG-028, Q-248, Q-263
    // Sources: MarketRegistry review 2026-11-10 finding 7 (the DAO's cancel locks the guardians' re-switch)
    function test_TEST_231_daoCancelLocksTheGuardianSwitch() public {
        address t = address(usdc);
        vm.warp(3_000_000);
        assertEq(registry.standbySwitchLockedUntil(t), 0);
        vm.prank(emergencyGuardian);
        registry.useStandbyRoute(t, RouteSlot.Primary);
        vm.prank(aaveGovernanceExecutor);
        registry.cancelStandbySwitch(t);
        uint256 until = block.timestamp + 5 days;
        assertEq(registry.standbySwitchLockedUntil(t), until);
        // Neither guardian can re-apply what the DAO undid, in the same block or before the lock ends.
        vm.prank(emergencyGuardian);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryStandby.StandbySwitchLocked.selector, t, until));
        registry.useStandbyRoute(t, RouteSlot.Primary);
        vm.warp(until - 1);
        vm.prank(aaveGuardian);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryStandby.StandbySwitchLocked.selector, t, until));
        registry.useStandbyRoute(t, RouteSlot.Alternate);
        // Another token is not locked.
        vm.prank(emergencyGuardian);
        registry.useStandbyRoute(address(usdt), RouteSlot.Primary);
        // From the end of the lock a guardian switches again.
        vm.warp(until);
        vm.prank(emergencyGuardian);
        registry.useStandbyRoute(t, RouteSlot.Primary);
        assertEq(registry.priceRouteVersion(t), 3);
        // The timelock's own switch (short delay, DAO-only cancel) is not locked and ends a lock.
        vm.prank(aaveGovernanceExecutor);
        registry.cancelStandbySwitch(t);
        vm.prank(address(timelock));
        registry.useStandbyRoute(t, RouteSlot.Alternate);
        assertEq(registry.standbySwitchLockedUntil(t), 0);
        vm.prank(address(timelock));
        registry.restorePriceRoute(t);
        vm.prank(emergencyGuardian);
        registry.useStandbyRoute(t, RouteSlot.Primary);
        // A new price source at the normal delay also ends a lock.
        vm.prank(aaveGovernanceExecutor);
        registry.cancelStandbySwitch(t);
        assertGt(registry.standbySwitchLockedUntil(t), block.timestamp);
        (address[] memory p, address[] memory a, address[] memory s) = _routes("usdc2");
        vm.prank(address(timelock));
        registry.setPriceSource(t, p, a, s);
        assertEq(registry.standbySwitchLockedUntil(t), 0);
        vm.prank(emergencyGuardian);
        registry.useStandbyRoute(t, RouteSlot.Primary);
    }

    // TEST-054 verifies: REQ-CONFIG-040, REQ-CONFIG-060, REQ-MREG-035
    // Sources: decisions of 2026-11-11 (a recorded AMM contract is never a route dependency, whatever the keying)
    // A market keyed by pool address refuses a route through any AMM contract recorded for its integration, as an
    // identifier-keyed market does; the world's record holds the position manager and factory.
    function test_TEST_054_addressKeyedMarketRefusesRecordedContract() public {
        address singleton = address(new RegistryTokenMock(0));
        address[] memory amm = new address[](1);
        amm[0] = singleton;
        vm.prank(address(timelock));
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

    // TEST-231 verifies: REQ-MREG-028, REQ-CONFIG-021, ATTACK-140
    function test_TEST_231_standbyThatLostItsFeedIsRefused() public {
        address t = address(usdt);
        address standbyFeed = registry.getToken(t).standbyRoute[0];
        ps.setFeed(standbyFeed, 0, 0, 0, 0);
        vm.prank(emergencyGuardian);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ListingCheckFailed.selector, bytes32("feed")));
        registry.useStandbyRoute(t, RouteSlot.Primary);
        ps.setFeed(standbyFeed, 8, 0, 25, 25);
        vm.prank(emergencyGuardian);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ListingCheckFailed.selector, bytes32("heartbeat")));
        registry.useStandbyRoute(t, RouteSlot.Primary);
        // A long published heartbeat (stablecoin feeds, 86,400 s) is accepted: there is no global ceiling.
        ps.setFeed(standbyFeed, 8, 86_400, 25, 25);
        vm.prank(emergencyGuardian);
        registry.useStandbyRoute(t, RouteSlot.Primary);
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

    // TEST-054 verifies: REQ-CONFIG-040, REQ-CONFIG-060, REQ-MREG-020, REQ-MREG-035
    // Sources: MarketRegistry review 2026-11-10 finding 5 (own-pool check of a market keyed by pool id)
    function test_TEST_054_idKeyedMarketRefusesItsSingleton() public {
        uint256 idm = registry.marketCount() + 1;
        bytes32 poolId = keccak256("usdc-usdt-v4");
        PositionShape memory full = PositionShape(ShapeKind.FullPool, 0, 0);
        RegistryLPOracleMock o = new RegistryLPOracleMock(idm, address(lpVault));
        vm.prank(address(timelock));
        address vtm = factory.deployVaultToken(
            V3, address(0), poolId, full, address(hub), address(spoke), idm, address(o), 18, "Avana v4", "avV4"
        );
        MarketDef memory d = _marketDef(vtm, address(o));
        (d.pool, d.poolId, d.shape) = (address(0), poolId, full);
        vm.prank(address(timelock));
        assertEq(registry.listCollateralMarket(d), idm);
        address singleton = address(new RegistryTokenMock(0));
        RegistryRouteMock viaSingleton = _routeWithDeps(address(usdc), address(gho), singleton, makeAddr("wrapper"));
        RegistryRouteMock elsewhere = _routeWithDeps(address(usdc), address(gho), makeAddr("curve"), makeAddr("uni"));
        // With no AMM contract recorded for the integration, every route of the market is refused (fail closed).
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.InvalidRoute.selector);
        registry.setRoute(idm, address(usdc), address(gho), 0, address(elsewhere));
        address[] memory amm = new address[](1);
        amm[0] = singleton;
        vm.prank(address(timelock));
        registry.recordIntegrationContracts(V3, amm);
        // Recorded but not finalized: still refused (REQ-MREG-035).
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.InvalidRoute.selector);
        registry.setRoute(idm, address(usdc), address(gho), 0, address(elsewhere));
        vm.prank(address(timelock));
        registry.finalizeIntegrationContracts(V3);
        // A route through the singleton cannot show it avoids the market's own pool id.
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.InvalidRoute.selector);
        registry.setRoute(idm, address(usdc), address(gho), 0, address(viaSingleton));
        vm.prank(address(timelock));
        registry.setRoute(idm, address(usdc), address(gho), 0, address(elsewhere));
    }
}
