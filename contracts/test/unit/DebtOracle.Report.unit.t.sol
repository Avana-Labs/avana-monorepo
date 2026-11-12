// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {DebtOracleFixture} from "../utils/fixtures/DebtOracleFixture.sol";
import {HostileConfig} from "../utils/mocks/DebtOracleConfigMocks.sol";

/// @title DebtOracleReportUnitTest
/// @notice The informational fields of `getPriceState()` (REQ-ORACLE-093: the legs of the served route, their age
/// limits, the route values and ages, the agreement deviation, the configuration read in this evaluation) in each
/// situation that changes them: the primary served, the alternate served with its liquidation limits held to its
/// borrow limits, a disagreement, and a failed configuration read that leaves no route to report.
contract DebtOracleReportUnitTest is DebtOracleFixture {
    function setUp() public {
        _deployDebtOracle();
        vm.warp(T0 + 10);
    }

    function _view() internal view returns (DebtPriceView memory) {
        return oracle.getPriceState();
    }

    // TEST-276 verifies: REQ-ORACLE-093, SPEC-ORC-015, REQ-ORACLE-043, REQ-ORACLE-092
    // Sources: 2.10 REQ-ORACLE-093 (getPriceState reports the legs of the served route)
    /// @notice With the primary served, the report names its one leg with its timestamp and both age limits of
    /// 88,200 s, leaves the second leg slot empty, reports both route values and ages, a deviation of 0, the stored
    /// tolerance of 225 bps and route version 1.
    function test_TEST_276_primaryLegReport() public view {
        DebtPriceView memory v = _view();
        assertEq(uint8(v.routeUsed), uint8(RouteSlot.Primary));
        assertEq(v.legFeeds[0], address(pUsd));
        assertEq(v.legFeeds[1], address(0), "one-leg route");
        assertEq(v.legUpdatedAt[0], T0 - 100);
        assertEq(v.legBorrowPriceMaxAge[0], 88_200);
        assertEq(v.legLiquidationPriceMaxAge[0], 88_200);
        assertEq(v.borrowPriceMaxAge, 88_200);
        assertEq(v.liquidationPriceMaxAge, 88_200);
        assertEq(v.primaryValue, 99_990_000);
        assertEq(v.alternateValue, 99_990_000);
        assertEq(v.primaryAge, 110);
        assertEq(v.alternateAge, 110);
        assertEq(v.deviationBps, 0);
        assertEq(v.feedAgreementToleranceBps, 225);
        assertEq(v.routeVersion, 1);
        assertEq(uint8(v.replaced), uint8(RouteSlot.None));
        assertEq(v.servedAge, 110);
        assertEq(v.debtStressRiseBps, 500);
    }

    // TEST-276 verifies: REQ-ORACLE-090, REQ-ORACLE-093, SPEC-ORC-015, REQ-ORACLE-043
    // Sources: 2.10 REQ-ORACLE-090 (an alternate's legs are held to their borrow age), REQ-ORACLE-093
    /// @notice With the alternate served, the report names both of its legs in order; with USDC/ETH's borrow age set
    /// to 7,200 s (below its 88,200-second liquidation age) the reported liquidation limit of that leg is 7,200; the
    /// served limits are the tightest over the legs (ETH/USD's 5,400 s).
    function test_TEST_276_alternateLegReportHeldToBorrowAge() public {
        pUsd.push(0, block.timestamp);
        store.setBorrowAge(address(aEth), 7200);
        DebtPriceView memory v = _view();
        assertEq(uint8(v.routeUsed), uint8(RouteSlot.Alternate));
        assertEq(v.legFeeds[0], address(aEth));
        assertEq(v.legFeeds[1], address(ethUsd));
        assertEq(v.legBorrowPriceMaxAge[0], 7200);
        assertEq(v.legLiquidationPriceMaxAge[0], 7200, "min(borrow, liquidation) on the alternate");
        assertEq(v.legBorrowPriceMaxAge[1], 5400);
        assertEq(v.legLiquidationPriceMaxAge[1], 5400);
        assertEq(v.borrowPriceMaxAge, 5400, "the tightest leg");
        assertEq(v.liquidationPriceMaxAge, 5400);
        assertEq(oracle.borrowPriceMaxAge(), 5400);
        assertEq(oracle.liquidationPriceMaxAge(), 5400);
    }

    // TEST-219 verifies: REQ-ORACLE-093, SPEC-ORC-003, REQ-ORACLE-008
    // Sources: 2.10 REQ-ORACLE-093 (deviationBps = floor(|p - b| x 10^4 / min(p, b)), informational)
    /// @notice The reported deviation: routes at 99,990,000 and 102,989,700 deviate by exactly 300 bps (Drifting at the
    /// 225 bps tolerance); at 99,990,000 and 101,999,799 by 201 bps (`2,009,799 x 10^4 / 99,990,000`, exact, Live).
    function test_TEST_219_reportedDeviation() public {
        ethUsd.push(309_000_000_000, block.timestamp);
        DebtPriceView memory v = _view();
        assertEq(v.deviationBps, 300);
        assertEq(uint8(v.state), uint8(PriceState.Drifting));
        ethUsd.push(306_030_000_000, block.timestamp);
        v = _view();
        assertEq(v.alternateValue, 101_999_799);
        assertEq(v.deviationBps, 201);
        assertEq(uint8(v.state), uint8(PriceState.Live));
    }

    // TEST-219 verifies: REQ-ORACLE-093, REQ-ORACLE-017, REQ-ORACLE-069, REQ-ORACLE-092
    // Sources: 2.10 REQ-ORACLE-092 (a failed configuration read leaves no route to read)
    /// @notice When the route read fails the report has no route: both values 0, both ages `type(uint64).max`, a
    /// saturated deviation, no legs, no age limits, the accepted price served with its own timestamp; the route version
    /// read before the failure is still reported.
    function test_TEST_219_failedConfigReportsNoRoute() public {
        reg.setMode(reg.activePriceRoutes.selector, HostileConfig.Mode.Revert);
        DebtPriceView memory v = _view();
        assertEq(uint8(v.state), uint8(PriceState.Cached));
        assertEq(v.primaryValue, 0);
        assertEq(v.alternateValue, 0);
        assertEq(v.primaryAge, type(uint64).max);
        assertEq(v.alternateAge, type(uint64).max);
        assertEq(v.legFeeds[0], address(0));
        assertEq(v.borrowPriceMaxAge, 0);
        assertEq(v.deviationBps, type(uint256).max, "no route value to compare: saturated");
        assertEq(v.servedUpdatedAt, T0 - 100);
        assertEq(v.routeVersion, 1, "the version read succeeded");
        assertEq(uint8(v.routeUsed), uint8(RouteSlot.None));
    }

    // TEST-062 verifies: REQ-ORACLE-091, REQ-ORACLE-040, REQ-ORACLE-098
    // Sources: 2.10 REQ-ORACLE-091 (one DebtOracle per non-GHO debt asset, fixed wiring)
    /// @notice The fixed wiring and metadata getters: 8 decimals, the description given at `initialize`, the asset,
    /// the MarketRegistry, the ParameterStore, the timelock and the poke gas floor.
    function test_TEST_062_wiringGetters() public view {
        assertEq(oracle.decimals(), 8);
        assertEq(oracle.description(), "USDC / USD");
        assertEq(oracle.ASSET(), usdc);
        assertEq(oracle.MARKET_REGISTRY(), address(reg));
        assertEq(oracle.PARAMETER_STORE(), address(store));
        assertEq(oracle.TIMELOCK(), address(timelock));
        assertEq(oracle.pokeMinGas(), MIN_GAS);
    }
}
