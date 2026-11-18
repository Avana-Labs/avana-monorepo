// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClMarketConfig, RiskStatus} from "../../../src/amm/types/AmmTypes.sol";
import {ILPOracle} from "../../../src/oracle/ILPOracle.sol";
import {DebtReserveDef, MarketStatus} from "../../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {FeedDef} from "../../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {MarketParams} from "../../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {SpeedView} from "../../../src/policy/risk-module/types/RiskModuleTypes.sol";
import {AccountGateStatus, Market} from "../../../src/types/MarketTypes.sol";
import {PriceState} from "../../../src/types/OracleTypes.sol";
import {PledgePreview} from "../../../src/types/PositionTypes.sol";
import {CollLPVaultMock} from "./CollateralizationMocks.sol";
import {DebtPriceView as OracleDebtView} from "./DebtPriceView.sol";

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
    address[] internal _spokes;
    mapping(address => mapping(address => address)) public firstLossReserveOf;
    mapping(address => mapping(address => uint256[3])) internal _coverage;
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

    function setCoverage(
        address hub,
        address asset,
        uint256 drawCapSum,
        uint256 required,
        uint256 funded
    ) external {
        _coverage[hub][asset] = [drawCapSum, required, funded];
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

    function drawCapCoverage(
        address hub,
        address asset
    ) external view returns (uint256 drawCapSum, uint256 required, uint256 funded) {
        uint256[3] storage c = _coverage[hub][asset];
        (drawCapSum, required, funded) = (c[0], c[1], c[2]);
    }
}

