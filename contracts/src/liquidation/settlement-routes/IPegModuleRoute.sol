// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PegModuleKind} from "./types/PegModuleStep.sol";

/// @title IPegModuleRoute
/// @notice The view a `PegModule` swap route (`routeType() == 0`) adds to `ISettlementRoute`: which peg module it calls.
/// @dev Read by the MarketRegistry in `setRoute` and `restoreRoute` (2.12 REQ-ROUTE-002, REQ-ROUTE-005): a route whose
/// module is a GSM is admitted only in the backup slot and only while the GSM is neither seized nor frozen and its
/// exposure cap is above 0 (Q-341); a LitePSM route is admitted in either slot.
/// @custom:spec REQ-ROUTE-002, REQ-ROUTE-005, Q-341
interface IPegModuleRoute {
    /// @notice The kind of peg module the route calls and its address, both fixed at deployment.
    /// @return kind `Gsm` (a GHO Stability Module) or `LitePsm` (the Sky LitePSM).
    /// @return module The GSM or the LitePSM; also the last entry of `dependencies()`.
    /// @custom:spec REQ-ROUTE-002, REQ-ROUTE-005, Q-341
    function pegModule() external view returns (PegModuleKind kind, address module);
}
