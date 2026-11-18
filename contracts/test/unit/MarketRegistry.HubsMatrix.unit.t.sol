// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistry} from "../../src/policy/market-registry/IMarketRegistry.sol";
import {IMarketRegistryBase} from "../../src/policy/market-registry/IMarketRegistryBase.sol";
import {RiskTier, SpokeDef} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryAaveOracleMock, RegistryHubMock, RegistrySpokeMock} from "../utils/mocks/MarketRegistryAaveMocks.sol";
import {RegistryFlashSourceMock, RegistryLPVaultMock, RegistryTokenMock} from "../utils/mocks/MarketRegistryMocks.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Boundaries of the Hub-level records: the AMM-contract list of an integration (1 to 16 per call, no partial
/// record), Hub records of every tier, cross-Hub line totals over several Spokes against the funding Hub's coverage,
/// and the flash-source replacement.
contract MarketRegistryHubsMatrixUnitTest is MarketRegistryFixture {
    RegistryHubMock internal hub2;
    address[3] internal spokes;

    /// @dev This suite sets no route and checks the integration record from empty, so the world records nothing.
    function _recordAmmContracts() internal override {}

    function setUp() public {
        _setUpWorld();
        hub2 = new RegistryHubMock();
        vm.prank(address(timelock));
        registry.recordHub(address(hub2), RiskTier.Correlated);
        // Three CDP Spokes on hub2 (integrations 10, 11, 12) that may draw GHO from the Stable LP Hub through
        // cross-Hub lines.
        for (uint256 i = 0; i < 3; ++i) {
            spokes[i] = _newSpokeOn(address(hub2), RiskTier.Correlated, uint32(10 + i));
        }
    }

    /// @dev Registers integration `id` and records a CDP Spoke on `h` for it.
    function _newSpokeOn(
        address h,
        RiskTier tier,
        uint32 id
    ) internal returns (address s) {
        lpVaultForId(id);
        RegistrySpokeMock sp = new RegistrySpokeMock();
        RegistryAaveOracleMock o = new RegistryAaveOracleMock();
        sp.setOracle(address(o));
        sp.setImplementation(address(spokeImpl));
        o.setSpoke(address(sp));
        vm.prank(address(timelock));
        s = registry.deployCdpSpoke(SpokeDef(false, h, id, tier, address(spokeImpl), address(o)));
    }

    function lpVaultForId(
        uint32 id
    ) internal {
        RegistryLPVaultMock vault = new RegistryLPVaultMock(id, address(collat), lockAddr);
        vault.setRegistry(address(registry));
        address v = address(vault);
        vm.startPrank(address(timelock));
        factory.registerIntegration(id, v);
        registry.registerIntegration(id, v, makeAddr(string(abi.encodePacked("pricing", bytes1(uint8(48 + id))))));
        vm.stopPrank();
    }

    function _contracts(
        uint256 n
    ) internal returns (address[] memory list) {
        list = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            list[i] = address(new RegistryTokenMock(0));
        }
    }

    // ─── AMM contracts of an integration ───

    // TEST-054 verifies: REQ-MREG-020, REQ-CONFIG-040
    // Sources: MarketRegistry review 2026-11-10 finding 5
    // One call records 1 to 16 contracts: 16 pass, 17 deployed contracts are refused for the count alone.
    function test_TEST_054_integrationContractsCountBound() public {
        address[] memory seventeen = _contracts(17);
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.InvalidIntegration.selector, V3));
        registry.recordIntegrationContracts(V3, seventeen);
        address[] memory sixteen = new address[](16);
        for (uint256 i = 0; i < 16; ++i) {
            sixteen[i] = seventeen[i];
        }
        vm.expectEmit(address(registry));
        emit IMarketRegistry.IntegrationContractsRecorded(V3, _recordKeyOf(V3), sixteen);
        vm.prank(address(timelock));
        registry.recordIntegrationContracts(V3, sixteen);
        assertEq(registry.integrationContracts(V3).length, 16);
        // A later call appends; a contract already recorded is refused.
        address[] memory last = new address[](1);
        last[0] = seventeen[16];
        vm.prank(address(timelock));
        registry.recordIntegrationContracts(V3, last);
        address[] memory got = registry.integrationContracts(V3);
        assertEq(got.length, 17);
        assertEq(got[16], seventeen[16]);
    }

    // TEST-054 verifies: REQ-MREG-020, REQ-CONFIG-040
    // A bad entry anywhere in the list reverts the whole call: none of the good entries before it is recorded.
    function test_TEST_054_badEntryLeavesNoPartialRecord() public {
        address[] memory list = _contracts(3);
        list[2] = makeAddr("eoa");
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.InvalidIntegration.selector, V3));
        registry.recordIntegrationContracts(V3, list);
        assertEq(registry.integrationContracts(V3).length, 0);
    }

    // TEST-054 verifies: REQ-MREG-020, REQ-CONFIG-040
    // Lists are per integration: the same contract may serve two integrations, each recording it once.
    function test_TEST_054_listsArePerIntegration() public {
        address[] memory list = _contracts(1);
        vm.startPrank(address(timelock));
        registry.recordIntegrationContracts(V3, list);
        registry.recordIntegrationContracts(10, list);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.InvalidIntegration.selector, uint32(10)));
        registry.recordIntegrationContracts(10, list);
        vm.stopPrank();
        assertEq(registry.integrationContracts(V3)[0], list[0]);
        assertEq(registry.integrationContracts(10)[0], list[0]);
        assertEq(registry.integrationContracts(11).length, 0);
    }

    // ─── Hubs ───

    // TEST-285 verifies: REQ-CONFIG-083
    // Any non-zero address can be recorded once with any tier but None.
    function testFuzz_TEST_285_recordHubOnceWithAnyTier(
        address h,
        uint8 tierSeed
    ) public {
        vm.assume(h != address(0) && h != address(hub) && h != address(hub2) && h != aaveV3Pool);
        RiskTier tier = RiskTier(bound(tierSeed, 1, 3));
        vm.expectEmit(address(registry));
        emit IMarketRegistry.HubRecorded(h, tier);
        vm.prank(address(timelock));
        registry.recordHub(h, tier);
        assertEq(uint8(registry.hubTier(h)), uint8(tier));
        assertTrue(registry.isRecordedHub(h));
        assertEq(registry.getHubs()[2], h);
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.InvalidHub.selector, h));
        registry.recordHub(h, tier == RiskTier.Stable ? RiskTier.Volatile : RiskTier.Stable);
        assertEq(uint8(registry.hubTier(h)), uint8(tier), "the tier never changes");
    }

    // ─── Cross-Hub lines ───

    // ─── Flash source ───

    // TEST-285 verifies: REQ-CONFIG-005, REQ-FLASH-006, INV-095, Q-386
    // A replacement must name this chain's LPVaultSwap and a lender that is no recorded Hub; each refusal leaves the
    // current source, and a valid one emits the previous and the new source.
    function test_TEST_285_flashSourceReplacementChecks() public {
        RegistryFlashSourceMock wrongSwap = new RegistryFlashSourceMock(aaveV3Pool, alice);
        RegistryFlashSourceMock hubLender = new RegistryFlashSourceMock(address(hub2), address(lpVaultSwap));
        RegistryFlashSourceMock good = new RegistryFlashSourceMock(makeAddr("otherPool"), address(lpVaultSwap));
        vm.startPrank(address(timelock));
        vm.expectRevert(IMarketRegistryBase.InvalidRoute.selector);
        registry.setFlashSource(address(0));
        vm.expectRevert(IMarketRegistryBase.InvalidRoute.selector);
        registry.setFlashSource(address(wrongSwap));
        vm.expectRevert(IMarketRegistryBase.InvalidRoute.selector);
        registry.setFlashSource(address(hubLender));
        assertEq(registry.flashSource(), address(flash));
        vm.expectEmit(address(registry));
        emit IMarketRegistry.FlashSourceSet(address(flash), address(good));
        registry.setFlashSource(address(good));
        vm.stopPrank();
        assertEq(registry.flashSource(), address(good));
    }

    // TEST-285 verifies: REQ-CONFIG-005, REQ-FLASH-006, REQ-MREG-020, Q-386
    // Sources: decisions of 2026-11-11 (dedicated FlashSourceSet test)
    // `FlashSourceSet(previous, current)` on the first setting (previous 0) and on a replacement; a refused source
    // emits nothing and leaves the source in force.
    function test_TEST_285_flashSourceSetOnFirstSettingAndReplacement() public {
        _deployRegistry();
        RegistryFlashSourceMock f1 = new RegistryFlashSourceMock(makeAddr("pool1"), address(lpVaultSwap));
        RegistryFlashSourceMock f2 = new RegistryFlashSourceMock(makeAddr("pool2"), address(lpVaultSwap));
        vm.expectEmit(address(registry));
        emit IMarketRegistry.FlashSourceSet(address(0), address(f1));
        vm.prank(address(timelock));
        registry.setFlashSource(address(f1));
        vm.expectEmit(address(registry));
        emit IMarketRegistry.FlashSourceSet(address(f1), address(f2));
        vm.prank(address(timelock));
        registry.setFlashSource(address(f2));
        RegistryFlashSourceMock wrong = new RegistryFlashSourceMock(makeAddr("pool3"), alice);
        vm.recordLogs();
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryBase.InvalidRoute.selector);
        registry.setFlashSource(address(wrong));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "a refused source emitted");
        assertEq(registry.flashSource(), address(f2));
    }

    // TEST-285 verifies: REQ-CONFIG-083, INV-095, Q-388, ATTACK-195
    // The Hub check follows the current flash source: after a replacement the old lender may be recorded as a Hub, the
    // new lender may not.
    function test_TEST_285_recordHubFollowsTheCurrentFlashSource() public {
        address newLender = makeAddr("newLender");
        RegistryFlashSourceMock next = new RegistryFlashSourceMock(newLender, address(lpVaultSwap));
        vm.startPrank(address(timelock));
        vm.expectRevert(IMarketRegistryBase.InvalidRoute.selector);
        registry.recordHub(aaveV3Pool, RiskTier.Volatile);
        registry.setFlashSource(address(next));
        vm.expectRevert(IMarketRegistryBase.InvalidRoute.selector);
        registry.recordHub(newLender, RiskTier.Volatile);
        registry.recordHub(aaveV3Pool, RiskTier.Volatile);
        // With the old lender now a Hub, the old source can no longer be set back.
        vm.expectRevert(IMarketRegistryBase.InvalidRoute.selector);
        registry.setFlashSource(address(flash));
        vm.stopPrank();
        assertTrue(registry.isRecordedHub(aaveV3Pool));
        assertEq(registry.flashSource(), address(next));
    }
}
