// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "../../types/PriceState.sol";

/// @title ILPOracleEvents
/// @notice Events of the LPOracle: seeded and accepted prices, price-state and route changes, failures, route
/// disagreements, the outage latch, recovery grace, the hourly checkpoint, route-version changes and the poke gas
/// setting. Price arrays are in the market's pool token order.
/// @custom:spec REQ-ORACLE-035, Q-370
interface ILPOracleEvents {
    /// @notice Emitted when `initialize` stores the first accepted price.
    /// @param answer Seeded price, 8 decimals.
    /// @param updatedAt Oldest-input source timestamp of the seeded price.
    /// @param prices Valuation price of each token in pool order, 8 decimals.
    /// @custom:spec REQ-ORACLE-059
    event PriceSeeded(int256 answer, uint64 updatedAt, uint256[] prices);

    /// @notice Emitted when `poke()` stores a new accepted price.
    /// @param answer Accepted price, 8 decimals.
    /// @param updatedAt Oldest-input source timestamp.
    /// @param prices Valuation price of each token in pool order, 8 decimals.
    /// @custom:spec REQ-ORACLE-029, REQ-ORACLE-035
    event PriceAccepted(int256 answer, uint64 updatedAt, uint256[] prices);

    /// @notice Emitted when `poke()` observes a state different from the last writing call.
    /// @param previous State at the last writing call.
    /// @param current State now.
    /// @param reasons Reason bitmap now.
    /// @param servedUpdatedAt Source timestamp of the served price.
    /// @custom:spec REQ-ORACLE-035, Q-076
    event PriceStateChanged(PriceState previous, PriceState current, uint256 reasons, uint64 servedUpdatedAt);

    /// @notice Emitted when `poke()` observes a token's route in use change.
    /// @param token Token index in pool order.
    /// @param previousRoute 0 None, 1 Primary, 2 Alternate.
    /// @param currentRoute 0 None, 1 Primary, 2 Alternate.
    /// @custom:spec REQ-ORACLE-035
    event RouteChanged(uint8 token, uint8 previousRoute, uint8 currentRoute);

    /// @notice Emitted when `poke()` sets `failedSince`.
    /// @param failedSince First failed read of the episode.
    /// @param reasons Reason bitmap.
    /// @custom:spec REQ-ORACLE-027
    event FailureRecorded(uint64 failedSince, uint256 reasons);

    /// @notice Emitted when `poke()` resets a non-zero `failedSince` to 0.
    /// @param failedSince Previous value.
    /// @param clearedAt Block timestamp.
    /// @custom:spec REQ-ORACLE-027
    event FailureCleared(uint64 failedSince, uint64 clearedAt);

    /// @notice Emitted when `poke()` sets `disagreeSince`.
    /// @param since Block timestamp of the first stored observation.
    /// @param primary Primary route value of each token in pool order, 8 decimals.
    /// @param alternate Alternate route value of each token in pool order, 8 decimals.
    /// @custom:spec REQ-ORACLE-028, Q-199
    event DisagreementRecorded(uint64 since, uint256[] primary, uint256[] alternate);

    /// @notice Emitted when `poke()` resets a non-zero `disagreeSince` to 0.
    /// @param since Previous value.
    /// @param clearedAt Block timestamp.
    /// @custom:spec REQ-ORACLE-028
    event DisagreementCleared(uint64 since, uint64 clearedAt);

    /// @notice Emitted when `poke()` sets `expiredLatched` from source timestamps.
    /// @param token Token index in pool order.
    /// @param staleAt First second both routes of the token were stale.
    /// @param observedAt Block timestamp.
    /// @custom:spec REQ-ORACLE-030
    event OutageExpiredLatched(uint8 token, uint64 staleAt, uint64 observedAt);

    /// @notice Emitted when `poke()` starts a grace window.
    /// @param recoveredAt Source timestamp of the first fresh update after the outage.
    /// @param graceEndsAt recoveredAt + graceDuration.
    /// @param fromLatch True when started by `expiredLatched`, false when started by SPEC-ORC-014 evidence.
    /// @custom:spec REQ-ORACLE-032, REQ-ORACLE-033
    event GraceStarted(uint64 recoveredAt, uint64 graceEndsAt, bool fromLatch);

    /// @notice Emitted when `poke()` refuses a fair price that moved more than `maxQuoteChangeBps` from the accepted
    /// price within one block.
    /// @param accepted Accepted price, 8 decimals.
    /// @param quoted Refused fair price, 8 decimals.
    /// @custom:spec REQ-ORACLE-103, Q-321
    event QuoteChangeCapped(int256 accepted, int256 quoted);

    /// @notice Emitted when `setPokeMinGas` succeeds.
    /// @param previous Previous value.
    /// @param current New value.
    /// @custom:spec REQ-ORACLE-038
    event PokeMinGasUpdated(uint32 previous, uint32 current);

    /// @notice Emitted when `initialize` seeds or `poke()` moves the hourly checkpoint.
    /// @param price8 Checkpointed accepted price, 8 decimals.
    /// @param at Block time of the copy.
    /// @custom:spec REQ-ORACLE-088, REQ-ORACLE-059, Q-241
    event PriceCheckpointed(uint256 price8, uint64 at);

    /// @notice Emitted when `poke()` observes a token's `MarketRegistry.priceRouteVersion` differ from the stored one.
    /// @param token Token index in pool order.
    /// @param previous Version stored at the last writing call.
    /// @param current Version now.
    /// @custom:spec REQ-ORACLE-095, REQ-ORACLE-035, Q-248
    event PriceRouteVersionObserved(uint8 token, uint64 previous, uint64 current);
}
