// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {DebtReserveDef} from "../../src/policy/market-registry/types/DebtReserveDef.sol";
import {MarketDef} from "../../src/types/MarketDef.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {
    RegistryCoverageSpokeMock,
    RegistryDebtOracleMock,
    RegistryLPOracleMock,
    RegistryTokenMock
} from "../utils/mocks/MarketRegistryMocks.sol";

/// @notice A CDP Spoke with two debt reserves (GHO and DAI): activation needs a primary and a backup route from each
/// pool token into every enabled debt asset, a new reserve is checked against every Active and Offboarding market of
/// the Spoke and no other, and the liveness bound reports the exact failing (market, reserve) pair.
contract MarketRegistryMultiDebtUnitTest is MarketRegistryFixture {
    uint256 internal constant DAI_RESERVE = 7;
    uint256 internal constant DAI_ASSET = 4;

    RegistryTokenMock internal dai;
    RegistryDebtOracleMock internal daiOracle;
    RegistryCoverageSpokeMock internal daiCoverage;

    function setUp() public {
        _setUpWorld();
        dai = new RegistryTokenMock(18);
        _listToken(address(dai), "dai");
        daiOracle = new RegistryDebtOracleMock(address(dai), address(registry), address(ps));
        daiCoverage = new RegistryCoverageSpokeMock(address(hub), address(dai), DAI_ASSET);
        daiCoverage.setFunded(1e30, false);
        hub.setAsset(address(dai), DAI_ASSET);
        hub.setSpokeConfig(DAI_ASSET, address(spoke), 0, 1_000_000);
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (address(dai), address(hub), uint16(DAI_ASSET), 18);
        IAaveV4Spoke.ReserveConfig memory c;
        c.borrowable = true;
        IAaveV4Spoke.DynamicReserveConfig memory d;
        spoke.setReserve(DAI_RESERVE, r, c, d);
        aaveOracle.setSource(DAI_RESERVE, address(daiOracle));
        ps.setStressRise(address(dai), 500);
        vm.startPrank(address(timelock));
        registry.setCoverageSpoke(address(hub), address(dai), address(daiCoverage));
        registry.recordCreditLine(address(hub), address(dai), 2_000_000);
        vm.stopPrank();
    }

    function _daiDef() internal view returns (DebtReserveDef memory) {
        return DebtReserveDef({
            reserveId: DAI_RESERVE,
            asset: address(dai),
            decimals: 18,
            fundingHub: address(hub),
            hubAssetId: DAI_ASSET,
            priceSource: address(daiOracle),
            fixedPrice: false,
            coverageSpoke: address(daiCoverage),
            crossHub: false,
            approved: false
        });
    }

    function _enableDai() internal {
        vm.prank(address(timelock));
        registry.enableDebtReserve(address(spoke), _daiDef());
    }

    function _daiRoutes(
        uint256 id
    ) internal {
        _setRoute(id, address(usdc), address(dai), 0, "daiA");
        _setRoute(id, address(usdc), address(dai), 1, "daiB");
        _setRoute(id, address(usdt), address(dai), 0, "daiC");
        _setRoute(id, address(usdt), address(dai), 1, "daiD");
    }

    function _expectActivation(
        uint256 id,
        bytes memory err
    ) internal {
        vm.prank(address(timelock));
        if (err.length != 0) vm.expectRevert(err);
        registry.activateMarket(id);
    }

    function _routesErr(
        uint256 id
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IMarketRegistryErrors.ActivationCheckFailed.selector, id, bytes32("routes"));
    }

    // TEST-054 verifies: REQ-CONFIG-039, REQ-CONFIG-047, REQ-MREG-032, REQ-CONFIG-073, REQ-ROUTE-001
    // Sources: 5.1 TEST-054, TEST-138
    // With GHO and DAI enabled, activation needs both slots of every (pool token, debt asset) pair: each of the four
    // DAI slots missing alone fails "routes", and all present pass.
    function test_TEST_054_activationNeedsEverySlotIntoEveryDebtAsset() public {
        _enableDai();
        (uint256 id, address vt,) = _listMarket();
        _prepareActivation(id, vt);
        _expectActivation(id, _routesErr(id));
        string[4] memory deps = ["daiA", "daiB", "daiC", "daiD"];
        address[2] memory toks = [address(usdc), address(usdt)];
        for (uint256 skip = 0; skip < 4; ++skip) {
            uint256 snap = vm.snapshotState();
            for (uint256 k = 0; k < 4; ++k) {
                if (k == skip) continue;
                // Slot k is pool token k / 2 and kind k % 2.
                _setRoute(id, toks[k / 2], address(dai), uint8(k % 2), deps[k]);
            }
            _expectActivation(id, _routesErr(id));
            vm.revertToState(snap);
        }
        _daiRoutes(id);
        _expectActivation(id, "");
    }

    // TEST-054 verifies: REQ-CONFIG-039, REQ-CONFIG-061, REQ-MREG-012, REQ-ROUTE-001, REQ-ROUTE-021
    // A disabled slot counts as missing at activation.
    function test_TEST_054_disabledSlotCountsAsMissing() public {
        _enableDai();
        (uint256 id, address vt,) = _listMarket();
        _prepareActivation(id, vt);
        _daiRoutes(id);
        vm.prank(address(timelock));
        registry.disableRoute(id, address(usdt), address(dai), 0);
        _expectActivation(id, _routesErr(id));
    }

    // TEST-054 verifies: REQ-CONFIG-039, REQ-ROUTE-001
    // A pool token that is itself the debt asset needs no route into itself: with USDC enabled as debt asset only the
    // USDT slots into USDC are required.
    function test_TEST_054_poolTokenThatIsTheDebtAssetNeedsNoRoute() public {
        RegistryDebtOracleMock usdcOracle = new RegistryDebtOracleMock(address(usdc), address(registry), address(ps));
        RegistryCoverageSpokeMock usdcCoverage = new RegistryCoverageSpokeMock(address(hub), address(usdc), 2);
        usdcCoverage.setFunded(1e30, false);
        hub.setAsset(address(usdc), 2);
        hub.setSpokeConfig(2, address(spoke), 0, 1000);
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (address(usdc), address(hub), uint16(2), 6);
        IAaveV4Spoke.ReserveConfig memory c;
        c.borrowable = true;
        IAaveV4Spoke.DynamicReserveConfig memory d;
        spoke.setReserve(5, r, c, d);
        aaveOracle.setSource(5, address(usdcOracle));
        ps.setStressRise(address(usdc), 500);
        vm.startPrank(address(timelock));
        registry.setCoverageSpoke(address(hub), address(usdc), address(usdcCoverage));
        registry.recordCreditLine(address(hub), address(usdc), 1_000_000);
        registry.enableDebtReserve(
            address(spoke),
            DebtReserveDef(
                5, address(usdc), 6, address(hub), 2, address(usdcOracle), false, address(usdcCoverage), false, false
            )
        );
        vm.stopPrank();
        (uint256 id, address vt,) = _listMarket();
        _prepareActivation(id, vt);
        _expectActivation(id, _routesErr(id));
        _setRoute(id, address(usdt), address(usdc), 0, "u1");
        _setRoute(id, address(usdt), address(usdc), 1, "u2");
        _expectActivation(id, "");
    }

    // TEST-245 verifies: REQ-MREG-032, Q-261
    // Sources: 5.1 TEST-245
    // Activation checks the liveness bound against every enabled reserve and reports the first failing one.
    function test_TEST_245_activationReportsTheFailingReserve() public {
        _enableDai();
        (uint256 id, address vt,) = _listMarket();
        _prepareActivation(id, vt);
        _daiRoutes(id);
        ps.setLivenessFails(address(spoke), id, DAI_RESERVE, true);
        _expectActivation(
            id, abi.encodeWithSelector(IMarketRegistryErrors.LivenessBound.selector, address(spoke), id, DAI_RESERVE)
        );
        ps.setLivenessFails(address(spoke), id, GHO_RESERVE, true);
        _expectActivation(
            id, abi.encodeWithSelector(IMarketRegistryErrors.LivenessBound.selector, address(spoke), id, GHO_RESERVE)
        );
        ps.setLivenessFails(address(spoke), id, GHO_RESERVE, false);
        ps.setLivenessFails(address(spoke), id, DAI_RESERVE, false);
        _expectActivation(id, "");
    }

    // TEST-245 verifies: REQ-MREG-032, REQ-CONFIG-039, Q-261, REQ-ROUTE-001, REQ-ROUTE-036
    // A new debt reserve is checked against the Spoke's Active and Offboarding markets: missing routes or a failing
    // bound on either reverts LivenessBound with that market; Registered, Cancelled and Closed markets are not checked.
    function test_TEST_245_newReserveCheckedAgainstLiquidatableMarketsOnly() public {
        (uint256 active,,) = _activeMarket();
        (uint256 off,) = _secondMarketActive(PositionShape(ShapeKind.TickRange, -80, 80), 21);
        vm.prank(address(timelock));
        registry.setMarketOffboarding(off);
        // A Registered and a Cancelled market without any DAI route.
        (uint256 reg,,) = _listShape(PositionShape(ShapeKind.TickRange, -30, 30));
        (uint256 can,,) = _listShape(PositionShape(ShapeKind.TickRange, -40, 40));
        vm.prank(address(timelock));
        registry.cancelRegistration(can);
        // No DAI routes anywhere: the first liquidatable market fails.
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryErrors.LivenessBound.selector, address(spoke), active, DAI_RESERVE)
        );
        registry.enableDebtReserve(address(spoke), _daiDef());
        // Routes for the Active market only: the Offboarding one fails.
        _daiRoutes(active);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryErrors.LivenessBound.selector, address(spoke), off, DAI_RESERVE)
        );
        registry.enableDebtReserve(address(spoke), _daiDef());
        // Routes for both: the liveness bound failing on the Offboarding market still blocks.
        _daiRoutes(off);
        ps.setLivenessFails(address(spoke), off, DAI_RESERVE, true);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryErrors.LivenessBound.selector, address(spoke), off, DAI_RESERVE)
        );
        registry.enableDebtReserve(address(spoke), _daiDef());
        ps.setLivenessFails(address(spoke), off, DAI_RESERVE, false);
        _enableDai();
        assertTrue(registry.isApprovedDebtReserve(address(spoke), DAI_RESERVE));
        // The Registered and Cancelled markets have no DAI route and did not block the enablement.
        (address r,) = registry.getRoute(reg, address(usdc), address(dai), 0);
        assertEq(r, address(0));
        (r,) = registry.getRoute(can, address(usdc), address(dai), 0);
        assertEq(r, address(0));
    }

    function _listShape(
        PositionShape memory sh
    ) internal returns (uint256 id, address vt, RegistryLPOracleMock o) {
        (vt, o) = _deployTokenAndOracle(registry.marketCount() + 1, sh);
        MarketDef memory d = _marketDef(vt, address(o));
        d.shape = sh;
        vm.prank(address(timelock));
        id = registry.listCollateralMarket(d);
    }

    /// @dev Lists and activates a market of `sh` on Hub asset and Spoke reserve `slot`.
    function _secondMarketActive(
        PositionShape memory sh,
        uint256 slot
    ) internal returns (uint256 id, address vt) {
        (id, vt,) = _listShape(sh);
        hub.setAsset(vt, slot);
        hub.setSpokeConfig(slot, address(spoke), 2_000_000, 0);
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (vt, address(hub), uint16(slot), 18);
        IAaveV4Spoke.ReserveConfig memory c;
        IAaveV4Spoke.DynamicReserveConfig memory d;
        (d.collateralFactor, d.maxLiquidationBonus) = (7500, 10_500);
        spoke.setReserve(slot, r, c, d);
        ps.setMarket(id, 9500, 10e8, 1_000_000e8, 100_000e8, 1e8);
        _setRoutesInto(id, address(gho));
        vm.prank(address(timelock));
        registry.activateMarket(id);
    }
}
