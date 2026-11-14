// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtPriceView} from "../../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {DebtReserveDef} from "../../../src/policy/market-registry/types/DebtReserveDef.sol";
import {MarketParams} from "../../../src/policy/parameter-store/types/MarketParams.sol";
import {Market} from "../../../src/types/Market.sol";
import {PriceState} from "../../../src/types/PriceState.sol";
import {PriceStateView} from "../../../src/types/PriceStateView.sol";
import {TokenPriceView} from "../../../src/types/TokenPriceView.sol";

/// @title LVSMarketRegistryMock
/// @notice MarketRegistry stand-in for the LPVaultSwap suites: the market and debt-reserve records, the settlement
/// reserve, First-Loss Reserves, the flash source, recorded Hubs, swap-route slots and the address freeze, each set by the
/// test. It has no pause state, pause reason or breaker: a read of any of them reverts, so a suite in which LPVaultSwap
/// completes shows that it never reads one (REQ-SWAP-003, REQ-SWAP-104).
contract LVSMarketRegistryMock {
    mapping(uint256 marketId => Market) internal _markets;
    mapping(address spoke => mapping(uint256 reserveId => DebtReserveDef)) internal _debt;
    mapping(address spoke => mapping(uint256 reserveId => bool)) public isApprovedDebtReserve;
    mapping(uint256 marketId => uint256 reserveId) public settlementReserve;
    mapping(address hub => mapping(address asset => address coverage)) public firstLossReserveOf;
    mapping(address hub => bool) public isRecordedHub;
    mapping(address account => bool) public isFrozenAddress;
    mapping(bytes32 slot => address route) internal _route;
    mapping(bytes32 slot => bool usable) internal _usable;
    address public flashSource;
    /// @notice Pause state and reason (0 None, 1 Frozen, 2 Paused; reason 0 None, 1 General, 2 MintPathSuspect), held
    /// for the pause handler; LPVaultSwap never reads them.
    uint8 public pauseState;
    uint8 public pauseReason;
    /// @notice When true, `isFrozenAddress` reverts (a registry read failing).
    bool public freezeReadReverts;

    function setPause(
        uint8 state,
        uint8 reason
    ) external {
        (pauseState, pauseReason) = (state, reason);
    }

    function setMarket(
        uint256 marketId,
        Market calldata m
    ) external {
        _markets[marketId] = m;
    }

    function getMarket(
        uint256 marketId
    ) external view returns (Market memory) {
        return _markets[marketId];
    }

    function setDebtReserve(
        address spoke,
        uint256 reserveId,
        DebtReserveDef calldata def,
        bool approved
    ) external {
        _debt[spoke][reserveId] = def;
        isApprovedDebtReserve[spoke][reserveId] = approved;
    }

    function getDebtReserve(
        address spoke,
        uint256 reserveId
    ) external view returns (DebtReserveDef memory) {
        return _debt[spoke][reserveId];
    }

    function setSettlementReserve(
        uint256 marketId,
        uint256 reserveId
    ) external {
        settlementReserve[marketId] = reserveId;
    }

    function setAvanaFirstLossReserve(
        address hub,
        address asset,
        address coverage
    ) external {
        firstLossReserveOf[hub][asset] = coverage;
    }

    function setFlashSource(
        address source
    ) external {
        flashSource = source;
    }

    function setRecordedHub(
        address hub,
        bool recorded
    ) external {
        isRecordedHub[hub] = recorded;
    }

    function setFrozen(
        address account,
        bool frozen
    ) external {
        isFrozenAddress[account] = frozen;
    }

    function setRoute(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind,
        address route,
        bool usable
    ) external {
        bytes32 k = keccak256(abi.encode(marketId, token, debtAsset, kind));
        _route[k] = route;
        _usable[k] = usable;
    }

    function getRoute(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind
    ) external view returns (address route, bool usable) {
        bytes32 k = keccak256(abi.encode(marketId, token, debtAsset, kind));
        route = _route[k];
        usable = route != address(0) && _usable[k];
    }
}

