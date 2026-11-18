// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAggregatorProxy} from "../../interfaces/external/chainlink/IAggregatorProxy.sol";
import {IAggregatorV3} from "../../interfaces/external/chainlink/IAggregatorV3.sol";
import {IOffchainAggregator} from "../../interfaces/external/chainlink/IOffchainAggregator.sol";
import {RouteMath} from "../../liquidation/settlement-routes/RouteMath.sol";
import {Market} from "../../types/MarketTypes.sol";
import {MarketStatus} from "../market-registry/types/MarketRegistryTypes.sol";
import {IParameterStoreListing} from "./IParameterStoreListing.sol";
import {IParameterStoreLogic} from "./IParameterStoreLogic.sol";
import {ParameterStoreRisk} from "./ParameterStoreRisk.sol";
import {ParameterStoreStorage} from "./ParameterStoreStorage.sol";
import {DebtReserveParams, FeedDef, MarketParams} from "./types/ParameterStoreTypes.sol";

/// @title ParameterStoreListingLogic
/// @notice Bodies of the listing-batch, Spoke expectation and coverage-ratio setters.
/// @dev Reached only by delegatecall from the ParameterStore, which checks the caller's role.
// Bodies of selectors the ParameterStore declares; only fully implemented pieces are inherited.
// solhint-disable comprehensive-interface
// Every external call here is a view (STATICCALL), so none can re-enter the store or reorder its events.
// forge-lint: disable-start(reentrancy-events)
contract ParameterStoreListingLogic is ParameterStoreRisk, IParameterStoreListing, IParameterStoreLogic {
    uint256 private constant INT192_MAX = 2 ** 191 - 1;

    /// @notice Fixes the implementation immutables; they must equal the ParameterStore's.
    constructor(
        address timelock,
        address marketRegistry,
        uint32 chainBlockTime
    ) ParameterStoreStorage(timelock, marketRegistry, chainBlockTime) {}

    /// @inheritdoc IParameterStoreLogic
    function logicConfig()
        external
        view
        override
        returns (bytes32 kind, address timelock, address marketRegistry, uint32 chainBlockTime)
    {
        return (keccak256("ParameterStoreListingLogic"), _TIMELOCK, address(_REGISTRY), _BLOCK_TIME);
    }

    /// @inheritdoc IParameterStoreListing
    function setInitialMarketParams(
        uint256 marketId,
        MarketParams calldata params
    ) external override {
        _onlyDelegated();
        Market memory m = _REGISTRY.getMarket(marketId);
        if (m.status != MarketStatus.Registered) revert NotInListing();
        if (params.slippageAllowanceBps < params.slippageAllowanceMinBps) revert LivenessBound();
        if (
            params.slippageAllowanceBps >= BPS || params.poolRiskFactor == 0
                || params.poolRiskFactor > POOL_RISK_FACTOR_MAX || params.minPledgeUsd > MIN_PLEDGE_USD_MAX
        ) revert OutOfBounds();
        _checkListingMargin(m, params.poolRiskFactor);
        MarketParams memory old = _s().market[marketId];
        _s().market[marketId] = params;
        bytes32 scope = bytes32(marketId);
        emit ParameterSet("slippageAllowanceBps", scope, old.slippageAllowanceBps, params.slippageAllowanceBps);
        emit ParameterSet("slippageAllowanceMinBps", scope, old.slippageAllowanceMinBps, params.slippageAllowanceMinBps);
        emit ParameterSet("poolRiskFactor", scope, old.poolRiskFactor, params.poolRiskFactor);
        emit MinPledgeUsdSet(marketId, old.minPledgeUsd, params.minPledgeUsd);
    }

    /// @inheritdoc IParameterStoreListing
    function setInitialMarketCaps(
        uint256 marketId,
        uint256 initialMarketUsdCap,
        uint256 initialTopUpSliceUsd,
        uint256 initialStressFloorUsd
    ) external override {
        _onlyDelegated();
        if (_REGISTRY.getMarket(marketId).status != MarketStatus.Registered) revert NotInListing();
        if (
            initialMarketUsdCap == 0 || initialMarketUsdCap > USD_CAP_MAX || initialTopUpSliceUsd > initialMarketUsdCap
                || initialStressFloorUsd == 0 || initialStressFloorUsd > USD_CAP_MAX
        ) revert OutOfBounds();
        Layout storage $ = _s();
        uint256 oldCap = $.marketUsdCap[marketId];
        uint256 oldSlice = $.topUpSliceUsd[marketId];
        uint256 oldFloor = $.stressFloorUsd[marketId];
        $.marketUsdCap[marketId] = initialMarketUsdCap;
        $.topUpSliceUsd[marketId] = initialTopUpSliceUsd;
        $.stressFloorUsd[marketId] = initialStressFloorUsd;
        _capEvent("marketUsdCap", bytes32(marketId), oldCap, initialMarketUsdCap);
        _capEvent("topUpSliceUsd", bytes32(marketId), oldSlice, initialTopUpSliceUsd);
        emit StressFloorSet(marketId, oldFloor, initialStressFloorUsd);
    }

    function _capEvent(
        bytes32 capKind,
        bytes32 scope,
        uint256 oldValue,
        uint256 newValue
    ) private {
        if (newValue > oldValue) emit CapLoosened(capKind, scope, oldValue, newValue, msg.sender);
        else if (newValue < oldValue) emit CapTightened(capKind, scope, oldValue, newValue, msg.sender);
    }

    /// @inheritdoc IParameterStoreListing
    function setInitialTokenCap(
        address hub,
        address token,
        uint256 cap
    ) external override {
        _onlyDelegated();
        _requireListedToken(token);
        _requireHub(hub);
        Layout storage $ = _s();
        if ($.tokenCapSet[hub][token]) revert NotInListing();
        if (cap == 0 || cap > USD_CAP_MAX) revert OutOfBounds();
        $.tokenCapSet[hub][token] = true;
        $.tokenUsdCap[hub][token] = cap;
        emit CapLoosened("tokenUsdCap", _pair(hub, token), 0, cap, msg.sender);
    }

    /// @inheritdoc IParameterStoreListing
    function setFeed(
        address feed,
        FeedDef calldata def
    ) external override {
        _onlyDelegated();
        uint256 maxAge = uint256(def.feedHeartbeat) + def.heartbeatMargin;
        if (
            def.feedHeartbeat == 0 || def.feedHeartbeat > FEED_HEARTBEAT_MAX || def.heartbeatMargin == 0
                || def.heartbeatMargin > HEARTBEAT_MARGIN_MAX || def.feedDeviationThresholdBps == 0
                || def.feedMaxAge != maxAge || def.liquidationPriceMaxAge != maxAge || def.borrowPriceMaxAge != maxAge
        ) revert OutOfBounds();
        (uint8 decimals, int256 minAnswer, int256 maxAnswer) = _pin(feed, def.maxAnswerCap);
        FeedDef storage d = _s().feeds[feed];
        uint256 oldError = _feedError(d);
        uint32 borrow = d.borrowPriceMaxAge;
        // Bounded by the checks above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 age = uint32(maxAge);
        d.decimals = decimals;
        d.minAnswer = minAnswer;
        d.maxAnswer = maxAnswer;
        d.maxAnswerCap = def.maxAnswerCap;
        d.feedHeartbeat = def.feedHeartbeat;
        d.heartbeatMargin = def.heartbeatMargin;
        d.feedMaxAge = age;
        d.feedDeviationThresholdBps = def.feedDeviationThresholdBps;
        d.heartbeatDriftBps = def.heartbeatDriftBps;
        // A borrow age a tightening lowered stays lowered; only setBorrowPriceMaxAge raises it again.
        d.borrowPriceMaxAge = borrow != 0 && borrow < age ? borrow : age;
        d.liquidationPriceMaxAge = age;
        if (_feedError(d) > oldError) _recheckMargins(SCOPE_FEED, feed);
        _emitFeed(feed, d);
    }

    /// @dev Bounds are read as raw words so a bad answer reverts `InvalidFeed`, not an ABI decoding error.
    function _pin(
        address feed,
        int256 cap
    ) private view returns (uint8 decimals, int256 minAnswer, int256 maxAnswer) {
        decimals = IAggregatorV3(feed).decimals();
        address aggregator = IAggregatorProxy(feed).aggregator();
        (bool minOk, uint256[3] memory lo) =
            RouteMath.words(aggregator, abi.encodeCall(IOffchainAggregator.minAnswer, ()), false);
        (bool maxOk, uint256[3] memory hi) =
            RouteMath.words(aggregator, abi.encodeCall(IOffchainAggregator.maxAnswer, ()), false);
        if (decimals == 0 || decimals > FEED_DECIMALS_MAX) revert InvalidFeed(feed, "decimals");
        // A word above type(int192).max is a negative int192 or no int192 at all: either way no positive minimum.
        if (!minOk || lo[0] == 0 || lo[0] > INT192_MAX) revert InvalidFeed(feed, "minAnswer");
        if (!maxOk || hi[0] > INT192_MAX) revert InvalidFeed(feed, "maxAnswer");
        // Both words are at most type(int192).max here.
        // forge-lint: disable-next-line(unsafe-typecast)
        (minAnswer, maxAnswer) = (int256(lo[0]), int256(hi[0]));
        if (cap < maxAnswer) maxAnswer = cap;
        // The normalised minimum is 0 exactly when decimals > 8 and minAnswer < 10^(decimals − 8).
        if (decimals > 8 && lo[0] < 10 ** (decimals - 8)) revert InvalidFeed(feed, "minAnswer");
        if (maxAnswer <= minAnswer) revert InvalidFeed(feed, "maxAnswer");
    }

    /// @inheritdoc IParameterStoreListing
    function setDebtAssetParams(
        address asset,
        DebtReserveParams calldata p
    ) external override {
        _onlyDelegated();
        _requireRoundingAllowance(asset, p.floorRoundingAllowance);
        uint256 old = _s().floorRoundingAllowance[asset];
        _s().floorRoundingAllowance[asset] = p.floorRoundingAllowance;
        emit ParameterSet("floorRoundingAllowance", _a(asset), old, p.floorRoundingAllowance);
        emit DebtAssetParamsSet(asset, p.floorRoundingAllowance);
    }

    /// @notice Body of `IParameterStore.setLiquidationExpectations`.
    function setLiquidationExpectations(
        address spoke,
        uint256 targetHealthFactor,
        uint16 minLiquidationBonusBps
    ) external {
        _onlyDelegated();
        if (!_REGISTRY.getSpoke(spoke).approved) revert UnknownSpoke(spoke);
        if (
            targetHealthFactor <= WAD || minLiquidationBonusBps < MIN_LIQUIDATION_BONUS_FLOOR
                || minLiquidationBonusBps >= BPS
        ) revert OutOfBounds();
        uint256 oldTarget = _s().targetHealthFactor[spoke];
        uint16 oldBonus = _s().minLiquidationBonus[spoke];
        _s().targetHealthFactor[spoke] = targetHealthFactor;
        _s().minLiquidationBonus[spoke] = minLiquidationBonusBps;
        emit ParameterSet("aaveTargetHealthFactor", _a(spoke), oldTarget, targetHealthFactor);
        emit ParameterSet("minLiquidationBonus", _a(spoke), oldBonus, minLiquidationBonusBps);
    }

    /// @notice Body of `IParameterStore.setCoverageRatioBps`.
    function setCoverageRatioBps(
        uint16 value
    ) external {
        _onlyDelegated();
        if (value > BPS) revert OutOfBounds();
        uint16 old = _s().coverageRatioBps;
        _s().coverageRatioBps = value;
        emit ParameterSet("coverageRatioBps", bytes32(0), old, value);
    }
}
// forge-lint: disable-end(reentrancy-events)
