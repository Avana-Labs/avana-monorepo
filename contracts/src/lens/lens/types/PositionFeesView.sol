// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Uncollected fees of one position.
/// @dev `amounts` are what `collectFees` would pay in the same block, pool order; all zero when unsupported.
struct PositionFeesView {
    uint256 blockNumber;
    uint256 timestamp;
    uint256 marketId;
    bytes32 positionKey;
    // The AMM protocol has a fee reader and the position belongs to the market's pool.
    bool supported;
    bool inCustody;
    // Depositor of record, address(0) out of custody.
    address depositor;
    uint128 liquidity;
    // Fees already credited to the position (`tokensOwed`), pool order.
    uint256[] tokensOwed;
    uint256[] amounts;
}
