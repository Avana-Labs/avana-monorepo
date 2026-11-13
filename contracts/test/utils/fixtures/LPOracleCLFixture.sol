// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {ILPOracle} from "../../../src/oracle/lp-oracle/ILPOracle.sol";
import {LPOracleCL} from "../../../src/oracle/lp-oracle/LPOracleCL.sol";
import {LPOracleCLInitLogic} from "../../../src/oracle/lp-oracle/LPOracleCLInitLogic.sol";
import {LPOracleCLListingLogic} from "../../../src/oracle/lp-oracle/LPOracleCLListingLogic.sol";
import {LPOracleCLModuleLogic} from "../../../src/oracle/lp-oracle/LPOracleCLModuleLogic.sol";
import {LPOracleCLPokeLogic} from "../../../src/oracle/lp-oracle/LPOracleCLPokeLogic.sol";
import {LPOracleCLViewLogic} from "../../../src/oracle/lp-oracle/LPOracleCLViewLogic.sol";
import {InitParams} from "../../../src/oracle/lp-oracle/types/InitParams.sol";
import {LPOracleLogicSet} from "../../../src/oracle/lp-oracle/types/LPOracleLogicSet.sol";
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
import {OracleFeedMock, OracleRegistryMock, OracleStoreMock} from "../mocks/LPOracleMocks.sol";
import {ClPoolFixture, ClTestToken, IClPool} from "./ClPoolFixture.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Deploys the concentrated-liquidity LPOracle implementation with its three logic contracts.
library LPOracleCLDeployer {
    function deploy(
        address timelock,
        uint32 chainBlockTime,
        uint32 floor,
        uint32 ceiling,
        bool hasSequencer,
        uint8 slot0Words
    ) internal returns (LPOracleCL) {
        address m =
            address(new LPOracleCLModuleLogic(timelock, chainBlockTime, floor, ceiling, hasSequencer, slot0Words));
        return deploy(timelock, chainBlockTime, floor, ceiling, hasSequencer, slot0Words, m);
    }

    function deploy(
        address timelock,
        uint32 chainBlockTime,
        uint32 floor,
        uint32 ceiling,
        bool hasSequencer,
        uint8 slot0Words,
        address moduleLogic
    ) internal returns (LPOracleCL) {
        address poke = address(
            new LPOracleCLPokeLogic(timelock, chainBlockTime, floor, ceiling, hasSequencer, slot0Words, moduleLogic)
        );
        address listing = address(
            new LPOracleCLListingLogic(timelock, chainBlockTime, floor, ceiling, hasSequencer, slot0Words, moduleLogic)
        );
        address init = address(
            new LPOracleCLInitLogic(timelock, chainBlockTime, floor, ceiling, hasSequencer, slot0Words, moduleLogic)
        );
        address views = address(
            new LPOracleCLViewLogic(timelock, chainBlockTime, floor, ceiling, hasSequencer, slot0Words, moduleLogic)
        );
        return new LPOracleCL(
            timelock,
            chainBlockTime,
            floor,
            ceiling,
            hasSequencer,
            slot0Words,
            moduleLogic,
            LPOracleLogicSet(poke, init, listing, views)
        );
    }
}

/// @notice The market's integration as the LPOracle reads it at listing: `rateProviders(marketId)` (`REQ-AMM-CORE-004`).
/// @dev The Uniswap v3 and Slipstream integrations return two zero addresses (their own suites check it); a test sets
/// a provider to check that the oracle refuses a rate token.
contract ClIntegrationStub {
    error MarketBinding(uint256 marketId);

    address[2] internal _providers;
    bool public bound;

    /// @notice Binds the market, as the integration's `bindMarket` does inside `listCollateralMarket`.
    function setBound(
        bool b
    ) external {
        bound = b;
    }

    function setProvider(
        uint256 i,
        address p
    ) external {
        _providers[i] = p;
    }

    function rateProviders(
        uint256 marketId
    ) external view returns (address[] memory providers) {
        if (!bound) revert MarketBinding(marketId);
        providers = new address[](2);
        (providers[0], providers[1]) = (_providers[0], _providers[1]);
    }
}

