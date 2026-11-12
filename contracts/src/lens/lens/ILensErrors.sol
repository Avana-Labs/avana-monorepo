// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILensErrors
/// @notice Errors of the Lens: calls while the lock is held, page sizes above the limit, and previews of a debt
/// reserve or proxy LPVaultSwap would reject.
interface ILensErrors {
    /// @notice An Avana call is in flight (`LOCK.isLocked()` is true).
    /// @custom:spec REQ-LENS-006, REQ-LENS-021
    error Locked();

    /// @notice A paged call asked for more than `LENS_MAX_PAGE` entries.
    /// @param limit The requested page size.
    /// @custom:spec REQ-LENS-020, REQ-LENS-023
    error LimitTooHigh(uint256 limit);

    /// @notice The debt reserve is not in the MarketRegistry's approved set for the Spoke.
    /// @param spoke The CDP Spoke.
    /// @param reserveId The debt reserve.
    /// @custom:spec REQ-LENS-016, REQ-LENS-030, REQ-LENS-032
    error UnknownDebtReserve(address spoke, uint256 reserveId);

    /// @notice The address is not a registered proxy of the vault token (`isValidProxy` is false).
    /// @param proxy The address passed as proxy.
    /// @custom:spec REQ-LENS-016, REQ-LENS-033
    error UnknownProxy(address proxy);

    /// @notice No approved debt reserve of any Spoke lends the asset passed to `getTailCoverage`.
    /// @param debtAsset The asset passed.
    /// @custom:spec REQ-LENS-034, REQ-LENS-039
    error UnknownDebtAsset(address debtAsset);

    /// @notice The eight Lens modules passed to the Lens constructor do not report the same core addresses, or the
    /// liquidation module was given no Aave sizing contract.
    /// @custom:spec REQ-LENS-001, REQ-LENS-002
    error InvalidModules();
}
