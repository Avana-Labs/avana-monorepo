// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Identity of one AMM position held in custody.
struct PositionRef {
    uint32 integrationId;
    // Integration-defined position key.
    bytes32 positionKey;
}
