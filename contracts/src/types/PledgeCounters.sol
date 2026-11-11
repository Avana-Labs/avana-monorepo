// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Current Collateralization exposure counters a pledge touches, passed by Collateralization to `checkPledge`.
/// @dev 8-decimal USD, read by Collateralization from its own storage in the same call (`Collateralization.getCounters`).
/// `tokenUsed[i]` is `tokenUsd[hub][tokens[i]]` for the market's token i in pool order; `tokenUsed.length` equals the
/// market's token count. Token and depositor counters are keyed by the market's Hub and summed across every Spoke and
/// market of that Hub on the chain, so listing another Spoke never multiplies a Hub-wide cap (AMMN-RT-05). The pool
/// counter is keyed by pool, not by Hub or market: `poolUnits` is `poolUnits(poolKey)`, the credited units of every
/// market (range) of the market's pool on the chain, with `poolKey = keccak256(abi.encode(integrationId, pool,
/// poolId))`, so k ranges of one pool share one `poolShareMaxBps` (AMMN-RT-05). `accountRecords` counts the open
/// records of the (PositionProxy, market).
/// @custom:spec SPEC-CAP-002, REQ-RISK-004, Q-209, Q-369, Q-370
struct PledgeCounters {
    // Hub the counters are scoped to.
    address hub;
    // Market regular counter R.
    uint128 regularUsed;
    // Market slice counter S.
    uint128 sliceUsed;
    // depositorUsd[hub][depositor].
    uint256 depositorUsed;
    // Pool the pool-share counter is keyed by.
    bytes32 poolKey;
    // poolUnits(poolKey): credited units summed over every market of the pool on the chain.
    uint256 poolUnits;
    // Open records of the account in the market before this pledge (Collateralization reverts TooManyRecords at 16).
    uint256 accountRecords;
    // tokenUsd[hub][tokens[i]] per token in pool order.
    uint256[] tokenUsed;
}
