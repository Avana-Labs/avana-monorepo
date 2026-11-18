// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The smallest repay with collateral of one record that brings an account to a target health factor.
/// @dev `reachable` false (amounts 0) when the call is closed or the target cannot be reached.
struct DeleverageSizing {
    uint256 blockNumber;
    uint256 timestamp;
    address proxy;
    bool reachable;
    uint256 units;
    uint256 debtRepaid;
    uint256 debtAssetToWallet;
    uint256 healthFactorAfter;
}
