// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {FeedDef} from "../../../src/policy/parameter-store/types/FeedDef.sol";
import {OracleInputsLayout} from "../../../src/policy/parameter-store/types/OracleInputsLayout.sol";
import {Market} from "../../../src/types/Market.sol";
import {OracleConfig} from "../../../src/types/OracleConfig.sol";
import {RouteSlot} from "../../../src/types/RouteSlot.sol";
import {SecondSource} from "../../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../../src/types/SecondSourceKind.sol";

/// @notice Behaviour of a mocked read: normal, revert, short (malformed) return, gas burn, oversized return.
enum ReadMode {
    Normal,
    Revert,
    Short,
    BurnGas,
    Huge
}

/// @notice Shared misbehaviour switches for the LPOracle mocks.
abstract contract MisbehavingRead {
    mapping(bytes4 selector => ReadMode) public modeOf;

    function setMode(
        bytes4 selector,
        ReadMode mode
    ) external {
        modeOf[selector] = mode;
    }

    /// @dev Applies the misbehaviour of `selector`, if any; returns normally for `Normal`.
    function _misbehave(
        bytes4 selector
    ) internal view {
        ReadMode m = modeOf[selector];
        if (m == ReadMode.Normal) return;
        if (m == ReadMode.Revert) revert("mock revert");
        if (m == ReadMode.BurnGas) {
            uint256 x = 0;
            while (gasleft() > 1000) {
                x = uint256(keccak256(abi.encode(x)));
            }
        }
        assembly {
            switch m
            case 2 { return(0, 16) }
            case 4 { return(0, 100000) }
            default { return(0, 0) }
        }
    }
}

/// @notice Chainlink aggregator proxy and aggregator in one: rounds, history, phases and bounds.
contract OracleFeedMock is MisbehavingRead {
    uint8 internal dec;
    uint80 public roundId;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    int192 public minAnswer;
    int192 public maxAnswer;
    mapping(uint80 id => uint256 at) public history;
    mapping(uint16 phase => address aggregator) public phaseAggregators;

    constructor(
        uint8 decimals_,
        int192 minAnswer_,
        int192 maxAnswer_
    ) {
        (dec, minAnswer, maxAnswer) = (decimals_, minAnswer_, maxAnswer_);
        roundId = 1;
    }

    function setDecimals(
        uint8 d
    ) external {
        dec = d;
    }

    function setBounds(
        int192 lo,
        int192 hi
    ) external {
        (minAnswer, maxAnswer) = (lo, hi);
    }

    /// @notice Publishes a new round: the previous round's timestamp stays readable through `getRoundData`.
    function push(
        int256 a,
        uint256 at
    ) external {
        history[roundId] = updatedAt;
        roundId += 1;
        (answer, updatedAt, startedAt) = (a, at, at);
        history[roundId] = at;
    }

    /// @notice Sets the current round exactly.
    function setRound(
        uint80 id,
        int256 a,
        uint256 started,
        uint256 at
    ) external {
        (roundId, answer, startedAt, updatedAt) = (id, a, started, at);
        history[id] = at;
    }

    function setHistory(
        uint80 id,
        uint256 at
    ) external {
        history[id] = at;
    }

    function setPhaseAggregator(
        uint16 phase,
        address aggregator_
    ) external {
        phaseAggregators[phase] = aggregator_;
    }

    function decimals() external view returns (uint8) {
        _misbehave(this.decimals.selector);
        return dec;
    }

    function aggregator() external view returns (address) {
        return address(this);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        _misbehave(this.latestRoundData.selector);
        return (roundId, answer, startedAt, updatedAt, roundId);
    }

    function getRoundData(
        uint80 id
    ) external view returns (uint80, int256, uint256, uint256, uint80) {
        _misbehave(this.getRoundData.selector);
        if (history[id] == 0) revert("no round");
        return (id, answer, history[id], history[id], id);
    }
}

/// @notice ERC-20 decimals only.
contract OracleTokenMock is MisbehavingRead {
    uint8 internal dec;

    constructor(
        uint8 d
    ) {
        dec = d;
    }

    function setDecimals(
        uint8 d
    ) external {
        dec = d;
    }

    function decimals() external view returns (uint8) {
        _misbehave(this.decimals.selector);
        return dec;
    }
}

/// @notice MarketRegistry reads of the LPOracle: routes in force, route versions, the feed's market.
contract OracleRegistryMock is MisbehavingRead {
    struct Routes {
        address[] primary;
        address[] alternate;
        RouteSlot replaced;
        uint64 version;
    }

    mapping(address token => Routes) internal routes;
    mapping(address oracle => uint256 id) public marketOfLpOracle;
    mapping(uint256 id => bytes encoded) internal markets;

    function setRoutes(
        address token,
        address[] calldata primary,
        address[] calldata alternate,
        RouteSlot replaced
    ) external {
        Routes storage r = routes[token];
        (r.primary, r.alternate, r.replaced) = (primary, alternate, replaced);
    }

    function setVersion(
        address token,
        uint64 version
    ) external {
        routes[token].version = version;
    }

    function bumpVersion(
        address token
    ) external {
        routes[token].version += 1;
    }

    function setMarketOf(
        address oracle,
        uint256 id,
        Market calldata m
    ) external {
        marketOfLpOracle[oracle] = id;
        markets[id] = abi.encode(m);
    }

    function activePriceRoutes(
        address token
    ) external view returns (address[] memory, address[] memory, RouteSlot) {
        _misbehave(this.activePriceRoutes.selector);
        Routes storage r = routes[token];
        return (r.primary, r.alternate, r.replaced);
    }

    function priceRouteVersion(
        address token
    ) external view returns (uint64) {
        _misbehave(this.priceRouteVersion.selector);
        return routes[token].version;
    }

    function getMarket(
        uint256 id
    ) external view returns (Market memory) {
        bytes memory b = markets[id];
        assembly {
            return(add(b, 0x20), mload(b))
        }
    }
}

