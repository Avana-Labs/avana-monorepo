// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PauseReason} from "../../types/PauseReason.sol";
import {PauseState} from "../../types/PauseState.sol";

/// @title IMarketRegistryPause
/// @notice The pause state (None, Frozen, Paused) of each Hub on the chain, and the reason of a pause.
/// @dev Repay, debt-free exits and liquidation never read the pause state.
interface IMarketRegistryPause {
    /// @notice Moves the state from None to Frozen.
    /// @dev `APPLICATION_FREEZE_GUARDIAN` or `APPLICATION_ADMIN`.
    function freeze(
        address hub
    ) external;

    /// @notice Moves the state from None or Frozen to Paused(reason), or changes the reason while Paused.
    /// @dev `APPLICATION_PAUSE_GUARDIAN` or `APPLICATION_ADMIN`.
    function pause(
        address hub,
        PauseReason reason
    ) external;

    /// @notice Applies `freeze` to every Hub registered on the chain in one call.
    /// @dev `APPLICATION_FREEZE_GUARDIAN` or `APPLICATION_ADMIN`; reverts `AlreadyFrozen` when no Hub changes.
    function freezeAll() external;

    /// @notice Applies `pause(hub, reason)` to every Hub registered on the chain in one call.
    /// @dev `APPLICATION_PAUSE_GUARDIAN` or `APPLICATION_ADMIN`; reverts `AlreadyPaused` when no Hub changes.
    function pauseAll(
        PauseReason reason
    ) external;

    /// @notice Moves the state from Frozen to None.
    /// @dev `APPLICATION_PAUSE_GUARDIAN` or `APPLICATION_ADMIN`; the freeze role alone cannot unfreeze.
    function unfreeze(
        address hub
    ) external;

    /// @notice Moves the state from Paused to None and clears the reason.
    /// @dev `APPLICATION_PAUSE_GUARDIAN` or `APPLICATION_ADMIN`. The state returns to None, never to Frozen.
    function unpause(
        address hub
    ) external;

    /// @notice A Hub's pause state.
    /// @return state None, Frozen or Paused (None for an unrecorded Hub).
    function pauseState(
        address hub
    ) external view returns (PauseState state);

    /// @notice The reason of a Hub's current pause.
    /// @return reason `None` exactly when the state is not Paused.
    function pauseReason(
        address hub
    ) external view returns (PauseReason reason);
}
