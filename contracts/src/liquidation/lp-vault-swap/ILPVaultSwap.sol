// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IFlashReceiver} from "../../flash/IFlashReceiver.sol";
import {ILPVaultSwapAdmin} from "./ILPVaultSwapAdmin.sol";
import {ILPVaultSwapDeleverage} from "./ILPVaultSwapDeleverage.sol";
import {ILPVaultSwapErrors} from "./ILPVaultSwapErrors.sol";
import {ILPVaultSwapEvents} from "./ILPVaultSwapEvents.sol";
import {ILPVaultSwapLiquidation} from "./ILPVaultSwapLiquidation.sol";
import {ILPVaultSwapViews} from "./ILPVaultSwapViews.sol";

/// @title ILPVaultSwap
/// @notice The chain's liquidator: seizes vault-token collateral through Aave and settles it in the debt asset.
/// @dev UUPS proxy; only the timelock can upgrade it. Never reads the pause state or circuit breakers.
interface ILPVaultSwap is
    ILPVaultSwapEvents,
    ILPVaultSwapErrors,
    ILPVaultSwapLiquidation,
    ILPVaultSwapAdmin,
    ILPVaultSwapViews,
    ILPVaultSwapDeleverage,
    IFlashReceiver
{}
