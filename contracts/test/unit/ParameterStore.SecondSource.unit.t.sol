// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {IParameterStoreEvents} from "../../src/policy/parameter-store/IParameterStoreEvents.sol";
import {OracleInputsLayout} from "../../src/policy/parameter-store/types/OracleInputsLayout.sol";
import {SecondSource} from "../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../src/types/SecondSourceKind.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {MockAggregator} from "../utils/mocks/ParameterStoreMocks.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Second-source configuration: every setter that writes it refuses a word the oracles would read as out of
/// range, a `PoolTwap` source for a debt asset with a DebtOracle, and a standby that is no longer independent.
contract ParameterStoreSecondSourceUnitTest is ParameterStoreFixture {
    address internal network;
    address internal standbyNetwork;
    SecondSource internal none;

    function setUp() public {
        _deployStore(false);
        _listMarket();
        network = _networkFeed();
        standbyNetwork = _networkFeed();
        vm.prank(address(timelock));
        store.grantRole(AvanaRoles.APPLICATION_PAUSE_GUARDIAN, emergencyGuardian);
    }

    function _networkFeed() internal returns (address feed) {
        feed = address(new MockAggregator(8, 1e6, 1e12));
        _tl();
        store.setFeed(feed, _feedDef(86_400, 1800));
    }

    function _oracleNetwork(
        address source
    ) internal pure returns (SecondSource memory s) {
        s = SecondSource(SecondSourceKind.OracleNetwork, source, bytes32(0), 88_200, 0, 100);
    }

    function _poolTwap(
        bytes32 poolRef
    ) internal view returns (SecondSource memory s) {
        s = SecondSource(SecondSourceKind.PoolTwap, address(integration), poolRef, 0, 1800, 100);
    }

    function _refused(
        SecondSource memory src,
        SecondSource memory standby
    ) internal {
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setSecondSource(usdc, src, standby);
    }

    /// @dev Each malformed variant of `good`, as the recorded source and as the standby.
    function _refuseEveryMalformedWord(
        SecondSource memory good
    ) internal {
        SecondSource[] memory bad = new SecondSource[](7);
        uint256 k = 0;
        SecondSource memory s = _copy(good);
        s.toleranceBps = 0;
        bad[k++] = s;
        s = _copy(good);
        s.toleranceBps = 501;
        bad[k++] = s;
        s = _copy(good);
        s.source = alice; // no code
        bad[k++] = s;
        if (good.kind == SecondSourceKind.OracleNetwork) {
            s = _copy(good);
            s.maxAge = 0;
            bad[k++] = s;
            s = _copy(good);
            s.twapWindow = 1800;
            bad[k++] = s;
            s = _copy(good);
            s.poolRef = bytes32(uint256(1));
            bad[k++] = s;
            s = _copy(good);
            s.source = address(new MockAggregator(8, 1e6, 1e12)); // no feed definition
            bad[k++] = s;
        } else {
            s = _copy(good);
            s.twapWindow = 0;
            bad[k++] = s;
            s = _copy(good);
            s.poolRef = bytes32(0);
            bad[k++] = s;
            s = _copy(good);
            s.maxAge = 3600;
            bad[k++] = s;
            // A pool source labelled as an oracle network: no feed definition, no age.
            s = _copy(good);
            s.kind = SecondSourceKind.OracleNetwork;
            bad[k++] = s;
        }
        SecondSource memory fine = _oracleNetwork(network);
        for (uint256 i = 0; i < k; ++i) {
            _refused(bad[i], none);
            _refused(fine, bad[i]);
        }
    }

    function _copy(
        SecondSource memory s
    ) internal pure returns (SecondSource memory c) {
        c = SecondSource(s.kind, s.source, s.poolRef, s.maxAge, s.twapWindow, s.toleranceBps);
    }

    // TEST-250 verifies: REQ-PSTORE-028, REQ-PSTORE-029, REQ-PSTORE-033, SPEC-ORC-020
    function test_TEST_250_oracleNetworkWordsAreChecked() public {
        _refuseEveryMalformedWord(_oracleNetwork(standbyNetwork));
        // The recorded source must share no feed with the token's routes either.
        _refused(_oracleNetwork(address(fUsdc)), none);
        _refused(_oracleNetwork(address(fUsdcAlt)), none);
        _refused(SecondSource(SecondSourceKind.None, network, 0, 88_200, 0, 100), none);
        _tl();
        store.setSecondSource(usdc, _oracleNetwork(network), _oracleNetwork(standbyNetwork));
        _assertServedWordsInRange();
    }

    // TEST-250 verifies: REQ-PSTORE-028, REQ-PSTORE-029, REQ-PSTORE-033, SPEC-ORC-020
    function test_TEST_250_poolTwapWordsAreChecked() public {
        _refuseEveryMalformedWord(_poolTwap(bytes32(uint256(7))));
        _tl();
        store.setSecondSource(usdc, _poolTwap(bytes32(uint256(7))), _oracleNetwork(network));
        _assertServedWordsInRange();
    }

    /// @dev Every second-source word `getOracleInputs(..., true)` serves for market 1 fits the type the oracles
    /// decode it into, and the source in force carries its kind's fields only.
    function _assertServedWordsInRange() internal view {
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (usdc, usdt);
        uint256[] memory w = store.getOracleInputs(address(lpOracle), tokens, true);
        uint256 stride = OracleInputsLayout.TOKEN_WORDS + OracleInputsLayout.SECOND_WORDS;
        uint256 k = OracleInputsLayout.HEAD_WORDS + OracleInputsLayout.TOKEN_WORDS;
        assertLe(w[k], uint256(type(SecondSourceKind).max));
        assertGt(w[k], 0);
        assertLe(w[k + 1], type(uint160).max);
        assertLe(w[k + 3], type(uint32).max);
        assertLe(w[k + 4], type(uint32).max);
        assertGt(w[k + 5], 0);
        assertLe(w[k + 5], 500);
        if (w[k] == uint256(SecondSourceKind.OracleNetwork)) {
            assertGt(w[k + 3], 0);
            assertEq(w[k + 4], 0);
            assertGt(w[k + 6], 0);
            assertLe(w[k + 6], 18);
        } else {
            assertEq(w[k + 3], 0);
            assertGt(w[k + 4], 0);
            assertGt(w[k + 2], 0);
        }
        // USDT has no second source: all nine words are zero, which the oracles read as an unconfirmed token.
        for (uint256 i = 0; i < OracleInputsLayout.SECOND_WORDS; ++i) {
            assertEq(w[k + stride + i], 0);
        }
    }

    // TEST-250 verifies: REQ-PSTORE-028, REQ-PSTORE-020
    function test_TEST_250_debtOracleAssetRefusesPoolTwap() public {
        // USDC lent as a debt asset with a DebtOracle carries a stress rise (written before its enableDebtReserve).
        _tl();
        store.tightenDebtStressRiseBps(usdc, 500);
        _refused(_poolTwap(bytes32(uint256(7))), none);
        _refused(_oracleNetwork(network), _poolTwap(bytes32(uint256(7))));
        _tl();
        store.setSecondSource(usdc, _oracleNetwork(network), _oracleNetwork(standbyNetwork));
        assertEq(uint8(store.secondSource(usdc).kind), uint8(SecondSourceKind.OracleNetwork));
    }

    // TEST-250 verifies: REQ-PSTORE-028, REQ-PSTORE-020
    function test_TEST_250_stressRiseRefusedOverAPoolTwapSource() public {
        // The first stress-rise write marks the asset as a DebtOracle asset: refused while a PoolTwap is recorded.
        _tl();
        store.setSecondSource(usdc, _oracleNetwork(network), _poolTwap(bytes32(uint256(7))));
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.tightenDebtStressRiseBps(usdc, 500);
        _tl();
        store.setSecondSource(usdc, _oracleNetwork(network), _oracleNetwork(standbyNetwork));
        _tl();
        store.tightenDebtStressRiseBps(usdc, 500);
        assertEq(store.debtStressRiseBps(usdc), 500);
    }

    // TEST-250 verifies: REQ-PSTORE-029, EMG-103
    function test_TEST_250_standbySwitchRechecksIndependence() public {
        _tl();
        store.setSecondSource(usdc, _oracleNetwork(network), _oracleNetwork(standbyNetwork));
        // A later route change makes the standby a feed of USDC's alternate route: the switch is refused.
        registry.setToken(usdc, _one(address(fUsdc)), _one(standbyNetwork), new address[](0));
        vm.prank(emergencyGuardian);
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.useStandbySecondSource(usdc);
        assertFalse(store.onStandby(usdc));
        registry.setToken(usdc, _one(address(fUsdc)), _one(address(fUsdcAlt)), new address[](0));
        vm.prank(emergencyGuardian);
        store.useStandbySecondSource(usdc);
        assertTrue(store.onStandby(usdc));
    }

    // TEST-250 verifies: REQ-PSTORE-029, REQ-PSTORE-009, EMG-103
    function test_TEST_250_restoreRechecksAndEmitsOnlyOnAChange() public {
        _tl();
        store.setSecondSource(usdc, _oracleNetwork(network), _oracleNetwork(standbyNetwork));
        // Nothing to restore: no event.
        vm.recordLogs();
        _tl();
        store.restoreSecondSource(usdc);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(logs[i].emitter != address(store), "restore without a change emitted");
        }
        vm.prank(emergencyGuardian);
        store.useStandbySecondSource(usdc);
        // The recorded source must pass checkConfig again before it returns.
        lpOracle.setFailed(32);
        _tl();
        vm.expectRevert(
            abi.encodeWithSelector(IParameterStoreErrors.OracleConfigRejected.selector, address(lpOracle), 32)
        );
        store.restoreSecondSource(usdc);
        assertTrue(store.onStandby(usdc));
        lpOracle.setFailed(0);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.SecondSourceSwitched(usdc, false, address(timelock));
        store.restoreSecondSource(usdc);
        assertFalse(store.onStandby(usdc));
    }

    // TEST-250 verifies: REQ-PSTORE-009, REQ-CONFIG-024, REQ-ORACLE-053
    function test_TEST_250_secondSourceFeedChangeRechecksItsMarkets() public {
        _tl();
        store.setSecondSource(usdc, _oracleNetwork(network), _oracleNetwork(standbyNetwork));
        // The standby's feed is used by no route; a change to it still re-runs checkConfig of USDC's markets, since
        // the second-source tolerance bound counts its deviation threshold.
        lpOracle.setFailed(64);
        _tl();
        vm.expectRevert(
            abi.encodeWithSelector(IParameterStoreErrors.OracleConfigRejected.selector, address(lpOracle), 64)
        );
        store.setFeed(standbyNetwork, _feedDef(86_400, 1800));
    }

    // TEST-250 verifies: REQ-PSTORE-029
    function test_TEST_250_standbyPoolMustDifferFromTheSourcePool() public {
        // Two pool sources read through different integrations but the same pool fail together.
        SecondSource memory src = _poolTwap(bytes32(uint256(7)));
        SecondSource memory standby = _poolTwap(bytes32(uint256(7)));
        standby.source = address(new MockAggregator(8, 1e6, 1e12));
        _refused(src, standby);
        standby.poolRef = bytes32(uint256(8));
        _tl();
        store.setSecondSource(usdc, src, standby);
        assertEq(store.standbySecondSource(usdc).poolRef, bytes32(uint256(8)));
    }
}
