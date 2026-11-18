// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RouteSlot} from "../../types/RouteSlot.sol";

/// @title IMarketRegistryStandby
/// @notice The routes in force for each listed token and the guardian switch to its pre-approved standby route.
/// @dev A switch changes only the registry's record and `priceRouteVersion`; oracles keep all their own checks.
interface IMarketRegistryStandby {
    /// @notice A guardian's `useStandbyRoute` while the Aave DAO's cancel of the token's last switch holds.
    /// @param until First timestamp at which a guardian may switch again.
    error StandbySwitchLocked(address token, uint256 until);

    /// @notice Puts the token's standby route in place of its primary or alternate route.
    /// @dev `APPLICATION_PAUSE_GUARDIAN` or `APPLICATION_ADMIN`; a guardian is locked out after a DAO cancel.
    function useStandbyRoute(
        address token,
        RouteSlot slot
    ) external;

    /// @notice Undoes a standby switch at once.
    /// @dev Only `AAVE_GOVERNANCE_EXECUTOR`. Starts the lock on the guardians' `useStandbyRoute` of the token.
    function cancelStandbySwitch(
        address token
    ) external;

    /// @notice Returns the replaced slot to its recorded route.
    /// @dev `APPLICATION_ADMIN` only.
    function restorePriceRoute(
        address token
    ) external;

    /// @notice The token's routes in force, with the standby substituted into the replaced slot.
    /// @dev Never reverts; empty arrays and `None` for an unlisted token.
    function activePriceRoutes(
        address token
    ) external view returns (address[] memory primary, address[] memory alternate, RouteSlot replaced);

    /// @notice The end of the lock on the guardians' `useStandbyRoute` of the token after a DAO cancel.
    /// @dev 0 when no lock holds or ever held; a time in the past once the lock has lapsed. Never reverts.
    function standbySwitchLockedUntil(
        address token
    ) external view returns (uint256 until);

    /// @notice Counter incremented by every change of the token's routes in force.
    /// @dev An oracle that sees a new version restarts its disagreement timer.
    function priceRouteVersion(
        address token
    ) external view returns (uint64 version);
}
