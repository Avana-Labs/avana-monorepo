// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Market} from "../../types/Market.sol";
import {OracleConfig} from "../../types/OracleConfig.sol";
import {OracleLeg} from "../../types/OracleLeg.sol";
import {OracleRoute} from "../../types/OracleRoute.sol";
import {TokenOracleConfig} from "../../types/TokenOracleConfig.sol";
import {MarketStatus} from "../market-registry/types/MarketRegistryTypes.sol";
import {IParameterStoreLogic} from "./IParameterStoreLogic.sol";
import {ParameterStoreRisk} from "./ParameterStoreRisk.sol";
import {ParameterStoreStorage} from "./ParameterStoreStorage.sol";
import {FeedDef} from "./types/FeedDef.sol";
import {MarketParams} from "./types/MarketParams.sol";

/// @title ParameterStoreAdminOracleLogic
/// @notice Bodies of the structural oracle setters and the views `getOracleConfig` and `liquidationLivenessHolds`.
/// @dev Runs only by delegatecall from the ParameterStore, which checks the caller's role.
// Bodies of selectors the ParameterStore declares; only fully implemented pieces are inherited.
// solhint-disable comprehensive-interface
// Every external call here is a view (STATICCALL), so none can re-enter the store or reorder its events.
// forge-lint: disable-start(reentrancy-events)
contract ParameterStoreAdminOracleLogic is ParameterStoreRisk, IParameterStoreLogic {
    /// @notice Fixes the implementation immutables; they must equal the ParameterStore's.
    constructor(
        address timelock,
        address marketRegistry,
        uint32 chainBlockTime,
        bool hasSequencer
    ) ParameterStoreStorage(timelock, marketRegistry, chainBlockTime, hasSequencer) {}

    /// @inheritdoc IParameterStoreLogic
    function logicConfig()
        external
        view
        override
        returns (bytes32 kind, address timelock, address marketRegistry, uint32 chainBlockTime, bool hasSequencer)
    {
        return (keccak256("ParameterStoreAdminOracleLogic"), _TIMELOCK, address(_REGISTRY), _BLOCK_TIME, _HAS_SEQUENCER);
    }

    /// @notice Body of `IParameterStoreAdmin.setBorrowPriceMaxAge`.
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

    /// @notice Body of `IParameterStoreAdmin.setConsistencyToleranceBps`.
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

    /// @notice Body of `IParameterStoreAdmin.setFeedAgreementToleranceBps`.
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

    /// @notice Body of `IParameterStoreAdmin.setCachedWindow`.
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

    /// @notice Body of `IParameterStoreAdmin.setDisagreementPauseMax`.
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

    /// @notice Body of `IParameterStoreAdmin.setTwapWindow`.
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

    /// @notice Body of `IParameterStoreAdmin.setUsdBand`.
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

    /// @notice Body of `IParameterStoreAdmin.setLiquidationPriceMaxAge`.
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
        _recheck(SCOPE_FEED, feed, false);
        _emitFeed(feed, d);
    }

    /// @notice Body of `IParameterStoreAdmin.setFeedMaxAge`.
    function setFeedMaxAge(
        address feed,
        uint32 value
    ) external {
        _onlyDelegated();
        FeedDef storage d = _feed(feed);
        if (value != uint256(d.feedHeartbeat) + d.heartbeatMargin) revert OutOfBounds();
        d.feedMaxAge = value;
        _recheck(SCOPE_FEED, feed, false);
        _emitFeed(feed, d);
    }

    /// @notice Body of `IParameterStoreAdmin.setGraceDuration`.
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

    /// @notice Body of `IParameterStoreAdmin.setGraceHealthFactor`.
    function setGraceHealthFactor(
        uint256 value
    ) external {
        _onlyDelegated();
        if (value < GRACE_HF_MIN || value >= WAD) revert LivenessBound();
        uint256 old = _s().g.graceHealthFactor;
        _s().g.graceHealthFactor = value;
        emit ParameterSet("graceHealthFactor", bytes32(0), old, value);
    }

    /// @notice Body of `IParameterStoreAdmin.setFeedAgreementMarginBps`.
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

    /// @notice Body of `IParameterStoreAdmin.setMaxFlashFeeBps`.
    function setMaxFlashFeeBps(
        uint16 value
    ) external {
        _onlyDelegated();
        if (value > FLASH_FEE_MAX_BPS) revert OutOfBounds();
        uint16 old = _s().g.maxFlashFeeBps;
        if (value > old) _requireLivenessEverywhere(value);
        _s().g.maxFlashFeeBps = value;
        emit ParameterSet("maxFlashFeeBps", bytes32(0), old, value);
    }

    /// @notice Body of `IParameterStoreAdmin.setSlippageAllowanceMinBps`.
    function setSlippageAllowanceMinBps(
        uint256 marketId,
        uint16 value
    ) external {
        _onlyDelegated();
        Market memory m = _market(marketId);
        MarketParams storage p = _s().market[marketId];
        uint16 old = p.slippageAllowanceMinBps;
        if (p.slippageAllowanceBps < value) revert LivenessBound();
        if (value > old && _live(m.status)) _requireLiveness(m, value, _s().g.maxFlashFeeBps);
        p.slippageAllowanceMinBps = value;
        emit ParameterSet("slippageAllowanceMinBps", bytes32(marketId), old, value);
    }

    // The loop below makes one registry view call per market token.
    // forge-lint: disable-start(calls-loop)
    /// @notice Body of `IParameterStoreViews.getOracleConfig`.
    function getOracleConfig(
        address lpOracle
    ) external view returns (OracleConfig memory config) {
        _onlyDelegated();
        uint256 marketId = _REGISTRY.marketOfLpOracle(lpOracle);
        if (marketId == 0) return config;
        config = _buildConfig(marketId, _REGISTRY.getMarket(marketId));
    }

    /// @notice Body of `IParameterStoreLiquidation.liquidationLivenessHolds`.
    function liquidationLivenessHolds(
        address spoke,
        uint256 marketId,
        uint256 debtReserveId
    ) external view returns (bool holds) {
        _onlyDelegated();
        Market memory m = _REGISTRY.getMarket(marketId);
        if (m.status == MarketStatus.None || spoke == address(0) || m.spoke != spoke) return false;
        if (!_REGISTRY.isApprovedDebtReserve(spoke, debtReserveId)) return false;
        holds = _inequality(_minLb(m), _s().market[marketId].slippageAllowanceMinBps, _s().g.maxFlashFeeBps);
    }

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
        (c.usdBandLow, c.usdBandHigh) = _usdBand(marketId);
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
            // setFeed bounds the margin by MAX_HEARTBEAT_MARGIN, so it fits uint16.
            // forge-lint: disable-next-line(unsafe-typecast)
            l.heartbeatMargin = uint16(d.heartbeatMargin);
            l.feedDeviationThresholdBps = d.feedDeviationThresholdBps;
            l.minAnswer = _clamp(d.minAnswer);
            l.maxAnswer = _clamp(d.maxAnswer);
            l.borrowPriceMaxAge = d.borrowPriceMaxAge;
            l.liquidationPriceMaxAge = d.liquidationPriceMaxAge;
        }
    }

    /// @dev Saturates into `int128` toward the inside of the range, so the leg accepts nothing the aggregator rejects.
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
