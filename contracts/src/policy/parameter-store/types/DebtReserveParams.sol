// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Settlement parameters of one debt asset on the chain, in base units of that asset.
/// @dev Written by `setDebtAssetParams`. `floorRoundingAllowance` is subtracted from the recovery floor of a liquidation
/// repaid in the asset (SPEC-LIQ-005). There is no settlement budget and so no budget bound (Q-397): the caller pays
/// any rounding gap at final settlement through the shortfall top-up.
/// @custom:spec REQ-PSTORE-006, REQ-CONFIG-050, Q-380, Q-397
struct DebtReserveParams {
    // Allowance subtracted from the recovery floor, base units.
    uint256 floorRoundingAllowance;
}
