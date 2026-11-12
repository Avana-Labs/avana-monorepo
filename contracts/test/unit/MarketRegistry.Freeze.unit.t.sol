// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryApprovals} from "../../src/policy/market-registry/IMarketRegistryApprovals.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {IMarketRegistryHubs} from "../../src/policy/market-registry/IMarketRegistryHubs.sol";
import {IMarketRegistrySafetyEvents} from "../../src/policy/market-registry/IMarketRegistrySafetyEvents.sol";
import {MarketDef} from "../../src/types/MarketDef.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryFlashSourceMock, RegistryLPOracleMock, RegistryTokenMock} from "../utils/mocks/MarketRegistryMocks.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice The address freeze of the MarketRegistry: protected set, per-caller limit over 24 hour buckets, unfreeze.
contract MarketRegistryFreezeUnitTest is MarketRegistryFixture {
    uint256 internal marketId;
    address internal vaultToken;
    RegistryLPOracleMock internal lpOracle;

    function setUp() public {
        _setUpWorld();
        (marketId, vaultToken, lpOracle) = _activeMarket();
    }

    function _expectProtected(
        address a
    ) internal {
        vm.prank(emergencyGuardian);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ProtectedAddress.selector, a));
        registry.freezeAddress(a);
    }

    // TEST-229 verifies: REQ-MREG-020, INV-085, Q-242, REQ-ACCESS-169
    // Sources: 5.1 TEST-229
    function test_TEST_229_protectedSetIsRefused() public {
        address proxy = makeAddr("aliceProxy");
        adapterMock.setWallet(proxy, alice);
        (address route,) = registry.getRoute(marketId, address(usdc), address(gho), 0);
        (address lpv, address pricing) = registry.integrationOf(V3);
        address[24] memory set = [
            address(timelock),
            aaveGovernanceExecutor,
            address(adapterMock),
            address(collat),
            address(lpVaultSwap),
            proxyManager,
            address(registry),
            address(ps),
            address(rm),
            payoutEscrow,
            lockAddr,
            address(factory),
            address(flash),
            flashLiquidator,
            vaultToken,
            address(lpOracle),
            address(ghoSource),
            address(hub),
            address(spoke),
            address(ghoCoverage),
            address(gho),
            lpv,
            pricing,
            route
        ];
        for (uint256 i = 0; i < set.length; ++i) {
            _expectProtected(set[i]);
        }
        _expectProtected(proxy);
        assertEq(registry.freezesInWindow(emergencyGuardian), 0);
    }

    // TEST-229 verifies: REQ-MREG-020, REQ-ACCESS-157, INV-085, Q-404
    function test_TEST_229_publicFlashLiquidatorIsProtected() public {
        assertEq(registry.FLASH_LIQUIDATOR(), flashLiquidator);
        _expectProtected(flashLiquidator);
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ProtectedAddress.selector, flashLiquidator));
        registry.freezeAddress(flashLiquidator);
        assertFalse(registry.isFrozenAddress(flashLiquidator));
        assertEq(registry.freezesInWindow(emergencyGuardian), 0);
    }

    // TEST-229 verifies: REQ-MREG-020, INV-085, Q-386, Q-404
    // Sources: Later decisions 2026-11-11 (the Aave V3 Pool behind the flash source is freeze-protected)
    function test_TEST_229_flashSourceLenderIsProtected() public {
        assertEq(flash.LENDER(), aaveV3Pool);
        _expectProtected(aaveV3Pool);
        // The protection follows the source in force: a new source protects its own lender and the old Pool is free.
        address pool2 = makeAddr("aaveV3Pool2");
        RegistryFlashSourceMock f2 = new RegistryFlashSourceMock(pool2, address(lpVaultSwap));
        vm.prank(address(timelock));
        registry.setFlashSource(address(f2));
        _expectProtected(pool2);
        _expectProtected(address(f2));
        vm.prank(emergencyGuardian);
        registry.freezeAddress(aaveV3Pool);
        assertTrue(registry.isFrozenAddress(aaveV3Pool));
        // A source whose lender cannot be read protects only itself; the freeze still works for everyone else.
        vm.mockCallRevert(address(f2), abi.encodeWithSignature("LENDER()"), "");
        _expectProtected(address(f2));
        vm.prank(emergencyGuardian);
        registry.freezeAddress(pool2);
        assertTrue(registry.isFrozenAddress(pool2));
    }

    // TEST-229 verifies: REQ-MREG-020, INV-085
    function test_TEST_229_noFlashSourceProtectsNoLender() public {
        // A registry whose flash source is not set yet protects no lender: the Pool is an ordinary address to it.
        _deployRegistry();
        assertEq(registry.flashSource(), address(0));
        vm.prank(emergencyGuardian);
        registry.freezeAddress(aaveV3Pool);
        assertTrue(registry.isFrozenAddress(aaveV3Pool));
    }

    // TEST-229 verifies: REQ-MREG-020, REQ-CONFIG-040, INV-085
    // Sources: MarketRegistry review 2026-11-10 finding 4 (each integration's position manager and factory)
    function test_TEST_229_integrationContractsAreProtected() public {
        address nfpm = address(new RegistryTokenMock(0));
        address v3Factory = address(new RegistryTokenMock(0));
        address[] memory list = new address[](2);
        (list[0], list[1]) = (nfpm, v3Factory);
        // The world recorded the integration's position manager and factory and finalized the record; an addition
        // appends to it.
        assertEq(registry.integrationContracts(V3).length, 2);
        // Only the admin records, for a registered integration, a non-empty list of new contracts.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, APP_ADMIN)
        );
        registry.recordIntegrationContracts(V3, list);
        _expectBadIntegration(9, list);
        _expectBadIntegration(V3, new address[](0));
        address[] memory bad = new address[](1);
        _expectBadIntegration(V3, bad);
        bad[0] = makeAddr("noCode");
        _expectBadIntegration(V3, bad);
        _expectBadIntegration(V3, new address[](17));
        address[] memory dup = new address[](2);
        (dup[0], dup[1]) = (nfpm, nfpm);
        _expectBadIntegration(V3, dup);
        vm.expectEmit(address(registry));
        emit IMarketRegistryApprovals.IntegrationContractsRecorded(V3, _recordKeyOf(V3), list);
        vm.prank(address(timelock));
        registry.recordIntegrationContracts(V3, list);
        address[] memory got = registry.integrationContracts(V3);
        assertEq(got.length, 4);
        assertEq(got[2], nfpm);
        assertEq(got[3], v3Factory);
        _expectProtected(nfpm);
        _expectProtected(v3Factory);
        // Already recorded for the integration.
        address[] memory again = new address[](1);
        again[0] = v3Factory;
        _expectBadIntegration(V3, again);
        assertEq(registry.freezesInWindow(emergencyGuardian), 0);
    }

    // TEST-229 verifies: REQ-MREG-019
    // Sources: MarketRegistry review 2026-11-10 finding 10 (the window is 24 hour buckets, not a rolling 24 hours)
    function test_TEST_229_windowIsTwentyFourHourBuckets() public {
        uint256 h = 1_000_000;
        // 20 freezes in the last second of hour h, 20 more at the start of hour h + 24: 23 h 00 min 01 s apart.
        vm.warp(h * 3600 + 3599);
        for (uint256 i = 0; i < 20; ++i) {
            vm.prank(emergencyGuardian);
            registry.freezeAddress(address(uint160(0xA000 + i)));
        }
        vm.warp((h + 23) * 3600 + 3599);
        assertEq(registry.freezesInWindow(emergencyGuardian), 20);
        vm.prank(emergencyGuardian);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.FreezeLimitReached.selector, emergencyGuardian));
        registry.freezeAddress(address(0xB100));
        vm.warp((h + 24) * 3600);
        assertEq(registry.freezesInWindow(emergencyGuardian), 0);
        for (uint256 i = 0; i < 20; ++i) {
            vm.prank(emergencyGuardian);
            registry.freezeAddress(address(uint160(0xB000 + i)));
        }
        assertEq(registry.freezesInWindow(emergencyGuardian), 20);
    }

    function _expectBadIntegration(
        uint32 id,
        address[] memory list
    ) internal {
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryHubs.InvalidIntegration.selector, id));
        registry.recordIntegrationContracts(id, list);
    }

    // TEST-289 verifies: REQ-MREG-020, REQ-CONFIG-005
    // Sources: 5.1 TEST-289 (the registry half: the public helper is the protected `FLASH_LIQUIDATOR` immutable)
    function test_TEST_289_helperIsProtectedFromFreeze() public {
        address helper = registry.FLASH_LIQUIDATOR();
        assertEq(helper, flashLiquidator);
        vm.prank(aaveGuardian);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ProtectedAddress.selector, helper));
        registry.freezeAddress(helper);
    }

    // TEST-229 verifies: REQ-MREG-020, REQ-CONFIG-048
    function test_TEST_229_cancelledMarketTokenIsNotProtected() public {
        (uint256 id2, address vt2, RegistryLPOracleMock o2) = _listSecondShape();
        _expectProtected(vt2);
        vm.prank(address(timelock));
        registry.cancelRegistration(id2);
        vm.startPrank(emergencyGuardian);
        registry.freezeAddress(vt2);
        registry.freezeAddress(address(o2));
        vm.stopPrank();
        assertTrue(registry.isFrozenAddress(vt2));
    }

    function _listSecondShape() internal returns (uint256 id, address vt, RegistryLPOracleMock o) {
        uint256 next = registry.marketCount() + 1;
        o = new RegistryLPOracleMock(next, address(lpVault));
        vm.prank(address(timelock));
        vt = factory.deployVaultToken(
            V3, pool, bytes32(0), _wideShape(), address(hub), address(spoke), next, address(o), 18, "Avana W", "avW"
        );
        vm.prank(address(timelock));
        id = registry.listCollateralMarket(_marketDefWith(vt, address(o)));
    }

    function _wideShape() internal pure returns (PositionShape memory) {
        return PositionShape(ShapeKind.TickRange, -100, 100);
    }

    function _marketDefWith(
        address vt,
        address o
    ) internal view returns (MarketDef memory d) {
        d = _marketDef(vt, o);
        d.shape = _wideShape();
    }

    // TEST-229 verifies: REQ-MREG-019, REQ-MREG-021, REQ-MREG-022, INV-085, Q-242, Q-263, Q-400, REQ-ACCESS-169, REQ-ACCESS-078, REQ-ACCESS-091, REQ-ACCESS-088
    function test_TEST_229_freezeUnfreezeAndKeeperFloorNotChecked() public {
        vm.expectEmit(address(registry));
        emit IMarketRegistrySafetyEvents.AddressFrozen(keeper, emergencyGuardian);
        vm.prank(emergencyGuardian);
        registry.freezeAddress(keeper);
        assertTrue(registry.isFrozenAddress(keeper));
        vm.prank(aaveGuardian);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.AddressAlreadyFrozen.selector, keeper));
        registry.freezeAddress(keeper);
        vm.prank(emergencyGuardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, emergencyGuardian, APP_ADMIN
            )
        );
        registry.unfreezeAddress(keeper);
        vm.expectEmit(address(registry));
        emit IMarketRegistrySafetyEvents.AddressUnfrozen(keeper);
        vm.prank(address(timelock));
        registry.unfreezeAddress(keeper);
        assertFalse(registry.isFrozenAddress(keeper));
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.AddressNotFrozen.selector, keeper));
        registry.unfreezeAddress(keeper);
    }

    // TEST-229 verifies: REQ-MREG-019, Q-262, REQ-ACCESS-169
    function test_TEST_229_twentyFreezesPerCallerPer24HourBuckets() public {
        vm.warp(100 * 3600 + 5 * 60);
        uint256 h0 = block.timestamp / 3600;
        for (uint256 i = 0; i < 20; ++i) {
            if (i == 7) vm.warp((h0 + 1) * 3600 + 60);
            if (i == 14) vm.warp((h0 + 2) * 3600 + 60);
            vm.prank(emergencyGuardian);
            registry.freezeAddress(address(uint160(0x1000 + i)));
        }
        assertEq(registry.freezesInWindow(emergencyGuardian), 20);
        vm.warp((h0 + 3) * 3600 + 600);
        vm.prank(emergencyGuardian);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.FreezeLimitReached.selector, emergencyGuardian));
        registry.freezeAddress(address(0x2000));
        // The other guardian keeps its full allowance.
        vm.prank(aaveGuardian);
        registry.freezeAddress(address(0x2001));
        // Hour h0 leaves the window at h0 + 24: its 7 freezes no longer count.
        vm.warp((h0 + 24) * 3600 + 1800);
        assertEq(registry.freezesInWindow(emergencyGuardian), 13);
        for (uint256 i = 0; i < 7; ++i) {
            vm.prank(emergencyGuardian);
            registry.freezeAddress(address(uint160(0x3000 + i)));
        }
        vm.prank(emergencyGuardian);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.FreezeLimitReached.selector, emergencyGuardian));
        registry.freezeAddress(address(0x4000));
    }

    // TEST-229 verifies: REQ-MREG-019
    function testFuzz_TEST_229_windowSumsTheLast24Buckets(
        uint32[8] calldata gaps
    ) public {
        vm.warp(1000 * 3600);
        uint256[] memory hours_ = new uint256[](8);
        for (uint256 i = 0; i < 8; ++i) {
            vm.warp(block.timestamp + uint256(gaps[i]) % (30 * 3600));
            hours_[i] = block.timestamp / 3600;
            vm.prank(emergencyGuardian);
            registry.freezeAddress(address(uint160(0x5000 + i)));
            uint256 expected = 0;
            for (uint256 j = 0; j <= i; ++j) {
                if (hours_[j] + 23 >= hours_[i]) ++expected;
            }
            assertEq(registry.freezesInWindow(emergencyGuardian), expected);
        }
    }
}

