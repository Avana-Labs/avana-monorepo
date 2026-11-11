// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../src/amm/IAmmIntegration.sol";
import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {IMarketRegistryEvents} from "../../src/policy/market-registry/IMarketRegistryEvents.sol";
import {IMarketRegistryHubs} from "../../src/policy/market-registry/IMarketRegistryHubs.sol";
import {IssuerProbe} from "../../src/policy/market-registry/types/IssuerProbe.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {TokenDef} from "../../src/policy/market-registry/types/TokenDef.sol";
import {Market} from "../../src/types/Market.sol";
import {MarketDef} from "../../src/types/MarketDef.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryLPOracleMock, RegistryTokenMock} from "../utils/mocks/MarketRegistryMocks.sol";

/// @notice Token listing and market registration at their boundaries: the full market record, the pool-token count
/// (2 to 8), the vault-token decimals window of the home Hub, which unlisted token is reported, each pair of routes
/// that may share a feed, the tolerance bound of a price-source change, the Spoke, Hub and integration of a definition,
/// and a relisting whose binding the integration does not confirm.
contract MarketRegistryListingBoundsUnitTest is MarketRegistryFixture {
    function setUp() public {
        _setUpWorld();
    }

    function _expectListing(
        bytes32 check
    ) internal {
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ListingCheckFailed.selector, check));
    }

    function _list(
        MarketDef memory d
    ) internal returns (uint256 id) {
        vm.prank(address(timelock));
        id = registry.listCollateralMarket(d);
    }

    function _newListedToken(
        string memory label
    ) internal returns (address t) {
        t = address(new RegistryTokenMock(6));
        _listToken(t, label);
    }

    function _setPoolTokens(
        address[] memory toks
    ) internal {
        lpVault.setPoolTokens(toks, 18);
    }

    // ─── The market record ───

    // TEST-138 verifies: REQ-CONFIG-008, REQ-CONFIG-006, REQ-CONFIG-078, REQ-CONFIG-028
    // Sources: 5.1 TEST-138
    // Every field of the record after listing: the definition's identity, the integration's tokens and decimals,
    // Registered status, the listing time, and no activation fields yet.
    function test_TEST_138_recordHoldsEveryFieldAfterListing() public {
        vm.chainId(8453);
        vm.warp(1_234_567);
        PositionShape memory sh = PositionShape(ShapeKind.TickRange, -60, 120);
        (address vt, RegistryLPOracleMock o) = _deployTokenAndOracle(1, sh);
        MarketDef memory d = _marketDef(vt, address(o));
        d.shape = sh;
        uint256 id = _list(d);
        Market memory m = registry.getMarket(id);
        assertEq(m.chainId, 8453);
        assertEq(m.hub, address(hub));
        assertEq(m.spoke, address(spoke));
        assertEq(m.integrationId, V3);
        assertEq(m.integration, address(lpVault));
        assertEq(m.pool, pool);
        assertEq(m.poolId, bytes32(0));
        assertEq(uint8(m.shape.kind), uint8(ShapeKind.TickRange));
        assertEq(m.shape.tickLower, -60);
        assertEq(m.shape.tickUpper, 120);
        assertEq(m.tokens.length, 2);
        assertEq(m.tokens[0], address(usdc));
        assertEq(m.tokens[1], address(usdt));
        assertEq(m.tokenDecimals.length, 2);
        assertEq(m.tokenDecimals[0], 6);
        assertEq(m.tokenDecimals[1], 6);
        assertEq(m.vaultToken, vt);
        assertEq(m.decimals, 18);
        assertEq(m.lpOracle, address(o));
        assertEq(m.hubAssetId, 0);
        assertEq(m.reserveId, 0);
        assertEq(uint8(m.status), uint8(MarketStatus.Registered));
        assertEq(m.registeredAt, 1_234_567);
        assertEq(m.activatedAt, 0);
        assertEq(registry.settlementReserve(id), GHO_RESERVE);
    }

    // TEST-138 verifies: REQ-CONFIG-006, REQ-CONFIG-007
    // Markets take consecutive identifiers from 1 and each LPOracle, vault token and key maps back to its own.
    function test_TEST_138_identifiersAreConsecutive() public {
        for (int24 w = 10; w <= 50; w += 10) {
            PositionShape memory sh = PositionShape(ShapeKind.TickRange, -w, w);
            uint256 next = registry.marketCount() + 1;
            (address vt, RegistryLPOracleMock o) = _deployTokenAndOracle(next, sh);
            MarketDef memory d = _marketDef(vt, address(o));
            d.shape = sh;
            uint256 id = _list(d);
            assertEq(id, next);
            assertEq(registry.marketOfVaultToken(vt), id);
            assertEq(registry.marketOfLpOracle(address(o)), id);
            assertEq(registry.marketOfKey(factory.marketKeyOf(V3, pool, bytes32(0), sh)), id);
        }
        assertEq(registry.marketCount(), 5);
        assertEq(registry.marketsOfSpoke(address(spoke)).length, 5);
    }

    // ─── Pool tokens ───

    // TEST-139 verifies: REQ-CONFIG-031, REQ-CONFIG-017
    // A pool of 1 or 9 tokens is refused; 8 listed stablecoins pass.
    function test_TEST_139_poolTokenCountBounds() public {
        address[] memory one = new address[](1);
        one[0] = address(usdc);
        _setPoolTokens(one);
        (address vt, RegistryLPOracleMock o) = _deployTokenAndOracle(1, _shape());
        vm.prank(address(timelock));
        _expectListing("tokens");
        registry.listCollateralMarket(_marketDef(vt, address(o)));

        address[] memory nine = new address[](9);
        for (uint256 i = 0; i < 9; ++i) {
            nine[i] = _newListedToken(string(abi.encodePacked("s", bytes1(uint8(65 + i)))));
        }
        _setPoolTokens(nine);
        vm.prank(address(timelock));
        _expectListing("tokens");
        registry.listCollateralMarket(_marketDef(vt, address(o)));

        address[] memory eight = new address[](8);
        for (uint256 i = 0; i < 8; ++i) {
            eight[i] = nine[i];
        }
        _setPoolTokens(eight);
        uint256 id = _list(_marketDef(vt, address(o)));
        assertEq(registry.getMarket(id).tokens.length, 8);
        assertEq(registry.getMarket(id).tokenDecimals.length, 8);
    }

    // TEST-139 verifies: REQ-CONFIG-017, REQ-CONFIG-031, REQ-CONFIG-018
    // The first unlisted pool token is the one reported; an unlisted token (which also has no stable class) is reported
    // as unlisted, not as a class mismatch.
    function test_TEST_139_firstUnlistedTokenReported() public {
        address a = address(new RegistryTokenMock(6));
        address b = address(new RegistryTokenMock(6));
        address[] memory toks = new address[](3);
        (toks[0], toks[1], toks[2]) = (address(usdc), a, b);
        _setPoolTokens(toks);
        (address vt, RegistryLPOracleMock o) = _deployTokenAndOracle(1, _shape());
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.TokenNotListed.selector, a));
        registry.listCollateralMarket(_marketDef(vt, address(o)));
        _listToken(a, "a");
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.TokenNotListed.selector, b));
        registry.listCollateralMarket(_marketDef(vt, address(o)));
    }

    // TEST-139 verifies: REQ-CONFIG-033, REQ-CONFIG-031
    // The vault-token decimals must lie inside the home Hub's [MIN, MAX] underlying decimals, both ends inclusive.
    function test_TEST_139_unitDecimalsInsideTheHubWindow() public {
        (address vt, RegistryLPOracleMock o) = _deployTokenAndOracle(1, _shape());
        MarketDef memory d = _marketDef(vt, address(o));
        bytes memory maxSel = abi.encodeWithSelector(IAaveV4Hub.MAX_ALLOWED_UNDERLYING_DECIMALS.selector);
        bytes memory minSel = abi.encodeWithSelector(IAaveV4Hub.MIN_ALLOWED_UNDERLYING_DECIMALS.selector);
        vm.mockCall(address(hub), maxSel, abi.encode(uint8(17)));
        vm.prank(address(timelock));
        _expectListing("decimals");
        registry.listCollateralMarket(d);
        vm.mockCall(address(hub), maxSel, abi.encode(uint8(18)));
        vm.mockCall(address(hub), minSel, abi.encode(uint8(19)));
        vm.prank(address(timelock));
        _expectListing("decimals");
        registry.listCollateralMarket(d);
        vm.mockCall(address(hub), minSel, abi.encode(uint8(18)));
        uint256 id = _list(d);
        assertEq(registry.getMarket(id).decimals, 18);
    }

    // ─── Definition identity ───

    // TEST-138 verifies: REQ-CONFIG-033, REQ-CONFIG-011, REQ-CONFIG-077, ATTACK-121
    // The Spoke must be approved with the definition's Hub, and the integration the Spoke's own.
    function test_TEST_138_spokeHubAndIntegrationOfTheDefinition() public {
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
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryHubs.InvalidIntegration.selector, uint32(2)));
        registry.listCollateralMarket(d);
    }

    // TEST-138 verifies: REQ-MREG-030, REQ-CONFIG-032
    // The vault token must be the factory's token of the (Spoke, market key): zero or another key's token is refused.
    function test_TEST_138_vaultTokenOfAnotherKeyRefused() public {
        (address vt,) = _deployTokenAndOracle(1, _shape());
        PositionShape memory other = PositionShape(ShapeKind.TickRange, -10, 10);
        (, RegistryLPOracleMock o2) = _deployTokenAndOracle(1, other);
        MarketDef memory d = _marketDef(vt, address(o2));
        d.shape = other;
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.VaultTokenMismatch.selector);
        registry.listCollateralMarket(d);
        d.vaultToken = address(0);
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.VaultTokenMismatch.selector);
        registry.listCollateralMarket(d);
    }

    // TEST-252 verifies: REQ-MREG-030
    // A relisting whose integration reports another binding for the reserved identifier is refused, and no second
    // bindMarket is attempted.
    function test_TEST_252_relistingNeedsTheSameBinding() public {
        (uint256 id, address vt, RegistryLPOracleMock o) = _listMarket();
        vm.prank(address(timelock));
        registry.cancelRegistration(id);
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (address(usdc), address(usdt));
        bytes memory call = abi.encodeWithSelector(IAmmIntegration.marketOf.selector, id);
        PositionShape memory sh = _shape();
        vm.mockCall(address(lpVault), call, abi.encode(makeAddr("otherPool"), bytes32(0), sh, toks));
        vm.prank(address(timelock));
        _expectListing("binding");
        registry.listCollateralMarket(_marketDef(vt, address(o)));
        sh.tickUpper = 51;
        vm.mockCall(address(lpVault), call, abi.encode(pool, bytes32(0), sh, toks));
        vm.prank(address(timelock));
        _expectListing("binding");
        registry.listCollateralMarket(_marketDef(vt, address(o)));
        vm.clearMockedCalls();
        assertEq(_list(_marketDef(vt, address(o))), id);
    }

    // ─── Tokens and price routes ───

    // TEST-250 verifies: REQ-CONFIG-021, REQ-MREG-027
    // No two of the three routes may share a feed: each of the three pairs alone is refused.
    function test_TEST_250_eachRoutePairMayNotShareAFeed() public {
        address t = address(new RegistryTokenMock(6));
        (address[] memory p, address[] memory a, address[] memory s) = _routes("t");
        TokenDef memory d = _tokenDef(p, a, _one(p[0]));
        vm.startPrank(address(timelock));
        _expectListing("sharedFeed");
        registry.listToken(t, d);
        d = _tokenDef(p, a, _one(a[1]));
        _expectListing("sharedFeed");
        registry.listToken(t, d);
        d = _tokenDef(_two(a[0], p[0]), a, s);
        _expectListing("sharedFeed");
        registry.listToken(t, d);
        // A two-leg route repeating its own feed.
        d = _tokenDef(_two(p[0], p[0]), a, s);
        _expectListing("sharedFeed");
        registry.listToken(t, d);
        registry.listToken(t, _tokenDef(p, a, s));
        vm.stopPrank();
    }

    // TEST-250 verifies: REQ-CONFIG-021, REQ-MREG-027
    // Each route takes one or two feeds: zero and three are refused in each slot; a zero feed is refused.
    function test_TEST_250_routeLengthInEverySlot() public {
        address t = address(new RegistryTokenMock(6));
        (address[] memory p, address[] memory a, address[] memory s) = _routes("t");
        address extra = _newFeed("extra");
        address[] memory three = new address[](3);
        (three[0], three[1], three[2]) = (a[0], a[1], extra);
        vm.startPrank(address(timelock));
        _expectListing("routeLength");
        registry.listToken(t, _tokenDef(new address[](0), a, s));
        _expectListing("routeLength");
        registry.listToken(t, _tokenDef(p, three, s));
        _expectListing("routeLength");
        registry.listToken(t, _tokenDef(p, a, new address[](0)));
        _expectListing("feed");
        registry.listToken(t, _tokenDef(p, a, new address[](1)));
        _expectListing("feed");
        registry.listToken(t, _tokenDef(p, _two(a[0], address(0)), s));
        vm.stopPrank();
        assertFalse(registry.getToken(t).listed);
    }

    // TEST-250 verifies: REQ-CONFIG-017, REQ-MREG-027
    // The token's decimals are read from the token, not taken from the definition; the probe, class and peg module
    // are recorded as given; the zero address is never listed.
    function test_TEST_250_listTokenRecordsWhatItReads() public {
        address t = address(new RegistryTokenMock(8));
        (address[] memory p, address[] memory a, address[] memory s) = _routes("t");
        TokenDef memory d = _tokenDef(p, a, s);
        d.decimals = 18;
        d.listed = false;
        d.isUsdStable = false;
        d.issuerProbe = IssuerProbe.UsdtFeeRate;
        d.pegModule = makeAddr("gsm");
        vm.prank(address(timelock));
        registry.listToken(t, d);
        TokenDef memory rec = registry.getToken(t);
        assertTrue(rec.listed);
        assertEq(rec.decimals, 8);
        assertFalse(rec.isUsdStable);
        assertEq(uint8(rec.issuerProbe), uint8(IssuerProbe.UsdtFeeRate));
        assertEq(rec.pegModule, d.pegModule);
        assertEq(uint8(rec.replacedSlot), uint8(RouteSlot.None));
        assertEq(rec.primaryRoute.length, 1);
        assertEq(rec.alternateRoute.length, 2);
        assertEq(rec.alternateRoute[1], a[1]);
        vm.prank(address(timelock));
        _expectListing("listed");
        registry.listToken(address(0), d);
    }

    // TEST-231 verifies: REQ-CONFIG-026, REQ-CONFIG-027, REQ-MREG-027, REQ-MREG-028
    // setPriceSource accepts a tolerance equal to its lower bound and refuses one below it; it writes the three
    // routes, resets the replaced slot, clears a DAO-cancel lock and bumps the version by exactly one.
    function test_TEST_231_setPriceSourceToleranceBoundAndEffects() public {
        address t = address(usdt);
        vm.prank(emergencyGuardian);
        registry.useStandbyRoute(t, RouteSlot.Alternate);
        vm.prank(aaveGovernanceExecutor);
        registry.cancelStandbySwitch(t);
        assertGt(registry.standbySwitchLockedUntil(t), 0);
        uint64 v = registry.priceRouteVersion(t);
        (address[] memory p, address[] memory a, address[] memory s) = _routes("usdt2");
        ps.setTolerance(t, 49, 50);
        vm.prank(address(timelock));
        _expectListing("tolerance");
        registry.setPriceSource(t, p, a, s);
        ps.setTolerance(t, 50, 50);
        vm.prank(address(timelock));
        registry.setPriceSource(t, p, a, s);
        assertEq(registry.priceRouteVersion(t), v + 1);
        assertEq(registry.standbySwitchLockedUntil(t), 0, "a new price source ends the lock");
        TokenDef memory rec = registry.getToken(t);
        assertEq(rec.primaryRoute[0], p[0]);
        assertEq(rec.alternateRoute[0], a[0]);
        assertEq(rec.standbyRoute[0], s[0]);
        assertEq(uint8(rec.replacedSlot), uint8(RouteSlot.None));
        // The guardian may switch again at once.
        vm.prank(emergencyGuardian);
        registry.useStandbyRoute(t, RouteSlot.Primary);
    }

    // TEST-231 verifies: REQ-CONFIG-026, REQ-MREG-027
    // A Cancelled market using the token is not re-checked: its failing LPOracle does not block the change.
    function test_TEST_231_setPriceSourceSkipsCancelledMarkets() public {
        (uint256 id,, RegistryLPOracleMock o) = _listMarket();
        o.setFailed(3);
        (address[] memory p, address[] memory a, address[] memory s) = _routes("usdc2");
        vm.prank(address(timelock));
        _expectListing("oracleConfig");
        registry.setPriceSource(address(usdc), p, a, s);
        vm.prank(address(timelock));
        registry.cancelRegistration(id);
        vm.prank(address(timelock));
        registry.setPriceSource(address(usdc), p, a, s);
        assertEq(registry.getToken(address(usdc)).primaryRoute[0], p[0]);
    }

    function _one(
        address x
    ) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = x;
    }

    function _two(
        address x,
        address y
    ) internal pure returns (address[] memory r) {
        r = new address[](2);
        (r[0], r[1]) = (x, y);
    }
}
