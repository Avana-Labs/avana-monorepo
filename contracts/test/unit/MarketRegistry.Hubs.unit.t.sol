// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IMarketRegistry} from "../../src/policy/market-registry/IMarketRegistry.sol";
import {IMarketRegistryBase} from "../../src/policy/market-registry/IMarketRegistryBase.sol";
import {RiskTier, SpokeDef} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {DriftReason, MarketDef} from "../../src/types/MarketTypes.sol";
import {PositionShape, ShapeKind} from "../../src/types/PositionTypes.sol";
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
    RegistryLPOracleMock,
    RegistryLPVaultMock,
    RegistryTokenMock
} from "../utils/mocks/MarketRegistryMocks.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

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
        vm.startPrank(governor);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.InvalidHub.selector, address(0)));
        registry.recordHub(address(0), RiskTier.Stable);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.InvalidHub.selector, address(hub)));
        registry.recordHub(address(hub), RiskTier.Stable);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.InvalidHub.selector, address(hub2)));
        registry.recordHub(address(hub2), RiskTier.None);
        vm.expectRevert(IMarketRegistryBase.InvalidRoute.selector);
        registry.recordHub(aaveV3Pool, RiskTier.Stable);
        vm.expectEmit(address(registry));
        emit IMarketRegistry.HubRecorded(address(hub2), RiskTier.Correlated);
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
        vm.startPrank(governor);
        vm.expectRevert(IMarketRegistryBase.InvalidRoute.selector);
        registry.setFlashSource(address(viaHub));
        vm.expectRevert(IMarketRegistryBase.InvalidRoute.selector);
        registry.setFlashSource(address(wrongSwap));
        vm.expectRevert(IMarketRegistryBase.InvalidRoute.selector);
        registry.setFlashSource(address(0));
        registry.recordHub(address(hub2), RiskTier.Correlated);
        RegistryFlashSourceMock viaHub2 = new RegistryFlashSourceMock(address(hub2), address(lpVaultSwap));
        vm.expectRevert(IMarketRegistryBase.InvalidRoute.selector);
        registry.setFlashSource(address(viaHub2));
        registry.setFlashSource(address(good));
        vm.stopPrank();
        assertEq(registry.flashSource(), address(good));
    }

    function test_TEST_264_listingRefusesAnotherRegisteredIntegration() public {
        RegistryLPVaultMock v2 = new RegistryLPVaultMock(2, address(collat), lockAddr);
        v2.setRegistry(address(registry));
        address[] memory amm = new address[](2);
        (amm[0], amm[1]) = (address(new RegistryTokenMock(18)), address(new RegistryTokenMock(18)));
        vm.startPrank(governor);
        factory.registerIntegration(2, address(v2));
        registry.recordIntegrationContracts(2, amm);
        registry.finalizeIntegrationContracts(2);
        registry.recordHub(address(hub2), RiskTier.Correlated);
        registry.deployCdpSpoke(
            SpokeDef(false, address(hub2), 2, RiskTier.Correlated, address(spokeImpl), address(oracle2))
        );
        vm.stopPrank();
        MarketDef memory d = _marketDef(makeAddr("vt"), makeAddr("lpo"));
        d.integrationId = 2;
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.InvalidIntegration.selector, 2));
        registry.listCollateralMarket(d);
        d = _marketDef(makeAddr("vt"), makeAddr("lpo"));
        (d.hub, d.spoke) = (address(hub2), address(spoke2));
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.InvalidIntegration.selector, V3));
        registry.listCollateralMarket(d);
    }
    // Needs imports in this file: {MarketDef} from "../../src/types/MarketDef.sol" if not present.
}
