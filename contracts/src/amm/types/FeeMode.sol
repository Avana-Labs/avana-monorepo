// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice How an AMM protocol pays trading fees to a position: collected separately, or rolled into the reserves.
/// @dev Ordinal values are fixed.
enum FeeMode {
    Separate,
    RolledIn
}
