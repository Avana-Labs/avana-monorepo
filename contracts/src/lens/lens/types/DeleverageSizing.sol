// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The smallest repay with collateral of one record that brings an account to a target health factor
/// (REQ-LENS-055).
/// @dev `units` vault-token units of the record, `debtRepaid` and `debtAssetToWallet` debt-asset base units and
/// `healthFactorAfter` WAD, each as `previewRepayWithCollateral` returns them for `units`. `reachable` is false
/// (and every amount 0) when the call is closed or no units of the record reach the target; with `units = 0` and
/// `reachable` true the account is already at or above the target.
/// @custom:spec REQ-LENS-055, REQ-LENS-005
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
