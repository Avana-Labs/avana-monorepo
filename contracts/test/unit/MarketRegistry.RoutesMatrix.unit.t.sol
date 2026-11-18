// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistry} from "../../src/policy/market-registry/IMarketRegistry.sol";
import {IMarketRegistryBase} from "../../src/policy/market-registry/IMarketRegistryBase.sol";
import {MarketDef, PauseReason} from "../../src/types/MarketTypes.sol";
import {PositionShape, ShapeKind} from "../../src/types/PositionTypes.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {
    RegistryAvanaFirstLossReserveMock,
    RegistryLPOracleMock,
    RegistryRouteMock,
    RegistryTokenMock
} from "../utils/mocks/MarketRegistryMocks.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Swap-route slots across market statuses, debt-asset classes and kinds; disable and restore across slots,
/// markets and relistings.
contract MarketRegistryRoutesMatrixUnitTest is MarketRegistryFixture {
    uint256 internal id;
    address internal vt;
    RegistryLPOracleMock internal lpo;

    function setUp() public {
        _setUpWorld();
        (id, vt, lpo) = _listMarket();
    }

    function _route(
        address tokenIn,
        address tokenOut,
        string memory dep
    ) internal returns (address) {
        return address(_newRoute(tokenIn, tokenOut, dep));
    }

    function _setAs(
        uint256 marketId,
        address token,
        address asset,
        uint8 kind,
        address route
    ) internal returns (bool ok, bytes memory ret) {
        vm.prank(address(timelock));
        (ok, ret) = address(registry).call(abi.encodeCall(registry.setRoute, (marketId, token, asset, kind, route)));
    }

    // TEST-054 verifies: REQ-CONFIG-059, REQ-CONFIG-060, REQ-CONFIG-039
    // Sources: 5.1 TEST-054
    // A slot can be set on a Registered, Active or Offboarding market and never on an unknown, Cancelled or Closed one.
    function test_TEST_054_setRouteAcrossMarketStatuses() public {
        address r = _route(address(usdc), address(gho), "dexA");
        // Registered.
        (bool ok,) = _setAs(id, address(usdc), address(gho), 0, r);
        assertTrue(ok, "Registered");
        // Active and Offboarding.
        _prepareActivation(id, vt);
        vm.prank(address(timelock));
        registry.activateMarket(id);
        (ok,) = _setAs(id, address(usdc), address(gho), 0, r);
        assertTrue(ok, "Active");
        vm.prank(address(timelock));
        registry.setMarketOffboarding(id);
        (ok,) = _setAs(id, address(usdc), address(gho), 0, r);
        assertTrue(ok, "Offboarding");
        // Closed.
        vm.warp(block.timestamp + 5 days);
        registry.closeMarket(id);
        bytes memory ret;
        (ok, ret) = _setAs(id, address(usdc), address(gho), 0, r);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(IMarketRegistryBase.UnknownMarket.selector, id));
        // Cancelled and unknown.
        (uint256 c,,) = _listWide();
        vm.prank(address(timelock));
        registry.cancelRegistration(c);
        (ok, ret) = _setAs(c, address(usdc), address(gho), 0, r);
        assertEq(ret, abi.encodeWithSelector(IMarketRegistryBase.UnknownMarket.selector, c));
        (ok, ret) = _setAs(0, address(usdc), address(gho), 0, r);
        assertEq(ret, abi.encodeWithSelector(IMarketRegistryBase.UnknownMarket.selector, 0));
    }

    function _listWide() internal returns (uint256 m, address token, RegistryLPOracleMock o) {
        PositionShape memory wide = PositionShape(ShapeKind.TickRange, -100, 100);
        (token, o) = _deployTokenAndOracle(registry.marketCount() + 1, wide);
        MarketDef memory d = _marketDef(token, address(o));
        d.shape = wide;
        vm.prank(address(timelock));
        m = registry.listCollateralMarket(d);
    }

    // TEST-054 verifies: REQ-CONFIG-039, REQ-CONFIG-060, Q-379
    // The out-asset of a slot is an enabled debt asset of the Spoke, any listed token, or an asset with a Coverage
    // Spoke on the market's home Hub (so the routes can be set in the batch that enables it); anything else is
    // TokenNotListed(asset).
    function test_TEST_054_debtAssetClassesOfASlot() public {
        // Enabled debt asset.
        (bool ok,) = _setAs(id, address(usdc), address(gho), 0, _route(address(usdc), address(gho), "d1"));
        assertTrue(ok, "enabled debt asset");
        // Listed token that is no debt asset.
        (ok,) = _setAs(id, address(usdc), address(usdt), 0, _route(address(usdc), address(usdt), "d2"));
        assertTrue(ok, "listed token");
        // Unlisted asset with a First-Loss Reserve on the home Hub.
        RegistryTokenMock dai = new RegistryTokenMock(18);
        hub.setAsset(address(dai), 4);
        RegistryAvanaFirstLossReserveMock cs = new RegistryAvanaFirstLossReserveMock(address(hub), address(dai), 4);
        bytes memory ret;
        (ok, ret) = _setAs(id, address(usdc), address(dai), 0, _route(address(usdc), address(dai), "d3"));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(IMarketRegistryBase.TokenNotListed.selector, address(dai)));
        vm.prank(address(timelock));
        registry.setAvanaFirstLossReserve(address(hub), address(dai), address(cs));
        (ok,) = _setAs(id, address(usdc), address(dai), 0, _route(address(usdc), address(dai), "d3"));
        assertTrue(ok, "asset with a First-Loss Reserve");
    }

    // TEST-054 verifies: REQ-CONFIG-060
    // Only kinds 0 (primary) and 1 (backup) exist: every other kind is refused, and reads (address(0), false).
    function testFuzz_TEST_054_onlyTwoKinds(
        uint8 kind
    ) public {
        address r = _route(address(usdc), address(gho), "dexK");
        (bool ok, bytes memory ret) = _setAs(id, address(usdc), address(gho), kind, r);
        if (kind <= 1) {
            assertTrue(ok);
            (address got, bool usable) = registry.getRoute(id, address(usdc), address(gho), kind);
            assertEq(got, r);
            assertTrue(usable);
        } else {
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(IMarketRegistryBase.InvalidRoute.selector));
            (address got, bool usable) = registry.getRoute(id, address(usdc), address(gho), kind);
            assertEq(got, address(0));
            assertFalse(usable);
        }
    }

    // TEST-054 verifies: REQ-CONFIG-060, REQ-MREG-014
    // The backup slot's event and record carry kind 1; the two slots are independent records.
    function test_TEST_054_backupSlotRecordAndEvent() public {
        address p = _route(address(usdt), address(gho), "dexP");
        address b = _route(address(usdt), address(gho), "dexQ");
        vm.prank(address(timelock));
        registry.setRoute(id, address(usdt), address(gho), 0, p);
        vm.expectEmit(address(registry));
        emit IMarketRegistryBase.RouteSet(id, address(usdt), address(gho), 1, b);
        vm.prank(address(timelock));
        registry.setRoute(id, address(usdt), address(gho), 1, b);
        (address r0,) = registry.getRoute(id, address(usdt), address(gho), 0);
        (address r1,) = registry.getRoute(id, address(usdt), address(gho), 1);
        assertEq(r0, p);
        assertEq(r1, b);
        // Disabling the backup leaves the primary usable.
        vm.prank(address(timelock));
        registry.disableRoute(id, address(usdt), address(gho), 1);
        (, bool u0) = registry.getRoute(id, address(usdt), address(gho), 0);
        (, bool u1) = registry.getRoute(id, address(usdt), address(gho), 1);
        assertTrue(u0);
        assertFalse(u1);
    }

    // TEST-054 verifies: REQ-CONFIG-062, REQ-MREG-012, Q-151, REQ-ACCESS-048, REQ-ACCESS-127, REQ-ROUTE-019
    // A route approved in one slot cannot be restored into another slot, another market, or another debt asset.
    function test_TEST_054_restoreIsBoundToItsOwnSlot() public {
        address p = _setRoute(id, address(usdc), address(gho), 0, "dexA");
        (uint256 other,,) = _listWide();
        vm.startPrank(address(timelock));
        registry.disableRoute(id, address(usdc), address(gho), 0);
        vm.expectRevert(IMarketRegistryBase.NotPreviouslyApproved.selector);
        registry.restoreRoute(id, address(usdc), address(gho), 1, p);
        vm.expectRevert(IMarketRegistryBase.NotPreviouslyApproved.selector);
        registry.restoreRoute(other, address(usdc), address(gho), 0, p);
        vm.expectRevert(IMarketRegistryBase.NotPreviouslyApproved.selector);
        registry.restoreRoute(id, address(usdc), address(usdt), 0, p);
        registry.restoreRoute(id, address(usdc), address(gho), 0, p);
        vm.stopPrank();
        (, bool usable) = registry.getRoute(id, address(usdc), address(gho), 0);
        assertTrue(usable);
    }

    // TEST-054 verifies: REQ-CONFIG-062, REQ-CONFIG-060, REQ-MREG-012, REQ-ROUTE-019, REQ-ROUTE-030
    // A restore re-runs the slot checks: a previously approved route that no longer supports the token class, or whose
    // market has closed, is refused.
    function test_TEST_054_restoreRerunsTheChecks() public {
        address p = _setRoute(id, address(usdc), address(gho), 0, "dexA");
        vm.prank(address(timelock));
        registry.disableRoute(id, address(usdc), address(gho), 0);
        // The route no longer supports the Spoke's token class.
        RegistryRouteMock(p).setClassOk(false);
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryBase.InvalidRoute.selector);
        registry.restoreRoute(id, address(usdc), address(gho), 0, p);
        RegistryRouteMock(p).setClassOk(true);
        // Closed market.
        _setRoute(id, address(usdc), address(gho), 1, "dexB");
        _prepareActivation(id, vt);
        // Activation set slot 0 again; a replaced route leaves the approved set (REQ-ROUTE-017), so the slot's current
        // route is the one to restore from here on.
        (p,) = registry.getRoute(id, address(usdc), address(gho), 0);
        vm.startPrank(address(timelock));
        registry.restoreRoute(id, address(usdc), address(gho), 0, p);
        registry.activateMarket(id);
        registry.setMarketOffboarding(id);
        registry.disableRoute(id, address(usdc), address(gho), 0);
        vm.stopPrank();
        vm.warp(block.timestamp + 5 days);
        registry.closeMarket(id);
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.UnknownMarket.selector, id));
        registry.restoreRoute(id, address(usdc), address(gho), 0, p);
    }

    // TEST-252 verifies: REQ-MREG-030, REQ-CONFIG-062
    // After a relisting the old approvals are hidden too: a route approved before the cancel cannot be restored.
    function test_TEST_252_relistHidesOldApprovals() public {
        address p = _setRoute(id, address(usdc), address(gho), 0, "dexA");
        vm.prank(address(timelock));
        registry.cancelRegistration(id);
        vm.prank(address(timelock));
        registry.listCollateralMarket(_marketDef(vt, address(lpo)));
        (address cur, bool usable) = registry.getRoute(id, address(usdc), address(gho), 0);
        assertEq(cur, address(0));
        assertFalse(usable);
        vm.startPrank(address(timelock));
        vm.expectRevert(IMarketRegistryBase.InvalidRoute.selector);
        registry.disableRoute(id, address(usdc), address(gho), 0);
        vm.expectRevert(IMarketRegistryBase.NotPreviouslyApproved.selector);
        registry.restoreRoute(id, address(usdc), address(gho), 0, p);
        // Approved again in the new epoch, it can be restored again.
        registry.setRoute(id, address(usdc), address(gho), 0, p);
        registry.disableRoute(id, address(usdc), address(gho), 0);
        registry.restoreRoute(id, address(usdc), address(gho), 0, p);
        vm.stopPrank();
    }

    // TEST-054 verifies: REQ-CONFIG-061, REQ-MREG-012, REQ-ACCESS-047, REQ-ROUTE-018
    // Disabling an already disabled slot is accepted again (the record stays disabled) and emits again; the route stays
    // recorded so it can be restored.
    function test_TEST_054_disableIsIdempotentAndKeepsTheRoute() public {
        address p = _setRoute(id, address(usdc), address(gho), 0, "dexA");
        for (uint256 i = 0; i < 2; ++i) {
            vm.expectEmit(address(registry));
            emit IMarketRegistryBase.RouteDisabled(id, address(usdc), address(gho), 0, address(timelock));
            vm.prank(address(timelock));
            registry.disableRoute(id, address(usdc), address(gho), 0);
            (address cur, bool usable) = registry.getRoute(id, address(usdc), address(gho), 0);
            assertEq(cur, p);
            assertFalse(usable);
        }
    }

    // TEST-168 verifies: REQ-ROUTE-020, REQ-ROUTE-018, REQ-ROUTE-038, Q-227
    // Sources: 2.12 REQ-ROUTE-020 (no route quarantine; a suspect route is disabled, guardians stop new activity)
    /// @notice A route has no quarantine or suspension state: no such selector exists; neither guardian can disable a
    /// route in either slot; a guardian's freeze or pause leaves both routes usable, so liquidation keeps its path;
    /// and only the timelock's `disableRoute` takes a route out of use, in the primary and the backup slot alike.
    /// @dev Kills: a quarantine or suspension selector added to the MarketRegistry, a guardian path into
    /// `disableRoute`, and a freeze or pause that disables or hides routes.
    function test_TEST_168_noRouteQuarantine() public {
        string[4] memory absent = [
            "quarantineRoute(uint256,address,address,uint8)",
            "unquarantineRoute(uint256,address,address,uint8)",
            "suspendRoute(uint256,address,address,uint8)",
            "resumeRoute(uint256,address,address,uint8)"
        ];
        for (uint256 i = 0; i < absent.length; ++i) {
            (bool ok, bytes memory ret) =
                address(registry).call(abi.encodeWithSignature(absent[i], id, address(usdc), address(gho), uint8(0)));
            assertFalse(ok, absent[i]);
            assertEq(ret.length, 0, absent[i]);
        }
        address[2] memory routes = [
            _setRoute(id, address(usdc), address(gho), 0, "dexA"), _setRoute(id, address(usdc), address(gho), 1, "dexB")
        ];
        address[2] memory guardians = [emergencyGuardian, aaveGuardian];
        for (uint8 kind = 0; kind < 2; ++kind) {
            for (uint256 g = 0; g < 2; ++g) {
                vm.prank(guardians[g]);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IAccessControl.AccessControlUnauthorizedAccount.selector, guardians[g], APP_ADMIN
                    )
                );
                registry.disableRoute(id, address(usdc), address(gho), kind);
            }
        }
        uint256 snap = vm.snapshotState();
        vm.prank(emergencyGuardian);
        registry.freeze(address(hub));
        _assertUsable(routes, true);
        vm.revertToState(snap);
        vm.prank(emergencyGuardian);
        registry.pause(address(hub), PauseReason.General);
        _assertUsable(routes, true);
        vm.startPrank(address(timelock));
        registry.disableRoute(id, address(usdc), address(gho), 0);
        registry.disableRoute(id, address(usdc), address(gho), 1);
        vm.stopPrank();
        _assertUsable(routes, false);
    }

    function _assertUsable(
        address[2] memory routes,
        bool expected
    ) internal view {
        for (uint8 kind = 0; kind < 2; ++kind) {
            (address r, bool usable) = registry.getRoute(id, address(usdc), address(gho), kind);
            assertEq(r, routes[kind], "the route stays recorded");
            assertEq(usable, expected, "usable");
        }
    }
}
