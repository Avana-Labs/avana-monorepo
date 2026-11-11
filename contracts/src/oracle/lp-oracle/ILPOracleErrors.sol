// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILPOracleErrors
/// @notice Errors of the LPOracle: insufficient gas, configuration checks, the Live check at initialization, the
/// poke gas bounds and the admin-role grant rule.
/// @custom:spec REQ-ORACLE-076
interface ILPOracleErrors {
    /// @notice Less gas than `pokeMinGas` was left at `poke()` entry or after a caught failure.
    /// @param gasLeft `gasleft()` at the check.
    /// @param required `pokeMinGas`.
    /// @custom:spec REQ-ORACLE-024, REQ-ORACLE-039, REQ-ORACLE-074
    error InsufficientGas(uint256 gasLeft, uint256 required);

    /// @notice `checkConfig` returned a non-zero bitmap at `initialize`.
    /// @param failedChecks Bitmap of failed checks.
    /// @custom:spec REQ-ORACLE-058, REQ-ORACLE-076
    error ConfigCheckFailed(uint256 failedChecks);

    /// @notice The evaluation at `initialize` is not Live.
    /// @param state Price state as uint8.
    /// @param reasons Reason bitmap.
    /// @custom:spec REQ-ORACLE-059, REQ-ORACLE-076
    error NotLive(uint8 state, uint256 reasons);

    /// @notice `setPokeMinGas` value outside `[POKE_MIN_GAS_FLOOR, POKE_MIN_GAS_CEILING]`.
    /// @param value Rejected value.
    /// @custom:spec REQ-ORACLE-038
    error PokeMinGasOutOfBounds(uint32 value);

    /// @notice The market passed to `initialize` is malformed: a zero market identifier or one that differs from the
    /// configuration's, a token count outside `[2, MAX_POOL_TOKENS]` or different from the stable flags', a zero or
    /// repeated token, a token whose `decimals()` cannot be read, a zero store, registry or integration, or a pool and
    /// shape the pricing module refuses.
    /// @param marketId The market.
    /// @custom:spec REQ-ORACLE-010, Q-370
    error MarketMismatch(uint256 marketId);

    /// @notice A grant of `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN` to an account other than `TIMELOCK`.
    /// @param role Role being granted.
    /// @param account Rejected account.
    /// @custom:spec REQ-ORACLE-097, REQ-ORACLE-058, Q-259
    error AdminRoleOnlyTimelock(bytes32 role, address account);

    /// @notice A logic contract's writing or listing entry point was called other than by delegatecall from the feed's
    /// proxy.
    /// @custom:spec REQ-ORACLE-062, REQ-ORACLE-080
    error NotDelegated();
}
