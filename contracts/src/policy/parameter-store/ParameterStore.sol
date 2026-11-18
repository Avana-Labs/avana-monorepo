// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../governance/roles/AvanaRoles.sol";
import {OracleConfig, RouteSlot, SecondSource, SecondSourceKind} from "../../types/OracleTypes.sol";
import {IParameterStore} from "./IParameterStore.sol";
import {ParameterStoreForwardAdmin} from "./ParameterStoreForwardAdmin.sol";
import {ParameterStoreForwardRisk} from "./ParameterStoreForwardRisk.sol";
import {ParameterStoreRouter} from "./ParameterStoreRouter.sol";
import {OracleInputsLayout} from "./types/OracleInputsLayout.sol";
import {
    DebtReserveParams,
    FeedDef,
    GlobalParams,
    MarketParams,
    ParameterStoreLogics
} from "./types/ParameterStoreTypes.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title ParameterStore
/// @notice Every Avana risk and oracle parameter of one chain, with its bounds and change direction.
/// @dev UUPS proxy; only the timelock can upgrade it. Setter bodies run in five logic contracts by delegatecall.
contract ParameterStore is UUPSUpgradeable, ParameterStoreForwardRisk, ParameterStoreForwardAdmin {
    // forge-lint: disable-start(calls-loop)
    /// @inheritdoc IParameterStore
    function getMarketParams(
        uint256 marketId
    ) external view override returns (MarketParams memory params) {
        params = _s().market[marketId];
    }

    /// @inheritdoc IParameterStore
    function feedAgreementToleranceBps(
        address token
    ) external view override returns (uint16 bps) {
        bps = _s().feedAgreementToleranceBps[token];
    }

    /// @inheritdoc IParameterStore
    function tokenCollateralFactorBps(
        address token
    ) external view override returns (uint16 bps) {
        bps = _s().tokenCollateralFactorBps[token];
    }

    /// @inheritdoc IParameterStore
    function getFeed(
        address feed
    ) external view override returns (FeedDef memory def) {
        def = _s().feeds[feed];
    }

    /// @inheritdoc IParameterStore
    function slippageAllowanceMinBps(
        uint256 marketId
    ) external view override returns (uint16 bps) {
        bps = _s().market[marketId].slippageAllowanceMinBps;
    }

    /// @inheritdoc IParameterStore
    function feedAgreementToleranceMinBps(
        address token
    ) external view override returns (uint16 bps) {
        bps = _toleranceMin(token);
    }

    /// @inheritdoc IParameterStore
    /// @dev Runs in the oracle-admin logic, whose return data ends the call; the `return` below is not reached.
    function getOracleConfig(
        address
    ) external view override returns (OracleConfig memory config) {
        _forwardView(_ADMIN_ORACLE_LOGIC);
        return config;
    }

    /// @inheritdoc IParameterStore
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

    /// @inheritdoc IParameterStore
    function borrowPriceMaxAge(
        address feed
    ) external view override returns (uint32 age) {
        age = _s().feeds[feed].borrowPriceMaxAge;
    }

    /// @inheritdoc IParameterStore
    function liquidationPriceMaxAge(
        address feed
    ) external view override returns (uint32 age) {
        age = _s().feeds[feed].liquidationPriceMaxAge;
    }

    /// @inheritdoc IParameterStore
    function hardHealthFloor(
        uint256 marketId
    ) external view override returns (uint256 value) {
        value = _s().market[marketId].hardHealthFloor;
    }

    /// @inheritdoc IParameterStore
    function cachedWindow() external view override returns (uint32 value) {
        value = _s().g.cachedWindow;
    }

    /// @inheritdoc IParameterStore
    function disagreementPauseMax() external view override returns (uint32 value) {
        value = _s().g.disagreementPauseMax;
    }

    /// @inheritdoc IParameterStore
    function usdBandLow() external view override returns (uint256 value) {
        value = _s().g.usdBandLow;
    }

    /// @inheritdoc IParameterStore
    function usdBandHigh() external view override returns (uint256 value) {
        value = _s().g.usdBandHigh;
    }

    /// @inheritdoc IParameterStore
    function graceDuration() external view override returns (uint32 value) {
        value = _s().g.graceDuration;
    }

    /// @inheritdoc IParameterStore
    function graceHealthFactor() external view override returns (uint256 value) {
        value = _s().g.graceHealthFactor;
    }

    /// @inheritdoc IParameterStore
    function maxFlashFeeBps() external view override returns (uint16 value) {
        value = _s().g.maxFlashFeeBps;
    }

    /// @inheritdoc IParameterStore
    function avanaFeeShareBps() external view override returns (uint16 value) {
        value = _s().g.avanaFeeShareBps;
    }

    /// @inheritdoc IParameterStore
    function feeRecipient() external view override returns (address recipient) {
        recipient = _s().g.feeRecipient;
    }

    /// @inheritdoc IParameterStore
    function feedAgreementMarginBps() external view override returns (uint16 value) {
        value = _s().g.feedAgreementMarginBps;
    }

    /// @inheritdoc IParameterStore
    function floorRoundingAllowance(
        address asset
    ) external view override returns (uint256 value) {
        value = _s().floorRoundingAllowance[asset];
    }

    /// @inheritdoc IParameterStore
    function graceHealthFactorMin() external pure override returns (uint256 value) {
        value = GRACE_HF_MIN;
    }

    /// @inheritdoc IParameterStore
    function graceDurationMax() external pure override returns (uint32 value) {
        value = GRACE_DURATION_MAX;
    }

    /// @inheritdoc IParameterStore
    function consistencyToleranceMinBps() external pure override returns (uint16 value) {
        value = CONSISTENCY_MIN_BPS;
    }

    /// @inheritdoc IParameterStore
    function MAX_HEARTBEAT_MARGIN() external pure override returns (uint32 value) {
        value = HEARTBEAT_MARGIN_MAX;
    }

    /// @inheritdoc IParameterStore
    function secondSource(
        address token
    ) external view override returns (SecondSource memory source) {
        source = _s().onStandby[token] ? _s().standby[token] : _s().secondSource[token];
    }

    /// @inheritdoc IParameterStore
    function standbySecondSource(
        address token
    ) external view override returns (SecondSource memory source) {
        source = _s().standby[token];
    }

    /// @inheritdoc IParameterStore
    function onStandby(
        address token
    ) external view override returns (bool active) {
        active = _s().onStandby[token];
    }

    /// @inheritdoc IParameterStore
    function lastLoosenedAt(
        bytes32 paramKey
    ) external view override returns (uint64 at) {
        at = _s().lastLoosenedAt[paramKey];
    }

    /// @inheritdoc IParameterStore
    function LOOSEN_HEALTH_FACTOR_STEP() external pure override returns (uint256 value) {
        value = HF_STEP;
    }

    /// @inheritdoc IParameterStore
    function LOOSEN_CAP_STEP_BPS() external pure override returns (uint16 value) {
        value = CAP_STEP_BPS;
    }

    /// @inheritdoc IParameterStore
    function LOOSEN_SLIPPAGE_STEP_BPS() external pure override returns (uint16 value) {
        value = SLIPPAGE_STEP_BPS;
    }

    /// @inheritdoc IParameterStore
    function TIMELOCK() external view override returns (address timelock) {
        timelock = _TIMELOCK;
    }

    /// @inheritdoc IParameterStore
    function marketUsdCap(
        uint256 marketId
    ) external view override returns (uint256 value) {
        value = _s().marketUsdCap[marketId];
    }

    /// @inheritdoc IParameterStore
    function topUpSliceUsd(
        uint256 marketId
    ) external view override returns (uint256 value) {
        value = _s().topUpSliceUsd[marketId];
    }

    /// @inheritdoc IParameterStore
    function stressFloorUsd(
        uint256 marketId
    ) external view override returns (uint256 value) {
        value = _s().stressFloorUsd[marketId];
    }

    /// @inheritdoc IParameterStore
    function tokenUsdCap(
        address hub,
        address token
    ) external view override returns (uint256 value) {
        value = _s().tokenUsdCap[hub][token];
    }

    /// @inheritdoc IParameterStore
    function poolShareMaxBps() external view override returns (uint16 value) {
        value = _s().poolShareMaxBps;
    }

    /// @inheritdoc IParameterStore
    function minPledgeUsd(
        uint256 marketId
    ) external view override returns (uint256 value) {
        value = _s().market[marketId].minPledgeUsd;
    }

    /// @inheritdoc IParameterStore
    function debtAssetParams(
        address asset
    ) external view override returns (DebtReserveParams memory p) {
        p.floorRoundingAllowance = _s().floorRoundingAllowance[asset];
    }

    /// @inheritdoc IParameterStore
    function routeDepthThreshold(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind
    ) external view override returns (uint256 value) {
        value = _s().routeDepth[keccak256(abi.encode(marketId, token, debtAsset, kind))];
    }

    /// @inheritdoc IParameterStore
    function MARKET_REGISTRY() external view override returns (address registry) {
        registry = address(_REGISTRY);
    }

    /// @inheritdoc IParameterStore
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
    // forge-lint: disable-end(calls-loop)

    /// @notice Fixes the implementation immutables and the five logic contracts.
    constructor(
        address timelock,
        address marketRegistry,
        uint32 chainBlockTime,
        bool hasSequencer,
        ParameterStoreLogics memory logics
    ) ParameterStoreRouter(timelock, marketRegistry, chainBlockTime, hasSequencer, logics) {}

    /// @inheritdoc IParameterStore
    function initialize(
        address timelock,
        GlobalParams calldata,
        uint16
    ) external override initializer {
        if (timelock != _TIMELOCK) revert AdminRoleOnlyTimelock(DEFAULT_ADMIN_ROLE, timelock);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _setRoleAdmin(AvanaRoles.APPLICATION_PAUSE_GUARDIAN, AvanaRoles.APPLICATION_ADMIN);
        _setRoleAdmin(AvanaRoles.APPLICATION_RISK_STEWARD, AvanaRoles.APPLICATION_ADMIN);
        _grantRole(DEFAULT_ADMIN_ROLE, timelock);
        _grantRole(AvanaRoles.APPLICATION_ADMIN, timelock);
        _forward(_ADMIN_RISK_LOGIC);
    }

    /// @inheritdoc IParameterStore
    /// @dev Runs in the oracle-admin logic, whose return data ends the call; the `return` below is not reached.
    function liquidationLivenessHolds(
        address,
        uint256,
        uint256
    ) external view override returns (bool holds) {
        _forwardView(_ADMIN_ORACLE_LOGIC);
        return holds;
    }

    /// @inheritdoc IParameterStore
    function maxShortfallBps() external view override returns (uint16 value) {
        value = _s().g.maxShortfallBps;
    }

    /// @inheritdoc IParameterStore
    function debtStressRiseBps(
        address asset
    ) external view override returns (uint16 value) {
        value = _s().debtStressRiseBps[asset];
    }

    /// @inheritdoc IParameterStore
    function aaveTargetHealthFactor(
        address spoke
    ) external view override returns (uint256 value) {
        value = _s().targetHealthFactor[spoke];
    }

    /// @inheritdoc IParameterStore
    function minLiquidationBonus(
        address spoke
    ) external view override returns (uint16 value) {
        value = _s().minLiquidationBonus[spoke];
    }

    /// @inheritdoc IParameterStore
    function breakerDeficitMax(
        address hub,
        address asset
    ) external view override returns (uint256 value) {
        value = _s().breakerDeficitMax[hub][asset];
    }

    /// @inheritdoc IParameterStore
    function gateRecoverySeconds() external view override returns (uint64 value) {
        value = _s().g.gateRecoverySeconds;
    }

    /// @inheritdoc IParameterStore
    function sequencer() external view override returns (address feed, uint32 gracePeriod) {
        (feed, gracePeriod) = (_s().sequencer.feed, _s().sequencer.gracePeriod);
    }

    /// @inheritdoc IParameterStore
    function CHAIN_BLOCK_TIME() external view override returns (uint32 value) {
        value = _BLOCK_TIME;
    }

    /// @inheritdoc IParameterStore
    function twapMinObservations(
        uint256 marketId
    ) external view override returns (uint16 count) {
        count = _twapMinObservations(_s().market[marketId].twapWindow);
    }

    /// @inheritdoc IParameterStore
    function heartbeatMargin(
        address feed
    ) external view override returns (uint32 margin) {
        margin = _s().feeds[feed].heartbeatMargin;
    }

    /// @inheritdoc IParameterStore
    function coverageRatioBps() external view override returns (uint16 value) {
        value = _s().coverageRatioBps;
    }

    /// @inheritdoc IParameterStore
    function tightenGateRecoverySeconds(
        uint64
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function loosenGateRecoverySeconds(
        uint64
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function tightenBreakerDeficitMax(
        address,
        address,
        uint256
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function loosenBreakerDeficitMax(
        address,
        address,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function tightenMaxShortfallBps(
        uint16
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function loosenMaxShortfallBps(
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function tightenDebtStressRiseBps(
        address,
        uint16
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function loosenDebtStressRiseBps(
        address,
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function setLiquidationExpectations(
        address,
        uint256,
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function setSequencer(
        address,
        uint32
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function setCoverageRatioBps(
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }

    /// @dev Only `APPLICATION_ADMIN` (the timelock) upgrades, at the normal delay.
    function _authorizeUpgrade(
        address
    ) internal view override onlyRole(AvanaRoles.APPLICATION_ADMIN) {}
}
