// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracleEvents} from "../../src/oracle/lp-oracle/ILPOracleEvents.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";
import {OracleFeedMock, ReadMode} from "../utils/mocks/LPOracleMocks.sol";

/// @notice Route disagreement: the stored first observation, the pause and its expiry, the lower-route price and the
/// route-version restart of the LPOracle base (2.10).
/// forge-config: default.isolate = false
contract LPOracleDisagreementUnitTest is LPOracleFixture {
    uint256 internal constant T1 = T0 + 600;

    function setUp() public {
        _deployMarket();
        vm.warp(T1);
        _pushAll(int256(ONE), T1);
        // Token B's alternate reads 97.5 cents against 1.00 on its primary: 250 bps > 150 bps.
        aB.push(97_500_000, T1);
    }

    // TEST-159 verifies: REQ-ORACLE-028, REQ-ORACLE-036, INV-059, Q-162, Q-183, Q-199
    // Sources: 5.1 TEST-159
    function test_TEST_159_firstObservationStored() public {
        PriceStateView memory v = _state();
        assertEq(v.disagreeSince, 0, "no poke has seen it yet");
        assertTrue(v.disagreementPauseActive, "a view measures the pause from now");
        uint256[] memory primary = new uint256[](2);
        uint256[] memory alternate = new uint256[](2);
        (primary[0], primary[1], alternate[0], alternate[1]) = (ONE, ONE, ONE, 97_500_000);
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.DisagreementRecorded(uint64(T1), primary, alternate);
        oracle.poke();
        (, uint64 since,,) = oracle.storedTimers();
        assertEq(since, T1);
    }

    // TEST-159 verifies: REQ-ORACLE-028, INV-059, Q-199
    function test_TEST_159_laterObservationsKeepTime() public {
        oracle.poke();
        vm.warp(T1 + 900);
        oracle.poke();
        (, uint64 since,,) = oracle.storedTimers();
        assertEq(since, T1, "a later poke never moves the stored start");
    }

    // TEST-159 verifies: REQ-ORACLE-023, REQ-ORACLE-028, INV-059, Q-183
    function test_TEST_159_agreementClears() public {
        oracle.poke();
        vm.warp(T1 + 120);
        aB.push(int256(ONE), T1 + 120);
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.DisagreementCleared(uint64(T1), uint64(T1 + 120));
        assertEq(uint8(oracle.poke()), uint8(PriceState.Live));
        (, uint64 since,,) = oracle.storedTimers();
        assertEq(since, 0);
    }

    // TEST-159 verifies: REQ-ORACLE-022, SPEC-ORC-016, Q-162
    function test_TEST_159_pauseEndsWithoutCalls() public {
        oracle.poke();
        vm.warp(T1 + 3599);
        assertTrue(_state().disagreementPauseActive);
        vm.warp(T1 + 3600);
        PriceStateView memory v = _state();
        assertFalse(v.disagreementPauseActive, "the pause ends at disagreeSince + disagreementPauseMax");
        assertTrue(v.disagreementExpired);
        assertTrue(v.liquidationPaused, "seizure stays blocked while the routes disagree");
        assertTrue(_has(v.reasons, 11), "DISAGREEMENT_EXPIRED");
    }

    // TEST-159 verifies: REQ-ORACLE-024, INV-059, ATTACK-042, Q-199
    function test_TEST_159_gasStarvedPokeStoresNothing() public {
        (bool ok,) = address(oracle).call{gas: POKE_FLOOR - 1}(abi.encodeCall(oracle.poke, ()));
        assertFalse(ok);
        (, uint64 since,,) = oracle.storedTimers();
        assertEq(since, 0);
    }

    // TEST-044 verifies: REQ-ORACLE-022, REQ-ORACLE-070, REQ-ORACLE-086, SPEC-ORC-016, SPEC-ORC-017, INV-059, INV-087, ATTACK-053, Q-162, Q-208, Q-247
    // Sources: 5.1 TEST-044, QNT-22, HYP-56, SIM-01E
    function test_TEST_044_pauseFromFirstObservation() public {
        oracle.poke();
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Drifting));
        assertTrue(v.disagreementPauseActive);
        assertTrue(v.liquidationPaused);
        assertTrue(_has(v.reasons, 9), "DISAGREEMENT_PAUSE");
        assertFalse(v.borrowAllowed, "borrowing blocked while Drifting");
        // Served at the lower routes: token B at 97.5 cents, never above fresh or accepted.
        uint256 lower = 99_999_900 + 97_499_902;
        assertEq(v.answer, int256(lower));
        assertLe(uint256(v.answer), uint256(v.freshAnswer));
        assertLe(uint256(v.answer), uint256(v.acceptedAnswer));
        assertEq(v.tokens[1].legFeeds[0], address(aB), "the lower route's legs serve");
    }

    // TEST-157 verifies: REQ-ORACLE-084, REQ-ORACLE-022, SPEC-ORC-016, INV-059, ATTACK-111, Q-199, Q-208, Q-248
    // Sources: 5.1 TEST-157
    function test_TEST_157_pauseThenExpiredForLiquidation() public {
        oracle.poke();
        vm.warp(T1 + 3600);
        oracle.poke();
        PriceStateView memory v = _state();
        assertTrue(v.disagreementExpired);
        assertTrue(v.liquidationPaused);
        assertEq(uint8(v.state), uint8(PriceState.Drifting), "still Drifting, not Cached");
        // Agreement resumes: the next poke clears and liquidation is no longer paused.
        aB.push(int256(ONE), T1 + 3600);
        oracle.poke();
        v = _state();
        assertFalse(v.liquidationPaused);
        assertFalse(v.disagreementExpired);
    }

    // TEST-157 verifies: REQ-ORACLE-100, REQ-ORACLE-084, Q-208
    function test_TEST_157_borrowBlocked() public {
        oracle.poke();
        vm.warp(T1 + 3600);
        assertFalse(_state().borrowAllowed);
    }

    // TEST-231 verifies: REQ-ORACLE-094, REQ-ORACLE-095, REQ-ORACLE-084, MKT-022, ATTACK-140, Q-248
    // Sources: 5.1 TEST-231
    function test_TEST_231_standbySwitchRestartsDisagreementKeepsFailure() public {
        oracle.poke();
        vm.warp(T1 + 1000);
        // The guardian switches token B's alternate slot to a standby that also disagrees: the window restarts.
        OracleFeedMock standby = _feed("standby");
        standby.push(97_000_000, T1 + 1000);
        registry.setRoutes(address(tokenB), _one(address(pB)), _one(address(standby)), RouteSlot.Alternate);
        registry.bumpVersion(address(tokenB));
        PriceStateView memory v = _state();
        assertEq(v.disagreeSince, 0, "a view after a version change measures from now");
        assertTrue(_has(v.reasons, 13), "ANY_TOKEN_ON_STANDBY");
        assertEq(uint8(v.tokens[1].replaced), uint8(RouteSlot.Alternate));
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.PriceRouteVersionObserved(1, 0, 1);
        oracle.poke();
        (, uint64 since,,) = oracle.storedTimers();
        assertEq(since, T1 + 1000, "disagreeSince restarts at the observing poke");
        // A switch to an agreeing standby makes the market Live at once.
        standby.push(int256(ONE), T1 + 1000);
        assertEq(uint8(_state().state), uint8(PriceState.Live));
    }

    // TEST-231 verifies: REQ-ORACLE-095, SPEC-ORC-013, Q-248
    function test_TEST_231_switchNeverDelaysCachedOrExpired() public {
        aB.push(int256(ONE), T1);
        pB.setMode(pB.latestRoundData.selector, ReadMode.Revert);
        aB.setMode(aB.latestRoundData.selector, ReadMode.Revert);
        oracle.poke();
        (uint64 failedSince,,,) = oracle.storedTimers();
        assertEq(failedSince, T1);
        // A switch to a standby that also fails keeps the failure timer.
        OracleFeedMock standby = _feed("standby");
        standby.setMode(standby.latestRoundData.selector, ReadMode.Revert);
        registry.setRoutes(address(tokenB), _one(address(standby)), _one(address(aB)), RouteSlot.Primary);
        registry.bumpVersion(address(tokenB));
        vm.warp(T1 + 2000);
        oracle.poke();
        (failedSince,,,) = oracle.storedTimers();
        assertEq(failedSince, T1, "a version change never resets failedSince");
        vm.warp(T1 + 3600);
        assertEq(uint8(_state().state), uint8(PriceState.Expired), "Expired on the original schedule");
    }
}
