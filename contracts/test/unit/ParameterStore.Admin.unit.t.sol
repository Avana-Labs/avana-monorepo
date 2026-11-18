// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtReserveDef} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {IParameterStoreBase} from "../../src/policy/parameter-store/IParameterStoreBase.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {MockHub, MockSpoke} from "../utils/mocks/ParameterStoreMocks.sol";

/// @notice Structural setters and the liquidation-liveness check.
contract ParameterStoreAdminUnitTest is ParameterStoreFixture {
    function setUp() public {
        _deployStore();
        _listMarket();
    }

    // TEST-245 verifies: REQ-PSTORE-021, REQ-PSTORE-024, REQ-CONFIG-052, Q-261, REQ-ACCESS-186, REQ-ACCESS-044, REQ-ACCESS-095
    function test_TEST_245_flashFeeRaiseRechecksLiveness() public {
        _activate();
        // minLB = 10,000 + ⌊500 × 4,000 / 10⁴⌋ = 10,200; floor 30: 10,200 × 9,970 = 101,694,000, which admits any
        // ceiling up to 169, so the hard bound of 100 binds.
        assertTrue(store.liquidationLivenessHolds(address(spoke), M, 1));
        _tl();
        store.setMaxFlashFeeBps(100);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.setMaxFlashFeeBps(101);
        _tl();
        store.tightenMaxFlashFeeBps(10);
        // Floor 100: 10,200 × 9,900 = 100,980,000 = 10⁴ × 10,098, so 98 passes with equality and 99 reverts.
        _tl();
        store.setSlippageAllowanceMinBps(M, 100);
        _tl();
        store.setMaxFlashFeeBps(98);
        _tl();
        vm.expectRevert(IParameterStoreBase.LivenessBound.selector);
        store.setMaxFlashFeeBps(99);
        // A lowering never re-checks, even when the Spoke's bonus no longer supports the pair.
        spoke.setBonus(10_000, 0);
        _tl();
        store.setMaxFlashFeeBps(5);
        assertEq(store.maxFlashFeeBps(), 5);
        _tl();
        vm.expectRevert(IParameterStoreBase.LivenessBound.selector);
        store.setMaxFlashFeeBps(6);
    }

    // TEST-245 verifies: REQ-PSTORE-021, REQ-PSTORE-015, REQ-CONFIG-041, REQ-CONFIG-044, Q-261, REQ-ACCESS-044, REQ-ACCESS-095
    function test_TEST_245_floorRaiseRechecksLiveness() public {
        _activate();
        // f = 10: 10,200 × (10⁴ − s) ≥ 100,100,000 holds up to s = 186 (10,200 × 9,814 = 100,102,800).
        _tl();
        store.setSlippageAllowanceMinBps(M, 35);
        _tl();
        store.loosenSlippageAllowanceBps(M, 125);
        vm.warp(block.timestamp + 432_000);
        _tl();
        store.loosenSlippageAllowanceBps(M, 150);
        // LIQ-I1 fee bound at minLB = 10,200: s ≤ ⌊(10⁴ − f) × 200 / 10,200⌋, 156 at f = 2,000, so 175 is refused; with
        // the fee share at 0 the bound is 196.
        vm.warp(block.timestamp + 432_000);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.loosenSlippageAllowanceBps(M, 175);
        _tl();
        store.setAvanaFeeShareBps(0);
        _tl();
        store.loosenSlippageAllowanceBps(M, 175);
        vm.warp(block.timestamp + 432_000);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.loosenSlippageAllowanceBps(M, 197);
        _tl();
        store.loosenSlippageAllowanceBps(M, 196);
        _tl();
        store.setSlippageAllowanceMinBps(M, 186);
        _tl();
        vm.expectRevert(IParameterStoreBase.LivenessBound.selector);
        store.setSlippageAllowanceMinBps(M, 187);
        // The floor never exceeds the allowance.
        _tl();
        vm.expectRevert(IParameterStoreBase.LivenessBound.selector);
        store.setSlippageAllowanceMinBps(M, 197);
        // Lowering the floor needs no check.
        spoke.setBonus(10_000, 0);
        _tl();
        store.setSlippageAllowanceMinBps(M, 30);
    }

    // TEST-245 verifies: REQ-PSTORE-021
    function test_TEST_245_livenessViewFailsClosed() public {
        assertTrue(store.liquidationLivenessHolds(address(spoke), M, 1));
        assertFalse(store.liquidationLivenessHolds(address(spoke), M, 2)); // unknown debt reserve
        assertFalse(store.liquidationLivenessHolds(alice, M, 1)); // another Spoke
        assertFalse(store.liquidationLivenessHolds(address(spoke), 9, 1)); // unknown market
        spoke.setBonus(9999, 4000);
        assertFalse(store.liquidationLivenessHolds(address(spoke), M, 1)); // maxLiquidationBonus below 10⁴
        spoke.setBonus(10_500, 4000);
        spoke.setReverts(true);
        assertFalse(store.liquidationLivenessHolds(address(spoke), M, 1)); // reserve read reverts
        spoke.setReverts(false);
        hub.setAsset(address(vaultToken), 7);
        assertTrue(store.liquidationLivenessHolds(address(spoke), M, 1));
    }

    // TEST-245 verifies: REQ-PSTORE-021
    function testFuzz_TEST_245_livenessMatchesInequality(
        uint32 maxLb,
        uint16 factor,
        uint16 floor
    ) public {
        maxLb = uint32(bound(maxLb, 10_000, 20_000));
        factor = uint16(bound(factor, 0, 10_000));
        floor = uint16(bound(floor, 30, 100));
        spoke.setBonus(maxLb, factor);
        _tl();
        (bool ok,) = address(store).call(abi.encodeCall(store.setSlippageAllowanceMinBps, (M, floor)));
        assertTrue(ok); // Registered: no liveness check yet
        uint256 minLb = 10_000 + (uint256(maxLb) - 10_000) * factor / 10_000;
        assertEq(
            store.liquidationLivenessHolds(address(spoke), M, 1),
            minLb * (10_000 - uint256(floor)) >= 10_000 * uint256(10_010)
        );
    }

    // TEST-064 verifies: REQ-CONFIG-015, REQ-CONFIG-019, REQ-CONFIG-020, REQ-PSTORE-010, SPEC-CF-004, REQ-ACCESS-138
    function test_TEST_064_riskStructural() public {
        _tl();
        store.setPoolRiskFactor(M, 1000);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.setPoolRiskFactor(M, 9001);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.setTokenCollateralFactorBps(usdc, 10_000);
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.TokenNotListed.selector, alice));
        store.setTokenCollateralFactorBps(alice, 1);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.setAvanaFeeShareBps(5001);
        _tl();
        store.setAvanaFeeShareBps(0);
        assertEq(store.avanaFeeShareBps(), 0);
    }

    // TEST-245 verifies: REQ-PSTORE-021
    /// @notice Every Aave read of minLB fails closed in the view: a reverting Hub `getAssetId`, Spoke `getReserve`,
    /// `getDynamicReserveConfig` or `getLiquidationConfig` makes `liquidationLivenessHolds` return false, not revert.
    function test_TEST_245_livenessViewFailsClosedOnEveryRead() public {
        assertTrue(store.liquidationLivenessHolds(address(spoke), M, 1));
        vm.mockCallRevert(address(hub), abi.encodeWithSelector(MockHub.getAssetId.selector), "hub");
        assertFalse(store.liquidationLivenessHolds(address(spoke), M, 1), "getAssetId");
        vm.clearMockedCalls();
        bytes4[3] memory sels = [
            MockSpoke.getReserve.selector,
            MockSpoke.getDynamicReserveConfig.selector,
            MockSpoke.getLiquidationConfig.selector
        ];
        for (uint256 i; i < sels.length; ++i) {
            vm.mockCallRevert(address(spoke), abi.encodeWithSelector(sels[i]), "spoke");
            assertFalse(store.liquidationLivenessHolds(address(spoke), M, 1));
            vm.clearMockedCalls();
        }
        assertTrue(store.liquidationLivenessHolds(address(spoke), M, 1));
    }

    // TEST-245 verifies: REQ-PSTORE-021
    /// @notice A zero bonus (`maxLiquidationBonus` of 10,000) gives minLB = 10,000, not 0: with no slippage floor and
    /// no flash fee the inequality holds with equality.
    function test_TEST_245_zeroBonusHoldsAtZeroFloorAndFee() public {
        spoke.setBonus(10_000, 0);
        _tl();
        store.setSlippageAllowanceMinBps(M, 0);
        _tl();
        store.tightenMaxFlashFeeBps(0);
        assertTrue(store.liquidationLivenessHolds(address(spoke), M, 1));
    }

    // TEST-245 verifies: REQ-PSTORE-021, REQ-PSTORE-024
    /// @notice The liveness checks count only enabled debt reserves: with the Spoke's one reserve disabled, raising the
    /// slippage floor and the flash ceiling on an Active market whose bonus no longer supports them both pass.
    function test_TEST_245_disabledReservesAreNotChecked() public {
        _activate();
        DebtReserveDef memory d = registry.getDebtReserve(address(spoke), 1);
        d.approved = false;
        registry.setDebtReserve(address(spoke), d);
        spoke.setBonus(10_000, 0);
        _tl();
        store.setSlippageAllowanceMinBps(M, 50);
        assertEq(store.getMarketParams(M).slippageAllowanceMinBps, 50);
        _tl();
        store.setMaxFlashFeeBps(20);
        assertEq(store.maxFlashFeeBps(), 20);
    }
}
