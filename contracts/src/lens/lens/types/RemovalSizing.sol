// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice One record's withdrawal against a target health factor (REQ-LENS-054).
/// @custom:spec REQ-LENS-054
struct RecordRemoval {
    bytes32 positionKey;
    // Credited units after reconciliation: what `AaveAdapter.withdraw` takes for the record.
    uint256 units;
    // Withdrawing the record alone keeps the account at or above the target and passes the withdrawal gates.
    bool fits;
}

/// @notice The largest collateral removal that keeps an account at or above a target health factor (REQ-LENS-054).
/// @dev `target` is `max(targetHealthFactor, 1e18, hardHealthFloor)` with debt; `maxUnits` the most vault-token
/// units the account can remove and stay at or above `target` (rescue exclusion subtracted, removal valued up), 0 when
/// the withdraw-with-debt gate is closed, every credited unit with no debt; `bestIndex` the record with the most units
/// among those that fit, `type(uint256).max` when none fits.
/// @custom:spec REQ-LENS-054, REQ-LENS-005
struct RemovalSizing {
    uint256 blockNumber;
    uint256 timestamp;
    address proxy;
    uint256 target;
    uint256 maxUnits;
    uint256 bestIndex;
    RecordRemoval[] records;
}
