// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Outcome of `liquidate`.
/// @dev Amounts other than `unitsSeized` and `amountsOut` are in base units of the repaid debt asset.
struct LiquidationResult {
    address debtAsset;
    uint256 debtRepaid;
    uint256 unitsSeized;
    // Raw amount of each pool token the unwind returned, market token order.
    uint256[] amountsOut;
    uint256 callerFunds;
    uint256 recovered;
    // Recovery floor, tested on recovered + shortfall.
    uint256 minOut;
    uint256 avanaFee;
    uint256 keeperReward;
    // Debt asset paid to the caller: unused funding, recovered principal and keeper reward.
    uint256 keeperOut;
    // Full borrower surplus; when a deficit is booked the First-Loss Reserve takes part of it.
    uint256 borrowerSurplus;
    uint256 shortfall;
}
