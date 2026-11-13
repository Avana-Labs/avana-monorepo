// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {IGasAaveOracle, LPOracleGasFixture} from "../utils/fixtures/LPOracleGasFixture.sol";

/// @notice Measures of the LPOracle price-read path inside the Aave V4 flows that read it: the single reads
/// (`latestAnswer`, `latestRoundData`, `getPriceState`, `getTokenPrices`, `poke`, `AaveOracle.getReservePrice`) and
/// `borrow`, `withdraw` and `liquidationCall` on the CDP Spoke at its reserve limit, in each price scenario.
abstract contract LPOracleAaveFlowsGasBase is LPOracleGasFixture {
    // Budgets: the worst scenario measured on the optimized path with the concentrated-liquidity implementation on a real
    // Uniswap v3 pool, rounded up to the next 5,000 gas (Josue's rule: acceptance is the full worst-case Aave flow; no
    // price is cached and no freshness, deviation or rounding check is weakened for gas). Cold: every account and slot
    // cold, as the first price read of a transaction. Warm: the same call repeated in one transaction, as the second and
    // later reads of a liquidation are. Against the base's measurement with a price-independent test module, each
    // evaluation adds the pricing module's real work: one delegatecall into the module contract per hook, one `slot0`
    // read (lock and cardinality), one `observe([1800, 0])` binary search over 151 observations, two to three
    // square roots and one `tickAtSqrtRatio` (warm `latestAnswer` 173,611 Live / 175,141 Alternate, where 155,000 was
    // the budget before; cold 416,111 / 417,641 against 400,000).
    // The per-market USD band (REQ-ORACLE-056) adds one storage read to every evaluation: one cold read (2,100 gas) on
    // the cold read and cold `getPriceState` budgets (worst 420,310 and 540,443, Alternate) and one warm read (100 gas)
    // on the warm `getPriceState` budget (worst 240,046, Alternate).
    uint256 internal constant COLD_READ = 422_100;
    uint256 internal constant COLD_RESERVE_PRICE = 430_000;
    uint256 internal constant COLD_PRICE_STATE = 542_100;
    uint256 internal constant COLD_POKE = 600_000;
    uint256 internal constant COLD_BORROW = 710_000;
    uint256 internal constant COLD_WITHDRAW = 715_000;
    uint256 internal constant COLD_LIQUIDATION = 1_225_000;
    uint256 internal constant WARM_READ = 180_000;
    uint256 internal constant WARM_PRICE_STATE = 240_100;
    uint256 internal constant WARM_POKE = 235_000;
    uint256 internal constant WARM_BORROW = 250_000;
    uint256 internal constant WARM_WITHDRAW = 255_000;
    uint256 internal constant WARM_LIQUIDATION = 710_000;

    function setUp() public {
        _setUpGas(false, FLOOR);
    }

    function _name(
        Scenario s
    ) internal pure returns (string memory) {
        if (s == Scenario.Live) return "Live";
        if (s == Scenario.Alternate) return "Alternate";
        if (s == Scenario.Cached) return "Cached";
        return "SecondSourceDisagrees";
    }

    /// @dev Logs `g` and checks it against `budget`.
    function _log(
        string memory kind,
        Scenario s,
        string memory what,
        uint256 g,
        uint256 budget
    ) internal {
        string memory label = string.concat(kind, " ", _name(s), " ", what);
        emit log_named_uint(label, g);
        assertLe(g, budget, label);
    }

    /// @dev Every served-price view returns what `getPriceState()` reports in the same block: the served views skip
    /// the second sources, which change neither the price, its timestamp, the state nor the age limits.
    function _servedViewsMatchReport() internal view {
        ILPOracle o = ILPOracle(address(oracle));
        PriceStateView memory v = o.getPriceState();
        assertEq(o.latestAnswer(), v.answer, "latestAnswer");
        (, int256 answer,, uint256 updatedAt,) = o.latestRoundData();
        assertEq(answer, v.answer, "latestRoundData answer");
        assertEq(updatedAt, v.servedUpdatedAt, "latestRoundData updatedAt");
        (, uint64 servedAt, PriceState state) = o.getTokenPrices();
        assertEq(servedAt, v.servedUpdatedAt, "getTokenPrices updatedAt");
        assertEq(uint8(state), uint8(v.state), "getTokenPrices state");
        assertEq(o.borrowPriceMaxAge(), v.borrowPriceMaxAge, "borrowPriceMaxAge");
        assertEq(o.liquidationPriceMaxAge(), v.liquidationPriceMaxAge, "liquidationPriceMaxAge");
        assertEq(IGasAaveOracle(aave.cdpOracle).getReservePrice(vtReserveId), uint256(v.answer), "AaveOracle");
    }

    function _borrow() internal returns (uint256 g) {
        _avanaHook();
        vm.prank(positionProxy);
        g = gasleft();
        IAaveV4Spoke(aave.cdpSpoke).borrow(debtReserveIds[3], 100e18, positionProxy);
        g -= gasleft();
    }

    function _withdraw() internal returns (uint256 g) {
        _avanaHook();
        vm.prank(positionProxy);
        g = gasleft();
        IAaveV4Spoke(aave.cdpSpoke).withdraw(vtReserveId, 100_000_000, positionProxy);
        g -= gasleft();
    }

    function _liquidate() internal returns (uint256 g) {
        _avanaHook();
        vm.prank(liquidator);
        g = gasleft();
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(vtReserveId, debtReserveIds[0], positionProxy, 50e18, false);
        g -= gasleft();
    }

    function _fundLiquidator() internal {
        debts[0].mint(liquidator, 1000e18);
        vm.prank(liquidator);
        debts[0].approve(aave.cdpSpoke, type(uint256).max);
    }

    function _latestAnswer() internal view returns (uint256 g) {
        g = gasleft();
        ILPOracle(address(oracle)).latestAnswer();
        g -= gasleft();
    }

    function _latestRoundData() internal view returns (uint256 g) {
        g = gasleft();
        ILPOracle(address(oracle)).latestRoundData();
        g -= gasleft();
    }

    function _getPriceState() internal view returns (uint256 g) {
        g = gasleft();
        ILPOracle(address(oracle)).getPriceState();
        g -= gasleft();
    }

    function _getTokenPrices() internal view returns (uint256 g) {
        g = gasleft();
        ILPOracle(address(oracle)).getTokenPrices();
        g -= gasleft();
    }

    function _reservePrice() internal view returns (uint256 g) {
        g = gasleft();
        IGasAaveOracle(aave.cdpOracle).getReservePrice(vtReserveId);
        g -= gasleft();
    }

    function _chainlinkReservePrice() internal view returns (uint256 g) {
        g = gasleft();
        IGasAaveOracle(aave.cdpOracle).getReservePrice(debtReserveIds[1]);
        g -= gasleft();
    }

    function _poke() internal returns (uint256 g) {
        g = gasleft();
        ILPOracle(address(oracle)).poke();
        g -= gasleft();
    }
}

