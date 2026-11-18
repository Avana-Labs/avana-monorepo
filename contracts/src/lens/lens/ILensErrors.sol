// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILensErrors
/// @notice Errors of the Lens.
interface ILensErrors {
    /// @notice An Avana call is in flight (`LOCK.isLocked()` is true).
    error Locked();

    /// @notice A paged call asked for more than `LENS_MAX_PAGE` entries.
    error LimitTooHigh(uint256 limit);

    /// @notice The debt reserve is not in the MarketRegistry's approved set for the Spoke.
    error UnknownDebtReserve(address spoke, uint256 reserveId);

    /// @notice The address is not a registered proxy of the vault token (`isValidProxy` is false).
    error UnknownProxy(address proxy);

    /// @notice No approved debt reserve of any Spoke lends the asset passed to `getTailCoverage`.
    error UnknownDebtAsset(address debtAsset);

    /// @notice The Lens modules disagree on core addresses, or the liquidation module has no Aave sizing contract.
    error InvalidModules();

    /// @notice The Hub lists no asset `assetId` (its underlying reads as address(0)).
    error UnknownHubAsset(address hub, uint256 assetId);
}
