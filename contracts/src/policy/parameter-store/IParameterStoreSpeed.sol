// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketSpeedLimits} from "./types/MarketSpeedLimits.sol";
import {SpeedLimit} from "./types/SpeedLimit.sol";

/// @title IParameterStoreSpeed
/// @notice The borrow-speed and pledge-speed limits the RiskModule reads (Q-411): per market, a window length, borrow
/// and pledge rates and their USD minimums and maximums; per (funding Hub, debt asset), a window length, a rate and a
/// minimum and maximum in asset base units.
/// @dev A value never written reads as all zero, which the RiskModule treats as a closed window (REQ-RISK-096); the
/// first value is written by the loosen setter (the market's listing batch, the batch of the first `enableDebtReserve`
/// of the pair). Tighten setters take a value with no looser field and one strictly tighter (`NotStricter`): a lower
/// rate, minimum or maximum, or a longer window; they run at the short delay or at once by `APPLICATION_RISK_STEWARD`.
/// Loosen setters take the reverse (`NotLooser`) at the normal delay, by `APPLICATION_ADMIN` only. Both revert
/// `OutOfBounds` for a window outside `[3,600, 604,800]`, a rate above 10,000 or a minimum above its maximum. There is
/// no step limit and no spacing, so the large-borrow path (raise a market's `borrowMaxUsd`, then tighten it back) is
/// two operations.
/// @custom:spec REQ-PSTORE-035, REQ-PSTORE-036, REQ-CONFIG-049, Q-411
interface IParameterStoreSpeed {
    /// @notice A market's speed limits changed.
    /// @param marketId The market.
    /// @param oldLimits The previous value (all zero before the first write).
    /// @param newLimits The new value.
    /// @param tightened True for a tightening, false for a loosening.
    event MarketSpeedLimitsSet(
        uint256 indexed marketId, MarketSpeedLimits oldLimits, MarketSpeedLimits newLimits, bool tightened
    );

    /// @notice A (funding Hub, debt asset)'s borrow-speed limit changed.
    /// @param hub The funding Hub.
    /// @param asset The debt asset.
    /// @param oldLimit The previous value (all zero before the first write).
    /// @param newLimit The new value.
    /// @param tightened True for a tightening, false for a loosening.
    event DebtSpeedLimitSet(
        address indexed hub, address indexed asset, SpeedLimit oldLimit, SpeedLimit newLimit, bool tightened
    );

    /// @notice A market's speed limits.
    /// @dev Example at launch: `{21,600, 2,500, 2,500, 250,000e8, 2,500,000e8, 1,000,000e8, 10,000,000e8}`.
    /// @param marketId The market.
    /// @return limits All zero when never written.
    /// @custom:spec REQ-PSTORE-035
    function marketSpeedLimits(
        uint256 marketId
    ) external view returns (MarketSpeedLimits memory limits);

    /// @notice A (funding Hub, debt asset)'s borrow-speed limit, in base units of the asset.
    /// @dev Example at launch for GHO: `{2,500, 21,600, 500,000e18, 5,000,000e18}`.
    /// @param hub The funding Hub.
    /// @param asset The debt asset.
    /// @return limit All zero when never written.
    /// @custom:spec REQ-PSTORE-035
    function debtSpeedLimit(
        address hub,
        address asset
    ) external view returns (SpeedLimit memory limit);

    /// @notice Tightens a market's speed limits: no field looser, one strictly tighter.
    /// @dev Reverts `UnknownMarket` for an identifier never assigned, `NotStricter`, `OutOfBounds`.
    /// @param marketId The market.
    /// @param limits The full new value.
    /// @custom:spec REQ-PSTORE-036
    function tightenMarketSpeedLimits(
        uint256 marketId,
        MarketSpeedLimits calldata limits
    ) external;

    /// @notice Loosens a market's speed limits, or writes the first value: no field tighter, one strictly looser.
    /// @dev Reverts `UnknownMarket`, `NotLooser`, `OutOfBounds`.
    /// @param marketId The market.
    /// @param limits The full new value.
    /// @custom:spec REQ-PSTORE-036
    function loosenMarketSpeedLimits(
        uint256 marketId,
        MarketSpeedLimits calldata limits
    ) external;

    /// @notice Tightens a (funding Hub, debt asset)'s borrow-speed limit: no field looser, one strictly tighter.
    /// @dev Reverts `UnknownHub` unless the MarketRegistry records `hub`, `NotStricter`, `OutOfBounds`.
    /// @param hub The funding Hub.
    /// @param asset The debt asset.
    /// @param limit The full new value.
    /// @custom:spec REQ-PSTORE-036
    function tightenDebtSpeedLimit(
        address hub,
        address asset,
        SpeedLimit calldata limit
    ) external;

    /// @notice Loosens a (funding Hub, debt asset)'s borrow-speed limit, or writes the first value.
    /// @dev Reverts `UnknownHub`, `UnknownDebtReserve(address(0), 0)` when no approved debt reserve of a CDP Spoke draws
    /// `asset` from `hub`, `NotLooser`, `OutOfBounds`.
    /// @param hub The funding Hub.
    /// @param asset The debt asset.
    /// @param limit The full new value.
    /// @custom:spec REQ-PSTORE-036
    function loosenDebtSpeedLimit(
        address hub,
        address asset,
        SpeedLimit calldata limit
    ) external;
}
