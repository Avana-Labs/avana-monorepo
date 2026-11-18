// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleAdmin} from "./IRiskModuleAdmin.sol";
import {IRiskModuleChecks} from "./IRiskModuleChecks.sol";
import {IRiskModuleErrors} from "./IRiskModuleErrors.sol";
import {IRiskModuleViews} from "./IRiskModuleViews.sol";

/// @title IRiskModule
/// @notice Avana's risk checks on one chain: the pledge check and the borrow-side pre- and post-checks.
/// @dev UUPS proxy; only the timelock can upgrade it. Holds no funds and has no setter.
interface IRiskModule is IRiskModuleErrors, IRiskModuleChecks, IRiskModuleAdmin, IRiskModuleViews {}
