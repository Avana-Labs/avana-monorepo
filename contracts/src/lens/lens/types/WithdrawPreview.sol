// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The outcome of withdrawing a record or part of it (REQ-LENS-049).
/// @dev `units` the units previewed; `healthFactorAfter` WAD, rounded down, `type(uint256).max` with no debt;
/// `allowed` conservative (the account's whole rescue exclusion subtracted).
/// @custom:spec REQ-LENS-049, REQ-LENS-005
struct WithdrawPreview {
    uint256 blockNumber;
    uint256 timestamp;
    uint256 units;
    uint256 healthFactorAfter;
    bool allowed;
}
