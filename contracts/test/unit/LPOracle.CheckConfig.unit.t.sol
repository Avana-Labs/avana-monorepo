// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPOracleCodes} from "../../src/oracle/lp-oracle/LPOracleTypes.sol";
import {Market} from "../../src/types/Market.sol";
import {OracleConfig} from "../../src/types/OracleConfig.sol";
import {SecondSourceKind} from "../../src/types/SecondSourceKind.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";

/// @notice `checkConfig`: the on-chain listing and configuration checks (2.10 `REQ-ORACLE-046` to `REQ-ORACLE-056`).
contract LPOracleCheckConfigUnitTest is LPOracleFixture {
    function setUp() public {
        _deployMarket();
    }

    function _check(
        OracleConfig memory c
    ) internal view returns (uint256) {
        return oracle.checkConfig(c);
    }

    // TEST-219 verifies: REQ-ORACLE-046, REQ-ORACLE-077, Q-191
    function test_TEST_219_launchConfigPasses() public view {
        assertEq(_check(_config()), 0);
    }

    // TEST-219 verifies: REQ-ORACLE-049, REQ-ORACLE-054, SPEC-ORC-019, Q-066, Q-191, Q-322
    function test_TEST_219_legChecks() public {
        OracleConfig memory c = _config();
        c.tokens[0].routes[0].legs[0].decimals = 18;
        assertTrue(_check(c) & LPOracleCodes.CHECK_LEG_DECIMALS != 0, "pinned decimals differ");
        c = _config();
        c.tokens[0].routes[0].legs[0].minAnswer = 2;
        assertTrue(_check(c) & LPOracleCodes.CHECK_LEG_BOUNDS != 0, "minAnswer not the aggregator's");
        c = _config();
        c.tokens[0].routes[0].legs[0].maxAnswer = 2e12;
        assertTrue(_check(c) & LPOracleCodes.CHECK_LEG_BOUNDS != 0, "maxAnswer above the aggregator's");
        pA.setBounds(1, 1e13);
        c.tokens[0].routes[0].legs[0].maxAnswer = 1e13;
        assertTrue(_check(c) & LPOracleCodes.CHECK_ROUTE_RANGE != 0, "route value at maxAnswer above MAX_ROUTE_ANSWER");
        c = _config();
        c.tokens[0].routes[0].legs[0].heartbeatMargin = 0;
        assertTrue(_check(c) & LPOracleCodes.CHECK_HEARTBEAT != 0, "zero margin");
        c = _config();
        c.tokens[0].routes[0].legs[0].liquidationPriceMaxAge = 4200;
        assertTrue(_check(c) & LPOracleCodes.CHECK_HEARTBEAT != 0, "feedMaxAge 4,200 for a 86,400 s feed");
        c = _config();
        c.tokens[0].routes[0].legCount = 3;
        assertTrue(_check(c) & LPOracleCodes.CHECK_ROUTE_RANGE != 0, "three legs");
    }

    // TEST-219 verifies: REQ-ORACLE-051, REQ-ORACLE-053, SPEC-ORC-020, ATTACK-054, Q-184, Q-323
    function test_TEST_219_independenceAndTolerances() public view {
        OracleConfig memory c = _config();
        c.tokens[0].routes[1] = c.tokens[0].routes[0];
        assertTrue(_check(c) & LPOracleCodes.CHECK_SHARED_FEED != 0, "primary and alternate share a feed");
        c = _config();
        c.tokens[1].routes[1] = c.tokens[0].routes[1];
        assertTrue(_check(c) & LPOracleCodes.CHECK_SHARED_FEED != 0, "two alternates share a feed");
        c = _config();
        c.tokens[0].secondSource.source = address(pA);
        assertTrue(_check(c) & LPOracleCodes.CHECK_SHARED_FEED != 0, "second source shares a route feed");
        c = _config();
        c.tokens[0].feedAgreementToleranceBps = 99;
        assertTrue(_check(c) & LPOracleCodes.CHECK_TOLERANCE != 0, "T below 25 + 25 + 50");
        c = _config();
        c.tokens[0].secondSource.toleranceBps = 99;
        assertTrue(_check(c) & LPOracleCodes.CHECK_TOLERANCE != 0, "S below 25 + 25 + 50");
        c = _config();
        c.tokens[0].secondSource.kind = SecondSourceKind.None;
        assertTrue(_check(c) & LPOracleCodes.CHECK_SECOND_SOURCE != 0, "every token needs a second source");
    }

    // TEST-219 verifies: REQ-ORACLE-056, REQ-ORACLE-099, REQ-ORACLE-103, REQ-ORACLE-047, REQ-ORACLE-050, Q-176, Q-324
    function test_TEST_219_marketChecks() public {
        OracleConfig memory c = _config();
        c.usdBandLow = 1e8;
        assertTrue(_check(c) & LPOracleCodes.CHECK_USD_BAND != 0, "band must straddle 1.00");
        c = _config();
        c.sequencer.feed = address(seqFeed);
        assertTrue(_check(c) & LPOracleCodes.CHECK_SEQUENCER != 0, "no sequencer feed on this chain");
        c = _config();
        c.marketId = 2;
        assertEq(_check(c), LPOracleCodes.CHECK_TOKENS, "another market");
        oracle.setListingFailures(1 << 3);
        assertEq(_check(_config()), uint256(1 << 3) << LPOracleCodes.MODULE_CHECKS_SHIFT, "module bits shifted");
        oracle.setListingFailures(0);
        // A token whose quote cannot be read fails the current-quote checks.
        pA.push(0, T0);
        aA.push(0, T0);
        assertTrue(_check(_config()) & LPOracleCodes.CHECK_QUOTES != 0);
    }

    // TEST-219 verifies: REQ-ORACLE-047, REQ-ORACLE-048, Q-066, Q-370
    function test_TEST_219_registeredMarketMustMatch() public {
        Market memory m;
        m.integration = integrationAddr;
        m.lpOracle = address(oracle);
        m.decimals = 6;
        m.tokens = _two(address(tokenA), address(tokenB));
        m.tokenDecimals = new uint8[](2);
        registry.setMarketOf(address(oracle), MARKET, m);
        assertEq(_check(_config()), 0, "registered with this feed, integration, decimals and tokens");
        m.decimals = 7;
        registry.setMarketOf(address(oracle), MARKET, m);
        assertEq(_check(_config()), LPOracleCodes.CHECK_MARKET, "vault-token decimals differ from d");
        m.decimals = 6;
        m.tokens = _two(address(tokenB), address(tokenA));
        registry.setMarketOf(address(oracle), MARKET, m);
        assertEq(_check(_config()), LPOracleCodes.CHECK_MARKET, "token order differs");
    }
}
