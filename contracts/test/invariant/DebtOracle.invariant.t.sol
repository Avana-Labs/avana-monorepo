// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {DebtOracleFixture} from "../utils/fixtures/DebtOracleFixture.sol";
import {MockAggregator} from "../utils/mocks/MockAggregator.sol";
import {DebtOracleHandler} from "./handlers/DebtOracleHandler.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";

/// @title DebtOracleInvariantTest
/// @notice `TEST-105` for the DebtOracle: after every handler call (feed moves, bounds, odd timestamps, hostile reads,
/// time, standby switches and restores, pokes) `latestAnswer()` returns at least 1 without reverting, a DebtOracle that
/// is not Live serves at least its accepted price, the accepted source timestamp never moves backwards and is always a
/// timestamp some feed published, and `poke()` with enough gas never reverts.
contract DebtOracleInvariantTest is DebtOracleFixture, HandlerReach {
    DebtOracleHandler internal handler;

    function setUp() public {
        _deployDebtOracle();
        MockAggregator[4] memory feeds = [pUsd, aEth, ethUsd, standby];
        int256[4] memory honest = [USDC_USD, USDC_ETH, ETH_USD, int256(99_995_000)];
        handler = new DebtOracleHandler(oracle, reg, usdc, feeds, honest);
        targetContract(address(handler));
    }

    // TEST-082 verifies: TEST-007
    /// @notice What the handler does: over 32 fixed-seed runs of 50 calls from set-up, counts per action the calls that
    /// changed the state of a contract other than the handler and this test, the skipped and failed calls and the
    /// calls that returned without changing anything; each action must change the state in at least its floor of
    /// calls (`forge test -vv` prints the table).
    function test_TEST_082_handlerReach() public {
        (bytes4[] memory actions, string[] memory names,) = _reachActions();
        address[] memory own = new address[](2);
        (own[0], own[1]) = (address(handler), address(this));
        Reach memory r = _replayLanded(address(handler), actions, bytes4(0), 32, 50, 0, own, true);
        _check(r, names, new string[](0), _floors(6, 0), new uint256[](0));
    }

    function _reached() internal pure override returns (bool[] memory hit) {
        hit = new bool[](0);
    }

    /// @dev The targeted actions, their names and the type of each of their parameters (see `_typed`).
    function _reachActions() internal pure returns (bytes4[] memory actions, string[] memory names, int16[][] memory kinds) {
        (actions, names, kinds) = (new bytes4[](6), new string[](6), new int16[][](6));
        (actions[0], names[0]) = (DebtOracleHandler.breakFeed.selector, "breakFeed");
        kinds[0] = new int16[](2);
        kinds[0][0] = 256;
        kinds[0][1] = 256;
        (actions[1], names[1]) = (DebtOracleHandler.move.selector, "move");
        kinds[1] = new int16[](3);
        kinds[1][0] = 256;
        kinds[1][1] = 256;
        kinds[1][2] = 256;
        (actions[2], names[2]) = (DebtOracleHandler.oddTimestamp.selector, "oddTimestamp");
        kinds[2] = new int16[](2);
        kinds[2][0] = 256;
        kinds[2][1] = 256;
        (actions[3], names[3]) = (DebtOracleHandler.poke.selector, "poke");
        kinds[3] = new int16[](0);
        (actions[4], names[4]) = (DebtOracleHandler.switchStandby.selector, "switchStandby");
        kinds[4] = new int16[](1);
        kinds[4][0] = 1;
        (actions[5], names[5]) = (DebtOracleHandler.warp.selector, "warp");
        kinds[5] = new int16[](1);
        kinds[5][0] = 256;
    }

    function _calldata(bytes4 selector, uint256 seed) internal pure override returns (bytes memory) {
        (bytes4[] memory actions,, int16[][] memory kinds) = _reachActions();
        for (uint256 k = 0; k < actions.length; ++k) {
            if (actions[k] == selector) return _typed(selector, kinds[k], seed);
        }
        return abi.encodePacked(selector);
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