/// @title LVSParameterStoreMock
/// @notice ParameterStore stand-in with the getters LPVaultSwap and the flash source read, at the launch values of 1.5
/// unless a test changes them.
contract LVSParameterStoreMock {
    mapping(uint256 marketId => MarketParams) internal _params;
    mapping(address asset => uint256) public floorRoundingAllowance;
    mapping(address feed => uint32) internal _liquidationAge;
    uint16 public maxFlashFeeBps = 10;
    uint16 public avanaFeeShareBps = 2000;
    uint16 public maxShortfallBps = 1000;
    address public feeRecipient;
    uint256 public graceHealthFactor = 0.95e18;
    uint32 public defaultLiquidationAge = 88_200;

    function setSlippage(
        uint256 marketId,
        uint16 bps
    ) external {
        _params[marketId].slippageAllowanceBps = bps;
    }

    function getMarketParams(
        uint256 marketId
    ) external view returns (MarketParams memory) {
        return _params[marketId];
    }

    /// @dev The AaveAdapter's sequencer read: a chain without a sequencer feed (the gate is always Up).
    function sequencer() external pure returns (address feed, uint32 gracePeriod) {
        return (address(0), 0);
    }

    function setFloorRoundingAllowance(
        address asset,
        uint256 value
    ) external {
        floorRoundingAllowance[asset] = value;
    }

    function setMaxFlashFeeBps(
        uint16 v
    ) external {
        maxFlashFeeBps = v;
    }

    function setAvanaFeeShareBps(
        uint16 v
    ) external {
        avanaFeeShareBps = v;
    }

    function setMaxShortfallBps(
        uint16 v
    ) external {
        maxShortfallBps = v;
    }

    function setFeeRecipient(
        address v
    ) external {
        feeRecipient = v;
    }

    function setGraceHealthFactor(
        uint256 v
    ) external {
        graceHealthFactor = v;
    }

    function setLiquidationPriceMaxAge(
        address feed,
        uint32 age
    ) external {
        _liquidationAge[feed] = age;
    }

    function liquidationPriceMaxAge(
        address feed
    ) external view returns (uint32) {
        uint32 age = _liquidationAge[feed];
        return age == 0 ? defaultLiquidationAge : age;
    }
}

/// @title LVSLPOracleMock
/// @notice LPOracle stand-in: an 8-decimal price feed the AaveOracle reads (`latestAnswer`), `poke()` that applies a
/// pending state (so a test sees whether LPVaultSwap pokes before it reads), `getPriceState()` built from settable
/// flags and per-token legs, and `getTokenPrices()`.
contract LVSLPOracleMock {
    int256 public latestAnswer;
    PriceState public state;
    PriceState public pendingState;
    bool public hasPending;
    bool public liquidationPaused;
    bool public disagreementPauseActive;
    bool public disagreementExpired;
    bool public inGrace;
    bool public pokeReverts;
    uint256 public pokes;
    uint256[] internal _prices;
    address[] internal _tokens;
    address[2][] internal _legFeeds;
    uint64[2][] internal _legUpdatedAt;

    constructor(
        int256 answer,
        address[] memory tokens,
        uint256[] memory prices
    ) {
        latestAnswer = answer;
        _tokens = tokens;
        _prices = prices;
        for (uint256 i = 0; i < tokens.length; ++i) {
            _legFeeds.push([address(0), address(0)]);
            _legUpdatedAt.push([uint64(0), uint64(0)]);
        }
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "LVS LP oracle mock";
    }

    function setAnswer(
        int256 answer
    ) external {
        latestAnswer = answer;
    }

    function setPrices(
        uint256[] calldata prices
    ) external {
        _prices = prices;
    }

    function setState(
        PriceState s
    ) external {
        state = s;
        hasPending = false;
    }

    function setPendingState(
        PriceState s
    ) external {
        pendingState = s;
        hasPending = true;
    }

    function setFlags(
        bool paused,
        bool pauseActive,
        bool expired,
        bool grace
    ) external {
        (liquidationPaused, disagreementPauseActive, disagreementExpired, inGrace) =
        (paused, pauseActive, expired, grace);
    }

    function setPokeReverts(
        bool on
    ) external {
        pokeReverts = on;
    }

    function setLeg(
        uint256 token,
        uint256 leg,
        address feed,
        uint64 updatedAt
    ) external {
        _legFeeds[token][leg] = feed;
        _legUpdatedAt[token][leg] = updatedAt;
    }

    function poke() external returns (PriceState) {
        require(!pokeReverts, "poke reverts");
        ++pokes;
        if (hasPending) {
            state = pendingState;
            hasPending = false;
        }
        return state;
    }

    function getTokenPrices() external view returns (uint256[] memory prices, uint64 servedUpdatedAt, PriceState s) {
        return (_prices, uint64(block.timestamp), state);
    }

    function getPriceState() external view returns (PriceStateView memory v) {
        v.state = state;
        v.answer = latestAnswer;
        v.liquidationPaused = liquidationPaused;
        v.disagreementPauseActive = disagreementPauseActive;
        v.disagreementExpired = disagreementExpired;
        v.inGrace = inGrace;
        v.tokens = new TokenPriceView[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; ++i) {
            v.tokens[i].token = _tokens[i];
            v.tokens[i].valuationPrice = _prices[i];
            v.tokens[i].legFeeds = _legFeeds[i];
            v.tokens[i].legUpdatedAt = _legUpdatedAt[i];
        }
    }
}

