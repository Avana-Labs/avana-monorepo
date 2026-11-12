// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {IParameterStoreEvents} from "../../src/policy/parameter-store/IParameterStoreEvents.sol";
import {DebtReserveParams} from "../../src/policy/parameter-store/types/DebtReserveParams.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";

/// @notice Tighten setters: strictly safer, within hard and liveness bounds, in that order (SPEC-GOV-011).
contract ParameterStoreTightenUnitTest is ParameterStoreFixture {
    function setUp() public {
        _deployStore(false);
        _listMarket();
    }

    // TEST-064 verifies: REQ-PSTORE-031, REQ-CONFIG-050, REQ-CONFIG-051, REQ-CONFIG-067, Q-398, REQ-ACCESS-037, REQ-ACCESS-120
    function test_TEST_064_hardHealthFloorRaisesWithinBounds() public {
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterTightened("hardHealthFloor", bytes32(M), 0, 1.1e18, address(timelock));
        store.tightenHardHealthFloor(M, 1.1e18);
        _tl();
        store.tightenHardHealthFloor(M, 1.12e18);
        assertEq(store.hardHealthFloor(M), 1.12e18);
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotStricter.selector);
        store.tightenHardHealthFloor(M, 1.08e18);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.tightenHardHealthFloor(M, 1.3e18);
    }

    // TEST-064 verifies: REQ-PSTORE-031, REQ-CONFIG-050
    function test_TEST_064_hardHealthFloorBelowOneRejected() public {
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.tightenHardHealthFloor(M, 0.99e18);
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreErrors.UnknownMarket.selector, 9));
        store.tightenHardHealthFloor(9, 1.1e18);
    }

    // TEST-064 verifies: REQ-CONFIG-052, REQ-CONFIG-041, REQ-PSTORE-015, INV-047
    function test_TEST_064_slippageNeverBelowMarketFloor() public {
        _tl();
        store.tightenSlippageAllowanceBps(M, 30);
        assertEq(store.getMarketParams(M).slippageAllowanceBps, 30);
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotStricter.selector);
        store.tightenSlippageAllowanceBps(M, 30);
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotStricter.selector);
        store.tightenSlippageAllowanceBps(M, 31);
    }

    // TEST-064 verifies: REQ-CONFIG-052, SPEC-GOV-009, INV-047, REQ-ACCESS-095, REQ-ACCESS-120
    function test_TEST_064_slippageBelowFloorIsLivenessBound() public {
        _tl();
        vm.expectRevert(IParameterStoreErrors.LivenessBound.selector);
        store.tightenSlippageAllowanceBps(M, 29);
    }

    // TEST-064 verifies: REQ-CONFIG-052, SPEC-GOV-009, REQ-PSTORE-009, INV-047, REQ-ACCESS-039, REQ-ACCESS-097, REQ-ACCESS-076
    function test_TEST_064_consistencyTolerance() public {
        _tl();
        store.tightenConsistencyToleranceBps(M, 10);
        assertEq(store.getMarketParams(M).consistencyToleranceBps, 10);
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotStricter.selector);
        store.tightenConsistencyToleranceBps(M, 10);
        _tl();
        store.setConsistencyToleranceBps(M, 50);
        _tl();
        vm.expectRevert(IParameterStoreErrors.LivenessBound.selector);
        store.tightenConsistencyToleranceBps(M, 9);
    }

    // TEST-064 verifies: REQ-PSTORE-009, REQ-PSTORE-013, REQ-CONFIG-051, SPEC-GOV-011
    function test_TEST_064_tightenRerunsCheckConfig() public {
        // A check the tightening's own write breaks reverts it, naming only that check.
        lpOracle.setFloors(45, 0, 0);
        _tl();
        vm.expectRevert(
            abi.encodeWithSelector(IParameterStoreErrors.OracleConfigRejected.selector, address(lpOracle), 4)
        );
        store.tightenConsistencyToleranceBps(M, 40);
        // A check that failed before the write is not the tightening's doing and never blocks it.
        lpOracle.setFloors(0, 0, 0);
        lpOracle.setFailed(16);
        _tl();
        store.tightenConsistencyToleranceBps(M, 40);
        assertEq(store.getMarketParams(M).consistencyToleranceBps, 40);
        // Nor does a checkConfig that already reverted.
        lpOracle.setFailed(0);
        lpOracle.setReverts(true);
        _tl();
        store.tightenConsistencyToleranceBps(M, 30);
        assertEq(store.getMarketParams(M).consistencyToleranceBps, 30);
    }

    // TEST-064 verifies: REQ-CONFIG-024, REQ-CONFIG-052, SPEC-GOV-009, REQ-ACCESS-040, REQ-ACCESS-098, REQ-ACCESS-077
    function test_TEST_064_feedToleranceNeverBelowLowerBound() public {
        // dev(primary) 25 + dev(alternate) 25 + margin 50 = 100.
        assertEq(store.feedAgreementToleranceMinBps(usdc), 100);
        _tl();
        store.tightenFeedAgreementToleranceBps(usdc, 100);
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotStricter.selector);
        store.tightenFeedAgreementToleranceBps(usdc, 100);
        _tl();
        store.setFeedAgreementToleranceBps(usdc, 150);
        _tl();
        vm.expectRevert(IParameterStoreErrors.LivenessBound.selector);
        store.tightenFeedAgreementToleranceBps(usdc, 99);
    }

    // TEST-064 verifies: REQ-CONFIG-023, REQ-PSTORE-009, Q-182, REQ-ACCESS-038
    function test_TEST_064_borrowAgeOnlyLowers() public {
        address f = address(fUsdc);
        _tl();
        store.tightenBorrowPriceMaxAge(f, 4200);
        assertEq(store.borrowPriceMaxAge(f), 4200);
        assertEq(store.liquidationPriceMaxAge(f), 88_200);
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotStricter.selector);
        store.tightenBorrowPriceMaxAge(f, 4200);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.tightenBorrowPriceMaxAge(f, 0);
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreErrors.UnknownFeed.selector, alice));
        store.tightenBorrowPriceMaxAge(alice, 1);
    }

    // TEST-064 verifies: REQ-CONFIG-015, REQ-CONFIG-050
    function test_TEST_064_poolRiskFactorAndFloorRounding() public {
        _tl();
        store.tightenPoolRiskFactor(M, 3500);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.tightenPoolRiskFactor(M, 0);
        _tl();
        store.setDebtAssetParams(gho, _rounding(1e18));
        _tl();
        store.tightenFloorRoundingAllowance(gho, 5e17);
        assertEq(store.floorRoundingAllowance(gho), 5e17);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.tightenFloorRoundingAllowance(gho, 0);
    }

    // TEST-272 verifies: REQ-RISK-042, REQ-RISK-044, REQ-PSTORE-026, SPEC-CAP-005, Q-383, Q-399
    function test_TEST_272_capsLowerOnly() public {
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.CapTightened("marketUsdCap", bytes32(M), 5_000_000e8, 4_000_000e8, address(timelock));
        store.tightenMarketUsdCap(M, 4_000_000e8);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.tightenMarketUsdCap(M, 400_000e8); // below the 500,000 slice
        _tl();
        store.tightenTopUpSliceUsd(M, 0);
        _tl();
        store.tightenMarketUsdCap(M, 400_000e8);
        address h = address(hub);
        _tl();
        store.tightenTokenUsdCap(h, usdc, 10_000_000e8);
        assertEq(store.tokenUsdCap(h, usdc), 10_000_000e8);
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotStricter.selector);
        store.tightenTokenUsdCap(h, usdt, 1);
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreErrors.UnknownHub.selector, alice));
        store.tightenDepositorUsdCap(alice, 1);
        _tl();
        store.tightenDepositorUsdCap(h, 500_000e8);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.tightenDepositorUsdCap(h, 0);
    }

    // TEST-272 verifies: REQ-RISK-042, SPEC-CAP-005, Q-383, Q-399, Q-403
    function test_TEST_272_poolShareDefaultAndOverride() public {
        bytes32 key = keccak256(abi.encode(uint32(1), address(pool), bytes32(0)));
        assertEq(store.poolShareMaxBpsOf(key), 10_000);
        _tl();
        store.tightenPoolShareMaxBpsOf(M, 1000);
        assertEq(store.poolShareMaxBpsOf(key), 1000);
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotStricter.selector);
        store.tightenPoolShareMaxBpsOf(M, 1000);
        _tl();
        store.tightenPoolShareMaxBps(500);
        assertEq(store.poolShareMaxBpsOf(key), 500); // the override never exceeds the default
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.tightenPoolShareMaxBps(0);
    }

    // TEST-064 verifies: REQ-PSTORE-005, Q-230
    function test_TEST_064_minPledgeRaisesWithinBound() public {
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.MinPledgeUsdSet(M, 10e8, 20e8);
        store.tightenMinPledgeUsd(M, 20e8);
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotStricter.selector);
        store.tightenMinPledgeUsd(M, 20e8);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.tightenMinPledgeUsd(M, 100_000e8 + 1);
        _tl();
        store.tightenMinPledgeUsd(M, 100_000e8);
    }

    // TEST-064 verifies: REQ-CONFIG-070, Q-379, REQ-ACCESS-131, REQ-ROUTE-006
    function test_TEST_064_routeDepthRaises() public {
        _tl();
        store.tightenRouteDepthThreshold(M, usdc, gho, 0, 1_000_000e8);
        assertEq(store.routeDepthThreshold(M, usdc, gho, 0), 1_000_000e8);
        assertEq(store.routeDepthThreshold(M, usdc, gho, 1), 0);
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotStricter.selector);
        store.tightenRouteDepthThreshold(M, usdc, gho, 0, 1_000_000e8);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.tightenRouteDepthThreshold(M, usdc, gho, 2, 1);
    }

    // TEST-064 verifies: REQ-PSTORE-016, REQ-PSTORE-018, REQ-PSTORE-020, REQ-PSTORE-024, REQ-PSTORE-030, Q-399, REQ-ACCESS-165
    function test_TEST_064_breakerShortfallStressFlash() public {
        _tl();
        store.tightenGateRecoverySeconds(7200);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.tightenGateRecoverySeconds(7201);
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotStricter.selector);
        store.tightenGateRecoverySeconds(7200);
        _tl();
        store.tightenMaxShortfallBps(50);
        assertEq(store.maxShortfallBps(), 50);
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotStricter.selector);
        store.tightenMaxShortfallBps(50);
        _tl();
        store.tightenDebtStressRiseBps(usdc, 500);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.tightenDebtStressRiseBps(usdc, 5001);
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreErrors.TokenNotListed.selector, alice));
        store.tightenDebtStressRiseBps(alice, 500);
        _tl();
        store.tightenMaxFlashFeeBps(0);
        assertEq(store.maxFlashFeeBps(), 0);
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotStricter.selector);
        store.tightenMaxFlashFeeBps(0);
        // breakerDeficitMax starts at 0, so only a loosening writes its first value.
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotStricter.selector);
        store.tightenBreakerDeficitMax(address(hub), gho, 0);
        _tl();
        store.loosenBreakerDeficitMax(address(hub), gho, 10_000e18);
        _tl();
        store.tightenBreakerDeficitMax(address(hub), gho, 5000e18);
        assertEq(store.breakerDeficitMax(address(hub), gho), 5000e18);
    }

    // TEST-064 verifies: REQ-CONFIG-051, REQ-CONFIG-067, INV-047
    function testFuzz_TEST_064_tightenMinPledgeOnlyRaises(
        uint256 value
    ) public {
        uint256 before = store.minPledgeUsd(M);
        _tl();
        (bool ok,) = address(store).call(abi.encodeCall(store.tightenMinPledgeUsd, (M, value)));
        assertEq(ok, value > before && value <= 100_000e8);
        assertEq(store.minPledgeUsd(M), ok ? value : before);
    }

    // TEST-064 verifies: REQ-CONFIG-052, REQ-CONFIG-051, INV-047
    function testFuzz_TEST_064_tightenSlippageStaysInLiveness(
        uint16 value
    ) public {
        _tl();
        (bool ok,) = address(store).call(abi.encodeCall(store.tightenSlippageAllowanceBps, (M, value)));
        assertEq(ok, value < 100 && value >= 30);
        assertGe(store.getMarketParams(M).slippageAllowanceBps, store.slippageAllowanceMinBps(M));
    }

    // TEST-064 verifies: REQ-PSTORE-031, REQ-CONFIG-051
    function testFuzz_TEST_064_tightenHardFloorInBounds(
        uint256 value
    ) public {
        _tl();
        (bool ok,) = address(store).call(abi.encodeCall(store.tightenHardHealthFloor, (M, value)));
        assertEq(ok, value >= 1e18 && value <= 1.25e18);
    }

    // TEST-064 verifies: REQ-PSTORE-011
    function test_TEST_064_cancelledMarketStillScoped() public {
        registry.setStatus(M, MarketStatus.Cancelled);
        _tl();
        store.tightenMinPledgeUsd(M, 11e8);
        assertEq(store.minPledgeUsd(M), 11e8);
    }

    function _rounding(
        uint256 v
    ) internal pure returns (DebtReserveParams memory p) {
        p.floorRoundingAllowance = v;
    }
}
