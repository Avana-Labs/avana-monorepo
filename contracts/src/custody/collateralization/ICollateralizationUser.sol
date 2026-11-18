// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ICollateralizationUser
/// @notice Depositor actions that need no debt check: release of a record at 0 credited units and fee collection.
/// @dev Called through the AaveAdapter while it holds the lock.
interface ICollateralizationUser {
    /// @notice Returns the position of a record at 0 credited units to its depositor.
    function releaseZeroCredit(
        address depositor,
        address vaultToken,
        bytes32 positionKey
    ) external;

    /// @notice Collects every owed fee of a record's position to its depositor.
    /// @return amounts Fees collected per token, pool order.
    function collectFees(
        address depositor,
        address vaultToken,
        bytes32 positionKey
    ) external returns (uint256[] memory amounts);
}
