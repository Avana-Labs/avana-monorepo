// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IDebtOracleErrors
/// @notice Errors of the DebtOracle.
interface IDebtOracleErrors {
    /// @notice Less gas than required was left at `poke()` entry or before an external read.
    error InsufficientGas(uint256 gasLeft, uint256 required);

    /// @notice The evaluation at `initialize` is not Live.
    error NotLive(uint8 state, uint256 reasons);

    /// @notice At `initialize`, the asset is not listed or has no readable routes in force.
    error NotDebtAsset(address asset);

    /// @notice `pokeMinGas` value outside `[POKE_MIN_GAS_FLOOR, POKE_MIN_GAS_CEILING]`.
    error PokeMinGasOutOfBounds(uint32 value);

    /// @notice A grant of `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN` to an account other than `TIMELOCK`.
    error AdminRoleOnlyTimelock(bytes32 role, address account);
}
