// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStoreAdmin} from "./IParameterStoreAdmin.sol";
import {IParameterStoreBreakers} from "./IParameterStoreBreakers.sol";
import {IParameterStoreChain} from "./IParameterStoreChain.sol";
import {IParameterStoreCoverage} from "./IParameterStoreCoverage.sol";
import {IParameterStoreErrors} from "./IParameterStoreErrors.sol";
import {IParameterStoreEvents} from "./IParameterStoreEvents.sol";
import {IParameterStoreLiquidation} from "./IParameterStoreLiquidation.sol";
import {IParameterStoreListing} from "./IParameterStoreListing.sol";
import {IParameterStoreLoosen} from "./IParameterStoreLoosen.sol";
import {IParameterStoreRiskViews} from "./IParameterStoreRiskViews.sol";
import {IParameterStoreSpeed} from "./IParameterStoreSpeed.sol";
import {IParameterStoreTighten} from "./IParameterStoreTighten.sol";
import {IParameterStoreViews} from "./IParameterStoreViews.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title IParameterStore
/// @notice Every Avana risk parameter of one chain, with its hard bounds, liveness bounds and change direction.
/// @dev UUPS proxy; only the timelock can upgrade it. Holds no funds.
interface IParameterStore is
    IAccessControl,
    IParameterStoreEvents,
    IParameterStoreErrors,
    IParameterStoreTighten,
    IParameterStoreLoosen,
    IParameterStoreAdmin,
    IParameterStoreListing,
    IParameterStoreViews,
    IParameterStoreRiskViews,
    IParameterStoreBreakers,
    IParameterStoreLiquidation,
    IParameterStoreChain,
    IParameterStoreCoverage,
    IParameterStoreSpeed
{}
