// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice One record of an account's seizure list (one market, at most 16 records).
/// @dev `liveUnits` is the position's live units as the market's AMM integration reports them for `positionKey`;
/// `creditedAfterReconcile` is the credited units after Collateralization reconciles the account's shortfall (debited
/// from the head of the list), the `units` a borrower passes to `AaveAdapter.withdraw`.
/// @custom:spec REQ-LENS-011, Q-376
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
