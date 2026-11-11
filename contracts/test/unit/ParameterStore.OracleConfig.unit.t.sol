// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {FeedDef} from "../../src/policy/parameter-store/types/FeedDef.sol";
import {OracleInputsLayout} from "../../src/policy/parameter-store/types/OracleInputsLayout.sol";
import {OracleConfig} from "../../src/types/OracleConfig.sol";
import {OracleLeg} from "../../src/types/OracleLeg.sol";
import {SecondSource} from "../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../src/types/SecondSourceKind.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {MockAggregator} from "../utils/mocks/ParameterStoreMocks.sol";

/// @notice Reads single fields of an `OracleConfig` from calldata (decoding the whole nested struct into memory
/// exceeds the legacy code generator's stack).
contract OracleConfigFields {
    function leg(
        OracleConfig calldata c,
        uint256 token,
        uint256 route,
        uint256 index
    ) external pure returns (uint8 legCount, OracleLeg memory l) {
        legCount = c.tokens[token].routes[route].legCount;
        l = c.tokens[token].routes[route].legs[index];
    }

    function second(
        OracleConfig calldata c,
        uint256 token
    ) external pure returns (address tokenAddr, uint16 tolerance, SecondSource memory s) {
        tokenAddr = c.tokens[token].token;
        tolerance = c.tokens[token].feedAgreementToleranceBps;
        s = c.tokens[token].secondSource;
    }

    function chain(
        OracleConfig calldata c
    )
        external
        pure
        returns (uint256 marketId, uint256 tokenCount, uint256 high, uint32 pause, address seqFeed, uint16 maxQuote)
    {
        return (
            c.marketId, c.tokens.length, c.usdBandHigh, c.disagreementPauseMax, c.sequencer.feed, c.maxQuoteChangeBps
        );
    }
}

