// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ICollateralizationErrors
/// @notice Errors of Collateralization.
/// @dev Position errors are raised by the market's LPVault and propagate unchanged.
interface ICollateralizationErrors {
    error NotAdapter();

    error NotLPVaultSwap();

    /// @notice An inner entry point was called while the lock is not held by its named caller.
    error LockNotHeld();

    /// @notice The vault token is unregistered, bound to other protocol contracts, or not the record's market.
    error InvalidVaultToken();

    error UnknownProxy(address proxy);

    error TooManyRecords(uint256 openRecords);

    error LengthMismatch(uint256 expected, uint256 actual);

    error BelowMinimum(uint256 index, uint256 received, uint256 minimum);

    error AlreadyPledged();

    /// @notice A position's units exceed `type(uint120).max`.
    error LiquidityAboveBound();

    /// @notice The RiskModule's charge is zero, out of bounds or inconsistent with the units credited.
    error InvalidCharge();

    error RecordNotFound();

    error NotRecordProxy();

    /// @notice The units are 0 or do not fit the record's credited units.
    error UnitsMismatch();

    error NotDepositor();

    error RecordHasCredit();

    error SharesNotEqualAssets();

    error SeizureActive();

    /// @notice No active snapshot matches the `proxy` and `vaultToken` of `settleSeizure`.
    error SeizureMismatch();

    /// @notice The proxy's supplied-share drop does not cover the seized units, or is nonzero with no units seized.
    error DebitMismatch();

    /// @notice The vault token's supply check failed in `settleSeizure` or `settlePending`.
    /// @param expected The supply drop or the largest supply the check admits.
    error SupplyDropMismatch(uint256 expected, uint256 actual);

    /// @notice Seized units exceed the account-market's credited units left after reconciliation.
    error InsufficientCredit();

    /// @notice `settlePending` was called with `units == 0` or `units > pending[vaultToken].units`.
    error PendingExceeded();

    error Locked();

    /// @notice `pledge` named the zero address, the market's LPVault or Collateralization as depositor.
    error InvalidDepositor(address depositor);

    /// @notice Too little gas left for a call whose failure must not come from the caller's gas limit.
    /// @param required `DEBT_MARK_GAS_FLOOR` or `SPEED_CREDIT_FLOOR`.
    error InsufficientGas(uint256 gasLeft, uint256 required);

    /// @notice `releasePartial` asked for at least the record's credited units; use a full withdrawal instead.
    error PartialRemovalTooLarge(uint128 units, uint128 credited);

    /// @notice `recredit` found a record at 0 credited units or no live units above its credited units.
    error NothingToRecredit(bytes32 positionKey);

    /// @notice `pledge` named a proxy bound to another market by its first pledge.
    error ProxyMarketMismatch(address proxy);

    /// @notice After custody the LPVault reported the position under a market other than the vault token's.
    error ShapeMismatch();

    error ZeroUnits();
}
