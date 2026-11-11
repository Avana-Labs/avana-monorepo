// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IMarketRegistryBreakers
/// @notice Breaker state per market and per (CDP Spoke, debt reserve): the latched security freezes and the time of
/// the last temporary-gate breach (Q-399).
/// @dev Keys: `bytes32(marketId)` for a market, `keccak256(abi.encode(spoke, debtReserveId))` for a debt reserve.
/// Temporary gates (`ORACLE`, `POOL_SHARE`, `POOL_DEPTH`) reopen `gateRecoverySeconds` after their last recorded breach
/// once the condition is gone (SPEC-BRK-007). Security freezes (`ISSUER`, `CONFIG_DRIFT`, `DEFICIT`, `MANUAL`) stay
/// latched until an authorized reset (SPEC-BRK-008). Only the RiskModule's permissionless `pokeBreakers` (through
/// `recordBreach`) and the guardians' manual trips and resets write this state; LPVaultSwap writes none, so no breaker
/// write can revert or slow a liquidation. The RiskModule reads it for new activity only; repay, debt-free exits, fee
/// collection, zero-credit release, pending settlement, eligible liquidation, rescue top-ups and repay with
/// collateral never read it.
interface IMarketRegistryBreakers {
    /// @notice Records the reasons a `pokeBreakers` call observed for one key.
    /// @dev RiskModule only (`NotRiskModule`). ORs the security-freeze reasons of `reasons` (`DEFICIT`, `ISSUER`,
    /// `CONFIG_DRIFT`) into `latched[key]` and emits `BreakerLatched` when a new reason is added; sets
    /// `lastBreachAt[key] = block.timestamp` and emits `GateBreached` when `reasons` holds `ORACLE`, `POOL_SHARE` or
    /// `POOL_DEPTH`. Never clears a latch or shortens a recovery. Example: `reasons = POOL_SHARE` at `t = 1,000` sets
    /// `lastBreachAt = 1,000`; with `gateRecoverySeconds = 1,800` the gate reopens at 2,800 if the share stays below
    /// `poolShareMaxBpsOf(poolKey)` (default 10,000 bps (off); per-pool cap optional, Q-403) until then.
    /// @param key Breaker key.
    /// @param reasons `BreakerReasons` bits observed by the RiskModule.
    /// @custom:spec REQ-MREG-025, REQ-MREG-026, SPEC-BRK-005, SPEC-BRK-006, SPEC-BRK-007, SPEC-BRK-008, Q-399
    function recordBreach(
        bytes32 key,
        uint32 reasons
    ) external;

    /// @notice Latches a manual breaker on a market until reset.
    /// @dev `APPLICATION_FREEZE_GUARDIAN` (immediate) or `APPLICATION_ADMIN` (short delay), else `Unauthorized`.
    /// Reverts `UnknownMarket` for an unknown market. Adds `MANUAL` to `latched[key]` and emits
    /// `BreakerLatched`.
    /// @param marketId The market.
    /// @custom:spec REQ-MREG-025, Q-241, Q-262
    function tripMarketBreaker(
        uint256 marketId
    ) external;

    /// @notice Latches a manual breaker on a debt reserve until reset.
    /// @dev Same roles as `tripMarketBreaker`. Reverts `UnknownDebtReserve` unless approved.
    /// @param spoke CDP Spoke.
    /// @param debtReserveId Debt reserve.
    /// @custom:spec REQ-MREG-025, Q-241, Q-262
    function tripDebtBreaker(
        address spoke,
        uint256 debtReserveId
    ) external;

    /// @notice Clears a market's latched security freezes, `MANUAL` included.
    /// @dev `APPLICATION_PAUSE_GUARDIAN` (immediate) or `APPLICATION_ADMIN` (normal delay), else `Unauthorized`.
    /// Reverts `NothingToReset` unless a reason is latched and `ConditionStillHolds(key, reasons)` while a security
    /// condition still holds (the RiskModule's live evaluation). Leaves `lastBreachAt` unchanged: a temporary gate
    /// needs no reset. Emits `BreakerReset`.
    /// @param marketId The market.
    /// @custom:spec REQ-MREG-025, Q-241
    function resetMarketBreaker(
        uint256 marketId
    ) external;

    /// @notice Clears a debt reserve's latched security freezes, `MANUAL` included.
    /// @dev Same roles and errors as `resetMarketBreaker`.
    /// @param spoke CDP Spoke.
    /// @param debtReserveId Debt reserve.
    /// @custom:spec REQ-MREG-025, Q-241
    function resetDebtBreaker(
        address spoke,
        uint256 debtReserveId
    ) external;

    /// @notice A market's latched security freezes and last temporary-gate breach. Never reverts.
    /// @param marketId The market.
    /// @return latchedReasons Latched `BreakerReasons` bits, 0 when none.
    /// @return lastBreach Latest time `pokeBreakers` recorded a temporary gate breached, 0 if never.
    /// @custom:spec REQ-MREG-025, SPEC-BRK-007
    function marketBreaker(
        uint256 marketId
    ) external view returns (uint32 latchedReasons, uint64 lastBreach);

    /// @notice A debt reserve's latched security freezes and last temporary-gate breach. Never reverts.
    /// @param spoke CDP Spoke.
    /// @param debtReserveId Debt reserve.
    /// @return latchedReasons Latched `BreakerReasons` bits, 0 when none.
    /// @return lastBreach Latest time `pokeBreakers` recorded a temporary gate breached, 0 if never.
    /// @custom:spec REQ-MREG-025, SPEC-BRK-007
    function debtBreaker(
        address spoke,
        uint256 debtReserveId
    ) external view returns (uint32 latchedReasons, uint64 lastBreach);

    /// @notice Latest time `pokeBreakers` recorded a temporary gate breached for `key`, 0 if never. Never reverts.
    /// @param key Breaker key.
    /// @return at Block timestamp, seconds.
    /// @custom:spec REQ-MREG-025, SPEC-BRK-007, Q-399
    function lastBreachAt(
        bytes32 key
    ) external view returns (uint64 at);

    /// @notice Number of the Spoke's markets that are Active or Offboarding. Never reverts; 0 for an unknown Spoke.
    /// @dev Read by the Lens and monitoring.
    /// @param spoke CDP Spoke.
    /// @return count Market count.
    /// @custom:spec REQ-MREG-031, Q-267, Q-397
    function activeMarketCount(
        address spoke
    ) external view returns (uint256 count);
}
