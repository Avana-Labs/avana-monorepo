// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketStatus} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {IParameterStoreBase} from "../../src/policy/parameter-store/IParameterStoreBase.sol";
import {DebtReserveParams} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";

/// @notice Tighten setters: strictly safer, within hard and liveness bounds, in that order (SPEC-GOV-011).
contract ParameterStoreTightenUnitTest is ParameterStoreFixture {
    function setUp() public {
        _deployStore();
        _listMarket();
    }

    // TEST-064 verifies: REQ-CONFIG-052, REQ-CONFIG-041, REQ-PSTORE-015, INV-047
    function test_TEST_064_slippageNeverBelowMarketFloor() public {
        _tl();
        store.tightenSlippageAllowanceBps(M, 30);
        assertEq(store.getMarketParams(M).slippageAllowanceBps, 30);
        _tl();
        vm.expectRevert(IParameterStoreBase.NotStricter.selector);
        store.tightenSlippageAllowanceBps(M, 30);
        _tl();
        vm.expectRevert(IParameterStoreBase.NotStricter.selector);
        store.tightenSlippageAllowanceBps(M, 31);
    }

    // TEST-064 verifies: REQ-CONFIG-052, SPEC-GOV-009, INV-047, REQ-ACCESS-095, REQ-ACCESS-120
    function test_TEST_064_slippageBelowFloorIsLivenessBound() public {
        _tl();
        vm.expectRevert(IParameterStoreBase.LivenessBound.selector);
        store.tightenSlippageAllowanceBps(M, 29);
    }

    // TEST-064 verifies: REQ-CONFIG-023, REQ-PSTORE-009, Q-182, REQ-ACCESS-038
    function test_TEST_064_borrowAgeOnlyLowers() public {
        address f = address(fUsdc);
        _tl();
        store.tightenBorrowPriceMaxAge(f, 4200);
        assertEq(store.borrowPriceMaxAge(f), 4200);
        assertEq(store.liquidationPriceMaxAge(f), 88_200);
        _tl();
        vm.expectRevert(IParameterStoreBase.NotStricter.selector);
        store.tightenBorrowPriceMaxAge(f, 4200);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.tightenBorrowPriceMaxAge(f, 0);
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.UnknownFeed.selector, alice));
        store.tightenBorrowPriceMaxAge(alice, 1);
    }

    // TEST-064 verifies: REQ-CONFIG-015, REQ-CONFIG-050
    function test_TEST_064_poolRiskFactorAndFloorRounding() public {
        _tl();
        store.tightenPoolRiskFactor(M, 3500);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.tightenPoolRiskFactor(M, 0);
        _tl();
        store.setDebtAssetParams(gho, _rounding(1e18));
        _tl();
        store.tightenFloorRoundingAllowance(gho, 5e17);
        assertEq(store.floorRoundingAllowance(gho), 5e17);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.tightenFloorRoundingAllowance(gho, 0);
    }

    // TEST-272 verifies: REQ-RISK-042, REQ-RISK-044, REQ-PSTORE-026, SPEC-CAP-005, Q-383, Q-399
    function test_TEST_272_capsLowerOnly() public {
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreBase.CapTightened("marketUsdCap", bytes32(M), 5_000_000e8, 4_000_000e8, address(timelock));
        store.tightenMarketUsdCap(M, 4_000_000e8);
        _tl();
        // Below the 500,000 slice: the slice only admits rescue top-ups, which reduce risk.
        store.tightenMarketUsdCap(M, 400_000e8);
        assertEq(store.marketUsdCap(M), 400_000e8);
        address h = address(hub);
        _tl();
        store.tightenTokenUsdCap(h, usdc, 10_000_000e8);
        assertEq(store.tokenUsdCap(h, usdc), 10_000_000e8);
        _tl();
        vm.expectRevert(IParameterStoreBase.NotStricter.selector);
        store.tightenTokenUsdCap(h, usdt, 1);
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.UnknownHub.selector, alice));
        store.tightenTokenUsdCap(alice, usdc, 1);
        _tl();
        store.tightenTokenUsdCap(h, usdc, 0);
        assertEq(store.tokenUsdCap(h, usdc), 0, "a token cap tightens to 0");
    }

    // TEST-272 verifies: REQ-RISK-042, REQ-RISK-044
    /// @notice (a) The market cap tightens from $5,000,000 to $5,000 and then to 0, each step at the short delay; the
    /// $500,000 slice does not bound it.
    function test_TEST_272_marketCapTightensFromFiveMillionToFiveThousandThenZero() public {
        assertEq(store.marketUsdCap(M), 5_000_000e8);
        uint256[4] memory steps = [uint256(1_000_000e8), 50_000e8, 5000e8, 0];
        for (uint256 i = 0; i < steps.length; ++i) {
            _tl();
            store.tightenMarketUsdCap(M, steps[i]);
            assertEq(store.marketUsdCap(M), steps[i]);
        }
        _tl();
        vm.expectRevert(IParameterStoreBase.NotStricter.selector);
        store.tightenMarketUsdCap(M, 0);
    }

    // TEST-272 verifies: REQ-RISK-042, REQ-RISK-044, REQ-PSTORE-026
    /// @notice (b) A token cap tightens to $2,000 and then to 0.
    function test_TEST_272_tokenCapTightensToTwoThousandThenZero() public {
        address h = address(hub);
        _tl();
        store.tightenTokenUsdCap(h, usdc, 2000e8);
        assertEq(store.tokenUsdCap(h, usdc), 2000e8);
        _tl();
        store.tightenTokenUsdCap(h, usdc, 0);
        assertEq(store.tokenUsdCap(h, usdc), 0);
    }

    // TEST-064 verifies: REQ-PSTORE-005, Q-230
    function test_TEST_064_minPledgeRaisesWithinBound() public {
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreBase.MinPledgeUsdSet(M, 10e8, 20e8);
        store.tightenMinPledgeUsd(M, 20e8);
        _tl();
        vm.expectRevert(IParameterStoreBase.NotStricter.selector);
        store.tightenMinPledgeUsd(M, 20e8);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
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
        vm.expectRevert(IParameterStoreBase.NotStricter.selector);
        store.tightenRouteDepthThreshold(M, usdc, gho, 0, 1_000_000e8);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.tightenRouteDepthThreshold(M, usdc, gho, 2, 1);
    }

    // TEST-064 verifies: REQ-PSTORE-016, REQ-PSTORE-018, REQ-PSTORE-020, REQ-PSTORE-024, REQ-PSTORE-030, Q-399, REQ-ACCESS-165
    function test_TEST_064_breakerShortfallStressFlash() public {
        _tl();
        store.tightenGateRecoverySeconds(7200);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.tightenGateRecoverySeconds(7201);
        _tl();
        vm.expectRevert(IParameterStoreBase.NotStricter.selector);
        store.tightenGateRecoverySeconds(7200);
        _tl();
        store.tightenMaxShortfallBps(50);
        assertEq(store.maxShortfallBps(), 50);
        _tl();
        vm.expectRevert(IParameterStoreBase.NotStricter.selector);
        store.tightenMaxShortfallBps(50);
        _tl();
        store.tightenDebtStressRiseBps(usdc, 500);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.tightenDebtStressRiseBps(usdc, 5001);
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.TokenNotListed.selector, alice));
        store.tightenDebtStressRiseBps(alice, 500);
        _tl();
        store.tightenMaxFlashFeeBps(0);
        assertEq(store.maxFlashFeeBps(), 0);
        _tl();
        vm.expectRevert(IParameterStoreBase.NotStricter.selector);
        store.tightenMaxFlashFeeBps(0);
        // breakerDeficitMax starts at 0, so only a loosening writes its first value.
        _tl();
        vm.expectRevert(IParameterStoreBase.NotStricter.selector);
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
