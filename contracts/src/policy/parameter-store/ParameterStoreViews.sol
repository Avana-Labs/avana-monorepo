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
/// @dev Every view is `view`, never reverts for a listed key and returns zeros for an unknown one, so every age and
/// usability check that reads it fails closed.
/// @custom:spec REQ-PSTORE-011, REQ-CONFIG-072
// The loops below walk the MarketRegistry's markets, Spokes and debt reserves with view calls at execution of a
// governance setter (or in a view); their length is the registry's size, which only timelock operations grow.
// forge-lint: disable-start(calls-loop)
abstract contract ParameterStoreViews is ParameterStoreRouter, IParameterStoreViews, IParameterStoreRiskViews {
    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-PSTORE-011
    function getMarketParams(
        uint256 marketId
    ) external view override returns (MarketParams memory params) {
        params = _s().market[marketId];
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-CONFIG-024, REQ-CONFIG-057
    function feedAgreementToleranceBps(
        address token
    ) external view override returns (uint16 bps) {
        bps = _s().feedAgreementToleranceBps[token];
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-CONFIG-019, REQ-CONFIG-020
    function tokenCollateralFactorBps(
        address token
    ) external view override returns (uint16 bps) {
        bps = _s().tokenCollateralFactorBps[token];
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-CONFIG-022, REQ-CONFIG-023
    function getFeed(
        address feed
    ) external view override returns (FeedDef memory def) {
        def = _s().feeds[feed];
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-CONFIG-041, REQ-CONFIG-052
    function slippageAllowanceMinBps(
        uint256 marketId
    ) external view override returns (uint16 bps) {
        bps = _s().market[marketId].slippageAllowanceMinBps;
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-CONFIG-024, REQ-CONFIG-052
    function feedAgreementToleranceMinBps(
        address token
    ) external view override returns (uint16 bps) {
        bps = _toleranceMin(token);
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-CONFIG-072, REQ-PSTORE-011
    /// @dev Built in the oracle-admin logic (`ParameterStoreAdminOracleLogic.getOracleConfig`), which this view runs
    /// by delegatecall and whose return data ends the call unchanged; the `return` below is not reached.
    function getOracleConfig(
        address
    ) external view override returns (OracleConfig memory config) {
        _forwardView(_ADMIN_ORACLE_LOGIC);
        return config;
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-PSTORE-033, REQ-CONFIG-072, REQ-PSTORE-011, REQ-PSTORE-029, REQ-ORACLE-094
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
        (w[3], w[4], w[5], w[6], w[7]) =
        ($.g.usdBandLow, $.g.usdBandHigh, $.g.cachedWindow, $.g.disagreementPauseMax, $.g.graceDuration);
        (w[8], w[9]) = (uint160($.sequencer.feed), $.sequencer.gracePeriod);
        for (uint256 i = 0; i < tokens.length; ++i) {
            _tokenInputs(w, OracleInputsLayout.HEAD_WORDS + i * stride, tokens[i], withSecondSources);
        }
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-CONFIG-023, SPEC-ORC-019
    function borrowPriceMaxAge(
        address feed
    ) external view override returns (uint32 age) {
        age = _s().feeds[feed].borrowPriceMaxAge;
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-CONFIG-023
    function liquidationPriceMaxAge(
        address feed
    ) external view override returns (uint32 age) {
        age = _s().feeds[feed].liquidationPriceMaxAge;
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-PSTORE-031, Q-398
    function hardHealthFloor(
        uint256 marketId
    ) external view override returns (uint256 value) {
        value = _s().market[marketId].hardHealthFloor;
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec SPEC-ORC-013
    function cachedWindow() external view override returns (uint32 value) {
        value = _s().g.cachedWindow;
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-ORACLE-022
    function disagreementPauseMax() external view override returns (uint32 value) {
        value = _s().g.disagreementPauseMax;
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec SPEC-ORC-011
    function usdBandLow() external view override returns (uint256 value) {
        value = _s().g.usdBandLow;
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec SPEC-ORC-011
    function usdBandHigh() external view override returns (uint256 value) {
        value = _s().g.usdBandHigh;
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-ORACLE-034
    function graceDuration() external view override returns (uint32 value) {
        value = _s().g.graceDuration;
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-SWAP-009
    function graceHealthFactor() external view override returns (uint256 value) {
        value = _s().g.graceHealthFactor;
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-PSTORE-024
    function maxFlashFeeBps() external view override returns (uint16 value) {
        value = _s().g.maxFlashFeeBps;
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-PSTORE-010
    function avanaFeeShareBps() external view override returns (uint16 value) {
        value = _s().g.avanaFeeShareBps;
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-CONFIG-056
    function feeRecipient() external view override returns (address recipient) {
        recipient = _s().g.feeRecipient;
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-CONFIG-024
    function feedAgreementMarginBps() external view override returns (uint16 value) {
        value = _s().g.feedAgreementMarginBps;
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec SPEC-LIQ-005, Q-380
    function floorRoundingAllowance(
        address asset
    ) external view override returns (uint256 value) {
        value = _s().floorRoundingAllowance[asset];
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-CONFIG-052
    function graceHealthFactorMin() external pure override returns (uint256 value) {
        value = GRACE_HF_MIN;
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-CONFIG-052
    function graceDurationMax() external pure override returns (uint32 value) {
        value = GRACE_DURATION_MAX;
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-CONFIG-052
    function consistencyToleranceMinBps() external pure override returns (uint16 value) {
        value = CONSISTENCY_MIN_BPS;
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-CONFIG-023, SPEC-ORC-019
    function MAX_HEARTBEAT_MARGIN() external pure override returns (uint32 value) {
        value = HEARTBEAT_MARGIN_MAX;
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-PSTORE-028, REQ-PSTORE-029
    function secondSource(
        address token
    ) external view override returns (SecondSource memory source) {
        source = _s().onStandby[token] ? _s().standby[token] : _s().secondSource[token];
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-PSTORE-029
    function standbySecondSource(
        address token
    ) external view override returns (SecondSource memory source) {
        source = _s().standby[token];
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-PSTORE-029
    function onStandby(
        address token
    ) external view override returns (bool active) {
        active = _s().onStandby[token];
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-PSTORE-017
    function lastLoosenedAt(
        bytes32 paramKey
    ) external view override returns (uint64 at) {
        at = _s().lastLoosenedAt[paramKey];
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-PSTORE-017
    function LOOSEN_HEALTH_FACTOR_STEP() external pure override returns (uint256 value) {
        value = HF_STEP;
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-PSTORE-017
    function LOOSEN_CAP_STEP_BPS() external pure override returns (uint16 value) {
        value = CAP_STEP_BPS;
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-PSTORE-017
    function LOOSEN_SLIPPAGE_STEP_BPS() external pure override returns (uint16 value) {
        value = SLIPPAGE_STEP_BPS;
    }

    /// @inheritdoc IParameterStoreViews
    /// @custom:spec REQ-PSTORE-001
    function TIMELOCK() external view override returns (address timelock) {
        timelock = _TIMELOCK;
    }

    /// @inheritdoc IParameterStoreRiskViews
    /// @custom:spec SPEC-CAP-002, REQ-RISK-041
    function marketUsdCap(
        uint256 marketId
    ) external view override returns (uint256 value) {
        value = _s().marketUsdCap[marketId];
    }

    /// @inheritdoc IParameterStoreRiskViews
    /// @custom:spec SPEC-CAP-002, SPEC-CAP-003
    function topUpSliceUsd(
        uint256 marketId
    ) external view override returns (uint256 value) {
        value = _s().topUpSliceUsd[marketId];
    }

    /// @inheritdoc IParameterStoreRiskViews
    /// @custom:spec SPEC-CAP-001, REQ-RISK-045
    function stressFloorUsd(
        uint256 marketId
    ) external view override returns (uint256 value) {
        value = _s().stressFloorUsd[marketId];
    }

    /// @inheritdoc IParameterStoreRiskViews
    /// @custom:spec SPEC-CAP-002, REQ-PSTORE-026
    function tokenUsdCap(
        address hub,
        address token
    ) external view override returns (uint256 value) {
        value = _s().tokenUsdCap[hub][token];
    }

    /// @inheritdoc IParameterStoreRiskViews
    /// @custom:spec SPEC-CAP-002, REQ-PSTORE-026
    function depositorUsdCap(
        address hub
    ) external view override returns (uint256 value) {
        value = _s().depositorUsdCap[hub];
    }

    /// @inheritdoc IParameterStoreRiskViews
    /// @custom:spec SPEC-CAP-005, Q-399, Q-403
    function poolShareMaxBps() external view override returns (uint16 value) {
        value = _s().poolShareMaxBps;
    }

    /// @inheritdoc IParameterStoreRiskViews
    /// @custom:spec REQ-PSTORE-005, Q-230
    function minPledgeUsd(
        uint256 marketId
    ) external view override returns (uint256 value) {
        value = _s().market[marketId].minPledgeUsd;
    }

    /// @inheritdoc IParameterStoreRiskViews
    /// @custom:spec REQ-PSTORE-006, Q-380
    function debtAssetParams(
        address asset
    ) external view override returns (DebtReserveParams memory p) {
        p.floorRoundingAllowance = _s().floorRoundingAllowance[asset];
    }

    /// @inheritdoc IParameterStoreRiskViews
    /// @custom:spec REQ-CONFIG-070, Q-379
    function routeDepthThreshold(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind
    ) external view override returns (uint256 value) {
        value = _s().routeDepth[keccak256(abi.encode(marketId, token, debtAsset, kind))];
    }

    /// @inheritdoc IParameterStoreRiskViews
    /// @custom:spec REQ-PSTORE-001
    function MARKET_REGISTRY() external view override returns (address registry) {
        registry = address(_REGISTRY);
    }

    /// @inheritdoc IParameterStoreRiskViews
    /// @custom:spec SPEC-CAP-005, Q-383, Q-399
    function poolShareMaxBpsOf(
        bytes32 poolKey
    ) external view override returns (uint16 value) {
        value = _poolShareOf(poolKey);
    }

    /// @dev One token's words of `OracleInputsLayout` from word `k`.
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
