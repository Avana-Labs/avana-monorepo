// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice State of a First-Loss Reserve withdrawal request. `None` is an ID never requested.
enum WithdrawalStatus {
    None,
    Pending,
    Cancelled,
    Executed
}

/// @notice A withdrawal request of the Aave DAO on a First-Loss Reserve.
/// @param amount Asset base units requested; execution withdraws at most `fundedBalance()`.
/// @param executableAt Earliest execution time, seconds.
struct Withdrawal {
    uint256 amount;
    address to;
    uint64 executableAt;
    WithdrawalStatus status;
}
