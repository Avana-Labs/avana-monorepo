// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice An account before and after one action at the block's prices (REQ-LENS-052, REQ-LENS-053).
/// @dev Health factors in WAD, rounded down, `type(uint256).max` with no debt; liquidation prices USD 8 decimals per
/// whole vault token, rounded up, 0 with no debt and `type(uint256).max` with debt and no counted collateral;
/// `collateralValueAfter` Aave value units (USD × 1e26) of the account's vault-token collateral, rounded down;
/// `debtValueAfterRay` Aave value units × RAY of every debt of the account; `amount` the borrowed or repaid
/// debt-asset base units, or the pledged or withdrawn vault-token units.
/// @custom:spec REQ-LENS-052, REQ-LENS-053, REQ-LENS-005
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
