// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Bounds shared by every AMM integration, the ledger and the oracles.
/// @dev `MAX_RECORDS_PER_ACCOUNT_MARKET` keeps a seizure within one transaction's gas.
library AmmConstants {
    uint256 internal constant MIN_POOL_TOKENS = 2;
    uint256 internal constant MAX_POOL_TOKENS = 8;
    uint256 internal constant MAX_RECORDS_PER_ACCOUNT_MARKET = 16;
}
