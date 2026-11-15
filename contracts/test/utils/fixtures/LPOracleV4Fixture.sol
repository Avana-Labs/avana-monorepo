// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IUniswapV4Integration} from "../../../src/amm/uniswap-v4/IUniswapV4Integration.sol";
import {UniswapV4PoolKey} from "../../../src/interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {ILPOracle} from "../../../src/oracle/lp-oracle/ILPOracle.sol";
import {LPOracleCLInitLogic} from "../../../src/oracle/lp-oracle/LPOracleCLInitLogic.sol";
import {LPOracleCLListingLogic} from "../../../src/oracle/lp-oracle/LPOracleCLListingLogic.sol";
import {LPOracleCLPokeLogic} from "../../../src/oracle/lp-oracle/LPOracleCLPokeLogic.sol";
import {LPOracleCLViewLogic} from "../../../src/oracle/lp-oracle/LPOracleCLViewLogic.sol";
import {LPOracleV4} from "../../../src/oracle/lp-oracle/LPOracleV4.sol";
import {LPOracleV4ModuleLogic} from "../../../src/oracle/lp-oracle/LPOracleV4ModuleLogic.sol";
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
import {ClTestToken, IClPool} from "./ClPoolFixture.sol";
import {UniswapV4WorldFixture} from "./UniswapV4WorldFixture.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice The integration views the v4 LPOracle reads: unit exponent, rate providers and the market's reference pool.
contract V4IntegrationStub {
    error MarketBinding(uint256 marketId);

    bool public bound;
    uint8 public unitExp;
    IUniswapV4Integration.V4Market internal _market;

    function setBound(
        bool b
    ) external {
        bound = b;
    }

    function setMarket(
        UniswapV4PoolKey memory key,
        address ref,
        uint8 k
    ) external {
        (_market.key, _market.referencePool, unitExp) = (key, ref, k);
    }

    function rateProviders(
        uint256 marketId
    ) external view returns (address[] memory providers) {
        if (!bound) revert MarketBinding(marketId);
        providers = new address[](2);
    }

    function unitExponent(
        uint256 marketId
    ) external view returns (uint8) {
        if (!bound) revert MarketBinding(marketId);
        return unitExp;
    }

    function v4Market(
        uint256 marketId
    ) external view returns (IUniswapV4Integration.V4Market memory) {
        if (!bound) revert MarketBinding(marketId);
        return _market;
    }
}

