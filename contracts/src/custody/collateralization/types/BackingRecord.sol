// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice One backing record per pledged position, packed into 5 storage slots.
/// @dev USD values have 8 decimals. A record exists while `depositor != address(0)`.
struct BackingRecord {
    bytes32 positionKey;
    address depositor;
    uint32 integrationId;
    uint32 marketId;
    bool inList;
    address proxy;
    uint40 pledgedAt;
    uint40 lastDebitedAt;
    uint16 windowedBps;
    uint128 credited;
    uint128 originalUnits;
    uint128 rescueUnits;
    uint64 originalUsdCharge;
    uint64 currentUsdCharge;
}
