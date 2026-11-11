// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PauseReason} from "../../types/PauseReason.sol";
import {RouteSlot} from "../../types/RouteSlot.sol";
import {BreakerScope} from "./types/Breaker.sol";

/// @title IMarketRegistrySafetyEvents
/// @notice Events of the pause reason, the address freeze, the circuit breakers, and the standby switch.
interface IMarketRegistrySafetyEvents {
    /// @notice The pause reason changed.
    /// @param hub The Hub.
    /// @param previous Reason before the call.
    /// @param current Reason after the call.
    /// @param caller Guardian or the timelock.
    /// @custom:spec REQ-MREG-024
    event PauseReasonChanged(address indexed hub, PauseReason previous, PauseReason current, address indexed caller);

    /// @notice An address was frozen.
    /// @param account Frozen address.
    /// @param caller Guardian or the timelock.
    /// @custom:spec REQ-MREG-019
    event AddressFrozen(address indexed account, address indexed caller);

    /// @notice An address was unfrozen.
    /// @param account Unfrozen address.
    /// @custom:spec REQ-MREG-022
    event AddressUnfrozen(address indexed account);

    /// @notice A security freeze latched by `recordBreach` or a manual trip.
    /// @param scope Market or debt reserve.
    /// @param key Breaker key.
    /// @param reasons Latched reason bits after the call.
    /// @custom:spec REQ-MREG-025, REQ-MREG-026, SPEC-BRK-008, Q-399
    event BreakerLatched(BreakerScope indexed scope, bytes32 indexed key, uint32 reasons);

    /// @notice `recordBreach` saw a temporary gate (`ORACLE`, `POOL_SHARE`, `POOL_DEPTH`) breached.
    /// @param key Breaker key.
    /// @param reasons Temporary reason bits observed.
    /// @param at New `lastBreachAt(key)`, seconds.
    /// @custom:spec REQ-MREG-026, SPEC-BRK-007, Q-399
    event GateBreached(bytes32 indexed key, uint32 reasons, uint64 at);

    /// @notice A breaker was reset.
    /// @param scope Market or debt reserve.
    /// @param key Breaker key.
    /// @param caller Guardian or the timelock.
    /// @custom:spec REQ-MREG-025
    event BreakerReset(BreakerScope indexed scope, bytes32 indexed key, address indexed caller);

    /// @notice A token's standby route replaced one of its routes.
    /// @param token The token.
    /// @param slot Replaced slot.
    /// @param caller Guardian or the timelock.
    /// @custom:spec REQ-MREG-028
    event StandbyRouteActivated(address indexed token, RouteSlot slot, address indexed caller);

    /// @notice The Aave governance executor undid a standby switch.
    /// @param token The token.
    /// @param caller The Aave governance executor.
    /// @custom:spec REQ-MREG-028
    event StandbySwitchCancelled(address indexed token, address indexed caller);

    /// @notice The replaced slot returned to its recorded route.
    /// @param token The token.
    /// @custom:spec REQ-MREG-028
    event PriceRouteRestored(address indexed token);
}
