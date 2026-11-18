// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Market} from "../../types/Market.sol";
import {IParameterStore} from "./IParameterStore.sol";
import {IParameterStoreLogic} from "./IParameterStoreLogic.sol";
import {IParameterStoreLoosen} from "./IParameterStoreLoosen.sol";
import {ParameterStoreRisk} from "./ParameterStoreRisk.sol";
import {ParameterStoreSpeedRules} from "./ParameterStoreSpeedRules.sol";
import {ParameterStoreStorage} from "./ParameterStoreStorage.sol";
import {MarketParams, MarketSpeedLimits, SpeedLimit} from "./types/ParameterStoreTypes.sol";

/// @title ParameterStoreLoosenLogic
/// @notice Bodies of every loosen setter: each moves one risk parameter in its riskier direction.
/// @dev Reached only by delegatecall from the ParameterStore, which checks the caller's role.
// Bodies of selectors the ParameterStore declares; only fully implemented pieces are inherited.
// solhint-disable comprehensive-interface
// Every external call here is a view (STATICCALL), so none can re-enter the store or reorder its events.
// forge-lint: disable-start(reentrancy-events)
contract ParameterStoreLoosenLogic is ParameterStoreRisk, IParameterStoreLoosen, IParameterStoreLogic {
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
        return (keccak256("ParameterStoreLoosenLogic"), _TIMELOCK, address(_REGISTRY), _BLOCK_TIME, _HAS_SEQUENCER);
    }

    /// @inheritdoc IParameterStoreLoosen
    function loosenHardHealthFloor(
        uint256 marketId,
        uint256 value
    ) external override {
        _onlyDelegated();
        _requireMarket(marketId);
        MarketParams storage p = _s().market[marketId];
        uint256 old = p.hardHealthFloor;
        if (value >= old) revert NotLooser();
        // A value below 1.00 switches the floor off; off counts as 1.00 in the step, since Aave's own HF 1 applies.
        uint256 stored = value < WAD ? 0 : value;
        _step(old - (stored == 0 ? WAD : stored) <= HF_STEP, "hardHealthFloor", bytes32(marketId));
        _spaceLoosening("hardHealthFloor", bytes32(marketId));
        p.hardHealthFloor = stored;
        emit ParameterLoosened("hardHealthFloor", bytes32(marketId), old, stored, msg.sender);
    }

    /// @inheritdoc IParameterStoreLoosen
    function loosenSlippageAllowanceBps(
        uint256 marketId,
        uint16 value
    ) external override {
        _onlyDelegated();
        _requireMarket(marketId);
        MarketParams storage p = _s().market[marketId];
        uint16 old = p.slippageAllowanceBps;
        if (value <= old) revert NotLooser();
        if (value >= BPS) revert OutOfBounds();
        Market memory m = _REGISTRY.getMarket(marketId);
        // A live market must keep the Avana fee intact at its smallest bonus.
        if (_live(m.status) && !_feeBoundHolds(_minLb(m), value, _s().g.avanaFeeShareBps)) revert OutOfBounds();
        _step(value <= uint256(old) + SLIPPAGE_STEP_BPS, "slippageAllowanceBps", bytes32(marketId));
        _spaceLoosening("slippageAllowanceBps", bytes32(marketId));
        p.slippageAllowanceBps = value;
        emit ParameterLoosened("slippageAllowanceBps", bytes32(marketId), old, value, msg.sender);
    }

    /// @inheritdoc IParameterStoreLoosen
    function loosenFloorRoundingAllowance(
        address asset,
        uint256 value
    ) external override {
        _onlyDelegated();
        uint256 old = _s().floorRoundingAllowance[asset];
        if (value <= old) revert NotLooser();
        _requireRoundingAllowance(asset, value);
        _s().floorRoundingAllowance[asset] = value;
        emit ParameterLoosened("floorRoundingAllowance", _a(asset), old, value, msg.sender);
    }

    /// @inheritdoc IParameterStoreLoosen
    function loosenRouteDepthThreshold(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind,
        uint256 depthThreshold
    ) external override {
        _onlyDelegated();
        _requireMarket(marketId);
        bytes32 slotKey = keccak256(abi.encode(marketId, token, debtAsset, kind));
        uint256 old = _s().routeDepth[slotKey];
        if (depthThreshold >= old) revert NotLooser();
        if (depthThreshold == 0) revert OutOfBounds();
        _s().routeDepth[slotKey] = depthThreshold;
        emit RouteDepthThresholdSet(marketId, token, debtAsset, kind, old, depthThreshold);
    }

    /// @dev One step: at most ×1.5 of the old value, or up to `USD_CAP_REOPEN_BASE` so a zero cap can reopen.
    function _capStepOk(
        uint256 old,
        uint256 value
    ) private pure returns (bool) {
        return value <= USD_CAP_REOPEN_BASE || value * BPS <= old * CAP_STEP_BPS;
    }

    /// @inheritdoc IParameterStoreLoosen
    function loosenMarketUsdCap(
        uint256 marketId,
        uint256 value
    ) external override {
        _onlyDelegated();
        Market memory m = _market(marketId);
        uint256 old = _s().marketUsdCap[marketId];
        if (value <= old) revert NotLooser();
        if (value > USD_CAP_MAX) revert OutOfBounds();
        _step(_capStepOk(old, value), "marketUsdCap", bytes32(marketId));
        _requireAddCap(m, value, _s().topUpSliceUsd[marketId], _s().stressFloorUsd[marketId]);
        _spaceLoosening("marketUsdCap", bytes32(marketId));
        _s().marketUsdCap[marketId] = value;
        emit CapLoosened("marketUsdCap", bytes32(marketId), old, value, msg.sender);
    }

    /// @inheritdoc IParameterStoreLoosen
    function loosenTopUpSliceUsd(
        uint256 marketId,
        uint256 value
    ) external override {
        _onlyDelegated();
        Market memory m = _market(marketId);
        uint256 old = _s().topUpSliceUsd[marketId];
        uint256 cap = _s().marketUsdCap[marketId];
        if (value <= old) revert NotLooser();
        if (value > cap) revert OutOfBounds();
        uint256 base = cap / 10 > old ? cap / 10 : old;
        _step(value * BPS <= base * CAP_STEP_BPS, "topUpSliceUsd", bytes32(marketId));
        _requireAddCap(m, cap, value, _s().stressFloorUsd[marketId]);
        _spaceLoosening("topUpSliceUsd", bytes32(marketId));
        _s().topUpSliceUsd[marketId] = value;
        emit CapLoosened("topUpSliceUsd", bytes32(marketId), old, value, msg.sender);
    }

    /// @inheritdoc IParameterStoreLoosen
    function loosenTokenUsdCap(
        address hub,
        address token,
        uint256 value
    ) external override {
        _onlyDelegated();
        _requireHub(hub);
        uint256 old = _s().tokenUsdCap[hub][token];
        bytes32 scope = _pair(hub, token);
        if (value <= old) revert NotLooser();
        if (value > USD_CAP_MAX) revert OutOfBounds();
        _step(_s().tokenCapSet[hub][token] && _capStepOk(old, value), "tokenUsdCap", scope);
        _spaceLoosening("tokenUsdCap", scope);
        _s().tokenUsdCap[hub][token] = value;
        emit CapLoosened("tokenUsdCap", scope, old, value, msg.sender);
    }

    /// @inheritdoc IParameterStoreLoosen
    function loosenPoolShareMaxBps(
        uint16 value
    ) external override {
        _onlyDelegated();
        uint16 old = _s().poolShareMaxBps;
        if (value <= old) revert NotLooser();
        if (value > BPS) revert OutOfBounds();
        _s().poolShareMaxBps = value;
        emit CapLoosened("poolShareMaxBps", bytes32(0), old, value, msg.sender);
    }

    /// @inheritdoc IParameterStoreLoosen
    function loosenMinPledgeUsd(
        uint256 marketId,
        uint256 value
    ) external override {
        _onlyDelegated();
        _requireMarket(marketId);
        MarketParams storage p = _s().market[marketId];
        uint256 old = p.minPledgeUsd;
        if (value >= old) revert NotLooser();
        p.minPledgeUsd = value;
        emit MinPledgeUsdSet(marketId, old, value);
    }

    /// @inheritdoc IParameterStoreLoosen
    function loosenPoolShareMaxBpsOf(
        uint256 marketId,
        uint16 value
    ) external override {
        _onlyDelegated();
        bytes32 poolKey = _poolKey(_market(marketId));
        uint16 old = _poolShareOf(poolKey);
        if (value <= old) revert NotLooser();
        if (value > _s().poolShareMaxBps) revert OutOfBounds();
        _s().poolShareOverride[poolKey] = value;
        emit CapLoosened("poolShareMaxBpsOf", poolKey, old, value, msg.sender);
    }

    /// @notice Body of `IParameterStore.loosenMaxShortfallBps`.
    function loosenMaxShortfallBps(
        uint16 value
    ) external {
        _onlyDelegated();
        uint16 old = _s().g.maxShortfallBps;
        if (value <= old) revert NotLooser();
        if (value > SHORTFALL_MAX_BPS) revert OutOfBounds();
        _s().g.maxShortfallBps = value;
        emit ParameterLoosened("maxShortfallBps", bytes32(0), old, value, msg.sender);
    }

    /// @notice Body of `IParameterStore.loosenDebtStressRiseBps`.
    function loosenDebtStressRiseBps(
        address asset,
        uint16 value
    ) external {
        _onlyDelegated();
        uint16 old = _s().debtStressRiseBps[asset];
        if (value >= old) revert NotLooser();
        if (value < STRESS_RISE_MIN_BPS) revert OutOfBounds();
        _s().debtStressRiseBps[asset] = value;
        emit ParameterLoosened("debtStressRiseBps", _a(asset), old, value, msg.sender);
    }

    /// @notice Body of `IParameterStore.loosenGateRecoverySeconds`.
    function loosenGateRecoverySeconds(
        uint64 value
    ) external {
        _onlyDelegated();
        uint64 old = _s().g.gateRecoverySeconds;
        if (value >= old) revert NotLooser();
        if (value < GATE_RECOVERY_MIN) revert OutOfBounds();
        _s().g.gateRecoverySeconds = value;
        emit ParameterLoosened("gateRecoverySeconds", bytes32(0), old, value, msg.sender);
    }

    /// @notice Body of `IParameterStore.loosenBreakerDeficitMax`.
    function loosenBreakerDeficitMax(
        address hub,
        address asset,
        uint256 value
    ) external {
        _onlyDelegated();
        _requireHub(hub);
        uint256 old = _s().breakerDeficitMax[hub][asset];
        if (value <= old) revert NotLooser();
        (bool found, uint256 coverageMin,,) = _scanReserves(asset, hub);
        if (!found) revert UnknownDebtReserve(address(0), 0);
        if (value > coverageMin) revert OutOfBounds();
        _s().breakerDeficitMax[hub][asset] = value;
        emit ParameterLoosened("breakerDeficitMax", _pair(hub, asset), old, value, msg.sender);
    }

    /// @notice Body of `IParameterStore.loosenMarketSpeedLimits`.
    function loosenMarketSpeedLimits(
        uint256 marketId,
        MarketSpeedLimits calldata limits
    ) external {
        _onlyDelegated();
        _requireMarket(marketId);
        MarketSpeedLimits memory old = _s().marketSpeed[marketId];
        (bool noTighter, bool looser) = ParameterStoreSpeedRules.compareMarket(limits, old);
        if (!noTighter || !looser) revert NotLooser();
        if (!ParameterStoreSpeedRules.validMarket(limits)) revert OutOfBounds();
        _s().marketSpeed[marketId] = limits;
        emit IParameterStore.MarketSpeedLimitsSet(marketId, old, limits, false);
    }

    /// @notice Body of `IParameterStore.loosenDebtSpeedLimit`.
    function loosenDebtSpeedLimit(
        address hub,
        address asset,
        SpeedLimit calldata limit
    ) external {
        _onlyDelegated();
        _requireHub(hub);
        SpeedLimit memory old = _s().debtSpeed[hub][asset];
        (bool noTighter, bool looser) = ParameterStoreSpeedRules.compareDebt(limit, old);
        if (!noTighter || !looser) revert NotLooser();
        if (!ParameterStoreSpeedRules.validDebt(limit)) revert OutOfBounds();
        // forge-lint: disable-next-line(unused-return)
        (bool found,,,) = _scanReserves(asset, hub);
        if (!found) revert UnknownDebtReserve(address(0), 0);
        _s().debtSpeed[hub][asset] = limit;
        emit IParameterStore.DebtSpeedLimitSet(hub, asset, old, limit, false);
    }
}
// forge-lint: disable-end(reentrancy-events)
