// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {ILPOracleErrors} from "../../src/oracle/lp-oracle/ILPOracleErrors.sol";
import {LPOracleCodes} from "../../src/oracle/lp-oracle/LPOracleTypes.sol";
import {InitParams} from "../../src/oracle/lp-oracle/types/InitParams.sol";
import {OracleInputsLayout} from "../../src/policy/parameter-store/types/OracleInputsLayout.sol";
import {OracleConfig} from "../../src/types/OracleConfig.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";
import {LPOracleHarness, LPOracleHarnessDeployer} from "../utils/harness/LPOracleHarness.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice The inputs of an LPOracle evaluation (2.10 Configuration read on every evaluation): each word of the one
/// `getOracleInputs` read is range-checked against its type, so a word beyond its type is a failed read that fails the
/// market (reason bit 1), never a decoder revert; the seed configuration of `initialize` and `checkConfig` refuses a
/// leg with no aggregator or no pinned decimals; `initialize` refuses a repeated token; token and aggregator reads that
/// return too little data or a value beyond its type fail their check; and a view's only revert is `InsufficientGas`.
contract LPOracleInputsUnitTest is LPOracleFixture {
    uint256 internal constant H = OracleInputsLayout.HEAD_WORDS;
    uint256 internal constant T = OracleInputsLayout.TOKEN_WORDS;
    uint256 internal constant L = OracleInputsLayout.LEG_WORDS;

    uint256 internal constant S = OracleInputsLayout.SECOND_WORDS;
    /// @dev Both tokens at 0.995 USD: a Live evaluation serves `2 * (10^6 - 1) * 99,500,000 / 10^6`.
    int256 internal constant FRESH = 198_999_800;

    function setUp() public {
        _deployMarket();
        vm.roll(block.number + 1);
        vm.warp(T0 + 60);
        _pushAll(99_500_000, T0 + 60);
    }

    /// @dev Serves both `getOracleInputs(oracle, [A, B], withSecondSources)` reads with word `offset` of token
    /// `token`'s words (or of the head words for `token == type(uint256).max`) replaced by `value`, as a store whose
    /// stored value does not fit its type would.
    function _serve(
        uint256 token,
        uint256 offset,
        uint256 value
    ) internal {
        vm.clearMockedCalls();
        address[] memory list = _two(address(tokenA), address(tokenB));
        for (uint256 i = 0; i < 2; ++i) {
            bool withSecond = i == 1;
            uint256[] memory w = store.getOracleInputs(address(oracle), list, withSecond);
            uint256 stride = withSecond ? T + S : T;
            w[token == type(uint256).max ? offset : H + token * stride + offset] = value;
            vm.mockCall(
                address(store),
                abi.encodeCall(store.getOracleInputs, (address(oracle), list, withSecond)),
                abi.encode(w)
            );
        }
    }

    function _serveHead(
        uint256 index,
        uint256 value
    ) internal {
        _serve(type(uint256).max, index, value);
    }

    /// @dev The market is failed with reason bit 1: Cached, serving the accepted (seeded) price in every view.
    function _assertFailedRead(
        string memory what
    ) internal view {
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Cached), what);
        assertTrue(v.reasons & LPOracleCodes.CONFIG_OR_DECIMALS_UNAVAILABLE != 0, what);
        assertEq(v.answer, int256(SEEDED), "the accepted price is served");
        assertEq(oracle.latestAnswer(), int256(SEEDED), "latestAnswer serves the accepted price");
        (,, PriceState served) = oracle.getTokenPrices();
        assertEq(uint8(served), uint8(PriceState.Cached), "served views see the failed read");
        assertEq(oracle.borrowPriceMaxAge(), 0, "no borrow age while failed");
    }

    function _assertLive(
        string memory what
    ) internal view {
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Live), what);
        assertEq(v.reasons & LPOracleCodes.CONFIG_OR_DECIMALS_UNAVAILABLE, 0, what);
        assertEq(v.answer, FRESH, "the fresh price is served");
        assertEq(oracle.latestAnswer(), FRESH, "latestAnswer");
    }

    // ─── Live configuration read ───

    // TEST-040 verifies: REQ-ORACLE-017, REQ-ORACLE-061, REQ-ORACLE-083
    function test_TEST_040_headWordBeyondItsTypeFailsTheMarket() public {
        _assertLive("unchanged words");
        _serveHead(1, type(uint32).max);
        _assertLive("twapWindow 2^32 - 1 fits uint32");
        _serveHead(1, uint256(type(uint32).max) + 1);
        _assertFailedRead("twapWindow 2^32");
        _serveHead(2, uint256(type(uint16).max) + 1);
        _assertFailedRead("consistencyToleranceBps 2^16");
        _serveHead(8, uint256(type(uint160).max) + 1);
        _assertFailedRead("sequencer feed above 160 bits");
        _serveHead(9, uint256(type(uint32).max) + 1);
        _assertFailedRead("sequencer grace period 2^32");
    }

    // TEST-040 verifies: REQ-ORACLE-017, REQ-ORACLE-061, REQ-ORACLE-083, REQ-ORACLE-094
    function test_TEST_040_tokenWordBeyondItsTypeFailsTheMarket() public {
        _serve(1, 0, type(uint16).max);
        _assertLive("token B tolerance 2^16 - 1 fits uint16");
        _serve(1, 0, uint256(type(uint16).max) + 1);
        _assertFailedRead("token B tolerance 2^16");
        _serve(0, 1, uint256(type(uint64).max) + 1);
        _assertFailedRead("route version 2^64");
        _serve(0, 2, 3);
        _assertFailedRead("replaced slot 3");
    }

    // TEST-040 verifies: REQ-ORACLE-017, REQ-ORACLE-061, REQ-ORACLE-094
    function test_TEST_040_legWordBeyondItsTypeFailsTheMarket() public {
        uint256 leg = 5;
        _serve(0, leg, 0);
        _assertFailedRead("leg with no aggregator");
        _serve(0, leg, uint256(uint160(address(pA))) | (uint256(1) << 160));
        _assertFailedRead("aggregator above 160 bits");
        _serve(0, leg + 1, 0);
        _assertFailedRead("leg with no feed definition (pinned decimals 0)");
        _serve(0, leg + 1, 256);
        _assertFailedRead("pinned decimals 256");
        _serve(1, leg + 4, uint256(type(uint32).max) + 1);
        _assertFailedRead("token B heartbeat 2^32");
        // The alternate's first leg sits two legs further.
        _serve(0, leg + 2 * L + 7, uint256(type(uint32).max) + 1);
        _assertFailedRead("alternate liquidation age 2^32");
    }

    // ─── Seed configuration (initialize and checkConfig) ───

    // TEST-219 verifies: REQ-ORACLE-046, REQ-ORACLE-047, REQ-ORACLE-049, REQ-ORACLE-017
    function test_TEST_219_seedLegWithNoAggregatorOrDecimalsFailsTheQuotes() public view {
        OracleConfig memory c = _config();
        c.tokens[0].routes[0].legs[0].aggregator = address(0);
        uint256 failed = oracle.checkConfig(c);
        assertTrue(failed & LPOracleCodes.CHECK_QUOTES != 0, "no aggregator: the seed evaluation fails");
        assertTrue(failed & LPOracleCodes.CHECK_LEG_DECIMALS != 0, "no aggregator: decimals unread");
        c = _config();
        c.tokens[1].routes[1].legs[0].decimals = 0;
        failed = oracle.checkConfig(c);
        assertTrue(failed & LPOracleCodes.CHECK_QUOTES != 0, "pinned decimals 0: the seed evaluation fails");
        assertTrue(failed & LPOracleCodes.CHECK_LEG_DECIMALS != 0, "pinned decimals 0 differ from the feed's 8");
    }

    // TEST-062 verifies: REQ-ORACLE-058, REQ-ORACLE-047, SPEC-ORC-005
    function test_TEST_062_initializeRefusesSeedLegWithNoAggregator() public {
        LPOracleHarness impl = LPOracleHarnessDeployer.deploy(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false);
        InitParams memory p = _params();
        p.config.tokens[0].routes[1].legs[0].aggregator = address(0);
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.ConfigCheckFailed.selector, LPOracleCodes.CHECK_QUOTES));
        new ERC1967Proxy(address(impl), abi.encodeCall(ILPOracle.initialize, (p)));
    }

    // TEST-062 verifies: REQ-ORACLE-058, MKT-019
    function test_TEST_062_initializeRefusesRepeatedToken() public {
        LPOracleHarness impl = LPOracleHarnessDeployer.deploy(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false);
        InitParams memory p = _params();
        p.config.tokens[1] = _tokenConfig(address(tokenA), address(pB), address(aB), address(sB));
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.MarketMismatch.selector, MARKET));
        new ERC1967Proxy(address(impl), abi.encodeCall(ILPOracle.initialize, (p)));
    }

    // ─── Bounded reads of tokens and aggregators ───

    // TEST-219 verifies: REQ-ORACLE-046, REQ-ORACLE-001, REQ-ORACLE-061
    function test_TEST_219_malformedTokenDecimalsFailTheCheck() public {
        bytes memory call = abi.encodeWithSignature("decimals()");
        vm.mockCall(address(tokenB), call, abi.encode(uint256(256)));
        assertTrue(oracle.checkConfig(_config()) & LPOracleCodes.CHECK_TOKEN_DECIMALS != 0, "decimals 256");
        vm.mockCall(address(tokenB), call, hex"0006");
        assertTrue(oracle.checkConfig(_config()) & LPOracleCodes.CHECK_TOKEN_DECIMALS != 0, "2-byte return");
        vm.clearMockedCalls();
        assertEq(oracle.checkConfig(_config()), 0);
    }

    // TEST-219 verifies: REQ-ORACLE-049, REQ-ORACLE-001, REQ-ORACLE-061
    function test_TEST_219_malformedAggregatorBoundFailsTheCheck() public {
        bytes memory call = abi.encodeWithSignature("minAnswer()");
        vm.mockCall(address(pA), call, abi.encode(int256(type(int192).max) + 1));
        assertTrue(oracle.checkConfig(_config()) & LPOracleCodes.CHECK_LEG_BOUNDS != 0, "minAnswer is no int192");
        vm.mockCall(address(pA), call, hex"01");
        assertTrue(oracle.checkConfig(_config()) & LPOracleCodes.CHECK_LEG_BOUNDS != 0, "1-byte return");
        vm.clearMockedCalls();
        assertEq(oracle.checkConfig(_config()), 0);
    }

    // ─── The only view revert ───

    /// @notice Across gas limits, every revert of `getPriceState()` that carries data is `InsufficientGas`: the
    /// pre-call bound of a read (`required > 0`) and a view logic that ran out of gas with no revert data, which the
    /// forward reports as `InsufficientGas(gasLeft, 0)`.
    // TEST-219 verifies: REQ-ORACLE-061, REQ-ORACLE-102, SPEC-ORC-023
    function test_TEST_219_viewRevertsOnlyInsufficientGas() public view {
        bytes memory call = abi.encodeCall(oracle.getPriceState, ());
        bool sawOutOfGas = false;
        bool sawBound = false;
        for (uint256 g = 3000; g <= 300_000 && !(sawOutOfGas && sawBound); g += 500) {
            (bool ok, bytes memory ret) = address(oracle).staticcall{gas: g}(call);
            // An empty revert is the proxy or the implementation running out of gas before the forward.
            if (ok || ret.length == 0) continue;
            assertEq(bytes4(ret), ILPOracleErrors.InsufficientGas.selector, "the only view revert");
            assertEq(ret.length, 68, "InsufficientGas(gasLeft, required)");
            uint256 required;
            assembly {
                required := mload(add(ret, 68))
            }
            if (required == 0) sawOutOfGas = true;
            else sawBound = true;
        }
        assertTrue(sawOutOfGas, "a starved view logic reverts InsufficientGas");
        assertTrue(sawBound, "a read's pre-call bound reverts InsufficientGas");
    }
}
