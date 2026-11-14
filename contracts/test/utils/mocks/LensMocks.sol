// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClMarketConfig} from "../../../src/amm/types/ClMarketConfig.sol";
import {RiskStatus} from "../../../src/amm/types/RiskStatus.sol";
import {DebtPriceView as OracleDebtView} from "../../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {DebtReserveDef} from "../../../src/policy/market-registry/types/DebtReserveDef.sol";
import {MarketStatus} from "../../../src/policy/market-registry/types/MarketStatus.sol";
import {MarketParams} from "../../../src/policy/parameter-store/types/MarketParams.sol";
import {SpeedView} from "../../../src/policy/risk-module/types/SpeedView.sol";
import {AccountGateStatus} from "../../../src/types/AccountGateStatus.sol";
import {Market} from "../../../src/types/Market.sol";
import {PauseReason} from "../../../src/types/PauseReason.sol";
import {PauseState} from "../../../src/types/PauseState.sol";
import {PledgePreview} from "../../../src/types/PledgePreview.sol";
import {PriceState} from "../../../src/types/PriceState.sol";
import {PriceStateView} from "../../../src/types/PriceStateView.sol";
import {TokenPriceView} from "../../../src/types/TokenPriceView.sol";
import {CollLPVaultMock} from "./CollateralizationMocks.sol";

/// @notice The MarketRegistry views the Lens reads, settable (the Lens suites' stand-in for the registry's listing
/// world; the registry's own suites test the real contract).
contract LensRegistryMock {
    struct Route {
        address route;
        bool usable;
    }

    mapping(uint256 => Market) internal _markets;
    mapping(address => uint256) public marketOfVaultToken;
    uint256 public marketCount;
    mapping(address => uint256[]) internal _ids;
    mapping(address => mapping(uint256 => DebtReserveDef)) internal _defs;
    mapping(bytes32 => Route) internal _routes;
    mapping(address => PauseState) public pauseState;
    mapping(address => PauseReason) public pauseReason;
    mapping(address => bool) public isFrozenAddress;
    address[] internal _spokes;
    mapping(address => mapping(address => address)) public firstLossReserveOf;
    mapping(address => mapping(address => uint256[4])) internal _lines;
    bool public crossHubLinesEnabled;
    mapping(uint256 => uint256) public settlementReserve;
    address public flashSource;
    mapping(address => address) public hubOf;
    mapping(address => mapping(uint256 => uint256)) public marketOfHubAsset;

    function setMarket(
        uint256 id,
        Market memory m
    ) external {
        _markets[id] = m;
        marketOfVaultToken[m.vaultToken] = id;
        if (m.hub != address(0)) marketOfHubAsset[m.hub][m.hubAssetId] = id;
        if (id > marketCount) marketCount = id;
    }

    function setStatus(
        uint256 id,
        uint8 status
    ) external {
        _markets[id].status = MarketStatus(status);
    }

    function setDebtReserve(
        address spoke,
        DebtReserveDef memory def
    ) external {
        if (!_defs[spoke][def.reserveId].approved) _ids[spoke].push(def.reserveId);
        def.approved = true;
        _defs[spoke][def.reserveId] = def;
    }

    function disableDebtReserve(
        address spoke,
        uint256 reserveId
    ) external {
        _defs[spoke][reserveId].approved = false;
        uint256[] storage ids = _ids[spoke];
        for (uint256 i = 0; i < ids.length; ++i) {
            if (ids[i] == reserveId) {
                ids[i] = ids[ids.length - 1];
                ids.pop();
                return;
            }
        }
    }

    function setRoute(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind,
        address route,
        bool usable
    ) external {
        _routes[keccak256(abi.encode(marketId, token, debtAsset, kind))] = Route(route, usable);
    }

    function setPause(
        address hub,
        PauseState state,
        PauseReason reason
    ) external {
        (pauseState[hub], pauseReason[hub]) = (state, reason);
    }

    function setFrozen(
        address account,
        bool frozen
    ) external {
        isFrozenAddress[account] = frozen;
    }

    function addSpoke(
        address spoke,
        address hub
    ) external {
        _spokes.push(spoke);
        hubOf[spoke] = hub;
    }

    function setAvanaFirstLossReserve(
        address hub,
        address asset,
        address spoke
    ) external {
        firstLossReserveOf[hub][asset] = spoke;
    }

    function setCreditLine(
        address hub,
        address asset,
        uint256 line,
        uint256 sum,
        uint256 required,
        uint256 funded
    ) external {
        _lines[hub][asset] = [line, sum, required, funded];
    }

    function setCrossHubLinesEnabled(
        bool on
    ) external {
        crossHubLinesEnabled = on;
    }

    function setSettlementReserve(
        uint256 marketId,
        uint256 reserveId
    ) external {
        settlementReserve[marketId] = reserveId;
    }

    function setFlashSource(
        address source
    ) external {
        flashSource = source;
    }

    function getMarket(
        uint256 id
    ) external view returns (Market memory) {
        return _markets[id];
    }

    function getDebtReserveIds(
        address spoke
    ) external view returns (uint256[] memory) {
        return _ids[spoke];
    }

    function getDebtReserve(
        address spoke,
        uint256 reserveId
    ) external view returns (DebtReserveDef memory) {
        return _defs[spoke][reserveId];
    }

    function isApprovedDebtReserve(
        address spoke,
        uint256 reserveId
    ) external view returns (bool) {
        return _defs[spoke][reserveId].approved;
    }

    function getRoute(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind
    ) external view returns (address route, bool usable) {
        Route memory r = _routes[keccak256(abi.encode(marketId, token, debtAsset, kind))];
        (route, usable) = (r.route, r.usable);
    }

    function getSpokes() external view returns (address[] memory) {
        return _spokes;
    }

    function creditLine(
        address hub,
        address asset
    ) external view returns (uint256 line, uint256 drawCapSum) {
        (line, drawCapSum) = (_lines[hub][asset][0], _lines[hub][asset][1]);
    }

    function creditLineCoverage(
        address hub,
        address asset
    ) external view returns (uint256 required, uint256 funded) {
        (required, funded) = (_lines[hub][asset][2], _lines[hub][asset][3]);
    }
}

