// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CounterKind} from "./types/CounterKind.sol";

/// @title ICollateralizationEvents
/// @notice Events of Collateralization.
/// @dev Amount arrays are in the market's pool token order.
interface ICollateralizationEvents {
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
