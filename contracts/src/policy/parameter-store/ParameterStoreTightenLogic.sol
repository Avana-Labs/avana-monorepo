// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Market} from "../../types/Market.sol";
import {SecondSourceKind} from "../../types/SecondSourceKind.sol";
import {IParameterStoreLogic} from "./IParameterStoreLogic.sol";
import {IParameterStoreTighten} from "./IParameterStoreTighten.sol";
import {ParameterStoreRisk} from "./ParameterStoreRisk.sol";
import {ParameterStoreStorage} from "./ParameterStoreStorage.sol";
import {FeedDef} from "./types/FeedDef.sol";
import {MarketParams} from "./types/MarketParams.sol";

/// @title ParameterStoreTightenLogic
/// @notice Bodies of every tighten setter: each moves one value strictly in its safer direction, within its hard and liveness bounds; all are on the timelock's short-delay list (12 hours).
/// @dev Predicate (SPEC-GOV-011): strictly safer than the stored value at execution, else `NotStricter`; within the 1.5 hard bounds, else `OutOfBounds`; within the liveness bound, else `LivenessBound`; checked in that order. No step or spacing limit applies to a tightening. A tightening that re-runs `checkConfig` reverts `OracleConfigRejected` only for a check its own write breaks (a check that already failed never blocks it). Callers: the timelock (short delay) or the `APPLICATION_RISK_STEWARD` holder (immediate). Reached only by delegatecall from the ParameterStore, which checks the caller's role; see
/// `IParameterStoreLogic`.
/// @custom:spec REQ-CONFIG-049, REQ-CONFIG-050, REQ-CONFIG-051, REQ-CONFIG-052, REQ-RISK-042, REQ-RISK-044, REQ-PSTORE-002, REQ-PSTORE-016, REQ-PSTORE-018, REQ-PSTORE-020, REQ-PSTORE-024, REQ-PSTORE-029, REQ-PSTORE-030, SPEC-GOV-009, SPEC-GOV-011
// Each function here carries the body of a selector declared in an IParameterStore piece, which the ParameterStore
// itself implements; this contract inherits only a piece it implements in full, since each other piece also declares
// functions another contract serves.
// solhint-disable comprehensive-interface
// Every external call made by these setters is a view (STATICCALL), so none can re-enter the store or reorder its
// events; the events follow the checks that need those reads.
// forge-lint: disable-start(reentrancy-events)
contract ParameterStoreTightenLogic is ParameterStoreRisk, IParameterStoreTighten, IParameterStoreLogic {
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
        return (keccak256("ParameterStoreTightenLogic"), _TIMELOCK, address(_REGISTRY), _BLOCK_TIME, _HAS_SEQUENCER);
    }

    /// @inheritdoc IParameterStoreTighten
    /// @custom:spec REQ-PSTORE-031, REQ-CONFIG-050, REQ-CONFIG-051, Q-398
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
    /// @custom:spec REQ-CONFIG-052, REQ-PSTORE-015, SPEC-GOV-011
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
    /// @custom:spec REQ-CONFIG-050, REQ-CONFIG-051, Q-380
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
    /// @custom:spec REQ-CONFIG-023, REQ-PSTORE-009, REQ-PSTORE-029, Q-182
    function tightenBorrowPriceMaxAge(
        address feed,
        uint32 value
    ) external override {
        _onlyDelegated();
        FeedDef storage d = _feed(feed);
        if (value >= d.borrowPriceMaxAge) revert NotStricter();
        if (value == 0) revert OutOfBounds();
        // A lower borrow age cannot move a tolerance bound; only checks the write itself breaks can revert it.
        // The second value (a tolerance bound) is not computed here.
        // forge-lint: disable-next-line(unused-return)
        (address[] memory oracles,,) = _affected(SCOPE_FEED, feed, false, false);
        uint256[] memory before = _failures(oracles);
        d.borrowPriceMaxAge = value;
        _requireNoNewFailures(oracles, before);
        _emitFeed(feed, d);
    }

    /// @inheritdoc IParameterStoreTighten
    /// @custom:spec REQ-CONFIG-052, REQ-PSTORE-009, REQ-PSTORE-029, SPEC-GOV-009
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
    /// @custom:spec REQ-CONFIG-024, REQ-CONFIG-052, REQ-PSTORE-009, REQ-PSTORE-029, SPEC-GOV-009
    function tightenFeedAgreementToleranceBps(
        address token,
        uint16 value
    ) external override {
        _onlyDelegated();
        uint16 old = _s().feedAgreementToleranceBps[token];
        if (value >= old) revert NotStricter();
        if (value < _toleranceMin(token)) revert LivenessBound();
        // The second value (a tolerance bound) is not computed here; the line above checks the new value against it.
        // forge-lint: disable-next-line(unused-return)
        (address[] memory oracles,,) = _affected(SCOPE_TOKEN, token, false, false);
        uint256[] memory before = _failures(oracles);
        _s().feedAgreementToleranceBps[token] = value;
        _requireNoNewFailures(oracles, before);
        emit ParameterTightened("feedAgreementToleranceBps", _a(token), old, value, msg.sender);
    }

    /// @inheritdoc IParameterStoreTighten
    /// @custom:spec REQ-CONFIG-015, REQ-CONFIG-049
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
    /// @custom:spec REQ-CONFIG-070, Q-379
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
    /// @custom:spec REQ-RISK-042, REQ-RISK-044
    function tightenMarketUsdCap(
        uint256 marketId,
        uint256 value
    ) external override {
        _onlyDelegated();
        _requireMarket(marketId);
        uint256 old = _s().marketUsdCap[marketId];
        if (value >= old) revert NotStricter();
        if (value == 0 || value < _s().topUpSliceUsd[marketId]) revert OutOfBounds();
        _s().marketUsdCap[marketId] = value;
        emit CapTightened("marketUsdCap", bytes32(marketId), old, value, msg.sender);
    }

    /// @inheritdoc IParameterStoreTighten
    /// @custom:spec REQ-RISK-042, REQ-RISK-044
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
    /// @custom:spec REQ-RISK-042, REQ-RISK-044, REQ-PSTORE-026
    function tightenTokenUsdCap(
        address hub,
        address token,
        uint256 value
    ) external override {
        _onlyDelegated();
        _requireHub(hub);
        uint256 old = _s().tokenUsdCap[hub][token];
        if (value >= old) revert NotStricter();
        if (value == 0) revert OutOfBounds();
        _s().tokenUsdCap[hub][token] = value;
        emit CapTightened("tokenUsdCap", _pair(hub, token), old, value, msg.sender);
    }

    /// @inheritdoc IParameterStoreTighten
    /// @custom:spec REQ-RISK-042, REQ-RISK-044, REQ-PSTORE-026
    function tightenDepositorUsdCap(
        address hub,
        uint256 value
    ) external override {
        _onlyDelegated();
        _requireHub(hub);
        uint256 old = _s().depositorUsdCap[hub];
        if (value >= old) revert NotStricter();
        if (value == 0) revert OutOfBounds();
        _s().depositorUsdCap[hub] = value;
        emit CapTightened("depositorUsdCap", _a(hub), old, value, msg.sender);
    }

    /// @inheritdoc IParameterStoreTighten
    /// @custom:spec REQ-RISK-042, REQ-RISK-044, Q-399, Q-403
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
    /// @custom:spec REQ-PSTORE-005, Q-230
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
    /// @custom:spec REQ-RISK-042, SPEC-CAP-005, Q-383, Q-399
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

    /// @notice Body of `IParameterStoreLiquidation.tightenMaxShortfallBps`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-PSTORE-018, REQ-CONFIG-051
    function tightenMaxShortfallBps(
        uint16 value
    ) external {
        _onlyDelegated();
        uint16 old = _s().g.maxShortfallBps;
        if (value >= old) revert NotStricter();
        _s().g.maxShortfallBps = value;
        emit ParameterTightened("maxShortfallBps", bytes32(0), old, value, msg.sender);
    }

    /// @notice Body of `IParameterStoreLiquidation.tightenDebtStressRiseBps`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-PSTORE-020, REQ-CONFIG-051
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

    /// @notice Body of `IParameterStoreBreakers.tightenGateRecoverySeconds`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-PSTORE-030, REQ-ACCESS-165
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

    /// @notice Body of `IParameterStoreBreakers.tightenBreakerDeficitMax`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-PSTORE-016, REQ-CONFIG-051
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

    /// @dev Whether the token's recorded or standby second source is a `PoolTwap`.
    /// @custom:spec REQ-PSTORE-028, REQ-PSTORE-020
    function _hasPoolTwap(
        address token
    ) private view returns (bool) {
        return _s().secondSource[token].kind == SecondSourceKind.PoolTwap
            || _s().standby[token].kind == SecondSourceKind.PoolTwap;
    }

    /// @notice Body of `IParameterStoreAdmin.tightenMaxFlashFeeBps`; the ParameterStore checks the caller's role first.
    /// @custom:spec REQ-PSTORE-024, REQ-CONFIG-051, Q-335
    function tightenMaxFlashFeeBps(
        uint16 value
    ) external {
        _onlyDelegated();
        uint16 old = _s().g.maxFlashFeeBps;
        if (value >= old) revert NotStricter();
        _s().g.maxFlashFeeBps = value;
        emit ParameterTightened("maxFlashFeeBps", bytes32(0), old, value, msg.sender);
    }
}
// forge-lint: disable-end(reentrancy-events)
