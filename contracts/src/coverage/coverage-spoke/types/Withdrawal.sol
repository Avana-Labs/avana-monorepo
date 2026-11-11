// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice State of a Coverage Spoke withdrawal request (2.14 Storage). `None` is an ID never requested.
/// @custom:spec REQ-FLR-023, REQ-FLR-024, REQ-FLR-025
enum WithdrawalStatus {
    None,
    Pending,
    Cancelled,
    Executed
}

/// @notice A withdrawal request of the Aave DAO on a Coverage Spoke.
/// @param amount Asset base units requested; execution withdraws `min(amount, fundedBalance())` (SPEC-FLR-003).
/// @param to Recipient the Hub pays directly.
/// @param executableAt Earliest execution time, `requestTime + RESERVE_WITHDRAWAL_DELAY`, seconds.
/// @param status Request state.
/// @custom:spec REQ-FLR-023, SPEC-FLR-003
struct Withdrawal {
    uint256 amount;
    address to;
    uint64 executableAt;
    WithdrawalStatus status;
}
