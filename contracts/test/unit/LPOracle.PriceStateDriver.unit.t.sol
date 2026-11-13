// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";
import {ReadMode} from "../utils/mocks/LPOracleMocks.sol";

/// @title LPOraclePriceStateDriverUnitTest
/// @notice The collateral half of the TEST-006 price-state driver on the local LPOracle: every state is produced
/// through the per-token aggregator stand-ins alone (stale answers, failing reads, one route moved), except Drifting
/// from the pool side, which the pricing module's consistency check produces here and moving the pool across
/// `twapWindow` produces on a fork. Nothing else in the market is touched, so a suite using this driver moves only the
/// collateral side. The fork half (the same driver on the Avana-deployed Aave V4, with the non-GHO debt feed moved
/// separately) belongs to the fork suites and is not run here.
/// forge-config: default.isolate = false
contract LPOraclePriceStateDriverUnitTest is LPOracleFixture {
    uint256 internal constant T1 = T0 + 60;

    function setUp() public {
        _deployMarket();
        vm.warp(T1);
        vm.roll(block.number + 1);
        _pushAll(int256(ONE), T1);
    }

    // TEST-006 verifies: REQ-ORACLE-016, REQ-ORACLE-017, REQ-ORACLE-018, Q-119, Q-128
    // Sources: 5.1 TEST-006 (Drifting by the pool, Cached and Expired by stale or failing aggregator stand-ins)
    /// @notice Live, then Drifting (consistency check failing), Live again, then Cached (both routes of one token
    /// failing), then Expired once the failure outlasts `cachedWindow`; the served price follows each state.
    function test_TEST_006_drivesEachPriceState() public {
        _assertState(PriceState.Live);
        oracle.poke();
        (uint256 accepted,) = oracle.lastAcceptedPrice();
        // Drifting from the pool side.
        oracle.setConsistency(false, true, 80, false);
        _assertState(PriceState.Drifting);
        oracle.setConsistency(false, false, 0, false);
        _assertState(PriceState.Live);
        // Cached: both routes of token B fail.
        pB.setMode(pB.latestRoundData.selector, ReadMode.Revert);
        aB.setMode(aB.latestRoundData.selector, ReadMode.Revert);
        _assertState(PriceState.Cached);
        assertEq(uint256(oracle.latestAnswer()), accepted, "Cached serves the accepted price");
        oracle.poke();
        // Expired: the failure outlasts cachedWindow (3,600 s) while token A stays fresh.
        vm.warp(T1 + 3600);
        pA.push(int256(ONE), T1 + 3600);
        aA.push(int256(ONE), T1 + 3600);
        _assertState(PriceState.Expired);
        assertEq(oracle.latestAnswer(), 1, "Expired serves 1");
    }

    // TEST-006 verifies: REQ-ORACLE-008, REQ-ORACLE-017, Q-119, Q-128
    // Sources: 5.1 TEST-006 (disagreement by moving one route; Cached by a stale aggregator)
    /// @notice Moving one route of token A 2.5 % away makes the market Drifting with the disagreement reason; a
    /// stale (not failing) pair of routes of token B makes it Cached.
    function test_TEST_006_routeDisagreementAndStaleness() public {
        aA.push(97_500_000, T1);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Drifting), "one route moved");
        assertTrue(_has(v.reasons, 2), "ANY_TOKEN_DISAGREE");
        aA.push(int256(ONE), T1);
        _assertState(PriceState.Live);
        // Token B's answers age past feedMaxAge while token A keeps publishing.
        uint256 later = T1 + MAX_AGE + 1;
        vm.warp(later);
        pA.push(int256(ONE), later);
        aA.push(int256(ONE), later);
        sA.push(int256(ONE), later);
        _assertState(PriceState.Cached);
    }
}
