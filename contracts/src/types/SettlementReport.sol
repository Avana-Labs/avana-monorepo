// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RouteMode} from "../liquidation/lp-vault-swap/types/RouteMode.sol";

/// @notice Settlement figures of one liquidation, carried by `LiquidationSettled`.
/// @dev Every amount except `unitsSeized` and `amountsOut` is in base units of `debtAsset`.
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
    // minRec, the recovery floor.
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
    // B, the full borrower surplus (part may go to the First-Loss Reserve when a deficit is booked).
    uint256 borrowerSurplus;
    // Debt asset paid to the caller: unused funding, recovered principal and kr.
    uint256 keeperOut;
    // Smallest payout the caller accepted.
    uint256 minPayout;
    // Route mode the caller chose.
    RouteMode routeMode;
    // Swap route used per token, pool order: 0 none, 1 primary, 2 backup.
    uint8[] routeUsed;
    // Caller top-up pulled to cover recovery below the floor.
    uint256 shortfall;
}
