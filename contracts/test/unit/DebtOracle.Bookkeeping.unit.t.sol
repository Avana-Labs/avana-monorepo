// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IDebtOracleEvents} from "../../src/oracle/debt-oracle/IDebtOracleEvents.sol";
import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState, RouteSlot} from "../../src/types/OracleTypes.sol";
import {DebtOracleFixture} from "../utils/fixtures/DebtOracleFixture.sol";
import {HostileConfig} from "../utils/mocks/DebtOracleConfigMocks.sol";
import {MockAggregator} from "../utils/mocks/MockAggregator.sol";

/// @title DebtOracleBookkeepingUnitTest
/// @notice State a DebtOracle poke writes for later reads (REQ-ORACLE-029, REQ-ORACLE-032, REQ-ORACLE-092,
/// REQ-ORACLE-093): a Live quote older than the accepted one is not accepted; a raised `cachedWindow` or
/// `debtStressRiseBps` is kept for a later failed read; a `cachedWindow` above 16 bits is read in full; a latched
/// outage that recovers on the alternate starts grace at the newest leg of that route; and a primary leg's reported
/// liquidation age is its own even when its borrow age is lower.
contract DebtOracleBookkeepingUnitTest is DebtOracleFixture {
    function setUp() public {
        _deployDebtOracle();
    }

    // TEST-219 verifies: REQ-ORACLE-029, REQ-ORACLE-005, REQ-ORACLE-092
    // Sources: 2.10 REQ-ORACLE-029 (a Live quote is accepted only when its source timestamp is newer)
    /// @notice The primary is accepted at `T0 + 100`. When the primary then fails and the alternate (value 99,900,000,
    /// source timestamp `T0 - 100`) is quoted Live, its quote is older than the accepted one and is not accepted: the
    /// accepted price stays 99,990,000 at `T0 + 100`.
    function test_TEST_219_olderLiveQuoteIsNotAccepted() public {
        vm.warp(T0 + 100);
        pUsd.push(USDC_USD, T0 + 100);
        _poke();
        (uint256 price, uint64 at) = oracle.lastAcceptedPrice();
        assertEq(price, uint256(USDC_USD));
        assertEq(at, T0 + 100, "control: the primary is accepted");
        aEth.push(333_000_000_000_000, T0 + 50);
        pUsd.setMode(MockAggregator.latestRoundData.selector, MockAggregator.Mode.Revert);
        vm.warp(T0 + 200);
        assertEq(uint8(_poke()), uint8(PriceState.Live), "Live on the alternate");
        assertEq(uint8(oracle.getPriceState().routeUsed), uint8(RouteSlot.Alternate));
        (price, at) = oracle.lastAcceptedPrice();
        assertEq(price, uint256(USDC_USD), "older quote not accepted");
        assertEq(at, T0 + 100);
    }

    // TEST-219 verifies: REQ-ORACLE-092, REQ-ORACLE-017, SPEC-ORC-013
    // Sources: 2.10 REQ-ORACLE-092 (a failed cachedWindow read uses the value the last writing call read)
    /// @notice A poke reads `cachedWindow` raised from 3,600 to 7,200 s. When the read then fails, the market is failed
    /// with `cachedUntil = failureStart + 7,200`, the raised value, and stays Cached 3,600 s later.
    function test_TEST_219_raisedCachedWindowIsKeptForAFailedRead() public {
        store.setTimers(7200, 3600, 1800);
        _poke();
        store.setMode(store.cachedWindow.selector, HostileConfig.Mode.Revert);
        DebtPriceView memory v = oracle.getPriceState();
        assertEq(uint8(v.state), uint8(PriceState.Cached));
        assertEq(v.failureStart, block.timestamp);
        assertEq(v.cachedUntil, block.timestamp + 7200, "the raised window");
    }

    // TEST-219 verifies: REQ-ORACLE-092, SPEC-ORC-018
    // Sources: 2.10 REQ-ORACLE-092 (a failed debtStressRiseBps read uses the value the last writing call read)
    /// @notice A poke reads `debtStressRiseBps` raised from 500 to 800. When the read then fails, the report carries 800.
    function test_TEST_219_raisedStressRiseIsKeptForAFailedRead() public {
        store.setStressRise(usdc, 800);
        _poke();
        store.setMode(store.debtStressRiseBps.selector, HostileConfig.Mode.Revert);
        assertEq(oracle.getPriceState().debtStressRiseBps, 800, "the raised stress rise");
    }

    // TEST-219 verifies: REQ-ORACLE-092, SPEC-ORC-013
    // Sources: 2.10 SPEC-ORC-013 (Cached until failureStart + cachedWindow; cachedWindow is a 32-bit value)
    /// @notice A `cachedWindow` of 70,000 s (above 16 bits) is read as it is: with both routes failing, the market is
    /// Cached until `failureStart + 70,000` and still Cached 3,600 s later.
    function test_TEST_219_cachedWindowAbove16Bits() public {
        store.setTimers(70_000, 3600, 1800);
        pUsd.setMode(MockAggregator.latestRoundData.selector, MockAggregator.Mode.Revert);
        aEth.setMode(MockAggregator.latestRoundData.selector, MockAggregator.Mode.Revert);
        DebtPriceView memory v = oracle.getPriceState();
        assertEq(uint8(v.state), uint8(PriceState.Cached));
        assertEq(v.cachedUntil, v.failureStart + 70_000);
        vm.warp(block.timestamp + 3600);
        assertEq(uint8(_state()), uint8(PriceState.Cached), "still Cached after 3,600 s");
    }

    // TEST-219 verifies: REQ-ORACLE-032, REQ-ORACLE-030, REQ-ORACLE-005
    // Sources: 2.10 REQ-ORACLE-032 (c) (without evidence, grace starts at the newest leg of the route in use)
    /// @notice Both routes are stale from `T0 + 88,101`; a poke at `T0 + 91,711` latches. The primary then fails by
    /// Error (so there is no recovery evidence) and the alternate recovers with USDC/ETH at `T0 + 91,800` and ETH/USD at
    /// `T0 + 91,750`: the poke at `T0 + 91,900` starts grace from the latch at `T0 + 91,800`, the newest leg of the
    /// alternate, the route in use.
    function test_TEST_219_latchGraceFromTheAlternatesNewestLeg() public {
        vm.warp(T0 + 91_711);
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtOutageExpiredLatched(uint64(T0 + 88_101), uint64(T0 + 91_711));
        _poke();
        pUsd.setMode(MockAggregator.latestRoundData.selector, MockAggregator.Mode.Revert);
        aEth.push(USDC_ETH, T0 + 91_800);
        ethUsd.push(ETH_USD, T0 + 91_750);
        vm.warp(T0 + 91_900);
        vm.expectEmit(address(oracle));
        emit IDebtOracleEvents.DebtGraceStarted(uint64(T0 + 91_800), uint64(T0 + 91_800 + 1800), true);
        _poke();
        assertEq(uint8(oracle.getPriceState().routeUsed), uint8(RouteSlot.Alternate));
    }

    // TEST-276 verifies: REQ-ORACLE-093, REQ-ORACLE-090, SPEC-ORC-015
    // Sources: 2.10 REQ-ORACLE-090 (only an alternate's legs are held to their borrow age), REQ-ORACLE-093
    /// @notice With the primary served and its borrow age set to 7,200 s (below its 88,200-second liquidation age), the
    /// report keeps the primary leg's liquidation limit at 88,200 s and its borrow limit at 7,200 s.
    function test_TEST_276_primaryLegKeepsItsLiquidationAge() public {
        store.setBorrowAge(address(pUsd), 7200);
        DebtPriceView memory v = oracle.getPriceState();
        assertEq(uint8(v.routeUsed), uint8(RouteSlot.Primary));
        assertEq(v.legBorrowPriceMaxAge[0], 7200);
        assertEq(v.legLiquidationPriceMaxAge[0], 88_200, "not held to the borrow age on the primary");
    }
}