/// @notice Cold: every top-level call is its own transaction (`isolate = true`), so each measured call starts with
/// every account and slot cold.
contract LPOracleAaveFlowsColdGasTest is LPOracleAaveFlowsGasBase {
    function _reads(
        Scenario s
    ) internal {
        _scenario(s);
        _log("COLD", s, "latestAnswer", _latestAnswer(), COLD_READ);
        _log("COLD", s, "latestRoundData", _latestRoundData(), COLD_READ);
        _log("COLD", s, "getTokenPrices", _getTokenPrices(), COLD_READ);
        _log("COLD", s, "getPriceState", _getPriceState(), COLD_PRICE_STATE);
        _log("COLD", s, "AaveOracle.getReservePrice(LP)", _reservePrice(), COLD_RESERVE_PRICE);
        _log("COLD", s, "AaveOracle.getReservePrice(Chainlink)", _chainlinkReservePrice(), 30_000);
        _log("COLD", s, "poke", _poke(), COLD_POKE);
        _servedViewsMatchReport();
    }

    function _flows(
        Scenario s
    ) internal {
        _scenario(s);
        _log("COLD", s, "borrow", _borrow(), COLD_BORROW);
        _log("COLD", s, "withdraw", _withdraw(), COLD_WITHDRAW);
        _makeLiquidatable();
        _fundLiquidator();
        _log("COLD", s, "liquidationCall", _liquidate(), COLD_LIQUIDATION);
    }

    // TEST-038 verifies: REQ-ORACLE-020, REQ-ORACLE-041, REQ-ORACLE-042, REQ-ORACLE-044, REQ-ORACLE-061, REQ-ORACLE-100, REQ-ORACLE-102, REQ-ORACLE-106
    function test_TEST_038_coldReadsWithinBudgetLive() public {
        _reads(Scenario.Live);
    }

    // TEST-038 verifies: REQ-ORACLE-020, REQ-ORACLE-041, REQ-ORACLE-042, REQ-ORACLE-044, REQ-ORACLE-061, REQ-ORACLE-100, REQ-ORACLE-102, REQ-ORACLE-106
    function test_TEST_038_coldReadsWithinBudgetAlternate() public {
        _reads(Scenario.Alternate);
    }

    // TEST-038 verifies: REQ-ORACLE-020, REQ-ORACLE-041, REQ-ORACLE-042, REQ-ORACLE-044, REQ-ORACLE-061, REQ-ORACLE-100, REQ-ORACLE-102, REQ-ORACLE-106
    function test_TEST_038_coldReadsWithinBudgetCached() public {
        _reads(Scenario.Cached);
    }

    // TEST-038 verifies: REQ-ORACLE-020, REQ-ORACLE-041, REQ-ORACLE-042, REQ-ORACLE-044, REQ-ORACLE-061, REQ-ORACLE-100, REQ-ORACLE-102, REQ-ORACLE-106
    function test_TEST_038_coldReadsWithinBudgetSecondSource() public {
        _reads(Scenario.SecondSourceDisagrees);
    }

    // TEST-038 verifies: REQ-ORACLE-020, REQ-ORACLE-041, REQ-ORACLE-042, REQ-ORACLE-044, REQ-ORACLE-061, REQ-ORACLE-100, REQ-ORACLE-102, REQ-ORACLE-106
    function test_TEST_038_coldFlowsWithinBudgetLive() public {
        _flows(Scenario.Live);
    }

    // TEST-038 verifies: REQ-ORACLE-020, REQ-ORACLE-041, REQ-ORACLE-042, REQ-ORACLE-044, REQ-ORACLE-061, REQ-ORACLE-100, REQ-ORACLE-102, REQ-ORACLE-106
    function test_TEST_038_coldFlowsWithinBudgetAlternate() public {
        _flows(Scenario.Alternate);
    }

    // TEST-038 verifies: REQ-ORACLE-020, REQ-ORACLE-041, REQ-ORACLE-042, REQ-ORACLE-044, REQ-ORACLE-061, REQ-ORACLE-100, REQ-ORACLE-102, REQ-ORACLE-106
    function test_TEST_038_coldFlowsWithinBudgetCached() public {
        _flows(Scenario.Cached);
    }

    // TEST-038 verifies: REQ-ORACLE-020, REQ-ORACLE-041, REQ-ORACLE-042, REQ-ORACLE-044, REQ-ORACLE-061, REQ-ORACLE-100, REQ-ORACLE-102, REQ-ORACLE-106
    function test_TEST_038_coldFlowsWithinBudgetSecondSource() public {
        _flows(Scenario.SecondSourceDisagrees);
    }
}