/// @notice The ParameterStore views the Lens reads, settable.
contract LensStoreMock {
    mapping(address => uint32) public borrowPriceMaxAge;
    mapping(address => uint32) public liquidationPriceMaxAge;
    uint256 public graceHealthFactor = 0.95e18;
    mapping(uint256 => MarketParams) internal _params;
    mapping(address => uint256) public floorRoundingAllowance;
    uint16 public avanaFeeShareBps = 2000;
    uint16 public maxFlashFeeBps = 10;
    mapping(uint256 => uint256) public hardHealthFloor;
    mapping(uint256 => uint256) public marketUsdCap;
    mapping(uint256 => uint256) public topUpSliceUsd;
    mapping(uint256 => uint256) public stressFloorUsd;
    mapping(address => mapping(address => uint256)) public tokenUsdCap;
    mapping(address => uint256) public depositorUsdCap;
    mapping(bytes32 => uint16) internal _poolShareMax;
    mapping(bytes32 => bool) internal _poolShareSet;
    mapping(uint256 => uint256) public minPledgeUsd;
    uint16 public coverageRatioBps = 1000;

    function setAges(
        address feed,
        uint32 borrowAge,
        uint32 liquidationAge
    ) external {
        (borrowPriceMaxAge[feed], liquidationPriceMaxAge[feed]) = (borrowAge, liquidationAge);
    }

    function setGraceHealthFactor(
        uint256 v
    ) external {
        graceHealthFactor = v;
    }

    function setMarketParams(
        uint256 id,
        MarketParams memory p
    ) external {
        _params[id] = p;
        minPledgeUsd[id] = p.minPledgeUsd;
        hardHealthFloor[id] = p.hardHealthFloor;
    }

    function setHardHealthFloor(
        uint256 id,
        uint256 v
    ) external {
        hardHealthFloor[id] = v;
        _params[id].hardHealthFloor = v;
    }

    function setMinPledgeUsd(
        uint256 id,
        uint256 v
    ) external {
        minPledgeUsd[id] = v;
        _params[id].minPledgeUsd = v;
    }

    function setFloorRoundingAllowance(
        address asset,
        uint256 v
    ) external {
        floorRoundingAllowance[asset] = v;
    }

    function setFees(
        uint16 feeShare,
        uint16 flashFee
    ) external {
        (avanaFeeShareBps, maxFlashFeeBps) = (feeShare, flashFee);
    }

    function setCaps(
        uint256 id,
        uint256 marketCap,
        uint256 slice,
        uint256 stressFloor
    ) external {
        (marketUsdCap[id], topUpSliceUsd[id], stressFloorUsd[id]) = (marketCap, slice, stressFloor);
    }

    function setTokenCap(
        address hub,
        address token,
        uint256 cap
    ) external {
        tokenUsdCap[hub][token] = cap;
    }

    function setDepositorCap(
        address hub,
        uint256 cap
    ) external {
        depositorUsdCap[hub] = cap;
    }

    function setPoolShareMax(
        bytes32 key,
        uint16 bps
    ) external {
        (_poolShareMax[key], _poolShareSet[key]) = (bps, true);
    }

    function setCoverageRatioBps(
        uint16 v
    ) external {
        coverageRatioBps = v;
    }

    function getMarketParams(
        uint256 id
    ) external view returns (MarketParams memory) {
        return _params[id];
    }

    function poolShareMaxBpsOf(
        bytes32 key
    ) external view returns (uint16) {
        return _poolShareSet[key] ? _poolShareMax[key] : 10_000;
    }
}

