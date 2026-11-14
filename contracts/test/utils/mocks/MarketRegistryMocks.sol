// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IntegrationCapabilities} from "../../../src/amm/types/IntegrationCapabilities.sol";
import {PoolKeying} from "../../../src/amm/types/PoolKeying.sol";
import {FeedDef} from "../../../src/policy/parameter-store/types/FeedDef.sol";
import {MarketParams} from "../../../src/policy/parameter-store/types/MarketParams.sol";
import {OracleConfig} from "../../../src/types/OracleConfig.sol";
import {PositionShape} from "../../../src/types/PositionShape.sol";
import {PriceState} from "../../../src/types/PriceState.sol";
import {PriceStateView} from "../../../src/types/PriceStateView.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";

/// @title RegistryParameterStoreMock
/// @notice The ParameterStore views the MarketRegistry reads, backed by settable storage.
contract RegistryParameterStoreMock {
    mapping(address => FeedDef) internal _feeds;
    mapping(address => uint16) public debtStressRiseBps;
    mapping(address => uint16) public feedAgreementToleranceBps;
    mapping(address => uint16) public feedAgreementToleranceMinBps;
    mapping(uint256 => MarketParams) internal _params;
    mapping(uint256 => uint256) public marketUsdCap;
    mapping(uint256 => uint256) public topUpSliceUsd;
    mapping(uint256 => uint256) public stressFloorUsd;
    mapping(address => uint256) public aaveTargetHealthFactor;
    mapping(address => uint16) public minLiquidationBonus;
    mapping(bytes32 => bool) public livenessFails;
    uint16 public maxFlashFeeBps = 10;
    uint16 public coverageRatioBps = 2000;
    bool public oracleConfigReverts;

    function setFeed(
        address feed,
        uint8 decimals,
        uint32 heartbeat,
        uint16 deviationBps,
        uint16 driftBps
    ) external {
        FeedDef storage f = _feeds[feed];
        f.decimals = decimals;
        f.feedHeartbeat = heartbeat;
        f.feedDeviationThresholdBps = deviationBps;
        f.heartbeatDriftBps = driftBps;
    }

    function getFeed(
        address feed
    ) external view returns (FeedDef memory) {
        return _feeds[feed];
    }

    function setStressRise(
        address asset,
        uint16 v
    ) external {
        debtStressRiseBps[asset] = v;
    }

    function setTolerance(
        address token,
        uint16 value,
        uint16 min
    ) external {
        feedAgreementToleranceBps[token] = value;
        feedAgreementToleranceMinBps[token] = min;
    }

    function setMaxFlashFeeBps(
        uint16 v
    ) external {
        maxFlashFeeBps = v;
    }

    function setCoverageRatioBps(
        uint16 v
    ) external {
        coverageRatioBps = v;
    }

    function setMarket(
        uint256 id,
        uint16 poolRiskFactor,
        uint256 minPledgeUsd,
        uint256 capUsd,
        uint256 sliceUsd,
        uint256 floorUsd
    ) external {
        _params[id].poolRiskFactor = poolRiskFactor;
        _params[id].minPledgeUsd = minPledgeUsd;
        marketUsdCap[id] = capUsd;
        topUpSliceUsd[id] = sliceUsd;
        stressFloorUsd[id] = floorUsd;
    }

    function setLiquidationExpectations(
        address spoke,
        uint256 target,
        uint16 minBonus
    ) external {
        aaveTargetHealthFactor[spoke] = target;
        minLiquidationBonus[spoke] = minBonus;
    }

    function setLivenessFails(
        address spoke,
        uint256 marketId,
        uint256 reserveId,
        bool fails
    ) external {
        livenessFails[keccak256(abi.encode(spoke, marketId, reserveId))] = fails;
    }

    function setOracleConfigReverts(
        bool r
    ) external {
        oracleConfigReverts = r;
    }

    function getMarketParams(
        uint256 id
    ) external view returns (MarketParams memory) {
        return _params[id];
    }

    function liquidationLivenessHolds(
        address spoke,
        uint256 marketId,
        uint256 reserveId
    ) external view returns (bool) {
        return !livenessFails[keccak256(abi.encode(spoke, marketId, reserveId))];
    }

    function getOracleConfig(
        address
    ) external view returns (OracleConfig memory config) {
        require(!oracleConfigReverts, "NoConfig");
        config.marketId = 1;
        config.twapWindow = 1800;
    }
}

