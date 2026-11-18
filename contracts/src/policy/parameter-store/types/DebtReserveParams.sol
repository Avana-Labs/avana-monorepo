// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Settlement parameters of one debt asset on the chain, in base units of that asset.
struct DebtReserveParams {
    // Allowance subtracted from the recovery floor, base units.
    uint256 floorRoundingAllowance;
}
