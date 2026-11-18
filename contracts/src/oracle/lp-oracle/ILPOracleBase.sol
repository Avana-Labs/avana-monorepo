// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "../../types/OracleTypes.sol";

/// @title ILPOracleBase
/// @notice Errors and events of LPOracle, shared with its contracts.
interface ILPOracleBase {
    /// @notice Less gas than required was left at `poke()` entry or before an external read.
    error InsufficientGas(uint256 gasLeft, uint256 required);

    /// @notice `checkConfig` returned a non-zero bitmap at `initialize`.
    error ConfigCheckFailed(uint256 failedChecks);

    /// @notice The evaluation at `initialize` is not Live.
    error NotLive(uint8 state, uint256 reasons);

    /// @notice `pokeMinGas` value outside `[POKE_MIN_GAS_FLOOR, POKE_MIN_GAS_CEILING]`.
    error PokeMinGasOutOfBounds(uint32 value);

    /// @notice The market passed to `initialize`, or a constructor argument, is malformed.
    error MarketMismatch(uint256 marketId);

    /// @notice A grant of `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN` to an account other than `TIMELOCK`.
    error AdminRoleOnlyTimelock(bytes32 role, address account);

    /// @notice A logic contract entry point was called other than by delegatecall from the feed's proxy.
    error NotDelegated();

    /// @notice Emitted when `initialize` stores the first accepted price.
    /// @param updatedAt Oldest-input source timestamp.
    /// @param prices Valuation price of each token, 8 decimals.
    event PriceSeeded(int256 answer, uint64 updatedAt, uint256[] prices);

    /// @notice Emitted when `poke()` stores a new accepted price.
    /// @param updatedAt Oldest-input source timestamp.
    /// @param prices Valuation price of each token, 8 decimals.
    event PriceAccepted(int256 answer, uint64 updatedAt, uint256[] prices);

    /// @notice Emitted when `poke()` observes a state different from the last writing call.
    event PriceStateChanged(PriceState previous, PriceState current, uint256 reasons, uint64 servedUpdatedAt);

    /// @notice Emitted when `poke()` observes a token's route in use change.
    /// @param token Token index in pool order.
    /// @param previousRoute 0 None, 1 Primary, 2 Alternate.
    /// @param currentRoute 0 None, 1 Primary, 2 Alternate.
    event RouteChanged(uint8 token, uint8 previousRoute, uint8 currentRoute);

    /// @notice Emitted when `poke()` sets `failedSince`.
    event FailureRecorded(uint64 failedSince, uint256 reasons);

    /// @notice Emitted when `poke()` clears `failedSince`.
    event FailureCleared(uint64 failedSince, uint64 clearedAt);

    /// @notice Emitted when `poke()` sets `disagreeSince`.
    /// @param primary Primary route value of each token, 8 decimals.
    /// @param alternate Alternate route value of each token, 8 decimals.
    event DisagreementRecorded(uint64 since, uint256[] primary, uint256[] alternate);

    /// @notice Emitted when `poke()` clears `disagreeSince`.
    event DisagreementCleared(uint64 since, uint64 clearedAt);

    /// @notice Emitted when `poke()` sets `expiredLatched` from source timestamps.
    /// @param token Token index in pool order.
    /// @param staleAt First second both routes of the token were stale.
    event OutageExpiredLatched(uint8 token, uint64 staleAt, uint64 observedAt);

    /// @notice Emitted when `poke()` starts a grace window.
    /// @param recoveredAt Source timestamp of the first fresh update after the outage.
    /// @param fromLatch True when started by `expiredLatched`, false when started by recovery evidence.
    event GraceStarted(uint64 recoveredAt, uint64 graceEndsAt, bool fromLatch);

    /// @notice Emitted when `poke()` refuses a fair price that moved too far from the accepted price in one block.
    event QuoteChangeCapped(int256 accepted, int256 quoted);

    /// @notice Emitted when `setPokeMinGas` succeeds.
    event PokeMinGasUpdated(uint32 previous, uint32 current);

    /// @notice Emitted when `initialize` seeds or `poke()` moves the hourly checkpoint.
    event PriceCheckpointed(uint256 price8, uint64 at);

    /// @notice Emitted when `poke()` first finds a token's `decimals()` unreadable or changed.
    /// @param token Token index in pool order.
    /// @param read Decimals read (0 when unreadable).
    event TokenDecimalsMismatch(uint8 token, uint8 stored, uint8 read, bool readable);

    /// @notice Emitted when `poke()` reads every token's stored decimals again after a mismatch.
    event TokenDecimalsRestored(uint64 verifiedAt);

    /// @notice Emitted when `poke()` observes a token's route version change.
    /// @param token Token index in pool order.
    event PriceRouteVersionObserved(uint8 token, uint64 previous, uint64 current);
}
