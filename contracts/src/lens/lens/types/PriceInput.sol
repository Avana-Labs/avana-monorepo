// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice One Chainlink input of a market's price.
/// @dev `updatedAt` is the original source timestamp; `age = timestamp - updatedAt` in seconds; the two limits and
/// freshness flags use ParameterStore values read in the same call.
/// @custom:spec REQ-LENS-015
struct PriceInput {
    address feed;
    uint256 updatedAt;
    uint256 age;
    uint256 borrowPriceMaxAge;
    uint256 liquidationPriceMaxAge;
    bool borrowFresh;
    bool liquidationFresh;
}
