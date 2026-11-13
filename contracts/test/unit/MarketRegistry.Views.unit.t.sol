// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IMarketRegistryCreditLines} from "../../src/policy/market-registry/IMarketRegistryCreditLines.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {RiskTier} from "../../src/policy/market-registry/types/RiskTier.sol";
import {SpokeDef} from "../../src/policy/market-registry/types/SpokeDef.sol";
import {TokenDef} from "../../src/policy/market-registry/types/TokenDef.sol";
import {WindDownState} from "../../src/policy/market-registry/types/WindDownState.sol";
import {DriftReason} from "../../src/types/DriftReason.sol";
import {Market} from "../../src/types/Market.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {RegistrySpokeImplMock} from "../utils/mocks/MarketRegistryAaveMocks.sol";
import {RegistryLPOracleMock} from "../utils/mocks/MarketRegistryMocks.sol";

/// @notice The read surface of the MarketRegistry: every view answers for any input without reverting, unknown keys
/// read as empty records, the coverage view at its zero and overflow ends, and the Spoke drift view over markets of
/// every status and a replaced Spoke implementation.
contract MarketRegistryViewsUnitTest is MarketRegistryFixture {
    uint256 internal marketId;
    address internal vt;
    address internal lpo;
    bytes32 internal key;

    function setUp() public {
        _setUpWorld();
        RegistryLPOracleMock o;
        (marketId, vt, o) = _activeMarket();
        lpo = address(o);
        key = factory.marketKeyOf(V3, pool, bytes32(0), _shape());
    }

    // TEST-204 verifies: REQ-MREG-025, REQ-MREG-031, REQ-MREG-014, REQ-MREG-022, REQ-CONFIG-005
    // Sources: 5.1 TEST-204, TEST-252
    // Every view of an unknown key answers the empty value and never reverts.
    function testFuzz_TEST_204_viewsOfUnknownKeysAreEmpty(
        uint256 anyId,
        address anyAddr,
        bytes32 anyKey,
        uint32 anyIntegration
    ) public view {
        vm.assume(anyId != marketId && anyId != 0);
        vm.assume(
            anyAddr != address(hub) && anyAddr != address(spoke) && anyAddr != address(usdc) && anyAddr != address(usdt)
                && anyAddr != address(gho) && anyAddr != address(lpVault) && anyAddr != vt
        );
        vm.assume(anyAddr != lpo && anyKey != key);
        vm.assume(anyIntegration != V3);
        _marketViewsEmpty(anyId, anyAddr, anyKey);
        _hubViewsEmpty(anyAddr, anyIntegration);
        _safetyViewsEmpty(anyId, anyAddr);
    }

    function _marketViewsEmpty(
        uint256 anyId,
        address anyAddr,
        bytes32 anyKey
    ) internal view {
        Market memory m = registry.getMarket(anyId);
        assertEq(uint8(m.status), uint8(MarketStatus.None));
        assertEq(m.vaultToken, address(0));
        TokenDef memory t = registry.getToken(anyAddr);
        assertFalse(t.listed);
        SpokeDef memory s = registry.getSpoke(anyAddr);
        assertFalse(s.approved);
        assertEq(registry.marketsOfSpoke(anyAddr).length, 0);
        assertEq(registry.marketOfKey(anyKey), 0);
        assertEq(registry.marketOfVaultToken(anyAddr), 0);
        assertEq(registry.marketOfLpOracle(anyAddr), 0);
        assertEq(registry.marketOfReserve(anyAddr, anyId), 0);
        assertEq(registry.marketOfHubAsset(anyAddr, anyId), 0);
        assertEq(registry.getDebtReserveIds(anyAddr).length, 0);
        assertFalse(registry.isApprovedDebtReserve(anyAddr, anyId));
        (address r, bool usable) = registry.getRoute(anyId, anyAddr, anyAddr, 0);
        assertEq(r, address(0));
        assertFalse(usable);
        WindDownState memory w = registry.windDownState(anyId);
        assertEq(w.offboardedAt, 0);
        assertEq(registry.settlementReserve(anyId), 0);
    }

    function _hubViewsEmpty(
        address anyAddr,
        uint32 anyIntegration
    ) internal view {
        assertEq(uint8(registry.hubTier(anyAddr)), uint8(RiskTier.None));
        assertFalse(registry.isRecordedHub(anyAddr));
        assertEq(registry.hubOf(anyAddr), address(0));
        (address lpv, address pricing) = registry.integrationOf(anyIntegration);
        assertEq(lpv, address(0));
        assertEq(pricing, address(0));
        assertEq(registry.integrationIdOf(anyAddr), 0);
        assertEq(registry.coverageSpokeOf(anyAddr, anyAddr), address(0));
        assertEq(registry.crossHubLineCap(anyAddr, anyAddr, anyAddr), 0);
        assertEq(registry.crossHubLineTotal(anyAddr, anyAddr), 0);
        (uint256 line, uint256 sum) = registry.creditLine(anyAddr, anyAddr);
        assertEq(line + sum, 0);
        assertEq(registry.integrationContracts(anyIntegration).length, 0);
        (uint256 dm, DriftReason dr) = registry.spokeSettingsDrift(anyAddr);
        assertEq(dm, 0);
        assertEq(uint8(dr), uint8(DriftReason.None));
        (address impl, bytes32 codeHash, bool current) = registry.spokeImplementationStatus(anyAddr);
        assertEq(impl, address(0));
        assertEq(codeHash, bytes32(0));
        assertFalse(current);
    }

    function _safetyViewsEmpty(
        uint256 anyId,
        address anyAddr
    ) internal view {
        assertEq(uint8(registry.pauseState(anyAddr)), uint8(PauseState.None));
        assertEq(uint8(registry.pauseReason(anyAddr)), uint8(PauseReason.None));
        assertFalse(registry.isFrozenAddress(anyAddr));
        assertEq(registry.freezesInWindow(anyAddr), 0);
        assertEq(registry.activeMarketCount(anyAddr), 0);
        (address[] memory p, address[] memory a, RouteSlot replaced) = registry.activePriceRoutes(anyAddr);
        assertEq(p.length + a.length, 0);
        assertEq(uint8(replaced), uint8(RouteSlot.None));
        assertEq(registry.standbySwitchLockedUntil(anyAddr), 0);
        assertEq(registry.priceRouteVersion(anyAddr), 0);
        (uint32 latched, uint64 at) = registry.marketBreaker(anyId);
        assertEq(uint256(latched) + at, 0);
    }

    // TEST-204 verifies: REQ-CONFIG-083, REQ-CONFIG-077
    // The Hub and Spoke lists hold every record in the order it was made, and each Spoke maps back to its Hub.
    function test_TEST_204_hubAndSpokeListsInRecordOrder() public {
        address[] memory hubs = registry.getHubs();
        assertEq(hubs.length, 1);
        assertEq(hubs[0], address(hub));
        address h2 = makeAddr("hub2");
        address h3 = makeAddr("hub3");
        vm.startPrank(address(timelock));
        registry.recordHub(h2, RiskTier.Volatile);
        registry.recordHub(h3, RiskTier.Correlated);
        vm.stopPrank();
        hubs = registry.getHubs();
        assertEq(hubs.length, 3);
        assertEq(hubs[1], h2);
        assertEq(hubs[2], h3);
        assertEq(uint8(registry.hubTier(h2)), uint8(RiskTier.Volatile));
        assertEq(uint8(registry.hubTier(h3)), uint8(RiskTier.Correlated));
        assertTrue(registry.isRecordedHub(h3));
        address[] memory spokes = registry.getSpokes();
        assertEq(spokes.length, 1);
        assertEq(spokes[0], address(spoke));
        assertEq(registry.hubOf(address(spoke)), address(hub));
        SpokeDef memory s = registry.getSpoke(address(spoke));
        assertTrue(s.approved);
        assertEq(s.integrationId, V3);
        assertEq(uint8(s.riskTier), uint8(RiskTier.Stable));
        assertEq(s.implementation, address(spokeImpl));
        assertEq(s.aaveOracle, address(aaveOracle));
    }

    // TEST-273 verifies: REQ-CONFIG-081, SPEC-CAP-010
    // creditLineCoverage reads (0, 0) for a zero line whatever the Coverage Spoke holds, and the funded balance of the
    // recorded Coverage Spoke otherwise; ceil(20,000,000 x 10^18 x 2,000 / 10^4) = 4 x 10^24 for the GHO line.
    function test_TEST_273_coverageViewAtZeroAndAtTheLine() public {
        (uint256 required, uint256 funded) = registry.creditLineCoverage(address(hub), address(gho));
        assertEq(required, 4e24);
        assertEq(funded, 4e24);
        (required, funded) = registry.creditLineCoverage(address(hub), address(usdc));
        assertEq(required, 0);
        assertEq(funded, 0);
        ghoCoverage.setFunded(123, false);
        (, funded) = registry.creditLineCoverage(address(hub), address(gho));
        assertEq(funded, 123);
    }

    // TEST-273 verifies: REQ-CONFIG-081, SPEC-CAP-010
    // A line so large that line x 10^decimals x ratio would overflow requires type(uint256).max: such a line is refused
    // with that requirement; the largest line that does not overflow is computed exactly (ceil).
    function test_TEST_273_coverageOverflowBoundary() public {
        uint256 k = 1e18 * 2000;
        uint256 edge = (type(uint256).max - 10_000) / k;
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketRegistryCreditLines.CoverageBelowRatio.selector,
                address(hub),
                address(gho),
                type(uint256).max,
                4e24
            )
        );
        registry.recordCreditLine(address(hub), address(gho), edge + 1);
        uint256 exact = (edge * k + 10_000 - 1) / 10_000;
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketRegistryCreditLines.CoverageBelowRatio.selector, address(hub), address(gho), exact, 4e24
            )
        );
        registry.recordCreditLine(address(hub), address(gho), edge);
    }

    // TEST-273 verifies: REQ-CONFIG-081, SPEC-CAP-010
    function testFuzz_TEST_273_coverageViewMatchesTheFormula(
        uint256 line,
        uint16 ratio,
        uint256 fundedBalance
    ) public {
        ratio = uint16(bound(ratio, 0, 10_000));
        line = bound(line, 1_000_000, 1e30);
        fundedBalance = bound(fundedBalance, 0, type(uint128).max);
        ps.setCoverageRatioBps(ratio);
        ghoCoverage.setFunded(type(uint256).max / 2, false);
        vm.prank(address(timelock));
        registry.recordCreditLine(address(hub), address(gho), line);
        ghoCoverage.setFunded(fundedBalance, false);
        (uint256 required, uint256 funded) = registry.creditLineCoverage(address(hub), address(gho));
        assertEq(required, (line * 1e18 * uint256(ratio) + 9999) / 10_000);
        assertEq(funded, fundedBalance);
    }

    // TEST-204 verifies: REQ-CONFIG-076, REQ-MREG-025, INV-093
    // The drift view looks only at Active and Offboarding markets: a broken reserve of a Registered or Cancelled
    // market is not reported, an Offboarding one is.
    function test_TEST_204_driftViewSkipsMarketsThatCannotBeLiquidated() public {
        // Break the active market's reserve: drift reported.
        IAaveV4Spoke.ReserveConfig memory on;
        on.receiveSharesEnabled = true;
        spoke.setConfig(VT_RESERVE, on);
        (uint256 m, DriftReason r) = registry.spokeSettingsDrift(address(spoke));
        assertEq(m, marketId);
        assertEq(uint8(r), uint8(DriftReason.ReceiveSharesOn));
        // Offboarding: still liquidatable, still reported.
        vm.prank(address(timelock));
        registry.setMarketOffboarding(marketId);
        (m, r) = registry.spokeSettingsDrift(address(spoke));
        assertEq(m, marketId);
        // Closed: no longer looked at.
        vm.warp(block.timestamp + 5 days);
        registry.closeMarket(marketId);
        (m, r) = registry.spokeSettingsDrift(address(spoke));
        assertEq(m, 0);
        assertEq(uint8(r), uint8(DriftReason.None));
    }

    // TEST-204 verifies: REQ-CONFIG-074, REQ-CONFIG-076, INV-093
    // A Spoke whose proxy now points at another implementation reports SpokeImplementation before any market, and so
    // does one whose slot cannot be read.
    function test_TEST_204_driftViewReportsAReplacedImplementation() public {
        RegistrySpokeImplMock other = new RegistrySpokeImplMock();
        spoke.setImplementation(address(other));
        (uint256 m, DriftReason r) = registry.spokeSettingsDrift(address(spoke));
        assertEq(m, 0);
        assertEq(uint8(r), uint8(DriftReason.SpokeImplementation));
        (address impl,, bool current) = registry.spokeImplementationStatus(address(spoke));
        assertEq(impl, address(other));
        assertFalse(current);
        spoke.setImplementation(address(spokeImpl));
        spoke.setRevertExtSload(true);
        (m, r) = registry.spokeSettingsDrift(address(spoke));
        assertEq(uint8(r), uint8(DriftReason.SpokeImplementation));
        (impl,, current) = registry.spokeImplementationStatus(address(spoke));
        assertEq(impl, address(0));
        assertFalse(current);
        spoke.setRevertExtSload(false);
        (m, r) = registry.spokeSettingsDrift(address(spoke));
        assertEq(uint8(r), uint8(DriftReason.None));
    }

    // TEST-213 verifies: REQ-MREG-031, REQ-CONFIG-080
    // windDownState and settlementReserve of a live market read the record, never a default.
    function test_TEST_213_windDownViewOfALiveMarket() public view {
        WindDownState memory w = registry.windDownState(marketId);
        assertEq(w.offboardedAt, 0);
        assertEq(w.targetLtBps, 0);
        assertEq(registry.settlementReserve(marketId), GHO_RESERVE);
        assertEq(registry.activeMarketCount(address(spoke)), 1);
        assertEq(registry.MAX_ADDRESS_FREEZES_PER_DAY(), 20);
    }
}
