// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice An account's liquidation price and borrow rates.
/// @dev `liquidationPrice` USD 8 decimals per whole vault token, rounded up; rates RAY per year, rounded up.
struct AccountRiskView {
    uint256 blockNumber;
    uint256 timestamp;
    address proxy;
    uint256 liquidationPrice;
    uint256[] reserveIds;
    uint256[] borrowRatesRay;
}