/// @title RegistryRiskModuleMock
/// @notice The RiskModule calls of the MarketRegistry: the drift check (reverting on demand), the Hub-share check, the
/// expected collateral factor and the live security reasons.
contract RegistryRiskModuleMock {
    bool public driftReverts;
    bool public sharesEqual = true;
    uint256 public cfLp = 8000;
    mapping(uint256 => uint32) public liveBreakerReasons;
    mapping(bytes32 => uint32) internal _liveDebt;
    uint256 public driftChecks;
    uint256 public driftMarket;

    error ConfigDrift();

    function setDrift(
        bool r
    ) external {
        driftReverts = r;
    }

    /// @notice Makes the drift check revert only when the checked ids include `marketId` (0: never).
    function setDriftMarket(
        uint256 marketId
    ) external {
        driftMarket = marketId;
    }

    function setSharesEqual(
        bool e
    ) external {
        sharesEqual = e;
    }

    function setCfLp(
        uint256 cf
    ) external {
        cfLp = cf;
    }

    function setLive(
        uint256 marketId,
        uint32 reasons
    ) external {
        liveBreakerReasons[marketId] = reasons;
    }

    function setLiveDebt(
        address spoke,
        uint256 id,
        uint32 reasons
    ) external {
        _liveDebt[keccak256(abi.encode(spoke, id))] = reasons;
    }

    function liveDebtBreakerReasons(
        address spoke,
        uint256 id
    ) external view returns (uint32) {
        return _liveDebt[keccak256(abi.encode(spoke, id))];
    }

    function checkAaveConfig(
        address,
        uint256[] calldata ids
    ) external view {
        if (driftReverts) revert ConfigDrift();
        for (uint256 i = 0; i < ids.length; ++i) {
            if (driftMarket != 0 && ids[i] == driftMarket) revert ConfigDrift();
        }
    }

    function isHubSharesEqualAssets(
        uint256
    ) external view returns (bool) {
        return sharesEqual;
    }

    function expectedCollateralFactorBps(
        uint256
    ) external view returns (uint256) {
        return cfLp;
    }
}

/// @title RegistryLPVaultMock
/// @notice An AMM integration's LPVault as the VaultTokenFactory and the MarketRegistry see it: identity, capabilities
/// and the market binding.
contract RegistryLPVaultMock {
    uint32 public immutable INTEGRATION_ID;
    address public immutable COLLATERALIZATION;
    address public immutable LOCK;
    bytes32 public constant AMM_PROTOCOL = keccak256("UNISWAP_V3");
    address public MARKET_REGISTRY;
    /// @dev The timelock the VaultTokenFactory compares; copied from the first registry that answers `TIMELOCK()`.
    address public TIMELOCK;
    address[] internal _tokens;
    uint8 public unitDecimals = 18;
    PoolKeying public keying = PoolKeying.Address;
    ShapeKind public shapeKind = ShapeKind.TickRange;

    struct Binding {
        address pool;
        bytes32 poolId;
        PositionShape shape;
        address[] tokens;
        bool bound;
    }

    mapping(uint256 => Binding) internal _bindings;

    error MarketBinding();

    constructor(
        uint32 id,
        address collateralization,
        address lock
    ) {
        INTEGRATION_ID = id;
        COLLATERALIZATION = collateralization;
        LOCK = lock;
    }

    function setRegistry(
        address r
    ) external {
        MARKET_REGISTRY = r;
        if (TIMELOCK == address(0) && r.code.length > 0) {
            (bool ok, bytes memory ret) = r.staticcall(abi.encodeWithSignature("TIMELOCK()"));
            if (ok && ret.length == 32) TIMELOCK = abi.decode(ret, (address));
        }
    }

    function setPoolTokens(
        address[] calldata tokens,
        uint8 decimals_
    ) external {
        _tokens = tokens;
        unitDecimals = decimals_;
    }

    function setKeying(
        PoolKeying k,
        ShapeKind s
    ) external {
        keying = k;
        shapeKind = s;
    }

    function capabilities() external view returns (IntegrationCapabilities memory c) {
        c.poolKeying = keying;
        c.shapeKind = shapeKind;
        c.hasTwap = true;
    }

    function bindMarket(
        uint256 marketId,
        address pool,
        bytes32 poolId,
        PositionShape calldata shape,
        bytes calldata
    ) external returns (address[] memory tokens, uint8 decimals_) {
        require(msg.sender == MARKET_REGISTRY, "NotMarketRegistry");
        if (_bindings[marketId].bound) revert MarketBinding();
        Binding storage b = _bindings[marketId];
        b.pool = pool;
        b.poolId = poolId;
        b.shape = shape;
        b.tokens = _tokens;
        b.bound = true;
        return (_tokens, unitDecimals);
    }

    function marketOf(
        uint256 marketId
    ) external view returns (address pool, bytes32 poolId, PositionShape memory shape, address[] memory tokens) {
        Binding storage b = _bindings[marketId];
        if (!b.bound) revert MarketBinding();
        return (b.pool, b.poolId, b.shape, b.tokens);
    }
}

