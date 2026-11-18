// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Market} from "../../types/MarketTypes.sol";
import {MarketStatus} from "../market-registry/types/MarketRegistryTypes.sol";
import {IParameterStoreLogic} from "./IParameterStoreLogic.sol";
import {ParameterStoreRisk} from "./ParameterStoreRisk.sol";
import {ParameterStoreStorage} from "./ParameterStoreStorage.sol";
import {FeedDef, MarketParams} from "./types/ParameterStoreTypes.sol";

/// @title ParameterStoreAdminOracleLogic
/// @notice Bodies of the structural feed setters, the liveness-checked setters and `liquidationLivenessHolds`.
/// @dev Runs only by delegatecall from the ParameterStore, which checks the caller's role.
// Bodies of selectors the ParameterStore declares; only fully implemented pieces are inherited.
// solhint-disable comprehensive-interface
// Every external call here is a view (STATICCALL), so none can re-enter the store or reorder its events.
// forge-lint: disable-start(reentrancy-events)
contract ParameterStoreAdminOracleLogic is ParameterStoreRisk, IParameterStoreLogic {
    /// @notice Fixes the implementation immutables; they must equal the ParameterStore's.
    constructor(
        address marketRegistry,
        uint32 chainBlockTime
    ) ParameterStoreStorage(marketRegistry, chainBlockTime) {}

    /// @inheritdoc IParameterStoreLogic
    function logicConfig()
        external
        view
        override
        returns (bytes32 kind, address marketRegistry, uint32 chainBlockTime)
    {
        return (keccak256("ParameterStoreAdminOracleLogic"), address(_REGISTRY), _BLOCK_TIME);
    }

    /// @notice Body of `IParameterStore.setBorrowPriceMaxAge`.
    function setBorrowPriceMaxAge(
        address feed,
        uint32 value
    ) external {
        _onlyDelegated();
        FeedDef storage d = _feed(feed);
        if (value == 0 || value > d.feedMaxAge) revert OutOfBounds();
        d.borrowPriceMaxAge = value;
        _emitFeed(feed, d);
    }

    /// @notice Body of `IParameterStore.setLiquidationPriceMaxAge`.
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
        _emitFeed(feed, d);
    }

    /// @notice Body of `IParameterStore.setFeedMaxAge`.
    function setFeedMaxAge(
        address feed,
        uint32 value
    ) external {
        _onlyDelegated();
        FeedDef storage d = _feed(feed);
        if (value != uint256(d.feedHeartbeat) + d.heartbeatMargin) revert OutOfBounds();
        d.feedMaxAge = value;
        _emitFeed(feed, d);
    }

    /// @notice Body of `IParameterStore.setMaxFlashFeeBps`.
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

    /// @notice Body of `IParameterStore.setSlippageAllowanceMinBps`.
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

    /// @notice Body of `IParameterStore.liquidationLivenessHolds`.
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
}
// forge-lint: disable-end(reentrancy-events)
