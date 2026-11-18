// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveAdapterAdmin} from "./IAaveAdapterAdmin.sol";
import {IAaveAdapterCollateral} from "./IAaveAdapterCollateral.sol";
import {IAaveAdapterErrors} from "./IAaveAdapterErrors.sol";
import {IAaveAdapterEvents} from "./IAaveAdapterEvents.sol";
import {IAaveAdapterSettlement} from "./IAaveAdapterSettlement.sol";
import {IAaveAdapterUser} from "./IAaveAdapterUser.sol";
import {IAaveAdapterViews} from "./IAaveAdapterViews.sol";

/// @title IAaveAdapter
/// @notice The chain's single entry point for every borrower action on every CDP Spoke.
/// @dev UUPS proxy; only the timelock can upgrade it. Holds no tokens between calls.
interface IAaveAdapter is
    IAaveAdapterEvents,
    IAaveAdapterErrors,
    IAaveAdapterUser,
    IAaveAdapterCollateral,
    IAaveAdapterSettlement,
    IAaveAdapterAdmin,
    IAaveAdapterViews
{}
