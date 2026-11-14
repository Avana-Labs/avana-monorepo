// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryApprovals} from "../../src/policy/market-registry/IMarketRegistryApprovals.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {IMarketRegistryEvents} from "../../src/policy/market-registry/IMarketRegistryEvents.sol";
import {IMarketRegistryHubs} from "../../src/policy/market-registry/IMarketRegistryHubs.sol";
import {RiskTier} from "../../src/policy/market-registry/types/RiskTier.sol";
import {SpokeDef} from "../../src/policy/market-registry/types/SpokeDef.sol";
import {DriftReason} from "../../src/types/DriftReason.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {
    RegistryAaveOracleMock,
    RegistryHubMock,
    RegistrySpokeImplMock,
    RegistrySpokeMock
} from "../utils/mocks/MarketRegistryAaveMocks.sol";
import {
    RegistryAvanaFirstLossReserveMock,
    RegistryFlashSourceMock,
    RegistryLPVaultMock
} from "../utils/mocks/MarketRegistryMocks.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Hubs, AMM integrations, First-Loss Reserves, cross-Hub lines, the flash source and CDP Spoke records.
contract MarketRegistryHubsUnitTest is MarketRegistryFixture {
    RegistryHubMock internal hub2;
    RegistrySpokeMock internal spoke2;
    RegistryAaveOracleMock internal oracle2;

    function setUp() public {
        _setUpWorld();
        hub2 = new RegistryHubMock();
        spoke2 = new RegistrySpokeMock();
        oracle2 = new RegistryAaveOracleMock();
        spoke2.setOracle(address(oracle2));
        spoke2.setImplementation(address(spokeImpl));
        oracle2.setSpoke(address(spoke2));
    }

    function _spoke2Def() internal view returns (SpokeDef memory d) {
        d = SpokeDef(false, address(hub2), V3, RiskTier.Correlated, address(spokeImpl), address(oracle2));
    }

    // TEST-285 verifies: REQ-CONFIG-083, REQ-CONFIG-005, INV-095, Q-388
    function test_TEST_285_recordHubChecks() public {
        vm.startPrank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryHubs.InvalidHub.selector, address(0)));
        registry.recordHub(address(0), RiskTier.Stable);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryHubs.InvalidHub.selector, address(hub)));
        registry.recordHub(address(hub), RiskTier.Stable);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryHubs.InvalidHub.selector, address(hub2)));
        registry.recordHub(address(hub2), RiskTier.None);
        vm.expectRevert(IMarketRegistryErrors.InvalidRoute.selector);
        registry.recordHub(aaveV3Pool, RiskTier.Stable);
        vm.expectEmit(address(registry));
        emit IMarketRegistryHubs.HubRecorded(address(hub2), RiskTier.Correlated);
        registry.recordHub(address(hub2), RiskTier.Correlated);
        vm.stopPrank();
        assertTrue(registry.isRecordedHub(address(hub2)));
        assertEq(uint8(registry.hubTier(address(hub2))), uint8(RiskTier.Correlated));
        address[] memory hubs = registry.getHubs();
        assertEq(hubs.length, 2);
        assertEq(hubs[1], address(hub2));
    }

    // TEST-285 verifies: REQ-CONFIG-005, INV-095, Q-386, Q-388, REQ-ACCESS-174
    // Sources: 5.1 TEST-285
    function test_TEST_285_flashSourceLenderNeverAHub() public {
        RegistryFlashSourceMock viaHub = new RegistryFlashSourceMock(address(hub), address(lpVaultSwap));
        RegistryFlashSourceMock wrongSwap = new RegistryFlashSourceMock(aaveV3Pool, alice);
        RegistryFlashSourceMock good = new RegistryFlashSourceMock(aaveV3Pool, address(lpVaultSwap));
        vm.startPrank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.InvalidRoute.selector);
        registry.setFlashSource(address(viaHub));
        vm.expectRevert(IMarketRegistryErrors.InvalidRoute.selector);
        registry.setFlashSource(address(wrongSwap));
        vm.expectRevert(IMarketRegistryErrors.InvalidRoute.selector);
        registry.setFlashSource(address(0));
        registry.recordHub(address(hub2), RiskTier.Correlated);
        RegistryFlashSourceMock viaHub2 = new RegistryFlashSourceMock(address(hub2), address(lpVaultSwap));
        vm.expectRevert(IMarketRegistryErrors.InvalidRoute.selector);
        registry.setFlashSource(address(viaHub2));
        registry.setFlashSource(address(good));
        vm.stopPrank();
        assertEq(registry.flashSource(), address(good));
    }

    // TEST-264 verifies: REQ-CONFIG-075, Q-313, Q-376
    function test_TEST_264_registerIntegrationPinsTheLPVault() public {
        RegistryLPVaultMock v2 = new RegistryLPVaultMock(2, address(collat), lockAddr);
        v2.setRegistry(address(registry));
        vm.startPrank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryHubs.InvalidIntegration.selector, 2));
        registry.registerIntegration(2, address(v2), alice);
        factory.registerIntegration(2, address(v2));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryHubs.InvalidIntegration.selector, 0));
        registry.registerIntegration(0, address(v2), alice);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryHubs.InvalidIntegration.selector, V3));
        registry.registerIntegration(V3, address(v2), alice);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryHubs.InvalidIntegration.selector, 3));
        registry.registerIntegration(3, address(v2), alice);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryHubs.InvalidIntegration.selector, 2));
        registry.registerIntegration(2, address(v2), address(0));
        v2.setRegistry(alice);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryHubs.InvalidIntegration.selector, 2));
        registry.registerIntegration(2, address(v2), alice);
        v2.setRegistry(address(registry));
        registry.registerIntegration(2, address(v2), alice);
        vm.stopPrank();
        (address lpv, address pricing) = registry.integrationOf(2);
        assertEq(lpv, address(v2));
        assertEq(pricing, alice);
        assertEq(registry.integrationIdOf(address(v2)), 2);
    }

    // TEST-273 verifies: REQ-MREG-009, REQ-CONFIG-081, Q-379
    function test_TEST_273_firstLossReserveRecord() public {
        RegistryAvanaFirstLossReserveMock wrongHub =
            new RegistryAvanaFirstLossReserveMock(address(hub2), address(gho), 0);
        RegistryAvanaFirstLossReserveMock wrongId =
            new RegistryAvanaFirstLossReserveMock(address(hub), address(usdc), 9);
        hub.setAsset(address(usdc), 2);
        vm.startPrank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryHubs.InvalidHub.selector, address(hub2)));
        registry.setAvanaFirstLossReserve(address(hub2), address(gho), address(wrongHub));
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryHubs.InvalidAvanaFirstLossReserve.selector, address(wrongId))
        );
        registry.setAvanaFirstLossReserve(address(hub), address(usdc), address(wrongId));
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryHubs.InvalidAvanaFirstLossReserve.selector, address(wrongHub))
        );
        registry.setAvanaFirstLossReserve(address(hub), address(gho), address(wrongHub));
        vm.stopPrank();
        assertEq(registry.firstLossReserveOf(address(hub), address(gho)), address(ghoCoverage));
    }

    // TEST-273 verifies: REQ-CONFIG-081, REQ-MREG-009, REQ-FLR-043, ATTACK-163, Q-378, REQ-ACCESS-175
    // Sources: 5.1 TEST-273
    function test_TEST_273_crossHubLines() public {
        vm.startPrank(address(timelock));
        registry.recordHub(address(hub2), RiskTier.Correlated);
        registry.deployCdpSpoke(_spoke2Def());
        vm.expectRevert(IMarketRegistryHubs.CrossHubLinesDisabled.selector);
        registry.setCrossHubLine(address(hub), address(gho), address(spoke2), 1);
        // A cap of 0 is always accepted.
        registry.setCrossHubLine(address(hub), address(gho), address(spoke2), 0);
        registry.setCrossHubLinesEnabled(true);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryHubs.InvalidHub.selector, address(hub2)));
        registry.setCrossHubLine(address(hub2), address(gho), address(spoke2), 1);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.InvalidSpoke.selector, alice));
        registry.setCrossHubLine(address(hub), address(gho), alice, 1);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryHubs.CrossHubCapExceeded.selector, 4e24 + 1, 4e24));
        registry.setCrossHubLine(address(hub), address(gho), address(spoke2), 4e24 + 1);
        vm.expectEmit(address(registry));
        emit IMarketRegistryHubs.CrossHubLineSet(address(hub), address(gho), address(spoke2), 3e24, 3e24);
        registry.setCrossHubLine(address(hub), address(gho), address(spoke2), 3e24);
        vm.stopPrank();
        assertEq(registry.crossHubLineCap(address(hub), address(gho), address(spoke2)), 3e24);
        assertEq(registry.crossHubLineTotal(address(hub), address(gho)), 3e24);
        // Coverage falls: a cut still passes, a raise does not.
        ghoCoverage.setFunded(1e24, false);
        vm.startPrank(address(timelock));
        registry.setCrossHubLine(address(hub), address(gho), address(spoke2), 2e24);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryHubs.CrossHubCapExceeded.selector, 2.5e24, 1e24));
        registry.setCrossHubLine(address(hub), address(gho), address(spoke2), 2.5e24);
        registry.setCrossHubLinesEnabled(false);
        vm.stopPrank();
        assertFalse(registry.crossHubLinesEnabled());
        assertEq(registry.crossHubLineTotal(address(hub), address(gho)), 2e24);
    }

    // TEST-185 verifies: REQ-CONFIG-077, REQ-CONFIG-074, REQ-CONFIG-083, REQ-CONFIG-016, ATTACK-121, Q-312, REQ-ACCESS-133
    // Sources: 5.1 TEST-185
    function test_TEST_185_deployCdpSpokeChecks() public {
        vm.prank(address(timelock));
        registry.recordHub(address(hub2), RiskTier.Correlated);
        SpokeDef memory d = _spoke2Def();
        // Oracle decimals other than 8.
        oracle2.setDecimals(18);
        _expectInvalidSpoke(d, address(spoke2));
        oracle2.setDecimals(8);
        // Implementation slot other than the named implementation.
        spoke2.setImplementation(alice);
        _expectInvalidSpoke(d, address(spoke2));
        // An implementation whose code differs from the approved standard implementation.
        RegistrySpokeMock otherCode = new RegistrySpokeMock();
        spoke2.setImplementation(address(otherCode));
        d.implementation = address(otherCode);
        _expectInvalidSpoke(d, address(spoke2));
        // A second deployment of the same audited code passes the code-hash check.
        RegistrySpokeImplMock sameCode = new RegistrySpokeImplMock();
        spoke2.setImplementation(address(sameCode));
        d.implementation = address(sameCode);
        // Hub tier mismatch, unknown integration, oracle naming another Spoke.
        d.riskTier = RiskTier.Volatile;
        _expectInvalidSpoke(d, address(spoke2));
        d.riskTier = RiskTier.Correlated;
        d.integrationId = 9;
        _expectInvalidSpoke(d, address(spoke2));
        d.integrationId = V3;
        spoke2.setOracle(alice);
        _expectInvalidSpoke(d, address(spoke2));
        spoke2.setOracle(address(oracle2));
        // Drift check failing.
        rm.setDrift(true);
        _expectInvalidSpoke(d, address(spoke2));
        rm.setDrift(false);
        vm.expectEmit(address(registry));
        emit IMarketRegistryEvents.SpokeApproved(
            address(spoke2), address(hub2), V3, address(sameCode), address(oracle2)
        );
        vm.prank(address(timelock));
        assertEq(registry.deployCdpSpoke(d), address(spoke2));
        assertEq(registry.hubOf(address(spoke2)), address(hub2));
        assertEq(registry.getSpokes().length, 2);
        // A second Spoke for the same (Hub, integration, tier).
        RegistrySpokeMock spoke3 = new RegistrySpokeMock();
        RegistryAaveOracleMock oracle3 = new RegistryAaveOracleMock();
        spoke3.setOracle(address(oracle3));
        spoke3.setImplementation(address(spokeImpl));
        oracle3.setSpoke(address(spoke3));
        SpokeDef memory d3 = d;
        (d3.aaveOracle, d3.implementation) = (address(oracle3), address(spokeImpl));
        _expectInvalidSpoke(d3, address(spoke3));
    }

    // TEST-185 verifies: REQ-CONFIG-016, REQ-CONFIG-074
    function test_TEST_185_reapprovalAfterAaveUpgrade() public {
        RegistrySpokeImplMock upgraded = new RegistrySpokeImplMock();
        spoke.setImplementation(address(upgraded));
        assertEq(_drift(), uint8(DriftReason.SpokeImplementation), "SpokeImplementation drift before re-approval");
        SpokeDef memory d = _spokeDef();
        d.implementation = address(upgraded);
        vm.prank(address(timelock));
        registry.deployCdpSpoke(d);
        assertEq(registry.getSpoke(address(spoke)).implementation, address(upgraded));
        assertEq(registry.getSpokes().length, 1);
        assertEq(uint8(_drift()), 0);
        d.riskTier = RiskTier.Correlated;
        _expectInvalidSpoke(d, address(spoke));
    }

    // TEST-185 verifies: REQ-CONFIG-074, REQ-CONFIG-077, REQ-CONFIG-016, REQ-ACCESS-133, REQ-ACCESS-177
    // Sources: MarketRegistry review 2026-11-10 finding 1 (approved Spoke code hashes)
    function test_TEST_185_approvedSpokeCodeHashes() public {
        vm.prank(address(timelock));
        registry.recordHub(address(hub2), RiskTier.Correlated);
        RegistrySpokeMock otherCode = new RegistrySpokeMock();
        bytes32 h = address(otherCode).codehash;
        spoke2.setImplementation(address(otherCode));
        SpokeDef memory d = _spoke2Def();
        d.implementation = address(otherCode);
        // Not approved yet: the code differs from the standard implementation's.
        assertFalse(registry.isApprovedSpokeCodeHash(h));
        assertTrue(registry.isApprovedSpokeCodeHash(address(spokeImpl).codehash));
        _expectInvalidSpoke(d, address(spoke2));
        // Only the admin approves, never 0, the empty-code hash or a hash already approved.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, APP_ADMIN)
        );
        registry.approveSpokeCodeHash(h);
        _expectBadHash(bytes32(0));
        _expectBadHash(keccak256(""));
        _expectBadHash(address(spokeImpl).codehash);
        assertFalse(registry.isApprovedSpokeCodeHash(bytes32(0)));
        assertFalse(registry.isApprovedSpokeCodeHash(keccak256("")));
        vm.expectEmit(address(registry));
        emit IMarketRegistryApprovals.SpokeCodeHashApproved(h);
        vm.prank(address(timelock));
        registry.approveSpokeCodeHash(h);
        assertTrue(registry.isApprovedSpokeCodeHash(h));
        _expectBadHash(h);
        vm.prank(address(timelock));
        registry.deployCdpSpoke(d);
        (address impl, bytes32 codeHash, bool current) = registry.spokeImplementationStatus(address(spoke2));
        assertEq(impl, address(otherCode));
        assertEq(codeHash, h);
        assertTrue(current);
    }

    // TEST-185 verifies: REQ-CONFIG-074, REQ-CONFIG-016, REQ-CONFIG-076
    // Sources: Step 2 decisions 2026-11-11 (upgrade detection binds the implementation behind the proxy)
    function test_TEST_185_implementationStatusFollowsTheProxySlot() public {
        (address impl, bytes32 codeHash, bool current) = registry.spokeImplementationStatus(address(spoke));
        assertEq(impl, address(spokeImpl));
        assertEq(codeHash, address(spokeImpl).codehash);
        assertTrue(current);
        // An unrecorded Spoke, even an address with no code, reads all zero and never reverts.
        (impl, codeHash, current) = registry.spokeImplementationStatus(alice);
        assertEq(impl, address(0));
        assertEq(codeHash, bytes32(0));
        assertFalse(current);
        (impl,, current) = registry.spokeImplementationStatus(address(spoke2));
        assertFalse(current);
        // The Aave DAO upgrades the proxy, even to a deployment of the same audited code: not current until re-approved.
        RegistrySpokeImplMock sameCode = new RegistrySpokeImplMock();
        spoke.setImplementation(address(sameCode));
        (impl, codeHash, current) = registry.spokeImplementationStatus(address(spoke));
        assertEq(impl, address(sameCode));
        assertEq(codeHash, address(spokeImpl).codehash);
        assertFalse(current);
        assertEq(_drift(), uint8(DriftReason.SpokeImplementation));
        // An unreadable slot is not current either.
        spoke.setRevertExtSload(true);
        (impl, codeHash, current) = registry.spokeImplementationStatus(address(spoke));
        assertEq(impl, address(0));
        assertFalse(current);
        assertEq(_drift(), uint8(DriftReason.SpokeImplementation));
        spoke.setRevertExtSload(false);
        SpokeDef memory d = _spokeDef();
        d.implementation = address(sameCode);
        vm.prank(address(timelock));
        registry.deployCdpSpoke(d);
        (,, current) = registry.spokeImplementationStatus(address(spoke));
        assertTrue(current);
    }

    // TEST-285 verifies: REQ-CONFIG-005, Q-386
    // Sources: MarketRegistry review 2026-11-10 finding 9 (setFlashSource event)
    function test_TEST_285_setFlashSourceEmits() public {
        RegistryFlashSourceMock f2 = new RegistryFlashSourceMock(makeAddr("otherLender"), address(lpVaultSwap));
        vm.expectEmit(address(registry));
        emit IMarketRegistryHubs.FlashSourceSet(address(flash), address(f2));
        vm.prank(address(timelock));
        registry.setFlashSource(address(f2));
        assertEq(registry.flashSource(), address(f2));
    }

    function _expectBadHash(
        bytes32 h
    ) internal {
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryApprovals.InvalidSpokeCodeHash.selector, h));
        registry.approveSpokeCodeHash(h);
    }

    function _drift() internal view returns (uint8) {
        (, DriftReason r) = registry.spokeSettingsDrift(address(spoke));
        return uint8(r);
    }

    function _expectInvalidSpoke(
        SpokeDef memory d,
        address s
    ) internal {
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.InvalidSpoke.selector, s));
        registry.deployCdpSpoke(d);
    }
}

