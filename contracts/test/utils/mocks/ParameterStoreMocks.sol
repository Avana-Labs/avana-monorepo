// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IntegrationCapabilities} from "../../../src/amm/types/IntegrationCapabilities.sol";
import {RiskStatus} from "../../../src/amm/types/RiskStatus.sol";
import {IAaveV4Hub} from "../../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {OracleConfig} from "../../../src/types/OracleConfig.sol";
import {PledgeCounters} from "../../../src/types/PledgeCounters.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";

/// @notice LPOracle `checkConfig` with a settable result; records nothing (the call is a view). Beside the fixed
/// bitmap `failed`, it can fail check `4` when the consistency tolerance is below a floor, check `8` when token 0's
/// feed-agreement tolerance is below a floor, and check `16` when a leg's borrow age is below a floor, so a test can
/// tell a check a setter's own write breaks from one that failed before it.
contract MockLPOracle {
    uint256 public failed;
    bool public reverts;
    uint16 public consistencyFloor;
    uint16 public toleranceFloor;
    uint32 public borrowAgeFloor;

    function setFloors(
        uint16 consistency,
        uint16 tolerance,
        uint32 borrowAge
    ) external {
        (consistencyFloor, toleranceFloor, borrowAgeFloor) = (consistency, tolerance, borrowAge);
    }

    function setFailed(
        uint256 f
    ) external {
        failed = f;
    }

    function setReverts(
        bool r
    ) external {
        reverts = r;
    }

    function checkConfig(
        OracleConfig calldata c
    ) external view returns (uint256 bits) {
        require(!reverts, "checkConfig");
        bits = failed;
        if (c.consistencyToleranceBps < consistencyFloor) bits |= 4;
        if (c.tokens.length != 0 && c.tokens[0].feedAgreementToleranceBps < toleranceFloor) bits |= 8;
        for (uint256 i = 0; i < c.tokens.length; ++i) {
            for (uint256 r = 0; r < 2; ++r) {
                for (uint256 l = 0; l < c.tokens[i].routes[r].legCount; ++l) {
                    if (c.tokens[i].routes[r].legs[l].borrowPriceMaxAge < borrowAgeFloor) bits |= 16;
                }
            }
        }
    }
}

/// @notice AMM integration `capabilities` and `riskStatus` with settable answers.
contract MockIntegration {
    bool public hasTwap = true;

    /// @notice No rate tokens: two zero providers, as the concentrated-liquidity integrations report.
    function rateProviders(
        uint256
    ) external pure returns (address[] memory providers) {
        providers = new address[](2);
    }

    bool public depthAvailable = true;
    bool public reverts;
    ShapeKind public shapeKind = ShapeKind.TickRange;

    function set(
        bool twap,
        bool depth,
        bool rev,
        ShapeKind kind
    ) external {
        (hasTwap, depthAvailable, reverts, shapeKind) = (twap, depth, rev, kind);
    }

    function capabilities() external view returns (IntegrationCapabilities memory c) {
        c.hasTwap = hasTwap;
        c.shapeKind = shapeKind;
    }

    function riskStatus(
        uint256,
        uint32
    ) external view returns (RiskStatus memory s) {
        require(!reverts, "OLD");
        s.depthAvailable = depthAvailable;
        s.depthUnits = 1;
    }
}

/// @notice Uniswap v3-shaped `slot0` (seven words) with a settable observation cardinality.
contract MockPool {
    uint16 public cardinality = 1000;

    function setCardinality(
        uint16 c
    ) external {
        cardinality = c;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (2 ** 96, 0, 0, cardinality, cardinality, 0, true);
    }
}

/// @notice Chainlink aggregator proxy that is its own aggregator, also usable as a sequencer-uptime feed.
contract MockAggregator {
    uint8 public decimals;
    int192 public minAnswer;
    int192 public maxAnswer;
    int256 public answer;
    uint256 public startedAt = 1;

    constructor(
        uint8 d,
        int192 lo,
        int192 hi
    ) {
        (decimals, minAnswer, maxAnswer) = (d, lo, hi);
    }

    function setBounds(
        uint8 d,
        int192 lo,
        int192 hi
    ) external {
        (decimals, minAnswer, maxAnswer) = (d, lo, hi);
    }

    function setRound(
        int256 a,
        uint256 s
    ) external {
        (answer, startedAt) = (a, s);
    }

    function aggregator() external view returns (address) {
        return address(this);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, block.timestamp, 1);
    }
}

