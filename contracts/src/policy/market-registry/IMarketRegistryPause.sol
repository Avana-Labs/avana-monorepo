// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PauseReason} from "../../types/PauseReason.sol";
import {PauseState} from "../../types/PauseState.sol";

/// @title IMarketRegistryPause
/// @notice The pause state of each Hub on the chain, with the states None, Frozen and Paused, and the reason of a
/// pause. A Hub's state applies to every CDP Spoke and market whose home Hub it is and to every debt reserve it funds;
/// a pause of one Hub stops no other Hub's markets (AMMN-FLOW-19), and a pause of a funding Hub stops every cross-Hub
/// line it funds (AMMN-SM-06).
/// @dev Guardian calls are immediate; `APPLICATION_ADMIN` calls are timelock operations, at the short delay for
/// `freeze` and `pause` and the normal delay for `unfreeze` and `unpause`. Frozen blocks new pledges by accounts with no
/// debt and borrowing. Paused(General) also blocks every non-rescue top-up and re-credit, withdraw-with-debt,
/// removal-with-debt and repay with collateral; Paused(MintPathSuspect) also blocks rescue top-ups. Repay, debt-free
/// withdrawal and removal, fee collection, zero-credit release, liquidation and pending settlement never read the state
/// or the reason. No expiry. Each change of state emits `PauseStateChanged(hub, previous, current, msg.sender)`; each change
/// of reason emits `PauseReasonChanged`.
interface IMarketRegistryPause {
    /// @notice Moves the state from None to Frozen.
    /// @dev `APPLICATION_FREEZE_GUARDIAN` (immediate) or `APPLICATION_ADMIN` (short delay), else `Unauthorized`.
    /// Reverts `AlreadyFrozen` when Frozen and `AlreadyPaused` when Paused.
    /// @param hub The Hub.
    /// @custom:spec REQ-MREG-001, REQ-MREG-004, REQ-MREG-017, SPEC-GOV-004, REQ-ACCESS-085, Q-227, Q-262
    function freeze(
        address hub
    ) external;

    /// @notice Moves the state from None or Frozen to Paused(reason), or changes the reason while Paused.
    /// @dev `APPLICATION_PAUSE_GUARDIAN` (immediate) or `APPLICATION_ADMIN` (short delay), else `Unauthorized`.
    /// Reverts `InvalidPauseReason` for `reason == None` or, while Paused, for the current reason.
    /// @param hub The Hub.
    /// @param reason `General` or `MintPathSuspect`.
    /// @custom:spec REQ-MREG-001, REQ-MREG-004, REQ-MREG-017, REQ-MREG-024, SPEC-GOV-004, REQ-ACCESS-085, Q-227, Q-252, Q-262
    function pause(
        address hub,
        PauseReason reason
    ) external;

    /// @notice Applies `freeze` to every Hub registered on the chain in one call.
    /// @dev `APPLICATION_FREEZE_GUARDIAN` (immediate) or `APPLICATION_ADMIN` (short delay), else `Unauthorized`. A Hub
    /// already Frozen or Paused is left unchanged; emits `PauseStateChanged` once per Hub changed and reverts
    /// `AlreadyFrozen` when no Hub changes.
    /// @custom:spec REQ-ACCESS-172, REQ-ACCESS-085, REQ-ACCESS-122, REQ-CONFIG-082, SPEC-GOV-004
    function freezeAll() external;

    /// @notice Applies `pause(hub, reason)` to every Hub registered on the chain in one call.
    /// @dev `APPLICATION_PAUSE_GUARDIAN` (immediate) or `APPLICATION_ADMIN` (short delay), else `Unauthorized`.
    /// Reverts `InvalidPauseReason` for `reason == None`. A Hub already Paused with `reason` is left unchanged; emits
    /// `PauseStateChanged` and `PauseReasonChanged` once per Hub changed and reverts `AlreadyPaused` when no Hub
    /// changes.
    /// @param reason `General` or `MintPathSuspect`.
    /// @custom:spec REQ-ACCESS-172, REQ-ACCESS-085, REQ-ACCESS-122, REQ-ACCESS-162, REQ-CONFIG-082, SPEC-GOV-004
    function pauseAll(
        PauseReason reason
    ) external;

    /// @notice Moves the state from Frozen to None.
    /// @dev `APPLICATION_PAUSE_GUARDIAN` or `APPLICATION_ADMIN`, else `Unauthorized`; a holder of only the freeze role
    /// cannot unfreeze. Reverts `NotFrozen` when None and `CannotUnfreezeWhilePaused` when Paused.
    /// @param hub The Hub.
    /// @custom:spec REQ-MREG-001, REQ-MREG-004, REQ-MREG-017, SPEC-GOV-004, REQ-ACCESS-086, Q-227
    function unfreeze(
        address hub
    ) external;

    /// @notice Moves the state from Paused to None and clears the reason.
    /// @dev `APPLICATION_PAUSE_GUARDIAN` or `APPLICATION_ADMIN`, else `Unauthorized`. Reverts `NotPaused` unless
    /// Paused. The state returns to None, never to Frozen.
    /// @param hub The Hub.
    /// @custom:spec REQ-MREG-001, REQ-MREG-004, REQ-MREG-017, SPEC-GOV-004, REQ-ACCESS-086, Q-227
    function unpause(
        address hub
    ) external;

    /// @notice A Hub's pause state.
    /// @param hub The Hub.
    /// @return state None, Frozen or Paused (None for an unrecorded Hub, which no market uses).
    /// @custom:spec REQ-MREG-001, REQ-MREG-002, REQ-MREG-003
    function pauseState(
        address hub
    ) external view returns (PauseState state);

    /// @notice The reason of a Hub's current pause.
    /// @param hub The Hub.
    /// @return reason `None` exactly when the state is not Paused.
    /// @custom:spec REQ-MREG-024, Q-252
    function pauseReason(
        address hub
    ) external view returns (PauseReason reason);
}