/// @notice The RiskModule views the Lens reads, settable per proxy, market and debt reserve.
contract LensRiskModuleMock {
    struct Gate {
        bool set;
        bool borrowAllowed;
        bool unavailable;
        PauseState pauseState;
    }

    mapping(address => Gate) internal _gates;
    mapping(uint256 => uint32) internal _marketReasons;
    mapping(uint256 => uint64) internal _marketReopens;
    mapping(address => mapping(uint256 => uint32)) internal _debtReasons;
    mapping(address => mapping(uint256 => uint64)) internal _debtReopens;

    function setGate(
        address proxy,
        bool borrowAllowed,
        bool unavailable,
        PauseState state
    ) external {
        _gates[proxy] = Gate(true, borrowAllowed, unavailable, state);
    }

    function setMarketBreaker(
        uint256 id,
        uint32 reasons,
        uint64 reopensAt
    ) external {
        (_marketReasons[id], _marketReopens[id]) = (reasons, reopensAt);
    }

    function setDebtBreaker(
        address spoke,
        uint256 id,
        uint32 reasons,
        uint64 reopensAt
    ) external {
        (_debtReasons[spoke][id], _debtReopens[spoke][id]) = (reasons, reopensAt);
    }

    function getAccountGateStatus(
        address proxy
    ) external view returns (AccountGateStatus memory st) {
        Gate memory g = _gates[proxy];
        st.unknownCollateralReserveId = type(uint256).max;
        st.unapprovedDebtReserveId = type(uint256).max;
        st.pausedDebtReserveId = type(uint256).max;
        st.staleDebtReserveId = type(uint256).max;
        st.haltedDebtReserveId = type(uint256).max;
        st.breakerDebtReserveId = type(uint256).max;
        st.statusUnavailable = !g.set || g.unavailable;
        if (st.statusUnavailable) return st;
        (st.spokeApproved, st.borrowAllowed, st.withdrawWithDebtAllowed) = (true, g.borrowAllowed, g.borrowAllowed);
        st.pauseState = g.pauseState;
    }

    PledgePreview internal _pledge;

    function setPledgePreview(
        bool eligible,
        bytes4 reason,
        uint256 usdCharge
    ) external {
        (_pledge.eligible, _pledge.reason, _pledge.usdCharge) = (eligible, reason, usdCharge);
    }

    function previewPledge(
        address,
        uint256,
        bytes32
    ) external view returns (PledgePreview memory p) {
        p = _pledge;
    }

    function getBreakerStatus(
        uint256 id
    ) external view returns (uint32, uint64) {
        return (_marketReasons[id], _marketReopens[id]);
    }

    function getDebtBreakerStatus(
        address spoke,
        uint256 id
    ) external view returns (uint32, uint64) {
        return (_debtReasons[spoke][id], _debtReopens[spoke][id]);
    }

    /// @notice The speed windows the Lens forwards (REQ-LENS-061): open windows with no room, read-only.
    function getBorrowSpeed(
        uint256,
        uint256
    ) external pure returns (SpeedView memory market, SpeedView memory debt) {
        return (market, debt);
    }

    function getPledgeSpeed(
        uint256
    ) external pure returns (SpeedView memory pledge) {
        return pledge;
    }
}

/// @notice Price source with a settable 8-decimal answer (the shape Aave's oracle reads).
interface ILensAnswer {
    function latestAnswer() external view returns (int256);
}

