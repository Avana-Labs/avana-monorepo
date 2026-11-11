// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationParams} from "../../../liquidation/lp-vault-swap/types/LiquidationParams.sol";

/// @notice Arguments of a flash liquidation helper's `flashLiquidate`.
/// @dev Every amount is in base units of the debt asset of `params.debtReserveId`. `params` is passed to
/// `LPVaultSwap.liquidate` unchanged; the helper takes no route, recipient, lender or executable calldata from the
/// request (REQ-HELPER-012). `minPayout` bounds the net payout after the loan and its premium are repaid (Q-345);
/// `params.minPayout` stays the bound LPVaultSwap checks on `keeperOut` and may be left at 0.
/// @custom:spec REQ-HELPER-003, REQ-HELPER-004, REQ-HELPER-005, REQ-HELPER-007, REQ-HELPER-008, REQ-HELPER-012, Q-345, Q-404
struct FlashLiquidationRequest {
    // Passed unchanged to LPVaultSwap.liquidate; the helper funds params.debtToCover.
    LiquidationParams params;
    // F, debt asset borrowed from the Aave V3 Pool; 0 < F <= params.debtToCover. The helper pulls the rest from its payer.
    uint256 flashAmount;
    // Most premium accepted on F.
    uint256 maxPremium;
    // Most debt asset pulled from the payer after liquidate when keeperOut is below F + premium.
    uint256 maxTopUp;
    // Smallest net payout to the payout recipient after the loan and premium are repaid.
    uint256 minPayout;
}
