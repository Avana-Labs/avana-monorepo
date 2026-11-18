// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RouteMode} from "../liquidation/lp-vault-swap/types/LPVaultSwapTypes.sol";

/// @notice Identity of one AMM position held in custody.
struct PositionRef {
    uint32 integrationId;
    // Integration-defined position key.
    bytes32 positionKey;
}

/// @notice Exact position shape of a market, fixed at listing.
/// @dev For `TickRange`, `tickLower < tickUpper`, both aligned to the tick spacing; for `FullPool` both are 0.
struct PositionShape {
    ShapeKind kind;
    // Lower tick of the exact range (0 for FullPool).
    int24 tickLower;
    // Upper tick of the exact range (0 for FullPool).
    int24 tickUpper;
}

/// @notice Kind of position shape a market accepts.
/// @dev Ordinal values are fixed.
enum ShapeKind {
    None,
    TickRange,
    FullPool
}

/// @notice Current Collateralization exposure counters a pledge touches, passed by Collateralization to `checkPledge`.
/// @dev 8-decimal USD; the pool counter is shared by every market of the pool.
struct PledgeCounters {
    address hub;
    // Market regular counter R.
    uint128 regularUsed;
    // Market slice counter S.
    uint128 sliceUsed;
    // Pool the pool-share counter is keyed by.
    bytes32 poolKey;
    // poolUnits(poolKey): credited units summed over every market of the pool on the chain.
    uint256 poolUnits;
    // Open records of the account in the market before this pledge.
    uint256 accountRecords;
    // tokenUsd[hub][tokens[i]] per token in pool order.
    uint256[] tokenUsed;
}

/// @notice Non-reverting outcome of the pledge checks for the app and the Lens.
/// @dev Room values are 8-decimal USD, except `poolShareRoomUnits` in vault-token base units.
struct PledgePreview {
    // True when checkPledge would pass.
    bool eligible;
    // Selector of the first failing custom error, or 0.
    bytes4 reason;
    // True when the account has debt on any debt reserve of the market's CDP Spoke.
    bool isTopUp;
    // Charge that would be booked.
    uint256 usdCharge;
    // Slice part of the charge.
    uint256 sliceUsd;
    // marketUsdCap minus the regular counter, floored at 0.
    uint256 marketRoomUsd;
    // topUpSliceUsd minus the slice counter, floored at 0.
    uint256 sliceRoomUsd;
    // Per-token room in pool order.
    uint256[] tokenRoomUsd;
    // Units still admissible under the pool-share cap.
    uint256 poolShareRoomUnits;
    // Open records the account may still add to the market.
    uint256 recordRoom;
}

/// @notice Pending-settlement balance of a market and whether LPVaultSwap can settle it.
struct PendingView {
    uint256 blockNumber;
    uint256 timestamp;
    address vaultToken;
    uint256 units;
    uint256[] amounts;
    uint256 unsettledSeizedUnits;
    uint256 settleableUnits;
    bool settleable;
    address debtAsset;
    address firstLossReserve;
    uint256 valueDebt;
}

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
