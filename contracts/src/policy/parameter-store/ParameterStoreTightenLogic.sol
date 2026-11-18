// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Market} from "../../types/Market.sol";
import {SecondSourceKind} from "../../types/SecondSourceKind.sol";
import {IParameterStore} from "./IParameterStore.sol";
import {IParameterStoreLogic} from "./IParameterStoreLogic.sol";
import {IParameterStoreTighten} from "./IParameterStoreTighten.sol";
import {ParameterStoreRisk} from "./ParameterStoreRisk.sol";
import {ParameterStoreSpeedRules} from "./ParameterStoreSpeedRules.sol";
import {ParameterStoreStorage} from "./ParameterStoreStorage.sol";
import {FeedDef, MarketParams, MarketSpeedLimits, SpeedLimit} from "./types/ParameterStoreTypes.sol";

/// @title ParameterStoreTightenLogic
/// @notice Bodies of every tighten setter: each moves one value strictly in its safer direction.
/// @dev Runs only by delegatecall from the ParameterStore, which checks the caller's role.
// Bodies of selectors the ParameterStore declares; only fully implemented pieces are inherited.
// solhint-disable comprehensive-interface
// Every external call here is a view (STATICCALL), so none can re-enter the store or reorder its events.
// forge-lint: disable-start(reentrancy-events)
contract ParameterStoreTightenLogic is ParameterStoreRisk, IParameterStoreTighten, IParameterStoreLogic {
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
        return (keccak256("ParameterStoreTightenLogic"), _TIMELOCK, address(_REGISTRY), _BLOCK_TIME, _HAS_SEQUENCER);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenHardHealthFloor(
        uint256 marketId,
        uint256 value
    ) external override {
        _onlyDelegated();
        _requireMarket(marketId);
        MarketParams storage p = _s().market[marketId];
        uint256 old = p.hardHealthFloor;
        if (value <= old) revert NotStricter();
        if (value < WAD || value > HARD_FLOOR_MAX) revert OutOfBounds();
        p.hardHealthFloor = value;
        emit ParameterTightened("hardHealthFloor", bytes32(marketId), old, value, msg.sender);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenSlippageAllowanceBps(
        uint256 marketId,
        uint16 value
    ) external override {
        _onlyDelegated();
        _requireMarket(marketId);
        MarketParams storage p = _s().market[marketId];
        uint16 old = p.slippageAllowanceBps;
        if (value >= old) revert NotStricter();
        if (value < p.slippageAllowanceMinBps) revert LivenessBound();
        p.slippageAllowanceBps = value;
        emit ParameterTightened("slippageAllowanceBps", bytes32(marketId), old, value, msg.sender);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenFloorRoundingAllowance(
        address asset,
        uint256 value
    ) external override {
        _onlyDelegated();
        uint256 old = _s().floorRoundingAllowance[asset];
        if (value >= old) revert NotStricter();
        if (value == 0) revert OutOfBounds();
        _s().floorRoundingAllowance[asset] = value;
        emit ParameterTightened("floorRoundingAllowance", _a(asset), old, value, msg.sender);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenBorrowPriceMaxAge(
        address feed,
        uint32 value
    ) external override {
        _onlyDelegated();
        FeedDef storage d = _feed(feed);
        if (value >= d.borrowPriceMaxAge) revert NotStricter();
        if (value == 0) revert OutOfBounds();
        // The second value (a tolerance bound) is not computed here.
        // forge-lint: disable-next-line(unused-return)
        (address[] memory oracles,,) = _affected(SCOPE_FEED, feed, false, false);
        uint256[] memory before = _failures(oracles);
        d.borrowPriceMaxAge = value;
        _requireNoNewFailures(oracles, before);
        _emitFeed(feed, d);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenConsistencyToleranceBps(
        uint256 marketId,
        uint16 value
    ) external override {
        _onlyDelegated();
        Market memory m = _market(marketId);
        MarketParams storage p = _s().market[marketId];
        uint16 old = p.consistencyToleranceBps;
        if (value >= old) revert NotStricter();
        if (value < CONSISTENCY_MIN_BPS) revert LivenessBound();
        // One slot per market identifier, as `_affected` lays them out; only this market's is set.
        address[] memory oracles = new address[](marketId);
        if (_configured(m.status)) oracles[marketId - 1] = m.lpOracle;
        uint256[] memory before = _failures(oracles);
        p.consistencyToleranceBps = value;
        _requireNoNewFailures(oracles, before);
        emit ParameterTightened("consistencyToleranceBps", bytes32(marketId), old, value, msg.sender);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenFeedAgreementToleranceBps(
        address token,
        uint16 value
    ) external override {
        _onlyDelegated();
        uint16 old = _s().feedAgreementToleranceBps[token];
        if (value >= old) revert NotStricter();
        if (value < _toleranceMin(token)) revert LivenessBound();
        // The second value (a tolerance bound) is not computed here; the line above checks against it.
        // forge-lint: disable-next-line(unused-return)
        (address[] memory oracles,,) = _affected(SCOPE_TOKEN, token, false, false);
        uint256[] memory before = _failures(oracles);
        _s().feedAgreementToleranceBps[token] = value;
        _requireNoNewFailures(oracles, before);
        emit ParameterTightened("feedAgreementToleranceBps", _a(token), old, value, msg.sender);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenPoolRiskFactor(
        uint256 marketId,
        uint16 value
    ) external override {
        _onlyDelegated();
        _requireMarket(marketId);
        MarketParams storage p = _s().market[marketId];
        uint16 old = p.poolRiskFactor;
        if (value >= old) revert NotStricter();
        if (value == 0) revert OutOfBounds();
        p.poolRiskFactor = value;
        emit ParameterTightened("poolRiskFactor", bytes32(marketId), old, value, msg.sender);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenRouteDepthThreshold(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind,
        uint256 depthThreshold
    ) external override {
        _onlyDelegated();
        _requireMarket(marketId);
        if (kind > 1) revert OutOfBounds();
        bytes32 slotKey = keccak256(abi.encode(marketId, token, debtAsset, kind));
        uint256 old = _s().routeDepth[slotKey];
        if (depthThreshold <= old) revert NotStricter();
        _s().routeDepth[slotKey] = depthThreshold;
        emit RouteDepthThresholdSet(marketId, token, debtAsset, kind, old, depthThreshold);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenMarketUsdCap(
        uint256 marketId,
        uint256 value
    ) external override {
        _onlyDelegated();
        _requireMarket(marketId);
        uint256 old = _s().marketUsdCap[marketId];
        if (value >= old) revert NotStricter();
        _s().marketUsdCap[marketId] = value;
        emit CapTightened("marketUsdCap", bytes32(marketId), old, value, msg.sender);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenTopUpSliceUsd(
        uint256 marketId,
        uint256 value
    ) external override {
        _onlyDelegated();
        _requireMarket(marketId);
        uint256 old = _s().topUpSliceUsd[marketId];
        if (value >= old) revert NotStricter();
        _s().topUpSliceUsd[marketId] = value;
        emit CapTightened("topUpSliceUsd", bytes32(marketId), old, value, msg.sender);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenTokenUsdCap(
        address hub,
        address token,
        uint256 value
    ) external override {
        _onlyDelegated();
        _requireHub(hub);
        uint256 old = _s().tokenUsdCap[hub][token];
        if (value >= old) revert NotStricter();
        _s().tokenUsdCap[hub][token] = value;
        emit CapTightened("tokenUsdCap", _pair(hub, token), old, value, msg.sender);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenPoolShareMaxBps(
        uint16 value
    ) external override {
        _onlyDelegated();
        uint16 old = _s().poolShareMaxBps;
        if (value >= old) revert NotStricter();
        if (value == 0) revert OutOfBounds();
        _s().poolShareMaxBps = value;
        emit CapTightened("poolShareMaxBps", bytes32(0), old, value, msg.sender);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenMinPledgeUsd(
        uint256 marketId,
        uint256 value
    ) external override {
        _onlyDelegated();
        _requireMarket(marketId);
        MarketParams storage p = _s().market[marketId];
        uint256 old = p.minPledgeUsd;
        if (value <= old) revert NotStricter();
        if (value > MIN_PLEDGE_USD_MAX) revert OutOfBounds();
        p.minPledgeUsd = value;
        emit MinPledgeUsdSet(marketId, old, value);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenPoolShareMaxBpsOf(
        uint256 marketId,
        uint16 value
    ) external override {
        _onlyDelegated();
        bytes32 poolKey = _poolKey(_market(marketId));
        uint16 old = _poolShareOf(poolKey);
        if (value >= old) revert NotStricter();
        if (value == 0) revert OutOfBounds();
        _s().poolShareOverride[poolKey] = value;
        emit CapTightened("poolShareMaxBpsOf", poolKey, old, value, msg.sender);
    }

    /// @notice Body of `IParameterStore.tightenMaxShortfallBps`.
    function tightenMaxShortfallBps(
        uint16 value
    ) external {
        _onlyDelegated();
        uint16 old = _s().g.maxShortfallBps;
        if (value >= old) revert NotStricter();
        _s().g.maxShortfallBps = value;
        emit ParameterTightened("maxShortfallBps", bytes32(0), old, value, msg.sender);
    }

    /// @notice Body of `IParameterStore.tightenDebtStressRiseBps`.
    function tightenDebtStressRiseBps(
        address asset,
        uint16 value
    ) external {
        _onlyDelegated();
        _requireListedToken(asset);
        uint16 old = _s().debtStressRiseBps[asset];
        if (value <= old) revert NotStricter();
        if (value < STRESS_RISE_MIN_BPS || value > STRESS_RISE_MAX_BPS) revert OutOfBounds();
        // The first write marks the asset as one with a DebtOracle, which reads only an oracle-network second source.
        if (old == 0 && _hasPoolTwap(asset)) revert OutOfBounds();
        _s().debtStressRiseBps[asset] = value;
        emit ParameterTightened("debtStressRiseBps", _a(asset), old, value, msg.sender);
    }

    /// @notice Body of `IParameterStore.tightenGateRecoverySeconds`.
    function tightenGateRecoverySeconds(
        uint64 value
    ) external {
        _onlyDelegated();
        uint64 old = _s().g.gateRecoverySeconds;
        if (value <= old) revert NotStricter();
        if (value > GATE_RECOVERY_MAX) revert OutOfBounds();
        _s().g.gateRecoverySeconds = value;
        emit ParameterTightened("gateRecoverySeconds", bytes32(0), old, value, msg.sender);
    }

    /// @notice Body of `IParameterStore.tightenBreakerDeficitMax`.
    function tightenBreakerDeficitMax(
        address hub,
        address asset,
        uint256 value
    ) external {
        _onlyDelegated();
        _requireHub(hub);
        uint256 old = _s().breakerDeficitMax[hub][asset];
        if (value >= old) revert NotStricter();
        _s().breakerDeficitMax[hub][asset] = value;
        emit ParameterTightened("breakerDeficitMax", _pair(hub, asset), old, value, msg.sender);
    }

    function _hasPoolTwap(
        address token
    ) private view returns (bool) {
        return _s().secondSource[token].kind == SecondSourceKind.PoolTwap
            || _s().standby[token].kind == SecondSourceKind.PoolTwap;
    }

    /// @notice Body of `IParameterStore.tightenMaxFlashFeeBps`.
    function tightenMaxFlashFeeBps(
        uint16 value
    ) external {
        _onlyDelegated();
        uint16 old = _s().g.maxFlashFeeBps;
        if (value >= old) revert NotStricter();
        _s().g.maxFlashFeeBps = value;
        emit ParameterTightened("maxFlashFeeBps", bytes32(0), old, value, msg.sender);
    }

    /// @notice Body of `IParameterStore.tightenMarketSpeedLimits`.
    function tightenMarketSpeedLimits(
        uint256 marketId,
        MarketSpeedLimits calldata limits
    ) external {
        _onlyDelegated();
        _requireMarket(marketId);
        MarketSpeedLimits memory old = _s().marketSpeed[marketId];
        (bool noLooser, bool stricter) = ParameterStoreSpeedRules.compareMarket(old, limits);
        if (!noLooser || !stricter) revert NotStricter();
        if (!ParameterStoreSpeedRules.validMarket(limits)) revert OutOfBounds();
        _s().marketSpeed[marketId] = limits;
        emit IParameterStore.MarketSpeedLimitsSet(marketId, old, limits, true);
    }

    /// @notice Body of `IParameterStore.tightenDebtSpeedLimit`.
    function tightenDebtSpeedLimit(
        address hub,
        address asset,
        SpeedLimit calldata limit
    ) external {
        _onlyDelegated();
        _requireHub(hub);
        SpeedLimit memory old = _s().debtSpeed[hub][asset];
        (bool noLooser, bool stricter) = ParameterStoreSpeedRules.compareDebt(old, limit);
        if (!noLooser || !stricter) revert NotStricter();
        if (!ParameterStoreSpeedRules.validDebt(limit)) revert OutOfBounds();
        _s().debtSpeed[hub][asset] = limit;
        emit IParameterStore.DebtSpeedLimitSet(hub, asset, old, limit, true);
    }
}
// forge-lint: disable-end(reentrancy-events)
