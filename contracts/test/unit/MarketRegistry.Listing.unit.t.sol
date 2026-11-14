// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PoolKeying} from "../../src/amm/types/PoolKeying.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {IMarketRegistryEvents} from "../../src/policy/market-registry/IMarketRegistryEvents.sol";
import {IMarketRegistryHubs} from "../../src/policy/market-registry/IMarketRegistryHubs.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {RiskTier} from "../../src/policy/market-registry/types/RiskTier.sol";
import {SpokeDef} from "../../src/policy/market-registry/types/SpokeDef.sol";
import {TokenDef} from "../../src/policy/market-registry/types/TokenDef.sol";
import {Market} from "../../src/types/Market.sol";
import {MarketDef} from "../../src/types/MarketDef.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryAaveOracleMock, RegistryHubMock, RegistrySpokeMock} from "../utils/mocks/MarketRegistryAaveMocks.sol";
import {RegistryFeedMock, RegistryLPOracleMock, RegistryTokenMock} from "../utils/mocks/MarketRegistryMocks.sol";
import {RegistryErc1820Mock} from "../utils/mocks/MarketRegistryRouteMocks.sol";

/// @notice Token listing, price sources and market registration (with relisting) of the MarketRegistry.
contract MarketRegistryListingUnitTest is MarketRegistryFixture {
    function setUp() public {
        _setUpWorld();
    }

    function _expectListing(
        bytes32 check
    ) internal {
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ListingCheckFailed.selector, check));
    }

    function _one(
        address a
    ) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    // TEST-250 verifies: REQ-CONFIG-017, Q-342
    /// @notice With the ERC-1820 registry present, `listToken` refuses a token with an `ERC777Token` implementer
    /// (`ListingCheckFailed("erc777")`); an implementer for another interface hash does not count. (Every other listing
    /// test runs with no code at the registry's address, where no token is refused.)
    function test_TEST_250_listTokenRefusesErc777() public {
        RegistryTokenMock dai = new RegistryTokenMock(18);
        (address[] memory p, address[] memory a, address[] memory s) = _routes("dai777");
        TokenDef memory d = _tokenDef(p, a, s);
        address erc1820 = 0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24;
        vm.etch(erc1820, address(new RegistryErc1820Mock()).code);
        RegistryErc1820Mock reg = RegistryErc1820Mock(erc1820);
        reg.setImplementer(address(dai), keccak256("ERC777Token"), uint256(uint160(makeAddr("hooks"))));
        vm.startPrank(address(timelock));
        _expectListing("erc777");
        registry.listToken(address(dai), d);
        vm.stopPrank();
        reg.setImplementer(address(dai), keccak256("ERC777Token"), 0);
        reg.setImplementer(address(dai), keccak256("ERC20Token"), uint256(uint160(makeAddr("hooks"))));
        vm.prank(address(timelock));
        registry.listToken(address(dai), d);
        assertTrue(registry.getToken(address(dai)).listed, "listed once no ERC777Token implementer");
    }

    // TEST-250 verifies: REQ-CONFIG-017, REQ-CONFIG-021, REQ-CONFIG-025, REQ-MREG-027, Q-248, Q-274, REQ-ACCESS-133
    // Sources: 5.1 TEST-250, TEST-139
    function test_TEST_250_listTokenRouteChecks() public {
        RegistryTokenMock dai = new RegistryTokenMock(18);
        (address[] memory p, address[] memory a, address[] memory s) = _routes("dai");
        TokenDef memory d = _tokenDef(p, a, s);
        vm.startPrank(address(timelock));
        // A route of zero or three feeds.
        d.standbyRoute = new address[](0);
        _expectListing("routeLength");
        registry.listToken(address(dai), d);
        d.standbyRoute = s;
        // A feed with no ParameterStore definition, or no heartbeat.
        d.primaryRoute = _one(address(new RegistryFeedMock(8, 1e8)));
        _expectListing("feed");
        registry.listToken(address(dai), d);
        address noBeat = address(new RegistryFeedMock(8, 1e8));
        ps.setFeed(noBeat, 8, 0, 25, 25);
        d.primaryRoute = _one(noBeat);
        _expectListing("heartbeat");
        registry.listToken(address(dai), d);
        // Routes sharing a feed.
        d.primaryRoute = _one(a[1]);
        _expectListing("sharedFeed");
        registry.listToken(address(dai), d);
        d.primaryRoute = p;
        d.replacedSlot = RouteSlot.Primary;
        _expectListing("replacedSlot");
        registry.listToken(address(dai), d);
        d.replacedSlot = RouteSlot.None;
        d.pegModule = makeAddr("litePsm");
        vm.expectEmit(address(registry));
        emit IMarketRegistryEvents.TokenListed(address(dai), 18, p, a, d.pegModule);
        registry.listToken(address(dai), d);
        _expectListing("listed");
        registry.listToken(address(dai), d);
        vm.stopPrank();
        TokenDef memory rec = registry.getToken(address(dai));
        assertTrue(rec.listed);
        assertEq(rec.decimals, 18);
        assertEq(rec.standbyRoute[0], s[0]);
        assertEq(rec.pegModule, d.pegModule);
        assertEq(registry.priceRouteVersion(address(dai)), 0);
    }

    // TEST-231 verifies: REQ-CONFIG-026, REQ-CONFIG-027, REQ-CONFIG-034, REQ-CONFIG-036, REQ-MREG-027, Q-248, REQ-ACCESS-045
    // Sources: 5.1 TEST-231, TEST-139
    function test_TEST_231_setPriceSourceRechecksEveryMarket() public {
        (uint256 id,, RegistryLPOracleMock lpOracle) = _activeMarket();
        vm.prank(emergencyGuardian);
        registry.useStandbyRoute(address(usdc), RouteSlot.Primary);
        (address[] memory p, address[] memory a, address[] memory s) = _routes("usdc2");
        vm.startPrank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.TokenNotListed.selector, alice));
        registry.setPriceSource(alice, p, a, s);
        // The new standby shares a feed with USDT's alternate: common-mode guard.
        address[] memory usdtAlt = registry.getToken(address(usdt)).alternateRoute;
        _expectListing("commonMode");
        registry.setPriceSource(address(usdc), p, a, _one(usdtAlt[1]));
        // The tolerance would fall below its lower bound.
        ps.setTolerance(address(usdc), 40, 50);
        _expectListing("tolerance");
        registry.setPriceSource(address(usdc), p, a, s);
        ps.setTolerance(address(usdc), 100, 50);
        // A route whose deviation plus drift reaches 1 - CF.
        ps.setFeed(s[0], 8, 86_400, 1000, 1000);
        _expectListing("listingMargin");
        registry.setPriceSource(address(usdc), p, a, s);
        ps.setFeed(s[0], 8, 86_400, 25, 25);
        // The market's LPOracle refuses the configuration the new routes give it.
        lpOracle.setFailed(1);
        _expectListing("oracleConfig");
        registry.setPriceSource(address(usdc), p, a, s);
        lpOracle.setFailed(0);
        uint64 v = registry.priceRouteVersion(address(usdc));
        vm.expectEmit(address(registry));
        emit IMarketRegistryEvents.PriceSourceSet(address(usdc), p, a, s);
        registry.setPriceSource(address(usdc), p, a, s);
        vm.stopPrank();
        assertEq(registry.priceRouteVersion(address(usdc)), v + 1);
        (address[] memory primary,, RouteSlot replaced) = registry.activePriceRoutes(address(usdc));
        assertEq(uint8(replaced), uint8(RouteSlot.None));
        assertEq(primary[0], p[0]);
        assertEq(uint8(registry.getMarket(id).status), uint8(MarketStatus.Active));
    }

    // TEST-138 verifies: REQ-CONFIG-078, REQ-CONFIG-006, REQ-CONFIG-007, REQ-CONFIG-008, REQ-CONFIG-028, REQ-CONFIG-037, REQ-MREG-033, Q-312, REQ-ACCESS-033
    // Sources: 5.1 TEST-138
    function test_TEST_138_listCollateralMarketRecordsTheMarket() public {
        (address vt, RegistryLPOracleMock o) = _deployTokenAndOracle(1, _shape());
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (address(usdc), address(usdt));
        vm.expectEmit(address(registry));
        emit IMarketRegistryEvents.MarketRegistered(1, V3, pool, bytes32(0), toks, vt, address(o), address(spoke));
        vm.prank(address(timelock));
        uint256 id = registry.listCollateralMarket(_marketDef(vt, address(o)));
        assertEq(id, 1);
        Market memory m = registry.getMarket(id);
        assertEq(uint8(m.status), uint8(MarketStatus.Registered));
        assertEq(m.chainId, block.chainid);
        assertEq(m.integration, address(lpVault));
        assertEq(m.tokens.length, 2);
        assertEq(m.tokenDecimals[1], 6);
        assertEq(m.decimals, 18);
        assertEq(m.vaultToken, vt);
        assertEq(m.registeredAt, block.timestamp);
        assertEq(registry.marketCount(), 1);
        assertEq(registry.marketOfVaultToken(vt), 1);
        assertEq(registry.marketOfLpOracle(address(o)), 1);
        assertEq(registry.marketOfKey(factory.marketKeyOf(V3, pool, bytes32(0), _shape())), 1);
        assertEq(registry.settlementReserve(1), GHO_RESERVE);
        assertEq(registry.marketsOfSpoke(address(spoke))[0], 1);
        assertEq(registry.activeMarketCount(address(spoke)), 0, "Registered is not listed");
    }

    // TEST-138 verifies: REQ-CONFIG-032, REQ-CONFIG-007, REQ-VTOKEN-022, Q-299, REQ-ACCESS-061
    function test_TEST_138_vaultTokenMustBeTheMarketsOwn() public {
        // A token deployed for another shape cannot be paired with this market.
        PositionShape memory other = PositionShape(ShapeKind.TickRange, -100, 100);
        (address vtOther, RegistryLPOracleMock o) = _deployTokenAndOracle(1, other);
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.VaultTokenMismatch.selector);
        registry.listCollateralMarket(_marketDef(vtOther, address(o)));
        // A token carrying the wrong market identifier.
        (address vtLate, RegistryLPOracleMock o2) = _deployTokenAndOracle(2, _shape());
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.VaultTokenMismatch.selector);
        registry.listCollateralMarket(_marketDef(vtLate, address(o2)));
    }

    // TEST-138 verifies: REQ-CONFIG-032, REQ-CONFIG-031
    function test_TEST_138_vaultTokenBindingsAndDecimals() public {
        (address vt, RegistryLPOracleMock o) = _deployTokenAndOracle(1, _shape());
        RegistryLPOracleMock otherOracle = new RegistryLPOracleMock(1, address(lpVault));
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.VaultTokenMismatch.selector);
        registry.listCollateralMarket(_marketDef(vt, address(otherOracle)));
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (address(usdc), address(usdt));
        lpVault.setPoolTokens(toks, 17);
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.VaultTokenMismatch.selector);
        registry.listCollateralMarket(_marketDef(vt, address(o)));
    }

    // TEST-138 verifies: REQ-CONFIG-033, REQ-CONFIG-030, REQ-CONFIG-011, REQ-CONFIG-007
    function test_TEST_138_spokePoolAndShapeChecks() public {
        (address vt, RegistryLPOracleMock o) = _deployTokenAndOracle(1, _shape());
        MarketDef memory d = _marketDef(vt, address(o));
        d.spoke = alice;
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.InvalidSpoke.selector, alice));
        registry.listCollateralMarket(d);
        d = _marketDef(vt, address(o));
        d.hub = alice;
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.InvalidSpoke.selector, address(spoke)));
        registry.listCollateralMarket(d);
        d = _marketDef(vt, address(o));
        d.integrationId = 2;
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryHubs.InvalidIntegration.selector, 2));
        registry.listCollateralMarket(d);
        d = _marketDef(vt, address(o));
        d.poolId = bytes32(uint256(1));
        vm.prank(address(timelock));
        _expectListing("pool");
        registry.listCollateralMarket(d);
        d = _marketDef(vt, address(o));
        d.shape = PositionShape(ShapeKind.TickRange, 50, 50);
        vm.prank(address(timelock));
        _expectListing("shape");
        registry.listCollateralMarket(d);
        d.shape = PositionShape(ShapeKind.FullPool, 0, 0);
        vm.prank(address(timelock));
        _expectListing("shape");
        registry.listCollateralMarket(d);
        d.shape = PositionShape(ShapeKind.None, -50, 50);
        vm.prank(address(timelock));
        _expectListing("shape");
        registry.listCollateralMarket(d);
        lpVault.setKeying(PoolKeying.Id, ShapeKind.FullPool);
        d = _marketDef(vt, address(o));
        d.shape = PositionShape(ShapeKind.FullPool, 0, 1);
        (d.pool, d.poolId) = (address(0), bytes32(uint256(7)));
        vm.prank(address(timelock));
        _expectListing("shape");
        registry.listCollateralMarket(d);
    }

    // TEST-139 verifies: REQ-CONFIG-017, REQ-CONFIG-018, REQ-CONFIG-034, REQ-CONFIG-035, REQ-CONFIG-037, Q-191
    // Sources: 5.1 TEST-139, MATH-UO-10, MATH-UO-22
    function test_TEST_139_registrationGuards() public {
        (address vt, RegistryLPOracleMock o) = _deployTokenAndOracle(1, _shape());
        MarketDef memory d = _marketDef(vt, address(o));
        // LPOracle seed.
        o.setSeed(18, 1e8);
        vm.prank(address(timelock));
        _expectListing("lpOracle");
        registry.listCollateralMarket(d);
        o.setSeed(8, 0);
        vm.prank(address(timelock));
        _expectListing("lpOracle");
        registry.listCollateralMarket(d);
        o.setSeed(8, 1e8);
        // Raw-price bound: with equal decimals the 2^128 bound is out of reach of a usable answer, so an answer at
        // 2^96 (unusable) is what fails it, and the largest usable one lists.
        address usdcPrimary = registry.getToken(address(usdc)).primaryRoute[0];
        RegistryFeedMock(usdcPrimary).setAnswer(int256(2 ** 96));
        vm.prank(address(timelock));
        _expectListing("rawPrice");
        registry.listCollateralMarket(d);
        RegistryFeedMock(usdcPrimary).setAnswer(int256(2 ** 96 - 1));
        vm.prank(address(timelock));
        registry.listCollateralMarket(d);
    }

    // TEST-139 verifies: REQ-CONFIG-017, REQ-CONFIG-018, REQ-CONFIG-034
    function test_TEST_139_poolTokensListedStableAndIndependent() public {
        (address vt, RegistryLPOracleMock o) = _deployTokenAndOracle(1, _shape());
        MarketDef memory d = _marketDef(vt, address(o));
        RegistryTokenMock dai = new RegistryTokenMock(18);
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (address(usdc), address(dai));
        lpVault.setPoolTokens(toks, 18);
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.TokenNotListed.selector, address(dai)));
        registry.listCollateralMarket(d);
        // DAI listed as a non-stable token on a Stable-tier Spoke.
        (address[] memory p, address[] memory a, address[] memory s) = _routes("dai");
        TokenDef memory td = _tokenDef(p, a, s);
        td.isUsdStable = false;
        vm.prank(address(timelock));
        registry.listToken(address(dai), td);
        vm.prank(address(timelock));
        _expectListing("tokenClass");
        registry.listCollateralMarket(d);
        // WETH-like token whose alternate route shares ETH/USD with USDC's alternate.
        RegistryTokenMock weth = new RegistryTokenMock(18);
        address[] memory usdcAlt = registry.getToken(address(usdc)).alternateRoute;
        (p, a, s) = _routes("weth");
        a[1] = usdcAlt[1];
        vm.prank(address(timelock));
        registry.listToken(address(weth), _tokenDef(p, a, s));
        (toks[0], toks[1]) = (address(usdc), address(weth));
        lpVault.setPoolTokens(toks, 18);
        vm.prank(address(timelock));
        _expectListing("commonMode");
        registry.listCollateralMarket(d);
    }

    // TEST-138 verifies: REQ-CONFIG-076, REQ-CONFIG-078, REQ-MREG-033
    function test_TEST_138_spokeWideDriftAndSettlementReserve() public {
        (address vt, RegistryLPOracleMock o) = _deployTokenAndOracle(1, _shape());
        rm.setDrift(true);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryErrors.ActivationCheckFailed.selector, 1, bytes32("aaveConfig"))
        );
        registry.listCollateralMarket(_marketDef(vt, address(o)));
        rm.setDrift(false);
        // A Spoke with no debt reserve has no settlement reserve.
        RegistryHubMock hub2 = new RegistryHubMock();
        RegistrySpokeMock spoke2 = new RegistrySpokeMock();
        RegistryAaveOracleMock oracle2 = new RegistryAaveOracleMock();
        spoke2.setOracle(address(oracle2));
        spoke2.setImplementation(address(spokeImpl));
        oracle2.setSpoke(address(spoke2));
        vm.startPrank(address(timelock));
        registry.recordHub(address(hub2), RiskTier.Stable);
        registry.deployCdpSpoke(
            SpokeDef(false, address(hub2), V3, RiskTier.Stable, address(spokeImpl), address(oracle2))
        );
        vt = factory.deployVaultToken(
            V3, pool, bytes32(0), _shape(), address(hub2), address(spoke2), 1, address(o), 18, "n", "s"
        );
        MarketDef memory d = _marketDef(vt, address(o));
        (d.hub, d.spoke) = (address(hub2), address(spoke2));
        _expectListing("settlementReserve");
        registry.listCollateralMarket(d);
        vm.stopPrank();
    }

    // TEST-252 verifies: REQ-MREG-030, REQ-CONFIG-048, REQ-CONFIG-007, Q-265
    // Sources: 5.1 TEST-252
    function test_TEST_252_relistingReusesTheReservedId() public {
        (uint256 id, address vt, RegistryLPOracleMock o) = _listMarket();
        // A second market's LPOracle cannot reuse a live market's.
        PositionShape memory wide = PositionShape(ShapeKind.TickRange, -100, 100);
        (address vt2,) = _deployTokenAndOracle(2, wide);
        MarketDef memory d2 = _marketDef(vt2, address(o));
        d2.shape = wide;
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.DuplicateMarketKey.selector);
        registry.listCollateralMarket(d2);
        vm.expectEmit(address(registry));
        emit IMarketRegistryEvents.MarketRegistrationCancelled(id);
        vm.prank(address(timelock));
        registry.cancelRegistration(id);
        assertEq(registry.marketOfVaultToken(vt), 0);
        // Relisting with another LPOracle is refused: the token carries its LPOracle.
        RegistryLPOracleMock o3 = new RegistryLPOracleMock(id, address(lpVault));
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.VaultTokenMismatch.selector);
        registry.listCollateralMarket(_marketDef(vt, address(o3)));
        vm.prank(address(timelock));
        uint256 again = registry.listCollateralMarket(_marketDef(vt, address(o)));
        assertEq(again, id);
        assertEq(registry.marketCount(), 1);
        assertEq(uint8(registry.getMarket(id).status), uint8(MarketStatus.Registered));
        assertEq(registry.marketsOfSpoke(address(spoke)).length, 1);
        assertEq(registry.marketOfVaultToken(vt), id);
    }

    // TEST-252 verifies: REQ-MREG-030, REQ-CONFIG-060, REQ-CONFIG-062, REQ-MREG-025, Q-265
    // Sources: MarketRegistry review 2026-11-10 finding 12 (relisting clears routes, approvals and latches)
    function test_TEST_252_relistingStartsClean() public {
        (uint256 id, address vt, RegistryLPOracleMock o) = _listMarket();
        address r1 = _setRoute(id, address(usdc), address(gho), 0, "dexA");
        vm.prank(emergencyGuardian);
        registry.tripMarketBreaker(id);
        (uint32 latched,) = registry.marketBreaker(id);
        assertGt(latched, 0);
        vm.prank(address(timelock));
        registry.cancelRegistration(id);
        vm.prank(address(timelock));
        registry.listCollateralMarket(_marketDef(vt, address(o)));
        // The cancelled registration's route, its approval for `restoreRoute` and its latch are gone.
        (address route, bool usable) = registry.getRoute(id, address(usdc), address(gho), 0);
        assertEq(route, address(0));
        assertFalse(usable);
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.NotPreviouslyApproved.selector);
        registry.restoreRoute(id, address(usdc), address(gho), 0, r1);
        (latched,) = registry.marketBreaker(id);
        assertEq(latched, 0);
        // The relisting's own routes are recorded as usual; the route stays in the protected set.
        address r2 = _setRoute(id, address(usdc), address(gho), 0, "dexB");
        (route, usable) = registry.getRoute(id, address(usdc), address(gho), 0);
        assertEq(route, r2);
        assertTrue(usable);
        vm.prank(emergencyGuardian);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ProtectedAddress.selector, r1));
        registry.freezeAddress(r1);
        // A second cancel and relisting moves to the next route epoch.
        vm.prank(address(timelock));
        registry.cancelRegistration(id);
        vm.prank(address(timelock));
        registry.listCollateralMarket(_marketDef(vt, address(o)));
        (route,) = registry.getRoute(id, address(usdc), address(gho), 0);
        assertEq(route, address(0));
        assertEq(uint256(vm.load(address(registry), _mapSlot(bytes32(id), 48))), 2, "routeEpoch");
    }

    /// @dev Slot of `mapping[key]` at field `field` of the ERC-7201 layout.
    function _mapSlot(
        bytes32 key,
        uint256 field
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, uint256(LAYOUT) + field));
    }

    bytes32 internal constant LAYOUT = 0x598189494afc908fd08b2b882e497a0aa6147de6d30a80184ae623e37f6d8000;

    // TEST-168 verifies: REQ-CONFIG-002
    // Sources: MarketRegistry review 2026-11-10 (storage-layout assertion); fields appended 2026-11-11
    function test_TEST_168_storageLayoutIsAppendOnly() public {
        // The namespace is the ERC-7201 slot of "avana.storage.MarketRegistry".
        bytes32 ns =
            keccak256(abi.encode(uint256(keccak256("avana.storage.MarketRegistry")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(ns, LAYOUT);
        (uint256 id,,) = _listMarket();
        // Field 0 marketCount, 20 flashSource, 31 crossHubLinesEnabled: unchanged positions.
        assertEq(uint256(vm.load(address(registry), LAYOUT)), id);
        assertEq(address(uint160(uint256(vm.load(address(registry), bytes32(uint256(LAYOUT) + 20))))), address(flash));
        vm.prank(address(timelock));
        registry.setCrossHubLinesEnabled(true);
        assertEq(uint256(vm.load(address(registry), bytes32(uint256(LAYOUT) + 31))), 1);
        // Field 41 frozen, 42 freezeBuckets.
        vm.warp(7200);
        vm.prank(emergencyGuardian);
        registry.freezeAddress(alice);
        assertEq(uint256(vm.load(address(registry), _mapSlot(bytes32(uint256(uint160(alice))), 41))), 1);
        bytes32 inner = _mapSlot(bytes32(uint256(uint160(emergencyGuardian))), 42);
        assertEq(uint256(vm.load(address(registry), keccak256(abi.encode(uint256(2), inner)))), 1);
        // Appended: 43 approvedSpokeCodeHash, 44 spokeCodeHash, 46 knownIntegrationContract, 47 standbyCancelledAt.
        bytes32 h = keccak256("some implementation");
        vm.prank(address(timelock));
        registry.approveSpokeCodeHash(h);
        assertEq(uint256(vm.load(address(registry), _mapSlot(h, 43))), 1);
        bytes32 spokeHash = vm.load(address(registry), _mapSlot(bytes32(uint256(uint160(address(spoke)))), 44));
        assertEq(spokeHash, address(spokeImpl).codehash);
        address[] memory amm = new address[](1);
        amm[0] = address(usdc);
        vm.prank(address(timelock));
        registry.recordIntegrationContracts(V3, amm);
        assertEq(uint256(vm.load(address(registry), _mapSlot(bytes32(uint256(uint160(address(usdc)))), 46))), 1);
        vm.prank(emergencyGuardian);
        registry.useStandbyRoute(address(usdt), RouteSlot.Primary);
        vm.prank(aaveGovernanceExecutor);
        registry.cancelStandbySwitch(address(usdt));
        assertEq(
            uint256(vm.load(address(registry), _mapSlot(bytes32(uint256(uint160(address(usdt)))), 47))), block.timestamp
        );
    }
}
