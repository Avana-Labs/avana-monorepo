// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PegModuleKind} from "./types/SettlementRouteTypes.sol";

/// @title IPegModuleRoute
/// @notice The view a `PegModule` swap route adds to `ISettlementRoute`: which peg module it calls.
interface IPegModuleRoute {
    /// @notice The kind of peg module the route calls and its address, both fixed at deployment.
    function pegModule() external view returns (PegModuleKind kind, address module);
}
