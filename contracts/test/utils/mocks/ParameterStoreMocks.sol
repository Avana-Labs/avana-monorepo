// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IntegrationCapabilities, RiskStatus} from "../../../src/amm/types/AmmTypes.sol";
import {IAaveV4Hub} from "../../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {PledgeCounters, ShapeKind} from "../../../src/types/PositionTypes.sol";

/// @notice Code at a market's LPOracle address; the stateless LPOracle has no configuration the ParameterStore checks.
contract MockLPOracle {}

/// @notice AMM integration `capabilities` and `riskStatus` with settable answers.
contract MockIntegration {
    bool public hasTwap = true;

    /// @notice No rate tokens: two zero providers, as the concentrated-liquidity integrations report.
    function rateProviders(
        uint256
    ) external pure returns (address[] memory providers) {
        providers = new address[](2);
    }

    /// @notice Unit exponent 0: one vault-token unit is one unit of liquidity, as for every pool these suites list.
    function unitExponent(
        uint256
    ) external pure returns (uint8) {
        return 0;
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

/// @notice Chainlink aggregator proxy that is its own aggregator.
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

/// @notice First-Loss Reserve minimum.
contract MockAvanaFirstLossReserve {
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
