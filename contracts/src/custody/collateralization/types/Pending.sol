// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Pending-settlement balance of a market.
/// @dev `units`: reconciled units not yet burned; `amounts`: principal per market token backing them.
struct Pending {
    uint256 units;
    uint256[] amounts;
}
