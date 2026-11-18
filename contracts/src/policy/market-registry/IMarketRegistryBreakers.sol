// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IMarketRegistryBreakers
/// @notice Breaker state per market and per debt reserve: latched security freezes and last temporary breach.
/// @dev Gates only new activity; repay, debt-free exits and liquidation never read it.
interface IMarketRegistryBreakers {
    /// @notice Records the reasons a `pokeBreakers` call observed for one key.
    /// @dev RiskModule only. Latches security reasons and stamps temporary-gate breach times; never clears a latch.
    function recordBreach(
        bytes32 key,
        uint32 reasons
    ) external;

    /// @notice Latches a manual breaker on a market until reset.
    /// @dev `APPLICATION_FREEZE_GUARDIAN` or `APPLICATION_ADMIN`.
    function tripMarketBreaker(
        uint256 marketId
    ) external;

    /// @notice Latches a manual breaker on a debt reserve until reset.
    /// @dev Same roles as `tripMarketBreaker`. Reverts `UnknownDebtReserve` unless approved.
    function tripDebtBreaker(
        address spoke,
        uint256 debtReserveId
    ) external;

    /// @notice Clears a market's latched security freezes, `MANUAL` included.
    /// @dev `APPLICATION_PAUSE_GUARDIAN` or `APPLICATION_ADMIN`; reverts while a latched condition still holds.
    function resetMarketBreaker(
        uint256 marketId
    ) external;

    /// @notice Clears a debt reserve's latched security freezes, `MANUAL` included.
    /// @dev Same roles and errors as `resetMarketBreaker`.
    function resetDebtBreaker(
        address spoke,
        uint256 debtReserveId
    ) external;

    /// @notice A market's latched security freezes and last temporary-gate breach. Never reverts.
    /// @return latchedReasons Latched `BreakerReasons` bits, 0 when none.
    /// @return lastBreach Latest time `pokeBreakers` recorded a temporary gate breached, 0 if never.
    function marketBreaker(
        uint256 marketId
    ) external view returns (uint32 latchedReasons, uint64 lastBreach);

    /// @notice A debt reserve's latched security freezes and last temporary-gate breach. Never reverts.
    /// @return latchedReasons Latched `BreakerReasons` bits, 0 when none.
    /// @return lastBreach Latest time `pokeBreakers` recorded a temporary gate breached, 0 if never.
    function debtBreaker(
        address spoke,
        uint256 debtReserveId
    ) external view returns (uint32 latchedReasons, uint64 lastBreach);

    /// @notice Latest time `pokeBreakers` recorded a temporary gate breached for `key`, 0 if never. Never reverts.
    /// @dev With a per-reason key (`BreakerReasons.breachKey`), the latest breach of that reason alone.
    /// @return at Block timestamp, seconds.
    function lastBreachAt(
        bytes32 key
    ) external view returns (uint64 at);

    /// @notice Number of the Spoke's markets that are Active or Offboarding. Never reverts; 0 for an unknown Spoke.
    function activeMarketCount(
        address spoke
    ) external view returns (uint256 count);
}
