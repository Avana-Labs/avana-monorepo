// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice An account before and after one action at the block's prices.
/// @dev Health factors WAD rounded down; liquidation prices USD 8 decimals per whole vault token, rounded up.
struct ActionPreview {
    uint256 blockNumber;
    uint256 timestamp;
    address proxy;
    uint256 amount;
    uint256 healthFactorBefore;
    uint256 healthFactorAfter;
    uint256 liquidationPriceBefore;
    uint256 liquidationPriceAfter;
    uint256 collateralValueAfter;
    uint256 debtValueAfterRay;
}
