// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice One debt of an account to repay before it closes.
struct DebtClose {
    uint256 reserveId;
    address asset;
    // `getUserTotalDebt`, base units.
    uint256 total;
    // `quoteRepayAll` for the same deadline: the spend cap and approval of `repayAll`.
    uint256 maxRepaySpend;
}

/// @notice One record an account withdraws when it closes.
struct RecordClose {
    bytes32 positionKey;
    // Credited units after reconciliation, the `units` of `AaveAdapter.withdraw`.
    uint256 units;
    // The record's token amounts at the oracle prices (`composition`), pool order.
    uint256[] amounts;
}

/// @notice Everything an account repays and withdraws to close.
/// @dev Repay and debt-free withdrawal are open in every state, so an account can always close.
struct CloseAccountView {
    uint256 blockNumber;
    uint256 timestamp;
    address proxy;
    DebtClose[] debts;
    RecordClose[] records;
}
