// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracle} from "../../../src/oracle/lp-oracle/ILPOracle.sol";
import {InitParams} from "../../../src/oracle/lp-oracle/types/InitParams.sol";
import {FeedDef} from "../../../src/policy/parameter-store/types/FeedDef.sol";
import {OracleConfig} from "../../../src/types/OracleConfig.sol";
import {OracleLeg} from "../../../src/types/OracleLeg.sol";
import {OracleRoute} from "../../../src/types/OracleRoute.sol";
import {PriceState} from "../../../src/types/PriceState.sol";
import {PriceStateView} from "../../../src/types/PriceStateView.sol";
import {RouteSlot} from "../../../src/types/RouteSlot.sol";
import {SecondSource} from "../../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../../src/types/SecondSourceKind.sol";
import {TokenOracleConfig} from "../../../src/types/TokenOracleConfig.sol";
import {AvanaTest} from "../AvanaTest.sol";
import {LPOracleHarness, LPOracleHarnessDeployer} from "../harness/LPOracleHarness.sol";
import {OracleFeedMock, OracleRegistryMock, OracleStoreMock, OracleTokenMock} from "../mocks/LPOracleMocks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice A two-token USD-stable market priced by `LPOracleHarness`: tokens A and B (6 decimals), one-leg primary
/// and alternate routes per token (8-decimal feeds, heartbeat 86,400 s, margin 1,800 s), an oracle-network second
/// source per token, launch timers (cached 3,600 s, pause 3,600 s, grace 1,800 s), band 0.90 / 1.02 and a linear
/// composition of one raw unit per vault-token unit, so `d = 6` and one whole vault token at $1 per token is worth
/// `2 * (10^6 - 1) * 10^8 / 10^6 = 199,999,800`.
abstract contract LPOracleFixture is AvanaTest {
    uint32 internal constant BLOCK_TIME = 12;
    /// @dev `POKE_MIN_GAS_FLOOR` of a two-token implementation (`SPEC-ORC-023`): 900,000, provisional until the fork
    /// calibration that is a launch requirement.
    uint32 internal constant POKE_FLOOR = 900_000;
    uint32 internal constant POKE_CEILING = 3_000_000;
    uint256 internal constant MARKET = 1;
    uint256 internal constant T0 = 1_762_650_000;
    uint256 internal constant ONE = 1e8;
    uint256 internal constant SEEDED = 199_999_800;
    uint32 internal constant MAX_AGE = 88_200;

    address internal tl = address(0x7173);
    address internal integrationAddr = address(0x1A7E);
    OracleRegistryMock internal registry;
    OracleStoreMock internal store;
    OracleTokenMock internal tokenA;
    OracleTokenMock internal tokenB;
    OracleFeedMock internal pA;
    OracleFeedMock internal aA;
    OracleFeedMock internal pB;
    OracleFeedMock internal aB;
    OracleFeedMock internal sA;
    OracleFeedMock internal sB;
    OracleFeedMock internal seqFeed;
    LPOracleHarness internal implementation;
    LPOracleHarness internal oracle;
    bool internal withSequencer;

    function _deployMarket() internal {
        _deployMarket(false);
    }

    function _deployMarket(
        bool hasSequencer
    ) internal {
        vm.warp(T0);
        vm.roll(100);
        registry = new OracleRegistryMock();
        store = new OracleStoreMock();
        store.setRegistry(registry);
        tokenA = new OracleTokenMock(6);
        tokenB = new OracleTokenMock(6);
        pA = _feed("pA");
        aA = _feed("aA");
        pB = _feed("pB");
        aB = _feed("aB");
        sA = _feed("sA");
        sB = _feed("sB");
        seqFeed = new OracleFeedMock(0, 0, 2);
        registry.setRoutes(address(tokenA), _one(address(pA)), _one(address(aA)), RouteSlot.None);
        registry.setRoutes(address(tokenB), _one(address(pB)), _one(address(aB)), RouteSlot.None);
        withSequencer = hasSequencer;
        store.setConfig(_config());
        implementation = LPOracleHarnessDeployer.deploy(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, hasSequencer);
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(ILPOracle.initialize, (_params())));
        oracle = LPOracleHarness(address(proxy));
        vm.label(address(oracle), "LPOracle");
    }

    function _feed(
        string memory label
    ) internal returns (OracleFeedMock f) {
        f = new OracleFeedMock(8, 1, 1e12);
        f.push(int256(ONE), T0);
        vm.label(address(f), label);
        FeedDef memory d;
        d.decimals = 8;
        d.minAnswer = 1;
        d.maxAnswer = 1e12;
        d.feedHeartbeat = 86_400;
        d.heartbeatMargin = 1800;
        d.feedMaxAge = MAX_AGE;
        d.feedDeviationThresholdBps = 25;
        d.borrowPriceMaxAge = MAX_AGE;
        d.liquidationPriceMaxAge = MAX_AGE;
        store.setFeed(address(f), d);
    }

    /// @dev The launch configuration of the market.
    function _config() internal view returns (OracleConfig memory c) {
        c.marketId = MARKET;
        c.twapWindow = 1800;
        c.twapMinObservations = 151;
        c.consistencyToleranceBps = 50;
        c.maxQuoteChangeBps = 100;
        c.usdBandLow = 0.9e8;
        c.usdBandHigh = 1.02e8;
        c.cachedWindow = 3600;
        c.disagreementPauseMax = 3600;
        c.graceDuration = 1800;
        if (withSequencer) {
            c.sequencer.feed = address(seqFeed);
            c.sequencer.gracePeriod = 3600;
        }
        c.tokens = new TokenOracleConfig[](2);
        c.tokens[0] = _tokenConfig(address(tokenA), address(pA), address(aA), address(sA));
        c.tokens[1] = _tokenConfig(address(tokenB), address(pB), address(aB), address(sB));
    }

    function _tokenConfig(
        address token,
        address primary,
        address alternate,
        address second
    ) internal pure returns (TokenOracleConfig memory t) {
        t.token = token;
        t.routes[0] = _route(primary);
        t.routes[1] = _route(alternate);
        t.feedAgreementToleranceBps = 150;
        t.secondSource = SecondSource({
            kind: SecondSourceKind.OracleNetwork,
            source: second,
            poolRef: bytes32(0),
            maxAge: MAX_AGE,
            twapWindow: 0,
            toleranceBps: 100
        });
    }

    function _route(
        address feed
    ) internal pure returns (OracleRoute memory r) {
        r.legCount = 1;
        r.legs[0] = OracleLeg({
            aggregator: feed,
            decimals: 8,
            heartbeat: 86_400,
            heartbeatMargin: 1800,
            feedDeviationThresholdBps: 25,
            minAnswer: 1,
            maxAnswer: 1e12,
            borrowPriceMaxAge: MAX_AGE,
            liquidationPriceMaxAge: MAX_AGE
        });
    }

    function _params() internal view returns (InitParams memory p) {
        p.timelock = tl;
        p.parameterStore = address(store);
        p.marketRegistry = address(registry);
        p.marketId = MARKET;
        p.integration = integrationAddr;
        p.isUsdStable = new bool[](2);
        p.isUsdStable[0] = true;
        p.isUsdStable[1] = true;
        p.description = "USDC/USDT [-10,10] / USD";
        p.pokeMinGas = POKE_FLOOR;
        p.config = _config();
        uint256[] memory c = new uint256[](2);
        (c[0], c[1]) = (1e18, 1e18);
        p.market = abi.encode(c);
    }

    function _one(
        address a
    ) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function _two(
        address a,
        address b
    ) internal pure returns (address[] memory list) {
        list = new address[](2);
        (list[0], list[1]) = (a, b);
    }

    /// @dev Publishes `answer` at `at` on every feed (primaries, alternates and second sources).
    function _pushAll(
        int256 answer,
        uint256 at
    ) internal {
        pA.push(answer, at);
        aA.push(answer, at);
        pB.push(answer, at);
        aB.push(answer, at);
        sA.push(answer, at);
        sB.push(answer, at);
    }

    function _state() internal view returns (PriceStateView memory v) {
        v = oracle.getPriceState();
    }

    function _has(
        uint256 reasons,
        uint256 bit
    ) internal pure returns (bool) {
        return reasons & (1 << bit) != 0;
    }

    function _assertState(
        PriceState expected
    ) internal view {
        assertEq(uint8(_state().state), uint8(expected), "state");
    }
}
