// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {DebtReserveDef} from "../../src/policy/market-registry/types/DebtReserveDef.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {RiskTier} from "../../src/policy/market-registry/types/RiskTier.sol";
import {SpokeDef} from "../../src/policy/market-registry/types/SpokeDef.sol";
import {MarketDef} from "../../src/types/MarketDef.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {IVaultTokenFactory} from "../../src/vault-token/vault-token-factory/IVaultTokenFactory.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryAaveOracleMock, RegistryHubMock, RegistrySpokeMock} from "../utils/mocks/MarketRegistryAaveMocks.sol";
import {RegistryCoverageSpokeMock, RegistryLPOracleMock} from "../utils/mocks/MarketRegistryMocks.sol";

/// @notice The worked examples of the MarketRegistry page, replayed on the real registry: the live-market count of
/// REQ-MREG-031 and the relisting of a closed market's pool and shape on a second Stable Spoke of REQ-CONFIG-007.
contract MarketRegistrySpecExamplesUnitTest is MarketRegistryFixture {
    function setUp() public {
        _setUpWorld();
    }

    /// @dev Lists and activates the USDC/USDT market of `shape` on Hub asset and Spoke reserve `slot`.
    function _activeShape(
        PositionShape memory shape,
        uint256 slot
    ) internal returns (uint256 id, address vt) {
        RegistryLPOracleMock o;
        (vt, o) = _deployTokenAndOracle(registry.marketCount() + 1, shape);
        MarketDef memory d = _marketDef(vt, address(o));
        d.shape = shape;
        vm.prank(address(timelock));
        id = registry.listCollateralMarket(d);
        hub.setAsset(vt, slot);
        hub.setSpokeConfig(slot, address(spoke), 2_000_000, 0);
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (vt, address(hub), uint16(slot), 18);
        IAaveV4Spoke.ReserveConfig memory c;
        IAaveV4Spoke.DynamicReserveConfig memory dc;
        (dc.collateralFactor, dc.maxLiquidationBonus) = (7500, 10_500);
        spoke.setReserve(slot, r, c, dc);
        spoke.setLiquidationConfig(1.1e18, 5000);
        ps.setLiquidationExpectations(address(spoke), 1.1e18, 200);
        ps.setMarket(id, 9500, 10e8, 1_000_000e8, 100_000e8, 1e8);
        _setRoutesInto(id, address(gho));
        vm.prank(address(timelock));
        registry.activateMarket(id);
    }

    function _range(
        int24 w
    ) internal pure returns (PositionShape memory) {
        return PositionShape(ShapeKind.TickRange, -w, w);
    }

    // TEST-213 verifies: REQ-MREG-031, Q-267, Q-397
    // Sources: 5.1 TEST-213 (REQ-MREG-031 example)
    // Three Active markets and one Offboarding market on the Stable LP CDP Spoke give 4; a Registered and a
    // Cancelled market do not count.
    function test_TEST_213_activeMarketCountExample() public {
        _activeShape(_range(10), 11);
        _activeShape(_range(20), 12);
        _activeShape(_range(30), 13);
        (uint256 off,) = _activeShape(_range(40), 14);
        vm.prank(address(timelock));
        registry.setMarketOffboarding(off);
        _listMarket();
        (address vt, RegistryLPOracleMock o) = _deployTokenAndOracle(registry.marketCount() + 1, _range(60));
        MarketDef memory d = _marketDef(vt, address(o));
        d.shape = _range(60);
        vm.prank(address(timelock));
        uint256 can = registry.listCollateralMarket(d);
        vm.prank(address(timelock));
        registry.cancelRegistration(can);
        assertEq(registry.activeMarketCount(address(spoke)), 4);
        assertEq(registry.marketsOfSpoke(address(spoke)).length, 6);
    }

    /// @dev A second Stable LP Hub and its CDP Spoke for the same integration, with GHO enabled as its debt reserve.
    function _secondStableSpoke() internal returns (RegistryHubMock hub2, RegistrySpokeMock spoke2) {
        hub2 = new RegistryHubMock();
        spoke2 = new RegistrySpokeMock();
        RegistryAaveOracleMock oracle2 = new RegistryAaveOracleMock();
        spoke2.setOracle(address(oracle2));
        spoke2.setImplementation(address(spokeImpl));
        oracle2.setSpoke(address(spoke2));
        vm.startPrank(address(timelock));
        registry.recordHub(address(hub2), RiskTier.Stable);
        registry.deployCdpSpoke(
            SpokeDef(false, address(hub2), V3, RiskTier.Stable, address(spokeImpl), address(oracle2))
        );
        vm.stopPrank();
        hub2.setAsset(address(gho), 0);
        hub2.setSpokeConfig(0, address(spoke2), 0, 1_000_000);
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (address(gho), address(hub2), 0, 18);
        IAaveV4Spoke.ReserveConfig memory c;
        c.borrowable = true;
        IAaveV4Spoke.DynamicReserveConfig memory d;
        spoke2.setReserve(0, r, c, d);
        oracle2.setSource(0, address(ghoSource));
        RegistryCoverageSpokeMock cs2 = new RegistryCoverageSpokeMock(address(hub2), address(gho), 0);
        cs2.setFunded(4e24, false);
        vm.startPrank(address(timelock));
        registry.setCoverageSpoke(address(hub2), address(gho), address(cs2));
        registry.recordCreditLine(address(hub2), address(gho), 20_000_000);
        registry.enableDebtReserve(
            address(spoke2),
            DebtReserveDef(0, address(gho), 18, address(hub2), 0, address(ghoSource), true, address(cs2), false, false)
        );
        vm.stopPrank();
    }

    // TEST-252 verifies: REQ-CONFIG-007, REQ-CONFIG-010, REQ-MREG-030, REQ-CONFIG-080, Q-068, Q-265
    // Sources: 5.1 TEST-252 (REQ-CONFIG-007 example)
    // The USDC/USDT [-50, 50] market on the Stable Spoke is wound down to Closed; the same pool and range listed on a
    // second Stable Spoke reuses the free market key with a new token and a new identifier. While the first market was
    // live that listing reverted DuplicateMarketKey, and a second token for the first Spoke is refused by the factory.
    function test_TEST_252_closedMarketRelistedOnASecondSpoke() public {
        (uint256 m1, address vt1,) = _activeMarket();
        (RegistryHubMock hub2, RegistrySpokeMock spoke2) = _secondStableSpoke();
        uint256 next = registry.marketCount() + 1;
        RegistryLPOracleMock o2 = new RegistryLPOracleMock(next, address(lpVault));
        vm.prank(address(timelock));
        address vt2 = factory.deployVaultToken(
            V3, pool, bytes32(0), _shape(), address(hub2), address(spoke2), next, address(o2), 18, "Avana 2", "av2"
        );
        MarketDef memory d = _marketDef(vt2, address(o2));
        (d.hub, d.spoke) = (address(hub2), address(spoke2));
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.DuplicateMarketKey.selector);
        registry.listCollateralMarket(d);
        // Wind the first market down to Closed.
        vm.prank(address(timelock));
        registry.setMarketOffboarding(m1);
        vm.warp(block.timestamp + 5 days);
        registry.closeMarket(m1);
        vm.prank(address(timelock));
        uint256 m2 = registry.listCollateralMarket(d);
        assertEq(m2, next);
        assertTrue(m2 != m1);
        bytes32 key = factory.marketKeyOf(V3, pool, bytes32(0), _shape());
        assertEq(registry.marketOfKey(key), m2, "the key now maps to the new market");
        assertEq(registry.marketOfVaultToken(vt1), m1, "the old token stays bound to the closed market");
        assertEq(registry.marketOfVaultToken(vt2), m2);
        assertEq(registry.getMarket(m2).spoke, address(spoke2));
        assertEq(registry.getMarket(m2).hub, address(hub2));
        assertEq(uint8(registry.getMarket(m1).status), uint8(MarketStatus.Closed));
        // A second token for the first Spoke and the same key is refused at the factory.
        RegistryLPOracleMock o3 = new RegistryLPOracleMock(next + 1, address(lpVault));
        vm.prank(address(timelock));
        vm.expectRevert(IVaultTokenFactory.TokenExistsForMarket.selector);
        factory.deployVaultToken(
            V3, pool, bytes32(0), _shape(), address(hub), address(spoke), next + 1, address(o3), 18, "Avana 3", "av3"
        );
    }
}