/// @notice `getOracleConfig` field by field (REQ-CONFIG-072): every leg of every route in force with its pinned
/// values, routes of other lengths served empty, bounds saturated into `int128`, the second source in force, and the
/// market and chain values; and the matching words of `getOracleInputs` (REQ-PSTORE-033).
contract ParameterStoreOracleConfigUnitTest is ParameterStoreFixture {
    OracleConfigFields internal fields;
    MockAggregator internal leg2;
    MockAggregator internal netA;
    MockAggregator internal netB;

    function setUp() public {
        _deployStore(false);
        _listMarket();
        fields = new OracleConfigFields();
        leg2 = new MockAggregator(18, 1e10, 1e30);
        netA = new MockAggregator(8, 2e6, 3e12);
        netB = new MockAggregator(8, 1e6, 1e12);
        vm.startPrank(address(timelock));
        FeedDef memory d = _feedDef(3600, 600);
        d.feedDeviationThresholdBps = 40;
        store.setFeed(address(leg2), d);
        store.setFeed(address(netA), _feedDef(86_400, 1800));
        store.setFeed(address(netB), _feedDef(86_400, 1800));
        store.grantRole(AvanaRoles.APPLICATION_PAUSE_GUARDIAN, emergencyGuardian);
        vm.stopPrank();
    }

    function _config() internal view returns (bytes memory raw) {
        bool ok;
        (ok, raw) = address(store).staticcall(abi.encodeCall(store.getOracleConfig, (address(lpOracle))));
        require(ok, "getOracleConfig");
    }

    function _leg(
        uint256 token,
        uint256 route,
        uint256 index
    ) internal view returns (uint8 count, OracleLeg memory l) {
        (bool ok, bytes memory ret) = address(fields)
            .staticcall(bytes.concat(abi.encodeWithSelector(fields.leg.selector), _withArgs(token, route, index)));
        require(ok, "leg");
        (count, l) = abi.decode(ret, (uint8, OracleLeg));
    }

    /// @dev The raw config bytes are the ABI encoding of one dynamic struct argument: head offset, then the struct.
    /// Further static arguments are appended to the head after the offset, so the offset is moved past them.
    function _withArgs(
        uint256 a,
        uint256 b,
        uint256 c
    ) internal view returns (bytes memory) {
        bytes memory raw = _config();
        // raw = [offset 0x20][struct...]; new head = [offset 0x80][a][b][c][struct...].
        bytes memory body = new bytes(raw.length - 32);
        for (uint256 i = 0; i < body.length; ++i) {
            body[i] = raw[i + 32];
        }
        return bytes.concat(abi.encode(uint256(0x80), a, b, c), body);
    }

    function _second(
        uint256 token
    ) internal view returns (address t, uint16 tol, SecondSource memory s) {
        bytes memory raw = _config();
        bytes memory body = new bytes(raw.length - 32);
        for (uint256 i = 0; i < body.length; ++i) {
            body[i] = raw[i + 32];
        }
        (bool ok, bytes memory ret) =
            address(fields).staticcall(bytes.concat(fields.second.selector, abi.encode(uint256(0x40), token), body));
        require(ok, "second");
        (t, tol, s) = abi.decode(ret, (address, uint16, SecondSource));
    }

    // TEST-250 verifies: REQ-CONFIG-072, REQ-CONFIG-023
    function test_TEST_250_everyLegCarriesItsPinnedDefinition() public {
        // USDT's alternate in force becomes two legs: its own alternate feed, then the 18-decimal leg.
        address[] memory alt = new address[](2);
        (alt[0], alt[1]) = (address(fUsdtAlt), address(leg2));
        registry.setActiveRoutes(usdt, _one(address(fUsdt)), alt);
        (uint8 count, OracleLeg memory l) = _leg(1, 1, 1);
        assertEq(count, 2);
        assertEq(l.aggregator, address(leg2));
        assertEq(l.decimals, 18);
        assertEq(l.heartbeat, 3600);
        assertEq(l.heartbeatMargin, 600);
        assertEq(l.feedDeviationThresholdBps, 40);
        assertEq(int256(l.minAnswer), 1e10);
        assertEq(int256(l.maxAnswer), 1e30);
        assertEq(l.borrowPriceMaxAge, 4200);
        assertEq(l.liquidationPriceMaxAge, 4200);
        (, OracleLeg memory first) = _leg(1, 1, 0);
        assertEq(first.aggregator, address(fUsdtAlt));
        assertEq(first.heartbeat, 86_400);
        // USDC's primary is one leg; its unused second leg is empty.
        (count, l) = _leg(0, 0, 1);
        assertEq(count, 1);
        assertEq(l.aggregator, address(0));
        assertEq(l.heartbeat, 0);
    }

    // TEST-250 verifies: REQ-CONFIG-072
    function test_TEST_250_routesOfOtherLengthsAreServedEmpty() public {
        address[] memory three = new address[](3);
        (three[0], three[1], three[2]) = (address(fUsdc), address(leg2), address(netA));
        registry.setActiveRoutes(usdc, new address[](0), three);
        (uint8 count, OracleLeg memory l) = _leg(0, 0, 0);
        assertEq(count, 0, "empty route served with legs");
        assertEq(l.aggregator, address(0));
        (count, l) = _leg(0, 1, 0);
        assertEq(count, 0, "three-leg route served with legs");
        assertEq(l.aggregator, address(0));
        // The inputs view counts the route as recorded but serves no leg of it.
        address[] memory toks = new address[](1);
        toks[0] = usdc;
        uint256[] memory w = store.getOracleInputs(address(lpOracle), toks, false);
        uint256 k = OracleInputsLayout.HEAD_WORDS;
        assertEq(w[k + 3], 0);
        assertEq(w[k + 4], 3);
        for (uint256 i = k + 5; i < w.length; ++i) {
            assertEq(w[i], 0, "leg word of an unusable route");
        }
    }

    // TEST-250 verifies: REQ-CONFIG-072, REQ-ORACLE-049
    function test_TEST_250_boundsSaturateIntoInt128OnlyInTheConfig() public {
        MockAggregator huge = new MockAggregator(8, 1e6, type(int192).max);
        _tl();
        store.setFeed(address(huge), _feedDef(3600, 600));
        registry.setActiveRoutes(usdc, _one(address(huge)), _one(address(fUsdcAlt)));
        (, OracleLeg memory l) = _leg(0, 0, 0);
        assertEq(l.maxAnswer, type(int128).max);
        assertEq(int256(l.minAnswer), 1e6);
        address[] memory toks = new address[](1);
        toks[0] = usdc;
        uint256[] memory w = store.getOracleInputs(address(lpOracle), toks, false);
        assertEq(int256(w[OracleInputsLayout.HEAD_WORDS + 5 + 3]), int256(type(int192).max));
    }

    // TEST-250 verifies: REQ-CONFIG-072, REQ-PSTORE-029, REQ-PSTORE-033
    function test_TEST_250_secondSourceInForceIsServed() public {
        SecondSource memory a = SecondSource(SecondSourceKind.OracleNetwork, address(netA), bytes32(0), 88_200, 0, 100);
        SecondSource memory b =
            SecondSource(SecondSourceKind.PoolTwap, address(integration), bytes32(uint256(9)), 0, 1800, 300);
        _tl();
        store.setSecondSource(usdt, a, b);
        (address t, uint16 tol, SecondSource memory s) = _second(1);
        assertEq(t, usdt);
        assertEq(tol, 150);
        assertEq(s.source, address(netA));
        assertEq(s.maxAge, 88_200);
        address[] memory toks = new address[](1);
        toks[0] = usdt;
        uint256[] memory w = store.getOracleInputs(address(lpOracle), toks, true);
        uint256 k = OracleInputsLayout.HEAD_WORDS + OracleInputsLayout.TOKEN_WORDS;
        assertEq(w[k], uint256(SecondSourceKind.OracleNetwork));
        assertEq(w[k + 1], uint160(address(netA)));
        assertEq(w[k + 5], 100);
        // The oracle network's pinned decimals and bounds come with it.
        assertEq(w[k + 6], 8);
        assertEq(w[k + 7], 2e6);
        assertEq(w[k + 8], 3e12);
        // The guardian puts the pool TWAP in force: served at once, with no feed words.
        vm.prank(emergencyGuardian);
        store.useStandbySecondSource(usdt);
        (,, s) = _second(1);
        assertEq(uint8(s.kind), uint8(SecondSourceKind.PoolTwap));
        assertEq(s.poolRef, bytes32(uint256(9)));
        assertEq(s.toleranceBps, 300);
        w = store.getOracleInputs(address(lpOracle), toks, true);
        assertEq(w[k], uint256(SecondSourceKind.PoolTwap));
        assertEq(w[k + 2], 9);
        assertEq(w[k + 4], 1800);
        assertEq(w[k + 6], 0);
        assertEq(w[k + 7], 0);
        assertEq(w[k + 8], 0);
    }

    // TEST-250 verifies: REQ-CONFIG-072, REQ-PSTORE-023, REQ-ORACLE-103
    function test_TEST_250_chainValuesAndConstants() public {
        _tl();
        store.setDisagreementPauseMax(900);
        _tl();
        store.setUsdBand(0.95e8, 1.05e8);
        (bool ok, bytes memory ret) = address(fields).staticcall(bytes.concat(fields.chain.selector, _config()));
        require(ok, "chain");
        (uint256 id, uint256 n, uint256 high, uint32 pause, address seq, uint16 maxQuote) =
            abi.decode(ret, (uint256, uint256, uint256, uint32, address, uint16));
        assertEq(id, M);
        assertEq(n, 2);
        assertEq(high, 1.05e8);
        assertEq(pause, 900);
        assertEq(seq, address(0));
        assertEq(maxQuote, 100);
    }
}
