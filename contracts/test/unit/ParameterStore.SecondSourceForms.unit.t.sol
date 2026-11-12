// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {IParameterStoreEvents} from "../../src/policy/parameter-store/IParameterStoreEvents.sol";
import {SecondSource} from "../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../src/types/SecondSourceKind.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {MockAggregator, MockPool} from "../utils/mocks/ParameterStoreMocks.sol";

/// @notice Second-source well-formedness of REQ-PSTORE-028 and REQ-PSTORE-029: every malformed variant of an
/// oracle-network and a pool-TWAP source is refused `OutOfBounds`, both as the recorded source and as the standby;
/// the boundaries that are accepted; the independence of the standby; and the guardian switch's own errors.
contract ParameterStoreSecondSourceFormsUnitTest is ParameterStoreFixture {
    MockAggregator internal netA;
    MockAggregator internal netB;
    MockAggregator internal undefinedFeed;
    address internal twapReader;
    address internal twapReader2;
    bytes internal oob = abi.encodeWithSelector(IParameterStoreErrors.OutOfBounds.selector);

    function setUp() public {
        _deployStore(false);
        _listMarket();
        netA = new MockAggregator(8, 1e6, 1e12);
        netB = new MockAggregator(8, 1e6, 1e12);
        undefinedFeed = new MockAggregator(8, 1e6, 1e12);
        twapReader = address(integration);
        twapReader2 = address(new MockPool());
        vm.startPrank(address(timelock));
        store.setFeed(address(netA), _feedDef(86_400, 1800));
        store.setFeed(address(netB), _feedDef(86_400, 1800));
        store.grantRole(AvanaRoles.APPLICATION_PAUSE_GUARDIAN, emergencyGuardian);
        vm.stopPrank();
    }

    function _net(
        address source
    ) internal pure returns (SecondSource memory) {
        return SecondSource(SecondSourceKind.OracleNetwork, source, bytes32(0), 88_200, 0, 100);
    }

    function _twap(
        bytes32 poolRef
    ) internal view returns (SecondSource memory) {
        return SecondSource(SecondSourceKind.PoolTwap, twapReader, poolRef, 0, 1800, 120);
    }

    function _twapOther(
        bytes32 poolRef
    ) internal view returns (SecondSource memory) {
        return SecondSource(SecondSourceKind.PoolTwap, twapReader2, poolRef, 0, 1800, 120);
    }

    function _none() internal pure returns (SecondSource memory s) {}

    function _set(
        address token,
        SecondSource memory src,
        SecondSource memory standby
    ) internal returns (bool ok, bytes memory ret) {
        vm.prank(address(timelock));
        (ok, ret) = address(store).call(abi.encodeCall(store.setSecondSource, (token, src, standby)));
    }

    /// @dev Every malformed variant of an oracle-network source for USDC.
    function _badNetworks() internal returns (SecondSource[] memory v) {
        v = new SecondSource[](12);
        for (uint256 i = 0; i < v.length; ++i) {
            v[i] = _net(address(netA));
        }
        v[0].toleranceBps = 0;
        v[1].toleranceBps = 501;
        v[2].toleranceBps = type(uint16).max;
        v[3].source = makeAddr("noCode");
        v[4].source = address(0);
        v[5].maxAge = 0;
        v[6].twapWindow = 1;
        v[7].poolRef = bytes32(uint256(1));
        // Holds code but has no feed definition, so no pinned decimals or bounds to serve.
        v[8].source = address(undefinedFeed);
        // A feed of the token's own routes is not independent.
        v[9].source = address(fUsdc);
        v[10].source = address(fUsdcAlt);
        v[11].kind = SecondSourceKind.None;
    }

    /// @dev Every malformed variant of a pool-TWAP source for USDC.
    function _badTwaps() internal returns (SecondSource[] memory v) {
        v = new SecondSource[](8);
        for (uint256 i = 0; i < v.length; ++i) {
            v[i] = _twap(bytes32(uint256(7)));
        }
        v[0].toleranceBps = 0;
        v[1].toleranceBps = 501;
        v[2].source = makeAddr("noCodeReader");
        v[3].twapWindow = 0;
        v[4].maxAge = 1;
        v[5].poolRef = bytes32(0);
        v[6].toleranceBps = type(uint16).max;
        v[7].source = address(fUsdc);
    }

    // ─── Every malformed form, as the recorded source and as the standby ───

    // TEST-250 verifies: REQ-PSTORE-028, REQ-PSTORE-029, SPEC-ORC-020
    function test_TEST_250_everyMalformedNetworkSourceIsRefused() public {
        SecondSource[] memory v = _badNetworks();
        for (uint256 i = 0; i < v.length; ++i) {
            (bool ok, bytes memory ret) = _set(usdc, v[i], _none());
            assertFalse(ok, "malformed recorded source accepted");
            assertEq(ret, oob);
            // Same form as the standby of a valid recorded source (a None standby is simply no standby).
            if (v[i].kind == SecondSourceKind.None) continue;
            (ok, ret) = _set(usdc, _net(address(netB)), v[i]);
            assertFalse(ok, "malformed standby accepted");
            assertEq(ret, oob);
        }
        assertEq(uint8(store.secondSource(usdc).kind), 0);
        assertEq(uint8(store.standbySecondSource(usdc).kind), 0);
    }

    // TEST-250 verifies: REQ-PSTORE-028, REQ-PSTORE-029, SPEC-ORC-020
    function test_TEST_250_everyMalformedTwapSourceIsRefused() public {
        SecondSource[] memory v = _badTwaps();
        for (uint256 i = 0; i < v.length; ++i) {
            (bool ok, bytes memory ret) = _set(usdc, v[i], _none());
            assertFalse(ok, "malformed recorded twap accepted");
            assertEq(ret, oob);
            (ok, ret) = _set(usdc, _net(address(netB)), v[i]);
            assertFalse(ok, "malformed standby twap accepted");
            assertEq(ret, oob);
        }
    }

    // TEST-250 verifies: REQ-PSTORE-028, REQ-PSTORE-029
    function test_TEST_250_standbyRouteFeedIsNotIndependent() public {
        // A feed only in USDC's standby route is a route feed too.
        MockAggregator standbyRoute = new MockAggregator(8, 1e6, 1e12);
        registry.setToken(usdc, _one(address(fUsdc)), _one(address(fUsdcAlt)), _one(address(standbyRoute)));
        _tl();
        store.setFeed(address(standbyRoute), _feedDef(86_400, 1800));
        (bool ok, bytes memory ret) = _set(usdc, _net(address(standbyRoute)), _none());
        assertFalse(ok);
        assertEq(ret, oob);
        (ok, ret) = _set(usdc, _net(address(netA)), _net(address(standbyRoute)));
        assertFalse(ok);
        assertEq(ret, oob);
        // Another token's route feed is independent of USDC.
        (ok,) = _set(usdc, _net(address(netA)), _none());
        assertTrue(ok);
    }

    // ─── Accepted boundaries ───

    // TEST-250 verifies: REQ-PSTORE-028, REQ-CONFIG-050
    function test_TEST_250_toleranceBoundsAccepted() public {
        SecondSource memory s = _net(address(netA));
        s.toleranceBps = 1;
        (bool ok,) = _set(usdc, s, _none());
        assertTrue(ok);
        assertEq(store.secondSource(usdc).toleranceBps, 1);
        s.toleranceBps = 500;
        SecondSource memory b = _twap(bytes32(uint256(9)));
        b.toleranceBps = 500;
        (ok,) = _set(usdc, s, b);
        assertTrue(ok);
        assertEq(store.secondSource(usdc).toleranceBps, 500);
        assertEq(store.standbySecondSource(usdc).toleranceBps, 500);
        // The smallest pool-TWAP window and age limit are 1 second.
        SecondSource memory t = _twap(bytes32(uint256(1)));
        t.twapWindow = 1;
        SecondSource memory n = _net(address(netB));
        n.maxAge = 1;
        (ok,) = _set(usdc, t, n);
        assertTrue(ok);
        assertEq(store.secondSource(usdc).twapWindow, 1);
        assertEq(store.standbySecondSource(usdc).maxAge, 1);
    }

    // TEST-250 verifies: REQ-PSTORE-028, REQ-PSTORE-029
    function test_TEST_250_everyWellFormedPairAccepted() public {
        SecondSource[4] memory sources =
            [_net(address(netA)), _twap(bytes32(uint256(1))), _net(address(netB)), _twap(bytes32(uint256(2)))];
        SecondSource[4] memory standbys = [
            _net(address(netB)), _net(address(netA)), _twapOther(bytes32(uint256(3))), _twapOther(bytes32(uint256(4)))
        ];
        for (uint256 i = 0; i < sources.length; ++i) {
            (bool ok,) = _set(usdc, sources[i], standbys[i]);
            assertTrue(ok, "well-formed pair refused");
            SecondSource memory got = store.secondSource(usdc);
            assertEq(uint8(got.kind), uint8(sources[i].kind));
            assertEq(got.source, sources[i].source);
            assertEq(got.poolRef, sources[i].poolRef);
            SecondSource memory sb = store.standbySecondSource(usdc);
            assertEq(uint8(sb.kind), uint8(standbys[i].kind));
            assertEq(sb.poolRef, standbys[i].poolRef);
        }
    }

    // ─── Standby independence from the recorded source ───

    // TEST-250 verifies: REQ-PSTORE-029
    function test_TEST_250_standbySharingTheRecordedSourceIsRefused() public {
        // Same oracle-network feed.
        (bool ok, bytes memory ret) = _set(usdc, _net(address(netA)), _net(address(netA)));
        assertFalse(ok);
        assertEq(ret, oob);
        // Same pool behind two TWAP windows.
        SecondSource memory longer = _twap(bytes32(uint256(7)));
        longer.twapWindow = 3600;
        (ok, ret) = _set(usdc, _twap(bytes32(uint256(7))), longer);
        assertFalse(ok);
        assertEq(ret, oob);
        // The store compares source addresses: one reader contract serving both slots counts as shared, even for two
        // pools; another reader with another pool is independent.
        (ok, ret) = _set(usdc, _twap(bytes32(uint256(7))), _twap(bytes32(uint256(8))));
        assertFalse(ok);
        assertEq(ret, oob);
        (ok,) = _set(usdc, _twap(bytes32(uint256(7))), _twapOther(bytes32(uint256(8))));
        assertTrue(ok);
        // Another reader on the same pool still shares the pool.
        (ok, ret) = _set(usdc, _twap(bytes32(uint256(7))), _twapOther(bytes32(uint256(7))));
        assertFalse(ok);
        assertEq(ret, oob);
        // An oracle network and a pool TWAP with distinct sources are independent.
        (ok,) = _set(usdc, _net(address(netA)), _twap(bytes32(uint256(7))));
        assertTrue(ok);
    }

    // ─── Debt assets with a DebtOracle read only oracle networks ───

    // TEST-250 verifies: REQ-PSTORE-028, REQ-PSTORE-020
    function test_TEST_250_debtOracleAssetRefusesEveryTwapForm() public {
        _tl();
        store.tightenDebtStressRiseBps(usdt, 500);
        (bool ok, bytes memory ret) = _set(usdt, _twap(bytes32(uint256(1))), _none());
        assertFalse(ok);
        assertEq(ret, oob);
        (ok, ret) = _set(usdt, _net(address(netA)), _twap(bytes32(uint256(1))));
        assertFalse(ok);
        assertEq(ret, oob);
        (ok,) = _set(usdt, _net(address(netA)), _net(address(netB)));
        assertTrue(ok);
        assertEq(store.secondSource(usdt).source, address(netA));
    }

    // TEST-250 verifies: REQ-PSTORE-020, REQ-PSTORE-028
    function test_TEST_250_firstStressRiseRefusedOverAnyTwapSlot() public {
        // Recorded TWAP.
        (bool ok,) = _set(usdt, _twap(bytes32(uint256(1))), _none());
        assertTrue(ok);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.tightenDebtStressRiseBps(usdt, 500);
        // Standby TWAP behind a network source.
        (ok,) = _set(usdt, _net(address(netA)), _twap(bytes32(uint256(1))));
        assertTrue(ok);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.tightenDebtStressRiseBps(usdt, 500);
        // Both oracle networks: the first write marks the asset.
        (ok,) = _set(usdt, _net(address(netA)), _net(address(netB)));
        assertTrue(ok);
        _tl();
        store.tightenDebtStressRiseBps(usdt, 500);
        assertEq(store.debtStressRiseBps(usdt), 500);
        // A later raise runs whatever the sources, which can no longer be TWAPs.
        _tl();
        store.tightenDebtStressRiseBps(usdt, 600);
        assertEq(store.debtStressRiseBps(usdt), 600);
    }

    // ─── Guardian switch errors and events ───

    // TEST-250 verifies: REQ-PSTORE-029, EMG-103
    function test_TEST_250_switchWithoutStandbyOrTwice() public {
        vm.prank(emergencyGuardian);
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreErrors.NoStandby.selector, usdc));
        store.useStandbySecondSource(usdc);
        (bool ok,) = _set(usdc, _net(address(netA)), _none());
        assertTrue(ok);
        vm.prank(emergencyGuardian);
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreErrors.NoStandby.selector, usdc));
        store.useStandbySecondSource(usdc);
        (ok,) = _set(usdc, _net(address(netA)), _net(address(netB)));
        assertTrue(ok);
        vm.prank(emergencyGuardian);
        store.useStandbySecondSource(usdc);
        vm.prank(emergencyGuardian);
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreErrors.StandbyActive.selector, usdc));
        store.useStandbySecondSource(usdc);
        assertEq(store.secondSource(usdc).source, address(netB));
    }

    // TEST-250 verifies: REQ-PSTORE-029, EMG-103
    function test_TEST_250_switchRefusedOnceTheStandbyJoinsARoute() public {
        (bool ok,) = _set(usdc, _net(address(netA)), _net(address(netB)));
        assertTrue(ok);
        // The registry later puts the standby's feed into USDC's alternate route.
        registry.setToken(usdc, _one(address(fUsdc)), _one(address(netB)), new address[](0));
        vm.prank(emergencyGuardian);
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.useStandbySecondSource(usdc);
        assertFalse(store.onStandby(usdc));
    }

    // TEST-250 verifies: REQ-PSTORE-029
    function test_TEST_250_setSecondSourceEventsAndLeavingTheStandby() public {
        (bool ok,) = _set(usdc, _net(address(netA)), _net(address(netB)));
        assertTrue(ok);
        vm.prank(emergencyGuardian);
        store.useStandbySecondSource(usdc);
        bytes32 scope = bytes32(uint256(uint160(usdc)));
        MockAggregator netC = new MockAggregator(8, 1e6, 1e12);
        _tl();
        store.setFeed(address(netC), _feedDef(86_400, 1800));
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("secondSource", scope, uint160(address(netA)), uint160(address(netC)));
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("standbySecondSource", scope, uint160(address(netB)), 0);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.SecondSourceSwitched(usdc, false, address(timelock));
        store.setSecondSource(usdc, _net(address(netC)), _none());
        assertFalse(store.onStandby(usdc));
        assertEq(store.secondSource(usdc).source, address(netC));
        assertEq(uint8(store.standbySecondSource(usdc).kind), 0);
    }

    // TEST-250 verifies: REQ-PSTORE-029
    function test_TEST_250_restoreWhileRecordedIsANoOp() public {
        (bool ok,) = _set(usdc, _net(address(netA)), _net(address(netB)));
        assertTrue(ok);
        vm.recordLogs();
        _tl();
        store.restoreSecondSource(usdc);
        assertEq(vm.getRecordedLogs().length, 0, "restore in force emitted");
        // Also for a token with no second source at all.
        vm.recordLogs();
        _tl();
        store.restoreSecondSource(gho);
        assertEq(vm.getRecordedLogs().length, 0);
        assertFalse(store.onStandby(gho));
    }
}
