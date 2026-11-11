// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IDebtOracleErrors
/// @notice Errors of the DebtOracle: insufficient gas, the asset and Live checks at initialization, the poke gas bounds
/// and the admin-role grant rule.
interface IDebtOracleErrors {
    /// @notice Less gas than `pokeMinGas` was left at `poke()` entry or after a caught failure.
    /// @param gasLeft `gasleft()` at the check.
    /// @param required `pokeMinGas`.
    /// @custom:spec REQ-ORACLE-092, REQ-ORACLE-024, REQ-ORACLE-039
    error InsufficientGas(uint256 gasLeft, uint256 required);

    /// @notice The evaluation at `initialize` is not Live.
    /// @param state Price state as uint8.
    /// @param reasons Reason bitmap.
    /// @custom:spec REQ-ORACLE-091
    error NotLive(uint8 state, uint256 reasons);

    /// @notice At `initialize`, the asset is not a listed MarketRegistry token, has a fixed Aave source, or has no primary and alternate
    /// route in force.
    /// @param asset Rejected asset.
    /// @custom:spec REQ-ORACLE-091
    error NotDebtAsset(address asset);

    /// @notice `initialize` or `setPokeMinGas` value outside `[POKE_MIN_GAS_FLOOR, POKE_MIN_GAS_CEILING]`.
    /// @param value Rejected value.
    /// @custom:spec REQ-ORACLE-098, REQ-ORACLE-091
    error PokeMinGasOutOfBounds(uint32 value);

    /// @notice A grant of `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN` to an account other than `TIMELOCK`.
    /// @param role Role being granted.
    /// @param account Rejected account.
    /// @custom:spec REQ-ORACLE-097, Q-259
    error AdminRoleOnlyTimelock(bytes32 role, address account);
}
