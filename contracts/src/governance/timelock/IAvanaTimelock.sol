// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAvanaTimelockErrors} from "./IAvanaTimelockErrors.sol";
import {IAvanaTimelockEvents} from "./IAvanaTimelockEvents.sol";
import {IAvanaTimelockGovernance} from "./IAvanaTimelockGovernance.sol";
import {IAvanaTimelockViews} from "./IAvanaTimelockViews.sol";

/// @title IAvanaTimelock
/// @notice The one executor of every privileged change to Avana: a non-upgradeable extension of OpenZeppelin
/// Contracts 5.1.0 `TimelockController` with two delays, a grace window, public execution and a cancel restriction
/// on role-change and restoring operations.
/// @dev Holds its own `DEFAULT_ADMIN_ROLE` and no other admin (constructor `admin = address(0)`), and holds
/// `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` on every upgradeable Avana contract; immutable Avana contracts check
/// `msg.sender == TIMELOCK`; a grant of its `DEFAULT_ADMIN_ROLE` to any account but itself reverts
/// `AdminRoleOnlyTimelock`. The proposers are the 4-of-7 governance multisig and the Aave governance executor (never
/// fewer than two). `schedule` and `scheduleBatch` require `delay >= requiredDelay(targets, payloads)`: `SHORT_DELAY`
/// (12 hours) when every call is on the short-delay list, a subset of the immutable `SHORT_ELIGIBLE` set, otherwise
/// `normalDelay()` (5 days at launch, within `[MIN_NORMAL_DELAY, MAX_DELAY]` = 4 to 5 days). A ready operation is
/// executable for `GRACE_PERIOD` (14 days), by anyone while public execution is on, then expires. Any
/// `CANCELLER_ROLE` holder (governance multisig, Emergency Guardian, Aave Protocol Guardian, Aave governance
/// executor) cancels, except that an operation in which every call is a role change, or every call is in the
/// immutable DAO-only cancel set (a restoring operation), needs `DAO_CANCELLER_ROLE` too.
/// `getMinDelay()` returns `SHORT_DELAY`; `updateDelay` reverts `UpdateDelayDisabled`. OpenZeppelin's
/// `schedule`, `scheduleBatch`, `execute`, `executeBatch`, `cancel`, `hashOperation(Batch)`, `getTimestamp`,
/// `getOperationState` and `isOperation*` keep their signatures and are not repeated here.
/// @custom:spec REQ-ACCESS-001, REQ-ACCESS-013, REQ-ACCESS-016, REQ-ACCESS-017, REQ-ACCESS-018, REQ-ACCESS-019, REQ-ACCESS-020, REQ-ACCESS-021, REQ-ACCESS-114, REQ-ACCESS-140, REQ-ACCESS-141, REQ-ACCESS-142, REQ-ACCESS-143, REQ-ACCESS-144, REQ-ACCESS-153, REQ-ACCESS-154, REQ-ACCESS-155, REQ-ACCESS-156, REQ-ACCESS-160, SPEC-GOV-001, SPEC-GOV-002, SPEC-GOV-005, SPEC-GOV-007, SPEC-GOV-013, SPEC-GOV-015, Q-228, Q-245, Q-259, Q-262, Q-263
interface IAvanaTimelock is IAvanaTimelockEvents, IAvanaTimelockErrors, IAvanaTimelockGovernance, IAvanaTimelockViews {}