/// @notice ParameterStore reads of the LPOracle: the oracle configuration, the evaluation inputs (`getOracleInputs`,
/// built from the configuration, the registry mock's routes in force and the feed definitions), feed definitions and
/// the margin. A misbehaving `getFeed` also fails `getOracleInputs`, as a failed feed-definition read would.
contract OracleStoreMock is MisbehavingRead {
    bytes internal config;
    mapping(address feed => FeedDef) internal feeds;
    uint16 public margin = 50;
    OracleRegistryMock public registry;
    uint256[10] internal head;
    uint16[] internal tolerances;
    SecondSource[] internal secondList;

    function setRegistry(
        OracleRegistryMock r
    ) external {
        registry = r;
    }

    function setConfig(
        OracleConfig calldata c
    ) external {
        config = abi.encode(c);
        head = [
            c.marketId,
            c.twapWindow,
            c.consistencyToleranceBps,
            c.usdBandLow,
            c.usdBandHigh,
            c.cachedWindow,
            c.disagreementPauseMax,
            c.graceDuration,
            uint160(c.sequencer.feed),
            c.sequencer.gracePeriod
        ];
        delete tolerances;
        delete secondList;
        for (uint256 i = 0; i < c.tokens.length; ++i) {
            tolerances.push(c.tokens[i].feedAgreementToleranceBps);
            secondList.push(c.tokens[i].secondSource);
        }
    }

    function getOracleInputs(
        address,
        address[] calldata tokens,
        bool withSecondSources
    ) external view returns (uint256[] memory w) {
        _misbehave(this.getOracleInputs.selector);
        uint256 stride = OracleInputsLayout.TOKEN_WORDS + (withSecondSources ? OracleInputsLayout.SECOND_WORDS : 0);
        w = new uint256[](OracleInputsLayout.HEAD_WORDS + tokens.length * stride);
        for (uint256 i = 0; i < 10; ++i) {
            w[i] = head[i];
        }
        for (uint256 i = 0; i < tokens.length; ++i) {
            uint256 k = OracleInputsLayout.HEAD_WORDS + i * stride;
            _token(w, k, tokens[i], i);
            if (withSecondSources && i < secondList.length) _second(w, k + OracleInputsLayout.TOKEN_WORDS, i);
        }
    }

    function _token(
        uint256[] memory w,
        uint256 k,
        address token,
        uint256 i
    ) internal view {
        (address[] memory p, address[] memory a, RouteSlot replaced) = registry.activePriceRoutes(token);
        w[k] = i < tolerances.length ? tolerances[i] : 0;
        w[k + 1] = registry.priceRouteVersion(token);
        w[k + 2] = uint8(replaced);
        (w[k + 3], w[k + 4]) = (p.length, a.length);
        _legs(w, k + 5, p);
        _legs(w, k + 5 + 2 * OracleInputsLayout.LEG_WORDS, a);
    }

    function _second(
        uint256[] memory w,
        uint256 k,
        uint256 i
    ) internal view {
        SecondSource memory s = secondList[i];
        (w[k], w[k + 1], w[k + 2]) = (uint8(s.kind), uint160(s.source), uint256(s.poolRef));
        (w[k + 3], w[k + 4], w[k + 5]) = (s.maxAge, s.twapWindow, s.toleranceBps);
        if (s.kind != SecondSourceKind.OracleNetwork) return;
        FeedDef memory d = _def(s.source);
        (w[k + 6], w[k + 7], w[k + 8]) = (d.decimals, uint256(d.minAnswer), uint256(d.maxAnswer));
    }

    function _legs(
        uint256[] memory w,
        uint256 k,
        address[] memory route
    ) internal view {
        if (route.length > 2) return;
        for (uint256 l = 0; l < route.length; ++l) {
            uint256 at = k + l * OracleInputsLayout.LEG_WORDS;
            FeedDef memory d = _def(route[l]);
            (w[at], w[at + 1]) = (uint160(route[l]), d.decimals);
            (w[at + 2], w[at + 3]) = (uint256(d.minAnswer), uint256(d.maxAnswer));
            (w[at + 4], w[at + 5]) = (d.feedHeartbeat, d.heartbeatMargin);
            (w[at + 6], w[at + 7]) = (d.borrowPriceMaxAge, d.liquidationPriceMaxAge);
        }
    }

    /// @dev A feed definition as `getFeed` serves it; a misbehaving `getFeed` reverts the whole read.
    function _def(
        address feed
    ) internal view returns (FeedDef memory) {
        if (modeOf[this.getFeed.selector] != ReadMode.Normal) revert("mock getFeed");
        return feeds[feed];
    }

    function setRawConfig(
        bytes calldata raw
    ) external {
        config = raw;
    }

    function setFeed(
        address feed,
        FeedDef calldata d
    ) external {
        feeds[feed] = d;
    }

    function setMargin(
        uint16 m
    ) external {
        margin = m;
    }

    function getOracleConfig(
        address
    ) external view returns (OracleConfig memory) {
        _misbehave(this.getOracleConfig.selector);
        bytes memory b = config;
        assembly {
            return(add(b, 0x20), mload(b))
        }
    }

    function getFeed(
        address feed
    ) external view returns (FeedDef memory) {
        _misbehave(this.getFeed.selector);
        return feeds[feed];
    }

    function feedAgreementMarginBps() external view returns (uint16) {
        return margin;
    }
}