/// @title RegistryLPOracleMock
/// @notice An LPOracle as the MarketRegistry sees it: seed, binding, configuration check and price state.
contract RegistryLPOracleMock {
    uint8 public decimals = 8;
    int256 public latestAnswer = 1e8;
    uint256 public marketId;
    address public integration;
    uint256 public failedChecks;
    PriceState public state = PriceState.Live;

    constructor(
        uint256 id,
        address amm
    ) {
        marketId = id;
        integration = amm;
    }

    function setSeed(
        uint8 d,
        int256 answer
    ) external {
        decimals = d;
        latestAnswer = answer;
    }

    function setFailed(
        uint256 f
    ) external {
        failedChecks = f;
    }

    function setState(
        PriceState s
    ) external {
        state = s;
    }

    function checkConfig(
        OracleConfig calldata
    ) external view returns (uint256) {
        return failedChecks;
    }

    function getPriceState() external view returns (PriceStateView memory report) {
        report.state = state;
        report.answer = latestAnswer;
    }
}

/// @title RegistryFeedMock
/// @notice A Chainlink aggregator (or an 8-decimal Aave price source) with a settable answer.
contract RegistryFeedMock {
    uint8 public decimals;
    int256 public latestAnswer;

    constructor(
        uint8 d,
        int256 answer
    ) {
        decimals = d;
        latestAnswer = answer;
    }

    function setAnswer(
        int256 a
    ) external {
        latestAnswer = a;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, latestAnswer, block.timestamp, block.timestamp, 1);
    }
}

/// @title RegistryTokenMock
/// @notice An ERC-20 with settable decimals and Tether's fee-rate switch.
contract RegistryTokenMock {
    uint8 public decimals;
    uint256 public basisPointsRate;
    bool public feeReverts;

    constructor(
        uint8 d
    ) {
        decimals = d;
    }

    function setFee(
        uint256 r,
        bool rev
    ) external {
        basisPointsRate = r;
        feeReverts = rev;
    }
}

/// @title RegistryTetherMock
/// @notice A token whose `basisPointsRate` can be set or made to revert.
contract RegistryTetherMock {
    uint8 public decimals = 6;
    uint256 internal _rate;
    bool internal _reverts;

    function setFee(
        uint256 r,
        bool rev
    ) external {
        _rate = r;
        _reverts = rev;
    }

    function basisPointsRate() external view returns (uint256) {
        require(!_reverts, "rate");
        return _rate;
    }
}

/// @title RegistryDebtOracleMock
/// @notice A DebtOracle as the MarketRegistry sees it.
contract RegistryDebtOracleMock {
    address public ASSET;
    address public MARKET_REGISTRY;
    address public PARAMETER_STORE;
    uint8 public decimals = 8;
    int256 public latestAnswer = 1e8;

    constructor(
        address asset,
        address registry,
        address store
    ) {
        ASSET = asset;
        MARKET_REGISTRY = registry;
        PARAMETER_STORE = store;
    }
}

/// @title RegistryCoverageSpokeMock
/// @notice A Coverage Spoke as the MarketRegistry sees it.
contract RegistryCoverageSpokeMock {
    address public HUB;
    address public ASSET;
    uint256 public ASSET_ID;
    uint256 public fundedBalance;
    bool public isBelowMinimum;

    constructor(
        address hub,
        address asset,
        uint256 assetId
    ) {
        HUB = hub;
        ASSET = asset;
        ASSET_ID = assetId;
    }

    function setFunded(
        uint256 b,
        bool below
    ) external {
        fundedBalance = b;
        isBelowMinimum = below;
    }
}

/// @title RegistryFlashSourceMock
/// @notice An IFlashSource as the MarketRegistry sees it.
contract RegistryFlashSourceMock {
    address public LENDER;
    address public LP_VAULT_SWAP;
    uint256 public available = 1e30;
    uint256 public premiumBps = 5;

    constructor(
        address lender,
        address lpVaultSwap
    ) {
        LENDER = lender;
        LP_VAULT_SWAP = lpVaultSwap;
    }

    function setLender(
        address l
    ) external {
        LENDER = l;
    }

    function setLiquidity(
        uint256 a,
        uint256 bps
    ) external {
        available = a;
        premiumBps = bps;
    }

    function maxFlashLoan(
        address
    ) external view returns (uint256) {
        return available;
    }

    function flashPremium(
        address,
        uint256 amount
    ) external view returns (uint256) {
        return amount * premiumBps / 10_000;
    }
}

