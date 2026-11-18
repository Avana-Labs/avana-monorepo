// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtReserveParams} from "./types/DebtReserveParams.sol";
import {FeedDef} from "./types/FeedDef.sol";
import {MarketParams} from "./types/MarketParams.sol";

/// @title IParameterStoreListing
/// @notice Setters the listing batches of markets, tokens and debt reserves use.
/// @dev Every setter requires `APPLICATION_ADMIN` and runs through the timelock at the normal delay.
interface IParameterStoreListing {
    /// @notice Writes a registered market's parameters, including `minPledgeUsd`.
    /// @dev Reverts `NotInListing` unless the market is `Registered`.
    function setInitialMarketParams(
        uint256 marketId,
        MarketParams calldata params
    ) external;

    /// @notice Writes the initial caps of a registered, not yet active market.
    /// @dev Reverts `NotInListing` unless the market is `Registered`.
    /// @param initialMarketUsdCap Regular pledge budget, 8-decimal USD.
    /// @param initialTopUpSliceUsd Rescue top-up budget, 8-decimal USD.
    /// @param initialStressFloorUsd Minimum price per whole vault token for cap booking, 8-decimal USD.
    function setInitialMarketCaps(
        uint256 marketId,
        uint256 initialMarketUsdCap,
        uint256 initialTopUpSliceUsd,
        uint256 initialStressFloorUsd
    ) external;

    /// @notice Writes the initial exposure cap of a listed token on a Hub that has none yet.
    /// @dev Reverts `NotInListing` if the pair's cap was ever written, even if since tightened to 0.
    /// @param cap Aggregate exposure cap across every market of the Hub, 8-decimal USD.
    function setInitialTokenCap(
        address hub,
        address token,
        uint256 cap
    ) external;

    /// @notice Adds a feed definition or changes its settings, pinned decimals or bounds.
    /// @dev Reads decimals and answer bounds from the aggregator, ignoring those fields of `def`.
    function setFeed(
        address feed,
        FeedDef calldata def
    ) external;

    /// @notice Writes the settlement parameters of one debt asset.
    /// @dev Reverts `TokenNotListed` unless the asset is a listed token or has a fixed-price source.
    /// @param p The asset's settlement parameters, base units of `asset`.
    function setDebtAssetParams(
        address asset,
        DebtReserveParams calldata p
    ) external;
}
