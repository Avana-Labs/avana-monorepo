// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RouteMode} from "../liquidation/lp-vault-swap/types/RouteMode.sol";

/// @notice Settlement figures of one liquidation, carried by `LiquidationSettled`.
/// @dev Every amount except `unitsSeized` and `amountsOut` is in base units of `debtAsset`, the asset that was repaid;
/// GHO appears only when the debt is GHO. `amountsOut[i]` is the raw principal of the market's token i (pool order)
/// the unwind returned; `routeUsed[i]` is 0 none (token i is the debt asset, a dust leg or its amount is 0), 1 primary,
/// 2 backup. Conservation: `callerFunds + recovered + shortfall = debtRepaid + avanaFee + borrowerSurplus + keeperOut`,
/// and `avanaFee + keeperReward + borrowerSurplus = surplus`. No flash field and no permissionless flag exist:
/// LPVaultSwap takes no flash loan in a liquidation, and every caller uses the same entry point (Q-404).
/// @custom:spec SPEC-LIQ-001, SPEC-LIQ-003, SPEC-LIQ-005, SPEC-LIQ-006, SPEC-LIQ-008, SPEC-LIQ-009, SPEC-LIQ-010, SPEC-LIQ-017, SPEC-LIQ-019, SPEC-LIQ-022, REQ-SWAP-026, REQ-SWAP-089, REQ-SWAP-101, Q-370, Q-373, Q-404
struct SettlementReport {
    // Debt reserve repaid.
    uint256 debtReserveId;
    // Debt asset repaid and paid out.
    address debtAsset;
    // D, debt asset Aave pulled.
    uint256 debtRepaid;
    // c, vault-token units seized.
    uint256 unitsSeized;
    // Raw token amounts the unwind returned, pool order.
    uint256[] amountsOut;
    // R, debt asset recovered from the unwind and the swaps.
    uint256 recovered;
    // minRec, the recovery floor (SPEC-LIQ-005).
    uint256 minOut;
    // s, bps.
    uint256 effectiveSlippageBps;
    // bNet, bps (1e4 = no bonus).
    uint256 bonusBps;
    // Kf, debt asset LPVaultSwap received from the caller.
    uint256 callerFunds;
    // S, realized surplus.
    uint256 surplus;
    // A, Avana's fee.
    uint256 avanaFee;
    // kr, keeper reward.
    uint256 keeperReward;
    // B, surplus paid or escrowed to the borrower.
    uint256 borrowerSurplus;
    // Debt asset paid to the caller: unused funding, recovered principal and kr.
    uint256 keeperOut;
    // Smallest payout the caller accepted.
    uint256 minPayout;
    // Route mode the caller chose.
    RouteMode routeMode;
    // Swap route used per token, pool order.
    uint8[] routeUsed;
    // Caller top-up pulled to cover recovery below the floor.
    uint256 shortfall;
}
