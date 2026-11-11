// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Bounds shared by every AMM integration, the ledger and the oracles.
/// @dev `MAX_POOL_TOKENS` bounds every n-token array: a market lists between 2 and 8 tokens (Curve StableSwap-NG and
/// Balancer pools hold at most 8). `MAX_RECORDS_PER_ACCOUNT_MARKET` bounds the open backing records of one
/// (PositionProxy, market): a seizure walks at most 16 records, about 1.31M + 16 x 0.29M = 5.95M gas, under 36 % of the
/// 16.78M per-transaction gas cap, so every account stays liquidatable in one transaction (AMMN-GAS-01).
/// @custom:spec REQ-AMM-CORE-002, REQ-VAULT-025, Q-369, Q-370
library AmmConstants {
    uint256 internal constant MIN_POOL_TOKENS = 2;
    uint256 internal constant MAX_POOL_TOKENS = 8;
    uint256 internal constant MAX_RECORDS_PER_ACCOUNT_MARKET = 16;
}
