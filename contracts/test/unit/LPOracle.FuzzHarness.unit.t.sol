// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "../../src/types/OracleTypes.sol";
import {LPOracleEchidnaTarget, LPOracleProperties} from "../invariant/echidna/LPOracleProperties.sol";
import {Test} from "forge-std/Test.sol";

/// @title LPOracleFuzzHarnessUnitTest
/// @notice Replays the Medusa call sequence of slow-tier run 43595414156 (commit `aa340fb`) that failed
/// `LPOracleProperties.property_servedByState()`: after a rally a Drifting market serves the lower-route price, which is
/// above the accepted price and at most the fresh price. `SPEC-ORC-017` serves the fresh price while Live or Drifting,
/// and `min(lower, fresh)` while a token disagrees; the accepted price bounds borrowing only. The property had required
/// a Drifting market to serve at most the accepted price; it now requires exactly the `SPEC-ORC-017` value.
contract LPOracleFuzzHarnessUnitTest is Test {
    function test_TEST_259_driftingAfterRallyServesAboveAccepted() public {
        LPOracleProperties h = new LPOracleProperties();
        // The harness's eleventh contract creation: CONFIG, two tokens, seven feeds, then the oracle.
        LPOracleEchidnaTarget oracle = LPOracleEchidnaTarget(vm.computeCreateAddress(address(h), 11));
        // Medusa ran every call at block 17, time 88,246; the constructor ran at time 1.
        vm.roll(17);
        vm.warp(88_246);
        h.pokeAndCheck();
        h.publish(183, 364_960_920, false);
        h.publish(90, 1_746_934_440, false);
        h.pokeAndCheck();
        h.publish(21, 2_808_400_013, false);
        h.publish(0, 164_770_541, false);

        (PriceState state, uint256 answer, uint256 accepted, uint256 fresh, uint256 lower, bool disagreeing) =
            oracle.served();
        assertEq(uint8(state), uint8(PriceState.Drifting), "Drifting");
        assertTrue(disagreeing, "token A's routes disagree");
        assertEq(answer, 191_999_808, "lower-route price");
        assertEq(answer, lower < fresh ? lower : fresh, "min(lower, fresh)");
        assertEq(accepted, 182_999_817, "accepted at the second poke");
        assertGt(answer, accepted, "served above the accepted price");

        assertTrue(h.property_servedByState(), "servedByState");
        assertTrue(h.property_latestAnswerAtLeastOne(), "latestAnswerAtLeastOne");
        assertTrue(h.property_acceptedTimestampNeverDecreases(), "acceptedTimestampNeverDecreases");
    }

    /// @dev The sequence of slow-tier run 43653574421 (commit `48864ef`), which failed the same property at time 17.
    function test_TEST_259_driftingAfterRallySecondSequence() public {
        LPOracleProperties h = new LPOracleProperties();
        vm.roll(17);
        vm.warp(17);
        h.publish(0, 247_822_469, false);
        h.pokeAndCheck();
        h.publish(25, 1_474_140_149, false);
        LPOracleEchidnaTarget oracle = LPOracleEchidnaTarget(vm.computeCreateAddress(address(h), 11));
        (PriceState state, uint256 answer, uint256 accepted, uint256 fresh, uint256 lower, bool disagreeing) =
            oracle.served();
        // Medusa's trace: token A's primary at 1.12 disagrees with its alternate at 1.00; under the $1 stable ceiling
        // the lower and the fresh price are both 199,999,800, served above the accepted 198,999,801.
        assertEq(uint8(state), uint8(PriceState.Drifting), "Drifting");
        assertTrue(disagreeing, "token A's routes disagree");
        assertEq(answer, 199_999_800, "min(lower, fresh)");
        assertEq(answer, lower < fresh ? lower : fresh, "min(lower, fresh)");
        assertEq(accepted, 198_999_801, "accepted");
        assertTrue(h.property_servedByState(), "servedByState");
        assertTrue(h.property_latestAnswerAtLeastOne(), "latestAnswerAtLeastOne");
    }
}
