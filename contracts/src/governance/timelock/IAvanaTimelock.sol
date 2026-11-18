// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAvanaTimelock
/// @notice Executor of every privileged change to Avana: a non-upgradeable OpenZeppelin `TimelockController` with
/// two delays, a grace window, public execution and DAO-only cancels of role-change and restoring operations.
/// @dev Holds `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` on every upgradeable Avana contract.
interface IAvanaTimelock {
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

    /// @notice `setNormalDelay` executed.
    event NormalDelayChanged(uint256 previousDelay, uint256 newDelay);

    /// @notice A short-delay list entry was set, at construction or by `setShortDelaySelector`.
    event ShortDelaySelectorSet(address indexed target, bytes4 indexed selector, bool enabled);

    /// @notice Public execution was set, at construction or by `togglePublicExecution`.
    event PublicExecutionToggled(bool enabled);

    /// @notice An expired operation was removed by `cleanupExpiredOperation`.
    event ExpiredOperationCleaned(bytes32 indexed id);

    /// @notice Sets the delay of every operation that is not entirely on the short-delay list.
    /// @dev Only the timelock. Reverts `DelayOutOfBounds` outside `[MIN_NORMAL_DELAY, MAX_DELAY]`.
    function setNormalDelay(
        uint256 newDelay
    ) external;

    /// @notice Adds or removes one `(target, selector)` pair of the short-delay list.
    /// @dev Only the timelock. Reverts `InvalidShortDelaySelector` when enabling a pair outside the short-eligible set.
    function setShortDelaySelector(
        address target,
        bytes4 selector,
        bool enabled
    ) external;

    /// @notice Turns public execution on or off.
    /// @dev Only the timelock.
    function togglePublicExecution(
        bool enabled
    ) external;

    /// @notice Removes an expired operation so the same calls can be scheduled again.
    /// @dev Callable by anyone; reverts `OperationNotExpired` unless the operation is expired.
    function cleanupExpiredOperation(
        bytes32 id
    ) external;

    /// @notice Short delay, seconds (12 hours; 60 seconds on a test network).
    function SHORT_DELAY() external view returns (uint256);

    /// @notice Upper bound of the normal delay, seconds (5 days).
    function MAX_DELAY() external view returns (uint256);

    /// @notice Lower bound of the normal delay, seconds (4 days; 60 seconds on a test network).
    function MIN_NORMAL_DELAY() external view returns (uint256);

    /// @notice How long a ready operation stays executable, seconds (14 days).
    function GRACE_PERIOD() external view returns (uint256);

    /// @notice Current normal delay, seconds.
    function normalDelay() external view returns (uint256);

    /// @notice Whether `(target, selector)` is on the short-delay list.
    function isShortDelaySelector(
        address target,
        bytes4 selector
    ) external view returns (bool);

    /// @notice Whether `(target, selector)` is in the immutable short-eligible set, the only pairs the short-delay
    /// list may ever hold.
    function isShortEligible(
        address target,
        bytes4 selector
    ) external view returns (bool);

    /// @notice Whether `(target, selector)` is in the immutable DAO-only cancel set.
    function isDaoOnlyCancelSelector(
        address target,
        bytes4 selector
    ) external view returns (bool);

    /// @notice Delay these calls need: `SHORT_DELAY` if non-empty and every call is short-listed, else the normal
    /// delay.
    /// @dev Reverts `TimelockInvalidOperationLength` when the arrays differ in length.
    function requiredDelay(
        address[] calldata targets,
        bytes[] calldata payloads
    ) external view returns (uint256 delay);

    /// @notice Whether anyone may execute ready operations.
    function publicExecution() external view returns (bool);

    /// @notice Whether a scheduled, not executed operation reached `readyAt + GRACE_PERIOD`.
    function isOperationExpired(
        bytes32 id
    ) external view returns (bool);

    /// @notice Whether every call of the pending operation is a role change, so only `DAO_CANCELLER_ROLE` may
    /// cancel it.
    function isRoleChangeOperation(
        bytes32 id
    ) external view returns (bool);

    /// @notice Whether every call of the pending operation is in the DAO-only cancel set, so only
    /// `DAO_CANCELLER_ROLE` may cancel it.
    function isRestoringOperation(
        bytes32 id
    ) external view returns (bool);
}

/// @notice Addresses of the three contracts whose selectors the AvanaTimelock's short-eligible and DAO-only cancel
/// sets name.
struct GovernedTargets {
    address parameterStore;
    address marketRegistry;
    address lpVaultSwap;
}

/// @notice One `(target, selector)` pair of the AvanaTimelock's short-eligible or DAO-only cancel set.
struct SelectorPair {
    address target;
    bytes4 selector;
}
