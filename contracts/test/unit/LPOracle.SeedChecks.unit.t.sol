// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {ILPOracleErrors} from "../../src/oracle/lp-oracle/ILPOracleErrors.sol";
import {LPOracleCodes} from "../../src/oracle/lp-oracle/LPOracleTypes.sol";
import {InitParams} from "../../src/oracle/lp-oracle/types/InitParams.sol";
import {OracleConfig} from "../../src/types/OracleConfig.sol";
import {TokenOracleConfig} from "../../src/types/TokenOracleConfig.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";
import {LPOracleHarness, LPOracleHarnessDeployer} from "../utils/harness/LPOracleHarness.sol";
import {OracleTokenMock, ReadMode} from "../utils/mocks/LPOracleMocks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice The entry points that refuse a configuration of another market or another token list before the seed
/// evaluation reads it (2.10 `REQ-ORACLE-046`, `REQ-ORACLE-058`). `_loadSeed` repeats the token-count and market check
/// as a defensive branch that today's paths cannot reach (`security/coverage-thresholds.json` `unreachable`): these
/// tests are what keep the rule covered.
contract LPOracleSeedChecksUnitTest is LPOracleFixture {
    function setUp() public {
        _deployMarket();
    }

    function _deploy(
        InitParams memory p
    ) internal returns (bool ok, bytes memory ret) {
        LPOracleHarness impl = LPOracleHarnessDeployer.deploy(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false);
        try new ERC1967Proxy(address(impl), abi.encodeCall(ILPOracle.initialize, (p))) {
            return (true, "");
        } catch (bytes memory reason) {
            return (false, reason);
        }
    }

    function _mismatch(
        uint256 id
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ILPOracleErrors.MarketMismatch.selector, id);
    }

    /// @dev The configuration's first two tokens, then new 6-decimal tokens priced by token B's feeds, `count` in all.
    function _tokens(
        OracleConfig memory c,
        uint256 count
    ) internal returns (OracleConfig memory) {
        TokenOracleConfig[] memory list = new TokenOracleConfig[](count);
        for (uint256 i = 0; i < count; ++i) {
            list[i] = i < 2
                ? c.tokens[i]
                : _tokenConfig(address(new OracleTokenMock(6)), address(pB), address(aB), address(sB));
        }
        c.tokens = list;
        return c;
    }

    // TEST-219 verifies: REQ-ORACLE-046, REQ-ORACLE-048
    /// @notice `checkConfig` returns exactly `CHECK_TOKENS`, before any read, for a token list of another length, a
    /// market id of 0 or of another market; the seed evaluation never sees such a configuration.
    function test_TEST_219_checkConfigRefusesAnotherMarketOrTokenCount() public {
        OracleConfig memory c = _config();
        TokenOracleConfig[] memory one = new TokenOracleConfig[](1);
        one[0] = c.tokens[0];
        c.tokens = one;
        assertEq(oracle.checkConfig(c), LPOracleCodes.CHECK_TOKENS, "one token");
        assertEq(oracle.checkConfig(_tokens(_config(), 3)), LPOracleCodes.CHECK_TOKENS, "three tokens");
        c = _config();
        c.marketId = 0;
        assertEq(oracle.checkConfig(c), LPOracleCodes.CHECK_TOKENS, "market 0");
        c.marketId = MARKET + 1;
        assertEq(oracle.checkConfig(c), LPOracleCodes.CHECK_TOKENS, "another market");
        assertEq(oracle.checkConfig(_config()), 0, "the market's own configuration passes");
    }

    // TEST-219 verifies: REQ-ORACLE-046, REQ-ORACLE-048, REQ-ORACLE-058
    /// @notice Same length, other tokens: `checkConfig` flags `CHECK_TOKENS`, and the seed evaluation of the same
    /// configuration fails, so `CHECK_QUOTES` is set too.
    function test_TEST_219_checkConfigRefusesOtherTokensInPlace() public view {
        OracleConfig memory c = _config();
        (c.tokens[0], c.tokens[1]) = (c.tokens[1], c.tokens[0]);
        uint256 failed = oracle.checkConfig(c);
        assertTrue(failed & LPOracleCodes.CHECK_TOKENS != 0, "pool order differs");
        assertTrue(failed & LPOracleCodes.CHECK_QUOTES != 0, "the seed evaluation refuses another token");
    }

    // TEST-062 verifies: REQ-ORACLE-058, REQ-ORACLE-047, MKT-019
    /// @notice `initialize` reverts `MarketMismatch` before the listing logic runs for a market id of 0, a configuration
    /// of another market, fewer than 2 or more than 8 tokens, stable flags of another length, a zero token, a token
    /// whose decimals cannot be read, and a zero store, registry or integration.
    function test_TEST_062_initializeRefusesAnotherMarketOrTokenList() public {
        InitParams memory p = _params();
        p.marketId = 0;
        p.config.marketId = 0;
        (bool ok, bytes memory ret) = _deploy(p);
        assertEq(ret, _mismatch(0), "market 0");
        p = _params();
        p.config.marketId = MARKET + 1;
        (ok, ret) = _deploy(p);
        assertEq(ret, _mismatch(MARKET), "configuration of another market");
        p = _params();
        p.config = _tokens(p.config, 1);
        p.isUsdStable = new bool[](1);
        (ok, ret) = _deploy(p);
        assertEq(ret, _mismatch(MARKET), "one token");
        p = _params();
        p.config = _tokens(p.config, 9);
        p.isUsdStable = new bool[](9);
        (ok, ret) = _deploy(p);
        assertEq(ret, _mismatch(MARKET), "nine tokens");
        p = _params();
        p.config.tokens[1].token = address(0);
        (ok, ret) = _deploy(p);
        assertEq(ret, _mismatch(MARKET), "zero token");
        assertFalse(ok);
    }

    // TEST-062 verifies: REQ-ORACLE-058, REQ-ORACLE-047, REQ-ORACLE-107
    /// @notice The addresses and decimals `initialize` stores must be usable: a zero ParameterStore, MarketRegistry or
    /// integration, or a token whose `decimals()` reverts, reverts `MarketMismatch`.
    function test_TEST_062_initializeRefusesUnusableMarketData() public {
        InitParams memory p = _params();
        p.parameterStore = address(0);
        (, bytes memory ret) = _deploy(p);
        assertEq(ret, _mismatch(MARKET), "zero store");
        p = _params();
        p.marketRegistry = address(0);
        (, ret) = _deploy(p);
        assertEq(ret, _mismatch(MARKET), "zero registry");
        p = _params();
        p.integration = address(0);
        (, ret) = _deploy(p);
        assertEq(ret, _mismatch(MARKET), "zero integration");
        tokenB.setMode(OracleTokenMock.decimals.selector, ReadMode.Revert);
        (, ret) = _deploy(_params());
        assertEq(ret, _mismatch(MARKET), "unreadable token decimals");
        tokenB.setMode(OracleTokenMock.decimals.selector, ReadMode.Normal);
        (bool ok,) = _deploy(_params());
        assertTrue(ok, "the launch parameters deploy");
    }
}
