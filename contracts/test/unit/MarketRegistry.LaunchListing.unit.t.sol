// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {IMarketRegistryEvents} from "../../src/policy/market-registry/IMarketRegistryEvents.sol";
import {DebtReserveDef} from "../../src/policy/market-registry/types/DebtReserveDef.sol";
import {IssuerProbe} from "../../src/policy/market-registry/types/IssuerProbe.sol";
import {TokenDef} from "../../src/policy/market-registry/types/TokenDef.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {
    RegistryCoverageSpokeMock,
    RegistryDebtOracleMock,
    RegistryFeedMock,
    RegistryLPOracleMock,
    RegistryRouteMock,
    RegistryTetherMock,
    RegistryTokenMock
} from "../utils/mocks/MarketRegistryMocks.sol";

/// @notice The launch listing shapes: a fixed-price debt asset listed with its monitoring feed only (REQ-CONFIG-021),
/// and the combined USDT issuer probe at every MarketRegistry reader (REQ-MREG-027, REQ-ROUTE-008, REQ-MREG-006).
contract MarketRegistryLaunchListingUnitTest is MarketRegistryFixture {
    uint256 internal constant NEW_RESERVE = 6;
    uint256 internal constant NEW_ASSET = 3;
    /// @dev A second fixed-price debt asset (GHO-like), listed with its monitoring feed only.
    RegistryTokenMock internal ghoM;

    function setUp() public {
        _setUpWorld();
        ghoM = new RegistryTokenMock(18);
        vm.label(address(ghoM), "ghoM");
    }

    function _monitoringDef(
        address feed
    ) internal pure returns (TokenDef memory d) {
        address[] memory p = new address[](1);
        p[0] = feed;
        d.isUsdStable = true;
        d.primaryRoute = p;
        d.alternateRoute = new address[](0);
        d.standbyRoute = new address[](0);
        d.replacedSlot = RouteSlot.None;
        d.issuerProbe = IssuerProbe.None;
    }

    function _listMonitoring(
        address token
    ) internal returns (address feed) {
        feed = _newFeed("GHO/USD monitoring");
        vm.prank(address(timelock));
        registry.listToken(token, _monitoringDef(feed));
    }

    /// @dev Gives `token` three routes through `setPriceSource`.
    function _giveThreeRoutes(
        address token
    ) internal {
        (address[] memory p, address[] memory a, address[] memory s) = _routes("three");
        ps.setTolerance(token, 100, 50);
        vm.prank(address(timelock));
        registry.setPriceSource(token, p, a, s);
    }

    /// @dev The Aave reserve, AaveOracle source and funded Coverage Spoke of a new debt reserve of `asset`.
    function _reserveFor(
        address asset,
        uint8 decimals,
        address source,
        bool fixedPrice
    ) internal returns (DebtReserveDef memory d) {
        RegistryCoverageSpokeMock cs = new RegistryCoverageSpokeMock(address(hub), asset, NEW_ASSET);
        cs.setFunded(1e13, false);
        hub.setAsset(asset, NEW_ASSET);
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (asset, address(hub), uint16(NEW_ASSET), decimals);
        IAaveV4Spoke.ReserveConfig memory c;
        c.borrowable = true;
        IAaveV4Spoke.DynamicReserveConfig memory dyn;
        spoke.setReserve(NEW_RESERVE, r, c, dyn);
        aaveOracle.setSource(NEW_RESERVE, source);
        vm.prank(address(timelock));
        registry.setCoverageSpoke(address(hub), asset, address(cs));
        d = DebtReserveDef({
            reserveId: NEW_RESERVE,
            asset: asset,
            decimals: decimals,
            fundingHub: address(hub),
            hubAssetId: NEW_ASSET,
            priceSource: source,
            fixedPrice: fixedPrice,
            coverageSpoke: address(cs),
            crossHub: false,
            approved: false
        });
    }

    /// @dev A DebtOracle-priced reserve of `asset` (stress rise 500 bps).
    function _oracleReserveFor(
        address asset,
        uint8 decimals
    ) internal returns (DebtReserveDef memory) {
        RegistryDebtOracleMock o = new RegistryDebtOracleMock(asset, address(registry), address(ps));
        ps.setStressRise(asset, 500);
        return _reserveFor(asset, decimals, address(o), false);
    }

    function _enable(
        DebtReserveDef memory d
    ) internal {
        vm.prank(address(timelock));
        registry.enableDebtReserve(address(spoke), d);
    }

    function _expectListing(
        bytes32 check
    ) internal {
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ListingCheckFailed.selector, check));
    }

    function _routeWithDeps(
        address tokenIn,
        address tokenOut,
        string memory a,
        string memory b
    ) internal returns (RegistryRouteMock) {
        address[] memory deps = new address[](2);
        (deps[0], deps[1]) = (makeAddr(a), makeAddr(b));
        return new RegistryRouteMock(tokenIn, tokenOut, address(lpVaultSwap), deps);
    }

    function _listWithProbe(
        address token,
        IssuerProbe probe
    ) internal {
        (address[] memory p, address[] memory a, address[] memory s) = _routes("probe");
        TokenDef memory d = _tokenDef(p, a, s);
        d.issuerProbe = probe;
        ps.setTolerance(token, 100, 50);
        vm.prank(address(timelock));
        registry.listToken(token, d);
    }

    // ─── Fixed-price debt asset: monitoring feed only ───

    // TEST-139 verifies: REQ-CONFIG-021, REQ-CONFIG-017, REQ-MREG-006, REQ-MREG-008, REQ-MREG-027
    // Sources: Launch configuration decision 2026-11-11 (GHO listing)
    /// @notice A fixed-price debt asset lists with its monitoring feed alone, after that feed's leg checks, and is
    /// enabled as a fixed-price debt reserve. Fails without the exemption in `listToken` (the listing reverts
    /// `routeLength`).
    function test_TEST_139_fixedPriceDebtAssetListsWithItsMonitoringFeed() public {
        address feed = _newFeed("GHO/USD monitoring");
        TokenDef memory d = _monitoringDef(feed);
        address[] memory noAlt = new address[](0);
        vm.expectEmit(address(registry));
        emit IMarketRegistryEvents.TokenListed(address(ghoM), 18, d.primaryRoute, noAlt, address(0));
        vm.prank(address(timelock));
        registry.listToken(address(ghoM), d);
        TokenDef memory t = registry.getToken(address(ghoM));
        assertTrue(t.listed);
        assertEq(t.decimals, 18);
        assertEq(t.primaryRoute.length, 1);
        assertEq(t.primaryRoute[0], feed);
        assertEq(t.alternateRoute.length, 0);
        assertEq(t.standbyRoute.length, 0);
        assertEq(uint8(t.issuerProbe), uint8(IssuerProbe.None));
        (address[] memory primary, address[] memory alternate, RouteSlot replaced) =
            registry.activePriceRoutes(address(ghoM));
        assertEq(primary[0], feed);
        assertEq(alternate.length, 0);
        assertEq(uint8(replaced), uint8(RouteSlot.None));
        // Enabled as a fixed-price debt reserve with Aave's fixed source.
        DebtReserveDef memory r = _reserveFor(address(ghoM), 18, address(new RegistryFeedMock(8, 1e8)), true);
        _enable(r);
        assertTrue(registry.getDebtReserve(address(spoke), NEW_RESERVE).approved);
        assertTrue(registry.getDebtReserve(address(spoke), NEW_RESERVE).fixedPrice);
        // There is no standby to switch to.
        vm.prank(emergencyGuardian);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.NoStandbyRoute.selector, address(ghoM)));
        registry.useStandbyRoute(address(ghoM), RouteSlot.Primary);
    }

    // TEST-139 verifies: REQ-CONFIG-021, REQ-MREG-027
    /// @notice The monitoring feed still passes the leg checks, and only an empty alternate together with an empty
    /// standby is a monitoring-only listing: one empty route of the three is refused as before.
    function test_TEST_139_monitoringListingKeepsItsLegChecks() public {
        address noDef = address(new RegistryFeedMock(8, 1e8));
        address noBeat = address(new RegistryFeedMock(8, 1e8));
        ps.setFeed(noBeat, 8, 0, 25, 25);
        vm.startPrank(address(timelock));
        _expectListing("feed");
        registry.listToken(address(ghoM), _monitoringDef(noDef));
        _expectListing("heartbeat");
        registry.listToken(address(ghoM), _monitoringDef(noBeat));
        _expectListing("feed");
        registry.listToken(address(ghoM), _monitoringDef(address(0)));
        vm.stopPrank();
        (address[] memory p, address[] memory a, address[] memory s) = _routes("partial");
        TokenDef memory onlyAlt = _monitoringDef(p[0]);
        onlyAlt.alternateRoute = a;
        TokenDef memory onlyStandby = _monitoringDef(p[0]);
        onlyStandby.standbyRoute = s;
        TokenDef memory noPrimary = _monitoringDef(p[0]);
        noPrimary.primaryRoute = new address[](0);
        vm.startPrank(address(timelock));
        _expectListing("routeLength");
        registry.listToken(address(ghoM), onlyAlt);
        _expectListing("routeLength");
        registry.listToken(address(ghoM), onlyStandby);
        _expectListing("routeLength");
        registry.listToken(address(ghoM), noPrimary);
        vm.stopPrank();
        assertFalse(registry.getToken(address(ghoM)).listed);
    }

    // TEST-139 verifies: REQ-CONFIG-021, REQ-CONFIG-017, REQ-CONFIG-029, REQ-CONFIG-027
    // Sources: Launch configuration decision 2026-11-11 (GHO listing)
    /// @notice A monitoring-only token, a fixed-price debt reserve included, is refused as a pool token of a new market
    /// until `setPriceSource` gives it three routes. Fails without the route check in `_checkTokens` (the first
    /// registration succeeds).
    function test_TEST_139_monitoringOnlyTokenIsNoPoolTokenUntilItHasThreeRoutes() public {
        _listMonitoring(address(ghoM));
        _enable(_reserveFor(address(ghoM), 18, address(new RegistryFeedMock(8, 1e8)), true));
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (address(usdc), address(ghoM));
        lpVault.setPoolTokens(toks, 18);
        (address vt, RegistryLPOracleMock o) = _deployTokenAndOracle(1, _shape());
        vm.prank(address(timelock));
        _expectListing("routeLength");
        registry.listCollateralMarket(_marketDef(vt, address(o)));
        // An unlisted pool token is still reported as unlisted first.
        address unlisted = address(new RegistryTokenMock(6));
        (toks[0], toks[1]) = (unlisted, address(ghoM));
        lpVault.setPoolTokens(toks, 18);
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.TokenNotListed.selector, unlisted));
        registry.listCollateralMarket(_marketDef(vt, address(o)));
        // With three routes the token is an ordinary listed token and the market registers.
        _giveThreeRoutes(address(ghoM));
        (toks[0], toks[1]) = (address(usdc), address(ghoM));
        lpVault.setPoolTokens(toks, 18);
        vm.prank(address(timelock));
        uint256 id = registry.listCollateralMarket(_marketDef(vt, address(o)));
        assertEq(registry.getMarket(id).tokens[1], address(ghoM));
    }

    // TEST-139 verifies: REQ-CONFIG-021, REQ-MREG-006, REQ-MREG-008
    /// @notice A debt asset without a fixed price still needs its three routes: a monitoring-only listing is refused
    /// for a DebtOracle-priced reserve with `InvalidDebtReserve("routes")` and accepted once it has three routes.
    /// Fails without the route check in `_checkPriceSource` (the reserve is enabled).
    function test_TEST_139_nonFixedPriceDebtAssetNeedsThreeRoutes() public {
        _listMonitoring(address(ghoM));
        DebtReserveDef memory d = _oracleReserveFor(address(ghoM), 18);
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.InvalidDebtReserve.selector, bytes32("routes")));
        registry.enableDebtReserve(address(spoke), d);
        _giveThreeRoutes(address(ghoM));
        _enable(d);
        assertTrue(registry.getDebtReserve(address(spoke), NEW_RESERVE).approved);
        assertFalse(registry.getDebtReserve(address(spoke), NEW_RESERVE).fixedPrice);
    }

    // ─── Combined USDT issuer probe ───

    // TEST-139 verifies: REQ-MREG-027, Q-241
    /// @notice Every probe kind lists on every chain (the listing package picks the kind per chain from the fork
    /// check), and the recorded kind is returned as listed.
    function test_TEST_139_everyProbeKindListsOnEveryChain() public {
        uint256[2] memory chains = [uint256(1), 8453];
        for (uint256 c = 0; c < 2; ++c) {
            vm.chainId(chains[c]);
            for (uint8 k = 0; k < 4; ++k) {
                address t = address(new RegistryTokenMock(6));
                _listWithProbe(t, IssuerProbe(k));
                assertEq(uint8(registry.getToken(t).issuerProbe), k);
            }
        }
    }

    // TEST-221 verifies: REQ-ROUTE-008, REQ-ROUTE-005, REQ-MREG-027
    // Sources: Launch configuration decision 2026-11-11 (USDT probe)
    /// @notice A route paying a token with the combined probe into an exact-amount input is refused in either slot,
    /// exactly as for `UsdtFeeRate`; a `PausedFlag` token there is accepted. Fails if the route check reads only
    /// `UsdtFeeRate`.
    function test_TEST_221_combinedProbeTokenNeverEntersAnExactAmountLeg() public {
        (uint256 id,,) = _listMarket();
        RegistryTetherMock tether = new RegistryTetherMock();
        _listWithProbe(address(tether), IssuerProbe.UsdtFeeRateAndPaused);
        address[] memory exact = new address[](1);
        exact[0] = address(tether);
        RegistryRouteMock viaClPool = _routeWithDeps(address(usdc), address(gho), "clA", "clB");
        viaClPool.setExactAmountInputs(exact);
        for (uint8 kind = 0; kind < 2; ++kind) {
            vm.prank(address(timelock));
            vm.expectRevert(IMarketRegistryErrors.InvalidRoute.selector);
            registry.setRoute(id, address(usdc), address(gho), kind, address(viaClPool));
        }
        // USDC (`PausedFlag`, no fee switch) may enter the same hop.
        exact[0] = address(usdc);
        RegistryRouteMock usdcHop = _routeWithDeps(address(usdc), address(gho), "clC", "clD");
        usdcHop.setExactAmountInputs(exact);
        vm.prank(address(timelock));
        registry.setRoute(id, address(usdc), address(gho), 0, address(usdcHop));
        (address r,) = registry.getRoute(id, address(usdc), address(gho), 0);
        assertEq(r, address(usdcHop));
    }

    // TEST-287 verifies: REQ-MREG-006, REQ-SWAP-123, REQ-MREG-027, Q-390
    // Sources: Launch configuration decision 2026-11-11 (USDT probe)
    /// @notice A debt asset with the combined probe is refused while its fee reads above 0 or the fee read reverts,
    /// exactly as for `UsdtFeeRate`; the pause read is no enablement check for either kind (the mock answers no
    /// `paused()`), so the reserve is enabled once the fee reads 0. Fails if enablement reads only `UsdtFeeRate`.
    function test_TEST_287_combinedProbeFeeRefusedAtEnablement() public {
        RegistryTetherMock tether = new RegistryTetherMock();
        _listWithProbe(address(tether), IssuerProbe.UsdtFeeRateAndPaused);
        DebtReserveDef memory d = _oracleReserveFor(address(tether), 6);
        tether.setFee(1, false);
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.TransferFeeActive.selector, address(tether)));
        registry.enableDebtReserve(address(spoke), d);
        tether.setFee(0, true);
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.TransferFeeActive.selector, address(tether)));
        registry.enableDebtReserve(address(spoke), d);
        tether.setFee(0, false);
        _enable(d);
        assertTrue(registry.getDebtReserve(address(spoke), NEW_RESERVE).approved);
    }
}
