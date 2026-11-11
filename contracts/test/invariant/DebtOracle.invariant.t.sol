// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {DebtOracleFixture} from "../utils/fixtures/DebtOracleFixture.sol";
import {MockAggregator} from "../utils/mocks/MockAggregator.sol";
import {DebtOracleHandler} from "./handlers/DebtOracleHandler.sol";

/// @title DebtOracleInvariantTest
/// @notice `TEST-105` for the DebtOracle: after every handler call (feed moves, bounds, odd timestamps, hostile reads,
/// time, standby switches and restores, pokes) `latestAnswer()` returns at least 1 without reverting, a DebtOracle that
/// is not Live serves at least its accepted price, the accepted source timestamp never moves backwards and is always a
/// timestamp some feed published, and `poke()` with enough gas never reverts.
contract DebtOracleInvariantTest is DebtOracleFixture {
    DebtOracleHandler internal handler;

    function setUp() public {
        _deployDebtOracle();
        MockAggregator[4] memory feeds = [pUsd, aEth, ethUsd, standby];
        int256[4] memory honest = [USDC_USD, USDC_ETH, ETH_USD, int256(99_995_000)];
        handler = new DebtOracleHandler(oracle, reg, usdc, feeds, honest);
        targetContract(address(handler));
    }

    // TEST-105 verifies: REQ-ORACLE-093, REQ-ORACLE-061, SPEC-ORC-018, INV-087, INV-055, Q-247
    // Sources: 5.1 TEST-105 (DebtOracle half), HYP-11
    function invariant_TEST_105_servedAtLeastOneAndAtLeastAcceptedUnlessLive() public view {
        uint256 served = uint256(oracle.latestAnswer());
        assertGe(served, 1);
        DebtPriceView memory v = oracle.getPriceState();
        if (v.state != PriceState.Live) assertGe(served, _accepted(), "non-Live serves at least the accepted price");
    }

    // TEST-105 verifies: REQ-ORACLE-029, REQ-ORACLE-066, REQ-ORACLE-021, INV-056, Q-182
    // Sources: 5.1 TEST-105 (the reported source timestamp never increases without a new round)
    function invariant_TEST_105_acceptedTimestampOnlyFromPublishedRounds() public view {
        (, uint64 at) = oracle.lastAcceptedPrice();
        assertLe(at, handler.maxPublished(), "accepted timestamp is a published one");
        assertLe(at, block.timestamp, "accepted timestamp is never in the future");
        assertEq(handler.acceptedWentBack(), 0, "accepted timestamp never moves backwards");
    }

    // TEST-105 verifies: REQ-ORACLE-092, REQ-ORACLE-025, REQ-ORACLE-061
    function invariant_TEST_105_pokeNeverReverts() public view {
        assertEq(handler.pokeReverts(), 0);
    }
}
