// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The outcome of withdrawing a record or part of it.
/// @dev `healthFactorAfter` WAD, rounded down; `allowed` is conservative.
struct WithdrawPreview {
    uint256 blockNumber;
    uint256 timestamp;
    uint256 units;
    uint256 healthFactorAfter;
    bool allowed;
}
