// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStoreEvents} from "../../src/policy/parameter-store/IParameterStoreEvents.sol";
import {DebtReserveParams} from "../../src/policy/parameter-store/types/DebtReserveParams.sol";
import {MarketParams} from "../../src/policy/parameter-store/types/MarketParams.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice One event per change with the parameter's name, scope, old and new value, and `caller` where the event
/// has one (2.9 Events): every structural, listing and loosen setter, checked field by field, and the exact number
/// of logs each emits.
contract ParameterStoreEventsUnitTest is ParameterStoreFixture {
    bytes32 internal constant CHAIN = bytes32(0);

    function setUp() public {
        _deployStore(false);
        _listMarket();
    }

    function _a(
        address a
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _pair(
        address a,
        address b
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(a, b));
    }

    /// @dev Runs `data` as the timelock and returns the number of logs the store emitted.
    function _logs(
        bytes memory data
    ) internal returns (uint256 n) {
        vm.recordLogs();
        vm.prank(address(timelock));
        (bool ok,) = address(store).call(data);
        assertTrue(ok, "setter refused");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(store)) ++n;
        }
    }

    // ─── Structural setters: ParameterSet(name, scope, old, new) ───

    // TEST-061 verifies: REQ-CONFIG-054, REQ-CONFIG-052
    function test_TEST_061_marketStructuralEvents() public {
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("consistencyToleranceBps", bytes32(M), 50, 75);
        store.setConsistencyToleranceBps(M, 75);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("twapWindow", bytes32(M), 1800, 3600);
        store.setTwapWindow(M, 3600);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("poolRiskFactor", bytes32(M), 4000, 2500);
        store.setPoolRiskFactor(M, 2500);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("slippageAllowanceMinBps", bytes32(M), 30, 60);
        store.setSlippageAllowanceMinBps(M, 60);
    }

    // TEST-061 verifies: REQ-CONFIG-054, REQ-CONFIG-049
    function test_TEST_061_chainStructuralEvents() public {
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("cachedWindow", CHAIN, 3600, 1800);
        store.setCachedWindow(1800);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("disagreementPauseMax", CHAIN, 3600, 600);
        store.setDisagreementPauseMax(600);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("graceDuration", CHAIN, 1800, 3600);
        store.setGraceDuration(3600);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("graceHealthFactor", CHAIN, 0.95e18, 0.92e18);
        store.setGraceHealthFactor(0.92e18);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("feedAgreementMarginBps", CHAIN, 50, 30);
        store.setFeedAgreementMarginBps(30);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("maxFlashFeeBps", CHAIN, 10, 40);
        store.setMaxFlashFeeBps(40);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("coverageRatioBps", CHAIN, 0, 2000);
        store.setCoverageRatioBps(2000);
    }

    // TEST-061 verifies: REQ-CONFIG-055, REQ-CONFIG-054
    function test_TEST_061_usdBandEmitsBothLevels() public {
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("usdBandLow", CHAIN, 0.9e8, 0.95e8);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("usdBandHigh", CHAIN, 1.02e8, 1.05e8);
        store.setUsdBand(0.95e8, 1.05e8);
        assertEq(_logs(abi.encodeCall(store.setUsdBand, (0.9e8, 1.02e8))), 2);
    }

    // TEST-061 verifies: REQ-CONFIG-019, REQ-CONFIG-024, REQ-PSTORE-010, REQ-CONFIG-056, REQ-ACCESS-109
    function test_TEST_061_tokenAndFeeEvents() public {
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("tokenCollateralFactorBps", _a(usdc), 7800, 7000);
        store.setTokenCollateralFactorBps(usdc, 7000);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("feedAgreementToleranceBps", _a(usdt), 150, 400);
        store.setFeedAgreementToleranceBps(usdt, 400);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("avanaFeeShareBps", CHAIN, 2000, 0);
        store.setAvanaFeeShareBps(0);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("feeRecipient", CHAIN, uint160(feeRecipient), uint160(bob));
        store.setFeeRecipient(bob);
    }

    // TEST-061 verifies: REQ-PSTORE-022
    function test_TEST_061_expectationEventsCarryTheOldValues() public {
        address s = address(spoke);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("aaveTargetHealthFactor", _a(s), 0, 1.1e18);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("minLiquidationBonus", _a(s), 0, 200);
        store.setLiquidationExpectations(s, 1.1e18, 200);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("aaveTargetHealthFactor", _a(s), 1.1e18, 1.05e18);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("minLiquidationBonus", _a(s), 200, 300);
        store.setLiquidationExpectations(s, 1.05e18, 300);
    }

    // TEST-061 verifies: REQ-CONFIG-050, REQ-PSTORE-006
    function test_TEST_061_debtAssetParamsEmitsBoth() public {
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("floorRoundingAllowance", _a(gho), 0, 0.5e18);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.DebtAssetParamsSet(gho, 0.5e18);
        store.setDebtAssetParams(gho, DebtReserveParams(0.5e18));
        assertEq(store.debtAssetParams(gho).floorRoundingAllowance, 0.5e18);
        assertEq(_logs(abi.encodeCall(store.setDebtAssetParams, (gho, DebtReserveParams(1e18)))), 2);
    }

    // ─── Listing writes ───

    // TEST-061 verifies: REQ-PSTORE-004, REQ-PSTORE-005
    function test_TEST_061_initialMarketParamsEmitEveryField() public {
        MarketParams memory p = _launchMarketParams();
        p.twapWindow = 3600;
        p.consistencyToleranceBps = 40;
        p.slippageAllowanceBps = 90;
        p.slippageAllowanceMinBps = 35;
        p.poolRiskFactor = 3500;
        p.minPledgeUsd = 20e8;
        p.hardHealthFloor = 1.1e18;
        bytes32 scope = bytes32(M);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("twapWindow", scope, 1800, 3600);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("consistencyToleranceBps", scope, 50, 40);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("slippageAllowanceBps", scope, 100, 90);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("slippageAllowanceMinBps", scope, 30, 35);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("poolRiskFactor", scope, 4000, 3500);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("hardHealthFloor", scope, 0, 1.1e18);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.MinPledgeUsdSet(M, 10e8, 20e8);
        store.setInitialMarketParams(M, p);
        MarketParams memory got = store.getMarketParams(M);
        assertEq(got.twapWindow, 3600);
        assertEq(got.consistencyToleranceBps, 40);
        assertEq(got.slippageAllowanceBps, 90);
        assertEq(got.slippageAllowanceMinBps, 35);
        assertEq(got.poolRiskFactor, 3500);
        assertEq(got.minPledgeUsd, 20e8);
        assertEq(got.hardHealthFloor, 1.1e18);
        assertEq(_logs(abi.encodeCall(store.setInitialMarketParams, (M, p))), 7);
    }

    // TEST-272 verifies: REQ-RISK-041, REQ-PSTORE-026
    function test_TEST_272_initialHubAndTokenCapsEmitCapLoosened() public {
        address hub2 = makeAddr("hub2");
        registry.setHub(hub2, true);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.CapLoosened("depositorUsdCap", _a(hub2), 0, 750_000e8, address(timelock));
        store.setInitialHubCaps(hub2, 750_000e8);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.CapLoosened("tokenUsdCap", _pair(hub2, usdt), 0, 3_000_000e8, address(timelock));
        store.setInitialTokenCap(hub2, usdt, 3_000_000e8);
    }

    // TEST-272 verifies: REQ-RISK-041
    function test_TEST_272_unchangedInitialCapsEmitOnlyTheFloor() public {
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.StressFloorSet(M, 1e8, 1e8);
        store.setInitialMarketCaps(M, 5_000_000e8, 500_000e8, 1e8);
        assertEq(_logs(abi.encodeCall(store.setInitialMarketCaps, (M, 5_000_000e8, 500_000e8, 1e8))), 1);
        // A raise of one and a lowering of the other emit one of each.
        assertEq(_logs(abi.encodeCall(store.setInitialMarketCaps, (M, 6_000_000e8, 400_000e8, 1e8))), 3);
    }

    // ─── Loosen setters: ParameterLoosened / CapLoosened with the caller ───

    // TEST-061 verifies: REQ-CONFIG-053, REQ-RISK-043, REQ-PSTORE-017, REQ-ACCESS-109
    function test_TEST_061_capLoosenEvents() public {
        address tl = address(timelock);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.CapLoosened("marketUsdCap", bytes32(M), 5_000_000e8, 7_500_000e8, tl);
        store.loosenMarketUsdCap(M, 7_500_000e8);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.CapLoosened("topUpSliceUsd", bytes32(M), 500_000e8, 750_000e8, tl);
        store.loosenTopUpSliceUsd(M, 750_000e8);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.CapLoosened("tokenUsdCap", _pair(address(hub), usdc), 20_000_000e8, 30_000_000e8, tl);
        store.loosenTokenUsdCap(address(hub), usdc, 30_000_000e8);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.CapLoosened("depositorUsdCap", _a(address(hub)), 1_000_000e8, 1_500_000e8, tl);
        store.loosenDepositorUsdCap(address(hub), 1_500_000e8);
    }

    // TEST-061 verifies: REQ-RISK-043, Q-383, Q-403
    function test_TEST_061_poolShareLoosenEvents() public {
        address tl = address(timelock);
        bytes32 key = keccak256(abi.encode(uint32(1), address(pool), bytes32(0)));
        vm.startPrank(tl);
        store.tightenPoolShareMaxBps(4000);
        store.tightenPoolShareMaxBpsOf(M, 500);
        vm.stopPrank();
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.CapLoosened("poolShareMaxBpsOf", key, 500, 4000, tl);
        store.loosenPoolShareMaxBpsOf(M, 4000);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.CapLoosened("poolShareMaxBps", CHAIN, 4000, 10_000, tl);
        store.loosenPoolShareMaxBps(10_000);
        // The override (4,000) is now below the default and served as is.
        assertEq(store.poolShareMaxBpsOf(key), 4000);
    }

    // TEST-061 verifies: REQ-CONFIG-053, REQ-PSTORE-016, REQ-PSTORE-018, REQ-PSTORE-020, REQ-PSTORE-030, REQ-ACCESS-109
    function test_TEST_061_parameterLoosenEvents() public {
        address tl = address(timelock);
        vm.startPrank(tl);
        store.tightenHardHealthFloor(M, 1.1e18);
        store.tightenDebtStressRiseBps(usdc, 500);
        store.tightenGateRecoverySeconds(3600);
        store.setDebtAssetParams(gho, DebtReserveParams(0.5e18));
        vm.stopPrank();
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterLoosened("hardHealthFloor", bytes32(M), 1.1e18, 1.08e18, tl);
        store.loosenHardHealthFloor(M, 1.08e18);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterLoosened("slippageAllowanceBps", bytes32(M), 100, 125, tl);
        store.loosenSlippageAllowanceBps(M, 125);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterLoosened("floorRoundingAllowance", _a(gho), 0.5e18, 1e18, tl);
        store.loosenFloorRoundingAllowance(gho, 1e18);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterLoosened("maxShortfallBps", CHAIN, 1000, 2000, tl);
        store.loosenMaxShortfallBps(2000);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterLoosened("debtStressRiseBps", _a(usdc), 500, 200, tl);
        store.loosenDebtStressRiseBps(usdc, 200);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterLoosened("gateRecoverySeconds", CHAIN, 3600, 900, tl);
        store.loosenGateRecoverySeconds(900);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterLoosened("breakerDeficitMax", _pair(address(hub), gho), 0, 10_000e18, tl);
        store.loosenBreakerDeficitMax(address(hub), gho, 10_000e18);
    }

    // TEST-061 verifies: REQ-PSTORE-005, REQ-CONFIG-070, REQ-ROUTE-006
    function test_TEST_061_pledgeAndRouteDepthEvents() public {
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.MinPledgeUsdSet(M, 10e8, 1e8);
        store.loosenMinPledgeUsd(M, 1e8);
        _tl();
        store.tightenRouteDepthThreshold(M, usdt, gho, 0, 3_000_000e8);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.RouteDepthThresholdSet(M, usdt, gho, 0, 3_000_000e8, 2_000_000e8);
        store.loosenRouteDepthThreshold(M, usdt, gho, 0, 2_000_000e8);
        assertEq(store.routeDepthThreshold(M, usdt, gho, 0), 2_000_000e8);
    }

    // ─── One log per write ───

    // TEST-061 verifies: REQ-CONFIG-054
    function test_TEST_061_singleValueSettersEmitExactlyOneLog() public {
        bytes[12] memory calls = [
            abi.encodeCall(store.setConsistencyToleranceBps, (M, 60)),
            abi.encodeCall(store.setTwapWindow, (M, 2400)),
            abi.encodeCall(store.setPoolRiskFactor, (M, 3000)),
            abi.encodeCall(store.setSlippageAllowanceMinBps, (M, 40)),
            abi.encodeCall(store.setCachedWindow, (100)),
            abi.encodeCall(store.setGraceDuration, (100)),
            abi.encodeCall(store.setGraceHealthFactor, (0.91e18)),
            abi.encodeCall(store.setTokenCollateralFactorBps, (usdt, 7000)),
            abi.encodeCall(store.setMaxFlashFeeBps, (11)),
            abi.encodeCall(store.setCoverageRatioBps, (1)),
            abi.encodeCall(store.setBorrowPriceMaxAge, (address(fUsdt), 5000)),
            abi.encodeCall(store.setStressFloorUsd, (M, 2e8))
        ];
        for (uint256 i = 0; i < calls.length; ++i) {
            assertEq(_logs(calls[i]), 1, "setter emitted other than one log");
        }
    }
}