/// @notice The market's LPOracle views the Lens reads: the served answer follows a source (the AaveOracle's source
/// of the vault-token reserve) unless overridden; the price-state report is built from settable fields.
contract LensLPOracleMock {
    struct Token {
        address token;
        address[2] feeds;
        uint64[2] updatedAt;
        uint8 routeUsed;
        uint256 deviationBps;
        uint256 price;
    }

    address public source;
    bool public overrideAnswer;
    int256 public answerOverride;
    PriceState public state;
    uint256 public reasons;
    bool public liquidationPaused;
    uint64 public disagreeSince;
    bool public pauseActive;
    bool public expired;
    bool public inGrace;
    uint64 public recoveredAt;
    uint64 public graceEndsAt;
    bool public borrowAllowed = true;
    uint256 public acceptedPrice;
    uint64 public acceptedAt;
    Token[] internal _tokens;

    constructor(
        address source_
    ) {
        source = source_;
    }

    function addToken(
        address token,
        address feed0,
        address feed1,
        uint64 at,
        uint256 price
    ) external {
        _tokens.push(Token(token, [feed0, feed1], [at, at], 0, 0, price));
    }

    function setTokenAt(
        uint256 i,
        uint64 at0,
        uint64 at1
    ) external {
        _tokens[i].updatedAt = [at0, at1];
    }

    function setTokenPrice(
        uint256 i,
        uint256 price
    ) external {
        _tokens[i].price = price;
    }

    function setTokenRoute(
        uint256 i,
        uint8 routeUsed,
        uint256 deviationBps
    ) external {
        (_tokens[i].routeUsed, _tokens[i].deviationBps) = (routeUsed, deviationBps);
    }

    function setAnswer(
        bool on,
        int256 answer
    ) external {
        (overrideAnswer, answerOverride) = (on, answer);
    }

    function setState(
        PriceState s,
        uint256 r,
        bool paused
    ) external {
        (state, reasons, liquidationPaused) = (s, r, paused);
    }

    function setDisagreement(
        uint64 since,
        bool active,
        bool isExpired
    ) external {
        (disagreeSince, pauseActive, expired) = (since, active, isExpired);
    }

    function setGrace(
        bool on,
        uint64 recovered,
        uint64 ends
    ) external {
        (inGrace, recoveredAt, graceEndsAt) = (on, recovered, ends);
    }

    function setBorrowAllowed(
        bool on
    ) external {
        borrowAllowed = on;
    }

    function setAccepted(
        uint256 price,
        uint64 at
    ) external {
        (acceptedPrice, acceptedAt) = (price, at);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestAnswer() public view returns (int256) {
        return overrideAnswer ? answerOverride : ILensAnswer(source).latestAnswer();
    }

    function lastAcceptedPrice() external view returns (uint256, uint64) {
        return (acceptedPrice, acceptedAt);
    }

    function getTokenPrices() external view returns (uint256[] memory prices, uint64 servedUpdatedAt, PriceState s) {
        prices = new uint256[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; ++i) {
            prices[i] = _tokens[i].price;
        }
        (servedUpdatedAt, s) = (acceptedAt, state);
    }

    function getPriceState() external view returns (PriceStateView memory v) {
        (v.state, v.reasons, v.answer, v.liquidationPaused) = (state, reasons, latestAnswer(), liquidationPaused);
        (v.disagreeSince, v.disagreementPauseActive, v.disagreementExpired) = (disagreeSince, pauseActive, expired);
        (v.inGrace, v.recoveredAt, v.graceEndsAt, v.borrowAllowed) = (inGrace, recoveredAt, graceEndsAt, borrowAllowed);
        (v.acceptedAnswer, v.acceptedUpdatedAt) = (int256(acceptedPrice), acceptedAt);
        v.tokens = new TokenPriceView[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; ++i) {
            Token memory t = _tokens[i];
            TokenPriceView memory p = v.tokens[i];
            (p.token, p.routeUsed, p.deviationBps, p.valuationPrice) = (t.token, t.routeUsed, t.deviationBps, t.price);
            (p.legFeeds, p.legUpdatedAt) = (t.feeds, t.updatedAt);
        }
    }
}

/// @notice A debt reserve's DebtOracle: served answer, accepted round, state and the feeds of the route in use.
contract LensDebtOracleMock {
    int256 public latestAnswer;
    PriceState public state;
    uint256 public accepted;
    uint64 public acceptedAt;
    address[2] internal _feeds;
    // The oracle's own gates beyond the state (sequencer down or not ready, an alternate past its borrow age).
    bool public extraLiquidationPause;
    bool public extraBorrowStop;

    constructor(
        int256 answer,
        address feed0,
        address feed1
    ) {
        latestAnswer = answer;
        accepted = uint256(answer);
        acceptedAt = uint64(block.timestamp);
        _feeds = [feed0, feed1];
    }

    function set(
        int256 answer,
        PriceState s,
        uint256 accepted_,
        uint64 at
    ) external {
        (latestAnswer, state, accepted, acceptedAt) = (answer, s, accepted_, at);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function lastAcceptedPrice() external view returns (uint256, uint64) {
        return (accepted, acceptedAt);
    }

    /// @notice Closes liquidation or borrowing the way the real oracle does while its state stays Live.
    function setGates(
        bool liquidationPaused,
        bool borrowStopped
    ) external {
        (extraLiquidationPause, extraBorrowStop) = (liquidationPaused, borrowStopped);
    }

    function getPriceState() external view returns (OracleDebtView memory v) {
        (v.state, v.answer, v.acceptedAnswer, v.acceptedUpdatedAt) = (state, latestAnswer, accepted, acceptedAt);
        v.legFeeds = _feeds;
        v.liquidationPaused = state != PriceState.Live || extraLiquidationPause;
        v.borrowAllowed = state == PriceState.Live && !extraBorrowStop;
    }
}

/// @notice A First-Loss Reserve's funded balance and First-Loss Reserve minimum.
contract LensCoverageMock {
    uint256 public fundedBalance;
    uint256 public firstLossReserveMinimum;

    function set(
        uint256 funded,
        uint256 minimum
    ) external {
        (fundedBalance, firstLossReserveMinimum) = (funded, minimum);
    }
}

/// @notice IFlashSource premium quote: `ceil(amount × bps / 1e4)`.
contract LensFlashSourceMock {
    uint256 public bps = 5;

    function setBps(
        uint256 v
    ) external {
        bps = v;
    }

    function flashPremium(
        address,
        uint256 amount
    ) external view returns (uint256) {
        return (amount * bps + 9999) / 10_000;
    }
}

/// @notice The Collateralization suites' LPVault with the AMM integration views the Lens reads: the fair composition
/// at the mock's fixed rates and a settable time-weighted depth.
contract LensLPVaultMock is CollLPVaultMock {
    constructor(
        uint32 integrationId,
        address collateralization,
        address lock
    ) CollLPVaultMock(integrationId, collateralization, lock) {}

    function composition(
        uint256,
        uint256 units,
        uint256[] calldata
    ) external view returns (uint256[] memory amounts, bool exact) {
        amounts = new uint256[](rate.length);
        for (uint256 i = 0; i < rate.length; ++i) {
            amounts[i] = units * rate[i] / RATE_SCALE;
        }
        exact = true;
    }

    function riskStatus(
        uint256,
        uint32
    ) external view returns (RiskStatus memory s) {
        (s.depthUnits, s.depthAvailable) = (depth, depthAvailable);
    }

    uint256 public depth;
    bool public depthAvailable;

    function clMarket(
        uint256
    ) external pure returns (ClMarketConfig memory c) {
        (c.fee, c.tickSpacing, c.tickLower, c.tickUpper) = (100, 1, -50, 50);
    }

    function setDepth(
        uint256 units,
        bool available
    ) external {
        (depth, depthAvailable) = (units, available);
    }

    /// @notice The units a pledge of `key` by `owner` would credit; reverts like `receivePosition` for another owner.
    function validatePosition(
        uint256,
        address owner,
        bytes32 key
    ) external view returns (uint128 units) {
        require(positions[key].owner == owner, "NotTokenOwner");
        units = positions[key].units;
    }
}

/// @notice A Spoke answering `FIRST_LOSS_LAYER()` the way a test sets: a well-formed address word, a revert, a word
/// with dirty upper bits, or a 64-byte return.
contract LensFirstLossLayerMock {
    enum Mode {
        Address,
        Revert,
        DirtyWord,
        LongReturn
    }

    Mode public mode;
    address public layer;

    constructor(
        address layer_
    ) {
        layer = layer_;
    }

    function set(
        Mode mode_,
        address layer_
    ) external {
        (mode, layer) = (mode_, layer_);
    }

    fallback() external {
        Mode m = mode;
        uint256 word = uint256(uint160(layer));
        require(m != Mode.Revert, "no FIRST_LOSS_LAYER");
        if (m == Mode.DirtyWord) word |= uint256(1) << 200;
        assembly ("memory-safe") {
            mstore(0, word)
            mstore(32, 0)
            return(0, add(32, mul(32, eq(m, 3))))
        }
    }
}