/// forge-config: default.isolate = false
/// @notice Warm: one transaction; each measured call repeats a call made just before it.
contract LPOracleAaveFlowsWarmGasTest is LPOracleAaveFlowsGasBase {
    function _reads(
        Scenario s
    ) internal {
        _scenario(s);
        _latestAnswer();
        _log("WARM", s, "latestAnswer", _latestAnswer(), WARM_READ);
        _log("WARM", s, "latestRoundData", _latestRoundData(), WARM_READ);
        _log("WARM", s, "getTokenPrices", _getTokenPrices(), WARM_READ);
        _getPriceState();
        _log("WARM", s, "getPriceState", _getPriceState(), WARM_PRICE_STATE);
        _reservePrice();
        _log("WARM", s, "AaveOracle.getReservePrice(LP)", _reservePrice(), WARM_READ);
        _chainlinkReservePrice();
        _log("WARM", s, "AaveOracle.getReservePrice(Chainlink)", _chainlinkReservePrice(), 5000);
        _poke();
        _log("WARM", s, "poke", _poke(), WARM_POKE);
        _servedViewsMatchReport();
    }

    function _flows(
        Scenario s
    ) internal {
        _scenario(s);
        _borrow();
        _log("WARM", s, "borrow", _borrow(), WARM_BORROW);
        _withdraw();
        _log("WARM", s, "withdraw", _withdraw(), WARM_WITHDRAW);
        _makeLiquidatable();
        _fundLiquidator();
        _liquidate();
        _log("WARM", s, "liquidationCall", _liquidate(), WARM_LIQUIDATION);
    }

    // TEST-038 verifies: REQ-ORACLE-020, REQ-ORACLE-041, REQ-ORACLE-042, REQ-ORACLE-044, REQ-ORACLE-061, REQ-ORACLE-100, REQ-ORACLE-102, REQ-ORACLE-106
    function test_TEST_038_warmReadsWithinBudgetLive() public {
        _reads(Scenario.Live);
    }

    // TEST-038 verifies: REQ-ORACLE-020, REQ-ORACLE-041, REQ-ORACLE-042, REQ-ORACLE-044, REQ-ORACLE-061, REQ-ORACLE-100, REQ-ORACLE-102, REQ-ORACLE-106
    function test_TEST_038_warmReadsWithinBudgetAlternate() public {
        _reads(Scenario.Alternate);
    }

    // TEST-038 verifies: REQ-ORACLE-020, REQ-ORACLE-041, REQ-ORACLE-042, REQ-ORACLE-044, REQ-ORACLE-061, REQ-ORACLE-100, REQ-ORACLE-102, REQ-ORACLE-106
    function test_TEST_038_warmReadsWithinBudgetCached() public {
        _reads(Scenario.Cached);
    }

    // TEST-038 verifies: REQ-ORACLE-020, REQ-ORACLE-041, REQ-ORACLE-042, REQ-ORACLE-044, REQ-ORACLE-061, REQ-ORACLE-100, REQ-ORACLE-102, REQ-ORACLE-106
    function test_TEST_038_warmReadsWithinBudgetSecondSource() public {
        _reads(Scenario.SecondSourceDisagrees);
    }

    // TEST-038 verifies: REQ-ORACLE-020, REQ-ORACLE-041, REQ-ORACLE-042, REQ-ORACLE-044, REQ-ORACLE-061, REQ-ORACLE-100, REQ-ORACLE-102, REQ-ORACLE-106
    function test_TEST_038_warmFlowsWithinBudgetLive() public {
        _flows(Scenario.Live);
    }

    // TEST-038 verifies: REQ-ORACLE-020, REQ-ORACLE-041, REQ-ORACLE-042, REQ-ORACLE-044, REQ-ORACLE-061, REQ-ORACLE-100, REQ-ORACLE-102, REQ-ORACLE-106
    function test_TEST_038_warmFlowsWithinBudgetAlternate() public {
        _flows(Scenario.Alternate);
    }

    // TEST-038 verifies: REQ-ORACLE-020, REQ-ORACLE-041, REQ-ORACLE-042, REQ-ORACLE-044, REQ-ORACLE-061, REQ-ORACLE-100, REQ-ORACLE-102, REQ-ORACLE-106
    function test_TEST_038_warmFlowsWithinBudgetCached() public {
        _flows(Scenario.Cached);
    }

    // TEST-038 verifies: REQ-ORACLE-020, REQ-ORACLE-041, REQ-ORACLE-042, REQ-ORACLE-044, REQ-ORACLE-061, REQ-ORACLE-100, REQ-ORACLE-102, REQ-ORACLE-106
    function test_TEST_038_warmFlowsWithinBudgetSecondSource() public {
        _flows(Scenario.SecondSourceDisagrees);
    }
}