/// @notice Aave V4 Hub views: asset ids by underlying, Spoke `addCap`, `MAX_ALLOWED_SPOKE_CAP`.
contract MockHub {
    mapping(address => uint256) public assetIds;
    mapping(address => bool) public listed;
    uint40 public addCap;

    function setAsset(
        address underlying,
        uint256 id
    ) external {
        assetIds[underlying] = id;
        listed[underlying] = true;
    }

    function setAddCap(
        uint40 c
    ) external {
        addCap = c;
    }

    function getAssetId(
        address underlying
    ) external view returns (uint256) {
        require(listed[underlying], "not listed");
        return assetIds[underlying];
    }

    function getSpokeConfig(
        uint256,
        address
    ) external view returns (IAaveV4Hub.SpokeConfig memory c) {
        c.addCap = addCap;
        c.active = true;
    }

    function MAX_ALLOWED_SPOKE_CAP() external pure returns (uint40) {
        return type(uint40).max;
    }
}

/// @notice Aave V4 Spoke views of one collateral reserve and the Spoke's liquidation configuration.
contract MockSpoke {
    uint32 public maxLiquidationBonus = 10_500;
    uint16 public bonusFactor = 4000;
    bool public reverts;

    function setBonus(
        uint32 maxLb,
        uint16 factor
    ) external {
        (maxLiquidationBonus, bonusFactor) = (maxLb, factor);
    }

    function setReverts(
        bool r
    ) external {
        reverts = r;
    }

    function getReserveId(
        address,
        uint256 assetId
    ) external view returns (uint256) {
        require(!reverts, "no reserve");
        return assetId + 100;
    }

    function getReserve(
        uint256
    ) external pure returns (IAaveV4Spoke.Reserve memory r) {
        r.dynamicConfigKey = 3;
    }

    function getDynamicReserveConfig(
        uint256,
        uint32 key
    ) external view returns (IAaveV4Spoke.DynamicReserveConfig memory d) {
        require(key == 3, "key");
        d.maxLiquidationBonus = maxLiquidationBonus;
        d.collateralFactor = 3000;
    }

    function getLiquidationConfig() external view returns (IAaveV4Spoke.LiquidationConfig memory c) {
        c.targetHealthFactor = 1.1e18;
        c.liquidationBonusFactor = bonusFactor;
    }
}

/// @notice Collateralization `getCounters` with settable market counters.
contract MockCollateralization {
    uint128 public regularUsed;
    uint128 public sliceUsed;

    function setUsed(
        uint128 r,
        uint128 s
    ) external {
        (regularUsed, sliceUsed) = (r, s);
    }

    function getCounters(
        address,
        address
    ) external view returns (PledgeCounters memory c) {
        c.regularUsed = regularUsed;
        c.sliceUsed = sliceUsed;
    }
}

/// @notice Coverage Spoke minimum.
contract MockCoverageSpoke {
    uint256 public firstLossReserveMinimum;

    function setMinimum(
        uint256 m
    ) external {
        firstLossReserveMinimum = m;
    }
}

/// @notice Aave price source with a settable 8-decimal answer.
contract MockPriceSource {
    int256 public latestAnswer;

    function setAnswer(
        int256 a
    ) external {
        latestAnswer = a;
    }
}

/// @notice Vault token supply.
contract MockVaultToken {
    uint256 public totalSupply;

    function setSupply(
        uint256 s
    ) external {
        totalSupply = s;
    }
}

/// @notice A contract reporting an `ADAPTER()`, as a PositionProxy does.
contract MockPositionProxy {
    address public ADAPTER;

    constructor(
        address adapter
    ) {
        ADAPTER = adapter;
    }
}

