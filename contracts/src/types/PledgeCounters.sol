// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

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
