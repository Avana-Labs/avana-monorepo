// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Outcome of `liquidate`.
/// @dev Every amount except `unitsSeized` and `amountsOut` is in base units of the repaid debt asset; `amountsOut` is in
/// raw units of each pool token, market token order. Payout order: Avana's fee `A` (20 % of the oracle gain `G`, capped
/// at the surplus `S`), then the borrower's surplus `B`, then the caller (AMMN-FLOW-23). Conservation:
/// `callerFunds + recovered + shortfall = debtRepaid + avanaFee + borrowerSurplus + keeperOut`, and
/// `keeperOut = callerFunds + keeperReward` whenever `recovered + shortfall >= debtRepaid` (SPEC-LIQ-010). No flash
/// field exists: LPVaultSwap takes no flash loan in a liquidation (Q-404).
/// @custom:spec SPEC-LIQ-005, SPEC-LIQ-006, SPEC-LIQ-009, SPEC-LIQ-010, SPEC-LIQ-017, SPEC-LIQ-019, SPEC-LIQ-022, Q-379, Q-397, Q-404
struct LiquidationResult {
    // Debt asset repaid.
    address debtAsset;
    // D, debt asset Aave pulled.
    uint256 debtRepaid;
    // c, vault-token units seized.
    uint256 unitsSeized;
    // Raw amount of each pool token the unwind of c returned.
    uint256[] amountsOut;
    // Kf, debt asset LPVaultSwap received from the caller.
    uint256 callerFunds;
    // R, debt asset recovered from the unwind and the swap routes.
    uint256 recovered;
    // minRec, the recovery floor (SPEC-LIQ-005), tested on R + shortfall.
    uint256 minOut;
    // A, Avana fee.
    uint256 avanaFee;
    // kr, keeper reward (SPEC-LIQ-022).
    uint256 keeperReward;
    // Debt asset paid to the caller: the unused funding, the recovered principal and kr.
    uint256 keeperOut;
    // B, debt asset paid (or escrowed) to the borrower's wallet.
    uint256 borrowerSurplus;
    // Caller funds pulled to cover recovery below the floor (0 when none).
    uint256 shortfall;
}
