// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPOracleCodes} from "../../src/oracle/lp-oracle/LPOracleTypes.sol";
import {Market} from "../../src/types/Market.sol";
import {OracleConfig} from "../../src/types/OracleConfig.sol";
import {OracleRoute} from "../../src/types/OracleRoute.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";
import {OracleFeedMock} from "../utils/mocks/LPOracleMocks.sol";

/// @notice `checkConfig` on inputs the launch configuration never exercises (2.10 `REQ-ORACLE-046` to
/// `REQ-ORACLE-056`): a two-leg route's value range, a proxy whose aggregator cannot be read, an unreadable agreement
/// margin, a second source with no source, a pricing module that cannot value the listing or the shocked quotes, an
/// unreadable registry and a registered market with another token count.
contract LPOracleCheckConfigEdgesUnitTest is LPOracleFixture {
    function setUp() public {
        _deployMarket();
    }

    function _check(
        OracleConfig memory c
    ) internal view returns (uint256) {
        return oracle.checkConfig(c);
    }

    /// @dev Token A's alternate as the two-leg route `x * y` of two new 8-decimal feeds with `minAnswer = lo`,
    /// `maxAnswer = hi` on both the feeds and the legs.
    function _twoLeg(
        int128 lo,
        int128 hi
    ) internal returns (OracleConfig memory c) {
        OracleFeedMock x = _feed("x");
        OracleFeedMock y = _feed("y");
        x.setBounds(lo, hi);
        y.setBounds(lo, hi);
        c = _config();
        OracleRoute memory r = _route(address(x));
        r.legCount = 2;
        r.legs[1] = _route(address(y)).legs[0];
        (r.legs[0].minAnswer, r.legs[0].maxAnswer) = (lo, hi);
        (r.legs[1].minAnswer, r.legs[1].maxAnswer) = (lo, hi);
        c.tokens[0].routes[1] = r;
    }

    // TEST-219 verifies: REQ-ORACLE-049, REQ-ORACLE-054, SPEC-ORC-019, Q-066, Q-191, Q-322
    /// @notice A two-leg route of two 8-decimal legs bounded `[10^4, 10^12]` values between
    /// `(10^4 + 1)^2 / 10^8 = 1` and `10^24 / 10^8 = 10^16`, inside `[1, 10^18]`: no CHECK_ROUTE_RANGE. With
    /// `minAnswer = 1` its least value `2 * 2 / 10^8` rounds to 0, and with `maxAnswer = 10^14` its largest is
    /// `10^20 > 10^18`: each sets CHECK_ROUTE_RANGE.
    function test_TEST_219_twoLegRouteValueRange() public {
        assertEq(_check(_twoLeg(1e4, 1e12)) & LPOracleCodes.CHECK_ROUTE_RANGE, 0, "inside the range");
        assertTrue(_check(_twoLeg(1, 1e12)) & LPOracleCodes.CHECK_ROUTE_RANGE != 0, "least value 0");
        assertTrue(_check(_twoLeg(1e4, 1e14)) & LPOracleCodes.CHECK_ROUTE_RANGE != 0, "largest value above 10^18");
    }

    // TEST-219 verifies: REQ-ORACLE-049, REQ-ORACLE-054, SPEC-ORC-019, Q-066, Q-191, Q-322
    /// @notice A leg's bounds are pinned from the proxy's aggregator: a proxy whose `aggregator()` answers the zero
    /// address, or reverts, cannot be checked and sets CHECK_LEG_BOUNDS.
    function test_TEST_219_unreadableAggregatorFailsLegBounds() public {
        assertEq(_check(_config()), 0, "control");
        bytes memory call = abi.encodeWithSignature("aggregator()");
        vm.mockCall(address(pA), call, abi.encode(address(0)));
        assertTrue(_check(_config()) & LPOracleCodes.CHECK_LEG_BOUNDS != 0, "zero aggregator");
        vm.mockCallRevert(address(pA), call, "down");
        assertTrue(_check(_config()) & LPOracleCodes.CHECK_LEG_BOUNDS != 0, "reverting aggregator()");
    }

    // TEST-219 verifies: REQ-ORACLE-051, REQ-ORACLE-053, SPEC-ORC-020, ATTACK-054, Q-184, Q-323
    /// @notice The tolerances are checked against the ParameterStore's `feedAgreementMarginBps`: when it reverts or
    /// answers a word above `uint16`, the check fails closed with exactly CHECK_TOLERANCE.
    function test_TEST_219_unreadableMarginFailsTolerance() public {
        bytes memory call = abi.encodeWithSignature("feedAgreementMarginBps()");
        vm.mockCallRevert(address(store), call, "down");
        assertEq(_check(_config()), LPOracleCodes.CHECK_TOLERANCE, "reverting margin");
        vm.mockCall(address(store), call, abi.encode(uint256(1) << 16));
        assertEq(_check(_config()), LPOracleCodes.CHECK_TOLERANCE, "margin above uint16");
    }

    // TEST-219 verifies: REQ-ORACLE-051, REQ-ORACLE-053, SPEC-ORC-020, ATTACK-054, Q-184, Q-323
    /// @notice An oracle-network second source with no source address is malformed: exactly CHECK_SECOND_SOURCE.
    function test_TEST_219_secondSourceWithoutSource() public view {
        OracleConfig memory c = _config();
        c.tokens[1].secondSource.source = address(0);
        assertEq(_check(c), LPOracleCodes.CHECK_SECOND_SOURCE);
    }

    // TEST-219 verifies: REQ-ORACLE-056, REQ-ORACLE-099, REQ-ORACLE-103, REQ-ORACLE-047, REQ-ORACLE-050, Q-176, Q-324
    /// @notice When the pricing module cannot compose the vault token, `d` cannot be re-derived at the listing prices
    /// (CHECK_VAULT_DECIMALS) and no shocked quote vector is valued (CHECK_SHOCK). With a composition of `10^-18` raw
    /// units of each token per vault-token unit, a whole vault token is worth far below `10^6` at every shocked vector:
    /// CHECK_SHOCK.
    function test_TEST_219_moduleThatCannotValueFailsDecimalsAndShock() public {
        oracle.setCompositionFails(true);
        uint256 failed = _check(_config());
        assertTrue(failed & LPOracleCodes.CHECK_VAULT_DECIMALS != 0, "no composition: d");
        assertTrue(failed & LPOracleCodes.CHECK_SHOCK != 0, "no composition: shock");
        oracle.setCompositionFails(false);
        uint256[] memory tiny = new uint256[](2);
        (tiny[0], tiny[1]) = (1, 1);
        oracle.setCoefficients(tiny);
        assertTrue(_check(_config()) & LPOracleCodes.CHECK_SHOCK != 0, "shocked price below 10^6");
    }

    // TEST-219 verifies: REQ-ORACLE-047, REQ-ORACLE-048, Q-066, Q-370
    /// @notice A MarketRegistry whose `marketOfLpOracle` reverts gives exactly CHECK_MARKET; a registered market whose
    /// token list has one token instead of two gives CHECK_MARKET too.
    function test_TEST_219_unreadableOrMismatchedRegistryFailsMarket() public {
        bytes memory call = abi.encodeWithSignature("marketOfLpOracle(address)", address(oracle));
        vm.mockCallRevert(address(registry), call, "down");
        assertEq(_check(_config()), LPOracleCodes.CHECK_MARKET, "unreadable registry");
        vm.clearMockedCalls();
        Market memory m;
        m.integration = integrationAddr;
        m.lpOracle = address(oracle);
        m.decimals = 6;
        m.tokens = _one(address(tokenA));
        m.tokenDecimals = new uint8[](1);
        registry.setMarketOf(address(oracle), MARKET, m);
        assertEq(_check(_config()), LPOracleCodes.CHECK_MARKET, "one token registered");
        m.tokens = _two(address(tokenA), address(tokenB));
        m.tokenDecimals = new uint8[](2);
        registry.setMarketOf(address(oracle), MARKET, m);
        assertEq(_check(_config()), 0, "control: both tokens in order");
    }
}
