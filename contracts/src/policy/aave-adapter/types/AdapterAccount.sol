// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The binding the AaveAdapter stores for a proxy in the pledge that creates it, never changed afterwards.
/// @dev Exits read it instead of the MarketRegistry.
struct AdapterAccount {
    address spoke;
    uint256 marketId;
    address vaultToken;
    uint256 reserveId;
}
