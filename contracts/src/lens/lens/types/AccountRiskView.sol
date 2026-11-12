// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice An account's liquidation price and borrow rates (REQ-LENS-047).
/// @dev `liquidationPrice` USD 8 decimals per whole vault token, rounded up: 0 with no debt, `type(uint256).max` with
/// debt and no counted collateral. `borrowRatesRay[i]` is the rate of `reserveIds[i]` including the account's risk
/// premium, RAY per year, rounded up.
/// @custom:spec REQ-LENS-047, REQ-LENS-005
struct AccountRiskView {
    uint256 blockNumber;
    uint256 timestamp;
    address proxy;
    uint256 liquidationPrice;
    uint256[] reserveIds;
    uint256[] borrowRatesRay;
}
