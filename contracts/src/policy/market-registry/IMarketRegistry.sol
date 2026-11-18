// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryApprovals} from "./IMarketRegistryApprovals.sol";
import {IMarketRegistryBreakers} from "./IMarketRegistryBreakers.sol";
import {IMarketRegistryCreditLines} from "./IMarketRegistryCreditLines.sol";
import {IMarketRegistryErrors} from "./IMarketRegistryErrors.sol";
import {IMarketRegistryEvents} from "./IMarketRegistryEvents.sol";
import {IMarketRegistryFreeze} from "./IMarketRegistryFreeze.sol";
import {IMarketRegistryHubs} from "./IMarketRegistryHubs.sol";
import {IMarketRegistryListing} from "./IMarketRegistryListing.sol";
import {IMarketRegistryPause} from "./IMarketRegistryPause.sol";
import {IMarketRegistryRouteViews} from "./IMarketRegistryRouteViews.sol";
import {IMarketRegistryRoutes} from "./IMarketRegistryRoutes.sol";
import {IMarketRegistrySafetyEvents} from "./IMarketRegistrySafetyEvents.sol";
import {IMarketRegistryStandby} from "./IMarketRegistryStandby.sol";
import {IMarketRegistryViews} from "./IMarketRegistryViews.sol";
import {IMarketRegistryWindDown} from "./IMarketRegistryWindDown.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title IMarketRegistry
/// @notice The chain's registry of Hubs, integrations, CDP Spokes, debt reserves, markets, routes and safety state.
/// @dev UUPS proxy; only the timelock can upgrade it. Holds no funds and stores no risk parameter.
interface IMarketRegistry is
    IAccessControl,
    IMarketRegistryEvents,
    IMarketRegistrySafetyEvents,
    IMarketRegistryErrors,
    IMarketRegistryListing,
    IMarketRegistryHubs,
    IMarketRegistryRoutes,
    IMarketRegistryPause,
    IMarketRegistryFreeze,
    IMarketRegistryBreakers,
    IMarketRegistryStandby,
    IMarketRegistryCreditLines,
    IMarketRegistryWindDown,
    IMarketRegistryApprovals,
    IMarketRegistryViews,
    IMarketRegistryRouteViews
{}
