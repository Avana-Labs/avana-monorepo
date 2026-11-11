// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RouteSlot} from "../../types/RouteSlot.sol";

/// @title IMarketRegistryStandby
/// @notice The routes in force for each listed token and the guardian switch to its pre-approved standby route.
/// @dev Preserves: every route in force passed the listing checks at the normal delay; the registry changes only its
/// own record and `priceRouteVersion`, so the LPOracle and the DebtOracle keep their freshness, validity and agreement
/// checks and a switch never forces Live. Exits and liquidation of other reserves never depend on a switch.
interface IMarketRegistryStandby {
    /// @notice A guardian's `useStandbyRoute` while the Aave DAO's cancel of the token's last switch holds.
    /// @param token The token.
    /// @param until First timestamp at which a guardian may switch again.
    /// @custom:spec REQ-MREG-028
    error StandbySwitchLocked(address token, uint256 until);

    /// @notice Puts the token's standby route in place of its primary or alternate route.
    /// @dev `APPLICATION_PAUSE_GUARDIAN` (immediate) or `APPLICATION_ADMIN` (short delay; only `DAO_CANCELLER_ROLE`
    /// can cancel the operation), else `Unauthorized`. Reverts `InvalidRouteSlot` unless `Primary` or `Alternate`,
    /// `TokenNotListed`, `NoStandbyRoute`, `StandbyAlreadyActive` unless no slot is replaced, and `ListingCheckFailed`
    /// if a standby leg lost its feed definition or, for the primary slot, has a heartbeat other than its feed's own configured heartbeat. A
    /// guardian's call reverts `StandbySwitchLocked(token, until)` for 5 days (the normal delay) after the
    /// Aave governance executor's `cancelStandbySwitch` of the token, so a guardian cannot re-apply a switch the DAO
    /// undid; the timelock's own call (short delay, DAO-only cancel) and `setPriceSource` end the lock. Increments
    /// `priceRouteVersion(token)`. Emits `StandbyRouteActivated`.
    /// @param token Listed token.
    /// @param slot Slot to replace.
    /// @custom:spec REQ-MREG-028, Q-248, Q-262, Q-263
    function useStandbyRoute(
        address token,
        RouteSlot slot
    ) external;

    /// @notice Undoes a standby switch at once.
    /// @dev Only `AAVE_GOVERNANCE_EXECUTOR`, else `Unauthorized`. Reverts `StandbyNotActive` unless a slot is
    /// replaced. Sets the replaced slot to `None`, increments `priceRouteVersion(token)` and starts the 5-day lock on
    /// the guardians' `useStandbyRoute` of the token. Emits
    /// `StandbySwitchCancelled`.
    /// @param token Listed token.
    /// @custom:spec REQ-MREG-028, Q-248
    function cancelStandbySwitch(
        address token
    ) external;

    /// @notice Returns the replaced slot to its recorded route.
    /// @dev `APPLICATION_ADMIN`, normal delay. Reverts `StandbyNotActive` unless a slot is replaced. Increments
    /// `priceRouteVersion(token)`. Emits `PriceRouteRestored`.
    /// @param token Listed token.
    /// @custom:spec REQ-MREG-028, Q-248
    function restorePriceRoute(
        address token
    ) external;

    /// @notice The token's routes in force, with the standby substituted into the replaced slot.
    /// @dev Never reverts; empty arrays and `None` for an unlisted token.
    /// @param token Listed token.
    /// @return primary Primary route in force.
    /// @return alternate Alternate route in force.
    /// @return replaced Slot the standby replaces, or `None`.
    /// @custom:spec REQ-MREG-028, REQ-ORACLE-094, Q-248
    function activePriceRoutes(
        address token
    ) external view returns (address[] memory primary, address[] memory alternate, RouteSlot replaced);

    /// @notice The end of the lock on the guardians' `useStandbyRoute` of the token after a DAO cancel.
    /// @dev 0 when no lock holds or ever held; a time in the past once the lock has lapsed. Never reverts.
    /// @param token Listed token.
    /// @return until First timestamp at which a guardian may switch again.
    /// @custom:spec REQ-MREG-028
    function standbySwitchLockedUntil(
        address token
    ) external view returns (uint256 until);

    /// @notice Counter incremented by every change of the token's routes in force.
    /// @dev An oracle that sees a version different from the one stored at its last `poke` restarts its disagreement
    /// timer and keeps its failure timer.
    /// @param token Listed token.
    /// @return version Route version.
    /// @custom:spec REQ-MREG-028, REQ-ORACLE-095, Q-248
    function priceRouteVersion(
        address token
    ) external view returns (uint64 version);
}
