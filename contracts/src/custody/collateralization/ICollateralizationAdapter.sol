// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ICollateralizationAdapter
/// @notice Pledge, release, partial removal, re-credit and deleverage release of backing records.
/// @dev Callable only by the AaveAdapter while it holds the lock.
interface ICollateralizationAdapter {
    /// @notice Takes custody of a position, books its charge and writes its record; returns the units to mint.
    /// @param depositor The wallet that called `Adapter.pledge`; becomes the depositor of record.
    /// @param requireRescue True when only a rescue top-up may pass.
    function pledge(
        address depositor,
        address proxy,
        address vaultToken,
        bytes32 positionKey,
        bool requireRescue
    ) external returns (uint256 recordId, uint128 credited);

    /// @notice Debits a record's units after the Adapter burned them, closes it and returns the position.
    /// @dev `units` must equal the record's credited units after reconciliation.
    function release(
        address proxy,
        address vaultToken,
        bytes32 positionKey,
        uint256 units
    ) external;

    /// @notice Debits part of a record after the Adapter burned it and releases that principal to the depositor.
    /// @dev Requires `0 < units < record.credited`.
    function releasePartial(
        address proxy,
        address vaultToken,
        bytes32 positionKey,
        uint128 units,
        uint256[] calldata minAmounts
    ) external returns (uint128 remaining, uint256[] memory amounts);

    /// @notice Credits the live units a depositor added to a pledged position; returns the units to mint.
    /// @param topUp Encoded LP amount the LPVault pulls from the depositor; empty for an NFT integration.
    function recredit(
        address depositor,
        address proxy,
        address vaultToken,
        bytes32 positionKey,
        bytes calldata topUp,
        bool requireRescue
    ) external returns (uint128 added, uint128 rescueUnits);

    /// @notice Debits a record by units burned in a repay with collateral and unwinds them to LPVaultSwap.
    /// @dev Requires `0 < units <= record.credited`.
    /// @return amounts Principal per token unwound to LPVaultSwap, pool order.
    function releaseForDeleverage(
        address proxy,
        address vaultToken,
        bytes32 positionKey,
        uint128 units,
        uint256[] calldata minAmounts
    ) external returns (uint256[] memory amounts, bool closed);
}
