// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "../../types/PriceState.sol";
import {RouteSlot} from "../../types/RouteSlot.sol";

/// @title IDebtOracleEvents
/// @notice Events of the DebtOracle: seeded and accepted prices, state and route changes, failures, route
/// disagreements, the outage latch, recovery grace, route-version changes and the poke gas setting.
interface IDebtOracleEvents {
    /// @notice Emitted when `initialize` stores the first accepted price.
    /// @param price8 Seeded price, 8 decimals.
    /// @param updatedAt Source timestamp of the seeded price.
    /// @custom:spec REQ-ORACLE-091
    event DebtPriceSeeded(uint256 price8, uint64 updatedAt);

    /// @notice Emitted when `poke()` stores a new accepted price (Live and newer than the stored one).
    /// @param price8 Accepted price, 8 decimals.
    /// @param updatedAt Source timestamp of the route used.
    /// @param source Route used: Primary or Alternate.
    /// @custom:spec REQ-ORACLE-092, REQ-ORACLE-029
    event DebtPriceAccepted(uint256 price8, uint64 updatedAt, RouteSlot source);

    /// @notice Emitted when `poke()` observes a state different from the last writing call.
    /// @param previous State at the last writing call.
    /// @param current State now.
    /// @param reasons Reason bitmap now.
    /// @custom:spec REQ-ORACLE-092, REQ-ORACLE-035
    event DebtPriceStateChanged(PriceState previous, PriceState current, uint256 reasons);

    /// @notice Emitted when `poke()` observes the route used change.
    /// @param previous Route used at the last writing call (None, Primary, Alternate).
    /// @param current Route used now.
    /// @custom:spec REQ-ORACLE-092, REQ-ORACLE-035
    event DebtRouteChanged(RouteSlot previous, RouteSlot current);

    /// @notice Emitted when `poke()` sets `failedSince`.
    /// @param failedSince First failed read of the episode.
    /// @param reasons Reason bitmap.
    /// @custom:spec REQ-ORACLE-092, REQ-ORACLE-027
    event DebtFailureRecorded(uint64 failedSince, uint256 reasons);

    /// @notice Emitted when `poke()` resets a non-zero `failedSince` to 0.
    /// @param failedSince Previous value.
    /// @param clearedAt Block timestamp.
    /// @custom:spec REQ-ORACLE-092, REQ-ORACLE-027
    event DebtFailureCleared(uint64 failedSince, uint64 clearedAt);

    /// @notice Emitted when `poke()` sets `disagreeSince`.
    /// @param since Block timestamp of the first stored observation.
    /// @param primary Primary route value, 8 decimals.
    /// @param alternate Alternate route value, 8 decimals.
    /// @custom:spec REQ-ORACLE-092, REQ-ORACLE-028
    event DebtDisagreementRecorded(uint64 since, uint256 primary, uint256 alternate);

    /// @notice Emitted when `poke()` resets a non-zero `disagreeSince` to 0.
    /// @param since Previous value.
    /// @param clearedAt Block timestamp.
    /// @custom:spec REQ-ORACLE-092, REQ-ORACLE-028
    event DebtDisagreementCleared(uint64 since, uint64 clearedAt);

    /// @notice Emitted when `poke()` sets `expiredLatched` from source timestamps.
    /// @param staleAt First second both routes were stale.
    /// @param observedAt Block timestamp.
    /// @custom:spec REQ-ORACLE-092, REQ-ORACLE-030
    event DebtOutageExpiredLatched(uint64 staleAt, uint64 observedAt);

    /// @notice Emitted when `poke()` starts a grace window.
    /// @param recoveredAt Source timestamp of the first fresh update after the outage.
    /// @param graceEndsAt recoveredAt + graceDuration.
    /// @param fromLatch True when started by `expiredLatched`, false when started by recovery evidence.
    /// @custom:spec REQ-ORACLE-092, REQ-ORACLE-032, REQ-ORACLE-089
    event DebtGraceStarted(uint64 recoveredAt, uint64 graceEndsAt, bool fromLatch);

    /// @notice Emitted when `poke()` observes `MarketRegistry.priceRouteVersion(asset)` differ from the stored one.
    /// @param previous Version stored at the last writing call.
    /// @param current Version now.
    /// @custom:spec REQ-ORACLE-095, Q-248
    event DebtRouteVersionObserved(uint64 previous, uint64 current);

    /// @notice Emitted when `setPokeMinGas` succeeds.
    /// @param previous Previous value.
    /// @param current New value.
    /// @custom:spec REQ-ORACLE-098
    event PokeMinGasUpdated(uint32 previous, uint32 current);
}