/// @title LVSDebtOracleMock
/// @notice DebtOracle stand-in: an 8-decimal feed the AaveOracle reads, `poke()` that applies a pending state, and
/// `getPriceState()` from settable fields with up to two legs.
contract LVSDebtOracleMock {
    int256 public latestAnswer;
    PriceState public state;
    PriceState public pendingState;
    bool public hasPending;
    bool public liquidationPaused;
    uint256 public pokes;
    address[2] internal _legFeeds;
    uint64[2] internal _legUpdatedAt;

    constructor(
        int256 answer
    ) {
        latestAnswer = answer;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "LVS debt oracle mock";
    }

    function setAnswer(
        int256 answer
    ) external {
        latestAnswer = answer;
    }

    function setState(
        PriceState s,
        bool paused
    ) external {
        (state, liquidationPaused) = (s, paused);
    }

    function setPendingState(
        PriceState s
    ) external {
        pendingState = s;
        hasPending = true;
    }

    function setLeg(
        uint256 leg,
        address feed,
        uint64 updatedAt
    ) external {
        _legFeeds[leg] = feed;
        _legUpdatedAt[leg] = updatedAt;
    }

    function poke() external returns (PriceState) {
        ++pokes;
        if (hasPending) {
            state = pendingState;
            hasPending = false;
        }
        return state;
    }

    function getPriceState() external view returns (DebtPriceView memory v) {
        v.state = state;
        v.answer = latestAnswer;
        v.liquidationPaused = liquidationPaused;
        v.legFeeds = _legFeeds;
        v.legUpdatedAt = _legUpdatedAt;
    }
}

/// @title LVSRevertingRoute
/// @notice A route stand-in whose `swap` reverts with a fixed reason, or whose `intermediates()` reverts.
contract LVSRevertingRoute {
    error RouteDown(uint256 code);

    bool public intermediatesRevert;
    uint256 public calls;

    function setIntermediatesRevert(
        bool on
    ) external {
        intermediatesRevert = on;
    }

    function intermediates() external view returns (address[] memory list) {
        require(!intermediatesRevert, "no intermediates");
        list = new address[](0);
    }

    function swap(
        uint256,
        uint256
    ) external pure returns (uint256) {
        revert RouteDown(7);
    }
}

/// @title LVSGasSink
/// @notice Hook target of a `PayoutToken`: burns every gas unit it gets while it runs inside a gas-limited payout
/// transfer (less than 200,000 gas left) and returns at once otherwise, so only LPVaultSwap's 100,000-gas payout
/// transfer runs out of gas.
contract LVSGasSink {
    fallback() external {
        if (gasleft() < 200_000) {
            while (true) {}
        }
    }
}

