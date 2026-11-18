// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "../../src/types/OracleTypes.sol";
import {DebtOracleFixture} from "../utils/fixtures/DebtOracleFixture.sol";
import {HostileConfig} from "../utils/mocks/DebtOracleConfigMocks.sol";
import {MockAggregator} from "../utils/mocks/MockAggregator.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title DebtOracleSeenRecordsUnitTest
/// @notice The leg records of REQ-ORACLE-031 across a poke whose configuration read fails after the route feeds were
/// read (a feed definition cannot be read): no leg is read, so every record is kept, and recovery evidence
/// (SPEC-ORC-014) later counts from the records written before that poke.
/// @dev Every feed published at `T0 - 100` and was recorded at `initialize`. The primary USDC/USD and ETH/USD are
/// hourly here (`feedMaxAge = 5,400`); `cachedWindow = 3,600`.
contract DebtOracleSeenRecordsUnitTest is DebtOracleFixture {
    bytes32 internal constant GRACE = keccak256("DebtGraceStarted(uint64,uint64,bool)");

    function setUp() public {
        _deployDebtOracle();
        store.setFeed(address(pUsd), 8, 0, 1e12, 3600, 1800);
    }

    /// @dev Pokes once and returns the number of grace windows it opened and the last recovery time.
    function _graces() internal returns (uint256 n, uint64 recoveredAt) {
        vm.recordLogs();
        _poke();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == GRACE) {
                ++n;
                (recoveredAt,,) = abi.decode(logs[i].data, (uint64, uint64, bool));
            }
        }
    }

    /// @dev A poke at `T0 + 1,000` whose `getFeed` reads revert: the routes are read from the registry, the feed
    /// definitions are not, and the market is failed with the configuration unavailable.
    function _pokeWithUnreadableFeedDefinitions() internal {
        vm.warp(T0 + 1000);
        store.setMode(store.getFeed.selector, HostileConfig.Mode.Revert);
        assertEq(uint8(_poke()), uint8(PriceState.Cached), "configuration unavailable");
        store.setMode(store.getFeed.selector, HostileConfig.Mode.Normal);
    }

    // TEST-219 verifies: REQ-ORACLE-031, SPEC-ORC-014, REQ-ORACLE-089, REQ-ORACLE-092
    /// @notice After a poke whose feed definitions could not be read, the primary and ETH/USD publish the first round of
    /// a new phase at `T0 + 20,000`, with no readable previous phase, so each gap starts from its record. The records
    /// still hold `T0 - 100`, so the gaps are `[T0 + 5,301, T0 + 20,000)` and grace opens at `T0 + 20,000`; records
    /// overwritten with time 0 would make both lookups unusable.
    function test_TEST_219_unreadableFeedDefinitionKeepsTheRecordTimes() public {
        _pokeWithUnreadableFeedDefinitions();
        vm.warp(T0 + 20_000);
        pUsd.pushNewPhase(USDC_USD, T0 + 20_000, address(0));
        ethUsd.pushNewPhase(ETH_USD, T0 + 20_000, address(0));
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 1, "gaps from the kept records");
        assertEq(rec, T0 + 20_000);
    }

    // TEST-219 verifies: REQ-ORACLE-031, SPEC-ORC-014, REQ-ORACLE-092
    /// @notice After a poke whose feed definitions could not be read, a leg whose round did not change has no gap. A
    /// poke at `T0 + 10` records round 2 of every leg; after the failed poke the primary and ETH/USD only rewrite round 2's
    /// time to `T0 + 20,000`, so no grace opens. Records overwritten with round 0 and time 0 would count round 2 as new,
    /// with the gap `[T0 + 5,301, T0 + 20,000)` from round 1, and open grace.
    function test_TEST_219_unreadableFeedDefinitionKeepsTheRecordRounds() public {
        vm.warp(T0 + 10);
        pUsd.push(USDC_USD, T0 + 10);
        aEth.push(USDC_ETH, T0 + 10);
        ethUsd.push(ETH_USD, T0 + 10);
        _poke();
        _pokeWithUnreadableFeedDefinitions();
        vm.warp(T0 + 20_000);
        pUsd.setCurrent(USDC_USD, T0 + 20_000);
        ethUsd.setCurrent(ETH_USD, T0 + 20_000);
        (uint256 n, uint64 rec) = _graces();
        assertEq(n, 0, "same rounds: no gap");
        assertEq(rec, 0);
    }
}
