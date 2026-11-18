// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleConfig} from "../../types/OracleConfig.sol";
import {RouteSlot} from "../../types/RouteSlot.sol";
import {SecondSource} from "../../types/SecondSource.sol";
import {SecondSourceKind} from "../../types/SecondSourceKind.sol";
import {IParameterStoreRiskViews} from "./IParameterStoreRiskViews.sol";
import {IParameterStoreViews} from "./IParameterStoreViews.sol";
import {ParameterStoreRouter} from "./ParameterStoreRouter.sol";
import {DebtReserveParams} from "./types/DebtReserveParams.sol";
import {FeedDef} from "./types/FeedDef.sol";
import {MarketParams} from "./types/MarketParams.sol";
import {OracleInputsLayout} from "./types/OracleInputsLayout.sol";

/// @title ParameterStoreViews
/// @notice Read access to every market, token, feed, cap and global parameter, the liveness bounds and constants.
/// @dev Views return zeros for an unknown key, so age and usability checks that read them fail closed.
// Loop lengths are the registry's size, which only timelock operations grow.
// forge-lint: disable-start(calls-loop)
abstract contract ParameterStoreViews is ParameterStoreRouter, IParameterStoreViews, IParameterStoreRiskViews {
    /// @inheritdoc IParameterStoreViews
    function getMarketParams(
        uint256 marketId
    ) external view override returns (MarketParams memory params) {
        params = _s().market[marketId];
    }

    /// @inheritdoc IParameterStoreViews
    function feedAgreementToleranceBps(
        address token
    ) external view override returns (uint16 bps) {
        bps = _s().feedAgreementToleranceBps[token];
    }

    /// @inheritdoc IParameterStoreViews
    function tokenCollateralFactorBps(
        address token
    ) external view override returns (uint16 bps) {
        bps = _s().tokenCollateralFactorBps[token];
    }

    /// @inheritdoc IParameterStoreViews
    function getFeed(
        address feed
    ) external view override returns (FeedDef memory def) {
        def = _s().feeds[feed];
    }

    /// @inheritdoc IParameterStoreViews
    function slippageAllowanceMinBps(
        uint256 marketId
    ) external view override returns (uint16 bps) {
        bps = _s().market[marketId].slippageAllowanceMinBps;
    }

    /// @inheritdoc IParameterStoreViews
    function feedAgreementToleranceMinBps(
        address token
    ) external view override returns (uint16 bps) {
        bps = _toleranceMin(token);
    }

    /// @inheritdoc IParameterStoreViews
    /// @dev Runs in the oracle-admin logic, whose return data ends the call; the `return` below is not reached.
    function getOracleConfig(
        address
    ) external view override returns (OracleConfig memory config) {
        _forwardView(_ADMIN_ORACLE_LOGIC);
        return config;
    }

    /// @inheritdoc IParameterStoreViews
    function getOracleInputs(
        address lpOracle,
        address[] calldata tokens,
        bool withSecondSources
    ) external view override returns (uint256[] memory w) {
        uint256 stride = OracleInputsLayout.TOKEN_WORDS + (withSecondSources ? OracleInputsLayout.SECOND_WORDS : 0);
        w = new uint256[](OracleInputsLayout.HEAD_WORDS + tokens.length * stride);
        uint256 marketId = _REGISTRY.marketOfLpOracle(lpOracle);
        if (marketId == 0) return w;
        Layout storage $ = _s();
        MarketParams storage p = $.market[marketId];
        (w[0], w[1], w[2]) = (marketId, p.twapWindow, p.consistencyToleranceBps);
        (w[3], w[4]) = _usdBand(marketId);
        (w[5], w[6], w[7]) = ($.g.cachedWindow, $.g.disagreementPauseMax, $.g.graceDuration);
        (w[8], w[9]) = (uint160($.sequencer.feed), $.sequencer.gracePeriod);
        for (uint256 i = 0; i < tokens.length; ++i) {
            _tokenInputs(w, OracleInputsLayout.HEAD_WORDS + i * stride, tokens[i], withSecondSources);
        }
    }

    /// @inheritdoc IParameterStoreViews
    function borrowPriceMaxAge(
        address feed
    ) external view override returns (uint32 age) {
        age = _s().feeds[feed].borrowPriceMaxAge;
    }

    /// @inheritdoc IParameterStoreViews
    function liquidationPriceMaxAge(
        address feed
    ) external view override returns (uint32 age) {
        age = _s().feeds[feed].liquidationPriceMaxAge;
    }

    /// @inheritdoc IParameterStoreViews
    function hardHealthFloor(
        uint256 marketId
    ) external view override returns (uint256 value) {
        value = _s().market[marketId].hardHealthFloor;
    }

    /// @inheritdoc IParameterStoreViews
    function cachedWindow() external view override returns (uint32 value) {
        value = _s().g.cachedWindow;
    }

    /// @inheritdoc IParameterStoreViews
    function disagreementPauseMax() external view override returns (uint32 value) {
        value = _s().g.disagreementPauseMax;
    }

    /// @inheritdoc IParameterStoreViews
    function usdBandLow() external view override returns (uint256 value) {
        value = _s().g.usdBandLow;
    }

    /// @inheritdoc IParameterStoreViews
    function usdBandHigh() external view override returns (uint256 value) {
        value = _s().g.usdBandHigh;
    }

    /// @inheritdoc IParameterStoreViews
    function graceDuration() external view override returns (uint32 value) {
        value = _s().g.graceDuration;
    }

    /// @inheritdoc IParameterStoreViews
    function graceHealthFactor() external view override returns (uint256 value) {
        value = _s().g.graceHealthFactor;
    }

    /// @inheritdoc IParameterStoreViews
    function maxFlashFeeBps() external view override returns (uint16 value) {
        value = _s().g.maxFlashFeeBps;
    }

    /// @inheritdoc IParameterStoreViews
    function avanaFeeShareBps() external view override returns (uint16 value) {
        value = _s().g.avanaFeeShareBps;
    }

    /// @inheritdoc IParameterStoreViews
    function feeRecipient() external view override returns (address recipient) {
        recipient = _s().g.feeRecipient;
    }

    /// @inheritdoc IParameterStoreViews
    function feedAgreementMarginBps() external view override returns (uint16 value) {
        value = _s().g.feedAgreementMarginBps;
    }

    /// @inheritdoc IParameterStoreViews
    function floorRoundingAllowance(
        address asset
    ) external view override returns (uint256 value) {
        value = _s().floorRoundingAllowance[asset];
    }

    /// @inheritdoc IParameterStoreViews
    function graceHealthFactorMin() external pure override returns (uint256 value) {
        value = GRACE_HF_MIN;
    }

    /// @inheritdoc IParameterStoreViews
    function graceDurationMax() external pure override returns (uint32 value) {
        value = GRACE_DURATION_MAX;
    }

    /// @inheritdoc IParameterStoreViews
    function consistencyToleranceMinBps() external pure override returns (uint16 value) {
        value = CONSISTENCY_MIN_BPS;
    }

    /// @inheritdoc IParameterStoreViews
    function MAX_HEARTBEAT_MARGIN() external pure override returns (uint32 value) {
        value = HEARTBEAT_MARGIN_MAX;
    }

    /// @inheritdoc IParameterStoreViews
    function secondSource(
        address token
    ) external view override returns (SecondSource memory source) {
        source = _s().onStandby[token] ? _s().standby[token] : _s().secondSource[token];
    }

    /// @inheritdoc IParameterStoreViews
    function standbySecondSource(
        address token
    ) external view override returns (SecondSource memory source) {
        source = _s().standby[token];
    }

    /// @inheritdoc IParameterStoreViews
    function onStandby(
        address token
    ) external view override returns (bool active) {
        active = _s().onStandby[token];
    }

    /// @inheritdoc IParameterStoreViews
    function lastLoosenedAt(
        bytes32 paramKey
    ) external view override returns (uint64 at) {
        at = _s().lastLoosenedAt[paramKey];
    }

    /// @inheritdoc IParameterStoreViews
    function LOOSEN_HEALTH_FACTOR_STEP() external pure override returns (uint256 value) {
        value = HF_STEP;
    }

    /// @inheritdoc IParameterStoreViews
    function LOOSEN_CAP_STEP_BPS() external pure override returns (uint16 value) {
        value = CAP_STEP_BPS;
    }

    /// @inheritdoc IParameterStoreViews
    function LOOSEN_SLIPPAGE_STEP_BPS() external pure override returns (uint16 value) {
        value = SLIPPAGE_STEP_BPS;
    }

    /// @inheritdoc IParameterStoreViews
    function TIMELOCK() external view override returns (address timelock) {
        timelock = _TIMELOCK;
    }

    /// @inheritdoc IParameterStoreRiskViews
    function marketUsdCap(
        uint256 marketId
    ) external view override returns (uint256 value) {
        value = _s().marketUsdCap[marketId];
    }

    /// @inheritdoc IParameterStoreRiskViews
    function topUpSliceUsd(
        uint256 marketId
    ) external view override returns (uint256 value) {
        value = _s().topUpSliceUsd[marketId];
    }

    /// @inheritdoc IParameterStoreRiskViews
    function stressFloorUsd(
        uint256 marketId
    ) external view override returns (uint256 value) {
        value = _s().stressFloorUsd[marketId];
    }

    /// @inheritdoc IParameterStoreRiskViews
    function tokenUsdCap(
        address hub,
        address token
    ) external view override returns (uint256 value) {
        value = _s().tokenUsdCap[hub][token];
    }

    /// @inheritdoc IParameterStoreRiskViews
    function poolShareMaxBps() external view override returns (uint16 value) {
        value = _s().poolShareMaxBps;
    }

    /// @inheritdoc IParameterStoreRiskViews
    function minPledgeUsd(
        uint256 marketId
    ) external view override returns (uint256 value) {
        value = _s().market[marketId].minPledgeUsd;
    }

    /// @inheritdoc IParameterStoreRiskViews
    function debtAssetParams(
        address asset
    ) external view override returns (DebtReserveParams memory p) {
        p.floorRoundingAllowance = _s().floorRoundingAllowance[asset];
    }

    /// @inheritdoc IParameterStoreRiskViews
    function routeDepthThreshold(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind
    ) external view override returns (uint256 value) {
        value = _s().routeDepth[keccak256(abi.encode(marketId, token, debtAsset, kind))];
    }

    /// @inheritdoc IParameterStoreRiskViews
    function MARKET_REGISTRY() external view override returns (address registry) {
        registry = address(_REGISTRY);
    }

    /// @inheritdoc IParameterStoreRiskViews
    function poolShareMaxBpsOf(
        bytes32 poolKey
    ) external view override returns (uint16 value) {
        value = _poolShareOf(poolKey);
    }

    function _tokenInputs(
        uint256[] memory w,
        uint256 k,
        address token,
        bool withSecondSource
    ) private view {
        Layout storage $ = _s();
        (address[] memory primary, address[] memory alternate, RouteSlot replaced) = _REGISTRY.activePriceRoutes(token);
        (w[k], w[k + 1], w[k + 2]) =
        ($.feedAgreementToleranceBps[token], _REGISTRY.priceRouteVersion(token), uint256(replaced));
        (w[k + 3], w[k + 4]) = (primary.length, alternate.length);
        _legInputs(w, k + 5, primary);
        _legInputs(w, k + 5 + 2 * OracleInputsLayout.LEG_WORDS, alternate);
        if (!withSecondSource) return;
        k += OracleInputsLayout.TOKEN_WORDS;
        SecondSource storage s = $.onStandby[token] ? $.standby[token] : $.secondSource[token];
        (w[k], w[k + 1], w[k + 2]) = (uint256(s.kind), uint160(s.source), uint256(s.poolRef));
        (w[k + 3], w[k + 4], w[k + 5]) = (s.maxAge, s.twapWindow, s.toleranceBps);
        if (s.kind != SecondSourceKind.OracleNetwork) return;
        FeedDef storage d = $.feeds[s.source];
        // Two's complement words of the signed bounds, as the ABI encodes an int256.
        // forge-lint: disable-next-line(unsafe-typecast)
        (w[k + 6], w[k + 7], w[k + 8]) = (d.decimals, uint256(d.minAnswer), uint256(d.maxAnswer));
    }

    /// @dev The legs of a route of one or two legs from word `k`; nothing for any other length.
    function _legInputs(
        uint256[] memory w,
        uint256 k,
        address[] memory feeds
    ) private view {
        uint256 n = feeds.length > 2 ? 0 : feeds.length;
        for (uint256 l = 0; l < n; ++l) {
            uint256 at = k + l * OracleInputsLayout.LEG_WORDS;
            FeedDef storage d = _s().feeds[feeds[l]];
            (w[at], w[at + 1]) = (uint160(feeds[l]), d.decimals);
            // Two's complement words of the signed bounds, as the ABI encodes an int256.
            // forge-lint: disable-next-line(unsafe-typecast)
            (w[at + 2], w[at + 3]) = (uint256(d.minAnswer), uint256(d.maxAnswer));
            (w[at + 4], w[at + 5]) = (d.feedHeartbeat, d.heartbeatMargin);
            (w[at + 6], w[at + 7]) = (d.borrowPriceMaxAge, d.liquidationPriceMaxAge);
        }
    }
}
// forge-lint: disable-end(calls-loop)
