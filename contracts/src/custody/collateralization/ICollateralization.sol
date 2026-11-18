// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationAdapter} from "./ICollateralizationAdapter.sol";
import {ICollateralizationDebtMark} from "./ICollateralizationDebtMark.sol";
import {ICollateralizationErrors} from "./ICollateralizationErrors.sol";
import {ICollateralizationEvents} from "./ICollateralizationEvents.sol";
import {ICollateralizationSeizure} from "./ICollateralizationSeizure.sol";
import {ICollateralizationUser} from "./ICollateralizationUser.sol";
import {ICollateralizationViews} from "./ICollateralizationViews.sol";

/// @title ICollateralization
/// @notice The chain's AMM-neutral backing ledger for vault-token collateral.
/// @dev Not upgradeable, no owner. Value-moving functions are reachable only from the AaveAdapter and LPVaultSwap.
interface ICollateralization is
    ICollateralizationEvents,
    ICollateralizationErrors,
    ICollateralizationAdapter,
    ICollateralizationUser,
    ICollateralizationSeizure,
    ICollateralizationDebtMark,
    ICollateralizationViews
{}
