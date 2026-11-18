// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Whether an AMM protocol's composition at an oracle price vector is exact.
/// @dev Ordinal values are fixed.
enum PricingMode {
    ClosedForm,
    LowerBound
}
