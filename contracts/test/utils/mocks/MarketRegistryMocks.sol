// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IntegrationCapabilities, PoolKeying} from "../../../src/amm/types/AmmTypes.sol";
import {ILegacyLPOracle} from "../../../src/legacy/ILegacyLPOracle.sol";
import {FeedDef, MarketParams} from "../../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {PriceState} from "../../../src/types/OracleTypes.sol";
import {PositionShape, ShapeKind} from "../../../src/types/PositionTypes.sol";

/// @title RegistryParameterStoreMock
/// @notice The ParameterStore views the MarketRegistry reads, backed by settable storage.
contract RegistryParameterStoreMock {
    mapping(address => FeedDef) internal _feeds;
    mapping(address => uint16) public debtStressRiseBps;
    mapping(uint256 => MarketParams) internal _params;
    mapping(uint256 => uint256) public marketUsdCap;
    mapping(uint256 => uint256) public topUpSliceUsd;
    mapping(uint256 => uint256) public stressFloorUsd;
    mapping(bytes32 => bool) public livenessFails;
    uint16 public maxFlashFeeBps = 10;
    uint16 public avanaFeeShareBps;
    uint16 public coverageRatioBps = 2000;

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

    /// @notice A debt reserve's Chainlink source, listed with its decimals and borrow and liquidation age limits.
    function setFeedAges(
        address feed,
        uint8 decimals,
        uint32 borrowAge,
        uint32 liquidationAge
    ) external {
        FeedDef storage f = _feeds[feed];
        (f.decimals, f.borrowPriceMaxAge, f.liquidationPriceMaxAge) = (decimals, borrowAge, liquidationAge);
    }

    function setStressRise(
        address asset,
        uint16 v
    ) external {
        debtStressRiseBps[asset] = v;
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

    function setFeeBoundInputs(
        uint256 id,
        uint16 slippageAllowanceBps,
        uint16 feeShareBps
    ) external {
        _params[id].slippageAllowanceBps = slippageAllowanceBps;
        avanaFeeShareBps = feeShareBps;
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

    function setLivenessFails(
        address spoke,
        uint256 marketId,
        uint256 reserveId,
        bool fails
    ) external {
        livenessFails[keccak256(abi.encode(spoke, marketId, reserveId))] = fails;
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
}

/// @title RegistryRiskModuleMock
/// @notice The RiskModule calls of the MarketRegistry: the drift check (reverting on demand), the Hub-share check and
/// the expected collateral factor.
contract RegistryRiskModuleMock {
    bool public driftReverts;
    bool public sharesEqual = true;
    uint256 public cfLp = 8000;
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
    /// @dev The authority_ the VaultTokenFactory compares; copied from the first registry that answers `authority()`.
    address public authority;
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
        if (authority == address(0) && r.code.length > 0) {
            (bool ok, bytes memory ret) = r.staticcall(abi.encodeWithSignature("authority()"));
            if (ok && ret.length == 32) authority = abi.decode(ret, (address));
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

    function maxRecordsPerAccountMarket() external pure returns (uint256) {
        return 16;
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
/// @notice An LPOracle as the MarketRegistry sees it: seed, binding and price status.
contract RegistryLPOracleMock {
    uint8 public decimals = 8;
    int256 public latestAnswer = 1e8;
    uint256 public marketId;
    address public integration;
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

    function setState(
        PriceState s
    ) external {
        state = s;
    }

    function getPriceStatus() external view returns (ILegacyLPOracle.PriceStatus memory s) {
        s.answer = latestAnswer;
        s.updatedAt = uint64(block.timestamp);
        s.borrowFresh = state == PriceState.Live;
        s.liquidationFresh = state == PriceState.Live || state == PriceState.Drifting;
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
        // Listed in a mock ParameterStore as a Chainlink feed (8 decimals, 24.5 h borrow and 25 h liquidation ages).
        if (store.code.length != 0) {
            (bool listed,) = store.call(
                abi.encodeWithSignature(
                    "setFeedAges(address,uint8,uint32,uint32)", address(this), uint8(8), uint32(88_200), uint32(90_000)
                )
            );
            listed;
        }
    }

    /// @notice The debt source as a Chainlink feed with a current round.
    function latestRoundData() external view virtual returns (uint80, int256, uint256, uint256, uint80) {
        return (0, latestAnswer, block.timestamp, block.timestamp, 0);
    }
}

/// @title RegistryAvanaFirstLossReserveMock
/// @notice A First-Loss Reserve as the MarketRegistry sees it.
contract RegistryAvanaFirstLossReserveMock {
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
/// @notice The AaveAdapter address the MarketRegistry and the VaultTokenFactory are deployed with.
contract RegistryAdapterMock {}

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
