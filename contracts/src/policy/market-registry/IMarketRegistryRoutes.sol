// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IMarketRegistryRoutes
/// @notice Governance of swap routes from a market's pool token into a debt asset, used by settlement.
/// @dev Every function is restricted by the AccessManager: `disableRoute` and `restoreRoute` take the tighten role, the rest the governance role. `kind` is the slot: 0 primary, 1 backup.
interface IMarketRegistryRoutes {
    /// @notice Adds or changes the primary or backup swap route of a market's pool token into a debt asset.
    /// @dev Reverts `InvalidRoute` on a failed route check. Replacing a route revokes the old one's approval.
    function setRoute(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind,
        address route
    ) external;

    /// @notice Disables a swap route until it is restored or replaced.
    /// @dev No expiry.
    function disableRoute(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind
    ) external;

    /// @notice Re-enables a previously approved swap route for a slot.
    /// @dev Only the slot's current route; re-runs the `setRoute` checks.
    function restoreRoute(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind,
        address route
    ) external;
}
