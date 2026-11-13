// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The binding the AaveAdapter stores for a proxy in the pledge that creates it, never changed afterwards.
/// @dev Exits read it instead of the MarketRegistry (Q-260).
/// @custom:spec REQ-ADAPTER-066, REQ-PROXY-049, REQ-PROXY-053
struct AdapterAccount {
    // The market's CDP Spoke.
    address spoke;
    // The market.
    uint256 marketId;
    // The market's vault token.
    address vaultToken;
    // The vault token's reserve on `spoke`.
    uint256 reserveId;
}
