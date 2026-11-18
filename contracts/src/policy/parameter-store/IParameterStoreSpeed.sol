// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketSpeedLimits} from "./types/MarketSpeedLimits.sol";
import {SpeedLimit} from "./types/SpeedLimit.sol";

/// @title IParameterStoreSpeed
/// @notice Borrow-speed and pledge-speed limits the RiskModule reads, per market and per (funding Hub, debt asset).
/// @dev A never-written value reads as all zero, a closed window; the loosen setter writes the first value.
interface IParameterStoreSpeed {
    /// @notice A market's speed limits changed.
    event MarketSpeedLimitsSet(
        uint256 indexed marketId, MarketSpeedLimits oldLimits, MarketSpeedLimits newLimits, bool tightened
    );

    /// @notice A (funding Hub, debt asset)'s borrow-speed limit changed.
    event DebtSpeedLimitSet(
        address indexed hub, address indexed asset, SpeedLimit oldLimit, SpeedLimit newLimit, bool tightened
    );

    /// @notice A market's speed limits.
    function marketSpeedLimits(
        uint256 marketId
    ) external view returns (MarketSpeedLimits memory limits);

    /// @notice A (funding Hub, debt asset)'s borrow-speed limit, in base units of the asset.
    function debtSpeedLimit(
        address hub,
        address asset
    ) external view returns (SpeedLimit memory limit);

    /// @notice Tightens a market's speed limits: no field looser, one strictly tighter.
    function tightenMarketSpeedLimits(
        uint256 marketId,
        MarketSpeedLimits calldata limits
    ) external;

    /// @notice Loosens a market's speed limits, or writes the first value: no field tighter, one strictly looser.
    function loosenMarketSpeedLimits(
        uint256 marketId,
        MarketSpeedLimits calldata limits
    ) external;

    /// @notice Tightens a (funding Hub, debt asset)'s borrow-speed limit: no field looser, one strictly tighter.
    function tightenDebtSpeedLimit(
        address hub,
        address asset,
        SpeedLimit calldata limit
    ) external;

    /// @notice Loosens a (funding Hub, debt asset)'s borrow-speed limit, or writes the first value.
    /// @dev Reverts `UnknownDebtReserve` when no approved debt reserve draws `asset` from `hub`.
    function loosenDebtSpeedLimit(
        address hub,
        address asset,
        SpeedLimit calldata limit
    ) external;
}
