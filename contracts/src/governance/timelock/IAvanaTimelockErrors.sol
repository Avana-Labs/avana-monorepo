// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAvanaTimelockErrors
/// @notice Errors the AvanaTimelock adds to OpenZeppelin `TimelockController`.
interface IAvanaTimelockErrors {
    /// @notice `schedule` or `scheduleBatch` asked for less than the operation's required delay.
    error DelayBelowRequired(uint256 delay, uint256 required);

    /// @notice `setNormalDelay` outside `[MIN_NORMAL_DELAY, MAX_DELAY]`.
    error DelayOutOfBounds(uint256 delay);

    /// @notice `execute` or `executeBatch` at or after `readyAt + GRACE_PERIOD`.
    error OperationExpired(bytes32 id);

    /// @notice `cleanupExpiredOperation` on an operation that is not expired.
    error OperationNotExpired(bytes32 id);

    /// @notice A canceller without `DAO_CANCELLER_ROLE` tried to cancel a role-change operation.
    error RoleChangeCancelRestricted(bytes32 id);

    /// @notice A canceller without `DAO_CANCELLER_ROLE` tried to cancel a restoring operation.
    error RestoringCancelRestricted(bytes32 id);

    /// @notice A grant of the timelock's `DEFAULT_ADMIN_ROLE` to any account but the timelock itself.
    error AdminRoleOnlyTimelock(bytes32 role, address account);

    /// @notice Public execution is off and the caller lacks `EXECUTOR_ROLE`.
    error ExecutionNotPublic(address caller);

    /// @notice `updateDelay` is disabled; the minimum delay stays `SHORT_DELAY` for life.
    error UpdateDelayDisabled();

    /// @notice A short-delay pair outside the short-eligible set, or an invalid pair given to the constructor.
    error InvalidShortDelaySelector(address target, bytes4 selector);

    /// @notice The constructor received an invalid DAO-only cancel pair.
    error InvalidDaoCancelSelector(address target, bytes4 selector);

    /// @notice A grant or revoke of the open executor role other than through `togglePublicExecution`.
    error PublicExecutionOnlyByToggle();

    /// @notice A revoke or renounce of the timelock's own `DEFAULT_ADMIN_ROLE`.
    error TimelockAdminRequired();

    /// @notice The constructor's role lists are invalid (zero account, under two proposers, no DAO canceller, or a
    /// DAO canceller without `CANCELLER_ROLE`).
    error InvalidRoleHolders();

    /// @notice The governed targets hold a zero address, repeat one another or name the timelock.
    error InvalidGovernedTargets();
}