/// @title RegistryRouteMock
/// @notice A swap route as the MarketRegistry sees it.
contract RegistryRouteMock {
    address public tokenIn;
    address public tokenOut;
    address public LP_VAULT_SWAP;
    address[] internal _deps;
    bool public classOk = true;

    constructor(
        address inToken,
        address outToken,
        address lpVaultSwap,
        address[] memory deps
    ) {
        tokenIn = inToken;
        tokenOut = outToken;
        LP_VAULT_SWAP = lpVaultSwap;
        _deps = deps;
    }

    function setClassOk(
        bool ok
    ) external {
        classOk = ok;
    }

    function dependencies() external view returns (address[] memory) {
        return _deps;
    }

    address[] internal _exact;

    function setExactAmountInputs(
        address[] calldata tokens
    ) external {
        _exact = tokens;
    }

    function exactAmountInputs() external view returns (address[] memory) {
        return _exact;
    }

    function supportsTokenClass(
        uint8
    ) external view returns (bool) {
        return classOk;
    }

    /// @dev Route type the registry reads (REQ-ROUTE-002); `DexPath` (1) unless a test sets another.
    uint256 internal _routeType = 1;
    address[] internal _intermediates;
    uint256 internal _pegKind;
    uint256 internal _pegModule;
    /// @dev Per view selector: 0 a normal answer, 1 revert, 2 one byte short, 3 one word too long.
    mapping(bytes4 selector => uint8 mode) public answerMode;

    function setRouteType(
        uint256 t
    ) external {
        _routeType = t;
    }

    function setIntermediates(
        address[] calldata tokens
    ) external {
        _intermediates = tokens;
    }

    function intermediates() external view returns (address[] memory) {
        return _intermediates;
    }

    /// @dev Raw words of `IPegModuleRoute.pegModule()`: the `PegModuleKind` ordinal (0 Gsm, 1 LitePsm) and the module.
    function setPegModule(
        uint256 kind,
        uint256 module
    ) external {
        (_pegKind, _pegModule) = (kind, module);
    }

    function setAnswerMode(
        bytes4 selector,
        uint8 mode
    ) external {
        answerMode[selector] = mode;
    }

    function routeType() external view returns (uint256) {
        _odd(this.routeType.selector, _routeType, 0, 1);
        return _routeType;
    }

    function pegModule() external view returns (uint256, uint256) {
        _odd(this.pegModule.selector, _pegKind, _pegModule, 2);
        return (_pegKind, _pegModule);
    }

    /// @dev Ends the call with a revert or an answer of the wrong length when the selector's mode asks for one.
    function _odd(
        bytes4 selector,
        uint256 w0,
        uint256 w1,
        uint256 words
    ) internal view {
        uint8 mode = answerMode[selector];
        if (mode == 0) return;
        if (mode == 1) revert("route read");
        uint256 size = mode == 2 ? words * 32 - 1 : words * 32 + 32;
        assembly {
            let p := mload(0x40)
            mstore(p, w0)
            mstore(add(p, 0x20), w1)
            mstore(add(p, 0x40), 0)
            return(p, size)
        }
    }
}

/// @title RegistryAdapterMock
/// @notice The AaveAdapter's proxy registry, read by the address freeze.
contract RegistryAdapterMock {
    mapping(address => address) public walletOf;

    function setWallet(
        address proxy,
        address wallet
    ) external {
        walletOf[proxy] = wallet;
    }
}

/// @title RegistryCollateralizationMock
/// @notice Collateralization as the VaultTokenFactory (its Lock, factory, Adapter and LPVaultSwap) and the
/// MarketRegistry (`getMarketDebtFree`) see it.
contract RegistryCollateralizationMock {
    address public immutable LOCK;
    address public VAULT_TOKEN_FACTORY;
    address public ADAPTER;
    address public LP_VAULT_SWAP;
    mapping(address => bool) public hasDebt;

    constructor(
        address lock
    ) {
        LOCK = lock;
    }

    function setHasDebt(
        address vaultToken,
        bool d
    ) external {
        hasDebt[vaultToken] = d;
    }

    function setCore(
        address factory,
        address adapter,
        address lpVaultSwap
    ) external {
        VAULT_TOKEN_FACTORY = factory;
        ADAPTER = adapter;
        LP_VAULT_SWAP = lpVaultSwap;
    }

    function getMarketDebtFree(
        address vaultToken
    ) external view returns (bool) {
        return !hasDebt[vaultToken];
    }
}