/// @title LPOracleV4Fixture
/// @notice A native ETH/USDC Uniswap v4 market priced by the real `LPOracleV4` on the local v4 world: one-leg primary
/// and alternate routes and an oracle-network second source per token (WETH stands for ETH), a 1,800 s window over the
/// WETH/USDC Uniswap v3 reference pool (151 observations at 12 s blocks), a 50-tick tolerance and a 1% quote-change
/// cap. Both pools sit at the oracle price.
abstract contract LPOracleV4Fixture is UniswapV4WorldFixture {
    uint32 internal constant BLOCK_TIME = 12;
    uint32 internal constant POKE_FLOOR = 900_000;
    uint32 internal constant POKE_CEILING = 3_000_000;
    uint256 internal constant MARKET = 1;
    uint256 internal constant T0 = 1_762_650_000;
    uint32 internal constant MAX_AGE = 88_200;
    uint32 internal constant WINDOW = 1800;
    uint16 internal constant TOLERANCE = 50;
    uint256 internal constant ETH = 3000e8;
    uint256 internal constant USD = 1e8;
    int24 internal constant LOWER = -207_000;
    int24 internal constant UPPER = -194_000;

    address internal tl = address(0x7173);
    V4IntegrationStub internal integration;
    OracleRegistryMock internal registry;
    OracleStoreMock internal store;
    ClTestToken internal usdc;
    PoolKey internal key;
    IClPool internal ref;
    OracleFeedMock[3] internal feeds0;
    OracleFeedMock[3] internal feeds1;
    LPOracleV4 internal implementation;
    LPOracleV4 internal oracle;
    uint256 internal price0;
    uint256 internal price1;

    function _deployV4Market() internal {
        vm.warp(T0 - 7200);
        vm.roll(100);
        _deployV4World();
        usdc = new ClTestToken("USDC", 6);
        key = _key(address(0), address(usdc), 500, 10);
        _initPool(key, ETH, USD, 18, 6);
        _mintV4(address(this), key, -887_270, 887_270, 1e18);
        ref = _referencePool(address(weth), address(usdc), ETH, USD, 151, 1e18);
        vm.warp(T0 - 3600);
        _touch(ref);
        vm.warp(T0);
        vm.roll(block.number + 1);
        (price0, price1) = (ETH, USD);
        integration = new V4IntegrationStub();
        integration.setMarket(_v4Key(), address(ref), 0);
        registry = new OracleRegistryMock();
        store = new OracleStoreMock();
        store.setRegistry(registry);
        for (uint256 i = 0; i < 3; ++i) {
            feeds0[i] = _feed(ETH);
            feeds1[i] = _feed(USD);
        }
        registry.setRoutes(address(weth), _one(address(feeds0[0])), _one(address(feeds0[1])), RouteSlot.None);
        registry.setRoutes(address(usdc), _one(address(feeds1[0])), _one(address(feeds1[1])), RouteSlot.None);
        store.setConfig(_config());
        implementation = _deployImplementation();
        oracle = LPOracleV4(
            address(new ERC1967Proxy(address(implementation), abi.encodeCall(ILPOracle.initialize, (_params()))))
        );
        vm.label(address(oracle), "LPOracleV4");
    }

    function _deployImplementation() internal returns (LPOracleV4) {
        address m = address(
            new LPOracleV4ModuleLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, address(weth))
        );
        LPOracleLogicSet memory logics = LPOracleLogicSet(
            address(new LPOracleCLPokeLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, m)),
            address(new LPOracleCLInitLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, m)),
            address(new LPOracleCLListingLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, m)),
            address(new LPOracleCLViewLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, m))
        );
        return new LPOracleV4(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, m, logics, address(weth));
    }

    function _v4Key() internal view returns (UniswapV4PoolKey memory k) {
        k = UniswapV4PoolKey(address(0), address(usdc), 500, 10, address(0));
    }

    function _feed(
        uint256 price
    ) internal returns (OracleFeedMock f) {
        f = new OracleFeedMock(8, 1, 1e18);
        f.push(int256(price), block.timestamp);
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
        c.usdBandLow = 0;
        c.usdBandHigh = type(uint256).max;
        c.cachedWindow = 3600;
        c.disagreementPauseMax = 3600;
        c.graceDuration = 1800;
        c.tokens = new TokenOracleConfig[](2);
        c.tokens[0] = _tokenConfig(address(weth), feeds0);
        c.tokens[1] = _tokenConfig(address(usdc), feeds1);
    }

    function _tokenConfig(
        address token,
        OracleFeedMock[3] memory f
    ) internal pure returns (TokenOracleConfig memory t) {
        t.token = token;
        t.routes[0] = _route(address(f[0]));
        t.routes[1] = _route(address(f[1]));
        t.feedAgreementToleranceBps = 150;
        t.secondSource = SecondSource({
            kind: SecondSourceKind.OracleNetwork,
            source: address(f[2]),
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

    function _market(
        UniswapV4PoolKey memory k,
        address refPool
    ) internal view returns (bytes memory) {
        return abi.encode(address(pm), k, LOWER, UPPER, uint256(0), refPool);
    }

    function _params() internal view returns (InitParams memory p) {
        p.timelock = tl;
        p.parameterStore = address(store);
        p.marketRegistry = address(registry);
        p.marketId = MARKET;
        p.integration = address(integration);
        p.isUsdStable = new bool[](2);
        p.isUsdStable[1] = true;
        p.description = "v4 market / USD";
        p.pokeMinGas = POKE_FLOOR;
        p.config = _config();
        p.market = _market(_v4Key(), address(ref));
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
        for (uint256 i = 0; i < 3; ++i) {
            feeds0[i].push(int256(q0), block.timestamp);
            feeds1[i].push(int256(q1), block.timestamp);
        }
    }

    function _state() internal view returns (PriceStateView memory v) {
        v = oracle.getPriceState();
    }

    function _assertState(
        PriceState expected
    ) internal view {
        assertEq(uint8(_state().state), uint8(expected), "state");
    }
}
