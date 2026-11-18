// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationParams} from "../../../liquidation/lp-vault-swap/types/LPVaultSwapTypes.sol";

/// @notice Arguments of a flash liquidation helper's `flashLiquidate`.
/// @dev Amounts are in base units of the debt asset. The helper takes no route, recipient, lender or calldata from it.
struct FlashLiquidationRequest {
    // Passed unchanged to LPVaultSwap.liquidate.
    LiquidationParams params;
    // F, the amount borrowed; 0 (no loan) only in the operator variant.
    uint256 flashAmount;
    // Most premium accepted on F.
    uint256 maxPremium;
    // Most debt asset pulled from the payer to repay the loan.
    uint256 maxTopUp;
    // Smallest net payout after the loan and premium are repaid.
    uint256 minPayout;
}
