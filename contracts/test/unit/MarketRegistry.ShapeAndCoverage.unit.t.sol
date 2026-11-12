// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PoolKeying} from "../../src/amm/types/PoolKeying.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {IMarketRegistryHubs} from "../../src/policy/market-registry/IMarketRegistryHubs.sol";
import {MarketDef} from "../../src/types/MarketDef.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {
    RegistryCoverageSpokeMock,
    RegistryLPVaultMock,
    RegistryTokenMock
} from "../utils/mocks/MarketRegistryMocks.sol";

/// @notice The canonical pool keying and shape of a market definition for every integration capability, and the
/// Coverage Spoke record of a (Hub, asset), field by field.
contract MarketRegistryShapeAndCoverageUnitTest is MarketRegistryFixture {
    function setUp() public {
        _setUpWorld();
    }

    /// @dev REQ-CONFIG-078: the reason `_checkShape` refuses the definition, or 0 when it passes.
    function _shapeRule(
        PoolKeying keying,
        ShapeKind capKind,
        bool hasPool,
        bool hasPoolId,
        PositionShape memory sh
    ) internal pure returns (bytes32) {
        bool byAddress = keying == PoolKeying.Address;
        if (byAddress ? (!hasPool || hasPoolId) : (hasPool || !hasPoolId)) return "pool";
        if (sh.kind == ShapeKind.None || sh.kind != capKind) return "shape";
        if (sh.kind == ShapeKind.FullPool ? (sh.tickLower != 0 || sh.tickUpper != 0) : sh.tickLower >= sh.tickUpper) {
            return "shape";
        }
        return 0;
    }

    // TEST-139 verifies: REQ-CONFIG-078, REQ-CONFIG-030, REQ-CONFIG-006
    // Sources: 5.1 TEST-139
    // For both pool keyings and both shape kinds of an integration, a definition passes the keying and shape checks
    // exactly when it names one pool reference of the right kind and a canonical shape of the integration's kind; a
    // passing definition then reaches the vault-token check (a zero token here, so VaultTokenMismatch).
    function testFuzz_TEST_139_keyingAndShapeRules(
        bool byId,
        bool fullPoolCap,
        bool hasPool,
        bool hasPoolId,
        uint8 kindSeed,
        int24 lower,
        int24 upper,
        bool zeroTicks
    ) public {
        PoolKeying keying = byId ? PoolKeying.Id : PoolKeying.Address;
        ShapeKind capKind = fullPoolCap ? ShapeKind.FullPool : ShapeKind.TickRange;
        lpVault.setKeying(keying, capKind);
        PositionShape memory sh = PositionShape(ShapeKind(bound(kindSeed, 0, 2)), lower, upper);
        if (zeroTicks) (sh.tickLower, sh.tickUpper) = (0, 0);
        MarketDef memory d = _marketDef(address(0), makeAddr("oracle"));
        d.pool = hasPool ? pool : address(0);
        d.poolId = hasPoolId ? keccak256("poolId") : bytes32(0);
        d.shape = sh;
        bytes32 rule = _shapeRule(keying, capKind, hasPool, hasPoolId, sh);
        vm.prank(address(timelock));
        if (rule != 0) {
            vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ListingCheckFailed.selector, rule));
        } else {
            vm.expectRevert(IMarketRegistryErrors.VaultTokenMismatch.selector);
        }
        registry.listCollateralMarket(d);
    }

    // TEST-139 verifies: REQ-CONFIG-078, REQ-CONFIG-030
    // Edges of the tick-range rule: lower = upper and lower = upper + 1 are refused, lower = upper - 1 passes; a full
    // pool with one non-zero tick is refused.
    function test_TEST_139_shapeEdges() public {
        int24[3] memory deltas = [int24(0), int24(-1), int24(1)];
        for (uint256 i = 0; i < 3; ++i) {
            MarketDef memory d = _marketDef(address(0), makeAddr("oracle"));
            d.shape = PositionShape(ShapeKind.TickRange, 100 - deltas[i], 100);
            vm.prank(address(timelock));
            if (deltas[i] <= 0) {
                vm.expectRevert(
                    abi.encodeWithSelector(IMarketRegistryErrors.ListingCheckFailed.selector, bytes32("shape"))
                );
            } else {
                vm.expectRevert(IMarketRegistryErrors.VaultTokenMismatch.selector);
            }
            registry.listCollateralMarket(d);
        }
        lpVault.setKeying(PoolKeying.Address, ShapeKind.FullPool);
        int24[2][3] memory ticks = [[int24(0), int24(1)], [int24(-1), int24(0)], [int24(0), int24(0)]];
        for (uint256 i = 0; i < 3; ++i) {
            MarketDef memory d = _marketDef(address(0), makeAddr("oracle"));
            d.shape = PositionShape(ShapeKind.FullPool, ticks[i][0], ticks[i][1]);
            vm.prank(address(timelock));
            if (i < 2) {
                vm.expectRevert(
                    abi.encodeWithSelector(IMarketRegistryErrors.ListingCheckFailed.selector, bytes32("shape"))
                );
            } else {
                vm.expectRevert(IMarketRegistryErrors.VaultTokenMismatch.selector);
            }
            registry.listCollateralMarket(d);
        }
    }

    // ─── Coverage Spoke record ───

    function _expectBadCoverage(
        address h,
        address asset,
        address cs
    ) internal {
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryHubs.InvalidCoverageSpoke.selector, cs));
        registry.setCoverageSpoke(h, asset, cs);
    }

    // TEST-273 verifies: REQ-MREG-009, REQ-CONFIG-081, Q-379
    // Sources: 5.1 TEST-273
    // The Coverage Spoke must be non-zero, for a non-zero asset, report the Hub, the asset and the Hub's asset id, and
    // be the first for its (Hub, asset); each condition alone is refused.
    function test_TEST_273_coverageSpokeEachCondition() public {
        RegistryTokenMock dai = new RegistryTokenMock(18);
        hub.setAsset(address(dai), 4);
        RegistryCoverageSpokeMock good = new RegistryCoverageSpokeMock(address(hub), address(dai), 4);
        _expectBadCoverage(address(hub), address(dai), address(0));
        _expectBadCoverage(address(hub), address(0), address(good));
        _expectBadCoverage(address(hub), address(dai), address(new RegistryCoverageSpokeMock(alice, address(dai), 4)));
        _expectBadCoverage(
            address(hub), address(dai), address(new RegistryCoverageSpokeMock(address(hub), address(usdc), 4))
        );
        _expectBadCoverage(
            address(hub), address(dai), address(new RegistryCoverageSpokeMock(address(hub), address(dai), 5))
        );
        vm.expectEmit(address(registry));
        emit IMarketRegistryHubs.CoverageSpokeSet(address(hub), address(dai), address(good));
        vm.prank(address(timelock));
        registry.setCoverageSpoke(address(hub), address(dai), address(good));
        assertEq(registry.coverageSpokeOf(address(hub), address(dai)), address(good));
        // Set once: a second Coverage Spoke for the pair, even a valid one, is refused.
        _expectBadCoverage(
            address(hub), address(dai), address(new RegistryCoverageSpokeMock(address(hub), address(dai), 4))
        );
        // The recorded Coverage Spoke is protected from the address freeze.
        vm.prank(emergencyGuardian);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ProtectedAddress.selector, address(good)));
        registry.freezeAddress(address(good));
    }

    // TEST-273 verifies: REQ-MREG-009, REQ-CONFIG-083
    // An asset the Hub does not list cannot get a Coverage Spoke (the Hub's asset-id read reverts).
    function test_TEST_273_coverageSpokeNeedsAHubAsset() public {
        RegistryTokenMock dai = new RegistryTokenMock(18);
        RegistryCoverageSpokeMock cs = new RegistryCoverageSpokeMock(address(hub), address(dai), 0);
        vm.prank(address(timelock));
        vm.expectRevert(bytes("AssetNotListed"));
        registry.setCoverageSpoke(address(hub), address(dai), address(cs));
        assertEq(registry.coverageSpokeOf(address(hub), address(dai)), address(0));
    }

    // ─── Integrations ───

    // TEST-264 verifies: REQ-CONFIG-075, REQ-MREG-020, Q-376
    // Registering pins the LPVault and the pricing for the id, emits them, and protects both; an LPVault already
    // pinned to another id is refused.
    function test_TEST_264_registerIntegrationRecordAndEvent() public {
        RegistryLPVaultMock v2 = new RegistryLPVaultMock(2, address(collat), lockAddr);
        v2.setRegistry(address(registry));
        address pricing2 = makeAddr("pricing2");
        vm.startPrank(address(timelock));
        factory.registerIntegration(2, address(v2));
        vm.expectEmit(address(registry));
        emit IMarketRegistryHubs.IntegrationRegistered(2, address(v2), pricing2);
        registry.registerIntegration(2, address(v2), pricing2);
        // The V3 LPVault cannot be pinned again under a new id.
        RegistryLPVaultMock v3 = new RegistryLPVaultMock(3, address(collat), lockAddr);
        v3.setRegistry(address(registry));
        factory.registerIntegration(3, address(v3));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryHubs.InvalidIntegration.selector, uint32(3)));
        registry.registerIntegration(3, address(lpVault), makeAddr("pricing3"));
        vm.stopPrank();
        assertEq(registry.integrationIdOf(address(v2)), 2);
        vm.startPrank(emergencyGuardian);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ProtectedAddress.selector, address(v2)));
        registry.freezeAddress(address(v2));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ProtectedAddress.selector, pricing2));
        registry.freezeAddress(pricing2);
        vm.stopPrank();
    }
}
