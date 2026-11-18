// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Custody and live liquidity against credited units for one open record of a market.
/// @dev `backed` is `inCustody && liveUnits >= credited`.
struct RecordBackingView {
    uint256 blockNumber;
    uint256 timestamp;
    uint256 recordId;
    uint32 integrationId;
    bytes32 positionKey;
    uint256 credited;
    uint256 liveUnits;
    bool inCustody;
    bool backed;
}