/// @title LVSLyingRoute
/// @notice A faulty route a governance mistake could record: it pulls `amountIn` of `tokenIn` from its caller and pays
/// a fixed `out` of `tokenOut` (pre-funded), ignoring `minOut`, optionally re-entering its caller with `reenterData`
/// first. LPVaultSwap's aggregate floor and Lock must catch what the route's own check would have.
contract LVSLyingRoute {
    address public immutable tokenIn;
    address public immutable tokenOut;
    uint256 public out;
    bytes public reenterData;
    address public reenterTarget;
    bool public lastReenterOk;
    bytes public lastReenterData;

    constructor(
        address tokenIn_,
        address tokenOut_
    ) {
        tokenIn = tokenIn_;
        tokenOut = tokenOut_;
    }

    function setOut(
        uint256 out_
    ) external {
        out = out_;
    }

    function setReenter(
        address target,
        bytes calldata data
    ) external {
        reenterTarget = target;
        reenterData = data;
    }

    function intermediates() external pure returns (address[] memory list) {
        list = new address[](0);
    }

    function swap(
        uint256 amountIn,
        uint256
    ) external returns (uint256) {
        if (reenterTarget != address(0)) {
            (lastReenterOk, lastReenterData) = reenterTarget.call(reenterData);
        }
        IERC20Like(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        if (out != 0) IERC20Like(tokenOut).transfer(msg.sender, out);
        return out;
    }
}

interface IERC20Like {
    function transfer(
        address to,
        uint256 amount
    ) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}

interface IMintable {
    function mint(
        address to,
        uint256 amount
    ) external;
}

/// @title LVSShortChange
/// @notice Hook target of a `PayoutToken` that makes a gas-limited payout transfer return `true` while moving less out
/// of LPVaultSwap than asked: inside the 100,000-gas payout transfer (less than 200,000 gas left) it mints `refund`
/// back to LPVaultSwap; with ample gas it does nothing.
contract LVSShortChange {
    address public immutable token;
    address public immutable lpVaultSwap;
    uint256 public refund;

    constructor(
        address token_,
        address lpVaultSwap_,
        uint256 refund_
    ) {
        (token, lpVaultSwap, refund) = (token_, lpVaultSwap_, refund_);
    }

    fallback() external {
        if (gasleft() < 200_000) IMintable(token).mint(lpVaultSwap, refund);
    }
}

interface ILVSFlashReceiver {
    function onFlashLoan(
        address asset,
        uint256 amount,
        uint256 premium,
        bytes calldata context
    ) external returns (bytes32);
}

/// @title LVSFlashSourceMock
/// @notice An `IFlashSource` stand-in for the callback checks of LPVaultSwap: it lends from its own float, forwards a
/// settable amount, calls `onFlashLoan` with settable overrides (asset, amount, premium, context, a second call, no
/// call) and requires its balance back at `amount + premium`. It performs none of the real source's own checks, so a
/// test reaches LPVaultSwap's.
contract LVSFlashSourceMock {
    address public immutable LP_VAULT_SWAP;
    address public LENDER;
    address public PARAMETER_STORE;
    uint256 public available = type(uint128).max;
    uint256 public quote;
    uint256 public premium;
    bool public overrideForward;
    uint256 public forward;
    bool public overrideAsset;
    address public assetOverride;
    bool public overrideAmount;
    uint256 public amountOverride;
    bool public tamperContext;
    bool public skipCallback;
    bool public callTwice;
    bytes32 public lastMagic;
    address public switchRegistry;
    address public switchTo;

    constructor(
        address lpVaultSwap,
        address lender
    ) {
        LP_VAULT_SWAP = lpVaultSwap;
        LENDER = lender;
    }

    function setQuote(
        uint256 q,
        uint256 charged
    ) external {
        (quote, premium) = (q, charged);
    }

    function setAvailable(
        uint256 a
    ) external {
        available = a;
    }

    function setForward(
        uint256 f
    ) external {
        (overrideForward, forward) = (true, f);
    }

    function setAssetOverride(
        address a
    ) external {
        (overrideAsset, assetOverride) = (true, a);
    }

    function setAmountOverride(
        uint256 a
    ) external {
        (overrideAmount, amountOverride) = (true, a);
    }

    function setTamper(
        bool on
    ) external {
        tamperContext = on;
    }

    function setSkip(
        bool on
    ) external {
        skipCallback = on;
    }

    function setTwice(
        bool on
    ) external {
        callTwice = on;
    }

    /// @notice Before calling back, records `newSource` as the registry's flash source (a source replaced mid-loan).
    function setRegistrySwitch(
        address registry,
        address newSource
    ) external {
        (switchRegistry, switchTo) = (registry, newSource);
    }

    function maxFlashLoan(
        address
    ) external view returns (uint256) {
        return available;
    }

    function flashPremium(
        address,
        uint256
    ) external view returns (uint256) {
        return quote;
    }

    function flashLoan(
        address asset,
        uint256 amount,
        address,
        bytes calldata context
    ) external returns (uint256) {
        require(msg.sender == LP_VAULT_SWAP, "not LPVaultSwap");
        uint256 sent = overrideForward ? forward : amount;
        if (sent != 0) IERC20Like(asset).transfer(LP_VAULT_SWAP, sent);
        if (switchRegistry != address(0)) LVSMarketRegistryMock(switchRegistry).setFlashSource(switchTo);
        if (!skipCallback) {
            bytes memory data = tamperContext ? abi.encodePacked(context, uint8(1)) : context;
            address a = overrideAsset ? assetOverride : asset;
            uint256 m = overrideAmount ? amountOverride : amount;
            lastMagic = ILVSFlashReceiver(LP_VAULT_SWAP).onFlashLoan(a, m, premium, data);
            if (callTwice) ILVSFlashReceiver(LP_VAULT_SWAP).onFlashLoan(a, m, premium, data);
        }
        return premium;
    }
}
