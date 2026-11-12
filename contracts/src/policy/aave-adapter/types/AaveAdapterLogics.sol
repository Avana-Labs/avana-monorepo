// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The four logic contracts of an AaveAdapter implementation, each built with the implementation's
/// immutables.
/// @custom:spec REQ-ADAPTER-004
struct AaveAdapterLogics {
    // pledge, borrow, repay.
    address user;
    // withdraw, repayAllAndWithdraw, collectFees, releaseZeroCredit, refreshDebtMark.
    address exit;
    // removeLiquidity, recredit, repayWithCollateral.
    address collateral;
    // burnSeized, deleverageRepay, deleverageRelease.
    address settlement;
}
