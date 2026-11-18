// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAvanaTimelockErrors} from "./IAvanaTimelockErrors.sol";
import {IAvanaTimelockEvents} from "./IAvanaTimelockEvents.sol";
import {IAvanaTimelockGovernance} from "./IAvanaTimelockGovernance.sol";
import {IAvanaTimelockViews} from "./IAvanaTimelockViews.sol";

/// @title IAvanaTimelock
/// @notice Executor of every privileged change to Avana: a non-upgradeable OpenZeppelin `TimelockController` with
/// two delays, a grace window, public execution and DAO-only cancels of role-change and restoring operations.
/// @dev Holds `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` on every upgradeable Avana contract.
interface IAvanaTimelock is IAvanaTimelockEvents, IAvanaTimelockErrors, IAvanaTimelockGovernance, IAvanaTimelockViews {}
