// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RouteMode} from "./RouteMode.sol";

/// @notice Arguments of `liquidate`, the one liquidation entry point.
/// @dev No caller, recipient, route, lender, funding source, recovery-floor override or executable calldata is taken
/// from the caller, and no caller-funds or flash-amount field exists: LPVaultSwap pulls `debtToCover` from
/// `msg.sender` and measures what arrived (`Kf`); how the caller obtained the debt asset (its own balance, the public
/// flash liquidation helper or its own helper) is outside LPVaultSwap (Q-404). `deadline` and `minPayout` can only make
/// the call revert; they change no amount, route or recipient. `maxShortfall` adds the caller's own debt asset below
/// the recovery floor and lowers the per-leg minimums by at most `maxShortfallBps` (SPEC-LIQ-019); it never lowers the
/// floor or Avana's fee. Every amount is in base units of the debt reserve's asset: the call is funded, settled and
/// paid out in the debt asset that is repaid. `Lens.previewLiquidation` returns a value of this struct that can be
/// sent unchanged.
/// @custom:spec REQ-SWAP-005, REQ-SWAP-011, REQ-SWAP-046, REQ-SWAP-074, REQ-SWAP-075, REQ-SWAP-087, REQ-SWAP-088, REQ-SWAP-101, SPEC-LIQ-019, Q-216, Q-232, Q-235, Q-251, Q-379, Q-404
struct LiquidationParams {
    // Borrower's PositionProxy (the Aave account of one market).
    address proxy;
    // Collateral market to seize; must equal the proxy's MARKET_ID().
    uint256 marketId;
    // Debt reserve to repay, from the CDP Spoke's enabled debt set.
    uint256 debtReserveId;
    // X, debt asset pulled from msg.sender; the measured Kf <= X is Aave's bound in liquidationCall.
    uint256 debtToCover;
    // Swap-route mode; either value for every caller.
    RouteMode routeMode;
    // Least raw amount of each pool token the unwind must return, market token order; empty for no caller minimum.
    uint256[] minAmounts;
    // Last valid block.timestamp.
    uint256 deadline;
    // Smallest keeperOut the caller accepts; keeperOut includes the returned funding, so this is the funding plus the
    // smallest net payout accepted (Q-345).
    uint256 minPayout;
    // Most of the caller's own debt asset the call may pull, beyond Kf, to cover recovery below the floor; 0 disables
    // the top-up.
    uint256 maxShortfall;
}
