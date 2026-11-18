// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice One Chainlink input of a market's price.
/// @dev Freshness flags follow execution's `PriceAge` rules; a future timestamp is never borrow-fresh.
struct PriceInput {
    address feed;
    uint256 updatedAt;
    uint256 age;
    uint256 borrowPriceMaxAge;
    uint256 liquidationPriceMaxAge;
    bool borrowFresh;
    bool liquidationFresh;
}
