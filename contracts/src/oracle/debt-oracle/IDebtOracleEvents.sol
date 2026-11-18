// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "../../types/PriceState.sol";
import {RouteSlot} from "../../types/RouteSlot.sol";

/// @title IDebtOracleEvents
/// @notice Events of the DebtOracle.
interface IDebtOracleEvents {
    /// @notice Emitted when `initialize` stores the first accepted price.
    event DebtPriceSeeded(uint256 price8, uint64 updatedAt);

    /// @notice Emitted when `poke()` stores a new accepted price.
    event DebtPriceAccepted(uint256 price8, uint64 updatedAt, RouteSlot source);

    /// @notice Emitted when `poke()` observes a state different from the last writing call.
    event DebtPriceStateChanged(PriceState previous, PriceState current, uint256 reasons);

    /// @notice Emitted when `poke()` observes the route used change.
    event DebtRouteChanged(RouteSlot previous, RouteSlot current);

    /// @notice Emitted when `poke()` sets `failedSince`.
    event DebtFailureRecorded(uint64 failedSince, uint256 reasons);

    /// @notice Emitted when `poke()` clears `failedSince`.
    event DebtFailureCleared(uint64 failedSince, uint64 clearedAt);

    /// @notice Emitted when `poke()` sets `disagreeSince`.
    event DebtDisagreementRecorded(uint64 since, uint256 primary, uint256 alternate);

    /// @notice Emitted when `poke()` clears `disagreeSince`.
    event DebtDisagreementCleared(uint64 since, uint64 clearedAt);

    /// @notice Emitted when `poke()` sets `expiredLatched` from source timestamps.
    /// @param staleAt First second both routes were stale.
    event DebtOutageExpiredLatched(uint64 staleAt, uint64 observedAt);

    /// @notice Emitted when `poke()` starts a grace window.
    /// @param fromLatch True when started by `expiredLatched`, false when started by recovery evidence.
    event DebtGraceStarted(uint64 recoveredAt, uint64 graceEndsAt, bool fromLatch);

    /// @notice Emitted when `poke()` observes the asset's route version change.
    event DebtRouteVersionObserved(uint64 previous, uint64 current);

    /// @notice Emitted when `setPokeMinGas` succeeds.
    event PokeMinGasUpdated(uint32 previous, uint32 current);
}
