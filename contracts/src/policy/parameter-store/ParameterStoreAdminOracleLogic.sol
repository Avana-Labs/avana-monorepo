// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Market} from "../../types/Market.sol";
import {OracleConfig} from "../../types/OracleConfig.sol";
import {OracleLeg} from "../../types/OracleLeg.sol";
import {OracleRoute} from "../../types/OracleRoute.sol";
import {TokenOracleConfig} from "../../types/TokenOracleConfig.sol";
import {IParameterStoreLogic} from "./IParameterStoreLogic.sol";
import {ParameterStoreRisk} from "./ParameterStoreRisk.sol";
import {ParameterStoreStorage} from "./ParameterStoreStorage.sol";
import {FeedDef} from "./types/FeedDef.sol";
import {MarketParams} from "./types/MarketParams.sol";

/// @title ParameterStoreAdminOracleLogic
/// @notice Bodies of the structural setters of the oracle configuration: feed age limits, tolerances, the consistency window, the USD band, the Cached and disagreement timers, grace and the feed-agreement margin. Normal delay, either direction.
/// @dev Each setter writes, then re-runs `checkConfig` of every LPOracle whose configuration it changes (`OracleConfigRejected`), so no LPOracle is left with a configuration it refuses. Reached only by delegatecall from the ParameterStore, which checks the caller's role; see
/// `IParameterStoreLogic`.
/// @custom:spec REQ-CONFIG-049, REQ-CONFIG-052, REQ-CONFIG-054, REQ-CONFIG-055, REQ-PSTORE-009, SPEC-GOV-012
// Each function here carries the body of a selector declared in an IParameterStore piece, which the ParameterStore
// itself implements; this contract inherits only a piece it implements in full, since each other piece also declares
// functions another contract serves.
// solhint-disable comprehensive-interface
// Every external call made by these setters is a view (STATICCALL), so none can re-enter the store or reorder its
// events; the events follow the checks that need those reads.
// forge-lint: disable-start(reentrancy-events)
contract ParameterStoreAdminOracleLogic is ParameterStoreRisk, IParameterStoreLogic {
    /// @notice Fixes the implementation immutables; they must equal the ParameterStore's.
    /// @param timelock The chain's AvanaTimelock.
    /// @param marketRegistry The chain's MarketRegistry proxy.
    /// @param chainBlockTime Seconds per block.
    /// @param hasSequencer Whether the chain runs an L2 sequencer.
    /// @custom:spec REQ-PSTORE-001
    constructor(
        address timelock,
        address marketRegistry,
        uint32 chainBlockTime,
        bool hasSequencer
    ) ParameterStoreStorage(timelock, marketRegistry, chainBlockTime, hasSequencer) {}

    /// @inheritdoc IParameterStoreLogic
    /// @custom:spec REQ-PSTORE-001
    function logicConfig()
        external
        view
        override
        returns (bytes32 kind, address timelock, address marketRegistry, uint32 chainBlockTime, bool hasSequencer)
    {
        return (keccak256("ParameterStoreAdminOracleLogic"), _TIMELOCK, address(_REGISTRY), _BLOCK_TIME, _HAS_SEQUENCER);
    }

    /// @notice Body of `IParameterStoreAdmin.setBorrowPriceMaxAge`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-CONFIG-023, REQ-CONFIG-054, REQ-PSTORE-009, SPEC-ORC-019
    function setBorrowPriceMaxAge(
        address feed,
        uint32 value
    ) external {
        _onlyDelegated();
        FeedDef storage d = _feed(feed);
        if (value == 0 || value > d.feedMaxAge) revert OutOfBounds();
        d.borrowPriceMaxAge = value;
        // An age limit moves no tolerance bound, so only the LPOracles' checks run again.
        _recheck(SCOPE_FEED, feed, false);
        _emitFeed(feed, d);
    }

    /// @notice Body of `IParameterStoreAdmin.setConsistencyToleranceBps`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-CONFIG-052, REQ-CONFIG-054, REQ-PSTORE-009, SPEC-GOV-012
    function setConsistencyToleranceBps(
        uint256 marketId,
        uint16 value
    ) external {
        _onlyDelegated();
        Market memory m = _market(marketId);
        if (value < CONSISTENCY_MIN_BPS) revert LivenessBound();
        if (value > BPS) revert OutOfBounds();
        MarketParams storage p = _s().market[marketId];
        uint16 old = p.consistencyToleranceBps;
        p.consistencyToleranceBps = value;
        if (_configured(m.status)) _checkLpOracle(m.lpOracle);
        emit ParameterSet("consistencyToleranceBps", bytes32(marketId), old, value);
    }

    /// @notice Body of `IParameterStoreAdmin.setFeedAgreementToleranceBps`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-CONFIG-024, REQ-CONFIG-054, REQ-PSTORE-009
    function setFeedAgreementToleranceBps(
        address token,
        uint16 value
    ) external {
        _onlyDelegated();
        _requireListedToken(token);
        if (value < _toleranceMin(token)) revert LivenessBound();
        if (value > BPS) revert OutOfBounds();
        uint16 old = _s().feedAgreementToleranceBps[token];
        _s().feedAgreementToleranceBps[token] = value;
        _recheck(SCOPE_TOKEN, token, false);
        emit ParameterSet("feedAgreementToleranceBps", _a(token), old, value);
    }

    /// @notice Body of `IParameterStoreAdmin.setCachedWindow`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-CONFIG-049, REQ-PSTORE-009, Q-183
    function setCachedWindow(
        uint32 value
    ) external {
        _onlyDelegated();
        if (value == 0) revert OutOfBounds();
        uint32 old = _s().g.cachedWindow;
        _s().g.cachedWindow = value;
        _recheck(SCOPE_ALL, address(0), false);
        emit ParameterSet("cachedWindow", bytes32(0), old, value);
    }

    /// @notice Body of `IParameterStoreAdmin.setDisagreementPauseMax`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-CONFIG-052, REQ-PSTORE-009, Q-183
    function setDisagreementPauseMax(
        uint32 value
    ) external {
        _onlyDelegated();
        if (value > DISAGREEMENT_PAUSE_MAX) revert LivenessBound();
        uint32 old = _s().g.disagreementPauseMax;
        _s().g.disagreementPauseMax = value;
        _recheck(SCOPE_ALL, address(0), false);
        emit ParameterSet("disagreementPauseMax", bytes32(0), old, value);
    }

    /// @notice Body of `IParameterStoreAdmin.setTwapWindow`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-CONFIG-038, REQ-CONFIG-054, REQ-PSTORE-009, REQ-PSTORE-027
    function setTwapWindow(
        uint256 marketId,
        uint32 value
    ) external {
        _onlyDelegated();
        Market memory m = _market(marketId);
        _checkTwap(marketId, m, value);
        MarketParams storage p = _s().market[marketId];
        uint32 old = p.twapWindow;
        p.twapWindow = value;
        if (_configured(m.status)) _checkLpOracle(m.lpOracle);
        emit ParameterSet("twapWindow", bytes32(marketId), old, value);
    }

    /// @notice Body of `IParameterStoreAdmin.setUsdBand`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-CONFIG-055, REQ-CONFIG-054, REQ-PSTORE-009
    function setUsdBand(
        uint256 low,
        uint256 high
    ) external {
        _onlyDelegated();
        if (low >= ONE_USD || high <= ONE_USD) revert OutOfBounds();
        uint256 oldLow = _s().g.usdBandLow;
        uint256 oldHigh = _s().g.usdBandHigh;
        _s().g.usdBandLow = low;
        _s().g.usdBandHigh = high;
        _recheck(SCOPE_ALL, address(0), false);
        emit ParameterSet("usdBandLow", bytes32(0), oldLow, low);
        emit ParameterSet("usdBandHigh", bytes32(0), oldHigh, high);
    }

    /// @notice Body of `IParameterStoreAdmin.setLiquidationPriceMaxAge`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-CONFIG-023, REQ-CONFIG-052, SPEC-ORC-019
    function setLiquidationPriceMaxAge(
        address feed,
        uint32 value
    ) external {
        _onlyDelegated();
        FeedDef storage d = _feed(feed);
        uint256 formula = uint256(d.feedHeartbeat) + d.heartbeatMargin;
        if (value < formula) revert LivenessBound();
        if (value > formula) revert OutOfBounds();
        d.liquidationPriceMaxAge = value;
        // An age limit moves no tolerance bound, so only the LPOracles' checks run again.
        _recheck(SCOPE_FEED, feed, false);
        _emitFeed(feed, d);
    }

    /// @notice Body of `IParameterStoreAdmin.setFeedMaxAge`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-CONFIG-023, REQ-CONFIG-054, REQ-ORACLE-002, SPEC-ORC-019
    function setFeedMaxAge(
        address feed,
        uint32 value
    ) external {
        _onlyDelegated();
        FeedDef storage d = _feed(feed);
        if (value != uint256(d.feedHeartbeat) + d.heartbeatMargin) revert OutOfBounds();
        d.feedMaxAge = value;
        // An age limit moves no tolerance bound, so only the LPOracles' checks run again.
        _recheck(SCOPE_FEED, feed, false);
        _emitFeed(feed, d);
    }

    /// @notice Body of `IParameterStoreAdmin.setGraceDuration`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-CONFIG-052, REQ-PSTORE-009, SPEC-GOV-012, Q-246
    function setGraceDuration(
        uint32 value
    ) external {
        _onlyDelegated();
        if (value > GRACE_DURATION_MAX) revert LivenessBound();
        uint32 old = _s().g.graceDuration;
        _s().g.graceDuration = value;
        _recheck(SCOPE_ALL, address(0), false);
        emit ParameterSet("graceDuration", bytes32(0), old, value);
    }

    /// @notice Body of `IParameterStoreAdmin.setGraceHealthFactor`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-CONFIG-052, SPEC-GOV-012, Q-246
    function setGraceHealthFactor(
        uint256 value
    ) external {
        _onlyDelegated();
        if (value < GRACE_HF_MIN || value >= WAD) revert LivenessBound();
        uint256 old = _s().g.graceHealthFactor;
        _s().g.graceHealthFactor = value;
        emit ParameterSet("graceHealthFactor", bytes32(0), old, value);
    }

    /// @notice Body of `IParameterStoreAdmin.setFeedAgreementMarginBps`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-CONFIG-024, REQ-CONFIG-049
    function setFeedAgreementMarginBps(
        uint16 value
    ) external {
        _onlyDelegated();
        if (value > BPS) revert OutOfBounds();
        uint16 old = _s().g.feedAgreementMarginBps;
        _s().g.feedAgreementMarginBps = value;
        _recheck(SCOPE_ALL, address(0), true);
        emit ParameterSet("feedAgreementMarginBps", bytes32(0), old, value);
    }

    // The loop below reads each token's routes in force from the MarketRegistry with view calls; its length is the
    // market's token count, at most MAX_POOL_TOKENS (8).
    // forge-lint: disable-start(calls-loop)
    /// @notice Body of `IParameterStoreViews.getOracleConfig`, run by delegatecall from the ParameterStore's view.
    /// @custom:spec REQ-CONFIG-072, REQ-PSTORE-011
    function getOracleConfig(
        address lpOracle
    ) external view returns (OracleConfig memory config) {
        _onlyDelegated();
        uint256 marketId = _REGISTRY.marketOfLpOracle(lpOracle);
        if (marketId == 0) return config;
        config = _buildConfig(marketId, _REGISTRY.getMarket(marketId));
    }

    /// @dev Builds the configuration of market `marketId` from storage: routes in force, legs from the feed
    /// definitions, each token's tolerance and second source in force, the market's window and tolerance, and the
    /// chain's band, timers and sequencer check.
    /// @custom:spec REQ-CONFIG-072, REQ-PSTORE-011, REQ-PSTORE-029
    function _buildConfig(
        uint256 marketId,
        Market memory m
    ) private view returns (OracleConfig memory c) {
        Layout storage $ = _s();
        MarketParams storage p = $.market[marketId];
        uint256 n = m.tokens.length;
        c.marketId = marketId;
        c.tokens = new TokenOracleConfig[](n);
        for (uint256 i = 0; i < n; ++i) {
            address token = m.tokens[i];
            // The replaced slot is not part of OracleConfig: the routes returned are already the ones in force.
            // forge-lint: disable-next-line(unused-return)
            (address[] memory primary, address[] memory alternate,) = _REGISTRY.activePriceRoutes(token);
            TokenOracleConfig memory t = c.tokens[i];
            t.token = token;
            t.routes[0] = _route(primary);
            t.routes[1] = _route(alternate);
            t.feedAgreementToleranceBps = $.feedAgreementToleranceBps[token];
            t.secondSource = $.onStandby[token] ? $.standby[token] : $.secondSource[token];
        }
        c.twapWindow = p.twapWindow;
        c.twapMinObservations = _twapMinObservations(p.twapWindow);
        c.consistencyToleranceBps = p.consistencyToleranceBps;
        c.maxQuoteChangeBps = MAX_QUOTE_CHANGE_BPS;
        c.usdBandLow = $.g.usdBandLow;
        c.usdBandHigh = $.g.usdBandHigh;
        c.cachedWindow = $.g.cachedWindow;
        c.disagreementPauseMax = $.g.disagreementPauseMax;
        c.graceDuration = $.g.graceDuration;
        c.sequencer = $.sequencer;
    }

    /// @dev A route of one or two legs; any other length is returned with `legCount = 0`, which no LPOracle uses.
    function _route(
        address[] memory feeds
    ) private view returns (OracleRoute memory r) {
        uint256 n = feeds.length;
        if (n == 0 || n > 2) return r;
        // n is 1 or 2 here.
        // forge-lint: disable-next-line(unsafe-typecast)
        r.legCount = uint8(n);
        for (uint256 i = 0; i < n; ++i) {
            FeedDef storage d = _s().feeds[feeds[i]];
            OracleLeg memory l = r.legs[i];
            l.aggregator = feeds[i];
            l.decimals = d.decimals;
            l.heartbeat = d.feedHeartbeat;
            // setFeed bounds the margin by MAX_HEARTBEAT_MARGIN (3,600), so it fits uint16.
            // forge-lint: disable-next-line(unsafe-typecast)
            l.heartbeatMargin = uint16(d.heartbeatMargin);
            l.feedDeviationThresholdBps = d.feedDeviationThresholdBps;
            l.minAnswer = _clamp(d.minAnswer);
            l.maxAnswer = _clamp(d.maxAnswer);
            l.borrowPriceMaxAge = d.borrowPriceMaxAge;
            l.liquidationPriceMaxAge = d.liquidationPriceMaxAge;
        }
    }

    /// @dev Saturates a pinned bound into `int128`: a minimum below the range rises and a maximum above it falls, so
    /// the leg accepts no answer the aggregator's own bounds reject.
    /// @custom:spec REQ-CONFIG-072
    function _clamp(
        int256 v
    ) private pure returns (int128) {
        if (v > type(int128).max) return type(int128).max;
        if (v < type(int128).min) return type(int128).min;
        // v is within the int128 range after the two checks above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int128(v);
    }
    // forge-lint: disable-end(calls-loop)
}
// forge-lint: disable-end(reentrancy-events)
