// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PauseReason} from "../../types/PauseReason.sol";
import {RouteSlot} from "../../types/RouteSlot.sol";
import {BreakerScope} from "./types/Breaker.sol";

/// @title IMarketRegistrySafetyEvents
/// @notice Events of the pause reason, the address freeze, the circuit breakers, and the standby switch.
interface IMarketRegistrySafetyEvents {
    event PauseReasonChanged(address indexed hub, PauseReason previous, PauseReason current, address indexed caller);

    event AddressFrozen(address indexed account, address indexed caller);

    event AddressUnfrozen(address indexed account);

    /// @notice A security freeze latched by `recordBreach` or a manual trip.
    /// @param reasons Latched reason bits after the call.
    event BreakerLatched(BreakerScope indexed scope, bytes32 indexed key, uint32 reasons);

    /// @notice `recordBreach` saw a temporary gate (`ORACLE`, `POOL_SHARE`, `POOL_DEPTH`) breached.
    /// @param at New `lastBreachAt(key)`, seconds.
    event GateBreached(bytes32 indexed key, uint32 reasons, uint64 at);

    event BreakerReset(BreakerScope indexed scope, bytes32 indexed key, address indexed caller);

    /// @notice A token's standby route replaced one of its routes.
    event StandbyRouteActivated(address indexed token, RouteSlot slot, address indexed caller);

    /// @notice The Aave governance executor undid a standby switch.
    event StandbySwitchCancelled(address indexed token, address indexed caller);

    /// @notice The replaced slot returned to its recorded route.
    event PriceRouteRestored(address indexed token);
}
