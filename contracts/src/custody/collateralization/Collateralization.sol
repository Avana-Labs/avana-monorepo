// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CollateralizationBase} from "./CollateralizationBase.sol";
import {CollateralizationDebtMark} from "./CollateralizationDebtMark.sol";
import {CollateralizationPending} from "./CollateralizationPending.sol";
import {CollateralizationPledge} from "./CollateralizationPledge.sol";
import {CollateralizationRelease} from "./CollateralizationRelease.sol";
import {CollateralizationSeizure} from "./CollateralizationSeizure.sol";
import {CollateralizationViews} from "./CollateralizationViews.sol";
import {ICollateralization} from "./ICollateralization.sol";

/// @title Collateralization
/// @notice AMM-neutral backing ledger: records, seizure lists, credited totals and USD exposure counters.
contract Collateralization is
    CollateralizationPledge,
    CollateralizationRelease,
    CollateralizationSeizure,
    CollateralizationPending,
    CollateralizationDebtMark,
    CollateralizationViews,
    ICollateralization
{
    constructor(
        address adapter,
        address lpVaultSwap,
        address riskModule,
        address lock,
        address vaultTokenFactory
    ) CollateralizationBase(adapter, lpVaultSwap, riskModule, lock, vaultTokenFactory) {}
}
