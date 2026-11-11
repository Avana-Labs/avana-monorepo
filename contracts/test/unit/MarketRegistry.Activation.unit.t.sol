// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {IMarketRegistryEvents} from "../../src/policy/market-registry/IMarketRegistryEvents.sol";
import {IMarketRegistryWindDown} from "../../src/policy/market-registry/IMarketRegistryWindDown.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {WindDownState} from "../../src/policy/market-registry/types/WindDownState.sol";
import {DriftReason} from "../../src/types/DriftReason.sol";
import {Market} from "../../src/types/Market.sol";
import {MarketDef} from "../../src/types/MarketDef.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryLPOracleMock} from "../utils/mocks/MarketRegistryMocks.sol";

/// @notice Market activation, cancellation, offboarding, wind-down and close.
contract MarketRegistryActivationUnitTest is MarketRegistryFixture {
    uint256 internal id;
    address internal vt;
    RegistryLPOracleMock internal lpo;

    function setUp() public {
        _setUpWorld();
        (id, vt, lpo) = _listMarket();
        _prepareActivation(id, vt);
    }

    function _activate() internal {
        vm.prank(address(timelock));
        registry.activateMarket(id);
    }

    function _expectCheck(
        bytes32 check
    ) internal {
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ActivationCheckFailed.selector, id, check));
        registry.activateMarket(id);
    }

    function _dynamic(
        uint16 cf,
        uint32 maxLb,
        uint16 fee
    ) internal {
        IAaveV4Spoke.DynamicReserveConfig memory d;
        (d.collateralFactor, d.maxLiquidationBonus, d.liquidationFee) = (cf, maxLb, fee);
        spoke.setDynamic(VT_RESERVE, d);
    }

    // TEST-138 verifies: REQ-CONFIG-042, REQ-CONFIG-043, REQ-CONFIG-073, REQ-CONFIG-012, Q-068, Q-114
    // Sources: 5.1 TEST-138
    function test_TEST_138_activationWiresTheReserve() public {
        vm.expectEmit(address(registry));
        emit IMarketRegistryEvents.MarketActivated(
            id, block.chainid, address(spoke), VT_RESERVE, address(hub), VT_ASSET
        );
        _activate();
        Market memory m = registry.getMarket(id);
        assertEq(uint8(m.status), uint8(MarketStatus.Active));
        assertEq(m.hubAssetId, VT_ASSET);
        assertEq(m.reserveId, VT_RESERVE);
        assertEq(m.activatedAt, block.timestamp);
        assertEq(registry.marketOfReserve(address(spoke), VT_RESERVE), id);
        assertEq(registry.marketOfHubAsset(address(hub), VT_ASSET), id);
        assertEq(registry.activeMarketCount(address(spoke)), 1);
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.MarketNotRegistered.selector, id));
        registry.activateMarket(id);
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.MarketNotRegistered.selector, 42));
        registry.activateMarket(42);
    }

    // TEST-138 verifies: REQ-CONFIG-042, REQ-CONFIG-043, REQ-CONFIG-066
    function test_TEST_138_aaveSideAndDriftChecks() public {
        hub.setAsset(vt, 7);
        _expectCheck("reserve");
        hub.setAsset(vt, VT_ASSET);
        rm.setDrift(true);
        _expectCheck("aaveConfig");
        rm.setDrift(false);
        rm.setSharesEqual(false);
        _expectCheck("hubShares");
        rm.setSharesEqual(true);
        Market memory m = registry.getMarket(id);
        assertEq(m.reserveId, 0, "a failed activation writes nothing");
        assertEq(registry.marketOfReserve(address(spoke), VT_RESERVE), 0);
    }

    // TEST-138 verifies: REQ-CONFIG-044, REQ-CONFIG-045, REQ-CONFIG-047, REQ-CONFIG-076, Q-270, Q-309
    // Sources: 5.1 TEST-138, SYM-15
    function test_TEST_138_reserveConfigurationChecks() public {
        IAaveV4Spoke.ReserveConfig memory c;
        c.frozen = true;
        spoke.setConfig(VT_RESERVE, c);
        _expectCheck("reserveState");
        c.frozen = false;
        spoke.setConfig(VT_RESERVE, c);
        _dynamic(0, 10_500, 0);
        _expectCheck("collateralFactor");
        _dynamic(8001, 10_500, 0);
        _expectCheck("collateralFactor");
        // ceil(13,400 x 7,500 / 10^4) = 10,050 >= 10^4.
        _dynamic(7500, 13_400, 0);
        _expectCheck("bonusBound");
        _dynamic(7500, 10_500, 1);
        _expectCheck("liquidationFee");
        _dynamic(7500, 10_500, 0);
        hub.setLiquidityFee(VT_ASSET, 1);
        _expectCheck("liquidityFee");
        hub.setLiquidityFee(VT_ASSET, 0);
        spoke.setLiquidationConfig(1e18, 5000);
        _expectCheck("liquidationConfig");
        spoke.setLiquidationConfig(1.2e18, 5000);
        _expectCheck("liquidationConfig");
        // Minimum bonus floor((10,500 - 10,000) x 5,000 / 10,000) = 250 bps against an expected 251.
        spoke.setLiquidationConfig(1.1e18, 5000);
        ps.setLiquidationExpectations(address(spoke), 1.1e18, 251);
        _expectCheck("minBonus");
        ps.setLiquidationExpectations(address(spoke), 1.1e18, 250);
        _activate();
    }

    // TEST-138 verifies: REQ-CONFIG-046, SPEC-CAP-006, REQ-CONFIG-036, SPEC-CF-004, Q-150
    // Sources: 5.1 TEST-138, MATH-UO-28
    function test_TEST_138_parametersCapsAndMargin() public {
        ps.setMarket(id, 0, 10e8, 1_000_000e8, 100_000e8, 1e8);
        _expectCheck("params");
        ps.setMarket(id, 9500, 10e8, 0, 100_000e8, 1e8);
        _expectCheck("caps");
        ps.setMarket(id, 9500, 10e8, 1_000_000e8, 100_000e8, 1e8);
        // SPEC-CAP-006 example: ceil((1,000,000 + 100,000) / 1.00) = 1,100,000 whole tokens.
        hub.setSpokeConfig(VT_ASSET, address(spoke), 1_099_999, 0);
        _expectCheck("addCap");
        hub.setSpokeConfig(VT_ASSET, address(spoke), 1_100_000, 0);
        // CF_LP 9,960: 1 - CF = 40 bps is not above the 50 bps of deviation plus drift.
        rm.setCfLp(9960);
        _expectCheck("listingMargin");
        rm.setCfLp(8000);
        _activate();
    }

    // TEST-138 verifies: REQ-CONFIG-046
    function test_TEST_138_uncappedAddCapPasses() public {
        hub.setSpokeConfig(VT_ASSET, address(spoke), type(uint40).max, 0);
        _activate();
    }

    // TEST-138 verifies: REQ-CONFIG-047, REQ-CONFIG-038, REQ-CONFIG-039
    function test_TEST_138_oracleAndRouteChecks() public {
        lpo.setFailed(4);
        _expectCheck("oracleConfig");
        lpo.setFailed(0);
        ps.setOracleConfigReverts(true);
        _expectCheck("oracleConfig");
        ps.setOracleConfigReverts(false);
        lpo.setState(PriceState.Cached);
        _expectCheck("oracleLive");
        lpo.setState(PriceState.Live);
        vm.prank(address(timelock));
        registry.disableRoute(id, address(usdt), address(gho), 1);
        _expectCheck("routes");
    }

    // TEST-245 verifies: REQ-MREG-032, Q-261
    // Sources: 5.1 TEST-245
    function test_TEST_245_activationLiveness() public {
        ps.setLivenessFails(address(spoke), id, GHO_RESERVE, true);
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryErrors.LivenessBound.selector, address(spoke), id, GHO_RESERVE)
        );
        registry.activateMarket(id);
    }

    // TEST-138 verifies: REQ-CONFIG-007, REQ-CONFIG-042
    function test_TEST_138_reserveHeldByAnotherMarket() public {
        _activate();
        PositionShape memory wide = PositionShape(ShapeKind.TickRange, -100, 100);
        (address vt2, RegistryLPOracleMock o2) = _deployTokenAndOracle(2, wide);
        vm.prank(address(timelock));
        registry.listCollateralMarket(_wideDef(vt2, address(o2), wide));
        hub.setAsset(vt2, VT_ASSET);
        ps.setMarket(2, 9500, 10e8, 1_000_000e8, 100_000e8, 1e8);
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.DuplicateMarketKey.selector);
        registry.activateMarket(2);
    }

    function _wideDef(
        address token,
        address oracle,
        PositionShape memory shape
    ) internal view returns (MarketDef memory d) {
        d = _marketDef(token, oracle);
        d.shape = shape;
    }

    // TEST-213 verifies: REQ-MREG-015, REQ-CONFIG-013, REQ-CONFIG-048, Q-227
    // Sources: 5.1 TEST-213
    function test_TEST_213_cancelAndOffboard() public {
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.MarketNotActive.selector, id));
        registry.setMarketOffboarding(id);
        _activate();
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.MarketNotRegistered.selector, id));
        registry.cancelRegistration(id);
        vm.expectEmit(address(registry));
        emit IMarketRegistryEvents.MarketOffboarding(id);
        vm.prank(address(timelock));
        registry.setMarketOffboarding(id);
        assertEq(uint8(registry.getMarket(id).status), uint8(MarketStatus.Offboarding));
        assertEq(registry.activeMarketCount(address(spoke)), 1, "Offboarding markets still count");
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.MarketNotActive.selector, id));
        registry.setMarketOffboarding(id);
    }

    // TEST-213 verifies: REQ-CONFIG-080, REQ-MREG-015, Q-355
    function test_TEST_213_windDownRampAndClose() public {
        _activate();
        vm.warp(1_000_000);
        vm.prank(address(timelock));
        registry.setMarketOffboarding(id);
        uint256 t0 = block.timestamp;
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryWindDown.MarketNotOffboarding.selector, 42));
        registry.stepWindDown(42);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryWindDown.WindDownStepTooEarly.selector, t0 + 5 days));
        registry.stepWindDown(id);
        // Day 5: first step at the start of the ramp (7,500 bps listed).
        vm.warp(t0 + 5 days);
        vm.expectEmit(address(registry));
        emit IMarketRegistryWindDown.WindDownStepped(id, 7500);
        vm.prank(keeper);
        registry.stepWindDown(id);
        vm.warp(t0 + 5 days + 23 hours);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryWindDown.WindDownStepTooEarly.selector, t0 + 6 days));
        registry.stepWindDown(id);
        // Day 20: halfway, 7,500 - 2,500 x 15/30 = 6,250.
        vm.warp(t0 + 20 days);
        vm.expectEmit(address(registry));
        emit IMarketRegistryWindDown.WindDownStepped(id, 6250);
        registry.stepWindDown(id);
        // Day 40: past the ramp end, the final 5,000.
        vm.warp(t0 + 40 days);
        vm.expectEmit(address(registry));
        emit IMarketRegistryWindDown.WindDownStepped(id, 5000);
        registry.stepWindDown(id);
        collat.setHasDebt(vt, true);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryWindDown.MarketHasDebt.selector, id));
        registry.closeMarket(id);
        collat.setHasDebt(vt, false);
        vm.expectEmit(address(registry));
        emit IMarketRegistryWindDown.MarketClosed(id);
        vm.prank(alice);
        registry.closeMarket(id);
        assertEq(uint8(registry.getMarket(id).status), uint8(MarketStatus.Closed));
        assertEq(registry.activeMarketCount(address(spoke)), 0);
        assertEq(registry.marketOfVaultToken(vt), id, "the old token stays bound to the closed market");
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryWindDown.MarketNotOffboarding.selector, id));
        registry.closeMarket(id);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryWindDown.MarketNotOffboarding.selector, id));
        registry.stepWindDown(id);
    }

    // TEST-213 verifies: REQ-CONFIG-080, Q-355
    // Sources: MarketRegistry review 2026-11-10 findings 3 (close waits for the notice) and 8 (wind-down view)
    function test_TEST_213_closeWaitsForTheNoticeAndStateIsReadable() public {
        _activate();
        WindDownState memory w = registry.windDownState(id);
        assertEq(w.offboardedAt, 0);
        assertEq(w.startLtBps, 0);
        vm.warp(2_000_000);
        vm.prank(address(timelock));
        registry.setMarketOffboarding(id);
        uint256 t0 = block.timestamp;
        w = registry.windDownState(id);
        assertEq(w.offboardedAt, t0);
        assertEq(w.lastStepAt, 0);
        assertEq(w.startLtBps, 7500);
        assertEq(w.currentLtBps, 7500);
        // Debt-free, but the notice has not run: no close in the offboarding block or before the notice ends.
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryWindDown.WindDownStepTooEarly.selector, t0 + 5 days));
        registry.closeMarket(id);
        vm.warp(t0 + 5 days - 1);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryWindDown.WindDownStepTooEarly.selector, t0 + 5 days));
        registry.closeMarket(id);
        vm.warp(t0 + 20 days);
        registry.stepWindDown(id);
        w = registry.windDownState(id);
        assertEq(w.lastStepAt, t0 + 20 days);
        assertEq(w.currentLtBps, 6250);
        vm.prank(alice);
        registry.closeMarket(id);
        assertEq(uint8(registry.getMarket(id).status), uint8(MarketStatus.Closed));
    }

    // TEST-213 verifies: REQ-CONFIG-080
    function testFuzz_TEST_213_rampStaysBetweenFinalAndStart(
        uint16 cf,
        uint32 elapsed
    ) public {
        cf = uint16(bound(cf, 1, 8000));
        _dynamic(cf, 10_500, 0);
        rm.setCfLp(8000);
        // A CF that fails the bonus bound cannot activate; keep it valid.
        vm.assume(uint256(cf) * 10_500 <= 99_990_000);
        _activate();
        vm.prank(address(timelock));
        registry.setMarketOffboarding(id);
        vm.warp(block.timestamp + 5 days + uint256(elapsed));
        vm.recordLogs();
        registry.stepWindDown(id);
        uint16 lt = abi.decode(vm.getRecordedLogs()[0].data, (uint16));
        uint16 lowest = cf < 5000 ? cf : 5000;
        assertGe(lt, lowest);
        assertLe(lt, cf);
        if (elapsed >= 30 days && cf > 5000) assertEq(lt, 5000);
    }

    // TEST-213 verifies: REQ-MREG-033, Q-358
    function test_TEST_213_settlementReserveChange() public {
        vm.startPrank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.UnknownMarket.selector, 42));
        registry.setSettlementReserve(42, GHO_RESERVE);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.UnknownDebtReserve.selector, address(spoke), 3));
        registry.setSettlementReserve(id, 3);
        vm.expectEmit(address(registry));
        emit IMarketRegistryWindDown.SettlementReserveSet(id, GHO_RESERVE);
        registry.setSettlementReserve(id, GHO_RESERVE);
        vm.stopPrank();
    }

    // TEST-204 verifies: REQ-CONFIG-076, INV-093, REQ-MREG-031
    // Sources: 5.1 TEST-204
    function test_TEST_204_spokeSettingsDriftView() public {
        _activate();
        (uint256 m, DriftReason r) = registry.spokeSettingsDrift(address(spoke));
        assertEq(m, 0);
        assertEq(uint8(r), uint8(DriftReason.None));
        IAaveV4Spoke.ReserveConfig memory c;
        c.receiveSharesEnabled = true;
        spoke.setConfig(VT_RESERVE, c);
        (m, r) = registry.spokeSettingsDrift(address(spoke));
        assertEq(m, id);
        assertEq(uint8(r), uint8(DriftReason.ReceiveSharesOn));
        c.receiveSharesEnabled = false;
        spoke.setConfig(VT_RESERVE, c);
        _dynamic(7500, 10_500, 10);
        (, r) = registry.spokeSettingsDrift(address(spoke));
        assertEq(uint8(r), uint8(DriftReason.LiquidationFeeNonZero));
        _dynamic(7500, 10_500, 0);
        hub.setReinvestment(VT_ASSET, alice);
        (, r) = registry.spokeSettingsDrift(address(spoke));
        assertEq(uint8(r), uint8(DriftReason.ReinvestmentController));
        (m, r) = registry.spokeSettingsDrift(alice);
        assertEq(uint8(r), uint8(DriftReason.None));
    }

    // TEST-204 verifies: REQ-CONFIG-076, INV-093
    // Sources: MarketRegistry review 2026-11-10 finding 11 (the drift view checks underlying and asset id)
    function test_TEST_204_driftViewChecksReserveIdentity() public {
        _activate();
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (alice, address(hub), uint16(VT_ASSET), 18);
        IAaveV4Spoke.ReserveConfig memory c;
        IAaveV4Spoke.DynamicReserveConfig memory d;
        (d.collateralFactor, d.maxLiquidationBonus) = (7500, 10_500);
        spoke.setReserve(VT_RESERVE, r, c, d);
        assertEq(_driftReason(), uint8(DriftReason.ReserveIdentity), "another underlying");
        (r.underlying, r.assetId) = (vt, uint16(VT_ASSET + 1));
        spoke.setReserve(VT_RESERVE, r, c, d);
        assertEq(_driftReason(), uint8(DriftReason.ReserveIdentity), "another Hub asset id");
        r.hub = alice;
        spoke.setReserve(VT_RESERVE, r, c, d);
        assertEq(_driftReason(), uint8(DriftReason.HomeHubMismatch), "another Hub");
        (r.hub, r.assetId) = (address(hub), uint16(VT_ASSET));
        spoke.setReserve(VT_RESERVE, r, c, d);
        assertEq(_driftReason(), uint8(DriftReason.None));
        // Every failed read reports ReserveIdentity, so the view fails closed and never reverts.
        bytes[4] memory reads = [
            abi.encodeWithSelector(IAaveV4Spoke.getReserve.selector),
            abi.encodeWithSelector(IAaveV4Spoke.getReserveConfig.selector),
            abi.encodeWithSelector(IAaveV4Spoke.getDynamicReserveConfig.selector),
            abi.encodeWithSignature("getAssetConfig(uint256)")
        ];
        for (uint256 i = 0; i < reads.length; ++i) {
            vm.mockCallRevert(i == 3 ? address(hub) : address(spoke), reads[i], "");
            assertEq(_driftReason(), uint8(DriftReason.ReserveIdentity));
            vm.clearMockedCalls();
        }
        assertEq(_driftReason(), uint8(DriftReason.None));
    }

    function _driftReason() internal view returns (uint8) {
        (, DriftReason r) = registry.spokeSettingsDrift(address(spoke));
        return uint8(r);
    }
}