/// @notice The ParameterStore views the Lens reads, settable.
contract LensStoreMock {
    mapping(address => uint32) public borrowPriceMaxAge;
    mapping(address => uint32) public liquidationPriceMaxAge;
    mapping(uint256 => MarketParams) internal _params;
    mapping(address => uint256) public floorRoundingAllowance;
    uint16 public avanaFeeShareBps = 2000;
    uint16 public maxFlashFeeBps = 10;
    mapping(uint256 => uint256) public marketUsdCap;
    mapping(uint256 => uint256) public topUpSliceUsd;
    mapping(uint256 => uint256) public stressFloorUsd;
    mapping(address => mapping(address => uint256)) public tokenUsdCap;
    mapping(uint256 => uint256) public minPledgeUsd;
    uint16 public coverageRatioBps = 1000;

    function setAges(
        address feed,
        uint32 borrowAge,
        uint32 liquidationAge
    ) external {
        (borrowPriceMaxAge[feed], liquidationPriceMaxAge[feed]) = (borrowAge, liquidationAge);
    }

    function setMarketParams(
        uint256 id,
        MarketParams memory p
    ) external {
        _params[id] = p;
        minPledgeUsd[id] = p.minPledgeUsd;
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

    function getFeed(
        address feed
    ) external view returns (FeedDef memory d) {
        (d.decimals, d.borrowPriceMaxAge, d.liquidationPriceMaxAge) =
        (8, borrowPriceMaxAge[feed], liquidationPriceMaxAge[feed]);
    }
}

/// @notice The RiskModule views the Lens reads, settable per proxy, market and debt reserve.
contract LensRiskModuleMock {
    struct Gate {
        bool set;
        bool borrowAllowed;
        bool unavailable;
    }

    mapping(address => Gate) internal _gates;
    mapping(uint256 => uint32) internal _marketReasons;
    mapping(address => mapping(uint256 => uint32)) internal _debtReasons;
    mapping(uint256 => uint32) internal _debtReasonsAnySpoke;

    function setGate(
        address proxy,
        bool borrowAllowed,
        bool unavailable
    ) external {
        _gates[proxy] = Gate(true, borrowAllowed, unavailable);
    }

    function setMarketBreaker(
        uint256 id,
        uint32 reasons
    ) external {
        _marketReasons[id] = reasons;
    }

    function setDebtBreaker(
        address spoke,
        uint256 id,
        uint32 reasons
    ) external {
        _debtReasons[spoke][id] = reasons;
        _debtReasonsAnySpoke[id] = reasons;
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
    }

    /// @notice The RiskModule's gates of a borrow: refused when the account's status is unset, unavailable or not
    /// `borrowAllowed`, or a debt breaker is set on the reserve for any Spoke the mock knows (`setDebtBreaker`).
    function checkBorrowGate(
        address proxy,
        uint256 debtReserveId
    ) external view {
        Gate memory g = _gates[proxy];
        require(g.set && !g.unavailable && g.borrowAllowed, "gate");
        require(_debtReasonsAnySpoke[debtReserveId] == 0, "debt breaker");
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
    ) external view returns (uint32) {
        return _marketReasons[id];
    }

    function getDebtBreakerStatus(
        address spoke,
        uint256 id
    ) external view returns (uint32) {
        return _debtReasons[spoke][id];
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

    /// @notice The round time recorded for `feed` on any token's route, 0 for a feed on no route.
    function updatedAtOf(
        address feed
    ) external view returns (uint64) {
        for (uint256 i = 0; i < _tokens.length; ++i) {
            for (uint256 k = 0; k < 2; ++k) {
                if (_tokens[i].feeds[k] == feed) return _tokens[i].updatedAt[k];
            }
        }
        return 0;
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

    function getTokenPrices() external view returns (uint256[] memory prices, uint64 updatedAt) {
        prices = new uint256[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; ++i) {
            prices[i] = _tokens[i].price;
        }
        updatedAt = acceptedAt;
    }

    function getPriceStatus() external view returns (ILPOracle.PriceStatus memory s) {
        (s.answer, s.updatedAt) = (latestAnswer(), acceptedAt);
        s.liquidationFresh = (state == PriceState.Live || state == PriceState.Drifting) && !liquidationPaused
            && !pauseActive && !expired;
        s.borrowFresh = s.liquidationFresh && state == PriceState.Live && borrowAllowed;
    }

    function tokens() external view returns (address[] memory list) {
        list = new address[](_tokens.length);
        for (uint256 i = 0; i < list.length; ++i) {
            list[i] = _tokens[i].token;
        }
    }

    function feedsOf(
        uint256 i
    ) external view returns (address[] memory feeds) {
        uint256 n = (_tokens[i].feeds[0] != address(0) ? 1 : 0) + (_tokens[i].feeds[1] != address(0) ? 1 : 0);
        feeds = new address[](n);
        n = 0;
        for (uint256 k = 0; k < 2; ++k) {
            if (_tokens[i].feeds[k] != address(0)) feeds[n++] = _tokens[i].feeds[k];
        }
    }
}

/// @notice A debt reserve's DebtOracle: served answer, accepted round, state and the feeds of the route in use.
contract LensDebtOracleMock {
    int256 public latestAnswer;
    PriceState public state;
    uint256 public accepted;
    uint64 public acceptedAt;
    // The served route's (and each leg's) source timestamp; follows `acceptedAt` unless set apart, as the real oracle's
    // does between pokes when the feed posts a round the accepted price has not yet taken.
    uint64 public servedAt;
    // The ParameterStore the real oracle reads its legs' age limits from.
    address public store;
    address[2] internal _feeds;
    // The oracle's own gates beyond the state (an input not ready, an alternate past its borrow age).
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
        servedAt = acceptedAt;
        _feeds = [feed0, feed1];
    }

    function setStore(
        address s
    ) external {
        store = s;
    }

    /// @notice The served route's source timestamp alone, the accepted price's left as it is.
    function setServedAt(
        uint64 at
    ) external {
        servedAt = at;
    }

    /// @notice The real oracle's `borrowPriceMaxAge()` for legs updated together: the smallest ParameterStore
    /// `borrowPriceMaxAge(feed)` of the route's feeds, 0 with none.
    function borrowPriceMaxAge() external view returns (uint32 age) {
        if (store == address(0)) return 0;
        age = type(uint32).max;
        bool any;
        for (uint256 i = 0; i < 2; ++i) {
            if (_feeds[i] == address(0)) continue;
            uint256 a = LensStoreMock(store).borrowPriceMaxAge(_feeds[i]);
            if (a < age) age = uint32(a);
            any = true;
        }
        if (!any) age = 0;
    }

    function set(
        int256 answer,
        PriceState s,
        uint256 accepted_,
        uint64 at
    ) external {
        (latestAnswer, state, accepted, acceptedAt, servedAt) = (answer, s, accepted_, at, at);
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
        v.servedUpdatedAt = servedAt;
        for (uint256 i = 0; i < 2; ++i) {
            if (_feeds[i] != address(0)) v.legUpdatedAt[i] = servedAt;
        }
        v.liquidationPaused = state != PriceState.Live || extraLiquidationPause;
        v.borrowAllowed = state == PriceState.Live && !extraBorrowStop;
    }

    /// @notice The debt source as a Chainlink feed: a current round while Live, open and within the route's borrow
    /// age, otherwise a round at time 0.
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint32 maxAge = this.borrowPriceMaxAge();
        bool ok = state == PriceState.Live && !extraLiquidationPause && !extraBorrowStop && servedAt <= block.timestamp
            && (store == address(0) || block.timestamp - servedAt <= maxAge);
        uint256 at = ok ? block.timestamp : 0;
        return (0, latestAnswer, at, at, 0);
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

/// @notice A Chainlink feed whose latest round is dated at the time its LensLPOracleMock records for it; the fixture
/// etches this code onto each listed feed address.
contract LensFeedEcho {
    LensLPOracleMock internal immutable _ORACLE;

    constructor(
        LensLPOracleMock oracle
    ) {
        _ORACLE = oracle;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint64 at = _ORACLE.updatedAtOf(address(this));
        return (1, 1e8, at, at, 1);
    }
}
