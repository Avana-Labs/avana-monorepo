// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAggregatorProxy} from "../../interfaces/external/chainlink/IAggregatorProxy.sol";
import {IAggregatorV3} from "../../interfaces/external/chainlink/IAggregatorV3.sol";
import {IOffchainAggregator} from "../../interfaces/external/chainlink/IOffchainAggregator.sol";
import {ISequencerUptimeFeed} from "../../interfaces/external/chainlink/ISequencerUptimeFeed.sol";
import {RouteReads} from "../../liquidation/settlement-routes/RouteReads.sol";
import {Market} from "../../types/Market.sol";
import {MarketStatus} from "../market-registry/types/MarketStatus.sol";
import {IParameterStoreChain} from "./IParameterStoreChain.sol";
import {IParameterStoreListing} from "./IParameterStoreListing.sol";
import {IParameterStoreLogic} from "./IParameterStoreLogic.sol";
import {ParameterStoreRisk} from "./ParameterStoreRisk.sol";
import {ParameterStoreStorage} from "./ParameterStoreStorage.sol";
import {DebtReserveParams} from "./types/DebtReserveParams.sol";
import {FeedDef} from "./types/FeedDef.sol";
import {MarketParams} from "./types/MarketParams.sol";

/// @title ParameterStoreListingLogic
/// @notice Bodies of the listing-batch setters (a registered market's parameters and caps, a Hub's depositor cap, a (Hub, token) cap, feed definitions, a debt asset's rounding allowance), of each CDP Spoke's liquidation expectations, of the sequencer check and of the coverage ratio. Normal delay.
/// @dev Initial writes neither check nor update `lastLoosenedAt`. Reached only by delegatecall from the ParameterStore, which checks the caller's role; see
/// `IParameterStoreLogic`.
/// @custom:spec REQ-PSTORE-004, REQ-PSTORE-006, REQ-PSTORE-012, REQ-PSTORE-022, REQ-PSTORE-023, REQ-PSTORE-026, REQ-PSTORE-028, REQ-PSTORE-034, REQ-PSTORE-032, REQ-RISK-041, REQ-CONFIG-022, REQ-CONFIG-023
// Each function here carries the body of a selector declared in an IParameterStore piece, which the ParameterStore
// itself implements; this contract inherits only a piece it implements in full, since each other piece also declares
// functions another contract serves.
// solhint-disable comprehensive-interface
// Every external call made by these setters is a view (STATICCALL), so none can re-enter the store or reorder its
// events; the events follow the checks that need those reads.
// forge-lint: disable-start(reentrancy-events)
contract ParameterStoreListingLogic is ParameterStoreRisk, IParameterStoreListing, IParameterStoreLogic {
    /// @dev `type(int192).max`, the largest bound an aggregator's `int192` `minAnswer` or `maxAnswer` can hold.
    uint256 private constant INT192_MAX = 2 ** 191 - 1;

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
        return (keccak256("ParameterStoreListingLogic"), _TIMELOCK, address(_REGISTRY), _BLOCK_TIME, _HAS_SEQUENCER);
    }

    /// @inheritdoc IParameterStoreListing
    /// @custom:spec REQ-PSTORE-004, REQ-PSTORE-005, REQ-PSTORE-027, REQ-PSTORE-028, REQ-PSTORE-034, REQ-CONFIG-015, REQ-CONFIG-041, SPEC-CF-004
    function setInitialMarketParams(
        uint256 marketId,
        MarketParams calldata params
    ) external override {
        _onlyDelegated();
        Market memory m = _REGISTRY.getMarket(marketId);
        if (m.status != MarketStatus.Registered) revert NotInListing();
        if (
            params.consistencyToleranceBps < CONSISTENCY_MIN_BPS
                || params.slippageAllowanceBps < params.slippageAllowanceMinBps
        ) revert LivenessBound();
        if (
            params.consistencyToleranceBps > BPS || params.slippageAllowanceBps >= BPS || params.poolRiskFactor == 0
                || params.poolRiskFactor > POOL_RISK_FACTOR_MAX || params.minPledgeUsd > MIN_PLEDGE_USD_MAX
                || (params.hardHealthFloor != 0
                    && (params.hardHealthFloor < WAD || params.hardHealthFloor > HARD_FLOOR_MAX))
        ) revert OutOfBounds();
        _checkTwap(marketId, m, params.twapWindow);
        _checkListingMargin(m, params.poolRiskFactor);
        // The tokens' second sources were recorded before this market existed: none may read its pool.
        if (!_marketFits(m, params.twapWindow)) revert OutOfBounds();
        MarketParams memory old = _s().market[marketId];
        _s().market[marketId] = params;
        _checkLpOracle(m.lpOracle);
        bytes32 scope = bytes32(marketId);
        emit ParameterSet("twapWindow", scope, old.twapWindow, params.twapWindow);
        emit ParameterSet("consistencyToleranceBps", scope, old.consistencyToleranceBps, params.consistencyToleranceBps);
        emit ParameterSet("slippageAllowanceBps", scope, old.slippageAllowanceBps, params.slippageAllowanceBps);
        emit ParameterSet("slippageAllowanceMinBps", scope, old.slippageAllowanceMinBps, params.slippageAllowanceMinBps);
        emit ParameterSet("poolRiskFactor", scope, old.poolRiskFactor, params.poolRiskFactor);
        emit ParameterSet("hardHealthFloor", scope, old.hardHealthFloor, params.hardHealthFloor);
        emit MinPledgeUsdSet(marketId, old.minPledgeUsd, params.minPledgeUsd);
    }

    /// @inheritdoc IParameterStoreListing
    /// @custom:spec REQ-RISK-041, REQ-RISK-044, REQ-PSTORE-012
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

    /// @dev A repeated initial write emits the direction it moved the cap: `CapLoosened` on a raise, `CapTightened` on
    /// a lowering, nothing when unchanged.
    /// @custom:spec REQ-RISK-041, REQ-RISK-042, REQ-RISK-043
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
    /// @custom:spec REQ-PSTORE-026, REQ-RISK-044
    function setInitialHubCaps(
        address hub,
        uint256 initialDepositorUsdCap
    ) external override {
        _onlyDelegated();
        _requireHub(hub);
        if (_s().depositorUsdCap[hub] != 0) revert NotInListing();
        if (initialDepositorUsdCap == 0 || initialDepositorUsdCap > USD_CAP_MAX) revert OutOfBounds();
        _s().depositorUsdCap[hub] = initialDepositorUsdCap;
        emit CapLoosened("depositorUsdCap", _a(hub), 0, initialDepositorUsdCap, msg.sender);
    }

    /// @inheritdoc IParameterStoreListing
    /// @custom:spec REQ-RISK-041, REQ-PSTORE-012, REQ-PSTORE-026
    function setInitialTokenCap(
        address hub,
        address token,
        uint256 cap
    ) external override {
        _onlyDelegated();
        _requireListedToken(token);
        _requireHub(hub);
        if (_s().tokenUsdCap[hub][token] != 0) revert NotInListing();
        if (cap == 0 || cap > USD_CAP_MAX) revert OutOfBounds();
        _s().tokenUsdCap[hub][token] = cap;
        emit CapLoosened("tokenUsdCap", _pair(hub, token), 0, cap, msg.sender);
    }

    /// @inheritdoc IParameterStoreListing
    /// @custom:spec REQ-CONFIG-022, REQ-CONFIG-023, REQ-CONFIG-024, REQ-PSTORE-009, REQ-PSTORE-013, REQ-ORACLE-049, SPEC-ORC-019, SPEC-CF-004
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
        // Bounded above by 86,400 + 3,600 s by the checks above.
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
        _recheck(SCOPE_FEED, feed, true);
        if (_feedError(d) > oldError) _recheckMargins(SCOPE_FEED, feed);
        _emitFeed(feed, d);
    }

    /// @dev The feed's decimals, its aggregator's `minAnswer`, and `min(aggregator maxAnswer, cap)`, checked by
    /// REQ-CONFIG-022 and REQ-ORACLE-049: `1 <= decimals <= 18`, a `minAnswer` in `[1, type(int192).max]` whose
    /// normalised value is at least 1, an aggregator `maxAnswer` at most `type(int192).max`, and a pinned maximum
    /// above the minimum (`InvalidFeed`). The two bounds are read as raw words, at most one word each, so a word
    /// outside the aggregator's `int192` type, a failed read or a short answer reverts with the named check instead
    /// of an ABI decoding error.
    function _pin(
        address feed,
        int256 cap
    ) private view returns (uint8 decimals, int256 minAnswer, int256 maxAnswer) {
        decimals = IAggregatorV3(feed).decimals();
        address aggregator = IAggregatorProxy(feed).aggregator();
        (bool minOk, uint256[3] memory lo) =
            RouteReads.words(aggregator, abi.encodeCall(IOffchainAggregator.minAnswer, ()), false);
        (bool maxOk, uint256[3] memory hi) =
            RouteReads.words(aggregator, abi.encodeCall(IOffchainAggregator.maxAnswer, ()), false);
        if (decimals == 0 || decimals > FEED_DECIMALS_MAX) revert InvalidFeed(feed, "decimals");
        // A word above type(int192).max is a negative int192 or no int192 at all: either way no positive minimum.
        if (!minOk || lo[0] == 0 || lo[0] > INT192_MAX) revert InvalidFeed(feed, "minAnswer");
        if (!maxOk || hi[0] > INT192_MAX) revert InvalidFeed(feed, "maxAnswer");
        // Both words are at most type(int192).max here.
        // forge-lint: disable-next-line(unsafe-typecast)
        (minAnswer, maxAnswer) = (int256(lo[0]), int256(hi[0]));
        if (cap < maxAnswer) maxAnswer = cap;
        // The normalised minimum ⌊minAnswer × 10⁸ / 10^decimals⌋ is 0 exactly when decimals > 8 and
        // minAnswer < 10^(decimals − 8); at 8 decimals or fewer it is minAnswer × 10^(8 − decimals) ≥ 1.
        if (decimals > 8 && lo[0] < 10 ** (decimals - 8)) revert InvalidFeed(feed, "minAnswer");
        if (maxAnswer <= minAnswer) revert InvalidFeed(feed, "maxAnswer");
    }

    /// @inheritdoc IParameterStoreListing
    /// @custom:spec REQ-PSTORE-006, REQ-CONFIG-050, Q-380, Q-397
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

    /// @notice Body of `IParameterStoreLiquidation.setLiquidationExpectations`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-PSTORE-022, REQ-CONFIG-054
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

    /// @notice Body of `IParameterStoreChain.setSequencer`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-PSTORE-023, REQ-PSTORE-034, REQ-ORACLE-099, REQ-PSTORE-009, SPEC-ORC-021, Q-324
    function setSequencer(
        address feed,
        uint32 gracePeriod
    ) external {
        _onlyDelegated();
        if (_HAS_SEQUENCER) {
            if (!_sequencerFeedValid(feed)) revert IParameterStoreChain.InvalidSequencerFeed(feed);
            if (gracePeriod < SEQUENCER_GRACE_MIN || gracePeriod > SEQUENCER_GRACE_MAX) revert OutOfBounds();
        } else {
            if (feed != address(0)) revert IParameterStoreChain.InvalidSequencerFeed(feed);
            if (gracePeriod != 0) revert OutOfBounds();
        }
        _s().sequencer.feed = feed;
        _s().sequencer.gracePeriod = gracePeriod;
        // Every market's window and every second-source window of its tokens must fit the new grace period.
        _recheck(SCOPE_ALL, address(0), false, true);
        emit IParameterStoreChain.SequencerSet(feed, gracePeriod);
    }

    /// @dev An L2 sequencer-uptime feed holds code and its latest round reports 0 (up) or 1 (down) with
    /// `startedAt > 0`.
    /// @custom:spec REQ-PSTORE-023
    function _sequencerFeedValid(
        address feed
    ) private view returns (bool) {
        if (feed.code.length == 0) return false;
        try ISequencerUptimeFeed(feed).latestRoundData() returns (
            uint80, int256 answer, uint256 startedAt, uint256, uint80
        ) {
            return (answer == 0 || answer == 1) && startedAt != 0;
        } catch {
            return false;
        }
    }

    /// @notice Body of `IParameterStoreCoverage.setCoverageRatioBps`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-PSTORE-032, REQ-CONFIG-049
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