/// @notice A contract reporting a PositionProxy's bindings but another `ADAPTER()`, so only the ProxyManager's
/// `predictProxy` can show it is a proxy.
contract MockProxyBindings {
    address public ADAPTER = address(0xBAD);
    address public WALLET;
    address public SPOKE;
    uint256 public MARKET_ID;

    constructor(
        address wallet,
        address spoke,
        uint256 marketId
    ) {
        (WALLET, SPOKE, MARKET_ID) = (wallet, spoke, marketId);
    }
}

/// @notice ProxyManager `predictProxy` answering one recorded (wallet, spoke, marketId) with a fixed address.
contract MockProxyManager {
    bytes32 internal _key;
    address internal _predicted;

    function setPrediction(
        address wallet,
        address spoke,
        uint256 marketId,
        address predicted
    ) external {
        (_key, _predicted) = (keccak256(abi.encode(wallet, spoke, marketId)), predicted);
    }

    function predictProxy(
        address wallet,
        address spoke,
        uint256 marketId
    ) external view returns (address) {
        return keccak256(abi.encode(wallet, spoke, marketId)) == _key ? _predicted : address(1);
    }
}

/// @notice A contract answering `TIMELOCK()` or `MARKET_REGISTRY()`, as every upgradeable Avana contract does.
contract MockAvanaComponent {
    address public TIMELOCK;
    address public MARKET_REGISTRY;

    constructor(
        address timelock,
        address registry
    ) {
        (TIMELOCK, MARKET_REGISTRY) = (timelock, registry);
    }
}

/// @notice Fields of an `OracleConfig` the ParameterStore tests compare, read from calldata.
struct OracleConfigSummary {
    uint256 marketId;
    uint256 tokenCount;
    address token0;
    uint8 legCount00;
    address aggregator00;
    uint32 heartbeat00;
    uint16 margin00;
    uint32 borrowAge00;
    int128 maxAnswer00;
    uint8 legCount10;
    uint16 tolerance0;
    uint32 twapWindow;
    uint16 twapMinObservations;
    uint16 consistencyToleranceBps;
    uint16 maxQuoteChangeBps;
    uint256 usdBandLow;
    uint32 cachedWindow;
    uint32 graceDuration;
    uint32 sequencerGrace;
}

/// @notice Reads an `OracleConfig` from calldata, where decoding is lazy; a test forwards the raw return bytes of
/// `getOracleConfig` to `summary` (the two encodings are identical), since decoding the whole nested struct into
/// memory exceeds the legacy code generator's stack.
contract OracleConfigReader {
    function summary(
        OracleConfig calldata c
    ) external pure returns (OracleConfigSummary memory s) {
        s.marketId = c.marketId;
        s.tokenCount = c.tokens.length;
        if (s.tokenCount > 0) {
            s.token0 = c.tokens[0].token;
            s.legCount00 = c.tokens[0].routes[0].legCount;
            s.aggregator00 = c.tokens[0].routes[0].legs[0].aggregator;
            s.heartbeat00 = c.tokens[0].routes[0].legs[0].heartbeat;
            s.margin00 = c.tokens[0].routes[0].legs[0].heartbeatMargin;
            s.borrowAge00 = c.tokens[0].routes[0].legs[0].borrowPriceMaxAge;
            s.maxAnswer00 = c.tokens[0].routes[0].legs[0].maxAnswer;
            s.tolerance0 = c.tokens[0].feedAgreementToleranceBps;
        }
        if (s.tokenCount > 1) s.legCount10 = c.tokens[1].routes[0].legCount;
        s.twapWindow = c.twapWindow;
        s.twapMinObservations = c.twapMinObservations;
        s.consistencyToleranceBps = c.consistencyToleranceBps;
        s.maxQuoteChangeBps = c.maxQuoteChangeBps;
        s.usdBandLow = c.usdBandLow;
        s.cachedWindow = c.cachedWindow;
        s.graceDuration = c.graceDuration;
        s.sequencerGrace = c.sequencer.gracePeriod;
    }
}
