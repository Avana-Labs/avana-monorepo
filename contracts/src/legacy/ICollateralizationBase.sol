// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CounterKind} from "./CollateralizationTypes.sol";

/// @title ICollateralizationBase
/// @notice Errors and events of Collateralization, shared with its contracts.
interface ICollateralizationBase {
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

    /// @notice The LegacyRiskModule's charge is zero, out of bounds or inconsistent with the units credited.
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
    /// @param required `DEBT_MARK_GAS_FLOOR`.
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

    /// @param usdCharge Charge booked, USD 8 decimals.
    /// @param sliceUsd Part of `usdCharge` booked in the market's top-up slice.
    event CollateralPledged(
        uint256 indexed recordId,
        bytes32 indexed positionKey,
        address indexed depositor,
        uint32 integrationId,
        address proxy,
        address vaultToken,
        uint128 credited,
        uint256 usdCharge,
        uint256 sliceUsd
    );

    /// @notice A record was closed and the LPVault returned its whole position to the depositor of record.
    /// @param unitsBurned Units burned for this release; 0 for `releaseZeroCredit`.
    event CollateralReleased(
        uint256 indexed recordId,
        bytes32 indexed positionKey,
        address indexed depositor,
        address proxy,
        address vaultToken,
        uint256 unitsBurned
    );

    /// @notice One record was debited, in a seizure settlement or in a reconciliation.
    /// @param amounts Principal per token unwound (to LPVaultSwap, or to pending for a reconciliation).
    /// @param capReleased USD (8 decimals) of exposure released.
    event RecordDebited(
        uint256 indexed recordId,
        bytes32 indexed positionKey,
        address indexed proxy,
        address vaultToken,
        uint256 unitsDebited,
        uint256 creditedAfter,
        uint256[] amounts,
        uint256 capReleased
    );

    /// @param amounts Principal per token unwound to LPVaultSwap.
    event SeizureSettled(
        address indexed proxy, address indexed vaultToken, uint256 units, uint256[] amounts, uint256 recordsDebited
    );

    /// @notice A reconciliation debited an account-market's shortfall into the pending-settlement balance.
    event SeizureReconciled(address indexed proxy, address indexed vaultToken, uint256 units, uint256[] amounts);

    /// @notice Burned units of an unsettled seizure were settled and their pending pool tokens sent to LPVaultSwap.
    event PendingSettled(address indexed vaultToken, uint256 units, uint256[] amounts);

    /// @notice An exposure counter subtraction was clamped at 0.
    /// @dev Exits never revert on counter arithmetic; saturation signals a bug.
    /// @param key Vault token or pool token that keys the counter.
    /// @param subtracted Amount that was to be subtracted, USD 8 decimals.
    event CounterSaturated(
        CounterKind counterKind, address indexed hub, address key, uint256 valueBefore, uint256 subtracted
    );

    /// @notice A record was reduced by a partial removal or a deleverage release.
    /// @param release USD (8 decimals) of exposure released.
    event RecordReduced(uint256 indexed recordId, uint128 units, uint256 release);

    /// @param charge USD (8 decimals) booked for the added units.
    event RecordRecredited(uint256 indexed recordId, uint128 added, uint256 charge, uint128 rescueUnits);
}