/// @notice A concentrated-liquidity market on a real Uniswap v3 pool priced by the real `LPOracleCL`: two tokens with
/// one-leg primary and alternate routes (8-decimal feeds, heartbeat 86,400 s, margin 1,800 s, bounds `[1, 10^18]`) and
/// an oracle-network second source each, served through the ParameterStore and MarketRegistry mocks (their own suites
/// test the real ones), launch timers, a 1,800 s TWAP window with 151 observations at 12 s blocks and a 50-tick
/// tolerance. The pool is created two hours before `T0` at the oracle price and holds full-range liquidity.
abstract contract LPOracleCLFixture is ClPoolFixture {
    uint32 internal constant BLOCK_TIME = 12;
    uint32 internal constant POKE_FLOOR = 900_000;
    uint32 internal constant POKE_CEILING = 3_000_000;
    uint256 internal constant MARKET = 1;
    uint256 internal constant T0 = 1_762_650_000;
    uint32 internal constant MAX_AGE = 88_200;
    uint32 internal constant WINDOW = 1800;
    uint16 internal constant TOLERANCE = 50;

    struct MarketSpec {
        string symA;
        uint8 decA;
        uint256 priceA;
        bool stableA;
        string symB;
        uint8 decB;
        uint256 priceB;
        bool stableB;
        uint24 fee;
        // Range offset from the pool's full range: 0 for full range, else the exact ticks below.
        bool fullRange;
        int24 tickLower;
        int24 tickUpper;
        uint128 poolLiquidity;
    }

    address internal tl = address(0x7173);
    ClIntegrationStub internal integration;
    OracleRegistryMock internal registry;
    OracleStoreMock internal store;
    ClTestToken internal token0;
    ClTestToken internal token1;
    IClPool internal pool;
    OracleFeedMock internal p0Feed;
    OracleFeedMock internal a0Feed;
    OracleFeedMock internal s0Feed;
    OracleFeedMock internal p1Feed;
    OracleFeedMock internal a1Feed;
    OracleFeedMock internal s1Feed;
    LPOracleCL internal implementation;
    LPOracleCL internal oracle;
    bool[2] internal stable;
    int24 internal tickLower;
    int24 internal tickUpper;
    uint256 internal price0;
    uint256 internal price1;

    function _usdcUsdt() internal pure returns (MarketSpec memory s) {
        s = MarketSpec("USDC", 6, 1e8, true, "USDT", 6, 1e8, true, 100, false, -10, 10, 1e15);
    }

    function _ethUsdc() internal pure returns (MarketSpec memory s) {
        s = MarketSpec("WETH", 18, 3000e8, false, "USDC", 6, 1e8, true, 500, true, 0, 0, 1e18);
    }

    function _wbtcEth() internal pure returns (MarketSpec memory s) {
        s = MarketSpec("WBTC", 8, 100_000e8, false, "WETH", 18, 3000e8, false, 3000, true, 0, 0, 1e15);
    }

    /// @dev Pool, feeds, configuration and the initialized LPOracle proxy for `s`.
    function _deployClMarket(
        MarketSpec memory s
    ) internal {
        vm.warp(T0 - 7200);
        vm.roll(100);
        _deployFactory();
        (ClTestToken a, ClTestToken b, bool aFirst) = _sortedTokens(s.symA, s.decA, s.symB, s.decB);
        (token0, token1) = aFirst ? (a, b) : (b, a);
        (price0, price1) = aFirst ? (s.priceA, s.priceB) : (s.priceB, s.priceA);
        (stable[0], stable[1]) = aFirst ? (s.stableA, s.stableB) : (s.stableB, s.stableA);
        pool = _createPool(token0, token1, s.fee, price0, price1, 151, s.poolLiquidity);
        int24 sp = pool.tickSpacing();
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 top = (ClPriceMath.MAX_TICK / sp) * sp;
        (tickLower, tickUpper) = s.fullRange ? (-top, top) : (s.tickLower, s.tickUpper);
        vm.warp(T0 - 3600);
        _touch(pool);
        vm.warp(T0);
        vm.roll(block.number + 1);
        integration = new ClIntegrationStub();
        registry = new OracleRegistryMock();
        store = new OracleStoreMock();
        store.setRegistry(registry);
        p0Feed = _feed("p0", price0);
        a0Feed = _feed("a0", price0);
        s0Feed = _feed("s0", price0);
        p1Feed = _feed("p1", price1);
        a1Feed = _feed("a1", price1);
        s1Feed = _feed("s1", price1);
        registry.setRoutes(address(token0), _one(address(p0Feed)), _one(address(a0Feed)), RouteSlot.None);
        registry.setRoutes(address(token1), _one(address(p1Feed)), _one(address(a1Feed)), RouteSlot.None);
        store.setConfig(_config());
        implementation = LPOracleCLDeployer.deploy(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7);
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(ILPOracle.initialize, (_params())));
        oracle = LPOracleCL(address(proxy));
        vm.label(address(oracle), "LPOracleCL");
    }

    function _feed(
        string memory label,
        uint256 price
    ) internal returns (OracleFeedMock f) {
        f = new OracleFeedMock(8, 1, 1e18);
        f.push(int256(price), block.timestamp);
        vm.label(address(f), label);
        FeedDef memory d;
        d.decimals = 8;
        d.minAnswer = 1;
        d.maxAnswer = 1e18;
        d.feedHeartbeat = 86_400;
        d.heartbeatMargin = 1800;
        d.feedMaxAge = MAX_AGE;
        d.feedDeviationThresholdBps = 25;
        d.borrowPriceMaxAge = MAX_AGE;
        d.liquidationPriceMaxAge = MAX_AGE;
        store.setFeed(address(f), d);
    }

    function _config() internal view returns (OracleConfig memory c) {
        c.marketId = MARKET;
        c.twapWindow = WINDOW;
        c.twapMinObservations = 151;
        c.consistencyToleranceBps = TOLERANCE;
        c.maxQuoteChangeBps = 100;
        bool allStable = stable[0] && stable[1];
        c.usdBandLow = allStable ? 0.9e8 : 0;
        c.usdBandHigh = allStable ? 1.02e8 : type(uint256).max;
        c.cachedWindow = 3600;
        c.disagreementPauseMax = 3600;
        c.graceDuration = 1800;
        c.tokens = new TokenOracleConfig[](2);
        c.tokens[0] = _tokenConfig(address(token0), address(p0Feed), address(a0Feed), address(s0Feed));
        c.tokens[1] = _tokenConfig(address(token1), address(p1Feed), address(a1Feed), address(s1Feed));
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
            maxAnswer: 1e18,
            borrowPriceMaxAge: MAX_AGE,
            liquidationPriceMaxAge: MAX_AGE
        });
    }

    function _params() internal view returns (InitParams memory p) {
        p.timelock = tl;
        p.parameterStore = address(store);
        p.marketRegistry = address(registry);
        p.marketId = MARKET;
        p.integration = address(integration);
        p.isUsdStable = new bool[](2);
        (p.isUsdStable[0], p.isUsdStable[1]) = (stable[0], stable[1]);
        p.description = "CL market / USD";
        p.pokeMinGas = POKE_FLOOR;
        p.config = _config();
        p.market = abi.encode(address(pool), tickLower, tickUpper);
    }

    function _one(
        address a
    ) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    /// @dev Publishes `q0` and `q1` on every feed of each token at the current time.
    function _setPrices(
        uint256 q0,
        uint256 q1
    ) internal {
        (price0, price1) = (q0, q1);
        p0Feed.push(int256(q0), block.timestamp);
        a0Feed.push(int256(q0), block.timestamp);
        s0Feed.push(int256(q0), block.timestamp);
        p1Feed.push(int256(q1), block.timestamp);
        a1Feed.push(int256(q1), block.timestamp);
        s1Feed.push(int256(q1), block.timestamp);
    }

    /// @dev The pool's square-root price at the oracle prices `q0`, `q1`.
    function _oracleSqrt(
        uint256 q0,
        uint256 q1
    ) internal view returns (uint160) {
        return ClPriceMath.oracleSqrtPrice(q0, q1, token0.decimals(), token1.decimals());
    }

    /// @dev USD value, 8 decimals, of raw amounts at the current oracle prices.
    function _usd(
        uint256 a0,
        uint256 a1
    ) internal view returns (uint256) {
        return a0 * price0 / 10 ** token0.decimals() + a1 * price1 / 10 ** token1.decimals();
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
