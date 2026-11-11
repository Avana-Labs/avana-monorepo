// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {IMarketRegistryEvents} from "../../src/policy/market-registry/IMarketRegistryEvents.sol";
import {RiskTier} from "../../src/policy/market-registry/types/RiskTier.sol";
import {SpokeDef} from "../../src/policy/market-registry/types/SpokeDef.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {
    RegistryAaveOracleMock,
    RegistryHubMock,
    RegistrySpokeImplMock,
    RegistrySpokeMock
} from "../utils/mocks/MarketRegistryAaveMocks.sol";

/// @notice CDP Spoke records at their edges: how the Spoke is found from its AaveOracle, an implementation of zero,
/// a tier of None, and a re-approval after an Aave upgrade that may change the implementation and nothing else.
contract MarketRegistrySpokeRecordsUnitTest is MarketRegistryFixture {
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
        vm.prank(address(timelock));
        registry.recordHub(address(hub2), RiskTier.Correlated);
    }

    function _def2() internal view returns (SpokeDef memory) {
        return SpokeDef(false, address(hub2), V3, RiskTier.Correlated, address(spokeImpl), address(oracle2));
    }

    function _expectInvalidSpoke(
        SpokeDef memory d,
        address s
    ) internal {
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.InvalidSpoke.selector, s));
        registry.deployCdpSpoke(d);
    }

    // TEST-185 verifies: REQ-CONFIG-077, REQ-CONFIG-074, ATTACK-121
    // Sources: 5.1 TEST-185
    // The Spoke is the one the AaveOracle names: no oracle, an oracle whose spoke() reverts, and an oracle naming no
    // Spoke are each InvalidSpoke(address(0)).
    function test_TEST_185_spokeFoundOnlyThroughItsOracle() public {
        SpokeDef memory d = _def2();
        d.aaveOracle = address(0);
        _expectInvalidSpoke(d, address(0));
        d.aaveOracle = address(spokeImpl);
        _expectInvalidSpoke(d, address(0));
        oracle2.setSpoke(address(0));
        _expectInvalidSpoke(_def2(), address(0));
        oracle2.setSpoke(address(spoke2));
        vm.prank(address(timelock));
        assertEq(registry.deployCdpSpoke(_def2()), address(spoke2));
    }

    // TEST-185 verifies: REQ-CONFIG-074, REQ-CONFIG-016, REQ-CONFIG-083
    // A zero implementation and the tier None are refused even when every other field matches.
    function test_TEST_185_zeroImplementationAndNoneTierRefused() public {
        SpokeDef memory d = _def2();
        d.implementation = address(0);
        spoke2.setImplementation(address(0));
        _expectInvalidSpoke(d, address(spoke2));
        spoke2.setImplementation(address(spokeImpl));
        d = _def2();
        d.riskTier = RiskTier.None;
        _expectInvalidSpoke(d, address(spoke2));
        assertEq(registry.getSpokes().length, 1);
        assertFalse(registry.getSpoke(address(spoke2)).approved);
    }

    // TEST-185 verifies: REQ-CONFIG-016, REQ-CONFIG-074, REQ-CONFIG-077
    // A re-approval must name the recorded Hub, integration, tier and oracle; each one changed alone is refused and the
    // record is untouched.
    function test_TEST_185_reapprovalChangesOnlyTheImplementation() public {
        RegistrySpokeImplMock upgraded = new RegistrySpokeImplMock();
        spoke.setImplementation(address(upgraded));
        SpokeDef memory d = _spokeDef();
        d.implementation = address(upgraded);
        d.hub = address(hub2);
        _expectInvalidSpoke(d, address(spoke));
        d = _spokeDef();
        d.implementation = address(upgraded);
        d.integrationId = 7;
        _expectInvalidSpoke(d, address(spoke));
        // Another oracle naming the same Spoke.
        RegistryAaveOracleMock o = new RegistryAaveOracleMock();
        o.setSpoke(address(spoke));
        d = _spokeDef();
        d.implementation = address(upgraded);
        d.aaveOracle = address(o);
        _expectInvalidSpoke(d, address(spoke));
        assertEq(registry.getSpoke(address(spoke)).implementation, address(spokeImpl), "record untouched");
        // The valid re-approval emits SpokeApproved and keeps the list and the triple.
        d = _spokeDef();
        d.implementation = address(upgraded);
        vm.expectEmit(address(registry));
        emit IMarketRegistryEvents.SpokeApproved(
            address(spoke), address(hub), V3, address(upgraded), address(aaveOracle)
        );
        vm.prank(address(timelock));
        assertEq(registry.deployCdpSpoke(d), address(spoke));
        assertEq(registry.getSpokes().length, 1);
        SpokeDef memory rec = registry.getSpoke(address(spoke));
        assertEq(rec.implementation, address(upgraded));
        assertEq(rec.hub, address(hub));
        assertEq(uint8(rec.riskTier), uint8(RiskTier.Stable));
        (address impl, bytes32 h, bool current) = registry.spokeImplementationStatus(address(spoke));
        assertEq(impl, address(upgraded));
        assertEq(h, address(upgraded).codehash);
        assertTrue(current);
    }

    // TEST-185 verifies: REQ-CONFIG-016, REQ-CONFIG-074
    // A re-approval of the unchanged implementation is accepted (idempotent) and leaves the record as it was.
    function test_TEST_185_reapprovalOfTheSameImplementation() public {
        vm.prank(address(timelock));
        registry.deployCdpSpoke(_spokeDef());
        assertEq(registry.getSpokes().length, 1);
        (,, bool current) = registry.spokeImplementationStatus(address(spoke));
        assertTrue(current);
    }

    // TEST-185 verifies: REQ-CONFIG-077, REQ-CONFIG-083, REQ-MREG-020
    // Recording a second Spoke on another Hub adds it to the list, maps it to its Hub and protects it from the freeze;
    // its debt-reserve set starts empty.
    function test_TEST_185_secondSpokeRecordedAndProtected() public {
        vm.prank(address(timelock));
        registry.deployCdpSpoke(_def2());
        address[] memory spokes = registry.getSpokes();
        assertEq(spokes.length, 2);
        assertEq(spokes[1], address(spoke2));
        assertEq(registry.hubOf(address(spoke2)), address(hub2));
        assertEq(registry.getDebtReserveIds(address(spoke2)).length, 0);
        assertEq(registry.activeMarketCount(address(spoke2)), 0);
        vm.prank(emergencyGuardian);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ProtectedAddress.selector, address(spoke2)));
        registry.freezeAddress(address(spoke2));
    }

    // TEST-185 verifies: REQ-CONFIG-077, REQ-CONFIG-079, REQ-MREG-006
    // A debt reserve can be enabled only on an approved Spoke.
    function test_TEST_185_debtReserveNeedsAnApprovedSpoke() public {
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.InvalidSpoke.selector, address(spoke2)));
        registry.enableDebtReserve(address(spoke2), _ghoDef());
    }
}
