// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Uncollected fees of one position (REQ-LENS-050).
/// @dev `amounts[i]` is what `collectFees` would pay for the position in the same block, in pool order and base
/// units: `tokensOwed[i]` plus `liquidity × (feeGrowthInside − feeGrowthInsideLast) / 2^128`, the position
/// manager's own update. All zero when `supported` is false.
/// @custom:spec REQ-LENS-050, REQ-LENS-005
struct PositionFeesView {
    uint256 blockNumber;
    uint256 timestamp;
    uint256 marketId;
    bytes32 positionKey;
    // The market's AMM protocol has a fee reader (Uniswap v3, Aerodrome Slipstream, fees paid separately) and the
    // position belongs to the market's pool.
    bool supported;
    // Held by the market's LPVault.
    bool inCustody;
    // Depositor of record, address(0) out of custody.
    address depositor;
    // Position liquidity.
    uint128 liquidity;
    // Fees already credited to the position (`tokensOwed`), pool order.
    uint256[] tokensOwed;
    // Uncollected fees: what `collectFees` pays, pool order.
    uint256[] amounts;
}
