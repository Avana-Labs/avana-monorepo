// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {IParameterStoreEvents} from "../../src/policy/parameter-store/IParameterStoreEvents.sol";
import {SecondSource} from "../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../src/types/SecondSourceKind.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {MockAggregator} from "../utils/mocks/ParameterStoreMocks.sol";

/// @notice Structural setters, the liquidation-liveness check and the standby second source.
contract ParameterStoreAdminUnitTest is ParameterStoreFixture {
    function setUp() public {
        _deployStore(false);
        _listMarket();
    }

    // TEST-245 verifies: REQ-PSTORE-021, REQ-PSTORE-024, REQ-CONFIG-052, Q-261
    function test_TEST_245_flashFeeRaiseRechecksLiveness() public {
        _activate();
        // minLB = 10,000 + ⌊500 × 4,000 / 10⁴⌋ = 10,200; floor 30: 10,200 × 9,970 = 101,694,000, which admits any
        // ceiling up to 169, so the hard bound of 100 binds.
        assertTrue(store.liquidationLivenessHolds(address(spoke), M, 1));
        _tl();
        store.setMaxFlashFeeBps(100);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setMaxFlashFeeBps(101);
        _tl();
        store.tightenMaxFlashFeeBps(10);
        // Floor 100: 10,200 × 9,900 = 100,980,000 = 10⁴ × 10,098, so 98 passes with equality and 99 reverts.
        _tl();
        store.setSlippageAllowanceMinBps(M, 100);
        _tl();
        store.setMaxFlashFeeBps(98);
        _tl();
        vm.expectRevert(IParameterStoreErrors.LivenessBound.selector);
        store.setMaxFlashFeeBps(99);
        // A lowering never re-checks, even when the Spoke's bonus no longer supports the pair.
        spoke.setBonus(10_000, 0);
        _tl();
        store.setMaxFlashFeeBps(5);
        assertEq(store.maxFlashFeeBps(), 5);
        _tl();
        vm.expectRevert(IParameterStoreErrors.LivenessBound.selector);
        store.setMaxFlashFeeBps(6);
    }

    // TEST-245 verifies: REQ-PSTORE-021, REQ-PSTORE-015, REQ-CONFIG-041, Q-261
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
        vm.warp(block.timestamp + 432_000);
        _tl();
        store.loosenSlippageAllowanceBps(M, 175);
        vm.warp(block.timestamp + 432_000);
        _tl();
        store.loosenSlippageAllowanceBps(M, 200);
        _tl();
        store.setSlippageAllowanceMinBps(M, 186);
        _tl();
        vm.expectRevert(IParameterStoreErrors.LivenessBound.selector);
        store.setSlippageAllowanceMinBps(M, 187);
        // The floor never exceeds the allowance.
        _tl();
        vm.expectRevert(IParameterStoreErrors.LivenessBound.selector);
        store.setSlippageAllowanceMinBps(M, 201);
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

    // TEST-064 verifies: REQ-CONFIG-052, SPEC-GOV-012, REQ-CONFIG-049, Q-246
    function test_TEST_064_graceBounds() public {
        _tl();
        store.setGraceHealthFactor(0.9e18);
        _tl();
        vm.expectRevert(IParameterStoreErrors.LivenessBound.selector);
        store.setGraceHealthFactor(0.89e18);
        _tl();
        vm.expectRevert(IParameterStoreErrors.LivenessBound.selector);
        store.setGraceHealthFactor(1e18);
        _tl();
        store.setGraceDuration(7200);
        _tl();
        vm.expectRevert(IParameterStoreErrors.LivenessBound.selector);
        store.setGraceDuration(7201);
        _tl();
        store.setGraceDuration(60); // either direction at the normal delay
        assertEq(store.graceDuration(), 60);
    }

    // TEST-064 verifies: REQ-CONFIG-055, REQ-CONFIG-052, REQ-CONFIG-049, REQ-PSTORE-009
    function test_TEST_064_bandAndTimers() public {
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setUsdBand(1e8, 1.02e8);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setUsdBand(0.9e8, 1e8);
        _tl();
        store.setUsdBand(0.95e8, 1.01e8);
        assertEq(store.usdBandLow(), 0.95e8);
        assertEq(store.usdBandHigh(), 1.01e8);
        _tl();
        vm.expectRevert(IParameterStoreErrors.LivenessBound.selector);
        store.setDisagreementPauseMax(3601);
        _tl();
        store.setDisagreementPauseMax(1800);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setCachedWindow(0);
        lpOracle.setFailed(8);
        _tl();
        vm.expectRevert(
            abi.encodeWithSelector(IParameterStoreErrors.OracleConfigRejected.selector, address(lpOracle), 8)
        );
        store.setCachedWindow(1200);
        // A Cancelled market's LPOracle is not consulted.
        registry.setStatus(M, MarketStatus.Cancelled);
        _tl();
        store.setCachedWindow(1200);
        assertEq(store.cachedWindow(), 1200);
    }

    // TEST-064 verifies: REQ-CONFIG-015, REQ-CONFIG-019, REQ-CONFIG-020, REQ-PSTORE-010, SPEC-CF-004
    function test_TEST_064_riskStructural() public {
        _tl();
        store.setPoolRiskFactor(M, 1000);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setPoolRiskFactor(M, 4001);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setTokenCollateralFactorBps(usdc, 10_000);
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreErrors.TokenNotListed.selector, alice));
        store.setTokenCollateralFactorBps(alice, 1);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setAvanaFeeShareBps(5001);
        _tl();
        store.setAvanaFeeShareBps(0);
        assertEq(store.avanaFeeShareBps(), 0);
    }

    function _src(
        SecondSourceKind kind,
        address source,
        bytes32 poolRef,
        uint16 tol
    ) internal pure returns (SecondSource memory s) {
        s.kind = kind;
        s.source = source;
        s.poolRef = poolRef;
        // Each kind carries only its own field: an age for an oracle network, a window for a pool.
        if (kind == SecondSourceKind.OracleNetwork) s.maxAge = 3600;
        else s.twapWindow = 1800;
        s.toleranceBps = tol;
    }

    /// @dev A second oracle network's aggregator with its feed definition, as a recorded `OracleNetwork` source needs.
    function _networkFeed() internal returns (address feed) {
        feed = address(new MockAggregator(8, 1, 2));
        _tl();
        store.setFeed(feed, _feedDef(86_400, 1800));
    }

    // TEST-250 verifies: REQ-PSTORE-028, REQ-PSTORE-029, EMG-103, Q-385
    function test_TEST_250_standbySecondSource() public {
        address pyth = _networkFeed();
        address twapSource = address(integration);
        SecondSource memory src = _src(SecondSourceKind.OracleNetwork, pyth, bytes32(0), 50);
        SecondSource memory standby = _src(SecondSourceKind.PoolTwap, twapSource, bytes32(uint256(1)), 100);
        _tl();
        store.setSecondSource(usdc, src, standby);
        assertEq(store.secondSource(usdc).source, pyth);
        vm.prank(emergencyGuardian);
        vm.expectRevert();
        store.useStandbySecondSource(usdc);
        vm.prank(address(timelock));
        store.grantRole(AvanaRoles.APPLICATION_PAUSE_GUARDIAN, emergencyGuardian);
        vm.prank(emergencyGuardian);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.SecondSourceSwitched(usdc, true, emergencyGuardian);
        store.useStandbySecondSource(usdc);
        assertTrue(store.onStandby(usdc));
        assertEq(store.secondSource(usdc).source, twapSource);
        vm.prank(emergencyGuardian);
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreErrors.StandbyActive.selector, usdc));
        store.useStandbySecondSource(usdc);
        vm.prank(emergencyGuardian);
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreErrors.NoStandby.selector, usdt));
        store.useStandbySecondSource(usdt);
        // Only the timelock restores.
        vm.prank(emergencyGuardian);
        vm.expectRevert();
        store.restoreSecondSource(usdc);
        _tl();
        store.restoreSecondSource(usdc);
        assertFalse(store.onStandby(usdc));
    }

    // TEST-250 verifies: REQ-PSTORE-028, REQ-PSTORE-029, REQ-PSTORE-009
    function test_TEST_250_secondSourceChecks() public {
        address pyth = _networkFeed();
        SecondSource memory empty;
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setSecondSource(usdc, _src(SecondSourceKind.OracleNetwork, pyth, 0, 501), empty);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setSecondSource(usdc, _src(SecondSourceKind.OracleNetwork, alice, 0, 50), empty);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setSecondSource(usdc, empty, empty);
        // A standby sharing a feed with the token's routes, or the recorded source, is refused.
        SecondSource memory src = _src(SecondSourceKind.OracleNetwork, pyth, 0, 50);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setSecondSource(usdc, src, _src(SecondSourceKind.OracleNetwork, address(fUsdcAlt), 0, 50));
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setSecondSource(usdc, src, src);
        _tl();
        store.setSecondSource(usdc, src, empty);
        // A configuration the LPOracle refuses is not written.
        lpOracle.setFailed(16);
        _tl();
        vm.expectRevert(
            abi.encodeWithSelector(IParameterStoreErrors.OracleConfigRejected.selector, address(lpOracle), 16)
        );
        store.setSecondSource(usdc, src, empty);
    }

    // TEST-250 verifies: REQ-PSTORE-029
    function test_TEST_250_newSecondSourceLeavesStandby() public {
        address pyth = _networkFeed();
        SecondSource memory src = _src(SecondSourceKind.OracleNetwork, pyth, 0, 50);
        SecondSource memory standby = _src(SecondSourceKind.PoolTwap, address(integration), bytes32(uint256(1)), 100);
        _tl();
        store.setSecondSource(usdc, src, standby);
        vm.prank(address(timelock));
        store.grantRole(AvanaRoles.APPLICATION_PAUSE_GUARDIAN, aaveGuardian);
        vm.prank(aaveGuardian);
        store.useStandbySecondSource(usdc);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.SecondSourceSwitched(usdc, false, address(timelock));
        store.setSecondSource(usdc, src, standby);
        assertFalse(store.onStandby(usdc));
    }
}
