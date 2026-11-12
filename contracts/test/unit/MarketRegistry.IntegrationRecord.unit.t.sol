// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {IMarketRegistryApprovals} from "../../src/policy/market-registry/IMarketRegistryApprovals.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {IMarketRegistryEvents} from "../../src/policy/market-registry/IMarketRegistryEvents.sol";
import {IMarketRegistryHubs} from "../../src/policy/market-registry/IMarketRegistryHubs.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryLPVaultMock, RegistryRouteMock, RegistryTokenMock} from "../utils/mocks/MarketRegistryMocks.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice The record of an integration's AMM protocol contracts (REQ-MREG-035): no route of the integration's markets
/// is accepted until the record is finalized; the record is keyed to the chain, the LPVault's address and code hash, its
/// AMM protocol tag and its pool keying; a replacement integration starts with an empty record.
contract MarketRegistryIntegrationRecordUnitTest is MarketRegistryFixture {
    uint256 internal id;
    address internal npm;
    address internal v3Factory;

    /// @dev Every test here builds the record itself.
    function _recordAmmContracts() internal override {}

    function setUp() public {
        _setUpWorld();
        (id,,) = _listMarket();
        npm = address(new RegistryTokenMock(0));
        v3Factory = address(new RegistryTokenMock(0));
    }

    function _pair() internal view returns (address[] memory list) {
        list = new address[](2);
        (list[0], list[1]) = (npm, v3Factory);
    }

    function _record(
        uint32 integrationId,
        address[] memory list
    ) internal {
        vm.prank(address(timelock));
        registry.recordIntegrationContracts(integrationId, list);
    }

    function _finalize(
        uint32 integrationId
    ) internal {
        vm.prank(address(timelock));
        registry.finalizeIntegrationContracts(integrationId);
    }

    function _expectRouteRefused(
        uint8 kind,
        address route
    ) internal {
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.InvalidRoute.selector);
        registry.setRoute(id, address(usdc), address(gho), kind, route);
    }

    function _expectBadFinalize(
        uint32 integrationId
    ) internal {
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryHubs.InvalidIntegration.selector, integrationId));
        registry.finalizeIntegrationContracts(integrationId);
    }

    // TEST-054 verifies: REQ-MREG-035, REQ-CONFIG-040, REQ-CONFIG-060
    // Sources: decisions of 2026-11-11 (no settlement route until the record is recorded and finalized)
    // Kills: removing `!rec.finalized` from `_touchesMarketAmm` lets the second `setRoute` through.
    function test_TEST_054_noRouteUntilTheRecordIsFinalized() public {
        address route = address(_newRoute(address(usdc), address(gho), "dexA"));
        // Nothing recorded: refused.
        _expectRouteRefused(0, route);
        bytes32 key = _recordKeyOf(V3);
        vm.expectEmit(address(registry));
        emit IMarketRegistryApprovals.IntegrationContractsRecorded(V3, key, _pair());
        _record(V3, _pair());
        // Recorded, not finalized: still refused.
        _expectRouteRefused(0, route);
        // Only the admin finalizes.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, APP_ADMIN)
        );
        registry.finalizeIntegrationContracts(V3);
        vm.expectEmit(address(registry));
        emit IMarketRegistryApprovals.IntegrationContractsFinalized(V3, key, 2);
        _finalize(V3);
        vm.prank(address(timelock));
        registry.setRoute(id, address(usdc), address(gho), 0, route);
        (address got, bool usable) = registry.getRoute(id, address(usdc), address(gho), 0);
        assertEq(got, route);
        assertTrue(usable);
    }

    // TEST-054 verifies: REQ-MREG-035
    // Finalizing needs a registered integration, a non-empty record and a record not yet finalized.
    function test_TEST_054_finalizeChecks() public {
        _expectBadFinalize(9);
        _expectBadFinalize(V3);
        _record(V3, _pair());
        _finalize(V3);
        _expectBadFinalize(V3);
        // An addition after finalizing keeps the record final; finalizing again is still refused.
        address[] memory one = new address[](1);
        one[0] = address(new RegistryTokenMock(0));
        _record(V3, one);
        _expectBadFinalize(V3);
        assertEq(registry.integrationContracts(V3).length, 3);
    }

    // TEST-054 verifies: REQ-MREG-035, REQ-CONFIG-040
    // The record is bound to the chain: on another chain ID (a fork of the chain) its key no longer matches, so routes,
    // additions and finalizing are refused until the chain ID is the recorded one again.
    // Kills: dropping `rec.key != _integrationRecordKey(iid)` lets `setRoute` through on the other chain.
    function test_TEST_054_recordKeyedToTheChain() public {
        _record(V3, _pair());
        address route = address(_newRoute(address(usdc), address(gho), "dexA"));
        uint256 chain = block.chainid;
        bytes32 recorded = _recordKeyOf(V3);
        vm.chainId(chain + 1);
        assertTrue(_recordKeyOf(V3) != recorded);
        _expectBadFinalize(V3);
        vm.chainId(chain);
        _finalize(V3);
        vm.chainId(chain + 1);
        _expectRouteRefused(0, route);
        address[] memory one = new address[](1);
        one[0] = address(new RegistryTokenMock(0));
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryHubs.InvalidIntegration.selector, V3));
        registry.recordIntegrationContracts(V3, one);
        vm.chainId(chain);
        vm.prank(address(timelock));
        registry.setRoute(id, address(usdc), address(gho), 0, route);
    }

    // TEST-054 verifies: REQ-MREG-035, REQ-CONFIG-040
    // The record is bound to the LPVault's code (its version): other code at the same address makes the key differ, so
    // no route is accepted and nothing more is recorded under the old key.
    function test_TEST_054_recordKeyedToTheIntegrationCode() public {
        _record(V3, _pair());
        _finalize(V3);
        bytes32 before = _recordKeyOf(V3);
        address route = address(_newRoute(address(usdc), address(gho), "dexA"));
        // One unreachable byte after the code changes the code hash and nothing else.
        vm.etch(address(lpVault), bytes.concat(address(lpVault).code, hex"00"));
        assertTrue(_recordKeyOf(V3) != before);
        _expectRouteRefused(0, route);
        address[] memory one = new address[](1);
        one[0] = address(new RegistryTokenMock(0));
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryHubs.InvalidIntegration.selector, V3));
        registry.recordIntegrationContracts(V3, one);
    }

    // TEST-054 verifies: REQ-MREG-035, REQ-CONFIG-075
    // A replacement integration is a new identifier with a new LPVault: its key differs and its record starts empty, so
    // it is recorded, checked and finalized afresh; the old integration's record is unchanged.
    function test_TEST_054_replacementIntegrationStartsEmpty() public {
        _record(V3, _pair());
        _finalize(V3);
        RegistryLPVaultMock lp2 = new RegistryLPVaultMock(2, address(collat), lockAddr);
        lp2.setRegistry(address(registry));
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (address(usdc), address(usdt));
        lp2.setPoolTokens(toks, 18);
        vm.startPrank(address(timelock));
        factory.registerIntegration(2, address(lp2));
        registry.registerIntegration(2, address(lp2), makeAddr("clPricing2"));
        vm.stopPrank();
        assertTrue(_recordKeyOf(2) != _recordKeyOf(V3));
        assertEq(registry.integrationContracts(2).length, 0);
        _expectBadFinalize(2);
        // The same AMM contracts may serve the replacement; they are recorded under its own key.
        vm.expectEmit(address(registry));
        emit IMarketRegistryApprovals.IntegrationContractsRecorded(2, _recordKeyOf(2), _pair());
        _record(2, _pair());
        _finalize(2);
        assertEq(registry.integrationContracts(V3).length, 2);
    }

    // TEST-054 verifies: REQ-MREG-035, REQ-MREG-020, REQ-CONFIG-040, REQ-CONFIG-061, REQ-CONFIG-062
    // Sources: decisions of 2026-11-11 (an addition applies at once and re-checks existing routes)
    // An addition after finalizing disables, in the same call, every active route of the integration's markets that
    // names an added contract; the others stay usable, and the disabled route cannot be restored.
    // Kills: removing the `_recheckRoutes` call leaves the backup usable.
    function test_TEST_054_additionAfterFinalizeDisablesRoutesThroughIt() public {
        _record(V3, _pair());
        _finalize(V3);
        address later = address(new RegistryTokenMock(0));
        address[] memory deps = new address[](2);
        (deps[0], deps[1]) = (makeAddr("uniB"), later);
        address unsafe = address(new RegistryRouteMock(address(usdc), address(gho), address(lpVaultSwap), deps));
        address safe = _setRoute(id, address(usdc), address(gho), 0, "dexA");
        vm.prank(address(timelock));
        registry.setRoute(id, address(usdc), address(gho), 1, unsafe);
        address usdtPrimary = _setRoute(id, address(usdt), address(gho), 0, "dexC");
        address[] memory one = new address[](1);
        one[0] = later;
        vm.expectEmit(address(registry));
        emit IMarketRegistryApprovals.IntegrationContractsRecorded(V3, _recordKeyOf(V3), one);
        vm.expectEmit(address(registry));
        emit IMarketRegistryEvents.RouteDisabled(id, address(usdc), address(gho), 1, address(timelock));
        _record(V3, one);
        (address r, bool usable) = registry.getRoute(id, address(usdc), address(gho), 1);
        assertEq(r, unsafe);
        assertFalse(usable, "route through the added contract still usable");
        (r, usable) = registry.getRoute(id, address(usdc), address(gho), 0);
        assertTrue(r == safe && usable);
        (r, usable) = registry.getRoute(id, address(usdt), address(gho), 0);
        assertTrue(r == usdtPrimary && usable);
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.InvalidRoute.selector);
        registry.restoreRoute(id, address(usdc), address(gho), 1, unsafe);
    }

    // TEST-054 verifies: REQ-MREG-035, REQ-CONFIG-040
    // A route whose dependency list cannot be read when an addition re-checks it is disabled (fail closed); an addition
    // that names nothing a route depends on disables nothing.
    function test_TEST_054_unreadableRouteIsDisabledByARecheck() public {
        _record(V3, _pair());
        _finalize(V3);
        address primary = _setRoute(id, address(usdc), address(gho), 0, "dexA");
        address backup = _setRoute(id, address(usdc), address(gho), 1, "dexB");
        vm.mockCallRevert(primary, abi.encodeCall(ISettlementRoute.dependencies, ()), "");
        address[] memory one = new address[](1);
        one[0] = address(new RegistryTokenMock(0));
        vm.recordLogs();
        _record(V3, one);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // The record event and exactly one RouteDisabled.
        uint256 disabled = 0;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == IMarketRegistryEvents.RouteDisabled.selector) ++disabled;
        }
        assertEq(disabled, 1);
        (, bool usable) = registry.getRoute(id, address(usdc), address(gho), 0);
        assertFalse(usable);
        (address r, bool ok) = registry.getRoute(id, address(usdc), address(gho), 1);
        assertTrue(r == backup && ok);
    }

    // TEST-054 verifies: REQ-MREG-035, REQ-MREG-030
    // The re-check reads the slots of the market's current registration only, and leaves a Cancelled market alone.
    function test_TEST_054_recheckSkipsCancelledMarkets() public {
        _record(V3, _pair());
        _finalize(V3);
        address later = address(new RegistryTokenMock(0));
        address[] memory deps = new address[](1);
        deps[0] = later;
        address viaLater = address(new RegistryRouteMock(address(usdc), address(gho), address(lpVaultSwap), deps));
        vm.prank(address(timelock));
        registry.setRoute(id, address(usdc), address(gho), 0, viaLater);
        vm.prank(address(timelock));
        registry.cancelRegistration(id);
        address[] memory one = new address[](1);
        one[0] = later;
        vm.recordLogs();
        _record(V3, one);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IMarketRegistryEvents.RouteDisabled.selector, "cancelled market touched");
        }
    }
}
