// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStore} from "./IParameterStore.sol";
import {IParameterStoreLogic} from "./IParameterStoreLogic.sol";
import {IParameterStoreTighten} from "./IParameterStoreTighten.sol";
import {ParameterStoreCapRules} from "./ParameterStoreCapRules.sol";
import {ParameterStoreRisk} from "./ParameterStoreRisk.sol";
import {ParameterStoreStorage} from "./ParameterStoreStorage.sol";
import {FeedDef, MarketDynamicCap, MarketParams} from "./types/ParameterStoreTypes.sol";

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
        uint32 chainBlockTime
    ) ParameterStoreStorage(timelock, marketRegistry, chainBlockTime) {}

    /// @inheritdoc IParameterStoreLogic
    function logicConfig()
        external
        view
        override
        returns (bytes32 kind, address timelock, address marketRegistry, uint32 chainBlockTime)
    {
        return (keccak256("ParameterStoreTightenLogic"), _TIMELOCK, address(_REGISTRY), _BLOCK_TIME);
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
        d.borrowPriceMaxAge = value;
        _emitFeed(feed, d);
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
        _s().debtStressRiseBps[asset] = value;
        emit ParameterTightened("debtStressRiseBps", _a(asset), old, value, msg.sender);
    }

    /// @notice Body of `IParameterStore.tightenDeficitMax`.
    function tightenDeficitMax(
        address hub,
        address asset,
        uint256 value
    ) external {
        _onlyDelegated();
        _requireHub(hub);
        uint256 old = _s().deficitMax[hub][asset];
        if (value >= old) revert NotStricter();
        _s().deficitMax[hub][asset] = value;
        emit ParameterTightened("deficitMax", _pair(hub, asset), old, value, msg.sender);
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

    /// @notice Body of `IParameterStore.tightenMarketDynamicCap`.
    function tightenMarketDynamicCap(
        uint256 marketId,
        MarketDynamicCap calldata terms
    ) external {
        _onlyDelegated();
        _requireMarket(marketId);
        MarketDynamicCap memory old = _s().marketDynamicCap[marketId];
        (bool noLooser, bool stricter) = ParameterStoreCapRules.compare(old, terms);
        if (!noLooser || !stricter) revert NotStricter();
        if (!ParameterStoreCapRules.valid(terms)) revert OutOfBounds();
        _s().marketDynamicCap[marketId] = terms;
        emit IParameterStore.MarketDynamicCapSet(marketId, old, terms, true);
    }
}
// forge-lint: disable-end(reentrancy-events)
