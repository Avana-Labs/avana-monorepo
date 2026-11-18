// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILPOracleErrors
/// @notice Errors of the LPOracle.
interface ILPOracleErrors {
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
}
