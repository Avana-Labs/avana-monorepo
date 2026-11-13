// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAvanaTimelockErrors
/// @notice Errors the AvanaTimelock adds to OpenZeppelin `TimelockController` (whose own errors
/// `TimelockInsufficientDelay`, `TimelockUnexpectedOperationState`, `TimelockUnexecutedPredecessor`,
/// `TimelockUnauthorizedCaller` and `TimelockInvalidOperationLength` still apply).
interface IAvanaTimelockErrors {
    /// @notice `schedule` or `scheduleBatch` asked for less than the operation's required delay.
    /// @param delay Requested delay, seconds.
    /// @param required `requiredDelay(targets, payloads)`, seconds.
    /// @custom:spec SPEC-GOV-001, REQ-ACCESS-117, REQ-ACCESS-141
    error DelayBelowRequired(uint256 delay, uint256 required);

    /// @notice `setNormalDelay` outside `[MIN_NORMAL_DELAY, MAX_DELAY]`.
    /// @param delay Rejected delay, seconds.
    /// @custom:spec SPEC-GOV-003, SPEC-GOV-015, REQ-ACCESS-125, REQ-ACCESS-154
    error DelayOutOfBounds(uint256 delay);

    /// @notice `execute` or `executeBatch` at or after `readyAt + GRACE_PERIOD`.
    /// @param id Operation identifier.
    /// @custom:spec SPEC-GOV-002, SPEC-GOV-013, REQ-ACCESS-118
    error OperationExpired(bytes32 id);

    /// @notice `cleanupExpiredOperation` on an operation that is not expired.
    /// @param id Operation identifier.
    /// @custom:spec SPEC-GOV-013, REQ-ACCESS-126
    error OperationNotExpired(bytes32 id);

    /// @notice A canceller without `DAO_CANCELLER_ROLE` tried to cancel a role-change operation.
    /// @param id Operation identifier.
    /// @custom:spec SPEC-GOV-005, REQ-ACCESS-019, REQ-ACCESS-119
    error RoleChangeCancelRestricted(bytes32 id);

    /// @notice A canceller without `DAO_CANCELLER_ROLE` tried to cancel a restoring operation (every call in the
    /// immutable DAO-only cancel set).
    /// @param id Operation identifier.
    /// @custom:spec SPEC-GOV-005, REQ-ACCESS-119, REQ-ACCESS-156
    error RestoringCancelRestricted(bytes32 id);

    /// @notice A grant of the timelock's `DEFAULT_ADMIN_ROLE` to any account but the timelock itself.
    /// @param role Role being granted.
    /// @param account Rejected grantee.
    /// @custom:spec REQ-ACCESS-153, REQ-ACCESS-168
    error AdminRoleOnlyTimelock(bytes32 role, address account);

    /// @notice Public execution is off and the caller lacks `EXECUTOR_ROLE`.
    /// @param caller Rejected caller.
    /// @custom:spec REQ-ACCESS-118, REQ-ACCESS-144
    error ExecutionNotPublic(address caller);

    /// @notice `updateDelay` is disabled; the minimum delay stays `SHORT_DELAY` for life.
    /// @custom:spec REQ-ACCESS-030, REQ-ACCESS-125
    error UpdateDelayDisabled();

    /// @notice `setShortDelaySelector` tried to enable a pair outside the immutable `SHORT_ELIGIBLE` set, or the
    /// constructor received a pair whose target is the timelock, whose selector is a role, upgrade or initializer
    /// selector, none of which may ever take the short delay, or whose target is not the deployed contract its
    /// selector belongs to.
    /// @param target Rejected target.
    /// @param selector Rejected selector.
    /// @custom:spec REQ-ACCESS-142, REQ-ACCESS-152, REQ-ACCESS-155
    error InvalidShortDelaySelector(address target, bytes4 selector);

    /// @notice The constructor received a DAO-only cancel pair whose target is the timelock, whose selector is a
    /// role, upgrade, flash-source, deployment-operation, cross-Hub or initializer selector, which would shield that
    /// change from every canceller but the Aave governance executor, or whose target is not the deployed contract its
    /// selector belongs to.
    /// @param target Rejected target.
    /// @param selector Rejected selector.
    /// @custom:spec REQ-ACCESS-181
    error InvalidDaoCancelSelector(address target, bytes4 selector);

    /// @notice A grant or revoke of `EXECUTOR_ROLE` for `address(0)` (the open executor role, public execution)
    /// other than through `togglePublicExecution` or the constructor's `publicExecution_`.
    /// @custom:spec REQ-ACCESS-144, REQ-ACCESS-029
    error PublicExecutionOnlyByToggle();

    /// @notice A revoke or renounce of the timelock's own `DEFAULT_ADMIN_ROLE`.
    /// @custom:spec REQ-ACCESS-182, REQ-ACCESS-001
    error TimelockAdminRequired();

    /// @notice The constructor's role lists break the role table: a zero account, fewer than two proposers, no DAO
    /// canceller, or a DAO canceller without `CANCELLER_ROLE`.
    /// @custom:spec REQ-ACCESS-183, REQ-ACCESS-160
    error InvalidRoleHolders();

    /// @notice The constructor's governed targets (ParameterStore, MarketRegistry, LPVaultSwap) hold a zero address,
    /// repeat one another or name the timelock.
    /// @custom:spec REQ-ACCESS-155, REQ-ACCESS-156
    error InvalidGovernedTargets();
}
