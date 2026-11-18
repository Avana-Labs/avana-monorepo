// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice One record of an account's seizure list.
/// @dev `creditedAfterReconcile` is the `units` a borrower passes to `AaveAdapter.withdraw`.
struct RecordView {
    uint256 blockNumber;
    uint256 timestamp;
    uint256 recordId;
    uint32 integrationId;
    bytes32 positionKey;
    address depositor;
    uint256 credited;
    uint256 liveUnits;
    uint256 creditedAfterReconcile;
}
