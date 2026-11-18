// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice One record's withdrawal against a target health factor.
struct RecordRemoval {
    bytes32 positionKey;
    // Credited units after reconciliation: what `AaveAdapter.withdraw` takes for the record.
    uint256 units;
    // Withdrawing the record alone keeps the account at or above the target and passes the withdrawal gates.
    bool fits;
}

/// @notice The largest collateral removal that keeps an account at or above a target health factor.
/// @dev `bestIndex` is the fitting record with the most units, `type(uint256).max` when none fits.
struct RemovalSizing {
    uint256 blockNumber;
    uint256 timestamp;
    address proxy;
    uint256 target;
    uint256 maxUnits;
    uint256 bestIndex;
    RecordRemoval[] records;
}
