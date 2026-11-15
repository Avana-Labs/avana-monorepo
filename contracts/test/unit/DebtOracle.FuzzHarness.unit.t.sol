// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IDebtOracle} from "../../src/oracle/debt-oracle/IDebtOracle.sol";
import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {DebtOracleProperties} from "../invariant/echidna/DebtOracleProperties.sol";
import {Test} from "forge-std/Test.sol";

/// @title DebtOracleFuzzHarnessUnitTest
/// @notice Replays the Medusa call sequence of slow-tier run 43653574421 (commit `48864ef`) that failed
/// `DebtOracleProperties.property_nonLiveServesAtLeastAccepted()`: the primary feed rises 50 %, the routes disagree
/// and the DebtOracle is Drifting. `SPEC-ORC-018` serves `max(min(p, b), A)` while Drifting, here the alternate route
/// (equal to the accepted price); the property still expected `max(p, b, A)`, the rule before that change. It now
/// expects `max(min(p, b), A)`.
contract DebtOracleFuzzHarnessUnitTest is Test {
    DebtOracleProperties internal h;
    IDebtOracle internal oracle;

    function setUp() public {
        h = new DebtOracleProperties();
        // The harness's eighth contract creation: four feeds, the registry, the store, the implementation, the proxy.
        oracle = IDebtOracle(vm.computeCreateAddress(address(h), 8));
    }

    function test_TEST_259_driftingServesTheLowerRouteOrAccepted() public {
        // Medusa ran the call at block 13, time 13; the constructor ran at time 1.
        vm.roll(13);
        vm.warp(13);
        h.move(0, 64);

        DebtPriceView memory v = oracle.getPriceState();
        assertEq(uint8(v.state), uint8(PriceState.Drifting), "Drifting");
        assertEq(v.primaryValue, 149_985_000, "primary 50 % up");
        assertEq(v.alternateValue, 99_990_000, "alternate unchanged");
        assertEq(v.acceptedAnswer, 99_990_000, "accepted");
        assertEq(v.answer, 99_990_000, "max(min(p, b), A)");
        assertTrue(h.property_nonLiveServesAtLeastAccepted(), "nonLiveServesAtLeastAccepted");
        assertTrue(h.property_servedAtLeastOneAndNeverReverts(), "servedAtLeastOneAndNeverReverts");
    }
}
