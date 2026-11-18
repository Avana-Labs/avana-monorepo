// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ICollateralizationSeizure
/// @notice Seizure snapshot and settlement, and settlement of the pending balance.
/// @dev Called only by LPVaultSwap while it holds the lock.
interface ICollateralizationSeizure {
    /// @notice Snapshots the proxy's supplied shares and the token's supply before `Spoke.liquidationCall`.
    function beginSeizure(
        address proxy,
        address vaultToken
    ) external;

    /// @notice Checks the share and supply drops, debits records and unwinds the seized units to LPVaultSwap.
    /// @dev The supply drop must equal `units`; any extra share drop is Aave's liquidation fee and goes to pending.
    /// @param units Seized units LPVaultSwap received and had the Adapter burn.
    /// @param minAmounts Per-token minimums of the summed unwind, pool order.
    /// @return amounts Principal per token unwound to LPVaultSwap, pool order.
    function settleSeizure(
        address proxy,
        address vaultToken,
        uint256 units,
        uint256[] calldata minAmounts
    ) external returns (uint256[] memory amounts);

    /// @notice Pays LPVaultSwap the pending pool tokens matching burned units of an unsettled seizure.
    /// @dev Pro-rata share rounded down; the exact remainder when settling all pending units.
    function settlePending(
        address vaultToken,
        uint256 units
    ) external returns (uint256[] memory amounts);
}
